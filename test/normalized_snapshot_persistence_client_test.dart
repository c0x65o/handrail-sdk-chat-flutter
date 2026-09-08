import 'dart:async';
import 'dart:convert';

import 'package:handrail_chat/core.dart';
import 'package:handrail_chat/testing.dart'
    show
        FakeChatRealtimeNetwork,
        FakeChatRealtimeSocket,
        FakeChatRealtimeSocketFactory;
import 'package:test/test.dart';

void main() {
  group('HandrailChatClient normalized snapshot persistence', () {
    for (final scenario in [
      (name: 'ephemeral device reconnect', tenant: 'tenant-1', user: 'user-1', persisted: false, retained: true),
      (name: 'different actor', tenant: 'tenant-1', user: 'user-2', persisted: false, retained: false),
      (name: 'different tenant', tenant: 'tenant-2', user: 'user-1', persisted: false, retained: false),
      (name: 'different storage device', tenant: 'tenant-1', user: 'user-1', persisted: true, retained: false),
    ]) {
      test('cache boundary on ${scenario.name}', () async {
        final first = FakeChatRealtimeSocket();
        final second = FakeChatRealtimeSocket();
        final sockets = FakeChatRealtimeSocketFactory()
          ..enqueueSocket(first)
          ..enqueueSocket(second);
        final session = ChatRealtimeSessionTransport(
          endpoint: Uri.parse('https://chat.example.test/api/chat'),
          clientPackageVersion: handrailChatPackageVersion,
          protocolVersion: handrailChatProtocolVersion,
          tokenProvider: () => 'realtime-token',
          socketFactory: sockets.call,
        );
        final client = HandrailChatClient(
          apiBaseUri: Uri.parse('https://chat.example.test/api/chat'),
          tokenProvider: () async => 'access-token',
          transport: _HttpTransport((_) async => _metadataResponse()),
          realtimeSession: session,
          localStorage: scenario.persisted ? _StorageHarness() : null,
        );
        try {
          await client.initialize();
          await session.start();
          first.emitJson(_acceptedFrame());
          await _pump();
          client.normalizedState.installPersistedSnapshot(await _snapshot('retained'));
          expect(client.normalizedState.state.conversations, isNotEmpty);

          await session.restart();
          second.emitJson({
            ..._acceptedFrame(),
            'tenantId': scenario.tenant,
            'actorStreamId': 'user:${scenario.user}',
            'deviceId': 'device-2',
            'sessionId': 'session-2',
          });
          await _pump();
          expect(session.state, isA<ChatRealtimeConnectedState>());
          expect(client.normalizedState.state.conversations.isNotEmpty,
              scenario.retained);
        } finally {
          await session.dispose();
          await client.dispose();
        }
      });
    }

    test('hydrates a non-empty snapshot before online initialization',
        () async {
      final storage = _StorageHarness();
      final snapshot = await _snapshot('persisted');
      storage.records[(_identity, _snapshotKind)] =
          ApplicationChatNormalizedSnapshotRecord(
        identity: _identity,
        snapshot: snapshot,
      );
      late final HandrailChatClient client;
      final transport = _HttpTransport((_) async {
        expect(
          client.normalizedState.state.conversations.keys,
          contains(const ConversationId('conversation-persisted')),
        );
        return _metadataResponse();
      });
      client = HandrailChatClient(
        apiBaseUri: Uri.parse('https://chat.example.test/api/chat'),
        tokenProvider: () async => 'access-token',
        transport: transport,
        localStorage: storage,
        storageIdentity: _identity,
      );

      expect(await client.initialize(), isA<ChatClientReadyState>());
      expect(transport.requests, hasLength(1));
      await client.dispose();
    });

    test('reads only the exact tenant, user, and device snapshot key',
        () async {
      final storage = _StorageHarness();
      final otherIdentities = <ApplicationChatStorageIdentity>[
        _identityFor(tenant: 'tenant-2'),
        _identityFor(user: 'user-2'),
        _identityFor(device: 'device-2'),
      ];
      for (var index = 0; index < otherIdentities.length; index += 1) {
        final identity = otherIdentities[index];
        storage.records[(identity, _snapshotKind)] =
            ApplicationChatNormalizedSnapshotRecord(
          identity: identity,
          snapshot: await _snapshot('other-$index', tenant: identity.tenantId),
        );
      }
      final client = _client(storage: storage, identity: _identity);

      expect(await client.initialize(), isA<ChatClientReadyState>());
      expect(client.normalizedState.state.conversations, isEmpty);
      expect(
        storage.reads.where((read) => read.$2 == _snapshotKind),
        [(_identity, _snapshotKind)],
      );
      expect(storage.removals, isEmpty);
      await client.dispose();
    });

    for (final malformed in <String, _ReadHandler>{
      'corrupt': (_, kind) async {
        if (kind == _snapshotKind) throw const FormatException('secret');
        return null;
      },
      'mismatched': (_, kind) async => kind == _snapshotKind
          ? ApplicationChatNormalizedSnapshotRecord(
              identity: _identityFor(user: 'other-user'),
              snapshot: await _snapshot('mismatch'),
            )
          : null,
      'wrong-kind': (_, kind) async => kind == _snapshotKind
          ? ApplicationChatRealtimeCursorRecord(
              identity: _identity,
              cursor: const EventCursor(eventId: 'wrong-kind'),
            )
          : null,
    }.entries) {
      test('${malformed.key} data quarantines only the requested snapshot key',
          () async {
        final diagnostics = <ChatClientDiagnostic>[];
        final storage = _StorageHarness(onRead: malformed.value);
        storage.records[(
          _identity,
          ApplicationChatStorageRecordKind.queuedSendMessageIntents
        )] = ApplicationChatQueuedSendMessageIntentsRecord(
          identity: _identity,
          intents: const [],
        );
        final client = _client(
          storage: storage,
          identity: _identity,
          diagnostics: diagnostics,
        );

        expect(await client.initialize(), isA<ChatClientReadyState>());
        expect(
          storage.removals,
          [(_identity, _snapshotKind)],
        );
        expect(
          storage.records,
          contains((
            _identity,
            ApplicationChatStorageRecordKind.queuedSendMessageIntents
          )),
        );
        expect(
          diagnostics.single.code,
          ChatClientDiagnosticCode.normalizedSnapshotRejected,
        );
        expect(diagnostics.single.toString(), isNot(contains('secret')));
        await client.dispose();
      });
    }

    test('ordinary read failure fails open into a usable online client',
        () async {
      const thrownSecret = 'adapter-thrown-secret';
      final diagnostics = <ChatClientDiagnostic>[];
      final storage = _StorageHarness(onRead: (_, kind) async {
        if (kind == _snapshotKind) throw StateError(thrownSecret);
        return null;
      });
      final client = _client(
        storage: storage,
        identity: _identity,
        diagnostics: diagnostics,
      );

      expect(await client.initialize(), isA<ChatClientReadyState>());
      expect(client.normalizedState.state.conversations, isEmpty);
      expect(storage.removals, isEmpty);
      expect(
        diagnostics.single.code,
        ChatClientDiagnosticCode.normalizedSnapshotReadFailed,
      );
      expect(diagnostics.single.toString(), isNot(contains(thrownSecret)));
      await client.dispose();
    });

    test('quarantine removal failure remains usable and credential-safe',
        () async {
      const thrownSecret = 'remove-thrown-secret';
      final diagnostics = <ChatClientDiagnostic>[];
      final storage = _StorageHarness(
        onRead: (_, kind) async {
          if (kind == _snapshotKind) throw const FormatException('corrupt');
          return null;
        },
        onRemove: (_, __) async => throw StateError(thrownSecret),
      );
      final client = _client(
        storage: storage,
        identity: _identity,
        diagnostics: diagnostics,
      );

      expect(await client.initialize(), isA<ChatClientReadyState>());
      expect(
        diagnostics.map((diagnostic) => diagnostic.code),
        [
          ChatClientDiagnosticCode.normalizedSnapshotRejected,
          ChatClientDiagnosticCode.normalizedSnapshotQuarantineFailed,
        ],
      );
      expect(diagnostics.join(), isNot(contains(thrownSecret)));
      await client.dispose();
    });

    test('a delayed old-identity read cannot replace a newer identity',
        () async {
      final oldRead = Completer<ApplicationChatStorageRecord?>();
      final newRead = Completer<ApplicationChatStorageRecord?>();
      final newIdentity = _identityFor(user: 'user-new', device: 'device-new');
      final oldRecord = ApplicationChatNormalizedSnapshotRecord(
        identity: _identity,
        snapshot: await _snapshot('old'),
      );
      final newRecord = ApplicationChatNormalizedSnapshotRecord(
        identity: newIdentity,
        snapshot: await _snapshot('new'),
      );
      final storage = _StorageHarness(onRead: (identity, kind) async {
        if (kind != _snapshotKind) return null;
        if (identity == _identity) return oldRead.future;
        return newRead.future;
      });
      final client = _client(storage: storage, identity: _identity);

      final initialization = client.initialize();
      await _eventually(
          () => storage.reads.contains((_identity, _snapshotKind)));
      final replacement = client.activateStorageIdentity(newIdentity);
      await _eventually(
        () => storage.reads.contains((newIdentity, _snapshotKind)),
      );
      oldRead.complete(oldRecord);
      await _pump();
      expect(client.state, isA<ChatClientIdleState>());

      newRead.complete(newRecord);
      await replacement;
      expect(
        client.normalizedState.state.conversations.keys,
        contains(const ConversationId('conversation-new')),
      );
      expect(await initialization, isA<ChatClientReadyState>());
      expect(
        client.normalizedState.state.conversations.keys,
        isNot(contains(const ConversationId('conversation-old'))),
      );
      expect(
        client.normalizedState.state.conversations.keys,
        contains(const ConversationId('conversation-new')),
      );
      await client.dispose();
    });

    test('disposal while reading prevents a late normalized-store mutation',
        () async {
      final read = Completer<ApplicationChatStorageRecord?>();
      final storage = _StorageHarness(
          onRead: (_, kind) async =>
              kind == _snapshotKind ? read.future : null);
      final store = NormalizedSnapshotStore();
      final client = _client(
        storage: storage,
        identity: _identity,
        normalizedState: store,
      );

      final initialization = client.initialize();
      await _eventually(
          () => storage.reads.contains((_identity, _snapshotKind)));
      await client.dispose();
      read.complete(ApplicationChatNormalizedSnapshotRecord(
        identity: _identity,
        snapshot: await _snapshot('late'),
      ));

      expect(await initialization, isA<ChatClientIdleState>());
      expect(store.state.conversations, isEmpty);
      await store.close();
    });

    test('snapshot hydration finishes before retained send and read loads',
        () async {
      final read = Completer<ApplicationChatStorageRecord?>();
      final tokenCalls = <String>[];
      final storage = _StorageHarness(onRead: (identity, kind) async {
        if (kind == _snapshotKind) return read.future;
        return null;
      });
      final client = _client(
        storage: storage,
        identity: _identity,
        tokenProvider: () async {
          tokenCalls.add('token');
          return 'access-token';
        },
      );

      final initialization = client.initialize();
      await _eventually(() => storage.reads.isNotEmpty);
      expect(storage.reads, [(_identity, _snapshotKind)]);
      expect(tokenCalls, isEmpty);

      read.complete(null);
      expect(await initialization, isA<ChatClientReadyState>());
      expect(
        storage.reads.indexWhere((read) =>
            read.$2 ==
            ApplicationChatStorageRecordKind.queuedSendMessageIntents),
        greaterThan(0),
      );
      expect(
        storage.reads.indexWhere((read) =>
            read.$2 ==
            ApplicationChatStorageRecordKind.queuedReadCursorIntents),
        greaterThan(0),
      );
      await client.dispose();
    });

    test('realtime replay waits for accepted-identity hydration', () async {
      final read = Completer<ApplicationChatStorageRecord?>();
      final storage = _StorageHarness(
          onRead: (_, kind) async =>
              kind == _snapshotKind ? read.future : null);
      final network = FakeChatRealtimeNetwork();
      final socket = FakeChatRealtimeSocket();
      final socketFactory = FakeChatRealtimeSocketFactory()
        ..enqueueSocket(socket);
      final session = ChatRealtimeSessionTransport(
        endpoint: Uri.parse('https://chat.example.test/api/chat'),
        clientPackageVersion: '0.1.19',
        protocolVersion: handrailChatProtocolVersion,
        tokenProvider: () => 'realtime-token',
        socketFactory: socketFactory.call,
        network: network,
      );
      final store = NormalizedSnapshotStore();
      final client = _client(
        storage: storage,
        normalizedState: store,
        realtimeSession: session,
      );
      expect(await client.initialize(), isA<ChatClientReadyState>());
      await session.start();
      await _eventually(() => socketFactory.uris.isNotEmpty);

      socket.emitJson(_acceptedFrame());
      await _eventually(
          () => storage.reads.contains((_identity, _snapshotKind)));
      socket.emitJson(_messageCreatedEvent());
      await _pump();
      expect(store.state.canonicalMessages, isEmpty);

      read.complete(ApplicationChatNormalizedSnapshotRecord(
        identity: _identity,
        snapshot: await _snapshot('replay'),
      ));
      await _eventually(() => store.state.canonicalMessages.isNotEmpty);
      expect(
        store.state.canonicalMessages.keys,
        contains(const MessageId('message-replayed')),
      );

      await client.dispose();
      await session.dispose();
      await network.dispose();
      await store.close();
    });

    test('accepted query state writes an exact identity-scoped checkpoint',
        () async {
      final storage = _StorageHarness();
      final transport = _HttpTransport((request) async {
        if (request.uri.path.endsWith('/_meta')) return _metadataResponse();
        return HandrailChatHttpResponse(
          statusCode: 200,
          body: jsonEncode(_conversationListSnapshotJson('query')),
        );
      });
      final client = HandrailChatClient(
        apiBaseUri: Uri.parse('https://chat.example.test/api/chat'),
        tokenProvider: () async => 'access-token',
        transport: transport,
        localStorage: storage,
        storageIdentity: _identity,
      );
      final controller = ChatConversationListController(
        client: client,
        scope: const OrganizationConversationSnapshotScope(),
      );

      expect(await client.initialize(), isA<ChatClientReadyState>());
      expect((await controller.refresh()).isReady, isTrue);
      await _eventually(() => storage.snapshotReplacements.isNotEmpty);

      final record = storage.snapshotReplacements.single;
      expect(record.identity, _identity);
      expect(
        NormalizedSnapshotStateStorageCodec.encode(record.snapshot),
        NormalizedSnapshotStateStorageCodec.encode(
          client.normalizedState.canonicalPersistenceSnapshot(),
        ),
      );

      await controller.dispose();
      await client.dispose();
    });

    test('accepted realtime event writes an exact identity checkpoint',
        () async {
      final storage = _StorageHarness();
      storage.records[(_identity, _snapshotKind)] =
          ApplicationChatNormalizedSnapshotRecord(
        identity: _identity,
        snapshot: await _snapshot('replay'),
      );
      final client = _client(storage: storage, identity: _identity);

      expect(await client.initialize(), isA<ChatClientReadyState>());
      client.reduceDurableEvent(KnownDurableEvent.fromJson(
        _messageCreatedEvent(),
        trustedIdentity: const DurableEventTrustedIdentity(
          tenantId: TenantId('tenant-1'),
          userId: UserId('user-1'),
        ),
      ));
      await _eventually(() => storage.snapshotReplacements.isNotEmpty);

      final record = storage.snapshotReplacements.single;
      expect(record.identity, _identity);
      expect(record.snapshot.canonicalMessages.keys,
          contains(const MessageId('message-replayed')));
      expect(
        NormalizedSnapshotStateStorageCodec.encode(record.snapshot),
        NormalizedSnapshotStateStorageCodec.encode(
          client.normalizedState.canonicalPersistenceSnapshot(),
        ),
      );
      await client.dispose();
    });

    test('a delayed engine cannot overwrite a competing atomic commit',
        () async {
      final releaseFirstExchange = Completer<void>();
      var snapshotExchangeCount = 0;
      final storage = _AtomicStorageHarness(
        onCompareExchange: (identity, kind, expected, replacement) async {
          if (kind != _snapshotKind || replacement == null) return;
          snapshotExchangeCount += 1;
          if (snapshotExchangeCount == 1) {
            await releaseFirstExchange.future;
          }
        },
      );
      final diagnosticsA = <ChatClientDiagnostic>[];
      final storeA = NormalizedSnapshotStore();
      final storeB = NormalizedSnapshotStore();
      final clientA = _client(
        storage: storage,
        identity: _identity,
        normalizedState: storeA,
        diagnostics: diagnosticsA,
      );
      final clientB = _client(
        storage: storage,
        identity: _identity,
        normalizedState: storeB,
      );
      expect(await clientA.initialize(), isA<ChatClientReadyState>());
      expect(await clientB.initialize(), isA<ChatClientReadyState>());

      storeA.hydrateConversationList(_conversationListSnapshot('engine-a'));
      await _eventually(() => snapshotExchangeCount == 1);
      storeB.hydrateConversationList(_conversationListSnapshot('engine-b'));
      await _eventually(() => storage.successfulSnapshotExchanges.length == 1);

      releaseFirstExchange.complete();
      await _eventually(() => diagnosticsA.isNotEmpty);
      final persisted = storage.snapshotRecord(_identity)!;
      expect(
        persisted.snapshot.conversations.keys,
        contains(const ConversationId('conversation-engine-b')),
      );
      expect(
        persisted.snapshot.conversations.keys,
        isNot(contains(const ConversationId('conversation-engine-a'))),
      );
      expect(
        diagnosticsA.single.code,
        ChatClientDiagnosticCode.normalizedSnapshotWriteFailed,
      );

      await clientA.dispose();
      await clientB.dispose();
      await storeA.close();
      await storeB.close();
    });

    test('atomic quarantine preserves a concurrent valid replacement',
        () async {
      const malformed = '{"malformed":"adapter-secret"}';
      final releaseQuarantine = Completer<void>();
      final storage = _AtomicStorageHarness(
        onCompareExchange: (identity, kind, expected, replacement) async {
          if (kind == _snapshotKind &&
              expected == malformed &&
              replacement == null) {
            await releaseQuarantine.future;
          }
        },
      )..putEncoded(_identity, _snapshotKind, malformed);
      final diagnostics = <ChatClientDiagnostic>[];
      final client = _client(
        storage: storage,
        identity: _identity,
        diagnostics: diagnostics,
      );

      final initialization = client.initialize();
      await _eventually(() => storage.compareExchangeAttempts.isNotEmpty);
      final replacement = ApplicationChatNormalizedSnapshotRecord(
        identity: _identity,
        snapshot: await _snapshot('engine-b'),
      ).encode();
      expect(
        await storage.compareExchange(
          _identity,
          _snapshotKind,
          malformed,
          replacement,
        ),
        isTrue,
      );
      releaseQuarantine.complete();

      expect(await initialization, isA<ChatClientReadyState>());
      expect(storage.encodedRecord(_identity, _snapshotKind), replacement);
      expect(
        diagnostics.single.code,
        ChatClientDiagnosticCode.normalizedSnapshotRejected,
      );
      expect(diagnostics.single.toString(), isNot(contains('adapter-secret')));
      await client.dispose();
    });

    test('rehydration establishes the fresh atomic checkpoint baseline',
        () async {
      final baseline = ApplicationChatNormalizedSnapshotRecord(
        identity: _identity,
        snapshot: await _snapshot('engine-b'),
      );
      final storage = _AtomicStorageHarness()
        ..putEncoded(_identity, _snapshotKind, baseline.encode());
      final store = NormalizedSnapshotStore();
      final client = _client(
        storage: storage,
        identity: _identity,
        normalizedState: store,
      );
      expect(await client.initialize(), isA<ChatClientReadyState>());

      store.hydrateConversationList(_conversationListSnapshot('fresh'));
      await _eventually(() => storage.successfulSnapshotExchanges.length == 1);

      final exchange = storage.successfulSnapshotExchanges.single;
      expect(exchange.$3, baseline.encode());
      final persisted = storage.snapshotRecord(_identity)!;
      expect(
        persisted.snapshot.conversations.keys,
        contains(const ConversationId('conversation-fresh')),
      );
      await client.dispose();
      await store.close();
    });

    test('rapid commits serialize replacements and retain the newest state',
        () async {
      final firstReplacement = Completer<void>();
      var snapshotAttempts = 0;
      final storage = _StorageHarness(onReplace: (record) async {
        if (record.kind != _snapshotKind) return;
        snapshotAttempts += 1;
        if (snapshotAttempts == 1) await firstReplacement.future;
      });
      final store = NormalizedSnapshotStore();
      final client = _client(
        storage: storage,
        identity: _identity,
        normalizedState: store,
      );
      expect(await client.initialize(), isA<ChatClientReadyState>());

      store.hydrateConversationList(_conversationListSnapshot('first'));
      await _eventually(() => snapshotAttempts == 1);
      store.hydrateConversationList(_conversationListSnapshot('newest'));
      await _pump();
      expect(snapshotAttempts, 1);

      firstReplacement.complete();
      await _eventually(() => storage.snapshotReplacements.length == 2);
      final persisted = storage.records[(_identity, _snapshotKind)]!
          as ApplicationChatNormalizedSnapshotRecord;
      expect(
        persisted.snapshot.conversations,
        contains(const ConversationId('conversation-newest')),
      );
      expect(
        NormalizedSnapshotStateStorageCodec.encode(persisted.snapshot),
        NormalizedSnapshotStateStorageCodec.encode(
          store.canonicalPersistenceSnapshot(),
        ),
      );

      await client.dispose();
      await store.close();
    });

    test('empty startup and hydration installation never replace the record',
        () async {
      final read = Completer<ApplicationChatStorageRecord?>();
      final persisted = ApplicationChatNormalizedSnapshotRecord(
        identity: _identity,
        snapshot: await _snapshot('persisted-only'),
      );
      final storage = _StorageHarness(
          onRead: (_, kind) async =>
              kind == _snapshotKind ? read.future : null);
      final client = _client(storage: storage, identity: _identity);

      final initialization = client.initialize();
      await _eventually(
          () => storage.reads.contains((_identity, _snapshotKind)));
      await _pump();
      expect(storage.snapshotReplaceAttempts, isEmpty);

      read.complete(persisted);
      expect(await initialization, isA<ChatClientReadyState>());
      await _pump();
      expect(storage.snapshotReplaceAttempts, isEmpty);
      expect(
        client.normalizedState.state.conversations,
        contains(const ConversationId('conversation-persisted-only')),
      );
      await client.dispose();
    });

    test('write failure is fail-open and a later commit retries safely',
        () async {
      const thrownSecret = 'checkpoint-adapter-secret';
      var snapshotAttempts = 0;
      final diagnostics = <ChatClientDiagnostic>[];
      final storage = _StorageHarness(onReplace: (record) async {
        if (record.kind != _snapshotKind) return;
        snapshotAttempts += 1;
        if (snapshotAttempts == 1) throw StateError(thrownSecret);
      });
      final store = NormalizedSnapshotStore();
      final client = _client(
        storage: storage,
        identity: _identity,
        normalizedState: store,
        diagnostics: diagnostics,
      );
      expect(await client.initialize(), isA<ChatClientReadyState>());

      store.hydrateConversationList(_conversationListSnapshot('failed'));
      await _eventually(() => diagnostics.isNotEmpty);
      expect(client.state, isA<ChatClientReadyState>());
      expect(
        diagnostics.single.code,
        ChatClientDiagnosticCode.normalizedSnapshotWriteFailed,
      );
      expect(diagnostics.single.toString(), isNot(contains(thrownSecret)));

      store.hydrateConversationList(_conversationListSnapshot('retried'));
      await _eventually(() => storage.snapshotReplacements.length == 1);
      final persisted = storage.snapshotReplacements.single;
      expect(
        persisted.snapshot.conversations,
        contains(const ConversationId('conversation-retried')),
      );
      expect(client.state, isA<ChatClientReadyState>());

      await client.dispose();
      await store.close();
    });

    test('a delayed old-identity write cannot affect the active identity',
        () async {
      final firstReplacement = Completer<void>();
      final newIdentity = _identityFor(user: 'user-new', device: 'device-new');
      var snapshotAttempts = 0;
      final storage = _StorageHarness(onReplace: (record) async {
        if (record.kind != _snapshotKind) return;
        snapshotAttempts += 1;
        if (snapshotAttempts == 1) await firstReplacement.future;
      });
      final store = NormalizedSnapshotStore();
      final client = _client(
        storage: storage,
        identity: _identity,
        normalizedState: store,
      );
      expect(await client.initialize(), isA<ChatClientReadyState>());

      store.hydrateConversationList(_conversationListSnapshot('old-write'));
      await _eventually(() => snapshotAttempts == 1);
      await client.activateStorageIdentity(newIdentity);
      store.hydrateConversationList(_conversationListSnapshot('new-write'));
      firstReplacement.complete();
      await _eventually(() => storage.snapshotReplacements.length == 2);
      expect(
        storage.snapshotReplacements.map((record) => record.identity),
        [_identity, newIdentity],
      );
      final activeRecord = storage.records[(newIdentity, _snapshotKind)]!
          as ApplicationChatNormalizedSnapshotRecord;
      expect(
        activeRecord.snapshot.conversations.keys,
        [const ConversationId('conversation-new-write')],
      );

      await client.dispose();
      await store.close();
    });

    test('disposal drops checkpoints queued behind a delayed write', () async {
      final firstReplacement = Completer<void>();
      var snapshotAttempts = 0;
      final storage = _StorageHarness(onReplace: (record) async {
        if (record.kind != _snapshotKind) return;
        snapshotAttempts += 1;
        if (snapshotAttempts == 1) await firstReplacement.future;
      });
      final store = NormalizedSnapshotStore();
      final client = _client(
        storage: storage,
        identity: _identity,
        normalizedState: store,
      );
      expect(await client.initialize(), isA<ChatClientReadyState>());

      store.hydrateConversationList(_conversationListSnapshot('in-flight'));
      await _eventually(() => snapshotAttempts == 1);
      store.hydrateConversationList(_conversationListSnapshot('queued-drop'));
      await client.dispose();

      firstReplacement.complete();
      await _eventually(() => storage.snapshotReplacements.length == 1);
      await _pump();
      expect(snapshotAttempts, 1);
      await store.close();
    });

    test('checkpoint encoding contains only the canonical export', () async {
      final storage = _StorageHarness();
      storage.records[(_identity, _snapshotKind)] =
          ApplicationChatNormalizedSnapshotRecord(
        identity: _identity,
        snapshot: await _snapshot('canonical'),
      );
      final store = NormalizedSnapshotStore();
      final client = _client(
        storage: storage,
        identity: _identity,
        normalizedState: store,
        tokenProvider: () async => 'credential-that-must-not-persist',
      );
      expect(await client.initialize(), isA<ChatClientReadyState>());

      store.beginOptimisticMessageSend(
        clientMessageId: 'pending-client-message',
        projection: MessageTimelineMessage.fromJson(
          _optimisticMessageJson('credential-that-must-not-persist'),
        ),
      );
      final expected = ApplicationChatNormalizedSnapshotRecord(
        identity: _identity,
        snapshot: store.canonicalPersistenceSnapshot(),
      );
      await _eventually(() => storage.snapshotReplacements.isNotEmpty);

      final record = storage.snapshotReplacements.single;
      expect(record.toJson(), expected.toJson());
      expect(record.toJson().keys,
          unorderedEquals(['schemaVersion', 'kind', 'identity', 'payload']));
      final encoded = record.encode();
      expect(encoded, isNot(contains('pending-client-message')));
      expect(encoded, isNot(contains('credential-that-must-not-persist')));
      expect(encoded, isNot(contains('provider')));
      expect(encoded, isNot(contains('byteSource')));
      expect(encoded, isNot(contains('mediaToken')));

      await client.dispose();
      await store.close();
    });
  });
}

