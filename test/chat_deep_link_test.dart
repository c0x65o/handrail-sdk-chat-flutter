import 'dart:async';
import 'dart:convert';

import 'package:handrail_chat/flutter.dart';
import 'package:test/test.dart';

import 'fixtures/thread_creation_fixtures.dart';
import 'fixtures/existing_thread_opening_fixtures.dart';

void main() {
  group('ChatDeepLinkParser', () {
    final parser = ChatDeepLinkParser(
      approvedUriPrefixes: [Uri.parse('https://chat.example.test/app/chat/')],
    );

    test('parses every typed target and decodes identifiers exactly once', () {
      final conversation = parser.parse(
        'https://chat.example.test/app/chat/conversations/conversation-1',
      );
      expect(
        (conversation as ChatDeepLinkParseSuccess).target,
        isA<ChatConversationDeepLinkTarget>().having(
          (target) => target.conversationId,
          'conversationId',
          const ConversationId('conversation-1'),
        ),
      );

      final message = parser.parse(
        'https://chat.example.test/app/chat/conversations/'
        'conversation%2FA/messages/message%252F1',
      );
      final messageTarget = (message as ChatDeepLinkParseSuccess).target
          as ChatMessageDeepLinkTarget;
      expect(messageTarget.conversationId.value, 'conversation/A');
      expect(messageTarget.messageId.value, 'message%2F1');

      final thread = parser.parse(
        'https://chat.example.test/app/chat/conversations/'
        'conversation-parent/threads/message-root',
      );
      expect(
        (thread as ChatDeepLinkParseSuccess).target,
        isA<ChatThreadDeepLinkTarget>().having(
          (target) => target.rootMessageId,
          'rootMessageId',
          const MessageId('message-root'),
        ),
      );
    });

    test('matches scheme, host, effective port, and path boundaries', () {
      expect(
        parser.parse(
          'https://chat.example.test:443/app/chat/conversations/allowed',
        ),
        isA<ChatDeepLinkParseSuccess>(),
      );
      for (final location in [
        'http://chat.example.test/app/chat/conversations/no',
        'https://evil.example.test/app/chat/conversations/no',
        'https://chat.example.test:444/app/chat/conversations/no',
        'https://chat.example.test/app/chatty/conversations/no',
      ]) {
        expect(
          parser.parse(location),
          isA<ChatDeepLinkParseFailure>().having(
            (failure) => failure.reason,
            'reason',
            ChatDeepLinkMalformedReason.unapprovedOrigin,
          ),
          reason: location,
        );
      }
    });

    test('rejects user-info, query, fragment, malformed, and ambiguous paths',
        () {
      final cases = <(String, ChatDeepLinkMalformedReason)>[
        (
          'https://user@chat.example.test/app/chat/conversations/no',
          ChatDeepLinkMalformedReason.unexpectedUriData,
        ),
        (
          'https://chat.example.test/app/chat/conversations/no?from=push',
          ChatDeepLinkMalformedReason.unexpectedUriData,
        ),
        (
          'https://chat.example.test/app/chat/conversations/no#message',
          ChatDeepLinkMalformedReason.unexpectedUriData,
        ),
        (
          'https://chat.example.test/app/chat/conversations/%20bad',
          ChatDeepLinkMalformedReason.invalidIdentifier,
        ),
        (
          'https://chat.example.test/app/chat/conversations/id/',
          ChatDeepLinkMalformedReason.ambiguousPath,
        ),
        (
          'https://chat.example.test/app/chat/conversations/id/messages',
          ChatDeepLinkMalformedReason.ambiguousPath,
        ),
        (
          'https://chat.example.test/app/chat/conversations/id/messages/'
              'message/extra',
          ChatDeepLinkMalformedReason.ambiguousPath,
        ),
        ('https://[', ChatDeepLinkMalformedReason.invalidUri),
      ];
      for (final testCase in cases) {
        expect(
          parser.parse(testCase.$1),
          isA<ChatDeepLinkParseFailure>().having(
            (failure) => failure.reason,
            'reason',
            testCase.$2,
          ),
          reason: testCase.$1,
        );
      }
    });

    test('requires safe absolute approved prefixes', () {
      expect(
        () => ChatDeepLinkParser(approvedUriPrefixes: const []),
        throwsArgumentError,
      );
      expect(
        () => ChatDeepLinkParser(
          approvedUriPrefixes: [Uri.parse('/relative/chat')],
        ),
        throwsArgumentError,
      );
      expect(
        () => ChatDeepLinkParser(
          approvedUriPrefixes: [
            Uri.parse('https://chat.example.test/chat?unsafe=true'),
          ],
        ),
        throwsArgumentError,
      );
    });
  });

  group('ChatDeepLinkResolver', () {
    test(
        'canonical thread and message formats read deleted-root history without creation',
        () async {
      for (final route in [
        'threads/conversation-thread',
        'threads/conversation-thread/messages/message-reply',
        'conversations/conversation-thread',
        'conversations/conversation-thread/messages/message-reply',
      ]) {
        final transport = _FakeTransport(_existingSuccessHandler());
        final client = _client(transport);
        final opened = <ChatResolvedDeepLinkTarget>[];
        final result = await _resolver(client, opened.add)
            .resolve('https://chat.example.test/app/chat/$route');
        expect(result, isA<ChatDeepLinkResolutionSuccess>(), reason: route);
        expect(opened, hasLength(1));
        final state = opened.single.threadOpeningState!;
        expect(state.rootContextStatus, ChatThreadRootContextStatus.deleted);
        expect(state.rootMessage, isNull);
        expect(state.threadConversation.id,
            const ConversationId('conversation-thread'));
        expect(transport.requests.map((r) => r.method), everyElement('GET'));
        if (route.startsWith('conversations/') &&
            route.contains('/messages/')) {
          expect(opened.single, isA<ChatResolvedMessageDeepLinkTarget>());
        }
        await client.dispose();
      }
    });

    test(
        'deleted legacy root is unavailable unless a known thread is freshly authorized',
        () async {
      final transport = _FakeTransport(_existingSuccessHandler());
      final client = _client(transport);
      final opened = <ChatResolvedDeepLinkTarget>[];
      final resolver = _resolver(client, opened.add);
      const link =
          'https://chat.example.test/app/chat/conversations/conversation-parent/threads/message-root';
      expect(await resolver.resolve(link),
          isA<ChatDeepLinkResolutionUnavailable>());
      expect(opened, isEmpty);
      client.normalizedState.hydrateConversationDetail(
          ConversationDetailSnapshot.fromJson(existingThreadDetailFixture()));
      expect(
          await resolver.resolve(link), isA<ChatDeepLinkResolutionSuccess>());
      expect(opened.single, isA<ChatResolvedExistingThreadDeepLinkTarget>());
      expect(opened.single.threadOpeningState!.rootContextStatus,
          ChatThreadRootContextStatus.deleted);
      expect(transport.requests.map((r) => r.method), everyElement('GET'));
      await client.dispose();
    });

    test('canonical host callback failure releases its thread subscription',
        () async {
      final realtime = ChatRealtimeSessionTransport(
        endpoint: Uri.parse('https://chat.example.test/api/chat'),
        clientPackageVersion: '0.1.4',
        protocolVersion: 4,
        tokenProvider: () => 'socket-token',
        socketFactory: (_, __) =>
            throw StateError('No socket connection needed'),
      );
      final states = <ChatRealtimeConversationSubscriptionState>[];
      final subscription =
          realtime.conversationSubscriptionStates.listen(states.add);
      final client = _client(_FakeTransport(_existingSuccessHandler()),
          realtime: realtime);
      final result = await _resolver(
              client, (_) => throw StateError('host failure'))
          .resolve(
              'https://chat.example.test/app/chat/threads/conversation-thread');
      expect(
          result,
          isA<ChatDeepLinkResolutionUnavailable>().having((r) => r.reason,
              'reason', ChatDeepLinkUnavailableReason.hostDelegate));
      expect(
          states.whereType<ChatRealtimeConversationSubscriptionRemovedState>(),
          hasLength(1));
      await client.dispose();
      await subscription.cancel();
      await realtime.dispose();
    });

    test(
        'canonical reads deny access before host callback, including cached identity',
        () async {
      var denied = false;
      final transport = _FakeTransport((request) async {
        if (denied && request.uri.path.endsWith('/conversation-thread')) {
          return _response(403, {'error': 'denied'});
        }
        return _existingSuccessHandler()(request);
      });
      final client = _client(transport);
      var calls = 0;
      final resolver = _resolver(client, (_) => calls += 1);
      const link =
          'https://chat.example.test/app/chat/threads/conversation-thread';
      expect(
          await resolver.resolve(link), isA<ChatDeepLinkResolutionSuccess>());
      denied = true;
      expect(await resolver.resolve(link), isA<ChatDeepLinkResolutionDenied>());
      expect(calls, 1);
      expect(transport.requests.map((r) => r.method), everyElement('GET'));
      await client.dispose();
    });

    test('canonical formats keep origin and identifier validation before I/O',
        () async {
      final transport = _FakeTransport((_) => throw StateError('No I/O'));
      final client = _client(transport);
      final resolver = _resolver(client, (_) => fail('No host callback'));
      for (final link in [
        'https://evil.test/app/chat/threads/thread',
        'https://chat.example.test/app/chat/threads/%20bad',
        'https://chat.example.test/app/chat/threads/thread/messages/%00',
        'https://chat.example.test/app/chat/threads/thread/threads/root',
      ]) {
        expect(await resolver.resolve(link),
            isA<ChatDeepLinkResolutionMalformed>());
      }
      expect(transport.requests, isEmpty);
      await client.dispose();
    });

    test('resolves a conversation and invokes the host exactly once', () async {
      final transport = _FakeTransport(_successHandler());
      final client = _client(transport);
      final opened = <ChatResolvedDeepLinkTarget>[];
      final resolver = _resolver(client, opened.add);

      final result = await resolver.resolve(
        'https://chat.example.test/app/chat/conversations/conversation-parent',
      );

      expect(result, isA<ChatDeepLinkResolutionSuccess>());
      expect(opened, hasLength(1));
      expect(opened.single, isA<ChatResolvedConversationDeepLinkTarget>());
      expect(
        client.normalizedState.state.conversations,
        contains(const ConversationId('conversation-parent')),
      );
      await client.dispose();
    });

    test('hydrates and resolves a message through the public timeline query',
        () async {
      final transport = _FakeTransport(_successHandler());
      final client = _client(transport);
      final opened = <ChatResolvedDeepLinkTarget>[];
      final resolver = _resolver(client, opened.add);

      final result = await resolver.resolve(
        'https://chat.example.test/app/chat/conversations/'
        'conversation-parent/messages/message-root',
      );

      final success = result as ChatDeepLinkResolutionSuccess;
      final target = success.target as ChatResolvedMessageDeepLinkTarget;
      expect(target.message.id, const MessageId('message-root'));
      expect(opened, [same(target)]);
      expect(
        transport.requests
            .where((request) => request.uri.path.endsWith('/messages')),
        hasLength(1),
      );
      await client.dispose();
    });

    test('hydrates, opens, and releases a root-thread controller handle',
        () async {
      final transport = _FakeTransport(_successHandler());
      final client = _client(transport);
      final opened = <ChatResolvedDeepLinkTarget>[];
      final resolver = _resolver(client, opened.add);

      final result = await resolver.resolve(
        'https://chat.example.test/app/chat/conversations/'
        'conversation-parent/threads/message-root',
      );

      final success = result as ChatDeepLinkResolutionSuccess;
      final target = success.target as ChatResolvedThreadDeepLinkTarget;
      expect(target.rootMessage.id, const MessageId('message-root'));
      expect(target.threadConversation.id,
          const ConversationId('conversation-thread'));
      expect(opened, [same(target)]);
      expect(
        transport.requests.where((request) => request.method == 'POST'),
        hasLength(1),
      );
      expect(
        client.threads.forRoot(const MessageId('message-root')).state,
        isA<ChatThreadOpeningIdleState>(),
      );
      await client.dispose();
    });

    test('coalesces pending readiness and opens once per resolve call',
        () async {
      final metadata = Completer<HandrailChatHttpResponse>();
      final transport = _FakeTransport((request) {
        if (request.uri.path.endsWith('/_meta')) return metadata.future;
        return _successHandler()(request);
      });
      final client = _client(transport);
      final opened = <ChatResolvedDeepLinkTarget>[];
      final resolver = _resolver(client, opened.add);
      const link = 'https://chat.example.test/app/chat/conversations/'
          'conversation-parent';

      final first = resolver.resolve(link);
      final second = resolver.resolve(link);
      await _pumpUntil(() => transport.requests.isNotEmpty);
      expect(
        transport.requests
            .where((request) => request.uri.path.endsWith('/_meta')),
        hasLength(1),
      );
      expect(opened, isEmpty);

      metadata.complete(_response(200, _metadata()));
      expect(await first, isA<ChatDeepLinkResolutionSuccess>());
      expect(await second, isA<ChatDeepLinkResolutionSuccess>());
      expect(opened, hasLength(2));
      await client.dispose();
    });

    test('maps denied and not-found responses without invoking the host',
        () async {
      for (final testCase in <(int, Matcher)>[
        (403, isA<ChatDeepLinkResolutionDenied>()),
        (404, isA<ChatDeepLinkResolutionNotFound>()),
      ]) {
        final transport = _FakeTransport((request) async {
          if (request.uri.path.endsWith('/_meta')) {
            return _response(200, _metadata());
          }
          return const HandrailChatHttpResponse(
            statusCode: 0,
            body: '',
          ).copyWithStatus(testCase.$1);
        });
        final client = _client(transport);
        var delegateCalls = 0;
        final resolver = _resolver(client, (_) => delegateCalls += 1);

        final result = await resolver.resolve(
          'https://chat.example.test/app/chat/conversations/missing',
        );

        expect(result, testCase.$2);
        expect(delegateCalls, 0);
        await client.dispose();
      }
    });

    test('rejects invalid targets before readiness, auth, transport, or host',
        () async {
      var tokenCalls = 0;
      var delegateCalls = 0;
      final transport = _FakeTransport(
        (_) => throw StateError('transport must not be called'),
      );
      final client = HandrailChatClient(
        apiBaseUri: Uri.parse('https://api.example.test/chat'),
        tokenProvider: () async {
          tokenCalls += 1;
          return 'token';
        },
        transport: transport,
      );
      final resolver = _resolver(client, (_) => delegateCalls += 1);

      final parsedFailure = await resolver.resolve(
        'https://evil.example.test/app/chat/conversations/no',
      );
      final typedFailure = await resolver.resolveTarget(
        const ChatMessageDeepLinkTarget(
          conversationId: ConversationId('conversation-parent'),
          messageId: MessageId(' bad'),
        ),
      );

      expect(parsedFailure, isA<ChatDeepLinkResolutionMalformed>());
      expect(typedFailure, isA<ChatDeepLinkResolutionMalformed>());
      expect(tokenCalls, 0);
      expect(transport.requests, isEmpty);
      expect(delegateCalls, 0);
      await client.dispose();
    });

    test('maps malformed and transport failures with zero host calls',
        () async {
      final cases = <Future<HandrailChatHttpResponse> Function(
        HandrailChatHttpRequest request,
      )>[
        (request) async {
          if (request.uri.path.endsWith('/_meta')) {
            return _response(200, _metadata());
          }
          return const HandrailChatHttpResponse(statusCode: 200, body: '{}');
        },
        (request) async {
          if (request.uri.path.endsWith('/_meta')) {
            return _response(200, _metadata());
          }
          throw StateError('offline');
        },
      ];
      final matchers = <Matcher>[
        isA<ChatDeepLinkResolutionMalformed>(),
        isA<ChatDeepLinkResolutionUnavailable>(),
      ];
      for (var index = 0; index < cases.length; index += 1) {
        final client = _client(_FakeTransport(cases[index]));
        var delegateCalls = 0;
        final resolver = _resolver(client, (_) => delegateCalls += 1);

        final result = await resolver.resolve(
          'https://chat.example.test/app/chat/conversations/'
          'conversation-parent',
        );

        expect(result, matchers[index]);
        expect(delegateCalls, 0);
        await client.dispose();
      }
    });

    test('maps refresh-required, initialization error, and closed clients',
        () async {
      final readinessCases = <({
        Future<HandrailChatHttpResponse> Function(
            HandrailChatHttpRequest) handler,
        ChatDeepLinkUnavailableReason reason,
      })>[
        (
          handler: (_) async => _response(
                200,
                _metadata(
                  protocolVersion: 5,
                  minimumProtocolVersion: 5,
                  maximumProtocolVersion: 6,
                ),
              ),
          reason: ChatDeepLinkUnavailableReason.refreshRequired,
        ),
        (
          handler: (_) async =>
              const HandrailChatHttpResponse(statusCode: 503, body: ''),
          reason: ChatDeepLinkUnavailableReason.clientError,
        ),
      ];
      for (final testCase in readinessCases) {
        final client = _client(_FakeTransport(testCase.handler));
        var delegateCalls = 0;
        final result =
            await _resolver(client, (_) => delegateCalls += 1).resolve(
          'https://chat.example.test/app/chat/conversations/'
          'conversation-parent',
        );
        expect(
          result,
          isA<ChatDeepLinkResolutionUnavailable>().having(
            (failure) => failure.reason,
            'reason',
            testCase.reason,
          ),
        );
        expect(delegateCalls, 0);
        await client.dispose();
      }

      final closedTransport = _FakeTransport(_successHandler());
      final closedClient = _client(closedTransport);
      await closedClient.initialize();
      await closedClient.dispose();
      var delegateCalls = 0;
      final closed = await _resolver(
        closedClient,
        (_) => delegateCalls += 1,
      ).resolve(
        'https://chat.example.test/app/chat/conversations/'
        'conversation-parent',
      );
      expect(
        closed,
        isA<ChatDeepLinkResolutionUnavailable>().having(
          (failure) => failure.reason,
          'reason',
          ChatDeepLinkUnavailableReason.closed,
        ),
      );
      expect(delegateCalls, 0);
    });

    test('returns not found when an authorized message does not exist',
        () async {
      final transport = _FakeTransport(_successHandler(messages: const []));
      final client = _client(transport);
      var delegateCalls = 0;

      final result = await _resolver(client, (_) => delegateCalls += 1).resolve(
        'https://chat.example.test/app/chat/conversations/'
        'conversation-parent/messages/missing-message',
      );

      expect(result, isA<ChatDeepLinkResolutionNotFound>());
      expect(delegateCalls, 0);
      await client.dispose();
    });
  });
}

