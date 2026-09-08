import 'dart:async';
import 'dart:collection';

import '../generated/ephemeral_signals.dart';
import '../generated/identifiers.dart';

/// Returns the current wall-clock time used for signal expiry decisions.
typedef EphemeralSignalClock = DateTime Function();

/// A cancellable scheduled expiry callback.
abstract interface class EphemeralSignalTimer {
  void cancel();
}

/// Schedules the single next expiry owned by an [EphemeralSignalStore].
abstract interface class EphemeralSignalScheduler {
  EphemeralSignalTimer schedule(Duration delay, void Function() callback);
}

/// The complete identity of one typing signal entry.
final class TypingSignalKey {
  const TypingSignalKey({
    required this.tenantId,
    required this.conversationId,
    required this.actorUserId,
    required this.deviceId,
    required this.sessionId,
  });

  factory TypingSignalKey.fromEvent(TypingSignalEvent event) => TypingSignalKey(
        tenantId: event.tenantId,
        conversationId: event.payload.scope.conversationId,
        actorUserId: event.payload.actorUserId,
        deviceId: event.payload.deviceId,
        sessionId: event.payload.sessionId,
      );

  final TenantId tenantId;
  final ConversationId conversationId;
  final UserId actorUserId;
  final DeviceId deviceId;
  final SessionId sessionId;

  @override
  bool operator ==(Object other) =>
      other is TypingSignalKey &&
      other.tenantId == tenantId &&
      other.conversationId == conversationId &&
      other.actorUserId == actorUserId &&
      other.deviceId == deviceId &&
      other.sessionId == sessionId;

  @override
  int get hashCode => Object.hash(
        tenantId,
        conversationId,
        actorUserId,
        deviceId,
        sessionId,
      );
}

/// The complete identity of one presence signal entry.
final class PresenceSignalKey {
  const PresenceSignalKey({
    required this.tenantId,
    required this.scopedUserId,
    required this.actorUserId,
    required this.deviceId,
    required this.sessionId,
  });

  factory PresenceSignalKey.fromEvent(PresenceSignalEvent event) =>
      PresenceSignalKey(
        tenantId: event.tenantId,
        scopedUserId: event.payload.scope.userId,
        actorUserId: event.payload.actorUserId,
        deviceId: event.payload.deviceId,
        sessionId: event.payload.sessionId,
      );

  final TenantId tenantId;
  final UserId scopedUserId;
  final UserId actorUserId;
  final DeviceId deviceId;
  final SessionId sessionId;

  @override
  bool operator ==(Object other) =>
      other is PresenceSignalKey &&
      other.tenantId == tenantId &&
      other.scopedUserId == scopedUserId &&
      other.actorUserId == actorUserId &&
      other.deviceId == deviceId &&
      other.sessionId == sessionId;

  @override
  int get hashCode => Object.hash(
        tenantId,
        scopedUserId,
        actorUserId,
        deviceId,
        sessionId,
      );
}

/// Immutable typing entries and conversation-scoped selectors.
final class TypingSignalSnapshot {
  TypingSignalSnapshot._(Map<TypingSignalKey, TypingSignalEvent> entries)
      : entries = UnmodifiableMapView(Map.of(entries));

  factory TypingSignalSnapshot.empty() => TypingSignalSnapshot._(const {});

  final Map<TypingSignalKey, TypingSignalEvent> entries;

  List<TypingSignalEvent> forConversation(
    TenantId tenantId,
    ConversationId conversationId,
  ) =>
      List<TypingSignalEvent>.unmodifiable(
        entries.entries
            .where(
              (entry) =>
                  entry.key.tenantId == tenantId &&
                  entry.key.conversationId == conversationId,
            )
            .map((entry) => entry.value),
      );
}

/// Immutable presence entries and user-scoped selectors.
final class PresenceSignalSnapshot {
  PresenceSignalSnapshot._(Map<PresenceSignalKey, PresenceSignalEvent> entries)
      : entries = UnmodifiableMapView(Map.of(entries));

  factory PresenceSignalSnapshot.empty() => PresenceSignalSnapshot._(const {});

  final Map<PresenceSignalKey, PresenceSignalEvent> entries;

  List<PresenceSignalEvent> forUser(
    TenantId tenantId,
    UserId scopedUserId,
  ) =>
      List<PresenceSignalEvent>.unmodifiable(
        entries.entries
            .where(
              (entry) =>
                  entry.key.tenantId == tenantId &&
                  entry.key.scopedUserId == scopedUserId,
            )
            .map((entry) => entry.value),
      );
}

/// Immutable aggregate typing and presence state.
final class EphemeralSignalSnapshot {
  const EphemeralSignalSnapshot._({
    required this.typing,
    required this.presence,
  });

  factory EphemeralSignalSnapshot.empty() => EphemeralSignalSnapshot._(
        typing: TypingSignalSnapshot.empty(),
        presence: PresenceSignalSnapshot.empty(),
      );

