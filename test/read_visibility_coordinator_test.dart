import 'dart:async';

import 'package:handrail_chat/core.dart';
import 'package:test/test.dart';

const _conversationOne = ConversationId('conversation-1');
const _conversationTwo = ConversationId('conversation-2');
const _user = UserId('user-1');
const _exposure = Duration(milliseconds: 100);
const _retryDelay = Duration(seconds: 2);

void main() {
  test('requires the full continuous exposure duration', () async {
    final harness = _Harness();
    harness.activate(_conversationOne);

    harness.coordinator.reportVisibleThrough(
      conversationId: _conversationOne,
      sequence: const MessageSequence(4),
    );
    harness.scheduler.advance(const Duration(milliseconds: 99));
    await _flush();
    expect(harness.calls, isEmpty);

    harness.scheduler.advance(const Duration(milliseconds: 1));
    await _flush();
    expect(harness.sequences, [4]);
  });

  test('requires foreground and active conversation state', () async {
    final harness = _Harness();
    harness.coordinator.reportVisibleThrough(
      conversationId: _conversationOne,
      sequence: const MessageSequence(3),
    );
    harness.scheduler.advance(const Duration(days: 1));
    expect(harness.calls, isEmpty);

    harness.coordinator.setApplicationForeground(true);
    harness.scheduler.advance(const Duration(days: 1));
    expect(harness.calls, isEmpty);

    harness.coordinator.setConversationActive(
      _conversationOne,
      isActive: true,
    );
    harness.scheduler.advance(_exposure);
    await _flush();
    expect(harness.sequences, [3]);

    harness.coordinator.reportVisibleThrough(
      conversationId: _conversationOne,
      sequence: const MessageSequence(4),
    );
    harness.scheduler.advance(const Duration(milliseconds: 50));
    harness.coordinator.setApplicationForeground(false);
    expect(harness.scheduler.activeCount, 0);
    harness.coordinator.setApplicationForeground(true);
    harness.scheduler.advance(const Duration(milliseconds: 99));
    await _flush();
    expect(harness.sequences, [3]);
    harness.scheduler.advance(const Duration(milliseconds: 1));
    await _flush();
    expect(harness.sequences, [3, 4]);
  });

  test('suppresses rapid scrolling and restarts exposure when settled',
      () async {
    final harness = _Harness();
    harness.activate(_conversationOne);
    harness.coordinator.reportVisibleThrough(
      conversationId: _conversationOne,
      sequence: const MessageSequence(5),
    );
    harness.scheduler.advance(const Duration(milliseconds: 40));

    harness.coordinator.reportScrollActivity(
      conversationId: _conversationOne,
      velocity: -1400,
      isSettled: false,
    );
    expect(harness.scheduler.activeCount, 0);
    harness.scheduler.advance(const Duration(seconds: 10));
    expect(harness.calls, isEmpty);

    harness.coordinator.reportScrollActivity(
      conversationId: _conversationOne,
      velocity: 0,
      isSettled: true,
    );
    harness.scheduler.advance(const Duration(milliseconds: 99));
    await _flush();
    expect(harness.calls, isEmpty);
    harness.scheduler.advance(const Duration(milliseconds: 1));
    await _flush();
    expect(harness.sequences, [5]);
  });

  test('coalesces monotonically and higher replacement restarts duration',
      () async {
    final harness = _Harness();
    harness.activate(_conversationOne);
    harness.coordinator.reportVisibleThrough(
      conversationId: _conversationOne,
      sequence: const MessageSequence(4),
    );
    harness.scheduler.advance(const Duration(milliseconds: 50));
    harness.coordinator.reportVisibleThrough(
      conversationId: _conversationOne,
      sequence: const MessageSequence(3),
    );
    harness.coordinator.reportVisibleThrough(
      conversationId: _conversationOne,
      sequence: const MessageSequence(4),
    );
    harness.scheduler.advance(const Duration(milliseconds: 50));
    await _flush();
    expect(harness.sequences, [4]);

    harness.coordinator.reportVisibleThrough(
      conversationId: _conversationOne,
      sequence: const MessageSequence(5),
    );
    harness.scheduler.advance(const Duration(milliseconds: 60));
    harness.coordinator.reportVisibleThrough(
      conversationId: _conversationOne,
      sequence: const MessageSequence(7),
    );
    harness.scheduler.advance(const Duration(milliseconds: 99));
    await _flush();
    expect(harness.sequences, [4]);
    harness.scheduler.advance(const Duration(milliseconds: 1));
    await _flush();
    expect(harness.sequences, [4, 7]);

    harness.coordinator.reportVisibleThrough(
      conversationId: _conversationOne,
      sequence: const MessageSequence(6),
    );
    harness.scheduler.advance(const Duration(days: 1));
    await _flush();
    expect(harness.sequences, [4, 7]);
  });

  test('conversation deactivation and candidate deletion require new samples',
      () async {
    final harness = _Harness();
    harness.activate(_conversationOne);
    harness.coordinator.reportVisibleThrough(
      conversationId: _conversationOne,
      sequence: const MessageSequence(5),
    );
    final deactivatedTimer = harness.scheduler.lastTimer;
    harness.coordinator.setConversationActive(
      _conversationOne,
      isActive: false,
    );
    harness.coordinator.setConversationActive(
      _conversationOne,
      isActive: true,
    );
    deactivatedTimer.fireIgnoringCancellation();
    harness.scheduler.advance(const Duration(days: 1));
    await _flush();
    expect(harness.calls, isEmpty);

    harness.coordinator.reportVisibleThrough(
      conversationId: _conversationOne,
      sequence: const MessageSequence(6),
    );
    final deletedTimer = harness.scheduler.lastTimer;
    harness.coordinator.reportSequenceDeleted(
      conversationId: _conversationOne,
      sequence: const MessageSequence(6),
    );
    deletedTimer.fireIgnoringCancellation();
    harness.scheduler.advance(const Duration(days: 1));
    await _flush();
    expect(harness.calls, isEmpty);

    harness.coordinator.reportVisibleThrough(
      conversationId: _conversationOne,
      sequence: const MessageSequence(5),
    );
    harness.scheduler.advance(_exposure);
    await _flush();
    expect(harness.sequences, [5]);
  });

  test('retries once with a stable key and never overlaps conversation sends',
      () async {
    final pending = <Completer<ChatCommandResult<ReadCursorMutationResult>>>[];
    final harness = _Harness(
      markRead: (input) {
        final operation =
            Completer<ChatCommandResult<ReadCursorMutationResult>>();
        pending.add(operation);
        return operation.future;
      },
    );
    harness.activate(_conversationOne);
    harness.coordinator.reportVisibleThrough(
      conversationId: _conversationOne,
      sequence: const MessageSequence(8),
    );
    harness.scheduler.advance(_exposure);
    await _flush();
    expect(harness.calls, hasLength(1));

    harness.coordinator.reportVisibleThrough(
      conversationId: _conversationOne,
      sequence: const MessageSequence(8),
    );
    harness.scheduler.advance(const Duration(days: 1));
    await _flush();
    expect(harness.calls, hasLength(1), reason: 'the first send is in flight');

    pending[0].complete(
      const ChatCommandTransportFailure<ReadCursorMutationResult>(),
    );
    await _flush();
    expect(harness.scheduler.activeCount, 1);
    harness.scheduler.advance(_retryDelay - const Duration(milliseconds: 1));
    await _flush();
    expect(harness.calls, hasLength(1));
    harness.scheduler.advance(const Duration(milliseconds: 1));
    await _flush();
    expect(harness.calls, hasLength(2));
    expect(harness.calls[1].idempotencyKey, harness.calls[0].idempotencyKey);

    pending[1].complete(
      const ChatCommandTransportFailure<ReadCursorMutationResult>(),
    );
    await _flush();
    expect(harness.scheduler.activeCount, 0);
    harness.coordinator.reportVisibleThrough(
      conversationId: _conversationOne,
      sequence: const MessageSequence(8),
    );
    harness.scheduler.advance(const Duration(days: 1));
    await _flush();
    expect(harness.calls, hasLength(2), reason: 'retry budget is exhausted');

    harness.coordinator.setRapidScrolling(
      _conversationOne,
      isRapidScrolling: true,
    );
    harness.coordinator.setRapidScrolling(
      _conversationOne,
      isRapidScrolling: false,
    );
    harness.scheduler.advance(_exposure);
    await _flush();
    expect(harness.calls, hasLength(3), reason: 'new eligibility cycle');
  });

  test('keeps conversation timing and suppression isolated', () async {
    final harness = _Harness();
    harness.activate(_conversationOne);
    harness.coordinator.setConversationActive(
      _conversationTwo,
      isActive: true,
    );
    harness.coordinator.setRapidScrolling(
      _conversationOne,
      isRapidScrolling: true,
    );
    harness.coordinator.reportVisibleThrough(
      conversationId: _conversationOne,
      sequence: const MessageSequence(5),
    );
    harness.coordinator.reportVisibleThrough(
      conversationId: _conversationTwo,
      sequence: const MessageSequence(9),
    );
    harness.scheduler.advance(_exposure);
    await _flush();
    expect(harness.sequences, [9]);

    harness.coordinator.setRapidScrolling(
      _conversationOne,
      isRapidScrolling: false,
    );
    harness.scheduler.advance(_exposure);
    await _flush();
    expect(harness.sequences, [9, 5]);
  });

  test('disposal cancels every timer and suppresses stale callbacks', () async {
    final harness = _Harness();
    harness.activate(_conversationOne);
    harness.coordinator.setConversationActive(
      _conversationTwo,
      isActive: true,
    );
    harness.coordinator.reportVisibleThrough(
      conversationId: _conversationOne,
      sequence: const MessageSequence(4),
    );
    harness.coordinator.reportVisibleThrough(
      conversationId: _conversationTwo,
      sequence: const MessageSequence(6),
    );
    final timers = List<_FakeTimer>.of(harness.scheduler.timers);
    expect(harness.scheduler.activeCount, 2);

    harness.coordinator.dispose();
    expect(harness.scheduler.activeCount, 0);
    for (final timer in timers) {
      timer.fireIgnoringCancellation();
    }
    harness.scheduler.advance(const Duration(days: 1));
    await _flush();
    expect(harness.calls, isEmpty);

    harness.coordinator.reportVisibleThrough(
      conversationId: _conversationOne,
      sequence: const MessageSequence(10),
    );
    expect(harness.scheduler.activeCount, 0);
  });

  test('client disposal owns and drains the reads scheduler', () async {
    final scheduler = _FakeScheduler(DateTime.utc(2026, 8, 26));
    final client = HandrailChatClient(
      apiBaseUri: Uri.parse('https://chat.example.test/api/chat'),
      tokenProvider: () async => 'token',
      transport: _UnexpectedTransport(),
      readVisibilityClock: () => scheduler.now,
      readVisibilityScheduler: scheduler,
      readVisibilityMinimumExposure: _exposure,
      generateIdempotencyKey: () => 'client-visibility-key',
    );
    client.reads.setApplicationForeground(true);
    client.reads.setConversationActive(_conversationOne, isActive: true);
    client.reads.reportVisibleThrough(
      conversationId: _conversationOne,
      sequence: const MessageSequence(4),
    );
    expect(scheduler.activeCount, 1);

    await client.dispose();
    expect(scheduler.activeCount, 0);
    scheduler.advance(const Duration(days: 1));
  });
}

