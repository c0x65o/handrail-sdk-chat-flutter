import 'dart:async';
import 'dart:convert';

import 'package:handrail_chat/core.dart';
import 'package:test/test.dart';

void main() {
  group('EphemeralSignalStore reduction', () {
    test('rejects older, equal, and expired frames and evicts at expiresAt',
        () async {
      final scheduler = FakeEphemeralScheduler(_time(0));
      final store = _store(scheduler);
      final accepted = _typing(
        sentAt: _time(0),
        expiresAt: _time(10),
        state: TypingSignalState.start,
      );

      expect(store.apply(accepted), isTrue);
      expect(
        store.apply(
          _typing(
            eventId: 'older',
            sentAt: _time(-1),
            expiresAt: _time(20),
            state: TypingSignalState.stop,
          ),
        ),
        isFalse,
      );
      expect(
        store.apply(
          _typing(
            eventId: 'equal-replay',
            sentAt: _time(0),
            expiresAt: _time(15),
            state: TypingSignalState.stop,
          ),
        ),
        isFalse,
      );
      final newer = _typing(
        eventId: 'newer',
        sentAt: _time(1),
        expiresAt: _time(10),
        state: TypingSignalState.stop,
      );
      expect(store.apply(newer), isTrue);
      expect(
        store.apply(
          _typing(
            eventId: 'newer-equal-replay',
            sentAt: _time(1),
            expiresAt: _time(12),
          ),
        ),
        isFalse,
      );
      final acceptedPresence = _presence(expiresAt: _time(20));
      expect(store.apply(acceptedPresence), isTrue);
      expect(
        store.apply(
          _presence(
            eventId: 'older-presence',
            sentAt: _time(-1),
            expiresAt: _time(30),
          ),
        ),
        isFalse,
      );
      expect(
        store.apply(
          _presence(
            eventId: 'expired-presence',
            actorUserId: 'expired-actor',
            sentAt: _time(-1),
            expiresAt: _time(0),
          ),
        ),
        isFalse,
      );
      expect(store.snapshot.typing.entries.values.single, same(newer));
      expect(
        store.snapshot.presence.entries.values.single,
        same(acceptedPresence),
      );
      expect(scheduler.activeCount, 1);

      scheduler.advance(const Duration(milliseconds: 9));
      expect(store.snapshot.typing.entries, hasLength(1));
      scheduler.advance(const Duration(milliseconds: 1));
      expect(store.snapshot.typing.entries, isEmpty);
      expect(store.snapshot.presence.entries, hasLength(1));
      expect(scheduler.activeCount, 1);
      scheduler.advance(const Duration(milliseconds: 10));
      expect(store.snapshot.isEmpty, isTrue);
      expect(scheduler.activeCount, 0);
      await store.close();
    });

    test('isolates typing and presence scopes, actors, devices, and sessions',
        () async {
      final scheduler = FakeEphemeralScheduler(_time(0));
      final store = _store(scheduler);
      final typing = [
        _typing(conversationId: 'conversation-1'),
        _typing(conversationId: 'conversation-2', eventId: 'typing-scope'),
        _typing(actorUserId: 'actor-2', eventId: 'typing-actor'),
        _typing(deviceId: 'device-2', eventId: 'typing-device'),
        _typing(sessionId: 'session-2', eventId: 'typing-session'),
      ];
      final presence = [
        _presence(scopedUserId: 'scoped-1'),
        _presence(scopedUserId: 'scoped-2', eventId: 'presence-scope'),
        _presence(actorUserId: 'actor-2', eventId: 'presence-actor'),
        _presence(deviceId: 'device-2', eventId: 'presence-device'),
        _presence(sessionId: 'session-2', eventId: 'presence-session'),
      ];

      for (final event in [...typing, ...presence]) {
        expect(store.apply(event), isTrue);
      }

      expect(store.snapshot.typing.entries, hasLength(5));
      expect(store.snapshot.presence.entries, hasLength(5));
      expect(
        store.snapshot.typing.forConversation(
          const TenantId('tenant-1'),
          const ConversationId('conversation-1'),
        ),
        hasLength(4),
      );
      expect(
        store.snapshot.presence.forUser(
          const TenantId('tenant-1'),
          const UserId('scoped-1'),
        ),
        hasLength(4),
      );
      expect(
        () => store.snapshot.typing.entries.clear(),
        throwsUnsupportedError,
      );
      expect(
        () => store.snapshot.presence
            .forUser(
              const TenantId('tenant-1'),
              const UserId('scoped-1'),
            )
            .clear(),
        throwsUnsupportedError,
      );
      await store.close();
    });

    test('broadcast streams emit only changed observable snapshots', () async {
      final scheduler = FakeEphemeralScheduler(_time(0));
      final store = _store(scheduler);
      var aggregateEvents = 0;
      var typingEvents = 0;
      var presenceEvents = 0;
      final subscriptions = [
        store.snapshots.listen((_) => aggregateEvents += 1),
        store.typingSnapshots.listen((_) => typingEvents += 1),
        store.presenceSnapshots.listen((_) => presenceEvents += 1),
      ];

      expect(store.apply(_typing()), isTrue);
      expect((aggregateEvents, typingEvents, presenceEvents), (1, 1, 0));
      expect(store.apply(_typing(eventId: 'equal')), isFalse);
      expect(
        store.disconnectSession(
          const TenantId('tenant-1'),
          const SessionId('not-present'),
        ),
        isFalse,
      );
      expect((aggregateEvents, typingEvents, presenceEvents), (1, 1, 0));

      expect(store.apply(_presence()), isTrue);
      expect((aggregateEvents, typingEvents, presenceEvents), (2, 1, 1));

      for (final subscription in subscriptions) {
        await subscription.cancel();
      }
      await store.close();
    });

    test('keeps one earliest-expiry timer and reschedules safely', () async {
      final scheduler = FakeEphemeralScheduler(_time(0));
      final store = _store(scheduler);

      store.apply(_typing(expiresAt: _time(20)));
      expect((scheduler.activeCount, scheduler.scheduledCount), (1, 1));
      store.apply(_presence(expiresAt: _time(30)));
      expect((scheduler.activeCount, scheduler.scheduledCount), (1, 1));
      store.apply(
        _typing(
          conversationId: 'earlier',
          eventId: 'earlier',
          expiresAt: _time(10),
        ),
      );
      expect((scheduler.activeCount, scheduler.scheduledCount), (1, 2));
      expect(scheduler.cancelledCount, 1);

      scheduler.advance(const Duration(milliseconds: 10));
      expect(store.snapshot.typing.entries, hasLength(1));
      expect((scheduler.activeCount, scheduler.scheduledCount), (1, 3));
      scheduler.advance(const Duration(milliseconds: 10));
      expect(store.snapshot.typing.entries, isEmpty);
      expect(store.snapshot.presence.entries, hasLength(1));
      expect(scheduler.activeCount, 1);

      await store.close();
      expect(scheduler.activeCount, 0);
    });

    test('disconnect removes only the matching tenant session', () async {
      final scheduler = FakeEphemeralScheduler(_time(0));
      final store = _store(scheduler);
      for (final event in <EphemeralSignalEvent>[
        _typing(eventId: 'tenant-1-session-1'),
        _typing(sessionId: 'session-2', eventId: 'tenant-1-session-2'),
        _typing(tenantId: 'tenant-2', eventId: 'tenant-2-session-1'),
        _presence(eventId: 'presence-tenant-1-session-1'),
        _presence(
          sessionId: 'session-2',
          eventId: 'presence-tenant-1-session-2',
        ),
        _presence(
          tenantId: 'tenant-2',
          eventId: 'presence-tenant-2-session-1',
        ),
      ]) {
        store.apply(event);
      }

      expect(
        store.disconnectSession(
          const TenantId('tenant-1'),
          const SessionId('session-1'),
        ),
        isTrue,
      );
      expect(store.snapshot.typing.entries, hasLength(2));
      expect(store.snapshot.presence.entries, hasLength(2));
      expect(
        store.snapshot.typing.entries.keys.map((key) => key.tenantId.value),
        containsAll(['tenant-1', 'tenant-2']),
      );
      expect(
        store.snapshot.typing.entries.keys.map((key) => key.sessionId.value),
        containsAll(['session-1', 'session-2']),
      );
      await store.close();
    });

    test('close clears state, cancels expiry, closes streams, and is final',
        () async {
      final scheduler = FakeEphemeralScheduler(_time(0));
      final store = _store(scheduler);
      final aggregateDone = Completer<void>();
      final typingDone = Completer<void>();
      final presenceDone = Completer<void>();
      var aggregateEvents = 0;
      store.snapshots.listen(
        (_) => aggregateEvents += 1,
        onDone: aggregateDone.complete,
      );
      store.typingSnapshots.listen((_) {}, onDone: typingDone.complete);
      store.presenceSnapshots.listen((_) {}, onDone: presenceDone.complete);
      store.apply(_typing());
      store.apply(_presence());
      expect(scheduler.activeCount, 1);

      await store.dispose();
      await Future.wait([
        aggregateDone.future,
        typingDone.future,
        presenceDone.future,
      ]);
      expect(store.isClosed, isTrue);
      expect(store.snapshot.isEmpty, isTrue);
      expect(aggregateEvents, 3);
      expect(scheduler.activeCount, 0);
      expect(store.apply(_typing(eventId: 'after-close')), isFalse);
      expect(store.expire(), isFalse);
      expect(
        store.disconnectSession(
          const TenantId('tenant-1'),
          const SessionId('session-1'),
        ),
        isFalse,
      );
      scheduler.advance(const Duration(days: 1));
      expect(store.snapshot.isEmpty, isTrue);
      expect(scheduler.activeCount, 0);
      await store.close();
    });
  });

  test('realtime disconnect hook clears only its accepted session', () async {
    final scheduler = FakeEphemeralScheduler(_time(0));
    final store = _store(scheduler);
    store.apply(_typing());
    store.apply(_typing(sessionId: 'other-session', eventId: 'other'));
    final socket = FakeRealtimeSocket();
    final transport = ChatRealtimeSessionTransport(
      endpoint: Uri.parse('https://chat.example/api/chat/'),
      clientPackageVersion: '0.1.3',
      protocolVersion: 4,
      tokenProvider: () => 'token',
      socketFactory: (_, __) => socket,
      ephemeralSignals: const ChatRealtimeEphemeralSignalOptions(
        typingEnabled: false,
        presenceEnabled: false,
      ),
      onEphemeralSessionDisconnected: store.disconnectSession,
    );

    await transport.start();
    socket.emitJson(_acceptedFrame());
    await pumpEventQueue();
    await transport.close();

    expect(store.snapshot.typing.entries, hasLength(1));
    expect(
      store.snapshot.typing.entries.keys.single.sessionId,
      const SessionId('other-session'),
    );
    await transport.dispose();
    await store.close();
  });
}

