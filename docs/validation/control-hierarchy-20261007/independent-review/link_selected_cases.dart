part of 'handrail_message_composer_test.dart';

void reviewLinkSelectionTests() {
  for (final material3 in [false, true]) {
    testWidgets('review restored Link selected semantics Material3=$material3', (tester) async {
      final semantics = tester.ensureSemantics();
      try {
        final harness = _Harness();
        addTearDown(() => _disposeHarness(tester, harness));
        expect(harness.client.reconcileDraftEvent(_draftEvent('[saved](https://example.test)')), isTrue);
        final theme = ThemeData(useMaterial3: material3);
        await _pumpComposer(tester, harness, theme: theme);
        await _selectText(tester, 'saved');
        await tester.ensureVisible(find.byKey(const ValueKey('handrail-message-composer-format-link')));
        await tester.pumpAndSettle();
        var nodes = _formatNodes(tester, 'Link');
        expect(nodes, hasLength(1));
        // ignore: deprecated_member_use
        expect(nodes.single.getSemanticsData().hasFlag(SemanticsFlag.isSelected), isTrue);
        // ignore: deprecated_member_use
        tester.binding.pipelineOwner.semanticsOwner!.performAction(nodes.single.id, SemanticsAction.tap);
        await tester.pumpAndSettle();
        expect(find.text('Edit link'), findsOneWidget);
        expect(find.text('https://example.test'), findsOneWidget);
        // Opening is qualified; Cancel lifetime is tested separately and remains failed.
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pump();
      } finally {
        semantics.dispose();
      }
    });
  }
}
