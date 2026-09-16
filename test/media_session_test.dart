import 'dart:async';
import 'dart:convert';

import 'package:handrail_chat/media.dart';
import 'package:test/test.dart';

const _conversationId = ConversationId('conversation-media');
const _descriptorSecret = 'OPAQUE_MEDIA_SESSION_SENTINEL';
final _now = DateTime.utc(2030, 1, 1);

void main() {
  group('ChatHuddleMediaSession', () {
    test('hands off the exact descriptor and serializes provider operations',
        () async {
      final huddle = await _activeHuddle();
      final calls = <String>[];
      final provider = _FakeProvider(calls);
      final delegate = _FakeDelegate(calls, provider);
      final expectedDescriptor =
          huddle.controller.mediaBoundary.readJoinDescriptor();
      final session = ChatHuddleMediaSession(
        controller: huddle.controller,
        delegate: delegate,
      );
      final devices = <ChatMediaDeviceState>[];
      final speakers = <List<ChatMediaActiveSpeaker>>[];
      final deviceSubscription = session.deviceStates.listen(devices.add);
      final speakerSubscription = session.activeSpeakers.listen(speakers.add);

      await session.connect();
      await session.setMicrophoneEnabled(true);
      await session.setMicrophoneEnabled(false);
      await session.setCameraEnabled(true);
      await session.setCameraEnabled(false);
      await session.setScreenShareEnabled(true);
      await session.setScreenShareEnabled(false);
      await session.selectAudioInput('microphone-2');
      await session.selectAudioOutput('speaker-1');

      final changedDevices = ChatMediaDeviceState(
        devices: const <ChatMediaDevice>[
          ChatMediaDevice(
            id: 'microphone-2',
            kind: ChatMediaDeviceKind.audioInput,
            label: 'External microphone',
          ),
          ChatMediaDevice(
            id: 'speaker-1',
            kind: ChatMediaDeviceKind.audioOutput,
            label: 'Speaker',
          ),
        ],
        selectedAudioInputId: 'microphone-2',
        selectedAudioOutputId: 'speaker-1',
      );
      provider.deviceController.add(changedDevices);
      provider.speakerController.add(const <ChatMediaActiveSpeaker>[
        ChatMediaActiveSpeaker(
          participantId: 'participant-alice',
          isSpeaking: true,
        ),
      ]);
      await Future<void>.delayed(Duration.zero);

      expect(delegate.descriptor, same(expectedDescriptor));
      expect(delegate.descriptor?.descriptor, _descriptorSecret);
      expect(calls, <String>[
        'connect',
        'permission:microphone',
        'microphone:true',
        'microphone:false',
        'permission:camera',
        'camera:true',
        'camera:false',
        'permission:screenShare',
        'screenShare:true',
        'screenShare:false',
        'audioInput:microphone-2',
        'audioOutput:speaker-1',
      ]);
      expect(session.state.status, ChatMediaSessionStatus.connected);
      expect(session.state.microphoneEnabled, isFalse);
      expect(session.state.cameraEnabled, isFalse);
      expect(session.state.screenShareEnabled, isFalse);
      expect(devices.last, same(changedDevices));
      expect(speakers.last.single.participantId, 'participant-alice');
      expect(
        huddle.transport.requests
            .where((request) => request.uri.path.endsWith('/screen-share'))
            .map((request) =>
                (jsonDecode(request.body!) as Map<String, Object?>)['intent']),
        <Object?>['set', 'clear'],
      );

      final printable = <Object?>[
        session,
        session.state,
        session.state.devices,
        session.state.activeSpeakers.single,
        delegate.descriptor,
      ].join('\n');
      expect(printable, isNot(contains(_descriptorSecret)));

      await session.close();
      await session.close();
      await session.dispose();
      expect(calls.where((call) => call == 'close'), hasLength(1));
      await deviceSubscription.cancel();
      await speakerSubscription.cancel();
      await huddle.client.dispose();
    });

    test('leave releases tracks and rejoin connects a fresh provider',
        () async {
      final huddle = await _activeHuddle();
      final firstCalls = <String>[];
      final secondCalls = <String>[];
      final delegate = _FakeDelegate(firstCalls, _FakeProvider(firstCalls));
      final session = ChatHuddleMediaSession(
        controller: huddle.controller,
        delegate: delegate,
      );
      await session.connect();
      await session.setMicrophoneEnabled(true);
      await huddle.controller.leave();
      await Future<void>.delayed(Duration.zero);
      expect(firstCalls.where((call) => call == 'close'), hasLength(1));
      expect(session.state.status, ChatMediaSessionStatus.idle);
      expect(session.state.microphoneEnabled, isFalse);
      expect(session.state.activeSpeakers, isEmpty);
      expect(session.state.devices.devices, isEmpty);

      delegate.provider = _FakeProvider(secondCalls);
      await huddle.controller.join();
      await session.connect();
      await session.setMicrophoneEnabled(true);
      expect(session.state.status, ChatMediaSessionStatus.connected);
      expect(secondCalls, ['microphone:true']);
      expect(firstCalls.where((call) => call == 'connect'), hasLength(2));

      await huddle.controller.end();
      await Future<void>.delayed(Duration.zero);
      // Cleanup is driven by the controller even without a mounted panel.
      expect(secondCalls.where((call) => call == 'close'), hasLength(1));
      expect(session.state.status, ChatMediaSessionStatus.idle);
      await session.close();
      await huddle.client.dispose();
      expect(secondCalls.where((call) => call == 'close'), hasLength(1));
    });

    test(
        'leave closes tracks before pending permission and rejects queued work',
        () async {
      final huddle = await _activeHuddle();
      final calls = <String>[];
      final delegate = _FakeDelegate(calls, _FakeProvider(calls));
      final permission = Completer<ChatMediaPermissionDecision>();
      delegate.permissionGate = permission;
      final session = ChatHuddleMediaSession(
        controller: huddle.controller,
        delegate: delegate,
      );
      await session.connect();
      final microphone = session.setMicrophoneEnabled(true);
      final queuedCamera = session.setCameraEnabled(true);
      final microphoneRejected =
          expectLater(microphone, throwsA(isA<ChatMediaException>()));
      final cameraRejected =
          expectLater(queuedCamera, throwsA(isA<ChatMediaException>()));
      await Future<void>.delayed(Duration.zero);
      await huddle.controller.leave();
      await Future<void>.delayed(Duration.zero);
      expect(permission.isCompleted, isFalse);
      expect(calls.where((call) => call == 'close'), hasLength(1));
      expect(session.state.microphoneEnabled, isFalse);
      permission.complete(ChatMediaPermissionDecision.granted);
      await microphoneRejected;
      await cameraRejected;
      expect(calls, ['connect', 'permission:microphone', 'close']);
      expect(session.state.status, ChatMediaSessionStatus.idle);
      await session.close();
      await huddle.client.dispose();
    });

    test('late connection after leave is closed without exposing live media',
        () async {
      final huddle = await _activeHuddle();
      final calls = <String>[];
      final provider = _FakeProvider(calls);
      final gate = Completer<ChatMediaProviderSession>();
      final delegate = _DelayedDelegate(gate);
      final session = ChatHuddleMediaSession(
        controller: huddle.controller,
        delegate: delegate,
      );
      final connecting = session.connect();
      await Future<void>.delayed(Duration.zero);
      await huddle.controller.leave();
      await Future<void>.delayed(Duration.zero);
      gate.complete(provider);
      await connecting;
      expect(calls, ['close']);
      expect(session.state.status, ChatMediaSessionStatus.idle);
      await session.close();
      await huddle.client.dispose();
      expect(calls, ['close']);
    });

    test('controller disposal releases an otherwise unowned media session',
        () async {
      final huddle = await _activeHuddle();
      final calls = <String>[];
      final session = ChatHuddleMediaSession(
        controller: huddle.controller,
        delegate: _FakeDelegate(calls, _FakeProvider(calls)),
      );
      await session.connect();
      await huddle.client.dispose();
      await session.close();
      expect(calls.where((call) => call == 'close'), hasLength(1));
      expect(session.state.status, ChatMediaSessionStatus.closed);
    });

    test('maps microphone, camera, and screen-share permission denial',
        () async {
      final huddle = await _activeHuddle();
      final calls = <String>[];
      final provider = _FakeProvider(calls);
      final delegate = _FakeDelegate(
        calls,
        provider,
        permissions: <ChatMediaPermission, ChatMediaPermissionDecision>{
          ChatMediaPermission.microphone: ChatMediaPermissionDecision.denied,
          ChatMediaPermission.camera: ChatMediaPermissionDecision.restricted,
          ChatMediaPermission.screenShare: ChatMediaPermissionDecision.denied,
        },
      );
      final session = ChatHuddleMediaSession(
        controller: huddle.controller,
        delegate: delegate,
      );
      await session.connect();

      for (final operation in <Future<void> Function()>[
        () => session.setMicrophoneEnabled(true),
        () => session.setCameraEnabled(true),
        () => session.setScreenShareEnabled(true),
      ]) {
        await expectLater(
          operation(),
          throwsA(isA<ChatMediaException>().having(
            (error) => error.failure.code,
            'code',
            ChatMediaErrorCode.permissionDenied,
          )),
        );
      }

      expect(calls, <String>[
        'connect',
        'permission:microphone',
        'permission:camera',
        'permission:screenShare',
      ]);
      expect(session.state.status, ChatMediaSessionStatus.connected);
      expect(
        session.state.lastFailure?.code,
        ChatMediaErrorCode.permissionDenied,
      );
      await session.dispose();
      await huddle.client.dispose();
    });

    test('capability-disabled sessions are successful no-ops', () async {
      final transport = _FakeHttpTransport((request) async {
        if (request.uri.path.endsWith('/_meta')) {
          return _jsonResponse(_metadata(huddles: false));
        }
        throw StateError('huddle or provider work is prohibited');
      });
      final client = _client(
        transport,
        requestedCapabilities: const <String, bool>{'huddles': true},
      );
      await client.initialize();
      final controller = client.huddles.forConversation(_conversationId);
      final calls = <String>[];
      final session = ChatHuddleMediaSession(
        controller: controller,
        delegate: _FakeDelegate(calls, _FakeProvider(calls)),
      );

      expect(session.state.status, ChatMediaSessionStatus.idle);
      await controller.hydrate();
      await session.connect();
      expect(session.state.status, ChatMediaSessionStatus.unavailable);
      await session.setMicrophoneEnabled(true);
      await session.setCameraEnabled(true);
      await session.setScreenShareEnabled(true);
      await session.selectAudioInput('unavailable-input');
      await session.selectAudioOutput('unavailable-output');

      expect(calls, isEmpty);
      expect(transport.requests, hasLength(1));
      await session.close();
      await session.dispose();
      expect(calls, isEmpty);
      await client.dispose();
    });

    test('maps provider exceptions without leaking provider or descriptor text',
        () async {
      final huddle = await _activeHuddle();
      final calls = <String>[];
      final provider = _FakeProvider(calls)
        ..microphoneError = StateError(
          'provider failure $_descriptorSecret',
        );
      final session = ChatHuddleMediaSession(
        controller: huddle.controller,
        delegate: _FakeDelegate(calls, provider),
      );
      await session.connect();

      late ChatMediaException failure;
      try {
        await session.setMicrophoneEnabled(true);
        fail('expected a stable media exception');
      } on ChatMediaException catch (error) {
        failure = error;
      }

      expect(failure.failure.code, ChatMediaErrorCode.providerFailure);
      expect(failure.failure.operation, ChatMediaOperation.microphone);
      expect(failure.failure.retryable, isTrue);
      expect(
        <Object?>[failure, failure.failure, session, session.state].join('\n'),
        isNot(contains(_descriptorSecret)),
      );
      await session.close();
      await huddle.client.dispose();
    });
  });
}

