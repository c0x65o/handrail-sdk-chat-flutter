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
const _conversationId = ConversationId('conversation-1');
const _messageId = MessageId('message-1');

void main() {
  for (final sameLane in [false, true]) {
    test(
        sameLane
            ? 'concurrent desired states converge in commit order at the stable lane position'
            : 'concurrent independent reactions both survive with committed FIFO order',
        () async {
      final backing = InMemoryApplicationChatStorage();
      final storage = _AtomicMutationStorage(backing);
      final first =
          _offlineFixture(storage, clock: () => DateTime.utc(2032, 2, 2));
      final second = _offlineFixture(_AtomicMutationStorage(backing));
      await first.activate();
      await second.activate();
      ApplicationChatQueuedMessageMutationIntent? winner;
      storage.beforeExchange = (expected, replacement) async {
        expect(expected, isNull);
        expect(replacement, isNotNull);
        expect(await second.client.setReaction(_input('commits-first')),
            isA<ChatCommandTransportFailure<ReactionMutationResult>>());
        winner = (await _readMutations(backing, _identity))!.intents.single;
      };

      expect(
          await first.client.setReaction(_input('commits-last',
              reactionKey: sameLane ? 'thumbsup' : 'heart',
              reactedByCurrentUser: false)),
          isA<ChatCommandTransportFailure<ReactionMutationResult>>());
      final intents = (await _readMutations(backing, _identity))!.intents;
      expect(intents.map((intent) => intent.idempotencyKey),
          sameLane ? ['commits-last'] : ['commits-first', 'commits-last']);
      expect(intents.last.request, isA<RemoveReactionInput>());
      expect(intents.last.enqueueOrder, sameLane ? winner!.enqueueOrder : 2);
      if (sameLane) expect(intents.single.enqueuedAt, winner!.enqueuedAt);
      expect(storage.conflicts, 1);
      expect(first.transport.patches, hasLength(1));
      expect(second.transport.patches, hasLength(1));
      await first.dispose();
      await second.dispose();
    });
  }

  test(
      'enqueue retry preserves edit, delete, and forward intents and recomputes order',
      () async {
    final backing = InMemoryApplicationChatStorage();
    final storage = _AtomicMutationStorage(backing);
    final fixture = _offlineFixture(storage);
    await fixture.activate();
    final unrelated = _unrelatedMutations();
    storage.beforeExchange = (expected, replacement) async {
      expect(expected, isNull);
      await backing.replace(ApplicationChatQueuedMessageMutationIntentsRecord(
        identity: _identity,
        intents: unrelated,
      ));
    };

    expect(await fixture.client.setReaction(_input('after-contention')),
        isA<ChatCommandTransportFailure<ReactionMutationResult>>());
    final intents = (await _readMutations(backing, _identity))!.intents;
    expect(intents.take(3).map((intent) => intent.toJson()),
        unrelated.map((intent) => intent.toJson()));
    expect(intents.last.idempotencyKey, 'after-contention');
    expect(intents.last.enqueueOrder, 13);
    expect(storage.conflicts, 1);
    await fixture.dispose();
  });

  for (final duplicate in [
    'exact',
    'different reaction',
    'different mutation'
  ]) {
    test('enqueue retry re-evaluates duplicate key: $duplicate', () async {
      final backing = InMemoryApplicationChatStorage();
      final storage = _AtomicMutationStorage(backing);
      final fixture = _offlineFixture(storage);
      await fixture.activate();
      final existing = ApplicationChatQueuedMessageMutationIntent(
        request: duplicate == 'different mutation'
            ? SoftDeleteMessageRequest.fromJson({
                'operation': 'soft_delete',
                'messageId': _messageId.toJson(),
                'expectedRevision': 1,
                'idempotencyKey': 'duplicate',
              })
            : ReactionMutationInput.fromJson({
                ..._request('duplicate'),
                if (duplicate == 'different reaction')
                  'operation': 'remove_reaction',
              }),
        enqueueOrder: 7,
        enqueuedAt: const IsoTimestamp('2032-01-01T00:00:00.000Z'),
      );
      storage.beforeExchange = (_, __) => backing.replace(
            ApplicationChatQueuedMessageMutationIntentsRecord(
              identity: _identity,
              intents: [existing],
            ),
          );

      final result = await fixture.client.setReaction(_input('duplicate'));
      if (duplicate == 'exact') {
        expect(
            result, isA<ChatCommandTransportFailure<ReactionMutationResult>>());
        expect(fixture.transport.patches, hasLength(1));
      } else {
        expect(result,
            isA<ChatCommandValidationFailure<ReactionMutationResult>>());
        expect(fixture.transport.patches, isEmpty);
      }
      expect(
          (await _readMutations(backing, _identity))!.intents.single.toJson(),
          existing.toJson());
      expect(storage.conflicts, 1);
      await fixture.dispose();
    });
  }

  test(
      'exact settlement retries and preserves concurrently appended unrelated intents',
      () async {
    final backing = InMemoryApplicationChatStorage();
    final storage = _AtomicMutationStorage(backing);
    final unrelated = _unrelatedMutations();
    final fixture = _Fixture(
      storage: storage,
      store: _seedStore(),
      transport: _ScriptedTransport()
        ..enqueuePatch((request) async {
          storage.beforeExchange = (expected, replacement) async {
            expect(expected, isNotNull);
            expect(replacement, isNull);
            final current = (await _readMutations(backing, _identity))!;
            await backing
                .replace(ApplicationChatQueuedMessageMutationIntentsRecord(
              identity: _identity,
              intents: [...current.intents, ...unrelated],
            ));
          };
          return _successResponse(_requestFrom(request));
        }),
    );
    await fixture.activate();
    expect(await fixture.client.setReaction(_input('settled')),
        isA<ChatCommandSuccess<ReactionMutationResult>>());
    expect(
        (await _readMutations(backing, _identity))!
            .intents
            .map((i) => i.toJson()),
        unrelated.map((i) => i.toJson()));
    expect(storage.conflicts, 1);
    expect(storage.unconditionalMutationRemovals, 0);
    await fixture.dispose();
  });

  for (final changedField in ['timestamp', 'request', 'order', 'key']) {
    test('stale settlement preserves a replacement with changed $changedField',
        () async {
      final backing = InMemoryApplicationChatStorage();
      final storage = _AtomicMutationStorage(backing);
      final replacement = ApplicationChatQueuedMessageMutationIntent(
        request: ReactionMutationInput.fromJson({
          ..._request(changedField == 'key' ? 'replacement' : 'same-key'),
          if (changedField == 'request') 'operation': 'remove_reaction',
        }),
        enqueueOrder: changedField == 'order' ? 2 : 1,
        enqueuedAt: IsoTimestamp(changedField == 'timestamp'
            ? '2032-02-02T00:00:00.000Z'
            : '2032-02-01T00:00:00.000Z'),
      );
      final fixture = _Fixture(
        storage: storage,
        store: _seedStore(),
        transport: _ScriptedTransport()
          ..enqueuePatch((request) async {
            storage.beforeExchange = (expected, proposal) async {
              expect(expected, isNotNull);
              expect(proposal, isNull);
              await backing
                  .replace(ApplicationChatQueuedMessageMutationIntentsRecord(
                identity: _identity,
                intents: [replacement],
              ));
            };
            return _successResponse(_requestFrom(request));
          }),
      );
      await fixture.activate();
      expect(await fixture.client.setReaction(_input('same-key')),
          isA<ChatCommandSuccess<ReactionMutationResult>>());
      expect(
          (await _readMutations(backing, _identity))!.intents.single.toJson(),
          replacement.toJson());
      expect(storage.conflicts, 1);
      expect(storage.unconditionalMutationRemovals, 0);
      await fixture.dispose();
    });
  }

  test('reaction hydration re-reads the committed record after contention',
      () async {
    final backing = InMemoryApplicationChatStorage();
    final storage = _AtomicMutationStorage(backing);
    // Target reaction hydration, after forward, edit, and delete hydration.
    storage.beforeEncodedRead = (readNumber) {
      if (readNumber != 4) return;
      storage.beforeExchange = (expected, replacement) async {
        expect(expected, isNull);
        expect(replacement, isNull);
        await _seedReaction(backing, _identity, 'hydration-winner');
      };
    };
    final fixture = _offlineFixture(storage);
    await fixture.activate();
    expect(storage.conflicts, 1);
    expect(_aggregate(fixture.store)?.reactedByCurrentUser, isTrue);
    expect(
        (await _readMutations(backing, _identity))!
            .intents
            .single
            .idempotencyKey,
        'hydration-winner');
    expect(fixture.transport.patches, isEmpty);
    await fixture.dispose();
  });

  test('reaction hydration quarantine cannot delete a racing valid replacement',
      () async {
    final backing = InMemoryApplicationChatStorage();
    final storage = _AtomicMutationStorage(backing);
    final diagnostics = <ChatClientDiagnostic>[];
    // Forward, edit, and delete hydrate this shared record before reactions.
    storage.beforeEncodedRead = (readNumber) {
      if (readNumber != 4) return;
      backing.putRawRecordForTesting(
          _identity,
          ApplicationChatStorageRecordKind.queuedMessageMutationIntents,
          {'malformed': 'private-record-details'});
      storage.beforeExchange = (expected, replacement) async {
        expect(expected, contains('private-record-details'));
        expect(replacement, isNull);
        await _seedReaction(backing, _identity, 'valid-replacement');
      };
    };
    final fixture = _Fixture(
      storage: storage,
      store: _seedStore(),
      transport: _ScriptedTransport(),
      onStorageDiagnostic: diagnostics.add,
    );
    await fixture.activate();
    expect(
        (await _readMutations(backing, _identity))!
            .intents
            .single
            .idempotencyKey,
        'valid-replacement');
    expect(storage.conflicts, 1);
    expect(storage.unconditionalMutationRemovals, 0);
    expect(diagnostics.map((d) => d.code),
        contains(ChatClientDiagnosticCode.messageMutationIntentsRejected));
    expect(diagnostics.map((d) => d.message).join(),
        isNot(contains('private-record-details')));
    expect(fixture.transport.patches, isEmpty);
    await fixture.dispose();
    // A fresh runtime reads and projects the valid committed value.
    storage.beforeEncodedRead = null;
    final restarted = _offlineFixture(storage);
    await restarted.activate();
    expect(_aggregate(restarted.store)?.reactedByCurrentUser, isTrue);
    expect(restarted.transport.patches, isEmpty);
    await restarted.dispose();
  });

  test('persists before projection, token access, or transport', () async {
    final backing = InMemoryApplicationChatStorage();
    final storage = _BlockingMutationStorage(backing);
    final transport = _ScriptedTransport();
    final response = Completer<HandrailChatHttpResponse>();
    transport.enqueuePatch((_) => response.future);
    var tokenCalls = 0;
    final fixture = _Fixture(
      storage: storage,
      store: _seedStore(),
      transport: transport,
      tokenProvider: () async {
        tokenCalls += 1;
        return 'token';
      },
    );
    await fixture.activate();

    final pending = fixture.client.setReaction(_input('persist-first'));
    await storage.replaceStarted.future;
    expect(_aggregate(fixture.store), isNull);
    expect(tokenCalls, 0);
    expect(transport.patches, isEmpty);

    storage.releaseReplace.complete();
    await _eventually(() => transport.patches.length == 1);
    response.complete(_successResponse(_requestFrom(transport.patches.single)));
    expect(await pending, isA<ChatCommandSuccess<ReactionMutationResult>>());
    expect(_requestFrom(transport.patches.single), _request('persist-first'));
    await fixture.dispose();
  });

  test('failed persistence causes no projection, authentication, or dispatch',
      () async {
    final backing = InMemoryApplicationChatStorage();
    final diagnostics = <ChatClientDiagnostic>[];
    var tokenCalls = 0;
    final fixture = _Fixture(
      storage: _FailingMutationStorage(backing),
      store: _seedStore(),
      transport: _ScriptedTransport(),
      tokenProvider: () async {
        tokenCalls += 1;
        return 'token';
      },
      onStorageDiagnostic: diagnostics.add,
    );
    await fixture.activate();

    expect(await fixture.client.setReaction(_input('write-failure')),
        isA<ChatCommandValidationFailure<ReactionMutationResult>>());
    expect(_aggregate(fixture.store), isNull);
    expect(tokenCalls, 0);
    expect(fixture.transport.patches, isEmpty);
    expect(diagnostics.single.code,
        ChatClientDiagnosticCode.messageMutationIntentsWriteFailed);
    expect(await _readMutations(backing, _identity), isNull);
    await fixture.dispose();
  });

  test('adjacent coalescing keeps latest state at the stable queue position',
      () async {
    final storage = InMemoryApplicationChatStorage();
    final transport = _ScriptedTransport();
    final active = Completer<HandrailChatHttpResponse>();
    transport.enqueuePatch((_) => active.future);
    final fixture = _Fixture(
      storage: storage,
      store: _seedStore(),
      transport: transport,
    );
    await fixture.activate();

    final first = fixture.client.setReaction(_input('add'));
    await _eventually(() => transport.patches.length == 1);
    final second = fixture.client.setReaction(
      _input('remove', reactedByCurrentUser: false),
    );
    await _eventually(() async {
      final record = await _readMutations(storage, _identity);
      return record?.intents.single.idempotencyKey == 'remove';
    });
    final record = await _readMutations(storage, _identity);
    expect(record!.intents, hasLength(1));
    expect(record.intents.single.enqueueOrder, 1);
    expect(record.intents.single.request, isA<RemoveReactionInput>());
    expect(_aggregate(fixture.store), isNull);

    final close = fixture.client.dispose();
    expect(await first, isA<ChatCommandClosed<ReactionMutationResult>>());
    expect(await second, isA<ChatCommandClosed<ReactionMutationResult>>());
    await close;
    await fixture.disposeDependencies();
  });

  test('intervening and independent reaction lanes retain FIFO entries',
      () async {
    final storage = InMemoryApplicationChatStorage();
    final transport = _ScriptedTransport();
    final pending = <Completer<HandrailChatHttpResponse>>[];
    for (var index = 0; index < 2; index += 1) {
      final response = Completer<HandrailChatHttpResponse>();
      pending.add(response);
      transport.enqueuePatch((_) => response.future);
    }
    final fixture = _Fixture(
      storage: storage,
      store: _seedStore(),
      transport: transport,
    );
    await fixture.activate();
    final futures = <Future<ChatCommandResult<ReactionMutationResult>>>[
      fixture.client.setReaction(_input('a-add')),
      fixture.client.setReaction(_input('b-add', reactionKey: 'heart')),
      fixture.client.setReaction(
        _input('a-remove', reactedByCurrentUser: false),
      ),
    ];
    await _eventually(() async =>
        (await _readMutations(storage, _identity))?.intents.length == 3);
    final intents = (await _readMutations(storage, _identity))!.intents;
    expect(intents.map((intent) => intent.idempotencyKey),
        ['a-add', 'b-add', 'a-remove']);
    expect(intents.map((intent) => intent.enqueueOrder), [1, 2, 3]);

    final close = fixture.client.dispose();
    for (final future in futures) {
      expect(await future, isA<ChatCommandClosed<ReactionMutationResult>>());
    }
    await close;
    await fixture.disposeDependencies();
  });

  test('restart restores projection and replays exact body and key', () async {
    final storage = InMemoryApplicationChatStorage();
    await _seedSnapshot(storage, _seedStore());
    final firstTransport = _ScriptedTransport()
      ..enqueuePatch((_) async => throw StateError('offline'));
    final first = _Fixture(
      storage: storage,
      store: NormalizedSnapshotStore(),
      transport: firstTransport,
      retryWait: _NeverRetryWait().call,
    );
    await first.activate();
    expect(await first.client.setReaction(_input('restart-key')),
        isA<ChatCommandTransportFailure<ReactionMutationResult>>());
    final exact = (await _readMutations(storage, _identity))!
        .intents
        .single
        .request as ReactionMutationInput;
    await first.dispose();

    final secondTransport = _ScriptedTransport()
      ..enqueuePatch((request) async =>
          _successResponse(_requestFrom(request), replayed: true));
    final second = _Fixture(
      storage: storage,
      store: NormalizedSnapshotStore(),
      transport: secondTransport,
    );
    await second.activate();
    expect(_aggregate(second.store)?.reactedByCurrentUser, isTrue);
    expect(secondTransport.patches, isEmpty);
    await second.initialize();
    await _eventually(
        () async => await _readMutations(storage, _identity) == null);
    expect(_requestFrom(secondTransport.patches.single), exact.toJson());
    expect(secondTransport.patches.single.headers['Idempotency-Key'],
        'restart-key');
    await second.dispose();
  });

  test('canonical event settles active dispatch before HTTP completion',
      () async {
    final storage = InMemoryApplicationChatStorage();
    final response = Completer<HandrailChatHttpResponse>();
    final transport = _ScriptedTransport()
      ..enqueuePatch((_) => response.future);
    final fixture = _Fixture(
      storage: storage,
      store: _seedStore(),
      transport: transport,
    );
    await fixture.activate();
    final pending = fixture.client.setReaction(_input('event-first'));
    await _eventually(() => transport.patches.length == 1);

    fixture.client.reduceDurableEvent(_reactionEvent());
    expect(await pending, isA<ChatCommandSuccess<ReactionMutationResult>>());
    expect(await _readMutations(storage, _identity), isNull);
    expect(_aggregate(fixture.store)?.count, 4);
    response.complete(_successResponse(_requestFrom(transport.patches.single)));
    await fixture.dispose();
  });

  test('ambiguous outcomes retain while terminal outcomes remove', () async {
    final ambiguousCases =
        <Future<HandrailChatHttpResponse> Function(HandrailChatHttpRequest)>[
      (_) async => throw StateError('offline'),
      (_) async => _errorResponse(429, 'RATE_LIMITED'),
      (_) async => _errorResponse(500, 'SERVER_FAILED'),
      (_) async => const HandrailChatHttpResponse(
            statusCode: 200,
            body: '{bad-json',
          ),
    ];
    for (var index = 0; index < ambiguousCases.length; index += 1) {
      final storage = InMemoryApplicationChatStorage();
      final fixture = _Fixture(
        storage: storage,
        store: _seedStore(),
        transport: _ScriptedTransport()..enqueuePatch(ambiguousCases[index]),
        retryWait: _NeverRetryWait().call,
      );
      await fixture.activate();
      final result =
          await fixture.client.setReaction(_input('ambiguous-$index'));
      expect(
          result,
          anyOf(isA<ChatCommandTransportFailure>(),
              isA<ChatCommandMalformedResponse>()));
      expect((await _readMutations(storage, _identity))?.intents, hasLength(1));
      await fixture.dispose();
    }

    final cancellationStorage = InMemoryApplicationChatStorage();
    final cancellationResponse = Completer<HandrailChatHttpResponse>();
    final cancellationTransport = _ScriptedTransport()
      ..enqueuePatch((_) => cancellationResponse.future);
    final cancellationFixture = _Fixture(
      storage: cancellationStorage,
      store: _seedStore(),
      transport: cancellationTransport,
      retryWait: _NeverRetryWait().call,
    );
    await cancellationFixture.activate();
    final cancellation = ChatCommandCancellationController();
    final cancelled = cancellationFixture.client.setReaction(
      _input('cancelled-after-dispatch'),
      cancellationSignal: cancellation.signal,
    );
    await _eventually(() => cancellationTransport.patches.length == 1);
    cancellation.cancel();
    expect(await cancelled, isA<ChatCommandAborted<ReactionMutationResult>>());
    expect((await _readMutations(cancellationStorage, _identity))?.intents,
        hasLength(1));
    await cancellationFixture.dispose();

    for (final entry in <(int, String)>[
      (403, 'AUTHENTICATION_FAILED'),
      (409, 'CONFLICT'),
    ]) {
      final storage = InMemoryApplicationChatStorage();
      final fixture = _Fixture(
        storage: storage,
        store: _seedStore(),
        transport: _ScriptedTransport()
          ..enqueuePatch((_) async => _errorResponse(entry.$1, entry.$2)),
      );
      await fixture.activate();
      await fixture.client.setReaction(_input('terminal-${entry.$1}'));
      expect(await _readMutations(storage, _identity), isNull);
      expect(_aggregate(fixture.store), isNull);
      await fixture.dispose();
    }
  });

  test('reaction settlement preserves non-reaction mutation intents', () async {
    final storage = InMemoryApplicationChatStorage();
    final edit = EditMessageRequest.fromJson({
      'operation': 'edit',
      'messageId': _messageId.toJson(),
      'expectedRevision': 1,
      'content': {
        'format': 'plain',
        'text': 'retained edit',
      },
      'idempotencyKey': 'independent-edit',
    });
    await storage.replace(ApplicationChatQueuedMessageMutationIntentsRecord(
      identity: _identity,
      intents: [
        ApplicationChatQueuedMessageMutationIntent(
          request: edit,
          enqueueOrder: 1,
          enqueuedAt: const IsoTimestamp('2032-02-01T00:00:00.000Z'),
        ),
      ],
    ));
    final fixture = _Fixture(
      storage: storage,
      store: _seedStore(),
      transport: _ScriptedTransport()
        ..enqueuePatch(
            (request) async => _successResponse(_requestFrom(request))),
    );
    await fixture.activate();
    expect(await fixture.client.setReaction(_input('settled-reaction')),
        isA<ChatCommandSuccess<ReactionMutationResult>>());
    final retained = await _readMutations(storage, _identity);
    expect(retained!.intents, hasLength(1));
    expect(retained.intents.single.request, isA<EditMessageRequest>());
    expect(retained.intents.single.idempotencyKey, 'independent-edit');
    await fixture.dispose();
  });

  test('replay waits for baseline and foreground online realtime readiness',
      () async {
    final missingStorage = InMemoryApplicationChatStorage();
    await _seedReaction(missingStorage, _identity, 'missing-base');
    final missingTransport = _ScriptedTransport()
      ..enqueuePatch(
          (request) async => _successResponse(_requestFrom(request)));
    final missing = _Fixture(
      storage: missingStorage,
      store: NormalizedSnapshotStore(),
      transport: missingTransport,
    );
    await missing.activate();
    await missing.initialize();
    expect(missingTransport.patches, isEmpty);
    missing.store.installPersistedSnapshot(
      _seedStore().canonicalPersistenceSnapshot(),
    );
    await _eventually(() => missingTransport.patches.length == 1);
    await missing.dispose();

    final storage = InMemoryApplicationChatStorage();
    await _seedReaction(storage, _identity, 'lifecycle-key');
    final network = FakeChatRealtimeNetwork(isOnline: false);
    final socket = FakeChatRealtimeSocket();
    final socketFactory = FakeChatRealtimeSocketFactory()
      ..enqueueSocket(socket);
    final session = ChatRealtimeSessionTransport(
      endpoint: Uri.parse('https://chat.example.test/api/chat'),
      clientPackageVersion: '0.1.3',
      protocolVersion: handrailChatProtocolVersion,
      tokenProvider: () => 'realtime-token',
      socketFactory: socketFactory.call,
      network: network,
    );
    final transport = _ScriptedTransport()
      ..enqueuePatch(
          (request) async => _successResponse(_requestFrom(request)));
    final fixture = _Fixture(
      storage: storage,
      store: _seedStore(),
      transport: transport,
      realtimeSession: session,
      network: network,
    );
    await fixture.activate();
    await fixture.initialize();
    expect(transport.patches, isEmpty);
    fixture.client.setApplicationForeground(false);
    await session.start();
    network.setOnline(true);
    await _eventually(() => socketFactory.uris.length == 1);
    socket.emitJson(_acceptedFrame());
    await _eventually(() => session.state is ChatRealtimeConnectedState);
    expect(transport.patches, isEmpty);
    fixture.client.setApplicationForeground(true);
    await _eventually(() => transport.patches.length == 1);
    await fixture.dispose();
  });

  test('identity replacement and dispose isolate delayed persistence',
      () async {
    final backing = InMemoryApplicationChatStorage();
    final storage = _BlockingMutationStorage(backing);
    final fixture = _Fixture(
      storage: storage,
      store: _seedStore(),
      transport: _ScriptedTransport(),
    );
    await fixture.activate();
    final pending = fixture.client.setReaction(_input('old-identity'));
    await storage.replaceStarted.future;
    final replacement = fixture.client.activateStorageIdentity(_otherIdentity);
    storage.releaseReplace.complete();
    expect(await pending, isA<ChatCommandClosed<ReactionMutationResult>>());
    await replacement;
    expect(fixture.transport.patches, isEmpty);
    expect((await _readMutations(backing, _identity))?.intents, hasLength(1));
    await fixture.dispose();

    final disposeBacking = InMemoryApplicationChatStorage();
    final disposeStorage = _BlockingMutationStorage(disposeBacking);
    final disposing = _Fixture(
      storage: disposeStorage,
      store: _seedStore(),
      transport: _ScriptedTransport(),
    );
    await disposing.activate();
    final disposePending =
        disposing.client.setReaction(_input('dispose-during-write'));
    await disposeStorage.replaceStarted.future;
    final close = disposing.client.dispose();
    disposeStorage.releaseReplace.complete();
    expect(
        await disposePending, isA<ChatCommandClosed<ReactionMutationResult>>());
    await close;
    expect(disposing.transport.patches, isEmpty);
    expect((await _readMutations(disposeBacking, _identity))?.intents,
        hasLength(1));
    await disposing.disposeDependencies();
  });
}

