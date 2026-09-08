part of '../handrail_chat_client.dart';

/// Cancellable scheduling boundary; hosts/tests may supply a deterministic clock.
typedef ChatThreadListSchedule = void Function() Function(
    Duration delay, void Function() callback);

final class ChatThreadListAuthority {
  const ChatThreadListAuthority(
      {required this.tenantId, required this.userId, this.canRead = false});
  final TenantId tenantId;
  final UserId userId;
  final bool canRead;
}

enum ChatThreadListStatus {
  idle,
  loading,
  ready,
  empty,
  error,
  accessDenied,
  disposed
}

/// Discovery is a projection only: follow, membership and read state stay separate.
final class ChatThreadListItem {
  const ChatThreadListItem(
      {required this.thread,
      required this.currentThreadFollow,
      required this.lastActivityAt,
      required this.hideAt});
  final ConversationSnapshotSummary thread;
  final ThreadListFollowAuthority currentThreadFollow;
  final IsoTimestamp lastActivityAt;
  final double? hideAt;
  ThreadConversation get conversation =>
      thread.conversation as ThreadConversation;
  ConversationId get threadId => conversation.id;
  int get unreadCount {
    final read = thread.currentReadState;
    final from =
        read.manualUnreadFromSequence?.value ?? read.lastReadSequence.value + 1;
    return max(0, thread.latestSequence.value - from + 1);
  }
}

final class ChatThreadListState {
  ChatThreadListState(
      {required this.status,
      required this.parentConversationId,
      required this.view,
      required List<ChatThreadListItem> items,
      this.isRefreshing = false,
      this.isLoadingMore = false,
      this.hasMore = false,
      this.error,
      this.evaluatedAt,
      this.inactivityPolicy,
      this.lifecycleSupported = false})
      : items = List.unmodifiable(items);
  final ChatThreadListStatus status;
  final ConversationId parentConversationId;
  final String view;
  final List<ChatThreadListItem> items;
  final bool isRefreshing, isLoadingMore, hasMore, lifecycleSupported;
  final ChatSnapshotQueryFailure<ThreadListResult>? error;
  final IsoTimestamp? evaluatedAt;
  final ThreadListInactivityPolicy? inactivityPolicy;
  bool get isBusy => isRefreshing || isLoadingMore;
  bool get isEmpty => status == ChatThreadListStatus.empty;
  bool get canRetry => status == ChatThreadListStatus.error;
}

/// Public query uses the client's existing authenticated, cancellable reader.
extension ChatThreadListQueries on HandrailChatClient {
  Future<ChatSnapshotQueryResult<ThreadListResult>> listThreads(
      ThreadListRequest input,
      {ChatSnapshotQueryOptions options = const ChatSnapshotQueryOptions()}) {
    final request = ThreadListRequest.fromJson(input.toJson());
    return _snapshotQueries._run<ThreadListResult>(
        query: ChatSnapshotQueryName.threadList,
        uri: _snapshotEndpointUri(_snapshotQueries.apiBaseUri,
            ['conversations', request.parentConversationId.value, 'threads'],
            queryParameters: request.toQuery()),
        options: options,
        parse: (json) =>
            ThreadListResult.fromJson(json, expectedRequest: request));
  }
}

/// Client-owned discovery controllers; subscriptions are shared with open parents.
final class ChatThreadListsController {
  ChatThreadListsController._(this._client) {
    _subscriptions =
        _client.realtimeSession?.conversationSubscriptionStates.listen((s) {
      if (s is ChatRealtimeConversationSubscriptionRevokedState ||
          s is ChatRealtimeConversationSubscriptionRejectedState) {
        _revoke(s.conversationId);
      }
    });
    _realtime = _client.realtimeSession?.states.listen((s) {
      final reconnect = s is ChatRealtimeConnectedState && !_connected;
      _connected = s is ChatRealtimeConnectedState;
      for (final c in _controllers.toList()) {
        if (s is ChatRealtimeConnectedState) {
          if (!c._matches(s.identity.tenantId, s.identity.userId)) {
            c.setAuthority(null);
          } else if (reconnect && c._requested) {
            c._queueRefresh();
          }
        } else {
          c._interrupt();
          c._publish();
        }
      }
    });
  }
  final HandrailChatClient _client;
  final _controllers = <ChatThreadListController>{};
  StreamSubscription<ChatRealtimeConversationSubscriptionState>? _subscriptions;
  StreamSubscription<ChatRealtimeLifecycleState>? _realtime;
  bool _connected = false, _disposed = false;

