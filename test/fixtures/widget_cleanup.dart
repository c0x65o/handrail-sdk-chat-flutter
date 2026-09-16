import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

/// Unmounts the UI and completes cleanup across real and FakeAsync queues.
///
/// Stream subscriptions can belong to either queue in widget fixtures. Directly
/// awaiting cancellation can leave the other queue paused. Keep both the bounded
/// completion assertion and the final await so errors are never swallowed.
Future<void> pumpWidgetCleanup(
  WidgetTester tester,
  Future<void> Function() cleanup,
) async {
  await tester.pumpWidget(const SizedBox.shrink());
  var completed = false;
  final disposal = cleanup();
  unawaited(disposal.then((_) => completed = true, onError: (Object _) {
    completed = true;
  }));
  for (var attempt = 0; attempt < 20 && !completed; attempt += 1) {
    await tester.runAsync(() async {
      await Future<void>.delayed(Duration.zero);
    });
    await tester.pump(const Duration(milliseconds: 1));
  }
  expect(completed, isTrue, reason: 'Widget fixture cleanup did not complete.');
  await disposal;
}
