import 'dart:async';
import 'dart:convert';

import 'package:handrail_chat/core.dart';
import 'package:test/test.dart';

import 'fixtures/conversation_list_fixtures.dart';

const _id = ConversationId('conversation-1');
const _time = conversationListTestNow;

void main() {
  test(
      'reply ping badge refreshes live, deduplicates replay and matches reload',
      () async {
    var count = 1;
    final transport =
        _Transport((_) async => _response(_detail(count: count, sequence: 1)));
    final client = _client(transport);
    addTearDown(client.dispose);
    final badges = <int>[];
    final subscription = client.normalizedState
        .watchConversation(_id)
        .listen((value) => badges.add(value.metadata?.unreadMentionCount ?? 0));
    addTearDown(subscription.cancel);
    final event = _event(1);
    expect((event.payload.data['message'] as Map)['content'],
        {'format': 'plain', 'text': 'Friday'});
    client.reduceDurableEvent(event);
    client.reduceDurableEvent(event);
    await _pump();
    expect(transport.requests, hasLength(1));
    expect(_badge(client), 1);
    expect(badges, contains(1));
    client.reduceDurableEvent(event);
    await _pump();
    expect(transport.requests, hasLength(1));
    expect(_badge(client), 1);
    final reloaded = NormalizedSnapshotStore();
    addTearDown(reloaded.close);
    reloaded.hydrateConversationDetail(
        ConversationDetailSnapshot.fromJson(_detail(count: 1, sequence: 1)));
    expect(reloaded.conversation(_id).metadata?.unreadMentionCount,
        _badge(client));

    // A reply deletion changes server mention authority without changing the
    // read cursor or conversation timestamps. No local mention arithmetic.
    count = 0;
    client.reduceDurableEvent(_event(1, deleted: true));
    await _pump();
    expect(_badge(client), 0);
    expect(transport.requests, hasLength(2));
    client.reduceDurableEvent(_event(1, deleted: true));
    await _pump();
    expect(transport.requests, hasLength(2));
    expect(
        client
            .normalizedState
            .state
            .canonicalMessages[const MessageId('message-1')]
            ?.replyTo
            ?.notifyAuthor,
        isTrue);
  });

  test('canonical source deletion refreshes its reply ping count', () async {
    var count = 1;
    final transport =
        _Transport((_) async => _response(_detail(count: count, sequence: 2)));
    final client = _client(transport);
    addTearDown(client.dispose);
    client.reduceDurableEvent(_event(1, reply: false));
    client.reduceDurableEvent(_event(2, target: 'message-1'));
    await _pump();
    expect(_badge(client), 1);
    count = 0;
    final deleted = Message.fromJson(
        _event(1, deleted: true, reply: false).payload.data['message']);
    client.normalizedState.reconcileMessage(deleted);
    await _pump();
    expect(_badge(client), 0);
    expect(transport.requests, hasLength(2));
    client.normalizedState.reconcileMessage(deleted);
    await _pump();
    expect(transport.requests, hasLength(2));
    expect(
        client
            .normalizedState
            .state
            .canonicalMessages[const MessageId('message-2')]
            ?.replyTo
            ?.messageId,
        const MessageId('message-1'));
  });

  test('newer read authority wins over a pending older snapshot', () async {
    final pending = Completer<HandrailChatHttpResponse>();
    var requests = 0;
    final transport = _Transport((_) {
      requests += 1;
      return requests == 1
          ? pending.future
          : Future.value(_response(_detail(count: 7, sequence: 1)));
    });
    final client = _client(transport);
    addTearDown(client.dispose);
    client.reduceDurableEvent(_event(1));
    await _pump();
    final read = ConversationReadState.fromJson({
      'conversationId': _id.value,
      'userId': conversationListTestUser,
      'lastReadSequence': 1,
      'updatedAt': '2026-08-26T23:02:00.000Z',
    });
    client.normalizedState
        .projectCurrentUserReadState(read, authoritativeReadState: read);
    pending.complete(_response(_detail(count: 99, sequence: 1)));
    await _pump();
    expect(requests, 2);
    expect(_badge(client), 0);
    expect(
        client.normalizedState
            .conversation(_id)
            .currentReadState
            ?.lastReadSequence
            .value,
        1);
  });

  test('bursts coalesce and a change during transport discards the old count',
      () async {
    final responses = <Completer<HandrailChatHttpResponse>>[];
    final transport = _Transport((_) {
      final response = Completer<HandrailChatHttpResponse>();
      responses.add(response);
      return response.future;
    });
    final client = _client(transport);
    addTearDown(client.dispose);
    client.reduceDurableEvent(_event(1));
    client.reduceDurableEvent(_event(2));
    await _pump();
    expect(responses, hasLength(1));
    client.reduceDurableEvent(_event(3));
    responses[0].complete(_response(_detail(count: 99, sequence: 2)));
    await _pump();
    expect(_badge(client), 0);
    expect(responses, hasLength(2));
    responses[1].complete(_response(_detail(count: 3, sequence: 3)));
    await _pump();
    expect(_badge(client), 3);
    expect(client.normalizedState.state.canonicalMessages, hasLength(3));
  });

  test('revoked access and disposal reject pending authoritative responses',
      () async {
    for (final dispose in [false, true]) {
      final response = Completer<HandrailChatHttpResponse>();
      final transport = _Transport((_) => response.future);
      final client = _client(transport);
      client.reduceDurableEvent(_event(1));
      await _pump();
      if (dispose) {
        await client.dispose();
      } else {
        client.reduceDurableEvent(_revoke());
        expect(client.normalizedState.state.currentUserReadStates, isEmpty);
      }
      response.complete(_response(_detail(count: 9, sequence: 1)));
      await _pump();
      if (!dispose) {
        expect(client.normalizedState.state.currentUserReadStates, isEmpty);
        expect(client.normalizedState.state.canonicalMessages, isEmpty);
        expect(_badge(client), 0);
        await client.dispose();
      }
    }
  });

  test(
      'connected session refreshes authority and isolates an old actor response',
      () async {
    final socket = _Socket();
    final session = ChatRealtimeSessionTransport(
        endpoint: Uri.parse('https://chat.test'),
        clientPackageVersion: '0.1.3',
        protocolVersion: handrailChatDurableEventProtocolVersion,
        tokenProvider: () => 'token',
        socketFactory: (_, __) => socket);
    final responses = <Completer<HandrailChatHttpResponse>>[];
    final transport = _Transport((_) {
      final response = Completer<HandrailChatHttpResponse>();
      responses.add(response);
      return response.future;
    });
    final client = _client(transport, session: session);
    addTearDown(client.dispose);
    addTearDown(session.dispose);
    await session.start();
    socket.emit(_accepted(conversationListTestUser));
    await _pump();
    expect(responses, hasLength(1));
    responses[0].complete(_response(_detail(count: 2)));
    await _pump();
    expect(_badge(client), 2);
    // An ordinary reconnect (without expired-cursor recovery) still refreshes.
    await session.close();
    await session.start();
    socket.emit(_accepted(conversationListTestUser));
    await _pump();
    expect(responses, hasLength(2));
    responses[1].complete(_response(_detail(count: 2)));
    await _pump();
    expect(_badge(client), 2);
    client.reduceDurableEvent(_event(1));
    await _pump();
    expect(responses, hasLength(3));
    await session.close();
    await session.start();
    socket.emit(_accepted('other-user'));
    await _pump();
    responses[2].complete(_response(_detail(count: 99, sequence: 1)));
    await _pump();
    expect(client.normalizedState.state.conversations, isEmpty);
    expect(client.normalizedState.state.conversationMetadata, isEmpty);
  });
}

