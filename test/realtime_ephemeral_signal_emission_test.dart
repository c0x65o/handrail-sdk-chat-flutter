import 'dart:async';
import 'dart:convert';

import 'package:handrail_chat/core.dart';
import 'package:test/test.dart';

void main() {
  group('ChatRealtimeSessionTransport ephemeral signals', () {
    test('emits exact trusted presence and public/private typing frames',
        () async {
      final clock = FakeEphemeralClock();
      final visibility = FakeVisibility();
      final socket = FakeSocket();
      final session = createSession(
        socketFactory: (uri, protocols) => socket,
        ephemeralSignals: signalOptions(
          clock: clock,
          visibility: visibility,
          resolver: (conversationId, requested) =>
              switch (conversationId.value) {
            'public-room' =>
              ChatRealtimeConversationVisibility.publicConversation,
            'private-room' =>
              ChatRealtimeConversationVisibility.privateConversation,
            _ => null,
          },
        ),
      );

      await session.start();
      expect(session.startTyping(const ConversationId('public-room')), isFalse);
      socket.emitJson(acceptedFrame());
      await pumpEventQueue();

      expect(presenceFrames(socket).single, {
        'eventId': 'client-ephemeral-session-1-1',
        'protocolVersion': 4,
        'tenantId': 'tenant-1',
        'streamId': 'user:user-1',
        'type': 'presence.signal',
        'occurredAt': '2026-08-26T12:00:00.000Z',
        'payload': {
          'capability': 'presence',
          'durability': 'ephemeral',
          'actorUserId': 'user-1',
          'deviceId': 'device-1',
          'sessionId': 'session-1',
          'sequence': 1,
          'sentAt': '2026-08-26T12:00:00.000Z',
          'expiresAt': '2026-08-26T12:00:00.300Z',
          'state': 'online',
          'scope': {'type': 'user_private', 'userId': 'user-1'},
        },
      });

      expect(
        session.startTyping(
          const ConversationId('public-room'),
          visibility: ChatRealtimeConversationVisibility.publicConversation,
        ),
        isTrue,
      );
      expect(typingFrames(socket).single, {
        'eventId': 'client-ephemeral-session-1-2',
        'protocolVersion': 4,
        'tenantId': 'tenant-1',
        'streamId': 'public-room',
        'type': 'typing.signal',
        'occurredAt': '2026-08-26T12:00:00.001Z',
        'payload': {
          'capability': 'typing',
          'durability': 'ephemeral',
          'actorUserId': 'user-1',
          'deviceId': 'device-1',
          'sessionId': 'session-1',
          'sequence': 2,
          'sentAt': '2026-08-26T12:00:00.001Z',
          'expiresAt': '2026-08-26T12:00:00.101Z',
          'state': 'start',
          'scope': {
            'type': 'conversation',
            'conversationId': 'public-room',
            'visibility': 'public',
            'audience': 'active_participants',
          },
        },
      });

      session.stopTyping(const ConversationId('public-room'));
      expect(
        session.startTyping(
          const ConversationId('private-room'),
          visibility: ChatRealtimeConversationVisibility.privateConversation,
        ),
        isTrue,
      );
      expect(
          typingFrames(socket).last['payload'],
          containsPair('scope', {
            'type': 'conversation',
            'conversationId': 'private-room',
            'visibility': 'private',
            'audience': 'members',
          }));
      await session.dispose();
    });

    test('heartbeats, typing idle, presence idle, and activity recover',
        () async {
      final clock = FakeEphemeralClock();
      final socket = FakeSocket();
      final session = createSession(
        socketFactory: (uri, protocols) => socket,
        ephemeralSignals: signalOptions(
          clock: clock,
          visibility: FakeVisibility(),
          resolver: privateResolver,
        ),
      );

      await session.start();
      socket.emitJson(acceptedFrame());
      await pumpEventQueue();
      expect(session.startTyping(const ConversationId('room')), isTrue);

      clock.advance(const Duration(milliseconds: 30));
      expect(typingStates(socket), ['start', 'start']);
      expect(session.startTyping(const ConversationId('room')), isTrue);
      clock.advance(const Duration(milliseconds: 60));
      expect(typingStates(socket), ['start', 'start', 'start', 'start']);
      clock.advance(const Duration(milliseconds: 10));
      expect(typingStates(socket).last, 'stop');

      clock.advance(const Duration(milliseconds: 80));
      expect(presenceStates(socket).last, 'away');
      session.notifyActivity();
      expect(presenceStates(socket).last, 'online');
      await session.dispose();
    });

    test('suppresses hidden/offline work and cleans close and disposal',
        () async {
      final clock = FakeEphemeralClock();
      final visibility = FakeVisibility();
      final socket = FakeSocket();
      final session = createSession(
        socketFactory: (uri, protocols) => socket,
        ephemeralSignals: signalOptions(
          clock: clock,
          visibility: visibility,
          resolver: privateResolver,
        ),
      );

      await session.start();
      socket.emitJson(acceptedFrame());
      await pumpEventQueue();
      session.startTyping(const ConversationId('room'));
      expect(visibility.listenerCount, 1);
      expect(clock.activeCount, 4);

      visibility.setVisible(false);
      expect(typingStates(socket).last, 'stop');
      expect(presenceStates(socket).last, 'away');
      expect(session.startTyping(const ConversationId('room')), isFalse);
      final hiddenFrameCount = socket.sent.length;
      session.notifyActivity();
      expect(socket.sent, hasLength(hiddenFrameCount));

      visibility.setVisible(true);
      expect(presenceStates(socket).last, 'online');
      session.setPresence(PresenceSignalState.offline);
      expect(presenceStates(socket).last, 'offline');
      expect(session.startTyping(const ConversationId('room')), isFalse);
      expect(clock.activeCount, 0);

      session.setPresence(PresenceSignalState.online);
      session.startTyping(const ConversationId('room'));
      await session.close();
      expect(typingStates(socket).last, 'stop');
      expect(presenceStates(socket).last, 'offline');
      expect(visibility.listenerCount, 0);
      expect(clock.activeCount, 0);
      final closedFrameCount = socket.sent.length;
      clock.advance(const Duration(days: 1));
      visibility.setVisible(false);
      expect(socket.sent, hasLength(closedFrameCount));

      await session.dispose();
      expect(visibility.listenerCount, 0);
      expect(clock.activeCount, 0);

      final disposeClock = FakeEphemeralClock();
      final disposeVisibility = FakeVisibility();
      final disposeSocket = FakeSocket();
      final disposeSession = createSession(
        socketFactory: (uri, protocols) => disposeSocket,
        ephemeralSignals: signalOptions(
          clock: disposeClock,
          visibility: disposeVisibility,
          resolver: privateResolver,
        ),
      );
      await disposeSession.start();
      disposeSocket.emitJson(acceptedFrame());
      await pumpEventQueue();
      disposeSession.startTyping(const ConversationId('room'));
      await disposeSession.dispose();
      expect(typingStates(disposeSocket).last, 'stop');
      expect(presenceStates(disposeSocket).last, 'offline');
      expect(disposeVisibility.listenerCount, 0);
      expect(disposeClock.activeCount, 0);
      final disposedFrameCount = disposeSocket.sent.length;
      disposeClock.advance(const Duration(days: 1));
      disposeVisibility.setVisible(false);
      expect(disposeSocket.sent, hasLength(disposedFrameCount));
    });

    test('enforces negotiated, local, and conversation privacy gates',
        () async {
      final negotiatedSocket = FakeSocket();
      final negotiated = createSession(
        socketFactory: (uri, protocols) => negotiatedSocket,
        ephemeralSignals: signalOptions(
          clock: FakeEphemeralClock(),
          visibility: FakeVisibility(),
          resolver: privateResolver,
        ),
      );
      await negotiated.start();
      negotiatedSocket.emitJson(
        acceptedFrame(features: {'typing': false, 'presence': false}),
      );
      await pumpEventQueue();
      expect(negotiated.startTyping(const ConversationId('room')), isFalse);
      negotiated.setPresence(PresenceSignalState.away);
      expect(typingFrames(negotiatedSocket), isEmpty);
      expect(presenceFrames(negotiatedSocket), isEmpty);
      await negotiated.dispose();

      final localSocket = FakeSocket();
      final local = createSession(
        socketFactory: (uri, protocols) => localSocket,
        ephemeralSignals: signalOptions(
          clock: FakeEphemeralClock(),
          visibility: FakeVisibility(),
          resolver: privateResolver,
          typingEnabled: false,
          presenceEnabled: false,
        ),
      );
      await local.start();
      localSocket.emitJson(acceptedFrame());
      await pumpEventQueue();
      expect(local.startTyping(const ConversationId('room')), isFalse);
      local.setPresence(PresenceSignalState.away);
      expect(typingFrames(localSocket), isEmpty);
      expect(presenceFrames(localSocket), isEmpty);
      await local.dispose();

      final privacySocket = FakeSocket();
      final privacy = createSession(
        socketFactory: (uri, protocols) => privacySocket,
        ephemeralSignals: signalOptions(
          clock: FakeEphemeralClock(),
          visibility: FakeVisibility(),
          resolver: (conversationId, requested) =>
              conversationId.value == 'authorized'
                  ? ChatRealtimeConversationVisibility.privateConversation
                  : null,
        ),
      );
      await privacy.start();
      privacySocket.emitJson(acceptedFrame());
      await pumpEventQueue();
      expect(
        privacy.startTyping(
          const ConversationId('authorized'),
          visibility: ChatRealtimeConversationVisibility.publicConversation,
        ),
        isFalse,
      );
      expect(
        privacy.startTyping(
          const ConversationId('unauthorized'),
        ),
        isFalse,
      );
      expect(
        privacy.startTyping(
          const ConversationId('authorized'),
          visibility: ChatRealtimeConversationVisibility.privateConversation,
        ),
        isTrue,
      );
      expect(
        (typingFrames(privacySocket).single['payload']
            as Map<String, Object?>)['scope'],
        {
          'type': 'conversation',
          'conversationId': 'authorized',
          'visibility': 'private',
          'audience': 'members',
        },
      );
      await privacy.dispose();
    });

    test('rate limits ordinary frames while terminal frames always send',
        () async {
      final clock = FakeEphemeralClock();
      final socket = FakeSocket();
      final session = createSession(
        socketFactory: (uri, protocols) => socket,
        ephemeralSignals: signalOptions(
          clock: clock,
          visibility: FakeVisibility(),
          resolver: privateResolver,
          presenceEnabled: false,
          rateLimitMaxSignals: 1,
        ),
      );

      await session.start();
      socket.emitJson(acceptedFrame());
      await pumpEventQueue();
      expect(session.startTyping(const ConversationId('room-a')), isTrue);
      expect(session.startTyping(const ConversationId('room-b')), isFalse);
      session.stopTyping(const ConversationId('room-a'));
      expect(typingStates(socket), ['start', 'stop']);

      clock.advance(const Duration(milliseconds: 100));
      expect(session.startTyping(const ConversationId('room-b')), isTrue);
      await session.close();
      expect(typingStates(socket), ['start', 'stop', 'start', 'stop']);

      final presenceSocket = FakeSocket();
      final presenceSession = createSession(
        socketFactory: (uri, protocols) => presenceSocket,
        ephemeralSignals: signalOptions(
          clock: FakeEphemeralClock(),
          visibility: FakeVisibility(),
          resolver: privateResolver,
          rateLimitMaxSignals: 1,
        ),
      );
      await presenceSession.start();
      presenceSocket.emitJson(acceptedFrame());
      await pumpEventQueue();
      expect(presenceStates(presenceSocket), ['online']);
      presenceSession.setPresence(PresenceSignalState.offline);
      expect(presenceStates(presenceSocket), ['online', 'offline']);
      await presenceSession.dispose();
    });

    test('timestamps stay monotonic and new acceptance resets identity state',
        () async {
      final clock = FakeEphemeralClock();
      final visibility = FakeVisibility();
      final network = FakeNetwork();
      final firstSocket = FakeSocket();
      final secondSocket = FakeSocket();
      final sockets = <FakeSocket>[firstSocket, secondSocket];
      var socketIndex = 0;
      final session = createSession(
        socketFactory: (uri, protocols) => sockets[socketIndex++],
        network: network,
        ephemeralSignals: signalOptions(
          clock: clock,
          visibility: visibility,
          resolver: privateResolver,
        ),
      );

      await session.start();
      firstSocket.emitJson(acceptedFrame(sessionId: 'old-session'));
      await pumpEventQueue();
      clock.setTime(clock.time.subtract(const Duration(seconds: 1)));
      session.startTyping(const ConversationId('room'));
      final oldTyping = typingFrames(firstSocket).single;
      expect(oldTyping['occurredAt'], '2026-08-26T12:00:00.001Z');
      expect(
        (oldTyping['payload'] as Map<String, Object?>)['sequence'],
        2,
      );

      network.setOnline(false);
      await pumpEventQueue();
      expect(typingStates(firstSocket).last, 'stop');
      expect(presenceStates(firstSocket).last, 'offline');
      expect(visibility.listenerCount, 0);
      expect(clock.activeCount, 0);

      network.setOnline(true);
      await pumpEventQueue();
      secondSocket.emitJson(
        acceptedFrame(
          tenantId: 'tenant-2',
          userId: 'user-2',
          deviceId: 'device-2',
          sessionId: 'new-session',
        ),
      );
      await pumpEventQueue();
      final newPresence = presenceFrames(secondSocket).single;
      expect(newPresence['eventId'], 'client-ephemeral-new-session-1');
      expect(newPresence['tenantId'], 'tenant-2');
      expect(newPresence['streamId'], 'user:user-2');
      expect(newPresence['occurredAt'], '2026-08-26T11:59:59.000Z');
      expect(newPresence['payload'], containsPair('deviceId', 'device-2'));
      expect(newPresence['payload'], containsPair('sessionId', 'new-session'));
      expect(newPresence['payload'], containsPair('sequence', 1));
      await session.dispose();
    });
  });
}