_Fixture _offlineFixture(ApplicationChatStorage storage,
        {ChatReactionClock? clock}) =>
    _Fixture(
      storage: storage,
      clock: clock,
      store: _seedStore(),
      transport: _ScriptedTransport()
        ..enqueuePatch((_) async => throw StateError('offline')),
      retryWait: _NeverRetryWait().call,
    );

List<ApplicationChatQueuedMessageMutationIntent> _unrelatedMutations() => [
      ApplicationChatQueuedMessageMutationIntent(
        request: EditMessageRequest.fromJson({
          'operation': 'edit',
          'messageId': 'other-edit-message',
          'expectedRevision': 1,
          'content': {'format': 'plain', 'text': 'retained edit'},
          'idempotencyKey': 'unrelated-edit',
        }),
        enqueueOrder: 10,
        enqueuedAt: const IsoTimestamp('2032-02-01T00:00:10.000Z'),
      ),
      ApplicationChatQueuedMessageMutationIntent(
        request: SoftDeleteMessageRequest.fromJson({
          'operation': 'soft_delete',
          'messageId': 'other-delete-message',
          'expectedRevision': 1,
          'idempotencyKey': 'unrelated-delete',
        }),
        enqueueOrder: 11,
        enqueuedAt: const IsoTimestamp('2032-02-01T00:00:11.000Z'),
      ),
      ApplicationChatQueuedMessageMutationIntent(
        request: ForwardMessageRequest.fromJson({
          'operation': 'forward_message.v1',
          'sourceMessageId': 'other-forward-message',
          'destinationConversationId': 'other-conversation',
          'clientCorrelationId': 'unrelated-forward-correlation',
          'idempotencyKey': 'unrelated-forward',
        }),
        enqueueOrder: 12,
        enqueuedAt: const IsoTimestamp('2032-02-01T00:00:12.000Z'),
      ),
    ];

