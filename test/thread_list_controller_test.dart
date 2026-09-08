import 'dart:async';
import 'dart:convert';
import 'package:handrail_chat/core.dart';
import 'package:test/test.dart';
import 'fixtures/existing_thread_opening_fixtures.dart';

const parent = ConversationId('conversation-parent');
const thread = ConversationId('conversation-thread');
const tenant = TenantId('tenant-from-session');
const user = UserId('user-current');
const authority =
    ChatThreadListAuthority(tenantId: tenant, userId: user, canRead: true);
const time = existingThreadFixtureTime;
Map<String, Object?> get metadata => {
      'packageVersion': '0.1.4',
      'protocolVersion': 4,
      'schemaVersion': 1,
      'enabledFeatures': <String, Object?>{},
      'supportedProtocolRange': {'minimumVersion': 1, 'maximumVersion': 4},
    };
HandrailChatHttpResponse response(Object? body, [int status = 200]) =>
    HandrailChatHttpResponse(statusCode: status, body: jsonEncode(body));
Map<String, Object?> row(String id,
    {String createdAt = time,
    double? duration,
    int revision = 1,
    bool closed = false,
    String activityAt = time}) {
  final summary = Map<String, Object?>.from(
      existingThreadDetailFixture()['conversation'] as Map);
  summary.remove('memberUserIds');
  final value =
      jsonDecode(jsonEncode(summary).replaceAll('conversation-thread', id))
          as Map<String, dynamic>;
  value['createdAt'] = createdAt;
  value['activityAt'] = activityAt;
  value['threadLifecycle'] = {
    'revision': revision,
    'locked': false,
    if (closed) 'closedAt': time,
    if (closed) 'closedByUserId': user.value
  };
  return {
    'thread': value,
    'currentThreadFollow': {'followRevision': 0, 'follow': null},
    'lastActivityAt': activityAt,
    'hideAt': duration == null
        ? null
        : DateTime.parse(activityAt).millisecondsSinceEpoch + duration
  };
}

Map<String, Object?> page(List<Map<String, Object?>> rows,
        {String view = 'active',
        String parentId = 'conversation-parent',
        String evaluatedAt = time,
        double? duration,
        bool more = false}) =>
    {
      'parentConversationId': parentId,
      'view': view,
      'evaluatedAt': evaluatedAt,
      'lifecycleSupported': true,
      'inactivityPolicy': duration == null ? false : {'hideAfterMs': duration},
      'items': rows,
      if (more)
        'nextCursor': encodeThreadListCursor(ThreadListCursorPosition(
            parentConversationId: ConversationId(parentId),
            view: view,
            createdAt: IsoTimestamp(
                (rows.last['thread'] as Map)['createdAt'] as String),
            threadId:
                ConversationId((rows.last['thread'] as Map)['id'] as String))),
    };
void hydrateParent(HandrailChatClient client) {
  final detail = jsonDecode(jsonEncode(existingThreadDetailFixture())
      .replaceAll('conversation-thread', parent.value)) as Map<String, dynamic>;
  final c = detail['conversation'] as Map<String, dynamic>;
  c.remove('parentConversationId');
  c.remove('rootMessageId');
  c['type'] = 'channel';
  c['name'] = 'Parent';
  (c['currentMember'] as Map)['state'] = 'active';
  client.normalizedState
      .hydrateConversationDetail(ConversationDetailSnapshot.fromJson(detail));
}

KnownDurableEvent lifecycleEvent(int revision,
        {String? id, String child = 'unopened'}) =>
    KnownDurableEvent.fromJson({
      'eventId': id ?? 'changed-$revision',
      'tenantId': tenant.value,
      'streamId': parent.value,
      'type': 'thread.lifecycle.changed',
      'protocolVersion': 4,
      'occurredAt': time,
      'payload': {
        'threadId': child,
        'parentConversationId': parent.value,
        'revision': revision
      }
    },
        trustedIdentity:
            const DurableEventTrustedIdentity(tenantId: tenant, userId: user));
Future<void> pump() async {
  for (var i = 0; i < 10; ++i) {
    await Future<void>.delayed(Duration.zero);
  }
}

typedef Handler = Future<HandrailChatHttpResponse> Function(
    HandrailChatHttpRequest);

