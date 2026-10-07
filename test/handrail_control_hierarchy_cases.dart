part of 'handrail_chat_workspace_test.dart';

void _controlHierarchyTests() {
  for (final width in [320.0, 390.0, 1400.0]) {
    testWidgets('one thread dismissal hierarchy at $width', (tester) async {
      final semantics = tester.ensureSemantics();
      try {
        final http = _HeaderDiscoveryTransport();
        final client = await _namedClient(tester, http);
        tester.view.physicalSize = Size(width, 900);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        await _mountReplyWorkspace(tester, client);
        await tester.tap(find.byTooltip('Browse channel threads'));
        await _pumpUntil(
            tester, () => find.text('Canonical launch').evaluate().isNotEmpty);
        await tester.tap(find.text('Canonical launch'));
        await _pumpUntil(
            tester, () => find.text('Thread reply').evaluate().isNotEmpty);
        await captureWidgetEvidence(tester, 'thread-${width.toInt()}.png');
        expect(find.byTooltip('Close panel'), findsNothing,
            reason: 'discovery has one Back to threads dismissal');
        expect(find.byTooltip('Back to threads'), findsOneWidget);
        final thread = find.byType(HandrailThreadView);
        final back = find.byTooltip('Back to threads');
        expect(find.descendant(of: thread, matching: back), findsOneWidget);
        expect(find.byTooltip('Thread subscriptions'), findsOneWidget);
        if (width < 600) {
          final settings =
              find.byKey(const ValueKey('handrail-workspace-settings'));
          expect(
              find.descendant(of: thread, matching: settings), findsOneWidget);
          await tester.tap(settings);
          await _pumpUntil(
              tester,
              () => find
                  .byType(HandrailReplyStyleSettings)
                  .evaluate()
                  .isNotEmpty);
          expect(find.byType(HandrailReplyStyleSettings), findsOneWidget);
          await tester.binding.handlePopRoute();
          await _pumpUntil(tester,
              () => find.byType(HandrailReplyStyleSettings).evaluate().isEmpty);
        }
        final handle = tester.widget<HandrailThreadView>(thread).openHandle!;
        await tester.tap(back);
        await _pumpUntil(
            tester, () => find.byType(HandrailThreadView).evaluate().isEmpty);
        expect(handle.isReleased, isTrue);
        expect(find.text('Canonical launch'), findsOneWidget);
        await tester.tap(find.text('Canonical launch'));
        await _pumpUntil(
            tester, () => find.text('Thread reply').evaluate().isNotEmpty);
        await tester.sendKeyEvent(LogicalKeyboardKey.escape);
        await _pumpUntil(
            tester, () => find.byType(HandrailThreadView).evaluate().isEmpty);
        expect(find.byType(HandrailThreadView), findsNothing);
        expect(find.text('Canonical launch'), findsOneWidget);
        expect(http.threadRequests, isEmpty);
        expect(tester.takeException(), isNull);
      } finally {
        semantics.dispose();
      }
    });
  }
}