final class _Fixture {
  _Fixture({
    required ApplicationChatStorage storage,
    required this.store,
    required this.transport,
    HandrailChatAccessTokenProvider? tokenProvider,
    ChatReactionRetryWait? retryWait,
    ChatReactionClock? clock,
    ChatClientDiagnosticCallback? onStorageDiagnostic,
    this.realtimeSession,
    this.network,
  }) {
    client = HandrailChatClient(
      apiBaseUri: Uri.parse('https://chat.example.test/api/chat'),
      tokenProvider: tokenProvider ?? () async => 'access-token',
      transport: transport,
      localStorage: storage,
      storageIdentity: _identity,
      normalizedSnapshotStore: store,
      realtimeSession: realtimeSession,
      commandRetryOptions: const ChatCommandRetryOptions(
        maxAttempts: 1,
        maxAuthenticationRefreshes: 0,
      ),
      reactionClock: clock ?? () => DateTime.utc(2032, 2, 1),
      reactionRetryWait: retryWait,
      onStorageDiagnostic: onStorageDiagnostic,
    );
  }

  final NormalizedSnapshotStore store;
  final _ScriptedTransport transport;
  final ChatRealtimeSessionTransport? realtimeSession;
  final FakeChatRealtimeNetwork? network;
  late final HandrailChatClient client;
  bool _disposed = false;

