import 'dart:async';
import 'dart:convert';

import 'package:handrail_chat/core.dart';
import 'package:test/test.dart';

import 'fixtures/existing_thread_opening_fixtures.dart';

const parent = ConversationId('conversation-parent');
const thread = ConversationId('conversation-thread');
const sourceId = MessageId('message-reply');
const tenant = TenantId('tenant-from-session');
const user = UserId('user-current');
const time = existingThreadFixtureTime;
const authority =
    ChatMessageContextAuthority(tenantId: tenant, userId: user, canRead: true);
MessageContextRequest get request =>
    MessageContextRequest(conversationId: thread, messageId: sourceId);
Map<String, Object?> get metadata => {
      'packageVersion': '0.1.4',
      'protocolVersion': 4,
      'schemaVersion': 1,
      'enabledFeatures': <String, Object?>{},
      'supportedProtocolRange': {'minimumVersion': 1, 'maximumVersion': 4},
    };
HandrailChatHttpResponse response(Object? body, [int status = 200]) =>
    HandrailChatHttpResponse(statusCode: status, body: jsonEncode(body));
Map<String, Object?> message(
        {int revision = 2,
        bool deleted = false,
        String text = 'Source preview',
        int sequence = 10,
        String id = 'message-reply'}) =>
    {
      'id': id,
      'tenantId': tenant.value,
      'conversationId': thread.value,
      'author': {'type': 'user', 'userId': 'user-other'},
      'sequence': sequence,
      'createdAt': time,
      'updatedAt': time,
      'revision': {'revision': revision},
      'content': deleted ? null : {'format': 'plain', 'text': text},
      if (deleted) ...{'deletedAt': time, 'deletedByUserId': 'user-other'},
    };
Map<String, Object?> context(
        {int revision = 2,
        bool deleted = false,
        String text = 'Source preview'}) =>
    {
      'status': deleted ? 'deleted' : 'available',
      'conversationId': thread.value,
      'messageId': sourceId.value,
      'sequence': 10,
      'message': message(revision: revision, deleted: deleted, text: text),
    };
Map<String, Object?> page(List<int> sequences,
        {bool older = false, bool newer = false}) =>
    {
      'conversationId': thread.value,
      'messages': [
        for (final n in sequences)
          {
            ...message(
                sequence: n, id: n == 10 ? sourceId.value : 'message-$n'),
            'isThreadRoot': false,
            'reactions': <Object?>[],
            'attachmentMetadata': <Object?>[],
          }
      ],
      'pagination': {
        'older': {'available': older, if (older) 'cursor': sequences.first},
        'newer': {'available': newer, if (newer) 'cursor': sequences.last},
      },
      'replay': {
        'resumeFrom': {'eventId': 'page-event'}
      },
    };
typedef Handler = Future<HandrailChatHttpResponse> Function(
    HandrailChatHttpRequest);

class Http implements HandrailChatHttpTransport {
  final requests = <HandrailChatHttpRequest>[];
  Handler? read, timeline, detail;
  Map<String, Object?> value = context();
  @override
  Future<HandrailChatHttpResponse> send(HandrailChatHttpRequest r) async {
    requests.add(r);
    if (r.uri.path.endsWith('/_meta')) return response(metadata);
    if (r.uri.path.endsWith('/context'))
      return read == null ? response(value) : await read!(r);
    if (r.uri.path.endsWith('/messages'))
      return timeline == null ? response(page([])) : await timeline!(r);
    return detail == null
        ? response(existingThreadDetailFixture())
        : await detail!(r);
  }

