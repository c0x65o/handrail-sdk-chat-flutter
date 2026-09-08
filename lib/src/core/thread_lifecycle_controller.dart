part of '../handrail_chat_client.dart';

/// Current host-authorized actor scope. Refresh this on host permission/access
/// changes; it is a UI gate, never a substitute for server authorization.
/// Absent authority disables all operations, including reads.
final class ChatThreadLifecycleAuthority {
  const ChatThreadLifecycleAuthority({
    required this.tenantId,
    required this.userId,
    this.canRead = false,
    this.canSend = false,
    this.canManage = false,
    this.parentArchived = false,
  });
  final TenantId tenantId;
  final UserId userId;
  final bool canRead;
  final bool canSend;
  final bool canManage;
  final bool parentArchived;
}

final class ChatThreadLifecycleCapabilities {
  const ChatThreadLifecycleCapabilities(
      {required this.supported,
      required this.canClose,
      required this.canReopen,
      required this.canLock,
      required this.canUnlock});
  final bool supported;
  final bool canClose;
  final bool canReopen;
  final bool canLock;
  final bool canUnlock;
}

enum ChatThreadLifecycleStatus {
  idle,
  loading,
  ready,
  saving,
  error,
  conflict,
  disposed
}

enum ChatThreadLifecycleError {
  unsupported,
  denied,
  validation,
  transport,
  malformedResponse,
  rejected,
  stale,
  disposed
}

final class ChatThreadLifecycleState {
  const ChatThreadLifecycleState(
      {required this.status,
      required this.capabilities,
      this.conversation,
      this.error,
      this.httpStatus,
      this.result,
      this.canRetry = false,
      this.isArchived = false,
      this.isParentArchived = false});
  final ChatThreadLifecycleStatus status;
  final ChatThreadLifecycleCapabilities capabilities;
  final ThreadConversation? conversation;
  final ChatThreadLifecycleError? error;
  final int? httpStatus;
  final ThreadLifecycleResult? result;
  final bool canRetry;
  ThreadLifecycle? get lifecycle => conversation == null
      ? null
      : conversation!.threadLifecycle ??
          ThreadLifecycle(revision: 1, locked: false);
  bool get isOpen => lifecycle != null && lifecycle!.closedAt == null;
  bool get isLocked => lifecycle?.locked ?? false;
  final bool isArchived;
  /// Parent archive restriction from trusted host authority or live snapshots.
  final bool isParentArchived;
  bool get isSaving => status == ChatThreadLifecycleStatus.saving;
  String? get errorMessage => error == null
      ? null
      : 'The thread lifecycle operation could not be completed.';
}

/// Client-owned controllers share canonical snapshots and realtime subscriptions.
final class ChatThreadLifecyclesController {
  ChatThreadLifecyclesController._(this._client) {
    _metadata = _client.states.listen((_) {
      for (final controller in _controllers.values) {
        controller._publish();
      }
    });
    _subscriptions =
        _client.realtimeSession?.conversationSubscriptionStates.listen((state) {
      if (state is ChatRealtimeConversationSubscriptionRevokedState ||
          state is ChatRealtimeConversationSubscriptionRejectedState) {
        _revoke(state.conversationId, deferRelease: true);
      }
    });
    _realtime = _client.realtimeSession?.states.listen((state) {
      final reconnect = state is ChatRealtimeConnectedState && !_connected;
      _connected = state is ChatRealtimeConnectedState;
      for (final controller in _controllers.values) {
        if (state is ChatRealtimeConnectedState) {
          if (!controller._matchesActor(
              state.identity.tenantId, state.identity.userId)) {
            controller.setAuthority(null);
          } else if (reconnect && controller._loadRequested) {
            unawaited(controller.load());
          }
        } else {
          controller._interrupt();
          controller._publish();
        }
      }
    });
  }
  final HandrailChatClient _client;
  final Map<ConversationId, ChatThreadLifecycleController> _controllers = {};
  late final StreamSubscription<ChatClientLifecycleState> _metadata;
  StreamSubscription<ChatRealtimeLifecycleState>? _realtime;
  StreamSubscription<ChatRealtimeConversationSubscriptionState>? _subscriptions;
  bool _disposed = false;
  bool _connected = false;