final class _Harness {
  _Harness({ChatReadVisibilityMarkRead? markRead})
      : scheduler = _FakeScheduler(DateTime.utc(2026, 8, 26)) {
    var key = 0;
    coordinator = ChatReadVisibilityCoordinator(
      markRead: (input) {
        calls.add(input);
        return markRead?.call(input) ?? Future.value(_success(input));
      },
      minimumExposure: _exposure,
      failureRetryDelay: _retryDelay,
      clock: () => scheduler.now,
      scheduler: scheduler,
      generateIdempotencyKey: () => 'visibility-key-${++key}',
    );
  }

  final _FakeScheduler scheduler;
  final List<ChatMarkReadInput> calls = [];
  late final ChatReadVisibilityCoordinator coordinator;

  List<int> get sequences =>
      calls.map((input) => input.throughSequence.value).toList();

  void activate(ConversationId conversationId) {
    coordinator.setApplicationForeground(true);
    coordinator.setConversationActive(conversationId, isActive: true);
  }
}

ChatCommandSuccess<ReadCursorMutationResult> _success(
  ChatMarkReadInput input,
) =>
    ChatCommandSuccess<ReadCursorMutationResult>(
      ReadCursorMutationResult(
        operation: ReadCursorMutationOperation.markRead,
        reconciliationStatus: ReadCursorReconciliationStatus.applied,
        idempotencyKey: input.idempotencyKey!,
        conversationId: input.conversationId,
        readState: ConversationReadState(
          conversationId: input.conversationId,
          userId: _user,
          lastReadSequence: input.throughSequence,
          updatedAt: const IsoTimestamp('2026-08-26T00:00:00.000Z'),
        ),
        latestSequence: input.throughSequence,
        unreadCount: 0,
      ),
    );

