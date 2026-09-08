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
const _initialPreference = <String, Object?>{
  'notificationPreference': 'mentions',
  'isStarred': false,
  'mute': <String, Object?>{'muted': false},
};
const _desiredPreference = <String, Object?>{
  'notificationPreference': 'none',
  'isStarred': true,
  'mute': <String, Object?>{'muted': true},
};

void main() {
  test('atomic concurrent conversations survive a failed exchange', () async {
    final backing = InMemoryApplicationChatStorage();
    final storage = _InterleavingPreferenceStorage(backing);
    final first = _Fixture(
        storage: storage,
        transport: _PreferenceTransport(),
        keys: Queue.of(['first-key']));
    final second = _Fixture(
        storage: backing,
        transport: _PreferenceTransport(),
        keys: Queue.of(['second-key']));
    addTearDown(first.dispose);
    addTearDown(second.dispose);
    await first.activate();
    await second.activate();
    const other = ConversationId('conversation-2');
    second.store.hydrateConversationDetail(_detail(other));
    final gate = storage.holdNextWrite();
    final pending = first.client.updateConversationPreference(_authored());
    await gate.started.future;
    expect(first.client.queuedConversationPreferences, isEmpty);
    expect(
        first.store
            .conversationPreference(_conversationId)
            .preference
            ?.isStarred,
        isFalse);
    final otherPending =
        second.client.updateConversationPreference(_authored(other));
    await _eventually(
        () => second.client.queuedConversationPreferences.length == 1);
    gate.release.complete();
    await _eventually(
        () => first.client.queuedConversationPreferences.length == 2);
    final committed = (await _readPreferences(backing, _identity))!;
    expect(committed.intents.map((intent) => intent.request.idempotencyKey),
        ['second-key', 'first-key']);
    expect(committed.intents.map((intent) => intent.enqueueOrder), [1, 2]);
    expect(storage.failedExchanges, 1);
    expect(first.client.queuedConversationPreferences.last.enqueueOrder, 2);
    await first.dispose();
    await second.dispose();
    await pending;
    await otherPending;
  });

  test('atomic same-conversation replacement publishes the committed winner',
      () async {
    final backing = InMemoryApplicationChatStorage();
    final storage = _InterleavingPreferenceStorage(backing);
    final first = _Fixture(
        storage: storage,
        transport: _PreferenceTransport(),
        keys: Queue.of(['first-key']));
    final second = _Fixture(
        storage: backing,
        transport: _PreferenceTransport(),
        keys: Queue.of(['second-key']));
    addTearDown(first.dispose);
    addTearDown(second.dispose);
    await first.activate();
    await second.activate();
    final gate = storage.holdNextWrite();
    final pending = first.client.updateConversationPreference(_authored());
    await gate.started.future;
    final otherPending = second.client
        .updateConversationPreference(_authored(_conversationId, false));
    await _eventually(
        () => second.client.queuedConversationPreferences.length == 1);
    final before = (await _readPreferences(backing, _identity))!.intents.single;
    gate.release.complete();
    await _eventually(
        () => first.client.queuedConversationPreferences.length == 1);
    final winner = (await _readPreferences(backing, _identity))!.intents.single;
    expect(winner.request.idempotencyKey, 'first-key');
    expect(winner.request.preference.isStarred, isTrue);
    expect(winner.enqueueOrder, before.enqueueOrder);
    expect(winner.enqueuedAt, before.enqueuedAt);
    expect(first.client.queuedConversationPreferences.single.request.toJson(),
        winner.request.toJson());
    expect(storage.failedExchanges, 1);
    await first.dispose();
    await second.dispose();
    await pending;
    await otherPending;
  });

  test('atomic stale cancellation preserves replacement and unrelated work',
      () async {
    final backing = InMemoryApplicationChatStorage();
    final storage = _InterleavingPreferenceStorage(backing);
    final first = _Fixture(
        storage: storage,
        transport: _PreferenceTransport(),
        keys: Queue.of(['stale-key']));
    final second = _Fixture(
        storage: backing,
        transport: _PreferenceTransport(),
        keys: Queue.of(['new-key', 'other-key']));
    addTearDown(first.dispose);
    addTearDown(second.dispose);
    await first.activate();
    await second.activate();
    final cancellation = ChatCommandCancellationController();
    final pending = first.client.updateConversationPreference(_authored(),
        cancellationSignal: cancellation.signal);
    await _eventually(
        () => first.client.queuedConversationPreferences.length == 1);
    final gate = storage.holdNextWrite();
    cancellation.cancel();
    await gate.started.future;
    final replacement = second.client
        .updateConversationPreference(_authored(_conversationId, false));
    await _eventually(
        () => second.client.queuedConversationPreferences.length == 1);
    const other = ConversationId('conversation-2');
    second.store.hydrateConversationDetail(_detail(other));
    final unrelated =
        second.client.updateConversationPreference(_authored(other));
    await _eventually(
        () => second.client.queuedConversationPreferences.length == 2);
    gate.release.complete();
    expect(await pending,
        isA<ChatCommandAborted<UpdateConversationPreferenceResult>>());
    final committed = (await _readPreferences(backing, _identity))!;
    expect(committed.intents.map((intent) => intent.request.idempotencyKey),
        ['new-key', 'other-key']);
    expect(
        first.client.queuedConversationPreferences
            .map((intent) => intent.request.idempotencyKey),
        ['new-key', 'other-key']);
    expect(storage.failedExchanges, 1);
    await first.dispose();
    await second.dispose();
    await replacement;
    await unrelated;
  });

  test('atomic malformed quarantine cannot remove a valid racing replacement',
      () async {
    final backing = InMemoryApplicationChatStorage();
    final storage = _InterleavingPreferenceStorage(backing);
    backing.putRawRecordForTesting(
        _identity, _preferenceKind, {'accessToken': 'secret-value'});
    final diagnostics = <ChatClientDiagnostic>[];
    final fixture = _Fixture(
        storage: storage,
        transport: _PreferenceTransport(),
        onStorageDiagnostic: diagnostics.add);
    addTearDown(fixture.dispose);
    final gate = storage.holdNextWrite();
    final activation = fixture.activate();
    await gate.started.future;
    final valid = ApplicationChatQueuedConversationPreferenceIntentsRecord(
      identity: _identity,
      intents: [
        ApplicationChatQueuedConversationPreferenceIntent(
          request: _request(
              key: 'valid-key',
              expectedRevision: 0,
              preference: _desiredPreference),
          enqueueOrder: 7,
          enqueuedAt: const IsoTimestamp('2032-02-01T00:00:00.000Z'),
        )
      ],
    );
    await backing.replace(valid);
    gate.release.complete();
    await activation;
    expect(
        (await _readPreferences(backing, _identity))!.encode(), valid.encode());
    expect(fixture.client.queuedConversationPreferences, isEmpty);
    expect(diagnostics.single.code,
        ChatClientDiagnosticCode.conversationPreferenceIntentsRejected);
    expect(diagnostics.single.toString(), isNot(contains('secret-value')));
    final recovered =
        _Fixture(storage: backing, transport: _PreferenceTransport());
    addTearDown(recovered.dispose);
    await recovered.activate();
    expect(
        recovered
            .client.queuedConversationPreferences.single.request.idempotencyKey,
        'valid-key');
  });

  for (final throwsOnWrite in [false, true]) {
    test(
        'atomic ${throwsOnWrite ? 'failed' : 'exhausted'} mutation never publishes',
        () async {
      final backing = InMemoryApplicationChatStorage();
      final storage = _InterleavingPreferenceStorage(backing);
      final diagnostics = <ChatClientDiagnostic>[];
      final fixture = _Fixture(
          storage: storage,
          transport: _PreferenceTransport(),
          onStorageDiagnostic: diagnostics.add);
      addTearDown(fixture.dispose);
      await fixture.activate();
      await fixture.initialize();
      storage.rejectWrites = !throwsOnWrite;
      storage.throwOnWrite = throwsOnWrite;
      final result =
          await fixture.client.updateConversationPreference(_authored());
      expect(
          result,
          isA<
              ChatCommandValidationFailure<
                  UpdateConversationPreferenceResult>>());
      expect(fixture.client.queuedConversationPreferences, isEmpty);
      expect(
          fixture.store
              .conversationPreference(_conversationId)
              .preference
              ?.isStarred,
          isFalse);
      expect(fixture.transport.patches, isEmpty);
      expect(await _readPreferences(backing, _identity), isNull);
      expect(diagnostics.single.code,
          ChatClientDiagnosticCode.conversationPreferenceIntentsWriteFailed);
      expect(diagnostics.single.toString(), isNot(contains('secret-value')));
      if (!throwsOnWrite) {
        expect(
            storage.failedExchanges, maxApplicationChatStorageMutationAttempts);
      }
    });
  }

  test('persists before projection, token access, or transport', () async {
    final backing = InMemoryApplicationChatStorage();
    final storage = _BlockingPreferenceStorage(backing);
    final transport = _PreferenceTransport();
    var tokenCalls = 0;
    final fixture = _Fixture(
      storage: storage,
      transport: transport,
      tokenProvider: () async {
        tokenCalls += 1;
        return 'token';
      },
      keys: Queue.of(['persisted-key']),
    );
    await fixture.activate();

    final pending = fixture.client.updateConversationPreference(_authored());
    await storage.replaceStarted.future;
    expect(fixture.client.queuedConversationPreferences, isEmpty);
    expect(
      fixture.store
          .conversationPreference(_conversationId)
          .preference
          ?.isStarred,
      isFalse,
    );
    expect(tokenCalls, 0);
    expect(transport.patches, isEmpty);

    storage.releaseReplace.complete();
    await _eventually(
      () => fixture.client.queuedConversationPreferences.length == 1,
    );
    expect(
      fixture.store
          .conversationPreference(_conversationId)
          .preference
          ?.isStarred,
      isTrue,
    );
    expect(tokenCalls, 0, reason: 'metadata is not ready');
    await fixture.initialize();
    expect(
      await pending,
      isA<ChatCommandSuccess<UpdateConversationPreferenceResult>>(),
    );
    expect(_body(transport.patches.single)['idempotencyKey'], 'persisted-key');
    expect(await _readPreferences(backing, _identity), isNull);
    await fixture.dispose();
  });

  test('restart restores desired state and replays the exact request',
      () async {
    final storage = InMemoryApplicationChatStorage();
    final request = _request(
      key: 'restart-key',
      expectedRevision: 0,
      preference: _desiredPreference,
    );
    await _seedSnapshotAndPreferences(storage, request: request);
    final fixture = _Fixture(
      storage: storage,
      transport: _PreferenceTransport(),
      keys: Queue.of(['must-not-be-used']),
      hydrateInitialStore: false,
    );

    await fixture.activate();
    expect(fixture.client.queuedConversationPreferences.single.request.toJson(),
        request.toJson());
    expect(
      fixture.store
          .conversationPreference(_conversationId)
          .preference
          ?.isStarred,
      isTrue,
    );
    await fixture.initialize();
    await _eventually(() => fixture.transport.patches.length == 1);
    final sent = fixture.transport.patches.single;
    expect(_body(sent), request.toJson());
    expect(sent.headers['Idempotency-Key'], 'restart-key');
    await _eventually(
      () => fixture.client.queuedConversationPreferences.isEmpty,
    );
    await fixture.dispose();
  });

  test('older, equal, and newer canonical authority are handled safely',
      () async {
    final olderStorage = InMemoryApplicationChatStorage();
    await _seedSnapshotAndPreferences(
      olderStorage,
      request: _request(
        key: 'older-key',
        expectedRevision: 1,
        preference: _desiredPreference,
      ),
    );
    final older = _Fixture(
      storage: olderStorage,
      transport: _PreferenceTransport(),
      hydrateInitialStore: false,
    );
    await older.activate();
    await older.initialize();
    expect(
      older.client.queuedConversationPreferences.single.status,
      ChatQueuedConversationPreferenceStatus.waitingForCanonicalBase,
    );
    expect(older.transport.patches, isEmpty);
    await older.dispose();

    final equalStorage = InMemoryApplicationChatStorage();
    await _seedSnapshotAndPreferences(
      equalStorage,
      request: _request(
        key: 'equal-key',
        expectedRevision: 0,
        preference: _initialPreference,
      ),
    );
    final equal = _Fixture(
      storage: equalStorage,
      transport: _PreferenceTransport(),
      hydrateInitialStore: false,
    );
    await equal.activate();
    await equal.initialize();
    await _eventually(
      () => equal.client.queuedConversationPreferences.isEmpty,
    );
    expect(equal.transport.patches, isEmpty);
    await equal.dispose();

    final newerMatchingStorage = InMemoryApplicationChatStorage();
    await _seedSnapshotAndPreferences(
      newerMatchingStorage,
      request: _request(
        key: 'newer-match-key',
        expectedRevision: 0,
        preference: _desiredPreference,
      ),
      revision: 1,
      canonical: _desiredPreference,
    );
    final newerMatching = _Fixture(
      storage: newerMatchingStorage,
      transport: _PreferenceTransport(),
      hydrateInitialStore: false,
    );
    await newerMatching.activate();
    await newerMatching.initialize();
    await _eventually(
      () => newerMatching.client.queuedConversationPreferences.isEmpty,
    );
    expect(newerMatching.transport.patches, isEmpty);
    await newerMatching.dispose();

    final conflictStorage = InMemoryApplicationChatStorage();
    await _seedSnapshotAndPreferences(
      conflictStorage,
      request: _request(
        key: 'conflict-key',
        expectedRevision: 0,
        preference: _desiredPreference,
      ),
      revision: 1,
      canonical: const <String, Object?>{
        'notificationPreference': 'all',
        'isStarred': false,
        'mute': <String, Object?>{'muted': false},
      },
    );
    final conflict = _Fixture(
      storage: conflictStorage,
      transport: _PreferenceTransport(),
      hydrateInitialStore: false,
    );
    await conflict.activate();
    await conflict.initialize();
    expect(
      conflict.client.queuedConversationPreferences.single.status,
      ChatQueuedConversationPreferenceStatus.revisionConflict,
    );
    expect(conflict.transport.patches, isEmpty);
    expect(
      conflict.store
          .conversationPreference(_conversationId)
          .preference
          ?.notificationPreference,
      'all',
    );
    await conflict.dispose();
  });

  test('matching canonical event settles retained work before HTTP', () async {
    final storage = InMemoryApplicationChatStorage();
    final request = _request(
      key: 'event-key',
      expectedRevision: 0,
      preference: _desiredPreference,
    );
    await _seedSnapshotAndPreferences(storage, request: request);
    final fixture = _Fixture(
      storage: storage,
      transport: _PreferenceTransport(),
      hydrateInitialStore: false,
    );
    await fixture.activate();
    fixture.client.reduceDurableEvent(_preferenceEvent(request));
    await _eventually(
      () => fixture.client.queuedConversationPreferences.isEmpty,
    );
    await fixture.initialize();
    expect(fixture.transport.patches, isEmpty);
    expect(await _readPreferences(storage, _identity), isNull);
    await fixture.dispose();
  });

  test('transient and malformed outcomes retain; terminal outcome removes',
      () async {
    final waits = <Duration>[];
    final waitGate = Completer<void>();
    final transientStorage = InMemoryApplicationChatStorage();
    final transient = _Fixture(
      storage: transientStorage,
      transport: _PreferenceTransport(
        patch: (_) async => throw StateError('offline'),
      ),
      keys: Queue.of(['transient-key']),
      retryBackoff: (_) => const Duration(seconds: 60),
      retryWait: (delay, signal) {
        waits.add(delay);
        return waitGate.future;
      },
    );
    await transient.activate();
    await transient.initialize();
    expect(
      await transient.client.updateConversationPreference(_authored()),
      isA<ChatCommandTransportFailure<UpdateConversationPreferenceResult>>(),
    );
    await _eventually(() => waits.isNotEmpty);
    expect(waits.single, const Duration(seconds: 60));
    expect(
      (await _readPreferences(transientStorage, _identity))?.intents,
      hasLength(1),
    );
    await transient.dispose();

    var boundedWaitCalled = false;
    final malformedStorage = InMemoryApplicationChatStorage();
    final malformed = _Fixture(
      storage: malformedStorage,
      transport: _PreferenceTransport(
        patch: (_) async => const HandrailChatHttpResponse(
          statusCode: 200,
          body: '{}',
        ),
      ),
      keys: Queue.of(['malformed-key']),
      retryBackoff: (_) => const Duration(seconds: 61),
      retryWait: (_, __) async {
        boundedWaitCalled = true;
      },
    );
    await malformed.activate();
    await malformed.initialize();
    expect(
      await malformed.client.updateConversationPreference(_authored()),
      isA<ChatCommandMalformedResponse<UpdateConversationPreferenceResult>>(),
    );
    expect(boundedWaitCalled, isFalse);
    expect(
      (await _readPreferences(malformedStorage, _identity))?.intents,
      hasLength(1),
    );
    await malformed.dispose();

    final terminalStorage = InMemoryApplicationChatStorage();
    final terminal = _Fixture(
      storage: terminalStorage,
      transport: _PreferenceTransport(
        patch: (_) async => _error(403, 'PERMISSION_DENIED'),
      ),
      keys: Queue.of(['terminal-key']),
    );
    await terminal.activate();
    await terminal.initialize();
    expect(
      await terminal.client.updateConversationPreference(_authored()),
      isA<
          ChatCommandAuthenticationFailure<
              UpdateConversationPreferenceResult>>(),
    );
    expect(await _readPreferences(terminalStorage, _identity), isNull);
    expect(
      terminal.store
          .conversationPreference(_conversationId)
          .preference
          ?.isStarred,
      isFalse,
    );
    await terminal.dispose();
  });

  test('HTTP revision conflict and cancellation after dispatch remain durable',
      () async {
    final conflictStorage = InMemoryApplicationChatStorage();
    final conflict = _Fixture(
      storage: conflictStorage,
      transport: _PreferenceTransport(patch: (wire) async {
        final request = UpdateConversationPreferenceInput.fromJson(_body(wire));
        return HandrailChatHttpResponse(
          statusCode: 409,
          body: jsonEncode(_resultJson(
            request,
            status: 'preference_revision_conflict',
            canonical: _initialPreference,
          )),
        );
      }),
      keys: Queue.of(['http-conflict-key']),
    );
    await conflict.activate();
    await conflict.initialize();
    expect(
      await conflict.client.updateConversationPreference(_authored()),
      isA<ChatCommandSuccess<UpdateConversationPreferenceResult>>(),
    );
    expect(
      conflict.client.queuedConversationPreferences.single.status,
      ChatQueuedConversationPreferenceStatus.revisionConflict,
    );
    expect(
      (await _readPreferences(conflictStorage, _identity))?.intents,
      hasLength(1),
    );
    await conflict.dispose();

    final cancelledStorage = InMemoryApplicationChatStorage();
    final dispatchStarted = Completer<void>();
    final cancelled = _Fixture(
      storage: cancelledStorage,
      transport: _PreferenceTransport(patch: (_) {
        if (!dispatchStarted.isCompleted) dispatchStarted.complete();
        return Completer<HandrailChatHttpResponse>().future;
      }),
      keys: Queue.of(['cancelled-key']),
      retryWait: (_, signal) {
        final stopped = Completer<void>();
        signal.onCancelled.listen((_) {
          if (!stopped.isCompleted) stopped.complete();
        });
        return stopped.future;
      },
    );
    await cancelled.activate();
    await cancelled.initialize();
    final cancellation = ChatCommandCancellationController();
    final pending = cancelled.client.updateConversationPreference(
      _authored(),
      cancellationSignal: cancellation.signal,
    );
    await dispatchStarted.future;
    cancellation.cancel();
    expect(
      await pending,
      isA<ChatCommandAborted<UpdateConversationPreferenceResult>>(),
    );
    expect(
      (await _readPreferences(cancelledStorage, _identity))?.intents,
      hasLength(1),
    );
    await cancelled.dispose();
  });

  test('offline and background pause replay until realtime identity is ready',
      () async {
    final storage = InMemoryApplicationChatStorage();
    await _seedSnapshotAndPreferences(
      storage,
      request: _request(
        key: 'lifecycle-key',
        expectedRevision: 0,
        preference: _desiredPreference,
      ),
    );
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
      transport: _PreferenceTransport(),
      hydrateInitialStore: false,
      realtimeSession: session,
      network: network,
    );
    await fixture.activate();
    await fixture.initialize();
    expect(fixture.transport.patches, isEmpty, reason: 'offline');
    fixture.client.setApplicationForeground(false);
    await session.start();
    network.setOnline(true);
    await _eventually(() => sockets.uris.length == 1);
    socket.emitJson(_acceptedFrame());
    await _eventually(() => session.state is ChatRealtimeConnectedState);
    expect(fixture.transport.patches, isEmpty, reason: 'backgrounded');
    fixture.client.setApplicationForeground(true);
    await _eventually(() => fixture.transport.patches.length == 1);
    await fixture.dispose();
  });

  test('canonical checkpoints exclude queue state and corrupt data quarantines',
      () async {
    final checkpointStorage = InMemoryApplicationChatStorage();
    final gate = Completer<HandrailChatHttpResponse>();
    final checkpoint = _Fixture(
      storage: checkpointStorage,
      transport: _PreferenceTransport(patch: (_) => gate.future),
      keys: Queue.of(['checkpoint-key']),
    );
    await checkpoint.activate();
    await checkpoint.initialize();
    final pending = checkpoint.client.updateConversationPreference(_authored());
    await _eventually(
      () => checkpoint.client.queuedConversationPreferences.length == 1,
    );
    await _eventually(() async {
      final record = await checkpointStorage.read(
        _identity,
        ApplicationChatStorageRecordKind.normalizedSnapshot,
      );
      return record is ApplicationChatNormalizedSnapshotRecord;
    });
    final normalized = await checkpointStorage.read(
      _identity,
      ApplicationChatStorageRecordKind.normalizedSnapshot,
    ) as ApplicationChatNormalizedSnapshotRecord;
    expect(normalized.snapshot.pendingConversationPreferenceIntents, isEmpty);
    expect(
      normalized.snapshot.currentUserPreferences[_conversationId]?.isStarred,
      isFalse,
    );
    await checkpoint.client.dispose();
    expect(
      await pending,
      isA<ChatCommandClosed<UpdateConversationPreferenceResult>>(),
    );
    expect(
      (await _readPreferences(checkpointStorage, _identity))?.intents,
      hasLength(1),
    );
    await checkpoint.finishDispose();

    final corruptStorage = InMemoryApplicationChatStorage();
    final valid = ApplicationChatQueuedConversationPreferenceIntentsRecord(
      identity: _identity,
      intents: [
        ApplicationChatQueuedConversationPreferenceIntent(
          request: _request(
            key: 'corrupt-key',
            expectedRevision: 0,
            preference: _desiredPreference,
          ),
          enqueueOrder: 1,
          enqueuedAt: const IsoTimestamp('2032-02-01T00:00:00.000Z'),
        ),
      ],
    ).toJson();
    final payload = valid['payload']! as Map<String, Object?>;
    final intents = payload['intents']! as List<Object?>;
    (intents.single as Map<String, Object?>)['accessToken'] = 'secret-value';
    corruptStorage.putRawRecordForTesting(
      _identity,
      ApplicationChatStorageRecordKind.queuedConversationPreferenceIntents,
      valid,
    );
    final diagnostics = <ChatClientDiagnostic>[];
    final corrupt = _Fixture(
      storage: corruptStorage,
      transport: _PreferenceTransport(),
      onStorageDiagnostic: diagnostics.add,
    );
    await corrupt.activate();
    expect(corrupt.client.queuedConversationPreferences, isEmpty);
    expect(
      diagnostics.single.code,
      ChatClientDiagnosticCode.conversationPreferenceIntentsRejected,
    );
    expect(diagnostics.single.toString(), isNot(contains('secret-value')));
    expect(await _readPreferences(corruptStorage, _identity), isNull);
    await corrupt.dispose();
  });

  test('identity replacement and dispose isolate in-flight storage/dispatch',
      () async {
    final backing = InMemoryApplicationChatStorage();
    final blocking = _BlockingPreferenceStorage(backing);
    final isolated = _Fixture(
      storage: blocking,
      transport: _PreferenceTransport(),
      keys: Queue.of(['old-key']),
    );
    await isolated.activate();
    final pending = isolated.client.updateConversationPreference(_authored());
    await blocking.replaceStarted.future;
    final replacement = isolated.client.activateStorageIdentity(_otherIdentity);
    blocking.releaseReplace.complete();
    expect(
      await pending,
      isA<ChatCommandClosed<UpdateConversationPreferenceResult>>(),
    );
    await replacement;
    expect(isolated.client.queuedConversationPreferences, isEmpty);
    expect((await _readPreferences(backing, _identity))?.intents, hasLength(1));
    expect(await _readPreferences(backing, _otherIdentity), isNull);
    await isolated.dispose();

    final disposeStorage = InMemoryApplicationChatStorage();
    final dispatchStarted = Completer<void>();
    final disposeFixture = _Fixture(
      storage: disposeStorage,
      transport: _PreferenceTransport(patch: (_) {
        if (!dispatchStarted.isCompleted) dispatchStarted.complete();
        return Completer<HandrailChatHttpResponse>().future;
      }),
      keys: Queue.of(['dispose-key']),
    );
    await disposeFixture.activate();
    await disposeFixture.initialize();
    final dispatched =
        disposeFixture.client.updateConversationPreference(_authored());
    await dispatchStarted.future;
    await disposeFixture.client.dispose();
    expect(
      await dispatched,
      isA<ChatCommandClosed<UpdateConversationPreferenceResult>>(),
    );
    expect(
      (await _readPreferences(disposeStorage, _identity))?.intents,
      hasLength(1),
    );
    expect(
      disposeFixture.store
          .conversationPreference(_conversationId)
          .preference
          ?.isStarred,
      isFalse,
    );
    await disposeFixture.finishDispose();
  });
}