ChatRealtimeSessionTransport createSession({
  required ChatRealtimeSocketFactory socketFactory,
  ChatRealtimeNetwork? network,
  required ChatRealtimeEphemeralSignalOptions ephemeralSignals,
}) =>
    ChatRealtimeSessionTransport(
      endpoint: Uri.parse('https://chat.example/api/chat/'),
      clientPackageVersion: '0.1.3',
      protocolVersion: 4,
      tokenProvider: () => 'token',
      socketFactory: socketFactory,
      network: network,
      ephemeralSignals: ephemeralSignals,
    );

ChatRealtimeEphemeralSignalOptions signalOptions({
  required FakeEphemeralClock clock,
  required FakeVisibility visibility,
  required ChatRealtimeConversationVisibilityResolver resolver,
  bool typingEnabled = true,
  bool presenceEnabled = true,
  int rateLimitMaxSignals = 20,
}) =>
    ChatRealtimeEphemeralSignalOptions(
      clock: clock,
      visibility: visibility,
      conversationVisibilityResolver: resolver,
      typingEnabled: typingEnabled,
      presenceEnabled: presenceEnabled,
      typingTtl: const Duration(milliseconds: 100),
      typingHeartbeat: const Duration(milliseconds: 30),
      typingIdle: const Duration(milliseconds: 70),
      presenceTtl: const Duration(milliseconds: 300),
      presenceHeartbeat: const Duration(milliseconds: 100),
      presenceIdle: const Duration(milliseconds: 150),
      rateLimitMaxSignals: rateLimitMaxSignals,
      rateLimitWindow: const Duration(milliseconds: 100),
    );

