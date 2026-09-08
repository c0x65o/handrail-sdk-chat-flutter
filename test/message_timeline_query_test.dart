import 'dart:async';
import 'dart:convert';

import 'package:handrail_chat/core.dart';
import 'package:test/test.dart';

const _now = '2026-08-26T15:00:00.000Z';

void main() {
  group('message timeline request construction', () {
    test('encodes a backward page without a cursor and parses enrichment',
        () async {
      const conversationId = 'conversation/A B?#%';
      const accessToken = 'timeline-token';
      final transport = _FakeHttpTransport(
        (_) async => _response(
          200,
          _timelineFixture(
            conversationId,
            messages: [_messageFixture(conversationId, 4, enrichedRoot: true)],
            older: 4,
          ),
        ),
      );
      final client = _client(
        transport: transport,
        tokenProvider: () async => accessToken,
      );

      final result = await client.getMessageTimeline(
        const MessageTimelineRequest(
          conversationId: ConversationId(conversationId),
          direction: MessageTimelineDirection.backward,
          limit: 25,
        ),
      );

      expect(result, isA<ChatSnapshotQuerySuccess<MessageTimelinePage>>());
      final request = transport.requests.single;
      expect(request.method, 'GET');
      expect(
        request.uri.toString(),
        'https://chat.example.test/api/chat/conversations/'
        'conversation%2FA%20B%3F%23%25/messages?limit=25',
      );
      expect(request.uri.queryParameters, const {'limit': '25'});
      expect(request.headers, const <String, String>{
        'Accept': 'application/json',
        'Authorization': 'Bearer $accessToken',
      });
      expect(request.cancellationSignal, isA<ChatCommandCancellationSignal>());

      final page =
          (result as ChatSnapshotQuerySuccess<MessageTimelinePage>).value;
      final message = page.messages.single;
      expect(page.conversationId, const ConversationId(conversationId));
      expect(message.isThreadRoot, isTrue);
      expect(message.reactions.single.reactionKey, 'thumbsup');
      expect(message.attachmentMetadata.single.fileName, 'status.png');
      expect(page.replay.resumeFrom.eventId, 'event-snapshot-42');
      expect(() => page.messages.add(message), throwsUnsupportedError);
      await client.dispose();
    });

    test('encodes a backward cursor as before followed by limit', () async {
      final transport = _FakeHttpTransport(
        (_) async => _response(200, _timelineFixture('conversation-1')),
      );
      final client = _client(transport: transport);

      final result = await client.getMessageTimeline(
        const MessageTimelineRequest(
          conversationId: ConversationId('conversation-1'),
          direction: MessageTimelineDirection.backward,
          cursor: MessageSequence(42),
          limit: 10,
        ),
      );

      expect(result, isA<ChatSnapshotQuerySuccess<MessageTimelinePage>>());
      expect(
        transport.requests.single.uri.toString(),
        'https://chat.example.test/api/chat/conversations/'
        'conversation-1/messages?before=42&limit=10',
      );
      expect(transport.requests.single.uri.queryParameters, const {
        'before': '42',
        'limit': '10',
      });
      await client.dispose();
    });

    test('encodes forward pages as after cursor or after zero', () async {
      for (final expectation in <(MessageSequence?, String)>[
        (null, 'after=0&limit=15'),
        (const MessageSequence(42), 'after=42&limit=15'),
      ]) {
        final transport = _FakeHttpTransport(
          (_) async => _response(200, _timelineFixture('conversation-1')),
        );
        final client = _client(transport: transport);

        final result = await client.getMessageTimeline(
          MessageTimelineRequest(
            conversationId: const ConversationId('conversation-1'),
            direction: MessageTimelineDirection.forward,
            cursor: expectation.$1,
            limit: 15,
          ),
        );

        expect(result, isA<ChatSnapshotQuerySuccess<MessageTimelinePage>>());
        expect(
          transport.requests.single.uri.toString(),
          'https://chat.example.test/api/chat/conversations/'
          'conversation-1/messages?${expectation.$2}',
        );
        expect(
          transport.requests.single.uri.queryParameters.keys,
          orderedEquals(const ['after', 'limit']),
        );
        await client.dispose();
      }
    });
  });

  group('message timeline outcomes', () {
    test('validates generated requests before authentication', () async {
      var tokenCalls = 0;
      final diagnostics = <ChatSnapshotQueryDiagnostic>[];
      final client = _client(
        transport: _FakeHttpTransport(
          (_) async => throw StateError('transport must not run'),
        ),
        tokenProvider: () async {
          tokenCalls += 1;
          return 'token';
        },
        onDiagnostic: diagnostics.add,
      );

      final result = await client.getMessageTimeline(
        const MessageTimelineRequest(
          conversationId: ConversationId(''),
          direction: MessageTimelineDirection.backward,
          cursor: MessageSequence(-1),
          limit: 101,
        ),
      );

      expect(result,
          isA<ChatSnapshotQueryValidationFailure<MessageTimelinePage>>());
      expect(tokenCalls, 0);
      expect(diagnostics.single.query, ChatSnapshotQueryName.messageTimeline);
      expect(
        diagnostics.single.event,
        ChatSnapshotQueryDiagnosticEvent.validationFailed,
      );
      await client.dispose();
    });

    test('cancels before authentication and while transport is pending',
        () async {
      final alreadyCancelled = ChatCommandCancellationController()..cancel();
      var tokenCalls = 0;
      final beforeClient = _client(
        transport: _FakeHttpTransport(
          (_) async => throw StateError('transport must not run'),
        ),
        tokenProvider: () async {
          tokenCalls += 1;
          return 'token';
        },
      );
      final before = await beforeClient.getMessageTimeline(
        _request(),
        options: ChatSnapshotQueryOptions(
          cancellationSignal: alreadyCancelled.signal,
        ),
      );
      expect(before, isA<ChatSnapshotQueryAborted<MessageTimelinePage>>());
      expect(tokenCalls, 0);
      await beforeClient.dispose();

      final response = Completer<HandrailChatHttpResponse>();
      final duringCancellation = ChatCommandCancellationController();
      final transport = _FakeHttpTransport((_) => response.future);
      final duringClient = _client(transport: transport);
      final during = duringClient.getMessageTimeline(
        _request(),
        options: ChatSnapshotQueryOptions(
          cancellationSignal: duringCancellation.signal,
        ),
      );
      await _pumpUntil(() => transport.requests.isNotEmpty);
      duringCancellation.cancel();
      expect(
          await during, isA<ChatSnapshotQueryAborted<MessageTimelinePage>>());
      await duringClient.dispose();
    });

    test('refreshes once on 401 and classifies non-success responses',
        () async {
      var tokenCalls = 0;
      final unauthorizedTransport = _FakeHttpTransport(
        (_) async => const HandrailChatHttpResponse(
          statusCode: 401,
          body: 'not inspected',
        ),
      );
      final unauthorizedClient = _client(
        transport: unauthorizedTransport,
        tokenProvider: () async => 'token-${++tokenCalls}',
      );
      final unauthorized =
          await unauthorizedClient.getMessageTimeline(_request());
      expect(
        unauthorized,
        isA<ChatSnapshotQueryAuthenticationFailure<MessageTimelinePage>>(),
      );
      expect(tokenCalls, 2);
      expect(
        unauthorizedTransport.requests
            .map((request) => request.headers['Authorization']),
        const ['Bearer token-1', 'Bearer token-2'],
      );
      await unauthorizedClient.dispose();

      for (final expectation in <(int, Matcher)>[
        (422, isA<ChatSnapshotQueryRejected<MessageTimelinePage>>()),
        (503, isA<ChatSnapshotQueryTransportFailure<MessageTimelinePage>>()),
      ]) {
        final client = _client(
          transport: _FakeHttpTransport(
            (_) async => HandrailChatHttpResponse(
              statusCode: expectation.$1,
              body: 'not inspected',
            ),
          ),
        );
        final result = await client.getMessageTimeline(_request());
        expect(result, expectation.$2);
        expect((result as ChatSnapshotQueryFailure).httpStatus, expectation.$1);
        await client.dispose();
      }
    });

    test('rejects malformed JSON and invalid timeline contracts', () async {
      final responses = <HandrailChatHttpResponse>[
        const HandrailChatHttpResponse(statusCode: 200, body: '{bad-json'),
        _response(
            200, const <String, Object?>{'conversationId': 'conversation-1'}),
        _response(
          200,
          {
            ..._timelineFixture('conversation-1'),
            'conversationId': 'conversation-2',
          },
        ),
        _response(
          200,
          _timelineFixture(
            'conversation-1',
            messages: [_messageFixture('conversation-2', 4)],
          ),
        ),
      ];

      for (final response in responses) {
        final client = _client(
          transport: _FakeHttpTransport((_) async => response),
        );
        final result = await client.getMessageTimeline(_request());
        expect(
          result,
          isA<ChatSnapshotQueryMalformedResponse<MessageTimelinePage>>(),
        );
        expect(
          (result as ChatSnapshotQueryMalformedResponse).httpStatus,
          200,
        );
        await client.dispose();
      }
    });

    test('dispose closes active and future timeline requests', () async {
      final response = Completer<HandrailChatHttpResponse>();
      final transport = _FakeHttpTransport((_) => response.future);
      final client = _client(transport: transport);
      final active = client.getMessageTimeline(_request());
      await _pumpUntil(() => transport.requests.isNotEmpty);

      await client.dispose();

      expect(active,
          completion(isA<ChatSnapshotQueryClosed<MessageTimelinePage>>()));
      final afterDispose = await client.getMessageTimeline(_request());
      expect(afterDispose, isA<ChatSnapshotQueryClosed<MessageTimelinePage>>());
      expect(transport.requests, hasLength(1));
    });
  });
}

