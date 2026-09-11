part of 'handrail_thread_view_test.dart';

const _authority = ChatThreadLifecycleAuthority(
  tenantId: TenantId(_tenantId),
  userId: UserId('user-current'),
  canRead: true,
  canSend: true,
  canManage: true,
);
const _composerInput = ValueKey('handrail-message-composer-input');
const _composerSend = ValueKey('handrail-message-composer-send');

void _lifecycleTests() {
  testWidgets(
      'host parent archive gates composition and stale open menus cannot dispatch',
      (tester) async {
    final harness = _Harness(existingThread: true);
    addTearDown(() => _disposeLifecycleHarness(tester, harness));
    final controller = await _prepareLifecycle(tester, harness);
    await _mountLifecycle(tester, harness);
    await tester.enterText(find.byKey(_composerInput), 'Keep this destination');
    await _openMenu(tester);
    controller.setAuthority(const ChatThreadLifecycleAuthority(
      tenantId: TenantId(_tenantId),
      userId: UserId('user-current'),
      canRead: true,
      canSend: true,
      canManage: true,
      parentArchived: true,
    ));
    await tester.pump();
    await tester.tap(find.text('Close shared thread'));
    await _settleLifecycle(tester);
    expect(harness.transport.lifecycleWrites, isEmpty);
    expect(controller.state.isParentArchived, isTrue);
    expect(
        tester
            .widget<HandrailMessageComposer>(
                find.byType(HandrailMessageComposer))
            .enabled,
        isFalse);
    expect(_draftText(tester), 'Keep this destination');
    expect(find.byTooltip('Shared thread controls'), findsNothing);
  });

  testWidgets('unconfigured lifecycle still observes remote send restrictions',
      (tester) async {
    final harness = _Harness(existingThread: true);
    addTearDown(() => _disposeLifecycleHarness(tester, harness));
    await _mountLifecycle(tester, harness);
    final composer = tester.state<HandrailMessageComposerState>(
        find.byType(HandrailMessageComposer));
    _remoteLifecycle(harness, 2, locked: true);
    await _settleLifecycle(tester);
    expect(
        tester
            .widget<HandrailMessageComposer>(
                find.byType(HandrailMessageComposer))
            .enabled,
        isFalse);
    expect(tester.state(find.byType(HandrailMessageComposer)), same(composer));
    expect(find.byTooltip('Shared thread controls'), findsNothing);
    expect(harness.transport.lifecycleWrites, isEmpty);
  });

  testWidgets(
      'lifecycle menu separates navigation and state-appropriate transitions',
      (tester) async {
    final harness = _Harness(existingThread: true);
    addTearDown(() => _disposeLifecycleHarness(tester, harness));
    final controller = await _prepareLifecycle(tester, harness);

    var closed = 0;
    await _mountLifecycle(tester, harness, onClose: () => closed++);

    await tester.tap(find.byTooltip('Close panel'));
    expect(closed, 1);
    expect(harness.transport.lifecycleWrites, isEmpty);
    await _openMenu(tester);
    expect(find.text('Close shared thread'), findsOneWidget);
    expect(find.text('Lock and close thread'), findsOneWidget);
    expect(find.text('Reopen thread'), findsNothing);
    await tester.tap(find.text('Close shared thread'));

    await _settleLifecycle(tester);

    expect(controller.state.isOpen, isFalse,
        reason:
            '${controller.state.status} ${controller.state.error} ${harness.transport.lifecycleWrites.map((r) => r.body)}');
    expect(find.textContaining('An authorized send reopens it atomically'),
        findsOneWidget);
    await tester.enterText(find.byKey(_composerInput), 'Closed thread reply');

    await tester.pump();
    expect(tester.widget<IconButton>(find.byKey(_composerSend)).onPressed,
        isNotNull);
    await _openMenu(tester);
    expect(find.text('Close shared thread'), findsNothing);
    await tester.tap(find.text('Lock and close thread'));

    await _settleLifecycle(tester);

    expect(controller.state.isLocked, isTrue);
    await _openMenu(tester);
    expect(find.text('Reopen thread'), findsNothing);
    expect(find.text('Lock and close thread'), findsNothing);
    await tester.tap(find.text('Unlock thread (leaves closed)'));
    await _settleLifecycle(tester);
    expect(controller.state.isLocked, isFalse);
    expect(controller.state.isOpen, isFalse);
    await _openMenu(tester);
    await tester.tap(find.text('Reopen thread'));
    await _settleLifecycle(tester);
    expect(controller.state.isOpen, isTrue);
    expect(_draftText(tester), 'Closed thread reply');
    expect(harness.transport.lifecycleWrites, hasLength(4));

    await tester.pumpWidget(const SizedBox());
    expect(controller.state.status, ChatThreadLifecycleStatus.ready);
  });

  testWidgets(
      'unsupported or missing authority hides actions without breaking legacy composition',
      (tester) async {
    for (final supported in [false, true]) {
      final harness = _Harness(existingThread: true);
      addTearDown(() => _disposeLifecycleHarness(tester, harness));
      harness.transport.lifecycleSupported = supported;
      await tester.runAsync(harness.client.initialize);
      if (!supported) await _prepareLifecycle(tester, harness);
      await _mountLifecycle(tester, harness);
      expect(find.byTooltip('Shared thread controls'), findsNothing);
      expect(
          tester
              .widget<HandrailMessageComposer>(
                  find.byType(HandrailMessageComposer))
              .enabled,
          isTrue);
      expect(harness.transport.lifecycleWrites, isEmpty);
      await tester.pumpWidget(const SizedBox());
    }
  });

  testWidgets(
      'send authority does not imply management or membership-based permission',
      (tester) async {
    final harness = _Harness(existingThread: true);
    addTearDown(() => _disposeLifecycleHarness(tester, harness));
    final controller = await _prepareLifecycle(tester, harness,
        authority: const ChatThreadLifecycleAuthority(
          tenantId: TenantId(_tenantId),
          userId: UserId('user-current'),
          canRead: true,
          canSend: true,
        ));
    await _mountLifecycle(tester, harness);
    expect(find.byTooltip('Shared thread controls'), findsNothing);
    _remoteLifecycle(harness, 2, closed: true);
    await tester.pump();
    await _openMenu(tester);
    expect(find.text('Reopen thread'), findsOneWidget);
    expect(find.text('Lock and close thread'), findsNothing);
    await tester.tap(find.text('Reopen thread'));
    await _settleLifecycle(tester);
    expect(controller.state.isOpen, isTrue);
    expect(controller.state.capabilities.canLock, isFalse);
  });

  for (final style in ReplyStyle.values) {
    for (final restriction in ['lock', 'thread archive', 'parent archive']) {
      testWidgets(
          'remote $restriction retains mounted draft/reference/attachments and destination in $style',
          (tester) async {
        final harness = _Harness(existingThread: true);
        addTearDown(() => _disposeLifecycleHarness(tester, harness));
        await _prepareLifecycle(tester, harness);
        harness.client.replyStyles
            .configure(ChatReplyStyleConfiguration(override: style));
        _seedLifecycleDraft(harness);
        await _mountLifecycle(tester, harness);
        final before = tester.state<HandrailMessageComposerState>(
            find.byType(HandrailMessageComposer));
        expect(_draftText(tester), 'Retained Friday');
        expect(before.replyTo!.notifyAuthor, isFalse);
        final draft = harness.client.draftFor(_threadId)!.draft;
        if (restriction == 'lock') {
          _remoteLifecycle(harness, 2, locked: true);
        } else {
          _remoteArchive(harness,
              restriction == 'parent archive' ? _parentId : _threadId, false);
        }
        await _settleLifecycle(tester);
        expect(
            tester.state(find.byType(HandrailMessageComposer)), same(before));
        expect(_draftText(tester), 'Retained Friday');
        expect(before.replyTo!.messageId, const MessageId('reply-1'));
        expect(before.replyTo!.notifyAuthor, isFalse);
        expect(find.textContaining('attachment-kept'), findsOneWidget);
        expect(harness.client.draftFor(_threadId)!.draft, same(draft));
        expect(
            tester
                .widget<HandrailMessageComposer>(
                    find.byType(HandrailMessageComposer))
                .conversationId,
            _threadId);
        expect(tester.widget<IconButton>(find.byKey(_composerSend)).onPressed,
            isNull);
        await tester.ensureVisible(find.byKey(_composerSend));
        await tester.pumpAndSettle();
        expect(tester.getRect(find.byKey(_composerSend)).bottom,
            lessThanOrEqualTo(tester.getRect(find.byType(HandrailThreadView)).bottom));
        expect(tester.takeException(), isNull);
        if (restriction == 'lock') {
          _remoteLifecycle(harness, 3, closed: true);
        } else {
          expect(find.byTooltip('Shared thread controls'), findsNothing);
          _remoteArchive(harness,
              restriction == 'parent archive' ? _parentId : _threadId, true);
        }
        await _settleLifecycle(tester);
        expect(tester.widget<IconButton>(find.byKey(_composerSend)).onPressed,
            isNotNull);
        await _mountLifecycle(tester, harness, enabled: false);
        expect(_draftText(tester), 'Retained Friday');
        expect(tester.widget<IconButton>(find.byKey(_composerSend)).onPressed,
            isNull);
      });
    }
  }

  testWidgets(
      'denied command sanitizes feedback and retains draft and original destination',
      (tester) async {
    final harness = _Harness(existingThread: true);
    addTearDown(() => _disposeLifecycleHarness(tester, harness));
    await _prepareLifecycle(tester, harness);
    _seedLifecycleDraft(harness);
    harness.transport.lifecycleWrite = (_) async =>
        _lifecycleResponse({'error': 'SECRET backend detail'}, 403);
    await _mountLifecycle(tester, harness);
    await _openMenu(tester);
    await tester.tap(find.text('Close shared thread'));
    await _settleLifecycle(tester);
    expect(find.textContaining('access denied'), findsOneWidget);
    expect(find.textContaining('SECRET'), findsNothing);
    expect(_draftText(tester), 'Retained Friday');
    expect(
        tester
            .state<HandrailMessageComposerState>(
                find.byType(HandrailMessageComposer))
            .replyTo!
            .notifyAuthor,
        isFalse);
    expect(
        tester
            .widget<HandrailMessageComposer>(
                find.byType(HandrailMessageComposer))
            .conversationId,
        _threadId);
    expect(find.byTooltip('Shared thread controls'), findsNothing);
    expect(harness.transport.lifecycleWrites, hasLength(1));
  });

  testWidgets(
      'compact keyboard menu retries exact ambiguous request and restores focus',
      (tester) async {
    final harness = _Harness(existingThread: true);
    addTearDown(() => _disposeLifecycleHarness(tester, harness));
    final controller = await _prepareLifecycle(tester, harness);
    final pending = Completer<HandrailChatHttpResponse>();
    harness.transport.lifecycleWrite = (_) => pending.future;
    await _mountLifecycle(tester, harness, width: 240);
    final semantics = tester.ensureSemantics();
    expect(find.byTooltip('Shared thread controls'), findsOneWidget);
    final buttonContext = tester.element(find.byIcon(Icons.more_vert));
    final focus = Focus.of(buttonContext);
    focus.requestFocus();
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await _settleLifecycle(tester);
    expect(find.bySemanticsLabel('Close shared thread'), findsOneWidget);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pump(const Duration(milliseconds: 300));
    expect(controller.state.isSaving, isTrue);
    expect(find.textContaining('Saving thread change'), findsOneWidget);
    pending.complete(_lifecycleResponse({'error': 'temporary'}, 503));
    await _settleLifecycle(tester);
    expect(controller.state.canRetry, isTrue);
    final original = harness.transport.lifecycleWrites.single.body;
    harness.transport.lifecycleWrite =
        (request) async => _lifecycleResponse(_lifecycleResult(request));
    await _openMenu(tester);
    expect(find.bySemanticsLabel('Retry thread change'), findsOneWidget);
    expect(find.text('Close shared thread'), findsNothing);
    await tester.tap(find.text('Retry thread change'));
    await _settleLifecycle(tester);
    expect(controller.state.status, ChatThreadLifecycleStatus.ready);
    expect(harness.transport.lifecycleWrites.last.body, original);
    expect(harness.transport.lifecycleWrites, hasLength(2));
    expect(focus.hasFocus, isTrue);
    expect(tester.takeException(), isNull);
    semantics.dispose();
  });

  testWidgets('conflict shows canonical state without blind retry',
      (tester) async {
    final harness = _Harness(existingThread: true);
    addTearDown(() => _disposeLifecycleHarness(tester, harness));
    final controller = await _prepareLifecycle(tester, harness);
    harness.transport.lifecycleWrite = (request) async {
      final result = _lifecycleResult(request);
      result['reconciliationStatus'] = 'lifecycle_conflict';
      result['previousLifecycle'] =
          _lifecycleJson(5, closed: true, locked: true);
      result['threadLifecycle'] = result['previousLifecycle'];
      return _lifecycleResponse(result, 409);
    };
    await _mountLifecycle(tester, harness);
    await _openMenu(tester);
    await tester.tap(find.text('Close shared thread'));
    await _settleLifecycle(tester);
    expect(controller.state.status, ChatThreadLifecycleStatus.conflict);
    expect(find.textContaining('changed elsewhere'), findsOneWidget);
    await _openMenu(tester);
    expect(find.text('Retry thread change'), findsNothing);
    expect(find.text('Unlock thread (leaves closed)'), findsOneWidget);
    expect(harness.transport.lifecycleWrites, hasLength(1));
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await _settleLifecycle(tester);
  });

  testWidgets(
      'client rebind ignores stale results and retains caller resources',
      (tester) async {
    final first = _Harness(existingThread: true);
    final second = _Harness(existingThread: true);
    addTearDown(() => _disposeLifecycleHarness(tester, first));
    addTearDown(() => _disposeLifecycleHarness(tester, second));
    final old = await _prepareLifecycle(tester, first);
    final fresh = await _prepareLifecycle(tester, second);

    final handle = (await tester.runAsync(
                () => first.client.threads.open(rootMessageId: _rootId))
            as ChatThreadOpenSuccess)
        .handle;
    final pending = Completer<HandrailChatHttpResponse>();
    first.transport.lifecycleRead = () => pending.future;
    unawaited(old.load());

    await _mountLifecycle(tester, first, handle: handle, controller: old);

    expect(find.textContaining('Loading thread controls'), findsOneWidget);
    await _mountLifecycle(tester, second, controller: fresh);

    pending.complete(
        _lifecycleResponse(_lifecycleDetail(_rootId, _threadId, locked: true)));
    await _pumpUntil(tester, () => old.state.isLocked);

    await tester.pump();
    expect(old.state.isLocked, isTrue);
    expect(fresh.state.isLocked, isFalse);
    expect(
        tester
            .widget<HandrailMessageComposer>(
                find.byType(HandrailMessageComposer))
            .enabled,
        isTrue);
    expect(handle.isReleased, isFalse);

    await tester.pumpWidget(const SizedBox());
    expect(old.state.status, isNot(ChatThreadLifecycleStatus.disposed));
    expect(fresh.state.status, ChatThreadLifecycleStatus.ready);
    handle.release();
  });

  testWidgets('compact initial loading failure offers a working read retry',
      (tester) async {
    final second = _Harness(existingThread: true);
    addTearDown(() => _disposeLifecycleHarness(tester, second));
    final fresh = await _prepareLifecycle(tester, second);
    fresh.setAuthority(_authority);
    second.transport.lifecycleRead = () async => _lifecycleResponse({}, 503);
    await tester.runAsync(fresh.load);

    await _mountLifecycle(tester, second, width: 240);
    second.transport.lifecycleRead = null;
    await _openMenu(tester);
    await tester.tap(find.text('Retry loading thread controls'));
    await _settleLifecycle(tester);
    expect(fresh.state.status, ChatThreadLifecycleStatus.ready);
  });
}

