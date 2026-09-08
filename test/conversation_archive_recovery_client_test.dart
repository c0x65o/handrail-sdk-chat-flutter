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

const _conversationId = ConversationId('conversation-1');
final _identity = ApplicationChatStorageIdentity(
  tenantId: const TenantId('tenant-1'),
  userId: const UserId('user-1'),
  deviceId: const DeviceId('device-1'),
);
final _otherIdentity = ApplicationChatStorageIdentity(
  tenantId: const TenantId('tenant-1'),
  userId: const UserId('user-2'),
  deviceId: const DeviceId('device-2'),
);

void main() {
  test('atomic concurrent conversations survive a failed exchange', () async {
    final backing = InMemoryApplicationChatStorage();
    final storage = _InterleavingArchiveStorage(backing);
    final first = _Fixture(
        storage: storage,
        transport: _ArchiveTransport(),
        keys: Queue.of(['first-key']));
    final second = _Fixture(
        storage: backing,
        transport: _ArchiveTransport(),
        keys: Queue.of(['second-key']));
    addTearDown(first.dispose);
    addTearDown(second.dispose);
    await first.activate();
    await second.activate();
    const other = ConversationId('conversation-2');
    _seedAuthority(second.store, conversationId: other);
    storage.proposals.clear();
    final gate = storage.holdNextWrite();
    final pending = first.client.archiveConversation(_authored());
    await gate.started.future;
    expect(first.client.queuedConversationArchives, isEmpty);
    expect(first.lifecycle.projectedArchived, isFalse);
    final otherPending = second.client.archiveConversation(_authored(other));
    await _eventually(
        () => second.client.queuedConversationArchives.length == 1);
    gate.release.complete();
    await _eventually(
        () => first.client.queuedConversationArchives.length == 2);
    final committed = (await _read(backing, _identity))!;
    expect(committed.intents.map((intent) => intent.request.idempotencyKey),
        ['second-key', 'first-key']);
    expect(committed.intents.map((intent) => intent.enqueueOrder), [1, 2]);
    expect(storage.failedExchanges, 1);
    expect(first.client.queuedConversationArchives.last.enqueueOrder, 2);
    expect(storage.proposals.first!.intents.single.enqueueOrder, 1);
    expect(storage.proposals.last!.intents.map((intent) => intent.enqueueOrder),
        [1, 2]);
    await first.dispose();
    await second.dispose();
    await pending;
    await otherPending;
  });

  for (final archive in [true, false]) {
    test(
        'atomic same-conversation replacement commits ${archive ? 'archive' : 'restore'}',
        () async {
      final backing = InMemoryApplicationChatStorage();
      final storage = _InterleavingArchiveStorage(backing);
      final first = _Fixture(
          storage: storage,
          transport: _ArchiveTransport(),
          keys: Queue.of(['first-key']));
      final second = _Fixture(
          storage: backing,
          transport: _ArchiveTransport(),
          keys: Queue.of(['second-key']));
      addTearDown(first.dispose);
      addTearDown(second.dispose);
      await first.activate();
      await second.activate();
      final gate = storage.holdNextWrite();
      final pending = archive
          ? first.client.archiveConversation(_authored())
          : first.client.restoreConversation(_authored());
      await gate.started.future;
      final otherPending = archive
          ? second.client.restoreConversation(_authored())
          : second.client.archiveConversation(_authored());
      await _eventually(
          () => second.client.queuedConversationArchives.length == 1);
      final before = (await _read(backing, _identity))!.intents.single;
      gate.release.complete();
      await _eventually(
          () => first.client.queuedConversationArchives.length == 1);
      final winner = (await _read(backing, _identity))!.intents.single;
      expect(winner.request.idempotencyKey, 'first-key');
      expect(
          winner.request.intent,
          archive
              ? ConversationArchiveIntent.archive
              : ConversationArchiveIntent.restore);
      expect(winner.enqueueOrder, before.enqueueOrder);
      expect(winner.enqueuedAt, before.enqueuedAt);
      expect(first.client.queuedConversationArchives.single.request.toJson(),
          winner.request.toJson());
      expect(storage.failedExchanges, 1);
      await first.dispose();
      await second.dispose();
      await pending;
      await otherPending;
    });
  }

  for (final settlement in ['cancellation', 'success', 'terminal', 'event']) {
    test('atomic stale $settlement preserves replacement and unrelated work',
        () async {
      final backing = InMemoryApplicationChatStorage();
      final storage = _InterleavingArchiveStorage(backing);
      final response = Completer<HandrailChatHttpResponse>();
      final first = _Fixture(
          storage: storage,
          transport: _ArchiveTransport(patch: (_) => response.future),
          keys: Queue.of(['stale-key']));
      final second = _Fixture(
          storage: backing,
          transport: _ArchiveTransport(),
          keys: Queue.of(['new-key', 'other-key']));
      addTearDown(first.dispose);
      addTearDown(second.dispose);
      await first.activate();
      await second.activate();
      if (settlement == 'success' || settlement == 'terminal') {
        await first.initialize();
      }
      final cancellation = ChatCommandCancellationController();
      final pending = first.client.archiveConversation(_authored(),
          cancellationSignal: cancellation.signal);
      await _eventually(
          () => first.client.queuedConversationArchives.length == 1);
      if (settlement == 'success' || settlement == 'terminal') {
        await _eventually(() => first.transport.patches.length == 1);
      }
      final gate = storage.holdNextWrite();
      switch (settlement) {
        case 'cancellation':
          cancellation.cancel();
        case 'success':
          response.complete(_success(_body(first.transport.patches.single)));
        case 'terminal':
          response.complete(_error(403, 'PERMISSION_DENIED'));
        case 'event':
          first.client.reduceDurableEvent(_lifecycleEvent(archived: true));
      }
      await gate.started.future;
      first.client.setApplicationForeground(false);
      final replacement = second.client.restoreConversation(_authored());
      await _eventually(
          () => second.client.queuedConversationArchives.length == 1);
      const other = ConversationId('conversation-2');
      _seedAuthority(second.store, conversationId: other);
      final unrelated = second.client.archiveConversation(_authored(other));
      await _eventually(
          () => second.client.queuedConversationArchives.length == 2);
      gate.release.complete();
      final result = await pending;
      if (settlement == 'cancellation') {
        expect(result, isA<ChatCommandAborted<ConversationArchiveResult>>());
      } else if (settlement == 'event') {
        // This event carries lifecycle authority without the archive actor
        // details required to synthesize a full command success result.
        expect(result, isA<ChatCommandClosed<ConversationArchiveResult>>());
      } else if (settlement == 'terminal') {
        expect(result,
            isA<ChatCommandAuthenticationFailure<ConversationArchiveResult>>());
      } else {
        expect(result, isA<ChatCommandSuccess<ConversationArchiveResult>>());
      }
      final committed = (await _read(backing, _identity))!;
      expect(committed.intents.map((intent) => intent.request.idempotencyKey),
          ['new-key', 'other-key']);
      expect(
          first.client.queuedConversationArchives
              .map((intent) => intent.request.idempotencyKey),
          ['new-key', 'other-key']);
      expect(storage.failedExchanges, 1);
      await first.dispose();
      await second.dispose();
      await replacement;
      await unrelated;
    });
  }

  for (final changeOrder in [true, false]) {
    test('atomic settlement matches enqueue ${changeOrder ? 'order' : 'time'}',
        () async {
      final backing = InMemoryApplicationChatStorage();
      final storage = _InterleavingArchiveStorage(backing);
      final fixture =
          _Fixture(storage: storage, transport: _ArchiveTransport());
      addTearDown(fixture.dispose);
      await fixture.activate();
      final cancellation = ChatCommandCancellationController();
      final pending = fixture.client.archiveConversation(_authored(),
          cancellationSignal: cancellation.signal);
      await _eventually(
          () => fixture.client.queuedConversationArchives.length == 1);
      final original = (await _read(backing, _identity))!.intents.single;
      final gate = storage.holdNextWrite();
      cancellation.cancel();
      await gate.started.future;
      final replacement = ApplicationChatQueuedConversationArchiveIntentsRecord(
        identity: _identity,
        intents: [
          ApplicationChatQueuedConversationArchiveIntent(
            request: original.request,
            enqueueOrder:
                changeOrder ? original.enqueueOrder + 1 : original.enqueueOrder,
            enqueuedAt: changeOrder
                ? original.enqueuedAt
                : const IsoTimestamp('2032-02-02T00:00:00.000Z'),
          ),
        ],
      );
      await backing.replace(replacement);
      gate.release.complete();
      expect(
          await pending, isA<ChatCommandAborted<ConversationArchiveResult>>());
      expect((await _read(backing, _identity))!.encode(), replacement.encode());
      final visible = fixture.client.queuedConversationArchives.single;
      expect(visible.enqueueOrder, replacement.intents.single.enqueueOrder);
      expect(visible.enqueuedAt,
          DateTime.parse(replacement.intents.single.enqueuedAt.value));
      expect(storage.failedExchanges, 1);
      expect(fixture.transport.patches, isEmpty);
    });
  }

  test('atomic malformed quarantine cannot remove a valid racing replacement',
      () async {
    final backing = InMemoryApplicationChatStorage();
    final storage = _InterleavingArchiveStorage(backing);
    backing.putRawRecordForTesting(
        _identity, _archiveKind, {'accessToken': 'secret-value'});
    final diagnostics = <ChatClientDiagnostic>[];
    final fixture = _Fixture(
        storage: storage,
        transport: _ArchiveTransport(),
        onStorageDiagnostic: diagnostics.add);
    addTearDown(fixture.dispose);
    final gate = storage.holdNextWrite();
    final activation = fixture.activate();
    await gate.started.future;
    final valid = ApplicationChatQueuedConversationArchiveIntentsRecord(
      identity: _identity,
      intents: [
        ApplicationChatQueuedConversationArchiveIntent(
          request: _request('valid-key', archive: true),
          enqueueOrder: 7,
          enqueuedAt: const IsoTimestamp('2032-02-01T00:00:00.000Z'),
        )
      ],
    );
    await backing.replace(valid);
    gate.release.complete();
    await activation;
    expect((await _read(backing, _identity))!.encode(), valid.encode());
    expect(fixture.client.queuedConversationArchives, isEmpty);
    expect(diagnostics.single.code,
        ChatClientDiagnosticCode.conversationArchiveIntentsRejected);
    expect(diagnostics.single.toString(), isNot(contains('secret-value')));
    final recovered =
        _Fixture(storage: backing, transport: _ArchiveTransport());
    addTearDown(recovered.dispose);
    await recovered.activate();
    expect(
        recovered
            .client.queuedConversationArchives.single.request.idempotencyKey,
        'valid-key');
  });

  for (final throwsOnWrite in [false, true]) {
    test(
        'atomic ${throwsOnWrite ? 'failed' : 'exhausted'} mutation never publishes',
        () async {
      final backing = InMemoryApplicationChatStorage();
      final storage = _InterleavingArchiveStorage(backing);
      final diagnostics = <ChatClientDiagnostic>[];
      final fixture = _Fixture(
          storage: storage,
          transport: _ArchiveTransport(),
          onStorageDiagnostic: diagnostics.add);
      addTearDown(fixture.dispose);
      await fixture.activate();
      await fixture.initialize();
      storage.rejectWrites = !throwsOnWrite;
      storage.throwOnWrite = throwsOnWrite;
      final result = await fixture.client.archiveConversation(_authored());
      expect(result,
          isA<ChatCommandValidationFailure<ConversationArchiveResult>>());
      expect(fixture.client.queuedConversationArchives, isEmpty);
      expect(fixture.lifecycle.projectedArchived, isFalse);
      expect(fixture.transport.patches, isEmpty);
      expect(await _read(backing, _identity), isNull);
      expect(diagnostics.single.code,
          ChatClientDiagnosticCode.conversationArchiveIntentsWriteFailed);
      expect(diagnostics.single.toString(), isNot(contains('secret-value')));
      if (!throwsOnWrite) {
        expect(
            storage.failedExchanges, maxApplicationChatStorageMutationAttempts);
      }
    });
  }

  for (final throwsOnWrite in [false, true]) {
    test(
        'atomic failed replacement preserves the committed intent and waiter '
        '(throws: $throwsOnWrite)', () async {
      final backing = InMemoryApplicationChatStorage();
      final storage = _InterleavingArchiveStorage(backing);
      final fixture = _Fixture(
          storage: storage,
          transport: _ArchiveTransport(),
          keys: Queue.of(['original-key', 'replacement-key']));
      addTearDown(fixture.dispose);
      await fixture.activate();
      var originalCompleted = false;
      final original =
          fixture.client.archiveConversation(_authored()).then((result) {
        originalCompleted = true;
        return result;
      });
      await _eventually(
          () => fixture.client.queuedConversationArchives.length == 1);
      final before = (await _read(backing, _identity))!.encode();
      storage.rejectWrites = !throwsOnWrite;
      storage.throwOnWrite = throwsOnWrite;
      expect(await fixture.client.restoreConversation(_authored()),
          isA<ChatCommandValidationFailure<ConversationArchiveResult>>());
      expect((await _read(backing, _identity))!.encode(), before);
      expect(
          fixture
              .client.queuedConversationArchives.single.request.idempotencyKey,
          'original-key');
      expect(fixture.lifecycle.projectedArchived, isTrue);
      expect(originalCompleted, isFalse);
      expect(fixture.transport.patches, isEmpty);
      storage.rejectWrites = false;
      storage.throwOnWrite = false;
      await fixture.initialize();
      expect(
          await original, isA<ChatCommandSuccess<ConversationArchiveResult>>());
      expect(_body(fixture.transport.patches.single)['idempotencyKey'],
          'original-key');
    });
  }

  test('persists the final request before projection, token, or transport',
      () async {
    final backing = InMemoryApplicationChatStorage();
    final storage = _BlockingArchiveStorage(backing);
    final transport = _ArchiveTransport();
    var tokenCalls = 0;
    final fixture = _Fixture(
      storage: storage,
      transport: transport,
      keys: Queue.of(['persisted-key']),
      tokenProvider: () async {
        tokenCalls += 1;
        return 'token';
      },
    );
    await fixture.activate();

    final pending = fixture.client.archiveConversation(
      const ChatSetConversationArchiveInput(
        conversationId: _conversationId,
        expectedLifecycleRevision: 1,
      ),
    );
    await storage.replaceStarted.future;
    expect(fixture.client.queuedConversationArchives, isEmpty);
    expect(fixture.lifecycle.projectedArchived, isFalse);
    expect(tokenCalls, 0);
    expect(transport.patches, isEmpty);

    storage.releaseReplace.complete();
    await _eventually(
      () => fixture.client.queuedConversationArchives.length == 1,
    );
    expect(fixture.lifecycle.projectedArchived, isTrue);
    expect(tokenCalls, 0, reason: 'metadata is not ready');
    final stored = await _read(backing, _identity);
    expect(stored?.intents.single.request.idempotencyKey, 'persisted-key');

    await fixture.initialize();
    expect(await pending, isA<ChatCommandSuccess<ConversationArchiveResult>>());
    expect(_body(transport.patches.single),
        stored!.intents.single.request.toJson());
    await fixture.dispose();
  });

  test('restart replays exact archive and restore requests', () async {
    for (final desiredArchive in [true, false]) {
      final storage = InMemoryApplicationChatStorage();
      final request = _request(
        desiredArchive ? 'archive-key' : 'restore-key',
        archive: desiredArchive,
      );
      await _seed(storage, request, archived: !desiredArchive);
      final fixture = _Fixture(
        storage: storage,
        transport: _ArchiveTransport(),
        keys: Queue.of(['must-not-be-used']),
        hydrateInitialStore: false,
      );

      await fixture.activate();
      expect(
        fixture.client.queuedConversationArchives.single.request.toJson(),
        request.toJson(),
      );
      expect(fixture.lifecycle.projectedArchived, desiredArchive);
      await fixture.initialize();
      await _eventually(() => fixture.transport.patches.length == 1);
      expect(_body(fixture.transport.patches.single), request.toJson());
      expect(
        fixture.transport.patches.single.headers['Idempotency-Key'],
        request.idempotencyKey,
      );
      await _eventually(
          () => fixture.client.queuedConversationArchives.isEmpty);
      await fixture.dispose();
    }
  });

  test('already-equal authority and matching event settle without replay',
      () async {
    final equalStorage = InMemoryApplicationChatStorage();
    await _seed(equalStorage, _request('equal-key', archive: false));
    final equal = _Fixture(
      storage: equalStorage,
      transport: _ArchiveTransport(),
      hydrateInitialStore: false,
    );
    await equal.activate();
    await equal.initialize();
    await _eventually(() => equal.client.queuedConversationArchives.isEmpty);
    expect(equal.transport.patches, isEmpty);
    expect(await _read(equalStorage, _identity), isNull);
    await equal.dispose();

    final eventStorage = InMemoryApplicationChatStorage();
    final request = _request('event-key', archive: true);
    await _seed(eventStorage, request);
    final eventFixture = _Fixture(
      storage: eventStorage,
      transport: _ArchiveTransport(),
      hydrateInitialStore: false,
    );
    await eventFixture.activate();
    eventFixture.client.reduceDurableEvent(_lifecycleEvent(archived: true));
    await _eventually(
      () => eventFixture.client.queuedConversationArchives.isEmpty,
    );
    await eventFixture.initialize();
    expect(eventFixture.transport.patches, isEmpty);
    expect(await _read(eventStorage, _identity), isNull);
    await eventFixture.dispose();
  });

  test('newer divergent lifecycle revision remains an explicit conflict',
      () async {
    final storage = InMemoryApplicationChatStorage();
    await _seed(storage, _request('conflict-key', archive: true));
    final fixture = _Fixture(
      storage: storage,
      transport: _ArchiveTransport(),
      hydrateInitialStore: false,
    );
    await fixture.activate();
    fixture.client.reduceDurableEvent(_lifecycleEvent(archived: false));
    await fixture.initialize();
    await _eventually(
      () =>
          fixture.client.queuedConversationArchives.single.status ==
          ChatQueuedConversationArchiveStatus.lifecycleConflict,
    );
    expect(fixture.transport.patches, isEmpty);
    expect(fixture.lifecycle.projectedArchived, isFalse);
    expect((await _read(storage, _identity))?.intents, hasLength(1));
    await fixture.dispose();
  });

  test('transient and malformed outcomes retain while terminal removes',
      () async {
    final transientStorage = InMemoryApplicationChatStorage();
    final retryGate = Completer<void>();
    final waits = <Duration>[];
    final transient = _Fixture(
      storage: transientStorage,
      transport: _ArchiveTransport(patch: (_) async {
        throw StateError('offline');
      }),
      keys: Queue.of(['transient-key']),
      retryBackoff: (_) => const Duration(seconds: 60),
      retryWait: (delay, _) {
        waits.add(delay);
        return retryGate.future;
      },
    );
    await transient.activate();
    await transient.initialize();
    expect(
      await transient.client
          .archiveConversation(const ChatSetConversationArchiveInput(
        conversationId: _conversationId,
        expectedLifecycleRevision: 1,
      )),
      isA<ChatCommandTransportFailure<ConversationArchiveResult>>(),
    );
    await _eventually(() => waits.isNotEmpty);
    expect(waits.single, const Duration(seconds: 60));
    expect((await _read(transientStorage, _identity))?.intents, hasLength(1));
    await transient.dispose();

    var invalidWaitCalled = false;
    final malformedStorage = InMemoryApplicationChatStorage();
    final malformed = _Fixture(
      storage: malformedStorage,
      transport: _ArchiveTransport(
        patch: (_) async =>
            const HandrailChatHttpResponse(statusCode: 200, body: '{}'),
      ),
      keys: Queue.of(['malformed-key']),
      retryBackoff: (_) => const Duration(seconds: 61),
      retryWait: (_, __) async => invalidWaitCalled = true,
    );
    await malformed.activate();
    await malformed.initialize();
    expect(
      await malformed.client
          .archiveConversation(const ChatSetConversationArchiveInput(
        conversationId: _conversationId,
        expectedLifecycleRevision: 1,
      )),
      isA<ChatCommandMalformedResponse<ConversationArchiveResult>>(),
    );
    expect(invalidWaitCalled, isFalse);
    expect((await _read(malformedStorage, _identity))?.intents, hasLength(1));
    await malformed.dispose();

    final terminalStorage = InMemoryApplicationChatStorage();
    final terminal = _Fixture(
      storage: terminalStorage,
      transport: _ArchiveTransport(
        patch: (_) async => _error(403, 'PERMISSION_DENIED'),
      ),
      keys: Queue.of(['terminal-key']),
    );
    await terminal.activate();
    await terminal.initialize();
    expect(
      await terminal.client
          .archiveConversation(const ChatSetConversationArchiveInput(
        conversationId: _conversationId,
        expectedLifecycleRevision: 1,
      )),
      isA<ChatCommandAuthenticationFailure<ConversationArchiveResult>>(),
    );
    expect(await _read(terminalStorage, _identity), isNull);
    await terminal.dispose();
  });

  test('offline and background pause replay until realtime is foreground-ready',
      () async {
    final storage = InMemoryApplicationChatStorage();
    await _seed(storage, _request('lifecycle-key', archive: true));
    final network = FakeChatRealtimeNetwork(isOnline: false);
    final socket = FakeChatRealtimeSocket();
    final sockets = FakeChatRealtimeSocketFactory()..enqueueSocket(socket);
    final session = ChatRealtimeSessionTransport(
      endpoint: Uri.parse('https://chat.example.test/api/chat'),
      clientPackageVersion: '0.1.3',
      protocolVersion: handrailChatProtocolVersion,
      tokenProvider: () => 'realtime-token',
      socketFactory: sockets.call,
      network: network,
    );
    final fixture = _Fixture(
      storage: storage,
      transport: _ArchiveTransport(),
      hydrateInitialStore: false,
      realtimeSession: session,
      network: network,
    );
    await fixture.activate();
    await fixture.initialize();
    expect(fixture.transport.patches, isEmpty);
    await session.start();
    network.setOnline(true);
    await _eventually(() => sockets.uris.length == 1);
    fixture.client.setApplicationForeground(false);
    socket.emitJson(_acceptedFrame());
    await _eventually(() => session.state is ChatRealtimeConnectedState);
    expect(fixture.transport.patches, isEmpty);
    fixture.client.setApplicationForeground(true);
    await _eventually(() => fixture.transport.patches.length == 1);
    await fixture.dispose();
  });

  test(
      'checkpoint cleanliness, corrupt quarantine, identity and dispose guards',
      () async {
    final storage = InMemoryApplicationChatStorage();
    final gate = Completer<HandrailChatHttpResponse>();
    final fixture = _Fixture(
      storage: storage,
      transport: _ArchiveTransport(patch: (_) => gate.future),
      keys: Queue.of(['checkpoint-key']),
    );
    await fixture.activate();
    await fixture.initialize();
    final pending = fixture.client.archiveConversation(
      const ChatSetConversationArchiveInput(
        conversationId: _conversationId,
        expectedLifecycleRevision: 1,
      ),
    );
    await _eventually(
        () => fixture.client.queuedConversationArchives.length == 1);
    await _eventually(() async => await storage.read(
            _identity, ApplicationChatStorageRecordKind.normalizedSnapshot)
        is ApplicationChatNormalizedSnapshotRecord);
    final checkpoint = await storage.read(
      _identity,
      ApplicationChatStorageRecordKind.normalizedSnapshot,
    ) as ApplicationChatNormalizedSnapshotRecord;
    expect(checkpoint.snapshot.pendingConversationArchiveInputs, isEmpty);
    await fixture.client.dispose();
    expect(await pending, isA<ChatCommandClosed<ConversationArchiveResult>>());
    expect((await _read(storage, _identity))?.intents, hasLength(1));
    await fixture.finishDispose();

    final corruptStorage = InMemoryApplicationChatStorage();
    await _seed(corruptStorage, _request('valid-key', archive: true));
    final corrupt = (await _read(corruptStorage, _identity))!.toJson();
    final payload = corrupt['payload']! as Map<String, Object?>;
    final intent =
        (payload['intents']! as List<Object?>).single as Map<String, Object?>;
    intent['accessToken'] = 'secret-value';
    corruptStorage.putRawRecordForTesting(
      _identity,
      ApplicationChatStorageRecordKind.queuedConversationArchiveIntents,
      corrupt,
    );
    final diagnostics = <ChatClientDiagnostic>[];
    final corruptFixture = _Fixture(
      storage: corruptStorage,
      transport: _ArchiveTransport(),
      onStorageDiagnostic: diagnostics.add,
      hydrateInitialStore: false,
    );
    await corruptFixture.activate();
    expect(corruptFixture.client.queuedConversationArchives, isEmpty);
    expect(
      diagnostics.single.code,
      ChatClientDiagnosticCode.conversationArchiveIntentsRejected,
    );
    expect(diagnostics.single.toString(), isNot(contains('secret-value')));
    expect(await _read(corruptStorage, _identity), isNull);
    await corruptFixture.dispose();

    final backing = InMemoryApplicationChatStorage();
    final blocking = _BlockingArchiveStorage(backing);
    final isolated = _Fixture(
      storage: blocking,
      transport: _ArchiveTransport(),
      keys: Queue.of(['old-key']),
    );
    await isolated.activate();
    final old = isolated.client.archiveConversation(
      const ChatSetConversationArchiveInput(
        conversationId: _conversationId,
        expectedLifecycleRevision: 1,
      ),
    );
    await blocking.replaceStarted.future;
    final replacement = isolated.client.activateStorageIdentity(_otherIdentity);
    blocking.releaseReplace.complete();
    expect(await old, isA<ChatCommandClosed<ConversationArchiveResult>>());
    await replacement;
    expect(isolated.client.queuedConversationArchives, isEmpty);
    expect((await _read(backing, _identity))?.intents, hasLength(1));
    expect(await _read(backing, _otherIdentity), isNull);
    await isolated.dispose();
  });
}

