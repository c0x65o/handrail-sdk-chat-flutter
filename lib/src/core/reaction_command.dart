part of '../handrail_chat_client.dart';

/// Authored fields accepted by [HandrailChatClient.setReaction].
final class ChatSetReactionInput {
  const ChatSetReactionInput({
    required this.messageId,
    required this.reactionKey,
    required this.reactedByCurrentUser,
    this.idempotencyKey,
  });

  final MessageId messageId;
  final String reactionKey;

  /// The explicit desired membership state; this is deliberately not a
  /// toggle so retries and queued changes have one unambiguous outcome.
  final bool reactedByCurrentUser;

  /// Optional caller-owned key. When omitted, the client generates one once
  /// for the complete logical intent and reuses it across safe retries.
  final String? idempotencyKey;
}

final ChatCommandDescriptor<ReactionMutationInput, ReactionMutationInput,
        ReactionMutationResult> _reactionDescriptor =
    ChatCommandDescriptor.withPathBuilder(
  name: 'message.reaction.set',
  method: ChatCommandMethod.patch,
  pathBuilder: (request) =>
      '/messages/${Uri.encodeComponent(request.messageId.toJson())}'
      '/reactions/${Uri.encodeComponent(request.reactionKey)}',
  retrySafety: ChatCommandRetrySafety.safe,
  validateInput: (request) => ReactionMutationInput.fromJson(request.toJson()),
  parseResult: ReactionMutationResult.fromJson,
);

final class _ReactionCommandIntent {
  _ReactionCommandIntent({
    required this.request,
    required this.cancellationSignal,
  });

  final ReactionMutationInput request;
  final ChatCommandCancellationSignal? cancellationSignal;
  StreamSubscription<void>? cancellationSubscription;
  final Completer<ChatCommandResult<ReactionMutationResult>> completer =
      Completer<ChatCommandResult<ReactionMutationResult>>();
}

final class _ReactionCommandLane {
  final List<_ReactionCommandIntent> intents = [];
  _ReactionCommandIntent? active;
  bool draining = false;
}

String _reactionCommandTarget(MessageId messageId, String reactionKey) =>
    '${messageId.value.length}:${messageId.value}:$reactionKey';

bool _reactionResultMatchesRequest(
  ReactionMutationInput request,
  ReactionMutationResult result,
) =>
    result.messageId == request.messageId &&
    result.reactionKey == request.reactionKey &&
    result.operation == request.operation;

/// Injectable wall clock used for durable reaction FIFO metadata.
typedef ChatReactionClock = DateTime Function();

/// Computes the delay before replaying an ambiguous retained reaction.
typedef ChatReactionRetryBackoff = Duration Function(int retryNumber);

/// Injectable wait boundary for deterministic retained-reaction tests.
typedef ChatReactionRetryWait = Future<void> Function(
  Duration delay,
  ChatCommandCancellationSignal cancellationSignal,
);

enum _QueuedReactionStatus { waitingForCanonicalBase, pending }

final class _QueuedReaction {
  const _QueuedReaction({
    required this.identity,
    required this.request,
    required this.enqueueOrder,
    required this.enqueuedAt,
    required this.status,
  });

  final ApplicationChatStorageIdentity identity;
  final ReactionMutationInput request;
  final int enqueueOrder;
  final IsoTimestamp enqueuedAt;
  final _QueuedReactionStatus status;

  _QueuedReaction withStatus(_QueuedReactionStatus next) => _QueuedReaction(
        identity: identity,
        request: request,
        enqueueOrder: enqueueOrder,
        enqueuedAt: enqueuedAt,
        status: next,
      );
}

