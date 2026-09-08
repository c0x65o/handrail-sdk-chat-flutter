part of '../handrail_chat_client.dart';

/// Trusted host identity/access scope. Every assignment starts a new generation.
/// Server authorization still runs on every read. Hosts must update this when
/// token-provider identity or access changes outside the client's realtime APIs.
final class ChatMessageContextAuthority {
  const ChatMessageContextAuthority({
    required this.tenantId,
    required this.userId,
    this.canRead = false,
  });
  final TenantId tenantId;
  final UserId userId;
  final bool canRead;
}

enum ChatMessageContextStatus {
  idle,
  loading,
  available,
  deleted,
  unavailable,
  error,
  disposed
}

/// Ephemeral source and adjacent context; never installed in durable state.
/// Consumers must replace previously rendered snapshots on controller changes.
final class ChatMessageContextState {
  ChatMessageContextState({
    required this.status,
    this.result,
    this.error,
    List<MessageTimelineMessage> before = const [],
    List<MessageTimelineMessage> after = const [],
    this.canLoadBefore = false,
    this.canLoadAfter = false,
    this.isLoadingPage = false,
  })  : before = List.unmodifiable(before),
        after = List.unmodifiable(after);
  final ChatMessageContextStatus status;
  final MessageContextResult? result;
  final ChatSnapshotQueryFailure<Object?>? error;
  final List<MessageTimelineMessage> before, after;
  final bool canLoadBefore, canLoadAfter, isLoadingPage;
  ActiveMessage? get source => switch (result) {
        AvailableMessageContext(:final message) => message,
        _ => null,
      };
  bool get canRetry => status == ChatMessageContextStatus.error;
}

extension ChatMessageContextQueries on HandrailChatClient {
  Future<ChatSnapshotQueryResult<MessageContextResult>> getMessageContext(
    MessageContextRequest input, {
    ChatSnapshotQueryOptions options = const ChatSnapshotQueryOptions(),
  }) {
    final request = MessageContextRequest.fromJson(input.toJson());
    return _snapshotQueries._run<MessageContextResult>(
      query: ChatSnapshotQueryName.messageContext,
      uri: _snapshotEndpointUri(_snapshotQueries.apiBaseUri, [
        'conversations',
        request.conversationId.value,
        'messages',
        request.messageId.value,
        'context',
      ]),
      options: options,
      parse: (json) =>
          MessageContextResult.fromJson(json, expectedRequest: request),
    );
  }
}

/// One shared controller per source, deduplicating reads across consumers.
/// A surface should dispose its controller only after its consumers detach.
final class ChatMessageContextsController {
  ChatMessageContextsController._(this._client) {
    _subscriptions =
        _client.realtimeSession?.conversationSubscriptionStates.listen((s) {
      if (s is ChatRealtimeConversationSubscriptionRevokedState ||
          s is ChatRealtimeConversationSubscriptionRejectedState) {
        _revoke(s.conversationId);
      }
    });
    _realtime = _client.realtimeSession?.states.listen((s) {
      final connected = s is ChatRealtimeConnectedState;
      final reconnect = connected && !_connected;
      _connected = connected;
      for (final c in _controllers.values.toList()) {
        if (s is ChatRealtimeConnectedState) {
          if (!c._matches(s.identity.tenantId, s.identity.userId)) {
            c.setAuthority(null);
          } else if (reconnect && c._requested) {
            c._invalidate(ChatMessageContextStatus.idle);
            unawaited(c.load());
          }
        } else {
          c._invalidate(ChatMessageContextStatus.idle);
        }
      }
    });
  }
  final HandrailChatClient _client;
  final _controllers =
      <(ConversationId, MessageId), ChatMessageContextController>{};
  StreamSubscription<ChatRealtimeConversationSubscriptionState>? _subscriptions;
  StreamSubscription<ChatRealtimeLifecycleState>? _realtime;
  bool _connected = false, _disposed = false;

  ChatMessageContextController forMessage(MessageContextRequest request,
      {int pageSize = 30}) {
    if (_disposed) throw StateError('Message contexts are disposed.');
    if (pageSize < messageTimelineMinimumLimit ||
        pageSize > messageTimelineMaximumLimit) {
      throw RangeError.range(
          pageSize, messageTimelineMinimumLimit, messageTimelineMaximumLimit);
    }
    return _controllers.putIfAbsent((request.conversationId, request.messageId),
        () => ChatMessageContextController._(this, request, pageSize));
  }

  void _invalidateIdentity() {
    for (final c in _controllers.values.toList()) {
      c.setAuthority(null);
    }
  }

