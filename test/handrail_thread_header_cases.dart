part of 'handrail_thread_view_test.dart';

void _threadHeaderTests() {
  for (final width in [320.0, 390.0, 900.0]) {
    testWidgets('standalone thread title actions and permissions at $width',
        (tester) async {
      final semantics = tester.ensureSemantics();
      try {
        tester.view.physicalSize = Size(width, 800);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        await prepareWidgetEvidence(tester);
        final harness = _Harness(existingThread: true);
        addTearDown(() => _disposeLifecycleHarness(tester, harness));
        final lifecycle = await _prepareLifecycle(tester, harness);
        var closes = 0;
        const title =
            'Launch planning and accessibility review for the next release';
        await tester.pumpWidget(widgetEvidenceBoundary(_host(
            harness.client,
            HandrailThreadView(
                rootMessageId: _rootId,
                title: const Text(title),
                onClose: () => closes++),
            theme: widgetEvidenceTheme)));
        await _pumpUntil(tester,
            () => find.text('First thread reply').evaluate().isNotEmpty);
        await _settleLifecycle(tester);
        expect(find.text(title), findsOneWidget);
        expect(find.byTooltip('Close panel'), findsOneWidget);
        expect(find.byTooltip('Thread subscriptions'), findsOneWidget);
        expect(find.byTooltip('Shared thread controls'), findsOneWidget);
        await captureWidgetEvidence(tester, 'standalone-${width.toInt()}.png');
        await tester.enterText(
            find.byKey(_composerInput), 'Retain thread draft');
        await _subscriptionChoose(tester, 'Follow');
        expect(
            harness.client.threads
                .forThread(_threadId)
                .state
                .authoritativeFollow
                ?.isFollowing,
            isTrue);
        await _openMenu(tester);
        expect(find.text('Close shared thread'), findsOneWidget);
        await tester.sendKeyEvent(LogicalKeyboardKey.escape);
        await _settleLifecycle(tester);
        await tester.tap(find.byTooltip('Close panel'));
        expect(closes, 1);
        expect(harness.transport.lifecycleWrites, isEmpty);
        expect(_draftText(tester), 'Retain thread draft');
        lifecycle.setAuthority(const ChatThreadLifecycleAuthority(
            tenantId: TenantId(_tenantId),
            userId: UserId('user-current'),
            canRead: true,
            canSend: false,
            canManage: false));
        await _settleLifecycle(tester);
        expect(find.byTooltip('Shared thread controls'), findsNothing);
        harness.transport.lifecycleRead =
            () async => _lifecycleResponse({}, 403);
        await tester.runAsync(lifecycle.load);
        await _settleLifecycle(tester);
        expect(
            tester
                .widget<HandrailMessageComposer>(
                    find.byType(HandrailMessageComposer))
                .enabled,
            isFalse);
        expect(find.byTooltip('Close panel'), findsOneWidget);
        expect(_draftText(tester), 'Retain thread draft');
        await captureWidgetEvidence(
            tester, 'standalone-denied-${width.toInt()}.png');
        final heading =
            tester.getSemantics(find.text(title)).getSemanticsData();
        expect(heading.label, title);
        // ignore: deprecated_member_use
        expect(heading.hasFlag(SemanticsFlag.isHeader), isTrue);
        if (width < 400) {
          expect(
              tester.getRect(find.text(title)).bottom,
              lessThanOrEqualTo(
                  tester.getRect(find.byTooltip('Close panel')).top));
        }
        expect(tester.takeException(), isNull);
      } finally {
        semantics.dispose();
      }
    });
  }
}
