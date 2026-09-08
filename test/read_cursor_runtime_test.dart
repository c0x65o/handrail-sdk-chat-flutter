import 'dart:async';
import 'dart:convert';

import 'package:handrail_chat/core.dart';
import 'package:test/test.dart';

const _tenantId = TenantId('tenant-1');
const _userId = UserId('user-1');
const _conversationOne = ConversationId('conversation-1');
const _conversationTwo = ConversationId('conversation-2');
const _initialTime = '2026-08-26T15:00:00.000Z';

void main() {
  group('read selectors', () {
    test('derive unread state, manual boundary, and hydration exactly', () {
      final manual = _store(
        [
          _summary(
            _conversationOne,
            latestSequence: 8,
            lastReadSequence: 6,
            manualUnreadFromSequence: 4,
          ),
        ],
      );

      expect(
        selectConversationUnreadCount(manual.state, _conversationOne),
        5,
      );
      expect(
        selectFirstUnreadSequence(manual.state, _conversationOne),
        const MessageSequence(4),
      );
      expect(
        selectManualUnreadFromSequence(manual.state, _conversationOne),
        const MessageSequence(4),
      );
      expect(
        selectFirstUnreadMessage(manual.state, _conversationOne),
        isNull,
        reason: 'an unhydrated first unread sequence stays unresolved',
      );

      manual.hydrateMessageTimeline(
        _timeline(_conversationOne, const [5, 6]),
      );
      expect(selectFirstUnreadMessage(manual.state, _conversationOne), isNull);
      manual.hydrateMessageTimeline(
        _timeline(_conversationOne, const [4]),
      );
      expect(
        selectFirstUnreadMessage(manual.state, _conversationOne)?.sequence,
        const MessageSequence(4),
      );

      final automatic = _store(
        [
          _summary(
            _conversationOne,
            latestSequence: 8,
            lastReadSequence: 6,
          ),
        ],
      );
      expect(
        selectConversationUnreadCount(automatic.state, _conversationOne),
        2,
      );
      expect(
        selectFirstUnreadSequence(automatic.state, _conversationOne),
        const MessageSequence(7),
      );
    });

    test('filters direct-message receipts without retaining supplied cursors',
        () {
      final store = _store(
        [
          _summary(_conversationOne, type: ConversationType.direct),
          _summary(_conversationTwo, type: ConversationType.channel),
          _summary(
            const ConversationId('group'),
            type: ConversationType.groupDirect,
          ),
          _summary(
            const ConversationId('thread'),
            type: ConversationType.thread,
          ),
        ],
      );
      final before = store.state.currentUserReadStates.length;
      final other = _wireRead(
        _conversationOne,
        userId: const UserId('user-other'),
        lastReadSequence: 5,
      );

      expect(
        selectDirectMessageOtherUserRead(
          store.state,
          DirectMessageReceiptInput(
            conversationId: _conversationOne,
            otherMemberReadState: other,
            messageSequence: const MessageSequence(5),
          ),
        ),
        isTrue,
      );
      expect(
        selectDirectMessageOtherUserRead(
          store.state,
          DirectMessageReceiptInput(
            conversationId: _conversationOne,
            otherMemberReadState: other,
            messageSequence: const MessageSequence(6),
          ),
        ),
        isFalse,
      );
      for (final conversationId in const [
        _conversationTwo,
        ConversationId('group'),
        ConversationId('thread'),
      ]) {
        expect(
          selectDirectMessageOtherUserRead(
            store.state,
            DirectMessageReceiptInput(
              conversationId: conversationId,
              otherMemberReadState: _wireRead(
                conversationId,
                userId: const UserId('user-other'),
                lastReadSequence: 5,
              ),
              messageSequence: const MessageSequence(5),
            ),
          ),
          isNull,
        );
      }
      for (final rejected in [
        _wireRead(_conversationOne, lastReadSequence: 5),
        _wireRead(
          _conversationTwo,
          userId: const UserId('user-other'),
          lastReadSequence: 5,
        ),
      ]) {
        expect(
          selectDirectMessageOtherUserRead(
            store.state,
            DirectMessageReceiptInput(
              conversationId: _conversationOne,
              otherMemberReadState: rejected,
              messageSequence: const MessageSequence(5),
            ),
          ),
          isNull,
        );
      }
      expect(store.state.currentUserReadStates.length, before);
    });
  });

  test('coalesces synchronous forward reads and encodes the exact PATCH',
      () async {
    const encodedId = ConversationId('conversation /?#');
    final store = _store([
      _summary(encodedId, latestSequence: 9, lastReadSequence: 2),
    ]);
    final response = Completer<HandrailChatHttpResponse>();
    final transport = _RecordingTransport((_) => response.future);
    final client = _client(store, transport);

    final first = client.markRead(
      const ChatMarkReadInput(
        conversationId: encodedId,
        throughSequence: MessageSequence(4),
        idempotencyKey: 'coalesced-first',
      ),
    );
    final second = client.markRead(
      const ChatMarkReadInput(
        conversationId: encodedId,
        throughSequence: MessageSequence(7),
        idempotencyKey: 'discarded-second',
      ),
    );

    expect(
      store.state.currentUserReadStates[encodedId]?.lastReadSequence,
      const MessageSequence(7),
      reason: 'the optimistic projection is synchronous',
    );
    await _eventLoop();
    expect(transport.requests, hasLength(1));
    final request = transport.requests.single;
    expect(request.method, 'PATCH');
    expect(
      request.uri.toString(),
      'https://chat.example.test/api/chat/conversations/'
      'conversation%20%2F%3F%23/read-cursor',
    );
    expect(request.headers['Idempotency-Key'], 'coalesced-first');
    expect(jsonDecode(request.body!), {
      'operation': 'mark_read',
      'conversationId': encodedId.value,
      'throughSequence': 7,
      'idempotencyKey': 'coalesced-first',
    });

    response.complete(
      _responseFor(
        request,
        status: 'applied',
        updatedAt: '2026-08-26T15:01:00.000Z',
      ),
    );
    expect(await first, isA<ChatCommandSuccess<ReadCursorMutationResult>>());
    expect(await second, isA<ChatCommandSuccess<ReadCursorMutationResult>>());
    await client.dispose();
    await store.close();
  });

  test('persists a coalesced stable intent before projection and transport',
      () async {
    final store = _store([
      _summary(_conversationOne, latestSequence: 8, lastReadSequence: 2),
    ]);
    final response = Completer<HandrailChatHttpResponse>();
    final transport = _RecordingTransport((_) => response.future);
    final storage = _ReadCursorStorage()..blockNextReplace();
    final identity = _storageIdentity();
    final client = _client(
      store,
      transport,
      storage: storage,
      storageIdentity: identity,
    );

    final first = client.markRead(
      const ChatMarkReadInput(
        conversationId: _conversationOne,
        throughSequence: MessageSequence(4),
        idempotencyKey: 'durable-first',
      ),
    );
    final second = client.markRead(
      const ChatMarkReadInput(
        conversationId: _conversationOne,
        throughSequence: MessageSequence(7),
        idempotencyKey: 'discarded-second',
      ),
    );

    await storage.nextReplaceStarted;
    expect(
      store.state.currentUserReadStates[_conversationOne]?.lastReadSequence,
      const MessageSequence(2),
    );
    expect(transport.requests, isEmpty);

    storage.releaseReplace();
    await _eventually(() => transport.requests.length == 1);
    final persisted = await storage.readCursorRecord(identity);
    expect(persisted?.intents, hasLength(1));
    final intent = persisted!.intents.single;
    expect(intent.request.idempotencyKey, 'durable-first');
    expect((intent.request as MarkReadInput).throughSequence.value, 7);
    expect(intent.acknowledgedReadState.lastReadSequence.value, 2);
    expect(
      store.state.currentUserReadStates[_conversationOne]?.lastReadSequence,
      const MessageSequence(7),
    );
    expect(
      jsonDecode(transport.requests.single.body!)['idempotencyKey'],
      'durable-first',
    );

    response.complete(
      _responseFor(
        transport.requests.single,
        status: 'applied',
        updatedAt: '2026-08-26T15:01:00.000Z',
      ),
    );
    expect(await first, isA<ChatCommandSuccess<ReadCursorMutationResult>>());
    expect(await second, isA<ChatCommandSuccess<ReadCursorMutationResult>>());
    expect(await storage.readCursorRecord(identity), isNull);
    await client.dispose();
    await store.close();
  });

  test('persists ordered unread and read segments without cross-coalescing',
      () async {
    final store = _store([
      _summary(_conversationOne, latestSequence: 8, lastReadSequence: 5),
    ]);
    final responses = <String, Completer<HandrailChatHttpResponse>>{};
    final transport = _RecordingTransport((request) {
      final key = jsonDecode(request.body!)['idempotencyKey']! as String;
      return (responses[key] = Completer<HandrailChatHttpResponse>()).future;
    });
    final storage = _ReadCursorStorage();
    final identity = _storageIdentity();
    final client = _client(
      store,
      transport,
      storage: storage,
      storageIdentity: identity,
    );

    final unread = client.markUnread(
      const ChatMarkUnreadInput(
        conversationId: _conversationOne,
        fromSequence: MessageSequence(3),
        idempotencyKey: 'unread-barrier',
      ),
    );
    final read = client.markRead(
      const ChatMarkReadInput(
        conversationId: _conversationOne,
        throughSequence: MessageSequence(7),
        idempotencyKey: 'read-after-barrier',
      ),
    );
    final coalesced = client.markRead(
      const ChatMarkReadInput(
        conversationId: _conversationOne,
        throughSequence: MessageSequence(8),
        idempotencyKey: 'discarded-read',
      ),
    );

    await _eventually(() => responses.containsKey('unread-barrier'));
    responses['unread-barrier']!.complete(
      _responseFor(
        _requestWithKey(transport, 'unread-barrier'),
        status: 'applied',
        updatedAt: '2026-08-26T15:01:00.000Z',
      ),
    );
    expect(await unread, isA<ChatCommandSuccess<ReadCursorMutationResult>>());
    await _eventually(() => responses.containsKey('read-after-barrier'));
    final persisted = await storage.readCursorRecord(identity);
    expect(persisted?.intents, hasLength(1));
    expect(
        persisted!.intents.single.request.idempotencyKey, 'read-after-barrier');
    expect(
      (persisted.intents.single.request as MarkReadInput).throughSequence.value,
      8,
    );
    responses['read-after-barrier']!.complete(
      _responseFor(
        _requestWithKey(transport, 'read-after-barrier'),
        status: 'replayed',
        updatedAt: '2026-08-26T15:02:00.000Z',
      ),
    );
    expect(await read, isA<ChatCommandSuccess<ReadCursorMutationResult>>());
    expect(
        await coalesced, isA<ChatCommandSuccess<ReadCursorMutationResult>>());
    await client.dispose();
    await store.close();
  });

  test('matching durable event settles and removes the persisted intent',
      () async {
    final store = _store([
      _summary(_conversationOne, latestSequence: 8, lastReadSequence: 2),
    ]);
    final pending = Completer<HandrailChatHttpResponse>();
    final storage = _ReadCursorStorage();
    final identity = _storageIdentity();
    final client = _client(
      store,
      _RecordingTransport((_) => pending.future),
      storage: storage,
      storageIdentity: identity,
    );
    final command = client.markRead(
      const ChatMarkReadInput(
        conversationId: _conversationOne,
        throughSequence: MessageSequence(7),
        idempotencyKey: 'event-settlement',
      ),
    );
    await _eventually(
      () async => (await storage.readCursorRecord(identity)) != null,
    );

    expect(
      client.reconcileReadCursorEvent(
        _event(lastReadSequence: 7, eventId: 'durable-match'),
      ),
      isTrue,
    );
    expect(await command, isA<ChatCommandSuccess<ReadCursorMutationResult>>());
    expect(await storage.readCursorRecord(identity), isNull);
    await client.dispose();
    await store.close();
  });

  test('atomic shared storage retains distinct-conversation intents', () async {
    final identity = _storageIdentity();
    final storage = _AtomicReadCursorStorage();
    final firstStore = _store([
      _summary(_conversationOne, latestSequence: 8, lastReadSequence: 2),
      _summary(_conversationTwo, latestSequence: 8, lastReadSequence: 2),
    ]);
    final secondStore = _store([
      _summary(_conversationOne, latestSequence: 8, lastReadSequence: 2),
      _summary(_conversationTwo, latestSequence: 8, lastReadSequence: 2),
    ]);
    final firstTransport = _RecordingTransport(
      (_) => Completer<HandrailChatHttpResponse>().future,
    );
    final secondTransport = _RecordingTransport(
      (_) => Completer<HandrailChatHttpResponse>().future,
    );
    final firstClient = _client(
      firstStore,
      firstTransport,
      storage: storage,
      storageIdentity: identity,
    );
    final secondClient = _client(
      secondStore,
      secondTransport,
      storage: storage,
      storageIdentity: identity,
    );
    await Future.wait([
      firstClient.activateStorageIdentity(identity),
      secondClient.activateStorageIdentity(identity),
    ]);
    storage.blockNextReadCursorReads(2);

    final first = firstClient.markRead(
      const ChatMarkReadInput(
        conversationId: _conversationOne,
        throughSequence: MessageSequence(5),
        idempotencyKey: 'atomic-distinct-one',
      ),
    );
    final second = secondClient.markRead(
      const ChatMarkReadInput(
        conversationId: _conversationTwo,
        throughSequence: MessageSequence(6),
        idempotencyKey: 'atomic-distinct-two',
      ),
    );
    await storage.blockedReadCursorReads;
    storage.releaseReadCursorReads();

    await _eventually(
      () =>
          firstTransport.requests.length == 1 &&
          secondTransport.requests.length == 1,
    );
    final record = await storage.readCursorRecord(identity);
    expect(record?.intents, hasLength(2));
    expect(
      record!.intents.map((intent) => intent.request.conversationId).toSet(),
      {_conversationOne, _conversationTwo},
    );
    expect(record.intents.map((intent) => intent.enqueueOrder), [1, 2]);

    await firstClient.dispose();
    await secondClient.dispose();
    expect(await first, isA<ChatCommandClosed<ReadCursorMutationResult>>());
    expect(await second, isA<ChatCommandClosed<ReadCursorMutationResult>>());
    await firstStore.close();
    await secondStore.close();
  });

  test('atomic same-conversation supersession commits one canonical winner',
      () async {
    final identity = _storageIdentity();
    final storage = _AtomicReadCursorStorage();
    final firstStore = _store([
      _summary(_conversationOne, latestSequence: 8, lastReadSequence: 2),
    ]);
    final secondStore = _store([
      _summary(_conversationOne, latestSequence: 8, lastReadSequence: 2),
    ]);
    final firstClient = _client(
      firstStore,
      _RecordingTransport(
        (_) => Completer<HandrailChatHttpResponse>().future,
      ),
      storage: storage,
      storageIdentity: identity,
    );
    final secondClient = _client(
      secondStore,
      _RecordingTransport(
        (_) => Completer<HandrailChatHttpResponse>().future,
      ),
      storage: storage,
      storageIdentity: identity,
    );
    await Future.wait([
      firstClient.activateStorageIdentity(identity),
      secondClient.activateStorageIdentity(identity),
    ]);
    storage.blockNextReadCursorReads(2);

    final first = firstClient.markRead(
      const ChatMarkReadInput(
        conversationId: _conversationOne,
        throughSequence: MessageSequence(5),
        idempotencyKey: 'atomic-canonical-first',
      ),
    );
    final second = secondClient.markRead(
      const ChatMarkReadInput(
        conversationId: _conversationOne,
        throughSequence: MessageSequence(7),
        idempotencyKey: 'atomic-canonical-second',
      ),
    );
    await storage.blockedReadCursorReads;
    storage.releaseReadCursorReads();

    await _eventually(() async {
      final record = await storage.readCursorRecord(identity);
      return record?.intents.length == 1 &&
          (record!.intents.single.request as MarkReadInput)
                  .throughSequence
                  .value ==
              7;
    });
    final intent = (await storage.readCursorRecord(identity))!.intents.single;
    expect(intent.request.idempotencyKey, 'atomic-canonical-first');
    expect(intent.enqueueOrder, 1);

    await firstClient.dispose();
    await secondClient.dispose();
    expect(await first, isA<ChatCommandClosed<ReadCursorMutationResult>>());
    expect(await second, isA<ChatCommandClosed<ReadCursorMutationResult>>());
    await firstStore.close();
    await secondStore.close();
  });

  test('atomic retry derives queue order and baseline from committed state',
      () async {
    final identity = _storageIdentity();
    final storage = _AtomicReadCursorStorage();
    final store = _store([
      _summary(_conversationOne, latestSequence: 8, lastReadSequence: 2),
      _summary(_conversationTwo, latestSequence: 8, lastReadSequence: 2),
    ]);
    final transport = _RecordingTransport(
      (_) => Completer<HandrailChatHttpResponse>().future,
    );
    final client = _client(
      store,
      transport,
      storage: storage,
      storageIdentity: identity,
    );
    await client.activateStorageIdentity(identity);
    storage.blockNextReadCursorReads(1);

    final command = client.markRead(
      const ChatMarkReadInput(
        conversationId: _conversationOne,
        throughSequence: MessageSequence(6),
        idempotencyKey: 'atomic-retried-proposal',
      ),
    );
    await storage.blockedReadCursorReads;
    await storage.replace(
      ApplicationChatQueuedReadCursorIntentsRecord(
        identity: identity,
        intents: [
          _retainedReadIntent(
            throughSequence: 5,
            acknowledgedSequence: 4,
            idempotencyKey: 'racing-conversation-one',
            enqueueOrder: 1,
          ),
          ApplicationChatQueuedReadCursorIntent(
            request: MarkReadInput(
              conversationId: _conversationTwo,
              throughSequence: const MessageSequence(3),
              idempotencyKey: 'racing-conversation-two',
            ),
            acknowledgedReadState: _wireRead(
              _conversationTwo,
              lastReadSequence: 2,
            ),
            enqueueOrder: 2,
            enqueuedAt: const IsoTimestamp('2026-08-26T15:00:02.000Z'),
          ),
        ],
      ),
    );
    storage.releaseReadCursorReads();

    await _eventually(() => transport.requests.length == 1);
    final retried =
        (await storage.readCursorRecord(identity))!.intents.singleWhere(
              (intent) =>
                  intent.request.idempotencyKey == 'atomic-retried-proposal',
            );
    expect(retried.enqueueOrder, 3);
    expect(retried.acknowledgedReadState.lastReadSequence.value, 4);

    await client.dispose();
    expect(await command, isA<ChatCommandClosed<ReadCursorMutationResult>>());
    await store.close();
  });

  test('atomic stale settlement preserves a same-key replacement', () async {
    final identity = _storageIdentity();
    final storage = _AtomicReadCursorStorage();
    final store = _store([
      _summary(_conversationOne, latestSequence: 8, lastReadSequence: 2),
    ]);
    final response = Completer<HandrailChatHttpResponse>();
    final transport = _RecordingTransport((_) => response.future);
    final client = _client(
      store,
      transport,
      storage: storage,
      storageIdentity: identity,
    );
    await client.activateStorageIdentity(identity);
    final command = client.markRead(
      const ChatMarkReadInput(
        conversationId: _conversationOne,
        throughSequence: MessageSequence(7),
        idempotencyKey: 'atomic-stale-settlement',
      ),
    );
    await _eventually(() => transport.requests.length == 1);
    final original = (await storage.readCursorRecord(identity))!.intents.single;
    final replacement = ApplicationChatQueuedReadCursorIntent(
      request: original.request,
      acknowledgedReadState: original.acknowledgedReadState,
      enqueueOrder: original.enqueueOrder + 1,
      enqueuedAt: const IsoTimestamp('2026-08-26T15:30:00.000Z'),
    );
    await storage.replace(
      ApplicationChatQueuedReadCursorIntentsRecord(
        identity: identity,
        intents: [replacement],
      ),
    );

    response.complete(_errorResponse(403, 'AUTHENTICATION_FAILED'));
    expect(
      await command,
      isA<ChatCommandAuthenticationFailure<ReadCursorMutationResult>>(),
    );
    final retained = (await storage.readCursorRecord(identity))!.intents.single;
    expect(retained.enqueueOrder, replacement.enqueueOrder);
    expect(retained.enqueuedAt, replacement.enqueuedAt);
    expect(retained.request.idempotencyKey, 'atomic-stale-settlement');

    await client.dispose();
    await store.close();
  });

  test('atomic exact settlement preserves an unrelated conversation', () async {
    final identity = _storageIdentity();
    final storage = _AtomicReadCursorStorage();
    final store = _store([
      _summary(_conversationOne, latestSequence: 8, lastReadSequence: 2),
      _summary(_conversationTwo, latestSequence: 8, lastReadSequence: 2),
    ]);
    final transport = _RecordingTransport(
      (request) async => _responseFor(
        request,
        status: 'applied',
        updatedAt: '2026-08-26T15:31:00.000Z',
      ),
    );
    final client = _client(
      store,
      transport,
      storage: storage,
      storageIdentity: identity,
    );
    await client.activateStorageIdentity(identity);
    await storage.replace(
      ApplicationChatQueuedReadCursorIntentsRecord(
        identity: identity,
        intents: [
          ApplicationChatQueuedReadCursorIntent(
            request: MarkReadInput(
              conversationId: _conversationTwo,
              throughSequence: const MessageSequence(5),
              idempotencyKey: 'atomic-unrelated',
            ),
            acknowledgedReadState: _wireRead(
              _conversationTwo,
              lastReadSequence: 2,
            ),
            enqueueOrder: 1,
            enqueuedAt: const IsoTimestamp('2026-08-26T15:00:01.000Z'),
          ),
        ],
      ),
    );

    final result = await client.markRead(
      const ChatMarkReadInput(
        conversationId: _conversationOne,
        throughSequence: MessageSequence(7),
        idempotencyKey: 'atomic-exact-target',
      ),
    );
    expect(result, isA<ChatCommandSuccess<ReadCursorMutationResult>>());
    final remaining = await storage.readCursorRecord(identity);
    expect(remaining?.intents, hasLength(1));
    expect(
      remaining!.intents.single.request.idempotencyKey,
      'atomic-unrelated',
    );

    await client.dispose();
    await store.close();
  });

  test('atomic corrupt quarantine preserves a racing valid replacement',
      () async {
    final identity = _storageIdentity();
    const malformed = '{malformed-read-cursor-record';
    final storage = _AtomicReadCursorStorage()
      ..putRawReadCursorRecord(identity, malformed)
      ..blockQuarantineOf(malformed);
    final store = _store([
      _summary(_conversationOne, latestSequence: 8, lastReadSequence: 2),
    ]);
    final transport = _RecordingTransport(
      (_) async => throw StateError('quarantined work must not dispatch'),
    );
    final client = _client(
      store,
      transport,
      storage: storage,
      storageIdentity: identity,
    );
    await storage.quarantineStarted;
    await storage.replace(
      ApplicationChatQueuedReadCursorIntentsRecord(
        identity: identity,
        intents: [
          _retainedReadIntent(
            throughSequence: 6,
            acknowledgedSequence: 2,
            idempotencyKey: 'racing-valid-replacement',
            enqueueOrder: 1,
          ),
        ],
      ),
    );
    storage.releaseQuarantine();

    await _eventLoop();
    final retained = await storage.readCursorRecord(identity);
    expect(
      retained?.intents.single.request.idempotencyKey,
      'racing-valid-replacement',
    );
    expect(transport.requests, isEmpty);

    await client.dispose();
    await store.close();
  });

  test('hydrates retained work over an older canonical baseline', () async {
    final store = _store([
      _summary(_conversationOne, latestSequence: 8, lastReadSequence: 2),
    ]);
    final storage = _ReadCursorStorage();
    final identity = _storageIdentity();
    await storage.replace(
      ApplicationChatQueuedReadCursorIntentsRecord(
        identity: identity,
        intents: [
          _retainedReadIntent(
            throughSequence: 7,
            acknowledgedSequence: 4,
            idempotencyKey: 'restart-stable-key',
            enqueueOrder: 1,
          ),
        ],
      ),
    );
    final response = Completer<HandrailChatHttpResponse>();
    final transport = _RecordingTransport((_) => response.future);
    final client = _client(
      store,
      transport,
      storage: storage,
      storageIdentity: identity,
    );

    await _eventually(() => transport.requests.length == 1);
    expect(
      store.state.currentUserReadStates[_conversationOne]?.lastReadSequence,
      const MessageSequence(7),
      reason: 'the retained acknowledged baseline is projected before replay',
    );
    final request = transport.requests.single;
    expect(request.headers['Idempotency-Key'], 'restart-stable-key');
    expect(jsonDecode(request.body!)['idempotencyKey'], 'restart-stable-key');

    response.complete(
      _responseFor(
        request,
        status: 'replayed',
        updatedAt: '2026-08-26T15:03:00.000Z',
      ),
    );
    await _eventually(
      () => storage.removals.contains(
        (identity, ApplicationChatStorageRecordKind.queuedReadCursorIntents),
      ),
    );
    expect(await storage.readCursorRecord(identity), isNull);
    await client.dispose();
    await store.close();
  });

  test('waits for matching canonical hydration before retained dispatch',
      () async {
    final store = NormalizedSnapshotStore();
    final storage = _ReadCursorStorage();
    final identity = _storageIdentity();
    await storage.replace(
      ApplicationChatQueuedReadCursorIntentsRecord(
        identity: identity,
        intents: [
          _retainedReadIntent(
            throughSequence: 7,
            acknowledgedSequence: 2,
            idempotencyKey: 'await-hydration',
            enqueueOrder: 1,
          ),
        ],
      ),
    );
    final transport = _RecordingTransport((request) async => _responseFor(
          request,
          status: 'replayed',
          updatedAt: '2026-08-26T15:03:00.000Z',
        ));
    final client = _client(
      store,
      transport,
      storage: storage,
      storageIdentity: identity,
    );
    await _eventLoop();
    expect(transport.requests, isEmpty);

    store.hydrateConversationList(
      _snapshot([
        _summary(_conversationOne, latestSequence: 8, lastReadSequence: 2),
      ]),
    );
    await _eventually(() => transport.requests.length == 1);
    await _eventually(
      () async => await storage.readCursorRecord(identity) == null,
    );
    await client.dispose();
    await store.close();
  });

  test('drains retained intents in deterministic conversation order', () async {
    final store = _store([
      _summary(_conversationOne, latestSequence: 8, lastReadSequence: 2),
    ]);
    final storage = _ReadCursorStorage();
    final identity = _storageIdentity();
    await storage.replace(
      ApplicationChatQueuedReadCursorIntentsRecord(
        identity: identity,
        intents: [
          _retainedReadIntent(
            throughSequence: 5,
            acknowledgedSequence: 2,
            idempotencyKey: 'retained-first',
            enqueueOrder: 1,
          ),
          ApplicationChatQueuedReadCursorIntent(
            request: MarkUnreadInput(
              conversationId: _conversationOne,
              fromSequence: const MessageSequence(4),
              idempotencyKey: 'retained-second',
            ),
            acknowledgedReadState:
                _wireRead(_conversationOne, lastReadSequence: 5),
            enqueueOrder: 2,
            enqueuedAt: const IsoTimestamp('2026-08-26T15:00:01.000Z'),
          ),
          _retainedReadIntent(
            throughSequence: 7,
            acknowledgedSequence: 5,
            idempotencyKey: 'retained-third',
            enqueueOrder: 3,
          ),
        ],
      ),
    );
    final responses = <String, Completer<HandrailChatHttpResponse>>{};
    final transport = _RecordingTransport((request) {
      final key = jsonDecode(request.body!)['idempotencyKey']! as String;
      return (responses[key] = Completer<HandrailChatHttpResponse>()).future;
    });
    final client = _client(
      store,
      transport,
      storage: storage,
      storageIdentity: identity,
    );

    for (final key in const [
      'retained-first',
      'retained-second',
      'retained-third',
    ]) {
      await _eventually(() => responses.containsKey(key));
      expect(
        transport.requests
            .map((request) => jsonDecode(request.body!)['idempotencyKey'])
            .toList(),
        <String>[
          'retained-first',
          if (key != 'retained-first') 'retained-second',
          if (key == 'retained-third') 'retained-third',
        ],
      );
      responses[key]!.complete(
        _responseFor(
          _requestWithKey(transport, key),
          status: 'applied',
          updatedAt: key == 'retained-first'
              ? '2026-08-26T15:01:00.000Z'
              : key == 'retained-second'
                  ? '2026-08-26T15:02:00.000Z'
                  : '2026-08-26T15:03:00.000Z',
        ),
      );
    }
    await _eventually(
        () async => await storage.readCursorRecord(identity) == null);
    await client.dispose();
    await store.close();
  });

  test('pauses retained dispatch offline and resumes through recovery',
      () async {
    final store = _store([
      _summary(_conversationOne, latestSequence: 8, lastReadSequence: 2),
    ]);
    final storage = _ReadCursorStorage();
    final identity = _storageIdentity();
    await storage.replace(
      ApplicationChatQueuedReadCursorIntentsRecord(
        identity: identity,
        intents: [
          _retainedReadIntent(
            throughSequence: 7,
            acknowledgedSequence: 2,
            idempotencyKey: 'offline-recovery',
            enqueueOrder: 1,
          ),
        ],
      ),
    );
    var attempts = 0;
    var waits = 0;
    final transport = _RecordingTransport((request) async {
      attempts += 1;
      if (attempts == 1) throw StateError('offline');
      return _responseFor(
        request,
        status: 'replayed',
        updatedAt: '2026-08-26T15:04:00.000Z',
      );
    });
    final client = _client(
      store,
      transport,
      storage: storage,
      storageIdentity: identity,
      readCursorRetryBackoff: (_) => const Duration(seconds: 30),
      readCursorRetryWait: (_, __) {
        waits += 1;
        return Completer<void>().future;
      },
    );
    client.setApplicationForeground(false);
    await _eventLoop();
    expect(transport.requests, isEmpty);

    client.setApplicationForeground(true);
    await _eventually(() => attempts == 1 && waits == 1);
    expect(await storage.readCursorRecord(identity), isNotNull);
    expect(
      store.state.currentUserReadStates[_conversationOne]?.lastReadSequence,
      const MessageSequence(2),
    );

    client.setApplicationForeground(false);
    client.setApplicationForeground(true);
    await _eventually(() => attempts == 2);
    await _eventually(
        () async => await storage.readCursorRecord(identity) == null);
    expect(
      transport.requests
          .map((request) => request.headers['Idempotency-Key'])
          .toSet(),
      {'offline-recovery'},
    );
    await client.dispose();
    await store.close();
  });

  test('canonical event settles a retained intent during ambiguous HTTP',
      () async {
    final store = _store([
      _summary(_conversationOne, latestSequence: 8, lastReadSequence: 2),
    ]);
    final storage = _ReadCursorStorage();
    final identity = _storageIdentity();
    await storage.replace(
      ApplicationChatQueuedReadCursorIntentsRecord(
        identity: identity,
        intents: [
          _retainedReadIntent(
            throughSequence: 7,
            acknowledgedSequence: 2,
            idempotencyKey: 'ambiguous-retained',
            enqueueOrder: 1,
          ),
        ],
      ),
    );
    final response = Completer<HandrailChatHttpResponse>();
    final transport = _RecordingTransport((_) => response.future);
    final client = _client(
      store,
      transport,
      storage: storage,
      storageIdentity: identity,
    );
    await _eventually(() => transport.requests.length == 1);

    expect(
      client.reconcileReadCursorEvent(
        _event(lastReadSequence: 7, eventId: 'retained-event-match'),
      ),
      isTrue,
    );
    await _eventually(
        () async => await storage.readCursorRecord(identity) == null);
    expect(
      (transport.requests.single.cancellationSignal
              as ChatCommandCancellationSignal?)
          ?.isCancelled,
      isTrue,
    );
    expect(
      store.state.currentUserReadStates[_conversationOne]?.lastReadSequence,
      const MessageSequence(7),
    );
    await client.dispose();
    await store.close();
  });

  test('disposal cancels retained HTTP and leaves its record recoverable',
      () async {
    final store = _store([
      _summary(_conversationOne, latestSequence: 8, lastReadSequence: 2),
    ]);
    final storage = _ReadCursorStorage();
    final identity = _storageIdentity();
    await storage.replace(
      ApplicationChatQueuedReadCursorIntentsRecord(
        identity: identity,
        intents: [
          _retainedReadIntent(
            throughSequence: 7,
            acknowledgedSequence: 2,
            idempotencyKey: 'disposed-retained',
            enqueueOrder: 1,
          ),
        ],
      ),
    );
    final response = Completer<HandrailChatHttpResponse>();
    final transport = _RecordingTransport((_) => response.future);
    final client = _client(
      store,
      transport,
      storage: storage,
      storageIdentity: identity,
    );
    await _eventually(() => transport.requests.length == 1);

    await client.dispose();
    expect(
      (transport.requests.single.cancellationSignal
              as ChatCommandCancellationSignal?)
          ?.isCancelled,
      isTrue,
    );
    expect(await storage.readCursorRecord(identity), isNotNull);
    expect(
      store.state.currentUserReadStates[_conversationOne]?.lastReadSequence,
      const MessageSequence(2),
    );
    await store.close();
  });

  test('quarantines only the active identity corrupt read-cursor record',
      () async {
    final store = _store([
      _summary(_conversationOne, latestSequence: 8, lastReadSequence: 2),
    ]);
    final storage = _ReadCursorStorage()..malformedReadCursorReads = 2;
    final identity = _storageIdentity();
    final otherIdentity = _storageIdentity(deviceId: 'device-2');
    await storage.replace(
      ApplicationChatQueuedReadCursorIntentsRecord(
        identity: identity,
        intents: [
          _retainedReadIntent(
            throughSequence: 7,
            acknowledgedSequence: 2,
            idempotencyKey: 'corrupt-active',
            enqueueOrder: 1,
          ),
        ],
      ),
    );
    await storage.replace(
      ApplicationChatRealtimeCursorRecord(
        identity: identity,
        cursor: const EventCursor(eventId: 'keep-realtime'),
      ),
    );
    await storage.replace(
      ApplicationChatQueuedReadCursorIntentsRecord(
        identity: otherIdentity,
        intents: [
          _retainedReadIntent(
            throughSequence: 6,
            acknowledgedSequence: 2,
            idempotencyKey: 'keep-other',
            enqueueOrder: 1,
          ),
        ],
      ),
    );
    final transport = _RecordingTransport(
      (_) async => throw StateError('corrupt work must not dispatch'),
    );
    final client = _client(
      store,
      transport,
      storage: storage,
      storageIdentity: identity,
    );

    await _eventually(
      () => storage.removals.contains(
        (identity, ApplicationChatStorageRecordKind.queuedReadCursorIntents),
      ),
    );
    expect(await storage.readCursorRecord(identity), isNull);
    expect(
      await storage.read(
        identity,
        ApplicationChatStorageRecordKind.realtimeCursor,
      ),
      isNotNull,
    );
    expect(await storage.readCursorRecord(otherIdentity), isNotNull);
    expect(transport.requests, isEmpty);
    await client.dispose();
    await store.close();
  });

  test('retains transient and malformed outcomes but rolls projection back',
      () async {
    for (final malformed in const [false, true]) {
      final store = _store([
        _summary(_conversationOne, latestSequence: 8, lastReadSequence: 2),
      ]);
      final storage = _ReadCursorStorage();
      final identity = _storageIdentity();
      final transport = _RecordingTransport((_) async {
        if (!malformed) throw StateError('offline');
        return const HandrailChatHttpResponse(
          statusCode: 200,
          body: '{"unexpected":true}',
        );
      });
      final client = _client(
        store,
        transport,
        storage: storage,
        storageIdentity: identity,
      );

      final result = await client.markRead(
        ChatMarkReadInput(
          conversationId: _conversationOne,
          throughSequence: const MessageSequence(7),
          idempotencyKey: malformed ? 'retained-malformed' : 'retained-offline',
        ),
      );
      expect(
        result,
        malformed
            ? isA<ChatCommandMalformedResponse<ReadCursorMutationResult>>()
            : isA<ChatCommandTransportFailure<ReadCursorMutationResult>>(),
      );
      expect(await storage.readCursorRecord(identity), isNotNull);
      expect(
        store.state.currentUserReadStates[_conversationOne]?.lastReadSequence,
        const MessageSequence(2),
      );
      await client.dispose();
      await store.close();
    }
  });

  test('terminal rejection removes only its exact intent and restores baseline',
      () async {
    final store = _store([
      _summary(_conversationOne, latestSequence: 8, lastReadSequence: 2),
    ]);
    final storage = _ReadCursorStorage();
    final identity = _storageIdentity();
    await storage.replace(
      ApplicationChatQueuedReadCursorIntentsRecord(
        identity: identity,
        intents: [
          ApplicationChatQueuedReadCursorIntent(
            request: MarkReadInput(
              conversationId: _conversationTwo,
              throughSequence: const MessageSequence(3),
              idempotencyKey: 'previous-retained',
            ),
            acknowledgedReadState: _wireRead(
              _conversationTwo,
              lastReadSequence: 2,
            ),
            enqueueOrder: 1,
            enqueuedAt: const IsoTimestamp(_initialTime),
          ),
        ],
      ),
    );
    final client = _client(
      store,
      _RecordingTransport(
          (_) async => _errorResponse(403, 'AUTHENTICATION_FAILED')),
      storage: storage,
      storageIdentity: identity,
    );

    final result = await client.markRead(
      const ChatMarkReadInput(
        conversationId: _conversationOne,
        throughSequence: MessageSequence(7),
        idempotencyKey: 'terminal-exact',
      ),
    );
    expect(result,
        isA<ChatCommandAuthenticationFailure<ReadCursorMutationResult>>());
    final remaining = await storage.readCursorRecord(identity);
    expect(remaining?.intents, hasLength(1));
    expect(
        remaining!.intents.single.request.idempotencyKey, 'previous-retained');
    expect(
      store.state.currentUserReadStates[_conversationOne]?.lastReadSequence,
      const MessageSequence(2),
    );
    await client.dispose();
    await store.close();
  });

  test('storage failure prevents an unrecorded projection or dispatch',
      () async {
    final store = _store([
      _summary(_conversationOne, latestSequence: 8, lastReadSequence: 2),
    ]);
    final storage = _ReadCursorStorage()..failNextReplace = true;
    final transport = _RecordingTransport(
        (_) async => throw StateError('transport must not be reached'));
    final client = _client(
      store,
      transport,
      storage: storage,
      storageIdentity: _storageIdentity(),
    );

    final result = await client.markRead(
      const ChatMarkReadInput(
        conversationId: _conversationOne,
        throughSequence: MessageSequence(7),
        idempotencyKey: 'storage-failure',
      ),
    );
    expect(
        result, isA<ChatCommandValidationFailure<ReadCursorMutationResult>>());
    expect(transport.requests, isEmpty);
    expect(
      store.state.currentUserReadStates[_conversationOne]?.lastReadSequence,
      const MessageSequence(2),
    );
    await client.dispose();
    await store.close();
  });

  test('serializes storage writes across conversations', () async {
    final store = _store([
      _summary(_conversationOne, latestSequence: 8, lastReadSequence: 2),
      _summary(_conversationTwo, latestSequence: 8, lastReadSequence: 2),
    ]);
    final storage = _ReadCursorStorage()..writeDelay = Duration.zero;
    final client = _client(
      store,
      _RecordingTransport((request) async => _responseFor(
            request,
            status: 'applied',
            updatedAt: '2026-08-26T15:01:00.000Z',
          )),
      storage: storage,
      storageIdentity: _storageIdentity(),
    );

    await Future.wait([
      client.markRead(
        const ChatMarkReadInput(
          conversationId: _conversationOne,
          throughSequence: MessageSequence(5),
          idempotencyKey: 'serialized-one',
        ),
      ),
      client.markRead(
        const ChatMarkReadInput(
          conversationId: _conversationTwo,
          throughSequence: MessageSequence(6),
          idempotencyKey: 'serialized-two',
        ),
      ),
    ]);
    expect(storage.maximumConcurrentWrites, 1);
    await client.dispose();
    await store.close();
  });

  test('old-identity persistence completion cannot project or dispatch',
      () async {
    final store = _store([
      _summary(_conversationOne, latestSequence: 8, lastReadSequence: 2),
    ]);
    final storage = _ReadCursorStorage()..blockNextReplace();
    final transport = _RecordingTransport(
        (_) async => throw StateError('old identity must not dispatch'));
    final client = _client(
      store,
      transport,
      storage: storage,
      storageIdentity: _storageIdentity(),
    );
    final command = client.markRead(
      const ChatMarkReadInput(
        conversationId: _conversationOne,
        throughSequence: MessageSequence(7),
        idempotencyKey: 'old-identity',
      ),
    );
    await storage.nextReplaceStarted;
    final activation = client.activateStorageIdentity(
      _storageIdentity(userId: 'user-2', deviceId: 'device-2'),
    );
    expect(await command, isA<ChatCommandClosed<ReadCursorMutationResult>>());
    storage.releaseReplace();
    await activation;
    await _eventLoop();
    expect(transport.requests, isEmpty);
    expect(
      await storage.readCursorRecord(_storageIdentity()),
      isNotNull,
      reason: 'the ambiguous old-scope intent remains recoverable',
    );
    expect(
      store.state.currentUserReadStates[_conversationOne]?.lastReadSequence,
      const MessageSequence(2),
    );
    await client.dispose();
    await store.close();
  });

  test('disposed persistence completion cannot project or dispatch', () async {
    final store = _store([
      _summary(_conversationOne, latestSequence: 8, lastReadSequence: 2),
    ]);
    final storage = _ReadCursorStorage()..blockNextReplace();
    final transport = _RecordingTransport(
        (_) async => throw StateError('disposed work must not dispatch'));
    final client = _client(
      store,
      transport,
      storage: storage,
      storageIdentity: _storageIdentity(),
    );
    final command = client.markRead(
      const ChatMarkReadInput(
        conversationId: _conversationOne,
        throughSequence: MessageSequence(7),
        idempotencyKey: 'disposed-persistence',
      ),
    );
    await storage.nextReplaceStarted;

    await client.dispose();
    expect(await command, isA<ChatCommandClosed<ReadCursorMutationResult>>());
    storage.releaseReplace();
    await _eventLoop();
    expect(transport.requests, isEmpty);
    expect(
      await storage.readCursorRecord(_storageIdentity()),
      isNotNull,
      reason: 'close does not erase an ambiguously persisted intent',
    );
    expect(
      store.state.currentUserReadStates[_conversationOne]?.lastReadSequence,
      const MessageSequence(2),
    );
    await store.close();
  });

  test('old-identity transport completion cannot mutate the new projection',
      () async {
    final store = _store([
      _summary(_conversationOne, latestSequence: 8, lastReadSequence: 2),
    ]);
    final storage = _ReadCursorStorage();
    final response = Completer<HandrailChatHttpResponse>();
    final transport = _RecordingTransport((_) => response.future);
    final client = _client(
      store,
      transport,
      storage: storage,
      storageIdentity: _storageIdentity(),
    );
    final command = client.markRead(
      const ChatMarkReadInput(
        conversationId: _conversationOne,
        throughSequence: MessageSequence(7),
        idempotencyKey: 'old-transport',
      ),
    );
    await _eventually(() => transport.requests.length == 1);
    await client.activateStorageIdentity(
      _storageIdentity(userId: 'user-2', deviceId: 'device-2'),
    );
    expect(await command, isA<ChatCommandClosed<ReadCursorMutationResult>>());

    response.complete(
      _responseFor(
        transport.requests.single,
        status: 'applied',
        updatedAt: '2026-08-26T15:03:00.000Z',
      ),
    );
    await _eventLoop();
    expect(
      store.state.currentUserReadStates[_conversationOne]?.lastReadSequence,
      const MessageSequence(2),
      reason: 'identity activation removes the old optimistic projection',
    );
    expect(
      await storage.readCursorRecord(
        _storageIdentity(userId: 'user-2', deviceId: 'device-2'),
      ),
      isNull,
    );
    expect(await storage.readCursorRecord(_storageIdentity()), isNotNull);
    await client.dispose();
    await store.close();
  });

  test('identity replacement cancels a retained retry wait', () async {
    final store = _store([
      _summary(_conversationOne, latestSequence: 8, lastReadSequence: 2),
    ]);
    final storage = _ReadCursorStorage();
    final identity = _storageIdentity();
    final nextIdentity =
        _storageIdentity(userId: 'user-2', deviceId: 'device-2');
    await storage.replace(
      ApplicationChatQueuedReadCursorIntentsRecord(
        identity: identity,
        intents: [
          _retainedReadIntent(
            throughSequence: 7,
            acknowledgedSequence: 2,
            idempotencyKey: 'identity-wait',
            enqueueOrder: 1,
          ),
        ],
      ),
    );
    final waitRelease = Completer<void>();
    ChatCommandCancellationSignal? waitSignal;
    final transport = _RecordingTransport(
      (_) async => throw StateError('offline'),
    );
    final client = _client(
      store,
      transport,
      storage: storage,
      storageIdentity: identity,
      readCursorRetryBackoff: (_) => const Duration(seconds: 30),
      readCursorRetryWait: (_, signal) {
        waitSignal = signal;
        return waitRelease.future;
      },
    );
    await _eventually(() => waitSignal != null);

    await client.activateStorageIdentity(nextIdentity);
    expect(waitSignal!.isCancelled, isTrue);
    if (!waitRelease.isCompleted) waitRelease.complete();
    await _eventLoop();
    expect(transport.requests, hasLength(1));
    expect(await storage.readCursorRecord(identity), isNotNull);
    expect(await storage.readCursorRecord(nextIdentity), isNull);
    expect(
      store.state.currentUserReadStates[_conversationOne]?.lastReadSequence,
      const MessageSequence(2),
    );
    await client.dispose();
    await store.close();
  });

  test('generates one idempotency key and reuses it across safe retries',
      () async {
    final store = _store([
      _summary(_conversationOne, latestSequence: 8, lastReadSequence: 2),
    ]);
    var attempts = 0;
    var keyCalls = 0;
    final transport = _RecordingTransport((request) async {
      attempts += 1;
      if (attempts == 1) throw StateError('offline');
      return _responseFor(
        request,
        status: 'replayed',
        updatedAt: '2026-08-26T15:01:00.000Z',
      );
    });
    final client = _client(
      store,
      transport,
      generateIdempotencyKey: () {
        keyCalls += 1;
        return 'stable-generated-key';
      },
      retryOptions: ChatCommandRetryOptions(
        maxAttempts: 2,
        backoff: (_) => Duration.zero,
        wait: (_, __) async {},
      ),
    );

    final result = await client.markRead(
      const ChatMarkReadInput(
        conversationId: _conversationOne,
        throughSequence: MessageSequence(6),
      ),
    );

    expect(result, isA<ChatCommandSuccess<ReadCursorMutationResult>>());
    expect(keyCalls, 1);
    expect(transport.requests, hasLength(2));
    expect(transport.requests[0].body, transport.requests[1].body);
    expect(
      transport.requests
          .map((request) => request.headers['Idempotency-Key'])
          .toSet(),
      {'stable-generated-key'},
    );
    await client.dispose();
    await store.close();
  });

  test('serializes each conversation while unrelated conversations progress',
      () async {
    final store = _store([
      _summary(_conversationOne, latestSequence: 8, lastReadSequence: 2),
      _summary(_conversationTwo, latestSequence: 8, lastReadSequence: 2),
    ]);
    final responses = <String, Completer<HandrailChatHttpResponse>>{};
    final transport = _RecordingTransport((request) {
      final body = jsonDecode(request.body!) as Map<String, Object?>;
      return (responses[body['idempotencyKey']! as String] =
              Completer<HandrailChatHttpResponse>())
          .future;
    });
    final client = _client(store, transport);

    final first = client.markRead(
      const ChatMarkReadInput(
        conversationId: _conversationOne,
        throughSequence: MessageSequence(5),
        idempotencyKey: 'one-read',
      ),
    );
    final unread = client.markUnread(
      const ChatMarkUnreadInput(
        conversationId: _conversationOne,
        fromSequence: MessageSequence(3),
        idempotencyKey: 'one-unread',
      ),
    );
    final other = client.markRead(
      const ChatMarkReadInput(
        conversationId: _conversationTwo,
        throughSequence: MessageSequence(6),
        idempotencyKey: 'two-read',
      ),
    );

    expect(
      store.state.currentUserReadStates[_conversationOne]
          ?.manualUnreadFromSequence,
      const MessageSequence(3),
      reason: 'queued mark-unread remains optimistically projected',
    );
    await _eventLoop();
    expect(responses.keys, containsAll(['one-read', 'two-read']));
    expect(responses, isNot(contains('one-unread')));

    responses['one-read']!.complete(
      _responseFor(
        _requestWithKey(transport, 'one-read'),
        status: 'applied',
        updatedAt: '2026-08-26T15:01:00.000Z',
      ),
    );
    await _eventLoop();
    expect(responses, contains('one-unread'));
    expect(
      store.state.currentUserReadStates[_conversationOne]
          ?.manualUnreadFromSequence,
      const MessageSequence(3),
    );

    responses['one-unread']!.complete(
      _responseFor(
        _requestWithKey(transport, 'one-unread'),
        status: 'replayed',
        updatedAt: '2026-08-26T15:02:00.000Z',
      ),
    );
    responses['two-read']!.complete(
      _responseFor(
        _requestWithKey(transport, 'two-read'),
        status: 'applied',
        updatedAt: '2026-08-26T15:01:00.000Z',
      ),
    );
    expect(await first, isA<ChatCommandSuccess<ReadCursorMutationResult>>());
    expect(await unread, isA<ChatCommandSuccess<ReadCursorMutationResult>>());
    expect(await other, isA<ChatCommandSuccess<ReadCursorMutationResult>>());
    expect(
      selectConversationUnreadCount(store.state, _conversationOne),
      6,
    );
    await client.dispose();
    await store.close();
  });

  test('accepts generated events, rejects stale events, and reprojects work',
      () async {
    final store = _store([
      _summary(_conversationOne, latestSequence: 8, lastReadSequence: 2),
    ]);
    final pending = Completer<HandrailChatHttpResponse>();
    final transport = _RecordingTransport((_) => pending.future);
    final client = _client(store, transport);
    final command = client.markRead(
      const ChatMarkReadInput(
        conversationId: _conversationOne,
        throughSequence: MessageSequence(7),
        idempotencyKey: 'pending-read',
      ),
    );
    await _eventLoop();

    expect(
      client.reconcileReadCursorEvent(
        _event(lastReadSequence: 4, eventId: 'event-new'),
      ),
      isTrue,
    );
    expect(
      store.state.currentUserReadStates[_conversationOne]?.lastReadSequence,
      const MessageSequence(7),
      reason: 'the accepted canonical baseline is reprojected through work',
    );
    expect(
      client.reconcileReadCursorEvent(
        _event(
          lastReadSequence: 3,
          eventId: 'event-stale',
          updatedAt: '2026-08-26T15:03:00.000Z',
        ),
      ),
      isFalse,
    );

    pending.complete(
      _responseFor(
        transport.requests.single,
        status: 'applied',
        updatedAt: '2026-08-26T15:04:00.000Z',
      ),
    );
    expect(await command, isA<ChatCommandSuccess<ReadCursorMutationResult>>());
    expect(
      store.state.currentUserReadStates[_conversationOne]?.lastReadSequence,
      const MessageSequence(7),
    );
    await client.dispose();
    await store.close();
  });

  test('does not let a stale successful result replace a newer event',
      () async {
    final store = _store([
      _summary(_conversationOne, latestSequence: 8, lastReadSequence: 2),
    ]);
    final pending = Completer<HandrailChatHttpResponse>();
    final transport = _RecordingTransport((_) => pending.future);
    final client = _client(store, transport);
    final command = client.markRead(
      const ChatMarkReadInput(
        conversationId: _conversationOne,
        throughSequence: MessageSequence(5),
        idempotencyKey: 'stale-result',
      ),
    );
    await _eventLoop();

    expect(
      client.reconcileReadCursorEvent(
        _event(lastReadSequence: 7, eventId: 'event-ahead'),
      ),
      isTrue,
    );
    pending.complete(
      _responseFor(
        transport.requests.single,
        status: 'replayed',
        updatedAt: '2026-08-26T15:03:00.000Z',
      ),
    );

    expect(await command, isA<ChatCommandSuccess<ReadCursorMutationResult>>());
    expect(
      store.state.currentUserReadStates[_conversationOne]?.lastReadSequence,
      const MessageSequence(7),
    );
    await client.dispose();
    await store.close();
  });

  test('reconciles both applied and replayed canonical results', () async {
    for (final status in const ['applied', 'replayed']) {
      final store = _store([
        _summary(_conversationOne, latestSequence: 8, lastReadSequence: 2),
      ]);
      late HandrailChatHttpRequest recorded;
      final transport = _RecordingTransport((request) async {
        recorded = request;
        return _responseFor(
          request,
          status: status,
          updatedAt: '2026-08-26T15:01:00.000Z',
        );
      });
      final client = _client(store, transport);

      final result = await client.markRead(
        ChatMarkReadInput(
          conversationId: _conversationOne,
          throughSequence: const MessageSequence(6),
          idempotencyKey: '$status-key',
        ),
      );

      expect(recorded.headers['Idempotency-Key'], '$status-key');
      expect(result, isA<ChatCommandSuccess<ReadCursorMutationResult>>());
      expect(
        store.state.currentUserReadStates[_conversationOne]?.lastReadSequence,
        const MessageSequence(6),
      );
      await client.dispose();
      await store.close();
    }
  });

  test('failure and malformed response roll back to the newest canonical row',
      () async {
    for (final malformed in const [false, true]) {
      final store = _store([
        _summary(_conversationOne, latestSequence: 8, lastReadSequence: 2),
      ]);
      final pending = Completer<HandrailChatHttpResponse>();
      final transport = _RecordingTransport((_) => pending.future);
      final client = _client(store, transport);
      final command = client.markRead(
        ChatMarkReadInput(
          conversationId: _conversationOne,
          throughSequence: const MessageSequence(7),
          idempotencyKey: malformed ? 'malformed' : 'failure',
        ),
      );
      await _eventLoop();

      store.hydrateConversationList(
        _snapshot([
          _summary(
            _conversationOne,
            latestSequence: 8,
            lastReadSequence: 4,
            updatedAt: '2026-08-26T15:02:00.000Z',
          ),
        ]),
      );
      expect(
        store.state.currentUserReadStates[_conversationOne]?.lastReadSequence,
        const MessageSequence(7),
      );
      pending.complete(
        malformed
            ? const HandrailChatHttpResponse(
                statusCode: 200,
                body: '{"unexpected":true}',
              )
            : _errorResponse(403, 'AUTHENTICATION_FAILED'),
      );
      final result = await command;
      expect(
        result,
        malformed
            ? isA<ChatCommandMalformedResponse<ReadCursorMutationResult>>()
            : isA<ChatCommandAuthenticationFailure<ReadCursorMutationResult>>(),
      );
      expect(
        store.state.currentUserReadStates[_conversationOne]?.lastReadSequence,
        const MessageSequence(4),
      );
      await client.dispose();
      await store.close();
    }
  });

  test('client disposal closes pending work and restores canonical state',
      () async {
    final store = _store([
      _summary(_conversationOne, latestSequence: 8, lastReadSequence: 2),
    ]);
    final pending = Completer<HandrailChatHttpResponse>();
    final transport = _RecordingTransport((_) => pending.future);
    final client = _client(store, transport);
    final command = client.markRead(
      const ChatMarkReadInput(
        conversationId: _conversationOne,
        throughSequence: MessageSequence(7),
        idempotencyKey: 'close-key',
      ),
    );
    await _eventLoop();

    await client.dispose();
    expect(await command, isA<ChatCommandClosed<ReadCursorMutationResult>>());
    expect(
      (transport.requests.single.cancellationSignal
              as ChatCommandCancellationSignal?)
          ?.isCancelled,
      isTrue,
    );
    expect(
      store.state.currentUserReadStates[_conversationOne]?.lastReadSequence,
      const MessageSequence(2),
    );
    expect(
      await client.markUnread(
        const ChatMarkUnreadInput(
          conversationId: _conversationOne,
          fromSequence: MessageSequence(1),
        ),
      ),
      isA<ChatCommandClosed<ReadCursorMutationResult>>(),
    );
    await store.close();
  });
}