ChatRealtimeConversationVisibility? privateResolver(
  ConversationId conversationId,
  ChatRealtimeConversationVisibility? requested,
) =>
    ChatRealtimeConversationVisibility.privateConversation;

Map<String, Object?> acceptedFrame({
  Map<String, bool> features = const {'typing': true, 'presence': true},
  String tenantId = 'tenant-1',
  String userId = 'user-1',
  String deviceId = 'device-1',
  String sessionId = 'session-1',
}) =>
    <String, Object?>{
      'type': 'chat.session.accepted',
      'metadata': {
        'packageVersion': '0.1.3',
        'protocolVersion': 4,
        'schemaVersion': 1,
        'enabledFeatures': features,
        'supportedProtocolRange': {
          'minimumVersion': 3,
          'maximumVersion': 4,
        },
      },
      'tenantId': tenantId,
      'actorStreamId': 'user:$userId',
      'deviceId': deviceId,
      'sessionId': sessionId,
    };

List<Map<String, Object?>> framesOfType(FakeSocket socket, String type) =>
    socket.sent
        .map((value) => Map<String, Object?>.from(
            jsonDecode(value) as Map<Object?, Object?>))
        .where((frame) => frame['type'] == type)
        .toList(growable: false);

List<Map<String, Object?>> typingFrames(FakeSocket socket) =>
    framesOfType(socket, 'typing.signal');

