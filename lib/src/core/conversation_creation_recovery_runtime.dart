part of '../handrail_chat_client.dart';

/// Injectable wall clock used for durable conversation-creation FIFO metadata.
typedef ChatConversationCreationClock = DateTime Function();

/// Computes the delay before replaying an ambiguous retained creation command.
typedef ChatConversationCreationRetryBackoff = Duration Function(
  int retryNumber,
);

/// Injectable wait boundary for deterministic retained-creation tests.
typedef ChatConversationCreationRetryWait = Future<void> Function(
  Duration delay,
  ChatCommandCancellationSignal cancellationSignal,
);

/// A credential-free view of one identity-scoped retained creation command.
final class ChatQueuedConversationCreation {
  const ChatQueuedConversationCreation._({
    required this.identity,
    required this.request,
    required this.enqueueOrder,
    required this.enqueuedAt,
  });

  final ApplicationChatStorageIdentity identity;
  final ConversationCreationInput request;
  final int enqueueOrder;
  final DateTime enqueuedAt;
}

final class _ConversationCreationRecoveryRuntime {
  _ConversationCreationRecoveryRuntime({
    required this.storage,
    required this.dispatcher,
    required this.store,
    required this.generateIdempotencyKey,
    required this.generateClientRequestId,
    required this.clock,
    required this.backoff,
    required this.wait,
    required this.lifecycleManaged,
    required this.onStorageDiagnostic,
  }) {
    _storeSubscription = store.acceptedCommitChanges.listen((_) {
      _startPump();
    });
  }

  final ApplicationChatStorage storage;
  final ChatCommandDispatcher dispatcher;
  final NormalizedSnapshotStore store;
  final ChatCommandIdempotencyKeyGenerator generateIdempotencyKey;
  final ChatConversationClientRequestIdGenerator generateClientRequestId;
  final ChatConversationCreationClock clock;
  final ChatConversationCreationRetryBackoff backoff;
  final ChatConversationCreationRetryWait wait;
  final bool lifecycleManaged;
  final void Function(String code, String message) onStorageDiagnostic;

  final List<ChatQueuedConversationCreation> _intents = [];
  final Map<String, _ActiveConversationCreationDispatch> _active = {};
  final Map<String,
          List<Completer<ChatCommandResult<ConversationCreationResult>>>>
      _waiters = {};
  final Map<String, StreamSubscription<void>> _callerCancellations = {};
  late final StreamSubscription<NormalizedSnapshotState> _storeSubscription;
  Future<void> _storageMutation = Future<void>.value();
  Future<void>? _pump;
  ChatCommandCancellationController? _retryWait;
  ApplicationChatStorageIdentity? _identity;
  int _generation = 0;
  int _epoch = 0;
  bool _metadataReady = false;
  bool _connectivityOnline = false;
  bool _realtimeConnected = false;
  bool _applicationForeground = true;
  bool _closed = false;

  List<ChatQueuedConversationCreation> get intents =>
      List.unmodifiable(_intents);

  bool _scopeActive(
    ApplicationChatStorageIdentity identity,
    int generation,
    int epoch,
  ) =>
      !_closed &&
      _identity == identity &&
      _generation == generation &&
      _epoch == epoch;

  bool get _ready =>
      !_closed &&
      _identity != null &&
      _metadataReady &&
      _connectivityOnline &&
      _applicationForeground &&
      (!lifecycleManaged || _realtimeConnected);

  void prepareActivation(
    ApplicationChatStorageIdentity identity, {
    required int generation,
  }) {
    if (_closed) return;
    _invalidateDispatches();
    _completeAll(const ChatCommandClosed<ConversationCreationResult>());
    _identity = identity;
    _generation = generation;
    ++_epoch;
    _intents.clear();
  }

