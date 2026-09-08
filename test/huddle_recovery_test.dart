import 'dart:async';
import 'dart:convert';

import 'package:handrail_chat/core.dart';
import 'package:handrail_chat/testing.dart' show InMemoryApplicationChatStorage;
import 'package:test/test.dart';

const _conversationId = ConversationId('conversation-1');
const _sessionId = HuddleSessionId('huddle-1');
final _now = DateTime.utc(2030, 1, 1);
final _identity = ApplicationChatStorageIdentity(
  tenantId: const TenantId('tenant-1'),
  userId: const UserId('user-alice'),
  deviceId: const DeviceId('device-1'),
);
final _otherIdentity = ApplicationChatStorageIdentity(
  tenantId: const TenantId('tenant-2'),
  userId: const UserId('user-bob'),
  deviceId: const DeviceId('device-2'),
);

void main() {
  group('current actor huddle participation', () {
    test('tracks joined to left canonical updates independently of media',
        () async {
      final transport = _FakeTransport(_standardHandler);
      final client =
          _client(transport, storage: InMemoryApplicationChatStorage());
      addTearDown(client.dispose);
      await client.activateStorageIdentity(_identity);
      final controller = client.huddles.forConversation(_conversationId);
      controller.reconcileCanonicalState(HuddleSessionState.fromJson(_active));
      expect(controller.currentActorParticipation,
          ChatHuddleActorParticipation.joined);
      expect(controller.state.media, isA<ChatHuddleMediaRejoinRequiredState>());

      controller.reconcileCanonicalState(HuddleSessionState.fromJson(_left));
      expect(controller.currentActorParticipation,
          ChatHuddleActorParticipation.left);
      expect(controller.state.media, isA<ChatHuddleMediaIdleState>());
      expect(transport.requests, isEmpty);
      expect(client.queuedHuddleCommands, isEmpty);
    });

    test('distinguishes an absent actor from non-live canonical state',
        () async {
      final client = _client(_FakeTransport(_standardHandler),
          storage: InMemoryApplicationChatStorage());
      addTearDown(client.dispose);
      await client.activateStorageIdentity(_identity);
      final controller = client.huddles.forConversation(_conversationId);
      expect(controller.currentActorParticipation,
          ChatHuddleActorParticipation.unavailable);
      for (final canonical in [_starting, _activeEmpty]) {
        controller
            .reconcileCanonicalState(HuddleSessionState.fromJson(canonical));
        expect(controller.currentActorParticipation,
            ChatHuddleActorParticipation.absent);
      }
      controller.reconcileCanonicalState(HuddleSessionState.fromJson(_active));
      controller.reconcileCanonicalState(HuddleSessionState.fromJson(_ended));
      expect(controller.currentActorParticipation,
          ChatHuddleActorParticipation.unavailable);
      controller
          .reconcileCanonicalState(HuddleSessionState.fromJson(_inactive));
      expect(controller.currentActorParticipation,
          ChatHuddleActorParticipation.unavailable);
    });

    test('participants, cached current user and opaque token are not identity',
        () async {
      final transport = _FakeTransport(_standardHandler);
      final client = _client(transport,
          storage: InMemoryApplicationChatStorage(), activateIdentity: false);
      addTearDown(client.dispose);
      await client.initialize();
      client.normalizedState.projectCurrentUserReadState(ConversationReadState(
        conversationId: _conversationId,
        userId: _identity.userId,
        lastReadSequence: const MessageSequence(0),
        updatedAt: const IsoTimestamp('2030-01-01T00:00:00.000Z'),
      ));
      final controller = client.huddles.forConversation(_conversationId);
      for (final canonical in [_inactive, _active, _left, _ended]) {
        controller
            .reconcileCanonicalState(HuddleSessionState.fromJson(canonical));
        expect(controller.currentActorParticipation,
            ChatHuddleActorParticipation.unknownIdentity);
      }
      expect(transport.commandRequests, isEmpty);
    });

    test('activation and account changes never reuse prior participation',
        () async {
      final client = _client(_FakeTransport(_standardHandler),
          storage: InMemoryApplicationChatStorage(), activateIdentity: false);
      addTearDown(client.dispose);
      final controller = client.huddles.forConversation(_conversationId);
      controller.reconcileCanonicalState(HuddleSessionState.fromJson(_active));
      expect(controller.currentActorParticipation,
          ChatHuddleActorParticipation.unknownIdentity);
      await client.activateStorageIdentity(_identity);
      expect(controller.currentActorParticipation,
          ChatHuddleActorParticipation.unavailable);
      controller.reconcileCanonicalState(HuddleSessionState.fromJson(_active));
      expect(controller.currentActorParticipation,
          ChatHuddleActorParticipation.joined);

      await client.activateStorageIdentity(_otherIdentity);
      expect(controller.currentActorParticipation,
          ChatHuddleActorParticipation.unavailable);
      controller.reconcileCanonicalState(HuddleSessionState.fromJson(_active));
      expect(controller.currentActorParticipation,
          ChatHuddleActorParticipation.absent);
      controller.reconcileCanonicalState(HuddleSessionState.fromJson({
        ..._active,
        'participants': [
          {
            'userId': _otherIdentity.userId.value,
            'status': 'left',
            'joinedAt': '2030-01-01T00:00:02.000Z',
            'leftAt': '2030-01-01T00:00:03.000Z',
          },
        ],
      }));
      expect(controller.currentActorParticipation,
          ChatHuddleActorParticipation.left);
      await client.activateStorageIdentity(_identity);
      expect(controller.currentActorParticipation,
          ChatHuddleActorParticipation.unavailable);
    });

    for (final disposeClient in [false, true]) {
      test(
          'is unavailable after ${disposeClient ? 'client' : 'controller'} disposal',
          () async {
        final client = _client(_FakeTransport(_standardHandler),
            storage: InMemoryApplicationChatStorage());
        addTearDown(client.dispose);
        await client.activateStorageIdentity(_identity);
        final controller = client.huddles.forConversation(_conversationId);
        controller
            .reconcileCanonicalState(HuddleSessionState.fromJson(_active));
        expect(controller.currentActorParticipation,
            ChatHuddleActorParticipation.joined);
        if (disposeClient) {
          await client.dispose();
        } else {
          await controller.dispose();
        }
        expect(controller.state.canonicalState, isA<ActiveHuddleState>());
        expect(controller.currentActorParticipation,
            ChatHuddleActorParticipation.unavailable);
        if (disposeClient) {
          expect(
              client.huddles
                  .forConversation(const ConversationId('after-disposal'))
                  .currentActorParticipation,
              ChatHuddleActorParticipation.unavailable);
        } else {
          await client.activateStorageIdentity(_otherIdentity);
          expect(controller.currentActorParticipation,
              ChatHuddleActorParticipation.unavailable);
        }
      });
    }

    test('repeated reads preserve state, media descriptor and command queue',
        () async {
      final transport = _FakeTransport(_standardHandler);
      final client =
          _client(transport, storage: InMemoryApplicationChatStorage());
      addTearDown(client.dispose);
      await client.activateStorageIdentity(_identity);
      final controller = client.huddles.forConversation(_conversationId);
      expect(await controller.start(), isA<ChatHuddleActionSuccess>());
      controller.reconcileCanonicalState(HuddleSessionState.fromJson(_active));
      final state = controller.state;
      final descriptor = controller.mediaBoundary.readJoinDescriptor();
      expect(state.media, isA<ChatHuddleMediaReadyState>());
      expect(descriptor, isNotNull);
      final requests = transport.requests.length;
      final queue = client.queuedHuddleCommands;
      final states = <ChatHuddleState>[];
      final subscription = controller.states.listen(states.add);
      await Future<void>.delayed(Duration.zero);
      final emissions = states.length;
      for (var read = 0; read < 3; read++) {
        expect(controller.currentActorParticipation,
            ChatHuddleActorParticipation.joined);
      }
      await Future<void>.delayed(Duration.zero);
      expect(controller.state, same(state));
      expect(controller.mediaBoundary.readJoinDescriptor(), same(descriptor));
      expect(transport.requests.length, requests);
      expect(client.queuedHuddleCommands, queue);
      expect(states.length, emissions);
      await subscription.cancel();
    });
  });

  group('durable huddle recovery', () {
    test('concurrent conversations survive a stale read and retry', () async {
      final backend = InMemoryApplicationChatStorage();
      final firstStorage = _InterleavedStorage(backend);
      final secondStorage = _InterleavedStorage(backend);
      final firstTransport = _FakeTransport(_unavailableHandler);
      final secondTransport = _FakeTransport(_unavailableHandler);
      final first = _client(firstTransport, storage: firstStorage);
      final second = _client(secondTransport, storage: secondStorage);
      addTearDown(first.dispose);
      addTearDown(second.dispose);
      await first.activateStorageIdentity(_identity);
      await second.activateStorageIdentity(_identity);

      final read = firstStorage.pauseRead = _StorageGate();
      final pending = first.huddles.forConversation(_conversationId).start(
            options: const ChatHuddleActionOptions(idempotencyKey: 'first'),
          );
      await read.entered.future;
      await second.huddles
          .forConversation(const ConversationId('conversation-2'))
          .start(
              options: const ChatHuddleActionOptions(idempotencyKey: 'second'));
      expect(first.queuedHuddleCommands, isEmpty);
      expect(firstTransport.commandRequests, isEmpty);
      read.release.complete();
      await pending;

      final queue = (await _readQueue(backend))!;
      expect(queue.intents.map((intent) => intent.request.idempotencyKey),
          ['second', 'first']);
      expect(queue.intents.map((intent) => intent.enqueueOrder), [1, 2]);
      expect(first.queuedHuddleCommands.map((intent) => intent.enqueueOrder),
          [1, 2]);
      expect(firstStorage.failedExchanges, 1);
      expect(firstTransport.commandRequests, isNotEmpty);
      expect(
          firstTransport.commandRequests
              .map((request) => request.headers['Idempotency-Key'])
              .toSet(),
          {'first'});
    });

    test('same-lane retry coalesces at the committed FIFO position', () async {
      final backend = InMemoryApplicationChatStorage();
      final firstStorage = _InterleavedStorage(backend);
      final first =
          _client(_FakeTransport(_unavailableHandler), storage: firstStorage);
      final second = _client(_FakeTransport(_unavailableHandler),
          storage: _InterleavedStorage(backend));
      addTearDown(first.dispose);
      addTearDown(second.dispose);
      await first.activateStorageIdentity(_identity);
      await second.activateStorageIdentity(_identity);
      final firstController = first.huddles.forConversation(_conversationId);
      final secondController = second.huddles.forConversation(_conversationId);
      firstController
          .reconcileCanonicalState(HuddleSessionState.fromJson(_active));
      secondController
          .reconcileCanonicalState(HuddleSessionState.fromJson(_active));
      final read = firstStorage.pauseRead = _StorageGate();
      final pending = firstController.leave(
        options: const ChatHuddleActionOptions(idempotencyKey: 'last-leave'),
      );
      await read.entered.future;
      await secondController.join(
        options: const ChatHuddleActionOptions(idempotencyKey: 'first-join'),
      );
      await second.huddles
          .forConversation(const ConversationId('conversation-2'))
          .start(
              options:
                  const ChatHuddleActionOptions(idempotencyKey: 'unrelated'));
      read.release.complete();
      await pending;

      final queue = (await _readQueue(backend))!;
      expect(queue.intents.map((intent) => intent.request.idempotencyKey),
          ['last-leave', 'unrelated']);
      expect(queue.intents.map((intent) => intent.enqueueOrder), [1, 2]);
      expect(first.queuedHuddleCommands.first.request, isA<LeaveHuddleInput>());
      expect(firstStorage.failedExchanges, 1);
    });

    for (final replacement in ['new-key', 'same-key', 'same-request']) {
      test(
          'stale settlement preserves $replacement replacement and peer commands',
          () async {
        final backend = InMemoryApplicationChatStorage();
        final firstStorage = _InterleavedStorage(backend);
        final secondStorage = _InterleavedStorage(backend);
        final response = Completer<HandrailChatHttpResponse>();
        final transport = _FakeTransport((_) => response.future);
        final first = _client(transport, storage: firstStorage);
        final second = _client(_FakeTransport(_unavailableHandler),
            storage: secondStorage);
        addTearDown(first.dispose);
        addTearDown(second.dispose);
        await first.activateStorageIdentity(_identity);
        await second.activateStorageIdentity(_identity);
        final firstController = first.huddles.forConversation(_conversationId);
        final secondController =
            second.huddles.forConversation(_conversationId);
        firstController
            .reconcileCanonicalState(HuddleSessionState.fromJson(_active));
        secondController
            .reconcileCanonicalState(HuddleSessionState.fromJson(_active));
        final pending = firstController.join(
          options: const ChatHuddleActionOptions(idempotencyKey: 'old-join'),
        );
        await _eventually(() => transport.commandRequests.isNotEmpty);
        final exchange = firstStorage.pauseExchange = _StorageGate();
        response.complete(_json({
          'error': {'code': 'PERMISSION_DENIED', 'message': 'denied'},
        }, statusCode: 403));
        await exchange.entered.future;
        // The first settlement proposal removes the old intent. The peer
        // changes that exact record before CAS, forcing a fresh decision.
        if (replacement == 'new-key') {
          await secondController.leave(
            options: const ChatHuddleActionOptions(idempotencyKey: 'new-leave'),
          );
        } else {
          final old = (await _readQueue(backend))!.intents.single;
          await secondStorage
              .replace(ApplicationChatQueuedHuddleCommandIntentsRecord(
            identity: _identity,
            intents: [
              ApplicationChatQueuedHuddleCommandIntent(
                request: replacement == 'same-request'
                    ? old.request
                    : const LeaveHuddleInput(
                        huddleSessionId: _sessionId,
                        idempotencyKey: 'old-join'),
                conversationId: old.conversationId,
                enqueueOrder:
                    replacement == 'same-request' ? 2 : old.enqueueOrder,
                enqueuedAt: replacement == 'same-request'
                    ? const IsoTimestamp('2030-01-01T00:00:02.000Z')
                    : old.enqueuedAt,
              )
            ],
          ));
        }
        await second.huddles
            .forConversation(const ConversationId('conversation-2'))
            .start(
                options: const ChatHuddleActionOptions(idempotencyKey: 'peer'));
        final expected = (await _readQueue(backend))!.encode();
        exchange.release.complete();
        expect(await pending, isA<ChatHuddleActionFailure>());

        expect((await _readQueue(backend))!.encode(), expected);
        expect(firstStorage.failedExchanges, 1);
        expect(
            first.queuedHuddleCommands
                .map((intent) => intent.request.idempotencyKey),
            [replacement == 'new-key' ? 'new-leave' : 'old-join', 'peer']);
        expect(first.queuedHuddleCommands.first.request.toJson(),
            (await _readQueue(backend))!.intents.first.request.toJson());
      });
    }

    test('absent settlement target still publishes the committed peer queue',
        () async {
      final backend = InMemoryApplicationChatStorage();
      final storage = _InterleavedStorage(backend);
      final response = Completer<HandrailChatHttpResponse>();
      final transport = _FakeTransport((_) => response.future);
      final client = _client(transport, storage: storage);
      final peer = _client(_FakeTransport(_unavailableHandler),
          storage: _InterleavedStorage(backend));
      addTearDown(client.dispose);
      addTearDown(peer.dispose);
      await client.activateStorageIdentity(_identity);
      await peer.activateStorageIdentity(_identity);
      final pending = client.huddles.forConversation(_conversationId).start(
            options: const ChatHuddleActionOptions(
                idempotencyKey: 'already-removed'),
          );
      await _eventually(() => transport.commandRequests.isNotEmpty);
      await backend.remove(_identity,
          ApplicationChatStorageRecordKind.queuedHuddleCommandIntents);
      await peer.huddles
          .forConversation(const ConversationId('conversation-2'))
          .start(
              options:
                  const ChatHuddleActionOptions(idempotencyKey: 'remaining'));
      response.complete(_json({
        'error': {'code': 'PERMISSION_DENIED', 'message': 'denied'},
      }, statusCode: 403));
      await pending;
      expect(client.queuedHuddleCommands.single.request.idempotencyKey,
          'remaining');
      expect((await _readQueue(backend))!.intents.single.request.idempotencyKey,
          'remaining');
    });

    test('quarantine rejection preserves a concurrently installed valid record',
        () async {
      final backend = InMemoryApplicationChatStorage();
      backend.putRawRecordForTesting(
          _identity,
          ApplicationChatStorageRecordKind.queuedHuddleCommandIntents,
          {'secret': 'credential-sentinel'});
      final storage = _InterleavedStorage(backend);
      final diagnostics = <ChatClientDiagnostic>[];
      final transport = _FakeTransport(_unavailableHandler);
      final client =
          _client(transport, storage: storage, onDiagnostic: diagnostics.add);
      addTearDown(client.dispose);
      final read = storage.pauseRead = _StorageGate();
      final activation = client.activateStorageIdentity(_identity);
      await read.entered.future;
      final replacement = ApplicationChatQueuedHuddleCommandIntentsRecord(
        identity: _identity,
        intents: [
          _intent(const StartHuddleInput(
              conversationId: _conversationId,
              idempotencyKey: 'valid-replacement'))
        ],
      );
      await backend.replace(replacement);
      read.release.complete();
      await activation;

      expect((await _readQueue(backend))!.encode(), replacement.encode());
      expect(storage.failedExchanges, 1);
      expect(client.queuedHuddleCommands, isEmpty);
      expect(transport.commandRequests, isEmpty);
      expect(diagnostics.map((item) => item.code),
          contains('huddle_intents_rejected'));
      expect(diagnostics.join('\n'), isNot(contains('credential-sentinel')));
    });

    test(
        'uncommitted proposals never project or dispatch and keep one request key',
        () async {
      final storage = _InterleavedStorage(InMemoryApplicationChatStorage());
      final transport = _FakeTransport(_standardHandler);
      final diagnostics = <ChatClientDiagnostic>[];
      final client =
          _client(transport, storage: storage, onDiagnostic: diagnostics.add);
      addTearDown(client.dispose);
      await client.activateStorageIdentity(_identity);
      storage.proposals.clear();
      final exchange = storage.pauseExchange = _StorageGate();
      storage.rejectExchanges = true;
      final controller = client.huddles.forConversation(_conversationId);
      final projected = <ChatHuddleState>[];
      final subscription = controller.states.listen(projected.add);
      addTearDown(subscription.cancel);
      final pending = controller.start();
      await exchange.entered.future;
      expect(controller.state.pendingOperation, isNull);
      expect(client.queuedHuddleCommands, isEmpty);
      expect(transport.commandRequests, isEmpty);
      exchange.release.complete();
      expect(
          await pending,
          isA<ChatHuddleActionFailure>()
              .having((failure) => failure.retryable, 'retryable', isTrue));
      expect(
          storage.failedExchanges, maxApplicationChatStorageMutationAttempts);
      expect(storage.proposals.toSet(), hasLength(1));
      expect(
          projected.every((state) => state.pendingOperation == null), isTrue);
      expect(client.queuedHuddleCommands, isEmpty);
      expect(transport.commandRequests, isEmpty);
      expect(await _readQueue(storage), isNull);
      expect(diagnostics.map((item) => item.code),
          contains('huddle_intents_write_failed'));
    });

    test(
        'successful atomic dispatch keeps media and access credentials out of storage',
        () async {
      final storage = _InterleavedStorage(InMemoryApplicationChatStorage());
      final client =
          _client(_FakeTransport(_standardHandler), storage: storage);
      addTearDown(client.dispose);
      await client.activateStorageIdentity(_identity);
      final controller = client.huddles.forConversation(_conversationId);
      expect(await controller.start(), isA<ChatHuddleActionSuccess>());
      expect(controller.mediaBoundary.readJoinDescriptor(), isNotNull);
      expect(storage.writes, isNotEmpty);
      for (final encoded in [
        ...storage.writes,
        ...storage.proposals.whereType<String>()
      ]) {
        for (final forbidden in [
          'SECRET-MEDIA-DESCRIPTOR',
          'access-token',
          'realtime-token',
          'mediaJoin',
          'descriptor',
          'provider',
          'token'
        ]) {
          expect(encoded, isNot(contains(forbidden)));
        }
      }
      expect(await _readQueue(storage), isNull);
    });

    test('persists before projection and transport', () async {
      final storage = _BlockingStorage();
      final transport = _FakeTransport(_standardHandler);
      final client = _client(transport, storage: storage);
      await client.activateStorageIdentity(_identity);
      final controller = client.huddles.forConversation(_conversationId);

      final operation = controller.start(
        options: const ChatHuddleActionOptions(idempotencyKey: 'exact-start'),
      );
      await storage.replaceStarted.future;

      expect(controller.state.pendingOperation, isNull);
      expect(transport.commandRequests, isEmpty);
      storage.allowReplace.complete();
      expect(await operation, isA<ChatHuddleActionSuccess>());
      expect(transport.commandRequests.single.headers['Idempotency-Key'],
          'exact-start');
      expect(await _readQueue(storage), isNull);
      await client.dispose();
    });

    test('cancellation before dispatch removes the just-persisted intent',
        () async {
      final storage = _BlockingStorage();
      final transport = _FakeTransport(_standardHandler);
      final client = _client(transport, storage: storage);
      await client.activateStorageIdentity(_identity);
      final cancellation = ChatCommandCancellationController();
      final operation = client.huddles.forConversation(_conversationId).start(
            options: ChatHuddleActionOptions(
              idempotencyKey: 'cancel-before-dispatch',
              cancellationSignal: cancellation.signal,
            ),
          );
      await storage.replaceStarted.future;
      cancellation.cancel();
      storage.allowReplace.complete();

      final result = await operation;
      expect(result, isA<ChatHuddleActionFailure>());
      expect((result as ChatHuddleActionFailure).code,
          ChatHuddleErrorCode.aborted);
      expect(transport.commandRequests, isEmpty);
      expect(await _readQueue(storage), isNull);
      await client.dispose();
    });

    test('replays all six forms after restart with their exact keys', () async {
      final cases = <({
        HuddleCommandInput request,
        Map<String, Object?> authority,
        Map<String, Object?> result
      })>[
        (
          request: const StartHuddleInput(
            conversationId: _conversationId,
            idempotencyKey: 'restart-start',
          ),
          authority: _inactive,
          result: _starting,
        ),
        (
          request: const JoinHuddleInput(
            huddleSessionId: _sessionId,
            idempotencyKey: 'restart-join',
          ),
          authority: _activeEmpty,
          result: _active,
        ),
        (
          request: const LeaveHuddleInput(
            huddleSessionId: _sessionId,
            idempotencyKey: 'restart-leave',
          ),
          authority: _active,
          result: _left,
        ),
        (
          request: const SetHuddleScreenShareInput(
            huddleSessionId: _sessionId,
            intent: HuddleScreenShareIntent.set,
            idempotencyKey: 'restart-share-set',
          ),
          authority: _active,
          result: _sharing,
        ),
        (
          request: const SetHuddleScreenShareInput(
            huddleSessionId: _sessionId,
            intent: HuddleScreenShareIntent.clear,
            idempotencyKey: 'restart-share-clear',
          ),
          authority: _sharing,
          result: _active,
        ),
        (
          request: const EndHuddleInput(
            huddleSessionId: _sessionId,
            idempotencyKey: 'restart-end',
          ),
          authority: _active,
          result: _ended,
        ),
      ];

      for (final testCase in cases) {
        final storage = InMemoryApplicationChatStorage();
        await storage.replace(ApplicationChatQueuedHuddleCommandIntentsRecord(
          identity: _identity,
          intents: [_intent(testCase.request)],
        ));
        final transport = _FakeTransport((request) async {
          if (request.uri.path.endsWith('/_meta')) return _metadataResponse;
          if (request.method == 'GET') return _json(testCase.authority);
          final input = jsonDecode(request.body!) as Map<String, Object?>;
          return _command(
            input,
            testCase.result,
            media: input['operation'] == 'start_huddle' ||
                input['operation'] == 'join_huddle',
          );
        });
        final client = _client(transport, storage: storage);

        await client.initialize();
        await _eventually(
          () => client.queuedHuddleCommands.isEmpty,
          description: '${testCase.request.operation}: '
              '${client.queuedHuddleCommands} / ${transport.requests.map((r) => '${r.method} ${r.uri.path}')}',
        );

        expect(transport.commandRequests, hasLength(1));
        expect(
          transport.commandRequests.single.headers['Idempotency-Key'],
          testCase.request.idempotencyKey,
        );
        expect(await _readQueue(storage), isNull);
        if (testCase.request is StartHuddleInput ||
            testCase.request is JoinHuddleInput) {
          final controller = client.huddles.forConversation(_conversationId);
          expect(controller.mediaBoundary.readJoinDescriptor(), isNull);
          expect(
            controller.state.media,
            testCase.request is JoinHuddleInput
                ? isA<ChatHuddleMediaRejoinRequiredState>()
                : isA<ChatHuddleMediaIdleState>(),
          );
        }
        await client.dispose();
      }
    });

    test('settles already-equal authority and event-first commands', () async {
      final alreadyStorage = InMemoryApplicationChatStorage();
      await alreadyStorage.replace(
        ApplicationChatQueuedHuddleCommandIntentsRecord(
          identity: _identity,
          intents: [
            _intent(const JoinHuddleInput(
              huddleSessionId: _sessionId,
              idempotencyKey: 'already-joined',
            )),
          ],
        ),
      );
      final alreadyTransport = _FakeTransport((request) async {
        if (request.uri.path.endsWith('/_meta')) return _metadataResponse;
        if (request.method == 'GET') return _json(_active);
        throw StateError('already-equal recovery must not dispatch');
      });
      final alreadyClient = _client(alreadyTransport, storage: alreadyStorage);
      await alreadyClient.initialize();
      await _eventually(() => alreadyClient.queuedHuddleCommands.isEmpty);
      expect(alreadyTransport.commandRequests, isEmpty);
      expect(
        alreadyClient.huddles
            .forConversation(_conversationId)
            .mediaBoundary
            .readJoinDescriptor(),
        isNull,
      );
      await alreadyClient.dispose();

      final response = Completer<HandrailChatHttpResponse>();
      final eventStorage = InMemoryApplicationChatStorage();
      final eventTransport = _FakeTransport((request) async {
        if (request.uri.path.endsWith('/_meta')) return _metadataResponse;
        if (request.method == 'GET') return _json(_inactive);
        return response.future;
      });
      final eventClient = _client(eventTransport, storage: eventStorage);
      await eventClient.initialize();
      final start = eventClient.huddles.forConversation(_conversationId).start(
            options:
                const ChatHuddleActionOptions(idempotencyKey: 'event-first'),
          );
      await _eventually(() => eventTransport.commandRequests.isNotEmpty);

      expect(
        eventClient.huddles
            .reconcileCanonicalState(HuddleSessionState.fromJson(_starting)),
        isTrue,
      );
      final result = await start;
      expect(result, isA<ChatHuddleActionSuccess>());
      expect((result as ChatHuddleActionSuccess).applied, isFalse);
      await _eventually(() => eventClient.queuedHuddleCommands.isEmpty);
      expect(await _readQueue(eventStorage), isNull);
      response.complete(_command(
        const StartHuddleInput(
          conversationId: _conversationId,
          idempotencyKey: 'event-first',
        ).toJson(),
        _starting,
        media: true,
      ));
      await eventClient.dispose();
    });

    test('retains divergent authority as an explicit conflict', () async {
      final storage = InMemoryApplicationChatStorage();
      await storage.replace(ApplicationChatQueuedHuddleCommandIntentsRecord(
        identity: _identity,
        intents: [
          _intent(const JoinHuddleInput(
            huddleSessionId: _sessionId,
            idempotencyKey: 'conflicting-join',
          )),
        ],
      ));
      final transport = _FakeTransport((request) async {
        if (request.uri.path.endsWith('/_meta')) return _metadataResponse;
        if (request.method == 'GET') return _json(_activeOtherSession);
        throw StateError('conflicting recovery must not dispatch');
      });
      final client = _client(transport, storage: storage);
      await client.initialize();
      await _eventually(() =>
          client.queuedHuddleCommands.single.status ==
          ChatHuddleRecoveryStatus.conflict);

      expect(client.queuedHuddleCommands.single.request.idempotencyKey,
          'conflicting-join');
      expect(
        client.huddles.forConversation(_conversationId).state.recoveryStatus,
        ChatHuddleRecoveryStatus.conflict,
      );
      expect(
        client.huddles.forConversation(_conversationId).state.recoveryOperation,
        ChatHuddleActionOperation.join,
      );
      expect(await _readQueue(storage), isNotNull);
      expect(transport.commandRequests, isEmpty);
      await client.dispose();
    });

    test('pauses in background and retries transient failures with backoff',
        () async {
      final storage = InMemoryApplicationChatStorage();
      await storage.replace(ApplicationChatQueuedHuddleCommandIntentsRecord(
        identity: _identity,
        intents: [
          _intent(const StartHuddleInput(
            conversationId: _conversationId,
            idempotencyKey: 'retry-start',
          )),
        ],
      ));
      var hydrationAttempts = 0;
      final waits = <Duration>[];
      final releaseWait = Completer<void>();
      final transport = _FakeTransport((request) async {
        if (request.uri.path.endsWith('/_meta')) return _metadataResponse;
        if (request.method == 'GET') {
          hydrationAttempts += 1;
          if (hydrationAttempts == 1) {
            return const HandrailChatHttpResponse(statusCode: 503, body: '');
          }
          return _json(_inactive);
        }
        final input = jsonDecode(request.body!) as Map<String, Object?>;
        return _command(input, _starting, media: true);
      });
      final client = _client(
        transport,
        storage: storage,
        retryBackoff: (attempt) => Duration(milliseconds: attempt * 10),
        retryWait: (delay, signal) async {
          waits.add(delay);
          await releaseWait.future;
          if (signal.isCancelled) throw StateError('cancelled');
        },
      );
      client.setApplicationForeground(false);
      await client.initialize();
      await Future<void>.delayed(Duration.zero);
      expect(hydrationAttempts, 0);

      client.setApplicationForeground(true);
      await _eventually(() => waits.isNotEmpty);
      expect(waits.single, const Duration(milliseconds: 10));
      expect(client.queuedHuddleCommands, hasLength(1));
      releaseWait.complete();
      await _eventually(() => client.queuedHuddleCommands.isEmpty);
      expect(hydrationAttempts, 2);
      await client.dispose();
    });

    test('waits for trusted identity and for online realtime readiness',
        () async {
      Future<InMemoryApplicationChatStorage> seededStorage() async {
        final storage = InMemoryApplicationChatStorage();
        await storage.replace(ApplicationChatQueuedHuddleCommandIntentsRecord(
          identity: _identity,
          intents: [
            _intent(const StartHuddleInput(
              conversationId: _conversationId,
              idempotencyKey: 'readiness-start',
            )),
          ],
        ));
        return storage;
      }

      final identityStorage = await seededStorage();
      final identityTransport = _FakeTransport((request) async {
        if (request.uri.path.endsWith('/_meta')) return _metadataResponse;
        if (request.method == 'GET') return _json(_inactive);
        final input = jsonDecode(request.body!) as Map<String, Object?>;
        return _command(input, _starting, media: true);
      });
      final identityClient = _client(
        identityTransport,
        storage: identityStorage,
        activateIdentity: false,
      );
      await identityClient.initialize();
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(identityTransport.commandRequests, isEmpty);
      expect(identityClient.queuedHuddleCommands, isEmpty);
      await identityClient.activateStorageIdentity(_identity);
      await _eventually(() =>
          identityClient.queuedHuddleCommands.isEmpty &&
          identityTransport.commandRequests.isNotEmpty);
      await identityClient.dispose();

      for (final online in <bool>[false, true]) {
        final storage = await seededStorage();
        final network = _FakeNetwork(online);
        final realtime = ChatRealtimeSessionTransport(
          endpoint: Uri.parse('https://chat.example.test/api/chat'),
          clientPackageVersion: '0.1.3',
          protocolVersion: handrailChatProtocolVersion,
          tokenProvider: () async => 'realtime-token',
          socketFactory: (_, __) => _FakeSocket(),
          network: network,
        );
        final transport = _FakeTransport((request) async {
          if (request.uri.path.endsWith('/_meta')) return _metadataResponse;
          throw StateError('recovery must wait for accepted realtime identity');
        });
        final client = _client(
          transport,
          storage: storage,
          realtime: realtime,
        );
        await client.initialize();
        await Future<void>.delayed(const Duration(milliseconds: 20));
        expect(client.queuedHuddleCommands, hasLength(1));
        expect(transport.commandRequests, isEmpty);
        expect(
          transport.requests.where((request) =>
              request.method == 'GET' && request.uri.path.endsWith('/huddle')),
          isEmpty,
        );
        await client.dispose();
        await realtime.dispose();
        await network.dispose();
      }
    });

    test('identity generations cannot dispatch or project stale recovery',
        () async {
      final storage = InMemoryApplicationChatStorage();
      await storage.replace(ApplicationChatQueuedHuddleCommandIntentsRecord(
        identity: _identity,
        intents: [
          _intent(const StartHuddleInput(
            conversationId: _conversationId,
            idempotencyKey: 'old-identity-start',
          )),
        ],
      ));
      final oldHydration = Completer<HandrailChatHttpResponse>();
      final transport = _FakeTransport((request) async {
        if (request.uri.path.endsWith('/_meta')) return _metadataResponse;
        if (request.method == 'GET') return oldHydration.future;
        throw StateError('stale identity must never dispatch');
      });
      final client = _client(transport, storage: storage);
      await client.initialize();
      await _eventually(() => transport.requests.any((request) =>
          request.method == 'GET' && request.uri.path.endsWith('/huddle')));

      await client.activateStorageIdentity(_otherIdentity);
      oldHydration.complete(_json(_inactive));
      await Future<void>.delayed(const Duration(milliseconds: 20));

      expect(client.queuedHuddleCommands, isEmpty);
      expect(
          client.huddles.forConversation(_conversationId).state.canonicalState,
          isA<InactiveHuddleState>());
      expect(transport.commandRequests, isEmpty);
      final oldRecord = await storage.read(
        _identity,
        ApplicationChatStorageRecordKind.queuedHuddleCommandIntents,
      ) as ApplicationChatQueuedHuddleCommandIntentsRecord?;
      expect(oldRecord?.intents.single.request.idempotencyKey,
          'old-identity-start');
      await client.dispose();
    });

    test(
        'removes terminal outcomes but retains post-dispatch cancellation and disposal',
        () async {
      final terminalStorage = InMemoryApplicationChatStorage();
      final terminalTransport = _FakeTransport((request) async {
        if (request.uri.path.endsWith('/_meta')) return _metadataResponse;
        return _json(
          <String, Object?>{
            'error': <String, Object?>{
              'code': 'PERMISSION_DENIED',
              'message': 'denied',
            },
          },
          statusCode: 403,
        );
      });
      final terminalClient =
          _client(terminalTransport, storage: terminalStorage);
      await terminalClient.initialize();
      final terminal =
          await terminalClient.huddles.forConversation(_conversationId).start();
      expect(terminal, isA<ChatHuddleActionFailure>());
      expect((terminal as ChatHuddleActionFailure).code,
          ChatHuddleErrorCode.authentication);
      expect(
        await _readQueue(terminalStorage),
        isNull,
        reason: '${terminalClient.queuedHuddleCommands}',
      );
      await terminalClient.dispose();

      final rateLimitStorage = InMemoryApplicationChatStorage();
      final rateLimitClient = _client(
        _FakeTransport((request) async {
          if (request.uri.path.endsWith('/_meta')) return _metadataResponse;
          return _json(
            <String, Object?>{
              'error': <String, Object?>{
                'code': 'RATE_LIMITED',
                'message': 'retry later',
              },
            },
            statusCode: 429,
          );
        }),
        storage: rateLimitStorage,
      );
      await rateLimitClient.initialize();
      final rateLimited = await rateLimitClient.huddles
          .forConversation(_conversationId)
          .start();
      expect(
        rateLimited,
        isA<ChatHuddleActionFailure>().having(
          (failure) => failure.retryable,
          'retryable',
          isTrue,
        ),
      );
      expect((await _readQueue(rateLimitStorage))?.intents, hasLength(1));
      await rateLimitClient.dispose();

      for (final disposeInstead in <bool>[false, true]) {
        final storage = InMemoryApplicationChatStorage();
        final response = Completer<HandrailChatHttpResponse>();
        final transport = _FakeTransport((request) async {
          if (request.uri.path.endsWith('/_meta')) return _metadataResponse;
          return response.future;
        });
        final client = _client(transport, storage: storage);
        await client.initialize();
        final cancellation = ChatCommandCancellationController();
        final start = client.huddles.forConversation(_conversationId).start(
              options: ChatHuddleActionOptions(
                idempotencyKey: disposeInstead ? 'dispose-key' : 'cancel-key',
                cancellationSignal: cancellation.signal,
              ),
            );
        await _eventually(() => transport.commandRequests.isNotEmpty);
        if (disposeInstead) {
          await client.dispose();
        } else {
          cancellation.cancel();
          expect(await start, isA<ChatHuddleActionFailure>());
          await client.dispose();
        }
        final retained = await _readQueue(storage);
        expect(retained?.intents, hasLength(1));
        expect(retained?.encode(), isNot(contains('SECRET-MEDIA-DESCRIPTOR')));
        response.complete(const HandrailChatHttpResponse(
          statusCode: 503,
          body: '',
        ));
        if (disposeInstead) expect(await start, isA<ChatHuddleActionFailure>());
      }
    });

    test('quarantines corrupt records with credential-safe diagnostics',
        () async {
      final storage = InMemoryApplicationChatStorage();
      storage.putRawRecordForTesting(
        _identity,
        ApplicationChatStorageRecordKind.queuedHuddleCommandIntents,
        <String, Object?>{'secret': 'credential-sentinel'},
      );
      final diagnostics = <ChatClientDiagnostic>[];
      final client = _client(
        _FakeTransport((request) async => _metadataResponse),
        storage: storage,
        onDiagnostic: diagnostics.add,
      );
      await client.initialize();

      expect(await _readQueue(storage), isNull);
      expect(diagnostics.map((item) => item.code),
          contains('huddle_intents_rejected'));
      expect(diagnostics.join('\n'), isNot(contains('credential-sentinel')));
      await client.dispose();
    });
  });
}

