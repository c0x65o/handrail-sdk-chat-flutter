import 'dart:async';
import 'dart:convert';

import 'package:handrail_chat/core.dart';
import 'package:test/test.dart';

void main() {
  group('ChatRealtimeSessionTransport', () {
    test('constructs ordered protocols, sends handshake, and accepts session',
        () async {
      final socket = FakeSocket();
      final factory = FakeSocketFactory()..sockets.add(socket);
      final session = createSession(socketFactory: factory.call);

      await session.start();

      expect(
          factory.uris, [Uri.parse('wss://chat.example/api/chat/_realtime')]);
      expect(factory.protocols.single, [
        chatRealtimeSubprotocol,
        '${chatRealtimeBearerSubprotocolPrefix}dMO2a2VuIOKYgw',
      ]);
      expect(jsonDecode(socket.sent.single), {
        'clientPackageVersion': '0.1.3',
        'protocolVersion': 4,
      });
      expect(session.state.state, 'connecting');

      socket.emitJson(acceptedFrame(resumeEventId: 'event-1'));
      await pumpEventQueue();

      expect(session.state, isA<ChatRealtimeConnectedState>());
      expect(session.state.state, 'connected');
      final connected = session.state as ChatRealtimeConnectedState;
      expect(connected.identity.tenantId, const TenantId('tenant-1'));
      expect(connected.identity.userId, const UserId('user-1'));
      expect(connected.identity.deviceId, const DeviceId('device-1'));
      expect(session.toString(), contains('state: connected'));
      expect(session.toString(), isNot(contains('töken')));
      await session.dispose();
    });

    test('loads only valid cursors and persists accepted cursors non-fatally',
        () async {
      final storage = FakeStorage(
        value: jsonEncode(<String, Object?>{'eventId': 'event-resume'}),
      );
      final socket = FakeSocket();
      final session = createSession(
        socketFactory: (uri, protocols) => socket,
        storage: storage,
      );

      await session.start();
      expect(jsonDecode(socket.sent.single), {
        'clientPackageVersion': '0.1.3',
        'protocolVersion': 4,
        'resumeFrom': {'eventId': 'event-resume'},
      });

      storage.throwOnWrite = true;
      socket.emitJson(acceptedFrame(resumeEventId: 'event-accepted'));
      await pumpEventQueue();
      expect(session.state, isA<ChatRealtimeConnectedState>());
      expect(storage.writes, [
        jsonEncode({'eventId': 'event-accepted'})
      ]);
      await session.dispose();

      final invalidStorage = FakeStorage(
        value: jsonEncode(<String, Object?>{'eventId': '   '}),
      );
      final invalidSocket = FakeSocket();
      final invalidSession = createSession(
        socketFactory: (uri, protocols) => invalidSocket,
        storage: invalidStorage,
      );
      await invalidSession.start();
      expect(jsonDecode(invalidSocket.sent.single), {
        'clientPackageVersion': '0.1.3',
        'protocolVersion': 4,
      });
      await invalidSession.dispose();
    });

    test('isolates cursor reads, writes, and clears by host identity scope',
        () async {
      final storage = FakeStorage()
        ..values['account-a:device-1'] =
            jsonEncode(<String, Object?>{'eventId': 'cursor-a'});
      final socketA = FakeSocket();
      final sessionA = createSession(
        socketFactory: (_, __) => socketA,
        storage: storage,
      );
      final socketB = FakeSocket();
      final sessionB = createSession(
        socketFactory: (_, __) => socketB,
        storage: storage,
        storageScope: 'account-b:device-1',
        hydrateSnapshot: (_) => Completer<EventCursor?>().future,
      );

      await sessionA.start();
      await sessionB.start();
      expect(
        jsonDecode(socketA.sent.single),
        containsPair('resumeFrom', <String, Object?>{'eventId': 'cursor-a'}),
      );
      expect(jsonDecode(socketB.sent.single), isNot(contains('resumeFrom')));
      expect(
        storage.reads,
        <String>['account-a:device-1', 'account-b:device-1'],
      );

      socketA.emitJson(acceptedFrame(resumeEventId: 'cursor-a-next'));
      socketB.emitJson(acceptedFrame(resumeEventId: 'cursor-b'));
      await pumpEventQueue();
      expect(storage.writeScopes,
          <String>['account-a:device-1', 'account-b:device-1']);

      socketB.emitJson(snapshotRequiredFrame('cursor-b'));
      await pumpEventQueue();
      expect(storage.clearedScopes, <String>['account-b:device-1']);
      expect(
        storage.values['account-a:device-1'],
        jsonEncode(<String, Object?>{'eventId': 'cursor-a-next'}),
      );
      expect(storage.values['account-b:device-1'], isNull);

      await sessionA.dispose();
      await sessionB.dispose();
    });

    test('requires a bounded cursor scope only when storage is configured',
        () async {
      for (final invalidScope in <String?>[
        null,
        '',
        ' account-a',
        List<String>.filled(
          maxChatRealtimeCursorStorageScopeUtf8Bytes + 1,
          'a',
        ).join(),
      ]) {
        expect(
          () => createSession(
            socketFactory: (_, __) => FakeSocket(),
            storage: FakeStorage(),
            storageScope: invalidScope,
          ),
          throwsArgumentError,
          reason: '$invalidScope',
        );
      }

      final storage = FakeStorage()..throwOnRead = true;
      final throwingSocket = FakeSocket();
      final throwingSession = createSession(
        socketFactory: (_, __) => throwingSocket,
        storage: storage,
      );
      await throwingSession.start();
      expect(jsonDecode(throwingSocket.sent.single),
          isNot(contains('resumeFrom')));
      await throwingSession.dispose();

      final storageFreeSocket = FakeSocket();
      final storageFreeSession = createSession(
        socketFactory: (_, __) => storageFreeSocket,
        storageScope: null,
      );
      await storageFreeSession.start();
      expect(jsonDecode(storageFreeSocket.sent.single),
          isNot(contains('resumeFrom')));
      await storageFreeSession.dispose();
    });

    test('hydrates snapshots, replaces cursor, and stops for refresh',
        () async {
      final storage = FakeStorage(
        value: jsonEncode(<String, Object?>{'eventId': 'event-expired'}),
      );
      final clock = FakeClock();
      final firstSocket = FakeSocket();
      final secondSocket = FakeSocket();
      final factory = FakeSocketFactory()
        ..sockets.addAll([firstSocket, secondSocket]);
      ChatRealtimeSnapshotHydrationInput? hydrationInput;
      final hydratedCursor = Completer<EventCursor?>();
      final session = createSession(
        socketFactory: factory.call,
        storage: storage,
        clock: clock,
        hydrateSnapshot: (input) {
          hydrationInput = input;
          return hydratedCursor.future;
        },
      );

      await session.start();
      storage.throwOnClear = true;
      firstSocket.emitJson(snapshotRequiredFrame('event-expired'));
      await pumpEventQueue();

      expect(session.state.state, 'hydratingSnapshot');
      expect(
        hydrationInput?.reason,
        ChatRealtimeSnapshotRecoveryReason.replayExpired,
      );
      expect(hydrationInput?.expiredCursor.eventId, 'event-expired');
      expect(storage.clearCount, 1);

      hydratedCursor.complete(const EventCursor(eventId: 'event-hydrated'));
      await pumpEventQueue();
      expect(session.state.state, 'reconnecting');
      expect(storage.writes.last, jsonEncode({'eventId': 'event-hydrated'}));
      expect(clock.delays.last, Duration.zero);

      clock.runNext();
      await pumpEventQueue();
      expect(jsonDecode(secondSocket.sent.single), {
        'clientPackageVersion': '0.1.3',
        'protocolVersion': 4,
        'resumeFrom': {'eventId': 'event-hydrated'},
      });

      secondSocket.emitJson(refreshRequiredFrame());
      await pumpEventQueue();
      expect(session.state, isA<ChatRealtimeRefreshRequiredState>());
      expect(session.state.state, 'refreshRequired');
      expect(secondSocket.closeCount, 1);
      expect(clock.activeCount, 0);
      await session.dispose();
    });

    test('recovers from token and malformed-frame failures with redaction',
        () async {
      const secret = 'SECRET-token-and-frame';
      final diagnostics = <ChatRealtimeDiagnostic>[];
      final states = <ChatRealtimeLifecycleState>[];
      final clock = FakeClock();
      final socket = FakeSocket();
      var tokenCalls = 0;
      final session = createSession(
        tokenProvider: () {
          tokenCalls += 1;
          if (tokenCalls == 1) throw StateError(secret);
          return secret;
        },
        socketFactory: (uri, protocols) => socket,
        clock: clock,
        onDiagnostic: diagnostics.add,
        onStateChange: states.add,
      );

      await session.start();
      expect(session.state, isA<ChatRealtimeReconnectingState>());
      expect(diagnostics.single.code,
          ChatRealtimeDiagnosticCode.accessTokenFailed);
      expect(diagnostics.single.toString(), isNot(contains(secret)));
      expect(session.state.toString(), isNot(contains(secret)));

      clock.runNext();
      await pumpEventQueue();
      socket.emit('$secret{not-json');
      await pumpEventQueue();

      expect(diagnostics.last.code,
          ChatRealtimeDiagnosticCode.malformedServerFrame);
      expect(diagnostics.map((value) => value.toString()).join(),
          isNot(contains(secret)));
      expect(states.map((value) => value.toString()).join(),
          isNot(contains(secret)));

      clock.runNext();
      await pumpEventQueue();
      socket.emit(<int>[0, 1, 2]);
      await pumpEventQueue();
      expect(diagnostics.last.code,
          ChatRealtimeDiagnosticCode.malformedServerFrame);
      await session.dispose();
    });

    test('snapshot failure retries with bounded redacted diagnostics',
        () async {
      const secret = 'snapshot-provider-secret';
      final diagnostics = <ChatRealtimeDiagnostic>[];
      final clock = FakeClock();
      final socket = FakeSocket();
      final session = createSession(
        socketFactory: (uri, protocols) => socket,
        clock: clock,
        hydrateSnapshot: (input) => throw StateError(secret),
        onDiagnostic: diagnostics.add,
      );

      await session.start();
      socket.emitJson(snapshotRequiredFrame('event-expired'));
      await pumpEventQueue();

      expect(session.state.state, 'reconnecting');
      expect(reconnectState(session).delay, isNot(Duration.zero));
      expect(diagnostics.last.code,
          ChatRealtimeDiagnosticCode.snapshotHydrationFailed);
      expect(diagnostics.last.toString(), isNot(contains(secret)));
      await session.dispose();
    });

    test('pauses all work offline and resumes with a fresh connection',
        () async {
      final network = FakeNetwork(isOnline: false);
      final firstSocket = FakeSocket();
      final secondSocket = FakeSocket();
      final factory = FakeSocketFactory()
        ..sockets.addAll([firstSocket, secondSocket]);
      final session = createSession(
        socketFactory: factory.call,
        network: network,
      );

      await session.start();
      expect(session.state.state, 'offline');
      expect(factory.callCount, 0);

      network.setOnline(true);
      await pumpEventQueue();
      expect(factory.callCount, 1);
      expect(session.state.state, 'connecting');

      network.setOnline(false);
      await pumpEventQueue();
      expect(session.state.state, 'offline');
      expect(firstSocket.closeCount, 1);

      network.setOnline(true);
      await pumpEventQueue();
      expect(factory.callCount, 2);
      expect(secondSocket.sent, hasLength(1));
      await session.dispose();
    });

    test('uses bounded deterministic backoff and resets after acceptance',
        () async {
      final clock = FakeClock();
      final socket = FakeSocket();
      var calls = 0;
      FutureOr<ChatRealtimeSocket> factory(
        Uri uri,
        List<String> protocols,
      ) {
        calls += 1;
        if (calls == 1) throw StateError('synchronous secret');
        if (calls == 2) {
          return Future<ChatRealtimeSocket>.error(
            StateError('asynchronous secret'),
          );
        }
        return socket;
      }

      final session = createSession(
        socketFactory: factory,
        clock: clock,
        random: () => 1,
        retry: const ChatRealtimeRetryOptions(
          initialDelay: Duration(milliseconds: 100),
          maximumDelay: Duration(milliseconds: 250),
          multiplier: 2,
          jitterRatio: 0.5,
        ),
      );

      await session.start();
      expect(reconnectState(session).attempt, 1);
      expect(reconnectState(session).delay, const Duration(milliseconds: 150));

      clock.runNext();
      await pumpEventQueue();
      expect(reconnectState(session).attempt, 2);
      expect(reconnectState(session).delay, const Duration(milliseconds: 250));

      clock.runNext();
      await pumpEventQueue();
      socket.emitJson(acceptedFrame());
      await pumpEventQueue();
      expect(session.state.state, 'connected');

      socket.serverClose();
      await pumpEventQueue();
      expect(reconnectState(session).attempt, 1);
      expect(reconnectState(session).delay, const Duration(milliseconds: 150));
      await session.dispose();
    });

    test('restart closes the old socket and loads its accepted cursor',
        () async {
      final storage = FakeStorage();
      final firstSocket = FakeSocket();
      final secondSocket = FakeSocket();
      final factory = FakeSocketFactory()
        ..sockets.addAll([firstSocket, secondSocket]);
      final session = createSession(
        socketFactory: factory.call,
        storage: storage,
      );

      await session.start();
      firstSocket.emitJson(acceptedFrame(resumeEventId: 'restart-cursor'));
      await pumpEventQueue();
      await session.restart();

      expect(firstSocket.closeCount, 1);
      expect(factory.callCount, 2);
      expect(jsonDecode(secondSocket.sent.single), {
        'clientPackageVersion': '0.1.3',
        'protocolVersion': 4,
        'resumeFrom': {'eventId': 'restart-cursor'},
      });
      await session.dispose();
    });

    test('stale asynchronous socket attempts cannot regain authority',
        () async {
      final staleFactory = Completer<ChatRealtimeSocket>();
      final staleSocket = FakeSocket();
      final activeSocket = FakeSocket();
      var calls = 0;
      FutureOr<ChatRealtimeSocket> factory(
        Uri uri,
        List<String> protocols,
      ) {
        calls += 1;
        if (calls == 1) return staleFactory.future;
        return activeSocket;
      }

      final session = createSession(socketFactory: factory);
      final firstStart = session.start();
      await pumpEventQueue();
      final restarted = session.restart();
      await restarted;
      expect(activeSocket.sent, hasLength(1));

      staleFactory.complete(staleSocket);
      await firstStart;
      await pumpEventQueue();
      expect(staleSocket.closeCount, 1);
      expect(staleSocket.sent, isEmpty);
      expect(calls, 2);
      expect(session.state.state, 'connecting');
      await session.dispose();
    });

    test('dispose cancels listeners and timers and never reconnects', () async {
      final network = FakeNetwork();
      final clock = FakeClock();
      final activeSocket = FakeSocket();
      final activeFactory = FakeSocketFactory()..sockets.add(activeSocket);
      final activeSession = createSession(
        socketFactory: activeFactory.call,
        network: network,
        clock: clock,
      );

      await activeSession.start();
      expect(network.hasListener, isTrue);
      await activeSession.dispose();
      await activeSession.dispose();
      expect(activeSocket.closeCount, 1);
      expect(network.hasListener, isFalse);
      expect(activeSession.state.state, 'idle');

      network.setOnline(false);
      network.setOnline(true);
      await pumpEventQueue();
      expect(activeFactory.callCount, 1);

      final retryClock = FakeClock();
      var retryCalls = 0;
      final retrySession = createSession(
        socketFactory: (uri, protocols) {
          retryCalls += 1;
          throw StateError('unavailable');
        },
        clock: retryClock,
      );
      await retrySession.start();
      expect(retryClock.activeCount, 1);
      await retrySession.dispose();
      expect(retryClock.activeCount, 0);
      retryClock.runAll();
      await pumpEventQueue();
      expect(retryCalls, 1);
    });

    test(
        'reference counts conversations and sends identity-safe frames only after acceptance',
        () async {
      final socket = FakeSocket();
      final states = <ChatRealtimeConversationSubscriptionState>[];
      final session = createSession(
        socketFactory: (uri, protocols) => socket,
        onConversationSubscriptionStateChange: states.add,
      );
      const conversationId = ConversationId('conversation-1');

      final releaseFirst = session.subscribeConversation(conversationId);
      final releaseSecond = session.subscribeConversation(conversationId);
      expect(states, hasLength(1));
      expect(states.single,
          isA<ChatRealtimeConversationSubscriptionPendingState>());

      await session.start();
      expect(sentJsonFrames(socket), hasLength(1));
      socket.emitJson(acceptedFrame());
      await pumpEventQueue();

      final subscribeFrames = subscriptionFrames(
        socket,
        type: 'chat.subscribe',
      );
      expect(subscribeFrames, hasLength(2));
      expect(
        subscribeFrames.where((frame) => frame['streamId'] == 'user:user-1'),
        hasLength(1),
      );
      final conversationSubscribe = subscribeFrames.singleWhere(
        (frame) => frame['streamId'] == conversationId.value,
      );
      expect(
        conversationSubscribe.keys,
        unorderedEquals(<String>['type', 'requestId', 'streamId']),
      );
      expect(conversationSubscribe, isNot(contains('tenantId')));
      expect(conversationSubscribe, isNot(contains('actorStreamId')));
      expect(conversationSubscribe, isNot(contains('userId')));
      expect(conversationSubscribe, isNot(contains('deviceId')));
      expect(conversationSubscribe, isNot(contains('sessionId')));

      socket.emitJson(subscriptionAcceptedFrame(conversationSubscribe));
      await pumpEventQueue();
      expect(
        session.conversationSubscriptionStatesById[conversationId.value],
        isA<ChatRealtimeConversationSubscriptionAcceptedState>(),
      );

      releaseFirst();
      expect(subscriptionFrames(socket, type: 'chat.unsubscribe'), isEmpty);
      releaseSecond();
      final unsubscribeFrames = subscriptionFrames(
        socket,
        type: 'chat.unsubscribe',
      );
      expect(unsubscribeFrames, hasLength(1));
      releaseSecond();
      expect(
          subscriptionFrames(socket, type: 'chat.unsubscribe'), hasLength(1));

      socket.emitJson(subscriptionRemovedFrame(unsubscribeFrames.single));
      await pumpEventQueue();
      expect(
        session.conversationSubscriptionStatesById[conversationId.value],
        isA<ChatRealtimeConversationSubscriptionRemovedState>(),
      );
      await session.dispose();
    });

    test('replays desired conversations after reconnect acceptance', () async {
      final clock = FakeClock();
      final firstSocket = FakeSocket();
      final secondSocket = FakeSocket();
      final factory = FakeSocketFactory()
        ..sockets.addAll(<FakeSocket>[firstSocket, secondSocket]);
      final session = createSession(
        socketFactory: factory.call,
        clock: clock,
      );
      const conversationId = ConversationId('conversation-replay');
      session.subscribeConversation(conversationId);

      await session.start();
      firstSocket.emitJson(acceptedFrame());
      await pumpEventQueue();
      final firstSubscribe = subscriptionFrames(
        firstSocket,
        type: 'chat.subscribe',
        streamId: conversationId.value,
      ).single;
      firstSocket.emitJson(subscriptionAcceptedFrame(firstSubscribe));
      await pumpEventQueue();

      firstSocket.serverClose();
      await pumpEventQueue();
      expect(session.state, isA<ChatRealtimeReconnectingState>());
      clock.runNext();
      await pumpEventQueue();
      expect(sentJsonFrames(secondSocket), hasLength(1));

      secondSocket.emitJson(subscriptionAcceptedFrame(firstSubscribe));
      await pumpEventQueue();
      expect(session.state.state, 'connecting');
      secondSocket.emitJson(acceptedFrame());
      await pumpEventQueue();
      final replaySubscribe = subscriptionFrames(
        secondSocket,
        type: 'chat.subscribe',
        streamId: conversationId.value,
      ).single;
      expect(replaySubscribe['requestId'], isNot(firstSubscribe['requestId']));

      secondSocket.emitJson(subscriptionAcceptedFrame(firstSubscribe));
      await pumpEventQueue();
      final pending =
          session.conversationSubscriptionStatesById[conversationId.value];
      expect(pending, isA<ChatRealtimeConversationSubscriptionPendingState>());
      expect(
        (pending! as ChatRealtimeConversationSubscriptionPendingState)
            .requestId,
        replaySubscribe['requestId'],
      );

      secondSocket.emitJson(subscriptionAcceptedFrame(replaySubscribe));
      await pumpEventQueue();
      expect(
        session.conversationSubscriptionStatesById[conversationId.value],
        isA<ChatRealtimeConversationSubscriptionAcceptedState>(),
      );
      await session.dispose();
    });

    test('surfaces typed rejection codes only for current operations',
        () async {
      final socket = FakeSocket();
      final session = createSession(socketFactory: (uri, protocols) => socket);
      const cases = <String, ChatRealtimeSubscriptionErrorCode>{
        'conversation-denied': ChatRealtimeSubscriptionErrorCode.accessDenied,
        'conversation-malformed':
            ChatRealtimeSubscriptionErrorCode.malformedRequest,
        'conversation-invalid': ChatRealtimeSubscriptionErrorCode.invalidStream,
      };
      for (final conversationId in cases.keys) {
        session.subscribeConversation(ConversationId(conversationId));
      }

      await session.start();
      socket.emitJson(acceptedFrame());
      await pumpEventQueue();
      for (final entry in cases.entries) {
        final request = subscriptionFrames(
          socket,
          type: 'chat.subscribe',
          streamId: entry.key,
        ).single;
        socket.emitJson(<String, Object?>{
          'type': 'chat.subscription.rejected',
          'code': entry.value.wireValue,
          'requestId': request['requestId'],
        });
      }
      await pumpEventQueue();

      for (final entry in cases.entries) {
        final state = session.conversationSubscriptionStatesById[entry.key];
        expect(state, isA<ChatRealtimeConversationSubscriptionRejectedState>());
        expect(
          (state! as ChatRealtimeConversationSubscriptionRejectedState).code,
          entry.value,
        );
        expect(state.state, entry.value.wireValue);
      }
      await session.dispose();
    });

    test('isolates stale acknowledgements across release and re-retain',
        () async {
      final socket = FakeSocket();
      final session = createSession(socketFactory: (uri, protocols) => socket);
      const conversationId = ConversationId('conversation-current');
      final release = session.subscribeConversation(conversationId);

      await session.start();
      socket.emitJson(acceptedFrame());
      await pumpEventQueue();
      final oldSubscribe = subscriptionFrames(
        socket,
        type: 'chat.subscribe',
        streamId: conversationId.value,
      ).single;
      release();
      final oldUnsubscribe = subscriptionFrames(
        socket,
        type: 'chat.unsubscribe',
        streamId: conversationId.value,
      ).single;
      session.subscribeConversation(conversationId);
      final currentSubscribe = subscriptionFrames(
        socket,
        type: 'chat.subscribe',
        streamId: conversationId.value,
      ).last;

      socket.emitJson(subscriptionAcceptedFrame(oldSubscribe));
      socket.emitJson(subscriptionRemovedFrame(oldUnsubscribe));
      socket.emitJson(<String, Object?>{
        'type': 'chat.subscription.rejected',
        'code': 'access_denied',
        'requestId': oldSubscribe['requestId'],
      });
      socket.emitJson(<String, Object?>{
        'type': 'chat.subscription.revoked',
        'code': 'access_revoked',
        'streamId': conversationId.value,
      });
      await pumpEventQueue();

      final pending =
          session.conversationSubscriptionStatesById[conversationId.value];
      expect(pending, isA<ChatRealtimeConversationSubscriptionPendingState>());
      expect(
        (pending! as ChatRealtimeConversationSubscriptionPendingState)
            .requestId,
        currentSubscribe['requestId'],
      );

      socket.emitJson(<String, Object?>{
        'type': 'chat.subscription.accepted',
        'requestId': currentSubscribe['requestId'],
        'streamId': 'conversation-wrong',
      });
      await pumpEventQueue();
      expect(
        session.conversationSubscriptionStatesById[conversationId.value],
        isA<ChatRealtimeConversationSubscriptionPendingState>(),
      );
      socket.emitJson(subscriptionAcceptedFrame(currentSubscribe));
      await pumpEventQueue();
      socket.emitJson(<String, Object?>{
        'type': 'chat.subscription.revoked',
        'code': 'access_revoked',
        'streamId': conversationId.value,
      });
      await pumpEventQueue();
      final revoked =
          session.conversationSubscriptionStatesById[conversationId.value];
      expect(revoked, isA<ChatRealtimeConversationSubscriptionRevokedState>());
      expect(revoked!.state, 'access_revoked');
      await session.dispose();
    });

    test('rejects actor, user, broad tenant, and malformed stream ids',
        () async {
      final session = createSession(
        socketFactory: (uri, protocols) => FakeSocket(),
      );
      const invalidIds = <String>[
        '',
        ' conversation-1',
        'conversation 1',
        'conversation-*',
        'user:user-1',
        'USER:user-1',
        'all',
        'tenant:tenant-1',
        'organization/conversations',
        'org:any',
      ];
      for (final value in invalidIds) {
        expect(
          () => session.subscribeConversation(ConversationId(value)),
          throwsArgumentError,
          reason: value,
        );
      }
      expect(session.conversationSubscriptionStatesById, isEmpty);
      await session.dispose();
    });
  });
}

