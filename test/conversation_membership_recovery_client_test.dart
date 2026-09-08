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

import 'fixtures/conversation_membership_fixtures.dart';

final _identity = ApplicationChatStorageIdentity(
  tenantId: const TenantId('tenant-1'),
  userId: const UserId('user-actor'),
  deviceId: const DeviceId('device-1'),
);
final _otherIdentity = ApplicationChatStorageIdentity(
  tenantId: const TenantId('tenant-1'),
  userId: const UserId('user-other'),
  deviceId: const DeviceId('device-2'),
);

void main() {
  for (final scenario in ['distinct lanes', 'same lane', 'equivalent']) {
    test('atomic concurrent membership enqueue preserves $scenario', () async {
      final backing = InMemoryApplicationChatStorage();
      final storage = _InterleavingMembershipStorage(backing);
      final first = _Fixture(
        storage: storage,
        store: _storeFor({'conversation-1': 4, 'conversation-2': 4}),
        transport: _MembershipTransport(),
        generatedKeys: Queue.of(['first']),
      );
      final second = _Fixture(
        storage: storage,
        store: _storeFor({'conversation-1': 4, 'conversation-2': 4}),
        transport: _MembershipTransport(),
        generatedKeys: Queue.of(['second']),
      );
      addTearDown(first.dispose);
      addTearDown(second.dispose);
      await first.activate();
      await second.activate();
      final proposed = Completer<void>();
      final release = Completer<void>();
      storage.beforeWrite = () async {
        proposed.complete();
        await release.future;
      };
      final firstPending = first.client.leaveConversation(
        const ChatLeaveConversationInput(
          conversationId: ConversationId('conversation-1'),
          expectedMemberListRevision: 4,
        ),
      );
      await proposed.future;
      expect(first.client.queuedConversationMemberships, isEmpty);
      expect(first.transport.patches, isEmpty);
      final secondPending = scenario == 'same lane'
          ? second.client.joinConversation(const ChatJoinConversationInput(
              conversationId: ConversationId('conversation-1'),
              expectedMemberListRevision: 4,
            ))
          : second.client.leaveConversation(ChatLeaveConversationInput(
              conversationId: ConversationId(
                scenario == 'distinct lanes'
                    ? 'conversation-2'
                    : 'conversation-1',
              ),
              expectedMemberListRevision: 4,
            ));
      await _eventually(
          () => second.client.queuedConversationMemberships.length == 1);
      release.complete();
      await _eventually(
          () => first.client.queuedConversationMemberships.isNotEmpty);
      final record = (await _readMemberships(backing, _identity))!;
      expect(record.intents.map((intent) => intent.request.idempotencyKey),
          scenario == 'equivalent' ? ['second'] : ['second', 'first']);
      expect(record.intents.map((intent) => intent.enqueueOrder),
          scenario == 'equivalent' ? [1] : [1, 2]);
      expect(
          first.client.queuedConversationMemberships
              .map((intent) => intent.request.toJson()),
          record.intents.map((intent) => intent.request.toJson()));
      expect(storage.failedExchanges, 1);
      expect(first.transport.patches, isEmpty);
      expect(second.transport.patches, isEmpty);
      await first.dispose();
      await second.dispose();
      expect(await firstPending,
          isA<ChatCommandClosed<ConversationMembershipMutationResult>>());
      expect(await secondPending,
          isA<ChatCommandClosed<ConversationMembershipMutationResult>>());
    });
  }

  for (final canonical in [false, true]) {
    for (final changed in ['unrelated only', 'request', 'order', 'time']) {
      test(
          'atomic ${canonical ? 'canonical' : 'HTTP'} settlement preserves $changed',
          () async {
        final backing = InMemoryApplicationChatStorage();
        final storage = _InterleavingMembershipStorage(backing);
        final response = Completer<HandrailChatHttpResponse>();
        final fixture = _Fixture(
          storage: storage,
          store: _storeFor({'conversation-1': 4}),
          transport: _MembershipTransport(patch: (_) => response.future),
          generatedKeys: Queue.of(['settling']),
        );
        addTearDown(fixture.dispose);
        await fixture.activate();
        await fixture.initialize();
        final pending = fixture.client.addConversationMember(
          const ChatAddConversationMemberInput(
            conversationId: ConversationId('conversation-1'),
            targetUserId: UserId('user-c'),
            requestedRole: ConversationMembershipMemberRole.moderator,
            expectedMemberListRevision: 4,
          ),
        );
        var completed = false;
        unawaited(pending.then((_) {
          completed = true;
        }));
        await _eventually(() => fixture.transport.patches.isNotEmpty);
        final original =
            (await _readMemberships(backing, _identity))!.intents.single;
        final unrelated = ApplicationChatQueuedConversationMembershipIntent(
          request: _request('leave', 'conversation-2', 'unrelated'),
          enqueueOrder: 9,
          enqueuedAt: const IsoTimestamp('2032-02-01T00:00:09.000Z'),
        );
        final replacement =
            ApplicationChatQueuedConversationMembershipIntentsRecord(
          identity: _identity,
          intents: [
            if (changed != 'unrelated only')
              ApplicationChatQueuedConversationMembershipIntent(
                request: changed == 'request'
                    ? _request('add_member', 'conversation-1', 'settling',
                        revision: 5)
                    : original.request,
                enqueueOrder: changed == 'order' ? 3 : original.enqueueOrder,
                enqueuedAt: changed == 'time'
                    ? const IsoTimestamp('2032-02-01T00:00:03.000Z')
                    : original.enqueuedAt,
              ),
            unrelated,
          ],
        );
        storage.beforeWrite = () async {
          if (!canonical) fixture.client.setApplicationForeground(false);
          await backing
              .replace(ApplicationChatQueuedConversationMembershipIntentsRecord(
            identity: _identity,
            intents: changed == 'unrelated only'
                ? [original, unrelated]
                : replacement.intents,
          ));
        };
        if (canonical) {
          fixture.client
              .reduceDurableEvent(_membershipEvent(original.request.toJson()));
        } else {
          response.complete(_success(original.request.toJson()));
          expect(await pending,
              isA<ChatCommandSuccess<ConversationMembershipMutationResult>>());
        }
        await _eventually(() => fixture.client.queuedConversationMemberships
            .any((intent) => intent.request.idempotencyKey == 'unrelated'));
        expect((await _readMemberships(backing, _identity))!.encode(),
            replacement.encode());
        expect(storage.failedExchanges, 1);
        if (canonical) {
          // A stale canonical success must not resolve the replacement's waiter.
          await Future<void>.delayed(Duration.zero);
          expect(completed, changed == 'unrelated only');
        }
        await fixture.dispose();
        await pending;
      });
    }
  }

  test('atomic malformed quarantine preserves a concurrent valid record',
      () async {
    final backing = InMemoryApplicationChatStorage();
    final storage = _InterleavingMembershipStorage(backing);
    backing.putRawRecordForTesting(
        _identity, _membershipKind, {'accessToken': 'secret'});
    final diagnostics = <ChatClientDiagnostic>[];
    final fixture = _Fixture(
      storage: storage,
      store: _storeFor({'conversation-1': 4}),
      transport: _MembershipTransport(),
      onStorageDiagnostic: diagnostics.add,
    );
    addTearDown(fixture.dispose);
    storage.beforeWrite = () => _seedMemberships(backing, [
          _request('leave', 'conversation-1', 'valid-replacement'),
        ]);
    await fixture.activate();
    expect(
        (await _readMemberships(backing, _identity))!
            .intents
            .single
            .request
            .idempotencyKey,
        'valid-replacement');
    expect(fixture.client.queuedConversationMemberships, isEmpty);
    expect(storage.failedExchanges, 1);
    expect(diagnostics.single.code,
        ChatClientDiagnosticCode.membershipIntentsRejected);
    expect(diagnostics.single.toString(), isNot(contains('secret')));
    final restarted = _Fixture(
      storage: storage,
      store: _storeFor({'conversation-1': 4}),
      transport: _MembershipTransport(),
    );
    addTearDown(restarted.dispose);
    await restarted.activate();
    expect(
        restarted
            .client.queuedConversationMemberships.single.request.idempotencyKey,
        'valid-replacement');
  });

  test('persists before lane visibility, token access, or membership transport',
      () async {
    final backing = InMemoryApplicationChatStorage();
    final storage = _BlockingMembershipStorage(backing);
    final transport = _MembershipTransport();
    var tokenCalls = 0;
    final fixture = _Fixture(
      storage: storage,
      store: _storeFor({'conversation-1': 4}),
      transport: transport,
      tokenProvider: () async {
        tokenCalls += 1;
        return 'token';
      },
      generatedKeys: Queue.of(['persist-first']),
    );
    await fixture.activate();

    final pending = fixture.client.joinConversation(
      const ChatJoinConversationInput(
        conversationId: ConversationId('conversation-1'),
        expectedMemberListRevision: 4,
      ),
    );
    await storage.replaceStarted.future;
    expect(fixture.client.queuedConversationMemberships, isEmpty);
    expect(tokenCalls, 0);
    expect(transport.patches, isEmpty);

    storage.releaseReplace.complete();
    await _eventually(
      () => fixture.client.queuedConversationMemberships.length == 1,
    );
    expect(transport.patches, isEmpty, reason: 'metadata is not ready');
    await fixture.initialize();
    expect(await pending,
        isA<ChatCommandSuccess<ConversationMembershipMutationResult>>());
    expect(_body(transport.patches.single)['idempotencyKey'], 'persist-first');
    expect(await _readMemberships(backing, _identity), isNull);
    await fixture.dispose();
  });

  test('restart replays all five exact requests and preserves FIFO per lane',
      () async {
    final storage = InMemoryApplicationChatStorage();
    final requests = <ConversationMembershipMutationInput>[
      _request('join', 'conversation-1', 'key-join'),
      _request('leave', 'conversation-2', 'key-leave'),
      _request('add_member', 'conversation-3', 'key-add'),
      _request('remove_member', 'conversation-4', 'key-remove'),
      _request('change_member_role', 'conversation-5', 'key-role'),
    ];
    await _seedMemberships(storage, requests);
    final transport = _MembershipTransport();
    final fixture = _Fixture(
      storage: storage,
      store: _storeFor(
        {for (var i = 1; i <= 5; i++) 'conversation-$i': 4},
        joinPending: {'conversation-1'},
        includeUserC: {'conversation-4'},
      ),
      transport: transport,
      generatedKeys: Queue.of(['must-not-replace']),
    );
    await fixture.activate();
    expect(
      fixture.client.queuedConversationMemberships
          .map((intent) => intent.request.toJson()),
      requests.map((request) => request.toJson()),
    );
    await fixture.initialize();
    await _eventually(
        () => fixture.client.queuedConversationMemberships.isEmpty);

    expect(
      transport.patches
          .map(_body)
          .map((json) => json['idempotencyKey'])
          .toSet(),
      {'key-join', 'key-leave', 'key-add', 'key-remove', 'key-role'},
    );
    for (final request in requests) {
      final sent = transport.patches.singleWhere(
        (wire) => _body(wire)['idempotencyKey'] == request.idempotencyKey,
      );
      expect(_body(sent), request.toJson());
      expect(sent.headers['Idempotency-Key'], request.idempotencyKey);
    }
    await fixture.dispose();

    final orderedStorage = InMemoryApplicationChatStorage();
    final first = _request('leave', 'conversation-1', 'fifo-1');
    final second = _request('join', 'conversation-1', 'fifo-2', revision: 5);
    final unrelated = _request('leave', 'conversation-2', 'independent');
    await _seedMemberships(orderedStorage, [first, second, unrelated]);
    final firstResponse = Completer<HandrailChatHttpResponse>();
    final orderedTransport = _MembershipTransport(
      patch: (request) {
        final body = _body(request);
        if (body['idempotencyKey'] == 'fifo-1') return firstResponse.future;
        return Future.value(_success(body));
      },
    );
    final ordered = _Fixture(
      storage: orderedStorage,
      store: _storeFor({'conversation-1': 4, 'conversation-2': 4}),
      transport: orderedTransport,
    );
    await ordered.activate();
    await ordered.initialize();
    await _eventually(() => orderedTransport.patches.length == 2);
    expect(
      orderedTransport.patches.map(_body).map((body) => body['idempotencyKey']),
      containsAll(['fifo-1', 'independent']),
    );
    expect(
      orderedTransport.patches.map(_body).map((body) => body['idempotencyKey']),
      isNot(contains('fifo-2')),
    );
    firstResponse.complete(_success(first.toJson()));
    await _eventually(() => orderedTransport.patches.length == 3);
    expect(_body(orderedTransport.patches.last)['idempotencyKey'], 'fifo-2');
    await _eventually(
        () => ordered.client.queuedConversationMemberships.isEmpty);
    await ordered.dispose();
  });

  test('canonical event and authoritative already-applied state settle work',
      () async {
    final eventStorage = InMemoryApplicationChatStorage();
    final response = Completer<HandrailChatHttpResponse>();
    final eventTransport = _MembershipTransport(
      patch: (_) => response.future,
    );
    final eventFixture = _Fixture(
      storage: eventStorage,
      store: _storeFor({'conversation-1': 4}),
      transport: eventTransport,
      generatedKeys: Queue.of(['event-first']),
    );
    await eventFixture.activate();
    await eventFixture.initialize();
    final pending = eventFixture.client.addConversationMember(
      const ChatAddConversationMemberInput(
        conversationId: ConversationId('conversation-1'),
        targetUserId: UserId('user-c'),
        requestedRole: ConversationMembershipMemberRole.moderator,
        expectedMemberListRevision: 4,
      ),
    );
    await _eventually(() => eventTransport.patches.length == 1);
    final input = _body(eventTransport.patches.single);
    eventFixture.client.reduceDurableEvent(_membershipEvent(input));
    expect(await pending,
        isA<ChatCommandSuccess<ConversationMembershipMutationResult>>());
    await _eventually(
      () async => await _readMemberships(eventStorage, _identity) == null,
    );
    expect(eventTransport.patches, hasLength(1));
    await eventFixture.dispose();

    final appliedStorage = InMemoryApplicationChatStorage();
    final applied = _request('join', 'conversation-1', 'already-applied');
    await _seedMemberships(appliedStorage, [applied]);
    final appliedTransport = _MembershipTransport();
    final appliedFixture = _Fixture(
      storage: appliedStorage,
      store: _storeFor({'conversation-1': 4}),
      transport: appliedTransport,
    );
    await appliedFixture.activate();
    await appliedFixture.initialize();
    await _eventually(
      () => appliedFixture.client.queuedConversationMemberships.isEmpty,
    );
    expect(appliedTransport.patches, isEmpty);
    expect(await _readMemberships(appliedStorage, _identity), isNull);
    await appliedFixture.dispose();

    final hydrateStorage = InMemoryApplicationChatStorage();
    await _seedMemberships(
      hydrateStorage,
      [_request('leave', 'conversation-1', 'hydrate-first')],
    );
    final hydrateTransport = _MembershipTransport();
    final hydrateFixture = _Fixture(
      storage: hydrateStorage,
      store: NormalizedSnapshotStore(),
      transport: hydrateTransport,
    );
    await hydrateFixture.activate();
    await hydrateFixture.initialize();
    await _eventually(() => hydrateTransport.patches.length == 1);
    expect(hydrateTransport.authorityGets, 1);
    expect(
      hydrateFixture.store
          .conversation(const ConversationId('conversation-1'))
          .memberListRevision,
      100,
    );
    await _eventually(
      () => hydrateFixture.client.queuedConversationMemberships.isEmpty,
    );
    await hydrateFixture.dispose();
  });

  test('retains acknowledgement ambiguity but removes terminal after refresh',
      () async {
    final transientStorage = InMemoryApplicationChatStorage();
    final transientTransport = _MembershipTransport(
      patch: (_) async => throw StateError('offline'),
    );
    final transient = _Fixture(
      storage: transientStorage,
      store: _storeFor({'conversation-1': 4}),
      transport: transientTransport,
      retryWait: _NeverRetryWait().call,
      generatedKeys: Queue.of(['transport-key']),
    );
    await transient.activate();
    await transient.initialize();
    expect(
      await transient.client.joinConversation(
        const ChatJoinConversationInput(
          conversationId: ConversationId('conversation-1'),
          expectedMemberListRevision: 4,
        ),
      ),
      isA<ChatCommandTransportFailure<ConversationMembershipMutationResult>>(),
    );
    expect((await _readMemberships(transientStorage, _identity))?.intents,
        hasLength(1));
    await transient.dispose();

    final cancellationStorage = InMemoryApplicationChatStorage();
    final started = Completer<void>();
    final cancellationTransport = _MembershipTransport(
      patch: (_) {
        if (!started.isCompleted) started.complete();
        return Completer<HandrailChatHttpResponse>().future;
      },
    );
    final cancellation = _Fixture(
      storage: cancellationStorage,
      store: _storeFor({'conversation-1': 4}),
      transport: cancellationTransport,
      generatedKeys: Queue.of(['cancel-key']),
    );
    await cancellation.activate();
    await cancellation.initialize();
    final controller = ChatCommandCancellationController();
    final cancelled = cancellation.client.joinConversation(
      const ChatJoinConversationInput(
        conversationId: ConversationId('conversation-1'),
        expectedMemberListRevision: 4,
      ),
      cancellationSignal: controller.signal,
    );
    await started.future;
    controller.cancel();
    expect(await cancelled,
        isA<ChatCommandAborted<ConversationMembershipMutationResult>>());
    expect((await _readMemberships(cancellationStorage, _identity))?.intents,
        hasLength(1));
    await cancellation.dispose();

    final closeStorage = InMemoryApplicationChatStorage();
    final closeStarted = Completer<void>();
    final closeTransport = _MembershipTransport(
      patch: (_) {
        if (!closeStarted.isCompleted) closeStarted.complete();
        return Completer<HandrailChatHttpResponse>().future;
      },
    );
    final closing = _Fixture(
      storage: closeStorage,
      store: _storeFor({'conversation-1': 4}),
      transport: closeTransport,
      generatedKeys: Queue.of(['close-key']),
    );
    await closing.activate();
    await closing.initialize();
    final closePending = closing.client.joinConversation(
      const ChatJoinConversationInput(
        conversationId: ConversationId('conversation-1'),
        expectedMemberListRevision: 4,
      ),
    );
    await closeStarted.future;
    await closing.client.dispose();
    expect(await closePending,
        isA<ChatCommandClosed<ConversationMembershipMutationResult>>());
    expect((await _readMemberships(closeStorage, _identity))?.intents,
        hasLength(1));
    await closing.store.close();

    final terminalStorage = InMemoryApplicationChatStorage();
    final terminalTransport = _MembershipTransport(
      patch: (_) async => _error(403, 'PERMISSION_DENIED'),
    );
    final terminal = _Fixture(
      storage: terminalStorage,
      store: _storeFor({'conversation-1': 4}),
      transport: terminalTransport,
      generatedKeys: Queue.of(['terminal-key']),
    );
    await terminal.activate();
    await terminal.initialize();
    expect(
      await terminal.client.joinConversation(
        const ChatJoinConversationInput(
          conversationId: ConversationId('conversation-1'),
          expectedMemberListRevision: 4,
        ),
      ),
      isA<
          ChatCommandAuthenticationFailure<
              ConversationMembershipMutationResult>>(),
    );
    expect(terminalTransport.authorityGets, 1);
    expect(await _readMemberships(terminalStorage, _identity), isNull);
    await terminal.dispose();
  });

  test('offline, background, and realtime identity readiness gate replay',
      () async {
    final storage = InMemoryApplicationChatStorage();
    await _seedMemberships(
      storage,
      [_request('leave', 'conversation-1', 'lifecycle-key')],
    );
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
    final transport = _MembershipTransport();
    final fixture = _Fixture(
      storage: storage,
      store: _storeFor({'conversation-1': 4}),
      transport: transport,
      realtimeSession: session,
      network: network,
    );
    await fixture.activate();
    await fixture.initialize();
    expect(transport.patches, isEmpty, reason: 'offline');
    fixture.client.setApplicationForeground(false);
    await session.start();
    network.setOnline(true);
    await _eventually(() => socketFactory.uris.length == 1);
    socket.emitJson(_acceptedFrame());
    await _eventually(() => session.state is ChatRealtimeConnectedState);
    expect(transport.patches, isEmpty, reason: 'backgrounded');
    fixture.client.setApplicationForeground(true);
    await _eventually(() => transport.patches.length == 1);
    await _eventually(
        () => fixture.client.queuedConversationMemberships.isEmpty);
    await fixture.dispose();
  });

  test('quarantines corrupt active record and isolates delayed old identity',
      () async {
    final corrupt = InMemoryApplicationChatStorage();
    final valid = ApplicationChatQueuedConversationMembershipIntentsRecord(
      identity: _identity,
      intents: [
        ApplicationChatQueuedConversationMembershipIntent(
          request: _request('join', 'conversation-1', 'corrupt-key'),
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
      ApplicationChatStorageRecordKind.queuedConversationMembershipIntents,
      valid,
    );
    final diagnostics = <ChatClientDiagnostic>[];
    final corruptFixture = _Fixture(
      storage: corrupt,
      store: _storeFor({'conversation-1': 4}),
      transport: _MembershipTransport(),
      onStorageDiagnostic: diagnostics.add,
    );
    await corruptFixture.activate();
    expect(corruptFixture.client.queuedConversationMemberships, isEmpty);
    expect(diagnostics.single.code,
        ChatClientDiagnosticCode.membershipIntentsRejected);
    expect(diagnostics.single.toString(), isNot(contains('secret')));
    expect(await _readMemberships(corrupt, _identity), isNull);
    await corruptFixture.dispose();

    final wrongIdentityStorage = _WrongIdentityMembershipStorage(
      ApplicationChatQueuedConversationMembershipIntentsRecord(
        identity: _otherIdentity,
        intents: [
          ApplicationChatQueuedConversationMembershipIntent(
            request: _request('join', 'conversation-1', 'wrong-identity'),
            enqueueOrder: 1,
            enqueuedAt: const IsoTimestamp('2032-02-01T00:00:00.000Z'),
          ),
        ],
      ),
    );
    final wrongDiagnostics = <ChatClientDiagnostic>[];
    final wrongIdentity = _Fixture(
      storage: wrongIdentityStorage,
      store: _storeFor({'conversation-1': 4}),
      transport: _MembershipTransport(),
      onStorageDiagnostic: wrongDiagnostics.add,
    );
    await wrongIdentity.activate();
    expect(wrongIdentity.client.queuedConversationMemberships, isEmpty);
    expect(wrongDiagnostics.single.code,
        ChatClientDiagnosticCode.membershipIntentsRejected);
    expect(wrongIdentityStorage.quarantined, isTrue);
    await wrongIdentity.dispose();

    final backing = InMemoryApplicationChatStorage();
    final blocking = _BlockingMembershipStorage(backing);
    final isolation = _Fixture(
      storage: blocking,
      store: _storeFor({'conversation-1': 4}),
      transport: _MembershipTransport(),
      generatedKeys: Queue.of(['old-key']),
    );
    await isolation.activate();
    final pending = isolation.client.joinConversation(
      const ChatJoinConversationInput(
        conversationId: ConversationId('conversation-1'),
        expectedMemberListRevision: 4,
      ),
    );
    await blocking.replaceStarted.future;
    final replacement =
        isolation.client.activateStorageIdentity(_otherIdentity);
    blocking.releaseReplace.complete();
    expect(await pending,
        isA<ChatCommandClosed<ConversationMembershipMutationResult>>());
    await replacement;
    expect(isolation.client.queuedConversationMemberships, isEmpty);
    expect((await _readMemberships(backing, _identity))?.intents, hasLength(1));
    expect(await _readMemberships(backing, _otherIdentity), isNull);
    await isolation.dispose();
  });
}

const _membershipKind =
    ApplicationChatStorageRecordKind.queuedConversationMembershipIntents;

final class _InterleavingMembershipStorage
    implements AtomicApplicationChatStorage {
  _InterleavingMembershipStorage(this.backing);
  final InMemoryApplicationChatStorage backing;
  Future<void> Function()? beforeWrite;
  int failedExchanges = 0;

  Future<void> _onWrite(ApplicationChatStorageRecordKind kind) async {
    if (kind != _membershipKind) return;
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
    await _onWrite(kind);
    final committed =
        await backing.compareExchange(identity, kind, expected, replacement);
    if (!committed && kind == _membershipKind) failedExchanges++;
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
    Queue<String>? generatedKeys,
    ChatConversationMembershipRetryWait? retryWait,
    ChatClientDiagnosticCallback? onStorageDiagnostic,
    this.realtimeSession,
    this.network,
  }) {
    final keys = generatedKeys ?? Queue.of(['generated-key']);
    client = HandrailChatClient(
      apiBaseUri: Uri.parse('https://chat.example.test/api/chat'),
      tokenProvider: tokenProvider ?? () async => 'access-token',
      transport: transport,
      localStorage: storage,
      storageIdentity: _identity,
      normalizedSnapshotStore: store,
      realtimeSession: realtimeSession,
      generateIdempotencyKey: () => keys.removeFirst(),
      commandRetryOptions: const ChatCommandRetryOptions(
        maxAttempts: 1,
        maxAuthenticationRefreshes: 0,
      ),
      conversationMembershipClock: () => DateTime.utc(2032, 2, 1),
      conversationMembershipRetryWait: retryWait,
      onStorageDiagnostic: onStorageDiagnostic,
    );
  }

  final NormalizedSnapshotStore store;
  final _MembershipTransport transport;
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
    await realtimeSession?.dispose();
    await network?.dispose();
    await store.close();
  }
}

