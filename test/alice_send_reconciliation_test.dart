import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:handrail_chat/testing.dart';

import 'fixtures/draft_mutation_fixtures.dart';

const _dm = ConversationId('a184c0ce-84d7-4cde-a610-4d3558e7ebe2');
const _input = ValueKey('handrail-message-composer-input');
const _send = ValueKey('handrail-message-composer-send');
const _text = 'QA 298e20b4 Alice Flutter acknowledgement';
const _time = '2026-09-07T18:02:11.417Z';

void main() {
  testWidgets(
      'Alice HTTP 201 renders without a realtime echo and releases composer',
      (tester) async {
    final transport = _CampaignTransport();
    final socket = FakeChatRealtimeSocket();
    final session = ChatRealtimeSessionTransport(
      endpoint: Uri.parse('https://chat.test/api/chat'),
      clientPackageVersion: '0.1.19',
      protocolVersion: 4,
      tokenProvider: () async => 'test-token',
      socketFactory: (_, __) => socket,
    );
    final client = transport.client(session: session);
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox());
      var closed = false;
      unawaited(client.dispose().then((_) => closed = true));
      for (var i = 0; i < 100 && !closed; i++) {
        await tester.pump(const Duration(milliseconds: 5));
        await tester.runAsync(() => Future<void>.delayed(Duration.zero));
      }
      expect(closed, isTrue);
      await tester.runAsync(session.dispose);
    });
    await tester.runAsync(() async {
      final started = session.start();
      await Future<void>.delayed(Duration.zero);
      socket.emitJson({
        'type': 'chat.session.accepted',
        'metadata': {
          'packageVersion': '0.1.19',
          'protocolVersion': 4,
          'schemaVersion': 1,
          'enabledFeatures': {},
          'supportedProtocolRange': {'minimumVersion': 3, 'maximumVersion': 4},
        },
        'tenantId': 'chat-lab',
        'actorStreamId': 'user:alice',
        'deviceId': 'campaign-device',
        'sessionId': 'campaign-session',
      });
      await started;
      await Future<void>.delayed(Duration.zero);
      await Future<void>.delayed(Duration.zero);
    });
    await tester.pump();
    expect(session.state, isA<ChatRealtimeConnectedState>());
    await tester.pumpWidget(MaterialApp(
      home: ChatScope(
        client: client,
        child: const Scaffold(
            body: Column(children: [
          Expanded(child: HandrailMessageTimeline(conversationId: _dm)),
          HandrailMessageComposer(conversationId: _dm),
        ])),
      ),
    ));
    await tester.pumpAndSettle();
    expect(client.normalizedState.timeline(_dm).messages, hasLength(3));
    await tester.enterText(find.byKey(_input), _text);
    await tester.pump();
    await tester.tap(find.byKey(_send));
    for (var i = 0; i < 100; i++) {
      await tester.pump(const Duration(milliseconds: 5));
      await tester.runAsync(() => Future<void>.delayed(Duration.zero));
    }
    expect(transport.sends, 1);
    expect(
        tester.widget<TextField>(find.byKey(_input)).controller!.text, isEmpty);
    expect(client.normalizedState.timeline(_dm).messages, hasLength(4));
    expect(find.text(_text), findsOneWidget);
    expect(session.state, isA<ChatRealtimeConnectedState>());
    await tester.enterText(find.byKey(_input), 'Next acknowledgement');
    await tester.pump();
    expect(tester.widget<IconButton>(find.byKey(_send)).onPressed, isNotNull);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });

  test('successful send does not wait for projection read; disposal ignores it',
      () async {
    final transport = _CampaignTransport()..pendingRead = Completer();
    final client = transport.client();
    client.normalizedState.hydrateConversationDetail(
        ConversationDetailSnapshot.fromJson(_detail));
    client.normalizedState.hydrateMessageTimeline(MessageTimelinePage.fromJson(
        transport.page(false),
        request: const MessageTimelineRequest(
            conversationId: _dm,
            direction: MessageTimelineDirection.backward,
            limit: 50)));
    final result = await client.sendMessage(ChatSendMessageInput(
        conversationId: _dm,
        content:
            MessageContent(format: MessageContentFormat.plain, text: _text)));
    expect(result, isA<ChatCommandSuccess<SendMessageResult>>());
    await Future<void>.delayed(Duration.zero);
    expect(transport.projectionReads, 1);
    await client.dispose();
    transport.pendingRead!.complete(_response(200, transport.sentPage));
    await Future<void>.delayed(Duration.zero);
    expect(client.normalizedState.timeline(_dm).messages, hasLength(3));
  });

  for (final echoFirst in [false, true]) {
    test(
        'HTTP and realtime ordering preserves one row (echo first: $echoFirst)',
        () async {
      final transport = _CampaignTransport();
      final client = transport.client();
      addTearDown(client.dispose);
      client.normalizedState.hydrateConversationDetail(
          ConversationDetailSnapshot.fromJson(_detail));
      final event = KnownDurableEvent.fromJson({
        'eventId': 'alice-send-event',
        'protocolVersion': 4,
        'tenantId': 'chat-lab',
        'streamId': _dm.value,
        'type': 'message.created',
        'occurredAt': _time,
        'payload': {
          'message': transport.sendResult['message'],
          'clientMessageId': transport.sendResult['clientMessageId'],
        },
      },
          trustedIdentity: DurableEventTrustedIdentity(
              tenantId: const TenantId('chat-lab'),
              userId: const UserId('alice')));
      if (echoFirst) client.reduceDurableEvent(event);
      final result = await client.sendMessage(ChatSendMessageInput(
          conversationId: _dm,
          content:
              MessageContent(format: MessageContentFormat.plain, text: _text)));
      expect(result, isA<ChatCommandSuccess<SendMessageResult>>());
      await Future<void>.delayed(Duration.zero);
      if (!echoFirst) client.reduceDurableEvent(event);
      client.reduceDurableEvent(event);
      expect(client.normalizedState.timeline(_dm).messages.map((m) => m.id),
          [MessageId(transport.sendResultMessageId)]);
      expect(transport.projectionReads, echoFirst ? 0 : 1);
    });
  }
}