ChatRealtimeSessionTransport createSession({
  ChatRealtimeAccessTokenProvider? tokenProvider,
  required ChatRealtimeSocketFactory socketFactory,
  ChatRealtimeNetwork? network,
  ChatRealtimeCursorStorage? storage,
  String? storageScope = 'account-a:device-1',
  ChatRealtimeClock? clock,
  double Function()? random,
  ChatRealtimeRetryOptions retry = const ChatRealtimeRetryOptions(),
  ChatRealtimeSnapshotHydrator? hydrateSnapshot,
  ChatRealtimeDiagnosticListener? onDiagnostic,
  void Function(ChatRealtimeLifecycleState state)? onStateChange,
  ChatRealtimeConversationSubscriptionListener?
      onConversationSubscriptionStateChange,
}) =>
    ChatRealtimeSessionTransport(
      endpoint: Uri.parse('https://chat.example/api/chat/'),
      clientPackageVersion: '0.1.3',
      protocolVersion: 4,
      tokenProvider: tokenProvider ?? () => 'töken ☃',
      socketFactory: socketFactory,
      network: network,
      cursorStorage: storage,
      cursorStorageScope: storage == null ? null : storageScope,
      clock: clock,
      random: random,
      retry: retry,
      hydrateSnapshot: hydrateSnapshot,
      onDiagnostic: onDiagnostic,
      onStateChange: onStateChange,
      onConversationSubscriptionStateChange:
          onConversationSubscriptionStateChange,
    );