  ChatThreadListController forParent(ConversationId parentConversationId,
      {String view = 'active',
      int pageSize = 50,
      DateTime Function()? now,
      ChatThreadListSchedule? schedule}) {
    if (_disposed) throw StateError('Thread lists are disposed.');
    final controller = ChatThreadListController._(
        this,
        ThreadListRequest(
            parentConversationId: parentConversationId,
            view: view,
            limit: pageSize),
        now ?? DateTime.now,
        schedule ?? _scheduleThreadListTimer);
    _controllers.add(controller);
    return controller;
  }

  void _invalidateIdentity() {
    for (final c in _controllers.toList()) {
      c.setAuthority(null);
    }
  }

  void _revoke(ConversationId id) {
    for (final c in _controllers.toList()) {
      if (c.parentConversationId == id) c.setAuthority(null);
    }
  }

  void _event(KnownDurableEvent event) {
    for (final c in _controllers.toList()) {
      c._event(event);
    }
  }

  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    await _subscriptions?.cancel();
    await _realtime?.cancel();
    for (final c in _controllers.toList()) {
      await c.dispose();
    }
  }
}

void Function() _scheduleThreadListTimer(
    Duration delay, void Function() callback) {
  final timer = Timer(delay, callback);
  return timer.cancel;
}

/// Current-first observable discovery, with no navigation or membership writes.
/// Set trusted authority before reading and whenever host permissions change.
/// A new authority always invalidates pending requests, including access regain
/// by the same actor. Observe [states] to enable expiry refreshes.
final class ChatThreadListController {
  ChatThreadListController._(
      this._owner, this._request, this._now, this._schedule) {
    _state = _build();
    _commits = _client.normalizedState.acceptedCommitChanges.listen((_) {
      if (_authority == null) return;
      final parent = _client.normalizedState.state;
      if (parent.lifecycleArchivedStates[parentConversationId] == true ||
          parent.conversations[parentConversationId]?.archivedAt != null) {
        setAuthority(null);
        return;
      }
      final signature = _projectionSignature();
      if (signature != _signature) {
        _signature = signature;
        _publish();
        if (_requested) _queueRefresh();
      }
    });
  }
  final ChatThreadListsController _owner;
  HandrailChatClient get _client => _owner._client;
  ThreadListRequest _request;
  final DateTime Function() _now;
  final ChatThreadListSchedule _schedule;
  final _changes = StreamController<ChatThreadListState>.broadcast(sync: true);
  late final StreamSubscription<NormalizedSnapshotState> _commits;
  late ChatThreadListState _state;
  ChatThreadListAuthority? _authority;
  ChatThreadListStatus _status = ChatThreadListStatus.idle;
  ChatSnapshotQueryFailure<ThreadListResult>? _error;
  final _rows = <ConversationId, ThreadListItem>{};
  final _deadlines = <ConversationId, DateTime>{};
  final _lifecycleRevisions = <ConversationId, int>{};
  ThreadListResult? _lastPage;
  String? _cursor, _failedCursor;
  ChatCommandCancellationController? _cancellation;
  Future<ChatThreadListState>? _pending;
  void Function()? _cancelTimer;
  int _generation = 0, _observers = 0, _elapsedRefreshes = 0;
  bool _disposed = false,
      _refreshing = false,
      _paging = false,
      _requested = false;
  bool _refreshQueued = false;
  String _signature = '';
  ConversationId get parentConversationId => _request.parentConversationId;
  String get view => _request.view;
  ChatThreadListState get state => _state;
  Stream<ChatThreadListState> get states => Stream.multi((events) {
        events.add(_state);
        if (_disposed) {
          events.close();
          return;
        }
        ++_observers;
        _armTimer();
        final subscription =
            _changes.stream.listen(events.add, onDone: events.close);
        events.onCancel = () {
          --_observers;
          if (_observers == 0) _stopTimer();
          return subscription.cancel();
        };
      }, isBroadcast: true);

  void setAuthority(ChatThreadListAuthority? authority) {
    if (_disposed) return;
    _interrupt();
    _releaseParent();
    _authority = authority;
    _rows.clear();
    _deadlines.clear();
    _lifecycleRevisions.clear();
    _lastPage = null;
    _cursor = null;
    _failedCursor = null;
    _requested = false;
    _elapsedRefreshes = 0;
    _status = authority?.canRead == true
        ? ChatThreadListStatus.idle
        : ChatThreadListStatus.accessDenied;
    _error = null;
    _signature = _projectionSignature();
    _publish();
  }

