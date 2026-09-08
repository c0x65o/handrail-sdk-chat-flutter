part of '../handrail_chat_client.dart';

/// Injectable wall clock used to produce durable FIFO projection metadata.
typedef ChatOfflineSendClock = DateTime Function();

/// Computes the delay before retrying an unsettled persisted send.
typedef ChatOfflineSendRetryBackoff = Duration Function(int retryNumber);

/// Injectable wait boundary for persisted-send retry scheduling.
typedef ChatOfflineSendRetryWait = Future<void> Function(
  Duration delay,
  ChatCommandCancellationSignal cancellationSignal,
);

/// One durable optimistic send projection.
///
/// The generated request supplies the complete later-dispatch contract while
/// [identity] supplies only the trusted storage scope. No authentication or
/// attachment byte-transfer state is retained.
final class ChatQueuedSendMessage {
  const ChatQueuedSendMessage._({
    required this.identity,
    required this.request,
    required this.enqueueOrder,
    required this.enqueuedAt,
  });

  final ApplicationChatStorageIdentity identity;
  final SendMessageRequest request;
  final int enqueueOrder;
  final DateTime enqueuedAt;

  ConversationId get conversationId => request.conversationId;
  MessageContent get content => request.content;
  String get clientMessageId => request.clientMessageId;
  String get idempotencyKey => request.idempotencyKey;
}

/// Immutable, framework-neutral state for durable optimistic sends.
final class ChatOfflineSendQueueState {
  ChatOfflineSendQueueState({
    required this.identity,
    required this.isHydrated,
    required List<ChatQueuedSendMessage> intents,
  }) : intents = List.unmodifiable(intents);

  const ChatOfflineSendQueueState.unconfigured()
      : identity = null,
        isHydrated = false,
        intents = const <ChatQueuedSendMessage>[];

  final ApplicationChatStorageIdentity? identity;
  final bool isHydrated;
  final List<ChatQueuedSendMessage> intents;
}

final class _OfflineSendMessageQueue {
  _OfflineSendMessageQueue({
    required ApplicationChatStorage storage,
    required ApplicationChatStorageIdentity? initialIdentity,
    required this.clock,
  })  : _mutator = ApplicationChatStorageMutator(storage),
        _identity = initialIdentity,
        _state = ChatOfflineSendQueueState(
          identity: initialIdentity,
          isHydrated: false,
          intents: const <ChatQueuedSendMessage>[],
        ) {
    _states = _createStateStream();
  }

  final ApplicationChatStorageMutator _mutator;
  final ChatOfflineSendClock clock;
  final StreamController<ChatOfflineSendQueueState> _stateChanges =
      StreamController<ChatOfflineSendQueueState>.broadcast(sync: true);
  late final Stream<ChatOfflineSendQueueState> _states;
  ChatOfflineSendQueueState _state;
  ApplicationChatStorageIdentity? _identity;
  Future<void> _operationTail = Future<void>.value();
  var _loaded = false;
  var _closed = false;

  ChatOfflineSendQueueState get state => _state;
  Stream<ChatOfflineSendQueueState> get states => _states;

  Future<void> ensureLoaded() => _serialized<void>(() async {
        _ensureOpen();
        if (_loaded) return;
        final identity = _identity;
        if (identity == null) return;
        await _load(identity);
      });

  Future<void> activate(ApplicationChatStorageIdentity identity) =>
      _serialized<void>(() async {
        _ensureOpen();
        if (_loaded && _identity == identity) return;
        await _load(identity);
      });

