import 'dart:async';
import 'dart:collection';
import 'dart:convert';

import 'package:handrail_chat/core.dart';
import 'package:handrail_chat/testing.dart'
    show
        FakeChatRealtimeNetwork,
        FakeChatRealtimeSocket,
        FakeChatRealtimeSocketFactory,
        InMemoryApplicationChatStorage;
import 'package:test/test.dart';

void main() {
  group('persisted send-message queue pump', () {
    for (final destination in ['channel-1', 'thread-1']) {
      for (final notifyAuthor in [true, false]) {
        test(
            'replays $destination reply unchanged after restart, style switch '
            'and retry (notifyAuthor=$notifyAuthor)', () async {
          // Host composition choices model a style switch; the queue has no
          // preference runtime and must only use the already captured request.
          var style = 'discord';
          var activeConversation = destination;
          ChatSendMessageInput compose() => ChatSendMessageInput(
                conversationId: ConversationId(style == 'current'
                    ? 'new-thread-for-current-style'
                    : activeConversation),
                content: MessageContent(
                    format: MessageContentFormat.markdown, text: 'Friday'),
                replyTo: style == 'discord'
                    ? MessageReplyReference(
                        messageId: const MessageId('source-message'),
                        notifyAuthor: notifyAuthor,
                      )
                    : null,
              );
          final originalInput = compose();
          final originalStorage = InMemoryApplicationChatStorage();
          await _persist(originalStorage,
              ids: ['client-reply'],
              keys: ['key-reply'],
              inputs: [originalInput]);
          final encoded = (await originalStorage.readEncoded(_identity,
              ApplicationChatStorageRecordKind.queuedSendMessageIntents))!;
          final storage = InMemoryApplicationChatStorage();
          storage.putRawRecordForTesting(
              _identity,
              ApplicationChatStorageRecordKind.queuedSendMessageIntents,
              jsonDecode(encoded));
          final waits = _ManualRetryWait();
          final pending = Completer<HandrailChatHttpResponse>();
          final fixture = _RestartFixture(
              storage: storage,
              online: false,
              retryBackoff: (_) => const Duration(milliseconds: 10),
              retryWait: waits.call)
            ..http.enqueuePost((_) async => throw StateError('transport down'))
            ..http.enqueuePost((_) => pending.future);
          addTearDown(fixture.dispose);
          await fixture.client.activateStorageIdentity(_identity);
          style = 'current';
          activeConversation = 'another-channel';
          expect(compose().replyTo, isNull);
          expect(compose().conversationId, isNot(originalInput.conversationId));
          expect(fixture.http.posts, isEmpty);
          fixture.network.setOnline(true);
          await fixture.initializeAndConnect();
          await _pumpUntil(() => waits.delays.length == 1);
          final expected = SendMessageRequest(
            conversationId: originalInput.conversationId,
            content: originalInput.content,
            replyTo: originalInput.replyTo,
            clientMessageId: 'client-reply',
            idempotencyKey: 'key-reply',
          ).toJson();
          expect(fixture.client.queuedSendMessages.single.request.toJson(),
              expected);
          expect(
              await storage.readEncoded(_identity,
                  ApplicationChatStorageRecordKind.queuedSendMessageIntents),
              encoded);
          await fixture.client.initialize();
          await fixture.client.activateStorageIdentity(_identity);
          fixture.network.setOnline(true);
          await _pump();
          expect(fixture.http.posts, hasLength(1));
          waits.release(0);
          await _pumpUntil(() => fixture.http.posts.length == 2);
          await fixture.client.initialize();
          await fixture.client.activateStorageIdentity(_identity);
          await _pump();
          expect(fixture.http.posts, hasLength(2));
          for (final request in fixture.http.posts) {
            expect(request.uri.path, endsWith('/messages'));
            expect(jsonDecode(request.body!), expected);
            expect(request.headers['Idempotency-Key'], 'key-reply');
          }
          pending.complete(_sendResponse('client-reply', 1,
              reconciliationStatus: 'replayed',
              conversationId: destination,
              replyTo: originalInput.replyTo));
          await _pumpUntil(() => fixture.client.queuedSendMessages.isEmpty);
          await fixture.client.initialize();
          await fixture.client.activateStorageIdentity(_identity);
          await _pump();
          expect(fixture.http.posts, hasLength(2),
              reason:
                  'one logical request, two attempts, no readiness duplicates');
          expect(fixture.store.state.canonicalMessages, hasLength(1));
          final canonical = fixture.store.state.canonicalMessages.values.single;
          expect(canonical.conversationId, originalInput.conversationId);
          expect(canonical.replyTo?.toJson(), originalInput.replyTo!.toJson());
          expect(
              await storage.readEncoded(_identity,
                  ApplicationChatStorageRecordKind.queuedSendMessageIntents),
              isNull);
        });
      }
    }

    test(
        'gates on hydration, metadata, connectivity, and realtime then '
        'flushes FIFO once with restart-stable IDs', () async {
      final storage = InMemoryApplicationChatStorage();
      await _persist(
        storage,
        ids: const ['client-a', 'client-b', 'client-c'],
        keys: const ['key-a', 'key-b', 'key-c'],
      );
      final first = Completer<HandrailChatHttpResponse>();
      final fixture = _RestartFixture(storage: storage, online: false)
        ..http.enqueuePost((_) => first.future)
        ..http.enqueuePost((_) async =>
            _sendResponse('client-b', 2, reconciliationStatus: 'replayed'))
        ..http.enqueuePost((_) async => _sendResponse('client-c', 3));

      await fixture.client.activateStorageIdentity(_identity);
      expect(fixture.http.posts, isEmpty,
          reason: 'hydration alone is not a dispatch gate');

      await fixture.session.start();
      expect(fixture.http.posts, isEmpty);
      fixture.network.setOnline(true);
      await _pumpUntil(() => fixture.socketFactory.uris.length == 1);
      fixture.socket.emitJson(_acceptedFrame());
      await _pump();
      expect(fixture.http.posts, isEmpty,
          reason: 'metadata must be ready after realtime recovery');

      expect(await fixture.client.initialize(), isA<ChatClientReadyState>());
      await _pumpUntil(() => fixture.http.posts.length == 1);
      await fixture.client.initialize();
      await fixture.client.activateStorageIdentity(_identity);
      await fixture.client.activateStorageIdentity(_identity);
      await _pump();
      expect(fixture.http.posts, hasLength(1),
          reason: 'equivalent ready signals must share one active pump');

      first.complete(_sendResponse('client-a', 1));
      await _pumpUntil(() => fixture.client.queuedSendMessages.isEmpty);

      expect(
        fixture.http.posts.map(_clientMessageIdFromRequest),
        const ['client-a', 'client-b', 'client-c'],
      );
      expect(
        fixture.http.posts.map((request) => request.headers['Idempotency-Key']),
        const ['key-a', 'key-b', 'key-c'],
      );
      expect(
        fixture.http.posts
            .map((request) =>
                (jsonDecode(request.body!) as Map<String, Object?>)['content'])
            .map((content) => (content as Map<String, Object?>)['text']),
        const ['message-a', 'message-b', 'message-c'],
      );
      expect(fixture.store.state.canonicalMessages, hasLength(3));
      expect(
        fixture.store
            .timeline(const ConversationId('conversation-1'))
            .messageIds,
        const [
          MessageId('message-1'),
          MessageId('message-2'),
          MessageId('message-3')
        ],
      );
      expect(
        await storage.read(
          _identity,
          ApplicationChatStorageRecordKind.queuedSendMessageIntents,
        ),
        isNull,
      );
      await fixture.dispose();
    });

    test('settles matching realtime events before and after HTTP exactly once',
        () async {
      final storage = _TrackingStorage(InMemoryApplicationChatStorage());
      await _persist(
        storage,
        ids: const ['client-a', 'client-b'],
        keys: const ['key-a', 'key-b'],
      );
      final first = Completer<HandrailChatHttpResponse>();
      final second = Completer<HandrailChatHttpResponse>();
      final store = _seedConversationStore();
      var timelineEmissions = 0;
      final timelineSubscription = store
          .watchTimeline(const ConversationId('conversation-1'))
          .listen((_) => timelineEmissions += 1);
      final fixture = _RestartFixture(
        storage: storage,
        normalizedState: store,
      )
        ..http.enqueuePost((_) => first.future)
        ..http.enqueuePost((_) => second.future);

      await fixture.initializeAndConnect();
      await _pumpUntil(() => fixture.http.posts.length == 1);
      fixture.socket.emitJson(_messageCreatedEvent('event-1', 'client-a', 1));
      await _pumpUntil(() => fixture.http.posts.length == 2);
      first.complete(_sendResponse('client-a', 1));

      second.complete(_sendResponse('client-b', 2));
      await _pumpUntil(() => fixture.client.queuedSendMessages.isEmpty);
      fixture.socket.emitJson(_messageCreatedEvent('event-2', 'client-b', 2));
      await _pump();

      expect(store.state.canonicalMessages, hasLength(2));
      expect(
        store.timeline(const ConversationId('conversation-1')).messageIds,
        const [MessageId('message-1'), MessageId('message-2')],
      );
      expect(timelineEmissions, 2);
      expect(storage.removeCount, 1,
          reason: 'only the final durable queue record is removed');
      expect(
        await storage.read(
          _identity,
          ApplicationChatStorageRecordKind.queuedSendMessageIntents,
        ),
        isNull,
      );

      await timelineSubscription.cancel();
      await fixture.dispose();
      await store.close();
    });

    for (final mismatch in [
      (
        name: 'teammate in the same conversation',
        author: 'user-2',
        conversation: 'conversation-1',
        clientId: 'client-a'
      ),
      (
        name: 'teammate in another conversation',
        author: 'user-2',
        conversation: 'conversation-2',
        clientId: 'client-a'
      ),
      (
        name: 'own author in another conversation',
        author: 'user-1',
        conversation: 'conversation-2',
        clientId: 'client-a'
      ),
      (
        name: 'unmatched client ID',
        author: 'user-1',
        conversation: 'conversation-1',
        clientId: 'client-unmatched'
      ),
    ]) {
      test('ignores ${mismatch.name} before matching acknowledgement',
          () async {
        final storage = _TrackingStorage(InMemoryApplicationChatStorage());
        await _persist(storage,
            ids: const ['client-a', 'client-b'],
            keys: const ['key-a', 'key-b']);
        final first = Completer<HandrailChatHttpResponse>();
        final second = Completer<HandrailChatHttpResponse>();
        final store = _seedConversationStore();
        final fixture =
            _RestartFixture(storage: storage, normalizedState: store)
              ..http.enqueuePost((_) => first.future)
              ..http.enqueuePost((_) => second.future);
        addTearDown(store.close);
        addTearDown(fixture.dispose);
        final canonicalIds = <String>[];
        final subscription = fixture.session.canonicalEvents
            .listen((event) => canonicalIds.add(event.eventId));
        addTearDown(subscription.cancel);

        await fixture.initializeAndConnect();
        await _pumpUntil(() => fixture.http.posts.length == 1);
        final retained = await storage.read(_identity,
                ApplicationChatStorageRecordKind.queuedSendMessageIntents)
            as ApplicationChatQueuedSendMessageIntentsRecord;
        final writesBefore = storage.queueReplaceCount;
        final active = fixture.http.posts.first.cancellationSignal!
            as ChatCommandCancellationSignal;
        var cancellations = 0;
        final cancellationSubscription =
            active.onCancelled.listen((_) => cancellations += 1);
        addTearDown(cancellationSubscription.cancel);

        fixture.socket.emitJson(_messageCreatedEvent(
          'event-mismatch',
          mismatch.clientId,
          1,
          authorId: mismatch.author,
          conversationId: mismatch.conversation,
        ));
        await _pumpUntil(() => canonicalIds.contains('event-mismatch'));
        await _pump();
        expect(
            (await storage.read(_identity,
                    ApplicationChatStorageRecordKind.queuedSendMessageIntents))!
                .toJson(),
            retained.toJson());
        expect(
            fixture.client.queuedSendMessages
                .map((intent) => intent.clientMessageId),
            ['client-a', 'client-b']);
        expect(storage.queueReplaceCount, writesBefore);
        expect(storage.removeCount, 0);
        expect(active.isCancelled, isFalse);
        expect(cancellations, 0);
        expect(fixture.http.posts, hasLength(1));

        final matching = _messageCreatedEvent(
          'event-own',
          'client-a',
          mismatch.conversation == 'conversation-1' ? 2 : 1,
          messageId: 'message-own',
        );
        fixture.socket.emitJson(matching);
        await _pumpUntil(() => fixture.http.posts.length == 2);
        await _pump();
        final remaining = await storage.read(_identity,
                ApplicationChatStorageRecordKind.queuedSendMessageIntents)
            as ApplicationChatQueuedSendMessageIntentsRecord;
        expect(remaining.intents.map((intent) => intent.toJson()),
            [retained.intents.last.toJson()]);
        expect(storage.queueReplaceCount, writesBefore + 1);
        expect(storage.removeCount, 0);
        expect(cancellations, 1);
        final nextActive = fixture.http.posts.last.cancellationSignal!
            as ChatCommandCancellationSignal;
        expect(nextActive.isCancelled, isFalse);

        fixture.socket.emitJson(matching);
        first.complete(_sendResponse('client-a', 9));
        await _pump();
        expect(
            (await storage.read(_identity,
                    ApplicationChatStorageRecordKind.queuedSendMessageIntents))!
                .toJson(),
            remaining.toJson());
        expect(storage.queueReplaceCount, writesBefore + 1);
        expect(storage.removeCount, 0);
        expect(cancellations, 1);
        expect(nextActive.isCancelled, isFalse);
        expect(fixture.http.posts, hasLength(2));
        expect(
            store.state.canonicalMessages
                .containsKey(const MessageId('message-9')),
            isFalse,
            reason: 'late HTTP completion cannot reconcile again');
      });
    }

    test('auth and transport failures retain FIFO state across manual backoff',
        () async {
      final storage = InMemoryApplicationChatStorage();
      await _persist(storage, ids: const ['client-a'], keys: const ['key-a']);
      final waits = _ManualRetryWait();
      var tokenCalls = 0;
      final fixture = _RestartFixture(
        storage: storage,
        tokenProvider: () async {
          tokenCalls += 1;
          if (tokenCalls == 2) throw StateError('refresh credentials');
          return 'access-token';
        },
        retryBackoff: (retry) => Duration(milliseconds: retry * 10),
        retryWait: waits.call,
      )
        ..http.enqueuePost((_) async => throw StateError('transport down'))
        ..http.enqueuePost((_) async => _sendResponse('client-a', 1));

      await fixture.initializeAndConnect();
      await _pumpUntil(() => waits.delays.length == 1);
      expect(waits.delays, const [Duration(milliseconds: 10)]);
      expect(fixture.http.posts, isEmpty);
      expect(fixture.client.queuedSendMessages, hasLength(1));

      waits.release(0);
      await _pumpUntil(() => waits.delays.length == 2);
      expect(waits.delays.last, const Duration(milliseconds: 20));
      expect(fixture.http.posts, hasLength(1));
      expect(fixture.client.queuedSendMessages, hasLength(1));

      waits.release(1);
      await _pumpUntil(() => fixture.client.queuedSendMessages.isEmpty);
      expect(fixture.http.posts, hasLength(2));
      expect(
        fixture.http.posts.map(_clientMessageIdFromRequest),
        everyElement('client-a'),
      );
      expect(
        fixture.http.posts.map((request) => request.headers['Idempotency-Key']),
        everyElement('key-a'),
      );
      await fixture.dispose();
    });

    test('removes terminal rejection and stops subsequent dispatch offline',
        () async {
      final storage = InMemoryApplicationChatStorage();
      await _persist(
        storage,
        ids: const ['client-a', 'client-b', 'client-c'],
        keys: const ['key-a', 'key-b', 'key-c'],
      );
      final interrupted = Completer<HandrailChatHttpResponse>();
      final fixture = _RestartFixture(storage: storage)
        ..http.enqueuePost((_) async => _rejectedResponse())
        ..http.enqueuePost((_) => interrupted.future)
        ..http.enqueuePost((_) async => _sendResponse('client-b', 2))
        ..http.enqueuePost((_) async => _sendResponse('client-c', 3));

      await fixture.initializeAndConnect();
      await _pumpUntil(() => fixture.http.posts.length == 2);
      fixture.network.setOnline(false);
      await _pumpUntil(() => fixture.session.state is ChatRealtimeOfflineState);
      await _pump();

      expect(fixture.http.posts, hasLength(2));
      expect(
        fixture.client.queuedSendMessages
            .map((intent) => intent.clientMessageId),
        const ['client-b', 'client-c'],
      );

      fixture.useFreshSocket();
      fixture.network.setOnline(true);
      await _pumpUntil(() => fixture.socketFactory.uris.length == 2);
      fixture.socket.emitJson(_acceptedFrame(sessionId: 'session-2'));
      await _pumpUntil(() => fixture.client.queuedSendMessages.isEmpty);
      interrupted.complete(_sendResponse('client-b', 2));

      expect(
        fixture.http.posts.map(_clientMessageIdFromRequest),
        const ['client-a', 'client-b', 'client-b', 'client-c'],
      );
      await fixture.dispose();
    });

    test('close preserves in-flight and remaining intents for restart',
        () async {
      final storage = InMemoryApplicationChatStorage();
      await _persist(
        storage,
        ids: const ['client-a', 'client-b'],
        keys: const ['key-a', 'key-b'],
      );
      final pending = Completer<HandrailChatHttpResponse>();
      final closing = _RestartFixture(storage: storage)
        ..http.enqueuePost((_) => pending.future);
      await closing.initializeAndConnect();
      await _pumpUntil(() => closing.http.posts.length == 1);

      await closing.client.dispose();
      final preserved = await storage.read(
        _identity,
        ApplicationChatStorageRecordKind.queuedSendMessageIntents,
      ) as ApplicationChatQueuedSendMessageIntentsRecord;
      expect(
        preserved.intents.map((intent) => intent.request.clientMessageId),
        const ['client-a', 'client-b'],
      );
      await closing.dispose();

      final restarted = _RestartFixture(storage: storage)
        ..http.enqueuePost((_) async => _sendResponse('client-a', 1))
        ..http.enqueuePost((_) async => _sendResponse('client-b', 2));
      await restarted.initializeAndConnect();
      await _pumpUntil(() => restarted.client.queuedSendMessages.isEmpty);
      expect(
        restarted.http.posts.map(_clientMessageIdFromRequest),
        const ['client-a', 'client-b'],
      );
      await restarted.dispose();
    });
  });
}

