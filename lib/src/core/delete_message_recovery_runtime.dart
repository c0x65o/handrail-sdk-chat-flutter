part of '../handrail_chat_client.dart';

/// Injectable wall clock used for durable delete FIFO metadata.
typedef ChatMessageDeleteClock = DateTime Function();

/// Computes the bounded delay before replaying an ambiguous retained delete.
typedef ChatMessageDeleteRetryBackoff = Duration Function(int retryNumber);

/// Injectable wait boundary for deterministic retained-delete recovery tests.
typedef ChatMessageDeleteRetryWait = Future<void> Function(
  Duration delay,
  ChatCommandCancellationSignal cancellationSignal,
);

/// Recovery state for one identity-scoped durable delete.
enum ChatQueuedMessageDeleteStatus {
  waitingForCanonicalBase,
  pending,
  revisionConflict,
  settlingCanonicalDeletion,
}

/// A credential-free view of one retained message delete.
final class ChatQueuedMessageDelete {
  const ChatQueuedMessageDelete._({
    required this.identity,
    required this.request,
    required this.enqueueOrder,
    required this.enqueuedAt,
    required this.status,
  });

  final ApplicationChatStorageIdentity identity;
  final SoftDeleteMessageRequest request;
  final int enqueueOrder;
  final DateTime enqueuedAt;
  final ChatQueuedMessageDeleteStatus status;
}

