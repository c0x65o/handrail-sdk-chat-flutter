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
const _sourceMessageId = MessageId('source-message');
const _sourceConversationId = ConversationId('source-conversation');
const _destinationConversationId = ConversationId('destination-conversation');
const _destinationMessageId = MessageId('forwarded-message');
const _input = ChatForwardMessageInput(
  sourceMessageId: _sourceMessageId,
  destinationConversationId: _destinationConversationId,
);

void main() {
  test(
      'atomic enqueue preserves concurrent intents and retries stable metadata',
      () async {
    final backing = InMemoryApplicationChatStorage();
    final storage = _InterleavingMutationStorage(backing);
    var correlations = 0;
    var keys = 0;
    final fixture = _Fixture(
      storage: storage,
      store: _seedStore(),
      transport: _ScriptedTransport()
        ..enqueuePost((_) async => throw StateError('offline')),
      generateCorrelationId: () => 'candidate-${++correlations}',
      generateIdempotencyKey: () => 'candidate-${++keys}',
      retryWait: _NeverRetryWait().call,
    );
    addTearDown(fixture.dispose);
    await fixture.activate();
    storage.proposals.clear();
    final concurrent = [..._unrelatedIntents(), _otherForward()];
    storage.beforeWrite = () async {
      expect(fixture.transport.posts, isEmpty);
      await backing.replace(_mutationRecord(concurrent));
    };
    expect(await fixture.client.forwardMessage(_input),
        isA<ChatCommandTransportFailure<ForwardMessageResult>>());
    final stored = (await _readMutations(backing, _identity))!;
    expect(stored.intents.take(4).map((intent) => intent.toJson()),
        concurrent.map((intent) => intent.toJson()));
    expect(
        stored.intents.map((intent) => intent.enqueueOrder), [5, 7, 9, 11, 12]);
    expect(correlations, 1);
    expect(keys, 1);
    expect(storage.failedExchanges, 1);
    final attempts =
        storage.proposals.map((record) => record!.intents.last).toList();
    expect(attempts, hasLength(2));
    expect(attempts.first.enqueueOrder, 1);
    expect(attempts.last.enqueueOrder, 12);
    expect((attempts.first.request as ForwardMessageRequest).toJson(),
        (attempts.last.request as ForwardMessageRequest).toJson());
    expect(attempts.first.enqueuedAt, attempts.last.enqueuedAt);
    expect(_requestFrom(fixture.transport.posts.single),
        (attempts.last.request as ForwardMessageRequest).toJson());
  });

  test('independent clients deduplicate against the committed winner',
      () async {
    final backing = InMemoryApplicationChatStorage();
    final storage = _InterleavingMutationStorage(backing);
    final first = _Fixture(
      storage: storage,
      store: _seedStore(),
      transport: _ScriptedTransport()
        ..enqueuePost((_) async => throw StateError('offline')),
      generateCorrelationId: () => 'losing-correlation',
      generateIdempotencyKey: () => 'losing-key',
      retryWait: _NeverRetryWait().call,
    );
    final second = _Fixture(
      storage: _InterleavingMutationStorage(backing),
      store: _seedStore(),
      transport: _ScriptedTransport()
        ..enqueuePost((_) async => throw StateError('offline')),
      generateCorrelationId: () => 'winning-correlation',
      generateIdempotencyKey: () => 'winning-key',
      retryWait: _NeverRetryWait().call,
    );
    addTearDown(first.dispose);
    addTearDown(second.dispose);
    await first.activate();
    await second.activate();
    storage.beforeWrite = () async {
      expect(await second.client.forwardMessage(_input),
          isA<ChatCommandTransportFailure<ForwardMessageResult>>());
    };
    expect(await first.client.forwardMessage(_input),
        isA<ChatCommandTransportFailure<ForwardMessageResult>>());
    final winner = (await _readMutations(backing, _identity))!.intents.single;
    expect(winner.idempotencyKey, 'winning-key');
    expect(_requestFrom(first.transport.posts.single),
        (winner.request as ForwardMessageRequest).toJson());
    expect(_requestFrom(second.transport.posts.single),
        (winner.request as ForwardMessageRequest).toJson());
    expect(storage.failedExchanges, 1);
  });

  for (final canonical in [false, true]) {
    test(
        'atomic ${canonical ? 'canonical' : 'HTTP'} settlement preserves concurrent intents',
        () async {
      final backing = InMemoryApplicationChatStorage();
      final storage = _InterleavingMutationStorage(backing);
      final response = Completer<HandrailChatHttpResponse>();
      final fixture = _Fixture(
          storage: storage,
          store: _seedStore(),
          transport: _ScriptedTransport()..enqueuePost((_) => response.future));
      addTearDown(fixture.dispose);
      await fixture.activate();
      final pending = fixture.client.forwardMessage(_input);
      await _eventually(() => fixture.transport.posts.length == 1);
      final original = (await _readMutations(backing, _identity))!;
      storage.beforeWrite = () => backing.replace(
          _mutationRecord([...original.intents, ..._unrelatedIntents()]));
      final request = _requestFrom(fixture.transport.posts.single);
      if (canonical) {
        fixture.client.reduceDurableEvent(_createdEvent(request));
      } else {
        response.complete(_successResponse(request));
      }
      expect(await pending, isA<ChatCommandSuccess<ForwardMessageResult>>());
      expect((await _readMutations(backing, _identity))!.encode(),
          _mutationRecord(_unrelatedIntents()).encode());
      expect(storage.failedExchanges, 1);
      if (canonical) response.complete(_successResponse(request));
    });
  }

  for (final changed in ['request', 'key', 'order', 'time']) {
    test(
        'stale canonical settlement cannot claim replacement with changed $changed',
        () async {
      final backing = InMemoryApplicationChatStorage();
      final storage = _InterleavingMutationStorage(backing);
      final response = Completer<HandrailChatHttpResponse>();
      final fixture = _Fixture(
          storage: storage,
          store: _seedStore(),
          transport: _ScriptedTransport()..enqueuePost((_) => response.future));
      addTearDown(fixture.dispose);
      await fixture.activate();
      final pending = fixture.client.forwardMessage(_input);
      var completed = false;
      unawaited(pending.then((_) {
        completed = true;
      }));
      await _eventually(() => fixture.transport.posts.length == 1);
      final original =
          (await _readMutations(backing, _identity))!.intents.single;
      final replacement = _mutationRecord([
        ApplicationChatQueuedMessageMutationIntent(
          request: changed == 'request' || changed == 'key'
              ? ForwardMessageRequest.fromJson({
                  ...(original.request as ForwardMessageRequest).toJson(),
                  if (changed == 'request')
                    'clientCorrelationId': 'replacement-correlation',
                  if (changed == 'key') 'idempotencyKey': 'replacement-key',
                })
              : original.request,
          enqueueOrder: changed == 'order' ? 3 : original.enqueueOrder,
          enqueuedAt: changed == 'time'
              ? const IsoTimestamp('2032-05-01T00:00:03.000Z')
              : original.enqueuedAt,
        ),
        ..._unrelatedIntents(),
      ]);
      storage.beforeWrite = () => backing.replace(replacement);
      fixture.client.reduceDurableEvent(
          _createdEvent(_requestFrom(fixture.transport.posts.single)));
      await _eventually(() => storage.failedExchanges == 1);
      await Future<void>.delayed(Duration.zero);
      expect(completed, isFalse);
      expect((await _readMutations(backing, _identity))!.encode(),
          replacement.encode());
      response.complete(_errorResponse(403, 'FORBIDDEN'));
      expect(await pending,
          isA<ChatCommandAuthenticationFailure<ForwardMessageResult>>());
      expect((await _readMutations(backing, _identity))!.encode(),
          replacement.encode());
    });
  }

  test('atomic cancellation settlement preserves concurrent intents', () async {
    final backing = InMemoryApplicationChatStorage();
    final storage = _InterleavingMutationStorage(backing);
    final cancellation = ChatCommandCancellationController();
    final fixture = _Fixture(
        storage: storage, store: _seedStore(), transport: _ScriptedTransport());
    addTearDown(fixture.dispose);
    await fixture.activate();
    storage.beforeWrite = () async {
      cancellation.cancel();
      storage.beforeWrite = () async {
        final original = (await _readMutations(backing, _identity))!;
        await backing.replace(_mutationRecord([
          ...original.intents,
          ..._unrelatedIntents(),
        ]));
      };
    };
    expect(
        await fixture.client
            .forwardMessage(_input, cancellationSignal: cancellation.signal),
        isA<ChatCommandAborted<ForwardMessageResult>>());
    expect((await _readMutations(backing, _identity))!.encode(),
        _mutationRecord(_unrelatedIntents()).encode());
    expect(fixture.transport.posts, isEmpty);
    expect(storage.failedExchanges, 1);
  });

  test(
      'bounded contention never publishes or dispatches an uncommitted forward',
      () async {
    final backing = InMemoryApplicationChatStorage();
    final storage = _InterleavingMutationStorage(backing);
    final diagnostics = <ChatClientDiagnostic>[];
    final fixture = _Fixture(
        storage: storage,
        store: _seedStore(),
        transport: _ScriptedTransport(),
        onStorageDiagnostic: diagnostics.add);
    addTearDown(fixture.dispose);
    await fixture.activate();
    storage.rejectWrites = true;
    expect(await fixture.client.forwardMessage(_input),
        isA<ChatCommandValidationFailure<ForwardMessageResult>>());
    expect(storage.failedExchanges, maxApplicationChatStorageMutationAttempts);
    expect(await _readMutations(backing, _identity), isNull);
    expect(fixture.transport.posts, isEmpty);
    expect(diagnostics.map((d) => d.code),
        contains(ChatClientDiagnosticCode.messageMutationIntentsWriteFailed));
    storage.rejectWrites = false;
    await fixture.initialize();
    fixture.store.reconcileMessage(_sourceMessage());
    await Future<void>.delayed(Duration.zero);
    expect(fixture.transport.posts, isEmpty);
  });

  test('forward quarantine cannot delete a concurrent valid replacement',
      () async {
    final backing = InMemoryApplicationChatStorage();
    final storage = _InterleavingMutationStorage(backing);
    final diagnostics = <ChatClientDiagnostic>[];
    final valid = _mutationRecord([..._unrelatedIntents(), _otherForward()]);
    backing
        .putRawRecordForTesting(_identity, _mutationKind, {'malformed': true});
    storage.beforeWrite = () => backing.replace(valid);
    final fixture = _Fixture(
        storage: storage,
        store: _seedStore(),
        transport: _ScriptedTransport(),
        onStorageDiagnostic: diagnostics.add);
    addTearDown(fixture.dispose);
    await fixture.activate();
    expect(
        (await _readMutations(backing, _identity))!.encode(), valid.encode());
    expect(diagnostics.map((d) => d.code),
        contains(ChatClientDiagnosticCode.messageMutationIntentsRejected));
    expect(storage.failedExchanges, 1);
  });

  test('persists before authentication and concurrent duplicates coalesce',
      () async {
    final backing = InMemoryApplicationChatStorage();
    await _seedSnapshot(backing, _seedStore());
    final storage = _BlockingMutationStorage(backing);
    final transport = _ScriptedTransport();
    final response = Completer<HandrailChatHttpResponse>();
    transport.enqueuePost((_) => response.future);
    var tokenCalls = 0;
    var correlationCalls = 0;
    var keyCalls = 0;
    final fixture = _Fixture(
      storage: storage,
      transport: transport,
      tokenProvider: () async {
        tokenCalls += 1;
        return 'credential-that-must-not-be-persisted';
      },
      generateCorrelationId: () => 'correlation-${++correlationCalls}',
      generateIdempotencyKey: () => 'forward-key-${++keyCalls}',
    );
    await fixture.activate();

    final first = fixture.client.forwardMessage(_input);
    await storage.replaceStarted.future;
    expect(tokenCalls, 0);
    expect(transport.posts, isEmpty);
    expect(correlationCalls, 1);
    expect(keyCalls, 1);

    final duplicate = fixture.client.forwardMessage(_input);
    storage.releaseReplace.complete();
    await _eventually(() => transport.posts.length == 1);
    expect(correlationCalls, 1);
    expect(keyCalls, 1);
    final request = _requestFrom(transport.posts.single);
    final raw = jsonEncode(backing.rawRecordForTesting(
      _identity,
      ApplicationChatStorageRecordKind.queuedMessageMutationIntents,
    ));
    expect(raw, isNot(contains('credential-that-must-not-be-persisted')));
    expect(raw, isNot(contains('Authorization')));
    expect(raw, isNot(contains('error')));

    response.complete(_successResponse(request));
    expect(await first, isA<ChatCommandSuccess<ForwardMessageResult>>());
    expect(await duplicate, isA<ChatCommandSuccess<ForwardMessageResult>>());
    expect(await _readMutations(backing, _identity), isNull);
    await fixture.dispose();
  });

  test('acknowledgement loss survives restart with the exact request',
      () async {
    final storage = InMemoryApplicationChatStorage();
    await _seedSnapshot(storage, _seedStore());
    final firstTransport = _ScriptedTransport()
      ..enqueuePost((_) async => throw StateError('acknowledgement lost'));
    final first = _Fixture(
      storage: storage,
      transport: firstTransport,
      retryWait: _NeverRetryWait().call,
    );
    await first.activate();
    expect(await first.client.forwardMessage(_input),
        isA<ChatCommandTransportFailure<ForwardMessageResult>>());
    final original = _requestFrom(firstTransport.posts.single);
    final retained = await _readMutations(storage, _identity);
    expect(
      (retained?.intents.single.request as ForwardMessageRequest).toJson(),
      original,
    );
    await first.dispose();

    final secondTransport = _ScriptedTransport();
    secondTransport.enqueuePost((request) async {
      final body = _requestFrom(request);
      return _successResponse(body, replayed: true);
    });
    final second = _Fixture(
      storage: storage,
      transport: secondTransport,
      generateCorrelationId: () => 'must-not-regenerate-correlation',
      generateIdempotencyKey: () => 'must-not-regenerate-key',
    );
    await second.initialize();
    await _eventually(() => secondTransport.posts.length == 1);
    expect(_requestFrom(secondTransport.posts.single), original);
    expect(secondTransport.posts.single.headers['Idempotency-Key'],
        original['idempotencyKey']);
    await _eventually(
        () async => await _readMutations(storage, _identity) == null);
    expect(second.store.state.canonicalMessages[_destinationMessageId],
        isA<ActiveMessage>());
    await second.dispose();
  });

  test('a later user retry reuses a retained request in the same process',
      () async {
    final storage = InMemoryApplicationChatStorage();
    await _seedSnapshot(storage, _seedStore());
    final transport = _ScriptedTransport()
      ..enqueuePost((_) async => throw StateError('acknowledgement lost'))
      ..enqueuePost((request) async =>
          _successResponse(_requestFrom(request), replayed: true));
    var correlations = 0;
    var keys = 0;
    final fixture = _Fixture(
      storage: storage,
      transport: transport,
      generateCorrelationId: () => 'correlation-${++correlations}',
      generateIdempotencyKey: () => 'key-${++keys}',
      retryWait: _NeverRetryWait().call,
    );
    await fixture.activate();
    expect(await fixture.client.forwardMessage(_input),
        isA<ChatCommandTransportFailure<ForwardMessageResult>>());
    final first = _requestFrom(transport.posts.first);
    expect(await fixture.client.forwardMessage(_input),
        isA<ChatCommandSuccess<ForwardMessageResult>>());
    expect(_requestFrom(transport.posts.last), first);
    expect(correlations, 1);
    expect(keys, 1);
    await fixture.dispose();
  });

  test('matching canonical message.created settles storage and active caller',
      () async {
    final storage = InMemoryApplicationChatStorage();
    await _seedSnapshot(storage, _seedStore());
    final transport = _ScriptedTransport();
    final pendingResponse = Completer<HandrailChatHttpResponse>();
    transport.enqueuePost((_) => pendingResponse.future);
    final fixture = _Fixture(storage: storage, transport: transport);
    await fixture.activate();

    final pending = fixture.client.forwardMessage(_input);
    await _eventually(() => transport.posts.length == 1);
    final request = _requestFrom(transport.posts.single);
    fixture.client.reduceDurableEvent(_createdEvent(request));

    expect(await pending, isA<ChatCommandSuccess<ForwardMessageResult>>());
    await _eventually(
        () async => await _readMutations(storage, _identity) == null);
    expect(fixture.store.state.canonicalMessages[_destinationMessageId],
        isA<ActiveMessage>());
    pendingResponse.complete(const HandrailChatHttpResponse(
      statusCode: 503,
      body: '',
    ));
    await fixture.dispose();
  });

  test('terminal outcomes remove while ambiguous outcomes remain', () async {
    final cases = <({
      String name,
      Future<HandrailChatHttpResponse> Function(HandrailChatHttpRequest) reply,
      bool retained,
    })>[
      (
        name: 'authorization',
        reply: (_) async => _errorResponse(403, 'FORBIDDEN'),
        retained: false,
      ),
      (
        name: 'conflict',
        reply: (_) async => _errorResponse(409, 'IDEMPOTENCY_CONFLICT'),
        retained: false,
      ),
      (
        name: 'rate limit',
        reply: (_) async => _errorResponse(429, 'RATE_LIMITED'),
        retained: true,
      ),
      (
        name: 'server',
        reply: (_) async => _errorResponse(503, 'UNAVAILABLE'),
        retained: true,
      ),
      (
        name: 'malformed',
        reply: (_) async => const HandrailChatHttpResponse(
              statusCode: 200,
              body: '{bad-json',
            ),
        retained: true,
      ),
      (
        name: 'transport',
        reply: (_) async => throw StateError('offline'),
        retained: true,
      ),
    ];

    for (final testCase in cases) {
      final storage = InMemoryApplicationChatStorage();
      await _seedSnapshot(storage, _seedStore());
      final transport = _ScriptedTransport()..enqueuePost(testCase.reply);
      final fixture = _Fixture(
        storage: storage,
        transport: transport,
        retryWait: _NeverRetryWait().call,
      );
      await fixture.activate();
      await fixture.client.forwardMessage(_input);
      expect(
        await _readMutations(storage, _identity),
        testCase.retained ? isNotNull : isNull,
        reason: testCase.name,
      );
      await fixture.dispose();
    }

    final validationStorage = InMemoryApplicationChatStorage();
    await _seedSnapshot(validationStorage, _seedStore());
    final validationFixture = _Fixture(
      storage: validationStorage,
      transport: _ScriptedTransport(),
      generateIdempotencyKey: () => 'invalid key with spaces',
    );
    await validationFixture.activate();
    expect(await validationFixture.client.forwardMessage(_input),
        isA<ChatCommandValidationFailure<ForwardMessageResult>>());
    expect(await _readMutations(validationStorage, _identity), isNull);
    await validationFixture.dispose();
  });

  test('cancellation before dispatch removes the safely undispatched intent',
      () async {
    final backing = InMemoryApplicationChatStorage();
    await _seedSnapshot(backing, _seedStore());
    final storage = _BlockingMutationStorage(backing);
    var tokenCalls = 0;
    final fixture = _Fixture(
      storage: storage,
      transport: _ScriptedTransport(),
      tokenProvider: () async {
        tokenCalls += 1;
        return 'token';
      },
    );
    await fixture.activate();
    final cancellation = ChatCommandCancellationController();
    final pending = fixture.client.forwardMessage(
      _input,
      cancellationSignal: cancellation.signal,
    );
    await storage.replaceStarted.future;
    cancellation.cancel();
    storage.releaseReplace.complete();
    expect(await pending, isA<ChatCommandAborted<ForwardMessageResult>>());
    expect(await _readMutations(backing, _identity), isNull);
    expect(tokenCalls, 0);
    expect(fixture.transport.posts, isEmpty);
    await fixture.dispose();
  });

  test('cancellation after dispatch and dispose ambiguity retain', () async {
    final storage = InMemoryApplicationChatStorage();
    await _seedSnapshot(storage, _seedStore());
    final transport = _ScriptedTransport();
    final firstResponse = Completer<HandrailChatHttpResponse>();
    transport.enqueuePost((_) => firstResponse.future);
    final fixture = _Fixture(
      storage: storage,
      transport: transport,
      retryWait: _NeverRetryWait().call,
    );
    await fixture.activate();
    final cancellation = ChatCommandCancellationController();
    final cancelled = fixture.client.forwardMessage(
      _input,
      cancellationSignal: cancellation.signal,
    );
    await _eventually(() => transport.posts.length == 1);
    cancellation.cancel();
    expect(await cancelled, isA<ChatCommandAborted<ForwardMessageResult>>());
    expect(await _readMutations(storage, _identity), isNotNull);
    firstResponse.complete(const HandrailChatHttpResponse(
      statusCode: 503,
      body: '',
    ));
    await fixture.dispose();

    final closeTransport = _ScriptedTransport();
    final closeResponse = Completer<HandrailChatHttpResponse>();
    closeTransport.enqueuePost((_) => closeResponse.future);
    final closeFixture = _Fixture(
      storage: storage,
      transport: closeTransport,
      retryWait: _NeverRetryWait().call,
    );
    await closeFixture.activate();
    final closing = closeFixture.client.forwardMessage(_input);
    await _eventually(() => closeTransport.posts.length == 1);
    final dispose = closeFixture.client.dispose();
    expect(await closing, isA<ChatCommandClosed<ForwardMessageResult>>());
    await dispose;
    expect(await _readMutations(storage, _identity), isNotNull);
    closeResponse.complete(const HandrailChatHttpResponse(
      statusCode: 503,
      body: '',
    ));
    await closeFixture.disposeDependencies();
  });

  test('replay waits for foreground and authoritative source/destination',
      () async {
    final storage = InMemoryApplicationChatStorage();
    final missing = _seedStore(
      includeSource: false,
      includeDestination: false,
    );
    await _seedSnapshot(storage, missing);
    await _seedForward(storage);
    final transport = _ScriptedTransport();
    transport.enqueuePost((request) async =>
        _successResponse(_requestFrom(request), replayed: true));
    final fixture = _Fixture(storage: storage, transport: transport);
    fixture.client.setApplicationForeground(false);
    await fixture.initialize();
    expect(transport.posts, isEmpty);

    fixture.client.setApplicationForeground(true);
    await Future<void>.delayed(Duration.zero);
    expect(transport.posts, isEmpty,
        reason: 'Canonical source and destination access are unavailable.');
    fixture.store.reconcileMessage(_sourceMessage());
    await Future<void>.delayed(Duration.zero);
    expect(transport.posts, isEmpty,
        reason: 'The canonical destination is still unavailable.');
    _installDestination(fixture.store);
    await _eventually(() => transport.posts.length == 1);
    await fixture.dispose();
  });

  test('offline realtime recovery waits for connected foreground ownership',
      () async {
    final storage = InMemoryApplicationChatStorage();
    await _seedForward(storage);
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
      ..enqueuePost((request) async =>
          _successResponse(_requestFrom(request), replayed: true));
    final fixture = _Fixture(
      storage: storage,
      store: _seedStore(),
      transport: transport,
      realtimeSession: session,
      network: network,
    );
    await fixture.activate();
    await fixture.initialize();
    expect(transport.posts, isEmpty);
    fixture.client.setApplicationForeground(false);
    await session.start();
    network.setOnline(true);
    await _eventually(() => socketFactory.uris.length == 1);
    socket.emitJson(_acceptedFrame());
    await _eventually(() => session.state is ChatRealtimeConnectedState);
    expect(transport.posts, isEmpty);
    fixture.client.setApplicationForeground(true);
    await _eventually(() => transport.posts.length == 1);
    await fixture.dispose();
  });

  test('unsupported source content is rejected before storage or auth',
      () async {
    for (final content in <MessageContent>[
      MessageContent(
        format: MessageContentFormat.plain,
        text: 'attachment',
        attachments: [
          MessageAttachmentReference.fromJson({
            'attachmentId': 'attachment-1',
          }),
        ],
      ),
      MessageContent(
        format: MessageContentFormat.plain,
        text: 'blocks',
        blocks: [
          MessageBlock.fromJson({
            'type': 'code',
            'data': {'language': 'text', 'text': 'unsupported'},
          }),
        ],
      ),
    ]) {
      final storage = InMemoryApplicationChatStorage();
      await _seedSnapshot(storage, _seedStore(sourceContent: content));
      var tokenCalls = 0;
      final fixture = _Fixture(
        storage: storage,
        transport: _ScriptedTransport(),
        tokenProvider: () async {
          tokenCalls += 1;
          return 'token';
        },
      );
      await fixture.activate();
      expect(await fixture.client.forwardMessage(_input),
          isA<ChatCommandValidationFailure<ForwardMessageResult>>());
      expect(await _readMutations(storage, _identity), isNull);
      expect(tokenCalls, 0);
      await fixture.dispose();
    }
  });

  test('identity switch prevents stale reconciliation and removal', () async {
    final storage = InMemoryApplicationChatStorage();
    await _seedSnapshot(storage, _seedStore());
    final transport = _ScriptedTransport();
    final response = Completer<HandrailChatHttpResponse>();
    transport.enqueuePost((_) => response.future);
    final fixture = _Fixture(storage: storage, transport: transport);
    await fixture.activate();
    final pending = fixture.client.forwardMessage(_input);
    await _eventually(() => transport.posts.length == 1);
    final request = _requestFrom(transport.posts.single);

    await fixture.client.activateStorageIdentity(_otherIdentity);
    expect(await pending, isA<ChatCommandClosed<ForwardMessageResult>>());
    response.complete(_successResponse(request));
    await Future<void>.delayed(Duration.zero);
    expect(
        fixture.store.state.canonicalMessages[_destinationMessageId], isNull);
    expect(await _readMutations(storage, _identity), isNotNull);
    await fixture.dispose();
  });

  test('identity switch and dispose guard delayed persistence boundaries',
      () async {
    final identityBacking = InMemoryApplicationChatStorage();
    await _seedSnapshot(identityBacking, _seedStore());
    final identityStorage = _BlockingMutationStorage(identityBacking);
    final identityFixture = _Fixture(
      storage: identityStorage,
      transport: _ScriptedTransport(),
    );
    await identityFixture.activate();
    final pending = identityFixture.client.forwardMessage(_input);
    await identityStorage.replaceStarted.future;
    final replacement =
        identityFixture.client.activateStorageIdentity(_otherIdentity);
    identityStorage.releaseReplace.complete();
    expect(await pending, isA<ChatCommandClosed<ForwardMessageResult>>());
    await replacement;
    expect(identityFixture.transport.posts, isEmpty);
    expect(await _readMutations(identityBacking, _identity), isNotNull);
    await identityFixture.dispose();

    final disposeBacking = InMemoryApplicationChatStorage();
    await _seedSnapshot(disposeBacking, _seedStore());
    final disposeStorage = _BlockingMutationStorage(disposeBacking);
    final disposeFixture = _Fixture(
      storage: disposeStorage,
      transport: _ScriptedTransport(),
    );
    await disposeFixture.activate();
    final disposing = disposeFixture.client.forwardMessage(_input);
    await disposeStorage.replaceStarted.future;
    final close = disposeFixture.client.dispose();
    disposeStorage.releaseReplace.complete();
    expect(await disposing, isA<ChatCommandClosed<ForwardMessageResult>>());
    await close;
    expect(disposeFixture.transport.posts, isEmpty);
    expect(await _readMutations(disposeBacking, _identity), isNotNull);
    await disposeFixture.disposeDependencies();
  });

  test('forward settlement preserves unrelated shared mutation intents',
      () async {
    final storage = InMemoryApplicationChatStorage();
    await _seedSnapshot(storage, _seedStore());
    const unrelatedKey = 'unrelated-edit-key';
    await storage.replace(ApplicationChatQueuedMessageMutationIntentsRecord(
      identity: _identity,
      intents: [
        ApplicationChatQueuedMessageMutationIntent(
          request: EditMessageRequest.fromJson({
            'operation': 'edit',
            'messageId': 'unrelated-message',
            'expectedRevision': 1,
            'content': {'format': 'plain', 'text': 'unrelated'},
            'idempotencyKey': unrelatedKey,
          }),
          enqueueOrder: 1,
          enqueuedAt: const IsoTimestamp('2032-05-01T00:00:00.000Z'),
        ),
      ],
    ));
    final transport = _ScriptedTransport()
      ..enqueuePost((request) async => _successResponse(_requestFrom(request)));
    final fixture = _Fixture(storage: storage, transport: transport);
    await fixture.activate();
    expect(await fixture.client.forwardMessage(_input),
        isA<ChatCommandSuccess<ForwardMessageResult>>());
    final retained = await _readMutations(storage, _identity);
    expect(retained?.intents, hasLength(1));
    expect(retained?.intents.single.idempotencyKey, unrelatedKey);
    expect(retained?.intents.single.request, isA<EditMessageRequest>());
    await fixture.dispose();
  });
}