final _identity = ApplicationChatStorageIdentity(
  tenantId: const TenantId('tenant-1'),
  userId: const UserId('user-1'),
  deviceId: const DeviceId('device-1'),
);

Future<void> _persist(
  ApplicationChatStorage storage, {
  required List<String> ids,
  required List<String> keys,
  List<ChatSendMessageInput>? inputs,
}) async {
  final network = FakeChatRealtimeNetwork(isOnline: false);
  final session = ChatRealtimeSessionTransport(
    endpoint: Uri.parse('https://chat.example.test/api/chat'),
    clientPackageVersion: '0.1.3',
    protocolVersion: handrailChatProtocolVersion,
    tokenProvider: () => 'realtime-token',
    socketFactory: (_, __) => throw StateError('offline'),
    network: network,
  );
  var idIndex = 0;
  var keyIndex = 0;
  final client = HandrailChatClient(
    apiBaseUri: Uri.parse('https://chat.example.test/api/chat'),
    tokenProvider: () async => 'access-token',
    transport: _PumpHttpTransport(),
    realtimeSession: session,
    localStorage: storage,
    storageIdentity: _identity,
    generateClientMessageId: () => ids[idIndex++],
    generateIdempotencyKey: () => keys[keyIndex++],
  );
  for (var index = 0; index < ids.length; index += 1) {
    final result = await client.sendMessage(
      inputs?[index] ??
          ChatSendMessageInput(
            conversationId: const ConversationId('conversation-1'),
            content: MessageContent(
              format: MessageContentFormat.markdown,
              text: 'message-${String.fromCharCode(97 + index)}',
            ),
          ),
    );
    expect(result, isA<ChatCommandQueued<SendMessageResult>>());
  }
  await client.dispose();
  await session.dispose();
  await network.dispose();
}

