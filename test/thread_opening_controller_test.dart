import 'dart:async';
import 'dart:convert';

import 'package:handrail_chat/core.dart';
import 'package:test/test.dart';

import 'fixtures/thread_creation_fixtures.dart';
import 'fixtures/existing_thread_opening_fixtures.dart';

void main() {
  group('root-thread opening', () {
    test('named creation serializes generated input and keeps canonical names',
        () async {
      for (final status in ['created', 'existing_for_root', 'replayed']) {
        final store = NormalizedSnapshotStore();
        _seedRoot(store);
        final response = threadCreationResultFixture(status);
        ((response['conversation'] as Map<String, Object?>)['conversation']
            as Map<String, Object?>)['name'] = 'Canonical name';
        final transport = _FakeHttpTransport((_) async =>
            HandrailChatHttpResponse(
                statusCode: 200, body: jsonEncode(response)));
        final client = _client(transport, store: store);
        final opened = await client.createThread(
            rootMessageId: _rootId,
            name: 'Requested name',
            initialFollow: false) as ChatThreadOpenSuccess;
        final body =
            jsonDecode(transport.requests.single.body!) as Map<String, dynamic>;
        expect(body['name'], 'Requested name');
        expect(body['initialFollow'], false);
        expect(opened.handle.conversation.name, 'Canonical name');
        expect(
            (store.state.conversations[_threadId] as ThreadConversation).name,
            'Canonical name');
        opened.handle.release();
        await client.dispose();
        await store.close();
      }
    });

    test(
        'ambiguous named retry freezes name and key; create starts a new intent',
        () async {
      final store = NormalizedSnapshotStore();
      _seedRoot(store);
      var keys = 0;
      final transport = _FakeHttpTransport((_) async =>
          const HandrailChatHttpResponse(statusCode: 503, body: 'unavailable'));
      final client = _client(transport,
          store: store, generateKey: () => 'intent-${++keys}');
      final controller = client.threads.forRoot(_rootId);
      await controller.create(name: 'First');
      await controller.retry();
      expect(transport.requests[1].body, transport.requests[0].body);
      expect(keys, 1);
      await controller.create(name: 'Second');
      expect(keys, 2);
      expect(jsonDecode(transport.requests.last.body!)['name'], 'Second');
      expect(transport.requests.last.headers['Idempotency-Key'], 'intent-2');
      await client.dispose();
      await store.close();
    });

    test(
        'invalid named intent performs no write and concurrent creation coalesces',
        () async {
      final store = NormalizedSnapshotStore();
      _seedRoot(store);
      final response = Completer<HandrailChatHttpResponse>();
      final transport = _FakeHttpTransport((_) => response.future);
      final client = _client(transport, store: store);
      final invalid = await client.createThread(
          rootMessageId: _rootId, name: '   ') as ChatThreadOpenFailure;
      expect(invalid.error.code, ChatThreadOpeningErrorCode.validation);
      expect(transport.requests, isEmpty);
      final first = client.createThread(rootMessageId: _rootId, name: 'First');
      final second =
          client.createThread(rootMessageId: _rootId, name: 'Second');
      await Future<void>.delayed(Duration.zero);
      expect(transport.requests, hasLength(1));
      expect(jsonDecode(transport.requests.single.body!)['name'], 'First');
      response.complete(HandrailChatHttpResponse(
          statusCode: 200,
          body: jsonEncode(threadCreationResultFixture('created'))));
      (await first as ChatThreadOpenSuccess).handle.release();
      (await second as ChatThreadOpenSuccess).handle.release();
      await client.dispose();
      await store.close();
    });

    test(
        'unfollowed reader opens deleted-root history read-only and releases handles',
        () async {
      final store = NormalizedSnapshotStore();
      _seedRoot(
          store); // Stale live source must never become displayed context.
      final realtime = _realtime();
      final states = <ChatRealtimeConversationSubscriptionState>[];
      final subscription =
          realtime.conversationSubscriptionStates.listen(states.add);
      final transport = _FakeHttpTransport(_existingHandler());
      final client = _client(transport, store: store, realtime: realtime);
      final results = await Future.wait([
        client.openExistingThread(_threadId),
        client.openExistingThread(_threadId),
      ]);
      final handles = results
          .cast<ChatExistingThreadOpenSuccess>()
          .map((r) => r.handle)
          .toList();
      expect(transport.requests, hasLength(3));
      expect(transport.requests.map((r) => r.method), everyElement('GET'));
      expect(handles.first.conversation.name, 'Canonical discussion');
      expect(handles.first.rootMessageId, _rootId);
      expect(handles.first.state.parentConversationId,
          const ConversationId('conversation-parent'));
      expect(handles.first.state.rootContextStatus,
          ChatThreadRootContextStatus.deleted);
      expect(handles.first.state.rootMessage, isNull);
      expect(store.state.canonicalMessages[const MessageId('message-reply')],
          isNotNull);
      expect(store.state.memberUserIdsByConversation[_threadId], isEmpty);
      handles.first.release();
      handles.first.release();
      expect(
          states.whereType<ChatRealtimeConversationSubscriptionRemovedState>(),
          isEmpty);
      handles.last.release();
      expect(
          states.whereType<ChatRealtimeConversationSubscriptionRemovedState>(),
          hasLength(1));
      await client.dispose();
      await subscription.cancel();
      await realtime.dispose();
      await store.close();
    });

    test(
        'cached identity and a live handle cannot bypass current parent denial',
        () async {
      for (final deniedPath in [
        'conversation-thread',
        'conversation-thread/messages',
        'conversation-parent/messages'
      ]) {
        final store = NormalizedSnapshotStore();
        final realtime = _realtime();
        final states = <ChatRealtimeConversationSubscriptionState>[];
        final subscription =
            realtime.conversationSubscriptionStates.listen(states.add);
        var denied = false;
        final transport = _FakeHttpTransport((request) async {
          if (denied && request.uri.path.endsWith('/$deniedPath')) {
            return const HandrailChatHttpResponse(
                statusCode: 403, body: 'denied');
          }
          return _existingHandler()(request);
        });
        final client = _client(transport, store: store, realtime: realtime);
        final first = await client.openExistingThread(_threadId)
            as ChatExistingThreadOpenSuccess;
        denied = true;
        final result = await client.openExistingThread(_threadId)
            as ChatExistingThreadOpenFailure;
        expect(result.code, ChatThreadOpeningErrorCode.authentication);
        expect(result.httpStatus, 403);
        expect(
            states
                .whereType<ChatRealtimeConversationSubscriptionRemovedState>(),
            hasLength(1));
        expect(transport.requests.map((r) => r.method), everyElement('GET'));
        first.handle.release();
        await client.dispose();
        await subscription.cancel();
        await realtime.dispose();
        await store.close();
      }
    });

    test('existing opening rejects mismatched identity and cancels on disposal',
        () async {
      final store = NormalizedSnapshotStore();
      final wrong = existingThreadDetailFixture();
      final conversation = wrong['conversation'] as Map<String, Object?>;
      conversation['type'] = 'channel';
      conversation.remove('rootMessageId');
      conversation.remove('parentConversationId');
      final client = _client(
          _FakeHttpTransport((_) async => HandrailChatHttpResponse(
              statusCode: 200, body: jsonEncode(wrong))),
          store: store);
      final result = await client.openExistingThread(_threadId)
          as ChatExistingThreadOpenFailure;
      expect(result.code, ChatThreadOpeningErrorCode.malformedResponse);
      expect(store.state.conversations, isEmpty);
      await client.dispose();
      final pending = Completer<HandrailChatHttpResponse>();
      final active =
          _client(_FakeHttpTransport((_) => pending.future), store: store);
      final opening = active.openExistingThread(_threadId);
      await Future<void>.delayed(Duration.zero);
      await active.dispose();
      expect((await opening as ChatExistingThreadOpenFailure).code,
          ChatThreadOpeningErrorCode.closed);
      await store.close();
    });

    test(
        'existing reads reject a different thread ID before timeline or subscription',
        () async {
      final store = NormalizedSnapshotStore();
      final response = threadCreationResultFixture('existing_for_root',
          threadId: 'another-thread');
      final transport = _FakeHttpTransport((_) async =>
          HandrailChatHttpResponse(
              statusCode: 200, body: jsonEncode(response['conversation'])));
      final client = _client(transport, store: store);
      final result = await client.openExistingThread(_threadId)
          as ChatExistingThreadOpenFailure;
      expect(result.code, ChatThreadOpeningErrorCode.malformedResponse);
      expect(transport.requests, hasLength(1));
      expect(store.state.conversations, isEmpty);
      await client.dispose();
      await store.close();
    });

    test('fresh missing and live root context both preserve existing history',
        () async {
      for (final missing in [true, false]) {
        final store = NormalizedSnapshotStore();
        _seedRoot(store);
        final transport = _FakeHttpTransport((request) async {
          if (request.uri.path.endsWith('/conversation-parent/messages')) {
            return HandrailChatHttpResponse(
                statusCode: 200,
                body: jsonEncode(existingThreadTimelineFixture(
                    parent: true, deletedRoot: false, missingRoot: missing)));
          }
          return _existingHandler()(request);
        });
        final client = _client(transport, store: store);
        final result = await client.openExistingThread(_threadId)
            as ChatExistingThreadOpenSuccess;
        expect(
            result.handle.state.rootContextStatus,
            missing
                ? ChatThreadRootContextStatus.unavailable
                : ChatThreadRootContextStatus.available);
        expect(result.handle.state.rootMessage?.id, missing ? isNull : _rootId);
        expect(store.state.canonicalMessages[const MessageId('message-reply')],
            isNotNull);
        result.handle.release();
        await client.dispose();
        await store.close();
      }
    });

    test('invalid named call while ready preserves the live subscription',
        () async {
      final store = NormalizedSnapshotStore();
      _seedRoot(store);
      final realtime = _realtime();
      final states = <ChatRealtimeConversationSubscriptionState>[];
      final subscription =
          realtime.conversationSubscriptionStates.listen(states.add);
      final transport = _FakeHttpTransport((_) async =>
          HandrailChatHttpResponse(
              statusCode: 200,
              body: jsonEncode(threadCreationResultFixture('created'))));
      final client = _client(transport, store: store, realtime: realtime);
      final first = await client.threads.open(rootMessageId: _rootId)
          as ChatThreadOpenSuccess;
      final invalid = await client.createThread(
          rootMessageId: _rootId, name: ' invalid ') as ChatThreadOpenFailure;
      expect(invalid.error.code, ChatThreadOpeningErrorCode.validation);
      expect(client.threads.forRoot(_rootId).state,
          isA<ChatThreadOpeningReadyState>());
      final second = await client.threads.open(rootMessageId: _rootId)
          as ChatThreadOpenSuccess;
      expect(transport.requests, hasLength(1));
      first.handle.release();
      second.handle.release();
      expect(
          states.whereType<ChatRealtimeConversationSubscriptionRemovedState>(),
          hasLength(1));
      await client.dispose();
      await subscription.cancel();
      await realtime.dispose();
      await store.close();
    });

    test('known thread uses the normalized fast path without POST', () async {
      final store = NormalizedSnapshotStore();
      _seedRoot(store);
      store.reconcileThreadOpening(_result('created'));
      final transport = _FakeHttpTransport(
        (_) => throw StateError('HTTP must not be used'),
      );
      final client = _client(transport, store: store);

      final opened = await client.threads.open(rootMessageId: _rootId);

      final success = opened as ChatThreadOpenSuccess;
      expect(success.handle.conversationId, _threadId);
      expect(success.handle.state.reconciliationStatus, isNull);
      expect(transport.requests, isEmpty);
      success.handle.release();
      await client.dispose();
      await store.close();
    });

    test('sends exact retry-safe POST and hydrates every outcome', () async {
      for (final status in <String>[
        'created',
        'existing_for_root',
        'replayed',
      ]) {
        final store = NormalizedSnapshotStore();
        _seedRoot(store);
        final transport = _FakeHttpTransport(
          (_) async => HandrailChatHttpResponse(
            statusCode: status == 'created' ? 201 : 200,
            body: jsonEncode(threadCreationResultFixture(status)),
          ),
        );
        final client = _client(transport, store: store);

        final opened = await client.threads.open(rootMessageId: _rootId);

        final success = opened as ChatThreadOpenSuccess;
        expect(success.handle.state.reconciliationStatus?.wireValue, status);
        final request = transport.requests.single;
        expect(request.method, 'POST');
        expect(
          request.uri,
          Uri.parse('https://chat.example.test/api/chat/messages/'
              'message-root/thread'),
        );
        expect(request.headers, {
          'Accept': 'application/json',
          'Authorization': 'Bearer access-token',
          'Idempotency-Key': 'thread-open-key',
          'Content-Type': 'application/json',
        });
        expect(jsonDecode(request.body!), {
          'operation': 'create_thread',
          'parentConversationId': 'conversation-parent',
          'rootMessageId': 'message-root',
          'idempotencyKey': 'thread-open-key',
        });
        expect(store.state.conversations[_threadId], isA<ThreadConversation>());
        expect(store.state.conversationDetails[_threadId], isNotNull);
        expect(
          store.state.memberUserIdsByConversation[_threadId],
          const [UserId('user-current'), UserId('user-other')],
        );
        expect(store.state.currentUserPreferences[_threadId], isNotNull);
        expect(
          store.state.canonicalMessages[_rootId]!.threadSummary!.threadId,
          _threadId,
        );
        success.handle.release();
        await client.dispose();
        await store.close();
      }
    });

    test('retries transient POSTs with one stable idempotency identity',
        () async {
      final store = NormalizedSnapshotStore();
      _seedRoot(store);
      var attempts = 0;
      final transport = _FakeHttpTransport((_) async {
        attempts += 1;
        return attempts == 1
            ? const HandrailChatHttpResponse(statusCode: 503, body: 'retry')
            : HandrailChatHttpResponse(
                statusCode: 201,
                body: jsonEncode(threadCreationResultFixture('created')),
              );
      });
      final client = _client(
        transport,
        store: store,
        retryOptions: ChatCommandRetryOptions(
          maxAttempts: 2,
          backoff: (_) => Duration.zero,
          wait: (_, __) async {},
        ),
      );

      final opened = await client.threads.open(rootMessageId: _rootId)
          as ChatThreadOpenSuccess;

      expect(transport.requests, hasLength(2));
      expect(
        transport.requests.map((request) => request.headers['Idempotency-Key']),
        everyElement('thread-open-key'),
      );
      expect(
        transport.requests.map((request) => request.body),
        everyElement(transport.requests.first.body),
      );
      opened.handle.release();
      await client.dispose();
      await store.close();
    });

    test('coalesces concurrent work and retains one realtime subscription',
        () async {
      final response = Completer<HandrailChatHttpResponse>();
      final store = NormalizedSnapshotStore();
      _seedRoot(store);
      final transport = _FakeHttpTransport((_) => response.future);
      final realtime = _realtime();
      final subscriptionStates = <ChatRealtimeConversationSubscriptionState>[];
      final stateSubscription = realtime.conversationSubscriptionStates
          .listen(subscriptionStates.add);
      final client = _client(transport, store: store, realtime: realtime);
      final controller = client.threads.forRoot(_rootId);
      final transitions = controller.states.take(4).toList();

      final first = controller.open();
      final second = controller.open();
      await Future<void>.delayed(Duration.zero);
      expect(transport.requests, hasLength(1));
      response.complete(HandrailChatHttpResponse(
        statusCode: 201,
        body: jsonEncode(threadCreationResultFixture('created')),
      ));
      final firstHandle = (await first as ChatThreadOpenSuccess).handle;
      final secondHandle = (await second as ChatThreadOpenSuccess).handle;

      expect(
        subscriptionStates
            .whereType<ChatRealtimeConversationSubscriptionPendingState>()
            .where((state) =>
                state.operation ==
                ChatRealtimeConversationSubscriptionOperation.subscribe),
        hasLength(1),
      );
      firstHandle.release();
      firstHandle.release();
      expect(
        subscriptionStates
            .whereType<ChatRealtimeConversationSubscriptionRemovedState>(),
        isEmpty,
      );
      secondHandle.release();
      expect(
        (await transitions).map((state) => state.state),
        ['idle', 'loading', 'ready', 'idle'],
      );
      expect(
        subscriptionStates
            .whereType<ChatRealtimeConversationSubscriptionRemovedState>(),
        hasLength(1),
      );

      final reopened = await client.threads.open(rootMessageId: _rootId)
          as ChatThreadOpenSuccess;
      expect(transport.requests, hasLength(1));
      expect(
        subscriptionStates
            .whereType<ChatRealtimeConversationSubscriptionPendingState>()
            .where((state) =>
                state.operation ==
                ChatRealtimeConversationSubscriptionOperation.subscribe),
        hasLength(2),
      );
      reopened.handle.release();
      await client.dispose();
      await stateSubscription.cancel();
      await realtime.dispose();
      await store.close();
    });

    test('failures are typed, redacted, atomic, and retryable', () async {
      const secret = 'sensitive-response-or-token';
      final cases = <({
        Future<String> Function() token,
        _Handler handler,
        ChatThreadOpeningErrorCode code,
      })>[
        (
          token: () => Future.error(StateError(secret)),
          handler: (_) => throw StateError('unused'),
          code: ChatThreadOpeningErrorCode.authentication,
        ),
        (
          token: () async => 'access-token',
          handler: (_) async => const HandrailChatHttpResponse(
                statusCode: 409,
                body: '{"error":{"code":"CONFLICT","message":"secret"}}',
              ),
          code: ChatThreadOpeningErrorCode.conflict,
        ),
        (
          token: () async => 'access-token',
          handler: (_) async => const HandrailChatHttpResponse(
                statusCode: 400,
                body: '{"error":{"code":"BAD_INPUT","message":"secret"}}',
              ),
          code: ChatThreadOpeningErrorCode.http,
        ),
        (
          token: () async => 'access-token',
          handler: (_) async => const HandrailChatHttpResponse(
                statusCode: 200,
                body: secret,
              ),
          code: ChatThreadOpeningErrorCode.malformedResponse,
        ),
      ];
      for (final testCase in cases) {
        final store = NormalizedSnapshotStore();
        _seedRoot(store);
        final client = _client(
          _FakeHttpTransport(testCase.handler),
          store: store,
          token: testCase.token,
        );

        final result = await client.threads.open(rootMessageId: _rootId)
            as ChatThreadOpenFailure;

        expect(result.error.code, testCase.code);
        expect(result.error.toString(), isNot(contains(secret)));
        expect(store.state.conversations[_threadId], isNull);
        expect(store.state.canonicalMessages[_rootId]!.threadSummary, isNull);
        await client.dispose();
        await store.close();
      }

      final retryStore = NormalizedSnapshotStore();
      _seedRoot(retryStore);
      var attempts = 0;
      final retryClient = _client(
        _FakeHttpTransport((_) async {
          attempts += 1;
          return attempts == 1
              ? const HandrailChatHttpResponse(
                  statusCode: 409,
                  body: '{"error":{"code":"CONFLICT","message":"no"}}',
                )
              : HandrailChatHttpResponse(
                  statusCode: 201,
                  body: jsonEncode(threadCreationResultFixture('created')),
                );
        }),
        store: retryStore,
      );
      expect(
        (await retryClient.threads.open(rootMessageId: _rootId)
                as ChatThreadOpenFailure)
            .error
            .code,
        ChatThreadOpeningErrorCode.conflict,
      );
      expect(retryStore.state.conversations[_threadId], isNull);
      final retried = await retryClient.threads.open(rootMessageId: _rootId)
          as ChatThreadOpenSuccess;
      expect(attempts, 2);
      retried.handle.release();
      await retryClient.dispose();
      await retryStore.close();
    });

    test('reconciliation failure releases its provisional subscription',
        () async {
      final store = NormalizedSnapshotStore();
      _seedRoot(store, tenantId: 'another-tenant');
      final realtime = _realtime();
      final subscriptionStates = <ChatRealtimeConversationSubscriptionState>[];
      final stateSubscription = realtime.conversationSubscriptionStates
          .listen(subscriptionStates.add);
      final client = _client(
        _FakeHttpTransport(
          (_) async => HandrailChatHttpResponse(
            statusCode: 201,
            body: jsonEncode(threadCreationResultFixture('created')),
          ),
        ),
        store: store,
        realtime: realtime,
      );

      final failed = await client.threads.open(rootMessageId: _rootId)
          as ChatThreadOpenFailure;

      expect(failed.error.code, ChatThreadOpeningErrorCode.reconciliation);
      expect(store.state.conversations[_threadId], isNull);
      expect(store.state.canonicalMessages[_rootId]!.threadSummary, isNull);
      expect(
        subscriptionStates
            .whereType<ChatRealtimeConversationSubscriptionRemovedState>(),
        hasLength(1),
      );
      await client.dispose();
      await stateSubscription.cancel();
      await realtime.dispose();
      await store.close();
    });

    test('validation, missing-root, disposal, and state sequencing are stable',
        () async {
      final emptyStore = NormalizedSnapshotStore();
      final noHttp = _FakeHttpTransport(
        (_) => throw StateError('HTTP must not be used'),
      );
      final client = _client(noHttp, store: emptyStore);
      expect(
        (await client.threads.open(rootMessageId: const MessageId(' bad'))
                as ChatThreadOpenFailure)
            .error
            .code,
        ChatThreadOpeningErrorCode.validation,
      );
      expect(
        (await client.threads.open(rootMessageId: _rootId)
                as ChatThreadOpenFailure)
            .error
            .code,
        ChatThreadOpeningErrorCode.rootMessageUnavailable,
      );
      expect(noHttp.requests, isEmpty);
      await client.dispose();
      expect(
        (await client.threads.open(rootMessageId: _rootId)
                as ChatThreadOpenFailure)
            .error
            .code,
        ChatThreadOpeningErrorCode.closed,
      );
      await emptyStore.close();

      final store = NormalizedSnapshotStore();
      _seedRoot(store);
      final pending = Completer<HandrailChatHttpResponse>();
      final activeClient = _client(
        _FakeHttpTransport((_) => pending.future),
        store: store,
      );
      final controller = activeClient.threads.forRoot(_rootId);
      expect(controller.states.isBroadcast, isTrue);
      final states = controller.states.take(3).toList();
      final opening = controller.open();
      await activeClient.dispose();
      final closed = await opening as ChatThreadOpenFailure;
      expect(closed.error.code, ChatThreadOpeningErrorCode.closed);
      expect(
        (await states).map((state) => state.state),
        ['idle', 'loading', 'error'],
      );
      await store.close();
    });
  });
}