class Http implements HandrailChatHttpTransport {
  final requests = <HandrailChatHttpRequest>[];
  Handler? read, write;
  Map<String, Object?> value = page([row(thread.value)]);
  @override
  Future<HandrailChatHttpResponse> send(HandrailChatHttpRequest r) async {
    requests.add(r);
    if (r.method != 'GET')
      return write == null ? response({}, 503) : await write!(r);
    if (r.uri.path.endsWith('/threads'))
      return read == null ? response(value) : await read!(r);
    if (r.uri.path.endsWith('/messages'))
      return response(existingThreadTimelineFixture(
          parent: r.uri.path.contains(parent.value)));
    if (r.uri.path.endsWith(thread.value))
      return response(existingThreadDetailFixture());
    return response(metadata);
  }

  List<HandrailChatHttpRequest> get reads =>
      requests.where((r) => r.uri.path.endsWith('/threads')).toList();
}

Future<HandrailChatClient> clientFor(Http http,
    {ChatRealtimeSessionTransport? realtime}) async {
  final client = HandrailChatClient(
      apiBaseUri: Uri.parse('https://chat.test/api/chat'),
      tokenProvider: () async => 'test-token',
      transport: http,
      realtimeSession: realtime,
      commandRetryOptions: const ChatCommandRetryOptions(maxAttempts: 1));
  addTearDown(client.dispose);
  await client.initialize();
  return client;
}

ChatThreadListController controllerFor(HandrailChatClient c,
        {int limit = 50, String view = 'active', Clock? clock}) =>
    c.threadLists.forParent(parent,
        pageSize: limit, view: view, now: clock?.now, schedule: clock?.schedule)
      ..setAuthority(authority);

class Scheduled {
  Scheduled(this.deadline, this.callback);
  final DateTime deadline;
  final void Function() callback;
  bool canceled = false;
}

class Clock {
  DateTime value = DateTime.utc(2030); // Deliberate server/client offset.
  final timers = <Scheduled>[];
  DateTime now() => value;
  void Function() schedule(Duration delay, void Function() callback) {
    final timer = Scheduled(value.add(delay), callback);
    timers.add(timer);
    return () {
      timer.canceled = true;
    };
  }

  List<Scheduled> get active => timers.where((t) => !t.canceled).toList();
  void elapse(Duration duration) {
    value = value.add(duration);
    for (final t in active) {
      if (!t.deadline.isAfter(value)) {
        t.canceled = true;
        t.callback();
      }
    }
  }
}

