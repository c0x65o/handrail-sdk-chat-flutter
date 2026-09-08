part of '../handrail_chat_client.dart';

/// Injectable wall clock used for durable forward FIFO metadata.
typedef ChatForwardMessageClock = DateTime Function();

/// Computes the bounded delay before replaying an ambiguous retained forward.
typedef ChatForwardMessageRetryBackoff = Duration Function(int retryNumber);

/// Injectable wait boundary for deterministic retained-forward tests.
typedef ChatForwardMessageRetryWait = Future<void> Function(
  Duration delay,
  ChatCommandCancellationSignal cancellationSignal,
);

enum _QueuedForwardStatus { waitingForCanonicalAccess, pending }

final class _QueuedForward {
  const _QueuedForward({
    required this.identity,
    required this.request,
    required this.enqueueOrder,
    required this.enqueuedAt,
    required this.status,
  });

  final ApplicationChatStorageIdentity identity;
  final ForwardMessageRequest request;
  final int enqueueOrder;
  final IsoTimestamp enqueuedAt;
  final _QueuedForwardStatus status;

  _QueuedForward withStatus(_QueuedForwardStatus next) => _QueuedForward(
        identity: identity,
        request: request,
        enqueueOrder: enqueueOrder,
        enqueuedAt: enqueuedAt,
        status: next,
      );
}

final class _ForwardMessageRecoveryRuntime {
  _ForwardMessageRecoveryRuntime({
    required this.storage,
    required this.storageCoordinator,
    required this.dispatcher,
    required this.store,
    required this.generateCorrelationId,
    required this.generateIdempotencyKey,
    required this.clock,
    required this.backoff,
    required this.wait,
    required this.lifecycleManaged,
    required this.onStorageDiagnostic,
  }) {
    _storeSubscription = store.acceptedCommitChanges.listen((_) {
      // Canonical event settlement runs immediately after the normalized
      // commit. Defer replay so it can claim the matching retained intent
      // before the commit listener considers another dispatch.
      scheduleMicrotask(() {
        if (_closed) return;
        _refreshAccess();
        _startPump();
      });
    });
  }

  final ApplicationChatStorage storage;
  final _MessageMutationIntentStorageCoordinator storageCoordinator;
  final ChatCommandDispatcher dispatcher;
  final NormalizedSnapshotStore store;
  final ChatForwardMessageCorrelationIdGenerator generateCorrelationId;
  final ChatCommandIdempotencyKeyGenerator generateIdempotencyKey;
  final ChatForwardMessageClock clock;
  final ChatForwardMessageRetryBackoff backoff;
  final ChatForwardMessageRetryWait wait;
  final bool lifecycleManaged;
  final void Function(String code, String message) onStorageDiagnostic;

