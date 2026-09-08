part of '../handrail_chat_client.dart';

typedef ChatConversationArchiveClock = IsoTimestamp Function();

IsoTimestamp _currentConversationArchiveTime() =>
    IsoTimestamp(DateTime.now().toUtc().toIso8601String());

/// Computes the delay before replaying an ambiguously settled archive change.
typedef ChatConversationArchiveRetryBackoff = Duration Function(
  int retryNumber,
);

/// Injectable wait boundary for deterministic archive recovery tests.
typedef ChatConversationArchiveRetryWait = Future<void> Function(
  Duration delay,
  ChatCommandCancellationSignal cancellationSignal,
);

/// Recovery state for one identity-scoped archive or restore command.
enum ChatQueuedConversationArchiveStatus {
  waitingForCanonicalBase,
  pending,
  lifecycleConflict,
}

/// Credential-free view of one retained conversation lifecycle command.
final class ChatQueuedConversationArchive {
  const ChatQueuedConversationArchive._({
    required this.identity,
    required this.request,
    required this.enqueueOrder,
    required this.enqueuedAt,
    required this.status,
  });

  final ApplicationChatStorageIdentity identity;
  final ConversationArchiveInput request;
  final int enqueueOrder;
  final DateTime enqueuedAt;
  final ChatQueuedConversationArchiveStatus status;
}

/// Authored fields accepted by archive and restore commands.
final class ChatSetConversationArchiveInput {
  const ChatSetConversationArchiveInput({
    required this.conversationId,
    required this.expectedLifecycleRevision,
    this.idempotencyKey,
  });

  final ConversationId conversationId;
  final int expectedLifecycleRevision;
  final String? idempotencyKey;
}

final class _ConversationArchiveCommandIntent {
  _ConversationArchiveCommandIntent({
    required this.request,
    required this.cancellationSignal,
  });

  final ConversationArchiveInput request;
  final ChatCommandCancellationSignal? cancellationSignal;
  final Completer<ChatCommandResult<ConversationArchiveResult>> completer =
      Completer();
  StreamSubscription<void>? cancellationSubscription;
}

final class _ConversationArchiveCommandLane {
  final List<_ConversationArchiveCommandIntent> intents = [];
  _ConversationArchiveCommandIntent? active;
  bool draining = false;
}

ChatCommandDescriptor<ConversationArchiveInput, ConversationArchiveInput,
    ConversationArchiveResult> _conversationArchiveDescriptor(
  ConversationArchiveInput request,
) =>
    ChatCommandDescriptor.withPathBuilder(
      name: 'conversation.archive.${request.intent.toJson()}',
      method: ChatCommandMethod.patch,
      pathBuilder: (input) =>
          '/conversations/${Uri.encodeComponent(input.conversationId.value)}/lifecycle',
      retrySafety: ChatCommandRetrySafety.safe,
      validateInput: (input) =>
          ConversationArchiveInput.fromJson(input.toJson()),
      parseResult: (json) => ConversationArchiveResult.fromJson(
        json,
        expectedInput: request,
      ),
      parseErrorResult: (json, httpStatus) {
        if (httpStatus != 409) return null;
        final result = ConversationArchiveResult.fromJson(
          json,
          expectedInput: request,
        );
        return result.reconciliationStatus ==
                ConversationArchiveReconciliationStatus.lifecycleConflict
            ? result
            : null;
      },
    );

