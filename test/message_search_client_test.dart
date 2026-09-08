import 'dart:async';
import 'dart:convert';

import 'package:handrail_chat/testing.dart';
import 'package:test/test.dart';

import 'fixtures/message_search_fixtures.dart';

void main() {
  group('HandrailChatClient.searchMessages request transport', () {
    test('posts authorized normalized generated fields and an opaque cursor',
        () async {
      const token = 'search-token';
      const cursor = 'opaque/+ page token ==';
      final transport = ScriptedHandrailChatHttpTransport()
        ..enqueueJson(messageSearchResponseFixture);
      final client = _client(transport, token: token);

      final result = await client.searchMessages(
        HandrailMessageSearchRequest(
          query: '  Cafe\u0301\t order\n updates  ',
          filters: HandrailMessageSearchFilter(
            conversationIds: const [
              ConversationId('conversation-1'),
              ConversationId('conversation-2'),
            ],
            authorUserIds: const [UserId('user-1')],
            sentAfter: const IsoTimestamp('2026-08-01T10:00:00.000Z'),
            sentBefore: const IsoTimestamp('2026-08-28T10:00:00-05:00'),
          ),
          pageSize: 50,
          pageToken: cursor,
        ),
      );

      expect(
          result, isA<ChatSnapshotQuerySuccess<HandrailMessageSearchPage>>());
      final request = transport.requests.single;
      expect(request.method, 'POST');
      expect(
        request.uri.toString(),
        'https://chat.example.test/api/chat/messages/search',
      );
      expect(request.headers, <String, String>{
        'Accept': 'application/json',
        'Authorization': 'Bearer $token',
        'Content-Type': 'application/json',
      });
      expect(jsonDecode(request.body!), <String, Object?>{
        ...normalizedMessageSearchRequestFixture,
        'cursor': cursor,
      });
      expect(request.cancellationSignal, isA<ChatCommandCancellationSignal>());
      await client.dispose();
    });

    test('omits absent filters and cursor and enforces generated validation',
        () async {
      var tokenCalls = 0;
      final transport = ScriptedHandrailChatHttpTransport()
        ..enqueueJson(const {'hits': <Object?>[]});
      final client = _client(
        transport,
        tokenProvider: () async {
          tokenCalls += 1;
          return 'token';
        },
      );

      final valid = await client.searchMessages(
        HandrailMessageSearchRequest(
          query: 'roadmap',
          filters: HandrailMessageSearchFilter.empty,
          pageSize: 1,
        ),
      );
      expect(valid, isA<ChatSnapshotQuerySuccess<HandrailMessageSearchPage>>());
      expect(jsonDecode(transport.requests.single.body!), <String, Object?>{
        'query': 'roadmap',
        'pageSize': 1,
      });

      for (final invalid in <HandrailMessageSearchRequest>[
        HandrailMessageSearchRequest(
          query: 'roadmap',
          filters: HandrailMessageSearchFilter.empty,
          pageSize: 101,
        ),
        HandrailMessageSearchRequest(
          query: 'roadmap',
          filters: HandrailMessageSearchFilter(
            conversationIds: const [
              ConversationId('duplicate'),
              ConversationId('duplicate'),
            ],
          ),
          pageSize: 10,
        ),
        HandrailMessageSearchRequest(
          query: 'roadmap',
          filters: HandrailMessageSearchFilter(
            sentAfter: const IsoTimestamp('2026-08-02T00:00:00Z'),
            sentBefore: const IsoTimestamp('2026-08-01T00:00:00Z'),
          ),
          pageSize: 10,
        ),
      ]) {
        final result = await client.searchMessages(invalid);
        expect(
          result,
          isA<ChatSnapshotQueryValidationFailure<HandrailMessageSearchPage>>(),
        );
      }
      expect(tokenCalls, 1);
      expect(transport.requests, hasLength(1));
      await client.dispose();
    });
  });

  group('HandrailChatClient.searchMessages response adaptation', () {
    test(
        'adapts both hit variants, optional titles, immutable pages, and state',
        () async {
      const snippetSentinel = 'SEARCH_SNIPPET_MUST_STAY_TRANSIENT';
      final response = <String, Object?>{
        'hits': const [
          {
            'type': 'conversation',
            'conversationId': 'conversation-1',
            'snippet': snippetSentinel,
          },
          {
            'type': 'message',
            'conversationId': 'conversation-2',
            'messageId': 'message-1',
            'snippet': 'Message excerpt',
            'authorUserId': 'user-1',
            'authorDisplayName': 'Ada',
            'sentAt': '2026-08-20T12:30:00.000Z',
          },
        ],
        'nextCursor': 'opaque.next',
      };
      final transport = ScriptedHandrailChatHttpTransport()
        ..enqueueJson(response);
      final client = _client(transport);
      final normalizedBefore = client.normalizedState.state;

      final result = await client.searchMessages(_request());
      final page =
          (result as ChatSnapshotQuerySuccess<HandrailMessageSearchPage>).value;

      expect(page.nextPageToken, 'opaque.next');
      expect(page.hits, hasLength(2));
      final conversation =
          page.hits.first as HandrailMessageSearchConversationHit;
      expect(conversation.title, 'Conversation');
      expect(conversation.snippet, snippetSentinel);
      final message = page.hits.last as HandrailMessageSearchMessageHit;
      expect(message.title, 'Ada');
      expect(message.messageId, const MessageId('message-1'));
      expect(message.authorUserId, const UserId('user-1'));
      expect(message.authorDisplayName, 'Ada');
      expect(message.sentAt, const IsoTimestamp('2026-08-20T12:30:00.000Z'));
      expect(() => page.hits.clear(), throwsUnsupportedError);
      expect(client.normalizedState.state, same(normalizedBefore));
      expect(client.normalizedState.state.canonicalMessages, isEmpty);
      expect(client.normalizedState.state.messages, isEmpty);
      expect(client.normalizedState.state.conversations, isEmpty);
      await client.dispose();
    });

    test('applies both UI hit-type filters without serializing them', () async {
      for (final entry in <(HandrailMessageSearchFilter, Type)>[
        (
          HandrailMessageSearchFilter(includeMessageHits: false),
          HandrailMessageSearchConversationHit,
        ),
        (
          HandrailMessageSearchFilter(includeConversationHits: false),
          HandrailMessageSearchMessageHit,
        ),
      ]) {
        final transport = ScriptedHandrailChatHttpTransport()
          ..enqueueJson(messageSearchResponseFixture);
        final client = _client(transport);
        final result = await client.searchMessages(
          HandrailMessageSearchRequest(
            query: 'café',
            filters: entry.$1,
            pageSize: 10,
          ),
        );
        final page =
            (result as ChatSnapshotQuerySuccess<HandrailMessageSearchPage>)
                .value;
        expect(page.hits, hasLength(1));
        expect(page.hits.single.runtimeType, entry.$2);
        expect(jsonDecode(transport.requests.single.body!), <String, Object?>{
          'query': 'café',
          'pageSize': 10,
        });
        await client.dispose();
      }
    });
  });

  group('HandrailChatClient.searchMessages stable outcomes', () {
    test('maps malformed JSON and malformed generated contracts', () async {
      for (final response in <HandrailChatHttpResponse>[
        const HandrailChatHttpResponse(statusCode: 200, body: '{bad-json'),
        HandrailChatHttpResponse(
          statusCode: 200,
          body: jsonEncode(const {
            'hits': [
              {
                'type': 'message',
                'conversationId': 'conversation-1',
                'snippet': 'missing message id',
              },
            ],
          }),
        ),
      ]) {
        final transport = ScriptedHandrailChatHttpTransport()
          ..enqueueResponse(response);
        final client = _client(transport);
        final result = await client.searchMessages(_request());
        expect(
          result,
          isA<ChatSnapshotQueryMalformedResponse<HandrailMessageSearchPage>>(),
        );
        expect((result as ChatSnapshotQueryFailure).httpStatus, 200);
        await client.dispose();
      }
    });

    test('maps token, auth refresh, HTTP rejection, and transport failures',
        () async {
      final tokenTransport = ScriptedHandrailChatHttpTransport();
      final tokenClient = _client(
        tokenTransport,
        tokenProvider: () async => throw StateError('token unavailable'),
      );
      expect(
        await tokenClient.searchMessages(_request()),
        isA<
            ChatSnapshotQueryAuthenticationFailure<
                HandrailMessageSearchPage>>(),
      );
      expect(tokenTransport.requests, isEmpty);
      await tokenClient.dispose();

      final unauthorizedTransport = ScriptedHandrailChatHttpTransport()
        ..enqueueJson(const {'error': 'expired'}, statusCode: 401)
        ..enqueueJson(const {'error': 'expired'}, statusCode: 401);
      var tokenCalls = 0;
      final unauthorizedClient = _client(
        unauthorizedTransport,
        tokenProvider: () async => 'token-${++tokenCalls}',
      );
      final unauthorized = await unauthorizedClient.searchMessages(_request());
      expect(
        unauthorized,
        isA<
            ChatSnapshotQueryAuthenticationFailure<
                HandrailMessageSearchPage>>(),
      );
      expect(tokenCalls, 2);
      expect(
        unauthorizedTransport.requests
            .map((request) => request.headers['Authorization']),
        ['Bearer token-1', 'Bearer token-2'],
      );
      await unauthorizedClient.dispose();

      for (final entry in <(int, Matcher)>[
        (
          403,
          isA<
              ChatSnapshotQueryAuthenticationFailure<
                  HandrailMessageSearchPage>>(),
        ),
        (422, isA<ChatSnapshotQueryRejected<HandrailMessageSearchPage>>()),
        (
          503,
          isA<ChatSnapshotQueryTransportFailure<HandrailMessageSearchPage>>(),
        ),
      ]) {
        final transport = ScriptedHandrailChatHttpTransport()
          ..enqueueJson(const {'error': 'not inspected'}, statusCode: entry.$1);
        final client = _client(transport);
        final result = await client.searchMessages(_request());
        expect(result, entry.$2);
        expect((result as ChatSnapshotQueryFailure).httpStatus, entry.$1);
        await client.dispose();
      }

      final errorTransport = ScriptedHandrailChatHttpTransport()
        ..enqueueError(StateError('network failed'));
      final errorClient = _client(errorTransport);
      expect(
        await errorClient.searchMessages(_request()),
        isA<ChatSnapshotQueryTransportFailure<HandrailMessageSearchPage>>(),
      );
      await errorClient.dispose();
    });

    test('supports caller cancellation and deterministic client close',
        () async {
      final cancelledTransport = _ControlledTransport();
      final cancelledClient = _client(cancelledTransport);
      final cancellation = ChatCommandCancellationController();
      final cancelled = cancelledClient.searchMessages(
        _request(),
        options: ChatSnapshotQueryOptions(
          cancellationSignal: cancellation.signal,
        ),
      );
      await _waitForRequests(cancelledTransport, 1);
      cancellation.cancel();
      expect(
        await cancelled,
        isA<ChatSnapshotQueryAborted<HandrailMessageSearchPage>>(),
      );
      expect(
        (cancelledTransport.requests.single.cancellationSignal!
                as ChatCommandCancellationSignal)
            .isCancelled,
        isTrue,
      );
      await cancelledClient.dispose();

      final closedTransport = _ControlledTransport();
      final closedClient = _client(closedTransport);
      final active = closedClient.searchMessages(_request());
      await _waitForRequests(closedTransport, 1);
      await closedClient.dispose();
      expect(active, completion(isA<ChatSnapshotQueryClosed>()));
      expect(
        await closedClient.searchMessages(_request()),
        isA<ChatSnapshotQueryClosed>(),
      );
      expect(closedTransport.requests, hasLength(1));
    });
  });

  group('ChatMessageSearchController', () {
    test('cancels and suppresses superseded searches', () async {
      final transport = _ControlledTransport();
      final client = _client(transport);
      final controller = ChatMessageSearchController(client: client);

      final old = controller.search(_request(query: 'old'));
      await _waitForRequests(transport, 1);
      final oldSignal = transport.requests.first.cancellationSignal!
          as ChatCommandCancellationSignal;
      final current = controller.search(_request(query: 'current'));
      await _waitForRequests(transport, 2);
      expect(oldSignal.isCancelled, isTrue);
      transport.completeAt(1, const {
        'hits': [
          {
            'type': 'message',
            'conversationId': 'conversation-current',
            'messageId': 'message-current',
            'title': 'Current result',
            'snippet': 'Current snippet',
          },
        ],
      });

      final currentState = await current;
      expect(currentState.status, ChatMessageSearchStatus.ready);
      expect(currentState.hits.single.title, 'Current result');
      await old;
      expect(controller.state.hits.single.title, 'Current result');

      transport.completeAt(0, const {
        'hits': [
          {
            'type': 'message',
            'conversationId': 'conversation-old',
            'messageId': 'message-old',
            'title': 'Stale result',
            'snippet': 'Stale snippet',
          },
        ],
      });
      await Future<void>.delayed(Duration.zero);
      expect(controller.state.hits.single.title, 'Current result');
      await controller.dispose();
      await client.dispose();
    });

    test('disposal cancels active work and settles disposed state', () async {
      final transport = _ControlledTransport();
      final client = _client(transport);
      final controller = ChatMessageSearchController(client: client);
      final statuses = <ChatMessageSearchStatus>[];
      final subscription = controller.states.listen(
        (state) => statuses.add(state.status),
      );

      final search = controller.search(_request());
      await _waitForRequests(transport, 1);
      final signal = transport.requests.single.cancellationSignal!
          as ChatCommandCancellationSignal;
      await controller.dispose();

      expect(signal.isCancelled, isTrue);
      expect(controller.state.status, ChatMessageSearchStatus.disposed);
      expect((await search).status, ChatMessageSearchStatus.disposed);
      expect(statuses.last, ChatMessageSearchStatus.disposed);
      await subscription.cancel();
      await client.dispose();
    });
  });
}