  void _revoke(ConversationId id) {
    for (final c in _controllers.values.toList()) {
      // Until detail resolves, any revoked parent could own this source.
      if (!c._scopeResolved ||
          id == c.request.conversationId ||
          id == c._parent) {
        c.setAuthority(null);
      }
    }
  }

  void _event(KnownDurableEvent event) {
    if (event is! MessageUpdatedDurableEvent &&
        event is! MessageDeletedDurableEvent) {
      return;
    }
    final message = Message.fromJson(event.payload.data['message']);
    for (final c in _controllers.values.toList()) {
      c._changed(message);
    }
  }

  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    // Clear text synchronously before awaiting stream teardown.
    final closing = [for (final c in _controllers.values.toList()) c.dispose()];
    await _subscriptions?.cancel();
    await _realtime?.cancel();
    await Future.wait(closing);
  }
}

final class ChatMessageContextController {
  ChatMessageContextController._(this._owner, this.request, this.pageSize) {
    _commits = _client.normalizedState.acceptedCommitChanges.listen((s) {
      if (_authority == null || _disposed) return;
      final denied = _deniedScopes(s);
      final newlyDenied = denied.difference(_denied);
      _denied = denied;
      if (denied.contains(_parent ?? request.conversationId) ||
          !_scopeResolved && newlyDenied.isNotEmpty) {
        setAuthority(null);
        return;
      }
      for (final id in {
        request.messageId,
        ..._before.map((m) => m.id),
        ..._after.map((m) => m.id)
      }) {
        final message = s.canonicalMessages[id];
        if (message != null) _changed(message);
      }
    });
  }
  final ChatMessageContextsController _owner;
  HandrailChatClient get _client => _owner._client;
  final MessageContextRequest request;
  final int pageSize;
  final _changes =
      StreamController<ChatMessageContextState>.broadcast(sync: true);
  late final StreamSubscription<NormalizedSnapshotState> _commits;
  ChatMessageContextState _state =
      ChatMessageContextState(status: ChatMessageContextStatus.idle);
  ChatMessageContextState get state => _state;
  ChatMessageContextAuthority? _authority;
  ConversationId? _parent;
  bool _scopeResolved = false, _disposed = false, _requested = false;
  int _generation = 0;
  Future<ChatMessageContextState>? _pending;
  ChatCommandCancellationController? _cancellation;
  final _releases =
      <ConversationId, ChatRealtimeConversationSubscriptionRelease>{};
  // Revision floors contain no text and survive invalidation until identity changes.
  final _revisions = <MessageId, int>{};
  final _deleted = <MessageId>{};
  Set<ConversationId> _denied = {};
  final _before = <MessageTimelineMessage>[],
      _after = <MessageTimelineMessage>[];
  MessageSequence? _beforeCursor, _afterCursor;

  Stream<ChatMessageContextState> get states => Stream.multi((events) {
        events.add(_state);
        if (_disposed) {
          events.close();
          return;
        }
        final subscription =
            _changes.stream.listen(events.add, onDone: events.close);
        events.onCancel = subscription.cancel;
      }, isBroadcast: true);

  /// Pass to the existing ChatDeepLinkResolver.resolveTarget for host navigation.
  /// Reading context itself never opens or creates a thread.
  ChatDeepLinkTarget get navigationTarget => _parent == null
      ? ChatMessageDeepLinkTarget(
          conversationId: request.conversationId, messageId: request.messageId)
      : ChatExistingThreadDeepLinkTarget(
          threadId: request.conversationId, messageId: request.messageId);

  bool _matches(TenantId tenant, UserId user) =>
      _authority?.tenantId == tenant && _authority?.userId == user;
  bool get _allowed {
    if (_disposed || _client._disposed || _authority?.canRead != true) {
      return false;
    }
    final identity = _client._forwardIdentity;
    if (identity != null && !_matches(identity.tenantId, identity.userId)) {
      return false;
    }
    final realtime = _client.realtimeSession?.state;
    return realtime == null ||
        realtime is ChatRealtimeConnectedState &&
            _matches(realtime.identity.tenantId, realtime.identity.userId);
  }

  void setAuthority(ChatMessageContextAuthority? authority) {
    if (_disposed) return;
    final sameIdentity =
        authority != null && _matches(authority.tenantId, authority.userId);
    _authority = authority;
    _denied = _deniedScopes(_client.normalizedState.state);
    _requested = false;
    _invalidate(
        authority?.canRead == true
            ? ChatMessageContextStatus.idle
            : ChatMessageContextStatus.unavailable,
        publish: false);
    _releaseSubscriptions();
    _scopeResolved = false;
    _parent = null;
    if (!sameIdentity) {
      _revisions.clear();
      _deleted.clear();
    }
    _publish(_state);
  }