final class _Fixture {
  _Fixture({
    required ApplicationChatStorage storage,
    required this.transport,
    Queue<String>? keys,
    HandrailChatAccessTokenProvider? tokenProvider,
    bool hydrateInitialStore = true,
    ChatConversationArchiveRetryBackoff? retryBackoff,
    ChatConversationArchiveRetryWait? retryWait,
    ChatClientDiagnosticCallback? onStorageDiagnostic,
    this.realtimeSession,
    this.network,
  }) : store = NormalizedSnapshotStore() {
    if (hydrateInitialStore) _seedAuthority(store);
    final generatedKeys = keys ?? Queue.of(['generated-key']);
    client = HandrailChatClient(
      apiBaseUri: Uri.parse('https://chat.example.test/api/chat'),
      tokenProvider: tokenProvider ?? () async => 'access-token',
      transport: transport,
      localStorage: storage,
      storageIdentity: _identity,
      normalizedSnapshotStore: store,
      realtimeSession: realtimeSession,
      generateIdempotencyKey: () => generatedKeys.removeFirst(),
      conversationArchiveClock: () =>
          const IsoTimestamp('2032-02-01T00:00:00.000Z'),
      conversationArchiveRetryBackoff: retryBackoff,
      conversationArchiveRetryWait: retryWait,
      commandRetryOptions: const ChatCommandRetryOptions(
        maxAttempts: 1,
        maxAuthenticationRefreshes: 0,
      ),
      onStorageDiagnostic: onStorageDiagnostic,
    );
  }