// Captured canonical campaign rows and the exact accepted HTTP send body.
// This fake represents only HTTP; it implements no persistence behavior.
final class _CampaignTransport implements HandrailChatHttpTransport {
  _CampaignTransport() {
    final evidence = jsonDecode(File(
            'docs/validation/flutter-alice-send/campaign/flutter-alice-dm-send.json')
        .readAsStringSync()) as Map<String, dynamic>;
    sendResult =
        Map<String, Object?>.from(evidence['request'][0]['body'] as Map);
    final canonical = jsonDecode(File(
            'docs/validation/flutter-alice-send/campaign/canonical-final.json')
        .readAsStringSync()) as Map<String, dynamic>;
    messages = (canonical['messages'] as List)
        .cast<Map<String, dynamic>>()
        .where((m) => m['conversation_id'] == _dm.value)
        .map((m) => <String, Object?>{
              'id': m['id'],
              'tenantId': 'chat-lab',
              'conversationId': _dm.value,
              'author': {'type': 'user', 'userId': m['author_user_id']},
              'sequence': int.parse(m['sequence'] as String),
              'createdAt': m['created_at'],
              'updatedAt': m['created_at'],
              'revision': {'revision': 1},
              'content': m['content'],
              if (m['reply_to_message_id'] != null)
                'replyTo': {
                  'messageId': m['reply_to_message_id'],
                  'notifyAuthor': m['reply_notify_author'],
                },
              'isThreadRoot': false,
              'reactions': [],
              'attachmentMetadata': [],
            })
        .toList();
  }