  final TypingSignalSnapshot typing;
  final PresenceSignalSnapshot presence;

  bool get isEmpty => typing.entries.isEmpty && presence.entries.isEmpty;
}

/// Pure-Dart transient state for accepted typing and presence frames.
///
/// Change streams are synchronous broadcast streams and do not emit an initial
/// value; read [snapshot] before subscribing when an initial value is needed.
/// [apply], [expire], and [disconnectSession] return `false` after [close].
final class EphemeralSignalStore {
  EphemeralSignalStore({
    EphemeralSignalClock? clock,
    EphemeralSignalScheduler? scheduler,
  })  : _clock = clock ?? DateTime.now,
        _scheduler = scheduler ?? const _DartEphemeralSignalScheduler(),
        _snapshot = EphemeralSignalSnapshot.empty();

  final EphemeralSignalClock _clock;
  final EphemeralSignalScheduler _scheduler;
  final StreamController<EphemeralSignalSnapshot> _snapshotChanges =
      StreamController<EphemeralSignalSnapshot>.broadcast(sync: true);
  final StreamController<TypingSignalSnapshot> _typingChanges =
      StreamController<TypingSignalSnapshot>.broadcast(sync: true);
  final StreamController<PresenceSignalSnapshot> _presenceChanges =
      StreamController<PresenceSignalSnapshot>.broadcast(sync: true);

  EphemeralSignalSnapshot _snapshot;
  EphemeralSignalTimer? _expiryTimer;
  DateTime? _scheduledExpiry;
  Future<void>? _closeOperation;
  var _timerEpoch = 0;
  var _closed = false;

  EphemeralSignalSnapshot get snapshot => _snapshot;
  bool get isClosed => _closed;

  Stream<EphemeralSignalSnapshot> get snapshots => _snapshotChanges.stream;
  Stream<TypingSignalSnapshot> get typingSnapshots => _typingChanges.stream;
  Stream<PresenceSignalSnapshot> get presenceSnapshots =>
      _presenceChanges.stream;

  /// Accepts a live frame only when its `sentAt` is strictly newer than the
  /// currently accepted frame for the same full identity key.
  bool apply(EphemeralSignalEvent event) {
    if (_closed) return false;
    final now = _now();
    final expired = _liveMaps(now);
    var typing = expired.typing;
    var presence = expired.presence;

    if (!_expiresAt(event).isAfter(now)) {
      return _replace(typing: typing, presence: presence);
    }

    switch (event) {
      case TypingSignalEvent():
        final key = TypingSignalKey.fromEvent(event);
        final accepted = typing[key];
        if (accepted != null && !_sentAt(event).isAfter(_sentAt(accepted))) {
          return _replace(typing: typing, presence: presence);
        }
        typing = Map<TypingSignalKey, TypingSignalEvent>.of(typing)
          ..[key] = event;
      case PresenceSignalEvent():
        final key = PresenceSignalKey.fromEvent(event);
        final accepted = presence[key];
        if (accepted != null && !_sentAt(event).isAfter(_sentAt(accepted))) {
          return _replace(typing: typing, presence: presence);
        }
        presence = Map<PresenceSignalKey, PresenceSignalEvent>.of(presence)
          ..[key] = event;
    }
    return _replace(typing: typing, presence: presence);
  }

  /// Removes entries whose `expiresAt` is at or before the injected clock.
  bool expire() {
    if (_closed) return false;
    final live = _liveMaps(_now());
    return _replace(typing: live.typing, presence: live.presence);
  }

  /// Removes only entries owned by [sessionId] in [tenantId].
  bool disconnectSession(TenantId tenantId, SessionId sessionId) {
    if (_closed) return false;
    final priorTyping = _snapshot.typing.entries;
    final priorPresence = _snapshot.presence.entries;
    final removesTyping = priorTyping.keys.any(
      (key) => key.tenantId == tenantId && key.sessionId == sessionId,
    );
    final removesPresence = priorPresence.keys.any(
      (key) => key.tenantId == tenantId && key.sessionId == sessionId,
    );
    final typing = removesTyping
        ? (Map<TypingSignalKey, TypingSignalEvent>.of(priorTyping)
          ..removeWhere(
            (key, _) => key.tenantId == tenantId && key.sessionId == sessionId,
          ))
        : priorTyping;
    final presence = removesPresence
        ? (Map<PresenceSignalKey, PresenceSignalEvent>.of(priorPresence)
          ..removeWhere(
            (key, _) => key.tenantId == tenantId && key.sessionId == sessionId,
          ))
        : priorPresence;
    return _replace(typing: typing, presence: presence);
  }

  /// Permanently clears state, cancels expiry, and closes all streams.
  Future<void> close() {
    final existing = _closeOperation;
    if (existing != null) return existing;
    _closed = true;
    _cancelExpiry();
    if (!_snapshot.isEmpty) {
      _replaceSnapshot(
        typing: const {},
        presence: const {},
        reschedule: false,
      );
    }
    final operation = Future.wait<void>([
      _snapshotChanges.close(),
      _typingChanges.close(),
      _presenceChanges.close(),
    ]);
    _closeOperation = operation;
    return operation;
  }