Future<ChatThreadLifecycleController> _prepareLifecycle(
    WidgetTester tester, _Harness harness,
    {ChatThreadLifecycleAuthority authority = _authority}) async {
  await tester.runAsync(harness.client.initialize);
  final parent = _lifecycleDetail(_rootId, _parentId);
  final conversation = parent['conversation'] as Map<String, Object?>;
  conversation.remove('rootMessageId');
  conversation.remove('parentConversationId');
  conversation.remove('threadLifecycle');
  conversation['type'] = 'channel';
  conversation['name'] = 'Parent channel';
  harness.store
      .hydrateConversationDetail(ConversationDetailSnapshot.fromJson(parent));
  final controller = harness.client.threadLifecycles.forThread(_threadId)
    ..setAuthority(authority);
  expect((await tester.runAsync(controller.load))!.status,
      ChatThreadLifecycleStatus.ready);
  return controller;
}

Future<void> _mountLifecycle(WidgetTester tester, _Harness harness,
    {double width = 360,
    bool enabled = true,
    VoidCallback? onClose,
    ChatThreadOpenHandle? handle,
    ChatThreadLifecycleController? controller}) async {
  await tester.pumpWidget(_host(
      harness.client,
      SizedBox(
          width: width,
          height: 680,
          child: HandrailThreadView(
              rootMessageId: _rootId,
              openHandle: handle,
              lifecycleController: controller,
              composerEnabled: enabled,
              onClose: onClose))));
  await _pumpUntil(
      tester, () => find.byType(HandrailMessageComposer).evaluate().isNotEmpty);
  await _settleLifecycle(tester);
}