final class _RestartFixture {
  _RestartFixture({
    required ApplicationChatStorage storage,
    bool online = true,
    NormalizedSnapshotStore? normalizedState,
    HandrailChatAccessTokenProvider? tokenProvider,
    ChatOfflineSendRetryBackoff? retryBackoff,
    ChatOfflineSendRetryWait? retryWait,
  })  : network = FakeChatRealtimeNetwork(isOnline: online),
        store = normalizedState ?? NormalizedSnapshotStore(),
        _ownsStore = normalizedState == null {
    socketFactory.enqueueSocket(socket);
    session = ChatRealtimeSessionTransport(
      endpoint: Uri.parse('https://chat.example.test/api/chat'),
      clientPackageVersion: '0.1.3',
      protocolVersion: handrailChatProtocolVersion,
      tokenProvider: () => 'realtime-token',
      socketFactory: socketFactory.call,
      network: network,
    );
    client = HandrailChatClient(
      apiBaseUri: Uri.parse('https://chat.example.test/api/chat'),
      tokenProvider: tokenProvider ?? () async => 'access-token',
      transport: http,
      commandRetryOptions: const ChatCommandRetryOptions(
        maxAttempts: 1,
        maxAuthenticationRefreshes: 0,
      ),
      realtimeSession: session,
      localStorage: storage,
      storageIdentity: _identity,
      normalizedSnapshotStore: store,
      generateClientMessageId: () => 'must-not-regenerate-client-id',
      generateIdempotencyKey: () => 'must-not-regenerate-key',
      offlineSendRetryBackoff: retryBackoff,
      offlineSendRetryWait: retryWait,
    );
  }