  late final Map<String, Object?> sendResult;
  late final List<Map<String, Object?>> messages;
  int sends = 0;
  int projectionReads = 0;
  Completer<HandrailChatHttpResponse>? pendingRead;

  String get sendResultMessageId =>
      (sendResult['message']! as Map)['id'] as String;

  HandrailChatClient client({ChatRealtimeSessionTransport? session}) =>
      HandrailChatClient(
        apiBaseUri: Uri.parse('https://chat.test/api/chat'),
        tokenProvider: () async => 'test-token',
        transport: this,
        realtimeSession: session,
        commandRetryOptions: const ChatCommandRetryOptions(maxAttempts: 1),
        generateClientMessageId: () => sendResult['clientMessageId']! as String,
      );

  Map<String, Object?> page(bool sent) => {
        'conversationId': _dm.value,
        'messages': messages.take(sent ? 4 : 3).toList(),
        'pagination': {
          'older': {'available': false},
          'newer': {'available': false}
        },
        'replay': {
          'resumeFrom': {'eventId': 'campaign-snapshot'}
        },
      };

  Map<String, Object?> get sentPage => {
        ...page(true),
        'messages': [messages.last],
        'pagination': {
          'older': {'available': true, 'cursor': 4},
          'newer': {'available': false},
        },
      };

  @override
  Future<HandrailChatHttpResponse> send(HandrailChatHttpRequest request) async {
    if (request.method == 'GET') {
      if (request.uri.path.endsWith('/messages')) {
        final after = request.uri.queryParameters['after'];
        if (after != null) {
          expect(request.uri.queryParameters, {'after': '3', 'limit': '1'});
          projectionReads++;
          if (pendingRead != null) return pendingRead!.future;
          return _response(200, sentPage);
        }
        return _response(200, page(sends > 0));
      }
      return _response(200, _detail);
    }
    final body = jsonDecode(request.body!) as Map<String, Object?>;
    if (body['operation'] == 'synchronize_draft') {
      return _response(200, settledDraftResultFixture(body));
    }
    if (body['operation'] == 'send') {
      sends++;
      expect((body['content'] as Map)['text'], _text);
      return _response(201, sendResult);
    }
    throw StateError('Unexpected HTTP operation');
  }
}

HandrailChatHttpResponse _response(int status, Object body) =>
    HandrailChatHttpResponse(statusCode: status, body: jsonEncode(body));

final _detail = <String, Object?>{
  'kind': 'conversation_detail',
  'conversation': {
    'id': _dm.value,
    'tenantId': 'chat-lab',
    'type': 'direct',
    'visibility': 'private',
    'createdAt': _time,
    'updatedAt': _time,
    'latestSequence': 3,
    'activityAt': _time,
    'unreadMentionCount': 0,
    'activeMemberUserIds': ['alice', 'bob'],
    'memberUserIds': ['alice', 'bob'],
    'currentMember': {
      'tenantId': 'chat-lab',
      'conversationId': _dm.value,
      'userId': 'alice',
      'role': 'member',
      'state': 'active',
      'joinedAt': _time,
      'updatedAt': _time,
    },
    'currentReadState': {
      'conversationId': _dm.value,
      'userId': 'alice',
      'lastReadSequence': 3,
      'updatedAt': _time,
    },
    'currentPreference': {
      'conversationId': _dm.value,
      'userId': 'alice',
      'notificationPreference': 'all',
      'isStarred': false,
      'mute': {'muted': false},
      'updatedAt': _time,
    },
  },
  '_meta': {
    'packageVersion': '0.1.19',
    'protocolVersion': 4,
    'schemaVersion': 9,
    'enabledFeatures': {conversationSnapshotFeature: true},
    'supportedProtocolRange': {'minimumVersion': 3, 'maximumVersion': 4},
    'feature': {
      'name': conversationSnapshotFeature,
      'version': conversationSnapshotVersion
    },
  },
};
