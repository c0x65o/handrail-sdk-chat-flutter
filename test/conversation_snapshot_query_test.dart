import 'dart:async';
import 'dart:convert';

import 'package:handrail_chat/core.dart';
import 'package:test/test.dart';

const _now = '2026-08-26T15:00:00.000Z';
const _tenantId = 'tenant-query';
const _userId = 'user-query';

void main() {
  group('conversation snapshot request construction', () {
    test('lists organization conversations with bearer authentication',
        () async {
      const accessToken = 'organization-token';
      final transport = _FakeHttpTransport(
        (_) async => _response(
          200,
          _listFixture(scope: const {'type': 'organization'}),
        ),
      );
      final client = _client(
        transport: transport,
        tokenProvider: () async => accessToken,
      );

      final result = await client.listConversations(
        const ConversationListSnapshotInput(
          scope: OrganizationConversationSnapshotScope(),
        ),
      );

      expect(result, isA<ChatSnapshotQuerySuccess<ConversationListSnapshot>>());
      expect(result.status, 'success');
      final request = transport.requests.single;
      expect(request.method, 'GET');
      expect(
        request.uri.toString(),
        'https://chat.example.test/api/chat/conversations?scope=organization',
      );
      expect(request.headers, <String, String>{
        'Accept': 'application/json',
        'Authorization': 'Bearer $accessToken',
      });
      expect(request.cancellationSignal, isA<ChatCommandCancellationSignal>());
      expect(() => request.headers['Other'] = 'value', throwsUnsupportedError);
      final snapshot =
          (result as ChatSnapshotQuerySuccess<ConversationListSnapshot>).value;
      expect(snapshot.scope, isA<OrganizationConversationSnapshotScope>());
      expect(() => snapshot.items.add(snapshot.items.single),
          throwsUnsupportedError);
      await client.dispose();
    });

    test('encodes entity scope, cursor, and limit deterministically', () async {
      const entityType = 'erp invoice/line';
      const entityId = 'A/B & C';
      final cursorValue = _cursor('conversation cursor/1');
      final cursor = ConversationSnapshotCursor.fromJson(cursorValue);
      final transport = _FakeHttpTransport(
        (_) async => _response(
          200,
          _listFixture(
            scope: const {
              'type': 'entity',
              'entity': {'type': entityType, 'id': entityId},
            },
          ),
        ),
      );
      final client = _client(transport: transport);

      final result = await client.listConversations(
        ConversationListSnapshotInput(
          scope: const EntityConversationSnapshotScope(
            entity: HostEntityReference(type: entityType, id: entityId),
          ),
          cursor: cursor,
          limit: 25,
        ),
      );

      expect(result, isA<ChatSnapshotQuerySuccess<ConversationListSnapshot>>());
      final uri = transport.requests.single.uri;
      expect(uri.path, '/api/chat/conversations');
      expect(uri.queryParameters, <String, String>{
        'scope': 'entity',
        'entityType': entityType,
        'entityId': entityId,
        'cursor': cursorValue,
        'limit': '25',
      });
      expect(
        uri.toString(),
        'https://chat.example.test/api/chat/conversations?scope=entity&'
        'entityType=erp+invoice%2Fline&entityId=A%2FB+%26+C&'
        'cursor=${Uri.encodeQueryComponent(cursorValue)}&limit=25',
      );
      await client.dispose();
    });

    test('encodes detail IDs and validates the returned conversation ID',
        () async {
      const conversationId = 'conversation/A B?#%';
      final matchingTransport = _FakeHttpTransport(
        (_) async => _response(200, _detailFixture(conversationId)),
      );
      final matchingClient = _client(transport: matchingTransport);

      final success = await matchingClient.getConversation(
        const ConversationDetailSnapshotInput(
          conversationId: ConversationId(conversationId),
        ),
      );

      expect(
        matchingTransport.requests.single.uri.toString(),
        'https://chat.example.test/api/chat/conversations/'
        'conversation%2FA%20B%3F%23%25',
      );
      expect(
        (success as ChatSnapshotQuerySuccess<ConversationDetailSnapshot>)
            .value
            .conversation
            .summary
            .conversation
            .id,
        const ConversationId(conversationId),
      );
      await matchingClient.dispose();

      final mismatchingClient = _client(
        transport: _FakeHttpTransport(
          (_) async => _response(200, _detailFixture('different-id')),
        ),
      );
      final mismatch = await mismatchingClient.getConversation(
        const ConversationDetailSnapshotInput(
          conversationId: ConversationId(conversationId),
        ),
      );
      expect(
        mismatch,
        isA<ChatSnapshotQueryMalformedResponse<ConversationDetailSnapshot>>(),
      );
      await mismatchingClient.dispose();
    });
  });

  group('conversation snapshot outcomes', () {
    test('validates generated inputs before authentication', () async {
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

      final list = await client.listConversations(
        const ConversationListSnapshotInput(
          scope: EntityConversationSnapshotScope(
            entity: HostEntityReference(type: '   ', id: 'entity'),
          ),
        ),
      );
      final detail = await client.getConversation(
        const ConversationDetailSnapshotInput(
          conversationId: ConversationId(''),
        ),
      );

      expect(list.status, 'validation');
      expect(detail.status, 'validation');
      expect(tokenCalls, 0);
      expect(
        diagnostics.map((value) => value.event),
        everyElement(ChatSnapshotQueryDiagnosticEvent.validationFailed),
      );
      await client.dispose();
    });

    test('cancels before token access and during token or transport work',
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
      final before = await beforeClient.listConversations(
        const ConversationListSnapshotInput(
          scope: OrganizationConversationSnapshotScope(),
        ),
        options: ChatSnapshotQueryOptions(
          cancellationSignal: alreadyCancelled.signal,
        ),
      );
      expect(before, isA<ChatSnapshotQueryAborted<ConversationListSnapshot>>());
      expect(tokenCalls, 0);
      await beforeClient.dispose();

      final token = Completer<String>();
      final duringTokenCancellation = ChatCommandCancellationController();
      final tokenClient = _client(
        transport: _FakeHttpTransport(
          (_) async => throw StateError('transport must not run'),
        ),
        tokenProvider: () => token.future,
      );
      final duringToken = tokenClient.listConversations(
        const ConversationListSnapshotInput(
          scope: OrganizationConversationSnapshotScope(),
        ),
        options: ChatSnapshotQueryOptions(
          cancellationSignal: duringTokenCancellation.signal,
        ),
      );
      await _pump();
      duringTokenCancellation.cancel();
      expect(await duringToken,
          isA<ChatSnapshotQueryAborted<ConversationListSnapshot>>());
      await tokenClient.dispose();

      final response = Completer<HandrailChatHttpResponse>();
      final duringRequestCancellation = ChatCommandCancellationController();
      final requestTransport = _FakeHttpTransport((_) => response.future);
      final requestClient = _client(transport: requestTransport);
      final duringRequest = requestClient.listConversations(
        const ConversationListSnapshotInput(
          scope: OrganizationConversationSnapshotScope(),
        ),
        options: ChatSnapshotQueryOptions(
          cancellationSignal: duringRequestCancellation.signal,
        ),
      );
      await _pumpUntil(() => requestTransport.requests.isNotEmpty);
      duringRequestCancellation.cancel();
      expect(await duringRequest,
          isA<ChatSnapshotQueryAborted<ConversationListSnapshot>>());
      await requestClient.dispose();
    });

    test('maps authentication, rejected, and server failures', () async {
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
      final unauthorized = await unauthorizedClient.listConversations(
        const ConversationListSnapshotInput(
          scope: OrganizationConversationSnapshotScope(),
        ),
      );
      expect(
        unauthorized,
        isA<ChatSnapshotQueryAuthenticationFailure<ConversationListSnapshot>>(),
      );
      expect(
        (unauthorized as ChatSnapshotQueryAuthenticationFailure).httpStatus,
        401,
      );
      expect(tokenCalls, 2);
      expect(unauthorizedTransport.requests, hasLength(2));
      expect(
        unauthorizedTransport.requests
            .map((request) => request.headers['Authorization']),
        <String>['Bearer token-1', 'Bearer token-2'],
      );
      await unauthorizedClient.dispose();

      for (final expectation in <(int, Matcher)>[
        (
          403,
          isA<
              ChatSnapshotQueryAuthenticationFailure<
                  ConversationListSnapshot>>(),
        ),
        (422, isA<ChatSnapshotQueryRejected<ConversationListSnapshot>>()),
        (
          503,
          isA<ChatSnapshotQueryTransportFailure<ConversationListSnapshot>>(),
        ),
      ]) {
        final client = _client(
          transport: _FakeHttpTransport(
            (_) async => HandrailChatHttpResponse(
              statusCode: expectation.$1,
              body: 'sensitive response body',
            ),
          ),
        );
        final result = await client.listConversations(
          const ConversationListSnapshotInput(
            scope: OrganizationConversationSnapshotScope(),
          ),
        );
        expect(result, expectation.$2);
        expect((result as ChatSnapshotQueryFailure).httpStatus, expectation.$1);
        await client.dispose();
      }
    });

    test('rejects malformed JSON, invalid contracts, and scope mismatches',
        () async {
      final responses = <HandrailChatHttpResponse>[
        const HandrailChatHttpResponse(statusCode: 200, body: '{bad-json'),
        _response(200, <String, Object?>{'kind': 'conversation_list'}),
        _response(
          200,
          _listFixture(
            scope: const {
              'type': 'entity',
              'entity': {'type': 'order', 'id': 'order-1'},
            },
          ),
        ),
      ];

      for (final response in responses) {
        final client = _client(
          transport: _FakeHttpTransport((_) async => response),
        );
        final result = await client.listConversations(
          const ConversationListSnapshotInput(
            scope: OrganizationConversationSnapshotScope(),
          ),
        );
        expect(
          result,
          isA<ChatSnapshotQueryMalformedResponse<ConversationListSnapshot>>(),
        );
        expect(
          (result as ChatSnapshotQueryMalformedResponse).httpStatus,
          200,
        );
        await client.dispose();
      }
    });

    test('dispose closes active and future queries', () async {
      final response = Completer<HandrailChatHttpResponse>();
      final transport = _FakeHttpTransport((_) => response.future);
      final client = _client(transport: transport);
      final active = client.listConversations(
        const ConversationListSnapshotInput(
          scope: OrganizationConversationSnapshotScope(),
        ),
      );
      await _pumpUntil(() => transport.requests.isNotEmpty);

      await client.dispose();

      expect(active, completion(isA<ChatSnapshotQueryClosed>()));
      final afterDispose = await client.listConversations(
        const ConversationListSnapshotInput(
          scope: OrganizationConversationSnapshotScope(),
        ),
      );
      expect(afterDispose, isA<ChatSnapshotQueryClosed>());
      expect(transport.requests, hasLength(1));
    });

    test('diagnostics and toString output are structurally redacted', () async {
      const token = 'SENTINEL_TOKEN';
      const conversationId = 'SENTINEL_URL_VALUE';
      const body = 'SENTINEL_RESPONSE_BODY';
      const thrown = 'SENTINEL_THROWN_TEXT';
      final diagnostics = <ChatSnapshotQueryDiagnostic>[];
      final transport = _FakeHttpTransport((_) async {
        throw StateError(thrown);
      });
      final client = _client(
        transport: transport,
        tokenProvider: () async => token,
        onDiagnostic: (diagnostic) {
          diagnostics.add(diagnostic);
          throw StateError('$thrown from observer');
        },
      );

      final result = await client.getConversation(
        const ConversationDetailSnapshotInput(
          conversationId: ConversationId(conversationId),
        ),
      );
      const response = HandrailChatHttpResponse(statusCode: 500, body: body);
      final output = <Object>[
        result,
        client,
        transport.requests.single,
        response,
        ...diagnostics,
      ].join('\n');

      expect(result,
          isA<ChatSnapshotQueryTransportFailure<ConversationDetailSnapshot>>());
      expect(diagnostics, isNotEmpty);
      for (final secret in <String>[token, conversationId, body, thrown]) {
        expect(output, isNot(contains(secret)));
      }
      await client.dispose();
    });
  });
}

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