  final NormalizedSnapshotStore store;
  final _ArchiveTransport transport;
  final ChatRealtimeSessionTransport? realtimeSession;
  final FakeChatRealtimeNetwork? network;
  late final HandrailChatClient client;
  bool _disposed = false;

  NormalizedConversationLifecycleProjection get lifecycle =>
      store.conversation(_conversationId).lifecycle!;

  Future<void> activate() => client.activateStorageIdentity(_identity);

  Future<void> initialize() async {
    expect(await client.initialize(), isA<ChatClientReadyState>());
  }

  Future<void> dispose() async {
    if (!_disposed) {
      _disposed = true;
      await client.dispose();
    }
    await finishDispose();
  }

  Future<void> finishDispose() async {
    _disposed = true;
    await realtimeSession?.dispose();
    await network?.dispose();
    await store.close();
  }
}

final class _ArchiveTransport implements HandrailChatHttpTransport {
  _ArchiveTransport({this.patch});

  final Future<HandrailChatHttpResponse> Function(HandrailChatHttpRequest)?
      patch;
  final List<HandrailChatHttpRequest> requests = [];

  Iterable<HandrailChatHttpRequest> get patches =>
      requests.where((request) => request.method == 'PATCH');

  @override
  Future<HandrailChatHttpResponse> send(HandrailChatHttpRequest request) {
    requests.add(request);
    if (request.method == 'GET' && request.uri.path.endsWith('/_meta')) {
      return Future.value(const HandrailChatHttpResponse(
        statusCode: 200,
        body: _metadataJson,
      ));
    }
    return patch?.call(request) ?? Future.value(_success(_body(request)));
  }
}

