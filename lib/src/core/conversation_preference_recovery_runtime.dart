part of '../handrail_chat_client.dart';

/// Computes the delay before replaying an ambiguous retained preference.
typedef ChatConversationPreferenceRetryBackoff = Duration Function(
  int retryNumber,
);

/// Injectable wait boundary for deterministic preference-recovery tests.
typedef ChatConversationPreferenceRetryWait = Future<void> Function(
  Duration delay,
  ChatCommandCancellationSignal cancellationSignal,
);

/// Recovery state for one identity-scoped conversation preference.
enum ChatQueuedConversationPreferenceStatus {
  waitingForCanonicalBase,
  pending,
  revisionConflict,
}

/// A credential-free view of one retained conversation preference command.
final class ChatQueuedConversationPreference {
  const ChatQueuedConversationPreference._({
    required this.identity,
    required this.request,
    required this.enqueueOrder,
    required this.enqueuedAt,
    required this.status,
  });

  final ApplicationChatStorageIdentity identity;
  final UpdateConversationPreferenceInput request;
  final int enqueueOrder;
  final DateTime enqueuedAt;
  final ChatQueuedConversationPreferenceStatus status;
}

final class _ConversationPreferenceRecoveryRuntime {
  _ConversationPreferenceRecoveryRuntime({
    required this.storage,
    required this.dispatcher,
    required this.store,
    required this.clock,
    required this.backoff,
    required this.wait,
    required this.lifecycleManaged,
    required this.onStorageDiagnostic,
  }) {
    _storeSubscription = store.acceptedCommitChanges.listen((_) {
      _refreshProjections();
      _startPumps();
    });
  }

  final ApplicationChatStorage storage;
  final ChatCommandDispatcher dispatcher;
  final NormalizedSnapshotStore store;
  final ChatConversationPreferenceClock clock;
  final ChatConversationPreferenceRetryBackoff backoff;
  final ChatConversationPreferenceRetryWait wait;
  final bool lifecycleManaged;
  final void Function(String code, String message) onStorageDiagnostic;

  final List<ChatQueuedConversationPreference> _intents = [];
  final Map<String, _ActiveConversationPreferenceDispatch> _active = {};
  final Map<
          String,
          List<
              Completer<ChatCommandResult<UpdateConversationPreferenceResult>>>>
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