Future<
    ({
      HandrailChatClient client,
      ChatHuddleController controller,
      _FakeHttpTransport transport,
    })> _activeHuddle() async {
  final transport = _FakeHttpTransport((request) async {
    final input = jsonDecode(request.body!) as Map<String, Object?>;
    final operation = input['operation'];
    return _commandResponse(
      input,
      switch (operation) {
        'start_huddle' => _starting,
        'join_huddle' => _active,
        'leave_huddle' => _left,
        'end_huddle' => _ended,
        'set_huddle_screen_share' =>
          input['intent'] == 'set' ? _sharing : _active,
        _ => throw StateError('unexpected operation $operation'),
      },
      media: operation == 'start_huddle' || operation == 'join_huddle',
    );
  });
  final client = _client(transport);
  client.normalizedState.projectCurrentUserReadState(ConversationReadState(
    conversationId: _conversationId,
    userId: const UserId('user-alice'),
    lastReadSequence: const MessageSequence(0),
    updatedAt: const IsoTimestamp('2030-01-01T00:00:00.000Z'),
  ));
  final controller = client.huddles.forConversation(_conversationId);
  expect(await controller.start(), isA<ChatHuddleActionSuccess>());
  expect(await controller.join(), isA<ChatHuddleActionSuccess>());
  return (client: client, controller: controller, transport: transport);
}

