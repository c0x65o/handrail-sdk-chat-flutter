part of 'handrail_chat_workspace_test.dart';

void threadDiscoveryTests() {
  for (final saved in ['current', 'discord']) {
    testWidgets(
        'thread discovery $saved opens unfollowed canonical deleted-root history without writes',
        (tester) async {
      final http = _DiscoveryTransport(saved: saved);
      final client = await _namedClient(tester, http);
      await _mountReplyWorkspace(tester, client);
      http.deletedRoot = true;
      await tester.tap(find.byTooltip('Browse channel threads'));
      await _pumpUntil(tester,
          () => find.text('Not following · 3 unread').evaluate().isNotEmpty);
      expect(find.text('Threads in Alpha'), findsOneWidget);
      expect(find.text('Canonical launch'), findsOneWidget);
      await tester.tap(find.text('Canonical launch'));
      await _pumpUntil(
          tester, () => find.text('Thread reply').evaluate().isNotEmpty);
      final handle = tester
          .widget<HandrailThreadView>(find.byType(HandrailThreadView))
          .openHandle!;
      expect(handle.conversationId, _thread);
      expect(
          handle.state.rootContextStatus, ChatThreadRootContextStatus.deleted);
      expect(find.textContaining('deleted'), findsWidgets);
      expect(find.text('In Alpha'), findsOneWidget);
      await tester.tap(find.byTooltip('Back to threads'));
      await tester.pump();
      expect(handle.isReleased, isTrue);
      await tester.tap(find.text('Canonical launch'));
      await _pumpUntil(
          tester, () => find.byType(HandrailThreadView).evaluate().isNotEmpty);
      final second = tester
          .widget<HandrailThreadView>(find.byType(HandrailThreadView))
          .openHandle!;
      expect(second.conversationId, _thread);
      await tester.pumpWidget(const SizedBox());
      expect(second.isReleased, isTrue);
      expect(http.threadRequests, isEmpty);
      expect(
          http.requests
              .where((r) => r.method != 'GET' && r.uri.path.contains('follow')),
          isEmpty);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets(
      'thread discovery compact keyboard back restores row and channel focus and draft',
      (tester) async {
    final http = _DiscoveryTransport();
    final client = await _namedClient(tester, http);
    tester.view.physicalSize = const Size(360, 800);
    await _mountReplyWorkspace(tester, client);
    final input = find.byKey(const ValueKey('handrail-message-composer-input'));
    await tester.enterText(input, 'Retain channel draft');
    final composer = tester.state<HandrailMessageComposerState>(
        find.byType(HandrailMessageComposer));
    final focus = tester
        .widget<IconButton>(
            find.byKey(const ValueKey('handrail-workspace-threads')))
        .focusNode!;
    focus.requestFocus();
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await _pumpUntil(
        tester, () => find.text('Canonical launch').evaluate().isNotEmpty);
    final row = find.byKey(const ValueKey('handrail-thread-list-thread-alpha'));
    final semantics = tester.ensureSemantics();
    expect(tester.getSemantics(row).getSemanticsData().label,
        contains('Not following'));
    await tester.pumpAndSettle();
    expect(_primaryFocusIsWithin(tester, row), isTrue);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await _pumpUntil(
        tester, () => find.text('Thread reply').evaluate().isNotEmpty);
    await tester.binding.handlePopRoute();
    await _pumpUntil(
        tester,
        () =>
            find.byType(HandrailThreadView).evaluate().isEmpty &&
            _primaryFocusIsWithin(tester, row));
    expect(find.byType(HandrailThreadView), findsNothing);
    expect(_primaryFocusIsWithin(tester, row), isTrue);
    await tester.binding.handlePopRoute();
    await _pumpUntil(
        tester,
        () =>
            focus.hasFocus &&
            find.byType(HandrailThreadList).evaluate().isEmpty);
    expect(focus.hasFocus, isTrue);
    expect(
        tester.state<HandrailMessageComposerState>(
            find.byType(HandrailMessageComposer)),
        same(composer));
    expect(tester.widget<TextField>(input).controller!.text,
        'Retain channel draft');
    expect(tester.takeException(), isNull);
    semantics.dispose();
  });

  testWidgets(
      'thread discovery pagination retry follow unread and supported filters',
      (tester) async {
    final http = _DiscoveryTransport()..more = true;
    final client = await _namedClient(tester, http);
    await tester.pumpWidget(_host(client,
        width: 1100,
        child: const HandrailChatWorkspace(
            initialConversationId: _alpha, pageSize: 1)));
    await _pumpUntil(tester,
        () => find.byTooltip('Browse channel threads').evaluate().isNotEmpty);
    await tester.tap(find.byTooltip('Browse channel threads'));
    await _pumpUntil(
        tester, () => find.text('Canonical launch').evaluate().isNotEmpty);
    expect(find.text('Active'), findsOneWidget);
    expect(find.text('All'), findsOneWidget);
    http.failList = true;
    await tester.tap(find.text('Load more threads'));
    await _pumpUntil(
        tester, () => find.text('Retry threads').evaluate().isNotEmpty);
    expect(find.text('Canonical launch'), findsOneWidget);
    final cursor = http.listReads.last.uri.queryParameters['cursor'];
    expect(cursor, isNotNull);
    http.failList = false;
    await tester.tap(find.text('Retry threads'));
    await _pumpUntil(
        tester, () => find.text('Following · 0 unread').evaluate().isNotEmpty);
    expect(http.listReads.last.uri.queryParameters['cursor'], cursor);
    expect(find.text('Thread'), findsOneWidget);
    await tester.tap(find.text('All'));
    await _pumpUntil(
        tester,
        () =>
            http.listReads.last.uri.queryParameters['view'] == 'all' &&
            find.text('Canonical launch').evaluate().isNotEmpty);
    expect(
        http.listReads.last.uri.queryParameters.containsKey('cursor'), isFalse);
    await tester.tap(find.byTooltip('Refresh threads'));
    await _pumpUntil(
        tester, () => find.byType(LinearProgressIndicator).evaluate().isEmpty);
    expect(http.listReads.last.uri.queryParameters['view'], 'all');
    expect(tester.takeException(), isNull);
  });

  testWidgets(
      'thread discovery unsupported filters empty initial retry and denied state',
      (tester) async {
    final http = _DiscoveryTransport()
      ..supported = false
      ..failList = true;
    final client = await _namedClient(tester, http);
    await _mountReplyWorkspace(tester, client);
    await tester.tap(find.byTooltip('Browse channel threads'));
    await _pumpUntil(
        tester, () => find.text('Retry threads').evaluate().isNotEmpty);
    http.failList = false;
    http.empty = true;
    await tester.tap(find.text('Retry threads'));
    await _pumpUntil(
        tester, () => find.text('No threads found.').evaluate().isNotEmpty);
    expect(find.byType(ChoiceChip), findsNothing);
    http.empty = false;
    await tester.tap(find.byTooltip('Refresh threads'));
    await _pumpUntil(
        tester, () => find.text('Canonical launch').evaluate().isNotEmpty);
    http.denyList = true;
    await tester.tap(find.byTooltip('Refresh threads'));
    await _pumpUntil(
        tester,
        () => find
            .text('Thread discovery is unavailable.')
            .evaluate()
            .isNotEmpty);
    expect(find.text('Canonical launch'), findsNothing);
    expect(find.byType(ChoiceChip), findsNothing);
  });

  testWidgets(
      'thread discovery parent revocation closes and releases open history',
      (tester) async {
    final http = _DiscoveryTransport();
    final client = await _namedClient(tester, http);
    await _mountReplyWorkspace(tester, client);
    await tester.tap(find.byTooltip('Browse channel threads'));
    await _pumpUntil(
        tester, () => find.text('Canonical launch').evaluate().isNotEmpty);
    await tester.tap(find.text('Canonical launch'));
    await _pumpUntil(
        tester, () => find.byType(HandrailThreadView).evaluate().isNotEmpty);
    final handle = tester
        .widget<HandrailThreadView>(find.byType(HandrailThreadView))
        .openHandle!;
    http.denyParent = true;
    await tester.runAsync(client.conversations.forConversation(_alpha).refresh);
    await tester.pumpAndSettle();
    expect(handle.isReleased, isTrue);
    expect(find.byType(HandrailThreadView), findsNothing);
    expect(find.byTooltip('Browse channel threads'), findsNothing);
    expect(find.text('Canonical launch'), findsNothing);
  });

  testWidgets('thread discovery stale list cannot display previous channel',
      (tester) async {
    final http = _DiscoveryTransport()
      ..pendingList = Completer<HandrailChatHttpResponse>();
    final client = await _namedClient(tester, http);
    await _mountReplyWorkspace(tester, client);
    await tester.tap(find.byTooltip('Browse channel threads'));
    await _pumpUntil(tester, () => http.listReads.isNotEmpty);
    expect(find.byType(LinearProgressIndicator), findsWidgets);
    await tester.pumpWidget(_host(client,
        width: 1100,
        child: const HandrailChatWorkspace(initialConversationId: _beta)));
    http.pendingList!.complete(_jsonResponse(http.page('active')));
    await tester.pumpAndSettle();
    expect(find.text('Canonical launch'), findsNothing);
    expect(find.byType(HandrailThreadList), findsNothing);
    expect(tester.takeException(), isNull);
  });

  for (final exit in ['dismiss', 'channel', 'dispose']) {
    testWidgets('thread discovery pending canonical open releases after $exit',
        (tester) async {
      final http = _DiscoveryTransport()
        ..pendingOpen = Completer<HandrailChatHttpResponse>();
      final client = await _namedClient(tester, http);
      await _mountReplyWorkspace(tester, client);
      await tester.tap(find.byTooltip('Browse channel threads'));
      await _pumpUntil(
          tester, () => find.text('Canonical launch').evaluate().isNotEmpty);
      await tester.tap(find.text('Canonical launch'));
      await _pumpUntil(tester, () => http.openRequested);
      if (exit == 'dismiss') {
        await tester.tap(find.byTooltip('Back to channel'));
      } else {
        await tester.pumpWidget(exit == 'dispose'
            ? const SizedBox()
            : _host(client,
                width: 1100,
                child:
                    const HandrailChatWorkspace(initialConversationId: _beta)));
      }
      http.pendingOpen!.complete(await tester.runAsync(http.detail));
      await tester.pumpAndSettle();
      expect(find.byType(HandrailThreadView), findsNothing);
      expect(client.threads.forRoot(_root).state,
          isA<ChatThreadOpeningIdleState>());
      expect(http.threadRequests, isEmpty);
      expect(tester.takeException(), isNull);
    });
  }

  for (final outcome in ['handled', 'throws', 'late']) {
    testWidgets('thread discovery delegate $outcome releases canonical retain',
        (tester) async {
      final http = _DiscoveryTransport();
      final client = await _namedClient(tester, http);
      final ids = <ConversationId>[];
      final pending = Completer<ChatApplicationDelegateResult>();
      await tester.pumpWidget(_host(client,
          width: 1100,
          child: HandrailChatWorkspace(
            initialConversationId: _alpha,
            delegates: ChatApplicationDelegates(openThread: (id) async {
              ids.add(id);
              if (outcome == 'throws')
                throw StateError('host navigation failed');
              if (outcome == 'late') return pending.future;
              return ChatApplicationDelegateResult.handled;
            }),
          )));
      await _pumpUntil(tester,
          () => find.byTooltip('Browse channel threads').evaluate().isNotEmpty);
      await tester.tap(find.byTooltip('Browse channel threads'));
      await _pumpUntil(
          tester, () => find.text('Canonical launch').evaluate().isNotEmpty);
      await tester.tap(find.text('Canonical launch'));
      await _pumpUntil(tester, () => ids.isNotEmpty);
      if (outcome == 'late') {
        await tester.tap(find.byTooltip('Back to channel'));
        await tester.pump();
        expect(client.threads.forRoot(_root).state,
            isA<ChatThreadOpeningIdleState>());
        pending.complete(ChatApplicationDelegateResult.unavailable);
      }
      await _pumpUntil(
          tester,
          () => client.threads.forRoot(_root).state
              is ChatThreadOpeningIdleState);
      expect(ids, [_thread]);
      expect(find.byType(HandrailThreadView), findsNothing);
      expect(http.threadRequests, isEmpty);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets(
      'thread discovery client replacement releases history and Escape returns to channel',
      (tester) async {
    final http = _DiscoveryTransport();
    final client = await _namedClient(tester, http);
    final replacement = await _namedClient(tester, _DiscoveryTransport());
    await _mountReplyWorkspace(tester, client);
    await tester.tap(find.byTooltip('Browse channel threads'));
    await _pumpUntil(
        tester, () => find.text('Canonical launch').evaluate().isNotEmpty);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await _pumpUntil(
        tester, () => find.byType(HandrailThreadList).evaluate().isEmpty);
    await tester.tap(find.byTooltip('Browse channel threads'));
    await _pumpUntil(
        tester, () => find.text('Canonical launch').evaluate().isNotEmpty);
    await tester.tap(find.text('Canonical launch'));
    await _pumpUntil(
        tester, () => find.byType(HandrailThreadView).evaluate().isNotEmpty);
    final handle = tester
        .widget<HandrailThreadView>(find.byType(HandrailThreadView))
        .openHandle!;
    await tester.pumpWidget(_host(replacement,
        width: 1100,
        child: const HandrailChatWorkspace(initialConversationId: _alpha)));
    await tester.pump();
    expect(handle.isReleased, isTrue);
    expect(find.byType(HandrailThreadView), findsNothing);
    expect(find.byType(HandrailThreadList), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
      'thread discovery pending list rejects revoked and changed identity authority',
      (tester) async {
    final http = _DiscoveryTransport()
      ..pendingList = Completer<HandrailChatHttpResponse>();
    final client = await _namedClient(tester, http);
    final controller = client.threadLists.forParent(_alpha);
    const authority = ChatThreadListAuthority(
        tenantId: TenantId(_tenant), userId: UserId(_user), canRead: true);
    Widget list(ChatThreadListAuthority? value) => MaterialApp(
            home: Scaffold(
                body: HandrailThreadList(
          client: client,
          parentConversationId: _alpha,
          authority: value,
          controller: controller,
          onSelected: (_) {},
        )));
    await tester.pumpWidget(list(authority));
    await _pumpUntil(tester, () => http.listReads.isNotEmpty);
    await tester.pumpWidget(list(null));
    http.pendingList!.complete(_jsonResponse(http.page('active')));
    await tester.pump();
    expect(controller.state.status, ChatThreadListStatus.accessDenied);
    expect(find.text('Canonical launch'), findsNothing);
    http.pendingList = null;
    await tester.pumpWidget(list(const ChatThreadListAuthority(
        tenantId: TenantId(_tenant),
        userId: UserId('different-user'),
        canRead: true)));
    await _pumpUntil(
        tester, () => controller.state.status == ChatThreadListStatus.error);
    expect(find.text('Canonical launch'), findsNothing);
    await tester.pumpWidget(const SizedBox());
    await tester.runAsync(controller.dispose);
  });

  testWidgets(
      'thread discovery supplied list controller survives disposal and authority changes clear data',
      (tester) async {
    final http = _DiscoveryTransport();
    final client = await _namedClient(tester, http);
    final controller = client.threadLists.forParent(_alpha);
    const authority = ChatThreadListAuthority(
        tenantId: TenantId(_tenant), userId: UserId(_user), canRead: true);
    Widget list(ChatThreadListAuthority? value) => MaterialApp(
            home: Scaffold(
                body: HandrailThreadList(
          client: client,
          parentConversationId: _alpha,
          authority: value,
          controller: controller,
          onSelected: (_) {},
        )));
    await tester.pumpWidget(list(authority));
    await _pumpUntil(
        tester, () => find.text('Canonical launch').evaluate().isNotEmpty);
    await tester.pumpWidget(list(null));
    await tester.pump();
    expect(find.text('Canonical launch'), findsNothing);
    expect(controller.state.status, ChatThreadListStatus.accessDenied);
    await tester.pumpWidget(list(authority));
    await _pumpUntil(
        tester, () => find.text('Canonical launch').evaluate().isNotEmpty);
    await tester.pumpWidget(const SizedBox());
    expect(controller.state.status, isNot(ChatThreadListStatus.disposed));
    await tester.runAsync(controller.dispose);
  });
}

class _DiscoveryTransport extends _NamedThreadTransport {
  _DiscoveryTransport({super.saved});
  bool more = false,
      failList = false,
      denyList = false,
      supported = true,
      empty = false,
      deletedRoot = false,
      openRequested = false;
  Completer<HandrailChatHttpResponse>? pendingList, pendingOpen;
  List<HandrailChatHttpRequest> get listReads => requests
      .where((r) => r.method == 'GET' && r.uri.path.endsWith('/threads'))
      .toList();

  Map<String, Object?> row({bool second = false}) {
    final id = second ? 'thread-second' : _thread.value;
    final body = threadCreationResultFixture('existing_for_root',
        parentConversationId: _alpha.value,
        rootMessageId: second ? 'root-second' : _root.value,
        threadId: id,
        summaryThreadId: id);
    final summary = Map<String, Object?>.from(
        (body['conversation'] as Map)['conversation'] as Map)
      ..remove('memberUserIds');
    if (!second) summary['name'] = 'Canonical launch';
    summary['latestSequence'] = second ? 0 : 3;
    summary['createdAt'] = _now;
    summary['updatedAt'] = _now;
    summary['activityAt'] = _now;
    (summary['currentReadState'] as Map)['lastReadSequence'] = 0;
    if (supported)
      summary['threadLifecycle'] = {'revision': 1, 'locked': false};
    return {
      'thread': summary,
      'currentThreadFollow': {
        'followRevision': second ? 1 : 0,
        'follow': second
            ? {
                'target': {'type': 'thread', 'id': id},
                'isFollowing': true,
                'source': 'manual',
                'updatedAt': _now,
              }
            : null
      },
      'lastActivityAt': _now,
      'hideAt': null
    };
  }

  Map<String, Object?> page(String view, {bool second = false}) => {
        'parentConversationId': _alpha.value,
        'view': view,
        'evaluatedAt': _now,
        'lifecycleSupported': supported,
        'inactivityPolicy': false,
        'items': empty ? [] : [row(second: second)],
        if (more && !second)
          'nextCursor': encodeThreadListCursor(ThreadListCursorPosition(
              parentConversationId: _alpha,
              view: view,
              createdAt: const IsoTimestamp(_now),
              threadId: _thread)),
      };

  Future<HandrailChatHttpResponse> detail() =>
      super.send(HandrailChatHttpRequest(
          method: 'GET',
          uri: Uri.parse(
              'https://chat.example.test/api/chat/conversations/thread-alpha'),
          headers: {}));

  @override
  Future<HandrailChatHttpResponse> send(HandrailChatHttpRequest request) async {
    if (request.method == 'GET' && request.uri.path.endsWith('/threads')) {
      requests.add(request);
      if (denyList) return _jsonResponse({}, statusCode: 403);
      if (failList) return _jsonResponse({}, statusCode: 503);
      if (pendingList != null) return pendingList!.future;
      final value = page(request.uri.queryParameters['view'] ?? 'active',
          second: request.uri.queryParameters.containsKey('cursor'));
      ThreadListResult.fromJson(value,
          expectedRequest: ThreadListRequest(
              parentConversationId: _alpha,
              view: request.uri.queryParameters['view'] ?? 'active',
              limit: int.parse(request.uri.queryParameters['limit'] ?? '50'),
              cursor: request.uri.queryParameters['cursor']));
      return _jsonResponse(value);
    }
    if (pendingOpen != null &&
        request.method == 'GET' &&
        request.uri.path.endsWith('/conversations/thread-alpha')) {
      requests.add(request);
      openRequested = true;
      return pendingOpen!.future;
    }
    final result = await super.send(request);
    if (deletedRoot &&
        request.uri.path.endsWith('/conversations/alpha/messages')) {
      final body = jsonDecode(result.body) as Map<String, dynamic>;
      final message = (body['messages'] as List).first as Map;
      message['content'] = null;
      message['deletedAt'] = _now;
      message['deletedByUserId'] = _user;
      message['revision'] = {'revision': 2};
      return _jsonResponse(body);
    }
    return result;
  }
}
