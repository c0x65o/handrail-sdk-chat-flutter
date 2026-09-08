part of '../handrail_chat_client.dart';

typedef ChatMessageReminderClock = IsoTimestamp Function();

IsoTimestamp _currentMessageReminderTime() =>
    IsoTimestamp(DateTime.now().toUtc().toIso8601String());

/// Computes the delay before retrying retained reminder work.
typedef ChatMessageReminderRetryBackoff = Duration Function(int retryNumber);

/// Injectable wait boundary for deterministic reminder recovery tests.
typedef ChatMessageReminderRetryWait = Future<void> Function(
  Duration delay,
  ChatCommandCancellationSignal cancellationSignal,
);

typedef _MessageReminderAuthorityRefresh
    = Future<List<MessageReminderListSnapshot>?> Function(
  ChatCommandCancellationSignal cancellationSignal,
);

/// Recovery state for one identity-scoped reminder change.
enum ChatQueuedMessageReminderStatus {
  waitingForAuthority,
  pending,
  revisionConflict,
}

/// Credential-free view of one retained message-reminder command.
final class ChatQueuedMessageReminder {
  const ChatQueuedMessageReminder._({
    required this.identity,
    required this.request,
    required this.enqueueOrder,
    required this.enqueuedAt,
    required this.status,
  });

  final ApplicationChatStorageIdentity identity;
  final MessageReminderRequest request;
  final int enqueueOrder;
  final DateTime enqueuedAt;
  final ChatQueuedMessageReminderStatus status;
}

final class _MessageReminderCommandIntent {
  _MessageReminderCommandIntent({
    required this.initialRequest,
    required this.generation,
    required this.externalCancellation,
  });

  final MessageReminderRequest initialRequest;
  final int generation;
  final ChatCommandCancellationSignal? externalCancellation;
  final ChatCommandCancellationController cancellation =
      ChatCommandCancellationController();
  StreamSubscription<void>? cancellationSubscription;
  final Completer<ChatCommandResult<MessageReminderResult>> completer =
      Completer();
}

final class _MessageReminderCommandLane {
  final List<_MessageReminderCommandIntent> intents = [];
  _MessageReminderCommandIntent? active;
  bool draining = false;
}

ChatCommandDescriptor<MessageReminderRequest, MessageReminderRequest,
    MessageReminderResult> _messageReminderDescriptor(
  MessageReminderRequest request,
) =>
    ChatCommandDescriptor.withPathBuilder(
      name: 'message.reminder.set',
      method: ChatCommandMethod.put,
      pathBuilder: (input) =>
          '/conversations/${Uri.encodeComponent(input.conversationId.value)}'
          '/messages/${Uri.encodeComponent(input.messageId.value)}/reminder',
      retrySafety: ChatCommandRetrySafety.safe,
      validateInput: (input) => MessageReminderRequest.fromJson(input.toJson()),
      parseResult: (json) => MessageReminderResult.fromJson(
        json,
        expectedInput: request,
      ),
      parseErrorResult: (json, httpStatus) {
        if (httpStatus != 409) return null;
        final result = MessageReminderResult.fromJson(
          json,
          expectedInput: request,
        );
        return result.reconciliationStatus ==
                MessageReminderReconciliationStatus.revisionConflict
            ? result
            : null;
      },
    );

final class _MessageReminderRecoveryRuntime {
  _MessageReminderRecoveryRuntime({
    required this.storage,
    required this.dispatcher,
    required this.store,
    required this.generateIdempotencyKey,
    required this.clock,
    required this.backoff,
    required this.wait,
    required this.refreshAuthority,
    required this.lifecycleManaged,
    required this.onStorageDiagnostic,
  });

  final ApplicationChatStorage storage;
  final ChatCommandDispatcher dispatcher;
  final NormalizedSnapshotStore store;
  final ChatCommandIdempotencyKeyGenerator generateIdempotencyKey;
  final ChatMessageReminderClock clock;
  final ChatMessageReminderRetryBackoff backoff;
  final ChatMessageReminderRetryWait wait;
  final _MessageReminderAuthorityRefresh refreshAuthority;
  final bool lifecycleManaged;
  final void Function(String code, String message) onStorageDiagnostic;

  final List<ChatQueuedMessageReminder> _intents = [];
  final Map<String, _ActiveMessageReminderDispatch> _active = {};
  final Map<String, List<Completer<ChatCommandResult<MessageReminderResult>>>>
      _waiters = {};
  final Map<String, StreamSubscription<void>> _callerCancellations = {};
  final Map<MessageId, Future<void>> _lanePumps = {};
  final Map<MessageId, ChatCommandCancellationController> _retryWaits = {};
  Future<void> _storageMutation = Future<void>.value();
  Future<void>? _authorityPump;
  ChatCommandCancellationController? _authorityCancellation;
  ApplicationChatStorageIdentity? _identity;
  int _generation = 0;
  int _epoch = 0;
  bool _metadataReady = false;
  bool _connectivityOnline = false;
  bool _realtimeConnected = false;
  bool _applicationForeground = true;
  bool _authorityReady = false;
  bool _closed = false;