  List<HandrailChatHttpRequest> get reads =>
      requests.where((r) => r.uri.path.endsWith('/context')).toList();
  List<HandrailChatHttpRequest> get pages =>
      requests.where((r) => r.uri.path.endsWith('/messages')).toList();
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

ChatMessageContextController controllerFor(HandrailChatClient client) =>
    client.messageContexts.forMessage(request, pageSize: 2)
      ..setAuthority(authority);
Future<void> pump() async {
  for (var i = 0; i < 10; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}

void hydrate(HandrailChatClient client) {
  client.normalizedState.hydrateConversationDetail(
      ConversationDetailSnapshot.fromJson(existingThreadDetailFixture()));
  client.normalizedState.hydrateMessageTimeline(MessageTimelinePage.fromJson(
      page([10]),
      request: MessageTimelineRequest(
          conversationId: thread,
          direction: MessageTimelineDirection.backward,
          limit: 2)));
}

KnownDurableEvent event({bool deleted = false, int revision = 3}) =>
    KnownDurableEvent.fromJson({
      'eventId': 'change-$revision',
      'tenantId': tenant.value,
      'streamId': thread.value,
      'type': deleted ? 'message.deleted' : 'message.updated',
      'protocolVersion': 4,
      'occurredAt': time,
      'payload': {
        'message': message(revision: revision, deleted: deleted, text: 'Edited')
      },
    },
        trustedIdentity:
            const DurableEventTrustedIdentity(tenantId: tenant, userId: user));

Map<String, Object?> parentDetail({bool left = false, bool public = false}) {
  final detail = jsonDecode(jsonEncode(existingThreadDetailFixture())
      .replaceAll(thread.value, parent.value)) as Map<String, dynamic>;
  final c = detail['conversation'] as Map<String, dynamic>;
  c.remove('parentConversationId');
  c.remove('rootMessageId');
  c['type'] = 'channel';
  c['name'] = 'Parent';
  c['visibility'] = public ? 'public' : 'private';
  if (left) c['updatedAt'] = '2026-08-27T16:00:00.000Z';
  (c['currentMember'] as Map)['state'] = left ? 'left' : 'active';
  if (left)
    (c['currentMember'] as Map)['updatedAt'] = '2026-08-27T16:00:00.000Z';
  return detail;
}

KnownDurableEvent parentRevocation() {
  final input = {
    'operation': 'mutate_conversation_membership',
    'intent': 'leave',
    'conversationId': parent.value,
    'expectedMemberListRevision': 1,
    'idempotencyKey': 'leave-parent',
  };
  return KnownDurableEvent.fromJson({
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
            'updatedAt': time,
          }
        ],
      }
    },
  },
      trustedIdentity:
          const DurableEventTrustedIdentity(tenantId: tenant, userId: user));
}