ChatRealtimeReconnectingState reconnectState(
  ChatRealtimeSessionTransport session,
) =>
    session.state as ChatRealtimeReconnectingState;

Map<String, Object?> acceptedFrame({String? resumeEventId}) =>
    <String, Object?>{
      'type': 'chat.session.accepted',
      'metadata': metadata,
      'tenantId': 'tenant-1',
      'actorStreamId': 'user:user-1',
      'deviceId': 'device-1',
      'sessionId': 'session-1',
      if (resumeEventId != null) 'resumeFrom': {'eventId': resumeEventId},
    };

List<Map<String, Object?>> sentJsonFrames(FakeSocket socket) => socket.sent
    .map((frame) => Map<String, Object?>.from(
          jsonDecode(frame) as Map<Object?, Object?>,
        ))
    .toList(growable: false);

List<Map<String, Object?>> subscriptionFrames(
  FakeSocket socket, {
  required String type,
  String? streamId,
}) =>
    sentJsonFrames(socket)
        .where(
          (frame) =>
              frame['type'] == type &&
              (streamId == null || frame['streamId'] == streamId),
        )
        .toList(growable: false);

Map<String, Object?> subscriptionAcceptedFrame(
  Map<String, Object?> request,
) =>
    <String, Object?>{
      'type': 'chat.subscription.accepted',
      'requestId': request['requestId'],
      'streamId': request['streamId'],
    };