  Future<ChatQueuedSendMessage> enqueue(SendMessageRequest request) {
    // Validate the complete durable representation before any storage read.
    final validated = SendMessageRequest.fromJson(request.toJson());
    ApplicationChatQueuedSendMessageIntent(
      request: validated,
      enqueueOrder: 1,
      enqueuedAt: const IsoTimestamp('1970-01-01T00:00:00.000Z'),
    );
    return _serialized<ChatQueuedSendMessage>(() async {
      _ensureOpen();
      final identity = _identity;
      if (identity == null) {
        throw StateError(
          'A trusted storage identity is required for offline sends.',
        );
      }
      if (!_loaded) await _load(identity);

      final enqueuedAt = clock().toUtc();
      final committed =
          await _mutator.mutate<ApplicationChatQueuedSendMessageIntentsRecord>(
        identity,
        ApplicationChatStorageRecordKind.queuedSendMessageIntents,
        (current) {
          final intents = current?.intents ??
              const <ApplicationChatQueuedSendMessageIntent>[];
          if (intents.any((intent) =>
              intent.request.clientMessageId == validated.clientMessageId ||
              intent.request.idempotencyKey == validated.idempotencyKey)) {
            throw StateError('The send identity is already queued.');
          }
          if (intents.length >= maxApplicationChatQueuedSendIntents) {
            throw ArgumentError.value(
              intents.length + 1,
              'intents',
              'must contain at most 1000 entries',
            );
          }
          final enqueueOrder =
              intents.isEmpty ? 1 : intents.last.enqueueOrder + 1;
          return ApplicationChatQueuedSendMessageIntentsRecord(
            identity: identity,
            intents: <ApplicationChatQueuedSendMessageIntent>[
              ...intents,
              ApplicationChatQueuedSendMessageIntent(
                request: validated,
                enqueueOrder: enqueueOrder,
                enqueuedAt: IsoTimestamp(enqueuedAt.toIso8601String()),
              ),
            ],
          );
        },
      );
      final committedIntents = committed!.intents;
      final projections = _toProjections(identity, committedIntents);
      final projection = projections.firstWhere((intent) =>
          intent.clientMessageId == validated.clientMessageId &&
          intent.idempotencyKey == validated.idempotencyKey);
      // The mutation commit precedes both the public projection and outcome.
      _emit(ChatOfflineSendQueueState(
        identity: identity,
        isHydrated: true,
        intents: projections,
      ));
      return projection;
    });
  }

  Future<bool> cancel(String clientMessageId) => _serialized<bool>(() async {
        _ensureOpen();
        if (clientMessageId.trim().isEmpty) return false;
        final identity = _identity;
        if (identity == null) return false;
        if (!_loaded) await _load(identity);
        var removed = false;
        final committed = await _mutator
            .mutate<ApplicationChatQueuedSendMessageIntentsRecord>(
          identity,
          ApplicationChatStorageRecordKind.queuedSendMessageIntents,
          (current) {
            removed = false;
            if (current == null) return null;
            final next = current.intents.where((intent) {
              final matches = intent.request.clientMessageId == clientMessageId;
              if (matches) removed = true;
              return !matches;
            }).toList(growable: false);
            if (!removed) return current;
            if (next.isEmpty) return null;
            return ApplicationChatQueuedSendMessageIntentsRecord(
              identity: identity,
              intents: next,
            );
          },
        );
        _emit(ChatOfflineSendQueueState(
          identity: identity,
          isHydrated: true,
          intents: _toProjections(
            identity,
            committed?.intents ??
                const <ApplicationChatQueuedSendMessageIntent>[],
          ),
        ));
        return removed;
      });

  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    await _operationTail;
    await _stateChanges.close();
  }

  Future<void> _load(ApplicationChatStorageIdentity identity) async {
    ApplicationChatQueuedSendMessageIntentsRecord? record;
    try {
      record =
          await _mutator.mutate<ApplicationChatQueuedSendMessageIntentsRecord>(
        identity,
        ApplicationChatStorageRecordKind.queuedSendMessageIntents,
        (current) => current,
      );
    } on FormatException {
      // The helper has already quarantined only the exact malformed value.
      // Re-read through it so a concurrently installed valid value hydrates.
      try {
        record = await _mutator
            .mutate<ApplicationChatQueuedSendMessageIntentsRecord>(
          identity,
          ApplicationChatStorageRecordKind.queuedSendMessageIntents,
          (current) => current,
        );
      } on FormatException {
        record = null;
      }
    }

    final projections = _toProjections(
      identity,
      record?.intents ?? const <ApplicationChatQueuedSendMessageIntent>[],
    );
    _identity = identity;
    _loaded = true;
    _emit(ChatOfflineSendQueueState(
      identity: identity,
      isHydrated: true,
      intents: projections,
    ));
  }

  List<ChatQueuedSendMessage> _toProjections(
    ApplicationChatStorageIdentity identity,
    List<ApplicationChatQueuedSendMessageIntent> intents,
  ) =>
      intents
          .map((intent) => _toProjection(identity, intent))
          .toList(growable: false);

  ChatQueuedSendMessage _toProjection(
    ApplicationChatStorageIdentity identity,
    ApplicationChatQueuedSendMessageIntent intent,
  ) {
    final enqueuedAt = DateTime.tryParse(intent.enqueuedAt.value);
    if (enqueuedAt == null) {
      throw const FormatException('Stored send enqueue time is invalid.');
    }
    return ChatQueuedSendMessage._(
      identity: identity,
      request: intent.request,
      enqueueOrder: intent.enqueueOrder,
      enqueuedAt: enqueuedAt.toUtc(),
    );
  }

  Future<T> _serialized<T>(Future<T> Function() operation) {
    final completer = Completer<T>();
    _operationTail = _operationTail.then((_) async {
      try {
        completer.complete(await operation());
      } catch (error, stackTrace) {
        completer.completeError(error, stackTrace);
      }
    });
    return completer.future;
  }

  void _emit(ChatOfflineSendQueueState next) {
    _state = next;
    _stateChanges.add(next);
  }

  Stream<ChatOfflineSendQueueState> _createStateStream() =>
      Stream<ChatOfflineSendQueueState>.multi(
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

  void _ensureOpen() {
    if (_closed) throw StateError('The offline send queue is closed.');
  }
}

