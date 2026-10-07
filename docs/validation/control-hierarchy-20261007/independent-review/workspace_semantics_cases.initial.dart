part of 'handrail_chat_workspace_test.dart';

void reviewWorkspaceSemanticsTests() {
  testWidgets('review exported heading and semantic Back action', (tester) async {
    final semantics = tester.ensureSemantics();
    try {
      tester.view.physicalSize = const Size(390, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final http = _HeaderDiscoveryTransport();
      final client = await _namedClient(tester, http);
      await _mountReplyWorkspace(tester, client);
      await tester.tap(find.byTooltip('Browse channel threads'));
      await _pumpUntil(tester, () => find.text('Canonical launch').evaluate().isNotEmpty);
      await tester.tap(find.text('Canonical launch'));
      await _pumpUntil(tester, () => find.text('Thread reply').evaluate().isNotEmpty);
      final nodes = <SemanticsNode>[];
      void visit(SemanticsNode node) {
        if (node.isMergedIntoParent) return;
        nodes.add(node);
        node.visitChildren((child) { visit(child); return true; });
      }
      // ignore: deprecated_member_use
      visit(tester.binding.pipelineOwner.semanticsOwner!.rootSemanticsNode!);
      // ignore: deprecated_member_use
      final headings = nodes.where((n) => n.getSemanticsData().hasFlag(SemanticsFlag.isHeader));
      expect(headings.map((n) => n.getSemanticsData().label), ['Canonical launch']);
      final backs = nodes.where((n) {
        final d = n.getSemanticsData();
        return d.label == 'Back to threads' || d.tooltip == 'Back to threads';
      }).toList();
      expect(backs, hasLength(1));
      expect(backs.single.getSemanticsData().hasAction(SemanticsAction.tap), isTrue);
      final handle = tester.widget<HandrailThreadView>(find.byType(HandrailThreadView)).openHandle!;
      // ignore: deprecated_member_use
      tester.binding.pipelineOwner.semanticsOwner!.performAction(backs.single.id, SemanticsAction.tap);
      await _pumpUntil(tester, () => find.byType(HandrailThreadView).evaluate().isEmpty);
      expect(handle.isReleased, isTrue);
      expect(find.text('Canonical launch'), findsOneWidget);
      expect(http.threadRequests, isEmpty);
      expect(tester.takeException(), isNull);
    } finally {
      semantics.dispose();
    }
  });
}