final class _Fixture {
  _Fixture({
    required ApplicationChatStorage storage,
    required this.transport,
    HandrailChatAccessTokenProvider? tokenProvider,
    Queue<String>? keys,
    bool hydrateInitialStore = true,
    ChatConversationPreferenceRetryBackoff? retryBackoff,
    ChatConversationPreferenceRetryWait? retryWait,
    ChatClientDiagnosticCallback? onStorageDiagnostic,
    this.realtimeSession,
    this.network,
  }) : store = NormalizedSnapshotStore() {
    if (hydrateInitialStore) store.hydrateConversationDetail(_detail());
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
      conversationPreferenceClock: () =>
          const IsoTimestamp('2032-02-01T00:00:00.000Z'),
      conversationPreferenceRetryBackoff: retryBackoff,
      conversationPreferenceRetryWait: retryWait,
      commandRetryOptions: const ChatCommandRetryOptions(
        maxAttempts: 1,
        maxAuthenticationRefreshes: 0,
      ),
      onStorageDiagnostic: onStorageDiagnostic,
    );
  }

  final NormalizedSnapshotStore store;
  final _PreferenceTransport transport;
  final ChatRealtimeSessionTransport? realtimeSession;
  final FakeChatRealtimeNetwork? network;
  late final HandrailChatClient client;
  bool _clientDisposed = false;

  Future<void> activate() => client.activateStorageIdentity(_identity);

  Future<void> initialize() async {
    expect(await client.initialize(), isA<ChatClientReadyState>());
  }

  Future<void> dispose() async {
    if (!_clientDisposed) {
      _clientDisposed = true;
      await client.dispose();
    }
    await finishDispose();
  }

  Future<void> finishDispose() async {
    _clientDisposed = true;
    await realtimeSession?.dispose();
    await network?.dispose();
    await store.close();
  }
}