  List<ChatQueuedConversationPreference> get intents =>
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
    final previousIntents = _intents.toList(growable: false);
    _invalidateDispatches();
    _completeAll(
      const ChatCommandClosed<UpdateConversationPreferenceResult>(),
    );
    _identity = identity;
    _generation = generation;
    ++_epoch;
    _intents.clear();
    for (final intent in previousIntents) {
      _rollback(intent);
    }
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
      ApplicationChatQueuedConversationPreferenceIntentsRecord? record;
      try {
        record = await _readRecord(identity);
        if (!_scopeActive(identity, generation, epoch)) return;
      } on FormatException {
        if (!_scopeActive(identity, generation, epoch)) return;
        onStorageDiagnostic(
          ChatClientDiagnosticCode.conversationPreferenceIntentsRejected,
          'The stored conversation-preference intents were rejected and quarantined.',
        );
        return;
      } catch (_) {
        if (_scopeActive(identity, generation, epoch)) {
          onStorageDiagnostic(
            ChatClientDiagnosticCode.conversationPreferenceIntentsReadFailed,
            'The stored conversation-preference intents could not be read.',
          );
        }
        return;
      }
      if (_scopeActive(identity, generation, epoch)) _publish(record);
    });
    if (!_scopeActive(identity, generation, epoch)) return;
    _refreshProjections();
    _startPumps();
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
    _refreshProjections();
    _startPumps();
  }

  Future<ChatCommandResult<UpdateConversationPreferenceResult>> execute(
    UpdateConversationPreferenceInput request, {
    ChatCommandCancellationSignal? cancellationSignal,
  }) async {
    if (_closed) {
      return const ChatCommandClosed<UpdateConversationPreferenceResult>();
    }
    if (cancellationSignal?.isCancelled == true) {
      return const ChatCommandAborted<UpdateConversationPreferenceResult>();
    }
    final identity = _identity;
    final generation = _generation;
    final epoch = _epoch;
    if (identity == null) {
      return const ChatCommandValidationFailure<
          UpdateConversationPreferenceResult>();
    }
    if (_head(request.conversationId) != null) {
      return const ChatCommandValidationFailure<
          UpdateConversationPreferenceResult>();
    }

    final stored = await _persist(identity, generation, epoch, request);
    if (stored == null) {
      return !_scopeActive(identity, generation, epoch)
          ? const ChatCommandClosed<UpdateConversationPreferenceResult>()
          : const ChatCommandValidationFailure<
              UpdateConversationPreferenceResult>();
    }
    if (!_scopeActive(identity, generation, epoch)) {
      return const ChatCommandClosed<UpdateConversationPreferenceResult>();
    }
    if (cancellationSignal?.isCancelled == true) {
      await _remove(identity, generation, epoch, stored);
      return const ChatCommandAborted<UpdateConversationPreferenceResult>();
    }

    _refreshProjections();
    final key = stored.request.idempotencyKey;
    final result = _addWaiter(key);
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
      if (cancellationSignal.isCancelled) {
        unawaited(_cancelBeforeDispatch(
          identity,
          generation,
          epoch,
          stored,
        ));
      }
    }
    _startLane(request.conversationId);
    return result;
  }

  Future<void> settleCanonicalEvent(KnownDurableEvent event) async {
    if (_closed || event is! PreferenceUpdatedDurableEvent) return;
    final identity = _identity;
    final generation = _generation;
    final epoch = _epoch;
    if (identity == null || event.tenantId != identity.tenantId) return;

    late final UpdateConversationPreferenceInput input;
    late final UpdateConversationPreferenceResult value;
    late final ChatQueuedConversationPreference intent;
    try {
      input = UpdateConversationPreferenceInput.fromJson(
        event.payload.data['input'],
      );
      intent = _intents.firstWhere(
        (candidate) => _sameRequest(candidate.request, input),
      );
      value = UpdateConversationPreferenceResult.fromJson(
        event.payload.data['result'],
        expectedInput: intent.request,
      );
    } catch (_) {
      return;
    }
    if (!_scopeActive(identity, generation, epoch)) return;
    final result = ChatCommandSuccess<UpdateConversationPreferenceResult>(
      value,
    );
    if (_isRevisionConflict(value)) {
      _refreshProjections();
      final active = _active[intent.request.idempotencyKey];
      if (active != null && !active.canonicalResult.isCompleted) {
        active.canonicalResult.complete(result);
        active.cancellation.cancel();
      }
      _complete(intent.request.idempotencyKey, result);
      return;
    }
    final removed = await _remove(identity, generation, epoch, intent);
    if (!removed || !_scopeActive(identity, generation, epoch)) return;
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
    final previousIntents = _intents.toList(growable: false);
    _closed = true;
    ++_epoch;
    _invalidateDispatches();
    for (final intent in previousIntents) {
      _rollback(intent);
    }
    _completeAll(
      const ChatCommandClosed<UpdateConversationPreferenceResult>(),
    );
    await _storeSubscription.cancel();
  }

  Future<void> _cancelBeforeDispatch(
    ApplicationChatStorageIdentity identity,
    int generation,
    int epoch,
    ChatQueuedConversationPreference intent,
  ) async {
    if (_active.containsKey(intent.request.idempotencyKey)) return;
    final removed = await _remove(identity, generation, epoch, intent);
    if (removed && _scopeActive(identity, generation, epoch)) {
      _rollback(intent);
      _complete(
        intent.request.idempotencyKey,
        const ChatCommandAborted<UpdateConversationPreferenceResult>(),
      );
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
    final head = _head(conversationId);
    if (identity == null || head == null) return;
    if (head.status != ChatQueuedConversationPreferenceStatus.pending &&
        !_canonicalMatches(head.request)) {
      return;
    }
    final generation = _generation;
    final epoch = _epoch;
    late final Future<void> pump;
    pump = _drainLane(identity, generation, epoch, conversationId)
        .whenComplete(() {
      if (identical(_lanePumps[conversationId], pump)) {
        _lanePumps.remove(conversationId);
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
      _refreshProjections();
      final intent = _head(conversationId);
      if (intent == null) return;
      if (_canonicalMatches(intent.request)) {
        final result = _alreadyEqualResult(intent.request);
        final removed = await _remove(identity, generation, epoch, intent);
        if (removed && _scopeActive(identity, generation, epoch)) {
          _complete(intent.request.idempotencyKey, result);
        }
        retryNumber = 0;
        continue;
      }
      if (intent.status != ChatQueuedConversationPreferenceStatus.pending) {
        return;
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

  Future<ChatCommandResult<UpdateConversationPreferenceResult>> _dispatch(
    ApplicationChatStorageIdentity identity,
    int generation,
    int epoch,
    ChatQueuedConversationPreference intent,
  ) async {
    final key = intent.request.idempotencyKey;
    final existing = _active[key];
    if (existing != null) return existing.result.future;
    if (!_scopeActive(identity, generation, epoch)) {
      return const ChatCommandClosed<UpdateConversationPreferenceResult>();
    }
    final active = _ActiveConversationPreferenceDispatch();
    _active[key] = active;
    late ChatCommandResult<UpdateConversationPreferenceResult> result;
    try {
      final dispatch = dispatcher.dispatch(
        _conversationPreferenceDescriptor(intent.request),
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
        result = const ChatCommandClosed<UpdateConversationPreferenceResult>();
      } else {
        result = await _settleResult(
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

  Future<ChatCommandResult<UpdateConversationPreferenceResult>> _settleResult(
    ApplicationChatStorageIdentity identity,
    int generation,
    int epoch,
    ChatQueuedConversationPreference intent,
    ChatCommandResult<UpdateConversationPreferenceResult> result,
  ) async {
    if (result
        case ChatCommandSuccess<UpdateConversationPreferenceResult>(
          :final value,
        )) {
      try {
        if (_isRevisionConflict(value)) {
          _rollback(intent);
          store.reconcileConversationPreferenceMutation(intent.request, value);
          _refreshProjections();
          return result;
        }
        store.reconcileConversationPreferenceMutation(intent.request, value);
      } catch (_) {
        return const ChatCommandMalformedResponse<
            UpdateConversationPreferenceResult>();
      }
      await _remove(identity, generation, epoch, intent);
    } else if (_isTerminal(result)) {
      final removed = await _remove(identity, generation, epoch, intent);
      if (removed && _scopeActive(identity, generation, epoch)) {
        _rollback(intent);
      }
    }
    return result;
  }

  Future<ChatQueuedConversationPreference?> _persist(
    ApplicationChatStorageIdentity identity,
    int generation,
    int epoch,
    UpdateConversationPreferenceInput request,
  ) =>
      _serialized(() async {
        if (!_scopeActive(identity, generation, epoch)) return null;
        try {
          final committed = await _mutateRecord(identity, (current) {
            if (!_scopeActive(identity, generation, epoch)) return current;
            final highest = current?.intents.fold<int>(
                  0,
                  (value, intent) => max(value, intent.enqueueOrder),
                ) ??
                0;
            // Reapply the desired lane to this attempt's record. The record
            // constructor coalesces replacements while preserving lane order
            // and enqueue time, including work committed by another runtime.
            return ApplicationChatQueuedConversationPreferenceIntentsRecord(
              identity: identity,
              intents: [
                ...?current?.intents,
                ApplicationChatQueuedConversationPreferenceIntent(
                  request: request,
                  enqueueOrder: highest + 1,
                  enqueuedAt: clock(),
                ),
              ],
            );
          });
          if (!_scopeActive(identity, generation, epoch)) return null;
          _publish(committed);
          return _intents.cast<ChatQueuedConversationPreference?>().firstWhere(
                (intent) =>
                    intent != null && _sameRequest(intent.request, request),
                orElse: () => null,
              );
        } catch (_) {
          if (_scopeActive(identity, generation, epoch)) {
            onStorageDiagnostic(
              ChatClientDiagnosticCode.conversationPreferenceIntentsWriteFailed,
              'The conversation-preference command could not be stored before dispatch.',
            );
          }
          return null;
        }
      });

  Future<bool> _remove(
    ApplicationChatStorageIdentity identity,
    int generation,
    int epoch,
    ChatQueuedConversationPreference intent,
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
                : ApplicationChatQueuedConversationPreferenceIntentsRecord(
                    identity: identity,
                    intents: remaining,
                  );
          });
          if (!_scopeActive(identity, generation, epoch)) return false;
          _publish(committed);
          return true;
        } catch (_) {
          if (_scopeActive(identity, generation, epoch)) {
            onStorageDiagnostic(
              ChatClientDiagnosticCode.conversationPreferenceIntentsWriteFailed,
              'A settled conversation-preference command could not be removed from storage.',
            );
          }
          return false;
        }
      });

  Future<ApplicationChatQueuedConversationPreferenceIntentsRecord?> _readRecord(
    ApplicationChatStorageIdentity identity,
  ) =>
      _mutateRecord(identity, (current) => current);

  Future<ApplicationChatQueuedConversationPreferenceIntentsRecord?>
      _mutateRecord(
    ApplicationChatStorageIdentity identity,
    ApplicationChatStorageUpdater<
            ApplicationChatQueuedConversationPreferenceIntentsRecord>
        updater,
  ) =>
          ApplicationChatStorageMutator(storage)
              .mutate<ApplicationChatQueuedConversationPreferenceIntentsRecord>(
            identity,
            ApplicationChatStorageRecordKind
                .queuedConversationPreferenceIntents,
            updater,
          );

  void _publish(
    ApplicationChatQueuedConversationPreferenceIntentsRecord? record,
  ) {
    final identity = _identity;
    if (identity == null) return;
    _intents
      ..clear()
      ..addAll([
        for (final intent in record?.intents ??
            const <ApplicationChatQueuedConversationPreferenceIntent>[])
          ChatQueuedConversationPreference._(
            identity: identity,
            request: intent.request,
            enqueueOrder: intent.enqueueOrder,
            enqueuedAt: DateTime.parse(intent.enqueuedAt.value).toUtc(),
            status:
                ChatQueuedConversationPreferenceStatus.waitingForCanonicalBase,
          ),
      ]);
  }

  void _refreshProjections() {
    final identity = _identity;
    final generation = _generation;
    final epoch = _epoch;
    if (identity == null || !_scopeActive(identity, generation, epoch)) return;
    for (var index = 0; index < _intents.length; index += 1) {
      final intent = _intents[index];
      final state = store.conversationPreference(intent.request.conversationId);
      final knownRevision = state.authoritativeRevision;
      late final ChatQueuedConversationPreferenceStatus status;
      if (knownRevision < intent.request.expectedPreferenceRevision) {
        status = ChatQueuedConversationPreferenceStatus.waitingForCanonicalBase;
      } else if (knownRevision > intent.request.expectedPreferenceRevision &&
          !_canonicalMatches(intent.request)) {
        status = ChatQueuedConversationPreferenceStatus.revisionConflict;
        _rollback(intent);
      } else if (_canonicalMatches(intent.request)) {
        status = ChatQueuedConversationPreferenceStatus.pending;
        _rollback(intent);
      } else {
        status = ChatQueuedConversationPreferenceStatus.pending;
        _project(intent);
      }
      if (status != intent.status && index < _intents.length) {
        _intents[index] = ChatQueuedConversationPreference._(
          identity: intent.identity,
          request: intent.request,
          enqueueOrder: intent.enqueueOrder,
          enqueuedAt: intent.enqueuedAt,
          status: status,
        );
      }
    }
  }

  void _project(ChatQueuedConversationPreference intent) {
    final state = store.conversationPreference(intent.request.conversationId);
    if (state.pendingIntents.any(
      (pending) => pending.idempotencyKey == intent.request.idempotencyKey,
    )) {
      return;
    }
    if (state.authoritativeRevision !=
        intent.request.expectedPreferenceRevision) {
      return;
    }
    try {
      store.beginOptimisticConversationPreference(intent.request, clock());
    } catch (_) {
      // A later canonical commit will re-evaluate this retained intent.
    }
  }

  void _rollback(ChatQueuedConversationPreference intent) {
    try {
      store.rollbackOptimisticConversationPreference(
        intent.request.conversationId,
        intent.request.idempotencyKey,
      );
    } on StateError {
      // An externally owned store may close before the client settles.
    }
  }

  bool _canonicalMatches(UpdateConversationPreferenceInput request) {
    final canonical = store
        .conversationPreference(request.conversationId)
        .authoritativePreference;
    if (canonical == null) return false;
    return jsonEncode(<String, Object?>{
          'notificationPreference': canonical.notificationPreference,
          'isStarred': canonical.isStarred,
          'mute': canonical.mute.toJson(),
        }) ==
        jsonEncode(request.preference.toJson());
  }

  ChatCommandSuccess<UpdateConversationPreferenceResult> _alreadyEqualResult(
    UpdateConversationPreferenceInput request,
  ) {
    final canonical = store
        .conversationPreference(request.conversationId)
        .authoritativePreference!;
    return ChatCommandSuccess(UpdateConversationPreferenceResult.fromJson(
      <String, Object?>{
        'operation': request.operation,
        'reconciliationStatus': 'already_requested_state',
        'conversationId': request.conversationId.toJson(),
        'expectedPreferenceRevision': request.expectedPreferenceRevision,
        'idempotencyKey': request.idempotencyKey,
        'requestedPreference': request.preference.toJson(),
        'preferenceRevision': request.expectedPreferenceRevision,
        'preference': <String, Object?>{
          ...request.preference.toJson(),
          'updatedAt': canonical.updatedAt.toJson(),
        },
      },
      expectedInput: request,
    ));
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
      await _raceConversationPreferenceWait(
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

  ChatQueuedConversationPreference? _head(ConversationId conversationId) {
    for (final intent in _intents) {
      if (intent.request.conversationId == conversationId) return intent;
    }
    return null;
  }

  bool _contains(ChatQueuedConversationPreference intent) =>
      _intents.any((candidate) => _sameVisible(candidate, intent));

  Future<ChatCommandResult<UpdateConversationPreferenceResult>> _addWaiter(
    String key,
  ) {
    final completer =
        Completer<ChatCommandResult<UpdateConversationPreferenceResult>>();
    (_waiters[key] ??= []).add(completer);
    return completer.future;
  }

  void _complete(
    String key,
    ChatCommandResult<UpdateConversationPreferenceResult> result,
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
    ChatCommandResult<UpdateConversationPreferenceResult> result,
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
    ApplicationChatQueuedConversationPreferenceIntent stored,
    ChatQueuedConversationPreference visible,
  ) =>
      stored.enqueueOrder == visible.enqueueOrder &&
      DateTime.parse(stored.enqueuedAt.value).toUtc() == visible.enqueuedAt &&
      _sameRequest(stored.request, visible.request);

  static bool _sameVisible(
    ChatQueuedConversationPreference left,
    ChatQueuedConversationPreference right,
  ) =>
      left.enqueueOrder == right.enqueueOrder &&
      left.enqueuedAt == right.enqueuedAt &&
      _sameRequest(left.request, right.request);

  static bool _sameRequest(
    UpdateConversationPreferenceInput left,
    UpdateConversationPreferenceInput right,
  ) =>
      jsonEncode(left.toJson()) == jsonEncode(right.toJson());

  static bool _isRevisionConflict(UpdateConversationPreferenceResult result) =>
      result.reconciliationStatus ==
      ConversationPreferenceReconciliationStatus.preferenceRevisionConflict;

  static bool _isTerminal(
    ChatCommandResult<UpdateConversationPreferenceResult> result,
  ) =>
      result
          is ChatCommandValidationFailure<UpdateConversationPreferenceResult> ||
      result is ChatCommandAuthenticationFailure<
          UpdateConversationPreferenceResult> ||
      result is ChatCommandConflict<UpdateConversationPreferenceResult> ||
      result
          is ChatCommandFeatureDisabled<UpdateConversationPreferenceResult> ||
      result is ChatCommandUnsupported<UpdateConversationPreferenceResult> ||
      result is ChatCommandRejected<UpdateConversationPreferenceResult>;

  static bool _isAmbiguous(
    ChatCommandResult<UpdateConversationPreferenceResult> result,
  ) =>
      result
          is ChatCommandTransportFailure<UpdateConversationPreferenceResult> ||
      result
          is ChatCommandMalformedResponse<UpdateConversationPreferenceResult> ||
      result is ChatCommandAborted<UpdateConversationPreferenceResult> ||
      result is ChatCommandClosed<UpdateConversationPreferenceResult>;
}

final class _ActiveConversationPreferenceDispatch {
  final ChatCommandCancellationController cancellation =
      ChatCommandCancellationController();
  final Completer<ChatCommandResult<UpdateConversationPreferenceResult>>
      canonicalResult = Completer();
  final Completer<ChatCommandResult<UpdateConversationPreferenceResult>>
      result = Completer();
}

Duration _defaultConversationPreferenceRetryBackoff(int retryNumber) {
  final exponent = retryNumber <= 1 ? 0 : (retryNumber - 1).clamp(0, 5);
  return Duration(seconds: 1 << exponent);
}

Future<void> _defaultConversationPreferenceRetryWait(
  Duration delay,
  ChatCommandCancellationSignal _,
) =>
    Future<void>.delayed(delay);

Future<void> _raceConversationPreferenceWait(
  Future<void> future,
  ChatCommandCancellationSignal signal,
) {
  if (signal.isCancelled) {
    return Future<void>.error(const _ConversationPreferenceWaitInterrupted());
  }
  final completer = Completer<void>();
  late final StreamSubscription<void> subscription;
  subscription = signal.onCancelled.listen((_) {
    if (!completer.isCompleted) {
      completer.completeError(const _ConversationPreferenceWaitInterrupted());
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

final class _ConversationPreferenceWaitInterrupted implements Exception {
  const _ConversationPreferenceWaitInterrupted();
}
