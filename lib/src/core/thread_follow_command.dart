part of '../handrail_chat_client.dart';

typedef ChatThreadFollowClock = IsoTimestamp Function();

IsoTimestamp _currentThreadFollowTime() =>
    IsoTimestamp(DateTime.now().toUtc().toIso8601String());

/// Computes the delay before replaying an ambiguous retained follow change.
typedef ChatThreadFollowRetryBackoff = Duration Function(
  int retryNumber,
);

/// Injectable wait boundary for deterministic thread-follow recovery tests.
typedef ChatThreadFollowRetryWait = Future<void> Function(
  Duration delay,
  ChatCommandCancellationSignal cancellationSignal,
);

/// Recovery state for one identity-scoped thread-follow change.
enum ChatQueuedThreadFollowStatus {
  waitingForCanonicalBase,
  pending,
  revisionConflict,
}

/// A credential-free view of one retained thread-follow command.
final class ChatQueuedThreadFollow {
  const ChatQueuedThreadFollow._({
    required this.identity,
    required this.request,
    required this.enqueueOrder,
    required this.enqueuedAt,
    required this.status,
  });

  final ApplicationChatStorageIdentity identity;
  final SetThreadFollowInput request;
  final int enqueueOrder;
  final DateTime enqueuedAt;
  final ChatQueuedThreadFollowStatus status;
}

ChatCommandDescriptor<SetThreadFollowInput, SetThreadFollowInput,
    SetThreadFollowResult> _threadFollowDescriptor(
  SetThreadFollowInput request,
) =>
    ChatCommandDescriptor.withPathBuilder(
      name: 'thread.follow.set',
      method: ChatCommandMethod.patch,
      pathBuilder: (input) =>
          '/conversations/${Uri.encodeComponent(input.target.id.value)}/follow',
      retrySafety: ChatCommandRetrySafety.safe,
      validateInput: (input) => SetThreadFollowInput.fromJson(input.toJson()),
      parseResult: (json) => SetThreadFollowResult.fromJson(
        json,
        expectedInput: request,
      ),
      parseErrorResult: (json, httpStatus) {
        if (httpStatus != 409) return null;
        final result = SetThreadFollowResult.fromJson(
          json,
          expectedInput: request,
        );
        return result.reconciliationStatus ==
                ThreadFollowMutationReconciliationStatus.followRevisionConflict
            ? result
            : null;
      },
    );