  void _subscribe(ConversationId id) {
    final realtime = _client.realtimeSession;
    if (realtime != null && !_releases.containsKey(id)) {
      _releases[id] = realtime.subscribeConversation(id);
    }
  }

  Set<ConversationId> _deniedScopes(NormalizedSnapshotState state) {
    final denied = <ConversationId>{};
    for (final conversation in state.conversations.values) {
      // Public-channel and child membership are participation, not read access.
      if (conversation is ThreadConversation) continue;
      final member =
          state.membersByConversation[conversation.id]?[_authority?.userId];
      final public = conversation is ChannelConversation &&
          conversation.visibility == ConversationVisibility.public;
      if (conversation.archivedAt != null ||
          state.lifecycleArchivedStates[conversation.id] == true ||
          !public && member != null && member.state != 'active') {
        denied.add(conversation.id);
      }
    }
    return denied;
  }

  void _releaseSubscriptions() {
    for (final release in _releases.values) {
      scheduleMicrotask(release);
    }
    _releases.clear();
  }

  /// Fresh authorized lookup; concurrent calls return the same active future.
  Future<ChatMessageContextState> load() {
    if (_pending != null) return _pending!;
    if (!_allowed) return Future.value(_state);
    _requested = true;
    _invalidate(ChatMessageContextStatus.loading, publish: false);
    final generation = _generation,
        identity = _client._storageIdentityGeneration;
    final cancellation = _cancellation = ChatCommandCancellationController();
    _subscribe(request.conversationId);
    // Install the future before synchronous observers see loading.
    final pending = _pending = _lookup(generation, identity, cancellation);
    _publish(_state);
    return pending;
  }

  Future<ChatMessageContextState> retry() => load();

  bool _current(int generation, int identity) =>
      _allowed &&
      generation == _generation &&
      identity == _client._storageIdentityGeneration;

  Future<ChatMessageContextState> _lookup(int generation, int identity,
      ChatCommandCancellationController cancellation) async {
    final options =
        ChatSnapshotQueryOptions(cancellationSignal: cancellation.signal);
    final response = await _client.getMessageContext(request, options: options);
    if (!_current(generation, identity)) return _state;
    if (response is ChatSnapshotQueryFailure<MessageContextResult>) {
      return _fail(response);
    }
    final result =
        (response as ChatSnapshotQuerySuccess<MessageContextResult>).value;
    if (result is UnavailableMessageContext) {
      _pending = null;
      _cancellation = null;
      _publish(ChatMessageContextState(
          status: ChatMessageContextStatus.unavailable, result: result));
      return _state;
    }
    // Source responses intentionally contain no conversation/parent metadata.
    // Resolve it without hydrating durable state or changing participation.
    final detail = await _client.getConversation(
        ConversationDetailSnapshotInput(conversationId: request.conversationId),
        options: options);
    if (!_current(generation, identity)) return _state;
    if (detail is ChatSnapshotQueryFailure<ConversationDetailSnapshot>) {
      return _fail(detail);
    }
    final summary =
        (detail as ChatSnapshotQuerySuccess<ConversationDetailSnapshot>)
            .value
            .conversation
            .summary;
    final conversation = summary.conversation;
    final message = switch (result) {
      AvailableMessageContext(:final message) => message,
      DeletedMessageContext(:final message) => message,
      _ => throw StateError('Unexpected context result'),
    };
    if (conversation.tenantId != _authority!.tenantId ||
        summary.currentMember.userId != _authority!.userId ||
        summary.currentReadState.userId != _authority!.userId ||
        summary.currentPreference.userId != _authority!.userId ||
        !_fresh(message)) {
      return _fail(
          const ChatSnapshotQueryMalformedResponse<MessageContextResult>());
    }
    _parent = conversation is ThreadConversation
        ? conversation.parentConversationId
        : null;
    if (_denied.contains(_parent ?? request.conversationId)) {
      setAuthority(null);
      return _state;
    }
    _scopeResolved = true;
    if (_parent case final parent?) _subscribe(parent);
    _record(message);
    _beforeCursor = message.sequence;
    _afterCursor = message.sequence;
    _pending = null;
    _cancellation = null;
    _publish(ChatMessageContextState(
      status: result is AvailableMessageContext
          ? ChatMessageContextStatus.available
          : ChatMessageContextStatus.deleted,
      result: result,
      canLoadBefore: true,
      canLoadAfter: true,
    ));
    return _state;
  }