HandrailChatClient _client(
  NormalizedSnapshotStore store,
  _RecordingTransport transport, {
  ChatCommandIdempotencyKeyGenerator? generateIdempotencyKey,
  ApplicationChatStorage? storage,
  ApplicationChatStorageIdentity? storageIdentity,
  ChatReadCursorRetryBackoff? readCursorRetryBackoff,
  ChatReadCursorRetryWait? readCursorRetryWait,
  ChatCommandRetryOptions retryOptions =
      const ChatCommandRetryOptions(maxAttempts: 1),
}) =>
    HandrailChatClient(
      apiBaseUri: Uri.parse(
        'https://chat.example.test/api/chat/?ignored=true#fragment',
      ),
      tokenProvider: () async => 'access-token',
      transport: transport,
      normalizedSnapshotStore: store,
      generateIdempotencyKey:
          generateIdempotencyKey ?? () => 'generated-read-key',
      commandRetryOptions: retryOptions,
      localStorage: storage,
      storageIdentity: storageIdentity,
      readCursorRetryBackoff: readCursorRetryBackoff,
      readCursorRetryWait: readCursorRetryWait,
    );

ApplicationChatStorageIdentity _storageIdentity({
  String userId = 'user-1',
  String deviceId = 'device-1',
}) =>
    ApplicationChatStorageIdentity(
      tenantId: _tenantId,
      userId: UserId(userId),
      deviceId: DeviceId(deviceId),
    );