  final FakeChatRealtimeNetwork network;
  final _PumpHttpTransport http = _PumpHttpTransport();
  final FakeChatRealtimeSocketFactory socketFactory =
      FakeChatRealtimeSocketFactory();
  final NormalizedSnapshotStore store;
  final bool _ownsStore;
  late FakeChatRealtimeSocket socket = FakeChatRealtimeSocket();
  late final ChatRealtimeSessionTransport session;
  late final HandrailChatClient client;

  Future<void> initializeAndConnect() async {
    expect(await client.initialize(), isA<ChatClientReadyState>());
    await session.start();
    await _pumpUntil(() => socketFactory.uris.isNotEmpty);
    socket.emitJson(_acceptedFrame());
    await _pumpUntil(() => session.state is ChatRealtimeConnectedState);
  }

  void useFreshSocket() {
    socket = FakeChatRealtimeSocket();
    socketFactory.enqueueSocket(socket);
  }

  Future<void> dispose() async {
    await client.dispose();
    await session.dispose();
    await network.dispose();
    if (_ownsStore) await store.close();
  }
}

final class _PumpHttpTransport implements HandrailChatHttpTransport {
  final Queue<
          Future<HandrailChatHttpResponse> Function(HandrailChatHttpRequest)>
      _postHandlers = Queue();
  final List<HandrailChatHttpRequest> requests = [];