  Future<void> activate() => client.activateStorageIdentity(_identity);

  Future<void> initialize() async {
    expect(await client.initialize(), isA<ChatClientReadyState>());
  }

  Future<void> dispose() async {
    if (!_disposed) {
      _disposed = true;
      await client.dispose();
    }
    await disposeDependencies();
  }

  Future<void> disposeDependencies() async {
    await realtimeSession?.dispose();
    await network?.dispose();
    await store.close();
  }
}

final class _ScriptedTransport implements HandrailChatHttpTransport {
  final Queue<
          Future<HandrailChatHttpResponse> Function(HandrailChatHttpRequest)>
      _patchHandlers = Queue();
  final List<HandrailChatHttpRequest> requests = [];

  Iterable<HandrailChatHttpRequest> get patches =>
      requests.where((request) => request.method == 'PATCH');

  void enqueuePatch(
    Future<HandrailChatHttpResponse> Function(HandrailChatHttpRequest) handler,
  ) =>
      _patchHandlers.add(handler);

  @override
  Future<HandrailChatHttpResponse> send(HandrailChatHttpRequest request) {
    requests.add(request);
    if (request.method == 'GET') {
      return Future.value(HandrailChatHttpResponse(
        statusCode: 200,
        body: jsonEncode(_metadata),
      ));
    }
    if (_patchHandlers.isEmpty) {
      return Future.error(StateError('No scripted PATCH response remains.'));
    }
    return _patchHandlers.removeFirst()(request);
  }
}

