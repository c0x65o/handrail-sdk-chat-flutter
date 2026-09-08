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

import 'fixtures/conversation_creation_fixtures.dart';

final _identity = ApplicationChatStorageIdentity(
  tenantId: const TenantId('tenant-from-session'),
  userId: const UserId('user-actor'),
  deviceId: const DeviceId('device-1'),
);
final _otherIdentity = ApplicationChatStorageIdentity(
  tenantId: const TenantId('tenant-from-session'),
  userId: const UserId('user-other'),
  deviceId: const DeviceId('device-2'),
);

void main() {
  test('distinct concurrent creations survive with committed FIFO metadata',
      () async {
    final storage = _AtomicCreationStorage();
    final keyCalls = [0, 0];
    final requestCalls = [0, 0];
    final clockCalls = [0, 0];
    final clients = List.generate(
        2,
        (index) => _Fixture(
              storage: storage,
              transport: _CreationTransport(),
              idempotencyGenerator: () => 'key-$index-${++keyCalls[index]}',
              requestIdGenerator: () =>
                  'request-$index-${++requestCalls[index]}',
              clock: () => DateTime.utc(2032, 2, 1, 0, 0, ++clockCalls[index]),
            ));
    for (final client in clients) {
      addTearDown(client.dispose);
      await client.activate();
    }
    final gates = [_ExchangeGate(), _ExchangeGate()];
    final retry = _ExchangeGate();
    storage.beforeExchange = (expected, replacement) async {
      if (replacement == null || expected == replacement) return;
      final record = _decodeCreations(replacement);
      final index =
          record.intents.last.request.idempotencyKey.startsWith('key-0')
              ? 0
              : 1;
      if (expected == null) {
        await gates[index].pause();
      } else if (index == 1) {
        await retry.pause();
      }
    };
    final first = clients[0].client.createChannel(const ChatCreateChannelInput(
          name: 'First',
          visibility: ConversationVisibility.private,
        ));
    await gates[0].started.future;
    final second = clients[1].client.createChannel(const ChatCreateChannelInput(
          name: 'Second',
          visibility: ConversationVisibility.private,
        ));
    await gates[1].started.future;
    for (final client in clients) {
      expect(client.client.queuedConversationCreations, isEmpty);
      expect(client.transport.posts, isEmpty);
    }
    gates[0].release.complete();
    await _eventually(
        () => clients[0].client.queuedConversationCreations.length == 1);
    gates[1].release.complete();
    await retry.started.future;
    expect(clients[1].client.queuedConversationCreations, isEmpty);
    expect((await _readCreations(storage.backing, _identity))!.intents,
        hasLength(1));
    expect(keyCalls, [1, 1]);
    expect(requestCalls, [1, 1]);
    expect(clockCalls, [1, 1]);
    retry.release.complete();
    await _eventually(
        () => clients[1].client.queuedConversationCreations.length == 2);
    final committed = (await _readCreations(storage.backing, _identity))!;
    expect(committed.intents.map((intent) => intent.enqueueOrder), [1, 2]);
    expect(committed.intents.map((intent) => intent.request.idempotencyKey),
        ['key-0-1', 'key-1-1']);
    expect(committed.intents.map((intent) => intent.enqueuedAt.value),
        everyElement('2032-02-01T00:00:01.000Z'));
    expect(
        clients[1]
            .client
            .queuedConversationCreations
            .map((intent) => intent.request.toJson()),
        committed.intents.map((intent) => intent.request.toJson()));
    await clients[1].initialize();
    expect(await second,
        isA<ChatCommandSuccess<ChannelConversationCreationResult>>());
    expect(
        clients[1]
            .transport
            .posts
            .map(_body)
            .map((body) => body['idempotencyKey']),
        ['key-0-1', 'key-1-1']);
    await clients[0].dispose();
    expect(await first,
        isA<ChatCommandClosed<ChannelConversationCreationResult>>());
  });

  for (final groupDirect in [false, true]) {
    test(
        'equivalent ${groupDirect ? 'group-direct' : 'direct'} contenders reuse the winner despite loser cancellation',
        () async {
      final storage = _AtomicCreationStorage();
      final keyCalls = [0, 0];
      final requestCalls = [0, 0];
      final clients = List.generate(
          2,
          (index) => _Fixture(
                storage: storage,
                transport: _CreationTransport(),
                idempotencyGenerator: () => 'key-$index-${++keyCalls[index]}',
                requestIdGenerator: () =>
                    'request-$index-${++requestCalls[index]}',
              ));
      for (final client in clients) {
        addTearDown(client.dispose);
        await client.activate();
      }
      final gates = [_ExchangeGate(), _ExchangeGate()];
      storage.beforeExchange = (expected, replacement) async {
        if (expected != null || replacement == null) return;
        final key =
            _decodeCreations(replacement).intents.single.request.idempotencyKey;
        await gates[key.startsWith('key-0') ? 0 : 1].pause();
      };
      final cancellation = ChatCommandCancellationController();
      Future<ChatCommandResult<ConversationCreationResult>> create(int index) =>
          groupDirect
              ? clients[index].client.createGroupDirect(
                  ChatCreateGroupDirectInput(
                    intendedMemberUserIds: index == 0
                        ? const [UserId('user-c'), UserId('user-b')]
                        : const [UserId('user-b'), UserId('user-c')],
                  ),
                  cancellationSignal: index == 1 ? cancellation.signal : null)
              : clients[index].client.createDirect(
                  ChatCreateDirectInput(
                    intendedMemberUserIds: const [UserId('user-b')],
                  ),
                  cancellationSignal: index == 1 ? cancellation.signal : null);
      final first = create(0);
      await gates[0].started.future;
      final second = create(1);
      await gates[1].started.future;
      expect(clients[1].client.queuedConversationCreations, isEmpty);
      gates[0].release.complete();
      await _eventually(
          () => clients[0].client.queuedConversationCreations.length == 1);
      cancellation.cancel();
      gates[1].release.complete();
      await _eventually(
          () => clients[1].client.queuedConversationCreations.isNotEmpty);
      final committed = (await _readCreations(storage.backing, _identity))!;
      expect(committed.intents, hasLength(1));
      expect(committed.intents.single.request.idempotencyKey, 'key-0-1');
      expect(committed.intents.single.request.clientRequestId, 'request-0-1');
      expect(keyCalls, [1, 1]);
      expect(requestCalls, [1, 1]);
      for (final client in clients) {
        expect(
            client.client.queuedConversationCreations.single.request.toJson(),
            committed.intents.single.request.toJson());
        expect(client.transport.posts, isEmpty);
      }
      await clients[1].initialize();
      final result = await second;
      expect(result, isA<ChatCommandSuccess<ConversationCreationResult>>());
      expect(
          (result as ChatCommandSuccess<ConversationCreationResult>)
              .value
              .clientRequestId,
          'request-0-1');
      expect(_body(clients[1].transport.posts.single),
          committed.intents.single.request.toJson());
      expect(await _readCreations(storage.backing, _identity), isNull);
      await clients[0].dispose();
      expect(await first, isA<ChatCommandClosed<ConversationCreationResult>>());
    });
  }

  for (final replacementChange in ['request', 'order', 'timestamp', 'none']) {
    test(
        'stale settlement preserves concurrent append and $replacementChange replacement',
        () async {
      final storage = _AtomicCreationStorage();
      final original = ConversationCreationInput.fromJson(
          channelConversationCreationInputFixture);
      await _seedCreations(storage.backing, [original]);
      final settler =
          _Fixture(storage: storage, transport: _CreationTransport());
      final appender =
          _Fixture(storage: storage, transport: _CreationTransport());
      addTearDown(settler.dispose);
      addTearDown(appender.dispose);
      await settler.activate();
      await appender.activate();
      final gate = _ExchangeGate();
      storage.beforeExchange = (expected, replacement) async {
        if (expected != null &&
            replacement == null &&
            !gate.started.isCompleted) {
          await gate.pause();
        }
      };
      settler.client.reduceDurableEvent(_creationEvent(original));
      await gate.started.future;
      if (replacementChange != 'none') {
        await storage.backing
            .replace(ApplicationChatQueuedConversationCreationIntentsRecord(
          identity: _identity,
          intents: [
            ApplicationChatQueuedConversationCreationIntent(
              request: ConversationCreationInput.fromJson({
                ...original.toJson(),
                if (replacementChange == 'request')
                  'name': 'Replacement channel',
              }),
              enqueueOrder: replacementChange == 'order' ? 7 : 1,
              enqueuedAt: IsoTimestamp(replacementChange == 'timestamp'
                  ? '2032-02-02T00:00:00.000Z'
                  : '2032-02-01T00:00:00.000Z'),
            )
          ],
        ));
      }
      final appended =
          appender.client.createChannel(const ChatCreateChannelInput(
        name: 'Unrelated append',
        visibility: ConversationVisibility.public,
      ));
      await _eventually(
          () => appender.client.queuedConversationCreations.length == 2);
      final beforeSettlement =
          (await _readCreations(storage.backing, _identity))!;
      final expectedRemainder = replacementChange == 'none'
          ? beforeSettlement.intents.skip(1).toList()
          : beforeSettlement.intents;
      gate.release.complete();
      await _eventually(() => settler.client.queuedConversationCreations
          .any((intent) => intent.request.idempotencyKey == 'generated-key'));
      final remainder = (await _readCreations(storage.backing, _identity))!;
      expect(remainder.intents.map((intent) => intent.toJson()),
          expectedRemainder.map((intent) => intent.toJson()));
      expect(
          settler.client.queuedConversationCreations
              .map((intent) => intent.request.toJson()),
          remainder.intents.map((intent) => intent.request.toJson()));
      expect(
          settler.client.queuedConversationCreations
              .map((intent) => intent.enqueueOrder),
          remainder.intents.map((intent) => intent.enqueueOrder));
      expect(settler.transport.posts, isEmpty);
      expect(appender.transport.posts, isEmpty);
      await appender.dispose();
      expect(await appended,
          isA<ChatCommandClosed<ChannelConversationCreationResult>>());
    });
  }

  test(
      'malformed quarantine preserves a valid replacement of the observed value',
      () async {
    final storage = _AtomicCreationStorage();
    storage.backing.putRawRecordForTesting(
        _identity,
        ApplicationChatStorageRecordKind.queuedConversationCreationIntents,
        {'malformed': true});
    final corrupt = await storage.backing.readEncoded(_identity,
        ApplicationChatStorageRecordKind.queuedConversationCreationIntents);
    final gate = _ExchangeGate();
    storage.beforeExchange = (expected, replacement) async {
      if (expected == corrupt && replacement == null) await gate.pause();
    };
    final diagnostics = <ChatClientDiagnostic>[];
    final fixture = _Fixture(
        storage: storage,
        transport: _CreationTransport(),
        onStorageDiagnostic: diagnostics.add);
    addTearDown(fixture.dispose);
    final activation = fixture.activate();
    await gate.started.future;
    await _seedCreations(storage.backing, [
      ConversationCreationInput.fromJson(directConversationCreationInputFixture)
    ]);
    final replacement = (await _readCreations(storage.backing, _identity))!;
    gate.release.complete();
    await activation;
    expect((await _readCreations(storage.backing, _identity))!.encode(),
        replacement.encode());
    expect(fixture.client.queuedConversationCreations, isEmpty);
    expect(fixture.transport.posts, isEmpty);
    expect(diagnostics.single.code,
        ChatClientDiagnosticCode.conversationCreationIntentsRejected);
    final restarted =
        _Fixture(storage: storage, transport: _CreationTransport());
    addTearDown(restarted.dispose);
    await restarted.activate();
    expect(restarted.client.queuedConversationCreations.single.request.toJson(),
        replacement.intents.single.request.toJson());
  });

  test(
      'bounded contention never publishes or dispatches an uncommitted creation',
      () async {
    final storage = _AtomicCreationStorage();
    var keyCalls = 0;
    var requestCalls = 0;
    var tokenCalls = 0;
    final diagnostics = <ChatClientDiagnostic>[];
    final fixture = _Fixture(
      storage: storage,
      transport: _CreationTransport(),
      idempotencyGenerator: () => 'key-${++keyCalls}',
      requestIdGenerator: () => 'request-${++requestCalls}',
      tokenProvider: () async {
        tokenCalls++;
        return 'token';
      },
      onStorageDiagnostic: diagnostics.add,
    );
    addTearDown(fixture.dispose);
    await fixture.activate();
    await fixture.initialize();
    tokenCalls = 0;
    storage.exchanges.clear();
    storage.rejectExchanges = true;

    expect(
      await fixture.client.createChannel(const ChatCreateChannelInput(
        name: 'Contended',
        visibility: ConversationVisibility.private,
      )),
      isA<ChatCommandValidationFailure<ChannelConversationCreationResult>>(),
    );
    expect(storage.exchanges,
        hasLength(maxApplicationChatStorageMutationAttempts));
    expect(keyCalls, 1);
    expect(requestCalls, 1);
    expect(fixture.client.queuedConversationCreations, isEmpty);
    expect(await _readCreations(storage.backing, _identity), isNull);
    expect(fixture.transport.posts, isEmpty);
    expect(tokenCalls, 0);
    expect(diagnostics.single.code,
        ChatClientDiagnosticCode.conversationCreationIntentsWriteFailed);
  });

  test('persists before queue visibility, token access, or transport',
      () async {
    final backing = InMemoryApplicationChatStorage();
    final storage = _BlockingCreationStorage(backing);
    final transport = _CreationTransport();
    var tokenCalls = 0;
    final fixture = _Fixture(
      storage: storage,
      transport: transport,
      tokenProvider: () async {
        tokenCalls += 1;
        return 'token';
      },
      idempotencyKeys: Queue.of(['persisted-key']),
      requestIds: Queue.of(['persisted-request']),
    );
    await fixture.activate();

    final pending = fixture.client.createChannel(const ChatCreateChannelInput(
      name: 'Durable channel',
      visibility: ConversationVisibility.private,
    ));
    await storage.replaceStarted.future;
    expect(fixture.client.queuedConversationCreations, isEmpty);
    expect(tokenCalls, 0);
    expect(transport.posts, isEmpty);

    storage.releaseReplace.complete();
    await _eventually(
        () => fixture.client.queuedConversationCreations.length == 1);
    expect(transport.posts, isEmpty, reason: 'metadata is not ready');
    await fixture.initialize();
    expect(await pending,
        isA<ChatCommandSuccess<ChannelConversationCreationResult>>());
    expect(_body(transport.posts.single)['idempotencyKey'], 'persisted-key');
    expect(await _readCreations(backing, _identity), isNull);
    await fixture.dispose();
  });

  test(
      'restart replays exact channel, direct, and group-direct requests in FIFO order',
      () async {
    final storage = InMemoryApplicationChatStorage();
    final requests = <ConversationCreationInput>[
      ConversationCreationInput.fromJson(
          channelConversationCreationInputFixture),
      ConversationCreationInput.fromJson(
          directConversationCreationInputFixture),
      ConversationCreationInput.fromJson(
          groupDirectConversationCreationInputFixture),
    ];
    await _seedCreations(storage, requests);
    final firstResponse = Completer<HandrailChatHttpResponse>();
    final transport = _CreationTransport(post: (request) {
      if (_body(request)['idempotencyKey'] == requests.first.idempotencyKey) {
        return firstResponse.future;
      }
      return Future.value(_success(_body(request)));
    });
    final fixture = _Fixture(
      storage: storage,
      transport: transport,
      idempotencyKeys: Queue.of(['must-not-be-used']),
      requestIds: Queue.of(['must-not-be-used']),
    );
    await fixture.activate();
    expect(
      fixture.client.queuedConversationCreations
          .map((intent) => intent.request.toJson()),
      requests.map((request) => _canonical(request.toJson())),
    );
    await fixture.initialize();
    await _eventually(() => transport.posts.length == 1);
    expect(_body(transport.posts.single), requests.first.toJson());
    firstResponse.complete(_success(_body(transport.posts.single)));
    await _eventually(() => transport.posts.length == 3);
    expect(
      transport.posts.map(_body).map((body) => body['idempotencyKey']),
      requests.map((request) => request.idempotencyKey),
    );
    for (final request in requests) {
      final sent = transport.posts.singleWhere(
        (wire) => _body(wire)['idempotencyKey'] == request.idempotencyKey,
      );
      expect(_body(sent), _canonical(request.toJson()));
      expect(sent.headers['Idempotency-Key'], request.idempotencyKey);
    }
    await _eventually(() => fixture.client.queuedConversationCreations.isEmpty);
    await fixture.dispose();
  });

  test('event-first and already-created canonical state settle without POST',
      () async {
    final eventStorage = InMemoryApplicationChatStorage();
    final eventRequest = ConversationCreationInput.fromJson(
      channelConversationCreationInputFixture,
    );
    await _seedCreations(eventStorage, [eventRequest]);
    final eventFixture = _Fixture(
      storage: eventStorage,
      transport: _CreationTransport(),
    );
    await eventFixture.activate();
    eventFixture.client.reduceDurableEvent(_creationEvent(eventRequest));
    await _eventually(
        () => eventFixture.client.queuedConversationCreations.isEmpty);
    await eventFixture.initialize();
    expect(eventFixture.transport.posts, isEmpty);
    expect(await _readCreations(eventStorage, _identity), isNull);
    await eventFixture.dispose();

    final existingStorage = InMemoryApplicationChatStorage();
    final direct = ConversationCreationInput.fromJson(
      directConversationCreationInputFixture,
    );
    await _seedCreations(existingStorage, [direct]);
    final existingStore = NormalizedSnapshotStore()
      ..hydrateConversationDetail(
        ConversationDetailSnapshot.fromJson(
          conversationCreationResultFixture(
            'direct',
            'existing_equivalent',
          )['conversation'],
        ),
      );
    final existingFixture = _Fixture(
      storage: existingStorage,
      transport: _CreationTransport(),
      store: existingStore,
    );
    await existingFixture.activate();
    await existingFixture.initialize();
    await _eventually(
      () => existingFixture.client.queuedConversationCreations.isEmpty,
    );
    expect(existingFixture.transport.posts, isEmpty);
    expect(await _readCreations(existingStorage, _identity), isNull);
    await existingFixture.dispose();
  });

  test(
      'identical retry reuses correlations and transient work retries with bounded wait',
      () async {
    final storage = InMemoryApplicationChatStorage();
    var idempotencyCalls = 0;
    var requestIdCalls = 0;
    final waits = <Duration>[];
    final waitGate = Completer<void>();
    final transport = _CreationTransport(
      post: (_) async => throw StateError('offline'),
    );
    final fixture = _Fixture(
      storage: storage,
      transport: transport,
      idempotencyGenerator: () => 'key-${++idempotencyCalls}',
      requestIdGenerator: () => 'request-${++requestIdCalls}',
      retryBackoff: (_) => const Duration(seconds: 60),
      retryWait: (delay, signal) {
        waits.add(delay);
        return waitGate.future;
      },
    );
    await fixture.activate();
    await fixture.initialize();
    const input = ChatCreateChannelInput(
      name: 'Retry me',
      visibility: ConversationVisibility.public,
    );
    expect(
      await fixture.client.createChannel(input),
      isA<ChatCommandTransportFailure<ChannelConversationCreationResult>>(),
    );
    await _eventually(() => waits.isNotEmpty);
    final retained = fixture.client.queuedConversationCreations.single.request;
    final duplicate = fixture.client.createChannel(input);
    await _eventually(
        () => fixture.client.queuedConversationCreations.length == 1);
    expect(idempotencyCalls, 1);
    expect(requestIdCalls, 1);
    expect(retained.idempotencyKey, 'key-1');
    expect(retained.clientRequestId, 'request-1');
    expect(waits.single, const Duration(seconds: 60));
    await fixture.client.dispose();
    expect(await duplicate,
        isA<ChatCommandClosed<ChannelConversationCreationResult>>());
    expect((await _readCreations(storage, _identity))?.intents, hasLength(1));
    await fixture.finishDispose();
  });

  test(
      'terminal failures remove intents while ambiguous malformed responses remain',
      () async {
    final terminalStorage = InMemoryApplicationChatStorage();
    final terminal = _Fixture(
      storage: terminalStorage,
      transport: _CreationTransport(
        post: (_) async => _error(403, 'PERMISSION_DENIED'),
      ),
      idempotencyKeys: Queue.of(['terminal-key']),
      requestIds: Queue.of(['terminal-request']),
    );
    await terminal.activate();
    await terminal.initialize();
    expect(
      await terminal.client.createDirect(
        ChatCreateDirectInput(intendedMemberUserIds: const [UserId('user-b')]),
      ),
      isA<ChatCommandAuthenticationFailure<DirectConversationCreationResult>>(),
    );
    expect(await _readCreations(terminalStorage, _identity), isNull);
    await terminal.dispose();

    final malformedStorage = InMemoryApplicationChatStorage();
    final malformed = _Fixture(
      storage: malformedStorage,
      transport: _CreationTransport(
        post: (_) async => const HandrailChatHttpResponse(
          statusCode: 201,
          body: '{}',
        ),
      ),
      retryWait: _NeverRetryWait().call,
      idempotencyKeys: Queue.of(['malformed-key']),
      requestIds: Queue.of(['malformed-request']),
    );
    await malformed.activate();
    await malformed.initialize();
    expect(
      await malformed.client.createChannel(const ChatCreateChannelInput(
        name: 'Malformed response',
        visibility: ConversationVisibility.public,
      )),
      isA<ChatCommandMalformedResponse<ChannelConversationCreationResult>>(),
    );
    expect((await _readCreations(malformedStorage, _identity))?.intents,
        hasLength(1));
    await malformed.dispose();
  });

  test('cancellation and disposal after dispatch retain ambiguous intents',
      () async {
    final cancellationStorage = InMemoryApplicationChatStorage();
    final cancellationStarted = Completer<void>();
    final cancellationTransport = _CreationTransport(post: (_) {
      if (!cancellationStarted.isCompleted) cancellationStarted.complete();
      return Completer<HandrailChatHttpResponse>().future;
    });
    final cancellation = _Fixture(
      storage: cancellationStorage,
      transport: cancellationTransport,
      idempotencyKeys: Queue.of(['cancel-key']),
      requestIds: Queue.of(['cancel-request']),
    );
    await cancellation.activate();
    await cancellation.initialize();
    final controller = ChatCommandCancellationController();
    final cancelled = cancellation.client.createChannel(
      const ChatCreateChannelInput(
        name: 'Cancellation ambiguity',
        visibility: ConversationVisibility.private,
      ),
      cancellationSignal: controller.signal,
    );
    await cancellationStarted.future;
    controller.cancel();
    expect(
      await cancelled,
      isA<ChatCommandAborted<ChannelConversationCreationResult>>(),
    );
    expect(
      (await _readCreations(cancellationStorage, _identity))?.intents,
      hasLength(1),
    );
    await cancellation.dispose();

    final disposalStorage = InMemoryApplicationChatStorage();
    final disposalStarted = Completer<void>();
    final disposal = _Fixture(
      storage: disposalStorage,
      transport: _CreationTransport(post: (_) {
        if (!disposalStarted.isCompleted) disposalStarted.complete();
        return Completer<HandrailChatHttpResponse>().future;
      }),
      idempotencyKeys: Queue.of(['dispose-key']),
      requestIds: Queue.of(['dispose-request']),
    );
    await disposal.activate();
    await disposal.initialize();
    final pending = disposal.client.createDirect(
      ChatCreateDirectInput(
        intendedMemberUserIds: const [UserId('user-b')],
      ),
    );
    await disposalStarted.future;
    await disposal.client.dispose();
    expect(
      await pending,
      isA<ChatCommandClosed<DirectConversationCreationResult>>(),
    );
    expect(
      (await _readCreations(disposalStorage, _identity))?.intents,
      hasLength(1),
    );
    await disposal.finishDispose();
  });

  test('offline, background, and realtime identity readiness gate replay',
      () async {
    final storage = InMemoryApplicationChatStorage();
    await _seedCreations(storage, [
      ConversationCreationInput.fromJson(
          directConversationCreationInputFixture),
    ]);
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
    final fixture = _Fixture(
      storage: storage,
      transport: _CreationTransport(),
      realtimeSession: session,
      network: network,
    );
    await fixture.activate();
    await fixture.initialize();
    expect(fixture.transport.posts, isEmpty, reason: 'offline');
    fixture.client.setApplicationForeground(false);
    await session.start();
    network.setOnline(true);
    await _eventually(() => socketFactory.uris.length == 1);
    socket.emitJson(_acceptedFrame());
    await _eventually(() => session.state is ChatRealtimeConnectedState);
    expect(fixture.transport.posts, isEmpty, reason: 'backgrounded');
    fixture.client.setApplicationForeground(true);
    await _eventually(() => fixture.transport.posts.length == 1);
    await fixture.dispose();
  });

  test(
      'corrupt and wrong-identity records quarantine; old identity completion is isolated',
      () async {
    final corrupt = InMemoryApplicationChatStorage();
    final valid = ApplicationChatQueuedConversationCreationIntentsRecord(
      identity: _identity,
      intents: [
        ApplicationChatQueuedConversationCreationIntent(
          request: ConversationCreationInput.fromJson(
            channelConversationCreationInputFixture,
          ),
          enqueueOrder: 1,
          enqueuedAt: const IsoTimestamp('2032-02-01T00:00:00.000Z'),
        ),
      ],
    ).toJson();
    final payload = valid['payload']! as Map<String, Object?>;
    final intents = payload['intents']! as List<Object?>;
    (intents.single as Map<String, Object?>)['accessToken'] = 'secret';
    corrupt.putRawRecordForTesting(
      _identity,
      ApplicationChatStorageRecordKind.queuedConversationCreationIntents,
      valid,
    );
    final diagnostics = <ChatClientDiagnostic>[];
    final corruptFixture = _Fixture(
      storage: corrupt,
      transport: _CreationTransport(),
      onStorageDiagnostic: diagnostics.add,
    );
    await corruptFixture.activate();
    expect(corruptFixture.client.queuedConversationCreations, isEmpty);
    expect(
      diagnostics.single.code,
      ChatClientDiagnosticCode.conversationCreationIntentsRejected,
    );
    expect(diagnostics.single.toString(), isNot(contains('secret')));
    expect(await _readCreations(corrupt, _identity), isNull);
    await corruptFixture.dispose();

    final wrong = _WrongIdentityCreationStorage(
      ApplicationChatQueuedConversationCreationIntentsRecord(
        identity: _otherIdentity,
        intents: [
          ApplicationChatQueuedConversationCreationIntent(
            request: ConversationCreationInput.fromJson(
              directConversationCreationInputFixture,
            ),
            enqueueOrder: 1,
            enqueuedAt: const IsoTimestamp('2032-02-01T00:00:00.000Z'),
          ),
        ],
      ),
    );
    final wrongDiagnostics = <ChatClientDiagnostic>[];
    final wrongFixture = _Fixture(
      storage: wrong,
      transport: _CreationTransport(),
      onStorageDiagnostic: wrongDiagnostics.add,
    );
    await wrongFixture.activate();
    expect(wrongFixture.client.queuedConversationCreations, isEmpty);
    expect(wrong.quarantined, isTrue);
    expect(
      wrongDiagnostics.single.code,
      ChatClientDiagnosticCode.conversationCreationIntentsRejected,
    );
    await wrongFixture.dispose();

    final backing = InMemoryApplicationChatStorage();
    final blocking = _BlockingCreationStorage(backing);
    final isolated = _Fixture(
      storage: blocking,
      transport: _CreationTransport(),
      idempotencyKeys: Queue.of(['old-key']),
      requestIds: Queue.of(['old-request']),
    );
    await isolated.activate();
    final pending = isolated.client.createChannel(const ChatCreateChannelInput(
      name: 'Old identity',
      visibility: ConversationVisibility.private,
    ));
    await blocking.replaceStarted.future;
    final replacement = isolated.client.activateStorageIdentity(_otherIdentity);
    blocking.releaseReplace.complete();
    expect(await pending,
        isA<ChatCommandClosed<ChannelConversationCreationResult>>());
    await replacement;
    expect(isolated.client.queuedConversationCreations, isEmpty);
    expect((await _readCreations(backing, _identity))?.intents, hasLength(1));
    expect(await _readCreations(backing, _otherIdentity), isNull);
    await isolated.dispose();
  });
}