final class _MembershipTransport implements HandrailChatHttpTransport {
  _MembershipTransport({this.patch});

  final Future<HandrailChatHttpResponse> Function(HandrailChatHttpRequest)?
      patch;
  final List<HandrailChatHttpRequest> requests = [];
  int authorityGets = 0;

  Iterable<HandrailChatHttpRequest> get patches =>
      requests.where((request) => request.method == 'PATCH');

  @override
  Future<HandrailChatHttpResponse> send(HandrailChatHttpRequest request) {
    requests.add(request);
    if (request.method == 'GET' && request.uri.path.endsWith('/_meta')) {
      return Future.value(HandrailChatHttpResponse(
        statusCode: 200,
        body: jsonEncode(_metadata),
      ));
    }
    if (request.method == 'GET') {
      authorityGets += 1;
      final conversationId = Uri.decodeComponent(request.uri.pathSegments.last);
      return Future.value(HandrailChatHttpResponse(
        statusCode: 200,
        body: jsonEncode(_detail(conversationId, revision: 100).toJson()),
      ));
    }
    return patch?.call(request) ?? Future.value(_success(_body(request)));
  }
}

final class _BlockingMembershipStorage implements ApplicationChatStorage {
  _BlockingMembershipStorage(this.backing);

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
        ApplicationChatStorageRecordKind.queuedConversationMembershipIntents) {
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

final class _WrongIdentityMembershipStorage implements ApplicationChatStorage {
  _WrongIdentityMembershipStorage(this.record);

  final ApplicationChatQueuedConversationMembershipIntentsRecord record;
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
                .queuedConversationMembershipIntents &&
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
        ApplicationChatStorageRecordKind.queuedConversationMembershipIntents) {
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

ConversationMembershipMutationInput _request(
  String intent,
  String conversationId,
  String key, {
  int revision = 4,
}) =>
    ConversationMembershipMutationInput.fromJson({
      'operation': 'mutate_conversation_membership',
      'intent': intent,
      'conversationId': conversationId,
      if (intent == 'add_member' ||
          intent == 'remove_member' ||
          intent == 'change_member_role')
        'targetUserId': intent == 'change_member_role' ? 'user-b' : 'user-c',
      if (intent == 'add_member' || intent == 'change_member_role')
        'requestedRole': 'moderator',
      'expectedMemberListRevision': revision,
      'idempotencyKey': key,
    });

Future<void> _seedMemberships(
  ApplicationChatStorage storage,
  List<ConversationMembershipMutationInput> requests,
) =>
    storage.replace(ApplicationChatQueuedConversationMembershipIntentsRecord(
      identity: _identity,
      intents: [
        for (var index = 0; index < requests.length; index++)
          ApplicationChatQueuedConversationMembershipIntent(
            request: requests[index],
            enqueueOrder: index + 1,
            enqueuedAt: IsoTimestamp(
              DateTime.utc(2032, 2, 1, 0, 0, index).toIso8601String(),
            ),
          ),
      ],
    ));

Future<ApplicationChatQueuedConversationMembershipIntentsRecord?>
    _readMemberships(
  ApplicationChatStorage storage,
  ApplicationChatStorageIdentity identity,
) async =>
        await storage.read(
          identity,
          ApplicationChatStorageRecordKind.queuedConversationMembershipIntents,
        ) as ApplicationChatQueuedConversationMembershipIntentsRecord?;

NormalizedSnapshotStore _storeFor(
  Map<String, int> revisions, {
  Set<String> joinPending = const {},
  Set<String> includeUserC = const {},
}) {
  final store = NormalizedSnapshotStore();
  for (final entry in revisions.entries) {
    store.hydrateConversationDetail(
      _detail(
        entry.key,
        revision: entry.value,
        currentMemberActive: !joinPending.contains(entry.key),
        includeUserC: includeUserC.contains(entry.key),
      ),
    );
  }
  return store;
}

ConversationDetailSnapshot _detail(
  String conversationId, {
  required int revision,
  bool currentMemberActive = true,
  bool includeUserC = false,
}) =>
    ConversationDetailSnapshot.fromJson({
      'kind': 'conversation_detail',
      'conversation': {
        'id': conversationId,
        'tenantId': _identity.tenantId.toJson(),
        'type': 'channel',
        'name': 'Channel $conversationId',
        'visibility': 'public',
        'createdAt': membershipTimestamp,
        'updatedAt': membershipTimestamp,
        'latestSequence': 3,
        'activityAt': membershipTimestamp,
        'unreadMentionCount': 0,
        'currentMember': {
          'tenantId': _identity.tenantId.toJson(),
          'conversationId': conversationId,
          'userId': _identity.userId.toJson(),
          'role': 'member',
          'state': currentMemberActive ? 'active' : 'left',
          'joinedAt': membershipTimestamp,
          'updatedAt': membershipTimestamp,
        },
        'currentReadState': {
          'conversationId': conversationId,
          'userId': _identity.userId.toJson(),
          'lastReadSequence': 0,
          'updatedAt': membershipTimestamp,
        },
        'currentPreference': {
          'conversationId': conversationId,
          'userId': _identity.userId.toJson(),
          'notificationPreference': 'mentions',
          'isStarred': false,
          'mute': {'muted': false},
          'updatedAt': membershipTimestamp,
        },
        'activeMemberUserIds': [
          if (currentMemberActive) _identity.userId.toJson(),
          'user-b',
          if (includeUserC) 'user-c',
        ],
        'memberUserIds': [
          if (currentMemberActive) _identity.userId.toJson(),
          'user-b',
          if (includeUserC) 'user-c',
        ],
        'memberListRevision': revision,
      },
      '_meta': {
        ..._metadata,
        'feature': {
          'name': conversationSnapshotFeature,
          'version': conversationSnapshotVersion,
        },
      },
    });

Map<String, Object?> _body(HandrailChatHttpRequest request) =>
    (jsonDecode(request.body!) as Map).cast<String, Object?>();

HandrailChatHttpResponse _success(Map<String, Object?> input) =>
    HandrailChatHttpResponse(
      statusCode: 200,
      body: jsonEncode(appliedMembershipFixture(input)),
    );

HandrailChatHttpResponse _error(int status, String code) =>
    HandrailChatHttpResponse(
      statusCode: status,
      body: jsonEncode({
        'error': {'code': code, 'message': 'request failed'},
      }),
    );

KnownDurableEvent _membershipEvent(Map<String, Object?> input) =>
    KnownDurableEvent.fromJson(
      {
        'eventId': 'membership-event-1',
        'protocolVersion': handrailChatProtocolVersion,
        'tenantId': _identity.tenantId.toJson(),
        'streamId': input['conversationId'],
        'type': 'conversation.membership.updated',
        'occurredAt': membershipTimestamp,
        'payload': {
          'input': input,
          'result': appliedMembershipFixture(input),
        },
      },
      trustedIdentity: DurableEventTrustedIdentity(
        tenantId: _identity.tenantId,
        userId: _identity.userId,
      ),
    );

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
