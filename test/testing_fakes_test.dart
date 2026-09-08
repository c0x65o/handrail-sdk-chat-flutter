import 'dart:async';
import 'dart:convert';

import 'package:handrail_chat/testing.dart';
import 'package:test/test.dart';

const _credentialSecret = 'SECRET_ACCESS_TOKEN_SENTINEL';
const _descriptorSecret = 'SECRET_MEDIA_DESCRIPTOR_SENTINEL';
final _testNow = DateTime.utc(2030);

void main() {
  group('testing.dart fakes', () {
    test('scripted HTTP, access tokens, and diagnostics drive the real client',
        () async {
      final tokens = ScriptedAccessTokenProvider(
        fallbackToken: _credentialSecret,
      )..enqueueError(StateError('provider:$_credentialSecret'));
      final http = ScriptedHandrailChatHttpTransport()
        ..enqueueError(StateError('network:$_credentialSecret'))
        ..enqueueJson(_metadata());
      final diagnostics = CredentialSafeDiagnosticRecorder();
      final client = HandrailChatClient(
        apiBaseUri: Uri.parse('https://chat.example.test/api/chat'),
        tokenProvider: tokens.call,
        transport: http,
      );

      final tokenFailure = await client.initialize();
      diagnostics.recordClient(
        (tokenFailure as ChatClientErrorState).diagnostic,
      );
      final requestFailure = await client.initialize();
      diagnostics.recordClient(
        (requestFailure as ChatClientErrorState).diagnostic,
      );
      final ready = await client.initialize();

      expect(ready, isA<ChatClientReadyState>());
      expect(tokens.callCount, 3);
      expect(http.requests, hasLength(2));
      expect(http.requests.first.method, 'GET');
      expect(
        http.requests.first.headers['Authorization'],
        'Bearer $_credentialSecret',
      );
      expect(
        <Object?>[
          tokens,
          http,
          ...http.requests,
          diagnostics,
        ].join('\n'),
        isNot(contains(_credentialSecret)),
      );

      await client.dispose();
      http.reset();
      tokens.reset(fallbackToken: 'replacement');
      diagnostics.reset();
      expect(http.requests, isEmpty);
      expect(tokens.callCount, 0);
      expect(diagnostics.records, isEmpty);
      http.dispose();
      http.dispose();
    });

    test('realtime fakes preserve connection, frame, and timer ordering',
        () async {
      final clock = FakeChatClock(_testNow);
      final network = FakeChatRealtimeNetwork();
      final socket = FakeChatRealtimeSocket();
      final factory = FakeChatRealtimeSocketFactory()
        ..enqueueError(StateError('first socket unavailable'))
        ..enqueueSocket(socket);
      final diagnostics = CredentialSafeDiagnosticRecorder();
      final session = ChatRealtimeSessionTransport(
        endpoint: Uri.parse('https://chat.example.test/api/chat'),
        clientPackageVersion: '0.1.3',
        protocolVersion: handrailChatProtocolVersion,
        tokenProvider: () => _credentialSecret,
        socketFactory: factory.call,
        network: network,
        clock: clock,
        random: () => 0.5,
        retry: const ChatRealtimeRetryOptions(jitterRatio: 0),
        onDiagnostic: diagnostics.recordRealtime,
      );

      await session.start();
      expect(session.state, isA<ChatRealtimeReconnectingState>());
      expect(clock.pendingTimerCount, 1);

      clock.runNext();
      await _pumpEventQueue();
      expect(factory.uris, hasLength(2));
      expect(socket.sent, hasLength(1));
      expect(jsonDecode(socket.sent.single), <String, Object?>{
        'clientPackageVersion': '0.1.3',
        'protocolVersion': handrailChatProtocolVersion,
      });

      socket.emitJson(_acceptedFrame());
      await _pumpEventQueue();
      expect(session.state, isA<ChatRealtimeConnectedState>());
      expect(
        diagnostics.records.single.code,
        ChatRealtimeDiagnosticCode.socketConnectionFailed,
      );
      expect(diagnostics.toString(), isNot(contains(_credentialSecret)));

      final frames = <Object?>[];
      final frameSubscription = socket.frames.listen(frames.add);
      socket.emitFrame('first');
      socket.emitFrame('second');
      expect(frames, <Object?>['first', 'second']);

      await session.dispose();
      await session.dispose();
      expect(socket.closeCount, 1);
      await frameSubscription.cancel();
      await network.dispose();
      await network.dispose();
      clock.dispose();
      clock.dispose();
    });

    test('one clock deterministically drives public scheduler boundaries',
        () async {
      final clock = FakeChatClock(_testNow);
      final order = <String>[];
      clock.schedule(const Duration(seconds: 2), () => order.add('later'));
      clock.schedule(const Duration(seconds: 1), () {
        order.add('first');
        clock.schedule(Duration.zero, () => order.add('nested'));
      });
      clock.schedule(const Duration(seconds: 1), () => order.add('second'));
      final cancelled = clock.schedule(
        const Duration(seconds: 1),
        () => order.add('cancelled'),
      );
      cancelled.cancel();

      clock.elapse(const Duration(seconds: 1));
      expect(order, <String>['first', 'second', 'nested']);
      expect(clock.now(), _testNow.add(const Duration(seconds: 1)));
      expect(clock.pendingTimerCount, 1);

      final reads = <ChatMarkReadInput>[];
      final coordinator = ChatReadVisibilityCoordinator(
        markRead: (input) async {
          reads.add(input);
          return const ChatCommandTransportFailure<ReadCursorMutationResult>();
        },
        minimumExposure: const Duration(seconds: 1),
        failureRetryDelay: const Duration(seconds: 2),
        clock: clock.now,
        scheduler: clock,
        generateIdempotencyKey: () => 'read-test-key',
      );
      const conversationId = ConversationId('conversation-clock');
      coordinator.setApplicationForeground(true);
      coordinator.setConversationActive(conversationId, isActive: true);
      coordinator.reportVisibleThrough(
        conversationId: conversationId,
        sequence: const MessageSequence(12),
      );

      clock.elapse(const Duration(seconds: 1));
      await _pumpEventQueue();
      expect(reads.map((input) => input.throughSequence.value), <int>[12]);
      clock.elapse(const Duration(seconds: 2));
      await _pumpEventQueue();
      expect(reads.map((input) => input.throughSequence.value), <int>[12, 12]);

      coordinator.dispose();
      clock.reset();
      expect(clock.now(), _testNow);
      expect(clock.pendingTimerCount, 0);
    });

    test('connectivity and device delegates are controllable and disposable',
        () async {
      final delegate = FakeChatConnectivityDelegate(
        current: ChatConnectivityStatus.offline,
      );
      final diagnostics = CredentialSafeDiagnosticRecorder();
      final network = ChatRealtimeNetworkAdapter(
        delegate: delegate,
        onDiagnostic: diagnostics.recordIntegration,
      );
      final changes = <bool>[];
      final subscription = network.changes.listen(changes.add);

      await network.initialize();
      expect(network.isOnline, isFalse);
      delegate.emit(ChatConnectivityStatus.online);
      delegate.emit(ChatConnectivityStatus.online);
      delegate.emit(ChatConnectivityStatus.offline);
      expect(changes, <bool>[true, false]);

      final identity = FakeChatDeviceIdentityDelegate()
        ..enqueueError(StateError('private device provider detail'))
        ..enqueueDeviceId('device-safe');
      await expectLater(
        identity.getOrCreateDeviceId(identityScopeKey: 'account-a'),
        throwsStateError,
      );
      expect(
        await identity.getOrCreateDeviceId(identityScopeKey: 'account-b'),
        'device-safe',
      );
      expect(identity.identityScopeKeys, <Object?>['account-a', 'account-b']);
      expect(identity.toString(), isNot(contains('device-safe')));
      identity.reset(fallbackDeviceId: 'device-next');
      expect(identity.identityScopeKeys, isEmpty);

      await network.dispose();
      await network.dispose();
      await subscription.cancel();
      await delegate.dispose();
      await delegate.dispose();
    });

    test('media fakes drive the public huddle media session safely', () async {
      final http = ScriptedHandrailChatHttpTransport()
        ..enqueueJson(_huddleResponse(
          operation: 'start_huddle',
          state: _startingHuddle,
          includeDescriptor: true,
        ))
        ..enqueueJson(_huddleResponse(
          operation: 'join_huddle',
          state: _activeHuddle,
          includeDescriptor: true,
        ));
      final clock = FakeChatClock(_testNow);
      final client = HandrailChatClient(
        apiBaseUri: Uri.parse('https://chat.example.test/api/chat'),
        tokenProvider: () async => _credentialSecret,
        transport: http,
        generateIdempotencyKey: () => 'huddle-test-key',
        huddleClock: clock.now,
        huddleTimerScheduler: clock.scheduleHuddle,
      );
      final controller = client.huddles.forConversation(
        const ConversationId('conversation-media'),
      );
      await controller.start();
      await controller.join();

      final provider = FakeChatMediaProviderSession();
      provider.queueError(
        ChatMediaOperation.microphone,
        StateError('provider:$_descriptorSecret'),
      );
      final delegate = FakeChatMediaDelegate(fallbackSession: provider);
      final media = ChatHuddleMediaSession(
        controller: controller,
        delegate: delegate,
      );
      final deviceStates = <ChatMediaDeviceState>[];
      final deviceSubscription = media.deviceStates.listen(deviceStates.add);

      await media.connect();
      await expectLater(
        media.setMicrophoneEnabled(true),
        throwsA(isA<ChatMediaException>()),
      );
      await media.setMicrophoneEnabled(true);
      provider.emitDevices(
        ChatMediaDeviceState(
          devices: const <ChatMediaDevice>[
            ChatMediaDevice(
              id: 'microphone-1',
              kind: ChatMediaDeviceKind.audioInput,
              label: 'Test microphone',
              isDefault: true,
            ),
          ],
          selectedAudioInputId: 'microphone-1',
        ),
      );
      await _pumpEventQueue();

      expect(delegate.connectCount, 1);
      expect(
        delegate.connectedDescriptors.single.descriptor,
        _descriptorSecret,
      );
      expect(delegate.permissionRequests, <ChatMediaPermission>[
        ChatMediaPermission.microphone,
        ChatMediaPermission.microphone,
      ]);
      expect(
        provider.calls.map((call) => call.operation),
        <ChatMediaOperation>[
          ChatMediaOperation.microphone,
          ChatMediaOperation.microphone,
        ],
      );
      expect(deviceStates.last.selectedAudioInputId, 'microphone-1');

      final recorder = CredentialSafeDiagnosticRecorder()
        ..recordMediaDescriptor(delegate.connectedDescriptors.single);
      expect(
        <Object?>[delegate, provider, ...provider.calls, recorder].join('\n'),
        isNot(contains(_descriptorSecret)),
      );

      await media.close();
      await media.close();
      await media.dispose();
      expect(provider.closeCount, 1);
      await deviceSubscription.cancel();
      await client.dispose();
      clock.dispose();
    });

    test('in-memory storage retains identity isolation and supports reset data',
        () async {
      final storage = InMemoryApplicationChatStorage();
      final first = ApplicationChatStorageIdentity(
        tenantId: const TenantId('tenant-a'),
        userId: const UserId('user-a'),
        deviceId: const DeviceId('device-a'),
      );
      final second = ApplicationChatStorageIdentity(
        tenantId: const TenantId('tenant-a'),
        userId: const UserId('user-b'),
        deviceId: const DeviceId('device-a'),
      );
      await storage.replace(ApplicationChatRealtimeCursorRecord(
        identity: first,
        cursor: const EventCursor(eventId: 'event-first'),
      ));
      await storage.replace(ApplicationChatRealtimeCursorRecord(
        identity: second,
        cursor: const EventCursor(eventId: 'event-second'),
      ));

      await storage.clearForLogout(first);
      expect(
        await storage.read(
          first,
          ApplicationChatStorageRecordKind.realtimeCursor,
        ),
        isNull,
      );
      final retained = await storage.read(
        second,
        ApplicationChatStorageRecordKind.realtimeCursor,
      ) as ApplicationChatRealtimeCursorRecord;
      expect(retained.cursor.eventId, 'event-second');
    });
  });
}