  ChatThreadLifecycleController forThread(ConversationId threadId) {
    if (_disposed) {
      throw StateError('Thread lifecycle controllers are disposed.');
    }
    return _controllers.putIfAbsent(
        threadId, () => ChatThreadLifecycleController._(this, threadId));
  }

  void _invalidateIdentity() {
    for (final controller in _controllers.values) {
      controller.setAuthority(null);
    }
  }

  void _revoke(ConversationId id, {bool deferRelease = false}) {
    for (final controller in _controllers.values) {
      if (controller.threadId == id ||
          controller._conversation?.parentConversationId == id) {
        // Subscription state streams are synchronous. Invalidate immediately,
        // but release outside that stream's delivery to avoid reentrant events.
        if (deferRelease) {
          final release = controller._release;
          controller._release = null;
          if (release != null) scheduleMicrotask(release);
        }
        controller.setAuthority(null);
      }
    }
  }

  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    await _metadata.cancel();
    await _realtime?.cancel();
    await _subscriptions?.cancel();
    for (final controller in _controllers.values) {
      await controller.dispose();
    }
    _controllers.clear();
  }
}

/// Explicit shared transitions. No drafts, sends, follow state, navigation or
/// durable queue are owned here. Call [retry] for an ambiguous write; calling a
/// transition method deliberately starts a new logical request.
final class ChatThreadLifecycleController {
  ChatThreadLifecycleController._(this._owner, this.threadId) {
    _snapshots =
        _client.normalizedState.watchConversation(threadId).listen((snapshot) {
      if (_authority == null || !_loaded) return;
      final conversation = snapshot.conversation;
      if (conversation is! ThreadConversation) {
        setAuthority(null);
        return;
      }
      _conversation = conversation;
      _publish();
    });
    _state = _buildState();
  }
  final ChatThreadLifecyclesController _owner;
  final ConversationId threadId;
  HandrailChatClient get _client => _owner._client;
  final _changes =
      StreamController<ChatThreadLifecycleState>.broadcast(sync: true);
  late final StreamSubscription<NormalizedConversationSnapshot> _snapshots;
  late ChatThreadLifecycleState _state;
  ChatThreadLifecycleAuthority? _authority;
  ThreadConversation? _conversation;
  ChatThreadLifecycleStatus _status = ChatThreadLifecycleStatus.idle;
  ChatThreadLifecycleError? _error;
  int? _httpStatus;
  ThreadLifecycleResult? _result;
  ThreadLifecycleInput? _request;
  ChatThreadLifecycleAuthority? _requestAuthority;
  int? _requestIdentityGeneration;
  ChatCommandCancellationController? _writeCancellation;
  ChatCommandCancellationController? _readCancellation;
  StreamSubscription<NormalizedConversationSnapshot>? _parentSnapshots;
  ChatRealtimeConversationSubscriptionRelease? _release;
  Future<ChatThreadLifecycleState>? _writing;
  int _generation = 0;
  int _readGeneration = 0;
  bool _loaded = false;
  bool _loadRequested = false;
  bool _disposed = false;

  ChatThreadLifecycleState get state => _state;
  Stream<ChatThreadLifecycleState> get states => Stream.multi((events) {
        events.add(_state);
        final subscription =
            _changes.stream.listen(events.add, onDone: events.close);
        events.onCancel = subscription.cancel;
      }, isBroadcast: true);

  /// Invalidates outstanding reads/writes even when the same actor regains
  /// access. Supply a fresh authority after an actor or access generation change.
  void setAuthority(ChatThreadLifecycleAuthority? authority) {
    if (_disposed) return;
    _interrupt();
    _release?.call();
    _release = null;
    unawaited(_parentSnapshots?.cancel());
    _parentSnapshots = null;
    _authority = authority;
    _conversation = null;
    _loaded = false;
    _loadRequested = false;
    _request = null;
    _httpStatus = null;
    _result = null;
    _error = authority == null ? ChatThreadLifecycleError.denied : null;
    _status = authority == null
        ? ChatThreadLifecycleStatus.error
        : ChatThreadLifecycleStatus.idle;
    _publish();
  }