  Iterable<HandrailChatHttpRequest> get posts =>
      requests.where((request) => request.method == 'POST');

  void enqueuePost(
    Future<HandrailChatHttpResponse> Function(HandrailChatHttpRequest) handler,
  ) =>
      _postHandlers.add(handler);

  @override
  Future<HandrailChatHttpResponse> send(HandrailChatHttpRequest request) {
    requests.add(request);
    if (request.method == 'GET') {
      return Future.value(HandrailChatHttpResponse(
        statusCode: 200,
        body: jsonEncode(_metadata),
      ));
    }
    if (_postHandlers.isEmpty) {
      return Future.error(StateError('No scripted POST response remains.'));
    }
    return _postHandlers.removeFirst()(request);
  }
}

final class _ManualRetryWait {
  final List<Duration> delays = [];
  final List<Completer<void>> _completers = [];

  Future<void> call(
    Duration delay,
    ChatCommandCancellationSignal _,
  ) {
    delays.add(delay);
    final completer = Completer<void>();
    _completers.add(completer);
    return completer.future;
  }

  void release(int index) => _completers[index].complete();
}

final class _TrackingStorage implements ApplicationChatStorage {
  _TrackingStorage(this.backing);

  final InMemoryApplicationChatStorage backing;
  var removeCount = 0;
  var queueReplaceCount = 0;