Map<String, Object?> subscriptionRemovedFrame(
  Map<String, Object?> request,
) =>
    <String, Object?>{
      'type': 'chat.subscription.removed',
      'requestId': request['requestId'],
      'streamId': request['streamId'],
    };

Map<String, Object?> snapshotRequiredFrame(String cursor) => <String, Object?>{
      'type': 'chat.session.snapshot_required',
      'state': 'snapshot_required',
      'reason': 'replay_expired',
      'metadata': metadata,
      'resumeFrom': {'eventId': cursor},
    };

Map<String, Object?> refreshRequiredFrame() => <String, Object?>{
      'type': 'chat.session.refresh_required',
      'state': 'refresh_required',
      'reason': 'unsupported_protocol',
      'message': chatRefreshRequiredMessage,
      'requestedProtocolVersion': 4,
      'metadata': metadata,
    };

const Map<String, Object?> metadata = <String, Object?>{
  'packageVersion': '0.1.3',
  'protocolVersion': 4,
  'schemaVersion': 1,
  'enabledFeatures': <String, Object?>{'typing': true},
  'supportedProtocolRange': <String, Object?>{
    'minimumVersion': 3,
    'maximumVersion': 4,
  },
};

Future<void> pumpEventQueue([int times = 4]) async {
  for (var index = 0; index < times; index += 1) {
    await Future<void>.delayed(Duration.zero);
  }
}