typedef _ReadHandler = Future<ApplicationChatStorageRecord?> Function(
  ApplicationChatStorageIdentity identity,
  ApplicationChatStorageRecordKind kind,
);

typedef _CompareExchangeHandler = Future<void> Function(
  ApplicationChatStorageIdentity identity,
  ApplicationChatStorageRecordKind kind,
  String? expectedEncodedRecord,
  String? replacementEncodedRecord,
);

final class _AtomicStorageHarness implements AtomicApplicationChatStorage {
  _AtomicStorageHarness({this.onCompareExchange});

  final _CompareExchangeHandler? onCompareExchange;
  final Map<(ApplicationChatStorageIdentity, ApplicationChatStorageRecordKind),
      String> _records = {};
  final List<
      (
        ApplicationChatStorageIdentity,
        ApplicationChatStorageRecordKind,
        String?,
        String?
      )> compareExchangeAttempts = [];
  final List<
      (
        ApplicationChatStorageIdentity,
        ApplicationChatStorageRecordKind,
        String?,
        String?
      )> successfulSnapshotExchanges = [];

  void putEncoded(
    ApplicationChatStorageIdentity identity,
    ApplicationChatStorageRecordKind kind,
    String encoded,
  ) {
    _records[(identity, kind)] = encoded;
  }