const _rootId = MessageId('message-root');
const _threadId = ConversationId('conversation-thread');

ThreadCreationResult _result(String status) => ThreadCreationResult.fromJson(
      threadCreationResultFixture(status),
      expectedInput: ThreadCreationInput.fromJson({
        ...threadCreationInputFixture,
        'initialFollow': null,
      }..remove('initialFollow')),
    );

void _seedRoot(
  NormalizedSnapshotStore store, {
  String tenantId = 'tenant-from-session',
}) {
  store.reconcileMessage(Message.fromJson({
    'id': _rootId.value,
    'tenantId': tenantId,
    'conversationId': 'conversation-parent',
    'author': {'type': 'user', 'userId': 'user-current'},
    'sequence': 1,
    'createdAt': '2026-08-26T16:00:00.000Z',
    'updatedAt': '2026-08-26T16:00:00.000Z',
    'revision': {'revision': 1},
    'content': {'format': 'plain', 'text': 'root'},
  }));
}

HandrailChatClient _client(
  _FakeHttpTransport transport, {
  required NormalizedSnapshotStore store,
  Future<String> Function()? token,
  String Function()? generateKey,
  ChatRealtimeSessionTransport? realtime,
  ChatCommandRetryOptions retryOptions =
      const ChatCommandRetryOptions(maxAttempts: 1),
}) =>
    HandrailChatClient(
      apiBaseUri: Uri.parse('https://chat.example.test/api/chat/'),
      tokenProvider: token ?? () async => 'access-token',
      transport: transport,
      commandRetryOptions: retryOptions,
      generateIdempotencyKey: generateKey ?? () => 'thread-open-key',
      normalizedSnapshotStore: store,
      realtimeSession: realtime,
    );