  /// One bounded page per call, exclusive of the separately returned source.
  /// Page reads are serialized; callers should await before requesting another.
  Future<ChatMessageContextState> loadBefore() =>
      _page(MessageTimelineDirection.backward);
  Future<ChatMessageContextState> loadAfter() =>
      _page(MessageTimelineDirection.forward);
  Future<ChatMessageContextState> _page(MessageTimelineDirection direction) {
    if (_pending != null) return _pending!;
    final cursor = direction == MessageTimelineDirection.backward
        ? _beforeCursor
        : _afterCursor;
    if (!_allowed || cursor == null || _state.result == null) {
      return Future.value(_state);
    }
    final cancellation = _cancellation = ChatCommandCancellationController();
    final pending = _pending = _readPage(direction, cursor, _generation,
        _client._storageIdentityGeneration, cancellation);
    _publish(ChatMessageContextState(
        status: _state.status,
        result: _state.result,
        before: _before,
        after: _after,
        canLoadBefore: _beforeCursor != null,
        canLoadAfter: _afterCursor != null,
        isLoadingPage: true));
    return pending;
  }

  Future<ChatMessageContextState> _readPage(
      MessageTimelineDirection direction,
      MessageSequence cursor,
      int generation,
      int identity,
      ChatCommandCancellationController cancellation) async {
    final response = await _client.getMessageTimeline(
        MessageTimelineRequest(
          conversationId: request.conversationId,
          direction: direction,
          cursor: cursor,
          limit: pageSize,
        ),
        options:
            ChatSnapshotQueryOptions(cancellationSignal: cancellation.signal));
    if (!_current(generation, identity)) return _state;
    if (response is ChatSnapshotQueryFailure<MessageTimelinePage>) {
      return _fail(response);
    }
    final page =
        (response as ChatSnapshotQuerySuccess<MessageTimelinePage>).value;
    if (page.messages
        .any((m) => m.id == request.messageId || !_fresh(m.message))) {
      return _fail(
          const ChatSnapshotQueryMalformedResponse<MessageTimelinePage>());
    }
    for (final m in page.messages) {
      _record(m.message);
    }
    if (direction == MessageTimelineDirection.backward) {
      _before.insertAll(0, page.messages);
      _beforeCursor = page.pagination.older.cursor;
    } else {
      _after.addAll(page.messages);
      _afterCursor = page.pagination.newer.cursor;
    }
    _pending = null;
    _cancellation = null;
    _publish(ChatMessageContextState(
        status: _state.status,
        result: _state.result,
        before: _before,
        after: _after,
        canLoadBefore: _beforeCursor != null,
        canLoadAfter: _afterCursor != null));
    return _state;
  }

  bool _fresh(Message message) {
    final known = _client.normalizedState.state.canonicalMessages[message.id];
    return message.tenantId == _authority?.tenantId &&
        message.conversationId == request.conversationId &&
        message.revision.revision >= (_revisions[message.id] ?? 0) &&
        message.revision.revision >= (known?.revision.revision ?? 0) &&
        (!(known is DeletedMessage || _deleted.contains(message.id)) ||
            message is DeletedMessage);
  }

  void _record(Message message) {
    _revisions[message.id] = message.revision.revision;
    if (message is DeletedMessage) _deleted.add(message.id);
  }

  void _changed(Message message) {
    if (_disposed ||
        message.tenantId != _authority?.tenantId ||
        message.conversationId != request.conversationId) {
      return;
    }
    final relevant = message.id == request.messageId ||
        _before.any((m) => m.id == message.id) ||
        _after.any((m) => m.id == message.id) ||
        _state.isLoadingPage;
    if (!relevant ||
        message.revision.revision <= (_revisions[message.id] ?? 0)) {
      return;
    }
    _record(message);
    _invalidate(message.id == request.messageId && message is DeletedMessage
        ? ChatMessageContextStatus.deleted
        : ChatMessageContextStatus.idle);
  }

  ChatMessageContextState _fail(ChatSnapshotQueryFailure<Object?> error) {
    _invalidate(ChatMessageContextStatus.error, publish: false);
    _publish(ChatMessageContextState(
        status: ChatMessageContextStatus.error, error: error));
    return _state;
  }

  void _invalidate(ChatMessageContextStatus status, {bool publish = true}) {
    ++_generation;
    _cancellation?.cancel();
    _cancellation = null;
    _pending = null;
    _before.clear();
    _after.clear();
    _beforeCursor = null;
    _afterCursor = null;
    _state = ChatMessageContextState(status: status);
    if (publish) _publish(_state);
  }

  void _publish(ChatMessageContextState state) {
    _state = state;
    if (!_changes.isClosed) _changes.add(state);
  }

  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    _invalidate(ChatMessageContextStatus.disposed);
    _authority = null;
    _revisions.clear();
    _deleted.clear();
    _releaseSubscriptions();
    _owner._controllers.remove((request.conversationId, request.messageId));
    await _commits.cancel();
    await _changes.close();
  }
}