  Future<void> activate(
    ApplicationChatStorageIdentity identity, {
    required int generation,
  }) async {
    if (_identity != identity || _generation != generation) {
      prepareActivation(identity, generation: generation);
    }
    final epoch = _epoch;
    await _serialized<void>(() async {
      if (!_scopeActive(identity, generation, epoch)) return;
      ApplicationChatQueuedConversationCreationIntentsRecord? record;
      try {
        record = await _readRecord(identity);
        if (!_scopeActive(identity, generation, epoch)) return;
      } on FormatException {
        if (!_scopeActive(identity, generation, epoch)) return;
        onStorageDiagnostic(
          ChatClientDiagnosticCode.conversationCreationIntentsRejected,
          'The stored conversation-creation intents were rejected and quarantined.',
        );
        return;
      } catch (_) {
        if (_scopeActive(identity, generation, epoch)) {
          onStorageDiagnostic(
            ChatClientDiagnosticCode.conversationCreationIntentsReadFailed,
            'The stored conversation-creation intents could not be read.',
          );
        }
        return;
      }
      if (_scopeActive(identity, generation, epoch)) _publish(record);
    });
    if (_scopeActive(identity, generation, epoch)) _startPump();
  }

  void updateReadiness({
    required bool metadataReady,
    required bool connectivityOnline,
    required bool realtimeConnected,
    required bool applicationForeground,
  }) {
    if (_closed) return;
    _metadataReady = metadataReady;
    _connectivityOnline = connectivityOnline;
    _realtimeConnected = realtimeConnected;
    _applicationForeground = applicationForeground;
    if (!_ready) {
      _invalidateDispatches();
      return;
    }
    _startPump();
  }

  Future<ChatCommandResult<ConversationCreationResult>> execute(
    Map<String, Object?> authored, {
    ChatCommandCancellationSignal? cancellationSignal,
  }) async {
    if (_closed) return const ChatCommandClosed<ConversationCreationResult>();
    if (cancellationSignal?.isCancelled == true) {
      return const ChatCommandAborted<ConversationCreationResult>();
    }
    final identity = _identity;
    final generation = _generation;
    final epoch = _epoch;
    if (identity == null) {
      return const ChatCommandValidationFailure<ConversationCreationResult>();
    }

    final stored = await _findOrPersist(
      identity,
      generation,
      epoch,
      authored,
    );
    if (stored == null) {
      return !_scopeActive(identity, generation, epoch)
          ? const ChatCommandClosed<ConversationCreationResult>()
          : const ChatCommandValidationFailure<ConversationCreationResult>();
    }
    if (!_scopeActive(identity, generation, epoch)) {
      return const ChatCommandClosed<ConversationCreationResult>();
    }
    if (cancellationSignal?.isCancelled == true && stored.wasInserted) {
      await _remove(identity, generation, epoch, stored.intent);
      return const ChatCommandAborted<ConversationCreationResult>();
    }

    final key = stored.intent.request.idempotencyKey;
    final future = _addWaiter(key);
    if (stored.wasInserted && cancellationSignal != null) {
      _callerCancellations[key] = cancellationSignal.onCancelled.listen((_) {
        final active = _active[key];
        if (active != null) {
          active.cancellation.cancel();
        } else {
          unawaited(_cancelBeforeDispatch(
            identity,
            generation,
            epoch,
            stored.intent,
          ));
        }
      });
    }
    _startPump();
    return future;
  }

