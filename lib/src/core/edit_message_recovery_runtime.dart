part of '../handrail_chat_client.dart';

/// Injectable wall clock used for durable edit FIFO metadata.
typedef ChatMessageEditClock = DateTime Function();

/// Computes the delay before replaying an ambiguous retained edit.
typedef ChatMessageEditRetryBackoff = Duration Function(int retryNumber);

/// Injectable wait boundary for deterministic retained-edit recovery tests.
typedef ChatMessageEditRetryWait = Future<void> Function(
  Duration delay,
  ChatCommandCancellationSignal cancellationSignal,
);

/// Recovery state for one identity-scoped durable edit.
enum ChatQueuedMessageEditStatus {
  waitingForCanonicalBase,
  pending,
  revisionConflict,
}

/// A credential-free view of one retained message edit.
final class ChatQueuedMessageEdit {
  const ChatQueuedMessageEdit._({
    required this.identity,
    required this.request,
    required this.enqueueOrder,
    required this.enqueuedAt,
    required this.status,
  });

  final ApplicationChatStorageIdentity identity;
  final EditMessageRequest request;
  final int enqueueOrder;
  final DateTime enqueuedAt;
  final ChatQueuedMessageEditStatus status;
}

final class _MessageEditRecoveryRuntime {
  _MessageEditRecoveryRuntime({
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
  final ChatMessageEditClock clock;
  final ChatMessageEditRetryBackoff backoff;
  final ChatMessageEditRetryWait wait;
  final bool lifecycleManaged;
  final void Function(String code, String message) onStorageDiagnostic;

  final List<ChatQueuedMessageEdit> _edits = <ChatQueuedMessageEdit>[];
  final Map<String, _ActiveMessageEditDispatch> _active = {};
  final Set<String> _authoredDispatchStarting = <String>{};
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

  List<ChatQueuedMessageEdit> get edits => List.unmodifiable(_edits);

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
    _identity = identity;
    _generation = generation;
    ++_epoch;
    _edits.clear();
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
      if (!_scopeActive(identity, generation, epoch)) return;
      _publish(record);
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

  Future<ChatCommandResult<EditMessageResult>> execute(
    EditMessageRequest request, {
    ChatCommandCancellationSignal? cancellationSignal,
  }) async {
    if (_closed) return const ChatCommandClosed<EditMessageResult>();
    if (cancellationSignal?.isCancelled == true) {
      return const ChatCommandAborted<EditMessageResult>();
    }
    final identity = _identity;
    final generation = _generation;
    final epoch = _epoch;
    if (identity == null) {
      return const ChatCommandValidationFailure<EditMessageResult>();
    }
    if (_edits.any((edit) => edit.request.messageId == request.messageId)) {
      return const ChatCommandValidationFailure<EditMessageResult>();
    }
    final stored = await _persist(identity, generation, epoch, request);
    if (stored == null) {
      return !_scopeActive(identity, generation, epoch)
          ? const ChatCommandClosed<EditMessageResult>()
          : const ChatCommandValidationFailure<EditMessageResult>();
    }
    if (!_scopeActive(identity, generation, epoch)) {
      return const ChatCommandClosed<EditMessageResult>();
    }
    if (cancellationSignal?.isCancelled == true) {
      await _remove(identity, generation, epoch, stored);
      return const ChatCommandAborted<EditMessageResult>();
    }
    final key = stored.request.idempotencyKey;
    _authoredDispatchStarting.add(key);
    late final ChatCommandResult<EditMessageResult> result;
    try {
      if (!_project(stored)) {
        await _remove(identity, generation, epoch, stored);
        return const ChatCommandValidationFailure<EditMessageResult>();
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
    if (_closed || event is! MessageUpdatedDurableEvent) return;
    final identity = _identity;
    final generation = _generation;
    final epoch = _epoch;
    if (identity == null || event.tenantId != identity.tenantId) return;
    late final ActiveMessage message;
    try {
      final parsed = Message.fromJson(event.payload.data['message']);
      if (parsed is! ActiveMessage) return;
      message = parsed;
    } catch (_) {
      return;
    }
    final matches = _edits.where((edit) {
      final request = edit.request;
      return request.messageId == message.id &&
          message.revision.revision == request.expectedRevision + 1 &&
          _sameJson(message.content.toJson(), request.content.toJson());
    }).toList(growable: false);
    for (final edit in matches) {
      if (!_scopeActive(identity, generation, epoch)) return;
      final removed = await _remove(identity, generation, epoch, edit);
      if (!removed || !_scopeActive(identity, generation, epoch)) continue;
      final active = _active[edit.request.idempotencyKey];
      if (active != null && !active.canonicalResult.isCompleted) {
        active.canonicalResult.complete(
          ChatCommandSuccess<EditMessageResult>(
            EditMessageResult.fromJson(<String, Object?>{
              'operation': 'edit',
              'reconciliationStatus': 'applied',
              'expectedRevision': edit.request.expectedRevision,
              'message': message.toJson(),
              'canonicalRevision': message.revision.revision,
            }),
          ),
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
    await _storeSubscription.cancel();
  }

  Future<ChatQueuedMessageEdit?> _persist(
    ApplicationChatStorageIdentity identity,
    int generation,
    int epoch,
    EditMessageRequest request,
  ) =>
      _serialized<ChatQueuedMessageEdit?>(() async {
        if (!_scopeActive(identity, generation, epoch)) return null;
        try {
          final enqueuedAt = IsoTimestamp(clock().toUtc().toIso8601String());
          final next = await _mutateRecord(identity, (current) {
            if (!_scopeActive(identity, generation, epoch)) return current;
            final highest = current?.intents.fold<int>(
                  0,
                  (value, intent) => max(value, intent.enqueueOrder),
                ) ??
                0;
            // Canonical normalization supersedes the message lane while
            // retaining its original FIFO metadata, including on CAS retries.
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
          for (final edit in _edits) {
            if (_sameJson(edit.request.toJson(), request.toJson())) {
              return edit;
            }
          }
          return null;
        } catch (_) {
          if (_scopeActive(identity, generation, epoch)) {
            onStorageDiagnostic(
              ChatClientDiagnosticCode.messageMutationIntentsWriteFailed,
              'The message edit could not be stored before dispatch.',
            );
          }
          return null;
        }
      });

  Future<bool> _remove(
    ApplicationChatStorageIdentity identity,
    int generation,
    int epoch,
    ChatQueuedMessageEdit edit,
  ) =>
      _serialized<bool>(() async {
        if (!_scopeActive(identity, generation, epoch)) return false;
        try {
          final next = await _mutateRecord(identity, (current) {
            if (!_scopeActive(identity, generation, epoch) || current == null) {
              return current;
            }
            final remaining = current.intents
                .where((intent) => !_sameStoredEdit(intent, edit))
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
              'A settled message edit could not be removed from storage.',
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
    _edits
      ..clear()
      ..addAll(<ChatQueuedMessageEdit>[
        for (final intent in record?.intents ??
            const <ApplicationChatQueuedMessageMutationIntent>[])
          if (intent.request case final EditMessageRequest request)
            ChatQueuedMessageEdit._(
              identity: identity,
              request: request,
              enqueueOrder: intent.enqueueOrder,
              enqueuedAt: DateTime.parse(intent.enqueuedAt.value).toUtc(),
              status: ChatQueuedMessageEditStatus.waitingForCanonicalBase,
            ),
      ]);
  }

  void _refreshProjections() {
    if (_closed) return;
    for (var index = 0; index < _edits.length; index += 1) {
      final edit = _edits[index];
      final message = store.state.canonicalMessages[edit.request.messageId];
      var status = edit.status;
      if (message == null || message is! ActiveMessage) {
        status = ChatQueuedMessageEditStatus.waitingForCanonicalBase;
      } else if (message.revision.revision < edit.request.expectedRevision) {
        status = ChatQueuedMessageEditStatus.waitingForCanonicalBase;
      } else if (message.revision.revision > edit.request.expectedRevision) {
        status = ChatQueuedMessageEditStatus.revisionConflict;
      } else if (status != ChatQueuedMessageEditStatus.pending) {
        status = _project(edit)
            ? ChatQueuedMessageEditStatus.pending
            : ChatQueuedMessageEditStatus.waitingForCanonicalBase;
      }
      if (status != edit.status) {
        _edits[index] = ChatQueuedMessageEdit._(
          identity: edit.identity,
          request: edit.request,
          enqueueOrder: edit.enqueueOrder,
          enqueuedAt: edit.enqueuedAt,
          status: status,
        );
      }
    }
  }

  bool _project(ChatQueuedMessageEdit edit) {
    if (edit.status == ChatQueuedMessageEditStatus.pending) return true;
    final message = store.state.canonicalMessages[edit.request.messageId];
    if (message is! ActiveMessage ||
        message.revision.revision != edit.request.expectedRevision) {
      return false;
    }
    final index = _edits.indexWhere(
      (candidate) =>
          candidate.request.idempotencyKey == edit.request.idempotencyKey,
    );
    if (index < 0) return false;
    final pending = ChatQueuedMessageEdit._(
      identity: edit.identity,
      request: edit.request,
      enqueueOrder: edit.enqueueOrder,
      enqueuedAt: edit.enqueuedAt,
      status: ChatQueuedMessageEditStatus.pending,
    );
    _edits[index] = pending;
    try {
      store.beginOptimisticMessageEdit(edit.request);
      return true;
    } catch (_) {
      if (index < _edits.length && identical(_edits[index], pending)) {
        _edits[index] = edit;
      }
      return false;
    }
  }

  void _startPump({bool waitBeforeFirstDispatch = false}) {
    if (!_ready) return;
    if (_pump != null) {
      _pumpRestartRequested = true;
      return;
    }
    final identity = _identity;
    if (identity == null || _edits.isEmpty) return;
    if (_authoredDispatchStarting
        .contains(_edits.first.request.idempotencyKey)) {
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
      if (_edits.isEmpty) return;
      final edit = _edits.first;
      if (edit.status != ChatQueuedMessageEditStatus.pending) return;
      final result = await _dispatch(identity, generation, epoch, edit);
      if (!_scopeActive(identity, generation, epoch)) return;
      if (!_edits.any((candidate) => _sameEdit(candidate, edit))) {
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

  Future<ChatCommandResult<EditMessageResult>> _dispatch(
    ApplicationChatStorageIdentity identity,
    int generation,
    int epoch,
    ChatQueuedMessageEdit edit, {
    ChatCommandCancellationSignal? callerCancellation,
  }) async {
    final key = edit.request.idempotencyKey;
    final existing = _active[key];
    if (existing != null) return existing.result.future;
    if (!_scopeActive(identity, generation, epoch)) {
      return const ChatCommandClosed<EditMessageResult>();
    }
    final active = _ActiveMessageEditDispatch();
    _active[key] = active;
    StreamSubscription<void>? callerSubscription;
    if (callerCancellation != null) {
      callerSubscription = callerCancellation.onCancelled.listen((_) {
        active.cancellation.cancel();
      });
      if (callerCancellation.isCancelled) active.cancellation.cancel();
    }
    late ChatCommandResult<EditMessageResult> result;
    try {
      final dispatch = dispatcher.dispatch(
        _editMessageDescriptor,
        edit.request,
        options: ChatCommandDispatchOptions(
          idempotencyKey: key,
          cancellationSignal: active.cancellation.signal,
        ),
      );
      result = await Future.any<ChatCommandResult<EditMessageResult>>([
        dispatch,
        active.canonicalResult.future,
      ]);
      if (active.canonicalResult.isCompleted) {
        active.cancellation.cancel();
        await dispatch;
      }
      if (!_scopeActive(identity, generation, epoch)) {
        result = const ChatCommandClosed<EditMessageResult>();
      } else {
        result = await _settleResult(
          identity,
          generation,
          epoch,
          edit,
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

  Future<ChatCommandResult<EditMessageResult>> _settleResult(
    ApplicationChatStorageIdentity identity,
    int generation,
    int epoch,
    ChatQueuedMessageEdit edit,
    ChatCommandResult<EditMessageResult> result,
  ) async {
    if (result case ChatCommandSuccess<EditMessageResult>(:final value)) {
      if (!_resultMatches(identity, edit, value)) {
        return ChatCommandMalformedResponse<EditMessageResult>();
      }
      try {
        store.reconcileOptimisticMessageEdit(
            edit.request.idempotencyKey, value);
      } catch (_) {
        return ChatCommandMalformedResponse<EditMessageResult>();
      }
      await _remove(identity, generation, epoch, edit);
    } else if (_isTerminal(result)) {
      try {
        store.rollbackOptimisticMessageEdit(
          edit.request.messageId,
          edit.request.idempotencyKey,
        );
      } on StateError {
        // An externally owned store may close before the client.
      }
      await _remove(identity, generation, epoch, edit);
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
      await _raceMessageEditWait(
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

  static bool _sameStoredEdit(
    ApplicationChatQueuedMessageMutationIntent intent,
    ChatQueuedMessageEdit edit,
  ) =>
      intent.request is EditMessageRequest &&
      intent.enqueueOrder == edit.enqueueOrder &&
      DateTime.parse(intent.enqueuedAt.value).toUtc() == edit.enqueuedAt &&
      _sameJson(
        (intent.request as EditMessageRequest).toJson(),
        edit.request.toJson(),
      );

  static bool _sameEdit(
    ChatQueuedMessageEdit left,
    ChatQueuedMessageEdit right,
  ) =>
      left.enqueueOrder == right.enqueueOrder &&
      left.enqueuedAt == right.enqueuedAt &&
      _sameJson(left.request.toJson(), right.request.toJson());

  static bool _resultMatches(
    ApplicationChatStorageIdentity identity,
    ChatQueuedMessageEdit edit,
    EditMessageResult result,
  ) =>
      result.expectedRevision == edit.request.expectedRevision &&
      result.message.id == edit.request.messageId &&
      result.message.tenantId == identity.tenantId;

  static bool _isTerminal(ChatCommandResult<EditMessageResult> result) =>
      result is ChatCommandValidationFailure<EditMessageResult> ||
      result is ChatCommandAuthenticationFailure<EditMessageResult> ||
      result is ChatCommandConflict<EditMessageResult> ||
      result is ChatCommandFeatureDisabled<EditMessageResult> ||
      result is ChatCommandUnsupported<EditMessageResult> ||
      result is ChatCommandRejected<EditMessageResult>;

  static bool _isAmbiguous(ChatCommandResult<EditMessageResult> result) =>
      result is ChatCommandTransportFailure<EditMessageResult> ||
      result is ChatCommandMalformedResponse<EditMessageResult> ||
      result is ChatCommandAborted<EditMessageResult> ||
      result is ChatCommandClosed<EditMessageResult>;
}

final class _ActiveMessageEditDispatch {
  final ChatCommandCancellationController cancellation =
      ChatCommandCancellationController();
  final Completer<ChatCommandResult<EditMessageResult>> canonicalResult =
      Completer<ChatCommandResult<EditMessageResult>>();
  final Completer<ChatCommandResult<EditMessageResult>> result =
      Completer<ChatCommandResult<EditMessageResult>>();
}

bool _sameJson(Object? left, Object? right) =>
    jsonEncode(left) == jsonEncode(right);

Duration _defaultMessageEditRetryBackoff(int retryNumber) {
  final exponent = retryNumber <= 1 ? 0 : (retryNumber - 1).clamp(0, 5);
  return Duration(seconds: 1 << exponent);
}

Future<void> _defaultMessageEditRetryWait(
  Duration delay,
  ChatCommandCancellationSignal _,
) =>
    Future<void>.delayed(delay);

Future<void> _raceMessageEditWait(
  Future<void> future,
  ChatCommandCancellationSignal signal,
) {
  if (signal.isCancelled) {
    return Future<void>.error(const _MessageEditWaitInterrupted());
  }
  final completer = Completer<void>();
  late final StreamSubscription<void> subscription;
  subscription = signal.onCancelled.listen((_) {
    if (!completer.isCompleted) {
      completer.completeError(const _MessageEditWaitInterrupted());
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

final class _MessageEditWaitInterrupted implements Exception {
  const _MessageEditWaitInterrupted();
}