final class _ConversationArchiveRecoveryRuntime {
  _ConversationArchiveRecoveryRuntime({
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
  final ChatConversationArchiveClock clock;
  final ChatConversationArchiveRetryBackoff backoff;
  final ChatConversationArchiveRetryWait wait;
  final bool lifecycleManaged;
  final void Function(String code, String message) onStorageDiagnostic;

  final List<ChatQueuedConversationArchive> _intents = [];
  final Map<String, _ActiveConversationArchiveDispatch> _active = {};
  final Map<String,
          List<Completer<ChatCommandResult<ConversationArchiveResult>>>>
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

  List<ChatQueuedConversationArchive> get intents =>
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
    final previous = _intents.toList(growable: false);
    _invalidateDispatches();
    _completeAll(const ChatCommandClosed<ConversationArchiveResult>());
    _identity = identity;
    _generation = generation;
    ++_epoch;
    _intents.clear();
    for (final intent in previous) {
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
      ApplicationChatQueuedConversationArchiveIntentsRecord? record;
      try {
        record = await _readRecord(identity);
        if (!_scopeActive(identity, generation, epoch)) return;
      } on FormatException {
        if (!_scopeActive(identity, generation, epoch)) return;
        onStorageDiagnostic(
          ChatClientDiagnosticCode.conversationArchiveIntentsRejected,
          'The stored conversation-archive intents were rejected and quarantined.',
        );
        return;
      } catch (_) {
        if (_scopeActive(identity, generation, epoch)) {
          onStorageDiagnostic(
            ChatClientDiagnosticCode.conversationArchiveIntentsReadFailed,
            'The stored conversation-archive intents could not be read.',
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

  Future<ChatCommandResult<ConversationArchiveResult>> execute(
    ConversationArchiveInput request, {
    ChatCommandCancellationSignal? cancellationSignal,
  }) async {
    if (_closed) return const ChatCommandClosed<ConversationArchiveResult>();
    if (cancellationSignal?.isCancelled == true) {
      return const ChatCommandAborted<ConversationArchiveResult>();
    }
    final identity = _identity;
    final generation = _generation;
    final epoch = _epoch;
    if (identity == null) {
      return const ChatCommandValidationFailure<ConversationArchiveResult>();
    }
    final stored = await _persist(identity, generation, epoch, request);
    if (stored == null) {
      return !_scopeActive(identity, generation, epoch)
          ? const ChatCommandClosed<ConversationArchiveResult>()
          : const ChatCommandValidationFailure<ConversationArchiveResult>();
    }
    if (!_scopeActive(identity, generation, epoch)) {
      return const ChatCommandClosed<ConversationArchiveResult>();
    }
    if (cancellationSignal?.isCancelled == true) {
      await _remove(identity, generation, epoch, stored);
      return const ChatCommandAborted<ConversationArchiveResult>();
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
    if (_closed ||
        (event is! ConversationArchivedDurableEvent &&
            event is! ConversationRestoredDurableEvent)) {
      return;
    }
    final identity = _identity;
    final generation = _generation;
    final epoch = _epoch;
    if (identity == null ||
        event.tenantId != identity.tenantId ||
        event.streamId.isEmpty) {
      return;
    }
    late final ConversationId conversationId;
    late final int revision;
    try {
      conversationId = ConversationId.fromJson(
        event.payload.data['conversationId'],
      );
      revision = event.payload.data['currentLifecycleRevision']! as int;
      if (event.streamId != conversationId.value) return;
    } catch (_) {
      return;
    }
    final desiredArchived = event is ConversationArchivedDurableEvent;
    ChatQueuedConversationArchive? intent;
    for (final candidate in _intents) {
      if (candidate.request.conversationId == conversationId &&
          _desiredArchived(candidate.request) == desiredArchived &&
          revision >= candidate.request.expectedLifecycleRevision) {
        intent = candidate;
        break;
      }
    }
    if (intent == null || !_scopeActive(identity, generation, epoch)) return;
    final removed = await _remove(identity, generation, epoch, intent);
    if (!removed || !_scopeActive(identity, generation, epoch)) return;
    _rollback(intent);
    final result = _canonicalSettlementResult(intent.request);
    final active = _active[intent.request.idempotencyKey];
    if (active != null) {
      if (result != null && !active.canonicalResult.isCompleted) {
        active.canonicalResult.complete(result);
      }
      active.cancellation.cancel();
    }
    _complete(
      intent.request.idempotencyKey,
      result ?? const ChatCommandClosed<ConversationArchiveResult>(),
    );
    _startLane(conversationId);
  }

  Future<void> close() async {
    if (_closed) return;
    final previous = _intents.toList(growable: false);
    _closed = true;
    ++_epoch;
    _invalidateDispatches();
    for (final intent in previous) {
      _rollback(intent);
    }
    _completeAll(const ChatCommandClosed<ConversationArchiveResult>());
    await _storeSubscription.cancel();
  }

  Future<void> _cancelBeforeDispatch(
    ApplicationChatStorageIdentity identity,
    int generation,
    int epoch,
    ChatQueuedConversationArchive intent,
  ) async {
    if (_active.containsKey(intent.request.idempotencyKey)) return;
    final removed = await _remove(identity, generation, epoch, intent);
    if (removed && _scopeActive(identity, generation, epoch)) {
      _rollback(intent);
      _complete(
        intent.request.idempotencyKey,
        const ChatCommandAborted<ConversationArchiveResult>(),
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
    if (head.status != ChatQueuedConversationArchiveStatus.pending &&
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
        final result = _canonicalSettlementResult(intent.request);
        final removed = await _remove(identity, generation, epoch, intent);
        if (removed && _scopeActive(identity, generation, epoch)) {
          _rollback(intent);
          _complete(
            intent.request.idempotencyKey,
            result ?? const ChatCommandClosed<ConversationArchiveResult>(),
          );
        }
        retryNumber = 0;
        continue;
      }
      if (intent.status != ChatQueuedConversationArchiveStatus.pending) return;

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

  Future<ChatCommandResult<ConversationArchiveResult>> _dispatch(
    ApplicationChatStorageIdentity identity,
    int generation,
    int epoch,
    ChatQueuedConversationArchive intent,
  ) async {
    final key = intent.request.idempotencyKey;
    final existing = _active[key];
    if (existing != null) return existing.result.future;
    if (!_scopeActive(identity, generation, epoch)) {
      return const ChatCommandClosed<ConversationArchiveResult>();
    }
    final active = _ActiveConversationArchiveDispatch();
    _active[key] = active;
    late ChatCommandResult<ConversationArchiveResult> result;
    try {
      final dispatch = dispatcher.dispatch(
        _conversationArchiveDescriptor(intent.request),
        intent.request,
        options: ChatCommandDispatchOptions(
          idempotencyKey: key,
          cancellationSignal: active.cancellation.signal,
        ),
      );
      result = await Future.any([dispatch, active.canonicalResult.future]);
      if (active.canonicalResult.isCompleted) {
        active.cancellation.cancel();
        await dispatch;
      }
      if (!_scopeActive(identity, generation, epoch)) {
        result = const ChatCommandClosed<ConversationArchiveResult>();
      } else if (!_contains(intent)) {
        // A matching canonical event settled and removed this intent while the
        // HTTP request was in flight.
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

  Future<ChatCommandResult<ConversationArchiveResult>> _settleResult(
    ApplicationChatStorageIdentity identity,
    int generation,
    int epoch,
    ChatQueuedConversationArchive intent,
    ChatCommandResult<ConversationArchiveResult> result,
  ) async {
    if (result
        case ChatCommandSuccess<ConversationArchiveResult>(:final value)) {
      try {
        if (value.reconciliationStatus ==
            ConversationArchiveReconciliationStatus.lifecycleConflict) {
          store.reconcileOptimisticConversationArchive(
            intent.request.idempotencyKey,
            value,
          );
          _refreshProjections();
          return result;
        }
        store.reconcileOptimisticConversationArchive(
          intent.request.idempotencyKey,
          value,
        );
      } catch (_) {
        return const ChatCommandMalformedResponse<ConversationArchiveResult>();
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

  Future<ChatQueuedConversationArchive?> _persist(
    ApplicationChatStorageIdentity identity,
    int generation,
    int epoch,
    ConversationArchiveInput request,
  ) =>
      _serialized(() async {
        if (!_scopeActive(identity, generation, epoch)) return null;
        try {
          final superseded = _head(request.conversationId);
          final committed = await _mutateRecord(identity, (current) {
            if (!_scopeActive(identity, generation, epoch)) return current;
            final highest = current?.intents.fold<int>(
                  0,
                  (value, intent) => max(value, intent.enqueueOrder),
                ) ??
                0;
            // Coalesce against each attempt's record, preserving the existing
            // conversation's enqueue metadata and unrelated conversations.
            return ApplicationChatQueuedConversationArchiveIntentsRecord(
              identity: identity,
              intents: [
                ...?current?.intents,
                ApplicationChatQueuedConversationArchiveIntent(
                  request: request,
                  enqueueOrder: highest + 1,
                  enqueuedAt: clock(),
                ),
              ],
            );
          });
          if (!_scopeActive(identity, generation, epoch)) return null;
          _publish(committed);
          if (superseded != null &&
              superseded.request.idempotencyKey != request.idempotencyKey) {
            _rollback(superseded);
            final active = _active[superseded.request.idempotencyKey];
            if (active != null && !active.canonicalResult.isCompleted) {
              active.canonicalResult.complete(
                const ChatCommandClosed<ConversationArchiveResult>(),
              );
              active.cancellation.cancel();
            }
            _complete(
              superseded.request.idempotencyKey,
              const ChatCommandClosed<ConversationArchiveResult>(),
            );
          }
          return _intents.cast<ChatQueuedConversationArchive?>().firstWhere(
                (intent) =>
                    intent?.request.idempotencyKey == request.idempotencyKey,
                orElse: () => null,
              );
        } catch (_) {
          if (_scopeActive(identity, generation, epoch)) {
            onStorageDiagnostic(
              ChatClientDiagnosticCode.conversationArchiveIntentsWriteFailed,
              'The conversation-archive command could not be stored before dispatch.',
            );
          }
          return null;
        }
      });

  Future<bool> _remove(
    ApplicationChatStorageIdentity identity,
    int generation,
    int epoch,
    ChatQueuedConversationArchive intent,
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
                : ApplicationChatQueuedConversationArchiveIntentsRecord(
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
              ChatClientDiagnosticCode.conversationArchiveIntentsWriteFailed,
              'A settled conversation-archive command could not be removed from storage.',
            );
          }
          return false;
        }
      });

  Future<ApplicationChatQueuedConversationArchiveIntentsRecord?> _readRecord(
    ApplicationChatStorageIdentity identity,
  ) =>
      _mutateRecord(identity, (current) => current);

  Future<ApplicationChatQueuedConversationArchiveIntentsRecord?> _mutateRecord(
    ApplicationChatStorageIdentity identity,
    ApplicationChatStorageUpdater<
            ApplicationChatQueuedConversationArchiveIntentsRecord>
        updater,
  ) =>
      ApplicationChatStorageMutator(storage)
          .mutate<ApplicationChatQueuedConversationArchiveIntentsRecord>(
        identity,
        ApplicationChatStorageRecordKind.queuedConversationArchiveIntents,
        updater,
      );

  void _publish(
    ApplicationChatQueuedConversationArchiveIntentsRecord? record,
  ) {
    final identity = _identity;
    if (identity == null) return;
    _intents
      ..clear()
      ..addAll([
        for (final intent in record?.intents ??
            const <ApplicationChatQueuedConversationArchiveIntent>[])
          ChatQueuedConversationArchive._(
            identity: identity,
            request: intent.request,
            enqueueOrder: intent.enqueueOrder,
            enqueuedAt: DateTime.parse(intent.enqueuedAt.value).toUtc(),
            status: ChatQueuedConversationArchiveStatus.waitingForCanonicalBase,
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
      final revision =
          store.state.lifecycleRevisions[intent.request.conversationId];
      late final ChatQueuedConversationArchiveStatus status;
      if (!_authorityReady(intent.request)) {
        status = ChatQueuedConversationArchiveStatus.waitingForCanonicalBase;
      } else if (revision! > intent.request.expectedLifecycleRevision &&
          !_canonicalMatches(intent.request)) {
        status = ChatQueuedConversationArchiveStatus.lifecycleConflict;
        _rollback(intent);
      } else if (_canonicalMatches(intent.request)) {
        status = ChatQueuedConversationArchiveStatus.pending;
        _rollback(intent);
      } else {
        status = ChatQueuedConversationArchiveStatus.pending;
        _project(intent);
      }
      if (status != intent.status && index < _intents.length) {
        _intents[index] = ChatQueuedConversationArchive._(
          identity: intent.identity,
          request: intent.request,
          enqueueOrder: intent.enqueueOrder,
          enqueuedAt: intent.enqueuedAt,
          status: status,
        );
      }
    }
  }

  void _project(ChatQueuedConversationArchive intent) {
    final lifecycle =
        store.conversation(intent.request.conversationId).lifecycle;
    if (lifecycle?.pendingIntents.any(
          (pending) => pending.idempotencyKey == intent.request.idempotencyKey,
        ) ==
        true) {
      return;
    }
    if (lifecycle?.authoritativeRevision !=
        intent.request.expectedLifecycleRevision) {
      return;
    }
    try {
      store.beginOptimisticConversationArchive(intent.request);
    } catch (_) {
      // A later canonical commit will re-evaluate this retained intent.
    }
  }

  void _rollback(ChatQueuedConversationArchive intent) {
    try {
      store.rollbackOptimisticConversationArchive(
        intent.request.conversationId,
        intent.request.idempotencyKey,
      );
    } on StateError {
      // An externally owned store may close before the client settles.
    }
  }

  bool _authorityReady(ConversationArchiveInput request) {
    final state = store.state;
    return state.conversations.containsKey(request.conversationId) &&
        (state.lifecycleRevisions[request.conversationId] ?? -1) >=
            request.expectedLifecycleRevision;
  }

  bool _canonicalMatches(ConversationArchiveInput request) {
    if (!_authorityReady(request)) return false;
    final state = store.state;
    final archived = state.lifecycleArchivedStates[request.conversationId] ??
        state.conversations[request.conversationId]!.archivedAt != null;
    return archived == _desiredArchived(request);
  }

  ChatCommandSuccess<ConversationArchiveResult>? _canonicalSettlementResult(
    ConversationArchiveInput request,
  ) {
    final state = store.state;
    final revision = state.lifecycleRevisions[request.conversationId];
    final conversation = state.conversations[request.conversationId];
    if (revision == null || conversation == null) return null;
    final status = revision == request.expectedLifecycleRevision
        ? 'already_requested_state'
        : revision == request.expectedLifecycleRevision + 1
            ? 'applied'
            : null;
    if (status == null) return null;
    final archiveState = _desiredArchived(request)
        ? <String, Object?>{
            'status': 'archived',
            'archivedAt': conversation.archivedAt?.toJson(),
            'archivedByUserId': conversation.archivedByUserId?.toJson(),
          }
        : const <String, Object?>{'status': 'active'};
    try {
      return ChatCommandSuccess(ConversationArchiveResult.fromJson(
        <String, Object?>{
          'operation': request.operation,
          'intent': request.intent.toJson(),
          'reconciliationStatus': status,
          'conversationId': request.conversationId.toJson(),
          'expectedLifecycleRevision': request.expectedLifecycleRevision,
          'lifecycleRevision': revision,
          'archiveState': archiveState,
        },
        expectedInput: request,
      ));
    } catch (_) {
      return null;
    }
  }

  static bool _desiredArchived(ConversationArchiveInput request) =>
      request.intent == ConversationArchiveIntent.archive;

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
      await _raceConversationArchiveWait(
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

  ChatQueuedConversationArchive? _head(ConversationId conversationId) {
    for (final intent in _intents) {
      if (intent.request.conversationId == conversationId) return intent;
    }
    return null;
  }

  bool _contains(ChatQueuedConversationArchive intent) =>
      _intents.any((candidate) => _sameVisible(candidate, intent));

  Future<ChatCommandResult<ConversationArchiveResult>> _addWaiter(String key) {
    final completer = Completer<ChatCommandResult<ConversationArchiveResult>>();
    (_waiters[key] ??= []).add(completer);
    return completer.future;
  }

  void _complete(
    String key,
    ChatCommandResult<ConversationArchiveResult> result,
  ) {
    final waiters = _waiters.remove(key);
    if (waiters != null) {
      for (final waiter in waiters) {
        if (!waiter.isCompleted) waiter.complete(result);
      }
    }
    unawaited(_callerCancellations.remove(key)?.cancel());
  }

  void _completeAll(ChatCommandResult<ConversationArchiveResult> result) {
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
    ApplicationChatQueuedConversationArchiveIntent stored,
    ChatQueuedConversationArchive visible,
  ) =>
      stored.enqueueOrder == visible.enqueueOrder &&
      DateTime.parse(stored.enqueuedAt.value).toUtc() == visible.enqueuedAt &&
      jsonEncode(stored.request.toJson()) ==
          jsonEncode(visible.request.toJson());

  static bool _sameVisible(
    ChatQueuedConversationArchive left,
    ChatQueuedConversationArchive right,
  ) =>
      left.enqueueOrder == right.enqueueOrder &&
      left.enqueuedAt == right.enqueuedAt &&
      jsonEncode(left.request.toJson()) == jsonEncode(right.request.toJson());

  static bool _isTerminal(
    ChatCommandResult<ConversationArchiveResult> result,
  ) =>
      result is ChatCommandValidationFailure<ConversationArchiveResult> ||
      result is ChatCommandAuthenticationFailure<ConversationArchiveResult> ||
      result is ChatCommandConflict<ConversationArchiveResult> ||
      result is ChatCommandFeatureDisabled<ConversationArchiveResult> ||
      result is ChatCommandUnsupported<ConversationArchiveResult> ||
      result is ChatCommandRejected<ConversationArchiveResult>;

  static bool _isAmbiguous(
    ChatCommandResult<ConversationArchiveResult> result,
  ) =>
      result is ChatCommandTransportFailure<ConversationArchiveResult> ||
      result is ChatCommandMalformedResponse<ConversationArchiveResult> ||
      result is ChatCommandAborted<ConversationArchiveResult> ||
      result is ChatCommandClosed<ConversationArchiveResult>;
}

final class _ActiveConversationArchiveDispatch {
  final ChatCommandCancellationController cancellation =
      ChatCommandCancellationController();
  final Completer<ChatCommandResult<ConversationArchiveResult>>
      canonicalResult = Completer();
  final Completer<ChatCommandResult<ConversationArchiveResult>> result =
      Completer();
}

Duration _defaultConversationArchiveRetryBackoff(int retryNumber) {
  final exponent = retryNumber <= 1 ? 0 : (retryNumber - 1).clamp(0, 5);
  return Duration(seconds: 1 << exponent);
}

Future<void> _defaultConversationArchiveRetryWait(
  Duration delay,
  ChatCommandCancellationSignal _,
) =>
    Future<void>.delayed(delay);

Future<void> _raceConversationArchiveWait(
  Future<void> future,
  ChatCommandCancellationSignal signal,
) {
  if (signal.isCancelled) {
    return Future<void>.error(const _ConversationArchiveWaitInterrupted());
  }
  final completer = Completer<void>();
  late final StreamSubscription<void> subscription;
  subscription = signal.onCancelled.listen((_) {
    if (!completer.isCompleted) {
      completer.completeError(const _ConversationArchiveWaitInterrupted());
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

final class _ConversationArchiveWaitInterrupted implements Exception {
  const _ConversationArchiveWaitInterrupted();
}

/// Pure-Dart archive and restore commands on [HandrailChatClient].
extension HandrailChatConversationArchiveCommands on HandrailChatClient {
  Future<ChatCommandResult<ConversationArchiveResult>> archiveConversation(
    ChatSetConversationArchiveInput input, {
    ChatCommandCancellationSignal? cancellationSignal,
  }) =>
      _beginConversationArchive(
        ConversationArchiveIntent.archive,
        input,
        cancellationSignal: cancellationSignal,
      );

  Future<ChatCommandResult<ConversationArchiveResult>> restoreConversation(
    ChatSetConversationArchiveInput input, {
    ChatCommandCancellationSignal? cancellationSignal,
  }) =>
      _beginConversationArchive(
        ConversationArchiveIntent.restore,
        input,
        cancellationSignal: cancellationSignal,
      );

  Future<ChatCommandResult<ConversationArchiveResult>>
      _beginConversationArchive(
    ConversationArchiveIntent intent,
    ChatSetConversationArchiveInput authored, {
    ChatCommandCancellationSignal? cancellationSignal,
  }) {
    if (_disposed) {
      return Future.value(
        const ChatCommandClosed<ConversationArchiveResult>(),
      );
    }
    if (cancellationSignal?.isCancelled == true) {
      return Future.value(
        const ChatCommandAborted<ConversationArchiveResult>(),
      );
    }

    late final ConversationArchiveInput request;
    try {
      final authoredJson = <String, Object?>{
        'operation': 'set_conversation_archive',
        'intent': intent.toJson(),
        'conversationId': authored.conversationId.toJson(),
        'expectedLifecycleRevision': authored.expectedLifecycleRevision,
      };
      ConversationArchiveInput.fromJson({
        ...authoredJson,
        'idempotencyKey': authored.idempotencyKey ?? 'archive-validation',
      });
      request = ConversationArchiveInput.fromJson({
        ...authoredJson,
        'idempotencyKey':
            authored.idempotencyKey ?? _generateCommandIdempotencyKey(),
      });
    } catch (_) {
      return Future.value(
        const ChatCommandValidationFailure<ConversationArchiveResult>(),
      );
    }

    final recovery = _conversationArchiveRecoveryRuntime;
    if (recovery != null) {
      return recovery.execute(
        request,
        cancellationSignal: cancellationSignal,
      );
    }

    try {
      normalizedState.beginOptimisticConversationArchive(request);
    } catch (_) {
      return Future.value(
        const ChatCommandValidationFailure<ConversationArchiveResult>(),
      );
    }
    final command = _ConversationArchiveCommandIntent(
      request: request,
      cancellationSignal: cancellationSignal,
    );
    final lane = _conversationArchiveCommandLanes.putIfAbsent(
      request.conversationId,
      _ConversationArchiveCommandLane.new,
    );
    lane.intents.add(command);
    if (cancellationSignal != null) {
      command.cancellationSubscription =
          cancellationSignal.onCancelled.listen((_) {
        if (identical(lane.active, command) || command.completer.isCompleted) {
          return;
        }
        if (!lane.intents.remove(command)) return;
        _rollbackConversationArchiveIntent(command.request);
        command.completer.complete(
          const ChatCommandAborted<ConversationArchiveResult>(),
        );
        unawaited(command.cancellationSubscription?.cancel());
      });
      if (cancellationSignal.isCancelled &&
          lane.intents.remove(command) &&
          !command.completer.isCompleted) {
        _rollbackConversationArchiveIntent(command.request);
        command.completer.complete(
          const ChatCommandAborted<ConversationArchiveResult>(),
        );
        unawaited(command.cancellationSubscription?.cancel());
      }
    }
    if (!lane.draining) {
      lane.draining = true;
      late final Future<void> drain;
      drain = _drainConversationArchiveLane(
        request.conversationId,
        lane,
      ).whenComplete(() {
        _conversationArchiveCommandDrains.remove(drain);
      });
      _conversationArchiveCommandDrains.add(drain);
    }
    return command.completer.future;
  }

  Future<void> _drainConversationArchiveLane(
    ConversationId conversationId,
    _ConversationArchiveCommandLane lane,
  ) async {
    while (lane.intents.isNotEmpty) {
      final command = lane.intents.first;
      if (command.completer.isCompleted) {
        lane.intents.removeAt(0);
        continue;
      }
      lane.active = command;
      final request = command.request;
      var result = await _commandDispatcher.dispatch(
        _conversationArchiveDescriptor(request),
        request,
        options: ChatCommandDispatchOptions(
          idempotencyKey: request.idempotencyKey,
          cancellationSignal: command.cancellationSignal,
        ),
      );
      if (_disposed) {
        result = const ChatCommandClosed<ConversationArchiveResult>();
      }
      if (result
          case ChatCommandSuccess<ConversationArchiveResult>(:final value)) {
        try {
          normalizedState.reconcileOptimisticConversationArchive(
            request.idempotencyKey,
            value,
          );
        } catch (_) {
          result =
              const ChatCommandMalformedResponse<ConversationArchiveResult>();
          _rollbackConversationArchiveIntent(request);
        }
      } else {
        _rollbackConversationArchiveIntent(request);
      }
      await command.cancellationSubscription?.cancel();
      if (!command.completer.isCompleted) command.completer.complete(result);
      if (lane.intents.isNotEmpty && identical(lane.intents.first, command)) {
        lane.intents.removeAt(0);
      } else {
        lane.intents.remove(command);
      }
      lane.active = null;
      if (_disposed) {
        for (final queued in lane.intents.toList(growable: false)) {
          _rollbackConversationArchiveIntent(queued.request);
          await queued.cancellationSubscription?.cancel();
          if (!queued.completer.isCompleted) {
            queued.completer.complete(
              const ChatCommandClosed<ConversationArchiveResult>(),
            );
          }
        }
        lane.intents.clear();
      }
    }
    lane.draining = false;
    if (identical(_conversationArchiveCommandLanes[conversationId], lane)) {
      _conversationArchiveCommandLanes.remove(conversationId);
    }
  }

  void _rollbackConversationArchiveIntent(ConversationArchiveInput request) {
    try {
      normalizedState.rollbackOptimisticConversationArchive(
        request.conversationId,
        request.idempotencyKey,
      );
    } on StateError {
      // An externally owned normalized store may close before the client.
    }
  }

  void _closeConversationArchiveCommands() {
    for (final lane in _conversationArchiveCommandLanes.values) {
      final queued = lane.active == null
          ? lane.intents.toList(growable: false)
          : lane.intents.skip(1).toList(growable: false);
      for (final command in queued) {
        lane.intents.remove(command);
        if (command.completer.isCompleted) continue;
        _rollbackConversationArchiveIntent(command.request);
        unawaited(command.cancellationSubscription?.cancel());
        command.completer.complete(
          const ChatCommandClosed<ConversationArchiveResult>(),
        );
      }
    }
  }
}