HandrailChatClient _client(_Transport transport,
    {ChatRealtimeSessionTransport? session}) {
  final client = HandrailChatClient(
      apiBaseUri: Uri.parse('https://chat.test'),
      tokenProvider: () async => 'token',
      transport: transport,
      realtimeSession: session);
  client.normalizedState.hydrateConversationDetail(
      ConversationDetailSnapshot.fromJson(_detail()));
  return client;
}

int? _badge(HandrailChatClient client) =>
    client.normalizedState.conversation(_id).metadata?.unreadMentionCount;

Map<String, Object?> _detail({int count = 0, int sequence = 0}) => {
      'kind': 'conversation_detail',
      'conversation': {
        ...conversationListSummary(
            id: _id.value,
            name: 'Replies',
            visibility: 'private',
            latestSequence: sequence),
        'unreadMentionCount': count,
        'memberUserIds': [conversationListTestUser],
        'memberListRevision': 1,
      },
      '_meta': conversationListMetadata(),
    };

KnownDurableEvent _event(int sequence,
        {bool deleted = false,
        bool reply = true,
        String target = 'source-1'}) =>
    KnownDurableEvent.fromJson({
      'eventId': '${deleted ? 'deleted' : 'created'}-$sequence',
      'protocolVersion': handrailChatDurableEventProtocolVersion,
      'tenantId': conversationListTestTenant,
      'streamId': _id.value,
      'type': deleted ? 'message.deleted' : 'message.created',
      'occurredAt': deleted ? '2026-08-26T23:01:00.000Z' : _time,
      'payload': {
        'message': {
          'id': 'message-$sequence',
          'tenantId': conversationListTestTenant,
          'conversationId': _id.value,
          'author': {'type': 'user', 'userId': 'bob'},
          'sequence': sequence,
          'createdAt': _time,
          'updatedAt': deleted ? '2026-08-26T23:01:00.000Z' : _time,
          'revision': {'revision': deleted ? 2 : 1},
          if (reply) 'replyTo': {'messageId': target, 'notifyAuthor': true},
          if (deleted) ...{
            'deletedAt': '2026-08-26T23:01:00.000Z',
            'deletedByUserId': 'bob',
            'content': null,
          },
          if (!deleted) 'content': {'format': 'plain', 'text': 'Friday'},
        },
        if (!deleted) 'clientMessageId': 'client-$sequence',
      },
    },
        trustedIdentity: const DurableEventTrustedIdentity(
            tenantId: TenantId(conversationListTestTenant),
            userId: UserId(conversationListTestUser)));