  /// Switching parent/view clears only discovery and requires explicit authority.
  void setScope(ConversationId parentConversationId,
      {required ChatThreadListAuthority? authority, String view = 'active'}) {
    final request = ThreadListRequest(
        parentConversationId: parentConversationId,
        view: view,
        limit: _request.limit);
    if (_disposed) return;
    _request = request;
    setAuthority(authority);
  }

  bool _matches(TenantId tenant, UserId user) =>
      _authority?.tenantId == tenant && _authority?.userId == user;
  bool get _allowed {
    if (_disposed || _authority?.canRead != true) return false;
    final identity = _client._forwardIdentity;
    if (identity != null && !_matches(identity.tenantId, identity.userId)) {
      return false;
    }
    final realtime = _client.realtimeSession?.state;
    return realtime == null ||
        realtime is ChatRealtimeConnectedState &&
            _matches(realtime.identity.tenantId, realtime.identity.userId);
  }

  ChatRealtimeConversationSubscriptionRelease? _release;
  void _releaseParent() {
    final release = _release;
    _release = null;
    // Subscription events are synchronous; never release during their delivery.
    if (release != null) scheduleMicrotask(release);
  }

  Future<ChatThreadListState> refresh() => _load(null);
  Future<ChatThreadListState> loadMore() =>
      _pending ?? (_cursor == null ? Future.value(_state) : _load(_cursor));
  Future<ChatThreadListState> retry() =>
      _pending ??
      (_state.canRetry ? _load(_failedCursor) : Future.value(_state));

  Future<ChatThreadListState> _load(String? cursor) {
    if (!_allowed) return Future.value(_state);
    _interrupt();
    _requested = true;
    _release ??=
        _client.realtimeSession?.subscribeConversation(parentConversationId);
    final generation = _generation;
    final identity = _client._storageIdentityGeneration;
    final cancellation = _cancellation = ChatCommandCancellationController();
    final startedAt = _now();
    _refreshing = cursor == null;
    _paging = cursor != null;
    if (_rows.isEmpty) _status = ChatThreadListStatus.loading;
    _error = null;
    _publish();
    final request = ThreadListRequest(
        parentConversationId: parentConversationId,
        view: view,
        limit: _request.limit,
        cursor: cursor);
    final future =
        _perform(request, cancellation, generation, identity, startedAt);
    _pending = future;
    return future;
  }

  Future<ChatThreadListState> _perform(
      ThreadListRequest request,
      ChatCommandCancellationController cancellation,
      int generation,
      int identity,
      DateTime startedAt) async {
    final response = await _client.listThreads(request,
        options:
            ChatSnapshotQueryOptions(cancellationSignal: cancellation.signal));
    if (!_allowed ||
        generation != _generation ||
        identity != _client._storageIdentityGeneration) {
      return _state;
    }
    _pending = null;
    _cancellation = null;
    _refreshing = false;
    _paging = false;
    if (response is ChatSnapshotQuerySuccess<ThreadListResult>) {
      final page = response.value;
      if (page.items.any((i) =>
          i.conversation.tenantId != _authority!.tenantId ||
          i.thread.currentReadState.userId != _authority!.userId ||
          i.thread.currentMember.userId != _authority!.userId ||
          i.thread.currentPreference.userId != _authority!.userId ||
          !_identityMatches(i.conversation))) {
        _error = const ChatSnapshotQueryMalformedResponse<ThreadListResult>();
      } else {
        if (request.cursor == null) {
          _rows.clear();
          _deadlines.clear();
        }
        for (final row in page.items) {
          _rows[row.conversation.id] = row;
          if (view == 'active' &&
              row.hideAt != null &&
              page.inactivityPolicy?.hideAfterMs != null) {
            final serverNow =
                DateTime.parse(page.evaluatedAt.value).millisecondsSinceEpoch;
            _deadlines[row.conversation.id] = startedAt.add(Duration(
                // Bound huge valid policies to a daily authority check and avoid
                // platform timer/DateTime overflow. Elapsed deadlines back off below.
                microseconds: ((row.hideAt! - serverNow) * 1000)
                    .clamp(-1000000, Duration.microsecondsPerDay)
                    .ceil()));
          } else {
            _deadlines.remove(row.conversation.id);
          }
        }
        _lastPage = page;
        _cursor = page.nextCursor;
        _failedCursor = null;
        _status = _rows.isEmpty
            ? ChatThreadListStatus.empty
            : ChatThreadListStatus.ready;
      }
    } else {
      _error = response as ChatSnapshotQueryFailure<ThreadListResult>;
    }
    if (_error != null) {
      final error = _error!;
      if (error.category == ChatSnapshotQueryResultCategory.authentication ||
          const [401, 403, 404].contains(error.httpStatus)) {
        setAuthority(null);
        _error = error;
      } else {
        _status = ChatThreadListStatus.error;
        _failedCursor = request.cursor;
      }
    }
    _signature = _projectionSignature();
    _publish();
    // Failed requests require retry/reconnect, rather than an expiry retry loop.
    if (_error == null) _armTimer();
    return _state;
  }

