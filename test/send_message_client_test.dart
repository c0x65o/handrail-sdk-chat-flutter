import 'dart:async';
import 'dart:convert';

import 'package:handrail_chat/src/core/command_dispatcher.dart';
import 'package:handrail_chat/src/core/normalized_snapshot_state.dart';
import 'package:handrail_chat/src/generated/identifiers.dart';
import 'package:handrail_chat/src/generated/edit_message.dart';
import 'package:handrail_chat/src/generated/delete_message.dart';
import 'package:handrail_chat/src/generated/message.dart';
import 'package:handrail_chat/src/generated/send_message.dart';
import 'package:handrail_chat/src/handrail_chat_client.dart';
import 'package:test/test.dart';

void main() {
  final content = MessageContent(
    format: MessageContentFormat.markdown,
    text: 'Order **42** is ready',
  );

  final reply = MessageReplyReference(
      messageId: const MessageId('source-1'), notifyAuthor: true);

  test('sends exact validated body to the encoded message route', () async {
    const conversationId = ConversationId('conversation /?#');
    final transport = _RecordingTransport(
      (request) async => HandrailChatHttpResponse(
        statusCode: 200,
        body: jsonEncode(
          _sendResult(
            'applied',
            conversationId: conversationId,
            content: content,
          ),
        ),
      ),
    );
    final client = _client(
      transport: transport,
      generateClientMessageId: () => 'client-message-1',
      generateIdempotencyKey: () => 'send-key-1',
    );

    final result = await client.sendMessage(
      ChatSendMessageInput(
        conversationId: conversationId,
        content: content,
      ),
    );

    expect(result, isA<ChatCommandSuccess<SendMessageResult>>());
    expect(
      (result as ChatCommandSuccess<SendMessageResult>)
          .value
          .reconciliationStatus,
      MessageMutationReconciliationStatus.applied,
    );
    expect(transport.requests, hasLength(1));
    final request = transport.requests.single;
    expect(request.method, 'POST');
    expect(
      request.uri.toString(),
      'https://chat.example.test/api/chat/conversations/'
      'conversation%20%2F%3F%23/messages',
    );
    expect(request.headers['Idempotency-Key'], 'send-key-1');
    expect(request.headers['Content-Type'], 'application/json');
    expect(jsonDecode(request.body!), <String, Object?>{
      'operation': 'send',
      'conversationId': conversationId.value,
      'content': content.toJson(),
      'clientMessageId': 'client-message-1',
      'idempotencyKey': 'send-key-1',
    });
    await client.dispose();
  });

  for (final destination in ['channel-1', 'dm-1', 'existing-thread-1']) {
    for (final notifyAuthor in [true, false]) {
      test('reply preserves $destination and ping=$notifyAuthor on replay',
          () async {
        final reference = MessageReplyReference(
            messageId: const MessageId('source-1'), notifyAuthor: notifyAuthor);
        var sends = 0;
        final transport = _RecordingTransport((request) async {
          expect(request.method, 'POST');
          expect(request.uri.path,
              '/api/chat/conversations/$destination/messages');
          expect(jsonDecode(request.body!), {
            'operation': 'send',
            'conversationId': destination,
            'content': content.toJson(),
            'replyTo': reference.toJson(),
            'clientMessageId': 'client-message-1',
            'idempotencyKey': 'send-key-1',
          });
          return HandrailChatHttpResponse(
              statusCode: 200,
              body: jsonEncode(_sendResult(
                  sends++ == 0 ? 'applied' : 'replayed',
                  conversationId: ConversationId(destination),
                  content: content,
                  replyTo: reference)));
        });
        final client = _client(transport: transport);
        addTearDown(client.dispose);
        final input = ChatSendMessageInput(
            conversationId: ConversationId(destination),
            content: content,
            replyTo: reference);
        for (final status in MessageMutationReconciliationStatus.values) {
          final result = await client.sendMessage(input);
          expect(result, isA<ChatCommandSuccess<SendMessageResult>>());
          final value = (result as ChatCommandSuccess<SendMessageResult>).value;
          expect(value.reconciliationStatus, status);
          expect(value.message.replyTo?.toJson(), reference.toJson());
        }
        expect(transport.requests, hasLength(2));
        expect(client.normalizedState.state.canonicalMessages, hasLength(1));
        final timeline =
            client.normalizedState.timeline(ConversationId(destination));
        expect(timeline.messageIds, [const MessageId('message-1')]);
        expect(timeline.canonicalMessages.single.replyTo?.toJson(),
            reference.toJson());
        expect(client.normalizedState.state.conversations, isEmpty,
            reason: 'Sending never creates or opens a thread.');
      });
    }
  }

  test('keeps generated IDs and body stable across a transient retry',
      () async {
    var clientIdCalls = 0;
    var idempotencyCalls = 0;
    var attempts = 0;
    final transport = _RecordingTransport((request) async {
      attempts += 1;
      if (attempts == 1) {
        return const HandrailChatHttpResponse(statusCode: 503, body: '');
      }
      return HandrailChatHttpResponse(
        statusCode: 200,
        body: jsonEncode(
          _sendResult(
            'applied',
            conversationId: const ConversationId('conversation-1'),
            content: content,
            clientMessageId: 'client-message-stable',
            replyTo: reply,
          ),
        ),
      );
    });
    final client = _client(
      transport: transport,
      generateClientMessageId: () {
        clientIdCalls += 1;
        return 'client-message-stable';
      },
      generateIdempotencyKey: () {
        idempotencyCalls += 1;
        return 'send-key-stable';
      },
      retryOptions: ChatCommandRetryOptions(
        maxAttempts: 2,
        backoff: (_) => Duration.zero,
        wait: (_, __) async {},
      ),
    );

    final result = await client.sendMessage(
      ChatSendMessageInput(
        conversationId: ConversationId('conversation-1'),
        content: content,
        replyTo: reply,
      ),
    );

    expect(result, isA<ChatCommandSuccess<SendMessageResult>>());
    expect(transport.requests, hasLength(2));
    expect(
        jsonDecode(transport.requests.first.body!)['replyTo'], reply.toJson());
    expect(clientIdCalls, 1);
    expect(idempotencyCalls, 1);
    expect(transport.requests[0].body, transport.requests[1].body);
    expect(
      transport.requests.map((request) => request.headers['Idempotency-Key']),
      everyElement('send-key-stable'),
    );
    await client.dispose();
  });

  test('generated-contract validation runs before token and HTTP access',
      () async {
    var tokenCalls = 0;
    final transport = _RecordingTransport(
      (_) async => throw StateError('HTTP must not run'),
    );
    final client = _client(
      transport: transport,
      tokenProvider: () async {
        tokenCalls += 1;
        return 'token';
      },
      generateClientMessageId: () => 'client-message-1',
      generateIdempotencyKey: () => '   ',
    );

    final result = await client.sendMessage(
      ChatSendMessageInput(
        conversationId: ConversationId('conversation-1'),
        content: content,
      ),
    );

    expect(result, isA<ChatCommandValidationFailure<SendMessageResult>>());
    expect(tokenCalls, 0);
    expect(transport.requests, isEmpty);
    await client.dispose();
  });

  test('applied then replayed stays one canonical row and stream effect',
      () async {
    final store = NormalizedSnapshotStore();
    var calls = 0;
    final transport = _RecordingTransport((_) async {
      calls += 1;
      return HandrailChatHttpResponse(
        statusCode: 200,
        body: jsonEncode(
          _sendResult(
            calls == 1 ? 'applied' : 'replayed',
            conversationId: const ConversationId('conversation-1'),
            content: content,
          ),
        ),
      );
    });
    final client = _client(
      transport: transport,
      normalizedState: store,
      generateClientMessageId: () => 'client-message-1',
      generateIdempotencyKey: () => 'send-key-1',
    );
    var timelineEffects = 0;
    final subscription = store
        .watchTimeline(const ConversationId('conversation-1'))
        .listen((_) => timelineEffects += 1);

    final applied = await client.sendMessage(
      ChatSendMessageInput(
        conversationId: ConversationId('conversation-1'),
        content: content,
      ),
    );
    final replayed = await client.sendMessage(
      ChatSendMessageInput(
        conversationId: ConversationId('conversation-1'),
        content: content,
      ),
    );

    expect(
      (applied as ChatCommandSuccess<SendMessageResult>)
          .value
          .reconciliationStatus,
      MessageMutationReconciliationStatus.applied,
    );
    expect(
      (replayed as ChatCommandSuccess<SendMessageResult>)
          .value
          .reconciliationStatus,
      MessageMutationReconciliationStatus.replayed,
    );
    expect(store.state.canonicalMessages, hasLength(1));
    expect(store.state.messages, isEmpty,
        reason: 'A send result has no timeline-only metadata to invent.');
    final timeline = store.timeline(const ConversationId('conversation-1'));
    expect(timeline.messageIds, const [MessageId('message-1')]);
    expect(timeline.canonicalMessages, hasLength(1));
    expect(timelineEffects, 1);

    await subscription.cancel();
    await client.dispose();
    await store.close();
  });

  test('preserves caller cancellation before and during transport', () async {
    final before = ChatCommandCancellationController()..cancel();
    final beforeTransport = _RecordingTransport(
      (_) async => throw StateError('HTTP must not run'),
    );
    final beforeClient = _client(transport: beforeTransport);

    final beforeResult = await beforeClient.sendMessage(
      ChatSendMessageInput(
        conversationId: ConversationId('conversation-1'),
        content: content,
        replyTo: reply,
      ),
      cancellationSignal: before.signal,
    );

    expect(beforeResult, isA<ChatCommandAborted<SendMessageResult>>());
    expect(beforeTransport.requests, isEmpty);
    await beforeClient.dispose();

    final started = Completer<void>();
    final pending = Completer<HandrailChatHttpResponse>();
    final duringTransport = _RecordingTransport((request) {
      started.complete();
      return pending.future;
    });
    final duringClient = _client(transport: duringTransport);
    final during = ChatCommandCancellationController();
    final future = duringClient.sendMessage(
      ChatSendMessageInput(
        conversationId: ConversationId('conversation-1'),
        content: content,
        replyTo: reply,
      ),
      cancellationSignal: during.signal,
    );
    await started.future;
    during.cancel();

    expect(await future, isA<ChatCommandAborted<SendMessageResult>>());
    final transportSignal = duringTransport.requests.single.cancellationSignal;
    expect(transportSignal, isA<ChatCommandCancellationSignal>());
    expect(
      (transportSignal! as ChatCommandCancellationSignal).isCancelled,
      isTrue,
    );
    pending.complete(HandrailChatHttpResponse(
        statusCode: 200,
        body: jsonEncode(_sendResult('applied',
            conversationId: const ConversationId('conversation-1'),
            content: content,
            replyTo: reply))));
    await Future<void>.delayed(Duration.zero);
    expect(duringClient.normalizedState.state.canonicalMessages, isEmpty);
    await duringClient.dispose();
  });

  test('canonical reply survives optimistic edit/delete and rollback',
      () async {
    final store = NormalizedSnapshotStore();
    addTearDown(store.close);
    final message = Message.fromJson((_sendResult('applied',
        conversationId: const ConversationId('conversation-1'),
        content: content,
        replyTo: reply))['message']);
    store.reconcileMessage(message);
    store.beginOptimisticMessageEdit(EditMessageRequest.fromJson({
      'operation': 'edit',
      'messageId': message.id.value,
      'expectedRevision': 1,
      'idempotencyKey': 'edit-1',
      'content': {'format': 'plain', 'text': 'Updated'},
    }));
    expect(store.state.canonicalMessages[message.id]?.replyTo?.toJson(),
        reply.toJson());
    store.rollbackOptimisticMessageEdit(message.id, 'edit-1');
    store.beginOptimisticMessageDelete(SoftDeleteMessageRequest.fromJson({
      'operation': 'soft_delete',
      'messageId': message.id.value,
      'expectedRevision': 1,
      'idempotencyKey': 'delete-1',
    }));
    expect(store.state.canonicalMessages[message.id]?.replyTo?.toJson(),
        reply.toJson());
    store.rollbackOptimisticMessageDelete(message.id, 'delete-1');
    expect(store.state.canonicalMessages[message.id]?.replyTo?.toJson(),
        reply.toJson());
  });

  test('authentication and transport exceptions return safe typed failures',
      () async {
    const secret = 'must-not-leak';
    final authTransport = _RecordingTransport(
      (_) async => throw StateError('HTTP must not run'),
    );
    final authClient = _client(
      transport: authTransport,
      tokenProvider: () => Future.error(StateError('token $secret')),
    );

    final auth = await authClient.sendMessage(
      ChatSendMessageInput(
        conversationId: ConversationId('conversation-1'),
        content: content,
      ),
    );
    expect(auth, isA<ChatCommandAuthenticationFailure<SendMessageResult>>());
    expect(auth.toString(), isNot(contains(secret)));
    expect(authTransport.requests, isEmpty);
    await authClient.dispose();

    final failingTransport = _RecordingTransport(
      (_) async => throw StateError('transport $secret'),
    );
    final transportClient = _client(
      transport: failingTransport,
      retryOptions: const ChatCommandRetryOptions(maxAttempts: 1),
    );
    final transport = await transportClient.sendMessage(
      ChatSendMessageInput(
        conversationId: ConversationId('conversation-1'),
        content: content,
      ),
    );
    expect(transport, isA<ChatCommandTransportFailure<SendMessageResult>>());
    expect(transport.toString(), isNot(contains(secret)));
    expect(failingTransport.requests, hasLength(1));
    await transportClient.dispose();
  });
}