void main() {
  test(
      'two pages preserve canonical identity, names, parent/root and contract order',
      () async {
    final http = Http()..value = page([row('a'), row('b')], more: true);
    final client = await clientFor(http);
    final c = controllerFor(client, limit: 2);
    expect((await c.states.first).status, ChatThreadListStatus.idle);
    expect((await c.refresh()).hasMore, isTrue);
    http.value = page([row('c', createdAt: '2026-08-25T16:00:00.000Z')]);
    final state = await c.loadMore();
    expect(state.items.map((i) => i.threadId.value), ['a', 'b', 'c']);
    expect(http.reads.last.uri.queryParameters['cursor'], isNotNull);
    expect(state.items.first.conversation.parentConversationId, parent);
    expect(state.items.first.conversation.rootMessageId,
        const MessageId('message-root'));
    expect(state.items.first.conversation.name, 'Canonical discussion');
    expect(() => state.items.clear(), throwsUnsupportedError);
    expect(client.normalizedState.state.conversations, isEmpty);
    expect(http.requests.every((r) => r.method == 'GET'), isTrue);
  });
  test('a page cannot change a previously discovered canonical identity',
      () async {
    final http = Http()..value = page([row('a')], more: true);
    final client = await clientFor(http);
    final c = controllerFor(client, limit: 1);
    await c.refresh();
    http.value = page([row('a', createdAt: '2026-08-25T16:00:00.000Z')]);
    await c.loadMore();
    expect(c.state.error,
        isA<ChatSnapshotQueryMalformedResponse<ThreadListResult>>());
    expect(c.state.items.single.conversation.createdAt.value, time);
  });
  test('large valid inactivity policies stay within platform timer bounds',
      () async {
    final clock = Clock();
    final http = Http()
      ..value = page([row('a', duration: 1e300)], duration: 1e300);
    final client = await clientFor(http);
    final c = controllerFor(client, clock: clock);
    final sub = c.states.listen((_) {});
    addTearDown(sub.cancel);
    await c.refresh();
    expect(c.state.error, isNull);
    expect(clock.active.single.deadline.difference(clock.now()),
        const Duration(days: 1));
  });
  test(
      'loading, empty, sanitized errors and retry; failed page retries its cursor',
      () async {
    final http = Http();
    final client = await clientFor(http);
    final c = controllerFor(client, limit: 1);
    final pending = Completer<HandrailChatHttpResponse>();
    http.read = (_) => pending.future;
    final load = c.refresh();
    expect(c.state.status, ChatThreadListStatus.loading);
    expect(c.state.isRefreshing, isTrue);
    pending.complete(response(page([])));
    await load;
    expect(c.state.isEmpty, isTrue);
    http.read = (_) async => response({'secret': 'do not expose'}, 500);
    await c.refresh();
    expect(c.state.canRetry, isTrue);
    expect(c.state.error!.message, isNot(contains('secret')));
    http.read = (_) async => response(page([row('a')], more: true));
    await c.retry();
    http.read = (_) async => throw StateError('sensitive transport details');
    await c.loadMore();
    expect(c.state.error,
        isA<ChatSnapshotQueryTransportFailure<ThreadListResult>>());
    final cursor = http.reads.last.uri.queryParameters['cursor'];
    http.read = (_) async => response(page([row('b')]));
    expect((await c.retry()).items.length, 2);
    expect(http.reads.last.uri.queryParameters['cursor'], cursor);
  });
  test('refresh supersedes a pending page', () async {
    final http = Http()..value = page([row('a')], more: true);
    final client = await clientFor(http);
    final c = controllerFor(client, limit: 1);
    await c.refresh();
    final late = Completer<HandrailChatHttpResponse>();
    http.read = (_) => late.future;
    final more = c.loadMore();
    await pump();
    expect(c.state.isLoadingMore, isTrue);
    http.read = (_) async => response(page([row('new')]));
    await c.refresh();
    late.complete(response(page([row('b')])));
    await more;
    await pump();
    expect(c.state.items.map((i) => i.threadId.value), ['new']);
  });
  test(
      'parent lifecycle invalidates unopened child with revision deduplication',
      () async {
    final http = Http();
    final client = await clientFor(http);
    hydrateParent(client);
    final c = controllerFor(client);
    await c.refresh();
    expect(
        client.normalizedState.state
            .conversations[const ConversationId('unopened')],
        isNull);
    client.reduceDurableEvent(lifecycleEvent(4));
    await pump();
    expect(http.reads.length, 2);
    client.reduceDurableEvent(lifecycleEvent(4, id: 'duplicate'));
    client.reduceDurableEvent(lifecycleEvent(2));
    await pump();
    expect(http.reads.length, 2);
    client.reduceDurableEvent(lifecycleEvent(5));
    await pump();
    expect(http.reads.length, 3);
    c.setAuthority(authority);
    await c.refresh();
    client.reduceDurableEvent(lifecycleEvent(4, id: 'new-access-generation'));
    await pump();
    expect(http.reads.length, 5);
  });
  test('new-thread event refreshes discovery without opening or joining child',
      () async {
    final http = Http();
    final client = await clientFor(http);
    hydrateParent(client);
    final c = controllerFor(client);
    await c.refresh();
    client.normalizedState.hydrateMessageTimeline(MessageTimelinePage.fromJson(
        existingThreadTimelineFixture(parent: true, deletedRoot: false),
        request: MessageTimelineRequest.fromJson({
          'conversationId': parent.value,
          'direction': 'forward',
          'limit': 50
        })));
    final e = KnownDurableEvent.fromJson({
      'eventId': 'new-thread',
      'tenantId': tenant.value,
      'streamId': parent.value,
      'type': 'message.thread_summary.updated',
      'protocolVersion': 4,
      'occurredAt': time,
      'payload': {
        'parentConversationId': parent.value,
        'rootMessageId': 'message-root',
        'rootThreadSummary': {
          'threadId': 'new-child',
          'replyCount': 0,
          'participantIds': [],
          'unreadCount': 0
        }
      }
    },
        trustedIdentity:
            const DurableEventTrustedIdentity(tenantId: tenant, userId: user));
    http.value = page([row('new-child')]);
    client.reduceDurableEvent(e);
    await pump();
    expect(c.state.items.single.threadId.value, 'new-child');
    expect(http.reads.length, 2);
    expect(http.requests.every((r) => r.method == 'GET'), isTrue);
  });
  test('nearest hideAt uses evaluatedAt despite clock offset', () async {
    final clock = Clock();
    final http = Http()
      ..value = page([
        row('a', duration: 5000, activityAt: '2026-08-26T16:00:01.000Z'),
        row('b', duration: 5000)
      ], duration: 5000, evaluatedAt: '2026-08-26T16:00:02.000Z');
    final client = await clientFor(http);
    final c = controllerFor(client, clock: clock);
    final sub = c.states.listen((_) {});
    addTearDown(sub.cancel);
    await c.refresh();
    expect(clock.active.single.deadline.difference(clock.now()),
        const Duration(seconds: 3));
    clock.elapse(const Duration(seconds: 2));
    await pump();
    expect(http.reads.length, 1);
    http.value =
        page([], duration: 5000, evaluatedAt: '2026-08-26T16:00:05.000Z');
    clock.elapse(const Duration(seconds: 1));
    await pump();
    expect(http.reads.length, 2);
    expect(c.state.isEmpty, isTrue);
    expect(clock.active, isEmpty);
  });
  test('elapsed deadline backs off without a tight loop', () async {
    final clock = Clock();
    final http = Http();
    http.read = (_) async {
      clock.value = clock.value.add(const Duration(seconds: 5));
      return response(page([row('a', duration: 1)], duration: 1));
    };
    final client = await clientFor(http);
    final c = controllerFor(client, clock: clock);
    final sub = c.states.listen((_) {});
    addTearDown(sub.cancel);
    await c.refresh();
    expect(clock.active.single.deadline.difference(clock.now()),
        const Duration(seconds: 1));
    clock.elapse(const Duration(seconds: 1));
    await pump();
    expect(clock.active.single.deadline.difference(clock.now()),
        const Duration(seconds: 2));
    expect(http.reads.length, 2);
  });
  for (final mode in ['unobserved', 'disposed', 'account', 'parent']) {
    test('expiry timer cancels on $mode', () async {
      final clock = Clock();
      final http = Http()
        ..value = page([row('a', duration: 5000)], duration: 5000);
      final client = await clientFor(http);
      final c = controllerFor(client, clock: clock);
      final sub = c.states.listen((_) {});
      addTearDown(sub.cancel);
      await c.refresh();
      expect(clock.active.length, 1);
      switch (mode) {
        case 'unobserved':
          await sub.cancel();
        case 'disposed':
          await c.dispose();
        case 'account':
          c.setAuthority(null);
        case 'parent':
          c.setScope(const ConversationId('other'), authority: authority);
      }
      expect(clock.active, isEmpty);
      clock.elapse(const Duration(days: 1));
      await pump();
      expect(http.reads.length, 1);
    });
  }
  for (final view in ['active', 'all']) {
    test('disabled policy and all view skip irrelevant expiry $view', () async {
      final clock = Clock();
      final http = Http()..value = page([row('a')], view: view);
      final client = await clientFor(http);
      final c = controllerFor(client, clock: clock, view: view);
      final sub = c.states.listen((_) {});
      addTearDown(sub.cancel);
      await c.refresh();
      expect(clock.active, isEmpty);
      if (view == 'all') {
        http.value = page([row('a', duration: 1, closed: true)],
            duration: 1, view: view, evaluatedAt: '2026-08-26T16:00:05.000Z');
        await c.refresh();
        expect(c.state.items.length, 1);
        expect(clock.active, isEmpty);
      }
    });
  }
  for (final mode in ['revoked', 'account', 'parent', 'disposed']) {
    test('$mode invalidates pending HTTP including same-actor regain',
        () async {
      final http = Http();
      final client = await clientFor(http);
      final c = controllerFor(client);
      await c.refresh();
      final late = Completer<HandrailChatHttpResponse>();
      http.read = (_) => late.future;
      final pending = c.refresh();
      await pump();
      switch (mode) {
        case 'revoked':
          c.setAuthority(null);
          c.setAuthority(authority);
        case 'account':
          c.setAuthority(const ChatThreadListAuthority(
              tenantId: tenant, userId: UserId('different'), canRead: true));
        case 'parent':
          c.setScope(const ConversationId('other-parent'),
              authority: authority);
        case 'disposed':
          await c.dispose();
      }
      late.complete(response(page([row('late')])));
      await pending;
      await pump();
      expect(c.state.items, isEmpty);
    });
  }
  test('HTTP access denial clears rows and requires fresh authority', () async {
    final http = Http();
    final client = await clientFor(http);
    final c = controllerFor(client);
    await c.refresh();
    http.read = (_) async => response({'secret': 'denial'}, 403);
    await c.refresh();
    expect(c.state.status, ChatThreadListStatus.accessDenied);
    expect(c.state.items, isEmpty);
    await c.refresh();
    expect(http.reads.length, 2);
    c.setAuthority(authority);
    http.read = null;
    await c.refresh();
    expect(c.state.items.length, 1);
  });
  test(
      'newer normalized private/lifecycle state survives stale HTTP; follow and unread independent',
      () async {
    final http = Http();
    final client = await clientFor(http);
    final c = controllerFor(client);
    await c.refresh();
    expect(c.state.items.single.currentThreadFollow.follow, isNull);
    expect(c.state.items.single.unreadCount, 1);
    expect(c.state.items.single.thread.currentMember.state, 'left');
    final detail = existingThreadDetailFixture();
    final value = detail['conversation'] as Map<String, Object?>;
    (value['currentReadState'] as Map)['lastReadSequence'] = 2;
    (value['currentReadState'] as Map)['updatedAt'] =
        '2026-08-27T16:00:00.000Z';
    value['threadLifecycle'] = {'revision': 8, 'locked': false};
    client.normalizedState
        .hydrateConversationDetail(ConversationDetailSnapshot.fromJson(detail));
    await pump();
    final before = client.normalizedState.state;
    await c.refresh();
    expect(c.state.items.single.unreadCount, 0);
    expect(c.state.items.single.conversation.threadLifecycle!.revision, 8);
    expect(client.normalizedState.state, same(before));
    client.normalizedState.reconcileThreadLifecycle(
        thread,
        ThreadLifecycle(
            revision: 9,
            locked: true,
            closedAt: const IsoTimestamp(time),
            closedByUserId: user));
    await pump();
    expect(c.state.items, isEmpty);
    expect(
        (client.normalizedState.state.conversations[thread]
                as ThreadConversation)
            .threadLifecycle!
            .revision,
        9);
  });
  test(
      'follow/read events refresh while membership and notification preferences stay independent',
      () async {
    final http = Http();
    final client = await clientFor(http);
    client.normalizedState.hydrateConversationDetail(
        ConversationDetailSnapshot.fromJson(existingThreadDetailFixture()));
    hydrateParent(client);
    client.normalizedState.hydrateMessageTimeline(MessageTimelinePage.fromJson(
        existingThreadTimelineFixture(parent: true, deletedRoot: false),
        request: MessageTimelineRequest.fromJson({
          'conversationId': parent.value,
          'direction': 'forward',
          'limit': 50
        })));
    final c = controllerFor(client);
    await c.refresh();
    final before = client.normalizedState.state;
    final follow = {
      'target': {'type': 'thread', 'id': thread.value},
      'isFollowing': true,
      'source': 'manual',
      'updatedAt': time
    };
    client.reduceDurableEvent(KnownDurableEvent.fromJson({
      'eventId': 'follow-8',
      'protocolVersion': 4,
      'tenantId': tenant.value,
      'streamId': 'user:${user.value}',
      'type': 'thread.follow.updated',
      'occurredAt': time,
      'payload': {
        'operation': 'set_thread_follow',
        'target': {'type': 'thread', 'id': thread.value},
        'followRevision': 8,
        'follow': follow
      }
    },
        trustedIdentity:
            const DurableEventTrustedIdentity(tenantId: tenant, userId: user)));
    await pump();
    expect(http.reads.length, 2);
    expect(c.state.items.single.currentThreadFollow.followRevision, 8);
    expect(
        c.state.items.single.currentThreadFollow.follow!.isFollowing, isTrue);
    expect(c.state.items.single.unreadCount, 1);
    expect(client.normalizedState.state.membersByConversation,
        before.membersByConversation);
    expect(client.normalizedState.state.currentUserPreferences,
        before.currentUserPreferences);
    client.reduceDurableEvent(KnownDurableEvent.fromJson({
      'eventId': 'read-2',
      'protocolVersion': 4,
      'tenantId': tenant.value,
      'streamId': 'user:${user.value}',
      'type': 'conversation.read_cursor_updated',
      'occurredAt': time,
      'payload': {
        'kind': 'conversation_read_cursor',
        'actorUserId': user.value,
        'operation': 'mark_read',
        'reconciliationStatus': 'applied',
        'conversationId': thread.value,
        'readState': {
          'conversationId': thread.value,
          'userId': user.value,
          'lastReadSequence': 2,
          'updatedAt': '2026-08-27T16:00:00.000Z'
        },
        'latestSequence': 2,
        'unreadCount': 0
      }
    },
        trustedIdentity:
            const DurableEventTrustedIdentity(tenantId: tenant, userId: user)));
    await pump();
    expect(c.state.items.single.unreadCount, 0);
    expect(c.state.items.single.currentThreadFollow.followRevision, 8);
    expect(http.reads.length, 3);
    expect(http.requests.every((r) => r.method == 'GET'), isTrue);
  });
  test('durable private-parent membership loss invalidates in-flight discovery',
      () async {
    final http = Http();
    final client = await clientFor(http);
    hydrateParent(client);
    final c = controllerFor(client);
    await c.refresh();
    final pending = Completer<HandrailChatHttpResponse>();
    http.read = (_) => pending.future;
    final load = c.refresh();
    await pump();
    final input = {
      'operation': 'mutate_conversation_membership',
      'intent': 'leave',
      'conversationId': parent.value,
      'expectedMemberListRevision': 1,
      'idempotencyKey': 'leave-parent'
    };
    client.reduceDurableEvent(KnownDurableEvent.fromJson({
      'eventId': 'leave-parent',
      'protocolVersion': 4,
      'tenantId': tenant.value,
      'streamId': 'user:${user.value}',
      'type': 'conversation.membership.updated',
      'occurredAt': time,
      'payload': {
        'input': input,
        'result': {
          for (final e in input.entries)
            if (e.key != 'idempotencyKey') e.key: e.value,
          'reconciliationStatus': 'applied',
          'memberListRevision': 2,
          'memberUserId': user.value,
          'members': [
            {
              'userId': user.value,
              'role': 'member',
              'state': 'left',
              'joinedAt': time,
              'updatedAt': time
            }
          ]
        }
      }
    },
        trustedIdentity:
            const DurableEventTrustedIdentity(tenantId: tenant, userId: user)));
    expect(c.state.status, ChatThreadListStatus.accessDenied);
    c.setAuthority(authority);
    pending.complete(response(page([row('late')])));
    await load;
    expect(c.state.items, isEmpty);
  });
  test(
      'malformed scope and actor pages are sanitized errors, never empty success',
      () async {
    final http = Http();
    final client = await clientFor(http);
    final c = controllerFor(client);
    http.value = page([], parentId: 'wrong-parent');
    await c.refresh();
    expect(c.state.error,
        isA<ChatSnapshotQueryMalformedResponse<ThreadListResult>>());
    final wrongActor = jsonDecode(
            jsonEncode(page([row('a')])).replaceAll(user.value, 'other-user'))
        as Map<String, dynamic>;
    http.value = wrongActor;
    await c.retry();
    expect(c.state.error,
        isA<ChatSnapshotQueryMalformedResponse<ThreadListResult>>());
    expect(c.state.status, ChatThreadListStatus.error);
    expect(c.state.items, isEmpty);
  });
  test(
      'disappearing row preserves open thread, draft and pending send destination',
      () async {
    final http = Http();
    final client = await clientFor(http);
    final c = controllerFor(client);
    await c.refresh();
    final opened = await client.threads.openExistingThread(thread);
    expect(opened, isA<ChatExistingThreadOpenSuccess>());
    final snapshot = client.normalizedState.state.conversations[thread];
    final pending = Completer<HandrailChatHttpResponse>();
    http.write = (_) => pending.future;
    final draft = client.synchronizeDraft(ChatReplaceDraftInput(
        conversationId: thread,
        baseRevision: 0,
        content: DraftContent.fromJson(
            {'format': 'plain', 'text': 'Keep draft', 'attachments': []})));
    final send = client.sendMessage(ChatSendMessageInput(
        conversationId: thread,
        content: MessageContent.fromJson(
            {'format': 'plain', 'text': 'Queued here'})));
    await pump();
    final before = client.draftFor(thread);
    expect(before, isNotNull);
    http.value = page([]);
    await c.refresh();
    expect(c.state.isEmpty, isTrue);
    expect(client.normalizedState.state.conversations[thread], same(snapshot));
    expect(client.draftFor(thread), same(before));
    final request = http.requests.singleWhere(
        (r) => r.method == 'POST' && r.uri.path.endsWith('/messages'));
    expect(request.uri.path, endsWith('/conversation-thread/messages'));
    expect(jsonDecode(request.body!)['conversationId'], thread.value);
    await client.dispose();
    await draft;
    await send;
  });
  test(
      'reconnect and parent subscription revocation reject late response after regain',
      () async {
    final socket = Socket();
    final realtime = ChatRealtimeSessionTransport(
        endpoint: Uri.parse('https://chat.test/api/chat'),
        clientPackageVersion: '0.1.4',
        protocolVersion: 4,
        tokenProvider: () => 'token',
        socketFactory: (_, __) => socket);
    addTearDown(realtime.dispose);
    final http = Http();
    final client = await clientFor(http, realtime: realtime);
    await realtime.start();
    socket.accept();
    await pump();
    final retainedParent = realtime.subscribeConversation(parent);
    final c = controllerFor(client);
    await c.refresh();
    await pump();
    expect(
        socket.sent
            .where((s) =>
                s['type'] == 'chat.subscribe' && s['streamId'] == parent.value)
            .length,
        1);
    expect(socket.sent.where((s) => s['streamId'] == thread.value), isEmpty);
    await realtime.suspend();
    await realtime.start();
    socket.accept();
    await pump();
    expect(http.reads.length, 2);
    final pending = Completer<HandrailChatHttpResponse>();
    http.read = (_) => pending.future;
    final load = c.refresh();
    await pump();
    socket.emit({
      'type': 'chat.subscription.revoked',
      'code': 'access_revoked',
      'streamId': parent.value
    });
    await pump();
    expect(c.state.status, ChatThreadListStatus.accessDenied);
    expect(c.state.items, isEmpty);
    c.setAuthority(authority);
    http.read = (_) async => response(page([row('new-access')]));
    await c.refresh();
    pending.complete(response(page([row('late')])));
    await load;
    await pump();
    expect(c.state.items.single.threadId.value, 'new-access');
    retainedParent();
    await c.dispose();
  });
}

class Socket implements ChatRealtimeSocket {
  final controller = StreamController<Object?>.broadcast(sync: true);
  final sent = <Map<String, dynamic>>[];
  @override
  Stream<Object?> get frames => controller.stream;
  @override
  void close() {}
  @override
  void send(String data) {
    final json = jsonDecode(data) as Map<String, dynamic>;
    sent.add(json);
    if (json['type'] == 'chat.subscribe')
      scheduleMicrotask(() => emit({
            'type': 'chat.subscription.accepted',
            'streamId': json['streamId'],
            'requestId': json['requestId']
          }));
  }

  void emit(Map<String, Object?> json) => controller.add(jsonEncode(json));
  void accept() => emit({
        'type': 'chat.session.accepted',
        'metadata': metadata,
        'tenantId': tenant.value,
        'actorStreamId': 'user:${user.value}',
        'deviceId': 'device-1',
        'sessionId': 'session-1'
      });
}