final class _Fixture {
  _Fixture({
    required ApplicationChatStorage storage,
    required this.transport,
    NormalizedSnapshotStore? store,
    HandrailChatAccessTokenProvider? tokenProvider,
    Queue<String>? idempotencyKeys,
    Queue<String>? requestIds,
    String Function()? idempotencyGenerator,
    String Function()? requestIdGenerator,
    ChatConversationCreationClock? clock,
    ChatConversationCreationRetryBackoff? retryBackoff,
    ChatConversationCreationRetryWait? retryWait,
    ChatClientDiagnosticCallback? onStorageDiagnostic,
    this.realtimeSession,
    this.network,
  }) : store = store ?? NormalizedSnapshotStore() {
    final keys = idempotencyKeys ?? Queue.of(['generated-key']);
    final correlations = requestIds ?? Queue.of(['generated-request']);
    client = HandrailChatClient(
      apiBaseUri: Uri.parse('https://chat.example.test/api/chat'),
      tokenProvider: tokenProvider ?? () async => 'access-token',
      transport: transport,
      localStorage: storage,
      storageIdentity: _identity,
      normalizedSnapshotStore: this.store,
      realtimeSession: realtimeSession,
      generateIdempotencyKey: idempotencyGenerator ?? () => keys.removeFirst(),
      generateConversationClientRequestId:
          requestIdGenerator ?? () => correlations.removeFirst(),
      commandRetryOptions: const ChatCommandRetryOptions(
        maxAttempts: 1,
        maxAuthenticationRefreshes: 0,
      ),
      conversationCreationClock: clock ?? () => DateTime.utc(2032, 2, 1),
      conversationCreationRetryBackoff: retryBackoff,
      conversationCreationRetryWait: retryWait,
      onStorageDiagnostic: onStorageDiagnostic,
    );
  }