const _mutationKind =
    ApplicationChatStorageRecordKind.queuedMessageMutationIntents;
ApplicationChatQueuedMessageMutationIntentsRecord _mutationRecord(
        List<ApplicationChatQueuedMessageMutationIntent> intents) =>
    ApplicationChatQueuedMessageMutationIntentsRecord(
        identity: _identity, intents: intents);

List<ApplicationChatQueuedMessageMutationIntent> _unrelatedIntents() => [
      ApplicationChatQueuedMessageMutationIntent(
        request: EditMessageRequest.fromJson({
          'operation': 'edit',
          'messageId': 'unrelated-edit',
          'expectedRevision': 1,
          'content': {'format': 'plain', 'text': 'edit'},
          'idempotencyKey': 'concurrent-edit',
        }),
        enqueueOrder: 5,
        enqueuedAt: const IsoTimestamp('2032-05-01T00:00:00.000Z'),
      ),
      ApplicationChatQueuedMessageMutationIntent(
        request: SoftDeleteMessageRequest.fromJson({
          'operation': 'soft_delete',
          'messageId': 'unrelated-delete',
          'expectedRevision': 1,
          'idempotencyKey': 'concurrent-delete',
        }),
        enqueueOrder: 7,
        enqueuedAt: const IsoTimestamp('2032-05-01T00:00:00.000Z'),
      ),
      ApplicationChatQueuedMessageMutationIntent(
        request: ReactionMutationInput.fromJson({
          'operation': 'add_reaction',
          'messageId': 'unrelated-reaction',
          'reactionKey': 'thumbsup',
          'idempotencyKey': 'concurrent-reaction',
        }),
        enqueueOrder: 9,
        enqueuedAt: const IsoTimestamp('2032-05-01T00:00:00.000Z'),
      ),
    ];