final class FakeSocket implements ChatRealtimeSocket {
  final StreamController<Object?> _frames =
      StreamController<Object?>.broadcast(sync: true);
  final List<String> sent = <String>[];
  var closeCount = 0;
  var throwOnSend = false;

  @override
  Stream<Object?> get frames => _frames.stream;

  @override
  void send(String data) {
    if (throwOnSend) throw StateError('send secret');
    sent.add(data);
  }

  @override
  void close() {
    closeCount += 1;
  }

  void emit(Object? value) => _frames.add(value);

  void emitJson(Map<String, Object?> value) => emit(jsonEncode(value));

  void serverClose() => _frames.close();
}

final class FakeSocketFactory {
  final List<FakeSocket> sockets = <FakeSocket>[];
  final List<Uri> uris = <Uri>[];
  final List<List<String>> protocols = <List<String>>[];
  var callCount = 0;

  ChatRealtimeSocket call(Uri uri, List<String> socketProtocols) {
    uris.add(uri);
    protocols.add(List<String>.of(socketProtocols));
    final socket = sockets[callCount];
    callCount += 1;
    return socket;
  }
}

final class FakeStorage implements ChatRealtimeCursorStorage {
  FakeStorage({String? value}) {
    if (value != null) values['account-a:device-1'] = value;
  }