  int get generation => _generation;
  List<ChatQueuedMessageReminder> get intents => List.unmodifiable(_intents);

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
    _invalidateWork();
    _completeAll(const ChatCommandClosed<MessageReminderResult>());
    _identity = identity;
    _generation = generation;
    ++_epoch;
    _authorityReady = false;
    _intents.clear();
    for (final intent in previous) {
      _rollback(intent);
    }
    try {
      store.clearActorPrivateMessageReminders();
    } on StateError {
      // An application-owned store may already be closed.
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
      ApplicationChatQueuedMessageReminderIntentsRecord? record;
      try {
        record = await _mutateRecord(identity, (current) => current);
        if (!_scopeActive(identity, generation, epoch)) return;
      } on FormatException {
        if (!_scopeActive(identity, generation, epoch)) return;
        onStorageDiagnostic(
          ChatClientDiagnosticCode.messageReminderIntentsRejected,
          'The stored message-reminder intents were rejected and quarantined.',
        );
        return;
      } catch (_) {
        if (_scopeActive(identity, generation, epoch)) {
          onStorageDiagnostic(
            ChatClientDiagnosticCode.messageReminderIntentsReadFailed,
            'The stored message-reminder intents could not be read.',
          );
        }
        return;
      }
      if (_scopeActive(identity, generation, epoch)) _publish(record);
    });
    if (!_scopeActive(identity, generation, epoch)) return;
    await _removeExpired(identity, generation, epoch);
    _startAuthorityPump();
  }

  void updateReadiness({
    required bool metadataReady,
    required bool connectivityOnline,
    required bool realtimeConnected,
    required bool applicationForeground,
  }) {
    if (_closed) return;
    final wasReady = _ready;
    _metadataReady = metadataReady;
    _connectivityOnline = connectivityOnline;
    _realtimeConnected = realtimeConnected;
    _applicationForeground = applicationForeground;
    if (!_ready) {
      _authorityReady = false;
      _invalidateWork();
      for (final intent in _intents) {
        _rollback(intent);
      }
      return;
    }
    if (!wasReady) _authorityReady = false;
    _startAuthorityPump();
  }

  Future<ChatCommandResult<MessageReminderResult>> set({
    required ConversationId conversationId,
    required MessageId messageId,
    required IsoTimestamp dueAt,
    ChatCommandCancellationSignal? cancellationSignal,
  }) =>
      _begin(
        conversationId: conversationId,
        messageId: messageId,
        intent: MessageReminderIntent.set,
        dueAt: dueAt,
        cancellationSignal: cancellationSignal,
      );

  Future<ChatCommandResult<MessageReminderResult>> cancel({
    required ConversationId conversationId,
    required MessageId messageId,
    ChatCommandCancellationSignal? cancellationSignal,
  }) =>
      _begin(
        conversationId: conversationId,
        messageId: messageId,
        intent: MessageReminderIntent.cancel,
        cancellationSignal: cancellationSignal,
      );

  Future<ChatCommandResult<MessageReminderResult>> _begin({
    required ConversationId conversationId,
    required MessageId messageId,
    required MessageReminderIntent intent,
    IsoTimestamp? dueAt,
    ChatCommandCancellationSignal? cancellationSignal,
  }) async {
    if (_closed) return const ChatCommandClosed<MessageReminderResult>();
    if (cancellationSignal?.isCancelled == true) {
      return const ChatCommandAborted<MessageReminderResult>();
    }
    final identity = _identity;
    final generation = _generation;
    final epoch = _epoch;
    if (identity == null) {
      return const ChatCommandValidationFailure<MessageReminderResult>();
    }
    late final MessageReminderRequest request;
    try {
      request = MessageReminderRequest.fromJson(<String, Object?>{
        'operation': 'message_reminder.v1',
        'intent': intent.toJson(),
        'conversationId': conversationId.toJson(),
        'messageId': messageId.toJson(),
        'expectedReminderRevision':
            store.messageReminder(messageId).authoritativeRevision,
        'idempotencyKey': generateIdempotencyKey(),
        if (dueAt != null) 'dueAt': dueAt.toJson(),
      });
    } catch (_) {
      return const ChatCommandValidationFailure<MessageReminderResult>();
    }

    final stored = await _persist(identity, generation, epoch, request);
    if (stored == null) {
      return !_scopeActive(identity, generation, epoch)
          ? const ChatCommandClosed<MessageReminderResult>()
          : const ChatCommandValidationFailure<MessageReminderResult>();
    }
    if (!_scopeActive(identity, generation, epoch)) {
      return const ChatCommandClosed<MessageReminderResult>();
    }
    if (cancellationSignal?.isCancelled == true) {
      await _remove(identity, generation, epoch, stored);
      return const ChatCommandAborted<MessageReminderResult>();
    }

    if (_authorityReady) _refreshProjections();
    _startAuthorityPump();
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
    if (_authorityReady) _startLane(messageId);
    return result;
  }

  Future<void> close() async {
    if (_closed) return;
    final previous = _intents.toList(growable: false);
    _closed = true;
    ++_epoch;
    _invalidateWork();
    for (final intent in previous) {
      _rollback(intent);
    }
    _completeAll(const ChatCommandClosed<MessageReminderResult>());
  }

  void _startAuthorityPump() {
    if (!_ready ||
        _intents.isEmpty ||
        _authorityReady ||
        _authorityPump != null) {
      return;
    }
    final identity = _identity;
    if (identity == null) return;
    final generation = _generation;
    final epoch = _epoch;
    late final Future<void> pump;
    pump = _refreshUntilReady(identity, generation, epoch).whenComplete(() {
      if (identical(_authorityPump, pump)) _authorityPump = null;
    });
    _authorityPump = pump;
    unawaited(pump);
  }

  Future<void> _refreshUntilReady(
    ApplicationChatStorageIdentity identity,
    int generation,
    int epoch,
  ) async {
    var retryNumber = 0;
    while (_ready && _scopeActive(identity, generation, epoch)) {
      final cancellation = ChatCommandCancellationController();
      _authorityCancellation = cancellation;
      List<MessageReminderListSnapshot>? pages;
      try {
        pages = await refreshAuthority(cancellation.signal);
      } catch (_) {
        pages = null;
      } finally {
        if (identical(_authorityCancellation, cancellation)) {
          _authorityCancellation = null;
        }
      }
      if (!_ready || !_scopeActive(identity, generation, epoch)) return;
      if (pages != null) {
        try {
          store.replaceMessageReminderList(pages);
        } catch (_) {
          pages = null;
        }
      }
      if (pages != null && _scopeActive(identity, generation, epoch)) {
        _authorityReady = true;
        await _settleAuthorityMatches(identity, generation, epoch);
        if (!_scopeActive(identity, generation, epoch) || !_ready) return;
        _refreshProjections();
        _startPumps();
        return;
      }
      retryNumber += 1;
      if (!await _waitForAuthorityRetry(
        retryNumber,
        identity,
        generation,
        epoch,
      )) {
        return;
      }
    }
  }

  Future<void> _settleAuthorityMatches(
    ApplicationChatStorageIdentity identity,
    int generation,
    int epoch,
  ) async {
    for (final intent in _intents.toList(growable: false)) {
      if (!_scopeActive(identity, generation, epoch)) return;
      if (_isExpired(intent.request) || _canonicalMatches(intent.request)) {
        final removed = await _remove(identity, generation, epoch, intent);
        if (!removed || !_scopeActive(identity, generation, epoch)) continue;
        _rollback(intent);
        _complete(
          intent.request.idempotencyKey,
          _isExpired(intent.request)
              ? const ChatCommandValidationFailure<MessageReminderResult>()
              : _authoritySettlement(intent.request),
        );
      }
    }
  }

  void _startPumps() {
    if (!_ready || !_authorityReady) return;
    for (final intent in _intents) {
      _startLane(intent.request.messageId);
    }
  }

  void _startLane(MessageId messageId) {
    if (!_ready || !_authorityReady || _lanePumps.containsKey(messageId)) {
      return;
    }
    final identity = _identity;
    final head = _head(messageId);
    if (identity == null || head == null) return;
    if (head.status != ChatQueuedMessageReminderStatus.pending) return;
    final generation = _generation;
    final epoch = _epoch;
    late final Future<void> pump;
    pump = _drainLane(identity, generation, epoch, messageId).whenComplete(() {
      if (identical(_lanePumps[messageId], pump)) _lanePumps.remove(messageId);
    });
    _lanePumps[messageId] = pump;
    unawaited(pump);
  }

  Future<void> _drainLane(
    ApplicationChatStorageIdentity identity,
    int generation,
    int epoch,
    MessageId messageId,
  ) async {
    var retryNumber = 0;
    while (_ready &&
        _authorityReady &&
        _scopeActive(identity, generation, epoch)) {
      final intent = _head(messageId);
      if (intent == null) return;
      _refreshProjections();
      if (_isExpired(intent.request)) {
        final removed = await _remove(identity, generation, epoch, intent);
        if (removed && _scopeActive(identity, generation, epoch)) {
          _rollback(intent);
          _complete(
            intent.request.idempotencyKey,
            const ChatCommandValidationFailure<MessageReminderResult>(),
          );
        }
        continue;
      }
      if (_canonicalMatches(intent.request)) {
        final removed = await _remove(identity, generation, epoch, intent);
        if (removed && _scopeActive(identity, generation, epoch)) {
          _rollback(intent);
          _complete(
            intent.request.idempotencyKey,
            _authoritySettlement(intent.request),
          );
        }
        continue;
      }
      if (intent.status != ChatQueuedMessageReminderStatus.pending) return;
      final result = await _dispatch(identity, generation, epoch, intent);
      if (!_scopeActive(identity, generation, epoch)) return;
      if (!_contains(intent)) {
        retryNumber = 0;
        continue;
      }
      if (!_isAmbiguous(result)) return;
      retryNumber += 1;
      if (!await _waitBeforeRetry(
        messageId,
        retryNumber,
        identity,
        generation,
        epoch,
      )) {
        return;
      }
    }
  }

  Future<ChatCommandResult<MessageReminderResult>> _dispatch(
    ApplicationChatStorageIdentity identity,
    int generation,
    int epoch,
    ChatQueuedMessageReminder intent,
  ) async {
    final key = intent.request.idempotencyKey;
    final existing = _active[key];
    if (existing != null) return existing.result.future;
    if (!_scopeActive(identity, generation, epoch)) {
      return const ChatCommandClosed<MessageReminderResult>();
    }
    final active = _ActiveMessageReminderDispatch();
    _active[key] = active;
    late ChatCommandResult<MessageReminderResult> result;
    try {
      result = await dispatcher.dispatch(
        _messageReminderDescriptor(intent.request),
        intent.request,
        options: ChatCommandDispatchOptions(
          idempotencyKey: key,
          cancellationSignal: active.cancellation.signal,
        ),
      );
      if (!_scopeActive(identity, generation, epoch)) {
        result = const ChatCommandClosed<MessageReminderResult>();
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
    if (_scopeActive(identity, generation, epoch)) {
      _complete(key, result);
    }
    return result;
  }

  Future<ChatCommandResult<MessageReminderResult>> _settleResult(
    ApplicationChatStorageIdentity identity,
    int generation,
    int epoch,
    ChatQueuedMessageReminder intent,
    ChatCommandResult<MessageReminderResult> result,
  ) async {
    if (result case ChatCommandSuccess<MessageReminderResult>(:final value)) {
      if (value.reconciliationStatus ==
          MessageReminderReconciliationStatus.revisionConflict) {
        try {
          _rollback(intent);
          store.reconcileMessageReminderMutation(intent.request, value);
          _refreshProjections();
        } catch (_) {
          return const ChatCommandMalformedResponse<MessageReminderResult>();
        }
        return result;
      }
      if (value.reconciliationStatus ==
          MessageReminderReconciliationStatus.unavailableSource) {
        return result;
      }
      final removed = await _remove(identity, generation, epoch, intent);
      if (removed && _scopeActive(identity, generation, epoch)) {
        try {
          store.reconcileMessageReminderMutation(intent.request, value);
        } catch (_) {
          return const ChatCommandMalformedResponse<MessageReminderResult>();
        }
      }
    } else if (_isTerminal(result)) {
      final removed = await _remove(identity, generation, epoch, intent);
      if (removed && _scopeActive(identity, generation, epoch)) {
        _rollback(intent);
      }
    }
    return result;
  }

  Future<ChatQueuedMessageReminder?> _persist(
    ApplicationChatStorageIdentity identity,
    int generation,
    int epoch,
    MessageReminderRequest request,
  ) =>
      _serialized(() async {
        if (!_scopeActive(identity, generation, epoch)) return null;
        try {
          final enqueuedAt = clock();
          final next = await _mutateRecord(identity, (current) {
            if (!_scopeActive(identity, generation, epoch)) return current;
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
            // Coalesce against this retry's current message lanes, keeping
            // unrelated reminders and the superseded lane's FIFO metadata.
            return ApplicationChatQueuedMessageReminderIntentsRecord(
              identity: identity,
              intents: [
                ...?current?.intents,
                ApplicationChatQueuedMessageReminderIntent(
                  request: request,
                  enqueueOrder: highest + 1,
                  enqueuedAt: enqueuedAt,
                ),
              ],
            );
          });
          if (!_scopeActive(identity, generation, epoch)) return null;
          // Only committed state can retire callers or cancel dispatches.
          final superseded = _intents
              .where((visible) => !(next?.intents
                      .any((stored) => _sameStored(stored, visible)) ??
                  false))
              .toList(growable: false);
          _publish(next);
          for (final intent in superseded) {
            _rollback(intent);
            _active[intent.request.idempotencyKey]?.cancellation.cancel();
            _complete(
              intent.request.idempotencyKey,
              const ChatCommandClosed<MessageReminderResult>(),
            );
          }
          return _intents.cast<ChatQueuedMessageReminder?>().firstWhere(
                (intent) =>
                    jsonEncode(intent?.request.toJson()) ==
                    jsonEncode(request.toJson()),
                orElse: () => null,
              );
        } catch (_) {
          if (_scopeActive(identity, generation, epoch)) {
            onStorageDiagnostic(
              ChatClientDiagnosticCode.messageReminderIntentsWriteFailed,
              'The message-reminder command could not be stored before dispatch.',
            );
          }
          return null;
        }
      });

  Future<bool> _remove(
    ApplicationChatStorageIdentity identity,
    int generation,
    int epoch,
    ChatQueuedMessageReminder intent,
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
            return ApplicationChatQueuedMessageReminderIntentsRecord(
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
              ChatClientDiagnosticCode.messageReminderIntentsWriteFailed,
              'A settled message-reminder command could not be removed from storage.',
            );
          }
          return false;
        }
      });

  Future<void> _removeExpired(
    ApplicationChatStorageIdentity identity,
    int generation,
    int epoch,
  ) async {
    for (final intent in _intents.toList(growable: false)) {
      if (!_isExpired(intent.request)) continue;
      final removed = await _remove(identity, generation, epoch, intent);
      if (removed && _scopeActive(identity, generation, epoch)) {
        _rollback(intent);
        _complete(
          intent.request.idempotencyKey,
          const ChatCommandValidationFailure<MessageReminderResult>(),
        );
      }
    }
  }

  Future<ApplicationChatQueuedMessageReminderIntentsRecord?> _mutateRecord(
    ApplicationChatStorageIdentity identity,
    ApplicationChatStorageUpdater<
            ApplicationChatQueuedMessageReminderIntentsRecord>
        updater,
  ) =>
      ApplicationChatStorageMutator(storage)
          .mutate<ApplicationChatQueuedMessageReminderIntentsRecord>(
        identity,
        ApplicationChatStorageRecordKind.queuedMessageReminderIntents,
        updater,
      );

  void _publish(ApplicationChatQueuedMessageReminderIntentsRecord? record) {
    final identity = _identity;
    if (identity == null) return;
    _intents
      ..clear()
      ..addAll([
        for (final intent in record?.intents ??
            const <ApplicationChatQueuedMessageReminderIntent>[])
          ChatQueuedMessageReminder._(
            identity: identity,
            request: intent.request,
            enqueueOrder: intent.enqueueOrder,
            enqueuedAt: DateTime.parse(intent.enqueuedAt.value).toUtc(),
            status: ChatQueuedMessageReminderStatus.waitingForAuthority,
          ),
      ]);
  }

  void _refreshProjections() {
    final identity = _identity;
    final generation = _generation;
    final epoch = _epoch;
    if (!_authorityReady ||
        identity == null ||
        !_scopeActive(identity, generation, epoch)) {
      return;
    }
    for (var index = 0; index < _intents.length; index += 1) {
      final intent = _intents[index];
      final state = store.messageReminder(intent.request.messageId);
      late final ChatQueuedMessageReminderStatus status;
      if (state.authoritativeRevision >
              intent.request.expectedReminderRevision &&
          !_canonicalMatches(intent.request)) {
        status = ChatQueuedMessageReminderStatus.revisionConflict;
        _rollback(intent);
      } else if (_canonicalMatches(intent.request)) {
        status = ChatQueuedMessageReminderStatus.pending;
        _rollback(intent);
      } else {
        status = ChatQueuedMessageReminderStatus.pending;
        _project(intent);
      }
      if (status != intent.status && index < _intents.length) {
        _intents[index] = ChatQueuedMessageReminder._(
          identity: intent.identity,
          request: intent.request,
          enqueueOrder: intent.enqueueOrder,
          enqueuedAt: intent.enqueuedAt,
          status: status,
        );
      }
    }
  }

  void _project(ChatQueuedMessageReminder intent) {
    final state = store.messageReminder(intent.request.messageId);
    if (state.pendingIntents.any((pending) =>
        pending.request.idempotencyKey == intent.request.idempotencyKey)) {
      return;
    }
    if (state.authoritativeRevision !=
        intent.request.expectedReminderRevision) {
      return;
    }
    try {
      store.beginOptimisticMessageReminder(intent.request);
    } catch (_) {
      // A later authority refresh will re-evaluate the retained intent.
    }
  }

  void _rollback(ChatQueuedMessageReminder intent) {
    try {
      store.rollbackOptimisticMessageReminder(
        intent.request.messageId,
        intent.request.idempotencyKey,
      );
    } on StateError {
      // An externally owned store may close before settlement.
    }
  }

  bool _canonicalMatches(MessageReminderRequest request) {
    final canonical =
        store.messageReminder(request.messageId).authoritativeReminder;
    return switch (request) {
      SetMessageReminderRequest(:final dueAt) =>
        canonical is CanonicalScheduledMessageReminder &&
            canonical.dueAt == dueAt,
      CancelMessageReminderRequest() =>
        canonical == null || canonical is CanonicalCancelledMessageReminder,
    };
  }

  bool _isExpired(MessageReminderRequest request) =>
      request is SetMessageReminderRequest &&
      !DateTime.parse(request.dueAt.value)
          .isAfter(DateTime.parse(clock().value));

  ChatCommandResult<MessageReminderResult> _authoritySettlement(
    MessageReminderRequest request,
  ) {
    final state = store.messageReminder(request.messageId);
    final canonical = state.authoritativeReminder ??
        const CanonicalCancelledMessageReminder();
    final revision = state.authoritativeRevision;
    final status = revision == request.expectedReminderRevision
        ? 'already-requested'
        : revision == request.expectedReminderRevision + 1
            ? 'applied'
            : null;
    if (status == null) return const ChatCommandClosed<MessageReminderResult>();
    try {
      return ChatCommandSuccess(MessageReminderResult.fromJson(
        <String, Object?>{
          'operation': request.operation,
          'intent': request.intent.toJson(),
          'reconciliationStatus': status,
          'conversationId': request.conversationId.toJson(),
          'messageId': request.messageId.toJson(),
          'expectedReminderRevision': request.expectedReminderRevision,
          'idempotencyKey': request.idempotencyKey,
          'reminderRevision': revision,
          'reminder': canonical.toJson(),
        },
        expectedInput: request,
      ));
    } catch (_) {
      return const ChatCommandClosed<MessageReminderResult>();
    }
  }

  Future<void> _cancelBeforeDispatch(
    ApplicationChatStorageIdentity identity,
    int generation,
    int epoch,
    ChatQueuedMessageReminder intent,
  ) async {
    if (_active.containsKey(intent.request.idempotencyKey)) return;
    final removed = await _remove(identity, generation, epoch, intent);
    if (removed && _scopeActive(identity, generation, epoch)) {
      _rollback(intent);
      _complete(
        intent.request.idempotencyKey,
        const ChatCommandAborted<MessageReminderResult>(),
      );
    }
  }

  Future<bool> _waitBeforeRetry(
    MessageId messageId,
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
    _retryWaits[messageId] = cancellation;
    if (!_ready || !_scopeActive(identity, generation, epoch)) {
      cancellation.cancel();
      return false;
    }
    try {
      await _raceMessageReminderWait(
        Future<void>.sync(() => wait(delay, cancellation.signal)),
        cancellation.signal,
      );
      return _ready && _scopeActive(identity, generation, epoch);
    } catch (_) {
      return false;
    } finally {
      if (identical(_retryWaits[messageId], cancellation)) {
        _retryWaits.remove(messageId);
      }
    }
  }

  Future<bool> _waitForAuthorityRetry(
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
    _authorityCancellation = cancellation;
    try {
      await _raceMessageReminderWait(
        Future<void>.sync(() => wait(delay, cancellation.signal)),
        cancellation.signal,
      );
      return _ready && _scopeActive(identity, generation, epoch);
    } catch (_) {
      return false;
    } finally {
      if (identical(_authorityCancellation, cancellation)) {
        _authorityCancellation = null;
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

  ChatQueuedMessageReminder? _head(MessageId messageId) {
    for (final intent in _intents) {
      if (intent.request.messageId == messageId) return intent;
    }
    return null;
  }

  bool _contains(ChatQueuedMessageReminder intent) =>
      _intents.any((candidate) => _sameVisible(candidate, intent));

  Future<ChatCommandResult<MessageReminderResult>> _addWaiter(String key) {
    final completer = Completer<ChatCommandResult<MessageReminderResult>>();
    (_waiters[key] ??= []).add(completer);
    return completer.future;
  }

  void _complete(
    String key,
    ChatCommandResult<MessageReminderResult> result,
  ) {
    final waiters = _waiters.remove(key);
    if (waiters != null) {
      for (final waiter in waiters) {
        if (!waiter.isCompleted) waiter.complete(result);
      }
    }
    unawaited(_callerCancellations.remove(key)?.cancel());
  }

  void _completeAll(ChatCommandResult<MessageReminderResult> result) {
    for (final key in _waiters.keys.toList(growable: false)) {
      _complete(key, result);
    }
  }

  void _invalidateWork() {
    _authorityCancellation?.cancel();
    _authorityCancellation = null;
    _authorityPump = null;
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
    ApplicationChatQueuedMessageReminderIntent stored,
    ChatQueuedMessageReminder visible,
  ) =>
      stored.enqueueOrder == visible.enqueueOrder &&
      DateTime.parse(stored.enqueuedAt.value).toUtc() == visible.enqueuedAt &&
      jsonEncode(stored.request.toJson()) ==
          jsonEncode(visible.request.toJson());

  static bool _sameVisible(
    ChatQueuedMessageReminder left,
    ChatQueuedMessageReminder right,
  ) =>
      left.enqueueOrder == right.enqueueOrder &&
      left.enqueuedAt == right.enqueuedAt &&
      jsonEncode(left.request.toJson()) == jsonEncode(right.request.toJson());

  static bool _isTerminal(ChatCommandResult<MessageReminderResult> result) =>
      result is ChatCommandValidationFailure<MessageReminderResult> ||
      result is ChatCommandAuthenticationFailure<MessageReminderResult> ||
      result is ChatCommandConflict<MessageReminderResult> ||
      result is ChatCommandFeatureDisabled<MessageReminderResult> ||
      result is ChatCommandUnsupported<MessageReminderResult> ||
      result is ChatCommandRejected<MessageReminderResult>;

  static bool _isAmbiguous(ChatCommandResult<MessageReminderResult> result) =>
      result is ChatCommandTransportFailure<MessageReminderResult> ||
      result is ChatCommandMalformedResponse<MessageReminderResult> ||
      result is ChatCommandAborted<MessageReminderResult> ||
      result is ChatCommandClosed<MessageReminderResult> ||
      result is ChatCommandSuccess<MessageReminderResult> &&
          result.value.reconciliationStatus ==
              MessageReminderReconciliationStatus.unavailableSource;
}

final class _ActiveMessageReminderDispatch {
  final ChatCommandCancellationController cancellation =
      ChatCommandCancellationController();
  final Completer<ChatCommandResult<MessageReminderResult>> result =
      Completer();
}

Duration _defaultMessageReminderRetryBackoff(int retryNumber) {
  final exponent = retryNumber <= 1 ? 0 : (retryNumber - 1).clamp(0, 5);
  return Duration(seconds: 1 << exponent);
}

Future<void> _defaultMessageReminderRetryWait(
  Duration delay,
  ChatCommandCancellationSignal _,
) =>
    Future<void>.delayed(delay);

Future<void> _raceMessageReminderWait(
  Future<void> future,
  ChatCommandCancellationSignal signal,
) {
  if (signal.isCancelled) {
    return Future<void>.error(const _MessageReminderWaitInterrupted());
  }
  final completer = Completer<void>();
  late final StreamSubscription<void> subscription;
  subscription = signal.onCancelled.listen((_) {
    if (!completer.isCompleted) {
      completer.completeError(const _MessageReminderWaitInterrupted());
    }
  });
  future.then(
    (_) {
      if (!completer.isCompleted) completer.complete();
    },
    onError: (Object error, StackTrace stackTrace) {
      if (!completer.isCompleted) {
        completer.completeError(error, stackTrace);
      }
    },
  );
  return completer.future.whenComplete(subscription.cancel);
}

final class _MessageReminderWaitInterrupted implements Exception {
  const _MessageReminderWaitInterrupted();
}

final class _ImmediateMessageReminderRuntime {
  _ImmediateMessageReminderRuntime({
    required ChatCommandDispatcher dispatcher,
    required NormalizedSnapshotStore store,
    required ChatCommandIdempotencyKeyGenerator generateIdempotencyKey,
  })  : _dispatcher = dispatcher,
        _store = store,
        _generateIdempotencyKey = generateIdempotencyKey;

  final ChatCommandDispatcher _dispatcher;
  final NormalizedSnapshotStore _store;
  final ChatCommandIdempotencyKeyGenerator _generateIdempotencyKey;
  final Map<MessageId, _MessageReminderCommandLane> _lanes = {};
  final Set<Future<void>> _drains = {};
  int _generation = 0;
  bool _closed = false;

  int get generation => _generation;

  Future<ChatCommandResult<MessageReminderResult>> set({
    required ConversationId conversationId,
    required MessageId messageId,
    required IsoTimestamp dueAt,
    ChatCommandCancellationSignal? cancellationSignal,
  }) =>
      _begin(
        conversationId: conversationId,
        messageId: messageId,
        intent: MessageReminderIntent.set,
        dueAt: dueAt,
        cancellationSignal: cancellationSignal,
      );

  Future<ChatCommandResult<MessageReminderResult>> cancel({
    required ConversationId conversationId,
    required MessageId messageId,
    ChatCommandCancellationSignal? cancellationSignal,
  }) =>
      _begin(
        conversationId: conversationId,
        messageId: messageId,
        intent: MessageReminderIntent.cancel,
        cancellationSignal: cancellationSignal,
      );

  Future<ChatCommandResult<MessageReminderResult>> _begin({
    required ConversationId conversationId,
    required MessageId messageId,
    required MessageReminderIntent intent,
    IsoTimestamp? dueAt,
    ChatCommandCancellationSignal? cancellationSignal,
  }) {
    if (_closed) {
      return Future.value(const ChatCommandClosed<MessageReminderResult>());
    }
    if (cancellationSignal?.isCancelled == true) {
      return Future.value(const ChatCommandAborted<MessageReminderResult>());
    }
    late final MessageReminderRequest request;
    try {
      final revision = _store.messageReminder(messageId).authoritativeRevision;
      request = MessageReminderRequest.fromJson({
        'operation': 'message_reminder.v1',
        'intent': intent.toJson(),
        'conversationId': conversationId.toJson(),
        'messageId': messageId.toJson(),
        'expectedReminderRevision': revision,
        'idempotencyKey': _generateIdempotencyKey(),
        if (dueAt != null) 'dueAt': dueAt.toJson(),
      });
      _store.beginOptimisticMessageReminder(request);
    } catch (_) {
      return Future.value(
        const ChatCommandValidationFailure<MessageReminderResult>(),
      );
    }

    final command = _MessageReminderCommandIntent(
      initialRequest: request,
      generation: _generation,
      externalCancellation: cancellationSignal,
    );
    final lane = _lanes.putIfAbsent(messageId, _MessageReminderCommandLane.new);
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
          const ChatCommandAborted<MessageReminderResult>(),
        );
        unawaited(command.cancellationSubscription?.cancel());
      });
    }
    if (!lane.draining) {
      lane.draining = true;
      late final Future<void> drain;
      drain = _drain(messageId, lane).whenComplete(() => _drains.remove(drain));
      _drains.add(drain);
    }
    return command.completer.future;
  }

  Future<void> _drain(
    MessageId messageId,
    _MessageReminderCommandLane lane,
  ) async {
    while (lane.intents.isNotEmpty) {
      final command = lane.intents.first;
      if (command.completer.isCompleted) {
        lane.intents.removeAt(0);
        continue;
      }
      lane.active = command;
      final initial = command.initialRequest;
      late final MessageReminderRequest request;
      ChatCommandResult<MessageReminderResult> result;
      try {
        final revision =
            _store.messageReminder(messageId).authoritativeRevision;
        request = MessageReminderRequest.fromJson({
          ...initial.toJson(),
          'expectedReminderRevision': revision,
        });
        _store.rebaseOptimisticMessageReminder(
          messageId,
          initial.idempotencyKey,
          revision,
        );
        result = await _dispatcher.dispatch(
          _messageReminderDescriptor(request),
          request,
          options: ChatCommandDispatchOptions(
            idempotencyKey: request.idempotencyKey,
            cancellationSignal: command.cancellation.signal,
          ),
        );
      } catch (_) {
        result = const ChatCommandValidationFailure<MessageReminderResult>();
      }

      if (_closed || command.generation != _generation) {
        _rollback(initial);
        result = const ChatCommandClosed<MessageReminderResult>();
      } else if (result
          case ChatCommandSuccess<MessageReminderResult>(:final value)) {
        try {
          _store.reconcileMessageReminderMutation(request, value);
        } catch (_) {
          result = const ChatCommandMalformedResponse<MessageReminderResult>();
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
    if (identical(_lanes[messageId], lane)) _lanes.remove(messageId);
  }

  void invalidateIdentity() {
    if (_closed) return;
    _generation += 1;
    for (final lane in _lanes.values) {
      lane.active?.cancellation.cancel();
      final queued = lane.active == null
          ? lane.intents.toList(growable: false)
          : lane.intents.skip(1).toList(growable: false);
      for (final command in queued) {
        lane.intents.remove(command);
        _rollback(command.initialRequest);
        unawaited(command.cancellationSubscription?.cancel());
        if (!command.completer.isCompleted) {
          command.completer.complete(
            const ChatCommandClosed<MessageReminderResult>(),
          );
        }
      }
    }
    try {
      _store.clearActorPrivateMessageReminders();
    } on StateError {
      // An application-owned store may close before identity invalidation.
    }
  }

  void _rollback(MessageReminderRequest request) {
    try {
      _store.rollbackOptimisticMessageReminder(
        request.messageId,
        request.idempotencyKey,
      );
    } on StateError {
      // An application-owned store may close before command settlement.
    }
  }

  Future<void> dispose() async {
    if (_closed) return;
    invalidateIdentity();
    _closed = true;
    if (_drains.isNotEmpty) {
      await Future.wait(_drains.toList(growable: false));
    }
  }
}

extension HandrailChatMessageReminderCommands on HandrailChatClient {
  /// Creates an actor-private reminder using an explicit future due time.
  Future<ChatCommandResult<MessageReminderResult>> setMessageReminder({
    required ConversationId conversationId,
    required MessageId messageId,
    required IsoTimestamp dueAt,
    ChatCommandCancellationSignal? cancellationSignal,
  }) =>
      _disposed
          ? Future.value(const ChatCommandClosed<MessageReminderResult>())
          : (_messageReminderRecoveryRuntime?.set(
                conversationId: conversationId,
                messageId: messageId,
                dueAt: dueAt,
                cancellationSignal: cancellationSignal,
              ) ??
              _immediateMessageReminderRuntime!.set(
                conversationId: conversationId,
                messageId: messageId,
                dueAt: dueAt,
                cancellationSignal: cancellationSignal,
              ));

  /// Reschedules through the canonical explicit set intent.
  Future<ChatCommandResult<MessageReminderResult>> rescheduleMessageReminder({
    required ConversationId conversationId,
    required MessageId messageId,
    required IsoTimestamp dueAt,
    ChatCommandCancellationSignal? cancellationSignal,
  }) =>
      _disposed
          ? Future.value(const ChatCommandClosed<MessageReminderResult>())
          : setMessageReminder(
              conversationId: conversationId,
              messageId: messageId,
              dueAt: dueAt,
              cancellationSignal: cancellationSignal,
            );

  /// Cancels one actor-private reminder without toggle semantics.
  Future<ChatCommandResult<MessageReminderResult>> cancelMessageReminder({
    required ConversationId conversationId,
    required MessageId messageId,
    ChatCommandCancellationSignal? cancellationSignal,
  }) =>
      _disposed
          ? Future.value(const ChatCommandClosed<MessageReminderResult>())
          : (_messageReminderRecoveryRuntime?.cancel(
                conversationId: conversationId,
                messageId: messageId,
                cancellationSignal: cancellationSignal,
              ) ??
              _immediateMessageReminderRuntime!.cancel(
                conversationId: conversationId,
                messageId: messageId,
                cancellationSignal: cancellationSignal,
              ));
}
