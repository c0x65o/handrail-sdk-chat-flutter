import 'dart:async';
import 'dart:convert';

import 'package:handrail_chat/core.dart';
import 'package:test/test.dart';

const _conversationId = ConversationId('conversation-1');
const _ordinaryMessageId = MessageId('message-1');

void main() {
  final originalContent = MessageContent(
    format: MessageContentFormat.plain,
    text: 'original content',
  );
  final replacementContent = MessageContent(
    format: MessageContentFormat.markdown,
    text: 'replacement **content**',
  );

  test('projects synchronously and sends the exact encoded PATCH request',
      () async {
    const messageId = MessageId('message /?#');
    final original = _message(
      messageId: messageId,
      content: originalContent,
    );
    final store = _timelineStore(original);
    final canonicalBefore = store.state.canonicalMessages[messageId]!;
    final timelineProjection = store.state.messages[messageId];
    final started = Completer<void>();
    final response = Completer<HandrailChatHttpResponse>();
    final transport = _RecordingTransport((_) {
      started.complete();
      return response.future;
    });
    final client = _client(
      store: store,
      transport: transport,
      generateIdempotencyKey: () => 'generated-key-must-not-run',
    );

    final future = client.editMessage(
      ChatEditMessageInput(
        messageId: messageId,
        expectedRevision: 1,
        content: replacementContent,
        idempotencyKey: 'caller-edit-key',
      ),
    );

    final projection = store.state.canonicalMessages[messageId]!;
    expect(projection, isNot(same(original)));
    expect(projection.content?.toJson(), replacementContent.toJson());
    expect(projection.revision, same(canonicalBefore.revision));
    expect(projection.id, canonicalBefore.id);
    expect(projection.tenantId, canonicalBefore.tenantId);
    expect(projection.conversationId, canonicalBefore.conversationId);
    expect(projection.author, same(canonicalBefore.author));
    expect(projection.sequence, canonicalBefore.sequence);
    expect(projection.createdAt, canonicalBefore.createdAt);
    expect(projection.updatedAt, canonicalBefore.updatedAt);
    expect(original.content.toJson(), originalContent.toJson());
    expect(store.state.messages[messageId], same(timelineProjection));

    await started.future;
    expect(transport.requests, hasLength(1));
    final request = transport.requests.single;
    expect(request.method, 'PATCH');
    expect(
      request.uri.toString(),
      'https://chat.example.test/api/chat/messages/message%20%2F%3F%23',
    );
    expect(request.headers['Idempotency-Key'], 'caller-edit-key');
    expect(request.headers['Content-Type'], 'application/json');
    expect(jsonDecode(request.body!), <String, Object?>{
      'operation': 'edit',
      'messageId': messageId.value,
      'expectedRevision': 1,
      'content': replacementContent.toJson(),
      'idempotencyKey': 'caller-edit-key',
    });

    final canonical = _message(
      messageId: messageId,
      revision: 2,
      content: replacementContent,
    );
    response.complete(_editResponse('applied', canonical));
    final result = await future;

    expect(result, isA<ChatCommandSuccess<EditMessageResult>>());
    expect(
      store.state.canonicalMessages[messageId]?.toJson(),
      canonical.toJson(),
    );
    expect(store.state.messages[messageId], same(timelineProjection));
    expect(store.timeline(_conversationId).messageIds, [messageId]);

    await client.dispose();
    await store.close();
  });

  test('validates the complete request before auth or HTTP access', () async {
    var tokenCalls = 0;
    final original = _message(content: originalContent);
    final store = NormalizedSnapshotStore()..reconcileMessage(original);
    final initialState = store.state;
    final transport = _RecordingTransport(
      (_) async => throw StateError('HTTP must not run'),
    );
    final client = _client(
      store: store,
      transport: transport,
      tokenProvider: () async {
        tokenCalls += 1;
        return 'token';
      },
    );

    final malformedRevision = await client.editMessage(
      ChatEditMessageInput(
        messageId: _ordinaryMessageId,
        expectedRevision: 0,
        content: replacementContent,
        idempotencyKey: 'edit-key',
      ),
    );
    final blankKey = await client.editMessage(
      ChatEditMessageInput(
        messageId: _ordinaryMessageId,
        expectedRevision: 1,
        content: replacementContent,
        idempotencyKey: '   ',
      ),
    );

    expect(
      malformedRevision,
      isA<ChatCommandValidationFailure<EditMessageResult>>(),
    );
    expect(blankKey, isA<ChatCommandValidationFailure<EditMessageResult>>());
    expect(tokenCalls, 0);
    expect(transport.requests, isEmpty);
    expect(store.state, same(initialState));

    await client.dispose();
    await store.close();
  });

  test('keeps one generated key and identical body across a safe retry',
      () async {
    var keyCalls = 0;
    var attempts = 0;
    final store = NormalizedSnapshotStore()
      ..reconcileMessage(_message(content: originalContent));
    final transport = _RecordingTransport((_) async {
      attempts += 1;
      if (attempts == 1) throw StateError('offline');
      return _editResponse(
        'replayed',
        _message(revision: 2, content: replacementContent),
      );
    });
    final client = _client(
      store: store,
      transport: transport,
      generateIdempotencyKey: () {
        keyCalls += 1;
        return 'stable-edit-key';
      },
      retryOptions: ChatCommandRetryOptions(
        maxAttempts: 2,
        backoff: (_) => Duration.zero,
        wait: (_, __) async {},
      ),
    );

    final result = await client.editMessage(
      ChatEditMessageInput(
        messageId: _ordinaryMessageId,
        expectedRevision: 1,
        content: replacementContent,
      ),
    );

    expect(result, isA<ChatCommandSuccess<EditMessageResult>>());
    expect(
      (result as ChatCommandSuccess<EditMessageResult>)
          .value
          .reconciliationStatus,
      EditMessageReconciliationStatus.replayed,
    );
    expect(keyCalls, 1);
    expect(transport.requests, hasLength(2));
    expect(transport.requests[0].body, transport.requests[1].body);
    expect(
      transport.requests
          .map((request) => request.headers['Idempotency-Key'])
          .toSet(),
      {'stable-edit-key'},
    );
    expect(
      (jsonDecode(transport.requests.first.body!)
          as Map<String, Object?>)['idempotencyKey'],
      'stable-edit-key',
    );

    await client.dispose();
    await store.close();
  });

  test('replayed reconciliation has one row and no duplicate state effect',
      () async {
    final original = _message(content: originalContent);
    final canonical = _message(revision: 2, content: replacementContent);
    final store = NormalizedSnapshotStore()..reconcileMessage(original);
    var timelineEffects = 0;
    final subscription = store
        .watchTimeline(_conversationId)
        .listen((_) => timelineEffects += 1);
    final client = _client(
      store: store,
      transport: _RecordingTransport(
        (_) async => _editResponse('replayed', canonical),
      ),
      generateIdempotencyKey: () => 'replay-key',
    );

    final result = await client.editMessage(
      ChatEditMessageInput(
        messageId: _ordinaryMessageId,
        expectedRevision: 1,
        content: replacementContent,
      ),
    );
    final value = (result as ChatCommandSuccess<EditMessageResult>).value;
    final settledState = store.state;
    store.reconcileOptimisticMessageEdit('replay-key', value);

    expect(store.state, same(settledState));
    expect(store.state.canonicalMessages, hasLength(1));
    expect(store.timeline(_conversationId).messageIds, [_ordinaryMessageId]);
    expect(timelineEffects, 2, reason: 'one projection and one settlement');

    await subscription.cancel();
    await client.dispose();
    await store.close();
  });

  test('parses a 409 revision conflict and installs its authoritative row',
      () async {
    final original = _message(content: originalContent);
    final serverCurrent = _message(
      revision: 3,
      content: MessageContent(
        format: MessageContentFormat.plain,
        text: 'server current',
      ),
    );
    final store = NormalizedSnapshotStore()..reconcileMessage(original);
    final client = _client(
      store: store,
      transport: _RecordingTransport(
        (_) async => _editResponse(
          'revision_conflict',
          serverCurrent,
          statusCode: 409,
          canonicalRevision: 3,
        ),
      ),
    );

    final result = await client.editMessage(
      ChatEditMessageInput(
        messageId: _ordinaryMessageId,
        expectedRevision: 1,
        content: replacementContent,
      ),
    );

    expect(result, isA<ChatCommandSuccess<EditMessageResult>>());
    final conflict = (result as ChatCommandSuccess<EditMessageResult>).value;
    expect(
      conflict.reconciliationStatus,
      EditMessageReconciliationStatus.revisionConflict,
    );
    expect(conflict.canonicalRevision, 3);
    expect(
      store.state.canonicalMessages[_ordinaryMessageId]?.toJson(),
      serverCurrent.toJson(),
    );
    expect(store.timeline(_conversationId).messageIds, [_ordinaryMessageId]);

    await client.dispose();
    await store.close();
  });

  test('terminal failure rolls back only the optimistic edit', () async {
    final original = _message(content: originalContent);
    final store = NormalizedSnapshotStore()..reconcileMessage(original);
    final client = _client(
      store: store,
      transport: _RecordingTransport(
        (_) async => _errorResponse(403, 'AUTHENTICATION_FAILED'),
      ),
    );

    final result = await client.editMessage(
      ChatEditMessageInput(
        messageId: _ordinaryMessageId,
        expectedRevision: 1,
        content: replacementContent,
      ),
    );

    expect(result, isA<ChatCommandAuthenticationFailure<EditMessageResult>>());
    expect(store.state.canonicalMessages[_ordinaryMessageId], same(original));
    expect(store.timeline(_conversationId).messageIds, [_ordinaryMessageId]);

    await client.dispose();
    await store.close();
  });

  test('cancellation before and during transport restores canonical content',
      () async {
    final beforeOriginal = _message(content: originalContent);
    final beforeStore = NormalizedSnapshotStore()
      ..reconcileMessage(beforeOriginal);
    final beforeTransport = _RecordingTransport(
      (_) async => throw StateError('HTTP must not run'),
    );
    final beforeClient = _client(
      store: beforeStore,
      transport: beforeTransport,
    );
    final beforeCancellation = ChatCommandCancellationController()..cancel();

    final beforeResult = await beforeClient.editMessage(
      ChatEditMessageInput(
        messageId: _ordinaryMessageId,
        expectedRevision: 1,
        content: replacementContent,
      ),
      cancellationSignal: beforeCancellation.signal,
    );

    expect(beforeResult, isA<ChatCommandAborted<EditMessageResult>>());
    expect(beforeTransport.requests, isEmpty);
    expect(
      beforeStore.state.canonicalMessages[_ordinaryMessageId],
      same(beforeOriginal),
    );
    await beforeClient.dispose();
    await beforeStore.close();

    final duringOriginal = _message(content: originalContent);
    final duringStore = NormalizedSnapshotStore()
      ..reconcileMessage(duringOriginal);
    final started = Completer<void>();
    final pending = Completer<HandrailChatHttpResponse>();
    final duringTransport = _RecordingTransport((_) {
      started.complete();
      return pending.future;
    });
    final duringClient = _client(
      store: duringStore,
      transport: duringTransport,
    );
    final duringCancellation = ChatCommandCancellationController();
    final future = duringClient.editMessage(
      ChatEditMessageInput(
        messageId: _ordinaryMessageId,
        expectedRevision: 1,
        content: replacementContent,
      ),
      cancellationSignal: duringCancellation.signal,
    );
    await started.future;
    duringCancellation.cancel();

    expect(await future, isA<ChatCommandAborted<EditMessageResult>>());
    expect(
      duringStore.state.canonicalMessages[_ordinaryMessageId],
      same(duringOriginal),
    );
    final transportSignal = duringTransport.requests.single.cancellationSignal
        as ChatCommandCancellationSignal;
    expect(transportSignal.isCancelled, isTrue);

    await duringClient.dispose();
    await duringStore.close();
  });

  test('newer durable reconciliation wins over a later rollback', () async {
    final original = _message(content: originalContent);
    final durable = _message(
      revision: 3,
      content: MessageContent(
        format: MessageContentFormat.plain,
        text: 'newer durable content',
      ),
    );
    final store = NormalizedSnapshotStore()..reconcileMessage(original);
    final started = Completer<void>();
    final response = Completer<HandrailChatHttpResponse>();
    final client = _client(
      store: store,
      transport: _RecordingTransport((_) {
        started.complete();
        return response.future;
      }),
    );
    final future = client.editMessage(
      ChatEditMessageInput(
        messageId: _ordinaryMessageId,
        expectedRevision: 1,
        content: replacementContent,
      ),
    );
    await started.future;

    store.reconcileMessage(durable);
    final durableState = store.state;
    response.complete(_errorResponse(403, 'AUTHENTICATION_FAILED'));
    final result = await future;

    expect(result, isA<ChatCommandAuthenticationFailure<EditMessageResult>>());
    expect(store.state, same(durableState));
    expect(store.state.canonicalMessages[_ordinaryMessageId], same(durable));
    expect(store.timeline(_conversationId).messageIds, [_ordinaryMessageId]);

    await client.dispose();
    await store.close();
  });
}

