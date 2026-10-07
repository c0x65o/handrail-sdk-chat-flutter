part of 'handrail_message_composer_test.dart';

const _linkButton = ValueKey('handrail-message-composer-format-link');
const _linkDestination = ValueKey('handrail-message-composer-link-destination');
const _linkApply = ValueKey('handrail-message-composer-link-apply');

Future<TextEditingController> _openLink(WidgetTester tester) async {
  await _tapFormat(tester, 'link');
  await tester.pumpAndSettle();
  expect(find.byType(AlertDialog), findsOneWidget);
  return tester.widget<TextField>(find.byKey(_linkDestination)).controller!;
}

String? _linkDraft(_Harness harness, [ConversationId id = _conversationId]) {
  final draft = harness.client.draftFor(id)?.draft;
  return draft is CanonicalReplacedDraft ? draft.content.text : null;
}

void _linkDialogTests() {
  for (final width in [320.0, 390.0, 900.0]) {
    for (final scale in [1.0, 2.0, 3.0]) {
      testWidgets('link validation wraps at $width with text scale $scale',
          (tester) async {
        await prepareWidgetEvidence(tester);
        await tester.binding.setSurfaceSize(Size(width, 1000));
        tester.platformDispatcher.textScaleFactorTestValue = scale;
        addTearDown(() async {
          tester.platformDispatcher.clearTextScaleFactorTestValue();
          await tester.binding.setSurfaceSize(null);
        });
        final harness = _Harness();
        addTearDown(() => _disposeHarness(tester, harness));
        await _pumpComposer(tester, harness);
        await tester.enterText(find.byKey(_input), 'Original');
        await _selectText(tester, 'Original');
        await _openLink(tester);
        await tester.enterText(find.byKey(_linkDestination), 'javascript:bad');
        await tester.tap(find.byKey(_linkApply));
        await tester.pumpAndSettle();
        await captureWidgetEvidence(
            tester, 'link-validation-$width-$scale.png');
        final error = find.text('Enter a safe web, email, or relative link.');
        final paragraph = tester.renderObject<RenderParagraph>(error);
        expect(paragraph.text.style?.color,
            Theme.of(tester.element(error)).colorScheme.error);
        expect(paragraph.didExceedMaxLines, isFalse,
            reason: 'The complete actionable validation message must render.');
        final rect = tester.getRect(error);
        final dialog = tester.getRect(find.byType(AlertDialog));
        expect(rect.left, greaterThanOrEqualTo(dialog.left));
        expect(rect.right, lessThanOrEqualTo(dialog.right));
        expect(rect.bottom, lessThanOrEqualTo(dialog.bottom));
        expect(dialog.left, greaterThanOrEqualTo(0));
        expect(dialog.right, lessThanOrEqualTo(width));
        expect(_linkDraft(harness), 'Original');
        expect(tester.takeException(), isNull);
      });
    }
  }

  for (final dismissal in ['Cancel', 'barrier', 'Escape', 'system Back']) {
    testWidgets(
        'link dialog lifetime: $dismissal preserves selection and draft',
        (tester) async {
      final harness = _Harness(storage: InMemoryApplicationChatStorage());
      addTearDown(() => _disposeHarness(tester, harness));
      final host = TextEditingController();
      addTearDown(host.dispose);
      await _pumpComposer(tester, harness, controller: host);
      await tester.enterText(find.byKey(_input), 'Original');
      await _selectText(tester, 'Original');
      final before = host.value;
      final destination = await _openLink(tester);
      await tester.enterText(
          find.byKey(_linkDestination), 'https://example.com');
      switch (dismissal) {
        case 'Cancel':
          await tester.tap(find.text('Cancel'));
        case 'barrier':
          await tester.tapAt(const Offset(5, 5));
        case 'Escape':
          await tester.sendKeyEvent(LogicalKeyboardKey.escape);
        case 'system Back':
          await tester.binding.handlePopRoute();
      }
      await tester.pump();
      // The route has popped, but its TextField is still mounted in transition.
      void listener() {}
      destination.addListener(listener);
      destination.removeListener(listener);
      await tester.pumpAndSettle();
      expect(find.byType(AlertDialog), findsNothing);
      expect(() => destination.addListener(listener), throwsFlutterError);
      expect(host.value, before);
      expect(_linkDraft(harness), 'Original');
      expect(tester.takeException(), isNull);
      await tester.tap(find.byKey(_input));
      tester.testTextInput.updateEditingValue(const TextEditingValue(
        text: 'Original next',
        selection: TextSelection.collapsed(offset: 13),
      ));
      await tester.pumpAndSettle();
      expect(_linkDraft(harness), 'Original next');
      expect(harness.transport.operations('send'), isEmpty);
    });
  }

  for (final action in ['Apply', 'done', 'semantics']) {
    testWidgets('link dialog lifetime: $action inserts and persists markdown',
        (tester) async {
      final semantics = tester.ensureSemantics();
      final storage = InMemoryApplicationChatStorage();
      final harness = _Harness(storage: storage);
      addTearDown(() => _disposeHarness(tester, harness));
      try {
        await _pumpComposer(tester, harness);
        await tester.enterText(find.byKey(_input), 'Read this now');
        await _selectText(tester, 'this');
        await _openLink(tester);
        final draftGate = Completer<void>();
        harness.transport.pendingDraft = draftGate;
        addTearDown(() {
          if (!draftGate.isCompleted) draftGate.complete();
        });
        await tester.enterText(
            find.byKey(_linkDestination), 'https://example.com');
        switch (action) {
          case 'Apply':
            await tester.tap(find.byKey(_linkApply));
          case 'done':
            await tester.testTextInput.receiveAction(TextInputAction.done);
          case 'semantics':
            // Kept for the declared Flutter 3.19 semantics test API.
            // ignore: deprecated_member_use
            tester.binding.pipelineOwner.semanticsOwner!.performAction(
                tester.getSemantics(find.byKey(_linkApply)).id,
                SemanticsAction.tap);
        }
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        expect(_text(tester), 'Read this now');
        expect(_linkDraft(harness), 'Read [this](https://example.com) now');
        expect(harness.client.draftFor(_conversationId)!.draft,
            isA<CanonicalReplacedDraft>());
        final stored = await storage.readEncoded(_storageIdentity,
            ApplicationChatStorageRecordKind.queuedDraftIntents);
        expect(stored, contains('https://example.com'));
        draftGate.complete();
        await _pumpUntil(tester,
            () => harness.client.draftFor(_conversationId)?.isPending == false);
        expect(harness.transport.operations('send'), isEmpty);
      } finally {
        semantics.dispose();
      }
    });
  }

  testWidgets(
      'link dialog lifetime: validation then correction and Remove link',
      (tester) async {
    final harness = _Harness();
    addTearDown(() => _disposeHarness(tester, harness));
    await _pumpComposer(tester, harness);
    await tester.enterText(find.byKey(_input), 'Original');
    await _selectText(tester, 'Original');
    await _openLink(tester);
    for (final value in ['', 'javascript:alert(1)']) {
      await tester.enterText(find.byKey(_linkDestination), value);
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pumpAndSettle();
      expect(find.text('Enter a safe web, email, or relative link.'),
          findsOneWidget);
      await tester.tap(find.byKey(_linkApply));
      await tester.pumpAndSettle();
      expect(find.byType(AlertDialog), findsOneWidget);
      expect(_linkDraft(harness), 'Original');
    }
    await tester.enterText(find.byKey(_linkDestination), '/safe');
    await tester.tap(find.byKey(_linkApply));
    await tester.pumpAndSettle();
    expect(_linkDraft(harness), '[Original](/safe)');
    await _openLink(tester);
    expect(find.text('Edit link'), findsOneWidget);
    expect(
        tester.widget<TextField>(find.byKey(_linkDestination)).controller!.text,
        '/safe');
    await tester.tap(
        find.byKey(const ValueKey('handrail-message-composer-link-remove')));
    await tester.pumpAndSettle();
    expect(_linkDraft(harness), 'Original');
    expect(tester.takeException(), isNull);
  });

  testWidgets('link dialog lifetime: repeated opens and double actions',
      (tester) async {
    final harness = _Harness();
    addTearDown(() => _disposeHarness(tester, harness));
    await _pumpComposer(tester, harness);
    await tester.enterText(find.byKey(_input), 'Original');
    await _selectText(tester, 'Original');
    final open = tester.widget<IconButton>(find.byKey(_linkButton)).onPressed!;
    for (var i = 0; i < 3; i++) {
      open();
      open();
      await tester.pumpAndSettle();
      expect(find.byType(AlertDialog), findsOneWidget);
      final cancel = tester
          .widget<TextButton>(find.widgetWithText(TextButton, 'Cancel'))
          .onPressed!;
      cancel();
      cancel();
      await tester.pumpAndSettle();
      expect(find.byKey(_input), findsOneWidget);
    }
    await _openLink(tester);
    await tester.enterText(find.byKey(_linkDestination), '/safe');
    final apply =
        tester.widget<FilledButton>(find.byKey(_linkApply)).onPressed!;
    apply();
    apply();
    await tester.pumpAndSettle();
    expect(_linkDraft(harness), '[Original](/safe)');
    expect(find.byKey(_input), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  for (final boundary in [
    'disabled',
    'disable then enable',
    'conversation',
    'account',
    'account cycle',
    'host controller',
    'host text',
    'remote replacement',
    'same-text formatting',
    'host disposal',
    'conversation revoked',
    'conversation restored',
    'timeline revoked',
    'timeline restored',
  ]) {
    testWidgets('link dialog lifetime: rejects late result after $boundary',
        (tester) async {
      final harness = _Harness(storage: InMemoryApplicationChatStorage());
      addTearDown(() => _disposeHarness(tester, harness));
      final host = TextEditingController();
      final replacement = TextEditingController(text: 'Replacement');
      addTearDown(host.dispose);
      addTearDown(replacement.dispose);
      await _pumpComposer(tester, harness, controller: host);
      await tester.enterText(find.byKey(_input), 'Original');
      await _selectText(tester, 'Original');
      await tester.pumpAndSettle();
      await _openLink(tester);
      await tester.enterText(find.byKey(_linkDestination), '/late');
      switch (boundary) {
        case 'disabled':
        case 'disable then enable':
          await _pumpComposer(tester, harness,
              controller: host, enabled: false, waitUntilReady: false);
          if (boundary == 'disable then enable') {
            await _pumpComposer(tester, harness, controller: host);
          }
        case 'conversation':
          await _pumpComposer(tester, harness,
              controller: host,
              conversationId: const ConversationId('replacement-conversation'));
        case 'account':
        case 'account cycle':
          var done = false;
          harness.client
              .activateStorageIdentity(ApplicationChatStorageIdentity(
                tenantId: _storageIdentity.tenantId,
                userId: const UserId('replacement-user'),
                deviceId: _storageIdentity.deviceId,
              ))
              .then((_) => done = true);
          await _pumpUntil(tester, () => done);
          if (boundary == 'account cycle') {
            done = false;
            harness.client
                .activateStorageIdentity(_storageIdentity)
                .then((_) => done = true);
            await _pumpUntil(tester, () => done);
          }
        case 'host controller':
          await _pumpComposer(tester, harness, controller: replacement);
        case 'host text':
          host.value = const TextEditingValue(
              text: 'Replacement',
              selection: TextSelection.collapsed(offset: 11));
          await tester.pump();
        case 'remote replacement':
        case 'same-text formatting':
          final revision = harness.client.draftFor(_conversationId)!.revision;
          harness.client.reconcileDraftEvent(_draftEvent(
            boundary == 'remote replacement' ? 'Replacement' : '**Original**',
            baseRevision: revision,
          ));
          await tester.pump();
        case 'conversation revoked':
        case 'conversation restored':
        case 'timeline revoked':
        case 'timeline restored':
          final timeline = boundary.startsWith('timeline');
          Future<void> refresh(int status) async {
            var done = false;
            if (timeline) {
              harness.transport.timelineStatus = status;
              harness.client.timelines
                  .forConversation(_conversationId)
                  .refresh()
                  .then((_) => done = true);
            } else {
              harness.transport.conversationStatus = status;
              harness.client.conversations
                  .forConversation(_conversationId)
                  .refresh()
                  .then((_) => done = true);
            }
            await _pumpUntil(tester, () => done);
          }
          await refresh(403);
          expect(tester.widget<TextField>(find.byKey(_input)).enabled, isFalse);
          if (boundary.endsWith('restored')) {
            await refresh(200);
            expect(
                tester.widget<TextField>(find.byKey(_input)).enabled, isTrue);
          }
        case 'host disposal':
          // Keep the Navigator/dialog alive while disposing only its host.
          await tester.pumpWidget(MaterialApp(
              theme: widgetEvidenceTheme,
              home: const Scaffold(body: SizedBox())));
      }
      expect(find.byType(AlertDialog), findsOneWidget);
      await tester.pumpAndSettle();
      final before = host.value;
      final draftBefore = _linkDraft(harness);
      await tester.tap(find.byKey(_linkApply));
      await tester.pumpAndSettle();
      expect(find.byType(AlertDialog), findsNothing);
      expect(host.value, before);
      expect(_linkDraft(harness), draftBefore);
      expect(_linkDraft(harness), isNot(contains('/late')));
      expect(
          _linkDraft(harness, const ConversationId('replacement-conversation')),
          isNot(contains('/late')));
      expect(harness.transport.operations('send'), isEmpty);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets(
      'link dialog lifetime: matching acknowledgement and selection-only change keep opening range',
      (tester) async {
    final harness = _Harness(storage: InMemoryApplicationChatStorage());
    addTearDown(() => _disposeHarness(tester, harness));
    final host = TextEditingController();
    addTearDown(host.dispose);
    final gate = Completer<void>();
    harness.transport.pendingDraft = gate;
    await _pumpComposer(tester, harness,
        controller: host, draftDebounce: Duration.zero);
    await tester.enterText(find.byKey(_input), 'Original suffix');
    await _selectText(tester, 'Original');
    await _openLink(tester);
    gate.complete();
    await _pumpUntil(tester,
        () => harness.client.draftFor(_conversationId)?.isPending == false);
    host.selection = const TextSelection.collapsed(offset: 15);
    await tester.enterText(find.byKey(_linkDestination), '/safe');
    await tester.tap(find.byKey(_linkApply));
    await tester.pumpAndSettle();
    expect(_linkDraft(harness), '[Original](/safe) suffix');
    expect(tester.takeException(), isNull);
  });
}
