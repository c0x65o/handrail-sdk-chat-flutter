import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:handrail_chat/flutter.dart';

const _conversationOne = ConversationId('conversation-1');
const _conversationTwo = ConversationId('conversation-2');
const _exposure = Duration(milliseconds: 100);

void main() {
  testWidgets('reports partial rows and excludes rows outside the viewport', (
    tester,
  ) async {
    final harness = _Harness();
    final keys = List<GlobalKey>.generate(4, (_) => GlobalKey());

    await tester.pumpWidget(
      _listFixture(
        harness: harness,
        keys: keys,
        viewportHeight: 150,
      ),
    );
    harness.advance(_exposure);
    await _flush(tester);

    expect(harness.sequences, <int>[2]);
    expect(keys[2].currentContext, isNotNull, reason: 'cached but offscreen');
  });

  testWidgets('lets a host refine the viewport-aware visibility policy', (
    tester,
  ) async {
    final harness = _Harness();
    final keys = List<GlobalKey>.generate(3, (_) => GlobalKey());
    final measuredFractions = <int, double>{};

    await tester.pumpWidget(
      _listFixture(
        harness: harness,
        keys: keys,
        viewportHeight: 150,
        visibilityDelegate: (details) {
          measuredFractions[details.item.sequence.value] =
              details.visibleFraction;
          return details.visibleFraction >= 0.75;
        },
      ),
    );
    harness.advance(_exposure);
    await _flush(tester);

    expect(harness.sequences, <int>[1]);
    expect(measuredFractions[1], 1);
    expect(measuredFractions[2], closeTo(0.5, 0.001));
    expect(measuredFractions[3], 0);
  });

  testWidgets('samples after downward and upward scrolling', (tester) async {
    final harness = _Harness();
    final controller = ScrollController();
    addTearDown(controller.dispose);
    final keys = List<GlobalKey>.generate(6, (_) => GlobalKey());
    var conversationId = _conversationOne;
    late StateSetter rebuild;

    await tester.pumpWidget(
      StatefulBuilder(
        builder: (context, setState) {
          rebuild = setState;
          return _listFixture(
            harness: harness,
            keys: keys,
            viewportHeight: 150,
            controller: controller,
            conversationId: conversationId,
          );
        },
      ),
    );
    harness.advance(_exposure);
    await _flush(tester);
    expect(harness.calls.last, (_conversationOne, 2));

    await tester.drag(find.byType(ListView), const Offset(0, -220));
    await tester.pump();
    harness.advance(_exposure);
    await _flush(tester);
    expect(controller.offset, greaterThan(0));
    expect(harness.calls.last.$1, _conversationOne);
    expect(harness.calls.last.$2, greaterThan(2));

    await tester.drag(find.byType(ListView), const Offset(0, 220));
    await tester.pump();
    expect(controller.offset, lessThan(100));
    rebuild(() => conversationId = _conversationTwo);
    await tester.pump();
    harness.advance(_exposure);
    await _flush(tester);
    expect(harness.calls.last, (_conversationTwo, 2));
  });

  testWidgets('suppresses rapid scrolling until it settles', (tester) async {
    final harness = _Harness();
    final keys = List<GlobalKey>.generate(8, (_) => GlobalKey());
    await tester.pumpWidget(
      _listFixture(
        harness: harness,
        keys: keys,
        viewportHeight: 150,
      ),
    );

    final gesture = await tester.startGesture(
      tester.getCenter(find.byType(ListView)),
    );
    await gesture.moveBy(const Offset(0, -260));
    await tester.pump();
    harness.advance(const Duration(seconds: 5));
    await _flush(tester);
    expect(harness.calls, isEmpty);

    await gesture.up();
    await tester.pump();
    harness.advance(_exposure - const Duration(milliseconds: 1));
    await _flush(tester);
    expect(harness.calls, isEmpty);
    harness.advance(const Duration(milliseconds: 1));
    await _flush(tester);
    expect(harness.calls, hasLength(1));
    expect(harness.sequences.single, greaterThan(2));
  });

  testWidgets('switching conversations cancels the old pending sample', (
    tester,
  ) async {
    final harness = _Harness();
    final keys = List<GlobalKey>.generate(3, (_) => GlobalKey());
    var conversationId = _conversationOne;
    late StateSetter rebuild;

    await tester.pumpWidget(
      StatefulBuilder(
        builder: (context, setState) {
          rebuild = setState;
          return _listFixture(
            harness: harness,
            keys: keys,
            viewportHeight: 150,
            conversationId: conversationId,
          );
        },
      ),
    );
    harness.advance(const Duration(milliseconds: 50));
    rebuild(() => conversationId = _conversationTwo);
    await tester.pump();
    harness.advance(_exposure);
    await _flush(tester);

    expect(harness.calls, <(ConversationId, int)>[(_conversationTwo, 2)]);
  });

  testWidgets('background time is gated and foreground starts fresh exposure', (
    tester,
  ) async {
    addTearDown(
      () => _resumeApplication(tester.binding),
    );
    final harness = _Harness();
    final keys = List<GlobalKey>.generate(3, (_) => GlobalKey());
    await tester.pumpWidget(
      _listFixture(
        harness: harness,
        keys: keys,
        viewportHeight: 150,
      ),
    );
    harness.advance(const Duration(milliseconds: 50));

    _pauseApplication(tester.binding);
    harness.advance(const Duration(days: 1));
    await _flush(tester);
    expect(harness.calls, isEmpty);

    _resumeApplication(tester.binding);
    harness.advance(_exposure - const Duration(milliseconds: 1));
    await _flush(tester);
    expect(harness.calls, isEmpty);
    harness.advance(const Duration(milliseconds: 1));
    await _flush(tester);
    expect(harness.sequences, <int>[2]);
  });

  testWidgets('removing a pending keyed row invalidates its sequence', (
    tester,
  ) async {
    final harness = _Harness();
    final keys = List<GlobalKey>.generate(2, (_) => GlobalKey());
    var itemCount = 2;
    late StateSetter rebuild;

    await tester.pumpWidget(
      StatefulBuilder(
        builder: (context, setState) {
          rebuild = setState;
          return _listFixture(
            harness: harness,
            keys: keys.take(itemCount).toList(),
            viewportHeight: 200,
          );
        },
      ),
    );
    harness.advance(const Duration(milliseconds: 50));
    rebuild(() => itemCount = 1);
    await tester.pump();
    harness.advance(_exposure);
    await _flush(tester);

    expect(harness.sequences, <int>[1]);
  });

  testWidgets('clips rows through nested scrollable viewports', (tester) async {
    final harness = _Harness();
    final keys = List<GlobalKey>.generate(3, (_) => GlobalKey());
    final items = _items(keys);

    await tester.pumpWidget(
      _host(
        SizedBox(
          width: 200,
          height: 180,
          child: ChatReadTracker(
            conversationId: _conversationOne,
            items: items,
            reads: harness.coordinator,
            child: SingleChildScrollView(
              child: Column(
                children: <Widget>[
                  const SizedBox(height: 100),
                  SizedBox(
                    height: 200,
                    child: ListView.builder(
                      padding: EdgeInsets.zero,
                      itemCount: keys.length,
                      itemExtent: 100,
                      itemBuilder: (context, index) => SizedBox(
                        key: keys[index],
                        height: 100,
                        child: Text('row-${index + 1}'),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
    harness.advance(_exposure);
    await _flush(tester);

    expect(harness.sequences, <int>[1]);
  });

  testWidgets('disposal cancels pending and controller-triggered reports', (
    tester,
  ) async {
    final harness = _Harness();
    final controller = ChatReadTrackerController();
    final keys = List<GlobalKey>.generate(2, (_) => GlobalKey());
    await tester.pumpWidget(
      _listFixture(
        harness: harness,
        keys: keys,
        viewportHeight: 150,
        trackerController: controller,
      ),
    );
    expect(controller.isAttached, isTrue);
    final pending = harness.scheduler.lastTimer;

    await tester.pumpWidget(_host(const SizedBox.shrink()));
    expect(controller.isAttached, isFalse);
    pending.fireIgnoringCancellation();
    controller.sampleVisibility();
    harness.advance(const Duration(days: 1));
    await _flush(tester);

    expect(harness.calls, isEmpty);
    expect(tester.takeException(), isNull);
  });

  testWidgets('uses the nearest ChatScope coordinator by default', (
    tester,
  ) async {
    final scheduler = _FakeScheduler(DateTime.utc(2026, 8, 26));
    final client = HandrailChatClient(
      apiBaseUri: Uri.parse('https://chat.example.test/api/chat'),
      tokenProvider: () async => 'token',
      transport: _UnexpectedTransport(),
      readVisibilityClock: () => scheduler.now,
      readVisibilityScheduler: scheduler,
      readVisibilityMinimumExposure: _exposure,
    );
    addTearDown(client.dispose);
    final key = GlobalKey();

    await tester.pumpWidget(
      _host(
        ChatScope(
          client: client,
          child: SizedBox(
            width: 200,
            height: 100,
            child: ChatReadTracker(
              conversationId: _conversationOne,
              items: <ChatReadTrackedItem>[
                ChatReadTrackedItem(
                  key: key,
                  sequence: const MessageSequence(1),
                ),
              ],
              child: SizedBox(key: key, height: 100),
            ),
          ),
        ),
      ),
    );

    expect(scheduler.activeCount, 1);
  });
}

Widget _listFixture({
  required _Harness harness,
  required List<GlobalKey> keys,
  required double viewportHeight,
  ConversationId conversationId = _conversationOne,
  ScrollController? controller,
  ChatReadTrackerController? trackerController,
  ChatReadVisibilityDelegate? visibilityDelegate,
}) =>
    _host(
      SizedBox(
        width: 200,
        height: viewportHeight,
        child: ChatReadTracker(
          conversationId: conversationId,
          items: _items(keys),
          reads: harness.coordinator,
          controller: trackerController,
          visibilityDelegate: visibilityDelegate,
          child: ListView.builder(
            controller: controller,
            padding: EdgeInsets.zero,
            itemCount: keys.length,
            itemExtent: 100,
            itemBuilder: (context, index) => SizedBox(
              key: keys[index],
              height: 100,
              child: Text('row-${index + 1}'),
            ),
          ),
        ),
      ),
    );

List<ChatReadTrackedItem> _items(List<GlobalKey> keys) => <ChatReadTrackedItem>[
      for (var index = 0; index < keys.length; index += 1)
        ChatReadTrackedItem(
          key: keys[index],
          sequence: MessageSequence(index + 1),
        ),
    ];

Widget _host(Widget child) => Directionality(
      textDirection: TextDirection.ltr,
      child: Align(alignment: Alignment.topLeft, child: child),
    );

Future<void> _flush(WidgetTester tester) async {
  await tester.pump();
  await tester.pump();
}

final class _Harness {
  _Harness() : scheduler = _FakeScheduler(DateTime.utc(2026, 8, 26)) {
    coordinator = ChatReadVisibilityCoordinator(
      markRead: (input) {
        calls.add((input.conversationId, input.throughSequence.value));
        return Future<ChatCommandResult<ReadCursorMutationResult>>.value(
          _success(input),
        );
      },
      minimumExposure: _exposure,
      clock: () => scheduler.now,
      scheduler: scheduler,
      generateIdempotencyKey: () => 'tracker-key-${calls.length + 1}',
    );
  }

  final _FakeScheduler scheduler;
  final List<(ConversationId, int)> calls = <(ConversationId, int)>[];
  late final ChatReadVisibilityCoordinator coordinator;

  List<int> get sequences => calls.map((call) => call.$2).toList();

  void advance(Duration duration) => scheduler.advance(duration);
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
          userId: const UserId('user-1'),
          lastReadSequence: input.throughSequence,
          updatedAt: const IsoTimestamp('2026-08-26T00:00:00.000Z'),
        ),
        latestSequence: input.throughSequence,
        unreadCount: 0,
      ),
    );

final class _FakeScheduler implements ChatReadVisibilityScheduler {
  _FakeScheduler(this.now);

  DateTime now;
  final List<_FakeTimer> timers = <_FakeTimer>[];

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

  @override
  void cancel() => active = false;

  void fire() {
    if (!active) return;
    active = false;
    callback();
  }

  void fireIgnoringCancellation() => callback();
}

final class _UnexpectedTransport implements HandrailChatHttpTransport {
  @override
  Future<HandrailChatHttpResponse> send(HandrailChatHttpRequest request) =>
      throw StateError('No request expected in this test.');
}

void _pauseApplication(TestWidgetsFlutterBinding binding) {
  switch (binding.lifecycleState) {
    case null:
      binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      return;
    case AppLifecycleState.resumed:
      binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
      binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      return;
    case AppLifecycleState.inactive:
      binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
      binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      return;
    case AppLifecycleState.hidden:
      binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      return;
    case AppLifecycleState.paused:
      return;
    case AppLifecycleState.detached:
      binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      _pauseApplication(binding);
      return;
  }
}

void _resumeApplication(TestWidgetsFlutterBinding binding) {
  switch (binding.lifecycleState) {
    case null:
      binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      return;
    case AppLifecycleState.resumed:
      return;
    case AppLifecycleState.inactive:
      binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      return;
    case AppLifecycleState.hidden:
      binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      return;
    case AppLifecycleState.paused:
      binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
      binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      return;
    case AppLifecycleState.detached:
      binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      return;
  }
}