NormalizedSnapshotStore _store(List<Map<String, Object?>> summaries) =>
    NormalizedSnapshotStore()..hydrateConversationList(_snapshot(summaries));

ConversationListSnapshot _snapshot(List<Map<String, Object?>> summaries) =>
    ConversationListSnapshot.fromJson({
      'kind': 'conversation_list',
      'scope': {'type': 'organization'},
      'items': summaries,
      'page': <String, Object?>{},
      '_meta': _metadata(),
    });

Map<String, Object?> _summary(
  ConversationId conversationId, {
  ConversationType type = ConversationType.channel,
  int latestSequence = 8,
  int lastReadSequence = 2,
  int? manualUnreadFromSequence,
  String updatedAt = _initialTime,
}) =>
    {
      'id': conversationId.value,
      'tenantId': _tenantId.value,
      'type': type.toJson(),
      if (type == ConversationType.channel) 'name': conversationId.value,
      'visibility': type == ConversationType.channel ? 'public' : 'private',
      if (type == ConversationType.thread)
        'parentConversationId': _conversationOne.value,
      if (type == ConversationType.thread) 'rootMessageId': 'root-message',
      'createdAt': _initialTime,
      'updatedAt': updatedAt,
      'latestSequence': latestSequence,
      'activityAt': updatedAt,
      'unreadMentionCount': 0,
      'currentMember': {
        'tenantId': _tenantId.value,
        'conversationId': conversationId.value,
        'userId': _userId.value,
        'role': 'member',
        'state': 'active',
        'joinedAt': _initialTime,
        'updatedAt': updatedAt,
      },
      'currentReadState': {
        'conversationId': conversationId.value,
        'userId': _userId.value,
        'lastReadSequence': lastReadSequence,
        if (manualUnreadFromSequence != null)
          'manualUnreadFromSequence': manualUnreadFromSequence,
        'updatedAt': updatedAt,
      },
      'currentPreference': {
        'conversationId': conversationId.value,
        'userId': _userId.value,
        'notificationPreference': 'mentions',
        'isStarred': false,
        'mute': {'muted': false},
        'updatedAt': updatedAt,
      },
      'activeMemberUserIds': [_userId.value],
    };