  final NormalizedSnapshotStore store;
  final _CreationTransport transport;
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

final class _CreationTransport implements HandrailChatHttpTransport {
  _CreationTransport({this.post});

  final Future<HandrailChatHttpResponse> Function(HandrailChatHttpRequest)?
      post;
  final List<HandrailChatHttpRequest> requests = [];

  Iterable<HandrailChatHttpRequest> get posts =>
      requests.where((request) => request.method == 'POST');

  @override
  Future<HandrailChatHttpResponse> send(HandrailChatHttpRequest request) {
    requests.add(request);
    if (request.method == 'GET' && request.uri.path.endsWith('/_meta')) {
      return Future.value(HandrailChatHttpResponse(
        statusCode: 200,
        body: jsonEncode(_metadata),
      ));
    }
    return post?.call(request) ?? Future.value(_success(_body(request)));
  }
}

final class _BlockingCreationStorage implements ApplicationChatStorage {
  _BlockingCreationStorage(this.backing);

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
        ApplicationChatStorageRecordKind.queuedConversationCreationIntents) {
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

final class _WrongIdentityCreationStorage implements ApplicationChatStorage {
  _WrongIdentityCreationStorage(this.record);

  final ApplicationChatQueuedConversationCreationIntentsRecord record;
  final InMemoryApplicationChatStorage backing =
      InMemoryApplicationChatStorage();
  bool quarantined = false;

  @override
  Future<ApplicationChatStorageRecord?> read(
    ApplicationChatStorageIdentity identity,
    ApplicationChatStorageRecordKind kind,
  ) {
    if (kind ==
            ApplicationChatStorageRecordKind
                .queuedConversationCreationIntents &&
        !quarantined) {
      return Future.value(record);
    }
    return backing.read(identity, kind);
  }

  @override
  Future<void> replace(ApplicationChatStorageRecord record) =>
      backing.replace(record);

  @override
  Future<void> remove(
    ApplicationChatStorageIdentity identity,
    ApplicationChatStorageRecordKind kind,
  ) {
    if (kind ==
        ApplicationChatStorageRecordKind.queuedConversationCreationIntents) {
      quarantined = true;
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

final class _ExchangeGate {
  final started = Completer<void>();
  final release = Completer<void>();

  Future<void> pause() {
    if (!started.isCompleted) started.complete();
    return release.future;
  }
}

ApplicationChatQueuedConversationCreationIntentsRecord _decodeCreations(
        String encoded) =>
    ApplicationChatStorageRecord.decode(encoded)
        as ApplicationChatQueuedConversationCreationIntentsRecord;

final class _AtomicCreationStorage implements AtomicApplicationChatStorage {
  final backing = InMemoryApplicationChatStorage();
  final exchanges = <({String? expected, String? replacement})>[];
  Future<void> Function(String? expected, String? replacement)? beforeExchange;
  bool rejectExchanges = false;

  @override
  Future<bool> compareExchange(
    ApplicationChatStorageIdentity identity,
    ApplicationChatStorageRecordKind kind,
    String? expectedEncodedRecord,
    String? replacementEncodedRecord,
  ) async {
    if (kind ==
        ApplicationChatStorageRecordKind.queuedConversationCreationIntents) {
      exchanges.add((
        expected: expectedEncodedRecord,
        replacement: replacementEncodedRecord
      ));
      await beforeExchange?.call(
          expectedEncodedRecord, replacementEncodedRecord);
      if (rejectExchanges) return false;
    }
    return backing.compareExchange(
        identity, kind, expectedEncodedRecord, replacementEncodedRecord);
  }

  @override
  Future<String?> readEncoded(ApplicationChatStorageIdentity identity,
          ApplicationChatStorageRecordKind kind) =>
      backing.readEncoded(identity, kind);

  @override
  Future<ApplicationChatStorageRecord?> read(
          ApplicationChatStorageIdentity identity,
          ApplicationChatStorageRecordKind kind) =>
      backing.read(identity, kind);

  @override
  Future<void> replace(ApplicationChatStorageRecord record) =>
      backing.replace(record);

  @override
  Future<void> remove(ApplicationChatStorageIdentity identity,
          ApplicationChatStorageRecordKind kind) =>
      backing.remove(identity, kind);

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
          previousIdentity: previousIdentity, nextIdentity: nextIdentity);
}

final class _NeverRetryWait {
  Future<void> call(
    Duration _,
    ChatCommandCancellationSignal cancellationSignal,
  ) {
    final completer = Completer<void>();
    cancellationSignal.onCancelled.listen((_) {
      if (!completer.isCompleted) completer.complete();
    });
    return completer.future;
  }
}

Future<void> _seedCreations(
  ApplicationChatStorage storage,
  List<ConversationCreationInput> requests,
) =>
    storage.replace(ApplicationChatQueuedConversationCreationIntentsRecord(
      identity: _identity,
      intents: [
        for (var index = 0; index < requests.length; index++)
          ApplicationChatQueuedConversationCreationIntent(
            request: requests[index],
            enqueueOrder: index + 1,
            enqueuedAt: IsoTimestamp(
              DateTime.utc(2032, 2, 1, 0, 0, index).toIso8601String(),
            ),
          ),
      ],
    ));

Future<ApplicationChatQueuedConversationCreationIntentsRecord?> _readCreations(
  ApplicationChatStorage storage,
  ApplicationChatStorageIdentity identity,
) async =>
    await storage.read(
      identity,
      ApplicationChatStorageRecordKind.queuedConversationCreationIntents,
    ) as ApplicationChatQueuedConversationCreationIntentsRecord?;

Map<String, Object?> _body(HandrailChatHttpRequest request) =>
    (jsonDecode(request.body!) as Map).cast<String, Object?>();

Map<String, Object?> _canonical(Map<String, Object?> input) {
  final copy = jsonDecode(jsonEncode(input)) as Map<String, Object?>;
  final members = copy['intendedMemberUserIds'];
  if (members is List<Object?>) members.sort((a, b) => '$a'.compareTo('$b'));
  return copy;
}

HandrailChatHttpResponse _success(Map<String, Object?> input) {
  final result = conversationCreationResultFixture(
    input['type']! as String,
    'created',
    clientRequestId: input['clientRequestId']! as String,
  );
  final detail = result['conversation']! as Map<String, Object?>;
  final conversation = detail['conversation']! as Map<String, Object?>;
  final conversationId = 'conversation-${input['idempotencyKey']}';
  conversation['id'] = conversationId;
  conversation['visibility'] = input['visibility'];
  if (input['name'] case final String name) conversation['name'] = name;
  if (input['entity'] case final Map<String, Object?> entity) {
    conversation['entity'] = Map<String, Object?>.of(entity);
  }
  for (final field in [
    'currentMember',
    'currentReadState',
    'currentPreference',
  ]) {
    (conversation[field]! as Map<String, Object?>)['conversationId'] =
        conversationId;
  }
  return HandrailChatHttpResponse(statusCode: 201, body: jsonEncode(result));
}

HandrailChatHttpResponse _error(int status, String code) =>
    HandrailChatHttpResponse(
      statusCode: status,
      body: jsonEncode({
        'error': {'code': code, 'message': 'request failed'},
      }),
    );

KnownDurableEvent _creationEvent(ConversationCreationInput request) {
  final result = conversationCreationResultFixture(
    request.type.toJson(),
    'created',
    clientRequestId: request.clientRequestId,
  );
  final detail = result['conversation']! as Map<String, Object?>;
  final summary = detail['conversation']! as Map<String, Object?>;
  final canonical = <String, Object?>{
    for (final field in [
      'id',
      'tenantId',
      'type',
      'name',
      'visibility',
      'entity',
      'createdAt',
      'updatedAt',
    ])
      if (summary.containsKey(field)) field: summary[field],
  };
  return KnownDurableEvent.fromJson(
    {
      'eventId': 'creation-event-1',
      'protocolVersion': handrailChatProtocolVersion,
      'tenantId': _identity.tenantId.toJson(),
      'streamId': canonical['id'],
      'type': 'conversation.created',
      'occurredAt': canonical['updatedAt'],
      'payload': {
        'conversation': canonical,
        'clientRequestId': request.clientRequestId,
      },
    },
    trustedIdentity: DurableEventTrustedIdentity(
      tenantId: _identity.tenantId,
      userId: _identity.userId,
    ),
  );
}

Future<void> _eventually(FutureOr<bool> Function() predicate) async {
  for (var attempt = 0; attempt < 500; attempt += 1) {
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
  'enabledFeatures': <String, Object?>{
    'realtime': true,
    'conversation_creation': true,
  },
  'supportedProtocolRange': <String, Object?>{
    'minimumVersion': handrailChatProtocolVersion,
    'maximumVersion': handrailChatProtocolVersion,
  },
};