EphemeralSignalStore _store(FakeEphemeralScheduler scheduler) =>
    EphemeralSignalStore(clock: () => scheduler.now, scheduler: scheduler);

DateTime _time(int milliseconds) =>
    DateTime.utc(2026, 8, 26, 12).add(Duration(milliseconds: milliseconds));

TypingSignalEvent _typing({
  String eventId = 'typing',
  String tenantId = 'tenant-1',
  String conversationId = 'conversation-1',
  String actorUserId = 'actor-1',
  String deviceId = 'device-1',
  String sessionId = 'session-1',
  DateTime? sentAt,
  DateTime? expiresAt,
  TypingSignalState state = TypingSignalState.start,
}) {
  final sent = sentAt ?? _time(0);
  final expires = expiresAt ?? _time(100);
  return TypingSignalEvent(
    eventId: eventId,
    protocolVersion: 4,
    tenantId: TenantId(tenantId),
    streamId: ConversationId(conversationId),
    occurredAt: IsoTimestamp(sent.toIso8601String()),
    payload: TypingSignalPayload(
      actorUserId: UserId(actorUserId),
      deviceId: DeviceId(deviceId),
      sessionId: SessionId(sessionId),
      sequence: 1,
      sentAt: IsoTimestamp(sent.toIso8601String()),
      expiresAt: IsoTimestamp(expires.toIso8601String()),
      state: state,
      scope: PrivateConversationSignalScope(ConversationId(conversationId)),
    ),
  );
}