  String? encodedRecord(
    ApplicationChatStorageIdentity identity,
    ApplicationChatStorageRecordKind kind,
  ) =>
      _records[(identity, kind)];

  ApplicationChatNormalizedSnapshotRecord? snapshotRecord(
    ApplicationChatStorageIdentity identity,
  ) {
    final encoded = encodedRecord(identity, _snapshotKind);
    if (encoded == null) return null;
    return ApplicationChatStorageRecord.decode(encoded)
        as ApplicationChatNormalizedSnapshotRecord;
  }

  @override
  Future<ApplicationChatStorageRecord?> read(
    ApplicationChatStorageIdentity identity,
    ApplicationChatStorageRecordKind kind,
  ) async {
    final encoded = _records[(identity, kind)];
    if (encoded == null) return null;
    final record = ApplicationChatStorageRecord.decode(encoded);
    if (record.identity != identity || record.kind != kind) {
      throw const FormatException(
        'Stored application chat record does not match its storage scope.',
      );
    }
    return record;
  }

  @override
  Future<String?> readEncoded(
    ApplicationChatStorageIdentity identity,
    ApplicationChatStorageRecordKind kind,
  ) async =>
      _records[(identity, kind)];

  @override
  Future<bool> compareExchange(
    ApplicationChatStorageIdentity identity,
    ApplicationChatStorageRecordKind kind,
    String? expectedEncodedRecord,
    String? replacementEncodedRecord,
  ) async {
    final attempt = (
      identity,
      kind,
      expectedEncodedRecord,
      replacementEncodedRecord,
    );
    compareExchangeAttempts.add(attempt);
    final handler = onCompareExchange;
    if (handler != null) {
      await handler(
        identity,
        kind,
        expectedEncodedRecord,
        replacementEncodedRecord,
      );
    }
    if (replacementEncodedRecord != null) {
      final replacement =
          ApplicationChatStorageRecord.decode(replacementEncodedRecord);
      if (replacement.identity != identity || replacement.kind != kind) {
        throw const FormatException(
          'Replacement application chat record does not match its key.',
        );
      }
    }
    final key = (identity, kind);
    if (_records[key] != expectedEncodedRecord) return false;
    if (replacementEncodedRecord == null) {
      _records.remove(key);
    } else {
      _records[key] = replacementEncodedRecord;
    }
    if (kind == _snapshotKind) successfulSnapshotExchanges.add(attempt);
    return true;
  }