final class _PreferenceTransport implements HandrailChatHttpTransport {
  _PreferenceTransport({this.patch});

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

final class _BlockingPreferenceStorage implements ApplicationChatStorage {
  _BlockingPreferenceStorage(this.backing);

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
        ApplicationChatStorageRecordKind.queuedConversationPreferenceIntents) {
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

ChatUpdateConversationPreferenceInput _authored([
  ConversationId conversationId = _conversationId,
  bool isStarred = true,
]) =>
    ChatUpdateConversationPreferenceInput(
      conversationId: conversationId,
      notificationPreference: ConversationNotificationPreference.none,
      isStarred: isStarred,
      mute: const IndefinitelyMutedConversationPreference(),
    );

UpdateConversationPreferenceInput _request({
  required String key,
  required int expectedRevision,
  required Map<String, Object?> preference,
}) =>
    UpdateConversationPreferenceInput.fromJson(<String, Object?>{
      'operation': 'update_conversation_preference',
      'conversationId': _conversationId.toJson(),
      'expectedPreferenceRevision': expectedRevision,
      'idempotencyKey': key,
      ...preference,
    });

Future<void> _seedSnapshotAndPreferences(
  ApplicationChatStorage storage, {
  required UpdateConversationPreferenceInput request,
  int revision = 0,
  Map<String, Object?> canonical = _initialPreference,
}) async {
  final store = NormalizedSnapshotStore()..hydrateConversationDetail(_detail());
  if (revision > 0) _advanceAuthority(store, revision, canonical);
  await storage.replace(ApplicationChatNormalizedSnapshotRecord(
    identity: _identity,
    snapshot: store.canonicalPersistenceSnapshot(),
  ));
  await store.close();
  await storage
      .replace(ApplicationChatQueuedConversationPreferenceIntentsRecord(
    identity: _identity,
    intents: [
      ApplicationChatQueuedConversationPreferenceIntent(
        request: request,
        enqueueOrder: 1,
        enqueuedAt: const IsoTimestamp('2032-02-01T00:00:00.000Z'),
      ),
    ],
  ));
}

void _advanceAuthority(
  NormalizedSnapshotStore store,
  int revision,
  Map<String, Object?> canonical,
) {
  for (var current = 0; current < revision; current += 1) {
    final request = _request(
      key: 'authority-$current',
      expectedRevision: current,
      preference: canonical,
    );
    final result = UpdateConversationPreferenceResult.fromJson(
      _resultJson(request, revision: current + 1),
      expectedInput: request,
    );
    store.reconcileConversationPreferenceMutation(request, result);
  }
}

Future<ApplicationChatQueuedConversationPreferenceIntentsRecord?>
    _readPreferences(
  ApplicationChatStorage storage,
  ApplicationChatStorageIdentity identity,
) async =>
        await storage.read(
          identity,
          ApplicationChatStorageRecordKind.queuedConversationPreferenceIntents,
        ) as ApplicationChatQueuedConversationPreferenceIntentsRecord?;

HandrailChatHttpResponse _success(Map<String, Object?> body) {
  final request = UpdateConversationPreferenceInput.fromJson(body);
  return HandrailChatHttpResponse(
    statusCode: 200,
    body: jsonEncode(_resultJson(request)),
  );
}

Map<String, Object?> _resultJson(
  UpdateConversationPreferenceInput request, {
  int? revision,
  String status = 'applied',
  Map<String, Object?>? canonical,
}) =>
    <String, Object?>{
      'operation': request.operation,
      'reconciliationStatus': status,
      'conversationId': request.conversationId.toJson(),
      'expectedPreferenceRevision': request.expectedPreferenceRevision,
      'idempotencyKey': request.idempotencyKey,
      'requestedPreference': request.preference.toJson(),
      'preferenceRevision': revision ?? request.expectedPreferenceRevision + 1,
      'preference': <String, Object?>{
        ...?canonical,
        if (canonical == null) ...request.preference.toJson(),
        'updatedAt': '2032-02-01T00:01:00.000Z',
      },
    };

KnownDurableEvent _preferenceEvent(UpdateConversationPreferenceInput request) =>
    KnownDurableEvent.fromJson(
      <String, Object?>{
        'eventId': 'preference-event-1',
        'protocolVersion': handrailChatProtocolVersion,
        'tenantId': _identity.tenantId.toJson(),
        'streamId': 'user:${_identity.userId.value}',
        'type': 'conversation.preference.updated',
        'occurredAt': '2032-02-01T00:01:00.000Z',
        'payload': <String, Object?>{
          'actorUserId': _identity.userId.toJson(),
          'input': request.toJson(),
          'result': _resultJson(request),
        },
      },
      trustedIdentity: DurableEventTrustedIdentity(
        tenantId: _identity.tenantId,
        userId: _identity.userId,
      ),
    );

Map<String, Object?> _body(HandrailChatHttpRequest request) =>
    (jsonDecode(request.body!) as Map).cast<String, Object?>();

HandrailChatHttpResponse _error(int status, String code) =>
    HandrailChatHttpResponse(
      statusCode: status,
      body: jsonEncode(<String, Object?>{
        'error': <String, Object?>{
          'code': code,
          'message': 'request failed',
        },
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

ConversationDetailSnapshot _detail(
        [ConversationId conversationId = _conversationId]) =>
    ConversationDetailSnapshot.fromJson(
      <String, Object?>{
        'kind': 'conversation_detail',
        'conversation': <String, Object?>{
          'id': conversationId.toJson(),
          'tenantId': _identity.tenantId.toJson(),
          'type': 'channel',
          'name': 'Preference recovery',
          'visibility': 'private',
          'createdAt': '2032-01-01T00:00:00.000Z',
          'updatedAt': '2032-01-01T00:00:00.000Z',
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
            ..._initialPreference,
            'updatedAt': '2032-01-01T00:00:00.000Z',
          },
          'memberUserIds': <Object?>[_identity.userId.toJson()],
          'activeMemberUserIds': <Object?>[_identity.userId.toJson()],
        },
        '_meta': <String, Object?>{
          'packageVersion': '0.1.3',
          'protocolVersion': handrailChatProtocolVersion,
          'schemaVersion': 1,
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
        },
      },
    );

const _metadataJson = '''
{
  "packageVersion": "0.1.3",
  "protocolVersion": 4,
  "schemaVersion": 1,
  "enabledFeatures": {
    "realtime": true,
    "conversation_preference": true,
    "conversation_snapshot": true
  },
  "supportedProtocolRange": {"minimumVersion": 4, "maximumVersion": 4}
}
''';

const _preferenceKind =
    ApplicationChatStorageRecordKind.queuedConversationPreferenceIntents;

final class _PreferenceWriteGate {
  final started = Completer<void>();
  final release = Completer<void>();
}

/// Models another storage writer after a read but before the next write.
/// Legacy writes also run the hook so lost-update regressions fail on old code.
final class _InterleavingPreferenceStorage
    implements AtomicApplicationChatStorage {
  _InterleavingPreferenceStorage(this.backing);
  final InMemoryApplicationChatStorage backing;
  Future<void> Function()? beforeWrite;
  int failedExchanges = 0;
  bool rejectWrites = false;
  bool throwOnWrite = false;

  _PreferenceWriteGate holdNextWrite() {
    final gate = _PreferenceWriteGate();
    beforeWrite = () async {
      gate.started.complete();
      await gate.release.future;
    };
    return gate;
  }

  final proposals =
      <ApplicationChatQueuedConversationPreferenceIntentsRecord?>[];

  Future<void> _onWrite(ApplicationChatStorageRecordKind kind) async {
    if (kind != _preferenceKind) return;
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
    if (kind == _preferenceKind) {
      proposals.add(replacement == null
          ? null
          : ApplicationChatStorageRecord.decode(replacement)
              as ApplicationChatQueuedConversationPreferenceIntentsRecord);
      if (throwOnWrite) throw StateError('secret-value');
      if (rejectWrites) {
        failedExchanges++;
        return false;
      }
    }
    await _onWrite(kind);
    final committed =
        await backing.compareExchange(identity, kind, expected, replacement);
    if (!committed && kind == _preferenceKind) failedExchanges++;
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