Future<void> _openMenu(WidgetTester tester) async {
  await tester.tap(find.byTooltip('Shared thread controls'));
  await _settleLifecycle(tester);
}

String _draftText(WidgetTester tester) =>
    tester.widget<TextField>(find.byKey(_composerInput)).controller!.text;
HandrailChatHttpResponse _lifecycleResponse(Object body, [int status = 200]) =>
    HandrailChatHttpResponse(statusCode: status, body: jsonEncode(body));
Map<String, Object?> _lifecycleJson(int revision,
        {bool closed = false, bool locked = false}) =>
    {
      'revision': revision,
      'locked': locked,
      if (closed || locked) 'closedAt': _now,
      if (closed || locked) 'closedByUserId': 'user-current',
    };
Map<String, Object?> _lifecycleDetail(MessageId root, ConversationId thread,
    {bool locked = false}) {
  final detail = threadCreationResultFixture('created',
      rootMessageId: root.value,
      threadId: thread.value,
      summaryThreadId: thread.value)['conversation'] as Map<String, Object?>;
  (detail['conversation'] as Map<String, Object?>)['threadLifecycle'] =
      _lifecycleJson(locked ? 9 : 1, locked: locked);
  return detail;
}

Map<String, Object?> _lifecycleResult(HandrailChatHttpRequest request) {
  final body = jsonDecode(request.body!) as Map<String, dynamic>;
  final before = body['expectedLifecycleRevision'] as int;
  final intent = body['intent'];
  return {
    ...body,
    'threadId': _threadId.value,
    'reconciliationStatus': 'applied',
    'previousLifecycle': _lifecycleJson(before,
        closed: intent == 'reopen' || intent == 'unlock',
        locked: intent == 'unlock'),
    'threadLifecycle': _lifecycleJson(before + 1,
        closed: intent != 'reopen', locked: intent == 'lock')
  };
}

