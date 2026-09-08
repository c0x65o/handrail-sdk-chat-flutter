import 'dart:async';
import 'dart:convert';

import 'package:handrail_chat/core.dart';
import 'package:test/test.dart';

const _conversationId = ConversationId('conversation-1');
const _messageId = MessageId('message-1');

void main() {
  test('encodes both path components and sends explicit add/remove bodies',
      () async {
    const messageId = MessageId('message /?#');
    const reactionKey = 'party /?#';
    final store = _store(
      messageId: messageId,
      reactions: const [
        MessageReactionAggregate(
          reactionKey: reactionKey,
          count: 2,
          reactedByCurrentUser: false,
        ),
        MessageReactionAggregate(
          reactionKey: 'unrelated',
          count: 7,
          reactedByCurrentUser: true,
        ),
      ],
    );
    final transport = _RecordingTransport((request) async {
      final body = jsonDecode(request.body!) as Map<String, Object?>;
      final adding = body['operation'] == 'add_reaction';
      return _reactionResponse(
        operation: body['operation']! as String,
        status: 'applied',
        messageId: messageId,
        reactionKey: reactionKey,
        count: adding ? 3 : 2,
        reactedByCurrentUser: adding,
      );
    });
    final client = _client(store, transport);

    final add = await client.setReaction(
      const ChatSetReactionInput(
        messageId: messageId,
        reactionKey: reactionKey,
        reactedByCurrentUser: true,
        idempotencyKey: 'add-key',
      ),
    );
    final remove = await client.setReaction(
      const ChatSetReactionInput(
        messageId: messageId,
        reactionKey: reactionKey,
        reactedByCurrentUser: false,
        idempotencyKey: 'remove-key',
      ),
    );

    expect(add, isA<ChatCommandSuccess<ReactionMutationResult>>());
    expect(remove, isA<ChatCommandSuccess<ReactionMutationResult>>());
    expect(transport.requests, hasLength(2));
    expect(
      transport.requests.map((request) => request.uri.toString()),
      everyElement(
        'https://chat.example.test/api/chat/messages/'
        'message%20%2F%3F%23/reactions/party%20%2F%3F%23',
      ),
    );
    expect(transport.requests.map((request) => request.method),
        everyElement('PATCH'));
    expect(jsonDecode(transport.requests[0].body!), {
      'operation': 'add_reaction',
      'messageId': messageId.value,
      'reactionKey': reactionKey,
      'idempotencyKey': 'add-key',
    });
    expect(jsonDecode(transport.requests[1].body!), {
      'operation': 'remove_reaction',
      'messageId': messageId.value,
      'reactionKey': reactionKey,
      'idempotencyKey': 'remove-key',
    });
    expect(_aggregate(store, reactionKey)?.count, 2);
    expect(_aggregate(store, reactionKey)?.reactedByCurrentUser, isFalse);
    expect(_aggregate(store, 'unrelated')?.toJson(), {
      'reactionKey': 'unrelated',
      'count': 7,
      'reactedByCurrentUser': true,
    });

    await client.dispose();
    await store.close();
  });

  test('uses one generated idempotency key and body across safe retries',
      () async {
    final store = _store();
    var keyCalls = 0;
    var attempts = 0;
    final transport = _RecordingTransport((_) async {
      attempts += 1;
      if (attempts == 1) throw StateError('offline');
      return _reactionResponse(
        operation: 'add_reaction',
        status: 'replayed',
        count: 1,
        reactedByCurrentUser: true,
      );
    });
    final client = _client(
      store,
      transport,
      generateIdempotencyKey: () {
        keyCalls += 1;
        return 'stable-reaction-key';
      },
      retryOptions: ChatCommandRetryOptions(
        maxAttempts: 2,
        backoff: (_) => Duration.zero,
        wait: (_, __) async {},
      ),
    );

    final result = await client.setReaction(
      const ChatSetReactionInput(
        messageId: _messageId,
        reactionKey: 'thumbsup',
        reactedByCurrentUser: true,
      ),
    );

    expect(result, isA<ChatCommandSuccess<ReactionMutationResult>>());
    expect(keyCalls, 1);
    expect(transport.requests, hasLength(2));
    expect(transport.requests[0].body, transport.requests[1].body);
    expect(
      transport.requests
          .map((request) => request.headers['Idempotency-Key'])
          .toSet(),
      {'stable-reaction-key'},
    );

    await client.dispose();
    await store.close();
  });

  test('serializes one key while unrelated keys dispatch independently',
      () async {
    final store = _store();
    final responses = <String, Completer<HandrailChatHttpResponse>>{};
    final transport = _RecordingTransport((request) {
      final body = jsonDecode(request.body!) as Map<String, Object?>;
      final key = body['idempotencyKey']! as String;
      return (responses[key] = Completer<HandrailChatHttpResponse>()).future;
    });
    final client = _client(store, transport);

    final first = client.setReaction(
      const ChatSetReactionInput(
        messageId: _messageId,
        reactionKey: 'thumbsup',
        reactedByCurrentUser: true,
        idempotencyKey: 'same-1',
      ),
    );
    final second = client.setReaction(
      const ChatSetReactionInput(
        messageId: _messageId,
        reactionKey: 'thumbsup',
        reactedByCurrentUser: false,
        idempotencyKey: 'same-2',
      ),
    );
    final other = client.setReaction(
      const ChatSetReactionInput(
        messageId: _messageId,
        reactionKey: 'heart',
        reactedByCurrentUser: true,
        idempotencyKey: 'other-1',
      ),
    );
    await _eventLoop();

    expect(transport.requests, hasLength(2));
    expect(responses.keys, containsAll(<String>['same-1', 'other-1']));
    expect(responses, isNot(contains('same-2')));
    expect(_aggregate(store, 'thumbsup'), isNull,
        reason: 'the latest queued remove remains projected');
    expect(_aggregate(store, 'heart')?.reactedByCurrentUser, isTrue);

    responses['same-1']!.complete(_reactionResponse(
      operation: 'add_reaction',
      status: 'applied',
      count: 1,
      reactedByCurrentUser: true,
    ));
    await _eventLoop();
    expect(responses, contains('same-2'));
    expect(transport.requests, hasLength(3));
    expect(_aggregate(store, 'thumbsup'), isNull,
        reason: 'authoritative add must not overwrite queued remove');

    responses['same-2']!.complete(_reactionResponse(
      operation: 'remove_reaction',
      status: 'replayed',
      count: 0,
      reactedByCurrentUser: false,
    ));
    responses['other-1']!.complete(_reactionResponse(
      operation: 'add_reaction',
      status: 'applied',
      reactionKey: 'heart',
      count: 1,
      reactedByCurrentUser: true,
    ));

    expect(await first, isA<ChatCommandSuccess<ReactionMutationResult>>());
    expect(await second, isA<ChatCommandSuccess<ReactionMutationResult>>());
    expect(await other, isA<ChatCommandSuccess<ReactionMutationResult>>());
    expect(_aggregate(store, 'thumbsup'), isNull);
    expect(_aggregate(store, 'heart')?.count, 1);

    await client.dispose();
    await store.close();
  });

  test('applied and replayed results install exact aggregates only once',
      () async {
    for (final status in ['applied', 'replayed']) {
      final store = _store(
        reactions: const [
          MessageReactionAggregate(
            reactionKey: 'thumbsup',
            count: 2,
            reactedByCurrentUser: false,
          ),
        ],
      );
      final client = _client(
        store,
        _RecordingTransport(
          (_) async => _reactionResponse(
            operation: 'add_reaction',
            status: status,
            count: 9,
            reactedByCurrentUser: true,
          ),
        ),
      );

      final result = await client.setReaction(
        ChatSetReactionInput(
          messageId: _messageId,
          reactionKey: 'thumbsup',
          reactedByCurrentUser: true,
          idempotencyKey: '$status-key',
        ),
      );
      final value =
          (result as ChatCommandSuccess<ReactionMutationResult>).value;
      final settled = store.state;
      store.reconcileOptimisticReaction('$status-key', value);

      expect(store.state, same(settled));
      expect(_aggregate(store, 'thumbsup')?.count, 9);
      expect(_aggregate(store, 'thumbsup')?.reactedByCurrentUser, isTrue);
      await client.dispose();
      await store.close();
    }
  });

  test('failure keeps a later intent and rolls back to newer snapshot state',
      () async {
    final store = _store(
      reactions: const [
        MessageReactionAggregate(
          reactionKey: 'thumbsup',
          count: 2,
          reactedByCurrentUser: false,
        ),
      ],
    );
    final firstResponse = Completer<HandrailChatHttpResponse>();
    final secondResponse = Completer<HandrailChatHttpResponse>();
    final transport = _RecordingTransport((request) {
      final body = jsonDecode(request.body!) as Map<String, Object?>;
      return body['idempotencyKey'] == 'first'
          ? firstResponse.future
          : secondResponse.future;
    });
    final client = _client(store, transport);
    final first = client.setReaction(
      const ChatSetReactionInput(
        messageId: _messageId,
        reactionKey: 'thumbsup',
        reactedByCurrentUser: true,
        idempotencyKey: 'first',
      ),
    );
    final later = client.setReaction(
      const ChatSetReactionInput(
        messageId: _messageId,
        reactionKey: 'thumbsup',
        reactedByCurrentUser: false,
        idempotencyKey: 'later',
      ),
    );

    expect(_aggregate(store, 'thumbsup')?.count, 2);
    expect(_aggregate(store, 'thumbsup')?.reactedByCurrentUser, isFalse);
    firstResponse.complete(_errorResponse(403, 'AUTHENTICATION_FAILED'));
    expect(await first,
        isA<ChatCommandAuthenticationFailure<ReactionMutationResult>>());
    expect(_aggregate(store, 'thumbsup')?.reactedByCurrentUser, isFalse);
    secondResponse.complete(_reactionResponse(
      operation: 'remove_reaction',
      status: 'applied',
      count: 2,
      reactedByCurrentUser: false,
    ));
    expect(await later, isA<ChatCommandSuccess<ReactionMutationResult>>());

    final pending = Completer<HandrailChatHttpResponse>();
    final newerClient = _client(
      store,
      _RecordingTransport((_) => pending.future),
    );
    final future = newerClient.setReaction(
      const ChatSetReactionInput(
        messageId: _messageId,
        reactionKey: 'thumbsup',
        reactedByCurrentUser: true,
        idempotencyKey: 'newer-snapshot',
      ),
    );
    await _eventLoop();
    store.hydrateMessageTimeline(
      _page(
        reactions: const [
          MessageReactionAggregate(
            reactionKey: 'thumbsup',
            count: 5,
            reactedByCurrentUser: false,
          ),
        ],
      ),
    );
    expect(_aggregate(store, 'thumbsup')?.count, 6);
    pending.complete(_errorResponse(403, 'AUTHENTICATION_FAILED'));
    expect(await future,
        isA<ChatCommandAuthenticationFailure<ReactionMutationResult>>());
    expect(_aggregate(store, 'thumbsup')?.count, 5);
    expect(_aggregate(store, 'thumbsup')?.reactedByCurrentUser, isFalse);

    await newerClient.dispose();
    await client.dispose();
    await store.close();
  });

  test('cancellation, client disposal, and store close clear projections',
      () async {
    final cancellationStore = _store();
    final cancellationPending = Completer<HandrailChatHttpResponse>();
    final cancellationClient = _client(
      cancellationStore,
      _RecordingTransport((_) => cancellationPending.future),
    );
    final cancellation = ChatCommandCancellationController();
    final cancelled = cancellationClient.setReaction(
      const ChatSetReactionInput(
        messageId: _messageId,
        reactionKey: 'thumbsup',
        reactedByCurrentUser: true,
      ),
      cancellationSignal: cancellation.signal,
    );
    await _eventLoop();
    cancellation.cancel();
    expect(await cancelled, isA<ChatCommandAborted<ReactionMutationResult>>());
    expect(_aggregate(cancellationStore, 'thumbsup'), isNull);
    await cancellationClient.dispose();
    await cancellationStore.close();

    final disposeStore = _store();
    final disposePending = Completer<HandrailChatHttpResponse>();
    final disposeClient = _client(
      disposeStore,
      _RecordingTransport((_) => disposePending.future),
    );
    final active = disposeClient.setReaction(
      const ChatSetReactionInput(
        messageId: _messageId,
        reactionKey: 'thumbsup',
        reactedByCurrentUser: true,
        idempotencyKey: 'active',
      ),
    );
    final queued = disposeClient.setReaction(
      const ChatSetReactionInput(
        messageId: _messageId,
        reactionKey: 'thumbsup',
        reactedByCurrentUser: false,
        idempotencyKey: 'queued',
      ),
    );
    await _eventLoop();
    await disposeClient.dispose();
    expect(await active, isA<ChatCommandClosed<ReactionMutationResult>>());
    expect(await queued, isA<ChatCommandClosed<ReactionMutationResult>>());
    expect(_aggregate(disposeStore, 'thumbsup'), isNull);
    await disposeStore.close();

    final closeStore = _store();
    closeStore.beginOptimisticReaction(
      AddReactionInput(
        messageId: _messageId,
        reactionKey: 'thumbsup',
        idempotencyKey: 'store-close',
      ),
    );
    expect(_aggregate(closeStore, 'thumbsup')?.count, 1);
    await closeStore.close();
    expect(_aggregate(closeStore, 'thumbsup'), isNull);
  });

  test('cancelling a queued intent does not wait or cancel the active intent',
      () async {
    final store = _store();
    final activeResponse = Completer<HandrailChatHttpResponse>();
    final transport = _RecordingTransport((_) => activeResponse.future);
    final client = _client(store, transport);
    final active = client.setReaction(
      const ChatSetReactionInput(
        messageId: _messageId,
        reactionKey: 'thumbsup',
        reactedByCurrentUser: true,
        idempotencyKey: 'active-add',
      ),
    );
    final cancellation = ChatCommandCancellationController();
    final queued = client.setReaction(
      const ChatSetReactionInput(
        messageId: _messageId,
        reactionKey: 'thumbsup',
        reactedByCurrentUser: false,
        idempotencyKey: 'queued-remove',
      ),
      cancellationSignal: cancellation.signal,
    );
    expect(_aggregate(store, 'thumbsup'), isNull);
    await _eventLoop();

    cancellation.cancel();

    expect(await queued, isA<ChatCommandAborted<ReactionMutationResult>>());
    expect(transport.requests, hasLength(1));
    expect(_aggregate(store, 'thumbsup')?.reactedByCurrentUser, isTrue);
    activeResponse.complete(_reactionResponse(
      operation: 'add_reaction',
      status: 'applied',
      count: 1,
      reactedByCurrentUser: true,
    ));
    expect(await active, isA<ChatCommandSuccess<ReactionMutationResult>>());

    await client.dispose();
    await store.close();
  });

  test('validates before authentication and transport', () async {
    final store = _store();
    var tokenCalls = 0;
    final transport = _RecordingTransport(
      (_) async => throw StateError('HTTP must not run'),
    );
    final client = _client(
      store,
      transport,
      tokenProvider: () async {
        tokenCalls += 1;
        return 'token';
      },
    );

    final malformed = await client.setReaction(
      const ChatSetReactionInput(
        messageId: _messageId,
        reactionKey: ' leading-space',
        reactedByCurrentUser: true,
      ),
    );
    final missing = await client.setReaction(
      const ChatSetReactionInput(
        messageId: MessageId('missing'),
        reactionKey: 'thumbsup',
        reactedByCurrentUser: true,
      ),
    );

    expect(
        malformed, isA<ChatCommandValidationFailure<ReactionMutationResult>>());
    expect(
        missing, isA<ChatCommandValidationFailure<ReactionMutationResult>>());
    expect(tokenCalls, 0);
    expect(transport.requests, isEmpty);
    expect(_aggregate(store, 'thumbsup'), isNull);

    await client.dispose();
    await store.close();
  });
}