MessageTimelinePage _timeline(
  ConversationId conversationId,
  List<int> sequences,
) {
  final request = MessageTimelineRequest(
    conversationId: conversationId,
    direction: MessageTimelineDirection.backward,
    limit: 20,
  );
  return MessageTimelinePage.fromJson(
    {
      'conversationId': conversationId.value,
      'messages': [
        for (final sequence in sequences)
          {
            'id': '${conversationId.value}-message-$sequence',
            'tenantId': _tenantId.value,
            'conversationId': conversationId.value,
            'author': {'type': 'user', 'userId': _userId.value},
            'sequence': sequence,
            'createdAt': _initialTime,
            'updatedAt': _initialTime,
            'revision': {'revision': 1},
            'content': {'format': 'plain', 'text': 'Message $sequence'},
            'isThreadRoot': false,
            'reactions': <Object?>[],
            'attachmentMetadata': <Object?>[],
          },
      ],
      'pagination': {
        'older': {'available': false},
        'newer': {'available': false},
      },
      'replay': {
        'resumeFrom': {'eventId': 'timeline-event'},
      },
    },
    request: request,
  );
}

ConversationReadState _wireRead(
  ConversationId conversationId, {
  UserId userId = _userId,
  required int lastReadSequence,
  String updatedAt = _initialTime,
}) =>
    ConversationReadState(
      conversationId: conversationId,
      userId: userId,
      lastReadSequence: MessageSequence(lastReadSequence),
      updatedAt: IsoTimestamp(updatedAt),
    );