Map<String, Object?> _listFixture({required Map<String, Object?> scope}) => {
      'kind': 'conversation_list',
      'scope': scope,
      'items': [_summaryFixture('conversation-list')],
      'page': <String, Object?>{},
      '_meta': _metadata(),
    };

Map<String, Object?> _detailFixture(String id) => {
      'kind': 'conversation_detail',
      'conversation': {
        ..._summaryFixture(id),
        'memberUserIds': [_userId, 'user-other'],
        'currentPreference': {
          'conversationId': id,
          'userId': _userId,
          'notificationPreference': 'mentions',
          'isStarred': false,
          'mute': {'muted': false},
          'updatedAt': _now,
        },
      },
      '_meta': _metadata(),
    };

Map<String, Object?> _summaryFixture(String id) => {
      'id': id,
      'tenantId': _tenantId,
      'type': 'channel',
      'name': 'Query fixture',
      'visibility': 'public',
      'createdAt': _now,
      'updatedAt': _now,
      'latestSequence': 12,
      'activityAt': _now,
      'unreadMentionCount': 0,
      'currentMember': {
        'tenantId': _tenantId,
        'conversationId': id,
        'userId': _userId,
        'role': 'member',
        'state': 'active',
        'joinedAt': _now,
        'updatedAt': _now,
      },
      'currentReadState': {
        'conversationId': id,
        'userId': _userId,
        'lastReadSequence': 11,
        'updatedAt': _now,
      },
      'currentPreference': {
        'conversationId': id,
        'userId': _userId,
        'notificationPreference': 'mentions',
        'isStarred': false,
        'mute': {'muted': false},
        'updatedAt': _now,
      },
      'activeMemberUserIds': [_userId],
    };

Map<String, Object?> _metadata() => {
      'packageVersion': '0.1.3',
      'protocolVersion': 4,
      'schemaVersion': 9,
      'enabledFeatures': {conversationSnapshotFeature: true},
      'supportedProtocolRange': {
        'minimumVersion': 3,
        'maximumVersion': 4,
      },
      'feature': {
        'name': conversationSnapshotFeature,
        'version': conversationSnapshotVersion,
      },
    };

String _cursor(String conversationId) =>
    'handrail-conversations.v1.${Uri.encodeComponent(jsonEncode([
          _now,
          conversationId,
        ]))}';

Future<void> _pump() => Future<void>.delayed(Duration.zero);

Future<void> _pumpUntil(bool Function() predicate) async {
  for (var index = 0; index < 100 && !predicate(); index += 1) {
    await _pump();
  }
  expect(predicate(), isTrue, reason: 'Asynchronous work did not start.');
}