HandrailChatClient _client(
  NormalizedSnapshotStore store,
  _RecordingTransport transport, {
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
      generateIdempotencyKey:
          generateIdempotencyKey ?? () => 'generated-reaction-key',
      commandRetryOptions: retryOptions,
    );

NormalizedSnapshotStore _store({
  MessageId messageId = _messageId,
  List<MessageReactionAggregate> reactions = const [],
}) =>
    NormalizedSnapshotStore()
      ..hydrateMessageTimeline(
        _page(messageId: messageId, reactions: reactions),
      );

MessageTimelinePage _page({
  MessageId messageId = _messageId,
  List<MessageReactionAggregate> reactions = const [],
}) {
  final request = MessageTimelineRequest(
    conversationId: _conversationId,
    direction: MessageTimelineDirection.backward,
    limit: 10,
  );
  return MessageTimelinePage.fromJson(
    <String, Object?>{
      'conversationId': _conversationId.toJson(),
      'messages': <Object?>[
        <String, Object?>{
          ..._message(messageId).toJson(),
          'isThreadRoot': false,
          'reactions': reactions.map((reaction) => reaction.toJson()).toList(),
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
}

ActiveMessage _message(MessageId messageId) => ActiveMessage(
      id: messageId,
      tenantId: const TenantId('tenant-1'),
      conversationId: _conversationId,
      author: const MessageAuthorIdentity(userId: UserId('user-1')),
      sequence: const MessageSequence(7),
      createdAt: const IsoTimestamp('2026-08-26T15:00:00.000Z'),
      updatedAt: const IsoTimestamp('2026-08-26T15:00:01.000Z'),
      revision: const MessageRevisionMetadata(revision: 1),
      content: MessageContent(
        format: MessageContentFormat.plain,
        text: 'message',
      ),
    );

MessageReactionAggregate? _aggregate(
  NormalizedSnapshotStore store,
  String reactionKey,
) {
  final reactions = store.state.messages[_messageId]?.reactions ??
      store.state.messages.values.single.reactions;
  for (final aggregate in reactions) {
    if (aggregate.reactionKey == reactionKey) return aggregate;
  }
  return null;
}

HandrailChatHttpResponse _reactionResponse({
  required String operation,
  required String status,
  MessageId messageId = _messageId,
  String reactionKey = 'thumbsup',
  required int count,
  required bool reactedByCurrentUser,
}) =>
    HandrailChatHttpResponse(
      statusCode: 200,
      body: jsonEncode(<String, Object?>{
        'operation': operation,
        'reconciliationStatus': status,
        'messageId': messageId.toJson(),
        'reactionKey': reactionKey,
        'count': count,
        'reactedByCurrentUser': reactedByCurrentUser,
      }),
    );

HandrailChatHttpResponse _errorResponse(int status, String code) =>
    HandrailChatHttpResponse(
      statusCode: status,
      body: jsonEncode(<String, Object?>{
        'error': <String, Object?>{
          'code': code,
          'message': 'request rejected',
        },
      }),
    );

Future<void> _eventLoop() => Future<void>.delayed(Duration.zero);

final class _RecordingTransport implements HandrailChatHttpTransport {
  _RecordingTransport(this.handler);

  final Future<HandrailChatHttpResponse> Function(HandrailChatHttpRequest)
      handler;
  final List<HandrailChatHttpRequest> requests = [];

  @override
  Future<HandrailChatHttpResponse> send(HandrailChatHttpRequest request) {
    requests.add(request);
    return handler(request);
  }
}
