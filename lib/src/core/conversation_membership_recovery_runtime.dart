part of '../handrail_chat_client.dart';

/// Injectable wall clock used for durable membership FIFO metadata.
typedef ChatConversationMembershipClock = DateTime Function();

/// Computes the delay before replaying an ambiguous retained membership command.
typedef ChatConversationMembershipRetryBackoff = Duration Function(
  int retryNumber,
);

/// Injectable wait boundary for deterministic retained-membership tests.
typedef ChatConversationMembershipRetryWait = Future<void> Function(
  Duration delay,
  ChatCommandCancellationSignal cancellationSignal,
);

enum _ConversationMembershipAuthorityRefreshResult {
  ready,
  retry,
  terminal,
}

typedef _ConversationMembershipAuthorityRefresher
    = Future<_ConversationMembershipAuthorityRefreshResult> Function(
  ConversationMembershipMutationInput request,
  ChatCommandCancellationSignal cancellationSignal,
);

/// A credential-free view of one identity-scoped retained membership command.
final class ChatQueuedConversationMembership {
  const ChatQueuedConversationMembership._({
    required this.identity,
    required this.request,
    required this.enqueueOrder,
    required this.enqueuedAt,
  });

  final ApplicationChatStorageIdentity identity;
  final ConversationMembershipMutationInput request;
  final int enqueueOrder;
  final DateTime enqueuedAt;
}

final class _ConversationMembershipRecoveryRuntime {
  _ConversationMembershipRecoveryRuntime({
    required this.storage,
    required this.dispatcher,
    required this.store,
    required this.refreshAuthority,
    required this.clearConversationSubscription,
    required this.clock,
    required this.backoff,
    required this.wait,
    required this.lifecycleManaged,
    required this.onStorageDiagnostic,
  }) {
    _storeSubscription = store.acceptedCommitChanges.listen((_) {
      _startPumps();
    });
  }

  final ApplicationChatStorage storage;
  final ChatCommandDispatcher dispatcher;
  final NormalizedSnapshotStore store;
  final _ConversationMembershipAuthorityRefresher refreshAuthority;
  final void Function(ConversationId conversationId)?
      clearConversationSubscription;
  final ChatConversationMembershipClock clock;
  final ChatConversationMembershipRetryBackoff backoff;
  final ChatConversationMembershipRetryWait wait;
  final bool lifecycleManaged;
  final void Function(String code, String message) onStorageDiagnostic;

  final List<ChatQueuedConversationMembership> _intents = [];
  final Map<String, _ActiveConversationMembershipDispatch> _active = {};
  final Map<
          String,
          List<
              Completer<
                  ChatCommandResult<ConversationMembershipMutationResult>>>>
      _waiters = {};
  final Map<String, StreamSubscription<void>> _callerCancellations = {};
  final Map<ConversationId, Future<void>> _lanePumps = {};
  final Map<ConversationId, ChatCommandCancellationController> _retryWaits = {};
  late final StreamSubscription<NormalizedSnapshotState> _storeSubscription;
  Future<void> _storageMutation = Future<void>.value();
  ApplicationChatStorageIdentity? _identity;
  int _generation = 0;
  int _epoch = 0;
  bool _metadataReady = false;
  bool _connectivityOnline = false;
  bool _realtimeConnected = false;
  bool _applicationForeground = true;
  bool _closed = false;