HandrailChatClient _client(
  _FakeHttpTransport transport, {
  Map<String, bool> requestedCapabilities = const <String, bool>{},
}) {
  var sequence = 0;
  return HandrailChatClient(
    apiBaseUri: Uri.parse('https://chat.example.test/api/chat'),
    tokenProvider: () async => 'access-token',
    transport: transport,
    requestedCapabilities: requestedCapabilities,
    generateIdempotencyKey: () => 'media-key-${++sequence}',
    huddleClock: () => _now,
  );
}

final class _FakeHttpTransport implements HandrailChatHttpTransport {
  _FakeHttpTransport(this.handler);

  final Future<HandrailChatHttpResponse> Function(HandrailChatHttpRequest)
      handler;
  final List<HandrailChatHttpRequest> requests = <HandrailChatHttpRequest>[];

  @override
  Future<HandrailChatHttpResponse> send(HandrailChatHttpRequest request) {
    requests.add(request);
    return handler(request);
  }
}

final class _FakeDelegate implements ChatMediaDelegate {
  _FakeDelegate(
    this.calls,
    this.provider, {
    this.permissions =
        const <ChatMediaPermission, ChatMediaPermissionDecision>{},
  });

  final List<String> calls;
  _FakeProvider provider;
  final Map<ChatMediaPermission, ChatMediaPermissionDecision> permissions;
  HuddleMediaJoinDescriptor? descriptor;
  Completer<ChatMediaPermissionDecision>? permissionGate;