HandrailChatClient _client({
  required _RecordingTransport transport,
  HandrailChatAccessTokenProvider? tokenProvider,
  ChatClientMessageIdGenerator? generateClientMessageId,
  ChatCommandIdempotencyKeyGenerator? generateIdempotencyKey,
  ChatCommandRetryOptions retryOptions = const ChatCommandRetryOptions(),
  NormalizedSnapshotStore? normalizedState,
}) =>
    HandrailChatClient(
      apiBaseUri: Uri.parse(
        'https://chat.example.test/api/chat/?ignored=true#fragment',
      ),
      tokenProvider: tokenProvider ?? () async => 'access-token',
      transport: transport,
      generateClientMessageId:
          generateClientMessageId ?? () => 'client-message-1',
      generateIdempotencyKey: generateIdempotencyKey ?? () => 'send-key-1',
      commandRetryOptions: retryOptions,
      normalizedSnapshotStore: normalizedState,
    );

Map<String, Object?> _sendResult(
  String reconciliationStatus, {
  required ConversationId conversationId,
  required MessageContent content,
  String clientMessageId = 'client-message-1',
  MessageReplyReference? replyTo,
}) =>
    <String, Object?>{
      'operation': 'send',
      'reconciliationStatus': reconciliationStatus,
      'clientMessageId': clientMessageId,
      'message': <String, Object?>{
        if (replyTo != null) 'replyTo': replyTo.toJson(),
        'id': 'message-1',
        'tenantId': 'tenant-1',
        'conversationId': conversationId.toJson(),
        'author': <String, Object?>{
          'type': 'user',
          'userId': 'user-1',
        },
        'sequence': 7,
        'createdAt': '2026-08-26T15:00:00.000Z',
        'updatedAt': '2026-08-26T15:00:00.000Z',
        'revision': <String, Object?>{'revision': 1},
        'content': content.toJson(),
      },
      'canonicalRevision': 1,
    };

final class _RecordingTransport implements HandrailChatHttpTransport {
  _RecordingTransport(this.handler);

  Future<HandrailChatHttpResponse> Function(HandrailChatHttpRequest request)
      handler;
  final List<HandrailChatHttpRequest> requests = [];

  @override
  Future<HandrailChatHttpResponse> send(HandrailChatHttpRequest request) {
    requests.add(request);
    return handler(request);
  }
}