  @override
  Future<void> replace(ApplicationChatStorageRecord record) async {
    _records[(record.identity, record.kind)] = record.encode();
  }

  @override
  Future<void> remove(
    ApplicationChatStorageIdentity identity,
    ApplicationChatStorageRecordKind kind,
  ) async {
    _records.remove((identity, kind));
  }

  @override
  Future<void> clearForIdentityChange({
    required ApplicationChatStorageIdentity previousIdentity,
    required ApplicationChatStorageIdentity nextIdentity,
  }) async {}

  @override
  Future<void> clearForLogout(
    ApplicationChatStorageIdentity previousIdentity,
  ) async {}
}

final class _StorageHarness implements ApplicationChatStorage {
  _StorageHarness({this.onRead, this.onRemove, this.onReplace});

  final _ReadHandler? onRead;
  final Future<void> Function(
    ApplicationChatStorageIdentity identity,
    ApplicationChatStorageRecordKind kind,
  )? onRemove;
  final Future<void> Function(ApplicationChatStorageRecord record)? onReplace;
  final Map<(ApplicationChatStorageIdentity, ApplicationChatStorageRecordKind),
      ApplicationChatStorageRecord> records = {};
  final List<(ApplicationChatStorageIdentity, ApplicationChatStorageRecordKind)>
      reads = [];
  final List<(ApplicationChatStorageIdentity, ApplicationChatStorageRecordKind)>
      removals = [];
  final List<ApplicationChatStorageRecord> replaceAttempts = [];
  final List<ApplicationChatStorageRecord> replacements = [];