Future<void> _flush() async {
  await Future<void>.delayed(Duration.zero);
  await Future<void>.delayed(Duration.zero);
}

final class _FakeScheduler implements ChatReadVisibilityScheduler {
  _FakeScheduler(this.now);

  DateTime now;
  final List<_FakeTimer> timers = [];

  int get activeCount => timers.where((timer) => timer.active).length;
  _FakeTimer get lastTimer => timers.last;

  @override
  ChatReadVisibilityTimer schedule(
    Duration delay,
    void Function() callback,
  ) {
    final timer = _FakeTimer(dueAt: now.add(delay), callback: callback);
    timers.add(timer);
    return timer;
  }

  void advance(Duration duration) {
    now = now.add(duration);
    while (true) {
      final due = timers.where(
        (timer) => timer.active && !timer.dueAt.isAfter(now),
      );
      if (due.isEmpty) return;
      due
          .reduce(
            (left, right) => left.dueAt.isBefore(right.dueAt) ? left : right,
          )
          .fire();
    }
  }
}

final class _FakeTimer implements ChatReadVisibilityTimer {
  _FakeTimer({required this.dueAt, required this.callback});

  final DateTime dueAt;
  final void Function() callback;
  var active = true;

  void fire() {
    if (!active) return;
    active = false;
    callback();
  }

  void fireIgnoringCancellation() => callback();

  @override
  void cancel() => active = false;
}

final class _UnexpectedTransport implements HandrailChatHttpTransport {
  @override
  Future<HandrailChatHttpResponse> send(HandrailChatHttpRequest request) =>
      throw StateError('No transport request was expected: ${request.method}');
}
