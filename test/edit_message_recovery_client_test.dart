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
const _messageId = MessageId('message-1');
const _conversationId = ConversationId('conversation-1');
final _originalContent = MessageContent(
  format: MessageContentFormat.plain,
  text: 'canonical before edit',
);
final _editedContent = MessageContent(
  format: MessageContentFormat.markdown,
  text: 'survives **restart**',
);

void main() {
  test(
      'edit enqueue retries over concurrent delete, reaction, and forward intents',
      () async {
    final backing = InMemoryApplicationChatStorage();
    final storage = _AtomicMutationStorage(backing);
    final unrelated = _unrelatedMutations();
    final fixture = _Fixture(
      storage: storage,
      store: _seedStore(),
      transport: _ScriptedTransport()
        ..enqueuePatch((_) async => throw StateError('offline')),
      retryWait: _NeverRetryWait().call,
    );
    await fixture.activate();
    storage.beforeExchange = (expected, replacement) async {
      expect(expected, isNull);
      expect(replacement, isNotNull);
      await _appendMutations(backing, unrelated);
    };

    expect(await fixture.client.editMessage(_input('concurrent-enqueue')),
        isA<ChatCommandTransportFailure<EditMessageResult>>());
    final record = (await _readEdits(backing, _identity))!;
    expect(record.intents.take(3).map((intent) => intent.toJson()),
        unrelated.map((intent) => intent.toJson()));
    expect(record.intents.last.idempotencyKey, 'concurrent-enqueue');
    expect(record.intents.last.enqueueOrder, 13);
    expect(storage.conflicts, 1);
    expect(fixture.transport.patches, hasLength(1));
    await fixture.dispose();
  });

  test('edit settlement retries without erasing concurrent unrelated intents',
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
            await _appendMutations(backing, unrelated);
          };
          return _successResponse(_requestFrom(request));
        }),
    );
    await fixture.activate();
    expect(await fixture.client.editMessage(_input('concurrent-settlement')),
        isA<ChatCommandSuccess<EditMessageResult>>());
    expect(
        (await _readEdits(backing, _identity))!
            .intents
            .map((intent) => intent.toJson()),
        unrelated.map((intent) => intent.toJson()));
    expect(storage.conflicts, 1);
    expect(fixture.client.queuedMessageEdits, isEmpty);
    await fixture.dispose();
  });

  test(
      'concurrent same-message edits coalesce in commit order with original FIFO metadata',
      () async {
    final backing = InMemoryApplicationChatStorage();
    final storage = _BlockingMutationStorage(backing);
    final first = _Fixture(
      storage: storage,
      store: _seedStore(),
      transport: _ScriptedTransport()
        ..enqueuePatch((_) async => throw StateError('offline')),
      retryWait: _NeverRetryWait().call,
    );
    final second = _Fixture(
      storage: _AtomicMutationStorage(backing),
      store: _seedStore(),
      transport: _ScriptedTransport()
        ..enqueuePatch((_) async => throw StateError('offline')),
      retryWait: _NeverRetryWait().call,
    );
    await first.activate();
    await second.activate();
    final pending = first.client.editMessage(_input('commits-last'));
    await storage.replaceStarted.future;
    expect(await second.client.editMessage(_input('commits-first')),
        isA<ChatCommandTransportFailure<EditMessageResult>>());
    final original = (await _readEdits(backing, _identity))!.intents.single;
    storage.releaseReplace.complete();
    expect(
        await pending, isA<ChatCommandTransportFailure<EditMessageResult>>());
    final committed = (await _readEdits(backing, _identity))!.intents.single;
    expect(committed.idempotencyKey, 'commits-last');
    expect(committed.enqueueOrder, original.enqueueOrder);
    expect(committed.enqueuedAt, original.enqueuedAt);
    expect(first.client.queuedMessageEdits.single.request.toJson(),
        _request('commits-last').toJson());
    expect(first.transport.patches, hasLength(1));
    expect(second.transport.patches, hasLength(1));
    expect(storage.conflicts, 1);
    await first.dispose();
    await second.dispose();
  });

  test('settling an old edit preserves its concurrently coalesced successor',
      () async {
    final backing = InMemoryApplicationChatStorage();
    final storage = _AtomicMutationStorage(backing);
    final fixture = _Fixture(
      storage: storage,
      store: _seedStore(),
      transport: _ScriptedTransport()
        ..enqueuePatch((request) async {
          storage.beforeExchange = (_, replacement) async {
            expect(replacement, isNull);
            await _appendMutations(backing, [
              ApplicationChatQueuedMessageMutationIntent(
                request: _request('successor'),
                enqueueOrder: 2,
                enqueuedAt: const IsoTimestamp('2032-02-02T00:00:00.000Z'),
              )
            ]);
          };
          return _successResponse(_requestFrom(request));
        }),
    );
    await fixture.activate();
    expect(await fixture.client.editMessage(_input('settles-first')),
        isA<ChatCommandSuccess<EditMessageResult>>());
    final committed = (await _readEdits(backing, _identity))!.intents.single;
    expect(committed.idempotencyKey, 'successor');
    expect(committed.enqueueOrder, 1);
    expect(committed.enqueuedAt.value, '2032-02-01T00:00:00.000Z');
    expect(fixture.client.queuedMessageEdits.single.request.idempotencyKey,
        'successor');
    expect(fixture.transport.patches, hasLength(1));
    expect(storage.conflicts, 1);
    await fixture.dispose();
  });

  test('malformed hydration quarantines only the exact observed value',
      () async {
    final backing = InMemoryApplicationChatStorage();
    final storage = _AtomicMutationStorage(backing);
    final diagnostics = <ChatClientDiagnostic>[];
    // Install corruption at the edit runtime's encoded read, after the
    // preceding legacy forward runtime has finished its own hydration.
    storage.beforeEncodedRead = () {
      backing.putRawRecordForTesting(
          _identity,
          ApplicationChatStorageRecordKind.queuedMessageMutationIntents,
          {'malformed': 'private-record-details'});
    };
    storage.beforeExchange = (expected, replacement) async {
      expect(expected, contains('private-record-details'));
      expect(replacement, isNull);
      await _seedEdit(backing, _identity, _request('valid-replacement'));
    };
    final fixture = _Fixture(
      storage: storage,
      store: _seedStore(),
      transport: _ScriptedTransport(),
      onStorageDiagnostic: diagnostics.add,
    );
    await fixture.activate();
    expect(
        (await _readEdits(backing, _identity))!.intents.single.idempotencyKey,
        'valid-replacement');
    expect(storage.conflicts, 1);
    expect(storage.unconditionalMutationRemovals, 0);
    expect(diagnostics.map((diagnostic) => diagnostic.code),
        contains(ChatClientDiagnosticCode.messageMutationIntentsRejected));
    expect(diagnostics.map((diagnostic) => diagnostic.message).join(),
        isNot(contains('private-record-details')));
    expect(fixture.transport.patches, isEmpty);
    await fixture.dispose();
  });

  test('persists before projection, token access, or transport', () async {
    final backing = InMemoryApplicationChatStorage();
    final storage = _BlockingMutationStorage(backing);
    final store = _seedStore();
    final transport = _ScriptedTransport();
    final response = Completer<HandrailChatHttpResponse>();
    transport.enqueuePatch((request) => response.future);
    var tokenCalls = 0;
    final fixture = _Fixture(
      storage: storage,
      store: store,
      transport: transport,
      tokenProvider: () async {
        tokenCalls += 1;
        return 'token';
      },
    );
    await fixture.activate();

    final pending = fixture.client.editMessage(_input('persist-first'));
    await storage.replaceStarted.future;

    expect(store.state.canonicalMessages[_messageId]?.content?.text,
        _originalContent.text);
    expect(tokenCalls, 0);
    expect(transport.patches, isEmpty);

    storage.releaseReplace.complete();
    await _eventually(() => transport.patches.length == 1);
    final request = _requestFrom(transport.patches.single);
    response.complete(_successResponse(request));
    expect(await pending, isA<ChatCommandSuccess<EditMessageResult>>());
    expect(request, _request('persist-first').toJson());

    await fixture.dispose();
  });

  test('failed persistence returns validation without projection or auth',
      () async {
    final backing = InMemoryApplicationChatStorage();
    final storage = _FailingMutationStorage(backing);
    final store = _seedStore();
    var tokenCalls = 0;
    final diagnostics = <ChatClientDiagnostic>[];
    final fixture = _Fixture(
      storage: storage,
      store: store,
      transport: _ScriptedTransport(),
      tokenProvider: () async {
        tokenCalls += 1;
        return 'token';
      },
      onStorageDiagnostic: diagnostics.add,
    );
    await fixture.activate();

    expect(await fixture.client.editMessage(_input('write-failure')),
        isA<ChatCommandValidationFailure<EditMessageResult>>());
    expect(store.state.canonicalMessages[_messageId]?.content?.text,
        _originalContent.text);
    expect(tokenCalls, 0);
    expect(fixture.transport.patches, isEmpty);
    expect(diagnostics.single.code,
        ChatClientDiagnosticCode.messageMutationIntentsWriteFailed);
    expect(await _readEdits(backing, _identity), isNull);
    await fixture.dispose();
  });

  test('fresh client replays the exact stored request and idempotency key',
      () async {
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
    final firstResult = await first.client.editMessage(
      _input('restart-key', content: _editedContent),
    );
    expect(firstResult, isA<ChatCommandTransportFailure<EditMessageResult>>());
    final retained = await _readEdits(storage, _identity);
    final exact =
        (retained!.intents.single.request as EditMessageRequest).toJson();
    await first.dispose();

    final secondTransport = _ScriptedTransport();
    secondTransport.enqueuePatch((request) async {
      return _successResponse(_requestFrom(request), replayed: true);
    });
    final second = _Fixture(
      storage: storage,
      store: NormalizedSnapshotStore(),
      transport: secondTransport,
      generatedKey: 'must-not-replace-key',
    );
    await second.activate();
    expect(second.client.queuedMessageEdits.single.status,
        ChatQueuedMessageEditStatus.pending);
    await second.initialize();
    await _eventually(() => second.client.queuedMessageEdits.isEmpty);

    expect(_requestFrom(secondTransport.patches.single), exact);
    expect(secondTransport.patches.single.headers['Idempotency-Key'],
        'restart-key');
    expect(await _readEdits(storage, _identity), isNull);
    await second.dispose();
  });

  test('matching canonical event settles before a later HTTP completion',
      () async {
    final storage = InMemoryApplicationChatStorage();
    final store = _seedStore();
    final transport = _ScriptedTransport();
    final response = Completer<HandrailChatHttpResponse>();
    transport.enqueuePatch((_) => response.future);
    final fixture = _Fixture(
      storage: storage,
      store: store,
      transport: transport,
    );
    await fixture.activate();
    final pending = fixture.client.editMessage(_input('event-first'));
    await _eventually(() => transport.patches.length == 1);

    final canonical = _message(revision: 2, content: _editedContent);
    fixture.client.reduceDurableEvent(_messageUpdatedEvent(canonical));
    await _eventually(() async => await _readEdits(storage, _identity) == null);
    response.complete(_successResponse(_requestFrom(transport.patches.single)));

    expect(await pending, isA<ChatCommandSuccess<EditMessageResult>>());
    expect(store.state.canonicalMessages[_messageId]?.toJson(),
        canonical.toJson());
    expect(transport.patches, hasLength(1));
    await fixture.dispose();
  });

  test('terminal authorization and revision-conflict outcomes remove intent',
      () async {
    final validationStorage = InMemoryApplicationChatStorage();
    final validation = _Fixture(
      storage: validationStorage,
      store: _seedStore(),
      transport: _ScriptedTransport(),
    );
    await validation.activate();
    expect(await validation.client.editMessage(_input('invalid key')),
        isA<ChatCommandValidationFailure<EditMessageResult>>());
    expect(await _readEdits(validationStorage, _identity), isNull);
    expect(validation.transport.patches, isEmpty);
    await validation.dispose();

    final authStorage = InMemoryApplicationChatStorage();
    final authTransport = _ScriptedTransport()
      ..enqueuePatch((_) async => _errorResponse(403, 'AUTHENTICATION_FAILED'));
    final auth = _Fixture(
      storage: authStorage,
      store: _seedStore(),
      transport: authTransport,
    );
    await auth.activate();
    expect(await auth.client.editMessage(_input('auth-terminal')),
        isA<ChatCommandAuthenticationFailure<EditMessageResult>>());
    expect(await _readEdits(authStorage, _identity), isNull);
    await auth.dispose();

    final conflictStorage = InMemoryApplicationChatStorage();
    final conflictTransport = _ScriptedTransport()
      ..enqueuePatch((request) async {
        final parsed = _requestFrom(request);
        return _conflictResponse(
          parsed,
          _message(
            revision: 3,
            content: MessageContent(
              format: MessageContentFormat.plain,
              text: 'newer canonical',
            ),
          ),
        );
      });
    final conflict = _Fixture(
      storage: conflictStorage,
      store: _seedStore(),
      transport: conflictTransport,
    );
    await conflict.activate();
    final conflictResult = await conflict.client.editMessage(
      _input('revision-terminal'),
    );
    expect(conflictResult, isA<ChatCommandSuccess<EditMessageResult>>());
    expect(
      (conflictResult as ChatCommandSuccess<EditMessageResult>)
          .value
          .reconciliationStatus,
      EditMessageReconciliationStatus.revisionConflict,
    );
    expect(await _readEdits(conflictStorage, _identity), isNull);
    await conflict.dispose();
  });

  test('ambiguous transport, 429, 5xx, malformed, and cancellation retain',
      () async {
    final cases = <String,
        Future<HandrailChatHttpResponse> Function(HandrailChatHttpRequest)>{
      'transport': (_) async => throw StateError('offline'),
      'rate-limit': (_) async => _errorResponse(429, 'RATE_LIMITED'),
      'server': (_) async => _errorResponse(500, 'SERVER_FAILED'),
      'malformed': (_) async => const HandrailChatHttpResponse(
            statusCode: 200,
            body: '{not-json',
          ),
    };
    for (final entry in cases.entries) {
      final storage = InMemoryApplicationChatStorage();
      final transport = _ScriptedTransport()..enqueuePatch(entry.value);
      final fixture = _Fixture(
        storage: storage,
        store: _seedStore(),
        transport: transport,
        retryWait: _NeverRetryWait().call,
      );
      await fixture.activate();
      final result =
          await fixture.client.editMessage(_input('${entry.key}-key'));
      expect(
        result,
        anyOf(
          isA<ChatCommandTransportFailure<EditMessageResult>>(),
          isA<ChatCommandMalformedResponse<EditMessageResult>>(),
        ),
        reason: entry.key,
      );
      expect((await _readEdits(storage, _identity))?.intents, hasLength(1),
          reason: entry.key);
      await fixture.dispose();
    }

    final storage = InMemoryApplicationChatStorage();
    final started = Completer<void>();
    final response = Completer<HandrailChatHttpResponse>();
    final transport = _ScriptedTransport()
      ..enqueuePatch((_) {
        started.complete();
        return response.future;
      });
    final fixture = _Fixture(
      storage: storage,
      store: _seedStore(),
      transport: transport,
      retryWait: _NeverRetryWait().call,
    );
    await fixture.activate();
    await fixture.initialize();
    final cancellation = ChatCommandCancellationController();
    final pending = fixture.client.editMessage(
      _input('cancelled-key'),
      cancellationSignal: cancellation.signal,
    );
    await started.future;
    cancellation.cancel();
    expect(await pending, isA<ChatCommandAborted<EditMessageResult>>());
    expect((await _readEdits(storage, _identity))?.intents, hasLength(1));
    await fixture.dispose();
  });

  test('close ambiguity retains the dispatched edit', () async {
    final storage = InMemoryApplicationChatStorage();
    final started = Completer<void>();
    final response = Completer<HandrailChatHttpResponse>();
    final transport = _ScriptedTransport()
      ..enqueuePatch((_) {
        started.complete();
        return response.future;
      });
    final fixture = _Fixture(
      storage: storage,
      store: _seedStore(),
      transport: transport,
    );
    await fixture.activate();
    final pending = fixture.client.editMessage(_input('close-key'));
    await started.future;
    await fixture.client.dispose();
    expect(await pending, isA<ChatCommandClosed<EditMessageResult>>());
    expect((await _readEdits(storage, _identity))?.intents, hasLength(1));
    await fixture.disposeClientDependencies();
  });

  test('recovery waits for exact canonical base and preserves stale conflict',
      () async {
    final missingStorage = InMemoryApplicationChatStorage();
    await _seedEdit(missingStorage, _identity, _request('missing-base'));
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
    expect(missing.client.queuedMessageEdits.single.status,
        ChatQueuedMessageEditStatus.waitingForCanonicalBase);
    missing.store.reconcileMessage(_message());
    await _eventually(() => missingTransport.patches.length == 1);
    await _eventually(() => missing.client.queuedMessageEdits.isEmpty);
    await missing.dispose();

    final staleStorage = InMemoryApplicationChatStorage();
    await _seedEdit(staleStorage, _identity, _request('stale-base'));
    final staleTransport = _ScriptedTransport();
    final stale = _Fixture(
      storage: staleStorage,
      store: _seedStore(revision: 2),
      transport: staleTransport,
    );
    await stale.activate();
    await stale.initialize();
    expect(stale.client.queuedMessageEdits.single.status,
        ChatQueuedMessageEditStatus.revisionConflict);
    expect(staleTransport.patches, isEmpty);
    expect(
        stale.store.state.canonicalMessages[_messageId]?.revision.revision, 2);
    expect((await _readEdits(staleStorage, _identity))?.intents, hasLength(1));
    await stale.dispose();
  });

  test('offline, background, and realtime readiness pause then resume replay',
      () async {
    final storage = InMemoryApplicationChatStorage();
    await _seedEdit(storage, _identity, _request('lifecycle-key'));
    final store = _seedStore();
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
      store: store,
      transport: transport,
      realtimeSession: session,
      network: network,
    );
    await fixture.activate();
    await fixture.initialize();
    expect(transport.patches, isEmpty, reason: 'offline and not connected');
    fixture.client.setApplicationForeground(false);
    await session.start();
    network.setOnline(true);
    await _eventually(() => socketFactory.uris.length == 1);
    socket.emitJson(_acceptedFrame());
    await _eventually(() => session.state is ChatRealtimeConnectedState);
    expect(transport.patches, isEmpty, reason: 'backgrounded');
    fixture.client.setApplicationForeground(true);
    await _eventually(() => transport.patches.length == 1);
    await _eventually(() => fixture.client.queuedMessageEdits.isEmpty);
    await fixture.dispose();
  });

  test('injectable bounded backoff retries only after the wait is released',
      () async {
    final storage = InMemoryApplicationChatStorage();
    await _seedEdit(storage, _identity, _request('retry-key'));
    final waits = _ManualRetryWait();
    final transport = _ScriptedTransport()
      ..enqueuePatch((_) async => throw StateError('offline'))
      ..enqueuePatch(
          (request) async => _successResponse(_requestFrom(request)));
    final fixture = _Fixture(
      storage: storage,
      store: _seedStore(),
      transport: transport,
      retryBackoff: (attempt) => Duration(milliseconds: attempt * 7),
      retryWait: waits.call,
    );
    await fixture.activate();
    await fixture.initialize();
    await _eventually(() => waits.delays.length == 1);
    expect(waits.delays, [const Duration(milliseconds: 7)]);
    expect(transport.patches, hasLength(1));
    waits.release(0);
    await _eventually(() => fixture.client.queuedMessageEdits.isEmpty);
    expect(transport.patches, hasLength(2));
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
    final pending = fixture.client.editMessage(_input('old-identity'));
    await storage.replaceStarted.future;
    final replacement = fixture.client.activateStorageIdentity(_otherIdentity);
    storage.releaseReplace.complete();
    expect(await pending, isA<ChatCommandClosed<EditMessageResult>>());
    await replacement;
    expect(fixture.transport.patches, isEmpty);
    expect(fixture.client.queuedMessageEdits, isEmpty);
    expect((await _readEdits(backing, _identity))?.intents, hasLength(1));
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
        disposing.client.editMessage(_input('dispose-during-write'));
    await disposeStorage.replaceStarted.future;
    final close = disposing.client.dispose();
    disposeStorage.releaseReplace.complete();
    expect(await disposePending, isA<ChatCommandClosed<EditMessageResult>>());
    await close;
    expect(disposing.transport.patches, isEmpty);
    expect(
        (await _readEdits(disposeBacking, _identity))?.intents, hasLength(1));
    await disposing.disposeClientDependencies();
  });
}

