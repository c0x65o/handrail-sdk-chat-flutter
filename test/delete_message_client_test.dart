import 'dart:async';
import 'dart:convert';

import 'package:handrail_chat/core.dart';
import 'package:test/test.dart';

const _conversationId = ConversationId('conversation-1');
const _messageId = MessageId('message-1');

void main() {
  test('projects synchronously and sends the exact encoded DELETE request',
      () async {
    const encodedMessageId = MessageId('message /?#');
    final original = _activeMessage(messageId: encodedMessageId);
    final store = _timelineStore(original);
    final stateBefore = store.state;
    final timelineBefore = store.timeline(_conversationId);
    final baseline =
        stateBefore.canonicalMessages[encodedMessageId]! as ActiveMessage;
    final queryProjection = stateBefore.messages[encodedMessageId];
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

    final future = client.deleteMessage(
      const ChatDeleteMessageInput(
        messageId: encodedMessageId,
        expectedRevision: 1,
        idempotencyKey: 'caller-delete-key',
      ),
    );

    final projectedState = store.state;
    final projection = projectedState.canonicalMessages[encodedMessageId]!;
    expect(projection, isA<DeletedMessage>());
    expect(projection.content, isNull);
    expect(projection.revision, same(baseline.revision));
    expect(projection.id, baseline.id);
    expect(projection.tenantId, baseline.tenantId);
    expect(projection.conversationId, baseline.conversationId);
    expect(projection.author, same(baseline.author));
    expect(projection.sequence, baseline.sequence);
    expect(projection.createdAt, baseline.createdAt);
    expect(projection.updatedAt, baseline.updatedAt);
    expect((projection as DeletedMessage).deletedAt, baseline.updatedAt);
    expect(projection.deletedByUserId, baseline.author.userId);
    expect(projectedState.messages[encodedMessageId], same(queryProjection));

    expect(stateBefore.canonicalMessages[encodedMessageId], same(baseline));
    expect(timelineBefore.canonicalMessages.single, same(baseline));
    expect(
      () => timelineBefore.canonicalMessages.add(baseline),
      throwsUnsupportedError,
    );

    await started.future;
    final request = transport.requests.single;
    expect(request.method, 'DELETE');
    expect(
      request.uri.toString(),
      'https://chat.example.test/api/chat/messages/message%20%2F%3F%23',
    );
    expect(request.headers['Authorization'], 'Bearer access-token');
    expect(request.headers['Idempotency-Key'], 'caller-delete-key');
    expect(request.headers['Content-Type'], 'application/json');
    expect(jsonDecode(request.body!), <String, Object?>{
      'operation': 'soft_delete',
      'messageId': encodedMessageId.value,
      'expectedRevision': 1,
      'idempotencyKey': 'caller-delete-key',
    });

    final tombstone = _deletedMessage(
      messageId: encodedMessageId,
      revision: 2,
    );
    response.complete(_deleteResponse('applied', tombstone));
    expect(await future, isA<ChatCommandSuccess<SoftDeleteMessageResult>>());
    expect(
      store.state.canonicalMessages[encodedMessageId]?.toJson(),
      tombstone.toJson(),
    );
    expect(stateBefore.canonicalMessages[encodedMessageId], same(baseline));
    expect(timelineBefore.canonicalMessages.single, same(baseline));

    await client.dispose();
    await store.close();
  });

  test('validates the complete request and canonical baseline before auth',
      () async {
    var tokenCalls = 0;
    final original = _activeMessage();
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

    final invalidRevision = await client.deleteMessage(
      const ChatDeleteMessageInput(
        messageId: _messageId,
        expectedRevision: 0,
        idempotencyKey: 'delete-key',
      ),
    );
    final blankKey = await client.deleteMessage(
      const ChatDeleteMessageInput(
        messageId: _messageId,
        expectedRevision: 1,
        idempotencyKey: '   ',
      ),
    );
    final missingBaseline = await client.deleteMessage(
      const ChatDeleteMessageInput(
        messageId: MessageId('missing-message'),
        expectedRevision: 1,
        idempotencyKey: 'delete-key',
      ),
    );

    expect(
      invalidRevision,
      isA<ChatCommandValidationFailure<SoftDeleteMessageResult>>(),
    );
    expect(
      blankKey,
      isA<ChatCommandValidationFailure<SoftDeleteMessageResult>>(),
    );
    expect(
      missingBaseline,
      isA<ChatCommandValidationFailure<SoftDeleteMessageResult>>(),
    );
    expect(tokenCalls, 0);
    expect(transport.requests, isEmpty);
    expect(store.state, same(initialState));

    await client.dispose();
    await store.close();
  });

  test('keeps one generated identity and identical body across retry',
      () async {
    var keyCalls = 0;
    var attempts = 0;
    final store = NormalizedSnapshotStore()..reconcileMessage(_activeMessage());
    final transport = _RecordingTransport((_) async {
      attempts += 1;
      if (attempts == 1) throw StateError('offline');
      return _deleteResponse('replayed', _deletedMessage(revision: 2));
    });
    final client = _client(
      store: store,
      transport: transport,
      generateIdempotencyKey: () {
        keyCalls += 1;
        return 'stable-delete-key';
      },
      retryOptions: ChatCommandRetryOptions(
        maxAttempts: 2,
        backoff: (_) => Duration.zero,
        wait: (_, __) async {},
      ),
    );

    final result = await client.deleteMessage(
      const ChatDeleteMessageInput(
        messageId: _messageId,
        expectedRevision: 1,
      ),
    );

    expect(result, isA<ChatCommandSuccess<SoftDeleteMessageResult>>());
    expect(
      (result as ChatCommandSuccess<SoftDeleteMessageResult>)
          .value
          .reconciliationStatus,
      SoftDeleteMessageReconciliationStatus.replayed,
    );
    expect(keyCalls, 1);
    expect(transport.requests, hasLength(2));
    expect(transport.requests[0].body, transport.requests[1].body);
    expect(
      transport.requests
          .map((request) => request.headers['Idempotency-Key'])
          .toSet(),
      {'stable-delete-key'},
    );

    await client.dispose();
    await store.close();
  });

  for (final status in <String>['applied', 'replayed']) {
    test('$status settles once to one canonical tombstone', () async {
      final original = _activeMessage();
      final tombstone = _deletedMessage(revision: 2);
      final store = NormalizedSnapshotStore()..reconcileMessage(original);
      var effects = 0;
      final subscription =
          store.watchTimeline(_conversationId).listen((_) => effects += 1);
      final client = _client(
        store: store,
        transport: _RecordingTransport(
          (_) async => _deleteResponse(status, tombstone),
        ),
        generateIdempotencyKey: () => 'settlement-key',
      );

      final result = await client.deleteMessage(
        const ChatDeleteMessageInput(
          messageId: _messageId,
          expectedRevision: 1,
        ),
      );
      final value =
          (result as ChatCommandSuccess<SoftDeleteMessageResult>).value;
      final settledState = store.state;
      store.reconcileOptimisticMessageDelete('settlement-key', value);

      expect(store.state, same(settledState));
      expect(store.state.canonicalMessages, hasLength(1));
      expect(store.state.canonicalMessages[_messageId], same(value.message));
      expect(effects, 2, reason: 'one projection and one settlement');

      await subscription.cancel();
      await client.dispose();
      await store.close();
    });
  }

  test('a 409 revision conflict installs its authoritative active row',
      () async {
    final serverCurrent = _activeMessage(
      revision: 3,
      text: 'server current',
    );
    final store = NormalizedSnapshotStore()..reconcileMessage(_activeMessage());
    final client = _client(
      store: store,
      transport: _RecordingTransport(
        (_) async => _deleteResponse(
          'revision_conflict',
          serverCurrent,
          statusCode: 409,
        ),
      ),
    );

    final result = await client.deleteMessage(
      const ChatDeleteMessageInput(
        messageId: _messageId,
        expectedRevision: 1,
      ),
    );

    expect(result, isA<ChatCommandSuccess<SoftDeleteMessageResult>>());
    final value = (result as ChatCommandSuccess<SoftDeleteMessageResult>).value;
    expect(
      value.reconciliationStatus,
      SoftDeleteMessageReconciliationStatus.revisionConflict,
    );
    expect(store.state.canonicalMessages[_messageId], same(value.message));
    expect(value.message.toJson(), serverCurrent.toJson());

    await client.dispose();
    await store.close();
  });

  test('terminal and malformed failures restore only the owned projection',
      () async {
    for (final response in <HandrailChatHttpResponse>[
      _errorResponse(403, 'AUTHENTICATION_FAILED'),
      const HandrailChatHttpResponse(statusCode: 200, body: '{malformed'),
    ]) {
      final original = _activeMessage();
      final store = NormalizedSnapshotStore()..reconcileMessage(original);
      final client = _client(
        store: store,
        transport: _RecordingTransport((_) async => response),
      );

      final result = await client.deleteMessage(
        const ChatDeleteMessageInput(
          messageId: _messageId,
          expectedRevision: 1,
        ),
      );

      expect(result, isA<ChatCommandFailure<SoftDeleteMessageResult>>());
      expect(store.state.canonicalMessages[_messageId], same(original));

      await client.dispose();
      await store.close();
    }
  });

  test('cancellation and disposal restore the still-owned projection',
      () async {
    final cancelledOriginal = _activeMessage();
    final cancelledStore = NormalizedSnapshotStore()
      ..reconcileMessage(cancelledOriginal);
    final cancelledPending = Completer<HandrailChatHttpResponse>();
    final cancelledStarted = Completer<void>();
    final cancelledClient = _client(
      store: cancelledStore,
      transport: _RecordingTransport((_) {
        cancelledStarted.complete();
        return cancelledPending.future;
      }),
    );
    final cancellation = ChatCommandCancellationController();
    final cancelledFuture = cancelledClient.deleteMessage(
      const ChatDeleteMessageInput(
        messageId: _messageId,
        expectedRevision: 1,
      ),
      cancellationSignal: cancellation.signal,
    );
    await cancelledStarted.future;
    cancellation.cancel();

    expect(
      await cancelledFuture,
      isA<ChatCommandAborted<SoftDeleteMessageResult>>(),
    );
    expect(
      cancelledStore.state.canonicalMessages[_messageId],
      same(cancelledOriginal),
    );
    await cancelledClient.dispose();
    await cancelledStore.close();

    final disposedOriginal = _activeMessage();
    final disposedPending = Completer<HandrailChatHttpResponse>();
    final disposedStarted = Completer<void>();
    final disposedClient = HandrailChatClient(
      apiBaseUri: Uri.parse('https://chat.example.test/api/chat'),
      tokenProvider: () async => 'access-token',
      transport: _RecordingTransport((_) {
        disposedStarted.complete();
        return disposedPending.future;
      }),
      generateIdempotencyKey: () => 'delete-key',
    );
    final disposedStore = disposedClient.normalizedState
      ..reconcileMessage(disposedOriginal);
    final disposedFuture = disposedClient.deleteMessage(
      const ChatDeleteMessageInput(
        messageId: _messageId,
        expectedRevision: 1,
      ),
    );
    await disposedStarted.future;
    await disposedClient.dispose();

    expect(
      await disposedFuture,
      isA<ChatCommandClosed<SoftDeleteMessageResult>>(),
    );
    expect(
      disposedStore.state.canonicalMessages[_messageId],
      same(disposedOriginal),
    );
  });

  test('newer authoritative rows win over late success conflict and rollback',
      () async {
    final lateResponses = <HandrailChatHttpResponse>[
      _deleteResponse('applied', _deletedMessage(revision: 2)),
      _deleteResponse(
        'revision_conflict',
        _activeMessage(revision: 3, text: 'older conflict'),
        statusCode: 409,
      ),
      _errorResponse(403, 'AUTHENTICATION_FAILED'),
    ];

    for (final lateResponse in lateResponses) {
      final store = NormalizedSnapshotStore()
        ..reconcileMessage(_activeMessage());
      final started = Completer<void>();
      final pending = Completer<HandrailChatHttpResponse>();
      final client = _client(
        store: store,
        transport: _RecordingTransport((_) {
          started.complete();
          return pending.future;
        }),
      );
      final future = client.deleteMessage(
        const ChatDeleteMessageInput(
          messageId: _messageId,
          expectedRevision: 1,
        ),
      );
      await started.future;

      final newer = _activeMessage(revision: 4, text: 'newer event row');
      store.reconcileMessage(newer);
      final newerState = store.state;
      pending.complete(lateResponse);
      await future;

      expect(store.state, same(newerState));
      expect(store.state.canonicalMessages[_messageId], same(newer));

      await client.dispose();
      await store.close();
    }
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
      generateIdempotencyKey: generateIdempotencyKey ?? () => 'delete-key',
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
          'reactions': <Object?>[],
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

ActiveMessage _activeMessage({
  MessageId messageId = _messageId,
  int revision = 1,
  String text = 'delete me',
}) =>
    ActiveMessage(
      id: messageId,
      tenantId: const TenantId('tenant-1'),
      conversationId: _conversationId,
      author: const MessageAuthorIdentity(userId: UserId('user-1')),
      sequence: const MessageSequence(7),
      createdAt: const IsoTimestamp('2026-08-26T15:00:00.000Z'),
      updatedAt: IsoTimestamp('2026-08-26T15:00:0$revision.000Z'),
      revision: MessageRevisionMetadata(
        revision: revision,
        editedAt: revision == 1
            ? null
            : IsoTimestamp('2026-08-26T15:00:0$revision.000Z'),
        editedByUserId: revision == 1 ? null : const UserId('user-2'),
      ),
      content: MessageContent(
        format: MessageContentFormat.plain,
        text: text,
      ),
    );

DeletedMessage _deletedMessage({
  MessageId messageId = _messageId,
  required int revision,
}) =>
    DeletedMessage(
      id: messageId,
      tenantId: const TenantId('tenant-1'),
      conversationId: _conversationId,
      author: const MessageAuthorIdentity(userId: UserId('user-1')),
      sequence: const MessageSequence(7),
      createdAt: const IsoTimestamp('2026-08-26T15:00:00.000Z'),
      updatedAt: IsoTimestamp('2026-08-26T15:00:0$revision.000Z'),
      revision: MessageRevisionMetadata(revision: revision),
      content: null,
      deletedAt: IsoTimestamp('2026-08-26T15:00:0$revision.000Z'),
      deletedByUserId: const UserId('user-2'),
    );

HandrailChatHttpResponse _deleteResponse(
  String reconciliationStatus,
  Message message, {
  int statusCode = 200,
}) =>
    HandrailChatHttpResponse(
      statusCode: statusCode,
      body: jsonEncode(<String, Object?>{
        'operation': 'soft_delete',
        'reconciliationStatus': reconciliationStatus,
        'expectedRevision': 1,
        'message': message.toJson(),
        'canonicalRevision': message.revision.revision,
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