  bool _identityMatches(ThreadConversation incoming) {
    final known = <Conversation?>[
      _rows[incoming.id]?.conversation,
      _client.normalizedState.state.conversations[incoming.id],
    ];
    return known.every((c) =>
        c == null ||
        c is ThreadConversation &&
            c.tenantId == incoming.tenantId &&
            c.parentConversationId == incoming.parentConversationId &&
            c.rootMessageId == incoming.rootMessageId &&
            c.createdAt == incoming.createdAt);
  }

  void _queueRefresh() {
    if (_refreshQueued || !_requested || !_allowed) return;
    // Invalidate immediately, before the coalesced replacement starts.
    _interrupt();
    _refreshQueued = true;
    final generation = _generation;
    scheduleMicrotask(() {
      _refreshQueued = false;
      if (generation == _generation && _allowed) unawaited(refresh());
    });
  }

  void _event(KnownDurableEvent event) {
    if (!_allowed || event.tenantId != _authority!.tenantId) return;
    final data = event.payload.data;
    if (event is ThreadLifecycleChangedDurableEvent) {
      if (event.streamId != parentConversationId.value ||
          data['parentConversationId'] != parentConversationId.value) {
        return;
      }
      final id = ConversationId.fromJson(data['threadId']);
      final revision = data['revision']! as int;
      if (revision <= (_lifecycleRevisions[id] ?? 0)) return;
      _lifecycleRevisions[id] = revision;
      _queueRefresh();
      return;
    }
    final conversation = data['conversation'];
    final message = data['message'];
    final relevant = event.streamId == parentConversationId.value ||
        _rows.keys.any((id) =>
            id.value == event.streamId ||
            id.value == data['conversationId'] ||
            id.value == data['threadId']) ||
        conversation is Map &&
            conversation['parentConversationId'] ==
                parentConversationId.value ||
        message is Map &&
            message['conversationId'] == parentConversationId.value;
    if (relevant &&
        (event.type.startsWith('conversation.') ||
            event.type.startsWith('thread.') ||
            event is ThreadSummaryUpdatedDurableEvent ||
            event.type.startsWith('read.') ||
            event.type == 'message.created')) {
      _queueRefresh();
    }
  }

  String _projectionSignature() {
    final s = _client.normalizedState.state;
    final ids = <ConversationId>{
      parentConversationId,
      ..._rows.keys,
      for (final c in s.conversations.values)
        if (c is ThreadConversation &&
            c.parentConversationId == parentConversationId)
          c.id
    };
    return jsonEncode([
      for (final id in ids)
        [
          id.value,
          s.conversations[id]?.toJson(),
          s.currentUserReadStates[id]?.toJson(),
          s.currentUserPreferences[id]?.toJson(),
          s.currentUserThreadFollows[id]?.toJson(),
          s.threadFollowRevisions[id],
          s.lifecycleArchivedStates[id]
        ]
    ]);
  }