final class _Fixture {
  _Fixture({
    required ApplicationChatStorage storage,
    required this.store,
    required this.transport,
    HandrailChatAccessTokenProvider? tokenProvider,
    String generatedKey = 'generated-key',
    ChatMessageEditRetryBackoff? retryBackoff,
    ChatMessageEditRetryWait? retryWait,
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
      generateIdempotencyKey: () => generatedKey,
      commandRetryOptions: const ChatCommandRetryOptions(
        maxAttempts: 1,
        maxAuthenticationRefreshes: 0,
      ),
      messageEditClock: () => DateTime.utc(2032, 2, 1),
      messageEditRetryBackoff: retryBackoff,
      messageEditRetryWait: retryWait,
      onStorageDiagnostic: onStorageDiagnostic,
    );
  }

  final NormalizedSnapshotStore store;
  final _ScriptedTransport transport;
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
    await disposeClientDependencies();
  }

  Future<void> disposeClientDependencies() async {
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

// Each wrapper is an independent engine boundary over the same atomic adapter.
class _AtomicMutationStorage implements AtomicApplicationChatStorage {
  _AtomicMutationStorage(this.backing);

  final InMemoryApplicationChatStorage backing;
  Future<void> Function(String? expected, String? replacement)? beforeExchange;
  void Function()? beforeEncodedRead;
  int conflicts = 0;
  int unconditionalMutationRemovals = 0;

  @override
  Future<String?> readEncoded(ApplicationChatStorageIdentity identity,
      ApplicationChatStorageRecordKind kind) {
    if (kind == ApplicationChatStorageRecordKind.queuedMessageMutationIntents) {
      final hook = beforeEncodedRead;
      beforeEncodedRead = null;
      hook?.call();
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

final class _BlockingMutationStorage extends _AtomicMutationStorage {
  _BlockingMutationStorage(super.backing);

  final Completer<void> replaceStarted = Completer<void>();
  final Completer<void> releaseReplace = Completer<void>();

  @override
  Future<bool> compareExchange(
      ApplicationChatStorageIdentity identity,
      ApplicationChatStorageRecordKind kind,
      String? expected,
      String? replacement) async {
    if (kind == ApplicationChatStorageRecordKind.queuedMessageMutationIntents &&
        replacement != null &&
        replacement != expected) {
      if (!replaceStarted.isCompleted) replaceStarted.complete();
      await releaseReplace.future;
    }
    return super.compareExchange(identity, kind, expected, replacement);
  }
}

final class _FailingMutationStorage extends _AtomicMutationStorage {
  _FailingMutationStorage(super.backing);

  @override
  Future<bool> compareExchange(
      ApplicationChatStorageIdentity identity,
      ApplicationChatStorageRecordKind kind,
      String? expected,
      String? replacement) {
    if (kind == ApplicationChatStorageRecordKind.queuedMessageMutationIntents &&
        replacement != expected) {
      return Future<bool>.error(StateError('storage unavailable'));
    }
    return super.compareExchange(identity, kind, expected, replacement);
  }
}

Future<void> _appendMutations(ApplicationChatStorage storage,
    List<ApplicationChatQueuedMessageMutationIntent> intents) async {
  await ApplicationChatStorageMutator(storage)
      .mutate<ApplicationChatQueuedMessageMutationIntentsRecord>(
    _identity,
    ApplicationChatStorageRecordKind.queuedMessageMutationIntents,
    (current) => ApplicationChatQueuedMessageMutationIntentsRecord(
      identity: _identity,
      intents: [...?current?.intents, ...intents],
    ),
  );
}

List<ApplicationChatQueuedMessageMutationIntent> _unrelatedMutations() => [
      ApplicationChatQueuedMessageMutationIntent(
        request: SoftDeleteMessageRequest.fromJson({
          'operation': 'soft_delete',
          'messageId': 'unrelated-delete',
          'expectedRevision': 1,
          'idempotencyKey': 'delete-key',
        }),
        enqueueOrder: 10,
        enqueuedAt: const IsoTimestamp('2032-02-01T00:00:10.000Z'),
      ),
      ApplicationChatQueuedMessageMutationIntent(
        request: ReactionMutationInput.fromJson({
          'operation': 'add_reaction',
          'messageId': 'unrelated-reaction',
          'reactionKey': 'thumbsup',
          'idempotencyKey': 'reaction-key',
        }),
        enqueueOrder: 11,
        enqueuedAt: const IsoTimestamp('2032-02-01T00:00:11.000Z'),
      ),
      ApplicationChatQueuedMessageMutationIntent(
        request: ForwardMessageRequest.fromJson({
          'operation': 'forward_message.v1',
          'sourceMessageId': 'unrelated-forward',
          'destinationConversationId': 'destination',
          'clientCorrelationId': 'forward-correlation',
          'idempotencyKey': 'forward-key',
        }),
        enqueueOrder: 12,
        enqueuedAt: const IsoTimestamp('2032-02-01T00:00:12.000Z'),
      ),
    ];

final class _ManualRetryWait {
  final List<Duration> delays = [];
  final List<Completer<void>> _waits = [];

  Future<void> call(Duration delay, ChatCommandCancellationSignal _) {
    delays.add(delay);
    final wait = Completer<void>();
    _waits.add(wait);
    return wait.future;
  }

  void release(int index) => _waits[index].complete();
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

ChatEditMessageInput _input(
  String key, {
  MessageContent? content,
}) =>
    ChatEditMessageInput(
      messageId: _messageId,
      expectedRevision: 1,
      content: content ?? _editedContent,
      idempotencyKey: key,
    );

EditMessageRequest _request(String key) => EditMessageRequest.fromJson({
      'operation': 'edit',
      'messageId': _messageId.toJson(),
      'expectedRevision': 1,
      'content': _editedContent.toJson(),
      'idempotencyKey': key,
    });

Map<String, Object?> _requestFrom(HandrailChatHttpRequest request) =>
    (jsonDecode(request.body!) as Map).cast<String, Object?>();

HandrailChatHttpResponse _successResponse(
  Map<String, Object?> request, {
  bool replayed = false,
}) =>
    HandrailChatHttpResponse(
      statusCode: 200,
      body: jsonEncode({
        'operation': 'edit',
        'reconciliationStatus': replayed ? 'replayed' : 'applied',
        'expectedRevision': request['expectedRevision'],
        'message': _message(
          revision: 2,
          content: MessageContent.fromJson(request['content']),
        ).toJson(),
        'canonicalRevision': 2,
      }),
    );

HandrailChatHttpResponse _conflictResponse(
  Map<String, Object?> request,
  ActiveMessage canonical,
) =>
    HandrailChatHttpResponse(
      statusCode: 409,
      body: jsonEncode({
        'operation': 'edit',
        'reconciliationStatus': 'revision_conflict',
        'expectedRevision': request['expectedRevision'],
        'message': canonical.toJson(),
        'canonicalRevision': canonical.revision.revision,
      }),
    );

HandrailChatHttpResponse _errorResponse(int status, String code) =>
    HandrailChatHttpResponse(
      statusCode: status,
      body: jsonEncode({
        'error': {'code': code, 'message': 'request failed'},
      }),
    );

ActiveMessage _message({
  int revision = 1,
  MessageContent? content,
}) =>
    ActiveMessage(
      id: _messageId,
      tenantId: _identity.tenantId,
      conversationId: _conversationId,
      author: const MessageAuthorIdentity(userId: UserId('user-1')),
      sequence: const MessageSequence(1),
      createdAt: const IsoTimestamp('2032-02-01T00:00:01.000Z'),
      updatedAt: IsoTimestamp(
        revision == 1 ? '2032-02-01T00:00:01.000Z' : '2032-02-01T00:00:05.000Z',
      ),
      revision: MessageRevisionMetadata(
        revision: revision,
        editedAt: revision == 1
            ? null
            : const IsoTimestamp('2032-02-01T00:00:05.000Z'),
        editedByUserId: revision == 1 ? null : const UserId('user-1'),
      ),
      content: content ?? _originalContent,
    );

NormalizedSnapshotStore _seedStore({int revision = 1}) {
  final store = NormalizedSnapshotStore();
  store.hydrateConversationList(ConversationListSnapshot.fromJson({
    'kind': 'conversation_list',
    'scope': const OrganizationConversationSnapshotScope().toJson(),
    'items': [
      {
        'id': _conversationId.toJson(),
        'tenantId': _identity.tenantId.toJson(),
        'type': 'channel',
        'name': 'Durable edits',
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
  store.reconcileMessage(_message(revision: revision));
  return store;
}

KnownDurableEvent _messageUpdatedEvent(ActiveMessage message) =>
    KnownDurableEvent.fromJson(
      {
        'eventId': 'edit-event-1',
        'protocolVersion': handrailChatProtocolVersion,
        'tenantId': _identity.tenantId.toJson(),
        'streamId': _conversationId.toJson(),
        'type': 'message.updated',
        'occurredAt': '2032-02-01T00:00:05.000Z',
        'payload': {'message': message.toJson()},
      },
      trustedIdentity: DurableEventTrustedIdentity(
        tenantId: _identity.tenantId,
        userId: _identity.userId,
      ),
    );

Future<void> _seedEdit(
  ApplicationChatStorage storage,
  ApplicationChatStorageIdentity identity,
  EditMessageRequest request,
) =>
    storage.replace(ApplicationChatQueuedMessageMutationIntentsRecord(
      identity: identity,
      intents: [
        ApplicationChatQueuedMessageMutationIntent(
          request: request,
          enqueueOrder: 1,
          enqueuedAt: const IsoTimestamp('2032-02-01T00:00:00.000Z'),
        ),
      ],
    ));

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

Future<ApplicationChatQueuedMessageMutationIntentsRecord?> _readEdits(
  ApplicationChatStorage storage,
  ApplicationChatStorageIdentity identity,
) async =>
    await storage.read(
      identity,
      ApplicationChatStorageRecordKind.queuedMessageMutationIntents,
    ) as ApplicationChatQueuedMessageMutationIntentsRecord?;

Future<void> _eventually(FutureOr<bool> Function() predicate) async {
  for (var attempt = 0; attempt < 200; attempt += 1) {
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