final class _ThreadFollowRecoveryRuntime {
  _ThreadFollowRecoveryRuntime({
    required this.storage,
    required this.dispatcher,
    required this.store,
    required this.generateIdempotencyKey,
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
  final ChatCommandIdempotencyKeyGenerator generateIdempotencyKey;
  final ChatThreadFollowClock clock;
  final ChatThreadFollowRetryBackoff backoff;
  final ChatThreadFollowRetryWait wait;
  final bool lifecycleManaged;
  final void Function(String code, String message) onStorageDiagnostic;

  final List<ChatQueuedThreadFollow> _intents = [];
  final Map<String, _ActiveThreadFollowDispatch> _active = {};
  final Map<String, List<Completer<ChatCommandResult<SetThreadFollowResult>>>>
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

  List<ChatQueuedThreadFollow> get intents => List.unmodifiable(_intents);

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
      const ChatCommandClosed<SetThreadFollowResult>(),
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
      ApplicationChatQueuedThreadFollowIntentsRecord? record;
      try {
        record = await _mutateRecord(identity, (current) {
          if (!_scopeActive(identity, generation, epoch)) {
            throw StateError('Thread-follow activation is no longer active.');
          }
          return current;
        });
        if (!_scopeActive(identity, generation, epoch)) return;
      } on FormatException {
        if (!_scopeActive(identity, generation, epoch)) return;
        onStorageDiagnostic(
          ChatClientDiagnosticCode.threadFollowIntentsRejected,
          'The stored thread-follow intents were rejected and quarantined.',
        );
        return;
      } catch (_) {
        if (_scopeActive(identity, generation, epoch)) {
          onStorageDiagnostic(
            ChatClientDiagnosticCode.threadFollowIntentsReadFailed,
            'The stored thread-follow intents could not be read.',
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

  Future<ChatCommandResult<SetThreadFollowResult>> follow(
    ConversationId threadId, {
    ChatCommandCancellationSignal? cancellationSignal,
  }) =>
      _begin(
        threadId,
        ThreadFollowMutationIntent.follow,
        cancellationSignal,
      );

  Future<ChatCommandResult<SetThreadFollowResult>> unfollow(
    ConversationId threadId, {
    ChatCommandCancellationSignal? cancellationSignal,
  }) =>
      _begin(
        threadId,
        ThreadFollowMutationIntent.unfollow,
        cancellationSignal,
      );

  Future<ChatCommandResult<SetThreadFollowResult>> _begin(
    ConversationId threadId,
    ThreadFollowMutationIntent intent,
    ChatCommandCancellationSignal? cancellationSignal,
  ) {
    if (_closed) {
      return Future.value(const ChatCommandClosed<SetThreadFollowResult>());
    }
    if (cancellationSignal?.isCancelled == true) {
      return Future.value(const ChatCommandAborted<SetThreadFollowResult>());
    }
    try {
      if (!_knownThreadTarget(threadId)) {
        throw const FormatException('Thread-follow target is not hydrated.');
      }
      final request = SetThreadFollowInput.fromJson(<String, Object?>{
        'operation': 'set_thread_follow',
        'intent': intent.toJson(),
        'target': <String, Object?>{
          'type': 'thread',
          'id': threadId.toJson(),
        },
        'expectedFollowRevision':
            store.threadFollow(threadId).authoritativeRevision,
        'idempotencyKey': generateIdempotencyKey(),
      });
      return execute(request, cancellationSignal: cancellationSignal);
    } catch (_) {
      return Future.value(
        const ChatCommandValidationFailure<SetThreadFollowResult>(),
      );
    }
  }

  Future<ChatCommandResult<SetThreadFollowResult>> execute(
    SetThreadFollowInput request, {
    ChatCommandCancellationSignal? cancellationSignal,
  }) async {
    if (_closed) {
      return const ChatCommandClosed<SetThreadFollowResult>();
    }
    if (cancellationSignal?.isCancelled == true) {
      return const ChatCommandAborted<SetThreadFollowResult>();
    }
    final identity = _identity;
    final generation = _generation;
    final epoch = _epoch;
    if (identity == null) {
      return const ChatCommandValidationFailure<SetThreadFollowResult>();
    }
    final stored = await _persist(identity, generation, epoch, request);
    if (stored == null) {
      return !_scopeActive(identity, generation, epoch)
          ? const ChatCommandClosed<SetThreadFollowResult>()
          : const ChatCommandValidationFailure<SetThreadFollowResult>();
    }
    if (!_scopeActive(identity, generation, epoch)) {
      return const ChatCommandClosed<SetThreadFollowResult>();
    }
    if (cancellationSignal?.isCancelled == true) {
      await _remove(identity, generation, epoch, stored);
      return const ChatCommandAborted<SetThreadFollowResult>();
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
    _startLane(request.target.id);
    return result;
  }

  Future<void> settleCanonicalEvent(KnownDurableEvent event) async {
    if (_closed || event is! ThreadFollowUpdatedDurableEvent) return;
    final identity = _identity;
    final generation = _generation;
    final epoch = _epoch;
    if (identity == null ||
        event.tenantId != identity.tenantId ||
        event.streamId != 'user:${identity.userId.value}') {
      return;
    }

    late final ChatQueuedThreadFollow intent;
    late final CanonicalThreadFollowState follow;
    late final int revision;
    try {
      revision = event.payload.data['followRevision']! as int;
      follow = CanonicalThreadFollowState.fromJson(
        event.payload.data['follow'],
      );
      final state = store.threadFollow(follow.target.id);
      if (revision < state.authoritativeRevision ||
          (revision == state.authoritativeRevision &&
              state.authoritativeFollow != null &&
              jsonEncode(state.authoritativeFollow!.toJson()) !=
                  jsonEncode(follow.toJson()))) {
        return;
      }
      intent = _intents.firstWhere(
        (candidate) =>
            candidate.request.target.id == follow.target.id &&
            _desiredFollowing(candidate.request) == follow.isFollowing &&
            revision >= candidate.request.expectedFollowRevision,
      );
    } catch (_) {
      return;
    }
    if (!_scopeActive(identity, generation, epoch)) return;
    final removed = await _remove(identity, generation, epoch, intent);
    if (!removed || !_scopeActive(identity, generation, epoch)) return;
    _rollback(intent);
    final result = _canonicalSettlementResult(
      intent.request,
      revision,
      follow,
    );
    final active = _active[intent.request.idempotencyKey];
    if (active != null) {
      if (result != null && !active.canonicalResult.isCompleted) {
        active.canonicalResult.complete(result);
      }
      active.cancellation.cancel();
    }
    _complete(
      intent.request.idempotencyKey,
      result ?? const ChatCommandClosed<SetThreadFollowResult>(),
    );
    _startLane(intent.request.target.id);
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
      const ChatCommandClosed<SetThreadFollowResult>(),
    );
    await _storeSubscription.cancel();
  }

  Future<void> _cancelBeforeDispatch(
    ApplicationChatStorageIdentity identity,
    int generation,
    int epoch,
    ChatQueuedThreadFollow intent,
  ) async {
    if (_active.containsKey(intent.request.idempotencyKey)) return;
    final removed = await _remove(identity, generation, epoch, intent);
    if (removed && _scopeActive(identity, generation, epoch)) {
      _rollback(intent);
      _complete(
        intent.request.idempotencyKey,
        const ChatCommandAborted<SetThreadFollowResult>(),
      );
    }
  }

  void _startPumps() {
    if (!_ready) return;
    final conversations = <ConversationId>{};
    for (final intent in _intents) {
      if (conversations.add(intent.request.target.id)) {
        _startLane(intent.request.target.id);
      }
    }
  }

  void _startLane(ConversationId conversationId) {
    if (!_ready || _lanePumps.containsKey(conversationId)) return;
    final identity = _identity;
    final head = _head(conversationId);
    if (identity == null || head == null) return;
    if (head.status != ChatQueuedThreadFollowStatus.pending &&
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
        final state = store.threadFollow(intent.request.target.id);
        final result = _canonicalSettlementResult(
          intent.request,
          state.authoritativeRevision,
          state.authoritativeFollow!,
        );
        final removed = await _remove(identity, generation, epoch, intent);
        if (removed && _scopeActive(identity, generation, epoch)) {
          _rollback(intent);
          _complete(
            intent.request.idempotencyKey,
            result ?? const ChatCommandClosed<SetThreadFollowResult>(),
          );
        }
        retryNumber = 0;
        continue;
      }
      if (intent.status != ChatQueuedThreadFollowStatus.pending) {
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

  Future<ChatCommandResult<SetThreadFollowResult>> _dispatch(
    ApplicationChatStorageIdentity identity,
    int generation,
    int epoch,
    ChatQueuedThreadFollow intent,
  ) async {
    final key = intent.request.idempotencyKey;
    final existing = _active[key];
    if (existing != null) return existing.result.future;
    if (!_scopeActive(identity, generation, epoch)) {
      return const ChatCommandClosed<SetThreadFollowResult>();
    }
    final active = _ActiveThreadFollowDispatch();
    _active[key] = active;
    late ChatCommandResult<SetThreadFollowResult> result;
    try {
      final dispatch = dispatcher.dispatch(
        _threadFollowDescriptor(intent.request),
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
        result = const ChatCommandClosed<SetThreadFollowResult>();
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

  Future<ChatCommandResult<SetThreadFollowResult>> _settleResult(
    ApplicationChatStorageIdentity identity,
    int generation,
    int epoch,
    ChatQueuedThreadFollow intent,
    ChatCommandResult<SetThreadFollowResult> result,
  ) async {
    if (result
        case ChatCommandSuccess<SetThreadFollowResult>(
          :final value,
        )) {
      try {
        if (_isRevisionConflict(value)) {
          _rollback(intent);
          store.reconcileThreadFollowMutation(intent.request, value);
          _refreshProjections();
          return result;
        }
        store.reconcileThreadFollowMutation(intent.request, value);
      } catch (_) {
        return const ChatCommandMalformedResponse<SetThreadFollowResult>();
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

  Future<ChatQueuedThreadFollow?> _persist(
    ApplicationChatStorageIdentity identity,
    int generation,
    int epoch,
    SetThreadFollowInput request,
  ) =>
      _serialized(() async {
        if (!_scopeActive(identity, generation, epoch)) return null;
        try {
          final superseded = _head(request.target.id);
          final enqueuedAt = clock();
          final next = await _mutateRecord(identity, (current) {
            if (!_scopeActive(identity, generation, epoch)) return current;
            // Preserve replay identity and metadata, including after contention.
            if (current?.intents.any((intent) =>
                    intent.request.idempotencyKey == request.idempotencyKey) ??
                false) {
              return current;
            }
            final highest = current?.intents.fold<int>(
                  0,
                  (value, intent) => max(value, intent.enqueueOrder),
                ) ??
                0;
            // Recompute the desired thread state and stable lane position from
            // this attempt's record. The record constructor coalesces each lane.
            return ApplicationChatQueuedThreadFollowIntentsRecord(
              identity: identity,
              intents: [
                ...?current?.intents,
                ApplicationChatQueuedThreadFollowIntent(
                  request: request,
                  enqueueOrder: highest + 1,
                  enqueuedAt: enqueuedAt,
                ),
              ],
            );
          });
          if (!_scopeActive(identity, generation, epoch)) return null;
          _publish(next);
          if (superseded != null && !_contains(superseded)) {
            _rollback(superseded);
            final active = _active[superseded.request.idempotencyKey];
            if (active != null && !active.canonicalResult.isCompleted) {
              active.canonicalResult.complete(
                const ChatCommandClosed<SetThreadFollowResult>(),
              );
              active.cancellation.cancel();
            }
            _complete(
              superseded.request.idempotencyKey,
              const ChatCommandClosed<SetThreadFollowResult>(),
            );
          }
          return _intents.cast<ChatQueuedThreadFollow?>().firstWhere(
                (intent) =>
                    intent != null && _sameRequest(intent.request, request),
                orElse: () => null,
              );
        } catch (_) {
          if (_scopeActive(identity, generation, epoch)) {
            onStorageDiagnostic(
              ChatClientDiagnosticCode.threadFollowIntentsWriteFailed,
              'The thread-follow command could not be stored before dispatch.',
            );
          }
          return null;
        }
      });

  Future<bool> _remove(
    ApplicationChatStorageIdentity identity,
    int generation,
    int epoch,
    ChatQueuedThreadFollow intent,
  ) =>
      _serialized(() async {
        if (!_scopeActive(identity, generation, epoch)) return false;
        try {
          final next = await _mutateRecord(identity, (current) {
            if (!_scopeActive(identity, generation, epoch) || current == null) {
              return current;
            }
            final remaining = current.intents
                .where((candidate) => !_sameStored(candidate, intent))
                .toList(growable: false);
            if (remaining.length == current.intents.length) return current;
            if (remaining.isEmpty) return null;
            return ApplicationChatQueuedThreadFollowIntentsRecord(
              identity: identity,
              intents: remaining,
            );
          });
          if (!_scopeActive(identity, generation, epoch)) return false;
          _publish(next);
          return true;
        } catch (_) {
          if (_scopeActive(identity, generation, epoch)) {
            onStorageDiagnostic(
              ChatClientDiagnosticCode.threadFollowIntentsWriteFailed,
              'A settled thread-follow command could not be removed from storage.',
            );
          }
          return false;
        }
      });

  Future<ApplicationChatQueuedThreadFollowIntentsRecord?> _mutateRecord(
    ApplicationChatStorageIdentity identity,
    ApplicationChatStorageUpdater<
            ApplicationChatQueuedThreadFollowIntentsRecord>
        updater,
  ) =>
      ApplicationChatStorageMutator(storage)
          .mutate<ApplicationChatQueuedThreadFollowIntentsRecord>(
        identity,
        ApplicationChatStorageRecordKind.queuedThreadFollowIntents,
        updater,
      );

  void _publish(
    ApplicationChatQueuedThreadFollowIntentsRecord? record,
  ) {
    final identity = _identity;
    if (identity == null) return;
    _intents
      ..clear()
      ..addAll([
        for (final intent in record?.intents ??
            const <ApplicationChatQueuedThreadFollowIntent>[])
          ChatQueuedThreadFollow._(
            identity: identity,
            request: intent.request,
            enqueueOrder: intent.enqueueOrder,
            enqueuedAt: DateTime.parse(intent.enqueuedAt.value).toUtc(),
            status: ChatQueuedThreadFollowStatus.waitingForCanonicalBase,
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
      final state = store.threadFollow(intent.request.target.id);
      final knownRevision = state.authoritativeRevision;
      late final ChatQueuedThreadFollowStatus status;
      if (!_authorityReady(intent.request)) {
        status = ChatQueuedThreadFollowStatus.waitingForCanonicalBase;
      } else if (knownRevision > intent.request.expectedFollowRevision &&
          !_canonicalMatches(intent.request)) {
        status = ChatQueuedThreadFollowStatus.revisionConflict;
        _rollback(intent);
      } else if (_canonicalMatches(intent.request)) {
        status = ChatQueuedThreadFollowStatus.pending;
        _rollback(intent);
      } else {
        status = ChatQueuedThreadFollowStatus.pending;
        _project(intent);
      }
      if (status != intent.status && index < _intents.length) {
        _intents[index] = ChatQueuedThreadFollow._(
          identity: intent.identity,
          request: intent.request,
          enqueueOrder: intent.enqueueOrder,
          enqueuedAt: intent.enqueuedAt,
          status: status,
        );
      }
    }
  }

  void _project(ChatQueuedThreadFollow intent) {
    final state = store.threadFollow(intent.request.target.id);
    if (state.pendingIntents.any(
      (pending) => pending.idempotencyKey == intent.request.idempotencyKey,
    )) {
      return;
    }
    if (state.authoritativeRevision != intent.request.expectedFollowRevision) {
      return;
    }
    try {
      store.beginOptimisticThreadFollow(intent.request, clock());
    } catch (_) {
      // A later canonical commit will re-evaluate this retained intent.
    }
  }

  void _rollback(ChatQueuedThreadFollow intent) {
    try {
      store.rollbackOptimisticThreadFollow(
        intent.request.target.id,
        intent.request.idempotencyKey,
      );
    } on StateError {
      // An externally owned store may close before the client settles.
    }
  }

  bool _canonicalMatches(SetThreadFollowInput request) {
    final canonical = store.threadFollow(request.target.id).authoritativeFollow;
    if (canonical == null) return false;
    return canonical.isFollowing == _desiredFollowing(request);
  }

  bool _authorityReady(SetThreadFollowInput request) {
    if (!_knownThreadTarget(request.target.id)) return false;
    final state = store.threadFollow(request.target.id);
    if (state.authoritativeRevision < request.expectedFollowRevision) {
      return false;
    }
    return state.authoritativeRevision == 0 ||
        state.authoritativeFollow != null;
  }

  bool _knownThreadTarget(ConversationId threadId) {
    final snapshot = store.state;
    final conversation = snapshot.conversations[threadId];
    if (conversation is! ThreadConversation) return false;
    final parent = snapshot.conversations[conversation.parentConversationId];
    final root = snapshot.canonicalMessages[conversation.rootMessageId];
    return parent != null &&
        parent is! ThreadConversation &&
        root != null &&
        root.conversationId == parent.id;
  }

  ChatCommandSuccess<SetThreadFollowResult>? _canonicalSettlementResult(
    SetThreadFollowInput request,
    int revision,
    CanonicalThreadFollowState follow,
  ) {
    final status = switch (revision) {
      final value when value == request.expectedFollowRevision =>
        'already_requested_state',
      final value when value == request.expectedFollowRevision + 1 => 'applied',
      _ => null,
    };
    if (status == null) return null;
    try {
      return ChatCommandSuccess(SetThreadFollowResult.fromJson(
        <String, Object?>{
          'operation': request.operation,
          'intent': request.intent.toJson(),
          'reconciliationStatus': status,
          'target': request.target.toJson(),
          'expectedFollowRevision': request.expectedFollowRevision,
          'idempotencyKey': request.idempotencyKey,
          'followRevision': revision,
          'follow': follow.toJson(),
        },
        expectedInput: request,
      ));
    } catch (_) {
      return null;
    }
  }

  static bool _desiredFollowing(SetThreadFollowInput request) =>
      request.intent == ThreadFollowMutationIntent.follow;

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
      await _raceThreadFollowWait(
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

  ChatQueuedThreadFollow? _head(ConversationId conversationId) {
    for (final intent in _intents) {
      if (intent.request.target.id == conversationId) return intent;
    }
    return null;
  }

  bool _contains(ChatQueuedThreadFollow intent) =>
      _intents.any((candidate) => _sameVisible(candidate, intent));

  Future<ChatCommandResult<SetThreadFollowResult>> _addWaiter(
    String key,
  ) {
    final completer = Completer<ChatCommandResult<SetThreadFollowResult>>();
    (_waiters[key] ??= []).add(completer);
    return completer.future;
  }

  void _complete(
    String key,
    ChatCommandResult<SetThreadFollowResult> result,
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
    ChatCommandResult<SetThreadFollowResult> result,
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
    ApplicationChatQueuedThreadFollowIntent stored,
    ChatQueuedThreadFollow visible,
  ) =>
      stored.enqueueOrder == visible.enqueueOrder &&
      DateTime.parse(stored.enqueuedAt.value).toUtc() == visible.enqueuedAt &&
      _sameRequest(stored.request, visible.request);

  static bool _sameVisible(
    ChatQueuedThreadFollow left,
    ChatQueuedThreadFollow right,
  ) =>
      left.enqueueOrder == right.enqueueOrder &&
      left.enqueuedAt == right.enqueuedAt &&
      _sameRequest(left.request, right.request);

  static bool _sameRequest(
    SetThreadFollowInput left,
    SetThreadFollowInput right,
  ) =>
      jsonEncode(left.toJson()) == jsonEncode(right.toJson());

  static bool _isRevisionConflict(SetThreadFollowResult result) =>
      result.reconciliationStatus ==
      ThreadFollowMutationReconciliationStatus.followRevisionConflict;

  static bool _isTerminal(
    ChatCommandResult<SetThreadFollowResult> result,
  ) =>
      result is ChatCommandValidationFailure<SetThreadFollowResult> ||
      result is ChatCommandAuthenticationFailure<SetThreadFollowResult> ||
      result is ChatCommandConflict<SetThreadFollowResult> ||
      result is ChatCommandFeatureDisabled<SetThreadFollowResult> ||
      result is ChatCommandUnsupported<SetThreadFollowResult> ||
      result is ChatCommandRejected<SetThreadFollowResult>;

  static bool _isAmbiguous(
    ChatCommandResult<SetThreadFollowResult> result,
  ) =>
      result is ChatCommandTransportFailure<SetThreadFollowResult> ||
      result is ChatCommandMalformedResponse<SetThreadFollowResult> ||
      result is ChatCommandAborted<SetThreadFollowResult> ||
      result is ChatCommandClosed<SetThreadFollowResult>;
}

final class _ActiveThreadFollowDispatch {
  final ChatCommandCancellationController cancellation =
      ChatCommandCancellationController();
  final Completer<ChatCommandResult<SetThreadFollowResult>> canonicalResult =
      Completer();
  final Completer<ChatCommandResult<SetThreadFollowResult>> result =
      Completer();
}

Duration _defaultThreadFollowRetryBackoff(int retryNumber) {
  final exponent = retryNumber <= 1 ? 0 : (retryNumber - 1).clamp(0, 5);
  return Duration(seconds: 1 << exponent);
}

Future<void> _defaultThreadFollowRetryWait(
  Duration delay,
  ChatCommandCancellationSignal _,
) =>
    Future<void>.delayed(delay);

Future<void> _raceThreadFollowWait(
  Future<void> future,
  ChatCommandCancellationSignal signal,
) {
  if (signal.isCancelled) {
    return Future<void>.error(const _ThreadFollowWaitInterrupted());
  }
  final completer = Completer<void>();
  late final StreamSubscription<void> subscription;
  subscription = signal.onCancelled.listen((_) {
    if (!completer.isCompleted) {
      completer.completeError(const _ThreadFollowWaitInterrupted());
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

final class _ThreadFollowWaitInterrupted implements Exception {
  const _ThreadFollowWaitInterrupted();
}

final class _ThreadFollowCommandIntent {
  _ThreadFollowCommandIntent({
    required this.initialRequest,
    required this.externalCancellation,
  });

  final SetThreadFollowInput initialRequest;
  final ChatCommandCancellationSignal? externalCancellation;
  final ChatCommandCancellationController cancellation =
      ChatCommandCancellationController();
  StreamSubscription<void>? cancellationSubscription;
  final Completer<ChatCommandResult<SetThreadFollowResult>> completer =
      Completer();
}

final class _ThreadFollowCommandLane {
  final List<_ThreadFollowCommandIntent> intents = [];
  _ThreadFollowCommandIntent? active;
  bool draining = false;
}

final class _ImmediateThreadFollowRuntime {
  _ImmediateThreadFollowRuntime({
    required ChatCommandDispatcher dispatcher,
    required NormalizedSnapshotStore store,
    required ChatCommandIdempotencyKeyGenerator generateIdempotencyKey,
    required ChatThreadFollowClock clock,
  })  : _dispatcher = dispatcher,
        _store = store,
        _generateIdempotencyKey = generateIdempotencyKey,
        _clock = clock;

  final ChatCommandDispatcher _dispatcher;
  final NormalizedSnapshotStore _store;
  final ChatCommandIdempotencyKeyGenerator _generateIdempotencyKey;
  final ChatThreadFollowClock _clock;
  final Map<ConversationId, _ThreadFollowCommandLane> _lanes = {};
  final Set<Future<void>> _drains = {};
  bool _closed = false;

  Future<ChatCommandResult<SetThreadFollowResult>> follow(
    ConversationId threadId, {
    ChatCommandCancellationSignal? cancellationSignal,
  }) =>
      _begin(
        threadId,
        ThreadFollowMutationIntent.follow,
        cancellationSignal,
      );

  Future<ChatCommandResult<SetThreadFollowResult>> unfollow(
    ConversationId threadId, {
    ChatCommandCancellationSignal? cancellationSignal,
  }) =>
      _begin(
        threadId,
        ThreadFollowMutationIntent.unfollow,
        cancellationSignal,
      );

  Future<ChatCommandResult<SetThreadFollowResult>> _begin(
    ConversationId threadId,
    ThreadFollowMutationIntent intent,
    ChatCommandCancellationSignal? cancellationSignal,
  ) {
    if (_closed) {
      return Future.value(const ChatCommandClosed<SetThreadFollowResult>());
    }
    if (cancellationSignal?.isCancelled == true) {
      return Future.value(const ChatCommandAborted<SetThreadFollowResult>());
    }

    late final SetThreadFollowInput request;
    try {
      final revision = _store.threadFollow(threadId).authoritativeRevision;
      final input = <String, Object?>{
        'operation': 'set_thread_follow',
        'intent': intent.toJson(),
        'target': {'type': 'thread', 'id': threadId.toJson()},
        'expectedFollowRevision': revision,
        'idempotencyKey': _generateIdempotencyKey(),
      };
      request = SetThreadFollowInput.fromJson(input);
      _store.beginOptimisticThreadFollow(request, _clock());
    } catch (_) {
      return Future.value(
        const ChatCommandValidationFailure<SetThreadFollowResult>(),
      );
    }

    final command = _ThreadFollowCommandIntent(
      initialRequest: request,
      externalCancellation: cancellationSignal,
    );
    final lane = _lanes.putIfAbsent(
      threadId,
      _ThreadFollowCommandLane.new,
    );
    lane.intents.add(command);
    if (cancellationSignal != null) {
      command.cancellationSubscription =
          cancellationSignal.onCancelled.listen((_) {
        if (identical(lane.active, command)) {
          command.cancellation.cancel();
          return;
        }
        if (command.completer.isCompleted || !lane.intents.remove(command)) {
          return;
        }
        _rollback(command.initialRequest);
        command.completer.complete(
          const ChatCommandAborted<SetThreadFollowResult>(),
        );
        unawaited(command.cancellationSubscription?.cancel());
      });
    }
    if (!lane.draining) {
      lane.draining = true;
      late final Future<void> drain;
      drain = _drain(threadId, lane).whenComplete(() => _drains.remove(drain));
      _drains.add(drain);
    }
    return command.completer.future;
  }

  Future<void> _drain(
    ConversationId threadId,
    _ThreadFollowCommandLane lane,
  ) async {
    while (lane.intents.isNotEmpty) {
      final command = lane.intents.first;
      if (command.completer.isCompleted) {
        lane.intents.removeAt(0);
        continue;
      }
      lane.active = command;
      final initial = command.initialRequest;
      late final SetThreadFollowInput request;
      ChatCommandResult<SetThreadFollowResult> result;
      try {
        final revision = _store.threadFollow(threadId).authoritativeRevision;
        request = SetThreadFollowInput.fromJson({
          ...initial.toJson(),
          'expectedFollowRevision': revision,
        });
        _store.rebaseOptimisticThreadFollow(
          threadId,
          initial.idempotencyKey,
          revision,
        );
        result = await _dispatcher.dispatch(
          _threadFollowDescriptor(request),
          request,
          options: ChatCommandDispatchOptions(
            idempotencyKey: request.idempotencyKey,
            cancellationSignal: command.cancellation.signal,
          ),
        );
      } catch (_) {
        result = const ChatCommandValidationFailure<SetThreadFollowResult>();
      }

      if (_closed) {
        _rollback(initial);
        result = const ChatCommandClosed<SetThreadFollowResult>();
      } else if (result
          case ChatCommandSuccess<SetThreadFollowResult>(:final value)) {
        try {
          _store.reconcileThreadFollowMutation(request, value);
        } catch (_) {
          result = const ChatCommandMalformedResponse<SetThreadFollowResult>();
          _rollback(initial);
        }
      } else {
        _rollback(initial);
      }
      await command.cancellationSubscription?.cancel();
      if (!command.completer.isCompleted) command.completer.complete(result);
      if (lane.intents.isNotEmpty && identical(lane.intents.first, command)) {
        lane.intents.removeAt(0);
      } else {
        lane.intents.remove(command);
      }
      lane.active = null;
    }
    lane.draining = false;
    if (identical(_lanes[threadId], lane)) _lanes.remove(threadId);
  }

  void _rollback(SetThreadFollowInput request) {
    try {
      _store.rollbackOptimisticThreadFollow(
        request.target.id,
        request.idempotencyKey,
      );
    } on StateError {
      // An externally owned normalized store may close first.
    }
  }

  Future<void> dispose() async {
    if (_closed) return;
    _closed = true;
    for (final lane in _lanes.values) {
      final active = lane.active;
      active?.cancellation.cancel();
      final queued = active == null
          ? lane.intents.toList(growable: false)
          : lane.intents.skip(1).toList(growable: false);
      for (final command in queued) {
        lane.intents.remove(command);
        _rollback(command.initialRequest);
        unawaited(command.cancellationSubscription?.cancel());
        if (!command.completer.isCompleted) {
          command.completer.complete(
            const ChatCommandClosed<SetThreadFollowResult>(),
          );
        }
      }
    }
    if (_drains.isNotEmpty) {
      await Future.wait(_drains.toList(growable: false));
    }
  }
}

extension HandrailChatThreadFollowCommands on HandrailChatClient {
  Future<ChatCommandResult<SetThreadFollowResult>> followThread(
    ConversationId threadId, {
    ChatCommandCancellationSignal? cancellationSignal,
  }) {
    if (_disposed) {
      return Future.value(const ChatCommandClosed<SetThreadFollowResult>());
    }
    final durable = _threadFollowRecoveryRuntime;
    return durable != null
        ? durable.follow(
            threadId,
            cancellationSignal: cancellationSignal,
          )
        : _immediateThreadFollowRuntime!.follow(
            threadId,
            cancellationSignal: cancellationSignal,
          );
  }

  Future<ChatCommandResult<SetThreadFollowResult>> unfollowThread(
    ConversationId threadId, {
    ChatCommandCancellationSignal? cancellationSignal,
  }) {
    if (_disposed) {
      return Future.value(const ChatCommandClosed<SetThreadFollowResult>());
    }
    final durable = _threadFollowRecoveryRuntime;
    return durable != null
        ? durable.unfollow(
            threadId,
            cancellationSignal: cancellationSignal,
          )
        : _immediateThreadFollowRuntime!.unfollow(
            threadId,
            cancellationSignal: cancellationSignal,
          );
  }
}

/// Framework-neutral follow state and commands for one thread conversation.
final class ChatThreadFollowController {
  ChatThreadFollowController._({
    required this.threadId,
    required NormalizedSnapshotStore normalizedState,
    required _ChatThreadFollowCommand followThread,
    required _ChatThreadFollowCommand unfollowThread,
    required bool initiallyClosed,
  })  : _followThread = followThread,
        _unfollowThread = unfollowThread,
        _state = normalizedState.threadFollow(threadId),
        _closed = initiallyClosed {
    _states = _createStateStream();
    if (initiallyClosed) {
      unawaited(_stateChanges.close());
    } else {
      _subscription = normalizedState
          .threadFollowStates(threadId)
          .skip(1)
          .listen(_emit, onError: _stateChanges.addError);
    }
  }

  final ConversationId threadId;
  final _ChatThreadFollowCommand _followThread;
  final _ChatThreadFollowCommand _unfollowThread;
  final StreamController<NormalizedThreadFollowState> _stateChanges =
      StreamController.broadcast(sync: true);
  late final Stream<NormalizedThreadFollowState> _states;
  StreamSubscription<NormalizedThreadFollowState>? _subscription;
  NormalizedThreadFollowState _state;
  bool _closed;

  NormalizedThreadFollowState get state => _state;
  Stream<NormalizedThreadFollowState> get states => _states;

  Future<ChatCommandResult<SetThreadFollowResult>> follow({
    ChatCommandCancellationSignal? cancellationSignal,
  }) =>
      _closed
          ? Future.value(const ChatCommandClosed<SetThreadFollowResult>())
          : _followThread(threadId, cancellationSignal: cancellationSignal);

  Future<ChatCommandResult<SetThreadFollowResult>> unfollow({
    ChatCommandCancellationSignal? cancellationSignal,
  }) =>
      _closed
          ? Future.value(const ChatCommandClosed<SetThreadFollowResult>())
          : _unfollowThread(threadId, cancellationSignal: cancellationSignal);

  void _emit(NormalizedThreadFollowState state) {
    if (_closed || _stateChanges.isClosed) return;
    _state = state;
    _stateChanges.add(state);
  }

  Stream<NormalizedThreadFollowState> _createStateStream() => Stream.multi(
        (events) {
          events.add(_state);
          final subscription = _stateChanges.stream.listen(
            events.add,
            onError: events.addError,
            onDone: events.close,
          );
          events.onCancel = subscription.cancel;
        },
        isBroadcast: true,
      );

  Future<void> dispose() async {
    if (_closed) return;
    _closed = true;
    await _subscription?.cancel();
    await _stateChanges.close();
  }
}