  @override
  Future<ApplicationChatStorageRecord?> read(
    ApplicationChatStorageIdentity identity,
    ApplicationChatStorageRecordKind kind,
  ) =>
      backing.read(identity, kind);

  @override
  Future<void> replace(ApplicationChatStorageRecord record) {
    if (record is ApplicationChatQueuedSendMessageIntentsRecord) {
      queueReplaceCount += 1;
    }
    return backing.replace(record);
  }

  @override
  Future<void> remove(
    ApplicationChatStorageIdentity identity,
    ApplicationChatStorageRecordKind kind,
  ) {
    if (kind == ApplicationChatStorageRecordKind.queuedSendMessageIntents) {
      removeCount += 1;
    }
    return backing.remove(identity, kind);
  }

  @override
  Future<void> clearForLogout(
    ApplicationChatStorageIdentity previousIdentity,
  ) =>
      backing.clearForLogout(previousIdentity);

  @override
  Future<void> clearForIdentityChange({
    required ApplicationChatStorageIdentity previousIdentity,
    required ApplicationChatStorageIdentity nextIdentity,
  }) =>
      backing.clearForIdentityChange(
        previousIdentity: previousIdentity,
        nextIdentity: nextIdentity,
      );
}

NormalizedSnapshotStore _seedConversationStore() {
  final store = NormalizedSnapshotStore();
  store.hydrateConversationList(ConversationListSnapshot.fromJson({
    'kind': 'conversation_list',
    'scope': const OrganizationConversationSnapshotScope().toJson(),
    'items': [
      for (final conversationId in ['conversation-1', 'conversation-2'])
        {
          'id': conversationId,
          'tenantId': 'tenant-1',
          'type': 'channel',
          'name': 'Queue pump',
          'visibility': 'public',
          'createdAt': '2026-08-26T15:00:00.000Z',
          'updatedAt': '2026-08-26T15:00:00.000Z',
          'latestSequence': 0,
          'activityAt': '2026-08-26T15:00:00.000Z',
          'unreadMentionCount': 0,
          'currentMember': {
            'tenantId': 'tenant-1',
            'conversationId': conversationId,
            'userId': 'user-1',
            'role': 'member',
            'state': 'active',
            'joinedAt': '2026-08-26T15:00:00.000Z',
            'updatedAt': '2026-08-26T15:00:00.000Z',
          },
          'currentReadState': {
            'conversationId': conversationId,
            'userId': 'user-1',
            'lastReadSequence': 0,
            'updatedAt': '2026-08-26T15:00:00.000Z',
          },
          'currentPreference': {
            'conversationId': conversationId,
            'userId': 'user-1',
            'notificationPreference': 'mentions',
            'isStarred': false,
            'mute': {'muted': false},
            'updatedAt': '2026-08-26T15:00:00.000Z',
          },
          'activeMemberUserIds': ['user-1', 'user-2'],
        },
    ],
    'page': <String, Object?>{},
    '_meta': {
      ..._metadata,
      'enabledFeatures': {
        'realtime': true,
        conversationSnapshotFeature: true,
      },
      'feature': {
        'name': conversationSnapshotFeature,
        'version': conversationSnapshotVersion,
      },
    },
  }));
  return store;
}