ApplicationChatQueuedReadCursorIntent _retainedReadIntent({
  required int throughSequence,
  required int acknowledgedSequence,
  required String idempotencyKey,
  required int enqueueOrder,
}) =>
    ApplicationChatQueuedReadCursorIntent(
      request: MarkReadInput(
        conversationId: _conversationOne,
        throughSequence: MessageSequence(throughSequence),
        idempotencyKey: idempotencyKey,
      ),
      acknowledgedReadState: _wireRead(
        _conversationOne,
        lastReadSequence: acknowledgedSequence,
      ),
      enqueueOrder: enqueueOrder,
      enqueuedAt: IsoTimestamp(
        '2026-08-26T15:00:${enqueueOrder.toString().padLeft(2, '0')}.000Z',
      ),
    );

ReadCursorUpdatedEvent _event({
  required int lastReadSequence,
  required String eventId,
  String updatedAt = '2026-08-26T15:02:00.000Z',
}) =>
    ReadCursorUpdatedEvent.fromJson(
      {
        'eventId': eventId,
        'protocolVersion': 4,
        'tenantId': _tenantId.value,
        'streamId': 'user:${_userId.value}',
        'type': readCursorUpdatedEventType,
        'occurredAt': updatedAt,
        'payload': {
          'kind': readCursorUpdatedPayloadKind,
          'actorUserId': _userId.value,
          'operation': 'mark_read',
          'conversationId': _conversationOne.value,
          'readState': {
            'conversationId': _conversationOne.value,
            'userId': _userId.value,
            'lastReadSequence': lastReadSequence,
            'updatedAt': updatedAt,
          },
          'latestSequence': 8,
          'unreadCount': 8 - lastReadSequence,
        },
      },
      expectedTenantId: _tenantId,
    );