void _remoteLifecycle(_Harness harness, int revision,
    {bool closed = false, bool locked = false}) {
  harness.client.reduceDurableEvent(KnownDurableEvent.fromJson({
    'eventId': 'remote-$revision',
    'tenantId': _tenantId,
    'streamId': _threadId.value,
    'type': 'thread.lifecycle.updated',
    'protocolVersion': 4,
    'occurredAt': _now,
    'payload': {
      'threadId': _threadId.value,
      'parentConversationId': _parentId.value,
      'threadLifecycle':
          _lifecycleJson(revision, closed: closed, locked: locked)
    },
  },
      trustedIdentity: const DurableEventTrustedIdentity(
          tenantId: TenantId(_tenantId), userId: UserId('user-current'))));
}

void _remoteArchive(_Harness harness, ConversationId id, bool restore) {
  harness.client.reduceDurableEvent(KnownDurableEvent.fromJson({
    'eventId': 'archive-${id.value}-$restore',
    'tenantId': _tenantId,
    'streamId': id.value,
    'type': restore ? 'conversation.restored' : 'conversation.archived',
    'protocolVersion': 4,
    'occurredAt': _now,
    'payload': {
      'conversationId': id.value,
      'intent': restore ? 'restore' : 'archive',
      'previousState': restore ? 'archived' : 'active',
      'currentState': restore ? 'active' : 'archived',
      'previousLifecycleRevision': restore ? 2 : 1,
      'currentLifecycleRevision': restore ? 3 : 2
    },
  },
      trustedIdentity: const DurableEventTrustedIdentity(
          tenantId: TenantId(_tenantId), userId: UserId('user-current'))));
}