class _AtomicMutationStorage implements AtomicApplicationChatStorage {
  _AtomicMutationStorage(this.backing);

  final InMemoryApplicationChatStorage backing;
  Future<void> Function(String? expected, String? replacement)? beforeExchange;
  void Function(int readNumber)? beforeEncodedRead;
  int encodedReads = 0;
  int conflicts = 0;
  int unconditionalMutationRemovals = 0;

  @override
  Future<String?> readEncoded(ApplicationChatStorageIdentity identity,
      ApplicationChatStorageRecordKind kind) {
    if (kind == ApplicationChatStorageRecordKind.queuedMessageMutationIntents) {
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
    if (kind == ApplicationChatStorageRecordKind.queuedMessageMutationIntents) {
      final hook = beforeExchange;
      beforeExchange = null;
      await hook?.call(expected, replacement);
    }
    final committed =
        await backing.compareExchange(identity, kind, expected, replacement);
    if (!committed &&
        kind == ApplicationChatStorageRecordKind.queuedMessageMutationIntents) {
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
  Future<void> replace(ApplicationChatStorageRecord record) =>
      backing.replace(record);

  @override
  Future<void> remove(ApplicationChatStorageIdentity identity,
      ApplicationChatStorageRecordKind kind) {
    if (kind == ApplicationChatStorageRecordKind.queuedMessageMutationIntents) {
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

final class _BlockingMutationStorage implements ApplicationChatStorage {
  _BlockingMutationStorage(this.backing);
  final InMemoryApplicationChatStorage backing;
  final Completer<void> replaceStarted = Completer<void>();
  final Completer<void> releaseReplace = Completer<void>();

  @override
  Future<ApplicationChatStorageRecord?> read(
          ApplicationChatStorageIdentity identity,
          ApplicationChatStorageRecordKind kind) =>
      backing.read(identity, kind);

  @override
  Future<void> replace(ApplicationChatStorageRecord record) async {
    if (record.kind ==
        ApplicationChatStorageRecordKind.queuedMessageMutationIntents) {
      if (!replaceStarted.isCompleted) replaceStarted.complete();
      await releaseReplace.future;
    }
    await backing.replace(record);
  }

  @override
  Future<void> remove(ApplicationChatStorageIdentity identity,
          ApplicationChatStorageRecordKind kind) =>
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
          previousIdentity: previousIdentity, nextIdentity: nextIdentity);
}

final class _FailingMutationStorage implements ApplicationChatStorage {
  _FailingMutationStorage(this.backing);
  final InMemoryApplicationChatStorage backing;

  @override
  Future<ApplicationChatStorageRecord?> read(
          ApplicationChatStorageIdentity identity,
          ApplicationChatStorageRecordKind kind) =>
      backing.read(identity, kind);

  @override
  Future<void> replace(ApplicationChatStorageRecord record) => record.kind ==
          ApplicationChatStorageRecordKind.queuedMessageMutationIntents
      ? Future<void>.error(StateError('storage unavailable'))
      : backing.replace(record);

  @override
  Future<void> remove(ApplicationChatStorageIdentity identity,
          ApplicationChatStorageRecordKind kind) =>
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
          previousIdentity: previousIdentity, nextIdentity: nextIdentity);
}

final class _NeverRetryWait {
  Future<void> call(Duration _, ChatCommandCancellationSignal signal) {
    final completer = Completer<void>();
    signal.onCancelled.listen((_) {
      if (!completer.isCompleted) completer.complete();
    });
    return completer.future;
  }
}

ChatSetReactionInput _input(
  String key, {
  String reactionKey = 'thumbsup',
  bool reactedByCurrentUser = true,
}) =>
    ChatSetReactionInput(
      messageId: _messageId,
      reactionKey: reactionKey,
      reactedByCurrentUser: reactedByCurrentUser,
      idempotencyKey: key,
    );

Map<String, Object?> _request(String key) => {
      'operation': 'add_reaction',
      'messageId': _messageId.toJson(),
      'reactionKey': 'thumbsup',
      'idempotencyKey': key,
    };

Map<String, Object?> _requestFrom(HandrailChatHttpRequest request) =>
    (jsonDecode(request.body!) as Map).cast<String, Object?>();

HandrailChatHttpResponse _successResponse(Map<String, Object?> request,
        {bool replayed = false}) =>
    HandrailChatHttpResponse(
      statusCode: 200,
      body: jsonEncode({
        'operation': request['operation'],
        'reconciliationStatus': replayed ? 'replayed' : 'applied',
        'messageId': request['messageId'],
        'reactionKey': request['reactionKey'],
        'count': request['operation'] == 'add_reaction' ? 1 : 0,
        'reactedByCurrentUser': request['operation'] == 'add_reaction',
      }),
    );

HandrailChatHttpResponse _errorResponse(int status, String code) =>
    HandrailChatHttpResponse(
      statusCode: status,
      body: jsonEncode({
        'error': {'code': code, 'message': 'request failed'},
      }),
    );

MessageReactionAggregate? _aggregate(NormalizedSnapshotStore store) {
  final reactions = store.state.messages[_messageId]?.reactions ?? const [];
  for (final reaction in reactions) {
    if (reaction.reactionKey == 'thumbsup') return reaction;
  }
  return null;
}

NormalizedSnapshotStore _seedStore() {
  final store = NormalizedSnapshotStore();
  store.hydrateConversationList(ConversationListSnapshot.fromJson({
    'kind': 'conversation_list',
    'scope': const OrganizationConversationSnapshotScope().toJson(),
    'items': [
      {
        'id': _conversationId.toJson(),
        'tenantId': _identity.tenantId.toJson(),
        'type': 'channel',
        'name': 'Durable reactions',
        'visibility': 'public',
        'createdAt': '2032-02-01T00:00:00.000Z',
        'updatedAt': '2032-02-01T00:00:00.000Z',
        'latestSequence': 1,
        'activityAt': '2032-02-01T00:00:01.000Z',
        'unreadMentionCount': 0,
        'currentMember': {
          'tenantId': _identity.tenantId.toJson(),
          'conversationId': _conversationId.toJson(),
          'userId': _identity.userId.toJson(),
          'role': 'member',
          'state': 'active',
          'joinedAt': '2032-02-01T00:00:00.000Z',
          'updatedAt': '2032-02-01T00:00:00.000Z',
        },
        'currentReadState': {
          'conversationId': _conversationId.toJson(),
          'userId': _identity.userId.toJson(),
          'lastReadSequence': 0,
          'updatedAt': '2032-02-01T00:00:00.000Z',
        },
        'currentPreference': {
          'conversationId': _conversationId.toJson(),
          'userId': _identity.userId.toJson(),
          'notificationPreference': 'mentions',
          'isStarred': false,
          'mute': {'muted': false},
          'updatedAt': '2032-02-01T00:00:00.000Z',
        },
        'activeMemberUserIds': [_identity.userId.toJson()],
      },
    ],
    'page': <String, Object?>{},
    '_meta': {
      ..._metadata,
      'feature': {
        'name': conversationSnapshotFeature,
        'version': conversationSnapshotVersion,
      },
    },
  }));
  final request = MessageTimelineRequest(
    conversationId: _conversationId,
    direction: MessageTimelineDirection.backward,
    limit: 10,
  );
  store.hydrateMessageTimeline(MessageTimelinePage.fromJson(
    {
      'conversationId': _conversationId.toJson(),
      'messages': [
        {
          ..._message().toJson(),
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
  ));
  return store;
}

ActiveMessage _message() => ActiveMessage(
      id: _messageId,
      tenantId: _identity.tenantId,
      conversationId: _conversationId,
      author: const MessageAuthorIdentity(userId: UserId('user-1')),
      sequence: const MessageSequence(1),
      createdAt: const IsoTimestamp('2032-02-01T00:00:01.000Z'),
      updatedAt: const IsoTimestamp('2032-02-01T00:00:01.000Z'),
      revision: const MessageRevisionMetadata(revision: 1),
      content: MessageContent(
        format: MessageContentFormat.plain,
        text: 'message',
      ),
    );

KnownDurableEvent _reactionEvent() => KnownDurableEvent.fromJson(
      {
        'eventId': 'reaction-event-1',
        'protocolVersion': handrailChatProtocolVersion,
        'tenantId': _identity.tenantId.toJson(),
        'streamId': _conversationId.toJson(),
        'type': 'reaction.updated',
        'occurredAt': '2032-02-01T00:00:05.000Z',
        'payload': {
          'conversationId': _conversationId.toJson(),
          'operation': 'add_reaction',
          'reconciliationStatus': 'applied',
          'messageId': _messageId.toJson(),
          'reactionKey': 'thumbsup',
          'count': 4,
          'reactedByCurrentUser': true,
        },
      },
      trustedIdentity: DurableEventTrustedIdentity(
        tenantId: _identity.tenantId,
        userId: _identity.userId,
      ),
    );

Future<void> _seedReaction(ApplicationChatStorage storage,
        ApplicationChatStorageIdentity identity, String key) =>
    storage.replace(ApplicationChatQueuedMessageMutationIntentsRecord(
      identity: identity,
      intents: [
        ApplicationChatQueuedMessageMutationIntent(
          request: AddReactionInput(
            messageId: _messageId,
            reactionKey: 'thumbsup',
            idempotencyKey: key,
          ),
          enqueueOrder: 1,
          enqueuedAt: const IsoTimestamp('2032-02-01T00:00:00.000Z'),
        ),
      ],
    ));

Future<void> _seedSnapshot(
    ApplicationChatStorage storage, NormalizedSnapshotStore store) async {
  await storage.replace(ApplicationChatNormalizedSnapshotRecord(
    identity: _identity,
    snapshot: store.canonicalPersistenceSnapshot(),
  ));
  await store.close();
}

Future<ApplicationChatQueuedMessageMutationIntentsRecord?> _readMutations(
        ApplicationChatStorage storage,
        ApplicationChatStorageIdentity identity) async =>
    await storage.read(
      identity,
      ApplicationChatStorageRecordKind.queuedMessageMutationIntents,
    ) as ApplicationChatQueuedMessageMutationIntentsRecord?;

Future<void> _eventually(FutureOr<bool> Function() predicate) async {
  for (var attempt = 0; attempt < 300; attempt += 1) {
    if (await predicate()) return;
    await Future<void>.delayed(Duration.zero);
  }
  fail('Condition was not reached.');
}

Map<String, Object?> _acceptedFrame() => {
      'type': 'chat.session.accepted',
      'metadata': _metadata,
      'tenantId': _identity.tenantId.toJson(),
      'actorStreamId': 'user:${_identity.userId.value}',
      'deviceId': _identity.deviceId.toJson(),
      'sessionId': 'session-1',
    };

const Map<String, Object?> _metadata = {
  'packageVersion': '0.1.3',
  'protocolVersion': handrailChatProtocolVersion,
  'schemaVersion': 1,
  'enabledFeatures': <String, Object?>{'realtime': true},
  'supportedProtocolRange': <String, Object?>{
    'minimumVersion': handrailChatProtocolVersion,
    'maximumVersion': handrailChatProtocolVersion,
  },
};
