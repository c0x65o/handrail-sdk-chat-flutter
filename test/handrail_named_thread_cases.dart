part of 'handrail_chat_workspace_test.dart';

void namedThreadTests() {
  for (final saved in ['current', 'discord']) {
    testWidgets(
        'named thread $saved creates canonical discussion without changing draft',
        (tester) async {
      final http = _NamedThreadTransport(saved: saved);
      final client = await _namedClient(tester, http);
      await _mountReplyWorkspace(tester, client);
      final composer = tester.state<HandrailMessageComposerState>(
          find.byType(HandrailMessageComposer));
      final input =
          find.byKey(const ValueKey('handrail-message-composer-input'));
      await tester.enterText(input, 'Keep my draft');
      final controller = tester.widget<TextField>(input).controller!;
      await _openNameDialog(tester);
      await tester.enterText(
          find.byKey(const ValueKey('handrail-thread-name')), 'Launch date');
      await tester
          .tap(find.byKey(const ValueKey('handrail-thread-create-submit')));
      await _pumpUntil(
          tester, () => find.byType(HandrailThreadView).evaluate().isNotEmpty);
      expect(http.threadRequests, hasLength(1));
      final payload = _requestBody(http.threadRequests.single);
      expect(payload['name'], 'Launch date');
      expect(payload['parentConversationId'], _alpha.value);
      expect(payload['rootMessageId'], _root.value);
      expect(payload['initialFollow'], true);
      expect(payload['idempotencyKey'], isNotEmpty);
      expect(find.text('Canonical launch'), findsOneWidget);
      expect(find.text('In Alpha'), findsOneWidget);
      expect(controller.text, 'Keep my draft');
      expect(
          tester.stateList<HandrailMessageComposerState>(
              find.byType(HandrailMessageComposer)),
          contains(composer));
      final handle = tester
          .widget<HandrailThreadView>(find.byType(HandrailThreadView))
          .openHandle!;
      expect(handle.conversation.name, 'Canonical launch');
      expect(find.byKey(const ValueKey('handrail-create-thread-thread-reply')),
          findsNothing);
      final writes = http.requests.where((r) => r.method != 'GET').length;
      await tester.tap(find.byKey(const ValueKey('handrail-thread-close')));
      await tester.pump();
      expect(handle.isReleased, isTrue);
      expect(http.requests.where((r) => r.method != 'GET').length, writes);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('named thread server existing-root reconciliation never renames',
      (tester) async {
    final http = _NamedThreadTransport(reconciliation: 'existing_for_root');
    final client = await _namedClient(tester, http);
    await _mountReplyWorkspace(tester, client);
    await _openNameDialog(tester);
    await tester.enterText(find.byKey(const ValueKey('handrail-thread-name')),
        'My competing name');
    await tester
        .tap(find.byKey(const ValueKey('handrail-thread-create-submit')));
    await _pumpUntil(
        tester, () => find.byType(HandrailThreadView).evaluate().isNotEmpty);
    expect(find.text('Canonical launch'), findsOneWidget);
    await tester.pumpAndSettle();
    expect(find.text('My competing name'), findsNothing);
    final handle = tester
        .widget<HandrailThreadView>(find.byType(HandrailThreadView))
        .openHandle!;
    expect(handle.state.reconciliationStatus,
        ThreadCreationReconciliationStatus.existingForRoot);
    await tester.tap(find.byKey(const ValueKey('handrail-thread-close')));
    await tester.pump();
    await tester
        .tap(find.byKey(const ValueKey('handrail-create-thread-root-alpha')));
    await _pumpUntil(
        tester, () => find.byType(HandrailThreadView).evaluate().isNotEmpty);
    expect(find.byType(AlertDialog), findsNothing);
    expect(http.threadRequests, hasLength(1));
  });

  testWidgets(
      'named thread compact validation keyboard semantics and cancel restores focus',
      (tester) async {
    final http = _NamedThreadTransport();
    final client = await _namedClient(tester, http);
    tester.view.physicalSize = const Size(360, 800);
    await _mountReplyWorkspace(tester, client);
    final trigger =
        find.byKey(const ValueKey('handrail-create-thread-root-alpha'));
    final semantics = tester.ensureSemantics();
    expect(
        tester.getSemantics(trigger).getSemanticsData().label, 'Create Thread');
    final focus = Focus.of(tester.element(
        find.descendant(of: trigger, matching: find.text('Create Thread'))));
    focus.requestFocus();
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();
    final name = find.byKey(const ValueKey('handrail-thread-name'));
    expect(_primaryFocusIsWithin(tester, name), true);
    for (final invalid in ['', ' name', 'name\u0085', '😀' * 101]) {
      await tester.enterText(name, invalid);
      await tester
          .tap(find.byKey(const ValueKey('handrail-thread-create-submit')));
      await tester.pump();
      expect(find.textContaining('Use 1–100'), findsOneWidget);
      expect(http.threadRequests, isEmpty);
    }
    expect(
        tester
            .widget<TextFormField>(name)
            .validator!(String.fromCharCode(0xd800)),
        isNotNull);
    await tester.tap(find.widgetWithText(TextButton, 'Cancel'));
    await tester.pumpAndSettle();
    expect(focus.hasFocus, isTrue);
    expect(tester.takeException(), isNull);
    semantics.dispose();
  });

  testWidgets(
      'named thread canonical Unicode scalar limit accepts 100 emoji unchanged',
      (tester) async {
    final http = _NamedThreadTransport();
    final client = await _namedClient(tester, http);
    await _mountReplyWorkspace(tester, client);
    await _openNameDialog(tester);
    final name = '😀' * 100;
    await tester.enterText(
        find.byKey(const ValueKey('handrail-thread-name')), name);
    await tester
        .tap(find.byKey(const ValueKey('handrail-thread-create-submit')));
    await _pumpUntil(tester, () => http.threadRequests.isNotEmpty);
    expect(_requestBody(http.threadRequests.single)['name'], name);
  });

  testWidgets(
      'named thread failed create retry freezes payload and preserves inline draft',
      (tester) async {
    final http = _NamedThreadTransport(failures: 1);
    final client = await _namedClient(tester, http);
    await _mountReplyWorkspace(tester, client);
    await tester.tap(find.byKey(const ValueKey('handrail-reply-root-alpha')));
    final composer = tester.state<HandrailMessageComposerState>(
        find.byType(HandrailMessageComposer));
    composer.setReplyNotifyAuthor(false);
    await tester.enterText(
        find.byKey(const ValueKey('handrail-message-composer-input')),
        'Friday');
    final controller = tester
        .widget<TextField>(
            find.byKey(const ValueKey('handrail-message-composer-input')))
        .controller!;
    await _openNameDialog(tester);
    await tester.enterText(
        find.byKey(const ValueKey('handrail-thread-name')), 'Frozen name');
    await tester
        .tap(find.byKey(const ValueKey('handrail-thread-create-submit')));
    await _pumpUntil(
        tester, () => find.textContaining('Retry uses').evaluate().isNotEmpty);
    expect(controller.text, 'Friday');
    expect(composer.replyTo!.messageId, _root);
    expect(composer.replyTo!.notifyAuthor, false);
    expect(
        tester
            .widget<TextField>(find.descendant(
                of: find.byKey(const ValueKey('handrail-thread-name')),
                matching: find.byType(TextField)))
            .readOnly,
        true);
    await tester
        .tap(find.byKey(const ValueKey('handrail-thread-create-submit')));
    await _pumpUntil(
        tester, () => find.byType(HandrailThreadView).evaluate().isNotEmpty);
    expect(http.threadRequests, hasLength(2));
    expect(_requestBody(http.threadRequests.first),
        _requestBody(http.threadRequests.last));
    expect(http.sends, isEmpty);
  });

  for (final ending in ['cancel', 'switch', 'dispose']) {
    testWidgets('named thread pending $ending ignores late completion',
        (tester) async {
      final pending = Completer<HandrailChatHttpResponse>();
      final http = _NamedThreadTransport(pending: pending);
      final client = await _namedClient(tester, http);
      var selected = _alpha;
      Future<void> mount() => tester.pumpWidget(_host(client,
          width: 1100,
          child: HandrailChatWorkspace(initialConversationId: selected)));
      await mount();
      await _pumpUntil(
          tester,
          () => find
              .byKey(const ValueKey('handrail-create-thread-root-alpha'))
              .evaluate()
              .isNotEmpty);
      await _openNameDialog(tester);
      await tester.enterText(
          find.byKey(const ValueKey('handrail-thread-name')), 'Pending name');
      final submit =
          find.byKey(const ValueKey('handrail-thread-create-submit'));
      await tester.tap(submit);
      await _pumpUntil(tester, () => http.threadRequests.isNotEmpty);
      expect(tester.widget<FilledButton>(submit).onPressed, isNull);
      if (ending == 'cancel') {
        await tester.tap(find.widgetWithText(TextButton, 'Cancel'));
      } else if (ending == 'switch') {
        selected = _beta;
        await mount();
      } else {
        await tester.pumpWidget(const SizedBox());
      }
      await tester.pumpAndSettle();
      pending.complete(http.result());
      await _pumpUntil(
          tester,
          () =>
              client.normalizedState.state.conversations[_thread] != null &&
              client.threads.forRoot(_root).state
                  is ChatThreadOpeningIdleState);
      await tester.pumpAndSettle();
      expect(find.byType(HandrailThreadView), findsNothing);
      expect(find.byType(AlertDialog), findsNothing);
      expect(http.threadRequests, hasLength(1));
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets(
      'named thread unavailable capability keeps existing and Current entry points',
      (tester) async {
    final http = _NamedThreadTransport(enabled: false, saved: 'current');
    final client = await _namedClient(tester, http);
    await _mountReplyWorkspace(tester, client);
    expect(
        tester
            .widget<TextButton>(
                find.byKey(const ValueKey('handrail-create-thread-root-alpha')))
            .onPressed,
        isNull);
    expect(
        find.textContaining('Named threads are unavailable'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('handrail-reply-root-alpha')));
    await _pumpUntil(
        tester, () => find.byType(HandrailThreadView).evaluate().isNotEmpty);
    expect(_requestBody(http.threadRequests.single).containsKey('name'), false);
    await tester.tap(find.byKey(const ValueKey('handrail-thread-close')));
    await tester.pump();
    expect(find.text('Open Thread'), findsOneWidget);
    await tester
        .tap(find.byKey(const ValueKey('handrail-create-thread-root-alpha')));
    await _pumpUntil(
        tester, () => find.byType(HandrailThreadView).evaluate().isNotEmpty);
    expect(find.text('Canonical launch'), findsOneWidget);
  });

  testWidgets(
      'named thread excludes deleted optimistic and newly deleted roots',
      (tester) async {
    final http = _NamedThreadTransport();
    final client = await _namedClient(tester, http);
    await _mountReplyWorkspace(tester, client);
    final pending = Map<String, Object?>.from(
        (_timelinePage(_alpha)['messages'] as List).first as Map)
      ..['id'] = 'pending'
      ..['sequence'] = 2
      ..remove('threadSummary')
      ..['isThreadRoot'] = false;
    client.normalizedState.beginOptimisticMessageSend(
        clientMessageId: 'pending',
        projection: MessageTimelineMessage.fromJson(pending));
    await tester.pump();
    expect(find.byKey(const ValueKey('handrail-create-thread-pending')),
        findsNothing);
    await _openNameDialog(tester);
    http.deleted = true;
    await tester
        .runAsync(() => client.timelines.forConversation(_alpha).refresh());
    await tester.enterText(
        find.byKey(const ValueKey('handrail-thread-name')), 'Too late');
    await tester
        .tap(find.byKey(const ValueKey('handrail-thread-create-submit')));
    await tester.pump();
    expect(
        find.text('This thread root is no longer available.'), findsOneWidget);
    expect(http.threadRequests, isEmpty);
    await tester.tap(find.widgetWithText(TextButton, 'Cancel'));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('handrail-create-thread-root-alpha')),
        findsNothing);
  });
  testWidgets(
      'named thread legacy header custom builders and caller handle ownership',
      (tester) async {
    final http = _NamedThreadTransport(name: null);
    final client = await _namedClient(tester, http);
    await _mountReplyWorkspace(tester, client);
    final result =
        await tester.runAsync(() => client.threads.forRoot(_root).open());
    final handle = (result as ChatThreadOpenSuccess).handle;
    Future<void> mount({bool custom = false}) => tester.pumpWidget(_host(client,
        width: 600,
        child: HandrailThreadView(
            openHandle: handle,
            title: custom ? const Text('Host title') : null,
            rootBuilder: custom
                ? (_, input) => Text('Host root ${input.rootMessageId.value}')
                : null)));
    await mount();
    await _pumpUntil(tester, () => find.text('Thread').evaluate().isNotEmpty);
    expect(find.text('In Alpha'), findsOneWidget);
    await mount(custom: true);
    await tester.pump();
    expect(find.text('Host title'), findsOneWidget);
    expect(find.text('Host root root-alpha'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
    expect(handle.isReleased, false);
    handle.release();
    expect(
        client.threads.forRoot(_root).state, isA<ChatThreadOpeningIdleState>());
    expect(tester.takeException(), isNull);
  });

  testWidgets(
      'named thread parent context redacts on denied access and deleted roots stay open',
      (tester) async {
    final http = _NamedThreadTransport();
    final client = await _namedClient(tester, http);
    await _mountReplyWorkspace(tester, client);
    await _openNameDialog(tester);
    await tester.enterText(
        find.byKey(const ValueKey('handrail-thread-name')), 'Launch');
    await tester
        .tap(find.byKey(const ValueKey('handrail-thread-create-submit')));
    await _pumpUntil(
        tester, () => find.byType(HandrailThreadView).evaluate().isNotEmpty);
    await tester.pumpAndSettle();
    final handle = tester
        .widget<HandrailThreadView>(find.byType(HandrailThreadView))
        .openHandle!;
    http.deleted = true;
    await tester
        .runAsync(() => client.timelines.forConversation(_alpha).refresh());
    await tester.pump();
    expect(find.text('Root message deleted'), findsOneWidget);
    expect(handle.isReleased, false);
    http.denyParent = true;
    await tester
        .runAsync(() => client.conversations.forConversation(_alpha).refresh());
    await tester.pump();
    expect(find.text('In Alpha'), findsNothing);
    expect(find.text('Parent conversation unavailable'), findsOneWidget);
    expect(find.text('Root message unavailable'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('handrail-thread-close')));
    await tester.pump();
    // Cached canonical IDs do not bypass fresh existing-thread authorization.
    final timeline = tester
        .widget<HandrailMessageTimeline>(find.byType(HandrailMessageTimeline));
    final root = client.timelines.forConversation(_alpha).state.messages.first;
    await tester.runAsync(() => timeline.onThreadRequested!(
        ChatMessageActions.forMessage(
            controller: client.timelines.forConversation(_alpha),
            message: root)));
    await tester.pump();
    expect(find.byType(HandrailThreadView), findsNothing);
    expect(find.text('This thread is unavailable. Try Open Thread again.'),
        findsOneWidget);
    expect(http.threadRequests, hasLength(1));
  });

  testWidgets(
      'named thread failed cancel keeps attachment draft and a new intent gets a new key',
      (tester) async {
    final http = _NamedThreadTransport(failures: 2);
    final client = await _namedClient(tester, http);
    await tester.runAsync(() => client.synchronizeDraft(ChatReplaceDraftInput(
        conversationId: _alpha,
        baseRevision: 0,
        content: DraftContent.fromJson({
          'format': 'plain',
          'text': 'Unsent plan',
          'attachments': [
            {'attachmentId': 'schedule'}
          ],
          'replyTo': {'messageId': _root.value, 'notifyAuthor': false}
        }),
        deviceMutationId: 'named-draft',
        idempotencyKey: 'named-draft')));
    await _mountReplyWorkspace(tester, client);
    final composer = tester.state<HandrailMessageComposerState>(
        find.byType(HandrailMessageComposer));
    final draft = client.draftFor(_alpha)!.draft.toJson();
    for (final name in ['First intent', 'New intent']) {
      await _openNameDialog(tester);
      await tester.enterText(
          find.byKey(const ValueKey('handrail-thread-name')), name);
      await tester
          .tap(find.byKey(const ValueKey('handrail-thread-create-submit')));
      await _pumpUntil(tester,
          () => find.textContaining('Retry uses').evaluate().isNotEmpty);
      await tester.tap(find.widgetWithText(TextButton, 'Cancel'));
      await tester.pumpAndSettle();
      expect(find.text('Unsent plan'), findsOneWidget);
      expect(find.text('schedule'), findsOneWidget);
      expect(composer.replyTo!.notifyAuthor, false);
      expect(client.draftFor(_alpha)!.draft.toJson(), draft);
      expect(
          tester.state(find.byType(HandrailMessageComposer)), same(composer));
    }
    expect(_requestBody(http.threadRequests.first)['idempotencyKey'],
        isNot(_requestBody(http.threadRequests.last)['idempotencyKey']));
    expect(http.sends, isEmpty);
  });

  for (final failDelegate in [false, true]) {
    testWidgets(
        'named thread host delegate failure=$failDelegate releases its retain',
        (tester) async {
      final http = _NamedThreadTransport();
      final client = await _namedClient(tester, http);
      final ids = <ConversationId>[];
      await tester.pumpWidget(_host(client,
          width: 1100,
          child: HandrailChatWorkspace(
              initialConversationId: _alpha,
              delegates: ChatApplicationDelegates(openThread: (id) async {
                ids.add(id);
                if (failDelegate) throw StateError('host navigation failed');
                return ChatApplicationDelegateResult.handled;
              }))));
      await _pumpUntil(
          tester,
          () => find
              .byKey(const ValueKey('handrail-create-thread-root-alpha'))
              .evaluate()
              .isNotEmpty);
      await _openNameDialog(tester);
      await tester.enterText(
          find.byKey(const ValueKey('handrail-thread-name')), 'Launch');
      await tester
          .tap(find.byKey(const ValueKey('handrail-thread-create-submit')));
      await _pumpUntil(
          tester,
          () =>
              ids.isNotEmpty &&
              client.threads.forRoot(_root).state
                  is ChatThreadOpeningIdleState);
      expect(ids, [_thread]);
      expect(find.byType(HandrailThreadView), findsNothing);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets(
      'named thread compact success keeps header close and returns to parent draft',
      (tester) async {
    final http = _NamedThreadTransport();
    final client = await _namedClient(tester, http);
    tester.view.physicalSize = const Size(390, 850);
    await _mountReplyWorkspace(tester, client);
    await tester.enterText(
        find.byKey(const ValueKey('handrail-message-composer-input')),
        'Parent plan');
    await _openNameDialog(tester);
    await tester.enterText(
        find.byKey(const ValueKey('handrail-thread-name')), 'Launch');
    await tester
        .tap(find.byKey(const ValueKey('handrail-thread-create-submit')));
    await _pumpUntil(
        tester, () => find.byType(HandrailThreadView).evaluate().isNotEmpty);
    await tester.pumpAndSettle();
    expect(find.text('Canonical launch'), findsOneWidget);
    expect(find.text('In Alpha'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('handrail-thread-close')));
    await _pumpUntil(
        tester, () => find.text('Parent plan').evaluate().isNotEmpty);
    expect(find.byType(HandrailThreadView), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
      'named thread disposal during host navigation releases before late delegate returns',
      (tester) async {
    final http = _NamedThreadTransport();
    final client = await _namedClient(tester, http);
    final navigation = Completer<ChatApplicationDelegateResult>();
    var requested = false;
    await tester.pumpWidget(_host(client,
        width: 1100,
        child: HandrailChatWorkspace(
            initialConversationId: _alpha,
            delegates: ChatApplicationDelegates(openThread: (_) {
              requested = true;
              return navigation.future;
            }))));
    await _pumpUntil(
        tester,
        () => find
            .byKey(const ValueKey('handrail-create-thread-root-alpha'))
            .evaluate()
            .isNotEmpty);
    await _openNameDialog(tester);
    await tester.enterText(
        find.byKey(const ValueKey('handrail-thread-name')), 'Launch');
    await tester
        .tap(find.byKey(const ValueKey('handrail-thread-create-submit')));
    await _pumpUntil(tester, () => requested);
    await tester.pumpWidget(const SizedBox());
    expect(
        client.threads.forRoot(_root).state, isA<ChatThreadOpeningIdleState>());
    navigation.complete(ChatApplicationDelegateResult.unavailable);
    await tester.pumpAndSettle();
    expect(find.byType(HandrailThreadView), findsNothing);
    expect(tester.takeException(), isNull);
  });
}

Future<void> _openNameDialog(WidgetTester tester) async {
  await tester
      .tap(find.byKey(const ValueKey('handrail-create-thread-root-alpha')));
  await tester.pumpAndSettle();
  expect(find.byType(AlertDialog), findsOneWidget);
}

Future<HandrailChatClient> _namedClient(
    WidgetTester tester, _NamedThreadTransport http) async {
  tester.view.physicalSize = const Size(1400, 900);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  var nextKey = 0;
  final client = HandrailChatClient(
      apiBaseUri: Uri.parse('https://chat.example.test/api/chat'),
      tokenProvider: () async => 'workspace-token',
      transport: http,
      commandRetryOptions: const ChatCommandRetryOptions(maxAttempts: 1),
      generateIdempotencyKey: () => 'named-ui-${nextKey++}',
      requestedCapabilities: {
        ChatReplyThreadFeatures.namedThreads: true,
        ChatReplyThreadFeatures.inlineReplies: true,
        replyStylePreferenceFeature: true,
      });
  addTearDown(() async {
    await tester.pumpWidget(const SizedBox());
    var disposed = false;
    unawaited(client.dispose().then((_) => disposed = true));
    await _pumpUntil(tester, () => disposed);
  });
  await tester.runAsync(client.initialize);
  await tester.runAsync(() => client.replyStyles.activateIdentity(
      const ChatReplyStyleIdentity(
          tenantId: TenantId(_tenant), userId: UserId(_user))));
  _seedConversation(client, _alpha, 'Alpha', latestSequence: 1);
  return client;
}

class _NamedThreadTransport extends _ReplyRoutingTransport {
  _NamedThreadTransport(
      {super.saved,
      this.enabled = true,
      this.reconciliation = 'created',
      this.failures = 0,
      this.pending,
      this.name = 'Canonical launch'});
  bool denyParent = false;
  final bool enabled;
  final String reconciliation;
  int failures;
  final Completer<HandrailChatHttpResponse>? pending;
  final String? name;

  @override
  Map<String, bool> get enabledFeatures => {
        ...super.enabledFeatures,
        ChatReplyThreadFeatures.namedThreads: enabled,
      };

  HandrailChatHttpResponse result() {
    final body = threadCreationResultFixture(reconciliation,
        parentConversationId: _alpha.value,
        rootMessageId: _root.value,
        threadId: _thread.value,
        summaryThreadId: _thread.value);
    if (name != null)
      ((body['conversation'] as Map)['conversation'] as Map)['name'] = name;
    return _jsonResponse(body, statusCode: 201);
  }

  @override
  Future<HandrailChatHttpResponse> send(HandrailChatHttpRequest request) async {
    if (denyParent &&
        request.method == 'GET' &&
        (request.uri.path.endsWith('/conversations/alpha') ||
            request.uri.path.endsWith('/conversations/alpha/messages'))) {
      requests.add(request);
      return _jsonResponse({'error': 'access denied'}, statusCode: 403);
    }
    if (request.method == 'POST' && request.uri.path.endsWith('/thread')) {
      requests.add(request);
      if (failures-- > 0)
        return _jsonResponse({'error': 'unavailable'}, statusCode: 503);
      if (pending != null) return pending!.future;
      return result();
    }
    final response = await super.send(request);
    if (request.method == 'GET' &&
        request.uri.path.endsWith('/conversations/thread-alpha') &&
        name != null) {
      final body = jsonDecode(response.body) as Map<String, dynamic>;
      (body['conversation'] as Map)['name'] = name;
      return _jsonResponse(body);
    }
    return response;
  }
}