  final Map<String, String> values = <String, String>{};
  final List<String> reads = <String>[];
  final List<String> writeScopes = <String>[];
  final List<String> writes = <String>[];
  final List<String> clearedScopes = <String>[];
  var clearCount = 0;
  var throwOnRead = false;
  var throwOnWrite = false;
  var throwOnClear = false;

  @override
  String? read({required String scope}) {
    if (throwOnRead) throw StateError('storage read secret');
    reads.add(scope);
    return values[scope];
  }

  @override
  void write({required String scope, required String value}) {
    writeScopes.add(scope);
    writes.add(value);
    if (throwOnWrite) throw StateError('storage write secret');
    values[scope] = value;
  }

  @override
  void clear({required String scope}) {
    clearCount += 1;
    clearedScopes.add(scope);
    if (throwOnClear) throw StateError('storage clear secret');
    values.remove(scope);
  }
}

final class FakeNetwork implements ChatRealtimeNetwork {
  FakeNetwork({this.isOnline = true});

  final StreamController<bool> _changes =
      StreamController<bool>.broadcast(sync: true);

  @override
  bool isOnline;

  @override
  Stream<bool> get changes => _changes.stream;

  bool get hasListener => _changes.hasListener;

  void setOnline(bool value) {
    isOnline = value;
    _changes.add(value);
  }
}

final class FakeClock implements ChatRealtimeClock {
  final List<_FakeTimer> _timers = <_FakeTimer>[];
  final List<Duration> delays = <Duration>[];

  int get activeCount => _timers.where((timer) => timer.isActive).length;

  @override
  ChatRealtimeTimer schedule(Duration delay, void Function() callback) {
    delays.add(delay);
    final timer = _FakeTimer(callback);
    _timers.add(timer);
    return timer;
  }

  void runNext() {
    final timer = _timers.firstWhere((candidate) => candidate.isActive);
    timer.run();
  }

  void runAll() {
    for (final timer in List<_FakeTimer>.of(_timers)) {
      if (timer.isActive) timer.run();
    }
  }
}

final class _FakeTimer implements ChatRealtimeTimer {
  _FakeTimer(this._callback);

  final void Function() _callback;
  var isActive = true;

  @override
  void cancel() => isActive = false;

  void run() {
    if (!isActive) return;
    isActive = false;
    _callback();
  }
}