final class _BlockingArchiveStorage implements ApplicationChatStorage {
  _BlockingArchiveStorage(this.backing);

  final InMemoryApplicationChatStorage backing;
  final Completer<void> replaceStarted = Completer<void>();
  final Completer<void> releaseReplace = Completer<void>();

  @override
  Future<ApplicationChatStorageRecord?> read(
    ApplicationChatStorageIdentity identity,
    ApplicationChatStorageRecordKind kind,
  ) =>
      backing.read(identity, kind);

  @override
  Future<void> replace(ApplicationChatStorageRecord record) async {
    if (record.kind ==
        ApplicationChatStorageRecordKind.queuedConversationArchiveIntents) {
      if (!replaceStarted.isCompleted) replaceStarted.complete();
      await releaseReplace.future;
    }
    await backing.replace(record);
  }

  @override
  Future<void> remove(
    ApplicationChatStorageIdentity identity,
    ApplicationChatStorageRecordKind kind,
  ) =>
      backing.remove(identity, kind);

  @override
  Future<void> clearForLogout(ApplicationChatStorageIdentity identity) =>
      backing.clearForLogout(identity);

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

ChatSetConversationArchiveInput _authored([
  ConversationId conversationId = _conversationId,
]) =>
    ChatSetConversationArchiveInput(
      conversationId: conversationId,
      expectedLifecycleRevision: 1,
    );

ConversationArchiveInput _request(
  String key, {
  required bool archive,
  ConversationId conversationId = _conversationId,
}) =>
    ConversationArchiveInput.fromJson(<String, Object?>{
      'operation': 'set_conversation_archive',
      'intent': archive ? 'archive' : 'restore',
      'conversationId': conversationId.toJson(),
      'expectedLifecycleRevision': 1,
      'idempotencyKey': key,
    });

Future<void> _seed(
  ApplicationChatStorage storage,
  ConversationArchiveInput request, {
  bool archived = false,
}) async {
  final store = NormalizedSnapshotStore();
  _seedAuthority(store, archived: archived);
  await storage.replace(ApplicationChatNormalizedSnapshotRecord(
    identity: _identity,
    snapshot: store.canonicalPersistenceSnapshot(),
  ));
  await store.close();
  await storage.replace(ApplicationChatQueuedConversationArchiveIntentsRecord(
    identity: _identity,
    intents: [
      ApplicationChatQueuedConversationArchiveIntent(
        request: request,
        enqueueOrder: 1,
        enqueuedAt: const IsoTimestamp('2032-02-01T00:00:00.000Z'),
      ),
    ],
  ));
}

void _seedAuthority(
  NormalizedSnapshotStore store, {
  bool archived = false,
  ConversationId conversationId = _conversationId,
}) {
  store.hydrateConversationList(ConversationListSnapshot.fromJson({
    'kind': 'conversation_list',
    'scope': {'type': 'organization'},
    'items': [
      _conversation(archived: archived, conversationId: conversationId)
    ],
    'page': <String, Object?>{},
    '_meta': _metadata(),
  }));
  final request = _request('seed-authority',
      archive: archived, conversationId: conversationId);
  store.beginOptimisticConversationArchive(request);
  store.reconcileOptimisticConversationArchive(
    request.idempotencyKey,
    ConversationArchiveResult.fromJson(
      _result(request, status: 'already_requested_state', revision: 1),
      expectedInput: request,
    ),
  );
}

Map<String, Object?> _conversation({
  required bool archived,
  ConversationId conversationId = _conversationId,
}) =>
    <String, Object?>{
      'id': conversationId.toJson(),
      'tenantId': _identity.tenantId.toJson(),
      'type': 'channel',
      'name': 'Archive recovery',
      'visibility': 'public',
      'createdAt': '2032-01-01T00:00:00.000Z',
      'updatedAt': '2032-01-01T00:00:00.000Z',
      if (archived) 'archivedAt': '2032-01-01T00:00:00.000Z',
      if (archived) 'archivedByUserId': _identity.userId.toJson(),
      'latestSequence': 0,
      'activityAt': '2032-01-01T00:00:00.000Z',
      'unreadMentionCount': 0,
      'currentMember': <String, Object?>{
        'tenantId': _identity.tenantId.toJson(),
        'conversationId': conversationId.toJson(),
        'userId': _identity.userId.toJson(),
        'role': 'member',
        'state': 'active',
        'joinedAt': '2032-01-01T00:00:00.000Z',
        'updatedAt': '2032-01-01T00:00:00.000Z',
      },
      'currentReadState': <String, Object?>{
        'conversationId': conversationId.toJson(),
        'userId': _identity.userId.toJson(),
        'lastReadSequence': 0,
        'updatedAt': '2032-01-01T00:00:00.000Z',
      },
      'currentPreference': <String, Object?>{
        'conversationId': conversationId.toJson(),
        'userId': _identity.userId.toJson(),
        'notificationPreference': 'mentions',
        'isStarred': false,
        'mute': <String, Object?>{'muted': false},
        'updatedAt': '2032-01-01T00:00:00.000Z',
      },
      'activeMemberUserIds': [_identity.userId.toJson()],
    };

KnownDurableEvent _lifecycleEvent({required bool archived}) =>
    KnownDurableEvent.fromJson(
      <String, Object?>{
        'eventId': archived ? 'archive-event' : 'restore-event',
        'protocolVersion': handrailChatProtocolVersion,
        'tenantId': _identity.tenantId.toJson(),
        'streamId': _conversationId.toJson(),
        'type': archived ? 'conversation.archived' : 'conversation.restored',
        'occurredAt': '2032-02-01T00:01:00.000Z',
        'payload': <String, Object?>{
          'conversationId': _conversationId.toJson(),
          'intent': archived ? 'archive' : 'restore',
          'previousState': archived ? 'active' : 'archived',
          'currentState': archived ? 'archived' : 'active',
          'previousLifecycleRevision': 1,
          'currentLifecycleRevision': 2,
        },
      },
      trustedIdentity: DurableEventTrustedIdentity(
        tenantId: _identity.tenantId,
        userId: _identity.userId,
      ),
    );

Future<ApplicationChatQueuedConversationArchiveIntentsRecord?> _read(
  ApplicationChatStorage storage,
  ApplicationChatStorageIdentity identity,
) async =>
    await storage.read(
      identity,
      ApplicationChatStorageRecordKind.queuedConversationArchiveIntents,
    ) as ApplicationChatQueuedConversationArchiveIntentsRecord?;

HandrailChatHttpResponse _success(Map<String, Object?> body) {
  final request = ConversationArchiveInput.fromJson(body);
  return HandrailChatHttpResponse(
    statusCode: 200,
    body: jsonEncode(_result(request)),
  );
}

Map<String, Object?> _result(
  ConversationArchiveInput request, {
  String status = 'applied',
  int? revision,
}) =>
    <String, Object?>{
      'operation': request.operation,
      'intent': request.intent.toJson(),
      'reconciliationStatus': status,
      'conversationId': request.conversationId.toJson(),
      'expectedLifecycleRevision': request.expectedLifecycleRevision,
      'lifecycleRevision': revision ?? request.expectedLifecycleRevision + 1,
      'archiveState': request.intent == ConversationArchiveIntent.archive
          ? <String, Object?>{
              'status': 'archived',
              'archivedAt': '2032-02-01T00:01:00.000Z',
              'archivedByUserId': _identity.userId.toJson(),
            }
          : const <String, Object?>{'status': 'active'},
    };

Map<String, Object?> _body(HandrailChatHttpRequest request) =>
    (jsonDecode(request.body!) as Map).cast<String, Object?>();

HandrailChatHttpResponse _error(int status, String code) =>
    HandrailChatHttpResponse(
      statusCode: status,
      body: jsonEncode(<String, Object?>{
        'error': <String, Object?>{'code': code, 'message': 'request failed'},
      }),
    );

Future<void> _eventually(FutureOr<bool> Function() predicate) async {
  for (var attempt = 0; attempt < 500; attempt += 1) {
    if (await predicate()) return;
    await Future<void>.delayed(Duration.zero);
  }
  fail('Condition was not reached.');
}

Map<String, Object?> _acceptedFrame() => <String, Object?>{
      'type': 'chat.session.accepted',
      'metadata': jsonDecode(_metadataJson),
      'tenantId': _identity.tenantId.toJson(),
      'actorStreamId': 'user:${_identity.userId.value}',
      'deviceId': _identity.deviceId.toJson(),
      'sessionId': 'session-1',
    };

Map<String, Object?> _metadata() => <String, Object?>{
      'packageVersion': '0.1.3',
      'protocolVersion': handrailChatProtocolVersion,
      'schemaVersion': 9,
      'enabledFeatures': <String, Object?>{
        conversationSnapshotFeature: true,
      },
      'supportedProtocolRange': <String, Object?>{
        'minimumVersion': handrailChatProtocolVersion,
        'maximumVersion': handrailChatProtocolVersion,
      },
      'feature': <String, Object?>{
        'name': conversationSnapshotFeature,
        'version': conversationSnapshotVersion,
      },
    };

const _metadataJson = '''
{
  "packageVersion": "0.1.3",
  "protocolVersion": 4,
  "schemaVersion": 9,
  "enabledFeatures": {"realtime": true, "conversation_snapshot": true},
  "supportedProtocolRange": {"minimumVersion": 4, "maximumVersion": 4}
}
''';

const _archiveKind =
    ApplicationChatStorageRecordKind.queuedConversationArchiveIntents;

final class _ArchiveWriteGate {
  final started = Completer<void>();
  final release = Completer<void>();
}

/// Models another storage writer after a read but before the next write.
/// Legacy writes also run the hook so lost-update regressions fail on old code.
final class _InterleavingArchiveStorage
    implements AtomicApplicationChatStorage {
  _InterleavingArchiveStorage(this.backing);
  final InMemoryApplicationChatStorage backing;
  Future<void> Function()? beforeWrite;
  int failedExchanges = 0;
  bool rejectWrites = false;
  bool throwOnWrite = false;

  _ArchiveWriteGate holdNextWrite() {
    final gate = _ArchiveWriteGate();
    beforeWrite = () async {
      gate.started.complete();
      await gate.release.future;
    };
    return gate;
  }

  final proposals = <ApplicationChatQueuedConversationArchiveIntentsRecord?>[];

  Future<void> _onWrite(ApplicationChatStorageRecordKind kind) async {
    if (kind != _archiveKind) return;
    final hook = beforeWrite;
    beforeWrite = null;
    await hook?.call();
  }

  @override
  Future<String?> readEncoded(ApplicationChatStorageIdentity identity,
      ApplicationChatStorageRecordKind kind) {
    return backing.readEncoded(identity, kind);
  }

  @override
  Future<ApplicationChatStorageRecord?> read(
      ApplicationChatStorageIdentity identity,
      ApplicationChatStorageRecordKind kind) {
    return backing.read(identity, kind);
  }

  @override
  Future<bool> compareExchange(
      ApplicationChatStorageIdentity identity,
      ApplicationChatStorageRecordKind kind,
      String? expected,
      String? replacement) async {
    if (kind == _archiveKind) {
      proposals.add(replacement == null
          ? null
          : ApplicationChatStorageRecord.decode(replacement)
              as ApplicationChatQueuedConversationArchiveIntentsRecord);
      if (throwOnWrite) throw StateError('secret-value');
      if (rejectWrites) {
        failedExchanges++;
        return false;
      }
    }
    await _onWrite(kind);
    final committed =
        await backing.compareExchange(identity, kind, expected, replacement);
    if (!committed && kind == _archiveKind) failedExchanges++;
    return committed;
  }

  @override
  Future<void> replace(ApplicationChatStorageRecord record) async {
    await _onWrite(record.kind);
    await backing.replace(record);
  }

  @override
  Future<void> remove(ApplicationChatStorageIdentity identity,
      ApplicationChatStorageRecordKind kind) async {
    await _onWrite(kind);
    await backing.remove(identity, kind);
  }

  @override
  Future<void> clearForLogout(ApplicationChatStorageIdentity identity) =>
      backing.clearForLogout(identity);
  @override
  Future<void> clearForIdentityChange(
          {required ApplicationChatStorageIdentity previousIdentity,
          required ApplicationChatStorageIdentity nextIdentity}) =>
      backing.clearForIdentityChange(
          previousIdentity: previousIdentity, nextIdentity: nextIdentity);
}