HandrailChatHttpResponse _responseFor(
  HandrailChatHttpRequest request, {
  required String status,
  required String updatedAt,
}) {
  final body = jsonDecode(request.body!) as Map<String, Object?>;
  final operation = body['operation']! as String;
  final conversationId = body['conversationId']! as String;
  final through = body['throughSequence'] as int?;
  final from = body['fromSequence'] as int?;
  final baseline = conversationId == _conversationTwo.value ? 2 : 2;
  final lastReadSequence = through ?? (from == null ? baseline : 5);
  final effectiveRead = from == null ? lastReadSequence : from - 1;
  return HandrailChatHttpResponse(
    statusCode: 200,
    body: jsonEncode({
      'operation': operation,
      'reconciliationStatus': status,
      'idempotencyKey': body['idempotencyKey'],
      'conversationId': conversationId,
      'readState': {
        'conversationId': conversationId,
        'userId': _userId.value,
        'lastReadSequence': lastReadSequence,
        if (from != null) 'manualUnreadFromSequence': from,
        'updatedAt': updatedAt,
      },
      'latestSequence': 8,
      'unreadCount': 8 - effectiveRead,
    }),
  );
}

HandrailChatHttpRequest _requestWithKey(
  _RecordingTransport transport,
  String key,
) =>
    transport.requests.singleWhere((request) {
      final body = jsonDecode(request.body!) as Map<String, Object?>;
      return body['idempotencyKey'] == key;
    });

