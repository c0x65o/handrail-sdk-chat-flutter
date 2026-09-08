part of '../handrail_chat_client.dart';

/// Stable failure categories for root-thread opening.
enum ChatThreadOpeningErrorCode {
  validation('validation'),
  rootMessageUnavailable('root_message_unavailable'),
  authentication('authentication'),
  conflict('conflict'),
  http('http'),
  malformedResponse('malformed_response'),
  transport('transport'),
  aborted('aborted'),
  subscription('subscription'),
  reconciliation('reconciliation'),
  closed('closed');

  const ChatThreadOpeningErrorCode(this.value);

  final String value;
}

/// Root context from an authorized read, without synthetic message content.
enum ChatThreadRootContextStatus { available, deleted, unavailable }

/// Immutable lifecycle state for opening one canonical root thread.
sealed class ChatThreadOpeningState {
  const ChatThreadOpeningState({required this.rootMessageId});

  final MessageId rootMessageId;
  String get state;

  @override
  String toString() => '$runtimeType(state: $state)';
}

final class ChatThreadOpeningIdleState extends ChatThreadOpeningState {
  const ChatThreadOpeningIdleState({required super.rootMessageId});

  @override
  String get state => 'idle';
}

final class ChatThreadOpeningLoadingState extends ChatThreadOpeningState {
  const ChatThreadOpeningLoadingState({
    required super.rootMessageId,
    this.parentConversationId,
  });

  @override
  String get state => 'loading';

  final ConversationId? parentConversationId;
}

final class ChatThreadOpeningReadyState extends ChatThreadOpeningState {
  const ChatThreadOpeningReadyState({
    required super.rootMessageId,
    required this.parentConversationId,
    required this.threadConversation,
    this.reconciliationStatus,
    this.rootContextStatus = ChatThreadRootContextStatus.unavailable,
    this.rootMessage,
    this.detail,
  });

  @override
  String get state => 'ready';

  final ChatThreadRootContextStatus rootContextStatus;
  final Message? rootMessage;
  final ConversationDetailSnapshot? detail;

  final ConversationId parentConversationId;
  final ThreadConversation threadConversation;

  /// Null for existing-thread reads and the normalized legacy fast path.
  final ThreadCreationReconciliationStatus? reconciliationStatus;
}

final class ChatThreadOpeningErrorState extends ChatThreadOpeningState {
  const ChatThreadOpeningErrorState({
    required super.rootMessageId,
    required this.code,
    required this.message,
    this.parentConversationId,
    this.httpStatus,
  });

  @override
  String get state => 'error';

  final ChatThreadOpeningErrorCode code;
  final String message;
  final ConversationId? parentConversationId;
  final int? httpStatus;

  @override
  String toString() => '$runtimeType(state: $state, code: ${code.value}, '
      'httpStatus: $httpStatus)';
}

/// One consumer retain on a resolved root thread.
///
/// [release] is idempotent. The final live handle releases the controller's
/// single realtime conversation subscription.
final class ChatThreadOpenHandle {
  ChatThreadOpenHandle._({
    required this.state,
    required void Function() release,
  }) : _release = release;

  final ChatThreadOpeningReadyState state;
  final void Function() _release;
  bool _released = false;

  MessageId get rootMessageId => state.rootMessageId;
  ConversationId get conversationId => state.threadConversation.id;
  ThreadConversation get conversation => state.threadConversation;
  bool get isReleased => _released;

  void release() {
    if (_released) return;
    _released = true;
    _release();
  }

  @override
  String toString() => 'ChatThreadOpenHandle(isReleased: $_released)';
}

sealed class ChatThreadOpenResult {
  const ChatThreadOpenResult();

  String get status;
}

final class ChatThreadOpenSuccess extends ChatThreadOpenResult {
  const ChatThreadOpenSuccess(this.handle);

  final ChatThreadOpenHandle handle;

  @override
  String get status => 'success';
}

final class ChatThreadOpenFailure extends ChatThreadOpenResult {
  const ChatThreadOpenFailure(this.error);

  final ChatThreadOpeningErrorState error;

  @override
  String get status => 'error';
}

