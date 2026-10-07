part of 'handrail_message_composer_test.dart';

// Evidence-only reproduction of an unchanged dialog lifetime defect. This is
// deliberately not a shipping test for the two scoped control hierarchy fixes.
void retainedLinkCancelReproduction() {
  testWidgets('retained baseline link Cancel controller lifetime', (tester) async {
    final semantics = tester.ensureSemantics();
    try {
      final harness = _Harness();
      addTearDown(() => _disposeHarness(tester, harness));
      await _pumpComposer(tester, harness);
      await tester.enterText(find.byKey(_input), 'Original');
      await _selectText(tester, 'Original');
      await tester.tap(find.byKey(const ValueKey('handrail-message-composer-format-link')));
      await tester.pumpAndSettle();
      expect(find.byType(AlertDialog), findsOneWidget);
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    } finally {
      semantics.dispose();
    }
  });
}