HandrailMessageSearchRequest _request({String query = 'roadmap'}) =>
    HandrailMessageSearchRequest(
      query: query,
      filters: HandrailMessageSearchFilter.empty,
      pageSize: 20,
    );

HandrailChatClient _client(
  HandrailChatHttpTransport transport, {
  String token = 'search-token',
  HandrailChatAccessTokenProvider? tokenProvider,
}) =>
    HandrailChatClient(
      apiBaseUri: Uri.parse(
        'https://chat.example.test/api/chat/?ignored=true#fragment',
      ),
      tokenProvider: tokenProvider ?? () async => token,
      transport: transport,
    );

final class _ControlledTransport implements HandrailChatHttpTransport {
  final List<HandrailChatHttpRequest> requests = [];
  final List<Completer<HandrailChatHttpResponse>> _responses = [];

  @override
  Future<HandrailChatHttpResponse> send(HandrailChatHttpRequest request) {
    requests.add(request);
    final response = Completer<HandrailChatHttpResponse>();
    _responses.add(response);
    return response.future;
  }

  void completeAt(int index, Object? body, {int statusCode = 200}) {
    _responses[index].complete(
      HandrailChatHttpResponse(
        statusCode: statusCode,
        body: jsonEncode(body),
      ),
    );
  }
}

Future<void> _waitForRequests(_ControlledTransport transport, int count) async {
  for (var attempt = 0;
      attempt < 100 && transport.requests.length < count;
      attempt += 1) {
    await Future<void>.delayed(Duration.zero);
  }
  expect(transport.requests, hasLength(count));
}