/// Existing-thread reads can fail before the canonical root identity is known.
/// Keep those results separate so legacy root-opening state stays non-nullable.
sealed class ChatExistingThreadOpenResult {
  const ChatExistingThreadOpenResult();
  String get status;
}

final class ChatExistingThreadOpenSuccess extends ChatExistingThreadOpenResult {
  const ChatExistingThreadOpenSuccess(this.handle);
  final ChatThreadOpenHandle handle;
  @override
  String get status => 'success';
}

final class ChatExistingThreadOpenFailure extends ChatExistingThreadOpenResult {
  const ChatExistingThreadOpenFailure({required this.code, this.httpStatus});
  final ChatThreadOpeningErrorCode code;
  final int? httpStatus;
  String get message => 'The existing thread could not be opened.';
  @override
  String get status => 'error';
}

typedef _ChatThreadConversationSubscriber
    = ChatRealtimeConversationSubscriptionRelease Function(
  ConversationId conversationId,
);
typedef _ChatThreadFollowCommand
    = Future<ChatCommandResult<SetThreadFollowResult>> Function(
  ConversationId threadId, {
  ChatCommandCancellationSignal? cancellationSignal,
});

/// Framework-neutral entry point for root-thread controllers.
final class ChatThreadsController {
  ChatThreadsController._({
    required ChatCommandDispatcher commandDispatcher,
    required NormalizedSnapshotStore normalizedState,
    required ChatCommandIdempotencyKeyGenerator generateIdempotencyKey,
    required _ChatThreadConversationSubscriber? subscribeConversation,
    required _ConversationSnapshotQueryReader snapshotQueries,
    required _ChatThreadFollowCommand followThread,
    required _ChatThreadFollowCommand unfollowThread,
  })  : _commandDispatcher = commandDispatcher,
        _normalizedState = normalizedState,
        _generateIdempotencyKey = generateIdempotencyKey,
        _subscribeConversation = subscribeConversation,
        _snapshotQueries = snapshotQueries,
        _followThread = followThread,
        _unfollowThread = unfollowThread;

  final ChatCommandDispatcher _commandDispatcher;
  final NormalizedSnapshotStore _normalizedState;
  final ChatCommandIdempotencyKeyGenerator _generateIdempotencyKey;
  final _ChatThreadConversationSubscriber? _subscribeConversation;
  final _ConversationSnapshotQueryReader _snapshotQueries;
  final Map<ConversationId, Future<Object>> _existingReads = {};
  final Map<ConversationId, ChatThreadOpeningController> _existingControllers =
      {};
  final Set<ChatCommandCancellationController> _readCancellations = {};
  final _ChatThreadFollowCommand _followThread;
  final _ChatThreadFollowCommand _unfollowThread;
  final Map<MessageId, ChatThreadOpeningController> _controllers = {};
  final Map<ConversationId, ChatThreadFollowController> _followControllers = {};
  bool _disposed = false;

  ChatThreadOpeningController forRoot(MessageId rootMessageId) =>
      _controllers.putIfAbsent(
        rootMessageId,
        () => ChatThreadOpeningController._(
          rootMessageId: rootMessageId,
          commandDispatcher: _commandDispatcher,
          normalizedState: _normalizedState,
          generateIdempotencyKey: _generateIdempotencyKey,
          subscribeConversation: _subscribeConversation,
          initiallyClosed: _disposed,
        ),
      );

  Future<ChatThreadOpenResult> open({required MessageId rootMessageId}) =>
      forRoot(rootMessageId).open();

  /// Starts a new named creation intent. Use the root controller's `retry()`
  /// after an ambiguous failure to retain its original name and key.
  Future<ChatThreadOpenResult> create({
    required MessageId rootMessageId,
    required String name,
    bool? initialFollow,
  }) =>
      forRoot(rootMessageId).create(name: name, initialFollow: initialFollow);

