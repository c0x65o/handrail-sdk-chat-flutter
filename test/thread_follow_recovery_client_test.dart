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

import 'fixtures/thread_creation_fixtures.dart';

const _threadId = ConversationId('thread-1');
const _parentId = ConversationId('conversation-1');
const _rootMessageId = MessageId('message-root');
final _identity = ApplicationChatStorageIdentity(
  tenantId: const TenantId('tenant-from-session'),
  userId: const UserId('user-current'),
  deviceId: const DeviceId('device-1'),
);
final _otherIdentity = ApplicationChatStorageIdentity(
  tenantId: const TenantId('tenant-from-session'),
  userId: const UserId('user-other'),
  deviceId: const DeviceId('device-2'),
);
const _initialFollowing = false;
const _desiredFollowing = true;

void main() {
  for (final sameThread in [false, true]) {
    test(
        sameThread
            ? 'atomic competing follow states converge in commit order'
            : 'atomic concurrent different threads both survive', () async {
      final backing = InMemoryApplicationChatStorage();
      final storage = _AtomicThreadFollowStorage(backing);
      final first = _Fixture(
          storage: storage,
          transport: _ThreadFollowTransport(),
          keys: Queue.of(['commits-last']));
      final second = _Fixture(
          storage: _AtomicThreadFollowStorage(backing),
          transport: _ThreadFollowTransport(),
          keys: Queue.of(['commits-first']));
      addTearDown(first.dispose);
      addTearDown(second.dispose);
      await first.activate();
      await second.activate();
      const otherThread = ConversationId('thread-2');
      if (!sameThread) {
        _seedThread(first.store,
            threadId: otherThread, rootMessageId: const MessageId('root-2'));
      }
      storage.beforeExchange = (expected, replacement) async {
        expect(expected, isNull);
        expect(replacement, isNotNull);
        unawaited(second.client.followThread(_threadId));
        await _eventually(() => second.client.queuedThreadFollows.length == 1);
        expect(first.client.queuedThreadFollows, isEmpty);
        expect(
            first.store
                .threadFollow(sameThread ? _threadId : otherThread)
                .isFollowing,
            isNull);
        expect(first.transport.patches, isEmpty);
      };
      unawaited(
          first.client.unfollowThread(sameThread ? _threadId : otherThread));
      await _eventually(() => first.client.queuedThreadFollows.isNotEmpty);
      final intents = (await _readThreadFollows(backing, _identity))!.intents;
      expect(intents.map((i) => i.request.idempotencyKey),
          sameThread ? ['commits-last'] : ['commits-first', 'commits-last']);
      expect(intents.last.request.intent, ThreadFollowMutationIntent.unfollow);
      expect(intents.last.enqueueOrder, sameThread ? 1 : 2);
      expect(storage.conflicts, 1);
      expect(first.client.queuedThreadFollows.map((i) => i.request.toJson()),
          intents.map((i) => i.request.toJson()));
      expect(first.transport.patches, isEmpty);
      expect(second.transport.patches, isEmpty);
    });
  }

  test('atomic activation publishes the committed record after a read race',
      () async {
    final backing = InMemoryApplicationChatStorage();
    final storage = _AtomicThreadFollowStorage(backing);
    final winner = _retained('activation-winner', order: 9);
    storage.beforeExchange = (expected, replacement) async {
      expect(expected, isNull);
      expect(replacement, isNull);
      await backing.replace(_record([winner]));
    };
    final fixture =
        _Fixture(storage: storage, transport: _ThreadFollowTransport());
    addTearDown(fixture.dispose);
    await fixture.activate();
    expect(storage.conflicts, 1);
    expect(fixture.client.queuedThreadFollows.single.request.toJson(),
        winner.request.toJson());
    expect(fixture.client.queuedThreadFollows.single.enqueueOrder, 9);
    expect(fixture.store.threadFollow(_threadId).isFollowing, isTrue);
    expect(fixture.transport.patches, isEmpty);
  });

  for (final exact in [true, false]) {
    test(
        'atomic enqueue retry rechecks ${exact ? 'exact replay' : 'conflicting key'}',
        () async {
      final backing = InMemoryApplicationChatStorage();
      final storage = _AtomicThreadFollowStorage(backing);
      final fixture = _Fixture(
          storage: storage,
          transport: _ThreadFollowTransport(),
          keys: Queue.of(['same-key']));
      addTearDown(fixture.dispose);
      await fixture.activate();
      final winner = _retained('same-key',
          following: exact, order: 7, timestamp: '2032-01-01T00:00:00.000Z');
      storage.beforeExchange = (_, __) => backing.replace(_record([winner]));
      final pending = fixture.client.followThread(_threadId);
      if (exact) {
        await _eventually(() => fixture.client.queuedThreadFollows.isNotEmpty);
      } else {
        expect(await pending,
            isA<ChatCommandValidationFailure<SetThreadFollowResult>>());
      }
      expect(storage.conflicts, 1);
      expect(
          (await _readThreadFollows(backing, _identity))!
              .intents
              .single
              .toJson(),
          winner.toJson());
      expect(fixture.client.queuedThreadFollows.single.enqueueOrder, 7);
      expect(fixture.transport.patches, isEmpty);
      await fixture.dispose();
      if (exact) {
        expect(await pending, isA<ChatCommandClosed<SetThreadFollowResult>>());
      }
    });
  }

  for (final changedField in ['none', 'timestamp', 'request', 'order', 'key']) {
    test(
        'atomic exact settlement preserves appended intents and $changedField replacement',
        () async {
      final backing = InMemoryApplicationChatStorage();
      final storage = _AtomicThreadFollowStorage(backing);
      final fixture = _Fixture(
          storage: storage,
          transport: _ThreadFollowTransport(),
          keys: Queue.of(['settled-key']));
      addTearDown(fixture.dispose);
      await fixture.activate();
      final cancellation = ChatCommandCancellationController();
      final pending = fixture.client
          .followThread(_threadId, cancellationSignal: cancellation.signal);
      await _eventually(() => fixture.client.queuedThreadFollows.length == 1);
      final original =
          (await _readThreadFollows(backing, _identity))!.intents.single;
      final replacement = _retained(
          changedField == 'key' ? 'replacement' : 'settled-key',
          order: changedField == 'order' ? 2 : 1,
          following: changedField != 'request',
          timestamp: changedField == 'timestamp'
              ? '2032-02-02T00:00:00.000Z'
              : '2032-02-01T00:00:00.000Z');
      final unrelated = _retained('unrelated',
          order: 10, threadId: const ConversationId('thread-2'));
      storage.beforeExchange = (expected, proposal) async {
        expect(expected, isNotNull);
        expect(proposal, isNull);
        await backing.replace(_record([
          changedField == 'none' ? original : replacement,
          unrelated,
        ]));
      };
      cancellation.cancel();
      expect(await pending, isA<ChatCommandAborted<SetThreadFollowResult>>());
      final expected = [if (changedField != 'none') replacement, unrelated];
      expect(
          (await _readThreadFollows(backing, _identity))!
              .intents
              .map((i) => i.toJson()),
          expected.map((i) => i.toJson()));
      expect(fixture.client.queuedThreadFollows.map((i) => i.request.toJson()),
          expected.map((i) => i.request.toJson()));
      expect(storage.conflicts, 1);
      expect(storage.unconditionalMutationRemovals, 0);
      expect(fixture.transport.patches, isEmpty);
    });
  }

  test('atomic malformed quarantine preserves racing valid bytes', () async {
    final backing = InMemoryApplicationChatStorage();
    final storage = _AtomicThreadFollowStorage(backing);
    final winner = _record([_retained('valid-replacement')]);
    storage.beforeEncodedRead = (readNumber) {
      if (readNumber != 1) return;
      backing.putRawRecordForTesting(
          _identity,
          ApplicationChatStorageRecordKind.queuedThreadFollowIntents,
          {'malformed': 'private-record-details'});
      storage.beforeExchange = (expected, replacement) async {
        expect(expected, contains('private-record-details'));
        expect(replacement, isNull);
        await backing.replace(winner);
      };
    };
    final diagnostics = <ChatClientDiagnostic>[];
    final fixture = _Fixture(
        storage: storage,
        transport: _ThreadFollowTransport(),
        onStorageDiagnostic: diagnostics.add);
    addTearDown(fixture.dispose);
    await fixture.activate();
    expect(
        await backing.readEncoded(_identity,
            ApplicationChatStorageRecordKind.queuedThreadFollowIntents),
        winner.encode());
    expect(storage.conflicts, 1);
    expect(storage.unconditionalMutationRemovals, 0);
    expect(diagnostics.map((d) => d.code),
        contains(ChatClientDiagnosticCode.threadFollowIntentsRejected));
    expect(diagnostics.map((d) => d.message).join(),
        isNot(contains('private-record-details')));
    expect(fixture.client.queuedThreadFollows, isEmpty);
    expect(fixture.transport.patches, isEmpty);
    final restarted = _Fixture(
        storage: _AtomicThreadFollowStorage(backing),
        transport: _ThreadFollowTransport());
    addTearDown(restarted.dispose);
    await restarted.activate();
    expect(restarted.client.queuedThreadFollows.single.request.idempotencyKey,
        'valid-replacement');
    expect(restarted.store.threadFollow(_threadId).isFollowing, isTrue);
  });

  for (final failure in ['contention', 'adapter']) {
    test('atomic $failure failure publishes and dispatches no proposal',
        () async {
      final backing = InMemoryApplicationChatStorage();
      final storage = _AtomicThreadFollowStorage(backing);
      final diagnostics = <ChatClientDiagnostic>[];
      var tokenCalls = 0;
      final fixture = _Fixture(
          storage: storage,
          transport: _ThreadFollowTransport(),
          tokenProvider: () async {
            tokenCalls += 1;
            return 'token';
          },
          onStorageDiagnostic: diagnostics.add);
      addTearDown(fixture.dispose);
      await fixture.activate();
      await fixture.initialize();
      final beforeTokens = tokenCalls;
      if (failure == 'contention') {
        storage.rejectExchanges = true;
      } else {
        storage.beforeExchange =
            (_, __) async => throw StateError('write failed');
      }
      expect(await fixture.client.followThread(_threadId),
          isA<ChatCommandValidationFailure<SetThreadFollowResult>>());
      expect(fixture.client.queuedThreadFollows, isEmpty);
      expect(fixture.store.threadFollow(_threadId).isFollowing, isNull);
      expect(fixture.transport.patches, isEmpty);
      expect(tokenCalls, beforeTokens);
      expect(await _readThreadFollows(backing, _identity), isNull);
      expect(diagnostics.map((d) => d.code),
          contains(ChatClientDiagnosticCode.threadFollowIntentsWriteFailed));
      if (failure == 'contention') {
        expect(storage.conflicts, maxApplicationChatStorageMutationAttempts);
      }
    });
  }

  test(
      'atomic failed supersession leaves the prior projection and waiter intact',
      () async {
    final backing = InMemoryApplicationChatStorage();
    final storage = _AtomicThreadFollowStorage(backing);
    final fixture = _Fixture(
        storage: storage,
        transport: _ThreadFollowTransport(),
        keys: Queue.of(['prior', 'failed']));
    addTearDown(fixture.dispose);
    await fixture.activate();
    var completed = false;
    final prior = fixture.client
        .followThread(_threadId)
        .whenComplete(() => completed = true);
    await _eventually(() => fixture.client.queuedThreadFollows.length == 1);
    storage.rejectExchanges = true;
    expect(await fixture.client.unfollowThread(_threadId),
        isA<ChatCommandValidationFailure<SetThreadFollowResult>>());
    expect(completed, isFalse);
    expect(fixture.client.queuedThreadFollows.single.request.idempotencyKey,
        'prior');
    expect(fixture.store.threadFollow(_threadId).isFollowing, isTrue);
    expect(
        (await _readThreadFollows(backing, _identity))!
            .intents
            .single
            .request
            .idempotencyKey,
        'prior');
    await fixture.dispose();
    expect(await prior, isA<ChatCommandClosed<SetThreadFollowResult>>());
  });

  test('atomic retry rechecks scope after disposal', () async {
    final backing = InMemoryApplicationChatStorage();
    final storage = _AtomicThreadFollowStorage(backing);
    final fixture =
        _Fixture(storage: storage, transport: _ThreadFollowTransport());
    addTearDown(fixture.dispose);
    await fixture.activate();
    final winner = _record([_retained('other-runtime')]);
    storage.beforeExchange = (_, __) async {
      await backing.replace(winner);
      await fixture.client.dispose();
    };
    expect(await fixture.client.unfollowThread(_threadId),
        isA<ChatCommandClosed<SetThreadFollowResult>>());
    expect(storage.conflicts, 1);
    expect(
        await backing.readEncoded(_identity,
            ApplicationChatStorageRecordKind.queuedThreadFollowIntents),
        winner.encode());
    expect(fixture.client.queuedThreadFollows, isEmpty);
    expect(fixture.store.threadFollow(_threadId).isFollowing, isNull);
    expect(fixture.transport.patches, isEmpty);
  });

  test('persists before projection, token access, or transport', () async {
    final backing = InMemoryApplicationChatStorage();
    final storage = _BlockingThreadFollowStorage(backing);
    final transport = _ThreadFollowTransport();
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

    final pending = fixture.client.followThread(_threadId);
    await storage.replaceStarted.future;
    expect(fixture.client.queuedThreadFollows, isEmpty);
    expect(fixture.store.threadFollow(_threadId).isFollowing, isNull);
    expect(tokenCalls, 0);
    expect(transport.patches, isEmpty);

    storage.releaseReplace.complete();
    await _eventually(
      () => fixture.client.queuedThreadFollows.length == 1,
    );
    expect(fixture.store.threadFollow(_threadId).isFollowing, isTrue);
    expect(tokenCalls, 0, reason: 'metadata is not ready');
    await fixture.initialize();
    expect(
      await pending,
      isA<ChatCommandSuccess<SetThreadFollowResult>>(),
    );
    expect(_body(transport.patches.single)['idempotencyKey'], 'persisted-key');
    expect(await _readThreadFollows(backing, _identity), isNull);
    await fixture.dispose();
  });

  test('restart restores desired state and replays the exact request',
      () async {
    final storage = InMemoryApplicationChatStorage();
    final request = _request(
      key: 'restart-key',
      expectedRevision: 0,
      following: _desiredFollowing,
    );
    await _seedSnapshotAndThreadFollows(storage, request: request);
    final fixture = _Fixture(
      storage: storage,
      transport: _ThreadFollowTransport(),
      keys: Queue.of(['must-not-be-used']),
      hydrateInitialStore: false,
    );

    await fixture.activate();
    expect(fixture.client.queuedThreadFollows.single.request.toJson(),
        request.toJson());
    expect(fixture.store.threadFollow(_threadId).isFollowing, isTrue);
    await fixture.initialize();
    await _eventually(() => fixture.transport.patches.length == 1);
    final sent = fixture.transport.patches.single;
    expect(_body(sent), request.toJson());
    expect(sent.headers['Idempotency-Key'], 'restart-key');
    await _eventually(
      () => fixture.client.queuedThreadFollows.isEmpty,
    );
    await fixture.dispose();
  });

  test('latest desired state durably supersedes an undispatched overlay',
      () async {
    final storage = InMemoryApplicationChatStorage();
    final fixture = _Fixture(
      storage: storage,
      transport: _ThreadFollowTransport(),
      keys: Queue.of(<String>['follow-key', 'unfollow-key']),
    );
    await fixture.activate();

    final follow = fixture.client.followThread(_threadId);
    await _eventually(() => fixture.client.queuedThreadFollows.length == 1);
    final unfollow = fixture.client.unfollowThread(_threadId);
    expect(await follow, isA<ChatCommandClosed<SetThreadFollowResult>>());
    await _eventually(
      () =>
          fixture.client.queuedThreadFollows.single.request.idempotencyKey ==
          'unfollow-key',
    );
    expect(fixture.store.threadFollow(_threadId).isFollowing, isFalse);
    final retained = await _readThreadFollows(storage, _identity);
    expect(retained?.intents, hasLength(1));
    expect(retained?.intents.single.request.intent,
        ThreadFollowMutationIntent.unfollow);

    await fixture.initialize();
    expect(await unfollow, isA<ChatCommandSuccess<SetThreadFollowResult>>());
    expect(_body(fixture.transport.patches.single)['idempotencyKey'],
        'unfollow-key');
    await fixture.dispose();
  });

  test('older, equal, and newer canonical authority are handled safely',
      () async {
    final olderStorage = InMemoryApplicationChatStorage();
    await _seedSnapshotAndThreadFollows(
      olderStorage,
      request: _request(
        key: 'older-key',
        expectedRevision: 1,
        following: _desiredFollowing,
      ),
    );
    final older = _Fixture(
      storage: olderStorage,
      transport: _ThreadFollowTransport(),
      hydrateInitialStore: false,
    );
    await older.activate();
    await older.initialize();
    expect(
      older.client.queuedThreadFollows.single.status,
      ChatQueuedThreadFollowStatus.waitingForCanonicalBase,
    );
    expect(older.transport.patches, isEmpty);
    await older.dispose();

    final equalStorage = InMemoryApplicationChatStorage();
    await _seedSnapshotAndThreadFollows(
      equalStorage,
      request: _request(
        key: 'equal-key',
        expectedRevision: 1,
        following: _initialFollowing,
      ),
      revision: 1,
      canonicalFollowing: _initialFollowing,
    );
    final equal = _Fixture(
      storage: equalStorage,
      transport: _ThreadFollowTransport(),
      hydrateInitialStore: false,
    );
    await equal.activate();
    await equal.initialize();
    await _eventually(
      () => equal.client.queuedThreadFollows.isEmpty,
    );
    expect(equal.transport.patches, isEmpty);
    await equal.dispose();

    final newerMatchingStorage = InMemoryApplicationChatStorage();
    await _seedSnapshotAndThreadFollows(
      newerMatchingStorage,
      request: _request(
        key: 'newer-match-key',
        expectedRevision: 0,
        following: _desiredFollowing,
      ),
      revision: 1,
      canonicalFollowing: _desiredFollowing,
    );
    final newerMatching = _Fixture(
      storage: newerMatchingStorage,
      transport: _ThreadFollowTransport(),
      hydrateInitialStore: false,
    );
    await newerMatching.activate();
    await newerMatching.initialize();
    await _eventually(
      () => newerMatching.client.queuedThreadFollows.isEmpty,
    );
    expect(newerMatching.transport.patches, isEmpty);
    await newerMatching.dispose();

    final conflictStorage = InMemoryApplicationChatStorage();
    await _seedSnapshotAndThreadFollows(
      conflictStorage,
      request: _request(
        key: 'conflict-key',
        expectedRevision: 0,
        following: _desiredFollowing,
      ),
      revision: 1,
      canonicalFollowing: false,
    );
    final conflict = _Fixture(
      storage: conflictStorage,
      transport: _ThreadFollowTransport(),
      hydrateInitialStore: false,
    );
    await conflict.activate();
    await conflict.initialize();
    expect(
      conflict.client.queuedThreadFollows.single.status,
      ChatQueuedThreadFollowStatus.revisionConflict,
    );
    expect(conflict.transport.patches, isEmpty);
    expect(conflict.store.threadFollow(_threadId).isFollowing, isFalse);
    await conflict.dispose();
  });

  test('matching canonical event settles retained work before HTTP', () async {
    final storage = InMemoryApplicationChatStorage();
    final request = _request(
      key: 'event-key',
      expectedRevision: 0,
      following: _desiredFollowing,
    );
    await _seedSnapshotAndThreadFollows(storage, request: request);
    final fixture = _Fixture(
      storage: storage,
      transport: _ThreadFollowTransport(),
      hydrateInitialStore: false,
    );
    await fixture.activate();
    fixture.client.reduceDurableEvent(_threadFollowEvent(request));
    await _eventually(
      () => fixture.client.queuedThreadFollows.isEmpty,
    );
    await fixture.initialize();
    expect(fixture.transport.patches, isEmpty);
    expect(await _readThreadFollows(storage, _identity), isNull);
    await fixture.dispose();
  });

  test('event-first settlement supersedes an in-flight HTTP request', () async {
    final storage = InMemoryApplicationChatStorage();
    final dispatchStarted = Completer<void>();
    final fixture = _Fixture(
      storage: storage,
      transport: _ThreadFollowTransport(patch: (_) {
        if (!dispatchStarted.isCompleted) dispatchStarted.complete();
        return Completer<HandrailChatHttpResponse>().future;
      }),
      keys: Queue.of(<String>['event-first-key']),
    );
    await fixture.activate();
    await fixture.initialize();

    final pending = fixture.client.followThread(_threadId);
    await dispatchStarted.future;
    final request = fixture.client.queuedThreadFollows.single.request;
    fixture.client.reduceDurableEvent(_threadFollowEvent(request));

    expect(
      await pending,
      isA<ChatCommandSuccess<SetThreadFollowResult>>(),
    );
    expect(fixture.client.queuedThreadFollows, isEmpty);
    expect(await _readThreadFollows(storage, _identity), isNull);
    expect(fixture.store.threadFollow(_threadId).isFollowing, isTrue);
    expect(fixture.transport.patches, hasLength(1));
    await fixture.dispose();
  });

  test('transient and malformed outcomes retain; terminal outcome removes',
      () async {
    final waits = <Duration>[];
    final waitGate = Completer<void>();
    final transientStorage = InMemoryApplicationChatStorage();
    final transient = _Fixture(
      storage: transientStorage,
      transport: _ThreadFollowTransport(
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
      await transient.client.followThread(_threadId),
      isA<ChatCommandTransportFailure<SetThreadFollowResult>>(),
    );
    await _eventually(() => waits.isNotEmpty);
    expect(waits.single, const Duration(seconds: 60));
    expect(
      (await _readThreadFollows(transientStorage, _identity))?.intents,
      hasLength(1),
    );
    await transient.dispose();

    var boundedWaitCalled = false;
    final malformedStorage = InMemoryApplicationChatStorage();
    final malformed = _Fixture(
      storage: malformedStorage,
      transport: _ThreadFollowTransport(
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
      await malformed.client.followThread(_threadId),
      isA<ChatCommandMalformedResponse<SetThreadFollowResult>>(),
    );
    expect(boundedWaitCalled, isFalse);
    expect(
      (await _readThreadFollows(malformedStorage, _identity))?.intents,
      hasLength(1),
    );
    await malformed.dispose();

    final terminalStorage = InMemoryApplicationChatStorage();
    final terminal = _Fixture(
      storage: terminalStorage,
      transport: _ThreadFollowTransport(
        patch: (_) async => _error(403, 'PERMISSION_DENIED'),
      ),
      keys: Queue.of(['terminal-key']),
    );
    await terminal.activate();
    await terminal.initialize();
    expect(
      await terminal.client.followThread(_threadId),
      isA<ChatCommandAuthenticationFailure<SetThreadFollowResult>>(),
    );
    expect(await _readThreadFollows(terminalStorage, _identity), isNull);
    expect(terminal.store.threadFollow(_threadId).isFollowing, isNull);
    await terminal.dispose();
  });

  test('HTTP revision conflict and cancellation after dispatch remain durable',
      () async {
    final conflictStorage = InMemoryApplicationChatStorage();
    final conflict = _Fixture(
      storage: conflictStorage,
      transport: _ThreadFollowTransport(patch: (wire) async {
        final request = SetThreadFollowInput.fromJson(_body(wire));
        return HandrailChatHttpResponse(
          statusCode: 409,
          body: jsonEncode(_resultJson(
            request,
            status: 'follow_revision_conflict',
            canonicalFollowing: _initialFollowing,
          )),
        );
      }),
      keys: Queue.of(['http-conflict-key']),
    );
    await conflict.activate();
    await conflict.initialize();
    expect(
      await conflict.client.followThread(_threadId),
      isA<ChatCommandSuccess<SetThreadFollowResult>>(),
    );
    expect(
      conflict.client.queuedThreadFollows.single.status,
      ChatQueuedThreadFollowStatus.revisionConflict,
    );
    expect(
      (await _readThreadFollows(conflictStorage, _identity))?.intents,
      hasLength(1),
    );
    await conflict.dispose();

    final cancelledStorage = InMemoryApplicationChatStorage();
    final dispatchStarted = Completer<void>();
    final cancelled = _Fixture(
      storage: cancelledStorage,
      transport: _ThreadFollowTransport(patch: (_) {
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
    final pending = cancelled.client.followThread(
      _threadId,
      cancellationSignal: cancellation.signal,
    );
    await dispatchStarted.future;
    cancellation.cancel();
    expect(
      await pending,
      isA<ChatCommandAborted<SetThreadFollowResult>>(),
    );
    expect(
      (await _readThreadFollows(cancelledStorage, _identity))?.intents,
      hasLength(1),
    );
    await cancelled.dispose();
  });

  test('offline and background pause replay until realtime identity is ready',
      () async {
    final storage = InMemoryApplicationChatStorage();
    await _seedSnapshotAndThreadFollows(
      storage,
      request: _request(
        key: 'lifecycle-key',
        expectedRevision: 0,
        following: _desiredFollowing,
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
      transport: _ThreadFollowTransport(),
      hydrateInitialStore: false,
      realtimeSession: session,
      network: network,
    );
    await fixture.activate();
    await fixture.initialize();
    expect(fixture.transport.patches, isEmpty, reason: 'offline');
    await session.start();
    network.setOnline(true);
    await _eventually(() => sockets.uris.length == 1);
    expect(fixture.transport.patches, isEmpty, reason: 'realtime disconnected');
    fixture.client.setApplicationForeground(false);
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
      transport: _ThreadFollowTransport(patch: (_) => gate.future),
      keys: Queue.of(['checkpoint-key']),
    );
    await checkpoint.activate();
    await checkpoint.initialize();
    final pending = checkpoint.client.followThread(_threadId);
    await _eventually(
      () => checkpoint.client.queuedThreadFollows.length == 1,
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
    expect(normalized.snapshot.pendingThreadFollowIntents, isEmpty);
    expect(
      normalized.snapshot.currentUserThreadFollows[_threadId],
      isNull,
    );
    await checkpoint.client.dispose();
    expect(
      await pending,
      isA<ChatCommandClosed<SetThreadFollowResult>>(),
    );
    expect(
      (await _readThreadFollows(checkpointStorage, _identity))?.intents,
      hasLength(1),
    );
    await checkpoint.finishDispose();

    final corruptStorage = InMemoryApplicationChatStorage();
    await _seedSnapshotAndThreadFollows(
      corruptStorage,
      request: _request(
        key: 'valid-before-corruption',
        expectedRevision: 0,
        following: _desiredFollowing,
      ),
    );
    final valid = ApplicationChatQueuedThreadFollowIntentsRecord(
      identity: _identity,
      intents: [
        ApplicationChatQueuedThreadFollowIntent(
          request: _request(
            key: 'corrupt-key',
            expectedRevision: 0,
            following: _desiredFollowing,
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
      ApplicationChatStorageRecordKind.queuedThreadFollowIntents,
      valid,
    );
    final diagnostics = <ChatClientDiagnostic>[];
    final corrupt = _Fixture(
      storage: corruptStorage,
      transport: _ThreadFollowTransport(),
      onStorageDiagnostic: diagnostics.add,
    );
    await corrupt.activate();
    expect(corrupt.client.queuedThreadFollows, isEmpty);
    expect(
      diagnostics.single.code,
      ChatClientDiagnosticCode.threadFollowIntentsRejected,
    );
    expect(diagnostics.single.toString(), isNot(contains('secret-value')));
    expect(await _readThreadFollows(corruptStorage, _identity), isNull);
    expect(
      await corruptStorage.read(
        _identity,
        ApplicationChatStorageRecordKind.normalizedSnapshot,
      ),
      isA<ApplicationChatNormalizedSnapshotRecord>(),
    );
    await corrupt.dispose();
  });

  test('identity replacement and dispose isolate in-flight storage/dispatch',
      () async {
    final backing = InMemoryApplicationChatStorage();
    final blocking = _BlockingThreadFollowStorage(backing);
    final isolated = _Fixture(
      storage: blocking,
      transport: _ThreadFollowTransport(),
      keys: Queue.of(['old-key']),
    );
    await isolated.activate();
    final pending = isolated.client.followThread(_threadId);
    await blocking.replaceStarted.future;
    final replacement = isolated.client.activateStorageIdentity(_otherIdentity);
    blocking.releaseReplace.complete();
    expect(
      await pending,
      isA<ChatCommandClosed<SetThreadFollowResult>>(),
    );
    await replacement;
    expect(isolated.client.queuedThreadFollows, isEmpty);
    expect(
        (await _readThreadFollows(backing, _identity))?.intents, hasLength(1));
    expect(await _readThreadFollows(backing, _otherIdentity), isNull);
    await isolated.dispose();

    final disposeStorage = InMemoryApplicationChatStorage();
    final dispatchStarted = Completer<void>();
    final disposeFixture = _Fixture(
      storage: disposeStorage,
      transport: _ThreadFollowTransport(patch: (_) {
        if (!dispatchStarted.isCompleted) dispatchStarted.complete();
        return Completer<HandrailChatHttpResponse>().future;
      }),
      keys: Queue.of(['dispose-key']),
    );
    await disposeFixture.activate();
    await disposeFixture.initialize();
    final dispatched = disposeFixture.client.followThread(_threadId);
    await dispatchStarted.future;
    await disposeFixture.client.dispose();
    expect(
      await dispatched,
      isA<ChatCommandClosed<SetThreadFollowResult>>(),
    );
    expect(
      (await _readThreadFollows(disposeStorage, _identity))?.intents,
      hasLength(1),
    );
    expect(disposeFixture.store.threadFollow(_threadId).isFollowing, isNull);
    await disposeFixture.finishDispose();
  });
}

ApplicationChatQueuedThreadFollowIntent _retained(
  String key, {
  bool following = true,
  int order = 1,
  ConversationId threadId = _threadId,
  String timestamp = '2032-02-01T00:00:00.000Z',
}) =>
    ApplicationChatQueuedThreadFollowIntent(
      request: _request(
          key: key,
          following: following,
          expectedRevision: 0,
          threadId: threadId),
      enqueueOrder: order,
      enqueuedAt: IsoTimestamp(timestamp),
    );

ApplicationChatQueuedThreadFollowIntentsRecord _record(
        List<ApplicationChatQueuedThreadFollowIntent> intents) =>
    ApplicationChatQueuedThreadFollowIntentsRecord(
        identity: _identity, intents: intents);

final class _Fixture {
  _Fixture({
    required ApplicationChatStorage storage,
    required this.transport,
    HandrailChatAccessTokenProvider? tokenProvider,
    Queue<String>? keys,
    bool hydrateInitialStore = true,
    ChatThreadFollowRetryBackoff? retryBackoff,
    ChatThreadFollowRetryWait? retryWait,
    ChatClientDiagnosticCallback? onStorageDiagnostic,
    this.realtimeSession,
    this.network,
  }) : store = NormalizedSnapshotStore() {
    if (hydrateInitialStore) _seedThread(store);
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
      threadFollowClock: () => const IsoTimestamp('2032-02-01T00:00:00.000Z'),
      threadFollowRetryBackoff: retryBackoff,
      threadFollowRetryWait: retryWait,
      commandRetryOptions: const ChatCommandRetryOptions(
        maxAttempts: 1,
        maxAuthenticationRefreshes: 0,
      ),
      onStorageDiagnostic: onStorageDiagnostic,
    );
  }

  final NormalizedSnapshotStore store;
  final _ThreadFollowTransport transport;
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

final class _ThreadFollowTransport implements HandrailChatHttpTransport {
  _ThreadFollowTransport({this.patch});

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

class _AtomicThreadFollowStorage implements AtomicApplicationChatStorage {
  _AtomicThreadFollowStorage(this.backing);

  final InMemoryApplicationChatStorage backing;
  Future<void> Function(String? expected, String? replacement)? beforeExchange;
  void Function(int readNumber)? beforeEncodedRead;
  int encodedReads = 0;
  int conflicts = 0;
  bool rejectExchanges = false;
  int unconditionalMutationRemovals = 0;

  @override
  Future<String?> readEncoded(ApplicationChatStorageIdentity identity,
      ApplicationChatStorageRecordKind kind) {
    if (kind == ApplicationChatStorageRecordKind.queuedThreadFollowIntents) {
      beforeEncodedRead?.call(++encodedReads);
    }
    return backing.readEncoded(identity, kind);
  }

  @override
  Future<bool> compareExchange(
    ApplicationChatStorageIdentity identity,
    ApplicationChatStorageRecordKind kind,
    String? expected,
    String? replacement,
  ) async {
    if (kind == ApplicationChatStorageRecordKind.queuedThreadFollowIntents) {
      final hook = beforeExchange;
      beforeExchange = null;
      await hook?.call(expected, replacement);
      if (rejectExchanges) {
        conflicts += 1;
        return false;
      }
    }
    final committed =
        await backing.compareExchange(identity, kind, expected, replacement);
    if (!committed &&
        kind == ApplicationChatStorageRecordKind.queuedThreadFollowIntents) {
      conflicts += 1;
    }
    return committed;
  }

  @override
  Future<ApplicationChatStorageRecord?> read(
    ApplicationChatStorageIdentity identity,
    ApplicationChatStorageRecordKind kind,
  ) =>
      backing.read(identity, kind);

  @override
  Future<void> replace(ApplicationChatStorageRecord record) async {
    // Exercise the same race if the runtime regresses to unconditional writes.
    if (record.kind ==
        ApplicationChatStorageRecordKind.queuedThreadFollowIntents) {
      final hook = beforeExchange;
      beforeExchange = null;
      await hook?.call(await backing.readEncoded(record.identity, record.kind),
          record.encode());
    }
    await backing.replace(record);
  }

  @override
  Future<void> remove(ApplicationChatStorageIdentity identity,
      ApplicationChatStorageRecordKind kind) {
    if (kind == ApplicationChatStorageRecordKind.queuedThreadFollowIntents) {
      unconditionalMutationRemovals += 1;
    }
    return backing.remove(identity, kind);
  }

  @override
  Future<void> clearForLogout(
          ApplicationChatStorageIdentity previousIdentity) =>
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

final class _BlockingThreadFollowStorage implements ApplicationChatStorage {
  _BlockingThreadFollowStorage(this.backing);

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
        ApplicationChatStorageRecordKind.queuedThreadFollowIntents) {
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

SetThreadFollowInput _request({
  required String key,
  required int expectedRevision,
  required bool following,
  ConversationId threadId = _threadId,
}) =>
    SetThreadFollowInput.fromJson(<String, Object?>{
      'operation': 'set_thread_follow',
      'intent': following ? 'follow' : 'unfollow',
      'target': <String, Object?>{
        'type': 'thread',
        'id': threadId.toJson(),
      },
      'expectedFollowRevision': expectedRevision,
      'idempotencyKey': key,
    });

Future<void> _seedSnapshotAndThreadFollows(
  ApplicationChatStorage storage, {
  required SetThreadFollowInput request,
  int revision = 0,
  bool canonicalFollowing = _initialFollowing,
}) async {
  final store = NormalizedSnapshotStore();
  _seedThread(store);
  if (revision > 0) {
    _advanceAuthority(store, revision, canonicalFollowing);
  }
  await storage.replace(ApplicationChatNormalizedSnapshotRecord(
    identity: _identity,
    snapshot: store.canonicalPersistenceSnapshot(),
  ));
  await store.close();
  await storage.replace(ApplicationChatQueuedThreadFollowIntentsRecord(
    identity: _identity,
    intents: [
      ApplicationChatQueuedThreadFollowIntent(
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
  bool canonicalFollowing,
) {
  for (var current = 0; current < revision; current += 1) {
    final request = _request(
      key: 'authority-$current',
      expectedRevision: current,
      following: canonicalFollowing,
    );
    final result = SetThreadFollowResult.fromJson(
      _resultJson(request, revision: current + 1),
      expectedInput: request,
    );
    store.reconcileThreadFollowMutation(request, result);
  }
}

Future<ApplicationChatQueuedThreadFollowIntentsRecord?> _readThreadFollows(
  ApplicationChatStorage storage,
  ApplicationChatStorageIdentity identity,
) async =>
    await storage.read(
      identity,
      ApplicationChatStorageRecordKind.queuedThreadFollowIntents,
    ) as ApplicationChatQueuedThreadFollowIntentsRecord?;

HandrailChatHttpResponse _success(Map<String, Object?> body) {
  final request = SetThreadFollowInput.fromJson(body);
  return HandrailChatHttpResponse(
    statusCode: 200,
    body: jsonEncode(_resultJson(request)),
  );
}

Map<String, Object?> _resultJson(
  SetThreadFollowInput request, {
  int? revision,
  String status = 'applied',
  bool? canonicalFollowing,
}) {
  final conflict = status == 'follow_revision_conflict';
  final following = canonicalFollowing ??
      (conflict
          ? request.intent != ThreadFollowMutationIntent.follow
          : request.intent == ThreadFollowMutationIntent.follow);
  return <String, Object?>{
    'operation': request.operation,
    'intent': request.intent.toJson(),
    'reconciliationStatus': status,
    'target': request.target.toJson(),
    'expectedFollowRevision': request.expectedFollowRevision,
    'idempotencyKey': request.idempotencyKey,
    'followRevision': revision ??
        (conflict
            ? request.expectedFollowRevision + 2
            : request.expectedFollowRevision + 1),
    'follow': <String, Object?>{
      'target': request.target.toJson(),
      'isFollowing': following,
      'source': 'manual',
      'updatedAt': '2032-02-01T00:01:00.000Z',
    },
  };
}

KnownDurableEvent _threadFollowEvent(SetThreadFollowInput request) =>
    KnownDurableEvent.fromJson(
      <String, Object?>{
        'eventId': 'thread-follow-event-1',
        'protocolVersion': handrailChatProtocolVersion,
        'tenantId': _identity.tenantId.toJson(),
        'streamId': 'user:${_identity.userId.value}',
        'type': 'thread.follow.updated',
        'occurredAt': '2032-02-01T00:01:00.000Z',
        'payload': <String, Object?>{
          'operation': request.operation,
          'target': request.target.toJson(),
          'followRevision': request.expectedFollowRevision + 1,
          'follow': (_resultJson(request)['follow']! as Map<String, Object?>),
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

void _seedThread(
  NormalizedSnapshotStore store, {
  ConversationId threadId = _threadId,
  MessageId rootMessageId = _rootMessageId,
}) {
  store.hydrateConversationDetail(_parentDetail());
  store.reconcileMessage(Message.fromJson(<String, Object?>{
    'id': rootMessageId.toJson(),
    'tenantId': _identity.tenantId.toJson(),
    'conversationId': _parentId.toJson(),
    'author': <String, Object?>{
      'type': 'user',
      'userId': _identity.userId.toJson(),
    },
    'sequence': threadId == _threadId ? 1 : 2,
    'createdAt': '2032-01-01T00:00:00.000Z',
    'updatedAt': '2032-01-01T00:00:00.000Z',
    'revision': <String, Object?>{'revision': 1},
    'content': <String, Object?>{'format': 'plain', 'text': 'root'},
  }));
  final input = ThreadCreationInput.fromJson(<String, Object?>{
    'operation': 'create_thread',
    'parentConversationId': _parentId.toJson(),
    'rootMessageId': rootMessageId.toJson(),
    'idempotencyKey': 'seed-thread',
  });
  store.reconcileThreadOpening(ThreadCreationResult.fromJson(
    threadCreationResultFixture(
      'created',
      parentConversationId: _parentId.value,
      rootMessageId: rootMessageId.value,
      threadId: threadId.value,
      summaryThreadId: threadId.value,
    ),
    expectedInput: input,
  ));
}

ConversationDetailSnapshot _parentDetail() =>
    ConversationDetailSnapshot.fromJson(
      <String, Object?>{
        'kind': 'conversation_detail',
        'conversation': <String, Object?>{
          'id': _parentId.toJson(),
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
            'conversationId': _parentId.toJson(),
            'userId': _identity.userId.toJson(),
            'role': 'member',
            'state': 'active',
            'joinedAt': '2032-01-01T00:00:00.000Z',
            'updatedAt': '2032-01-01T00:00:00.000Z',
          },
          'currentReadState': <String, Object?>{
            'conversationId': _parentId.toJson(),
            'userId': _identity.userId.toJson(),
            'lastReadSequence': 0,
            'updatedAt': '2032-01-01T00:00:00.000Z',
          },
          'currentPreference': <String, Object?>{
            'conversationId': _parentId.toJson(),
            'userId': _identity.userId.toJson(),
            'notificationPreference': 'mentions',
            'isStarred': false,
            'mute': <String, Object?>{'muted': false},
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