List<Map<String, Object?>> presenceFrames(FakeSocket socket) =>
    framesOfType(socket, 'presence.signal');

List<Object?> typingStates(FakeSocket socket) => typingFrames(socket)
    .map((frame) => (frame['payload'] as Map<String, Object?>)['state'])
    .toList(growable: false);

List<Object?> presenceStates(FakeSocket socket) => presenceFrames(socket)
    .map((frame) => (frame['payload'] as Map<String, Object?>)['state'])
    .toList(growable: false);

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

  @override
  Stream<Object?> get frames => _frames.stream;

  @override
  void send(String data) => sent.add(data);

  @override
  void close() => closeCount += 1;

  void emitJson(Map<String, Object?> frame) => _frames.add(jsonEncode(frame));
}

final class FakeNetwork implements ChatRealtimeNetwork {
  final StreamController<bool> _changes =
      StreamController<bool>.broadcast(sync: true);

  @override
  bool isOnline = true;

  @override
  Stream<bool> get changes => _changes.stream;

  void setOnline(bool value) {
    isOnline = value;
    _changes.add(value);
  }
}

final class FakeVisibility implements ChatRealtimeVisibility {
  final Set<void Function()> _listeners = <void Function()>{};
  var visible = true;

  @override
  bool get isVisible => visible;