  /// Reads a canonical thread with fresh authorization on every open, including
  /// when a handle or cached identity already exists. No participation writes.
  Future<ChatExistingThreadOpenResult> openExistingThread(
      ConversationId threadId) async {
    if (_disposed) return _readFailure(ChatThreadOpeningErrorCode.closed);
    if (threadId.value.isEmpty || threadId.value.trim() != threadId.value) {
      return _readFailure(ChatThreadOpeningErrorCode.validation);
    }
    final read = _existingReads.putIfAbsent(threadId, () {
      late final Future<Object> tracked;
      tracked = _readExisting(threadId).whenComplete(() {
        if (identical(_existingReads[threadId], tracked)) {
          _existingReads.remove(threadId);
        }
      });
      return tracked;
    });
    final result = await read;
    if (_disposed) return _readFailure(ChatThreadOpeningErrorCode.closed);
    if (result is ChatExistingThreadOpenFailure) {
      // Existing handles must no longer retain delivery after a rejected read.
      final previous = _existingControllers.remove(threadId);
      await previous?.dispose();
      return result;
    }
    final ready = result as ChatThreadOpeningReadyState;
    final controller = _existingControllers.putIfAbsent(
        threadId,
        () => ChatThreadOpeningController._(
              rootMessageId: ready.rootMessageId,
              commandDispatcher: _commandDispatcher,
              normalizedState: _normalizedState,
              generateIdempotencyKey: _generateIdempotencyKey,
              subscribeConversation: _subscribeConversation,
              initiallyClosed: _disposed,
            ));
    final retained = controller._retainExisting(ready);
    if (retained is ChatThreadOpenFailure) {
      return _readFailure(retained.error.code,
          httpStatus: retained.error.httpStatus);
    }
    return ChatExistingThreadOpenSuccess(
        (retained as ChatThreadOpenSuccess).handle);
  }

  Future<Object> _readExisting(ConversationId threadId) async {
    final cancellation = ChatCommandCancellationController();
    _readCancellations.add(cancellation);
    final options =
        ChatSnapshotQueryOptions(cancellationSignal: cancellation.signal);
    try {
      final detailResult = await _snapshotQueries.getConversation(
          ConversationDetailSnapshotInput(conversationId: threadId),
          options: options);
      if (detailResult
          is! ChatSnapshotQuerySuccess<ConversationDetailSnapshot>) {
        return _readQueryFailure(detailResult);
      }
      final detail = detailResult.value;
      final thread = detail.conversation.summary.conversation;
      if (thread is! ThreadConversation || thread.id != threadId) {
        return _readFailure(ChatThreadOpeningErrorCode.malformedResponse);
      }
      final timelineResult = await _snapshotQueries.getMessageTimeline(
          MessageTimelineRequest(
              conversationId: threadId,
              direction: MessageTimelineDirection.backward,
              limit: 50),
          options: options);
      if (timelineResult is! ChatSnapshotQuerySuccess<MessageTimelinePage>) {
        return _readQueryFailure(timelineResult);
      }
      // A bounded, fresh source read. A missing/deleted source never prevents
      // reading authorized history, and cached content is never a substitute.
      final rootResult = await _snapshotQueries.getMessageTimeline(
          MessageTimelineRequest(
              conversationId: thread.parentConversationId,
              direction: MessageTimelineDirection.backward,
              limit: 50),
          options: options);
      Message? root;
      var rootStatus = ChatThreadRootContextStatus.unavailable;
      if (rootResult is ChatSnapshotQuerySuccess<MessageTimelinePage>) {
        for (final row in rootResult.value.messages) {
          if (row.id != thread.rootMessageId) continue;
          if (row.message is DeletedMessage) {
            rootStatus = ChatThreadRootContextStatus.deleted;
          } else {
            root = row.message;
            rootStatus = ChatThreadRootContextStatus.available;
          }
        }
      } else {
        // A failed parent read may hide access revocation (including 404).
        // Only a successful read may establish that the source is unavailable.
        return _readQueryFailure(rootResult);
      }
      if (_disposed) return _readFailure(ChatThreadOpeningErrorCode.closed);
      _normalizedState.hydrateConversationDetail(detail);
      _normalizedState.hydrateMessageTimeline(timelineResult.value);
      return ChatThreadOpeningReadyState(
        rootMessageId: thread.rootMessageId,
        parentConversationId: thread.parentConversationId,
        threadConversation: thread,
        rootContextStatus: rootStatus,
        rootMessage: root,
        detail: detail,
      );
    } catch (_) {
      return _readFailure(ChatThreadOpeningErrorCode.reconciliation);
    } finally {
      _readCancellations.remove(cancellation);
    }
  }

