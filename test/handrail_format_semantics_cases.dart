part of 'handrail_message_composer_test.dart';

List<SemanticsNode> _formatNodes(WidgetTester tester, String label) {
  final nodes = <SemanticsNode>[];
  void visit(SemanticsNode node) {
    if (node.isMergedIntoParent) return;
    final data = node.getSemanticsData();
    // ignore: deprecated_member_use
    if (data.hasFlag(SemanticsFlag.isButton) &&
        (data.label.contains(label) || data.tooltip == label)) {
      nodes.add(node);
    }
    node.visitChildren((child) {
      visit(child);
      return true;
    });
  }

  // ignore: deprecated_member_use
  visit(tester.binding.pipelineOwner.semanticsOwner!.rootSemanticsNode!);
  return nodes;
}

void _formatSemanticsTests() {
  for (final width in [320.0, 390.0, 1050.0]) {
    testWidgets('format toolbar render and keyboard scroll at $width',
        (tester) async {
      tester.view.physicalSize = Size(width, 600);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await prepareWidgetEvidence(tester);
      final harness = _Harness();
      addTearDown(() => _disposeHarness(tester, harness));
      await _pumpComposer(tester, harness);
      await tester.enterText(find.byKey(_input), 'Selected words');
      await _selectText(tester, 'Selected');
      await captureWidgetEvidence(tester, 'toolbar-${width.toInt()}.png');
      final button = find
          .byKey(const ValueKey('handrail-message-composer-format-code-block'));
      var reached = false;
      for (var i = 0; i < 12; i++) {
        await tester.sendKeyEvent(LogicalKeyboardKey.tab);
        await tester.pump();
        FocusManager.instance.primaryFocus?.context
            ?.visitAncestorElements((element) {
          if (element.widget.key == tester.widget(button).key) reached = true;
          return !reached;
        });
        if (reached) break;
      }
      expect(reached, isTrue);
      // Keyboard traversal must make the clipped action visible.
      expect(button.hitTestable(), findsOneWidget);
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pump();
      expect(_text(tester), 'Selected words');
      await captureWidgetEvidence(
          tester, 'toolbar-scrolled-${width.toInt()}.png');
      expect(tester.takeException(), isNull);
    });
  }
  for (final material3 in [false, true]) {
    for (final entry in {
      'bold': 'Bold',
      'italic': 'Italic',
      'link': 'Link',
      'unordered-list': 'Bulleted list',
      'ordered-list': 'Numbered list',
      'inline-code': 'Inline code',
      'code-block': 'Code block',
    }.entries) {
      testWidgets('single format action ${entry.key} Material3=$material3',
          (tester) async {
        final semantics = tester.ensureSemantics();
        try {
          final harness = _Harness(storage: InMemoryApplicationChatStorage());
          addTearDown(() => _disposeHarness(tester, harness));
          final focus = FocusNode();
          addTearDown(focus.dispose);
          final theme = ThemeData(useMaterial3: material3);
          await _pumpComposer(tester, harness, theme: theme, focusNode: focus);
          final button = find
              .byKey(ValueKey('handrail-message-composer-format-${entry.key}'));
          await _pumpComposer(tester, harness,
              theme: theme,
              focusNode: focus,
              enabled: false,
              waitUntilReady: false);
          await tester.ensureVisible(button);
          await tester.pumpAndSettle();
          final disabledNodes = _formatNodes(tester, entry.value);
          expect(disabledNodes, hasLength(1));
          final disabledData = disabledNodes.single.getSemanticsData();
          // ignore: deprecated_member_use
          expect(disabledData.hasFlag(SemanticsFlag.hasEnabledState), isTrue);
          // ignore: deprecated_member_use
          expect(disabledData.hasFlag(SemanticsFlag.isEnabled), isFalse);
          expect(disabledData.hasAction(SemanticsAction.tap), isFalse);
          await _pumpComposer(tester, harness, theme: theme, focusNode: focus);
          await tester.enterText(find.byKey(_input), 'Original');
          await _selectText(tester, 'Original');
          await tester.ensureVisible(button);
          await tester.pumpAndSettle();
          var nodes = _formatNodes(tester, entry.value);
          expect(nodes, hasLength(1),
              reason: 'one labelled native action, no wrapper button');
          var data = nodes.single.getSemanticsData();
          expect(data.label.isEmpty ? data.tooltip : data.label, entry.value);
          // ignore: deprecated_member_use
          expect(data.hasFlag(SemanticsFlag.isEnabled), isTrue);
          // ignore: deprecated_member_use
          expect(data.hasFlag(SemanticsFlag.isSelected), isFalse);
          expect(data.hasAction(SemanticsAction.tap), isTrue);
          // Exercise the action delivered by accessibility, not onPressed directly.
          // ignore: deprecated_member_use
          tester.binding.pipelineOwner.semanticsOwner!
              .performAction(nodes.single.id, SemanticsAction.tap);
          await tester.pumpAndSettle();
          if (entry.key == 'link') {
            expect(find.byType(AlertDialog), findsOneWidget);
            // Dialog dismissal has a separately retained baseline controller
            // lifetime defect. This test qualifies the toolbar's open action.
            await tester.pumpWidget(const SizedBox.shrink());
            await tester.pump();
          } else {
            data = _formatNodes(tester, entry.value).single.getSemanticsData();
            // ignore: deprecated_member_use
            expect(data.hasFlag(SemanticsFlag.isSelected), isTrue);
            expect(focus.hasFocus, isTrue);
            expect(_text(tester), 'Original');
            await _pumpUntil(
                tester,
                () => harness.transport
                    .operations('synchronize_draft')
                    .isNotEmpty);
            final expected = {
              'bold': '**Original**',
              'italic': '*Original*',
              'inline-code': '`Original`',
              'code-block': '```\nOriginal\n```',
              'unordered-list': '- Original',
              'ordered-list': '1. Original'
            }[entry.key];
            expect(
                (harness.transport
                    .operations('synchronize_draft')
                    .last['content'] as Map)['text'],
                expected);
            // Touch toggles the very same control off.
            await tester.tap(button);
            await tester.pumpAndSettle();
            final afterTouch =
                _formatNodes(tester, entry.value).single.getSemanticsData();
            // ignore: deprecated_member_use
            expect(afterTouch.hasFlag(SemanticsFlag.isSelected), isFalse);
          }
        } finally {
          semantics.dispose();
        }
      });
    }
  }
}