Future<void> _pumpEventQueue() => Future<void>.delayed(Duration.zero);

Map<String, Object?> _metadata() => <String, Object?>{
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
    };

Map<String, Object?> _acceptedFrame() => <String, Object?>{
      'type': 'chat.session.accepted',
      'metadata': _metadata(),
      'tenantId': 'tenant-realtime',
      'actorStreamId': 'user:user-realtime',
      'deviceId': 'device-realtime',
      'sessionId': 'session-realtime',
    };

Map<String, Object?> _huddleResponse({
  required String operation,
  required Map<String, Object?> state,
  required bool includeDescriptor,
}) =>
    <String, Object?>{
      'operation': operation,
      'outcome': 'ok',
      'reconciliationStatus': 'applied',
      'state': state,
      if (includeDescriptor)
        'mediaJoin': <String, Object?>{
          'kind': 'opaque_media_join',
          'descriptor': _descriptorSecret,
          'expiresAt': '2030-01-01T00:04:00.000Z',
        },
    };

const _startingHuddle = <String, Object?>{
  'status': 'starting',
  'conversationId': 'conversation-media',
  'huddleSessionId': 'huddle-media',
  'startedAt': '2030-01-01T00:00:01.000Z',
  'participants': <Object?>[],
  'screenShareOwnerUserId': null,
};

const _activeHuddle = <String, Object?>{
  'status': 'active',
  'conversationId': 'conversation-media',
  'huddleSessionId': 'huddle-media',
  'startedAt': '2030-01-01T00:00:01.000Z',
  'participants': <Object?>[
    <String, Object?>{
      'userId': 'user-media',
      'status': 'joined',
      'joinedAt': '2030-01-01T00:00:02.000Z',
    },
  ],
  'screenShareOwnerUserId': null,
};