  List<ChatQueuedConversationMembership> get intents =>
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
    _completeAll(
        const ChatCommandClosed<ConversationMembershipMutationResult>());
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
      ApplicationChatQueuedConversationMembershipIntentsRecord? record;
      try {
        record = await _readRecord(identity);
        if (!_scopeActive(identity, generation, epoch)) return;
      } on FormatException {
        if (!_scopeActive(identity, generation, epoch)) return;
        onStorageDiagnostic(
          ChatClientDiagnosticCode.membershipIntentsRejected,
          'The stored conversation-membership intents were rejected and quarantined.',
        );
        return;
      } catch (_) {
        if (_scopeActive(identity, generation, epoch)) {
          onStorageDiagnostic(
            ChatClientDiagnosticCode.membershipIntentsReadFailed,
            'The stored conversation-membership intents could not be read.',
          );
        }
        return;
      }
      if (_scopeActive(identity, generation, epoch)) _publish(record);
    });
    if (_scopeActive(identity, generation, epoch)) _startPumps();
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
    _startPumps();
  }

  Future<ChatCommandResult<ConversationMembershipMutationResult>> execute(
    ConversationMembershipMutationInput request, {
    ChatCommandCancellationSignal? cancellationSignal,
  }) async {
    if (_closed) {
      return const ChatCommandClosed<ConversationMembershipMutationResult>();
    }
    if (cancellationSignal?.isCancelled == true) {
      return const ChatCommandAborted<ConversationMembershipMutationResult>();
    }
    final identity = _identity;
    final generation = _generation;
    final epoch = _epoch;
    if (identity == null) {
      return const ChatCommandValidationFailure<
          ConversationMembershipMutationResult>();
    }

    final persisted = await _persist(identity, generation, epoch, request);
    final stored = persisted?.intent;
    if (stored == null) {
      return !_scopeActive(identity, generation, epoch)
          ? const ChatCommandClosed<ConversationMembershipMutationResult>()
          : const ChatCommandValidationFailure<
              ConversationMembershipMutationResult>();
    }
    if (!_scopeActive(identity, generation, epoch)) {
      return const ChatCommandClosed<ConversationMembershipMutationResult>();
    }
    if (persisted!.coalesced) {
      final future = _addWaiter(stored.request.idempotencyKey);
      _startLane(stored.request.conversationId);
      return future;
    }
    if (cancellationSignal?.isCancelled == true) {
      await _remove(identity, generation, epoch, stored);
      return const ChatCommandAborted<ConversationMembershipMutationResult>();
    }

    final key = stored.request.idempotencyKey;
    final future = _addWaiter(key);
    if (cancellationSignal != null) {
      _callerCancellations[key] = cancellationSignal.onCancelled.listen((_) {
        final active = _active[key];
        if (active != null) {
          active.cancellation.cancel();
        } else {
          unawaited(_cancelBeforeDispatch(
            identity,
            generation,
            epoch,
            stored,
          ));
        }
      });
    }
    _startLane(stored.request.conversationId);
    return future;
  }

  Future<void> settleCanonicalEvent(KnownDurableEvent event) async {
    if (_closed || event is! MembershipUpdatedDurableEvent) return;
    final identity = _identity;
    final generation = _generation;
    final epoch = _epoch;
    if (identity == null || event.tenantId != identity.tenantId) return;

    late final ConversationMembershipMutationInput input;
    late final ConversationMembershipMutationResult value;
    late final ChatQueuedConversationMembership intent;
    try {
      input = ConversationMembershipMutationInput.fromJson(
        event.payload.data['input'],
      );
      intent = _intents.firstWhere(
        (candidate) => _sameRequest(candidate.request, input),
      );
      value = ConversationMembershipMutationResult.fromJson(
        event.payload.data['result'],
        expectedInput: intent.request,
      );
    } catch (_) {
      return;
    }
    if (!_scopeActive(identity, generation, epoch)) return;
    final result = ChatCommandSuccess<ConversationMembershipMutationResult>(
      value,
    );
    final settled = await _settleResult(
      identity,
      generation,
      epoch,
      intent,
      result,
    );
    if (!settled || !_scopeActive(identity, generation, epoch)) return;
    final active = _active[intent.request.idempotencyKey];
    if (active != null && !active.canonicalResult.isCompleted) {
      active.canonicalResult.complete(result);
      active.cancellation.cancel();
    }
    _complete(intent.request.idempotencyKey, result);
    _startLane(intent.request.conversationId);
  }

  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    ++_epoch;
    _invalidateDispatches();
    _completeAll(
        const ChatCommandClosed<ConversationMembershipMutationResult>());
    await _storeSubscription.cancel();
  }

  Future<void> _cancelBeforeDispatch(
    ApplicationChatStorageIdentity identity,
    int generation,
    int epoch,
    ChatQueuedConversationMembership intent,
  ) async {
    if (_active.containsKey(intent.request.idempotencyKey)) return;
    await _remove(identity, generation, epoch, intent);
    if (_scopeActive(identity, generation, epoch)) {
      _complete(
        intent.request.idempotencyKey,
        const ChatCommandAborted<ConversationMembershipMutationResult>(),
      );
      _startLane(intent.request.conversationId);
    }
  }

  void _startPumps() {
    if (!_ready) return;
    final conversations = <ConversationId>{};
    for (final intent in _intents) {
      if (conversations.add(intent.request.conversationId)) {
        _startLane(intent.request.conversationId);
      }
    }
  }

  void _startLane(ConversationId conversationId) {
    if (!_ready || _lanePumps.containsKey(conversationId)) return;
    final identity = _identity;
    if (identity == null || _head(conversationId) == null) return;
    final generation = _generation;
    final epoch = _epoch;
    late final Future<void> pump;
    pump = _drainLane(identity, generation, epoch, conversationId)
        .whenComplete(() {
      if (identical(_lanePumps[conversationId], pump)) {
        _lanePumps.remove(conversationId);
      }
      if (_ready && _head(conversationId) != null) {
        _startLane(conversationId);
      }
    });
    _lanePumps[conversationId] = pump;
    unawaited(pump);
  }

  Future<void> _drainLane(
    ApplicationChatStorageIdentity identity,
    int generation,
    int epoch,
    ConversationId conversationId,
  ) async {
    var retryNumber = 0;
    while (_ready && _scopeActive(identity, generation, epoch)) {
      final intent = _head(conversationId);
      if (intent == null) return;

      if (!_authorityReady(intent.request)) {
        final cancellation = ChatCommandCancellationController();
        final outcome = await refreshAuthority(
          intent.request,
          cancellation.signal,
        ).catchError(
          (_) => _ConversationMembershipAuthorityRefreshResult.retry,
        );
        if (!_scopeActive(identity, generation, epoch) || !_ready) return;
        if (outcome == _ConversationMembershipAuthorityRefreshResult.terminal) {
          await _remove(identity, generation, epoch, intent);
          _complete(
            intent.request.idempotencyKey,
            const ChatCommandRejected<ConversationMembershipMutationResult>(
              httpStatus: 403,
            ),
          );
          retryNumber = 0;
          continue;
        }
        if (outcome != _ConversationMembershipAuthorityRefreshResult.ready ||
            !_authorityReady(intent.request)) {
          retryNumber += 1;
          if (!await _waitBeforeRetry(
            conversationId,
            retryNumber,
            identity,
            generation,
            epoch,
          )) {
            return;
          }
          continue;
        }
      }

      if (!_waiters.containsKey(intent.request.idempotencyKey) &&
          _stateConverges(identity, intent.request)) {
        await _remove(identity, generation, epoch, intent);
        retryNumber = 0;
        continue;
      }

      final result = await _dispatch(
        identity,
        generation,
        epoch,
        intent,
      );
      if (!_scopeActive(identity, generation, epoch)) return;
      if (!_contains(intent)) {
        retryNumber = 0;
        continue;
      }
      if (!_isAmbiguous(result)) return;
      retryNumber += 1;
      if (!await _waitBeforeRetry(
        conversationId,
        retryNumber,
        identity,
        generation,
        epoch,
      )) {
        return;
      }
    }
  }

  Future<ChatCommandResult<ConversationMembershipMutationResult>> _dispatch(
    ApplicationChatStorageIdentity identity,
    int generation,
    int epoch,
    ChatQueuedConversationMembership intent,
  ) async {
    final key = intent.request.idempotencyKey;
    final existing = _active[key];
    if (existing != null) return existing.result.future;
    if (!_scopeActive(identity, generation, epoch)) {
      return const ChatCommandClosed<ConversationMembershipMutationResult>();
    }
    final active = _ActiveConversationMembershipDispatch();
    _active[key] = active;
    late ChatCommandResult<ConversationMembershipMutationResult> result;
    try {
      final dispatch = dispatcher.dispatch(
        _membershipDescriptor(intent.request),
        intent.request,
        options: ChatCommandDispatchOptions(
          idempotencyKey: key,
          cancellationSignal: active.cancellation.signal,
        ),
      );
      result = await Future.any([
        dispatch,
        active.canonicalResult.future,
      ]);
      if (active.canonicalResult.isCompleted) {
        active.cancellation.cancel();
        await dispatch;
      }
      if (!_scopeActive(identity, generation, epoch)) {
        result =
            const ChatCommandClosed<ConversationMembershipMutationResult>();
      } else {
        await _settleResult(
          identity,
          generation,
          epoch,
          intent,
          result,
        );
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
    ChatQueuedConversationMembership intent,
    ChatCommandResult<ConversationMembershipMutationResult> result,
  ) async {
    if (result
        case ChatCommandSuccess<ConversationMembershipMutationResult>(
          :final value,
        )) {
      if (_successIsTerminal(value)) {
        final cancellation = ChatCommandCancellationController();
        await refreshAuthority(intent.request, cancellation.signal).catchError(
            (_) => _ConversationMembershipAuthorityRefreshResult.retry);
        return _remove(identity, generation, epoch, intent);
      }
      try {
        final accessRevoked = store.reconcileConversationMembership(value);
        if (accessRevoked) {
          clearConversationSubscription?.call(value.conversationId);
        }
      } catch (_) {
        return false;
      }
      return _remove(identity, generation, epoch, intent);
    }
    if (_isTerminal(result)) {
      final cancellation = ChatCommandCancellationController();
      await refreshAuthority(intent.request, cancellation.signal).catchError(
          (_) => _ConversationMembershipAuthorityRefreshResult.retry);
      return _remove(identity, generation, epoch, intent);
    }
    return false;
  }

  Future<({ChatQueuedConversationMembership intent, bool coalesced})?> _persist(
    ApplicationChatStorageIdentity identity,
    int generation,
    int epoch,
    ConversationMembershipMutationInput request,
  ) =>
      _serialized(() async {
        if (!_scopeActive(identity, generation, epoch)) return null;
        try {
          ApplicationChatQueuedConversationMembershipIntent? selected;
          var coalesced = false;
          final committed = await _mutateRecord(identity, (current) {
            // Failed proposals must not retain a selection or FIFO order.
            selected = null;
            coalesced = false;
            if (!_scopeActive(identity, generation, epoch)) return current;
            for (final intent in current?.intents ??
                const <ApplicationChatQueuedConversationMembershipIntent>[]) {
              if (_sameMembershipSemantics(intent.request, request)) {
                selected = intent;
                coalesced = true;
                return current;
              }
            }
            // Distinct commands may share a conversation lane. Append them
            // after every intent in this retry's current record.
            final highest = current?.intents.fold<int>(
                  0,
                  (value, intent) => max(value, intent.enqueueOrder),
                ) ??
                0;
            final intent = ApplicationChatQueuedConversationMembershipIntent(
              request: request,
              enqueueOrder: highest + 1,
              enqueuedAt: IsoTimestamp(clock().toUtc().toIso8601String()),
            );
            selected = intent;
            return ApplicationChatQueuedConversationMembershipIntentsRecord(
              identity: identity,
              intents: [...?current?.intents, intent],
            );
          });
          if (!_scopeActive(identity, generation, epoch)) return null;
          _publish(committed);
          final stored = selected;
          if (stored == null) return null;
          for (final intent in _intents) {
            if (_sameStored(stored, intent)) {
              return (intent: intent, coalesced: coalesced);
            }
          }
          return null;
        } catch (_) {
          if (_scopeActive(identity, generation, epoch)) {
            onStorageDiagnostic(
              ChatClientDiagnosticCode.membershipIntentsWriteFailed,
              'The conversation-membership command could not be stored before dispatch.',
            );
          }
          return null;
        }
      });

  Future<bool> _remove(
    ApplicationChatStorageIdentity identity,
    int generation,
    int epoch,
    ChatQueuedConversationMembership intent,
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
                : ApplicationChatQueuedConversationMembershipIntentsRecord(
                    identity: identity,
                    intents: remaining,
                  );
          });
          if (!_scopeActive(identity, generation, epoch)) return false;
          _publish(committed);
          // Absence is settled; a reused correlation with changed request or
          // enqueue metadata belongs to a replacement and must remain pending.
          return !(committed?.intents.any(
                (candidate) =>
                    candidate.request.idempotencyKey ==
                    intent.request.idempotencyKey,
              ) ??
              false);
        } catch (_) {
          if (_scopeActive(identity, generation, epoch)) {
            onStorageDiagnostic(
              ChatClientDiagnosticCode.membershipIntentsWriteFailed,
              'A settled conversation-membership command could not be removed from storage.',
            );
          }
          return false;
        }
      });

  Future<ApplicationChatQueuedConversationMembershipIntentsRecord?> _readRecord(
    ApplicationChatStorageIdentity identity,
  ) =>
      _mutateRecord(identity, (current) => current);

  Future<ApplicationChatQueuedConversationMembershipIntentsRecord?>
      _mutateRecord(
    ApplicationChatStorageIdentity identity,
    ApplicationChatStorageUpdater<
            ApplicationChatQueuedConversationMembershipIntentsRecord>
        updater,
  ) =>
          ApplicationChatStorageMutator(storage)
              .mutate<ApplicationChatQueuedConversationMembershipIntentsRecord>(
            identity,
            ApplicationChatStorageRecordKind
                .queuedConversationMembershipIntents,
            updater,
          );

  void _publish(
    ApplicationChatQueuedConversationMembershipIntentsRecord? record,
  ) {
    final identity = _identity;
    if (identity == null) return;
    _intents
      ..clear()
      ..addAll([
        for (final intent in record?.intents ??
            const <ApplicationChatQueuedConversationMembershipIntent>[])
          ChatQueuedConversationMembership._(
            identity: identity,
            request: intent.request,
            enqueueOrder: intent.enqueueOrder,
            enqueuedAt: DateTime.parse(intent.enqueuedAt.value).toUtc(),
          ),
      ]);
  }

  bool _authorityReady(ConversationMembershipMutationInput request) {
    final snapshot = store.conversation(request.conversationId);
    return snapshot.conversation != null &&
        (snapshot.memberListRevision ?? -1) >=
            request.expectedMemberListRevision;
  }

  bool _stateConverges(
    ApplicationChatStorageIdentity identity,
    ConversationMembershipMutationInput request,
  ) {
    if (!_authorityReady(request)) return false;
    final state = store.state;
    final ids = state.memberUserIdsByConversation[request.conversationId];
    final members = state.membersByConversation[request.conversationId];
    return switch (request.intent) {
      ConversationMembershipMutationIntent.join =>
        ids?.contains(identity.userId) == true ||
            members?[identity.userId]?.state == 'active',
      ConversationMembershipMutationIntent.leave =>
        ids != null && !ids.contains(identity.userId),
      ConversationMembershipMutationIntent.removeMember =>
        ids != null && !ids.contains(request.targetUserId),
      ConversationMembershipMutationIntent.addMember ||
      ConversationMembershipMutationIntent.changeMemberRole =>
        members?[request.targetUserId]?.state == 'active' &&
            members?[request.targetUserId]?.role ==
                request.requestedRole?.toJson(),
    };
  }

  Future<bool> _waitBeforeRetry(
    ConversationId conversationId,
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
    _retryWaits[conversationId] = cancellation;
    if (!_ready || !_scopeActive(identity, generation, epoch)) {
      cancellation.cancel();
      return false;
    }
    try {
      await _raceConversationMembershipWait(
        Future<void>.sync(() => wait(delay, cancellation.signal)),
        cancellation.signal,
      );
      return _ready && _scopeActive(identity, generation, epoch);
    } catch (_) {
      return false;
    } finally {
      if (identical(_retryWaits[conversationId], cancellation)) {
        _retryWaits.remove(conversationId);
      }
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

  ChatQueuedConversationMembership? _head(ConversationId conversationId) {
    for (final intent in _intents) {
      if (intent.request.conversationId == conversationId) return intent;
    }
    return null;
  }

  bool _contains(ChatQueuedConversationMembership intent) =>
      _intents.any((candidate) => _sameIntent(candidate, intent));

  Future<ChatCommandResult<ConversationMembershipMutationResult>> _addWaiter(
    String key,
  ) {
    final completer =
        Completer<ChatCommandResult<ConversationMembershipMutationResult>>();
    (_waiters[key] ??= []).add(completer);
    return completer.future;
  }

  void _complete(
    String key,
    ChatCommandResult<ConversationMembershipMutationResult> result,
  ) {
    final waiters = _waiters.remove(key);
    if (waiters != null) {
      for (final waiter in waiters) {
        if (!waiter.isCompleted) waiter.complete(result);
      }
    }
    unawaited(_callerCancellations.remove(key)?.cancel());
  }

  void _completeAll(
    ChatCommandResult<ConversationMembershipMutationResult> result,
  ) {
    for (final key in _waiters.keys.toList(growable: false)) {
      _complete(key, result);
    }
  }

  void _invalidateDispatches() {
    for (final cancellation in _retryWaits.values) {
      cancellation.cancel();
    }
    _retryWaits.clear();
    for (final active in _active.values) {
      active.cancellation.cancel();
    }
    _active.clear();
    _lanePumps.clear();
  }

  static bool _sameStored(
    ApplicationChatQueuedConversationMembershipIntent stored,
    ChatQueuedConversationMembership visible,
  ) =>
      stored.enqueueOrder == visible.enqueueOrder &&
      DateTime.parse(stored.enqueuedAt.value).toUtc() == visible.enqueuedAt &&
      _sameRequest(stored.request, visible.request);

  static bool _sameIntent(
    ChatQueuedConversationMembership left,
    ChatQueuedConversationMembership right,
  ) =>
      left.enqueueOrder == right.enqueueOrder &&
      left.enqueuedAt == right.enqueuedAt &&
      _sameRequest(left.request, right.request);

  static bool _sameRequest(
    ConversationMembershipMutationInput left,
    ConversationMembershipMutationInput right,
  ) =>
      jsonEncode(left.toJson()) == jsonEncode(right.toJson());

  static bool _sameMembershipSemantics(
    ConversationMembershipMutationInput left,
    ConversationMembershipMutationInput right,
  ) =>
      left.intent == right.intent &&
      left.conversationId == right.conversationId &&
      left.targetUserId == right.targetUserId &&
      left.requestedRole == right.requestedRole &&
      left.expectedMemberListRevision == right.expectedMemberListRevision;

  static bool _successIsTerminal(
    ConversationMembershipMutationResult result,
  ) =>
      result.reconciliationStatus ==
          ConversationMembershipReconciliationStatus.memberListConflict ||
      result.reconciliationStatus ==
          ConversationMembershipReconciliationStatus.safetyRejected;

  static bool _isTerminal(
    ChatCommandResult<ConversationMembershipMutationResult> result,
  ) =>
      result is ChatCommandValidationFailure<
          ConversationMembershipMutationResult> ||
      result is ChatCommandAuthenticationFailure<
          ConversationMembershipMutationResult> ||
      result is ChatCommandConflict<ConversationMembershipMutationResult> ||
      result
          is ChatCommandFeatureDisabled<ConversationMembershipMutationResult> ||
      result is ChatCommandUnsupported<ConversationMembershipMutationResult> ||
      result is ChatCommandRejected<ConversationMembershipMutationResult>;

  static bool _isAmbiguous(
    ChatCommandResult<ConversationMembershipMutationResult> result,
  ) =>
      result is ChatCommandTransportFailure<
          ConversationMembershipMutationResult> ||
      result is ChatCommandMalformedResponse<
          ConversationMembershipMutationResult> ||
      result is ChatCommandAborted<ConversationMembershipMutationResult> ||
      result is ChatCommandClosed<ConversationMembershipMutationResult>;
}

final class _ActiveConversationMembershipDispatch {
  final ChatCommandCancellationController cancellation =
      ChatCommandCancellationController();
  final Completer<ChatCommandResult<ConversationMembershipMutationResult>>
      canonicalResult = Completer();
  final Completer<ChatCommandResult<ConversationMembershipMutationResult>>
      result = Completer();
}

Duration _defaultConversationMembershipRetryBackoff(int retryNumber) {
  final exponent = retryNumber <= 1 ? 0 : (retryNumber - 1).clamp(0, 5);
  return Duration(seconds: 1 << exponent);
}

Future<void> _defaultConversationMembershipRetryWait(
  Duration delay,
  ChatCommandCancellationSignal _,
) =>
    Future<void>.delayed(delay);

Future<void> _raceConversationMembershipWait(
  Future<void> future,
  ChatCommandCancellationSignal signal,
) {
  if (signal.isCancelled) {
    return Future<void>.error(const _ConversationMembershipWaitInterrupted());
  }
  final completer = Completer<void>();
  late final StreamSubscription<void> subscription;
  subscription = signal.onCancelled.listen((_) {
    if (!completer.isCompleted) {
      completer.completeError(const _ConversationMembershipWaitInterrupted());
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

final class _ConversationMembershipWaitInterrupted implements Exception {
  const _ConversationMembershipWaitInterrupted();
}