ApplicationChatQueuedMessageMutationIntent _otherForward() =>
    ApplicationChatQueuedMessageMutationIntent(
      request: ForwardMessageRequest.fromJson({
        'operation': 'forward_message.v1',
        'sourceMessageId': 'unrelated-source',
        'destinationConversationId': 'other-conversation',
        'clientCorrelationId': 'other-correlation',
        'idempotencyKey': 'other-forward',
      }),
      enqueueOrder: 11,
      enqueuedAt: const IsoTimestamp('2032-05-01T00:00:00.000Z'),
    );

/// Models another storage writer after a read but before the next write.
/// Legacy writes also run the hook so lost-update regressions fail on old code.
final class _InterleavingMutationStorage
    implements AtomicApplicationChatStorage {
  _InterleavingMutationStorage(this.backing);
  final InMemoryApplicationChatStorage backing;
  Future<void> Function()? beforeWrite;
  int failedExchanges = 0;
  bool rejectWrites = false;
  final proposals = <ApplicationChatQueuedMessageMutationIntentsRecord?>[];

  Future<void> _onWrite(ApplicationChatStorageRecordKind kind) async {
    if (kind != _mutationKind) return;
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
    if (kind == _mutationKind) {
      proposals.add(replacement == null
          ? null
          : ApplicationChatStorageRecord.decode(replacement)
              as ApplicationChatQueuedMessageMutationIntentsRecord);
      if (rejectWrites) {
        failedExchanges++;
        return false;
      }
    }
    await _onWrite(kind);
    final committed =
        await backing.compareExchange(identity, kind, expected, replacement);
    if (!committed && kind == _mutationKind) failedExchanges++;
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

final class _Fixture {
  _Fixture({
    required ApplicationChatStorage storage,
    required this.transport,
    NormalizedSnapshotStore? store,
    HandrailChatAccessTokenProvider? tokenProvider,
    ChatForwardMessageCorrelationIdGenerator? generateCorrelationId,
    ChatCommandIdempotencyKeyGenerator? generateIdempotencyKey,
    ChatForwardMessageRetryWait? retryWait,
    ChatClientDiagnosticCallback? onStorageDiagnostic,
    this.realtimeSession,
    this.network,
  }) : store = store ?? NormalizedSnapshotStore() {
    client = HandrailChatClient(
      apiBaseUri: Uri.parse('https://chat.example.test/api/chat'),
      tokenProvider: tokenProvider ?? () async => 'access-token',
      transport: transport,
      localStorage: storage,
      onStorageDiagnostic: onStorageDiagnostic,
      storageIdentity: _identity,
      normalizedSnapshotStore: this.store,
      realtimeSession: realtimeSession,
      generateForwardMessageCorrelationId:
          generateCorrelationId ?? () => 'durable-forward-correlation',
      generateIdempotencyKey:
          generateIdempotencyKey ?? () => 'durable-forward-key',
      commandRetryOptions: const ChatCommandRetryOptions(
        maxAttempts: 1,
        maxAuthenticationRefreshes: 0,
      ),
      forwardMessageClock: () => DateTime.utc(2032, 5, 1),
      forwardMessageRetryBackoff: (_) => Duration.zero,
      forwardMessageRetryWait: retryWait,
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
    if (request.method != 'POST' || _postHandlers.isEmpty) {
      return Future.error(StateError('No scripted POST response remains.'));
    }
    return _postHandlers.removeFirst()(request);
  }
}

final class _BlockingMutationStorage implements ApplicationChatStorage {
  _BlockingMutationStorage(this.backing);

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
        ApplicationChatStorageRecordKind.queuedMessageMutationIntents) {
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

Map<String, Object?> _requestFrom(HandrailChatHttpRequest request) =>
    (jsonDecode(request.body!) as Map).cast<String, Object?>();

HandrailChatHttpResponse _successResponse(
  Map<String, Object?> request, {
  bool replayed = false,
}) =>
    HandrailChatHttpResponse(
      statusCode: 200,
      body: jsonEncode({
        'operation': 'forward_message.v1',
        'reconciliationStatus': replayed ? 'replayed' : 'applied',
        'clientCorrelationId': request['clientCorrelationId'],
        'destinationConversationId': request['destinationConversationId'],
        'message': _forwardedMessage().toJson(),
        'canonicalRevision': 1,
      }),
    );

HandrailChatHttpResponse _errorResponse(int status, String code) =>
    HandrailChatHttpResponse(
      statusCode: status,
      body: jsonEncode({
        'error': {'code': code, 'message': 'request failed'},
      }),
    );

ActiveMessage _sourceMessage({MessageContent? content}) => ActiveMessage(
      id: _sourceMessageId,
      tenantId: _identity.tenantId,
      conversationId: _sourceConversationId,
      author: const MessageAuthorIdentity(userId: UserId('source-author')),
      sequence: const MessageSequence(1),
      createdAt: const IsoTimestamp('2032-05-01T00:00:00.000Z'),
      updatedAt: const IsoTimestamp('2032-05-01T00:00:00.000Z'),
      revision: const MessageRevisionMetadata(revision: 1),
      content: content ??
          MessageContent(
            format: MessageContentFormat.plain,
            text: 'source text',
          ),
    );

ActiveMessage _forwardedMessage() => ActiveMessage(
      id: _destinationMessageId,
      tenantId: _identity.tenantId,
      conversationId: _destinationConversationId,
      author: const MessageAuthorIdentity(userId: UserId('user-1')),
      sequence: const MessageSequence(2),
      createdAt: const IsoTimestamp('2032-05-01T00:00:01.000Z'),
      updatedAt: const IsoTimestamp('2032-05-01T00:00:01.000Z'),
      revision: const MessageRevisionMetadata(revision: 1),
      content: MessageContent(
        format: MessageContentFormat.plain,
        text: 'source text',
        forwarded: const ForwardedMessageSnapshot(
          sourceMessageId: _sourceMessageId,
          originalAuthor: ForwardedMessageAuthorAttribution(
            userId: UserId('source-author'),
            displayName: 'Source Author',
          ),
          originalCreatedAt: IsoTimestamp('2032-05-01T00:00:00.000Z'),
        ),
      ),
    );

NormalizedSnapshotStore _seedStore({
  bool includeSource = true,
  bool includeDestination = true,
  MessageContent? sourceContent,
}) {
  final store = NormalizedSnapshotStore();
  if (includeDestination) _installDestination(store);
  if (includeSource) {
    store.reconcileMessage(_sourceMessage(content: sourceContent));
  }
  return store;
}

void _installDestination(NormalizedSnapshotStore store) {
  store.hydrateConversationList(ConversationListSnapshot.fromJson({
    'kind': 'conversation_list',
    'scope': const OrganizationConversationSnapshotScope().toJson(),
    'items': [
      {
        'id': _destinationConversationId.toJson(),
        'tenantId': _identity.tenantId.toJson(),
        'type': 'channel',
        'name': 'Forward destination',
        'visibility': 'public',
        'createdAt': '2032-05-01T00:00:00.000Z',
        'updatedAt': '2032-05-01T00:00:00.000Z',
        'latestSequence': 1,
        'activityAt': '2032-05-01T00:00:00.000Z',
        'unreadMentionCount': 0,
        'currentMember': {
          'tenantId': _identity.tenantId.toJson(),
          'conversationId': _destinationConversationId.toJson(),
          'userId': _identity.userId.toJson(),
          'role': 'member',
          'state': 'active',
          'joinedAt': '2032-05-01T00:00:00.000Z',
          'updatedAt': '2032-05-01T00:00:00.000Z',
        },
        'currentReadState': {
          'conversationId': _destinationConversationId.toJson(),
          'userId': _identity.userId.toJson(),
          'lastReadSequence': 0,
          'updatedAt': '2032-05-01T00:00:00.000Z',
        },
        'currentPreference': {
          'conversationId': _destinationConversationId.toJson(),
          'userId': _identity.userId.toJson(),
          'notificationPreference': 'mentions',
          'isStarred': false,
          'mute': {'muted': false},
          'updatedAt': '2032-05-01T00:00:00.000Z',
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
}

Future<void> _seedSnapshot(
  ApplicationChatStorage storage,
  NormalizedSnapshotStore store,
) async {
  await storage.replace(ApplicationChatNormalizedSnapshotRecord(
    identity: _identity,
    snapshot: store.canonicalPersistenceSnapshot(),
  ));
  await store.close();
}

Future<void> _seedForward(ApplicationChatStorage storage) => storage.replace(
      ApplicationChatQueuedMessageMutationIntentsRecord(
        identity: _identity,
        intents: [
          ApplicationChatQueuedMessageMutationIntent(
            request: ForwardMessageRequest.fromJson({
              'operation': 'forward_message.v1',
              'sourceMessageId': _sourceMessageId.toJson(),
              'destinationConversationId': _destinationConversationId.toJson(),
              'clientCorrelationId': 'durable-forward-correlation',
              'idempotencyKey': 'durable-forward-key',
            }),
            enqueueOrder: 1,
            enqueuedAt: const IsoTimestamp('2032-05-01T00:00:00.000Z'),
          ),
        ],
      ),
    );

Future<ApplicationChatQueuedMessageMutationIntentsRecord?> _readMutations(
  ApplicationChatStorage storage,
  ApplicationChatStorageIdentity identity,
) async =>
    await storage.read(
      identity,
      ApplicationChatStorageRecordKind.queuedMessageMutationIntents,
    ) as ApplicationChatQueuedMessageMutationIntentsRecord?;

KnownDurableEvent _createdEvent(Map<String, Object?> request) =>
    KnownDurableEvent.fromJson(
      {
        'eventId': 'forward-created-event',
        'protocolVersion': handrailChatProtocolVersion,
        'tenantId': _identity.tenantId.toJson(),
        'streamId': _destinationConversationId.toJson(),
        'type': 'message.created',
        'occurredAt': '2032-05-01T00:00:01.000Z',
        'payload': {
          'message': _forwardedMessage().toJson(),
          'clientMessageId': request['clientCorrelationId'],
        },
      },
      trustedIdentity: DurableEventTrustedIdentity(
        tenantId: _identity.tenantId,
        userId: _identity.userId,
      ),
    );

Map<String, Object?> _acceptedFrame() => {
      'type': 'chat.session.accepted',
      'metadata': _metadata,
      'tenantId': _identity.tenantId.toJson(),
      'actorStreamId': 'user:${_identity.userId.value}',
      'deviceId': _identity.deviceId.toJson(),
      'sessionId': 'session-1',
    };

Future<void> _eventually(FutureOr<bool> Function() predicate) async {
  for (var attempt = 0; attempt < 300; attempt += 1) {
    if (await predicate()) return;
    await Future<void>.delayed(Duration.zero);
  }
  fail('Condition was not reached.');
}

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