final class _MessageDeleteRecoveryRuntime {
  _MessageDeleteRecoveryRuntime({
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
      // A synchronous store listener cannot publish another store commit.
      // Defer restoration until the authoritative commit has finished.
      scheduleMicrotask(() {
        if (_closed) return;
        _refreshProjections();
        _startPump();
      });
    });
  }

  final ApplicationChatStorage storage;
  final _MessageMutationIntentStorageCoordinator storageCoordinator;
  final ChatCommandDispatcher dispatcher;
  final NormalizedSnapshotStore store;
  final ChatMessageDeleteClock clock;
  final ChatMessageDeleteRetryBackoff backoff;
  final ChatMessageDeleteRetryWait wait;
  final bool lifecycleManaged;
  final void Function(String code, String message) onStorageDiagnostic;

  final List<ChatQueuedMessageDelete> _deletes = <ChatQueuedMessageDelete>[];
  final Map<String, _ActiveMessageDeleteDispatch> _active = {};
  final Set<String> _authoredDispatchStarting = <String>{};
  final Set<String> _canonicalSettlements = <String>{};
  final Set<String> _projectedKeys = <String>{};
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

  List<ChatQueuedMessageDelete> get deletes => List.unmodifiable(_deletes);

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
    _projectedKeys.clear();
    _identity = identity;
    _generation = generation;
    ++_epoch;
    _deletes.clear();
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
      } on FormatException {
        if (!_scopeActive(identity, generation, epoch)) return;
        onStorageDiagnostic(
          ChatClientDiagnosticCode.messageMutationIntentsRejected,
          'The stored message-mutation intents were rejected and quarantined.',
        );
        try {
          // The mutator quarantines only the exact rejected bytes. A competing
          // writer may already have installed a valid queue; hydrate that value.
          record = await _readRecord(identity);
        } catch (_) {
          if (_scopeActive(identity, generation, epoch)) {
            onStorageDiagnostic(
              ChatClientDiagnosticCode.messageMutationIntentsQuarantineFailed,
              'The rejected message-mutation intents could not be quarantined.',
            );
          }
          return;
        }
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

  Future<ChatCommandResult<SoftDeleteMessageResult>> execute(
    SoftDeleteMessageRequest request, {
    ChatCommandCancellationSignal? cancellationSignal,
  }) async {
    if (_closed) return const ChatCommandClosed<SoftDeleteMessageResult>();
    if (cancellationSignal?.isCancelled == true) {
      return const ChatCommandAborted<SoftDeleteMessageResult>();
    }
    final identity = _identity;
    final generation = _generation;
    final epoch = _epoch;
    if (identity == null || !_hasExactCanonicalBase(request)) {
      return const ChatCommandValidationFailure<SoftDeleteMessageResult>();
    }
    if (_deletes.any(
      (delete) => delete.request.messageId == request.messageId,
    )) {
      return const ChatCommandValidationFailure<SoftDeleteMessageResult>();
    }
    final stored = await _persist(identity, generation, epoch, request);
    if (stored == null) {
      return !_scopeActive(identity, generation, epoch)
          ? const ChatCommandClosed<SoftDeleteMessageResult>()
          : const ChatCommandValidationFailure<SoftDeleteMessageResult>();
    }
    if (!_scopeActive(identity, generation, epoch)) {
      return const ChatCommandClosed<SoftDeleteMessageResult>();
    }
    if (cancellationSignal?.isCancelled == true) {
      await _remove(identity, generation, epoch, stored);
      return const ChatCommandAborted<SoftDeleteMessageResult>();
    }

    final key = stored.request.idempotencyKey;
    _authoredDispatchStarting.add(key);
    late final ChatCommandResult<SoftDeleteMessageResult> result;
    try {
      if (!_project(stored)) {
        final canonical = store.state.canonicalMessages[request.messageId];
        if (canonical is DeletedMessage ||
            (canonical is ActiveMessage &&
                canonical.revision.revision > request.expectedRevision)) {
          await _settleCanonicalAuthority(
            identity,
            generation,
            epoch,
            stored,
            canonical!,
          );
          return const ChatCommandConflict<SoftDeleteMessageResult>(
            httpStatus: 409,
          );
        }
        return const ChatCommandTransportFailure<SoftDeleteMessageResult>();
      }
      if (cancellationSignal?.isCancelled == true) {
        _rollback(stored);
        await _remove(identity, generation, epoch, stored);
        return const ChatCommandAborted<SoftDeleteMessageResult>();
      }
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
    if (_closed || event is! MessageDeletedDurableEvent) return;
    final identity = _identity;
    final generation = _generation;
    final epoch = _epoch;
    if (identity == null || event.tenantId != identity.tenantId) return;
    late final DeletedMessage message;
    try {
      final parsed = Message.fromJson(event.payload.data['message']);
      if (parsed is! DeletedMessage) return;
      message = parsed;
    } catch (_) {
      return;
    }
    final matches = _deletes
        .where((delete) => delete.request.messageId == message.id)
        .toList(growable: false);
    for (final delete in matches) {
      if (!_scopeActive(identity, generation, epoch)) return;
      await _settleCanonicalAuthority(
        identity,
        generation,
        epoch,
        delete,
        message,
      );
    }
    _refreshProjections();
    _startPump();
  }

  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    ++_epoch;
    _invalidateActiveDispatches();
    await _storeSubscription.cancel();
  }

  bool _hasExactCanonicalBase(SoftDeleteMessageRequest request) {
    final message = store.state.canonicalMessages[request.messageId];
    return message is ActiveMessage &&
        message.revision.revision == request.expectedRevision;
  }

  Future<ChatQueuedMessageDelete?> _persist(
    ApplicationChatStorageIdentity identity,
    int generation,
    int epoch,
    SoftDeleteMessageRequest request,
  ) =>
      _serialized<ChatQueuedMessageDelete?>(() async {
        if (!_scopeActive(identity, generation, epoch)) return null;
        try {
          ApplicationChatQueuedMessageMutationIntent? appended;
          final committed = await _mutateRecord(identity, (current) {
            // This updater may run again after contention. Recompute both lane
            // occupancy and FIFO order from that attempt's current record.
            appended = null;
            if (!_scopeActive(identity, generation, epoch)) return current;
            final messageLaneOccupied = current?.intents.any(
                  (intent) => switch (intent.request) {
                    EditMessageRequest(:final messageId) ||
                    SoftDeleteMessageRequest(:final messageId) =>
                      messageId == request.messageId,
                    _ => false,
                  },
                ) ??
                false;
            if (messageLaneOccupied) return current;
            final highest = current?.intents.fold<int>(
                  0,
                  (value, intent) => max(value, intent.enqueueOrder),
                ) ??
                0;
            final intent = ApplicationChatQueuedMessageMutationIntent(
              request: request,
              enqueueOrder: highest + 1,
              enqueuedAt: IsoTimestamp(clock().toUtc().toIso8601String()),
            );
            appended = intent;
            return ApplicationChatQueuedMessageMutationIntentsRecord(
              identity: identity,
              intents: <ApplicationChatQueuedMessageMutationIntent>[
                ...?current?.intents,
                intent,
              ],
            );
          });
          if (!_scopeActive(identity, generation, epoch)) return null;
          _publish(committed);
          final stored = appended;
          if (stored == null) return null;
          for (final delete in _deletes) {
            if (_sameStoredDelete(stored, delete)) return delete;
          }
          return null;
        } catch (_) {
          if (_scopeActive(identity, generation, epoch)) {
            onStorageDiagnostic(
              ChatClientDiagnosticCode.messageMutationIntentsWriteFailed,
              'The message delete could not be stored before dispatch.',
            );
          }
          return null;
        }
      });

  Future<bool> _remove(
    ApplicationChatStorageIdentity identity,
    int generation,
    int epoch,
    ChatQueuedMessageDelete delete,
  ) =>
      _serialized<bool>(() async {
        if (!_scopeActive(identity, generation, epoch)) return false;
        try {
          final committed = await _mutateRecord(identity, (current) {
            if (!_scopeActive(identity, generation, epoch) || current == null) {
              return current;
            }
            final remaining = current.intents
                .where((intent) => !_sameStoredDelete(intent, delete))
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
          // Absence is settled, but the same correlation with different stored
          // identity belongs to a replacement and cannot settle this dispatch.
          return !(committed?.intents.any(
                (intent) =>
                    intent.request is SoftDeleteMessageRequest &&
                    (intent.request as SoftDeleteMessageRequest)
                            .idempotencyKey ==
                        delete.request.idempotencyKey,
              ) ??
              false);
        } catch (_) {
          if (_scopeActive(identity, generation, epoch)) {
            onStorageDiagnostic(
              ChatClientDiagnosticCode.messageMutationIntentsWriteFailed,
              'A settled message delete could not be removed from storage.',
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
    final previous = <String, ChatQueuedMessageDelete>{
      for (final delete in _deletes) _deleteStorageKey(delete): delete,
    };
    _deletes
      ..clear()
      ..addAll(<ChatQueuedMessageDelete>[
        for (final intent in record?.intents ??
            const <ApplicationChatQueuedMessageMutationIntent>[])
          if (intent.request case final SoftDeleteMessageRequest request)
            ChatQueuedMessageDelete._(
              identity: identity,
              request: request,
              enqueueOrder: intent.enqueueOrder,
              enqueuedAt: DateTime.parse(intent.enqueuedAt.value).toUtc(),
              status: previous[_storedDeleteKey(intent)]?.status ??
                  ChatQueuedMessageDeleteStatus.waitingForCanonicalBase,
            ),
      ]);
  }

  void _refreshProjections() {
    if (_closed) return;
    for (var index = 0; index < _deletes.length; index += 1) {
      final delete = _deletes[index];
      final message = store.state.canonicalMessages[delete.request.messageId];
      var status = delete.status;
      if (_projectedKeys.contains(delete.request.idempotencyKey)) {
        if (message is ActiveMessage &&
            message.revision.revision > delete.request.expectedRevision) {
          status = ChatQueuedMessageDeleteStatus.revisionConflict;
          _replaceStatus(index, delete, status);
          _scheduleCanonicalSettlement(delete, message);
        }
        continue;
      }
      if (message is DeletedMessage) {
        status = ChatQueuedMessageDeleteStatus.settlingCanonicalDeletion;
        _replaceStatus(index, delete, status);
        _scheduleCanonicalSettlement(delete, message);
      } else if (message == null || message is! ActiveMessage) {
        status = ChatQueuedMessageDeleteStatus.waitingForCanonicalBase;
      } else if (message.revision.revision < delete.request.expectedRevision) {
        status = ChatQueuedMessageDeleteStatus.waitingForCanonicalBase;
      } else if (message.revision.revision > delete.request.expectedRevision) {
        status = ChatQueuedMessageDeleteStatus.revisionConflict;
        _replaceStatus(index, delete, status);
        _scheduleCanonicalSettlement(delete, message);
      } else if (status != ChatQueuedMessageDeleteStatus.pending) {
        status = _project(delete)
            ? ChatQueuedMessageDeleteStatus.pending
            : ChatQueuedMessageDeleteStatus.waitingForCanonicalBase;
      }
      _replaceStatus(index, delete, status);
    }
  }

  void _replaceStatus(
    int index,
    ChatQueuedMessageDelete delete,
    ChatQueuedMessageDeleteStatus status,
  ) {
    if (status == delete.status || index >= _deletes.length) return;
    _deletes[index] = ChatQueuedMessageDelete._(
      identity: delete.identity,
      request: delete.request,
      enqueueOrder: delete.enqueueOrder,
      enqueuedAt: delete.enqueuedAt,
      status: status,
    );
  }

  bool _project(ChatQueuedMessageDelete delete) {
    if (delete.status == ChatQueuedMessageDeleteStatus.pending) return true;
    if (!_hasExactCanonicalBase(delete.request)) return false;
    final index = _deletes.indexWhere(
      (candidate) =>
          candidate.request.idempotencyKey == delete.request.idempotencyKey,
    );
    if (index < 0) return false;
    final pending = ChatQueuedMessageDelete._(
      identity: delete.identity,
      request: delete.request,
      enqueueOrder: delete.enqueueOrder,
      enqueuedAt: delete.enqueuedAt,
      status: ChatQueuedMessageDeleteStatus.pending,
    );
    _deletes[index] = pending;
    _projectedKeys.add(delete.request.idempotencyKey);
    try {
      store.beginOptimisticMessageDelete(delete.request);
      return true;
    } catch (_) {
      _projectedKeys.remove(delete.request.idempotencyKey);
      if (index < _deletes.length && identical(_deletes[index], pending)) {
        _deletes[index] = delete;
      }
      return false;
    }
  }

  void _scheduleCanonicalSettlement(
    ChatQueuedMessageDelete delete,
    Message canonical,
  ) {
    final identity = _identity;
    if (identity == null) return;
    final key = _deleteStorageKey(delete);
    if (!_canonicalSettlements.add(key)) return;
    final generation = _generation;
    final epoch = _epoch;
    unawaited(
      _settleCanonicalAuthority(
        identity,
        generation,
        epoch,
        delete,
        canonical,
      ).whenComplete(() => _canonicalSettlements.remove(key)),
    );
  }

  Future<void> _settleCanonicalAuthority(
    ApplicationChatStorageIdentity identity,
    int generation,
    int epoch,
    ChatQueuedMessageDelete delete,
    Message canonical,
  ) async {
    _rollback(delete);
    final removed = await _remove(identity, generation, epoch, delete);
    if (!removed || !_scopeActive(identity, generation, epoch)) return;
    final active = _active[delete.request.idempotencyKey];
    if (active == null || active.canonicalResult.isCompleted) return;
    if (canonical is DeletedMessage &&
        canonical.revision.revision == delete.request.expectedRevision + 1) {
      active.canonicalResult.complete(
        ChatCommandSuccess<SoftDeleteMessageResult>(
          SoftDeleteMessageResult.fromJson(<String, Object?>{
            'operation': 'soft_delete',
            'reconciliationStatus': 'applied',
            'expectedRevision': delete.request.expectedRevision,
            'message': canonical.toJson(),
            'canonicalRevision': canonical.revision.revision,
          }),
        ),
      );
    } else {
      active.canonicalResult.complete(
        const ChatCommandConflict<SoftDeleteMessageResult>(httpStatus: 409),
      );
    }
    active.cancellation.cancel();
  }

  void _startPump({bool waitBeforeFirstDispatch = false}) {
    if (!_ready) return;
    if (_pump != null) {
      _pumpRestartRequested = true;
      return;
    }
    final identity = _identity;
    if (identity == null || _deletes.isEmpty) return;
    if (_authoredDispatchStarting
        .contains(_deletes.first.request.idempotencyKey)) {
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
      if (_deletes.isEmpty) return;
      final delete = _deletes.first;
      if (delete.status != ChatQueuedMessageDeleteStatus.pending) return;
      final result = await _dispatch(identity, generation, epoch, delete);
      if (!_scopeActive(identity, generation, epoch)) return;
      if (!_deletes.any((candidate) => _sameDelete(candidate, delete))) {
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

  Future<ChatCommandResult<SoftDeleteMessageResult>> _dispatch(
    ApplicationChatStorageIdentity identity,
    int generation,
    int epoch,
    ChatQueuedMessageDelete delete, {
    ChatCommandCancellationSignal? callerCancellation,
  }) async {
    final key = delete.request.idempotencyKey;
    final existing = _active[key];
    if (existing != null) return existing.result.future;
    if (!_scopeActive(identity, generation, epoch)) {
      return const ChatCommandClosed<SoftDeleteMessageResult>();
    }
    final active = _ActiveMessageDeleteDispatch();
    _active[key] = active;
    StreamSubscription<void>? callerSubscription;
    if (callerCancellation != null) {
      callerSubscription = callerCancellation.onCancelled.listen((_) {
        active.cancellation.cancel();
      });
      if (callerCancellation.isCancelled) active.cancellation.cancel();
    }
    late ChatCommandResult<SoftDeleteMessageResult> result;
    try {
      final dispatch = dispatcher.dispatch(
        _deleteMessageDescriptor,
        delete.request,
        options: ChatCommandDispatchOptions(
          idempotencyKey: key,
          cancellationSignal: active.cancellation.signal,
        ),
      );
      result = await Future.any<ChatCommandResult<SoftDeleteMessageResult>>([
        dispatch,
        active.canonicalResult.future,
      ]);
      if (active.canonicalResult.isCompleted) {
        active.cancellation.cancel();
        await dispatch;
      }
      if (!_scopeActive(identity, generation, epoch)) {
        result = const ChatCommandClosed<SoftDeleteMessageResult>();
      } else {
        result = await _settleResult(
          identity,
          generation,
          epoch,
          delete,
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

  Future<ChatCommandResult<SoftDeleteMessageResult>> _settleResult(
    ApplicationChatStorageIdentity identity,
    int generation,
    int epoch,
    ChatQueuedMessageDelete delete,
    ChatCommandResult<SoftDeleteMessageResult> result,
  ) async {
    if (result case ChatCommandSuccess<SoftDeleteMessageResult>(:final value)) {
      if (!_resultMatches(identity, delete, value)) {
        return ChatCommandMalformedResponse<SoftDeleteMessageResult>();
      }
      try {
        _projectedKeys.remove(delete.request.idempotencyKey);
        store.reconcileOptimisticMessageDelete(
          delete.request.idempotencyKey,
          value,
        );
      } catch (_) {
        _projectedKeys.add(delete.request.idempotencyKey);
        return ChatCommandMalformedResponse<SoftDeleteMessageResult>();
      }
      await _remove(identity, generation, epoch, delete);
    } else if (_isTerminal(result)) {
      _rollback(delete);
      await _remove(identity, generation, epoch, delete);
    }
    return result;
  }

  void _rollback(ChatQueuedMessageDelete delete) {
    _projectedKeys.remove(delete.request.idempotencyKey);
    try {
      store.rollbackOptimisticMessageDelete(
        delete.request.messageId,
        delete.request.idempotencyKey,
      );
    } on StateError {
      // An externally owned store may close before the client.
    }
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
      await _raceMessageDeleteWait(
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

  static bool _sameStoredDelete(
    ApplicationChatQueuedMessageMutationIntent intent,
    ChatQueuedMessageDelete delete,
  ) =>
      intent.request is SoftDeleteMessageRequest &&
      intent.enqueueOrder == delete.enqueueOrder &&
      DateTime.parse(intent.enqueuedAt.value)
          .toUtc()
          .isAtSameMomentAs(delete.enqueuedAt) &&
      _sameJson(
        (intent.request as SoftDeleteMessageRequest).toJson(),
        delete.request.toJson(),
      );

  static bool _sameDelete(
    ChatQueuedMessageDelete left,
    ChatQueuedMessageDelete right,
  ) =>
      left.enqueueOrder == right.enqueueOrder &&
      left.enqueuedAt == right.enqueuedAt &&
      _sameJson(left.request.toJson(), right.request.toJson());

  static String _deleteStorageKey(ChatQueuedMessageDelete delete) =>
      '${delete.enqueueOrder}:${delete.enqueuedAt.toIso8601String()}:'
      '${jsonEncode(delete.request.toJson())}';

  static String _storedDeleteKey(
    ApplicationChatQueuedMessageMutationIntent intent,
  ) =>
      '${intent.enqueueOrder}:'
      '${DateTime.parse(intent.enqueuedAt.value).toUtc().toIso8601String()}:'
      '${jsonEncode((intent.request as SoftDeleteMessageRequest).toJson())}';

  static bool _resultMatches(
    ApplicationChatStorageIdentity identity,
    ChatQueuedMessageDelete delete,
    SoftDeleteMessageResult result,
  ) =>
      result.expectedRevision == delete.request.expectedRevision &&
      result.message.id == delete.request.messageId &&
      result.message.tenantId == identity.tenantId;

  static bool _isTerminal(
    ChatCommandResult<SoftDeleteMessageResult> result,
  ) =>
      result is ChatCommandValidationFailure<SoftDeleteMessageResult> ||
      result is ChatCommandAuthenticationFailure<SoftDeleteMessageResult> ||
      result is ChatCommandConflict<SoftDeleteMessageResult> ||
      result is ChatCommandFeatureDisabled<SoftDeleteMessageResult> ||
      result is ChatCommandUnsupported<SoftDeleteMessageResult> ||
      (result is ChatCommandRejected<SoftDeleteMessageResult> &&
          result.httpStatus != 429);

  static bool _isAmbiguous(
    ChatCommandResult<SoftDeleteMessageResult> result,
  ) =>
      result is ChatCommandTransportFailure<SoftDeleteMessageResult> ||
      result is ChatCommandMalformedResponse<SoftDeleteMessageResult> ||
      result is ChatCommandAborted<SoftDeleteMessageResult> ||
      result is ChatCommandClosed<SoftDeleteMessageResult> ||
      (result is ChatCommandRejected<SoftDeleteMessageResult> &&
          result.httpStatus == 429);
}

final class _ActiveMessageDeleteDispatch {
  final ChatCommandCancellationController cancellation =
      ChatCommandCancellationController();
  final Completer<ChatCommandResult<SoftDeleteMessageResult>> canonicalResult =
      Completer<ChatCommandResult<SoftDeleteMessageResult>>();
  final Completer<ChatCommandResult<SoftDeleteMessageResult>> result =
      Completer<ChatCommandResult<SoftDeleteMessageResult>>();
}

Duration _defaultMessageDeleteRetryBackoff(int retryNumber) {
  final exponent = retryNumber <= 1 ? 0 : (retryNumber - 1).clamp(0, 5);
  return Duration(seconds: 1 << exponent);
}

Future<void> _defaultMessageDeleteRetryWait(
  Duration delay,
  ChatCommandCancellationSignal _,
) =>
    Future<void>.delayed(delay);

Future<void> _raceMessageDeleteWait(
  Future<void> future,
  ChatCommandCancellationSignal signal,
) {
  if (signal.isCancelled) {
    return Future<void>.error(const _MessageDeleteWaitInterrupted());
  }
  final completer = Completer<void>();
  late final StreamSubscription<void> subscription;
  subscription = signal.onCancelled.listen((_) {
    if (!completer.isCompleted) {
      completer.completeError(const _MessageDeleteWaitInterrupted());
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

final class _MessageDeleteWaitInterrupted implements Exception {
  const _MessageDeleteWaitInterrupted();
}
