part of 'handrail_chat_workspace_test.dart';

// These cases share the existing deterministic workspace/client HTTP boundary.
void replyRoutingTests() {
  testWidgets(
      'reply routing unknown capability updates and detaches on client rebinding',
      (tester) async {
    final http = _ReplyRoutingTransport();
    final client = await _replyClient(tester, http, initialize: false);
    client.replyStyles.configure(
        const ChatReplyStyleConfiguration(override: ReplyStyle.discord));
    final next =
        await _replyClient(tester, _ReplyRoutingTransport(saved: 'current'));
    final timelineKey = GlobalKey();
    Future<void> mount(HandrailChatClient value) async {
      await tester.pumpWidget(MaterialApp(
          home: ChatScope(
              key: ObjectKey(value),
              client: value,
              child: Scaffold(
                  body: HandrailMessageTimeline(
                      key: timelineKey,
                      conversationId: _alpha,
                      onReplyRequested: (_) => true)))));
      await _pumpUntil(
          tester,
          () => find
              .byKey(const ValueKey('handrail-reply-root-alpha'))
              .evaluate()
              .isNotEmpty);
    }

    await mount(client);
    final reply = find.byKey(const ValueKey('handrail-reply-root-alpha'));
    expect(tester.widget<TextButton>(reply).onPressed, isNull);
    expect(
        find.textContaining('Inline replies are unavailable'), findsOneWidget);
    await tester.runAsync(client.initialize);
    await tester.pump();
    expect(tester.widget<TextButton>(reply).onPressed, isNotNull);
    await mount(next);
    client.replyStyles.configure(
        const ChatReplyStyleConfiguration(override: ReplyStyle.current));
    client.replyStyles.configure(
        const ChatReplyStyleConfiguration(override: ReplyStyle.discord));
    await tester.pump();
    await tester.tap(reply);
    await _pumpUntil(
        tester,
        () => (next.transport as _ReplyRoutingTransport)
            .threadRequests
            .isNotEmpty);
    await tester.pumpWidget(const SizedBox());
    expect(client.replyStyles.state.isDisposed, isFalse);
    expect(next.replyStyles.state.isDisposed, isFalse);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
      'reply routing excludes pending and deleted sources including an open menu',
      (tester) async {
    final http = _ReplyRoutingTransport(summary: true);
    final client = await _replyClient(tester, http);
    await _mountReplyWorkspace(tester, client);
    final pending = Map<String, Object?>.from(
        (_timelinePage(_alpha)['messages'] as List).first as Map);
    pending['id'] = 'pending';
    pending['sequence'] = 2;
    pending.remove('threadSummary');
    pending['isThreadRoot'] = false;
    client.normalizedState.beginOptimisticMessageSend(
        clientMessageId: 'pending',
        projection: MessageTimelineMessage.fromJson(pending));
    await tester.pump();
    expect(find.byKey(const ValueKey('handrail-reply-pending')), findsNothing);
    await tester
        .longPress(find.byKey(const ValueKey('handrail-reply-root-alpha')));
    await tester.pumpAndSettle();
    http.deleted = true;
    await tester
        .runAsync(() => client.timelines.forConversation(_alpha).refresh());
    await tester.pump();
    await tester.tap(find.widgetWithText(ListTile, 'Reply'));
    await tester.pumpAndSettle();
    expect(
        find.byKey(const ValueKey('handrail-reply-root-alpha')), findsNothing);
    expect(find.byKey(const ValueKey('handrail-thread-root-alpha')),
        findsOneWidget);
    expect(
        tester
            .state<HandrailMessageComposerState>(
                find.byType(HandrailMessageComposer))
            .replyTo,
        isNull);
    expect(http.threadRequests, isEmpty);
  });

  for (final type in ['channel', 'direct', 'group_direct']) {
    for (final summary in [false, true]) {
      testWidgets('reply routing $type summary=$summary sends Friday in place',
          (tester) async {
        final http = _ReplyRoutingTransport(type: type, summary: summary);
        final client = await _replyClient(tester, http);
        await _mountReplyWorkspace(tester, client);
        final composer = tester.state<HandrailMessageComposerState>(
            find.byType(HandrailMessageComposer));
        final source = client.messageContexts.forMessage(
            MessageContextRequest(conversationId: _alpha, messageId: _root));
        final authority = source.state;
        await tester
            .tap(find.byKey(const ValueKey('handrail-reply-root-alpha')));
        await tester.pump();
        expect(composer.replyTo!.messageId, _root);
        expect(source.state.status, authority.status);
        expect(source.state.source, isNull);
        expect(
            _primaryFocusIsWithin(tester,
                find.byKey(const ValueKey('handrail-message-composer-input'))),
            isTrue);
        if (summary) {
          expect(find.byKey(const ValueKey('handrail-thread-root-alpha')),
              findsOneWidget);
        }
        await _sendFriday(tester, http, _alpha, _root);
        expect(http.threadRequests, isEmpty);
        expect(find.byType(HandrailThreadView), findsNothing);
        expect(
            client.conversations
                .forConversation(_alpha)
                .state
                .conversation!
                .type
                .wireValue,
            type);
      });
    }
  }

  testWidgets('reply routing existing thread uses its own composer and ID',
      (tester) async {
    final http = _ReplyRoutingTransport(summary: true);
    final client = await _replyClient(tester, http);
    await _mountReplyWorkspace(tester, client);
    await tester.tap(find.byKey(const ValueKey('handrail-thread-root-alpha')));
    await _pumpUntil(
        tester,
        () => find
            .byKey(const ValueKey('handrail-reply-thread-reply'))
            .evaluate()
            .isNotEmpty);
    final view =
        tester.widget<HandrailThreadView>(find.byType(HandrailThreadView));
    final handle = view.openHandle!;
    final requestsBefore = http.threadRequests.length;
    await tester.tap(find.byKey(const ValueKey('handrail-reply-thread-reply')));
    await tester.pump();
    final threadComposer = find.descendant(
        of: find.byType(HandrailThreadView),
        matching: find.byType(HandrailMessageComposer));
    final state = tester.state<HandrailMessageComposerState>(threadComposer);
    expect(state.replyTo!.messageId, const MessageId('thread-reply'));
    state.setReplyNotifyAuthor(false);
    await tester.pump();
    await captureWidgetEvidence(tester, 'discord-thread-reply-widget.png');
    client.replyStyles.configure(
        const ChatReplyStyleConfiguration(override: ReplyStyle.current));
    await tester.pump();
    expect(
        identical(
            handle,
            tester
                .widget<HandrailThreadView>(find.byType(HandrailThreadView))
                .openHandle),
        isTrue);
    expect(handle.isReleased, isFalse);
    expect(identical(state, tester.state(threadComposer)), isTrue);
    await tester.tap(find.byKey(const ValueKey('handrail-reply-thread-reply')));
    await tester.pump();
    expect(state.replyTo!.messageId, const MessageId('thread-reply'));
    expect(state.replyTo!.notifyAuthor, isFalse);
    await _sendFriday(tester, http, _thread, const MessageId('thread-reply'),
        within: find.byType(HandrailThreadView), notify: false);
    expect(http.threadRequests, hasLength(requestsBefore));
  });

  for (final saved in [null, 'current']) {
    for (final inline in [false, true]) {
      testWidgets(
          'reply routing Current in thread saved=$saved inline=$inline keeps composition',
          (tester) async {
        final http =
            _ReplyRoutingTransport(saved: saved, inline: inline, summary: true);
        final client = await _replyClient(tester, http);
        await _mountReplyWorkspace(tester, client);
        await tester
            .tap(find.byKey(const ValueKey('handrail-thread-root-alpha')));
        final reply = find.byKey(const ValueKey('handrail-reply-thread-reply'));
        await _pumpUntil(tester, () => reply.evaluate().isNotEmpty);
        final view = find.byType(HandrailThreadView);
        final handle = tester.widget<HandrailThreadView>(view).openHandle!;
        final composer = find.descendant(
            of: view, matching: find.byType(HandrailMessageComposer));
        final state = tester.state<HandrailMessageComposerState>(composer);
        final input = find.descendant(
            of: view,
            matching:
                find.byKey(const ValueKey('handrail-message-composer-input')));
        final send = find.descendant(
            of: view,
            matching:
                find.byKey(const ValueKey('handrail-message-composer-send')));
        await tester.enterText(input, 'Friday');
        tester.widget<TextField>(input).focusNode!.unfocus();
        await tester.pump();
        final requestsBefore = http.threadRequests.length;
        await tester.tap(reply);
        await tester.pump();
        expect(tester.widget<TextField>(input).focusNode!.hasFocus, isTrue);
        expect(tester.widget<TextField>(input).controller!.text, 'Friday');
        expect(identical(state, tester.state(composer)), isTrue);
        expect(state.replyTo, isNull);
        expect(
            identical(
                handle, tester.widget<HandrailThreadView>(view).openHandle),
            isTrue);
        expect(handle.isReleased, isFalse);
        expect(http.threadRequests, hasLength(requestsBefore));
        if (saved == 'current' && !inline) {
          await captureWidgetEvidence(
              tester, 'current-thread-reply-widget.png');
        }
        await tester.tap(send);
        await _pumpUntil(
            tester,
            () =>
                http.sends.isNotEmpty &&
                tester.widget<TextField>(input).controller!.text.isEmpty);
        expect(http.sends.single['conversationId'], _thread.value);
        expect(http.sends.single.containsKey('replyTo'), isFalse);
        expect((http.sends.single['content'] as Map)['text'], 'Friday');
        expect(http.threadRequests, hasLength(requestsBefore));
      });
    }
  }

  testWidgets(
      'reply routing Current standalone thread never creates a nested thread',
      (tester) async {
    final http = _ReplyRoutingTransport(saved: 'current', summary: true);
    final client = await _replyClient(tester, http);
    await _mountReplyWorkspace(tester, client);
    await tester.tap(find.byKey(const ValueKey('handrail-thread-root-alpha')));
    final reply = find.byKey(const ValueKey('handrail-reply-thread-reply'));
    await _pumpUntil(tester, () => reply.evaluate().isNotEmpty);
    final requestsBefore = http.threadRequests.length;
    await tester.pumpWidget(MaterialApp(
        home: Scaffold(
            body: HandrailMessageTimeline(
                conversationId: _thread,
                reads: client.reads,
                controller: client.timelines.forConversation(_thread)))));
    await _pumpUntil(tester, () => reply.evaluate().isNotEmpty);
    await tester.tap(reply);
    await tester.pump();
    expect(find.text('The thread composer cannot accept a reply right now.'),
        findsOneWidget);
    expect(http.threadRequests, hasLength(requestsBefore));
    expect(http.sends, isEmpty);
  });

  for (final saved in [null, 'current']) {
    testWidgets('reply routing Current saved=$saved retains thread behavior',
        (tester) async {
      final http = _ReplyRoutingTransport(saved: saved);
      final client = await _replyClient(tester, http);
      await _mountReplyWorkspace(tester, client);
      expect(client.replyStyles.state.effectiveStyle, ReplyStyle.current);
      await tester.tap(find.byKey(const ValueKey('handrail-reply-root-alpha')));
      await _pumpUntil(
          tester, () => find.byType(HandrailThreadView).evaluate().isNotEmpty);
      expect(http.threadRequests, hasLength(1));
      expect(http.sends, isEmpty);
    });
  }

  testWidgets(
      'reply routing absent preference API still allows supported inline replies',
      (tester) async {
    final http = _ReplyRoutingTransport(preferences: false);
    final client = await _replyClient(tester, http);
    client.replyStyles.configure(
        const ChatReplyStyleConfiguration(defaultStyle: ReplyStyle.discord));
    await _mountReplyWorkspace(tester, client);
    await tester.tap(find.byKey(const ValueKey('handrail-reply-root-alpha')));
    await _sendFriday(tester, http, _alpha, _root);
    expect(http.threadRequests, isEmpty);
  });

  testWidgets(
      'reply routing missing capability disables without thread fallback',
      (tester) async {
    final http = _ReplyRoutingTransport(inline: false);
    final client = await _replyClient(tester, http);
    await _mountReplyWorkspace(tester, client);
    expect(
        tester
            .widget<TextButton>(
                find.byKey(const ValueKey('handrail-reply-root-alpha')))
            .onPressed,
        isNull);
    expect(
        find.textContaining('Inline replies are unavailable'), findsOneWidget);
    expect(http.threadRequests, isEmpty);
  });

  testWidgets(
      'reply routing keyboard and long press retain composition across styles',
      (tester) async {
    final http = _ReplyRoutingTransport();
    final client = await _replyClient(tester, http);
    await _mountReplyWorkspace(tester, client);
    final reply = find.byKey(const ValueKey('handrail-reply-root-alpha'));
    final semantics = tester.ensureSemantics();
    expect(tester.getSemantics(reply).getSemanticsData().label, 'Reply');
    final focus = Focus.of(tester
        .element(find.descendant(of: reply, matching: find.text('Reply'))));
    focus.requestFocus();
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pump();
    final state = tester.state<HandrailMessageComposerState>(
        find.byType(HandrailMessageComposer));
    expect(state.replyTo!.messageId, _root);
    state.cancelReply();
    await tester.longPress(reply);
    await tester.pumpAndSettle();
    expect(find.byType(BottomSheet), findsOneWidget);
    await tester.tap(find.widgetWithText(ListTile, 'Reply'));
    await tester.pumpAndSettle();
    expect(state.replyTo!.messageId, _root);
    state.setReplyNotifyAuthor(false);
    await tester.enterText(
        find.byKey(const ValueKey('handrail-message-composer-input')),
        'Friday');
    for (final value in [ReplyStyle.current, ReplyStyle.discord]) {
      client.replyStyles
          .configure(ChatReplyStyleConfiguration(override: value));
      await tester.pump();
      expect(
          identical(state, tester.state(find.byType(HandrailMessageComposer))),
          isTrue);
      expect(state.replyTo!.notifyAuthor, isFalse);
      expect(
          tester
              .widget<TextField>(
                  find.byKey(const ValueKey('handrail-message-composer-input')))
              .controller!
              .text,
          'Friday');
    }
    await _sendFriday(tester, http, _alpha, _root, notify: false);
    expect(http.threadRequests, isEmpty);
    semantics.dispose();
  });

  testWidgets(
      'reply routing no handler and rejecting handler explain unavailable composer',
      (tester) async {
    final http = _ReplyRoutingTransport();
    final client = await _replyClient(tester, http);
    Future<void> mount(HandrailReplyRequested? handler) async {
      await tester.pumpWidget(MaterialApp(
          home: ChatScope(
              client: client,
              child: Scaffold(
                  body: HandrailMessageTimeline(
                      conversationId: _alpha, onReplyRequested: handler)))));
      await _pumpUntil(
          tester,
          () => find
              .byKey(const ValueKey('handrail-reply-root-alpha'))
              .evaluate()
              .isNotEmpty);
    }

    await mount(null);
    expect(find.text('Inline replies require a composer reply handler.'),
        findsOneWidget);
    expect(
        tester
            .widget<TextButton>(
                find.byKey(const ValueKey('handrail-reply-root-alpha')))
            .onPressed,
        isNull);
    await mount((_) => false);
    await tester.tap(find.byKey(const ValueKey('handrail-reply-root-alpha')));
    await tester.pump();
    expect(find.text('The composer cannot accept a reply right now.'),
        findsOneWidget);
    expect(http.threadRequests, isEmpty);
  });
}

Future<HandrailChatClient> _replyClient(
    WidgetTester tester, _ReplyRoutingTransport http,
    {bool initialize = true}) async {
  tester.view.physicalSize = const Size(1400, 900);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  final client = _client(http, requestedCapabilities: {
    ChatReplyThreadFeatures.inlineReplies: true,
    replyStylePreferenceFeature: true
  });
  addTearDown(() async {
    await tester.pumpWidget(const SizedBox());
    var disposed = false;
    unawaited(client.dispose().then((_) => disposed = true));
    await _pumpUntil(tester, () => disposed);
  });
  if (initialize) await tester.runAsync(client.initialize);
  await tester.runAsync(() => client.replyStyles.activateIdentity(
      const ChatReplyStyleIdentity(
          tenantId: TenantId(_tenant), userId: UserId(_user))));
  final detail = await tester.runAsync(() => http.send(HandrailChatHttpRequest(
      method: 'GET',
      uri: Uri.parse('https://chat.example.test/api/chat/conversations/alpha'),
      headers: {})));
  client.normalizedState.hydrateConversationDetail(
      ConversationDetailSnapshot.fromJson(jsonDecode(detail!.body)));
  return client;
}

Future<void> _mountReplyWorkspace(
    WidgetTester tester, HandrailChatClient client) async {
  await prepareWidgetEvidence(tester);
  await tester.pumpWidget(widgetEvidenceBoundary(_host(client,
      width: 1100,
      child: const HandrailChatWorkspace(initialConversationId: _alpha))));
  await _pumpUntil(
      tester,
      () =>
          find.text('Which launch date?').evaluate().isNotEmpty &&
          (tester
                  .widget<TextField>(find
                      .byKey(const ValueKey('handrail-message-composer-input')))
                  .enabled ??
              false),
      diagnostic: () =>
          'texts=${tester.widgetList<Text>(find.byType(Text)).map((t) => t.data ?? t.textSpan?.toPlainText()).toList()} style=${client.replyStyles.state.effectiveStyle} conversation=${client.conversations.forConversation(_alpha).state.status} error=${client.conversations.forConversation(_alpha).state.error?.code} timeline=${client.timelines.forConversation(_alpha).state.status}');
}

Future<void> _sendFriday(WidgetTester tester, _ReplyRoutingTransport http,
    ConversationId destination, MessageId source,
    {Finder? within, bool notify = true}) async {
  Finder control(String name) {
    final found = find.byKey(ValueKey('handrail-message-composer-$name'));
    return within == null
        ? found
        : find.descendant(of: within, matching: found);
  }

  await tester.enterText(control('input'), 'Friday');
  await tester.pump();
  await tester.tap(control('send'));
  await _pumpUntil(
      tester,
      () =>
          http.sends.isNotEmpty &&
          tester.widget<TextField>(control('input')).controller!.text.isEmpty);
  final send = http.sends.single;
  expect(send['conversationId'], destination.value);
  expect(send['replyTo'], {'messageId': source.value, 'notifyAuthor': notify});
  expect((send['content'] as Map)['text'], 'Friday');
}

class _ReplyRoutingTransport extends _WorkspaceTransport {
  _ReplyRoutingTransport(
      {this.type = 'channel',
      this.saved = 'discord',
      bool inline = true,
      bool preferences = true,
      bool summary = false})
      : super(
            includeThreadSummary: summary,
            enabledFeatures: {
              replyStylePreferenceFeature: preferences,
              ChatReplyThreadFeatures.inlineReplies: inline,
            },
            listResponses: Queue.of([
              _jsonResponse(jsonDecode(jsonEncode(_listPage())
                  .replaceAll(conversationListTestTenant, _tenant)
                  .replaceAll(conversationListTestUser, _user)))
            ]));
  bool deleted = false;
  final String type;
  final String? saved;
  final List<Map<String, Object?>> sends = [];
  List<HandrailChatHttpRequest> get threadRequests => requests
      .where((r) =>
          r.method != 'GET' &&
          (r.uri.path.endsWith('/thread') || r.uri.path.endsWith('/threads')))
      .toList();

  @override
  Future<HandrailChatHttpResponse> send(HandrailChatHttpRequest request) async {
    if (request.uri.path.endsWith('/preferences/reply-style')) {
      requests.add(request);
      return style
          .response(saved == null ? style.absent : style.saved(1, saved!));
    }
    if (request.method != 'GET' && request.body != null) {
      final body = _requestBody(request);
      if (body['operation'] == 'synchronize_draft') {
        requests.add(request);
        return _jsonResponse(settledDraftResultFixture(body));
      }
      if (body['operation'] == 'send') {
        requests.add(request);
        sends.add(body);
        return _jsonResponse({
          'operation': 'send',
          'reconciliationStatus': 'applied',
          'clientMessageId': body['clientMessageId'],
          'canonicalRevision': 1,
          'message': {
            'id': 'bob-friday',
            'tenantId': _tenant,
            'conversationId': body['conversationId'],
            'author': {'type': 'user', 'userId': _user},
            'sequence': 2,
            'createdAt': _now,
            'updatedAt': _now,
            'revision': {'revision': 1},
            'content': body['content'],
            if (body.containsKey('replyTo')) 'replyTo': body['replyTo']
          },
        });
      }
    }
    final response = await super.send(request);
    if (request.method != 'GET' || response.statusCode != 200) return response;
    final body = jsonDecode(response.body) as Map<String, dynamic>;
    if (request.uri.path.endsWith('/messages')) {
      final message = (body['messages'] as List).first as Map<String, dynamic>;
      message['author'] = {'type': 'user', 'userId': 'alice'};
      if (deleted) {
        message['content'] = null;
        message['deletedAt'] = _now;
        message['deletedByUserId'] = _user;
        message['revision'] = {'revision': 2};
      }
      if (!deleted && message['id'] == _root.value) {
        message['content'] = {'format': 'plain', 'text': 'Which launch date?'};
      }
    } else if (request.uri.path.endsWith('/conversations/alpha')) {
      final conversation = body['conversation'] as Map<String, dynamic>;
      conversation['type'] = type;
      if (type != 'channel') {
        conversation.remove('name');
        conversation['visibility'] = 'private';
        conversation['memberUserIds'] = [
          _user,
          'alice',
          if (type == 'group_direct') 'carol'
        ];
        conversation['activeMemberUserIds'] = conversation['memberUserIds'];
      }
    } else if (request.uri.path.endsWith('/conversations/thread-alpha')) {
      return _jsonResponse(threadCreationResultFixture('existing_for_root',
          parentConversationId: _alpha.value,
          rootMessageId: _root.value,
          threadId: _thread.value,
          summaryThreadId: _thread.value)['conversation']);
    }
    return _jsonResponse(body);
  }
}