  final List<_QueuedForward> _forwards = <_QueuedForward>[];
  final Map<String, _ActiveForwardDispatch> _active = {};
  final Set<String> _authoredDispatchStarting = <String>{};
  final Set<String> _canonicalSettlements = <String>{};
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
    _canonicalSettlements.clear();
    _identity = identity;
    _generation = generation;
    ++_epoch;
    _forwards.clear();
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
        record = await _readRecord(identity);
        if (!_scopeActive(identity, generation, epoch)) return;
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
    _refreshAccess();
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
    _refreshAccess();
    _startPump();
  }

  Future<ChatCommandResult<ForwardMessageResult>> execute(
    ChatForwardMessageInput input, {
    ChatCommandCancellationSignal? cancellationSignal,
  }) async {
    if (_closed) return const ChatCommandClosed<ForwardMessageResult>();
    if (cancellationSignal?.isCancelled == true) {
      return const ChatCommandAborted<ForwardMessageResult>();
    }
    final identity = _identity;
    final generation = _generation;
    final epoch = _epoch;
    if (identity == null || !_hasCanonicalAccess(identity, input)) {
      return const ChatCommandValidationFailure<ForwardMessageResult>();
    }
    final stored = await _persistOrReuse(identity, generation, epoch, input);
    if (stored == null) {
      return !_scopeActive(identity, generation, epoch)
          ? const ChatCommandClosed<ForwardMessageResult>()
          : const ChatCommandValidationFailure<ForwardMessageResult>();
    }
    if (!_scopeActive(identity, generation, epoch)) {
      return const ChatCommandClosed<ForwardMessageResult>();
    }
    if (cancellationSignal?.isCancelled == true) {
      await _remove(identity, generation, epoch, stored);
      return const ChatCommandAborted<ForwardMessageResult>();
    }
    final key = stored.request.idempotencyKey;
    _authoredDispatchStarting.add(key);
    late final ChatCommandResult<ForwardMessageResult> result;
    try {
      result = await _dispatch(
        identity,
        generation,
        epoch,
        stored,
        callerCancellation: cancellationSignal,
      );
    } finally {
      _authoredDispatchStarting.remove(key);
    }
    if (_scopeActive(identity, generation, epoch) && _isAmbiguous(result)) {
      _startPump(waitBeforeFirstDispatch: true);
    }
    return result;
  }

  Future<void> settleCanonicalEvent(KnownDurableEvent event) async {
    if (_closed || event is! MessageCreatedDurableEvent) return;
    final identity = _identity;
    final generation = _generation;
    final epoch = _epoch;
    if (identity == null || event.tenantId != identity.tenantId) return;
    final clientMessageId = event.payload.data['clientMessageId'];
    if (clientMessageId is! String) return;
    for (final forward in _forwards.toList(growable: false)) {
      if (!_scopeActive(identity, generation, epoch)) return;
      final request = forward.request;
      if (clientMessageId != request.clientCorrelationId ||
          event.streamId != request.destinationConversationId.value) {
        continue;
      }
      late final ForwardMessageResult value;
      try {
        value = ForwardMessageResult.fromJson(<String, Object?>{
          'operation': 'forward_message.v1',
          'reconciliationStatus': 'replayed',
          'clientCorrelationId': clientMessageId,
          'destinationConversationId': request.destinationConversationId.value,
          'message': event.payload.data['message'],
          'canonicalRevision': 1,
        }, request: request);
      } catch (_) {
        continue;
      }
      if (!_resultMatches(identity, forward, value)) continue;
      final key = request.idempotencyKey;
      _canonicalSettlements.add(key);
      try {
        final removed = await _remove(identity, generation, epoch, forward);
        if (!removed || !_scopeActive(identity, generation, epoch)) continue;
        final active = _active[key];
        if (active != null && !active.canonicalResult.isCompleted) {
          active.canonicalResult.complete(
            ChatCommandSuccess<ForwardMessageResult>(value),
          );
          active.cancellation.cancel();
        }
      } finally {
        _canonicalSettlements.remove(key);
      }
    }
    _startPump();
  }

  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    ++_epoch;
    _invalidateActiveDispatches();
    await _storeSubscription.cancel();
  }

  Future<_QueuedForward?> _persistOrReuse(
    ApplicationChatStorageIdentity identity,
    int generation,
    int epoch,
    ChatForwardMessageInput input,
  ) =>
      _serialized<_QueuedForward?>(() async {
        if (!_scopeActive(identity, generation, epoch) ||
            !_hasCanonicalAccess(identity, input)) {
          return null;
        }
        try {
          ForwardMessageRequest? candidate;
          IsoTimestamp? enqueuedAt;
          final committed = await _mutateRecord(identity, (current) {
            if (!_scopeActive(identity, generation, epoch) ||
                !_hasCanonicalAccess(identity, input)) {
              return current;
            }
            // Another runtime may have won since the previous attempt.
            final exists = current?.intents.any((intent) {
                  final request = intent.request;
                  return request is ForwardMessageRequest &&
                      request.sourceMessageId == input.sourceMessageId &&
                      request.destinationConversationId ==
                          input.destinationConversationId;
                }) ??
                false;
            if (exists) return current;
            // Allocate request identity once, but place it after the current
            // attempt's FIFO tail so a concurrent append cannot collide.
            candidate ??= ForwardMessageRequest.fromJson(<String, Object?>{
              'operation': 'forward_message.v1',
              'sourceMessageId': input.sourceMessageId.value,
              'destinationConversationId':
                  input.destinationConversationId.value,
              'clientCorrelationId': generateCorrelationId(),
              'idempotencyKey': generateIdempotencyKey(),
            });
            enqueuedAt ??= IsoTimestamp(clock().toUtc().toIso8601String());
            final highest = current?.intents.fold<int>(
                  0,
                  (value, intent) => max(value, intent.enqueueOrder),
                ) ??
                0;
            return ApplicationChatQueuedMessageMutationIntentsRecord(
              identity: identity,
              intents: <ApplicationChatQueuedMessageMutationIntent>[
                ...?current?.intents,
                ApplicationChatQueuedMessageMutationIntent(
                  request: candidate!,
                  enqueueOrder: highest + 1,
                  enqueuedAt: enqueuedAt!,
                ),
              ],
            );
          });
          if (!_scopeActive(identity, generation, epoch)) return null;
          _publish(committed);
          if (!_hasCanonicalAccess(identity, input)) return null;
          return _forwards
              .where((forward) =>
                  forward.request.sourceMessageId == input.sourceMessageId &&
                  forward.request.destinationConversationId ==
                      input.destinationConversationId)
              .firstOrNull;
        } catch (_) {
          if (_scopeActive(identity, generation, epoch)) {
            onStorageDiagnostic(
              ChatClientDiagnosticCode.messageMutationIntentsWriteFailed,
              'The message forward could not be stored before dispatch.',
            );
          }
          return null;
        }
      });

  Future<bool> _remove(
    ApplicationChatStorageIdentity identity,
    int generation,
    int epoch,
    _QueuedForward forward,
  ) =>
      _serialized<bool>(() async {
        if (!_scopeActive(identity, generation, epoch)) return false;
        try {
          final committed = await _mutateRecord(identity, (current) {
            if (!_scopeActive(identity, generation, epoch) || current == null) {
              return current;
            }
            final remaining = current.intents
                .where((intent) => !_sameStoredForward(intent, forward))
                .toList(growable: false);
            if (remaining.length == current.intents.length) return current;
            return remaining.isEmpty
                ? null
                : ApplicationChatQueuedMessageMutationIntentsRecord(
                    identity: identity,
                    intents: remaining,
                  );
          });
          if (!_scopeActive(identity, generation, epoch)) return false;
          _publish(committed);
          // Absence is settled, but a replacement with different request or
          // ordering metadata must not complete the original dispatch.
          return !(committed?.intents.any((intent) {
                final request = intent.request;
                return request is ForwardMessageRequest &&
                    (request.idempotencyKey == forward.request.idempotencyKey ||
                        request.clientCorrelationId ==
                            forward.request.clientCorrelationId);
              }) ??
              false);
        } catch (_) {
          if (_scopeActive(identity, generation, epoch)) {
            onStorageDiagnostic(
              ChatClientDiagnosticCode.messageMutationIntentsWriteFailed,
              'A settled message forward could not be removed from storage.',
            );
          }
          return false;
        }
      });

  Future<ApplicationChatQueuedMessageMutationIntentsRecord?> _readRecord(
    ApplicationChatStorageIdentity identity,
  ) =>
      _mutateRecord(identity, (current) => current);

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
    _forwards
      ..clear()
      ..addAll(<_QueuedForward>[
        for (final intent in record?.intents ??
            const <ApplicationChatQueuedMessageMutationIntent>[])
          if (intent.request case final ForwardMessageRequest request)
            _QueuedForward(
              identity: identity,
              request: request,
              enqueueOrder: intent.enqueueOrder,
              enqueuedAt: intent.enqueuedAt,
              status: _QueuedForwardStatus.waitingForCanonicalAccess,
            ),
      ]);
  }

  void _refreshAccess() {
    final identity = _identity;
    if (_closed || identity == null) return;
    for (var index = 0; index < _forwards.length; index += 1) {
      final forward = _forwards[index];
      final pending = _hasCanonicalAccess(
        identity,
        ChatForwardMessageInput(
          sourceMessageId: forward.request.sourceMessageId,
          destinationConversationId: forward.request.destinationConversationId,
        ),
      );
      final status = pending
          ? _QueuedForwardStatus.pending
          : _QueuedForwardStatus.waitingForCanonicalAccess;
      if (status != forward.status) {
        _forwards[index] = forward.withStatus(status);
      }
    }
  }

  bool _hasCanonicalAccess(
    ApplicationChatStorageIdentity identity,
    ChatForwardMessageInput input,
  ) {
    final source = store.state.canonicalMessages[input.sourceMessageId];
    final destination =
        store.state.conversations[input.destinationConversationId];
    if (source is! ActiveMessage ||
        source.tenantId != identity.tenantId ||
        source.content.blocks != null ||
        (source.content.attachments?.isNotEmpty ?? false)) {
      return false;
    }
    final destinationMember =
        store.state.membersByConversation[input.destinationConversationId]
            ?[identity.userId];
    return destination != null &&
        destination.tenantId == identity.tenantId &&
        destinationMember?.state == 'active' &&
        store.state.lifecycleArchivedStates[input.destinationConversationId] !=
            true;
  }

  void _startPump({bool waitBeforeFirstDispatch = false}) {
    if (!_ready) return;
    if (_pump != null) {
      _pumpRestartRequested = true;
      return;
    }
    final identity = _identity;
    if (identity == null || _forwards.isEmpty) return;
    if (_authoredDispatchStarting
        .contains(_forwards.first.request.idempotencyKey)) {
      return;
    }
    if (_canonicalSettlements
        .contains(_forwards.first.request.idempotencyKey)) {
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
      _refreshAccess();
      if (_forwards.isEmpty) return;
      final forward = _forwards.first;
      if (forward.status != _QueuedForwardStatus.pending) return;
      if (_canonicalSettlements.contains(forward.request.idempotencyKey)) {
        return;
      }
      final result = await _dispatch(identity, generation, epoch, forward);
      if (!_scopeActive(identity, generation, epoch)) return;
      if (!_forwards.any((candidate) => _sameForward(candidate, forward))) {
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

  Future<ChatCommandResult<ForwardMessageResult>> _dispatch(
    ApplicationChatStorageIdentity identity,
    int generation,
    int epoch,
    _QueuedForward forward, {
    ChatCommandCancellationSignal? callerCancellation,
  }) async {
    final key = forward.request.idempotencyKey;
    final existing = _active[key];
    if (existing != null) return existing.result.future;
    if (!_scopeActive(identity, generation, epoch)) {
      return const ChatCommandClosed<ForwardMessageResult>();
    }
    final active = _ActiveForwardDispatch();
    _active[key] = active;
    StreamSubscription<void>? callerSubscription;
    if (callerCancellation != null) {
      callerSubscription = callerCancellation.onCancelled.listen((_) {
        active.cancellation.cancel();
      });
      if (callerCancellation.isCancelled) active.cancellation.cancel();
    }
    late ChatCommandResult<ForwardMessageResult> result;
    try {
      final dispatch = dispatcher.dispatch(
        _forwardMessageDescriptor(forward.request),
        forward.request,
        options: ChatCommandDispatchOptions(
          idempotencyKey: key,
          cancellationSignal: active.cancellation.signal,
        ),
      );
      result = await Future.any<ChatCommandResult<ForwardMessageResult>>([
        dispatch,
        active.canonicalResult.future,
      ]);
      if (active.canonicalResult.isCompleted) {
        active.cancellation.cancel();
        await dispatch;
      }
      if (!_scopeActive(identity, generation, epoch)) {
        result = const ChatCommandClosed<ForwardMessageResult>();
      } else {
        result = await _settleResult(
          identity,
          generation,
          epoch,
          forward,
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

  Future<ChatCommandResult<ForwardMessageResult>> _settleResult(
    ApplicationChatStorageIdentity identity,
    int generation,
    int epoch,
    _QueuedForward forward,
    ChatCommandResult<ForwardMessageResult> result,
  ) async {
    if (result case ChatCommandSuccess<ForwardMessageResult>(:final value)) {
      if (!_resultMatches(identity, forward, value)) {
        return const ChatCommandMalformedResponse<ForwardMessageResult>();
      }
      try {
        store.reconcileMessage(value.message);
      } catch (_) {
        return const ChatCommandMalformedResponse<ForwardMessageResult>();
      }
      await _remove(identity, generation, epoch, forward);
    } else if (_isTerminal(result)) {
      await _remove(identity, generation, epoch, forward);
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
      await _raceForwardWait(
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

  void _invalidateActiveDispatches() {
    _retryCancellation?.cancel();
    _retryCancellation = null;
    for (final active in _active.values) {
      active.cancellation.cancel();
    }
  }

  Future<T> _serialized<T>(Future<T> Function() operation) =>
      storageCoordinator.serialized(operation);

  static bool _sameStoredForward(
    ApplicationChatQueuedMessageMutationIntent intent,
    _QueuedForward forward,
  ) =>
      intent.request is ForwardMessageRequest &&
      intent.enqueueOrder == forward.enqueueOrder &&
      intent.enqueuedAt.value == forward.enqueuedAt.value &&
      _sameJson(
        (intent.request as ForwardMessageRequest).toJson(),
        forward.request.toJson(),
      );

  static bool _sameForward(_QueuedForward left, _QueuedForward right) =>
      left.enqueueOrder == right.enqueueOrder &&
      left.enqueuedAt == right.enqueuedAt &&
      _sameJson(left.request.toJson(), right.request.toJson());

  static bool _resultMatches(
    ApplicationChatStorageIdentity identity,
    _QueuedForward forward,
    ForwardMessageResult result,
  ) =>
      forward.identity == identity &&
      result.message.tenantId == identity.tenantId &&
      result.destinationConversationId ==
          forward.request.destinationConversationId &&
      result.message.conversationId ==
          forward.request.destinationConversationId &&
      result.clientCorrelationId == forward.request.clientCorrelationId &&
      result.message.content.forwarded?.sourceMessageId ==
          forward.request.sourceMessageId;

  static bool _isTerminal(ChatCommandResult<ForwardMessageResult> result) =>
      result is ChatCommandValidationFailure<ForwardMessageResult> ||
      result is ChatCommandAuthenticationFailure<ForwardMessageResult> ||
      result is ChatCommandConflict<ForwardMessageResult> ||
      result is ChatCommandFeatureDisabled<ForwardMessageResult> ||
      result is ChatCommandUnsupported<ForwardMessageResult> ||
      result is ChatCommandRejected<ForwardMessageResult>;

  static bool _isAmbiguous(ChatCommandResult<ForwardMessageResult> result) =>
      result is ChatCommandTransportFailure<ForwardMessageResult> ||
      result is ChatCommandMalformedResponse<ForwardMessageResult> ||
      result is ChatCommandAborted<ForwardMessageResult> ||
      result is ChatCommandClosed<ForwardMessageResult>;
}

final class _ActiveForwardDispatch {
  final ChatCommandCancellationController cancellation =
      ChatCommandCancellationController();
  final Completer<ChatCommandResult<ForwardMessageResult>> canonicalResult =
      Completer<ChatCommandResult<ForwardMessageResult>>();
  final Completer<ChatCommandResult<ForwardMessageResult>> result =
      Completer<ChatCommandResult<ForwardMessageResult>>();
}

Duration _defaultForwardMessageRetryBackoff(int retryNumber) {
  final exponent = retryNumber <= 1 ? 0 : (retryNumber - 1).clamp(0, 5);
  return Duration(seconds: 1 << exponent);
}

Future<void> _defaultForwardMessageRetryWait(
  Duration delay,
  ChatCommandCancellationSignal _,
) =>
    Future<void>.delayed(delay);

Future<void> _raceForwardWait(
  Future<void> future,
  ChatCommandCancellationSignal signal,
) {
  if (signal.isCancelled) {
    return Future<void>.error(const _ForwardWaitInterrupted());
  }
  final completer = Completer<void>();
  late final StreamSubscription<void> subscription;
  subscription = signal.onCancelled.listen((_) {
    if (!completer.isCompleted) {
      completer.completeError(const _ForwardWaitInterrupted());
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

final class _ForwardWaitInterrupted implements Exception {
  const _ForwardWaitInterrupted();
}