  Future<void> settleCanonicalEvent(KnownDurableEvent event) async {
    if (_closed || event is! ConversationCreatedDurableEvent) return;
    final identity = _identity;
    final generation = _generation;
    final epoch = _epoch;
    if (identity == null || event.tenantId != identity.tenantId) return;
    final clientRequestId = event.payload.data['clientRequestId'];
    if (clientRequestId is! String) return;
    final intent = _intents.cast<ChatQueuedConversationCreation?>().firstWhere(
          (candidate) => candidate?.request.clientRequestId == clientRequestId,
          orElse: () => null,
        );
    if (intent == null) return;

    ChatCommandSuccess<ConversationCreationResult>? success;
    try {
      success = ChatCommandSuccess<ConversationCreationResult>(
        _resultFromCanonicalEvent(identity, intent.request, event),
      );
    } catch (_) {
      // The canonical reducer has still proved acknowledgement. Queue removal
      // must not depend on fabricating fields omitted by the durable event.
    }
    final removed = await _remove(identity, generation, epoch, intent);
    if (!removed || !_scopeActive(identity, generation, epoch)) return;
    final active = _active[intent.request.idempotencyKey];
    if (success != null) {
      if (active != null && !active.canonicalResult.isCompleted) {
        active.canonicalResult.complete(success);
        active.cancellation.cancel();
      }
      _complete(intent.request.idempotencyKey, success);
    }
    _startPump();
  }

  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    ++_epoch;
    _invalidateDispatches();
    _completeAll(const ChatCommandClosed<ConversationCreationResult>());
    await _storeSubscription.cancel();
  }

  Future<void> _cancelBeforeDispatch(
    ApplicationChatStorageIdentity identity,
    int generation,
    int epoch,
    ChatQueuedConversationCreation intent,
  ) async {
    if (_active.containsKey(intent.request.idempotencyKey)) return;
    await _remove(identity, generation, epoch, intent);
    if (_scopeActive(identity, generation, epoch)) {
      _complete(
        intent.request.idempotencyKey,
        const ChatCommandAborted<ConversationCreationResult>(),
      );
      _startPump();
    }
  }

  void _startPump() {
    if (!_ready || _pump != null || _intents.isEmpty) return;
    final identity = _identity;
    if (identity == null) return;
    final generation = _generation;
    final epoch = _epoch;
    late final Future<void> pump;
    pump = _drain(identity, generation, epoch).whenComplete(() {
      if (identical(_pump, pump)) _pump = null;
      if (_ready && _intents.isNotEmpty) _startPump();
    });
    _pump = pump;
    unawaited(pump);
  }

  Future<void> _drain(
    ApplicationChatStorageIdentity identity,
    int generation,
    int epoch,
  ) async {
    var retryNumber = 0;
    while (_ready && _scopeActive(identity, generation, epoch)) {
      if (_intents.isEmpty) return;
      final intent = _intents.first;
      final existing = _resultFromExistingState(identity, intent.request);
      if (existing != null) {
        final result = ChatCommandSuccess<ConversationCreationResult>(existing);
        final removed = await _remove(identity, generation, epoch, intent);
        if (removed && _scopeActive(identity, generation, epoch)) {
          _complete(intent.request.idempotencyKey, result);
        }
        retryNumber = 0;
        continue;
      }

      final result = await _dispatch(identity, generation, epoch, intent);
      if (!_scopeActive(identity, generation, epoch)) return;
      if (!_contains(intent)) {
        retryNumber = 0;
        continue;
      }
      if (!_isAmbiguous(result)) return;
      retryNumber += 1;
      if (!await _waitBeforeRetry(
        retryNumber,
        identity,
        generation,
        epoch,
      )) {
        return;
      }
    }
  }

  Future<ChatCommandResult<ConversationCreationResult>> _dispatch(
    ApplicationChatStorageIdentity identity,
    int generation,
    int epoch,
    ChatQueuedConversationCreation intent,
  ) async {
    final key = intent.request.idempotencyKey;
    final existing = _active[key];
    if (existing != null) return existing.result.future;
    if (!_scopeActive(identity, generation, epoch)) {
      return const ChatCommandClosed<ConversationCreationResult>();
    }
    final active = _ActiveConversationCreationDispatch();
    _active[key] = active;
    late ChatCommandResult<ConversationCreationResult> result;
    try {
      final dispatch = dispatcher.dispatch(
        _conversationCreationDescriptor(intent.request),
        intent.request,
        options: ChatCommandDispatchOptions(
          idempotencyKey: key,
          cancellationSignal: active.cancellation.signal,
        ),
      );
      result = await Future.any([dispatch, active.canonicalResult.future]);
      final canonicalEventSettled = active.canonicalResult.isCompleted;
      if (canonicalEventSettled) {
        active.cancellation.cancel();
        await dispatch;
      }
      if (!_scopeActive(identity, generation, epoch)) {
        result = const ChatCommandClosed<ConversationCreationResult>();
      } else {
        if (!canonicalEventSettled &&
            result is ChatCommandSuccess<ConversationCreationResult>) {
          try {
            store.reconcileConversationCreation(result.value);
          } catch (_) {
            result = const ChatCommandMalformedResponse<
                ConversationCreationResult>();
          }
        }
        await _settleResult(identity, generation, epoch, intent, result);
      }
    } finally {
      if (identical(_active[key], active)) _active.remove(key);
    }
    if (!active.result.isCompleted) active.result.complete(result);
    _complete(key, result);
    return result;
  }

  Future<bool> _settleResult(
    ApplicationChatStorageIdentity identity,
    int generation,
    int epoch,
    ChatQueuedConversationCreation intent,
    ChatCommandResult<ConversationCreationResult> result,
  ) async {
    if (result is ChatCommandSuccess<ConversationCreationResult>) {
      return _remove(identity, generation, epoch, intent);
    }
    if (_isTerminal(result)) {
      return _remove(identity, generation, epoch, intent);
    }
    return false;
  }

  Future<_StoredConversationCreation?> _findOrPersist(
    ApplicationChatStorageIdentity identity,
    int generation,
    int epoch,
    Map<String, Object?> authored,
  ) =>
      _serialized(() async {
        if (!_scopeActive(identity, generation, epoch)) return null;
        try {
          final semanticProbe = ConversationCreationInput.fromJson({
            ...authored,
            'idempotencyKey': _conversationCreationValidationIdentity,
            'clientRequestId': _conversationCreationValidationIdentity,
          });
          ConversationCreationInput? candidate;
          IsoTimestamp? enqueuedAt;
          var wasInserted = false;
          final committed = await _mutateRecord(identity, (current) {
            wasInserted = false;
            if (!_scopeActive(identity, generation, epoch)) return current;
            // Recheck the logical key on every attempt: a competing runtime
            // may have committed an equivalent request with its own correlation.
            if (current?.intents.any((intent) =>
                    _sameCreationSemantics(intent.request, semanticProbe)) ??
                false) {
              return current;
            }
            // Keep one correlation pair and timestamp across retries, but
            // allocate FIFO order against each attempt's current tail.
            candidate ??= ConversationCreationInput.fromJson({
              ...authored,
              'idempotencyKey': generateIdempotencyKey(),
              'clientRequestId': generateClientRequestId(),
            });
            enqueuedAt ??= IsoTimestamp(clock().toUtc().toIso8601String());
            final highest = current?.intents.fold<int>(
                  0,
                  (value, intent) => max(value, intent.enqueueOrder),
                ) ??
                0;
            wasInserted = true;
            return ApplicationChatQueuedConversationCreationIntentsRecord(
              identity: identity,
              intents: [
                ...?current?.intents,
                ApplicationChatQueuedConversationCreationIntent(
                  request: candidate!,
                  enqueueOrder: highest + 1,
                  enqueuedAt: enqueuedAt!,
                ),
              ],
            );
          });
          if (!_scopeActive(identity, generation, epoch)) return null;
          _publish(committed);
          final winner = _intents
              .where((intent) =>
                  _sameCreationSemantics(intent.request, semanticProbe))
              .firstOrNull;
          if (winner == null) return null;
          return _StoredConversationCreation(winner, wasInserted: wasInserted);
        } catch (_) {
          if (_scopeActive(identity, generation, epoch)) {
            onStorageDiagnostic(
              ChatClientDiagnosticCode.conversationCreationIntentsWriteFailed,
              'The conversation-creation command could not be stored before dispatch.',
            );
          }
          return null;
        }
      });

  Future<bool> _remove(
    ApplicationChatStorageIdentity identity,
    int generation,
    int epoch,
    ChatQueuedConversationCreation intent,
  ) =>
      _serialized(() async {
        if (!_scopeActive(identity, generation, epoch)) return false;
        try {
          final committed = await _mutateRecord(identity, (current) {
            if (!_scopeActive(identity, generation, epoch) || current == null) {
              return current;
            }
            final remaining = current.intents
                .where((candidate) => !_sameStored(candidate, intent))
                .toList(growable: false);
            if (remaining.length == current.intents.length) return current;
            return remaining.isEmpty
                ? null
                : ApplicationChatQueuedConversationCreationIntentsRecord(
                    identity: identity,
                    intents: remaining,
                  );
          });
          if (!_scopeActive(identity, generation, epoch)) return false;
          _publish(committed);
          // A replacement sharing a correlation is still pending; an old
          // completion must not acknowledge that replacement.
          return !(committed?.intents.any((candidate) =>
                  candidate.request.idempotencyKey ==
                      intent.request.idempotencyKey ||
                  candidate.request.clientRequestId ==
                      intent.request.clientRequestId) ??
              false);
        } catch (_) {
          if (_scopeActive(identity, generation, epoch)) {
            onStorageDiagnostic(
              ChatClientDiagnosticCode.conversationCreationIntentsWriteFailed,
              'A settled conversation-creation command could not be removed from storage.',
            );
          }
          return false;
        }
      });

  Future<ApplicationChatQueuedConversationCreationIntentsRecord?> _readRecord(
    ApplicationChatStorageIdentity identity,
  ) =>
      _mutateRecord(identity, (current) => current);

  Future<ApplicationChatQueuedConversationCreationIntentsRecord?> _mutateRecord(
    ApplicationChatStorageIdentity identity,
    ApplicationChatStorageUpdater<
            ApplicationChatQueuedConversationCreationIntentsRecord>
        updater,
  ) =>
      ApplicationChatStorageMutator(storage)
          .mutate<ApplicationChatQueuedConversationCreationIntentsRecord>(
        identity,
        ApplicationChatStorageRecordKind.queuedConversationCreationIntents,
        updater,
      );

  void _publish(
      ApplicationChatQueuedConversationCreationIntentsRecord? record) {
    final identity = _identity;
    if (identity == null) return;
    _intents
      ..clear()
      ..addAll([
        for (final intent in record?.intents ??
            const <ApplicationChatQueuedConversationCreationIntent>[])
          _visible(intent, identity),
      ]);
  }

  ChatQueuedConversationCreation _visible(
    ApplicationChatQueuedConversationCreationIntent intent,
    ApplicationChatStorageIdentity identity,
  ) =>
      ChatQueuedConversationCreation._(
        identity: identity,
        request: intent.request,
        enqueueOrder: intent.enqueueOrder,
        enqueuedAt: DateTime.parse(intent.enqueuedAt.value).toUtc(),
      );

  ConversationCreationResult? _resultFromExistingState(
    ApplicationChatStorageIdentity identity,
    ConversationCreationInput request,
  ) {
    if (request is! ParticipantConversationCreationInput) return null;
    final expected = <UserId>{
      identity.userId,
      ...request.intendedMemberUserIds
    };
    for (final entry in store.state.conversations.entries) {
      final conversation = entry.value;
      final expectedType = request.type == ConversationCreationType.direct
          ? ConversationType.direct
          : ConversationType.groupDirect;
      if (conversation.tenantId != identity.tenantId ||
          conversation.type != expectedType) {
        continue;
      }
      final members = store.state.memberUserIdsByConversation[entry.key];
      if (members == null ||
          members.toSet().length != expected.length ||
          !members.toSet().containsAll(expected)) {
        continue;
      }
      final detail = _detailFromState(identity, entry.key);
      if (detail == null) continue;
      return ConversationCreationResult.fromJson({
        'operation': 'create_conversation',
        'type': request.type.toJson(),
        'reconciliationStatus': 'existing_equivalent',
        'clientRequestId': request.clientRequestId,
        'conversation': detail.toJson(),
        'participantIdentity': deriveCanonicalParticipantIdentity(
          identity.userId,
          request.intendedMemberUserIds,
        ).toJson(),
      }, expectedInput: request);
    }
    return null;
  }

  ConversationDetailSnapshot? _detailFromState(
    ApplicationChatStorageIdentity identity,
    ConversationId conversationId,
  ) {
    final state = store.state;
    final conversation = state.conversations[conversationId];
    final metadata = state.conversationMetadata[conversationId];
    final snapshotMetadata = state.conversationDetails[conversationId];
    final currentMember =
        state.membersByConversation[conversationId]?[identity.userId];
    final currentRead = state.currentUserReadStates[conversationId];
    final currentPreference = state.currentUserPreferences[conversationId];
    if (conversation == null ||
        metadata == null ||
        snapshotMetadata == null ||
        currentMember == null ||
        currentRead == null ||
        currentPreference == null) {
      return null;
    }
    final memberIds =
        state.memberUserIdsByConversation[conversationId] ?? const [];
    return ConversationDetailSnapshot(
      conversation: ConversationDetailSnapshotConversation(
        summary: ConversationSnapshotSummary(
          conversation: conversation,
          latestSequence: metadata.latestSequence,
          activityAt: metadata.activityAt,
          unreadMentionCount: 0,
          currentMember: currentMember,
          currentReadState: currentRead,
          currentPreference: currentPreference,
          activeMemberUserIds: memberIds,
        ),
        memberUserIds: memberIds,
        memberListRevision: state.memberListRevisions[conversationId],
        currentPreference: currentPreference,
      ),
      metadata: snapshotMetadata,
    );
  }

  ConversationCreationResult _resultFromCanonicalEvent(
    ApplicationChatStorageIdentity identity,
    ConversationCreationInput request,
    ConversationCreatedDurableEvent event,
  ) {
    final conversation =
        Conversation.fromJson(event.payload.data['conversation']);
    final existing = _detailFromState(identity, conversation.id);
    final timestamp = conversation.updatedAt.toJson();
    final memberIds = request is ParticipantConversationCreationInput
        ? <UserId>{identity.userId, ...request.intendedMemberUserIds}.toList()
        : <UserId>[identity.userId];
    final detail = existing ??
        ConversationDetailSnapshot.fromJson({
          'kind': 'conversation_detail',
          'conversation': {
            ...conversation.toJson(),
            'latestSequence': 0,
            'activityAt': timestamp,
            'unreadMentionCount': 0,
            'currentMember': {
              'tenantId': identity.tenantId.toJson(),
              'conversationId': conversation.id.toJson(),
              'userId': identity.userId.toJson(),
              'role': 'owner',
              'state': 'active',
              'joinedAt': timestamp,
              'updatedAt': timestamp,
            },
            'currentReadState': {
              'conversationId': conversation.id.toJson(),
              'userId': identity.userId.toJson(),
              'lastReadSequence': 0,
              'updatedAt': timestamp,
            },
            'currentPreference': {
              'conversationId': conversation.id.toJson(),
              'userId': identity.userId.toJson(),
              'isStarred': false,
              'notificationPreference': 'all',
              'mute': {'muted': false},
              'updatedAt': timestamp,
            },
            'activeMemberUserIds': memberIds.map((id) => id.toJson()).toList(),
            'memberUserIds': memberIds.map((id) => id.toJson()).toList(),
          },
          '_meta': {
            'packageVersion': 'durable-event',
            'protocolVersion': handrailChatProtocolVersion,
            'schemaVersion': 1,
            'enabledFeatures': {'conversation_creation': true},
            'supportedProtocolRange': {
              'minimumVersion': handrailChatProtocolVersion,
              'maximumVersion': handrailChatProtocolVersion,
            },
            'feature': {
              'name': conversationSnapshotFeature,
              'version': conversationSnapshotVersion,
            },
          },
        });
    return ConversationCreationResult.fromJson({
      'operation': 'create_conversation',
      'type': request.type.toJson(),
      'reconciliationStatus': 'replayed',
      'clientRequestId': request.clientRequestId,
      'conversation': detail.toJson(),
      if (request is ParticipantConversationCreationInput)
        'participantIdentity': deriveCanonicalParticipantIdentity(
          identity.userId,
          request.intendedMemberUserIds,
        ).toJson(),
    }, expectedInput: request);
  }

  Future<bool> _waitBeforeRetry(
    int retryNumber,
    ApplicationChatStorageIdentity identity,
    int generation,
    int epoch,
  ) async {
    late final Duration delay;
    try {
      delay = backoff(retryNumber);
      if (delay.isNegative || delay > const Duration(seconds: 60)) return false;
    } catch (_) {
      return false;
    }
    final cancellation = ChatCommandCancellationController();
    _retryWait = cancellation;
    if (!_ready || !_scopeActive(identity, generation, epoch)) {
      cancellation.cancel();
      return false;
    }
    try {
      await _raceConversationCreationWait(
        Future<void>.sync(() => wait(delay, cancellation.signal)),
        cancellation.signal,
      );
      return _ready && _scopeActive(identity, generation, epoch);
    } catch (_) {
      return false;
    } finally {
      if (identical(_retryWait, cancellation)) _retryWait = null;
    }
  }

  Future<T> _serialized<T>(Future<T> Function() operation) {
    final completer = Completer<T>();
    _storageMutation = _storageMutation.then((_) async {
      try {
        completer.complete(await operation());
      } catch (error, stackTrace) {
        completer.completeError(error, stackTrace);
      }
    });
    return completer.future;
  }

  Future<ChatCommandResult<ConversationCreationResult>> _addWaiter(String key) {
    final completer =
        Completer<ChatCommandResult<ConversationCreationResult>>();
    (_waiters[key] ??= []).add(completer);
    return completer.future;
  }

  void _complete(
    String key,
    ChatCommandResult<ConversationCreationResult> result,
  ) {
    final waiters = _waiters.remove(key);
    if (waiters != null) {
      for (final waiter in waiters) {
        if (!waiter.isCompleted) waiter.complete(result);
      }
    }
    unawaited(_callerCancellations.remove(key)?.cancel());
  }

  void _completeAll(ChatCommandResult<ConversationCreationResult> result) {
    for (final key in _waiters.keys.toList(growable: false)) {
      _complete(key, result);
    }
  }

  void _invalidateDispatches() {
    _retryWait?.cancel();
    _retryWait = null;
    for (final active in _active.values) {
      active.cancellation.cancel();
    }
    _active.clear();
    _pump = null;
  }

  bool _contains(ChatQueuedConversationCreation intent) =>
      _intents.any((candidate) => _sameVisible(candidate, intent));

  static bool _sameStored(
    ApplicationChatQueuedConversationCreationIntent stored,
    ChatQueuedConversationCreation visible,
  ) =>
      stored.enqueueOrder == visible.enqueueOrder &&
      DateTime.parse(stored.enqueuedAt.value).toUtc() == visible.enqueuedAt &&
      _sameRequest(stored.request, visible.request);

  static bool _sameVisible(
    ChatQueuedConversationCreation left,
    ChatQueuedConversationCreation right,
  ) =>
      left.enqueueOrder == right.enqueueOrder &&
      left.enqueuedAt == right.enqueuedAt &&
      _sameRequest(left.request, right.request);

  static bool _sameRequest(
    ConversationCreationInput left,
    ConversationCreationInput right,
  ) =>
      jsonEncode(left.toJson()) == jsonEncode(right.toJson());

  static bool _sameCreationSemantics(
    ConversationCreationInput left,
    ConversationCreationInput right,
  ) =>
      _conversationCreationLogicalKey(left) ==
      _conversationCreationLogicalKey(right);

  static bool _isTerminal(
    ChatCommandResult<ConversationCreationResult> result,
  ) =>
      result is ChatCommandValidationFailure<ConversationCreationResult> ||
      result is ChatCommandAuthenticationFailure<ConversationCreationResult> ||
      result is ChatCommandConflict<ConversationCreationResult> ||
      result is ChatCommandFeatureDisabled<ConversationCreationResult> ||
      result is ChatCommandUnsupported<ConversationCreationResult> ||
      result is ChatCommandRejected<ConversationCreationResult>;

  static bool _isAmbiguous(
    ChatCommandResult<ConversationCreationResult> result,
  ) =>
      result is ChatCommandTransportFailure<ConversationCreationResult> ||
      result is ChatCommandMalformedResponse<ConversationCreationResult> ||
      result is ChatCommandAborted<ConversationCreationResult> ||
      result is ChatCommandClosed<ConversationCreationResult>;
}