MessageTimelineRequest _request() => const MessageTimelineRequest(
      conversationId: ConversationId('conversation-1'),
      direction: MessageTimelineDirection.backward,
      limit: 20,
    );

HandrailChatClient _client({
  required _FakeHttpTransport transport,
  HandrailChatAccessTokenProvider? tokenProvider,
  ChatSnapshotQueryDiagnosticCallback? onDiagnostic,
}) =>
    HandrailChatClient(
      apiBaseUri: Uri.parse(
        'https://chat.example.test/api/chat/?ignored=true#fragment',
      ),
      tokenProvider: tokenProvider ?? () async => 'query-token',
      transport: transport,
      onSnapshotQueryDiagnostic: onDiagnostic,
    );

final class _FakeHttpTransport implements HandrailChatHttpTransport {
  _FakeHttpTransport(this._send);

  final Future<HandrailChatHttpResponse> Function(
    HandrailChatHttpRequest request,
  ) _send;
  final List<HandrailChatHttpRequest> requests = <HandrailChatHttpRequest>[];

  @override
  Future<HandrailChatHttpResponse> send(HandrailChatHttpRequest request) {
    requests.add(request);
    return _send(request);
  }
}

HandrailChatHttpResponse _response(int status, Object? body) =>
    HandrailChatHttpResponse(statusCode: status, body: jsonEncode(body));