ChatDeepLinkResolver _resolver(
  HandrailChatClient client,
  ChatDeepLinkOpenDelegate openTarget,
) =>
    ChatDeepLinkResolver(
      client: client,
      approvedUriPrefixes: [Uri.parse('https://chat.example.test/app/chat')],
      openTarget: openTarget,
    );

HandrailChatClient _client(_FakeTransport transport,
        {ChatRealtimeSessionTransport? realtime}) =>
    HandrailChatClient(
      realtimeSession: realtime,
      apiBaseUri: Uri.parse('https://api.example.test/chat'),
      tokenProvider: () async => 'access-token',
      transport: transport,
      generateIdempotencyKey: () => 'deep-link-thread-key',
    );

typedef _Handler = Future<HandrailChatHttpResponse> Function(
  HandrailChatHttpRequest request,
);

final class _FakeTransport implements HandrailChatHttpTransport {
  _FakeTransport(this._handler);

  final _Handler _handler;
  final List<HandrailChatHttpRequest> requests = [];

  @override
  Future<HandrailChatHttpResponse> send(HandrailChatHttpRequest request) {
    requests.add(request);
    return _handler(request);
  }
}

_Handler _successHandler({
  List<Map<String, Object?>>? messages,
}) =>
    (request) async {
      if (request.uri.path.endsWith('/_meta')) {
        return _response(200, _metadata());
      }
      if (request.method == 'POST' && request.uri.path.endsWith('/thread')) {
        return _response(201, threadCreationResultFixture('created'));
      }
      if (request.uri.path.endsWith('/messages')) {
        return _response(
          200,
          _timeline(
            messages: messages ?? [_message('message-root')],
          ),
        );
      }
      if (request.uri.path.contains('/conversations/')) {
        return _response(200, _conversationDetail('conversation-parent'));
      }
      throw StateError('Unexpected request: ${request.method} ${request.uri}');
    };