  bool _matchesActor(TenantId tenant, UserId user) =>
      _authority?.tenantId == tenant && _authority?.userId == user;
  bool get _actorValid {
    final authority = _authority;
    if (authority == null || !authority.canRead) return false;
    final identity = _client._forwardIdentity;
    if (identity != null &&
        !_matchesActor(identity.tenantId, identity.userId)) {
      return false;
    }
    final realtime = _client.realtimeSession?.state;
    if (realtime != null &&
        (realtime is! ChatRealtimeConnectedState ||
            !_matchesActor(
                realtime.identity.tenantId, realtime.identity.userId))) {
      return false;
    }
    return true;
  }

  bool _archived(ConversationId? id) {
    if (id == null) return false;
    final store = _client.normalizedState.state;
    return store.lifecycleArchivedStates[id] ??
        (store.conversations[id]?.archivedAt != null);
  }

  ChatThreadLifecycleCapabilities get _capabilities {
    final metadata = _client.state;
    final realtime = _client.realtimeSession?.state;
    final supported = !_disposed &&
        metadata is ChatClientReadyState &&
        metadata.negotiatedCapabilities[ChatReplyThreadFeatures.threadLifecycle] == true &&
        (realtime == null ||
            realtime is ChatRealtimeConnectedState &&
                realtime.metadata.enabledFeatures[ChatReplyThreadFeatures.threadLifecycle] ==
                    true);
    final parentId = _conversation?.parentConversationId;
    final archived = _authority?.parentArchived == true ||
        _archived(threadId) ||
        _archived(parentId);
    final eligible = supported &&
        _actorValid &&
        _loaded &&
        _conversation != null &&
        !archived;
    final manage = eligible && _authority!.canManage;
    return ChatThreadLifecycleCapabilities(
        supported: supported,
        canClose: manage,
        canLock: manage,
        canUnlock: manage,
        canReopen: eligible &&
            _authority!.canSend &&
            !(_conversation?.threadLifecycle?.locked ?? false));
  }

  /// Fresh parent-authorized detail read, also run automatically on reconnect.
  Future<ChatThreadLifecycleState> load() async {
    if (_disposed) return _state;
    if (!_actorValid) return _fail(ChatThreadLifecycleError.denied);
    _loadRequested = true;
    final generation = _generation,
        identity = _client._storageIdentityGeneration;
    final read = ++_readGeneration;
    _readCancellation?.cancel();
    final cancellation =
        _readCancellation = ChatCommandCancellationController();
    if (_status != ChatThreadLifecycleStatus.saving &&
        _status != ChatThreadLifecycleStatus.conflict &&
        !(_status == ChatThreadLifecycleStatus.error && _request != null)) {
      _status = ChatThreadLifecycleStatus.loading;
    }
    _publish();
    final response = await _client._snapshotQueries.getConversation(
        ConversationDetailSnapshotInput(conversationId: threadId),
        options:
            ChatSnapshotQueryOptions(cancellationSignal: cancellation.signal));
    if (!_current(generation, identity) || read != _readGeneration) {
      return _state;
    }
    if (response is! ChatSnapshotQuerySuccess<ConversationDetailSnapshot>) {
      final status =
          response is ChatSnapshotQueryFailure<ConversationDetailSnapshot>
              ? response.httpStatus
              : null;
      if (status == 401 || status == 403 || status == 404) {
        setAuthority(null);
        return _fail(ChatThreadLifecycleError.denied, httpStatus: status);
      }
      return _fail(
          response.category == ChatSnapshotQueryResultCategory.malformedResponse
              ? ChatThreadLifecycleError.malformedResponse
              : ChatThreadLifecycleError.transport,
          httpStatus: status);
    }
    final thread = response.value.conversation.summary.conversation;
    if (thread is! ThreadConversation ||
        thread.id != threadId ||
        thread.tenantId != _authority!.tenantId ||
        response.value.conversation.summary.currentReadState.userId !=
            _authority!.userId) {
      return _fail(ChatThreadLifecycleError.malformedResponse);
    }
    try {
      _client.normalizedState.hydrateConversationDetail(response.value);
      _conversation = _client.normalizedState.state.conversations[threadId]
          as ThreadConversation;
      _loaded = true;
      _parentSnapshots ??= _client.normalizedState
          .watchConversation(thread.parentConversationId)
          .listen((_) => _publish());
      _release ??= _client.realtimeSession?.subscribeConversation(threadId);
      if (_status == ChatThreadLifecycleStatus.loading ||
          _status == ChatThreadLifecycleStatus.idle) {
        _status = ChatThreadLifecycleStatus.ready;
        _error = null;
      }
      _publish();
    } catch (_) {
      return _fail(ChatThreadLifecycleError.malformedResponse);
    }
    return _state;
  }