  /// Alias for [close]. Repeated disposal is harmless.
  Future<void> dispose() => close();

  _LiveSignalMaps _liveMaps(DateTime now) {
    final typing = _snapshot.typing.entries;
    final presence = _snapshot.presence.entries;
    Map<TypingSignalKey, TypingSignalEvent>? nextTyping;
    Map<PresenceSignalKey, PresenceSignalEvent>? nextPresence;

    for (final entry in typing.entries) {
      if (!_expiresAt(entry.value).isAfter(now)) {
        (nextTyping ??= Map.of(typing)).remove(entry.key);
      }
    }
    for (final entry in presence.entries) {
      if (!_expiresAt(entry.value).isAfter(now)) {
        (nextPresence ??= Map.of(presence)).remove(entry.key);
      }
    }
    return _LiveSignalMaps(
      typing: nextTyping ?? typing,
      presence: nextPresence ?? presence,
    );
  }

  bool _replace({
    required Map<TypingSignalKey, TypingSignalEvent> typing,
    required Map<PresenceSignalKey, PresenceSignalEvent> presence,
  }) {
    if (identical(typing, _snapshot.typing.entries) &&
        identical(presence, _snapshot.presence.entries)) {
      _scheduleExpiry();
      return false;
    }
    _replaceSnapshot(typing: typing, presence: presence);
    return true;
  }

  void _replaceSnapshot({
    required Map<TypingSignalKey, TypingSignalEvent> typing,
    required Map<PresenceSignalKey, PresenceSignalEvent> presence,
    bool reschedule = true,
  }) {
    final previous = _snapshot;
    final nextTyping = identical(typing, previous.typing.entries)
        ? previous.typing
        : TypingSignalSnapshot._(typing);
    final nextPresence = identical(presence, previous.presence.entries)
        ? previous.presence
        : PresenceSignalSnapshot._(presence);
    _snapshot = EphemeralSignalSnapshot._(
      typing: nextTyping,
      presence: nextPresence,
    );
    if (!_snapshotChanges.isClosed) _snapshotChanges.add(_snapshot);
    if (!identical(nextTyping, previous.typing) && !_typingChanges.isClosed) {
      _typingChanges.add(nextTyping);
    }
    if (!identical(nextPresence, previous.presence) &&
        !_presenceChanges.isClosed) {
      _presenceChanges.add(nextPresence);
    }
    if (reschedule) _scheduleExpiry();
  }

  void _scheduleExpiry() {
    if (_closed) return;
    DateTime? earliest;
    for (final event in <EphemeralSignalEvent>[
      ..._snapshot.typing.entries.values,
      ..._snapshot.presence.entries.values,
    ]) {
      final expiry = _expiresAt(event);
      if (earliest == null || expiry.isBefore(earliest)) earliest = expiry;
    }
    if (earliest == null) {
      _cancelExpiry();
      return;
    }
    if (_expiryTimer != null && earliest == _scheduledExpiry) return;

    _cancelExpiry();
    final epoch = ++_timerEpoch;
    final delay = earliest.difference(_now());
    _scheduledExpiry = earliest;
    try {
      _expiryTimer = _scheduler.schedule(
        delay.isNegative ? Duration.zero : delay,
        () {
          if (_closed || epoch != _timerEpoch) return;
          _expiryTimer = null;
          _scheduledExpiry = null;
          expire();
        },
      );
    } catch (_) {
      _scheduledExpiry = null;
      rethrow;
    }
  }

  void _cancelExpiry() {
    ++_timerEpoch;
    _expiryTimer?.cancel();
    _expiryTimer = null;
    _scheduledExpiry = null;
  }

  DateTime _now() => _clock().toUtc();
}

final class _LiveSignalMaps {
  const _LiveSignalMaps({required this.typing, required this.presence});

  final Map<TypingSignalKey, TypingSignalEvent> typing;
  final Map<PresenceSignalKey, PresenceSignalEvent> presence;
}

DateTime _sentAt(EphemeralSignalEvent event) =>
    DateTime.parse(event.payload.sentAt.value).toUtc();

DateTime _expiresAt(EphemeralSignalEvent event) =>
    DateTime.parse(event.payload.expiresAt.value).toUtc();

final class _DartEphemeralSignalTimer implements EphemeralSignalTimer {
  const _DartEphemeralSignalTimer(this._timer);

  final Timer _timer;

  @override
  void cancel() => _timer.cancel();
}

final class _DartEphemeralSignalScheduler implements EphemeralSignalScheduler {
  const _DartEphemeralSignalScheduler();

  @override
  EphemeralSignalTimer schedule(Duration delay, void Function() callback) =>
      _DartEphemeralSignalTimer(Timer(delay, callback));
}