HandrailChatHttpResponse _response(int statusCode, Object? body) =>
    HandrailChatHttpResponse(
      statusCode: statusCode,
      body: jsonEncode(body),
    );

Map<String, Object?> _metadata({
  int protocolVersion = 4,
  int minimumProtocolVersion = 3,
  int maximumProtocolVersion = 4,
}) =>
    {
      'packageVersion': '0.1.3',
      'protocolVersion': protocolVersion,
      'schemaVersion': 1,
      'enabledFeatures': {'conversation_snapshots': true},
      'supportedProtocolRange': {
        'minimumVersion': minimumProtocolVersion,
        'maximumVersion': maximumProtocolVersion,
      },
    };

Map<String, Object?> _conversationDetail(String conversationId) => {
      'kind': 'conversation_detail',
      'conversation': {
        'id': conversationId,
        'tenantId': 'tenant-from-session',
        'type': 'channel',
        'name': 'Deep-link fixture',
        'visibility': 'public',
        'createdAt': _now,
        'updatedAt': _now,
        'latestSequence': 1,
        'activityAt': _now,
        'unreadMentionCount': 0,
        'currentMember': {
          'tenantId': 'tenant-from-session',
          'conversationId': conversationId,
          'userId': 'user-current',
          'role': 'member',
          'state': 'active',
          'joinedAt': _now,
          'updatedAt': _now,
        },
        'currentReadState': {
          'conversationId': conversationId,
          'userId': 'user-current',
          'lastReadSequence': 0,
          'updatedAt': _now,
        },
        'memberUserIds': ['user-current'],
        'currentPreference': {
          'conversationId': conversationId,
          'userId': 'user-current',
          'notificationPreference': 'all',
          'isStarred': false,
          'mute': {'muted': false},
          'updatedAt': _now,
        },
        'activeMemberUserIds': ['user-current'],
      },
      '_meta': {
        ..._metadata(),
        'feature': {
          'name': 'conversation_snapshots',
          'version': 1,
        },
      },
    };