typedef _Handler = Future<HandrailChatHttpResponse> Function(
  HandrailChatHttpRequest request,
);

final class _FakeHttpTransport implements HandrailChatHttpTransport {
  _FakeHttpTransport(this.handler);

  final _Handler handler;
  final List<HandrailChatHttpRequest> requests = [];

  @override
  Future<HandrailChatHttpResponse> send(HandrailChatHttpRequest request) {
    requests.add(request);
    return handler(request);
  }
}

ChatRealtimeSessionTransport _realtime() => ChatRealtimeSessionTransport(
      endpoint: Uri.parse('https://chat.example.test/api/chat'),
      clientPackageVersion: '0.1.4',
      protocolVersion: 4,
      tokenProvider: () => 'socket-token',
      socketFactory: (uri, protocols) => _UnusedSocket(),
    );

final class _UnusedSocket implements ChatRealtimeSocket {
  @override
  Stream<Object?> get frames => const Stream.empty();

  @override
  void send(String data) {}

  @override
  void close() {}
}

_Handler _existingHandler() => (request) async {
      final parent = request.uri.path.endsWith('/conversation-parent/messages');
      return HandrailChatHttpResponse(
          statusCode: 200,
          body: jsonEncode(request.uri.path.endsWith('/messages')
              ? existingThreadTimelineFixture(parent: parent)
              : existingThreadDetailFixture()));
    };