HandrailChatHttpResponse _sendResponse(
  String clientMessageId,
  int sequence, {
  String reconciliationStatus = 'applied',
  String conversationId = 'conversation-1',
  MessageReplyReference? replyTo,
}) =>
    HandrailChatHttpResponse(
      statusCode: 200,
      body: jsonEncode({
        'operation': 'send',
        'reconciliationStatus': reconciliationStatus,
        'clientMessageId': clientMessageId,
        'message': {
          ..._message(sequence),
          'conversationId': conversationId,
          if (replyTo != null) 'replyTo': replyTo.toJson(),
        },
        'canonicalRevision': 1,
      }),
    );

HandrailChatHttpResponse _rejectedResponse() => HandrailChatHttpResponse(
      statusCode: 422,
      body: jsonEncode({
        'error': {'code': 'INVALID_MESSAGE', 'message': 'Rejected'},
      }),
    );

Map<String, Object?> _message(int sequence) => {
      'id': 'message-$sequence',
      'tenantId': 'tenant-1',
      'conversationId': 'conversation-1',
      'author': {'type': 'user', 'userId': 'user-1'},
      'sequence': sequence,
      'createdAt':
          '2026-08-26T15:00:${sequence.toString().padLeft(2, '0')}.000Z',
      'updatedAt':
          '2026-08-26T15:00:${sequence.toString().padLeft(2, '0')}.000Z',
      'revision': {'revision': 1},
      'content': {
        'format': 'markdown',
        'text': 'message-${String.fromCharCode(96 + sequence)}',
      },
    };