void main() {
  for (final deleted in [false, true]) {
    test(
        'unloaded source ${deleted ? 'deletion' : 'edit'} enters existing realtime recovery and clears text',
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
      final c = controllerFor(client);
      await c.load();
      await pump();
      expect(client.normalizedState.state.canonicalMessages, isEmpty);
      final held = Completer<HandrailChatHttpResponse>();
      http.read = (_) => held.future;
      final pending = c.load();
      await pump();
      final recovery = Completer<HandrailChatHttpResponse>();
      http.detail = (_) => recovery.future;
      socket.emit(event(deleted: deleted).toJson());
      await pump();
      expect(realtime.state, isA<ChatRealtimeHydratingSnapshotState>());
      expect(c.state.result, isNull);
      held.complete(response(context()));
      await pending;
      expect(c.state.source, isNull);
      await client.dispose();
      recovery.complete(response({}, 403));
    });
  }
  test(
      'channel source reuses the existing conversation/message navigation target',
      () async {
    final http = Http();
    http.value =
        jsonDecode(jsonEncode(context()).replaceAll(thread.value, parent.value))
            as Map<String, dynamic>;
    http.detail = (_) async => response(parentDetail());
    final client = await clientFor(http);
    final c = client.messageContexts.forMessage(
        MessageContextRequest(conversationId: parent, messageId: sourceId))
      ..setAuthority(authority);
    await c.load();
    expect(c.state.status, ChatMessageContextStatus.available);
    expect(c.navigationTarget, isA<ChatMessageDeepLinkTarget>());
    expect(c.navigationTarget.conversationId, parent);
    expect(http.requests.every((r) => r.method == 'GET'), isTrue);
  });
  for (final phase in ['lookup', 'detail', 'page']) {
    for (final boundary in ['durable', 'snapshot']) {
      test(
          'parent $boundary revocation during $phase clears unresolved or loaded child',
          () async {
        final http = Http();
        final client = await clientFor(http);
        client.normalizedState.hydrateConversationDetail(
            ConversationDetailSnapshot.fromJson(parentDetail()));
        final c = controllerFor(client);
        if (phase == 'page') await c.load();
        final held = Completer<HandrailChatHttpResponse>();
        if (phase == 'lookup') http.read = (_) => held.future;
        if (phase == 'detail') http.detail = (_) => held.future;
        if (phase == 'page') http.timeline = (_) => held.future;
        final pending = phase == 'page' ? c.loadAfter() : c.load();
        await pump();
        if (boundary == 'durable') {
          expect(client.reduceDurableEvent(parentRevocation()).status,
              DurableEventReductionStatus.applied);
        } else {
          client.normalizedState.hydrateConversationDetail(
              ConversationDetailSnapshot.fromJson(parentDetail(left: true)));
        }
        expect(c.state.status, ChatMessageContextStatus.unavailable);
        expect(c.state.source, isNull);
        held.complete(response(phase == 'lookup'
            ? context()
            : phase == 'detail'
                ? existingThreadDetailFixture()
                : page([11])));
        await pending;
        expect(c.state.result, isNull);
        expect(c.state.after, isEmpty);
      });
    }
  }
  test(
      'public parent and child participation changes do not revoke read access',
      () async {
    final http = Http();
    final client = await clientFor(http);
    client.normalizedState.hydrateConversationDetail(
        ConversationDetailSnapshot.fromJson(parentDetail(public: true)));
    final c = controllerFor(client);
    await c.load();
    client.normalizedState.hydrateConversationDetail(
        ConversationDetailSnapshot.fromJson(
            parentDetail(left: true, public: true)));
    client.normalizedState.hydrateConversationDetail(
        ConversationDetailSnapshot.fromJson(existingThreadDetailFixture()));
    expect(c.state.source, isNotNull);
  });
  for (final phase in ['lookup', 'page']) {
    test('accepted client identity change during $phase rejects old requests',
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
      final c = controllerFor(client);
      await c.load();
      final held = Completer<HandrailChatHttpResponse>();
      if (phase == 'lookup') http.read = (_) => held.future;
      if (phase == 'page') http.timeline = (_) => held.future;
      final pending = phase == 'lookup' ? c.load() : c.loadAfter();
      await pump();
      await realtime.suspend();
      await pump();
      await realtime.start();
      socket.accept(actor: 'new-user');
      await pump();
      held.complete(response(phase == 'lookup' ? context() : page([11])));
      await pending;
      expect(c.state.status, ChatMessageContextStatus.unavailable);
      expect(c.state.source, isNull);
      expect(c.state.after, isEmpty);
      final count = http.reads.length;
      await c.retry();
      expect(http.reads.length, count);
    });
  }
  test(
      'unloaded source uses authenticated GET without hydration or side effects',
      () async {
    final http = Http();
    final client = await clientFor(http);
    final c = controllerFor(client);
    expect((await c.states.first).status, ChatMessageContextStatus.idle);
    final state = await c.load();
    expect(state.status, ChatMessageContextStatus.available);
    expect(state.source?.content.text, 'Source preview');
    expect(http.reads.single.uri.path,
        '/api/chat/conversations/conversation-thread/messages/message-reply/context');
    expect(http.reads.single.headers['Authorization'], 'Bearer test-token');
    expect(http.pages, isEmpty);
    expect(client.normalizedState.state.canonicalMessages, isEmpty);
    expect(client.normalizedState.state.conversations, isEmpty);
    expect(client.normalizedState.state.currentUserDrafts, isEmpty);
    expect(http.requests.every((r) => r.method == 'GET'), isTrue);
    expect(c.navigationTarget, isA<ChatExistingThreadDeepLinkTarget>());
  });
  test('source lookups and active futures deduplicate across consumers',
      () async {
    final http = Http();
    final held = Completer<HandrailChatHttpResponse>();
    http.read = (_) => held.future;
    final client = await clientFor(http);
    final c = controllerFor(client);
    final a = c.load();
    expect(c.state.status, ChatMessageContextStatus.loading);
    expect(client.messageContexts.forMessage(request), same(c));
    expect(c.load(), same(a));
    await pump();
    expect(http.reads.length, 1);
    held.complete(response(context()));
    await a;
    expect(c.state.source, isNotNull);
  });
  test(
      'before and after use exclusive sequence cursors and bounded continuation',
      () async {
    final http = Http();
    final client = await clientFor(http);
    final c = controllerFor(client);
    await c.load();
    http.timeline = (_) async => response(page([8, 9], older: true));
    await c.loadBefore();
    expect(http.pages.last.uri.queryParameters, {'before': '10', 'limit': '2'});
    http.timeline = (_) async => response(page([6, 7]));
    await c.loadBefore();
    expect(http.pages.last.uri.queryParameters['before'], '8');
    http.timeline = (_) async => response(page([11, 12], newer: true));
    await c.loadAfter();
    expect(http.pages.last.uri.queryParameters, {'after': '10', 'limit': '2'});
    http.timeline = (_) async => response(page([13]));
    await c.loadAfter();
    expect(http.pages.last.uri.queryParameters['after'], '12');
    expect(c.state.before.map((m) => m.sequence.value), [6, 7, 8, 9]);
    expect(c.state.after.map((m) => m.sequence.value), [11, 12, 13]);
    expect(c.state.source?.sequence.value, 10);
    expect(c.state.canLoadBefore, isFalse);
    expect(c.state.canLoadAfter, isFalse);
    await c.loadBefore();
    await c.loadAfter();
    expect(http.pages.length, 4);
    expect(() => c.state.before.clear(), throwsUnsupportedError);
  });
  test('an inclusive or wrong-tenant page is a retryable error', () async {
    final http = Http();
    final c = controllerFor(await clientFor(http));
    await c.load();
    http.timeline = (_) async => response(page([10]));
    await c.loadBefore();
    expect(c.state.error, isA<ChatSnapshotQueryMalformedResponse>());
    expect(c.state.source, isNull);
    await c.retry();
    http.timeline = (_) async => response(jsonDecode(
        jsonEncode(page([11])).replaceAll(tenant.value, 'wrong-tenant')));
    await c.loadAfter();
    expect(c.state.status, ChatMessageContextStatus.error);
  });
  test('deleted and unavailable are distinct successful results', () async {
    final http = Http()..value = context(deleted: true);
    final c = controllerFor(await clientFor(http));
    expect((await c.load()).result, isA<DeletedMessageContext>());
    expect(c.state.status, ChatMessageContextStatus.deleted);
    expect(c.state.source, isNull);
    http.value = {
      'status': 'unavailable',
      'conversationId': thread.value,
      'messageId': sourceId.value
    };
    expect((await c.load()).result, isA<UnavailableMessageContext>());
    expect(c.state.status, ChatMessageContextStatus.unavailable);
    expect(c.state.error, isNull);
  });
  for (final kind in [
    'transport',
    'json',
    'identity',
    'tenant',
    'authentication',
    'detail'
  ]) {
    test('$kind failure remains an error and retry reauthorizes', () async {
      final http = Http();
      final c = controllerFor(await clientFor(http));
      await c.load();
      switch (kind) {
        case 'transport':
          http.read = (_) async => throw StateError('secret transport detail');
        case 'json':
          http.read = (_) async =>
              const HandrailChatHttpResponse(statusCode: 200, body: 'invalid');
        case 'identity':
          http.value = {...context(), 'messageId': 'wrong'};
        case 'tenant':
          http.value = {
            ...context(),
            'message': {...message(), 'tenantId': 'wrong'}
          };
        case 'authentication':
          http.read = (_) async => response({}, 401);
        case 'detail':
          http.detail = (_) async => response({}, 403);
      }
      await c.load();
      expect(c.state.status, ChatMessageContextStatus.error);
      expect(c.state.canRetry, isTrue);
      expect(c.state.source, isNull);
      expect(c.state.error.toString(), isNot(contains('secret')));
      http.read = null;
      http.detail = null;
      http.value = context(text: 'Fresh');
      await c.retry();
      expect(c.state.source?.content.text, 'Fresh');
    });
  }
  for (final deleted in [false, true]) {
    for (final phase in ['lookup', 'detail', 'page']) {
      test(
          '${deleted ? 'delete' : 'edit'} during $phase rejects stale text and pages',
          () async {
        final http = Http();
        final client = await clientFor(http);
        hydrate(client);
        final c = controllerFor(client);
        await c.load();
        final held = Completer<HandrailChatHttpResponse>();
        if (phase == 'lookup') http.read = (_) => held.future;
        if (phase == 'detail') http.detail = (_) => held.future;
        if (phase == 'page') http.timeline = (_) => held.future;
        final pending = phase == 'page' ? c.loadAfter() : c.load();
        await pump();
        expect(client.reduceDurableEvent(event(deleted: deleted)).status,
            DurableEventReductionStatus.applied);
        expect(c.state.source, isNull);
        expect(c.state.before, isEmpty);
        expect(c.state.after, isEmpty);
        expect(
            c.state.status,
            deleted
                ? ChatMessageContextStatus.deleted
                : ChatMessageContextStatus.idle);
        http.read = null;
        http.detail = null;
        http.value =
            context(deleted: deleted, revision: 3, text: 'Fresh authorized');
        await c.retry();
        held.complete(response(phase == 'lookup'
            ? context()
            : phase == 'detail'
                ? existingThreadDetailFixture()
                : page([11])));
        await pending;
        expect(
            c.state.source?.content.text, deleted ? null : 'Fresh authorized');
        expect(c.state.after, isEmpty);
      });
    }
  }
  test('normalized snapshot edits clear preview; older retry cannot restore it',
      () async {
    final http = Http();
    final client = await clientFor(http);
    hydrate(client);
    final c = controllerFor(client);
    await c.load();
    final updated = page([10]);
    ((updated['messages'] as List).single as Map)['revision'] = {'revision': 3};
    client.normalizedState.hydrateMessageTimeline(MessageTimelinePage.fromJson(
        updated,
        request: MessageTimelineRequest(
            conversationId: thread,
            direction: MessageTimelineDirection.backward,
            limit: 2)));
    expect(c.state.source, isNull);
    await c.retry();
    expect(c.state.status, ChatMessageContextStatus.error);
    expect(c.state.source, isNull);
  });
  for (final phase in ['lookup', 'detail', 'page']) {
    test('authority identity replacement during $phase rejects old completion',
        () async {
      final http = Http();
      final c = controllerFor(await clientFor(http));
      await c.load();
      final held = Completer<HandrailChatHttpResponse>();
      if (phase == 'lookup') http.read = (_) => held.future;
      if (phase == 'detail') http.detail = (_) => held.future;
      if (phase == 'page') http.timeline = (_) => held.future;
      final pending = phase == 'page' ? c.loadBefore() : c.load();
      await pump();
      c.setAuthority(const ChatMessageContextAuthority(
          tenantId: tenant, userId: UserId('new-user'), canRead: true));
      expect(c.state.source, isNull);
      held.complete(response(phase == 'lookup'
          ? context()
          : phase == 'detail'
              ? existingThreadDetailFixture()
              : page([9])));
      await pending;
      expect(c.state.status, ChatMessageContextStatus.idle);
      expect(c.state.result, isNull);
    });
  }
  test('disposal synchronously clears text, cancels pages and closes observers',
      () async {
    final http = Http();
    final client = await clientFor(http);
    final c = controllerFor(client);
    await c.load();
    final held = Completer<HandrailChatHttpResponse>();
    http.timeline = (_) => held.future;
    final pending = c.loadAfter();
    await pump();
    final states = <ChatMessageContextState>[];
    final sub = c.states.listen(states.add);
    final disposed = client.dispose();
    expect(c.state.source, isNull);
    expect(c.state.status, ChatMessageContextStatus.disposed);
    held.complete(response(page([11])));
    await pending;
    await disposed;
    await sub.cancel();
    expect(c.state.after, isEmpty);
    expect((await c.states.first).status, ChatMessageContextStatus.disposed);
  });
  test(
      'reconnect clears text and reloads; shared parent revocation wins against pages',
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
    final retain = realtime.subscribeConversation(parent);
    final c = controllerFor(client);
    await c.load();
    await pump();
    expect(
        socket.sent
            .where((s) =>
                s['type'] == 'chat.subscribe' && s['streamId'] == parent.value)
            .length,
        1);
    expect(c.state.source, isNotNull);
    final old = Completer<HandrailChatHttpResponse>();
    http.timeline = (_) => old.future;
    final pending = c.loadAfter();
    await pump();
    await realtime.suspend();
    await pump();
    expect(c.state.source, isNull);
    http.value = context(text: 'Reconnected');
    await realtime.start();
    socket.accept();
    await pump();
    expect(c.state.source?.content.text, 'Reconnected');
    old.complete(response(page([11])));
    await pending;
    expect(c.state.after, isEmpty);
    final held = Completer<HandrailChatHttpResponse>();
    http.timeline = (_) => held.future;
    final load = c.loadBefore();
    await pump();
    socket.emit({
      'type': 'chat.subscription.revoked',
      'code': 'access_revoked',
      'streamId': parent.value
    });
    await pump();
    expect(c.state.status, ChatMessageContextStatus.unavailable);
    expect(c.state.source, isNull);
    c.setAuthority(authority);
    http.value = context(text: 'New access');
    await c.retry();
    held.complete(response(page([9])));
    await load;
    expect(c.state.source?.content.text, 'New access');
    expect(c.state.before, isEmpty);
    retain();
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
    final value = jsonDecode(data) as Map<String, dynamic>;
    sent.add(value);
    if (value['type'] == 'chat.subscribe') {
      scheduleMicrotask(() => emit({
            'type': 'chat.subscription.accepted',
            'streamId': value['streamId'],
            'requestId': value['requestId']
          }));
    }
  }

  void emit(Map<String, Object?> value) => controller.add(jsonEncode(value));
  void accept({String actor = 'user-current'}) => emit({
        'type': 'chat.session.accepted',
        'metadata': metadata,
        'tenantId': tenant.value,
        'actorStreamId': 'user:$actor',
        'deviceId': 'device-1',
        'sessionId': 'session-1',
      });
}