HandrailChatClient _client({
  required NormalizedSnapshotStore store,
  required _RecordingTransport transport,
  HandrailChatAccessTokenProvider? tokenProvider,
  ChatCommandIdempotencyKeyGenerator? generateIdempotencyKey,
  ChatCommandRetryOptions retryOptions = const ChatCommandRetryOptions(),
}) =>
    HandrailChatClient(
      apiBaseUri: Uri.parse(
        'https://chat.example.test/api/chat/?ignored=true#fragment',
      ),
      tokenProvider: tokenProvider ?? () async => 'access-token',
      transport: transport,
      normalizedSnapshotStore: store,
      generateIdempotencyKey: generateIdempotencyKey ?? () => 'edit-key',
      commandRetryOptions: retryOptions,
    );

NormalizedSnapshotStore _timelineStore(ActiveMessage message) {
  final request = MessageTimelineRequest(
    conversationId: message.conversationId,
    direction: MessageTimelineDirection.backward,
    limit: 10,
  );
  final page = MessageTimelinePage.fromJson(
    <String, Object?>{
      'conversationId': message.conversationId.toJson(),
      'messages': <Object?>[
        <String, Object?>{
          ...message.toJson(),
          'isThreadRoot': false,
          'reactions': <Object?>[
            <String, Object?>{
              'reactionKey': 'thumbsup',
              'count': 2,
              'reactedByCurrentUser': true,
            },
          ],
          'attachmentMetadata': <Object?>[],
        },
      ],
      'pagination': <String, Object?>{
        'older': <String, Object?>{'available': false},
        'newer': <String, Object?>{'available': false},
      },
      'replay': <String, Object?>{
        'resumeFrom': <String, Object?>{'eventId': 'event-1'},
      },
    },
    request: request,
  );
  return NormalizedSnapshotStore()..hydrateMessageTimeline(page);
}