ApplicationChatQueuedHuddleCommandIntent _intent(HuddleCommandInput request) =>
    ApplicationChatQueuedHuddleCommandIntent(
      request: request,
      conversationId: _conversationId,
      enqueueOrder: 1,
      enqueuedAt: const IsoTimestamp('2030-01-01T00:00:00.000Z'),
    );

Future<ApplicationChatQueuedHuddleCommandIntentsRecord?> _readQueue(
  ApplicationChatStorage storage,
) async =>
    await storage.read(
      _identity,
      ApplicationChatStorageRecordKind.queuedHuddleCommandIntents,
    ) as ApplicationChatQueuedHuddleCommandIntentsRecord?;

Future<void> _eventually(
  bool Function() predicate, {
  String description = 'condition',
}) async {
  for (var attempt = 0; attempt < 100; attempt += 1) {
    if (predicate()) return;
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
  fail('$description did not become true.');
}

HandrailChatClient _client(
  _FakeTransport transport, {
  required ApplicationChatStorage storage,
  ChatHuddleRetryBackoff? retryBackoff,
  ChatHuddleRetryWait? retryWait,
  ChatClientDiagnosticCallback? onDiagnostic,
  ChatRealtimeSessionTransport? realtime,
  bool activateIdentity = true,
}) =>
    HandrailChatClient(
      apiBaseUri: Uri.parse('https://chat.example.test/api/chat'),
      tokenProvider: () async => 'access-token',
      transport: transport,
      requestedCapabilities: const <String, bool>{
        'huddles': true,
        'media': true,
      },
      localStorage: storage,
      storageIdentity: activateIdentity ? _identity : null,
      huddleClock: () => _now,
      huddleRetryBackoff: retryBackoff,
      huddleRetryWait: retryWait,
      onStorageDiagnostic: onDiagnostic,
      realtimeSession: realtime,
    );

final class _FakeTransport implements HandrailChatHttpTransport {
  _FakeTransport(this.handler);
  final Future<HandrailChatHttpResponse> Function(HandrailChatHttpRequest)
      handler;
  final List<HandrailChatHttpRequest> requests = [];
  List<HandrailChatHttpRequest> get commandRequests => requests
      .where((request) =>
          request.method != 'GET' && !request.uri.path.endsWith('/_meta'))
      .toList(growable: false);

  @override
  Future<HandrailChatHttpResponse> send(HandrailChatHttpRequest request) {
    requests.add(request);
    return handler(request);
  }
}

final class _StorageGate {
  final entered = Completer<void>();
  final release = Completer<void>();

  Future<void> wait() async {
    entered.complete();
    await release.future;
  }
}

// Independent adapters share the real test backend's encoded CAS semantics.
// Gates suspend after a read or before an exchange without locking its peers.
final class _InterleavedStorage implements AtomicApplicationChatStorage {
  _InterleavedStorage(this.delegate);

  final InMemoryApplicationChatStorage delegate;
  _StorageGate? pauseRead;
  _StorageGate? pauseExchange;
  bool rejectExchanges = false;
  int failedExchanges = 0;
  final proposals = <String?>[];
  final writes = <String>[];

  static const _kind =
      ApplicationChatStorageRecordKind.queuedHuddleCommandIntents;

  @override
  Future<String?> readEncoded(ApplicationChatStorageIdentity identity,
      ApplicationChatStorageRecordKind kind) async {
    final encoded = await delegate.readEncoded(identity, kind);
    if (kind == _kind) {
      final gate = pauseRead;
      pauseRead = null;
      await gate?.wait();
    }
    return encoded;
  }

  @override
  Future<ApplicationChatStorageRecord?> read(
      ApplicationChatStorageIdentity identity,
      ApplicationChatStorageRecordKind kind) async {
    final encoded = await readEncoded(identity, kind);
    return encoded == null
        ? null
        : ApplicationChatStorageRecord.decode(encoded);
  }

  @override
  Future<bool> compareExchange(
      ApplicationChatStorageIdentity identity,
      ApplicationChatStorageRecordKind kind,
      String? expectedEncodedRecord,
      String? replacementEncodedRecord) async {
    if (kind == _kind) {
      proposals.add(replacementEncodedRecord);
      final gate = pauseExchange;
      pauseExchange = null;
      await gate?.wait();
      if (rejectExchanges) {
        failedExchanges += 1;
        return false;
      }
    }
    final committed = await delegate.compareExchange(
        identity, kind, expectedEncodedRecord, replacementEncodedRecord);
    if (kind == _kind && !committed) failedExchanges += 1;
    if (committed && replacementEncodedRecord != null) {
      writes.add(replacementEncodedRecord);
    }
    return committed;
  }

  @override
  Future<void> replace(ApplicationChatStorageRecord record) async {
    writes.add(record.encode());
    await delegate.replace(record);
  }

  @override
  Future<void> remove(ApplicationChatStorageIdentity identity,
          ApplicationChatStorageRecordKind kind) =>
      delegate.remove(identity, kind);

  @override
  Future<void> clearForIdentityChange({
    required ApplicationChatStorageIdentity previousIdentity,
    required ApplicationChatStorageIdentity nextIdentity,
  }) =>
      delegate.clearForIdentityChange(
          previousIdentity: previousIdentity, nextIdentity: nextIdentity);

  @override
  Future<void> clearForLogout(
          ApplicationChatStorageIdentity previousIdentity) =>
      delegate.clearForLogout(previousIdentity);
}

Future<HandrailChatHttpResponse> _unavailableHandler(
        HandrailChatHttpRequest request) async =>
    request.uri.path.endsWith('/_meta')
        ? _metadataResponse
        : const HandrailChatHttpResponse(statusCode: 503, body: '');

final class _BlockingStorage implements ApplicationChatStorage {
  final delegate = InMemoryApplicationChatStorage();
  final replaceStarted = Completer<void>();
  final allowReplace = Completer<void>();

  @override
  Future<ApplicationChatStorageRecord?> read(
          ApplicationChatStorageIdentity identity,
          ApplicationChatStorageRecordKind kind) =>
      delegate.read(identity, kind);

  @override
  Future<void> replace(ApplicationChatStorageRecord record) async {
    if (!replaceStarted.isCompleted) replaceStarted.complete();
    await allowReplace.future;
    await delegate.replace(record);
  }

  @override
  Future<void> remove(ApplicationChatStorageIdentity identity,
          ApplicationChatStorageRecordKind kind) =>
      delegate.remove(identity, kind);

  @override
  Future<void> clearForIdentityChange({
    required ApplicationChatStorageIdentity previousIdentity,
    required ApplicationChatStorageIdentity nextIdentity,
  }) =>
      delegate.clearForIdentityChange(
        previousIdentity: previousIdentity,
        nextIdentity: nextIdentity,
      );

  @override
  Future<void> clearForLogout(
          ApplicationChatStorageIdentity previousIdentity) =>
      delegate.clearForLogout(previousIdentity);
}

final class _FakeNetwork implements ChatRealtimeNetwork {
  _FakeNetwork(this._online);
  final bool _online;
  final StreamController<bool> _changes = StreamController<bool>.broadcast();

  @override
  bool get isOnline => _online;

  @override
  Stream<bool> get changes => _changes.stream;

  Future<void> dispose() => _changes.close();
}

final class _FakeSocket implements ChatRealtimeSocket {
  final StreamController<Object?> _frames = StreamController<Object?>();

  @override
  Stream<Object?> get frames => _frames.stream;

  @override
  Future<void> close() => _frames.close();

  @override
  void send(String data) {}
}

Future<HandrailChatHttpResponse> _standardHandler(
  HandrailChatHttpRequest request,
) async {
  if (request.uri.path.endsWith('/_meta')) return _metadataResponse;
  if (request.method == 'GET') return _json(_inactive);
  final input = jsonDecode(request.body!) as Map<String, Object?>;
  return _command(input, _starting, media: true);
}

HandrailChatHttpResponse _json(Object? value, {int statusCode = 200}) =>
    HandrailChatHttpResponse(statusCode: statusCode, body: jsonEncode(value));

HandrailChatHttpResponse _command(
  Map<String, Object?> input,
  Map<String, Object?> state, {
  bool media = false,
}) =>
    _json(<String, Object?>{
      'operation': input['operation'],
      'outcome': 'ok',
      'reconciliationStatus': 'applied',
      'state': state,
      if (media)
        'mediaJoin': <String, Object?>{
          'kind': 'opaque_media_join',
          'descriptor': 'SECRET-MEDIA-DESCRIPTOR',
          'expiresAt': '2030-01-01T00:04:00.000Z',
        },
    });

final _metadataResponse = _json(<String, Object?>{
  'packageVersion': '0.1.3',
  'protocolVersion': handrailChatProtocolVersion,
  'schemaVersion': 1,
  'enabledFeatures': <String, Object?>{
    'huddles': true,
    'media': true,
    'realtime': true,
  },
  'supportedProtocolRange': <String, Object?>{
    'minimumVersion': handrailChatProtocolVersion - 1,
    'maximumVersion': handrailChatProtocolVersion,
  },
});

const _inactive = <String, Object?>{
  'status': 'inactive',
  'conversationId': 'conversation-1',
};
const _starting = <String, Object?>{
  'status': 'starting',
  'conversationId': 'conversation-1',
  'huddleSessionId': 'huddle-1',
  'startedAt': '2030-01-01T00:00:01.000Z',
  'participants': <Object?>[],
  'screenShareOwnerUserId': null,
};
final _activeEmpty = <String, Object?>{
  ..._starting,
  'status': 'active',
};
final _active = <String, Object?>{
  ..._activeEmpty,
  'participants': <Object?>[
    <String, Object?>{
      'userId': 'user-alice',
      'status': 'joined',
      'joinedAt': '2030-01-01T00:00:02.000Z',
    },
  ],
};
final _sharing = <String, Object?>{
  ..._active,
  'screenShareOwnerUserId': 'user-alice',
};
final _left = <String, Object?>{
  ..._active,
  'participants': <Object?>[
    <String, Object?>{
      'userId': 'user-alice',
      'status': 'left',
      'joinedAt': '2030-01-01T00:00:02.000Z',
      'leftAt': '2030-01-01T00:00:03.000Z',
    },
  ],
};
const _ended = <String, Object?>{
  'status': 'ended',
  'conversationId': 'conversation-1',
  'huddleSessionId': 'huddle-1',
  'startedAt': '2030-01-01T00:00:01.000Z',
  'endedAt': '2030-01-01T00:00:04.000Z',
  'endedByUserId': 'user-alice',
  'participants': <Object?>[
    <String, Object?>{
      'userId': 'user-alice',
      'status': 'left',
      'joinedAt': '2030-01-01T00:00:02.000Z',
      'leftAt': '2030-01-01T00:00:04.000Z',
    },
  ],
  'screenShareOwnerUserId': null,
};
final _activeOtherSession = <String, Object?>{
  ..._activeEmpty,
  'huddleSessionId': 'huddle-2',
};