ChatCommandDescriptor<ConversationCreationInput, ConversationCreationInput,
    ConversationCreationResult> _conversationCreationDescriptor(
  ConversationCreationInput request,
) =>
    ChatCommandDescriptor(
      name: 'conversation.create',
      method: ChatCommandMethod.post,
      path: '/conversations',
      retrySafety: ChatCommandRetrySafety.safe,
      validateInput: (input) => ConversationCreationInput.fromJson(
        input.toJson(),
      ),
      parseResult: (json) => ConversationCreationResult.fromJson(
        json,
        expectedInput: request,
      ),
    );

final class _StoredConversationCreation {
  const _StoredConversationCreation(this.intent, {required this.wasInserted});

  final ChatQueuedConversationCreation intent;
  final bool wasInserted;
}

final class _ActiveConversationCreationDispatch {
  final ChatCommandCancellationController cancellation =
      ChatCommandCancellationController();
  final Completer<ChatCommandResult<ConversationCreationResult>>
      canonicalResult = Completer();
  final Completer<ChatCommandResult<ConversationCreationResult>> result =
      Completer();
}

Duration _defaultConversationCreationRetryBackoff(int retryNumber) {
  final exponent = retryNumber <= 1 ? 0 : (retryNumber - 1).clamp(0, 5);
  return Duration(seconds: 1 << exponent);
}

Future<void> _defaultConversationCreationRetryWait(
  Duration delay,
  ChatCommandCancellationSignal _,
) =>
    Future<void>.delayed(delay);

Future<void> _raceConversationCreationWait(
  Future<void> future,
  ChatCommandCancellationSignal signal,
) {
  if (signal.isCancelled) {
    return Future<void>.error(const _ConversationCreationWaitInterrupted());
  }
  final completer = Completer<void>();
  late final StreamSubscription<void> subscription;
  subscription = signal.onCancelled.listen((_) {
    if (!completer.isCompleted) {
      completer.completeError(const _ConversationCreationWaitInterrupted());
    }
  });
  future.then(
    (_) {
      if (!completer.isCompleted) completer.complete();
    },
    onError: (Object error, StackTrace stackTrace) {
      if (!completer.isCompleted) completer.completeError(error, stackTrace);
    },
  ).whenComplete(subscription.cancel);
  return completer.future;
}

final class _ConversationCreationWaitInterrupted implements Exception {
  const _ConversationCreationWaitInterrupted();
}
