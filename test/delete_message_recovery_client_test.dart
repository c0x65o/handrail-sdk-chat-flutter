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

void main() {
  test('atomic delete append retries preserve forward and reaction order',
      () async {
    final backing = InMemoryApplicationChatStorage();
    final storage = _InterleavingMutationStorage(backing);
    final fixture = _Fixture(
      storage: storage,
      store: _seedStore(),
      transport: _ScriptedTransport()
        ..enqueueDelete((_) async => throw StateError('offline')),
      retryWait: _NeverRetryWait().call,
    );
    addTearDown(fixture.dispose);
    await fixture.activate();
    final concurrent = _unrelatedIntents();
    storage.beforeWrite = () async {
      expect(fixture.client.queuedMessageDeletes, isEmpty);
      expect(fixture.transport.deletes, isEmpty);
      await backing.replace(_mutationRecord(concurrent));
    };
    expect(await fixture.client.deleteMessage(_input('atomic-append')),
        isA<ChatCommandTransportFailure<SoftDeleteMessageResult>>());
    final record = (await _readMutations(backing, _identity))!;
    expect(record.intents.take(2).map((intent) => intent.toJson()),
        concurrent.map((intent) => intent.toJson()));
    expect(record.intents.last.enqueueOrder, 10);
    expect(fixture.client.queuedMessageDeletes.single.enqueueOrder, 10);
    expect(storage.failedExchanges, 1);
  });

  test('atomic append rechecks occupied message lane on retry', () async {
    final backing = InMemoryApplicationChatStorage();
    final storage = _InterleavingMutationStorage(backing);
    final fixture = _Fixture(
        storage: storage, store: _seedStore(), transport: _ScriptedTransport());
    addTearDown(fixture.dispose);
    await fixture.activate();
    final competing = _mutationRecord([
      ApplicationChatQueuedMessageMutationIntent(
        request: _request('competing-delete'),
        enqueueOrder: 4,
        enqueuedAt: const IsoTimestamp('2032-02-01T00:00:02.000Z'),
      ),
      ..._unrelatedIntents(),
    ]);
    storage.beforeWrite = () => backing.replace(competing);
    expect(await fixture.client.deleteMessage(_input('losing-delete')),
        isA<ChatCommandValidationFailure<SoftDeleteMessageResult>>());
    expect((await _readMutations(backing, _identity))!.encode(),
        competing.encode());
    expect(fixture.client.queuedMessageDeletes.single.request.idempotencyKey,
        'competing-delete');
    expect(fixture.transport.deletes, isEmpty);
  });

  for (final canonical in [false, true]) {
    test(
        'atomic ${canonical ? 'canonical' : 'HTTP'} settlement preserves concurrent forward and reaction',
        () async {
      final backing = InMemoryApplicationChatStorage();
      final storage = _InterleavingMutationStorage(backing);
      final response = Completer<HandrailChatHttpResponse>();
      final fixture = _Fixture(
          storage: storage,
          store: _seedStore(),
          transport: _ScriptedTransport()
            ..enqueueDelete((_) => response.future));
      addTearDown(fixture.dispose);
      await fixture.activate();
      final pending = fixture.client.deleteMessage(_input('atomic-settle'));
      await _eventually(() => fixture.transport.deletes.length == 1);
      final original = (await _readMutations(backing, _identity))!;
      final concurrent = _unrelatedIntents();
      storage.beforeWrite = () => backing
          .replace(_mutationRecord([...original.intents, ...concurrent]));
      if (canonical) {
        fixture.client.reduceDurableEvent(
            _messageDeletedEvent(_deletedMessage(revision: 2)));
        await _eventually(() => fixture.client.queuedMessageDeletes.isEmpty);
      }
      response.complete(_successResponse(_request('atomic-settle').toJson()));
      expect(await pending, isA<ChatCommandSuccess<SoftDeleteMessageResult>>());
      expect((await _readMutations(backing, _identity))!.encode(),
          _mutationRecord(concurrent).encode());
      expect(fixture.client.queuedMessageDeletes, isEmpty);
      expect(storage.failedExchanges, 1);
    });
  }

  for (final changed in ['request', 'order', 'time']) {
    test('stale delete settlement preserves replacement with changed $changed',
        () async {
      final backing = InMemoryApplicationChatStorage();
      final storage = _InterleavingMutationStorage(backing);
      final response = Completer<HandrailChatHttpResponse>();
      final fixture = _Fixture(
          storage: storage,
          store: _seedStore(),
          transport: _ScriptedTransport()
            ..enqueueDelete((_) => response.future));
      addTearDown(fixture.dispose);
      await fixture.activate();
      final pending = fixture.client.deleteMessage(_input('replaced-delete'));
      await _eventually(() => fixture.transport.deletes.length == 1);
      final original =
          (await _readMutations(backing, _identity))!.intents.single;
      final replacement = _mutationRecord([
        ApplicationChatQueuedMessageMutationIntent(
          request: changed == 'request'
              ? SoftDeleteMessageRequest.fromJson({
                  ..._request('replaced-delete').toJson(),
                  'expectedRevision': 2,
                })
              : original.request,
          enqueueOrder: changed == 'order' ? 3 : original.enqueueOrder,
          enqueuedAt: changed == 'time'
              ? const IsoTimestamp('2032-02-01T00:00:03.000Z')
              : original.enqueuedAt,
        ),
        ..._unrelatedIntents(),
      ]);
      storage.beforeWrite = () => backing.replace(replacement);
      response.complete(_errorResponse(400, 'REJECTED'));
      expect(
          await pending, isA<ChatCommandRejected<SoftDeleteMessageResult>>());
      expect((await _readMutations(backing, _identity))!.encode(),
          replacement.encode());
      final queued = fixture.client.queuedMessageDeletes.single;
      expect(
          queued.request.toJson(),
          (replacement.intents.first.request as SoftDeleteMessageRequest)
              .toJson());
      expect(queued.enqueueOrder, replacement.intents.first.enqueueOrder);
      expect(queued.enqueuedAt,
          DateTime.parse(replacement.intents.first.enqueuedAt.value));
      expect(storage.failedExchanges, 1);
      expect(fixture.store.state.canonicalMessages[_messageId],
          isA<ActiveMessage>());
    });
  }

  test('atomic pre-dispatch cancellation preserves concurrent intents',
      () async {
    final backing = InMemoryApplicationChatStorage();
    final storage = _InterleavingMutationStorage(backing);
    final cancellation = ChatCommandCancellationController();
    final fixture = _Fixture(
        storage: storage, store: _seedStore(), transport: _ScriptedTransport());
    addTearDown(fixture.dispose);
    await fixture.activate();
    storage.beforeWrite = () async {
      cancellation.cancel();
      // The first write persists the delete. Interleave the second writer
      // specifically with cancellation's subsequent removal.
      storage.beforeWrite = () async {
        final current = (await _readMutations(backing, _identity))!;
        await backing.replace(
            _mutationRecord([...current.intents, ..._unrelatedIntents()]));
      };
    };
    expect(
        await fixture.client.deleteMessage(_input('cancel-race'),
            cancellationSignal: cancellation.signal),
        isA<ChatCommandAborted<SoftDeleteMessageResult>>());
    expect((await _readMutations(backing, _identity))!.encode(),
        _mutationRecord(_unrelatedIntents()).encode());
    expect(fixture.client.queuedMessageDeletes, isEmpty);
    expect(fixture.transport.deletes, isEmpty);
    expect(storage.failedExchanges, 1);
  });

  for (final replaced in [false, true]) {
    test(
        'canonical settlement handles ${replaced ? 'replaced' : 'absent'} exact delete',
        () async {
      final backing = InMemoryApplicationChatStorage();
      final storage = _InterleavingMutationStorage(backing);
      final response = Completer<HandrailChatHttpResponse>();
      final fixture = _Fixture(
          storage: storage,
          store: _seedStore(),
          transport: _ScriptedTransport()
            ..enqueueDelete((_) => response.future));
      addTearDown(fixture.dispose);
      await fixture.activate();
      final pending = fixture.client.deleteMessage(_input('canonical-race'));
      var completed = false;
      unawaited(pending.then((_) {
        completed = true;
      }));
      await _eventually(() => fixture.transport.deletes.length == 1);
      final competing = _mutationRecord([
        if (replaced)
          ApplicationChatQueuedMessageMutationIntent(
            request: SoftDeleteMessageRequest.fromJson({
              ..._request('canonical-race').toJson(),
              'messageId': 'replacement-message',
            }),
            enqueueOrder: 2,
            enqueuedAt: const IsoTimestamp('2032-02-01T00:00:02.000Z'),
          ),
        ..._unrelatedIntents(),
      ]);
      storage.beforeWrite = () => backing.replace(competing);
      fixture.client.reduceDurableEvent(
          _messageDeletedEvent(_deletedMessage(revision: 2)));
      await _eventually(() => replaced
          ? fixture.client.queuedMessageDeletes.single.request.messageId ==
              const MessageId('replacement-message')
          : fixture.client.queuedMessageDeletes.isEmpty);
      // Drain scheduled settlement work before observing whether canonical
      // authority completed the original dispatch.
      await Future<void>.delayed(Duration.zero);
      expect(completed, !replaced);
      response.complete(_successResponse(_request('canonical-race').toJson()));
      expect(await pending, isA<ChatCommandSuccess<SoftDeleteMessageResult>>());
      expect((await _readMutations(backing, _identity))!.encode(),
          competing.encode());
      expect(storage.failedExchanges, 1);
    });
  }

  test(
      'delete activation quarantines exact malformed bytes and hydrates concurrent valid record',
      () async {
    final backing = InMemoryApplicationChatStorage();
    final storage = _InterleavingMutationStorage(backing);
    final diagnostics = <ChatClientDiagnostic>[];
    final valid = _mutationRecord([
      ApplicationChatQueuedMessageMutationIntent(
          request: _request('quarantine-survivor'),
          enqueueOrder: 1,
          enqueuedAt: const IsoTimestamp('2032-02-01T00:00:00.000Z')),
      ..._unrelatedIntents(),
    ]);
    // Forward and edit activate first. Inject corruption only at the delete
    // activation read, whether siblings use read or readEncoded.
    storage.beforeRead = (readNumber) {
      if (readNumber != 3) return;
      backing.putRawRecordForTesting(
          _identity, _mutationKind, {'malformed': true});
      storage.beforeWrite = () => backing.replace(valid);
    };
    final fixture = _Fixture(
        storage: storage,
        store: _seedStore(),
        transport: _ScriptedTransport(),
        onStorageDiagnostic: diagnostics.add);
    addTearDown(fixture.dispose);
    await fixture.activate();
    expect(
        (await _readMutations(backing, _identity))!.encode(), valid.encode());
    expect(fixture.client.queuedMessageDeletes.single.request.idempotencyKey,
        'quarantine-survivor');
    expect(fixture.client.queuedMessageDeletes.single.status,
        ChatQueuedMessageDeleteStatus.pending);
    expect(diagnostics.map((diagnostic) => diagnostic.code),
        contains(ChatClientDiagnosticCode.messageMutationIntentsRejected));
    expect(
        diagnostics.map((diagnostic) => diagnostic.code),
        isNot(contains(
            ChatClientDiagnosticCode.messageMutationIntentsQuarantineFailed)));
    expect(storage.failedExchanges, 1);
  });

  test('persists the exact request before projection, auth, or transport',
      () async {
    final backing = InMemoryApplicationChatStorage();
    final storage = _BlockingMutationStorage(backing);
    final store = _seedStore();
    final transport = _ScriptedTransport();
    final response = Completer<HandrailChatHttpResponse>();
    transport.enqueueDelete((request) => response.future);
    var tokenCalls = 0;
    final fixture = _Fixture(
      storage: storage,
      store: store,
      transport: transport,
      tokenProvider: () async {
        tokenCalls += 1;
        return 'access-token';
      },
    );
    await fixture.activate();

    final pending = fixture.client.deleteMessage(_input('persist-first'));
    await storage.replaceStarted.future;

    expect(store.state.canonicalMessages[_messageId], isA<ActiveMessage>());
    expect(tokenCalls, 0);
    expect(transport.deletes, isEmpty);

    storage.releaseReplace.complete();
    await _eventually(() => transport.deletes.length == 1);
    final wire = _requestFrom(transport.deletes.single);
    expect(wire, _request('persist-first').toJson());
    response.complete(_successResponse(wire));
    expect(await pending, isA<ChatCommandSuccess<SoftDeleteMessageResult>>());
    expect(await _readMutations(backing, _identity), isNull);
    await fixture.dispose();
  });

  test('restarts from an ambiguous loss and replays the exact stored request',
      () async {
    final storage = InMemoryApplicationChatStorage();
    await _seedSnapshot(storage, _seedStore());
    final firstTransport = _ScriptedTransport()
      ..enqueueDelete((_) async => throw StateError('offline'));
    final first = _Fixture(
      storage: storage,
      store: NormalizedSnapshotStore(),
      transport: firstTransport,
      retryWait: _NeverRetryWait().call,
    );
    await first.activate();
    final firstResult =
        await first.client.deleteMessage(_input('restart-delete-key'));
    expect(
      firstResult,
      isA<ChatCommandTransportFailure<SoftDeleteMessageResult>>(),
    );
    final retained = await _readMutations(storage, _identity);
    final exact =
        (retained!.intents.single.request as SoftDeleteMessageRequest).toJson();
    await first.dispose();

    final secondTransport = _ScriptedTransport()
      ..enqueueDelete((request) async =>
          _successResponse(_requestFrom(request), replayed: true));
    final second = _Fixture(
      storage: storage,
      store: NormalizedSnapshotStore(),
      transport: secondTransport,
      generatedKey: 'must-not-replace-key',
    );
    await second.activate();
    expect(second.client.queuedMessageDeletes.single.status,
        ChatQueuedMessageDeleteStatus.pending);
    await second.initialize();
    await _eventually(() => second.client.queuedMessageDeletes.isEmpty);

    expect(_requestFrom(secondTransport.deletes.single), exact);
    expect(secondTransport.deletes.single.headers['Idempotency-Key'],
        'restart-delete-key');
    expect(await _readMutations(storage, _identity), isNull);
    await second.dispose();
  });

  test('canonical deletion event and already-deleted restart settle exactly',
      () async {
    final eventStorage = InMemoryApplicationChatStorage();
    final eventStore = _seedStore();
    final response = Completer<HandrailChatHttpResponse>();
    final eventTransport = _ScriptedTransport()
      ..enqueueDelete((_) => response.future);
    final eventFixture = _Fixture(
      storage: eventStorage,
      store: eventStore,
      transport: eventTransport,
    );
    await eventFixture.activate();
    final pending =
        eventFixture.client.deleteMessage(_input('canonical-event-key'));
    await _eventually(() => eventTransport.deletes.length == 1);
    final tombstone = _deletedMessage(revision: 2);
    eventFixture.client.reduceDurableEvent(_messageDeletedEvent(tombstone));
    await _eventually(
        () async => await _readMutations(eventStorage, _identity) == null);
    response.complete(
        _successResponse(_requestFrom(eventTransport.deletes.single)));
    expect(await pending, isA<ChatCommandSuccess<SoftDeleteMessageResult>>());
    expect(eventStore.state.canonicalMessages[_messageId]?.toJson(),
        tombstone.toJson());
    await eventFixture.dispose();

    final deletedStorage = InMemoryApplicationChatStorage();
    await _seedDelete(deletedStorage, _request('already-deleted'));
    final deletedStore = _seedStore()..reconcileMessage(tombstone);
    final deletedTransport = _ScriptedTransport();
    final deletedFixture = _Fixture(
      storage: deletedStorage,
      store: deletedStore,
      transport: deletedTransport,
    );
    await deletedFixture.activate();
    await _eventually(() => deletedFixture.client.queuedMessageDeletes.isEmpty);
    expect(deletedTransport.deletes, isEmpty);
    expect(await _readMutations(deletedStorage, _identity), isNull);
    await deletedFixture.dispose();
  });

  test('terminal outcomes remove while transient outcomes retain', () async {
    final terminalCases = <HandrailChatHttpResponse>[
      _errorResponse(401, 'AUTHENTICATION_FAILED'),
      _errorResponse(403, 'AUTHENTICATION_FAILED'),
      _errorResponse(403, 'FEATURE_DISABLED'),
      _errorResponse(400, 'REJECTED'),
      _errorResponse(404, 'UNSUPPORTED'),
    ];
    for (final response in terminalCases) {
      final storage = InMemoryApplicationChatStorage();
      final transport = _ScriptedTransport()
        ..enqueueDelete((_) async => response);
      final fixture = _Fixture(
        storage: storage,
        store: _seedStore(),
        transport: transport,
      );
      await fixture.activate();
      expect(
        await fixture.client
            .deleteMessage(_input('terminal-${response.statusCode}')),
        isA<ChatCommandFailure<SoftDeleteMessageResult>>(),
      );
      expect(await _readMutations(storage, _identity), isNull);
      await fixture.dispose();
    }

    final conflictStorage = InMemoryApplicationChatStorage();
    final conflictTransport = _ScriptedTransport()
      ..enqueueDelete((_) async => HandrailChatHttpResponse(
            statusCode: 409,
            body: jsonEncode({
              'operation': 'soft_delete',
              'reconciliationStatus': 'revision_conflict',
              'expectedRevision': 1,
              'message': _activeMessage(revision: 3).toJson(),
              'canonicalRevision': 3,
            }),
          ));
    final conflict = _Fixture(
      storage: conflictStorage,
      store: _seedStore(),
      transport: conflictTransport,
    );
    await conflict.activate();
    final conflictResult =
        await conflict.client.deleteMessage(_input('server-conflict'));
    expect(conflictResult, isA<ChatCommandSuccess<SoftDeleteMessageResult>>());
    expect(
      (conflictResult as ChatCommandSuccess<SoftDeleteMessageResult>)
          .value
          .reconciliationStatus,
      SoftDeleteMessageReconciliationStatus.revisionConflict,
    );
    expect(await _readMutations(conflictStorage, _identity), isNull);
    await conflict.dispose();

    final transientCases = <String,
        Future<HandrailChatHttpResponse> Function(HandrailChatHttpRequest)>{
      'transport': (_) async => throw StateError('offline'),
      'rate-limit': (_) async => _errorResponse(429, 'RATE_LIMITED'),
      'server': (_) async => _errorResponse(503, 'SERVER_FAILED'),
      'malformed': (_) async => const HandrailChatHttpResponse(
            statusCode: 200,
            body: '{not-json',
          ),
    };
    for (final entry in transientCases.entries) {
      final storage = InMemoryApplicationChatStorage();
      final transport = _ScriptedTransport()..enqueueDelete(entry.value);
      final fixture = _Fixture(
        storage: storage,
        store: _seedStore(),
        transport: transport,
        retryWait: _NeverRetryWait().call,
      );
      await fixture.activate();
      final result =
          await fixture.client.deleteMessage(_input('${entry.key}-key'));
      expect(result, isA<ChatCommandFailure<SoftDeleteMessageResult>>(),
          reason: entry.key);
      expect((await _readMutations(storage, _identity))?.intents, hasLength(1),
          reason: entry.key);
      await fixture.dispose();
    }

    final cancelledStorage = InMemoryApplicationChatStorage();
    final started = Completer<void>();
    final never = Completer<HandrailChatHttpResponse>();
    final cancelledTransport = _ScriptedTransport()
      ..enqueueDelete((_) {
        started.complete();
        return never.future;
      });
    final cancelled = _Fixture(
      storage: cancelledStorage,
      store: _seedStore(),
      transport: cancelledTransport,
      retryWait: _NeverRetryWait().call,
    );
    await cancelled.activate();
    final cancellation = ChatCommandCancellationController();
    final pending = cancelled.client.deleteMessage(
      _input('cancel-after-dispatch'),
      cancellationSignal: cancellation.signal,
    );
    await started.future;
    cancellation.cancel();
    expect(await pending, isA<ChatCommandAborted<SoftDeleteMessageResult>>());
    expect((await _readMutations(cancelledStorage, _identity))?.intents,
        hasLength(1));
    await cancelled.dispose();
  });

  test('pre-dispatch cancellation removes, while close after dispatch retains',
      () async {
    final beforeBacking = InMemoryApplicationChatStorage();
    final beforeStorage = _BlockingMutationStorage(beforeBacking);
    final beforeTransport = _ScriptedTransport();
    final before = _Fixture(
      storage: beforeStorage,
      store: _seedStore(),
      transport: beforeTransport,
    );
    await before.activate();
    final cancellation = ChatCommandCancellationController();
    final beforePending = before.client.deleteMessage(
      _input('cancel-before-dispatch'),
      cancellationSignal: cancellation.signal,
    );
    await beforeStorage.replaceStarted.future;
    cancellation.cancel();
    beforeStorage.releaseReplace.complete();
    expect(await beforePending,
        isA<ChatCommandAborted<SoftDeleteMessageResult>>());
    expect(beforeTransport.deletes, isEmpty);
    expect(await _readMutations(beforeBacking, _identity), isNull);
    await before.dispose();

    final closeStorage = InMemoryApplicationChatStorage();
    final started = Completer<void>();
    final never = Completer<HandrailChatHttpResponse>();
    final closeTransport = _ScriptedTransport()
      ..enqueueDelete((_) {
        started.complete();
        return never.future;
      });
    final closing = _Fixture(
      storage: closeStorage,
      store: _seedStore(),
      transport: closeTransport,
    );
    await closing.activate();
    final closePending =
        closing.client.deleteMessage(_input('close-after-dispatch'));
    await started.future;
    await closing.client.dispose();
    expect(
        await closePending, isA<ChatCommandClosed<SoftDeleteMessageResult>>());
    expect(
        (await _readMutations(closeStorage, _identity))?.intents, hasLength(1));
    await closing.disposeDependencies();
  });

  test('recovery awaits authority and removes stale-base conflicts', () async {
    final missingStorage = InMemoryApplicationChatStorage();
    await _seedDelete(missingStorage, _request('missing-base'));
    final missingTransport = _ScriptedTransport()
      ..enqueueDelete(
          (request) async => _successResponse(_requestFrom(request)));
    final missing = _Fixture(
      storage: missingStorage,
      store: NormalizedSnapshotStore(),
      transport: missingTransport,
    );
    await missing.activate();
    await missing.initialize();
    expect(missingTransport.deletes, isEmpty);
    expect(missing.store.state.canonicalMessages[_messageId], isNull);
    expect(missing.client.queuedMessageDeletes.single.status,
        ChatQueuedMessageDeleteStatus.waitingForCanonicalBase);
    missing.store.reconcileMessage(_activeMessage());
    await _eventually(
      () => missingTransport.deletes.length == 1,
      diagnostic: () =>
          'missing-base dispatches=${missingTransport.deletes.length} '
          'queued=${missing.client.queuedMessageDeletes.map((value) => value.status).toList()} '
          'message=${missing.store.state.canonicalMessages[_messageId]?.runtimeType}',
    );
    await _eventually(
      () => missing.client.queuedMessageDeletes.isEmpty,
      diagnostic: () => 'missing-base retained after HTTP success',
    );
    await missing.dispose();

    final staleStorage = InMemoryApplicationChatStorage();
    await _seedDelete(staleStorage, _request('stale-base'));
    final staleTransport = _ScriptedTransport();
    final stale = _Fixture(
      storage: staleStorage,
      store: _seedStore(revision: 3),
      transport: staleTransport,
    );
    await stale.activate();
    await _eventually(
      () => stale.client.queuedMessageDeletes.isEmpty,
      diagnostic: () => 'stale-base queued='
          '${stale.client.queuedMessageDeletes.map((value) => value.status).toList()}',
    );
    expect(staleTransport.deletes, isEmpty);
    expect(await _readMutations(staleStorage, _identity), isNull);
    expect(
        stale.store.state.canonicalMessages[_messageId]?.revision.revision, 3);
    await stale.dispose();
  });

  test('offline and background pause replay until connected foreground',
      () async {
    final storage = InMemoryApplicationChatStorage();
    await _seedDelete(storage, _request('lifecycle-key'));
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
      ..enqueueDelete(
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
    expect(transport.deletes, isEmpty);
    fixture.client.setApplicationForeground(false);
    await session.start();
    network.setOnline(true);
    await _eventually(() => socketFactory.uris.length == 1);
    socket.emitJson(_acceptedFrame());
    await _eventually(() => session.state is ChatRealtimeConnectedState);
    expect(transport.deletes, isEmpty);
    fixture.client.setApplicationForeground(true);
    await _eventually(() => transport.deletes.length == 1);
    await _eventually(() => fixture.client.queuedMessageDeletes.isEmpty);
    await fixture.dispose();
  });

  test('bounded injectable retry waits before replay', () async {
    final storage = InMemoryApplicationChatStorage();
    await _seedDelete(storage, _request('retry-key'));
    final waits = _ManualRetryWait();
    final transport = _ScriptedTransport()
      ..enqueueDelete((_) async => throw StateError('offline'))
      ..enqueueDelete(
          (request) async => _successResponse(_requestFrom(request)));
    final fixture = _Fixture(
      storage: storage,
      store: _seedStore(),
      transport: transport,
      retryBackoff: (attempt) => Duration(milliseconds: attempt * 9),
      retryWait: waits.call,
    );
    await fixture.activate();
    await fixture.initialize();
    await _eventually(() => waits.delays.length == 1);
    expect(waits.delays, [const Duration(milliseconds: 9)]);
    expect(transport.deletes, hasLength(1));
    waits.release(0);
    await _eventually(() => fixture.client.queuedMessageDeletes.isEmpty);
    expect(transport.deletes, hasLength(2));
    await fixture.dispose();
  });

  test('edit and delete share one atomic mutation-record writer', () async {
    const editedMessageId = MessageId('message-2');
    final backing = InMemoryApplicationChatStorage();
    final storage = _BlockingMutationStorage(backing);
    final store = _seedStore()
      ..reconcileMessage(_activeMessage(
        messageId: editedMessageId,
        sequence: 2,
      ));
    final transport = _ScriptedTransport()
      ..enqueuePatch((_) async => throw StateError('offline edit'))
      ..enqueueDelete((_) async => throw StateError('offline delete'));
    final fixture = _Fixture(
      storage: storage,
      store: store,
      transport: transport,
      editRetryWait: _NeverRetryWait().call,
      retryWait: _NeverRetryWait().call,
    );
    await fixture.activate();
    final editPending = fixture.client.editMessage(ChatEditMessageInput(
      messageId: editedMessageId,
      expectedRevision: 1,
      content: MessageContent(
        format: MessageContentFormat.plain,
        text: 'retained edit',
      ),
      idempotencyKey: 'edit-key',
    ));
    await storage.replaceStarted.future;
    final deletePending =
        fixture.client.deleteMessage(_input('delete-key-shared-record'));
    await Future<void>.delayed(Duration.zero);
    expect(storage.mutationReplaceStarts, 1,
        reason: 'the delete waits behind the edit read-modify-write');
    storage.releaseReplace.complete();
    expect(await editPending,
        isA<ChatCommandTransportFailure<EditMessageResult>>());
    expect(await deletePending,
        isA<ChatCommandTransportFailure<SoftDeleteMessageResult>>());
    final retained = await _readMutations(backing, _identity);
    expect(retained?.intents, hasLength(2));
    expect(retained?.intents.map((intent) => intent.operation).toSet(),
        {'edit', 'soft_delete'});
    await fixture.dispose();
  });

  test('delete settlement preserves unrelated retained mutation intents',
      () async {
    const editedMessageId = MessageId('message-2');
    final storage = InMemoryApplicationChatStorage();
    final retainedEdit = EditMessageRequest.fromJson({
      'operation': 'edit',
      'messageId': editedMessageId.toJson(),
      'expectedRevision': 1,
      'content': MessageContent(
        format: MessageContentFormat.plain,
        text: 'unrelated retained edit',
      ).toJson(),
      'idempotencyKey': 'unrelated-edit-key',
    });
    await storage.replace(ApplicationChatQueuedMessageMutationIntentsRecord(
      identity: _identity,
      intents: [
        ApplicationChatQueuedMessageMutationIntent(
          request: retainedEdit,
          enqueueOrder: 1,
          enqueuedAt: const IsoTimestamp('2032-02-01T00:00:00.000Z'),
        ),
      ],
    ));
    final store = _seedStore()
      ..reconcileMessage(_activeMessage(
        messageId: editedMessageId,
        sequence: 2,
      ));
    final transport = _ScriptedTransport()
      ..enqueueDelete(
          (request) async => _successResponse(_requestFrom(request)));
    final fixture = _Fixture(
      storage: storage,
      store: store,
      transport: transport,
    );
    await fixture.activate();
    expect(
      await fixture.client.deleteMessage(_input('settled-delete-key')),
      isA<ChatCommandSuccess<SoftDeleteMessageResult>>(),
    );
    final retained = await _readMutations(storage, _identity);
    expect(retained?.intents, hasLength(1));
    expect(retained?.intents.single.request, isA<EditMessageRequest>());
    expect(
      (retained?.intents.single.request as EditMessageRequest).toJson(),
      retainedEdit.toJson(),
    );
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
    final pending = fixture.client.deleteMessage(_input('old-identity'));
    await storage.replaceStarted.future;
    final replacement = fixture.client.activateStorageIdentity(_otherIdentity);
    storage.releaseReplace.complete();
    expect(await pending, isA<ChatCommandClosed<SoftDeleteMessageResult>>());
    await replacement;
    expect(fixture.transport.deletes, isEmpty);
    expect(fixture.client.queuedMessageDeletes, isEmpty);
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
        disposing.client.deleteMessage(_input('dispose-during-write'));
    await disposeStorage.replaceStarted.future;
    final close = disposing.client.dispose();
    disposeStorage.releaseReplace.complete();
    expect(await disposePending,
        isA<ChatCommandClosed<SoftDeleteMessageResult>>());
    await close;
    expect(disposing.transport.deletes, isEmpty);
    expect((await _readMutations(disposeBacking, _identity))?.intents,
        hasLength(1));
    await disposing.disposeDependencies();
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
        request: ForwardMessageRequest.fromJson({
          'operation': 'forward_message.v1',
          'sourceMessageId': 'unrelated-source',
          'destinationConversationId': 'other-conversation',
          'clientCorrelationId': 'concurrent-forward-correlation',
          'idempotencyKey': 'concurrent-forward',
        }),
        enqueueOrder: 8,
        enqueuedAt: const IsoTimestamp('2032-02-01T00:00:00.000Z'),
      ),
      ApplicationChatQueuedMessageMutationIntent(
        request: ReactionMutationInput.fromJson({
          'operation': 'add_reaction',
          'messageId': 'unrelated-message',
          'reactionKey': 'thumbsup',
          'idempotencyKey': 'concurrent-reaction',
        }),
        enqueueOrder: 9,
        enqueuedAt: const IsoTimestamp('2032-02-01T00:00:00.000Z'),
      ),
    ];

/// Models another storage writer after a read but before the next write.
/// Legacy writes also run the hook so lost-update regressions fail on old code.
final class _InterleavingMutationStorage
    implements AtomicApplicationChatStorage {
  _InterleavingMutationStorage(this.backing);
  final InMemoryApplicationChatStorage backing;
  Future<void> Function()? beforeWrite;
  void Function(int)? beforeRead;
  int mutationReads = 0;
  int failedExchanges = 0;

  void _onRead(ApplicationChatStorageRecordKind kind) {
    if (kind == _mutationKind) beforeRead?.call(++mutationReads);
  }

  Future<void> _onWrite(ApplicationChatStorageRecordKind kind) async {
    if (kind != _mutationKind) return;
    final hook = beforeWrite;
    beforeWrite = null;
    await hook?.call();
  }

  @override
  Future<String?> readEncoded(ApplicationChatStorageIdentity identity,
      ApplicationChatStorageRecordKind kind) {
    _onRead(kind);
    return backing.readEncoded(identity, kind);
  }

  @override
  Future<ApplicationChatStorageRecord?> read(
      ApplicationChatStorageIdentity identity,
      ApplicationChatStorageRecordKind kind) {
    _onRead(kind);
    return backing.read(identity, kind);
  }

  @override
  Future<bool> compareExchange(
      ApplicationChatStorageIdentity identity,
      ApplicationChatStorageRecordKind kind,
      String? expected,
      String? replacement) async {
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
    required this.store,
    required this.transport,
    HandrailChatAccessTokenProvider? tokenProvider,
    ChatClientDiagnosticCallback? onStorageDiagnostic,
    String generatedKey = 'generated-key',
    ChatMessageDeleteRetryBackoff? retryBackoff,
    ChatMessageDeleteRetryWait? retryWait,
    ChatMessageEditRetryWait? editRetryWait,
    this.realtimeSession,
    this.network,
  }) {
    client = HandrailChatClient(
      apiBaseUri: Uri.parse('https://chat.example.test/api/chat'),
      tokenProvider: tokenProvider ?? () async => 'access-token',
      transport: transport,
      localStorage: storage,
      onStorageDiagnostic: onStorageDiagnostic,
      storageIdentity: _identity,
      normalizedSnapshotStore: store,
      realtimeSession: realtimeSession,
      generateIdempotencyKey: () => generatedKey,
      commandRetryOptions: const ChatCommandRetryOptions(
        maxAttempts: 1,
        maxAuthenticationRefreshes: 0,
      ),
      messageDeleteClock: () => DateTime.utc(2032, 2, 1),
      messageDeleteRetryBackoff: retryBackoff,
      messageDeleteRetryWait: retryWait,
      messageEditRetryWait: editRetryWait,
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
      _deleteHandlers = Queue();
  final Queue<
          Future<HandrailChatHttpResponse> Function(HandrailChatHttpRequest)>
      _patchHandlers = Queue();
  final List<HandrailChatHttpRequest> requests = [];

  Iterable<HandrailChatHttpRequest> get deletes =>
      requests.where((request) => request.method == 'DELETE');

  void enqueueDelete(
    Future<HandrailChatHttpResponse> Function(HandrailChatHttpRequest) handler,
  ) =>
      _deleteHandlers.add(handler);

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
    if (request.method == 'PATCH') {
      if (_patchHandlers.isEmpty) {
        return Future.error(StateError('No scripted PATCH response remains.'));
      }
      return _patchHandlers.removeFirst()(request);
    }
    if (_deleteHandlers.isEmpty) {
      return Future.error(StateError('No scripted DELETE response remains.'));
    }
    return _deleteHandlers.removeFirst()(request);
  }
}

final class _BlockingMutationStorage implements ApplicationChatStorage {
  _BlockingMutationStorage(this.backing);

  final InMemoryApplicationChatStorage backing;
  final Completer<void> replaceStarted = Completer<void>();
  final Completer<void> releaseReplace = Completer<void>();
  int mutationReplaceStarts = 0;

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
      mutationReplaceStarts += 1;
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

ChatDeleteMessageInput _input(String key) => ChatDeleteMessageInput(
      messageId: _messageId,
      expectedRevision: 1,
      idempotencyKey: key,
    );

SoftDeleteMessageRequest _request(String key) =>
    SoftDeleteMessageRequest.fromJson({
      'operation': 'soft_delete',
      'messageId': _messageId.toJson(),
      'expectedRevision': 1,
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
        'operation': 'soft_delete',
        'reconciliationStatus': replayed ? 'replayed' : 'applied',
        'expectedRevision': request['expectedRevision'],
        'message': _deletedMessage(revision: 2).toJson(),
        'canonicalRevision': 2,
      }),
    );

HandrailChatHttpResponse _errorResponse(int status, String code) =>
    HandrailChatHttpResponse(
      statusCode: status,
      body: jsonEncode({
        'error': {'code': code, 'message': 'request failed'},
      }),
    );

ActiveMessage _activeMessage({
  int revision = 1,
  MessageId messageId = _messageId,
  int sequence = 1,
}) =>
    ActiveMessage(
      id: messageId,
      tenantId: _identity.tenantId,
      conversationId: _conversationId,
      author: const MessageAuthorIdentity(userId: UserId('user-1')),
      sequence: MessageSequence(sequence),
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
      content: MessageContent(
        format: MessageContentFormat.plain,
        text: revision == 1 ? 'canonical message' : 'newer canonical message',
      ),
    );

DeletedMessage _deletedMessage({required int revision}) => DeletedMessage(
      id: _messageId,
      tenantId: _identity.tenantId,
      conversationId: _conversationId,
      author: const MessageAuthorIdentity(userId: UserId('user-1')),
      sequence: const MessageSequence(1),
      createdAt: const IsoTimestamp('2032-02-01T00:00:01.000Z'),
      updatedAt: const IsoTimestamp('2032-02-01T00:00:05.000Z'),
      revision: MessageRevisionMetadata(
        revision: revision,
        editedAt: null,
        editedByUserId: null,
      ),
      content: null,
      deletedAt: const IsoTimestamp('2032-02-01T00:00:05.000Z'),
      deletedByUserId: const UserId('user-1'),
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
        'name': 'Durable deletes',
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
  store.reconcileMessage(_activeMessage(revision: revision));
  return store;
}

KnownDurableEvent _messageDeletedEvent(DeletedMessage message) =>
    KnownDurableEvent.fromJson(
      {
        'eventId': 'delete-event-1',
        'protocolVersion': handrailChatProtocolVersion,
        'tenantId': _identity.tenantId.toJson(),
        'streamId': _conversationId.toJson(),
        'type': 'message.deleted',
        'occurredAt': '2032-02-01T00:00:05.000Z',
        'payload': {'message': message.toJson()},
      },
      trustedIdentity: DurableEventTrustedIdentity(
        tenantId: _identity.tenantId,
        userId: _identity.userId,
      ),
    );

Future<void> _seedDelete(
  ApplicationChatStorage storage,
  SoftDeleteMessageRequest request,
) =>
    storage.replace(ApplicationChatQueuedMessageMutationIntentsRecord(
      identity: _identity,
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

Future<ApplicationChatQueuedMessageMutationIntentsRecord?> _readMutations(
  ApplicationChatStorage storage,
  ApplicationChatStorageIdentity identity,
) async =>
    await storage.read(
      identity,
      ApplicationChatStorageRecordKind.queuedMessageMutationIntents,
    ) as ApplicationChatQueuedMessageMutationIntentsRecord?;

Future<void> _eventually(
  FutureOr<bool> Function() predicate, {
  String Function()? diagnostic,
}) async {
  for (var attempt = 0; attempt < 300; attempt += 1) {
    if (await predicate()) return;
    await Future<void>.delayed(Duration.zero);
  }
  fail(diagnostic?.call() ?? 'Condition was not reached.');
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