  List<ApplicationChatNormalizedSnapshotRecord> get snapshotReplaceAttempts =>
      replaceAttempts
          .whereType<ApplicationChatNormalizedSnapshotRecord>()
          .toList(growable: false);

  List<ApplicationChatNormalizedSnapshotRecord> get snapshotReplacements =>
      replacements
          .whereType<ApplicationChatNormalizedSnapshotRecord>()
          .toList(growable: false);

  @override
  Future<ApplicationChatStorageRecord?> read(
    ApplicationChatStorageIdentity identity,
    ApplicationChatStorageRecordKind kind,
  ) async {
    reads.add((identity, kind));
    final handler = onRead;
    if (handler != null) return handler(identity, kind);
    return records[(identity, kind)];
  }

  @override
  Future<void> replace(ApplicationChatStorageRecord record) async {
    replaceAttempts.add(record);
    final handler = onReplace;
    if (handler != null) await handler(record);
    records[(record.identity, record.kind)] = record;
    replacements.add(record);
  }

  @override
  Future<void> remove(
    ApplicationChatStorageIdentity identity,
    ApplicationChatStorageRecordKind kind,
  ) async {
    removals.add((identity, kind));
    final handler = onRemove;
    if (handler != null) return handler(identity, kind);
    records.remove((identity, kind));
  }