Map<String, Object?> _timelineFixture(
  String conversationId, {
  List<Map<String, Object?>> messages = const [],
  int? older,
  int? newer,
}) =>
    {
      'conversationId': conversationId,
      'messages': messages,
      'pagination': {
        'older': older == null
            ? {'available': false}
            : {'available': true, 'cursor': older},
        'newer': newer == null
            ? {'available': false}
            : {'available': true, 'cursor': newer},
      },
      'replay': {
        'resumeFrom': {'eventId': 'event-snapshot-42'},
      },
    };

Map<String, Object?> _messageFixture(
  String conversationId,
  int sequence, {
  bool enrichedRoot = false,
}) =>
    {
      'id': 'message-$sequence',
      'tenantId': 'tenant-1',
      'conversationId': conversationId,
      'author': {'type': 'user', 'userId': 'user-1'},
      'sequence': sequence,
      'createdAt': _now,
      'updatedAt': _now,
      'revision': {'revision': 1},
      'content': {
        'format': 'markdown',
        'text': 'message $sequence',
        if (enrichedRoot)
          'attachments': [
            {'attachmentId': 'attachment-1'},
          ],
      },
      'isThreadRoot': enrichedRoot,
      if (enrichedRoot)
        'threadSummary': {
          'threadId': 'thread-$sequence',
          'replyCount': 2,
          'participantIds': ['user-1', 'user-2'],
          'unreadCount': 1,
          'lastReplyAt': _now,
        },
      'reactions': enrichedRoot
          ? [
              {
                'reactionKey': 'thumbsup',
                'count': 2,
                'reactedByCurrentUser': true,
              },
            ]
          : <Object?>[],
      'attachmentMetadata': enrichedRoot
          ? [
              {
                'attachmentId': 'attachment-1',
                'fileName': 'status.png',
                'contentType': 'image/png',
                'sizeBytes': 2048,
                'downloadUrl': 'https://cdn.example.test/status.png',
                'previewUrl': 'https://cdn.example.test/status-preview.png',
                'width': 640,
                'height': 480,
                'altText': 'Current order status',
              },
            ]
          : <Object?>[],
    };

Future<void> _pump() => Future<void>.delayed(Duration.zero);

Future<void> _pumpUntil(bool Function() predicate) async {
  for (var index = 0; index < 100 && !predicate(); index += 1) {
    await _pump();
  }
  expect(predicate(), isTrue, reason: 'Asynchronous work did not start.');
}