  int get listenerCount => _listeners.length;

  @override
  void addListener(void Function() listener) => _listeners.add(listener);

  @override
  void removeListener(void Function() listener) => _listeners.remove(listener);

  void setVisible(bool value) {
    visible = value;
    for (final listener in List<void Function()>.of(_listeners)) {
      listener();
    }
  }
}

final class FakeEphemeralClock implements ChatRealtimeEphemeralClock {
  DateTime time = DateTime.utc(2026, 8, 26, 12);
  final List<_FakeTimer> _timers = <_FakeTimer>[];
  var _nextTimerId = 0;

  int get activeCount => _timers.where((timer) => timer.isActive).length;

  @override
  DateTime now() => time;

  @override
  ChatRealtimeTimer schedule(Duration delay, void Function() callback) {
    final timer = _FakeTimer(
      ++_nextTimerId,
      time.add(delay),
      callback,
    );
    _timers.add(timer);
    return timer;
  }

  void setTime(DateTime value) => time = value;

  void advance(Duration duration) {
    final target = time.add(duration);
    while (true) {
      final active = _timers.where((timer) => timer.isActive).toList()
        ..sort((left, right) {
          final dueOrder = left.due.compareTo(right.due);
          return dueOrder != 0 ? dueOrder : left.id.compareTo(right.id);
        });
      if (active.isEmpty || active.first.due.isAfter(target)) break;
      final timer = active.first;
      time = timer.due;
      timer.run();
    }
    time = target;
  }
}

final class _FakeTimer implements ChatRealtimeTimer {
  _FakeTimer(this.id, this.due, this.callback);

  final int id;
  final DateTime due;
  final void Function() callback;
  var isActive = true;

  @override
  void cancel() => isActive = false;

  void run() {
    if (!isActive) return;
    isActive = false;
    callback();
  }
}