void _seedLifecycleDraft(_Harness harness) {
  final input = <String, Object?>{
    'operation': 'synchronize_draft',
    'intent': 'replace',
    'conversationId': _threadId.value,
    'baseRevision': 0,
    'deviceMutationId': 'seed-draft',
    'idempotencyKey': 'seed-draft',
    'content': {
      'format': 'plain',
      'text': 'Retained Friday',
      'attachments': [
        {'attachmentId': 'attachment-kept'}
      ],
      'replyTo': {'messageId': 'reply-1', 'notifyAuthor': false}
    },
  };
  harness.client.reconcileDraftEvent(ConversationDraftUpdatedEvent.fromJson({
    'eventId': 'draft-seed',
    'protocolVersion': 4,
    'tenantId': _tenantId,
    'streamId': 'user:user-current',
    'type': draftUpdatedEventType,
    'occurredAt': canonicalDraftUpdatedAtFixture,
    'payload': {
      'actorUserId': 'user-current',
      'input': input,
      'result': settledDraftResultFixture(input)
    },
  }, expectedTenantId: const TenantId(_tenantId)));
}

Future<void> _settleLifecycle(WidgetTester tester) async {
  await tester.runAsync(() => Future<void>.delayed(Duration.zero));
  await tester.pumpAndSettle();
  await tester.runAsync(() => Future<void>.delayed(Duration.zero));
  await tester.pumpAndSettle();
}

Future<void> _disposeLifecycleHarness(
    WidgetTester tester, _Harness harness) async {
  await tester.pumpWidget(const SizedBox());
  var closed = false;
  unawaited(harness.dispose().then((_) => closed = true));
  await _pumpUntil(tester, () => closed);
}