  ChatThreadListItem? _project(ThreadListItem row) {
    final s = _client.normalizedState.state, id = row.conversation.id;
    var conversation = row.conversation;
    final normalized = s.conversations[id];
    if (normalized is ThreadConversation &&
        normalized.tenantId == conversation.tenantId &&
        normalized.parentConversationId == conversation.parentConversationId &&
        normalized.rootMessageId == conversation.rootMessageId) {
      final lifecycle = normalized.threadLifecycle;
      if (lifecycle != null &&
          lifecycle.revision >= (conversation.threadLifecycle?.revision ?? 0)) {
        conversation = ThreadConversation.fromJson(
            {...conversation.toJson(), 'threadLifecycle': lifecycle.toJson()});
      }
      if (normalized.archivedAt != null ||
          s.lifecycleArchivedStates[id] == true) {
        return null;
      }
    }
    if (view == 'active' && conversation.threadLifecycle?.closedAt != null) {
      return null;
    }
    final read = s.currentUserReadStates[id],
        preference = s.currentUserPreferences[id];
    final summary = row.thread;
    final followRevision = s.threadFollowRevisions[id];
    final follow = s.currentUserReadStates[id]?.userId == _authority?.userId &&
            followRevision != null &&
            followRevision >= row.currentThreadFollow.followRevision
        ? ThreadListFollowAuthority.fromJson({
            'followRevision': followRevision,
            'follow': s.authoritativeCurrentUserThreadFollows[id]?.toJson()
          }, id)
        : row.currentThreadFollow;
    return ChatThreadListItem(
        thread: ConversationSnapshotSummary(
            conversation: conversation,
            latestSequence: summary.latestSequence,
            activityAt: summary.activityAt,
            unreadMentionCount: summary.unreadMentionCount,
            currentMember: summary.currentMember,
            currentReadState: read != null &&
                    read.userId == _authority?.userId &&
                    read.updatedAt.value.compareTo(
                            summary.currentReadState.updatedAt.value) >=
                        0
                ? read
                : summary.currentReadState,
            currentPreference: preference != null &&
                    preference.userId == _authority?.userId &&
                    preference.updatedAt.value.compareTo(
                            summary.currentPreference.updatedAt.value) >=
                        0
                ? preference
                : summary.currentPreference,
            activeMemberUserIds: summary.activeMemberUserIds),
        currentThreadFollow: follow,
        lastActivityAt: row.lastActivityAt,
        hideAt: row.hideAt);
  }

  ChatThreadListState _build() {
    final rows = _rows.values.toList()
      ..sort((a, b) => compareThreadListPositions(
          ThreadListCursorPosition(
              parentConversationId: parentConversationId,
              view: view,
              createdAt: a.conversation.createdAt,
              threadId: a.conversation.id),
          ThreadListCursorPosition(
              parentConversationId: parentConversationId,
              view: view,
              createdAt: b.conversation.createdAt,
              threadId: b.conversation.id)));
    final items = rows.map(_project).whereType<ChatThreadListItem>().toList();
    final settled = _status == ChatThreadListStatus.ready ||
        _status == ChatThreadListStatus.empty;
    return ChatThreadListState(
        status: settled
            ? (items.isEmpty
                ? ChatThreadListStatus.empty
                : ChatThreadListStatus.ready)
            : _status,
        parentConversationId: parentConversationId,
        view: view,
        items: items,
        isRefreshing: _refreshing,
        isLoadingMore: _paging,
        hasMore: _cursor != null,
        error: _error,
        evaluatedAt: _lastPage?.evaluatedAt,
        inactivityPolicy: _lastPage?.inactivityPolicy,
        lifecycleSupported: _lastPage?.lifecycleSupported ?? false);
  }

  void _publish() {
    _state = _build();
    if (!_changes.isClosed) _changes.add(_state);
  }

  void _stopTimer() {
    _cancelTimer?.call();
    _cancelTimer = null;
  }

  void _armTimer() {
    _stopTimer();
    if (_observers == 0 ||
        !_allowed ||
        _pending != null ||
        _error != null ||
        view != 'active' ||
        _lastPage?.inactivityPolicy?.hideAfterMs == null ||
        _deadlines.isEmpty) {
      return;
    }
    final nearest = _deadlines.values.reduce((a, b) => a.isBefore(b) ? a : b);
    var delay = nearest.difference(_now());
    if (delay <= Duration.zero) {
      // Clock skew/latency or a server clock that stopped advancing: bounded
      // exponential retries, never an immediate refresh loop.
      delay = Duration(seconds: 1 << min(_elapsedRefreshes++, 6));
    } else {
      _elapsedRefreshes = 0;
    }
    final generation = _generation;
    _cancelTimer = _schedule(delay, () {
      _cancelTimer = null;
      if (generation == _generation && _observers > 0) _queueRefresh();
    });
  }

  void _interrupt() {
    ++_generation;
    _cancellation?.cancel();
    _cancellation = null;
    _pending = null;
    _refreshing = false;
    _paging = false;
    _stopTimer();
  }

  Future<void> dispose() async {
    if (_disposed) return;
    _interrupt();
    _disposed = true;
    _releaseParent();
    _rows.clear();
    _deadlines.clear();
    _cursor = null;
    _status = ChatThreadListStatus.disposed;
    _publish();
    _owner._controllers.remove(this);
    await _commits.cancel();
    await _changes.close();
  }
}
