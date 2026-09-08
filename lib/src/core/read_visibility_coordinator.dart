part of '../handrail_chat_client.dart';

/// Returns the wall-clock time used to measure continuous message exposure.
typedef ChatReadVisibilityClock = DateTime Function();

/// Sends a visibility-qualified read through the client's existing read path.
typedef ChatReadVisibilityMarkRead
    = Future<ChatCommandResult<ReadCursorMutationResult>> Function(
  ChatMarkReadInput input,
);

/// A cancellable callback created by [ChatReadVisibilityScheduler].
abstract interface class ChatReadVisibilityTimer {
  void cancel();
}

/// Framework-neutral scheduling boundary for exposure and retry delays.
abstract interface class ChatReadVisibilityScheduler {
  ChatReadVisibilityTimer schedule(
    Duration delay,
    void Function() callback,
  );
}

/// Coordinates custom-timeline visibility with durable read-cursor advances.
///
/// Hosts report application/conversation activity, scroll activity, and the
/// highest sequence visible in each conversation. A sequence is sent only
/// after that same highest candidate remains eligible for [minimumExposure].
/// Higher samples replace lower pending samples and restart the exposure
/// interval; lower samples never move a candidate or successful cursor back.
///
/// The underlying [HandrailChatClient.markRead] command owns its normal bounded
/// transport retry.
/// If that command still returns a transport, authentication, or malformed
/// response failure, this coordinator makes exactly one additional attempt
/// after [failureRetryDelay], using the same idempotency key. It never overlaps
/// sends for one conversation. A second failure is held until eligibility is
/// lost and regained or a higher candidate is reported, preventing tight or
/// unbounded retry loops.
///
/// This class is pure Dart. It does not inspect widgets or render objects.
final class ChatReadVisibilityCoordinator {
  ChatReadVisibilityCoordinator({
    required ChatReadVisibilityMarkRead markRead,
    this.minimumExposure = const Duration(milliseconds: 500),
    this.failureRetryDelay = const Duration(seconds: 2),
    this.rapidScrollVelocityThreshold = 1200,
    ChatReadVisibilityClock? clock,
    ChatReadVisibilityScheduler? scheduler,
    ChatCommandIdempotencyKeyGenerator? generateIdempotencyKey,
  })  : _markRead = markRead,
        _clock = clock ?? DateTime.now,
        _scheduler = scheduler ?? const _DartReadVisibilityScheduler(),
        _generateIdempotencyKey =
            generateIdempotencyKey ?? _generateSecureCommandIdempotencyKey {
    if (minimumExposure.isNegative) {
      throw ArgumentError.value(
        minimumExposure,
        'minimumExposure',
        'must not be negative',
      );
    }
    if (failureRetryDelay <= Duration.zero) {
      throw ArgumentError.value(
        failureRetryDelay,
        'failureRetryDelay',
        'must be greater than zero',
      );
    }
    if (!rapidScrollVelocityThreshold.isFinite ||
        rapidScrollVelocityThreshold <= 0) {
      throw ArgumentError.value(
        rapidScrollVelocityThreshold,
        'rapidScrollVelocityThreshold',
        'must be finite and greater than zero',
      );
    }
  }

  final Duration minimumExposure;
  final Duration failureRetryDelay;

  /// Absolute host-defined scroll units per second treated as rapid motion.
  final double rapidScrollVelocityThreshold;

  final ChatReadVisibilityMarkRead _markRead;
  final ChatReadVisibilityClock _clock;
  final ChatReadVisibilityScheduler _scheduler;
  final ChatCommandIdempotencyKeyGenerator _generateIdempotencyKey;
  final Map<ConversationId, _ReadVisibilityConversation> _conversations = {};
  var _isForeground = false;
  var _disposed = false;

  /// Whether visibility samples are currently eligible at the app level.
  bool get isApplicationForeground => _isForeground;

  /// Starts or stops exposure accounting for every active conversation.
  ///
  /// Pending candidates are retained while backgrounded, but elapsed exposure
  /// and scheduled retry work are invalidated. Foregrounding begins a fresh
  /// full exposure interval.
  void setApplicationForeground(bool isForeground) {
    if (_disposed || _isForeground == isForeground) return;
    _isForeground = isForeground;
    for (final state in _conversations.values) {
      if (isForeground) {
        _ensureExposure(state);
      } else {
        _suspend(state, clearCandidate: false);
      }
    }
  }