KnownDurableEvent _revoke() {
  final input = {
    'operation': 'mutate_conversation_membership',
    'intent': 'leave',
    'conversationId': _id.value,
    'expectedMemberListRevision': 1
  };
  return KnownDurableEvent.fromJson({
    'eventId': 'revoke',
    'protocolVersion': handrailChatDurableEventProtocolVersion,
    'tenantId': conversationListTestTenant,
    'streamId': 'user:$conversationListTestUser',
    'type': 'conversation.membership.updated',
    'occurredAt': '2026-08-26T23:02:00.000Z',
    'payload': {
      'input': {...input, 'idempotencyKey': 'revoke'},
      'result': {
        ...input,
        'reconciliationStatus': 'applied',
        'memberListRevision': 2,
        'memberUserId': conversationListTestUser,
        'members': [
          {
            'userId': conversationListTestUser,
            'role': 'member',
            'state': 'left',
            'joinedAt': _time,
            'updatedAt': '2026-08-26T23:02:00.000Z',
          }
        ],
      }
    },
  },
      trustedIdentity: const DurableEventTrustedIdentity(
          tenantId: TenantId(conversationListTestTenant),
          userId: UserId(conversationListTestUser)));
}

Map<String, Object?> _accepted(String user) => {
      'type': 'chat.session.accepted',
      'metadata': conversationListMetadata(),
      'tenantId': conversationListTestTenant,
      'actorStreamId': 'user:$user',
      'deviceId': 'device-1',
      'sessionId': 'session-1',
    };

HandrailChatHttpResponse _response(Object value) =>
    HandrailChatHttpResponse(statusCode: 200, body: jsonEncode(value));
Future<void> _pump() async {
  for (var i = 0; i < 20; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}

final class _Transport implements HandrailChatHttpTransport {
  _Transport(this.handler);
  final Future<HandrailChatHttpResponse> Function(HandrailChatHttpRequest)
      handler;
  final requests = <HandrailChatHttpRequest>[];
  @override
  Future<HandrailChatHttpResponse> send(HandrailChatHttpRequest request) {
    requests.add(request);
    return handler(request);
  }
}

final class _Socket implements ChatRealtimeSocket {
  final controller = StreamController<Object?>.broadcast(sync: true);
  @override
  Stream<Object?> get frames => controller.stream;
  void emit(Object value) => controller.add(jsonEncode(value));
  @override
  void send(String data) {}
  @override
  void close() {}
}