  ChatExistingThreadOpenFailure _readQueryFailure<T>(
      ChatSnapshotQueryResult<T> result) {
    final status =
        result is ChatSnapshotQueryFailure<T> ? result.httpStatus : null;
    final code = status == 401 || status == 403
        ? ChatThreadOpeningErrorCode.authentication
        : switch (result.category) {
            ChatSnapshotQueryResultCategory.authentication =>
              ChatThreadOpeningErrorCode.authentication,
            ChatSnapshotQueryResultCategory.validation =>
              ChatThreadOpeningErrorCode.validation,
            ChatSnapshotQueryResultCategory.malformedResponse =>
              ChatThreadOpeningErrorCode.malformedResponse,
            ChatSnapshotQueryResultCategory.aborted =>
              ChatThreadOpeningErrorCode.aborted,
            ChatSnapshotQueryResultCategory.closed =>
              ChatThreadOpeningErrorCode.closed,
            ChatSnapshotQueryResultCategory.rejected =>
              ChatThreadOpeningErrorCode.http,
            _ => ChatThreadOpeningErrorCode.transport,
          };
    return _readFailure(code, httpStatus: status);
  }

  ChatExistingThreadOpenFailure _readFailure(ChatThreadOpeningErrorCode code,
          {int? httpStatus}) =>
      ChatExistingThreadOpenFailure(code: code, httpStatus: httpStatus);

  /// Returns the headless follow controller for one canonical thread.
  ChatThreadFollowController forThread(ConversationId threadId) =>
      _followControllers.putIfAbsent(
        threadId,
        () => ChatThreadFollowController._(
          threadId: threadId,
          normalizedState: _normalizedState,
          followThread: _followThread,
          unfollowThread: _unfollowThread,
          initiallyClosed: _disposed,
        ),
      );

  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    for (final cancellation in _readCancellations) {
      cancellation.cancel();
    }
    final controllers = [
      ..._controllers.values,
      ..._existingControllers.values
    ];
    final followControllers = _followControllers.values.toList(growable: false);
    await Future.wait([
      ...controllers.map((controller) => controller.dispose()),
      ...followControllers.map((controller) => controller.dispose()),
    ]);
  }
}

final class _ResolvedThread {
  const _ResolvedThread(this.ready);

  final ChatThreadOpeningReadyState ready;
}

/// Opening state and retain coordination for one root message identifier.
final class ChatThreadOpeningController {
  ChatThreadOpeningController._({
    required this.rootMessageId,
    required ChatCommandDispatcher commandDispatcher,
    required NormalizedSnapshotStore normalizedState,
    required ChatCommandIdempotencyKeyGenerator generateIdempotencyKey,
    required _ChatThreadConversationSubscriber? subscribeConversation,
    required bool initiallyClosed,
  })  : _commandDispatcher = commandDispatcher,
        _normalizedState = normalizedState,
        _generateIdempotencyKey = generateIdempotencyKey,
        _subscribeConversation = subscribeConversation,
        _state = initiallyClosed
            ? ChatThreadOpeningErrorState(
                rootMessageId: rootMessageId,
                code: ChatThreadOpeningErrorCode.closed,
                message: _closedMessage,
              )
            : ChatThreadOpeningIdleState(rootMessageId: rootMessageId),
        _disposed = initiallyClosed {
    _states = _createStateStream();
    if (initiallyClosed) unawaited(_stateChanges.close());
  }