  @override
  Future<void> clearForIdentityChange({
    required ApplicationChatStorageIdentity previousIdentity,
    required ApplicationChatStorageIdentity nextIdentity,
  }) async {}

  @override
  Future<void> clearForLogout(
    ApplicationChatStorageIdentity previousIdentity,
  ) async {}
}

HandrailChatClient _client({
  required ApplicationChatStorage storage,
  ApplicationChatStorageIdentity? identity,
  List<ChatClientDiagnostic>? diagnostics,
  NormalizedSnapshotStore? normalizedState,
  ChatRealtimeSessionTransport? realtimeSession,
  HandrailChatAccessTokenProvider? tokenProvider,
}) =>
    HandrailChatClient(
      apiBaseUri: Uri.parse('https://chat.example.test/api/chat'),
      tokenProvider: tokenProvider ?? () async => 'access-token',
      transport: _HttpTransport((_) async => _metadataResponse()),
      localStorage: storage,
      storageIdentity: identity,
      normalizedSnapshotStore: normalizedState,
      realtimeSession: realtimeSession,
      onStorageDiagnostic: diagnostics?.add,
    );

final class _HttpTransport implements HandrailChatHttpTransport {
  _HttpTransport(this.onSend);

  final Future<HandrailChatHttpResponse> Function(HandrailChatHttpRequest)
      onSend;
  final List<HandrailChatHttpRequest> requests = [];