final class _OfflineSendMessagePump {
  _OfflineSendMessagePump({
    required this.queue,
    required this.dispatcher,
    required this.normalizedState,
    required this.backoff,
    required this.wait,
  });

  final _OfflineSendMessageQueue queue;
  final ChatCommandDispatcher dispatcher;
  final NormalizedSnapshotStore normalizedState;
  final ChatOfflineSendRetryBackoff backoff;
  final ChatOfflineSendRetryWait wait;
  final Set<Future<void>> _settlementOperations = <Future<void>>{};

  Future<void>? _pump;
  _OfflineSendDispatch? _active;
  var _restartRequested = false;
  var _metadataReady = false;
  var _connectivityOnline = false;
  var _realtimeConnected = false;
  var _closed = false;

  bool get _isReady =>
      !_closed &&
      _metadataReady &&
      _connectivityOnline &&
      _realtimeConnected &&
      queue.state.isHydrated;

  void updateReadiness({
    required bool metadataReady,
    required bool connectivityOnline,
    required bool realtimeConnected,
  }) {
    if (_closed) return;
    _metadataReady = metadataReady;
    _connectivityOnline = connectivityOnline;
    _realtimeConnected = realtimeConnected;
    if (!_isReady) {
      _active?.cancellation.cancel();
      return;
    }
    _start();
  }