  final MessageId rootMessageId;
  final ChatCommandDispatcher _commandDispatcher;
  final NormalizedSnapshotStore _normalizedState;
  final ChatCommandIdempotencyKeyGenerator _generateIdempotencyKey;
  final _ChatThreadConversationSubscriber? _subscribeConversation;
  final StreamController<ChatThreadOpeningState> _stateChanges =
      StreamController<ChatThreadOpeningState>.broadcast(sync: true);
  late final Stream<ChatThreadOpeningState> _states;
  ChatThreadOpeningState _state;
  ThreadCreationInput? _creationInput;
  Future<Object>? _inFlight;
  ChatCommandCancellationController? _cancellation;
  ChatRealtimeConversationSubscriptionRelease? _releaseSubscription;
  var _retainCount = 0;
  bool _disposed;

  ChatThreadOpeningState get state => _state;

  /// A current-first broadcast stream for this root's opening lifecycle.
  Stream<ChatThreadOpeningState> get states => _states;

  /// Starts a new intent after a failure. Concurrent calls share the first
  /// operation; retries must call [retry] to preserve ambiguous-write identity.
  Future<ChatThreadOpenResult> create(
      {required String name, bool? initialFollow}) {
    if (_disposed || _inFlight != null) return open();
    try {
      validateThreadConversationName(name);
      if (_state is ChatThreadOpeningReadyState) return open();
      final parent = _normalizedState
              .state.canonicalMessages[rootMessageId]?.conversationId ??
          _knownThread()?.parentConversationId;
      if (parent == null) {
        final error = _error(ChatThreadOpeningErrorCode.rootMessageUnavailable,
            'The canonical thread root message is unavailable.');
        _emit(error);
        return Future.value(ChatThreadOpenFailure(error));
      }
      _creationInput = ThreadCreationInput(
        parentConversationId: parent,
        rootMessageId: rootMessageId,
        name: name,
        initialFollow: initialFollow,
        idempotencyKey: _generateIdempotencyKey(),
      );
    } catch (_) {
      final error = _error(ChatThreadOpeningErrorCode.validation,
          'The thread creation input is invalid.');
      // Invalid new intent must not disturb a live handle's subscription.
      if (_state is! ChatThreadOpeningReadyState) _emit(error);
      return Future.value(ChatThreadOpenFailure(error));
    }
    return open();
  }

  /// Repeats the frozen request after a failed or ambiguous attempt.
  Future<ChatThreadOpenResult> retry() => open();

  ChatThreadOpenResult _retainExisting(ChatThreadOpeningReadyState ready) {
    if (_disposed) return ChatThreadOpenFailure(_closedState);
    try {
      _releaseSubscription ??=
          _subscribeConversation?.call(ready.threadConversation.id);
    } catch (_) {
      return ChatThreadOpenFailure(_error(
          ChatThreadOpeningErrorCode.subscription,
          'The thread realtime subscription could not be established.'));
    }
    _retainCount += 1;
    _emit(ready);
    return ChatThreadOpenSuccess(_createHandle(ready));
  }

  Future<ChatThreadOpenResult> open() {
    if (_disposed) {
      return Future.value(ChatThreadOpenFailure(_closedState));
    }
    if (!_validRootMessageId(rootMessageId)) {
      final error = _error(
        ChatThreadOpeningErrorCode.validation,
        'The thread root message identifier is invalid.',
      );
      _emit(error);
      return Future.value(ChatThreadOpenFailure(error));
    }

    _retainCount += 1;
    if (_state case final ChatThreadOpeningReadyState ready) {
      return Future.value(ChatThreadOpenSuccess(_createHandle(ready)));
    }

    final active = _inFlight;
    if (active != null) return _resultFor(active);

    late final Future<Object> tracked;
    tracked = _resolve().whenComplete(() {
      if (identical(_inFlight, tracked)) _inFlight = null;
    });
    _inFlight = tracked;
    return _resultFor(tracked);
  }

  Future<ChatThreadOpenResult> _resultFor(Future<Object> operation) async {
    final resolved = await operation;
    if (resolved case _ResolvedThread(:final ready)) {
      if (_disposed) {
        _releaseConsumer();
        return ChatThreadOpenFailure(_closedState);
      }
      return ChatThreadOpenSuccess(_createHandle(ready));
    }
    _releaseConsumer();
    return ChatThreadOpenFailure(resolved as ChatThreadOpeningErrorState);
  }