  Future<ChatThreadLifecycleState> close() =>
      _start(ThreadLifecycleIntent.close);
  Future<ChatThreadLifecycleState> reopen() =>
      _start(ThreadLifecycleIntent.reopen);
  Future<ChatThreadLifecycleState> lock() => _start(ThreadLifecycleIntent.lock);
  Future<ChatThreadLifecycleState> unlock() =>
      _start(ThreadLifecycleIntent.unlock);

  bool _allowed(ThreadLifecycleIntent intent) => switch (intent) {
        ThreadLifecycleIntent.close => _capabilities.canClose,
        ThreadLifecycleIntent.reopen => _capabilities.canReopen,
        ThreadLifecycleIntent.lock => _capabilities.canLock,
        ThreadLifecycleIntent.unlock => _capabilities.canUnlock,
      };

  Future<ChatThreadLifecycleState> _start(ThreadLifecycleIntent intent) {
    if (_disposed) return Future.value(_state);
    if (_writing != null) return _writing!;
    if (!_allowed(intent)) {
      return Future.value(_fail(_capabilities.supported
          ? ChatThreadLifecycleError.denied
          : ChatThreadLifecycleError.unsupported));
    }
    try {
      _request = ThreadLifecycleInput.fromJson(ThreadLifecycleInput(
              intent: intent,
              threadId: threadId,
              expectedLifecycleRevision:
                  _conversation!.threadLifecycle?.revision ?? 1,
              idempotencyKey: _client._generateCommandIdempotencyKey())
          .toJson());
      _requestAuthority = _authority;
      _requestIdentityGeneration = _client._storageIdentityGeneration;
    } catch (_) {
      return Future.value(_fail(ChatThreadLifecycleError.validation));
    }
    return _dispatch();
  }

  /// Retries the exact actor, destination, intent, revision and key. A canonical
  /// conflict remains explicit until the caller chooses a new transition.
  Future<ChatThreadLifecycleState> retry() {
    if (_disposed || _status == ChatThreadLifecycleStatus.conflict) {
      return Future.value(_state);
    }
    if (_writing != null) return _writing!;
    if (!_canRetry) return Future.value(_state);
    return _dispatch();
  }

  bool get _canRetry =>
      !_disposed &&
      _request != null &&
      identical(_requestAuthority, _authority) &&
      _requestIdentityGeneration == _client._storageIdentityGeneration &&
      _status == ChatThreadLifecycleStatus.error &&
      _error == ChatThreadLifecycleError.transport &&
      _allowed(_request!.intent);

  Future<ChatThreadLifecycleState> _dispatch() {
    late final Future<ChatThreadLifecycleState> tracked;
    tracked = _perform().whenComplete(() {
      if (identical(_writing, tracked)) _writing = null;
    });
    _writing = tracked;
    return tracked;
  }