  @override
  Future<HandrailChatHttpResponse> send(HandrailChatHttpRequest request) {
    requests.add(request);
    return onSend(request);
  }
}

const _snapshotKind = ApplicationChatStorageRecordKind.normalizedSnapshot;

final _identity = _identityFor();

ApplicationChatStorageIdentity _identityFor({
  String tenant = 'tenant-1',
  String user = 'user-1',
  String device = 'device-1',
}) =>
    ApplicationChatStorageIdentity(
      tenantId: TenantId(tenant),
      userId: UserId(user),
      deviceId: DeviceId(device),
    );

Future<NormalizedSnapshotState> _snapshot(
  String suffix, {
  TenantId tenant = const TenantId('tenant-1'),
}) async {
  final store = NormalizedSnapshotStore();
  store.hydrateConversationList(_conversationListSnapshot(suffix, tenant));
  final snapshot = store.state;
  await store.close();
  return snapshot;
}

ConversationListSnapshot _conversationListSnapshot(
  String suffix, [
  TenantId tenant = const TenantId('tenant-1'),
]) =>
    ConversationListSnapshot.fromJson(
      _conversationListSnapshotJson(suffix, tenant),
    );

Map<String, Object?> _conversationListSnapshotJson(
  String suffix, [
  TenantId tenant = const TenantId('tenant-1'),
]) =>
    {
      'kind': 'conversation_list',
      'scope': const OrganizationConversationSnapshotScope().toJson(),
      'items': [
        {
          'id': 'conversation-$suffix',
          'tenantId': tenant.toJson(),
          'type': 'channel',
          'name': 'Conversation $suffix',
          'visibility': 'public',
          'createdAt': '2026-09-03T12:00:00.000Z',
          'updatedAt': '2026-09-03T12:00:00.000Z',
          'latestSequence': 0,
          'activityAt': '2026-09-03T12:00:00.000Z',
          'unreadMentionCount': 0,
          'currentMember': {
            'tenantId': tenant.toJson(),
            'conversationId': 'conversation-$suffix',
            'userId': 'user-1',
            'role': 'member',
            'state': 'active',
            'joinedAt': '2026-09-03T12:00:00.000Z',
            'updatedAt': '2026-09-03T12:00:00.000Z',
          },
          'currentReadState': {
            'conversationId': 'conversation-$suffix',
            'userId': 'user-1',
            'lastReadSequence': 0,
            'updatedAt': '2026-09-03T12:00:00.000Z',
          },
          'currentPreference': {
            'conversationId': 'conversation-$suffix',
            'userId': 'user-1',
            'notificationPreference': 'mentions',
            'isStarred': false,
            'mute': {'muted': false},
            'updatedAt': '2026-09-03T12:00:00.000Z',
          },
          'activeMemberUserIds': ['user-1'],
        }
      ],
      'page': <String, Object?>{},
      '_meta': {
        ..._metadata,
        'enabledFeatures': {
          'realtime': true,
          conversationSnapshotFeature: true,
        },
        'feature': {
          'name': conversationSnapshotFeature,
          'version': conversationSnapshotVersion,
        },
      },
    };