Map<String, Object?> _timeline({
  required List<Map<String, Object?>> messages,
}) =>
    {
      'conversationId': 'conversation-parent',
      'messages': messages,
      'pagination': {
        'older': {'available': false},
        'newer': {'available': false},
      },
      'replay': {
        'resumeFrom': {'eventId': 'event-deep-link'},
      },
    };

Map<String, Object?> _message(String messageId) => {
      'id': messageId,
      'tenantId': 'tenant-from-session',
      'conversationId': 'conversation-parent',
      'author': {'type': 'user', 'userId': 'user-current'},
      'sequence': 1,
      'createdAt': _now,
      'updatedAt': _now,
      'revision': {'revision': 1},
      'content': {'format': 'plain', 'text': 'Deep-link root'},
      'isThreadRoot': false,
      'reactions': <Object?>[],
      'attachmentMetadata': <Object?>[],
    };

Future<void> _pumpUntil(bool Function() predicate) async {
  for (var index = 0; index < 100 && !predicate(); index += 1) {
    await Future<void>.delayed(Duration.zero);
  }
  expect(predicate(), isTrue, reason: 'Asynchronous work did not start.');
}

const _now = '2026-08-26T16:00:00.000Z';

extension on HandrailChatHttpResponse {
  HandrailChatHttpResponse copyWithStatus(int statusCode) =>
      HandrailChatHttpResponse(statusCode: statusCode, body: body);
}

_Handler _existingSuccessHandler() => (request) async {
      if (request.uri.path.endsWith('/conversation-thread')) {
        return _response(200, existingThreadDetailFixture());
      }
      if (request.uri.path.endsWith('/messages')) {
        return _response(
            200,
            existingThreadTimelineFixture(
                parent: request.uri.path
                    .endsWith('/conversation-parent/messages')));
      }
      return _successHandler()(request);
    };