  /// Sets whether one conversation is actively presented to the user.
  ///
  /// Deactivation discards its candidate, because a later activation may show
  /// a different viewport and must provide a fresh visibility sample.
  void setConversationActive(
    ConversationId conversationId, {
    required bool isActive,
  }) {
    if (_disposed) return;
    final state = _stateFor(conversationId);
    if (state.active == isActive) return;
    state.active = isActive;
    if (isActive) {
      _ensureExposure(state);
    } else {
      _suspend(state, clearCandidate: true);
    }
  }

  /// Reports host scroll velocity and whether scrolling has settled.
  ///
  /// Unsettled motion at or above [rapidScrollVelocityThreshold] suppresses
  /// reads. Settling, or slowing below the threshold, starts a fresh exposure
  /// interval for the retained highest candidate.
  void reportScrollActivity({
    required ConversationId conversationId,
    required double velocity,
    required bool isSettled,
  }) {
    if (_disposed) return;
    if (!velocity.isFinite) {
      throw ArgumentError.value(velocity, 'velocity', 'must be finite');
    }
    final state = _stateFor(conversationId);
    final rapid = !isSettled && velocity.abs() >= rapidScrollVelocityThreshold;
    _setRapidScrolling(state, rapid);
  }

  /// Direct rapid/settled signal for hosts that classify velocity themselves.
  void setRapidScrolling(
    ConversationId conversationId, {
    required bool isRapidScrolling,
  }) {
    if (_disposed) return;
    _setRapidScrolling(_stateFor(conversationId), isRapidScrolling);
  }

  /// Reports the highest sequence presently visible in one custom timeline.
  ///
  /// Reports are monotonic while a candidate is pending: equal samples keep
  /// the current interval and lower samples are ignored. A higher sample
  /// replaces the candidate and must survive a new full exposure interval.
  void reportVisibleThrough({
    required ConversationId conversationId,
    required MessageSequence sequence,
  }) {
    if (_disposed) return;
    final state = _stateFor(conversationId);
    final completed = state.lastSuccessfulSequence;
    if (completed != null && sequence.value <= completed.value) return;
    final current = state.candidate;
    if (current != null && sequence.value <= current.value) {
      if (sequence == current) _ensureExposure(state);
      return;
    }

    _cancelTimer(state);
    state.candidate = sequence;
    state.intent = ChatMarkReadInput(
      conversationId: conversationId,
      throughSequence: sequence,
      idempotencyKey: _generateIdempotencyKey(),
    );
    state.exposedSince = null;
    state.sendAttempts = 0;
    state.retryExhausted = false;
    _ensureExposure(state);
  }

  /// Invalidates an exact pending candidate whose message was deleted.
  ///
  /// The host must report a new highest visible sequence after invalidation.
  void reportSequenceDeleted({
    required ConversationId conversationId,
    required MessageSequence sequence,
  }) {
    if (_disposed) return;
    final state = _conversations[conversationId];
    if (state?.candidate != sequence) return;
    _suspend(state!, clearCandidate: true);
  }