  Future<void> settleCanonicalEvent(KnownDurableEvent event) {
    if (_closed ||
        !_realtimeConnected ||
        event is! MessageCreatedDurableEvent) {
      return Future<void>.value();
    }
    final clientMessageId = event.payload.data['clientMessageId'];
    if (clientMessageId is! String || clientMessageId.trim().isEmpty) {
      return Future<void>.value();
    }
    late final Future<void> operation;
    operation = _settleCanonicalClientMessage(
      clientMessageId,
      Message.fromJson(event.payload.data['message']),
    ).whenComplete(() => _settlementOperations.remove(operation));
    _settlementOperations.add(operation);
    return operation;
  }

  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    _active?.cancellation.cancel();
    final pump = _pump;
    if (pump != null) await pump;
    if (_settlementOperations.isNotEmpty) {
      await Future.wait(_settlementOperations.toList(growable: false));
    }
  }

  void _start() {
    if (!_isReady || queue.state.intents.isEmpty) return;
    if (_pump != null) {
      _restartRequested = true;
      return;
    }
    late final Future<void> pump;
    pump = _drain().whenComplete(() {
      if (identical(_pump, pump)) _pump = null;
      final restart = _restartRequested;
      _restartRequested = false;
      if (restart) _start();
    });
    _pump = pump;
    unawaited(pump);
  }

  Future<void> _drain() async {
    var retryNumber = 0;
    try {
      while (_isReady && queue.state.intents.isNotEmpty) {
        final intent = queue.state.intents.first;
        final active = _OfflineSendDispatch(intent.clientMessageId);
        _active = active;
        final dispatch = dispatcher.dispatch(
          _sendMessageDescriptor,
          intent.request.toJson(),
          options: ChatCommandDispatchOptions(
            idempotencyKey: intent.idempotencyKey,
            cancellationSignal: active.cancellation.signal,
          ),
        );
        final outcome = await Future.any<_OfflineSendOutcome>([
          dispatch.then<_OfflineSendOutcome>(_OfflineSendHttpOutcome.new),
          active.realtimeSettlement.future.then<_OfflineSendOutcome>(
            (_) => const _OfflineSendRealtimeOutcome(),
          ),
        ]);

        if (outcome is _OfflineSendRealtimeOutcome) {
          active.cancellation.cancel();
          await dispatch;
          retryNumber = 0;
          if (identical(_active, active)) _active = null;
          continue;
        }

        final result = (outcome as _OfflineSendHttpOutcome).result;
        if (active.realtimeSettlement.isCompleted) {
          retryNumber = 0;
          if (identical(_active, active)) _active = null;
          continue;
        }
        if (result case ChatCommandSuccess<SendMessageResult>(:final value)) {
          if (_matches(intent, value)) {
            normalizedState.reconcileMessage(value.message);
            await queue.cancel(intent.clientMessageId);
            retryNumber = 0;
            if (identical(_active, active)) _active = null;
            continue;
          }
        } else if (_isTerminal(result)) {
          await queue.cancel(intent.clientMessageId);
          retryNumber = 0;
          if (identical(_active, active)) _active = null;
          continue;
        }

        retryNumber += 1;
        final waited = await _waitBeforeRetry(retryNumber, active);
        if (active.realtimeSettlement.isCompleted) retryNumber = 0;
        if (identical(_active, active)) _active = null;
        if (!waited && !active.realtimeSettlement.isCompleted) return;
      }
    } catch (_) {
      // Storage, scheduler, and host transport edges are application-owned.
      // An unexpected failure must retain the current intent for restart.
    } finally {
      _active?.cancellation.cancel();
      _active = null;
    }
  }

  Future<void> _settleCanonicalClientMessage(
    String clientMessageId,
    Message message,
  ) async {
    // Canonical events include other members' messages. A client key only
    // acknowledges an intent within its tenant, author, and conversation.
    final matchesIntent = queue.state.intents.any((intent) =>
        intent.clientMessageId == clientMessageId &&
        intent.identity.tenantId == message.tenantId &&
        intent.identity.userId == message.author.userId &&
        intent.conversationId == message.conversationId);
    if (!matchesIntent) return;
    final removed = await queue.cancel(clientMessageId);
    if (!removed) return;
    final active = _active;
    if (active?.clientMessageId != clientMessageId) return;
    if (!active!.realtimeSettlement.isCompleted) {
      active.realtimeSettlement.complete();
    }
    active.cancellation.cancel();
  }

  Future<bool> _waitBeforeRetry(
    int retryNumber,
    _OfflineSendDispatch active,
  ) async {
    late final Duration delay;
    try {
      delay = backoff(retryNumber);
      if (delay.isNegative || delay > const Duration(seconds: 60)) {
        return false;
      }
    } catch (_) {
      return false;
    }
    final cancelled = Completer<void>();
    final subscription = active.cancellation.signal.onCancelled.listen((_) {
      if (!cancelled.isCompleted) cancelled.complete();
    });
    if (active.cancellation.signal.isCancelled && !cancelled.isCompleted) {
      cancelled.complete();
    }
    try {
      final completed = await Future.any<bool>([
        Future<void>.sync(
          () => wait(delay, active.cancellation.signal),
        ).then((_) => true),
        cancelled.future.then((_) => false),
      ]);
      return completed && _isReady;
    } catch (_) {
      return false;
    } finally {
      await subscription.cancel();
    }
  }

  static bool _matches(
    ChatQueuedSendMessage intent,
    SendMessageResult result,
  ) =>
      result.clientMessageId == intent.clientMessageId &&
      result.message.conversationId == intent.conversationId;

  static bool _isTerminal(ChatCommandResult<SendMessageResult> result) =>
      result is ChatCommandValidationFailure<SendMessageResult> ||
      result is ChatCommandConflict<SendMessageResult> ||
      result is ChatCommandFeatureDisabled<SendMessageResult> ||
      result is ChatCommandUnsupported<SendMessageResult> ||
      result is ChatCommandRejected<SendMessageResult>;
}

final class _OfflineSendDispatch {
  _OfflineSendDispatch(this.clientMessageId)
      : cancellation = ChatCommandCancellationController();

  final String clientMessageId;
  final ChatCommandCancellationController cancellation;
  final Completer<void> realtimeSettlement = Completer<void>();
}

sealed class _OfflineSendOutcome {
  const _OfflineSendOutcome();
}

final class _OfflineSendHttpOutcome extends _OfflineSendOutcome {
  const _OfflineSendHttpOutcome(this.result);

  final ChatCommandResult<SendMessageResult> result;
}

final class _OfflineSendRealtimeOutcome extends _OfflineSendOutcome {
  const _OfflineSendRealtimeOutcome();
}

Duration _defaultOfflineSendRetryBackoff(int retryNumber) {
  final exponent = retryNumber <= 1 ? 0 : (retryNumber - 1).clamp(0, 5);
  return Duration(seconds: 1 << exponent);
}

Future<void> _defaultOfflineSendRetryWait(
  Duration delay,
  ChatCommandCancellationSignal _,
) =>
    Future<void>.delayed(delay);