ActiveMessage _message({
  MessageId messageId = _ordinaryMessageId,
  int revision = 1,
  required MessageContent content,
}) =>
    ActiveMessage(
      id: messageId,
      tenantId: const TenantId('tenant-1'),
      conversationId: _conversationId,
      author: const MessageAuthorIdentity(userId: UserId('user-1')),
      sequence: const MessageSequence(7),
      createdAt: const IsoTimestamp('2026-08-26T15:00:00.000Z'),
      updatedAt: IsoTimestamp(
        '2026-08-26T15:00:0$revision.000Z',
      ),
      revision: MessageRevisionMetadata(
        revision: revision,
        editedAt: revision == 1
            ? null
            : IsoTimestamp('2026-08-26T15:00:0$revision.000Z'),
        editedByUserId: revision == 1 ? null : const UserId('user-1'),
      ),
      content: content,
    );

HandrailChatHttpResponse _editResponse(
  String reconciliationStatus,
  ActiveMessage message, {
  int statusCode = 200,
  int? canonicalRevision,
}) =>
    HandrailChatHttpResponse(
      statusCode: statusCode,
      body: jsonEncode(<String, Object?>{
        'operation': 'edit',
        'reconciliationStatus': reconciliationStatus,
        'expectedRevision': 1,
        'message': message.toJson(),
        'canonicalRevision': canonicalRevision ?? message.revision.revision,
      }),
    );

HandrailChatHttpResponse _errorResponse(int statusCode, String code) =>
    HandrailChatHttpResponse(
      statusCode: statusCode,
      body: jsonEncode(<String, Object?>{
        'error': <String, Object?>{
          'code': code,
          'message': 'request rejected',
        },
      }),
    );

final class _RecordingTransport implements HandrailChatHttpTransport {
  _RecordingTransport(this.handler);

  final Future<HandrailChatHttpResponse> Function(
    HandrailChatHttpRequest request,
  ) handler;
  final List<HandrailChatHttpRequest> requests = [];

  @override
  Future<HandrailChatHttpResponse> send(HandrailChatHttpRequest request) {
    requests.add(request);
    return handler(request);
  }
}