  /// Cancels all scheduled work and ignores late asynchronous completions.
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    for (final state in _conversations.values) {
      _cancelTimer(state);
      state.candidate = null;
      state.intent = null;
      state.exposedSince = null;
    }
    _conversations.clear();
  }

  _ReadVisibilityConversation _stateFor(ConversationId conversationId) =>
      _conversations.putIfAbsent(
        conversationId,
        _ReadVisibilityConversation.new,
      );

  void _setRapidScrolling(
    _ReadVisibilityConversation state,
    bool isRapidScrolling,
  ) {
    if (state.rapidScrolling == isRapidScrolling) return;
    state.rapidScrolling = isRapidScrolling;
    if (isRapidScrolling) {
      _suspend(state, clearCandidate: false);
    } else {
      _ensureExposure(state);
    }
  }

  void _suspend(
    _ReadVisibilityConversation state, {
    required bool clearCandidate,
  }) {
    _cancelTimer(state);
    state.exposedSince = null;
    state.sendAttempts = 0;
    state.retryExhausted = false;
    if (clearCandidate) {
      state.candidate = null;
      state.intent = null;
    }
  }

  bool _isEligible(_ReadVisibilityConversation state) =>
      !_disposed &&
      _isForeground &&
      state.active &&
      !state.rapidScrolling &&
      state.candidate != null &&
      !state.retryExhausted;

  void _ensureExposure(_ReadVisibilityConversation state) {
    if (!_isEligible(state)) return;
    state.exposedSince ??= _now();
    if (state.inFlight != null || state.timer != null) return;
    final elapsed = _elapsedSince(state.exposedSince!);
    final remaining = minimumExposure - elapsed;
    _schedule(
      state,
      remaining.isNegative ? Duration.zero : remaining,
      () => _exposureElapsed(state),
    );
  }

  void _exposureElapsed(_ReadVisibilityConversation state) {
    if (!_isEligible(state)) return;
    final exposedSince = state.exposedSince;
    if (exposedSince == null) return;
    final elapsed = _elapsedSince(exposedSince);
    if (elapsed < minimumExposure) {
      _schedule(
          state, minimumExposure - elapsed, () => _exposureElapsed(state));
      return;
    }
    _send(state);
  }

  void _send(_ReadVisibilityConversation state) {
    if (!_isEligible(state) || state.inFlight != null) return;
    final intent = state.intent;
    if (intent == null || intent.throughSequence != state.candidate) return;

    final token = Object();
    final generation = state.generation;
    state.inFlight = token;
    state.sendAttempts += 1;
    late final Future<ChatCommandResult<ReadCursorMutationResult>> operation;
    try {
      operation = _markRead(intent);
    } catch (_) {
      operation = Future.value(
        const ChatCommandTransportFailure<ReadCursorMutationResult>(),
      );
    }
    unawaited(
      operation.then<void>(
        (result) => _finishSend(state, token, generation, intent, result),
        onError: (_, __) => _finishSend(
          state,
          token,
          generation,
          intent,
          const ChatCommandTransportFailure<ReadCursorMutationResult>(),
        ),
      ),
    );
  }

  void _finishSend(
    _ReadVisibilityConversation state,
    Object token,
    int generation,
    ChatMarkReadInput intent,
    ChatCommandResult<ReadCursorMutationResult> result,
  ) {
    if (!identical(state.inFlight, token)) return;
    state.inFlight = null;
    if (_disposed) return;

    if (result is ChatCommandSuccess<ReadCursorMutationResult>) {
      final successful = state.lastSuccessfulSequence;
      if (successful == null ||
          intent.throughSequence.value > successful.value) {
        state.lastSuccessfulSequence = intent.throughSequence;
      }
      final candidate = state.candidate;
      if (candidate != null &&
          candidate.value <= intent.throughSequence.value) {
        _cancelTimer(state);
        state.candidate = null;
        state.intent = null;
        state.exposedSince = null;
        state.sendAttempts = 0;
        state.retryExhausted = false;
      } else {
        _ensureExposure(state);
      }
      return;
    }

    final isCurrent = identical(state.intent, intent) &&
        generation == state.generation &&
        _isEligible(state);
    if (!isCurrent) {
      _ensureExposure(state);
      return;
    }
    if (_isRetryable(result) && state.sendAttempts == 1) {
      _schedule(state, failureRetryDelay, () => _send(state));
      return;
    }
    state.retryExhausted = true;
    _cancelTimer(state);
  }

  bool _isRetryable(ChatCommandResult<ReadCursorMutationResult> result) =>
      result.category == ChatCommandResultCategory.transport ||
      result.category == ChatCommandResultCategory.authentication ||
      result.category == ChatCommandResultCategory.malformedResponse;

  void _schedule(
    _ReadVisibilityConversation state,
    Duration delay,
    void Function() callback,
  ) {
    _cancelTimer(state);
    final generation = state.generation;
    state.timer = _scheduler.schedule(delay, () {
      if (_disposed || generation != state.generation) return;
      state.timer = null;
      callback();
    });
  }

  void _cancelTimer(_ReadVisibilityConversation state) {
    state.generation += 1;
    state.timer?.cancel();
    state.timer = null;
  }

  DateTime _now() => _clock().toUtc();

  Duration _elapsedSince(DateTime startedAt) {
    final elapsed = _now().difference(startedAt);
    return elapsed.isNegative ? Duration.zero : elapsed;
  }
}

final class _ReadVisibilityConversation {
  var active = false;
  var rapidScrolling = false;
  MessageSequence? candidate;
  MessageSequence? lastSuccessfulSequence;
  ChatMarkReadInput? intent;
  DateTime? exposedSince;
  ChatReadVisibilityTimer? timer;
  Object? inFlight;
  var generation = 0;
  var sendAttempts = 0;
  var retryExhausted = false;
}

final class _DartReadVisibilityScheduler
    implements ChatReadVisibilityScheduler {
  const _DartReadVisibilityScheduler();

  @override
  ChatReadVisibilityTimer schedule(
    Duration delay,
    void Function() callback,
  ) =>
      _DartReadVisibilityTimer(Timer(delay, callback));
}

final class _DartReadVisibilityTimer implements ChatReadVisibilityTimer {
  const _DartReadVisibilityTimer(this._timer);

  final Timer _timer;

  @override
  void cancel() => _timer.cancel();
}