Map<String, Object?> _optimisticMessageJson(String sensitiveText) => {
      'id': 'optimistic-message',
      'tenantId': 'tenant-1',
      'conversationId': 'conversation-canonical',
      'author': {'type': 'user', 'userId': 'user-1'},
      'sequence': 1,
      'createdAt': '2026-09-03T12:00:01.000Z',
      'updatedAt': '2026-09-03T12:00:01.000Z',
      'revision': {'revision': 1},
      'content': {'format': 'markdown', 'text': sensitiveText},
      'isThreadRoot': false,
      'reactions': <Object?>[],
      'attachmentMetadata': <Object?>[],
    };

HandrailChatHttpResponse _metadataResponse() => HandrailChatHttpResponse(
      statusCode: 200,
      body: jsonEncode(_metadata),
    );

Map<String, Object?> _acceptedFrame() => {
      'type': 'chat.session.accepted',
      'metadata': _metadata,
      'tenantId': 'tenant-1',
      'actorStreamId': 'user:user-1',
      'deviceId': 'device-1',
      'sessionId': 'session-1',
    };

Map<String, Object?> _messageCreatedEvent() => {
      'eventId': 'event-replayed',
      'protocolVersion': handrailChatProtocolVersion,
      'tenantId': 'tenant-1',
      'streamId': 'conversation-replay',
      'type': 'message.created',
      'occurredAt': '2026-09-03T12:00:01.000Z',
      'payload': {
        'message': {
          'id': 'message-replayed',
          'tenantId': 'tenant-1',
          'conversationId': 'conversation-replay',
          'author': {'type': 'user', 'userId': 'user-1'},
          'sequence': 1,
          'createdAt': '2026-09-03T12:00:01.000Z',
          'updatedAt': '2026-09-03T12:00:01.000Z',
          'revision': {'revision': 1},
          'content': {'format': 'markdown', 'text': 'Replay'},
        },
        'clientMessageId': 'client-replayed',
      },
    };

const Map<String, Object?> _metadata = {
  'packageVersion': '0.1.19',
  'protocolVersion': handrailChatProtocolVersion,
  'schemaVersion': 1,
  'enabledFeatures': <String, Object?>{'realtime': true},
  'supportedProtocolRange': <String, Object?>{
    'minimumVersion': 3,
    'maximumVersion': handrailChatProtocolVersion,
  },
};

Future<void> _pump([int times = 16]) async {
  for (var index = 0; index < times; index += 1) {
    await Future<void>.delayed(Duration.zero);
  }
}

Future<void> _eventually(bool Function() condition) async {
  for (var index = 0; index < 200; index += 1) {
    if (condition()) return;
    await Future<void>.delayed(Duration.zero);
  }
  throw StateError('The expected asynchronous state was not reached.');
}