Map<String, Object?> _messageCreatedEvent(
  String eventId,
  String clientMessageId,
  int sequence, {
  String authorId = 'user-1',
  String conversationId = 'conversation-1',
  String? messageId,
}) =>
    {
      'eventId': eventId,
      'protocolVersion': handrailChatProtocolVersion,
      'tenantId': 'tenant-1',
      'streamId': conversationId,
      'type': 'message.created',
      'occurredAt':
          '2026-08-26T15:01:${sequence.toString().padLeft(2, '0')}.000Z',
      'payload': {
        'message': {
          ..._message(sequence),
          if (messageId != null) 'id': messageId,
          'conversationId': conversationId,
          'author': {'type': 'user', 'userId': authorId},
        },
        'clientMessageId': clientMessageId,
      },
    };

String _clientMessageIdFromRequest(HandrailChatHttpRequest request) =>
    (jsonDecode(request.body!) as Map<String, Object?>)['clientMessageId']!
        as String;

Map<String, Object?> _acceptedFrame({String sessionId = 'session-1'}) => {
      'type': 'chat.session.accepted',
      'metadata': _metadata,
      'tenantId': 'tenant-1',
      'actorStreamId': 'user:user-1',
      'deviceId': 'device-1',
      'sessionId': sessionId,
    };

const Map<String, Object?> _metadata = {
  'packageVersion': '0.1.3',
  'protocolVersion': handrailChatProtocolVersion,
  'schemaVersion': 1,
  'enabledFeatures': <String, Object?>{'realtime': true},
  'supportedProtocolRange': <String, Object?>{
    'minimumVersion': 3,
    'maximumVersion': handrailChatProtocolVersion,
  },
};

Future<void> _pump([int times = 16]) async {
  for (var index = 0; index < times; index += 1) {
    await Future<void>.delayed(Duration.zero);
  }
}

Future<void> _pumpUntil(bool Function() condition) async {
  for (var index = 0; index < 200; index += 1) {
    if (condition()) return;
    await Future<void>.delayed(Duration.zero);
  }
  throw StateError('The expected asynchronous state was not reached.');
}