final class _ReactionRecoveryRuntime {
  _ReactionRecoveryRuntime({
    required this.storage,
    required this.storageCoordinator,
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
      _startPump();
    });
  }

  final ApplicationChatStorage storage;
  final _MessageMutationIntentStorageCoordinator storageCoordinator;
  final ChatCommandDispatcher dispatcher;
  final NormalizedSnapshotStore store;
  final ChatReactionClock clock;
  final ChatReactionRetryBackoff backoff;
  final ChatReactionRetryWait wait;
  final bool lifecycleManaged;
  final void Function(String code, String message) onStorageDiagnostic;

  final List<_QueuedReaction> _reactions = <_QueuedReaction>[];
  final Map<String, _ActiveReactionDispatch> _active = {};
  final Set<String> _authoredDispatchStarting = <String>{};
  final Map<String, Future<void>> _laneTails = <String, Future<void>>{};
  late final StreamSubscription<NormalizedSnapshotState> _storeSubscription;
  Future<void>? _pump;
  bool _pumpRestartRequested = false;
  ChatCommandCancellationController? _retryCancellation;
  ApplicationChatStorageIdentity? _identity;
  int _generation = 0;
  int _epoch = 0;
  bool _metadataReady = false;
  bool _connectivityOnline = false;
  bool _realtimeConnected = false;
  bool _applicationForeground = true;
  bool _closed = false;

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
      _metadataReady &&
      _applicationForeground &&
      _connectivityOnline &&
      (!lifecycleManaged || _realtimeConnected) &&
      _identity != null;

  void prepareActivation(
    ApplicationChatStorageIdentity identity, {
    required int generation,
  }) {
    if (_closed) return;
    _invalidateActiveDispatches();
    _active.clear();
    _rollbackAllProjections();
    _identity = identity;
    _generation = generation;
    ++_epoch;
    _reactions.clear();
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
      ApplicationChatQueuedMessageMutationIntentsRecord? record;
      try {
        record = await _mutateRecord(identity, (current) => current);
      } on FormatException {
        if (!_scopeActive(identity, generation, epoch)) return;
        onStorageDiagnostic(
          ChatClientDiagnosticCode.messageMutationIntentsRejected,
          'The stored message-mutation intents were rejected and quarantined.',
        );
        return;
      } catch (_) {
        if (_scopeActive(identity, generation, epoch)) {
          onStorageDiagnostic(
            ChatClientDiagnosticCode.messageMutationIntentsReadFailed,
            'The stored message-mutation intents could not be read.',
          );
        }
        return;
      }
      if (_scopeActive(identity, generation, epoch)) _publish(record);
    });
    if (!_scopeActive(identity, generation, epoch)) return;
    _refreshProjections();
    _startPump();
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
      _invalidateActiveDispatches();
      return;
    }
    _refreshProjections();
    _startPump();
  }

  Future<ChatCommandResult<ReactionMutationResult>> execute(
    ReactionMutationInput request, {
    ChatCommandCancellationSignal? cancellationSignal,
  }) async {
    if (_closed) return const ChatCommandClosed<ReactionMutationResult>();
    if (cancellationSignal?.isCancelled == true) {
      return const ChatCommandAborted<ReactionMutationResult>();
    }
    final identity = _identity;
    final generation = _generation;
    final epoch = _epoch;
    if (identity == null || !_hasCanonicalBaseline(request)) {
      return const ChatCommandValidationFailure<ReactionMutationResult>();
    }
    final stored = await _persist(identity, generation, epoch, request);
    if (stored == null) {
      return !_scopeActive(identity, generation, epoch)
          ? const ChatCommandClosed<ReactionMutationResult>()
          : const ChatCommandValidationFailure<ReactionMutationResult>();
    }
    if (!_scopeActive(identity, generation, epoch)) {
      return const ChatCommandClosed<ReactionMutationResult>();
    }
    if (cancellationSignal?.isCancelled == true) {
      await _remove(identity, generation, epoch, stored);
      return const ChatCommandAborted<ReactionMutationResult>();
    }
    if (!_project(stored)) {
      await _remove(identity, generation, epoch, stored);
      return const ChatCommandValidationFailure<ReactionMutationResult>();
    }

    final key = stored.request.idempotencyKey;
    final target = _reactionCommandTarget(
      stored.request.messageId,
      stored.request.reactionKey,
    );
    _authoredDispatchStarting.add(key);
    late final ChatCommandResult<ReactionMutationResult> result;
    try {
      result = await _runInLane(
        target,
        () async {
          if (!_scopeActive(identity, generation, epoch)) {
            return const ChatCommandClosed<ReactionMutationResult>();
          }
          if (!_contains(stored)) {
            return const ChatCommandAborted<ReactionMutationResult>();
          }
          return _dispatch(
            identity,
            generation,
            epoch,
            stored,
            callerCancellation: cancellationSignal,
          );
        },
      );
    } finally {
      _authoredDispatchStarting.remove(key);
    }
    if (_scopeActive(identity, generation, epoch) && _isAmbiguous(result)) {
      _startPump(waitBeforeFirstDispatch: true);
    } else {
      _startPump();
    }
    return result;
  }

  Future<void> settleCanonicalEvent(KnownDurableEvent event) async {
    if (_closed || event is! ReactionUpdatedDurableEvent) return;
    final identity = _identity;
    final generation = _generation;
    final epoch = _epoch;
    if (identity == null || event.tenantId != identity.tenantId) return;
    late final ReactionMutationResult result;
    try {
      final payload = event.payload.data;
      result = ReactionMutationResult.fromJson(<String, Object?>{
        'operation': payload['operation'],
        'reconciliationStatus': payload['reconciliationStatus'],
        'messageId': payload['messageId'],
        'reactionKey': payload['reactionKey'],
        'count': payload['count'],
        'reactedByCurrentUser': payload['reactedByCurrentUser'],
      });
    } catch (_) {
      return;
    }
    final matches = _reactions
        .where((reaction) =>
            reaction.request.messageId == result.messageId &&
            reaction.request.reactionKey == result.reactionKey &&
            (reaction.request is AddReactionInput) ==
                result.reactedByCurrentUser)
        .toList(growable: false);
    for (final reaction in matches) {
      if (!_scopeActive(identity, generation, epoch)) return;
      final removed = await _remove(
        identity,
        generation,
        epoch,
        reaction,
      );
      if (!removed || !_scopeActive(identity, generation, epoch)) continue;
      try {
        store.reconcileOptimisticReaction(
          reaction.request.idempotencyKey,
          result,
        );
      } on StateError {
        // An externally owned store may close before the client.
      }
      final active = _active[reaction.request.idempotencyKey];
      if (active != null && !active.canonicalResult.isCompleted) {
        active.canonicalResult.complete(
          ChatCommandSuccess<ReactionMutationResult>(result),
        );
        active.cancellation.cancel();
      }
    }
    _refreshProjections();
    _startPump();
  }

  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    ++_epoch;
    _invalidateActiveDispatches();
    _rollbackAllProjections();
    await _storeSubscription.cancel();
  }

  Future<_QueuedReaction?> _persist(
    ApplicationChatStorageIdentity identity,
    int generation,
    int epoch,
    ReactionMutationInput request,
  ) =>
      _serialized<_QueuedReaction?>(() async {
        if (!_scopeActive(identity, generation, epoch)) return null;
        try {
          final enqueuedAt = IsoTimestamp(clock().toUtc().toIso8601String());
          final next = await _mutateRecord(identity, (current) {
            if (!_scopeActive(identity, generation, epoch)) return current;
            // Check all mutation types on every retry. An existing key keeps
            // its identity and metadata; a different request cannot reuse it.
            if (current?.intents.any((intent) =>
                    intent.idempotencyKey == request.idempotencyKey) ??
                false) {
              return current;
            }
            final highest = current?.intents.fold<int>(
                  0,
                  (value, intent) => max(value, intent.enqueueOrder),
                ) ??
                0;
            // Normalize against this attempt's complete committed record.
            // Adjacent same-lane requests converge in commit order while
            // keeping the original lane position and timestamp.
            return ApplicationChatQueuedMessageMutationIntentsRecord(
              identity: identity,
              intents: <ApplicationChatQueuedMessageMutationIntent>[
                ...?current?.intents,
                ApplicationChatQueuedMessageMutationIntent(
                  request: request,
                  enqueueOrder: highest + 1,
                  enqueuedAt: enqueuedAt,
                ),
              ],
            );
          });
          if (!_scopeActive(identity, generation, epoch)) return null;
          _publish(next);
          for (final reaction in _reactions) {
            if (_sameJson(reaction.request.toJson(), request.toJson())) {
              return reaction;
            }
          }
          return null;
        } catch (_) {
          if (_scopeActive(identity, generation, epoch)) {
            onStorageDiagnostic(
              ChatClientDiagnosticCode.messageMutationIntentsWriteFailed,
              'The reaction intent could not be stored before dispatch.',
            );
          }
          return null;
        }
      });

  Future<bool> _remove(
    ApplicationChatStorageIdentity identity,
    int generation,
    int epoch,
    _QueuedReaction reaction,
  ) =>
      _serialized<bool>(() async {
        if (!_scopeActive(identity, generation, epoch)) return false;
        try {
          final next = await _mutateRecord(identity, (current) {
            if (!_scopeActive(identity, generation, epoch) || current == null) {
              return current;
            }
            final remaining = current.intents
                .where((intent) => !_sameStoredReaction(intent, reaction))
                .toList(growable: false);
            if (remaining.length == current.intents.length) return current;
            if (remaining.isEmpty) return null;
            return ApplicationChatQueuedMessageMutationIntentsRecord(
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
              ChatClientDiagnosticCode.messageMutationIntentsWriteFailed,
              'A settled reaction intent could not be removed from storage.',
            );
          }
          return false;
        }
      });

  Future<ApplicationChatQueuedMessageMutationIntentsRecord?> _mutateRecord(
    ApplicationChatStorageIdentity identity,
    ApplicationChatStorageUpdater<
            ApplicationChatQueuedMessageMutationIntentsRecord>
        updater,
  ) =>
      ApplicationChatStorageMutator(storage)
          .mutate<ApplicationChatQueuedMessageMutationIntentsRecord>(
        identity,
        ApplicationChatStorageRecordKind.queuedMessageMutationIntents,
        updater,
      );

  void _publish(ApplicationChatQueuedMessageMutationIntentsRecord? record) {
    final identity = _identity;
    if (identity == null) return;
    final previous = <String, _QueuedReaction>{
      for (final reaction in _reactions)
        reaction.request.idempotencyKey: reaction,
    };
    final next = <_QueuedReaction>[
      for (final intent in record?.intents ??
          const <ApplicationChatQueuedMessageMutationIntent>[])
        if (intent.request case final ReactionMutationInput request)
          _QueuedReaction(
            identity: identity,
            request: request,
            enqueueOrder: intent.enqueueOrder,
            enqueuedAt: intent.enqueuedAt,
            status: previous[request.idempotencyKey]?.status ??
                _QueuedReactionStatus.waitingForCanonicalBase,
          ),
    ];
    final retainedKeys =
        next.map((reaction) => reaction.request.idempotencyKey).toSet();
    for (final reaction in _reactions) {
      if (reaction.status == _QueuedReactionStatus.pending &&
          !retainedKeys.contains(reaction.request.idempotencyKey)) {
        _rollback(reaction.request);
      }
    }
    _reactions
      ..clear()
      ..addAll(next);
  }

  void _refreshProjections() {
    if (_closed) return;
    for (var index = 0; index < _reactions.length; index += 1) {
      final reaction = _reactions[index];
      if (reaction.status == _QueuedReactionStatus.pending) continue;
      _project(reaction);
    }
  }

  bool _project(_QueuedReaction reaction) {
    if (reaction.status == _QueuedReactionStatus.pending) return true;
    if (!_hasCanonicalBaseline(reaction.request)) return false;
    final index = _reactions.indexWhere(
      (candidate) =>
          candidate.request.idempotencyKey == reaction.request.idempotencyKey,
    );
    if (index < 0) return false;
    final pending = reaction.withStatus(_QueuedReactionStatus.pending);
    _reactions[index] = pending;
    try {
      store.beginOptimisticReaction(reaction.request);
      return true;
    } catch (_) {
      if (index < _reactions.length && identical(_reactions[index], pending)) {
        _reactions[index] = reaction;
      }
      return false;
    }
  }

  bool _hasCanonicalBaseline(ReactionMutationInput request) {
    final canonical = store.state.canonicalMessages[request.messageId];
    final timeline = store.state.messages[request.messageId];
    return canonical is ActiveMessage &&
        timeline != null &&
        timeline.message is ActiveMessage;
  }

  void _startPump({bool waitBeforeFirstDispatch = false}) {
    if (!_ready) return;
    if (_pump != null) {
      _pumpRestartRequested = true;
      return;
    }
    final identity = _identity;
    if (identity == null || _reactions.isEmpty) return;
    final first = _reactions.first;
    if (_authoredDispatchStarting.contains(first.request.idempotencyKey)) {
      return;
    }
    final generation = _generation;
    final epoch = _epoch;
    late final Future<void> pump;
    pump = _drain(
      identity,
      generation,
      epoch,
      waitBeforeFirstDispatch: waitBeforeFirstDispatch,
    ).whenComplete(() {
      if (identical(_pump, pump)) _pump = null;
      final restart = _pumpRestartRequested;
      _pumpRestartRequested = false;
      if (restart) _startPump();
    });
    _pump = pump;
    unawaited(pump);
  }

  Future<void> _drain(
    ApplicationChatStorageIdentity identity,
    int generation,
    int epoch, {
    required bool waitBeforeFirstDispatch,
  }) async {
    var retryNumber = 0;
    if (waitBeforeFirstDispatch) {
      retryNumber = 1;
      if (!await _waitBeforeRetry(retryNumber, identity, generation, epoch)) {
        return;
      }
    }
    while (_ready && _scopeActive(identity, generation, epoch)) {
      _refreshProjections();
      if (_reactions.isEmpty) return;
      final reaction = _reactions.first;
      if (reaction.status != _QueuedReactionStatus.pending ||
          _authoredDispatchStarting.contains(reaction.request.idempotencyKey)) {
        return;
      }
      final result = await _dispatch(
        identity,
        generation,
        epoch,
        reaction,
      );
      if (!_scopeActive(identity, generation, epoch)) return;
      if (!_contains(reaction)) {
        retryNumber = 0;
        continue;
      }
      if (!_isAmbiguous(result)) return;
      retryNumber += 1;
      if (!await _waitBeforeRetry(retryNumber, identity, generation, epoch)) {
        return;
      }
    }
  }

  Future<ChatCommandResult<ReactionMutationResult>> _dispatch(
    ApplicationChatStorageIdentity identity,
    int generation,
    int epoch,
    _QueuedReaction reaction, {
    ChatCommandCancellationSignal? callerCancellation,
  }) async {
    final key = reaction.request.idempotencyKey;
    final existing = _active[key];
    if (existing != null) return existing.result.future;
    if (!_scopeActive(identity, generation, epoch)) {
      return const ChatCommandClosed<ReactionMutationResult>();
    }
    final active = _ActiveReactionDispatch();
    _active[key] = active;
    StreamSubscription<void>? callerSubscription;
    if (callerCancellation != null) {
      callerSubscription = callerCancellation.onCancelled.listen((_) {
        active.cancellation.cancel();
      });
      if (callerCancellation.isCancelled) active.cancellation.cancel();
    }
    late ChatCommandResult<ReactionMutationResult> result;
    try {
      final dispatch = dispatcher.dispatch(
        _reactionDescriptor,
        reaction.request,
        options: ChatCommandDispatchOptions(
          idempotencyKey: key,
          cancellationSignal: active.cancellation.signal,
        ),
      );
      result = await Future.any<ChatCommandResult<ReactionMutationResult>>([
        dispatch,
        active.canonicalResult.future,
      ]);
      if (active.canonicalResult.isCompleted) active.cancellation.cancel();
      if (!_scopeActive(identity, generation, epoch)) {
        result = const ChatCommandClosed<ReactionMutationResult>();
      } else {
        result = await _settleResult(
          identity,
          generation,
          epoch,
          reaction,
          result,
        );
      }
    } finally {
      await callerSubscription?.cancel();
      if (identical(_active[key], active)) _active.remove(key);
    }
    if (!active.result.isCompleted) active.result.complete(result);
    return result;
  }

  Future<ChatCommandResult<ReactionMutationResult>> _settleResult(
    ApplicationChatStorageIdentity identity,
    int generation,
    int epoch,
    _QueuedReaction reaction,
    ChatCommandResult<ReactionMutationResult> result,
  ) async {
    if (result case ChatCommandSuccess<ReactionMutationResult>(:final value)) {
      if (!_reactionResultMatchesRequest(reaction.request, value)) {
        return ChatCommandMalformedResponse<ReactionMutationResult>();
      }
      try {
        store.reconcileOptimisticReaction(
          reaction.request.idempotencyKey,
          value,
        );
      } catch (_) {
        return ChatCommandMalformedResponse<ReactionMutationResult>();
      }
      await _remove(identity, generation, epoch, reaction);
    } else if (_isTerminal(result)) {
      _rollback(reaction.request);
      await _remove(identity, generation, epoch, reaction);
    }
    return result;
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
    _retryCancellation = cancellation;
    if (!_ready || !_scopeActive(identity, generation, epoch)) {
      cancellation.cancel();
      return false;
    }
    try {
      await _raceReactionWait(
        Future<void>.sync(() => wait(delay, cancellation.signal)),
        cancellation.signal,
      );
      return _ready && _scopeActive(identity, generation, epoch);
    } catch (_) {
      return false;
    } finally {
      if (identical(_retryCancellation, cancellation)) {
        _retryCancellation = null;
      }
    }
  }

  Future<ChatCommandResult<ReactionMutationResult>> _runInLane(
    String target,
    Future<ChatCommandResult<ReactionMutationResult>> Function() operation,
  ) {
    final completer = Completer<ChatCommandResult<ReactionMutationResult>>();
    final previous = _laneTails[target] ?? Future<void>.value();
    late final Future<void> current;
    current = previous.then((_) async {
      try {
        completer.complete(await operation());
      } catch (error, stackTrace) {
        completer.completeError(error, stackTrace);
      }
    }).whenComplete(() {
      if (identical(_laneTails[target], current)) _laneTails.remove(target);
    });
    _laneTails[target] = current;
    unawaited(current);
    return completer.future;
  }

  void _invalidateActiveDispatches() {
    _retryCancellation?.cancel();
    _retryCancellation = null;
    for (final active in _active.values) {
      active.cancellation.cancel();
    }
  }

  void _rollbackAllProjections() {
    for (final reaction in _reactions) {
      if (reaction.status == _QueuedReactionStatus.pending) {
        _rollback(reaction.request);
      }
    }
  }

  void _rollback(ReactionMutationInput request) {
    try {
      store.rollbackOptimisticReaction(
        request.messageId,
        request.reactionKey,
        request.idempotencyKey,
      );
    } on StateError {
      // An externally owned store may close before the client.
    }
  }

  bool _contains(_QueuedReaction reaction) =>
      _reactions.any((candidate) => _sameReaction(candidate, reaction));

  Future<T> _serialized<T>(Future<T> Function() operation) =>
      storageCoordinator.serialized(operation);

  static bool _sameStoredReaction(
    ApplicationChatQueuedMessageMutationIntent intent,
    _QueuedReaction reaction,
  ) =>
      intent.request is ReactionMutationInput &&
      intent.enqueueOrder == reaction.enqueueOrder &&
      intent.enqueuedAt == reaction.enqueuedAt &&
      _sameJson(
        (intent.request as ReactionMutationInput).toJson(),
        reaction.request.toJson(),
      );

  static bool _sameReaction(_QueuedReaction left, _QueuedReaction right) =>
      left.enqueueOrder == right.enqueueOrder &&
      left.enqueuedAt == right.enqueuedAt &&
      _sameJson(left.request.toJson(), right.request.toJson());

  static bool _isTerminal(
    ChatCommandResult<ReactionMutationResult> result,
  ) =>
      result is ChatCommandValidationFailure<ReactionMutationResult> ||
      result is ChatCommandAuthenticationFailure<ReactionMutationResult> ||
      result is ChatCommandConflict<ReactionMutationResult> ||
      result is ChatCommandFeatureDisabled<ReactionMutationResult> ||
      result is ChatCommandUnsupported<ReactionMutationResult> ||
      result is ChatCommandRejected<ReactionMutationResult>;

  static bool _isAmbiguous(
    ChatCommandResult<ReactionMutationResult> result,
  ) =>
      result is ChatCommandTransportFailure<ReactionMutationResult> ||
      result is ChatCommandMalformedResponse<ReactionMutationResult> ||
      result is ChatCommandAborted<ReactionMutationResult> ||
      result is ChatCommandClosed<ReactionMutationResult>;
}