  Future<Object> _resolve() async {
    final known = _creationInput == null ? _knownThread() : null;
    if (known case final ThreadConversation thread) {
      _emit(ChatThreadOpeningLoadingState(
        rootMessageId: rootMessageId,
        parentConversationId: thread.parentConversationId,
      ));
      return _finishResolution(thread, null);
    }

    final root = _normalizedState.state.canonicalMessages[rootMessageId];
    if (root == null && _creationInput == null) {
      final error = _error(
        ChatThreadOpeningErrorCode.rootMessageUnavailable,
        'The canonical thread root message is unavailable.',
      );
      _emit(error);
      return error;
    }
    final parentConversationId =
        _creationInput?.parentConversationId ?? root!.conversationId;
    late final ThreadCreationInput input;
    try {
      input = _creationInput ??= ThreadCreationInput(
        parentConversationId: parentConversationId,
        rootMessageId: rootMessageId,
        idempotencyKey: _generateIdempotencyKey(),
      );
      ThreadCreationInput.fromJson(input.toJson());
    } catch (_) {
      final error = _error(
        ChatThreadOpeningErrorCode.validation,
        'The thread creation input is invalid.',
        parentConversationId: parentConversationId,
      );
      _emit(error);
      return error;
    }

    _emit(ChatThreadOpeningLoadingState(
      rootMessageId: rootMessageId,
      parentConversationId: parentConversationId,
    ));
    final cancellation = ChatCommandCancellationController();
    _cancellation = cancellation;
    final command = await _commandDispatcher.dispatch(
      _threadCreationDescriptor(input),
      input,
      options: ChatCommandDispatchOptions(
        idempotencyKey: input.idempotencyKey,
        cancellationSignal: cancellation.signal,
      ),
    );
    if (identical(_cancellation, cancellation)) _cancellation = null;
    if (_disposed) return _closedState;
    if (command case ChatCommandSuccess<ThreadCreationResult>(:final value)) {
      return _finishResolution(
        value.conversation.thread,
        value.reconciliationStatus,
        result: value,
      );
    }
    final error = _commandError(command, parentConversationId);
    _emit(error);
    return error;
  }

  Object _finishResolution(
    ThreadConversation thread,
    ThreadCreationReconciliationStatus? reconciliationStatus, {
    ThreadCreationResult? result,
  }) {
    ChatRealtimeConversationSubscriptionRelease? release;
    try {
      release = _subscribeConversation?.call(thread.id);
    } catch (_) {
      final error = _error(
        ChatThreadOpeningErrorCode.subscription,
        'The thread realtime subscription could not be established.',
        parentConversationId: thread.parentConversationId,
      );
      _emit(error);
      return error;
    }
    if (_disposed) {
      release?.call();
      return _closedState;
    }
    try {
      if (result != null) _normalizedState.reconcileThreadOpening(result);
    } catch (_) {
      release?.call();
      final error = _error(
        ChatThreadOpeningErrorCode.reconciliation,
        'The canonical thread state could not be reconciled.',
        parentConversationId: thread.parentConversationId,
      );
      _emit(error);
      return error;
    }
    _releaseSubscription = release;
    _creationInput = null;
    final ready = ChatThreadOpeningReadyState(
      rootMessageId: rootMessageId,
      parentConversationId: thread.parentConversationId,
      threadConversation: thread,
      reconciliationStatus: reconciliationStatus,
    );
    _emit(ready);
    return _ResolvedThread(ready);
  }

  ThreadConversation? _knownThread() {
    ThreadConversation? found;
    for (final conversation in _normalizedState.state.conversations.values) {
      if (conversation is! ThreadConversation ||
          conversation.rootMessageId != rootMessageId) {
        continue;
      }
      if (found != null && found.id != conversation.id) return null;
      found = conversation;
    }
    return found;
  }