  @override
  Future<ChatMediaProviderSession> connect(
    HuddleMediaJoinDescriptor descriptor,
  ) async {
    calls.add('connect');
    this.descriptor = descriptor;
    return provider;
  }

  @override
  Future<ChatMediaPermissionDecision> requestPermission(
    ChatMediaPermission permission,
  ) async {
    calls.add('permission:${permission.name}');
    if (permissionGate != null) return permissionGate!.future;
    return permissions[permission] ?? ChatMediaPermissionDecision.granted;
  }
}

final class _FakeProvider implements ChatMediaProviderSession {
  _FakeProvider(this.calls);

  final List<String> calls;
  final StreamController<ChatMediaDeviceState> deviceController =
      StreamController<ChatMediaDeviceState>.broadcast(sync: true);
  final StreamController<List<ChatMediaActiveSpeaker>> speakerController =
      StreamController<List<ChatMediaActiveSpeaker>>.broadcast(sync: true);
  Object? microphoneError;

  @override
  ChatMediaProviderState get initialState => ChatMediaProviderState(
        devices: ChatMediaDeviceState(devices: const <ChatMediaDevice>[]),
      );

  @override
  Stream<List<ChatMediaActiveSpeaker>> get activeSpeakerChanges =>
      speakerController.stream;

  @override
  Stream<ChatMediaDeviceState> get deviceChanges => deviceController.stream;