final class _ActiveReactionDispatch {
  final ChatCommandCancellationController cancellation =
      ChatCommandCancellationController();
  final Completer<ChatCommandResult<ReactionMutationResult>> canonicalResult =
      Completer<ChatCommandResult<ReactionMutationResult>>();
  final Completer<ChatCommandResult<ReactionMutationResult>> result =
      Completer<ChatCommandResult<ReactionMutationResult>>();
}

Duration _defaultReactionRetryBackoff(int retryNumber) {
  final exponent = retryNumber <= 1 ? 0 : (retryNumber - 1).clamp(0, 5);
  return Duration(seconds: 1 << exponent);
}

Future<void> _defaultReactionRetryWait(
  Duration delay,
  ChatCommandCancellationSignal _,
) =>
    Future<void>.delayed(delay);

Future<void> _raceReactionWait(
  Future<void> future,
  ChatCommandCancellationSignal signal,
) {
  if (signal.isCancelled) {
    return Future<void>.error(const _ReactionWaitInterrupted());
  }
  final cancelled = Completer<void>();
  late final StreamSubscription<void> subscription;
  subscription = signal.onCancelled.listen((_) {
    if (!cancelled.isCompleted) {
      cancelled.completeError(const _ReactionWaitInterrupted());
    }
  });
  return Future.any<void>([future, cancelled.future]).whenComplete(
    subscription.cancel,
  );
}

final class _ReactionWaitInterrupted implements Exception {
  const _ReactionWaitInterrupted();
}