  ChatThreadOpeningErrorState _commandError(
    ChatCommandResult<ThreadCreationResult> result,
    ConversationId parentConversationId,
  ) {
    final code = switch (result.category) {
      ChatCommandResultCategory.validation =>
        ChatThreadOpeningErrorCode.validation,
      ChatCommandResultCategory.authentication =>
        ChatThreadOpeningErrorCode.authentication,
      ChatCommandResultCategory.conflict => ChatThreadOpeningErrorCode.conflict,
      ChatCommandResultCategory.malformedResponse =>
        ChatThreadOpeningErrorCode.malformedResponse,
      ChatCommandResultCategory.aborted => ChatThreadOpeningErrorCode.aborted,
      ChatCommandResultCategory.closed => ChatThreadOpeningErrorCode.closed,
      ChatCommandResultCategory.transport =>
        ChatThreadOpeningErrorCode.transport,
      ChatCommandResultCategory.featureDisabled ||
      ChatCommandResultCategory.unsupported ||
      ChatCommandResultCategory.rejected =>
        ChatThreadOpeningErrorCode.http,
      ChatCommandResultCategory.success => ChatThreadOpeningErrorCode.transport,
      ChatCommandResultCategory.queued => ChatThreadOpeningErrorCode.transport,
    };
    final failure = result as ChatCommandFailure<ThreadCreationResult>;
    return _error(
      code,
      code == ChatThreadOpeningErrorCode.closed
          ? _closedMessage
          : 'The thread could not be resolved.',
      parentConversationId: parentConversationId,
      httpStatus: failure.httpStatus,
    );
  }

  ChatThreadOpenHandle _createHandle(ChatThreadOpeningReadyState ready) =>
      ChatThreadOpenHandle._(state: ready, release: _releaseConsumer);

  void _releaseConsumer() {
    if (_retainCount == 0) return;
    _retainCount -= 1;
    if (_retainCount != 0 || _inFlight != null) return;
    final release = _releaseSubscription;
    _releaseSubscription = null;
    release?.call();
    if (!_disposed && _state is ChatThreadOpeningReadyState) {
      _emit(ChatThreadOpeningIdleState(rootMessageId: rootMessageId));
    }
  }

  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    _cancellation?.cancel();
    _cancellation = null;
    _retainCount = 0;
    final release = _releaseSubscription;
    _releaseSubscription = null;
    release?.call();
    _state = _closedState;
    if (!_stateChanges.isClosed) {
      _stateChanges.add(_state);
      await _stateChanges.close();
    }
  }

  ChatThreadOpeningErrorState get _closedState => ChatThreadOpeningErrorState(
        rootMessageId: rootMessageId,
        code: ChatThreadOpeningErrorCode.closed,
        message: _closedMessage,
      );

  ChatThreadOpeningErrorState _error(
    ChatThreadOpeningErrorCode code,
    String message, {
    ConversationId? parentConversationId,
    int? httpStatus,
  }) =>
      ChatThreadOpeningErrorState(
        rootMessageId: rootMessageId,
        code: code,
        message: message,
        parentConversationId: parentConversationId,
        httpStatus: httpStatus,
      );

  void _emit(ChatThreadOpeningState next) {
    if (_disposed || _stateChanges.isClosed) return;
    _state = next;
    _stateChanges.add(next);
  }

  Stream<ChatThreadOpeningState> _createStateStream() =>
      Stream<ChatThreadOpeningState>.multi(
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
}

ChatCommandDescriptor<ThreadCreationInput, ThreadCreationInput,
    ThreadCreationResult> _threadCreationDescriptor(
  ThreadCreationInput expectedInput,
) =>
    ChatCommandDescriptor.withPathBuilder(
      name: 'thread.create',
      method: ChatCommandMethod.post,
      pathBuilder: (input) =>
          '/messages/${Uri.encodeComponent(input.rootMessageId.value)}/thread',
      retrySafety: ChatCommandRetrySafety.safe,
      validateInput: (input) => ThreadCreationInput.fromJson(input.toJson()),
      parseResult: (value) => ThreadCreationResult.fromJson(
        value,
        expectedInput: expectedInput,
      ),
    );

bool _validRootMessageId(MessageId rootMessageId) =>
    rootMessageId.value.isNotEmpty &&
    rootMessageId.value.trim() == rootMessageId.value;

const String _closedMessage = 'The thread opening controller is closed.';
