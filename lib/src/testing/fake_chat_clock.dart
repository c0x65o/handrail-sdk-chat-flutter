import '../../core.dart';

/// One deterministic wall clock and scheduler for Handrail's public timers.
final class FakeChatClock
    implements
        ChatRealtimeClock,
        ChatRealtimeEphemeralClock,
        ChatReadVisibilityScheduler,
        ChatDraftMutationScheduler,
        EphemeralSignalScheduler {
  FakeChatClock([DateTime? initialTime])
      : _initialTime = initialTime ?? DateTime.utc(2000),
        _now = initialTime ?? DateTime.utc(2000);

  final DateTime _initialTime;
  final List<_ScheduledChatCallback> _callbacks = <_ScheduledChatCallback>[];
  DateTime _now;
  var _nextSequence = 0;
  var _disposed = false;

  @override
  DateTime now() => _now;

  int get pendingTimerCount =>
      _callbacks.where((callback) => callback.isActive).length;
  bool get isDisposed => _disposed;

  @override
  FakeChatTimer schedule(Duration delay, void Function() callback) {
    _ensureActive();
    if (delay.isNegative) {
      throw ArgumentError.value(delay, 'delay', 'must not be negative');
    }
    final scheduled = _ScheduledChatCallback(
      dueAt: _now.add(delay),
      sequence: _nextSequence++,
      callback: callback,
    );
    _callbacks.add(scheduled);
    return FakeChatTimer._(scheduled);
  }

  /// A [ChatHuddleTimerScheduler]-compatible tear-off.
  void Function() scheduleHuddle(
    Duration delay,
    void Function() callback,
  ) {
    final timer = schedule(delay, callback);
    return timer.cancel;
  }

  /// Advances time, running due callbacks in due-time and insertion order.
  void elapse(Duration duration) {
    _ensureActive();
    if (duration.isNegative) {
      throw ArgumentError.value(duration, 'duration', 'must not be negative');
    }
    final target = _now.add(duration);
    while (true) {
      final next = _nextActive(dueOnOrBefore: target);
      if (next == null) break;
      _now = next.dueAt;
      next.run();
    }
    _now = target;
    _removeInactive();
  }

  /// Runs the next active callback and advances to its due time.
  bool runNext() {
    _ensureActive();
    final next = _nextActive();
    if (next == null) return false;
    _now = next.dueAt.isAfter(_now) ? next.dueAt : _now;
    next.run();
    _removeInactive();
    return true;
  }

  /// Runs all currently and subsequently scheduled callbacks.
  void runAll({int maximumCallbacks = 1000}) {
    var count = 0;
    while (runNext()) {
      count += 1;
      if (count > maximumCallbacks) {
        throw StateError('The fake clock exceeded its callback limit.');
      }
    }
  }

  /// Cancels pending callbacks and restores the initial wall time.
  void reset() {
    _ensureActive();
    for (final callback in _callbacks) {
      callback.cancel();
    }
    _callbacks.clear();
    _now = _initialTime;
    _nextSequence = 0;
  }

  void dispose() {
    if (_disposed) return;
    for (final callback in _callbacks) {
      callback.cancel();
    }
    _callbacks.clear();
    _disposed = true;
  }

  _ScheduledChatCallback? _nextActive({DateTime? dueOnOrBefore}) {
    _ScheduledChatCallback? next;
    for (final candidate in _callbacks) {
      if (!candidate.isActive ||
          (dueOnOrBefore != null && candidate.dueAt.isAfter(dueOnOrBefore))) {
        continue;
      }
      if (next == null ||
          candidate.dueAt.isBefore(next.dueAt) ||
          (candidate.dueAt == next.dueAt &&
              candidate.sequence < next.sequence)) {
        next = candidate;
      }
    }
    return next;
  }

  void _removeInactive() =>
      _callbacks.removeWhere((callback) => !callback.isActive);

  void _ensureActive() {
    if (_disposed) throw StateError('The fake chat clock is disposed.');
  }
}

/// Timer handle shared by all supported scheduler boundaries.
final class FakeChatTimer
    implements
        ChatRealtimeTimer,
        ChatReadVisibilityTimer,
        ChatDraftMutationTimer,
        EphemeralSignalTimer {
  FakeChatTimer._(this._callback);

  final _ScheduledChatCallback _callback;

  bool get isActive => _callback.isActive;

  @override
  void cancel() => _callback.cancel();
}

final class _ScheduledChatCallback {
  _ScheduledChatCallback({
    required this.dueAt,
    required this.sequence,
    required this.callback,
  });

  final DateTime dueAt;
  final int sequence;
  final void Function() callback;
  var isActive = true;

  void cancel() => isActive = false;

  void run() {
    if (!isActive) return;
    isActive = false;
    callback();
  }
}