  Future<ChatThreadLifecycleState> _perform() async {
    final request = _request!;
    final generation = _generation,
        identity = _client._storageIdentityGeneration;
    final cancellation =
        _writeCancellation = ChatCommandCancellationController();
    _status = ChatThreadLifecycleStatus.saving;
    _httpStatus = null;
    _error = null;
    _result = null;
    _publish();
    final response = await _client._commandDispatcher.dispatch(
        _threadLifecycleDescriptor(request), request,
        options: ChatCommandDispatchOptions(
            idempotencyKey: request.idempotencyKey,
            cancellationSignal: cancellation.signal));
    if (!_current(generation, identity)) return _state;
    if (response is ChatCommandSuccess<ThreadLifecycleResult>) {
      try {
        _client.normalizedState
            .reconcileThreadLifecycle(threadId, response.value.threadLifecycle);
        _conversation = _client.normalizedState.state.conversations[threadId]
            as ThreadConversation;
        _result = response.value;
        _status = _result!.reconciliationStatus ==
                ThreadLifecycleReconciliationStatus.lifecycleConflict
            ? ChatThreadLifecycleStatus.conflict
            : ChatThreadLifecycleStatus.ready;
        _publish();
      } catch (_) {
        return _fail(ChatThreadLifecycleError.malformedResponse);
      }
      return _state;
    }
    final failure = response as ChatCommandFailure<ThreadLifecycleResult>;
    if (failure.httpStatus == 401 ||
        failure.httpStatus == 403 ||
        failure.httpStatus == 404) {
      setAuthority(null);
      return _fail(ChatThreadLifecycleError.denied,
          httpStatus: failure.httpStatus);
    }
    return _fail(
        switch (response.category) {
          ChatCommandResultCategory.transport =>
            ChatThreadLifecycleError.transport,
          ChatCommandResultCategory.malformedResponse =>
            ChatThreadLifecycleError.malformedResponse,
          _ => ChatThreadLifecycleError.rejected,
        },
        httpStatus: failure.httpStatus);
  }

  bool _current(int generation, int identity) =>
      !_disposed &&
      generation == _generation &&
      identity == _client._storageIdentityGeneration &&
      _actorValid;
  void _interrupt() {
    ++_generation;
    ++_readGeneration;
    _readCancellation?.cancel();
    _writeCancellation?.cancel();
    _writing = null;
    if (_status == ChatThreadLifecycleStatus.saving) {
      _status = ChatThreadLifecycleStatus.error;
      _error = ChatThreadLifecycleError.transport;
    }
  }

  ChatThreadLifecycleState _fail(ChatThreadLifecycleError error,
      {int? httpStatus}) {
    _status = ChatThreadLifecycleStatus.error;
    _error = error;
    _httpStatus = httpStatus;
    _publish();
    return _state;
  }

  ChatThreadLifecycleState _buildState() => ChatThreadLifecycleState(
      status: _status,
      capabilities: _capabilities,
      isArchived: _conversation != null && _archived(threadId),
      isParentArchived: _authority?.parentArchived == true ||
          _archived(_conversation?.parentConversationId),
      conversation: _conversation,
      error: _error,
      httpStatus: _httpStatus,
      result: _result,
      canRetry: _canRetry);
  void _publish() {
    if (_disposed) return;
    _state = _buildState();
    _changes.add(_state);
  }

  Future<void> dispose() async {
    if (_disposed) return;
    _interrupt();
    _disposed = true;
    _release?.call();
    _release = null;
    await _snapshots.cancel();
    await _parentSnapshots?.cancel();
    _conversation = null;
    _status = ChatThreadLifecycleStatus.disposed;
    _state = _buildState();
    _changes.add(_state);
    await _changes.close();
  }
}

ChatCommandDescriptor<ThreadLifecycleInput, Map<String, Object?>,
    ThreadLifecycleResult> _threadLifecycleDescriptor(
        ThreadLifecycleInput request) =>
    ChatCommandDescriptor(
      name: 'thread.lifecycle.update',
      method: ChatCommandMethod.patch,
      path:
          '/conversations/${Uri.encodeComponent(request.threadId.value)}/lifecycle',
      retrySafety: ChatCommandRetrySafety.safe,
      validateInput: (input) =>
          ThreadLifecycleInput.fromJson(input.toJson()).toHttpBody(),
      parseResult: (json) {
        final result =
            ThreadLifecycleResult.fromJson(json, expectedInput: request);
        if (result.reconciliationStatus ==
            ThreadLifecycleReconciliationStatus.lifecycleConflict) {
          throw const FormatException('Conflict requires HTTP 409.');
        }
        return result;
      },
      parseErrorResult: (json, status) {
        if (status != 409 || json is! Map || !json.containsKey('operation')) {
          return null;
        }
        final result =
            ThreadLifecycleResult.fromJson(json, expectedInput: request);
        if (result.reconciliationStatus !=
            ThreadLifecycleReconciliationStatus.lifecycleConflict) {
          throw const FormatException('HTTP 409 requires conflict.');
        }
        return result;
      },
    );