HandrailChatHttpResponse _errorResponse(int status, String code) =>
    HandrailChatHttpResponse(
      statusCode: status,
      body: jsonEncode({
        'error': {'code': code, 'message': 'request rejected'},
      }),
    );

Map<String, Object?> _metadata() => {
      'packageVersion': '0.1.3',
      'protocolVersion': 4,
      'schemaVersion': 9,
      'enabledFeatures': {
        conversationSnapshotFeature: true,
      },
      'supportedProtocolRange': {
        'minimumVersion': 1,
        'maximumVersion': 4,
      },
      'feature': {
        'name': conversationSnapshotFeature,
        'version': conversationSnapshotVersion,
      },
    };

Future<void> _eventLoop() => Future<void>.delayed(Duration.zero);

Future<void> _eventually(FutureOr<bool> Function() predicate) async {
  for (var attempt = 0; attempt < 100; attempt += 1) {
    if (await predicate()) return;
    await _eventLoop();
  }
  fail('Condition was not reached.');
}

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

final class _ReadCursorStorage implements ApplicationChatStorage {
  final Map<String, ApplicationChatStorageRecord> _records = {};
  Completer<void>? _replaceGate;
  Completer<void> _replaceStarted = Completer<void>();
  bool failNextReplace = false;
  int malformedReadCursorReads = 0;
  final List<
      (
        ApplicationChatStorageIdentity,
        ApplicationChatStorageRecordKind,
      )> removals = [];
  Duration? writeDelay;
  var _activeWrites = 0;
  var maximumConcurrentWrites = 0;