  @override
  Future<void> setMicrophoneEnabled(bool enabled) async {
    calls.add('microphone:$enabled');
    final error = microphoneError;
    if (error != null) throw error;
  }

  @override
  Future<void> setCameraEnabled(bool enabled) async {
    calls.add('camera:$enabled');
  }

  @override
  Future<void> setScreenShareEnabled(bool enabled) async {
    calls.add('screenShare:$enabled');
  }

  @override
  Future<void> selectAudioInput(String? deviceId) async {
    calls.add('audioInput:$deviceId');
  }

  @override
  Future<void> selectAudioOutput(String? deviceId) async {
    calls.add('audioOutput:$deviceId');
  }

  @override
  Future<void> close() async {
    calls.add('close');
    await deviceController.close();
    await speakerController.close();
  }
}

Future<HandrailChatHttpResponse> _commandResponse(
  Map<String, Object?> input,
  Map<String, Object?> state, {
  required bool media,
}) async =>
    _jsonResponse(<String, Object?>{
      'operation': input['operation'],
      'outcome': 'ok',
      'reconciliationStatus': 'applied',
      'state': state,
      if (media)
        'mediaJoin': <String, Object?>{
          'kind': 'opaque_media_join',
          'descriptor': _descriptorSecret,
          'expiresAt': '2030-01-01T00:04:00.000Z',
        },
    });

HandrailChatHttpResponse _jsonResponse(Object? value) =>
    HandrailChatHttpResponse(statusCode: 200, body: jsonEncode(value));

Map<String, Object?> _metadata({required bool huddles}) => <String, Object?>{
      'packageVersion': '0.1.3',
      'protocolVersion': handrailChatProtocolVersion,
      'schemaVersion': 1,
      'enabledFeatures': <String, Object?>{
        'huddles': huddles,
        'media': huddles,
        'realtime': true,
      },
      'supportedProtocolRange': <String, Object?>{
        'minimumVersion': handrailChatProtocolVersion - 1,
        'maximumVersion': handrailChatProtocolVersion,
      },
    };

const _starting = <String, Object?>{
  'status': 'starting',
  'conversationId': 'conversation-media',
  'huddleSessionId': 'huddle-media',
  'startedAt': '2030-01-01T00:00:01.000Z',
  'participants': <Object?>[],
  'screenShareOwnerUserId': null,
};

const _active = <String, Object?>{
  'status': 'active',
  'conversationId': 'conversation-media',
  'huddleSessionId': 'huddle-media',
  'startedAt': '2030-01-01T00:00:01.000Z',
  'participants': <Object?>[
    <String, Object?>{
      'userId': 'user-alice',
      'status': 'joined',
      'joinedAt': '2030-01-01T00:00:02.000Z',
    },
  ],
  'screenShareOwnerUserId': null,
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

final _ended = <String, Object?>{
  ..._left,
  'status': 'ended',
  'endedAt': '2030-01-01T00:00:03.000Z',
  'endedByUserId': 'user-alice',
};

final class _DelayedDelegate implements ChatMediaDelegate {
  _DelayedDelegate(this.gate);
  final Completer<ChatMediaProviderSession> gate;

  @override
  Future<ChatMediaProviderSession> connect(
          HuddleMediaJoinDescriptor descriptor) =>
      gate.future;

  @override
  Future<ChatMediaPermissionDecision> requestPermission(
          ChatMediaPermission permission) async =>
      ChatMediaPermissionDecision.granted;
}