PresenceSignalEvent _presence({
  String eventId = 'presence',
  String tenantId = 'tenant-1',
  String scopedUserId = 'scoped-1',
  String actorUserId = 'actor-1',
  String deviceId = 'device-1',
  String sessionId = 'session-1',
  DateTime? sentAt,
  DateTime? expiresAt,
}) {
  final sent = sentAt ?? _time(0);
  final expires = expiresAt ?? _time(100);
  return PresenceSignalEvent(
    eventId: eventId,
    protocolVersion: 4,
    tenantId: TenantId(tenantId),
    streamId: 'user:$scopedUserId',
    occurredAt: IsoTimestamp(sent.toIso8601String()),
    payload: PresenceSignalPayload(
      actorUserId: UserId(actorUserId),
      deviceId: DeviceId(deviceId),
      sessionId: SessionId(sessionId),
      sequence: 1,
      sentAt: IsoTimestamp(sent.toIso8601String()),
      expiresAt: IsoTimestamp(expires.toIso8601String()),
      state: PresenceSignalState.online,
      scope: UserPrivateSignalScope(UserId(scopedUserId)),
    ),
  );
}

Map<String, Object?> _acceptedFrame() => {
      'type': 'chat.session.accepted',
      'metadata': {
        'packageVersion': '0.1.3',
        'protocolVersion': 4,
        'schemaVersion': 1,
        'enabledFeatures': {'typing': false, 'presence': false},
        'supportedProtocolRange': {
          'minimumVersion': 3,
          'maximumVersion': 4,
        },
      },
      'tenantId': 'tenant-1',
      'actorStreamId': 'user:actor-1',
      'deviceId': 'device-1',
      'sessionId': 'session-1',
    };