  Future<void> get nextReplaceStarted => _replaceStarted.future;

  void blockNextReplace() {
    _replaceGate = Completer<void>();
    _replaceStarted = Completer<void>();
  }

  void releaseReplace() {
    final gate = _replaceGate;
    _replaceGate = null;
    if (gate != null && !gate.isCompleted) gate.complete();
  }

  Future<ApplicationChatQueuedReadCursorIntentsRecord?> readCursorRecord(
    ApplicationChatStorageIdentity identity,
  ) async =>
      await read(
        identity,
        ApplicationChatStorageRecordKind.queuedReadCursorIntents,
      ) as ApplicationChatQueuedReadCursorIntentsRecord?;

  @override
  Future<ApplicationChatStorageRecord?> read(
    ApplicationChatStorageIdentity identity,
    ApplicationChatStorageRecordKind kind,
  ) async {
    if (kind == ApplicationChatStorageRecordKind.queuedReadCursorIntents &&
        malformedReadCursorReads > 0) {
      malformedReadCursorReads -= 1;
      throw const FormatException('corrupt queued read-cursor record');
    }
    return _records[_key(identity, kind)];
  }

  @override
  Future<void> replace(ApplicationChatStorageRecord record) async {
    await _write(record.kind, () async {
      if (!_replaceStarted.isCompleted) _replaceStarted.complete();
      final gate = _replaceGate;
      if (gate != null) await gate.future;
      if (failNextReplace) {
        failNextReplace = false;
        throw StateError('storage replace failed');
      }
      _records[_key(record.identity, record.kind)] = record;
    });
  }

  @override
  Future<void> remove(
    ApplicationChatStorageIdentity identity,
    ApplicationChatStorageRecordKind kind,
  ) =>
      _write(kind, () async {
        removals.add((identity, kind));
        _records.remove(_key(identity, kind));
      });

  @override
  Future<void> clearForLogout(
    ApplicationChatStorageIdentity previousIdentity,
  ) async {
    for (final kind in ApplicationChatStorageRecordKind.values) {
      _records.remove(_key(previousIdentity, kind));
    }
  }

  @override
  Future<void> clearForIdentityChange({
    required ApplicationChatStorageIdentity previousIdentity,
    required ApplicationChatStorageIdentity nextIdentity,
  }) async {
    if (previousIdentity == nextIdentity) return;
    await clearForLogout(previousIdentity);
  }

  Future<void> _write(
    ApplicationChatStorageRecordKind kind,
    Future<void> Function() operation,
  ) async {
    if (kind != ApplicationChatStorageRecordKind.queuedReadCursorIntents) {
      await operation();
      return;
    }
    _activeWrites += 1;
    if (_activeWrites > maximumConcurrentWrites) {
      maximumConcurrentWrites = _activeWrites;
    }
    try {
      final delay = writeDelay;
      if (delay != null) await Future<void>.delayed(delay);
      await operation();
    } finally {
      _activeWrites -= 1;
    }
  }

  String _key(
    ApplicationChatStorageIdentity identity,
    ApplicationChatStorageRecordKind kind,
  ) =>
      '${identity.tenantId.value}\u0000${identity.userId.value}\u0000'
      '${identity.deviceId.value}\u0000${kind.wireValue}';
}

final class _AtomicReadCursorStorage implements AtomicApplicationChatStorage {
  final Map<String, String> _records = {};
  var _blockedReadCursorReadCount = 0;
  Completer<void> _blockedReadCursorReads = Completer<void>();
  Completer<void>? _readCursorReadsRelease;
  String? _blockedQuarantineValue;
  Completer<void> _quarantineStarted = Completer<void>();
  Completer<void>? _quarantineRelease;

  Future<void> get blockedReadCursorReads => _blockedReadCursorReads.future;
  Future<void> get quarantineStarted => _quarantineStarted.future;

  void blockNextReadCursorReads(int count) {
    _blockedReadCursorReadCount = count;
    _blockedReadCursorReads = Completer<void>();
    _readCursorReadsRelease = Completer<void>();
  }

  void releaseReadCursorReads() {
    final release = _readCursorReadsRelease;
    _readCursorReadsRelease = null;
    if (release != null && !release.isCompleted) release.complete();
  }

  void putRawReadCursorRecord(
    ApplicationChatStorageIdentity identity,
    String encoded,
  ) {
    _records[_key(
      identity,
      ApplicationChatStorageRecordKind.queuedReadCursorIntents,
    )] = encoded;
  }

  void blockQuarantineOf(String encoded) {
    _blockedQuarantineValue = encoded;
    _quarantineStarted = Completer<void>();
    _quarantineRelease = Completer<void>();
  }

  void releaseQuarantine() {
    final release = _quarantineRelease;
    _quarantineRelease = null;
    if (release != null && !release.isCompleted) release.complete();
  }

  Future<ApplicationChatQueuedReadCursorIntentsRecord?> readCursorRecord(
    ApplicationChatStorageIdentity identity,
  ) async =>
      await read(
        identity,
        ApplicationChatStorageRecordKind.queuedReadCursorIntents,
      ) as ApplicationChatQueuedReadCursorIntentsRecord?;

  @override
  Future<String?> readEncoded(
    ApplicationChatStorageIdentity identity,
    ApplicationChatStorageRecordKind kind,
  ) async {
    final captured = _records[_key(identity, kind)];
    if (kind == ApplicationChatStorageRecordKind.queuedReadCursorIntents &&
        _blockedReadCursorReadCount > 0) {
      _blockedReadCursorReadCount -= 1;
      if (_blockedReadCursorReadCount == 0 &&
          !_blockedReadCursorReads.isCompleted) {
        _blockedReadCursorReads.complete();
      }
      final release = _readCursorReadsRelease;
      if (release != null) await release.future;
    }
    return captured;
  }

  @override
  Future<bool> compareExchange(
    ApplicationChatStorageIdentity identity,
    ApplicationChatStorageRecordKind kind,
    String? expectedEncodedRecord,
    String? replacementEncodedRecord,
  ) async {
    if (kind == ApplicationChatStorageRecordKind.queuedReadCursorIntents &&
        expectedEncodedRecord == _blockedQuarantineValue &&
        replacementEncodedRecord == null) {
      if (!_quarantineStarted.isCompleted) _quarantineStarted.complete();
      final release = _quarantineRelease;
      if (release != null) await release.future;
    }
    final key = _key(identity, kind);
    if (_records[key] != expectedEncodedRecord) return false;
    if (replacementEncodedRecord == null) {
      _records.remove(key);
    } else {
      final replacement = ApplicationChatStorageRecord.decode(
        replacementEncodedRecord,
      );
      if (replacement.identity != identity || replacement.kind != kind) {
        throw ArgumentError('Atomic replacement must match its storage key.');
      }
      _records[key] = replacementEncodedRecord;
    }
    return true;
  }

  @override
  Future<ApplicationChatStorageRecord?> read(
    ApplicationChatStorageIdentity identity,
    ApplicationChatStorageRecordKind kind,
  ) async {
    final encoded = _records[_key(identity, kind)];
    return encoded == null
        ? null
        : ApplicationChatStorageRecord.decode(encoded);
  }

  @override
  Future<void> replace(ApplicationChatStorageRecord record) async {
    _records[_key(record.identity, record.kind)] = record.encode();
  }

  @override
  Future<void> remove(
    ApplicationChatStorageIdentity identity,
    ApplicationChatStorageRecordKind kind,
  ) async {
    _records.remove(_key(identity, kind));
  }

  @override
  Future<void> clearForLogout(
    ApplicationChatStorageIdentity previousIdentity,
  ) async {
    for (final kind in ApplicationChatStorageRecordKind.values) {
      _records.remove(_key(previousIdentity, kind));
    }
  }

  @override
  Future<void> clearForIdentityChange({
    required ApplicationChatStorageIdentity previousIdentity,
    required ApplicationChatStorageIdentity nextIdentity,
  }) async {
    if (previousIdentity == nextIdentity) return;
    await clearForLogout(previousIdentity);
  }

  String _key(
    ApplicationChatStorageIdentity identity,
    ApplicationChatStorageRecordKind kind,
  ) =>
      '${identity.tenantId.value}\u0000${identity.userId.value}\u0000'
      '${identity.deviceId.value}\u0000${kind.wireValue}';
}