final class FakeEphemeralScheduler implements EphemeralSignalScheduler {
  FakeEphemeralScheduler(this.now);

  DateTime now;
  final List<_FakeScheduledTimer> _timers = [];
  var scheduledCount = 0;
  var cancelledCount = 0;

  int get activeCount => _timers.where((timer) => timer.isActive).length;

  @override
  EphemeralSignalTimer schedule(Duration delay, void Function() callback) {
    scheduledCount += 1;
    final timer = _FakeScheduledTimer(
      dueAt: now.add(delay),
      callback: callback,
      onCancel: () => cancelledCount += 1,
    );
    _timers.add(timer);
    return timer;
  }

  void advance(Duration duration) {
    now = now.add(duration);
    while (true) {
      final due = _timers.where(
        (timer) => timer.isActive && !timer.dueAt.isAfter(now),
      );
      if (due.isEmpty) return;
      final next = due.reduce(
        (left, right) => left.dueAt.isBefore(right.dueAt) ? left : right,
      );
      next.fire();
    }
  }
}

final class _FakeScheduledTimer implements EphemeralSignalTimer {
  _FakeScheduledTimer({
    required this.dueAt,
    required this.callback,
    required this.onCancel,
  });

  final DateTime dueAt;
  final void Function() callback;
  final void Function() onCancel;
  var isActive = true;

  void fire() {
    if (!isActive) return;
    isActive = false;
    callback();
  }

  @override
  void cancel() {
    if (!isActive) return;
    isActive = false;
    onCancel();
  }
}

final class FakeRealtimeSocket implements ChatRealtimeSocket {
  final StreamController<Object?> _frames = StreamController<Object?>();

  @override
  Stream<Object?> get frames => _frames.stream;

  @override
  Future<void> send(String data) async {}

  void emitJson(Map<String, Object?> frame) => _frames.add(jsonEncode(frame));

  @override
  Future<void> close() => _frames.close();
}
