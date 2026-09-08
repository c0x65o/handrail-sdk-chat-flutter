part of 'handrail_thread_view_test.dart';

void _subscriptionTests() {
  for (final style in [null, ReplyStyle.current, ReplyStyle.discord]) {
    testWidgets('subscriptions map follow and unfollow for style $style',
        (tester) async {
      final harness = _Harness(existingThread: true);
      addTearDown(() => _disposeLifecycleHarness(tester, harness));
      await _prepareLifecycle(tester, harness);
      if (style != null)
        harness.client.replyStyles
            .configure(ChatReplyStyleConfiguration(override: style));
      await _mountLifecycle(tester, harness, onClose: () {});
      final composer = tester.state(find.byType(HandrailMessageComposer));
      await _subscriptionChoose(
          tester, style == ReplyStyle.discord ? 'Join' : 'Follow');
      expect(
          harness.client.threads
              .forThread(_threadId)
              .state
              .authoritativeFollow
              ?.isFollowing,
          isTrue);
      await _subscriptionChoose(
          tester, style == ReplyStyle.discord ? 'Leave' : 'Unfollow');
      expect(
          harness.transport.subscriptionWrites
              .map((r) => jsonDecode(r.body!)['intent']),
          ['follow', 'unfollow']);
      for (final request in harness.transport.subscriptionWrites) {
        expect(jsonDecode(request.body!)['target'],
            {'type': 'thread', 'id': _threadId.value});
      }
      expect(
          harness.client.threads
              .forThread(_threadId)
              .state
              .authoritativeFollow
              ?.isFollowing,
          isFalse);
      expect(
          tester.state(find.byType(HandrailMessageComposer)), same(composer));
      expect(find.byTooltip('Shared thread controls'), findsOneWidget);
      expect(find.byTooltip('Close panel'), findsOneWidget);
      expect(harness.transport.lifecycleWrites, isEmpty);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets(
      'subscriptions independently save every notification and mute choice retaining stars',
      (tester) async {
    final harness = _Harness(existingThread: true);
    addTearDown(() => _disposeLifecycleHarness(tester, harness));
    await _prepareLifecycle(tester, harness);
    await _mountLifecycle(tester, harness);
    _seedSubscriptionPreference(harness,
        starred: true,
        mute: {'muted': true, 'mutedUntil': '2030-02-03T04:05:06.000Z'});
    await tester.pump();
    for (final notification in ['mentions', 'none', 'all']) {
      await _subscriptionChoose(tester, 'Notifications: $notification');
      final body = jsonDecode(harness.transport.subscriptionWrites.last.body!);
      expect(body['notificationPreference'], notification);
      expect(body['isStarred'], isTrue);
      expect(body['mute'],
          {'muted': true, 'mutedUntil': '2030-02-03T04:05:06.000Z'});
    }
    for (final label in ['Unmute', 'Mute indefinitely', 'Mute for 1 hour']) {
      final before = DateTime.now().toUtc();
      await _subscriptionChoose(tester, label);
      final body = jsonDecode(harness.transport.subscriptionWrites.last.body!);
      expect(body['notificationPreference'], 'all');
      expect(body['isStarred'], isTrue);
      if (label == 'Unmute') expect(body['mute'], {'muted': false});
      if (label == 'Mute indefinitely') expect(body['mute'], {'muted': true});
      if (label == 'Mute for 1 hour') {
        expect(body['mute']['muted'], isTrue);
        final until = DateTime.parse(body['mute']['mutedUntil'] as String);
        expect(until.difference(before).inMinutes, inInclusiveRange(59, 60));
      }
    }
    expect(harness.transport.subscriptionWrites, hasLength(6));
    expect(
        harness.transport.subscriptionWrites
            .every((r) => r.uri.path.endsWith('/preference')),
        isTrue);
  });

  testWidgets(
      'subscriptions failed Leave retries at compact width retaining draft read and open state',
      (tester) async {
    final harness = _Harness(existingThread: true);
    addTearDown(() => _disposeLifecycleHarness(tester, harness));
    await _prepareLifecycle(tester, harness);
    harness.client.replyStyles.configure(
        const ChatReplyStyleConfiguration(override: ReplyStyle.discord));
    await tester
        .runAsync(() => harness.client.threads.forThread(_threadId).follow());
    _seedSubscriptionDraft(harness);
    final handle = (await harness.client.threads.open(rootMessageId: _rootId)
            as ChatThreadOpenSuccess)
        .handle;
    addTearDown(handle.release);
    var closed = 0;
    await _mountLifecycle(tester, harness,
        width: 240, handle: handle, onClose: () => closed++);
    final composer = tester.state<HandrailMessageComposerState>(
        find.byType(HandrailMessageComposer));
    final draft =
        harness.client.conversations.forConversation(_threadId).state.draft;
    final cursor = ConversationReadState.fromJson({
      ...harness.store.state.currentUserReadStates[_threadId]!.toJson(),
      'manualUnreadFromSequence': 1,
    });
    harness.store
        .projectCurrentUserReadState(cursor, authoritativeReadState: cursor);
    await tester.pump();
    final read = harness.store.state.currentUserReadStates[_threadId]!.toJson();
    final unread =
        selectConversationUnreadCount(harness.store.state, _threadId);
    expect(unread, greaterThan(0));
    expect(selectManualUnreadFromSequence(harness.store.state, _threadId),
        const MessageSequence(1));
    final preference = harness.store
        .conversationPreference(_threadId)
        .authoritativePreference!
        .toJson();
    final pending = Completer<HandrailChatHttpResponse>();
    harness.transport.subscriptionWrite = (_) => pending.future;
    final semantics = tester.ensureSemantics();
    final focus =
        Focus.of(tester.element(find.byIcon(Icons.notifications_outlined)));
    focus.requestFocus();
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await _settleLifecycle(tester);
    expect(find.bySemanticsLabel('Leave'), findsOneWidget);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await _settleLifecycle(tester);
    expect(
        find.bySemanticsLabel('Saving thread subscription…'), findsOneWidget);
    await _subscriptionMenu(tester);
    final leave = tester.widget<PopupMenuItem<dynamic>>(find
        .ancestor(
            of: find.text('Leave'),
            matching: find.byWidgetPredicate((w) => w is PopupMenuItem))
        .first);
    expect(leave.enabled, isFalse);
    expect(find.text('Join'),
        findsNothing); // Optimistic unfollow is not confirmed.
    await tester.tap(find.text('Leave'), warnIfMissed: false);
    expect(harness.transport.subscriptionWrites, hasLength(2));
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await _settleLifecycle(tester);
    pending
        .complete(const HandrailChatHttpResponse(statusCode: 500, body: '{}'));
    await _settleLifecycle(tester);
    expect(find.textContaining('Subscription change failed'), findsOneWidget);
    harness.transport.subscriptionWrite = null;
    await _subscriptionChoose(tester, 'Retry subscription change');
    expect(
        harness.transport.subscriptionWrites
            .map((r) => jsonDecode(r.body!)['intent']),
        ['follow', 'unfollow', 'unfollow']);
    expect(focus.hasFocus, isTrue);
    expect(
        harness.client.threads
            .forThread(_threadId)
            .state
            .authoritativeFollow
            ?.isFollowing,
        isFalse);
    expect(_draftText(tester), 'Retained Friday');
    expect(tester.state(find.byType(HandrailMessageComposer)), same(composer));
    expect(harness.client.conversations.forConversation(_threadId).state.draft,
        same(draft));
    expect(
        harness.store.state.currentUserReadStates[_threadId]!.toJson(), read);
    expect(
        selectConversationUnreadCount(harness.store.state, _threadId), unread);
    expect(
        harness.store
            .conversationPreference(_threadId)
            .authoritativePreference!
            .toJson(),
        preference);
    expect(handle.isReleased, isFalse);
    expect(closed, 0);
    expect(find.byKey(const ValueKey('handrail-thread-root-context')),
        findsOneWidget);
    expect(
        tester
            .widget<HandrailMessageComposer>(
                find.byType(HandrailMessageComposer))
            .conversationId,
        _threadId);
    expect(
        harness.transport.requests
            .where((r) => r.method != 'GET' && !r.uri.path.endsWith('/follow')),
        isEmpty);
    expect(find.byTooltip('Close panel'), findsOneWidget);
    expect(find.byTooltip('Shared thread controls'), findsOneWidget);
    expect(tester.takeException(), isNull);
    semantics.dispose();
  });

  testWidgets(
      'subscriptions reconcile preference conflict and explicitly retry only the selected field',
      (tester) async {
    final harness = _Harness(existingThread: true);
    addTearDown(() => _disposeLifecycleHarness(tester, harness));
    await _prepareLifecycle(tester, harness);
    await _mountLifecycle(tester, harness);
    final pending = Completer<HandrailChatHttpResponse>();
    harness.transport.subscriptionWrite = (_) => pending.future;
    await _subscriptionChoose(tester, 'Notifications: none');
    expect(
        find.bySemanticsLabel('Saving thread subscription…'), findsOneWidget);
    await _subscriptionMenu(tester);
    final all = tester.widget<PopupMenuItem<dynamic>>(find
        .ancestor(
            of: find.text('Notifications: all'),
            matching: find.byWidgetPredicate((w) => w is PopupMenuItem))
        .first);
    expect(all.enabled, isFalse);
    expect(
        find.descendant(
            of: find.byWidget(all),
            matching: find.byWidgetPredicate(
                (w) => w is Semantics && w.properties.selected == true)),
        findsOneWidget);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await _settleLifecycle(tester);
    final request =
        jsonDecode(harness.transport.subscriptionWrites.single.body!)
            as Map<String, dynamic>;
    pending
        .complete(_lifecycleResponse(conflictingPreferenceResult(request, 4)));
    await _settleLifecycle(tester);
    expect(
        find.textContaining('Subscription changed elsewhere'), findsOneWidget);
    expect(harness.transport.subscriptionWrites, hasLength(1));
    expect(
        harness.store
            .conversationPreference(_threadId)
            .authoritativePreference!
            .notificationPreference,
        'all');
    _seedSubscriptionPreference(harness, starred: true, mute: {'muted': true});
    harness.transport.subscriptionWrite = null;
    await _subscriptionChoose(tester, 'Retry subscription change');
    final retried = jsonDecode(harness.transport.subscriptionWrites.last.body!);
    expect(retried['notificationPreference'], 'none');
    expect(retried['mute'], {'muted': true});
    expect(retried['isStarred'], isTrue);
    expect(retried['expectedPreferenceRevision'], 5);
    expect(retried['idempotencyKey'], isNot(request['idempotencyKey']));
    expect(harness.store.conversationPreference(_threadId).isPending, isFalse);
  });

  testWidgets(
      'subscriptions follow conflict requires explicit retry and style changes preserve the open composer',
      (tester) async {
    final harness = _Harness(existingThread: true);
    addTearDown(() => _disposeLifecycleHarness(tester, harness));
    await _prepareLifecycle(tester, harness);
    await _mountLifecycle(tester, harness);
    await tester.enterText(find.byKey(_composerInput), 'Same thread');
    final composer = tester.state(find.byType(HandrailMessageComposer));
    harness.transport.subscriptionWrite = (request) async => _lifecycleResponse(
        conflictingThreadFollowResultFixture(
            jsonDecode(request.body!) as Map<String, dynamic>, 4));
    await _subscriptionChoose(tester, 'Follow');
    expect(
        find.textContaining('Subscription changed elsewhere'), findsOneWidget);
    expect(harness.transport.subscriptionWrites, hasLength(1));
    harness.client.replyStyles.configure(
        const ChatReplyStyleConfiguration(override: ReplyStyle.discord));
    await tester.pump();
    await _subscriptionMenu(tester);
    expect(find.text('Join'), findsOneWidget);
    expect(find.text('Follow'), findsNothing);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await _settleLifecycle(tester);
    harness.transport.subscriptionWrite = null;
    await _subscriptionChoose(tester, 'Retry subscription change');
    expect(
        jsonDecode(harness.transport.subscriptionWrites.last.body!)[
            'expectedFollowRevision'],
        4);
    expect(
        harness.client.threads
            .forThread(_threadId)
            .state
            .authoritativeFollow
            ?.isFollowing,
        isTrue);
    expect(tester.state(find.byType(HandrailMessageComposer)), same(composer));
    expect(_draftText(tester), 'Same thread');
  });

  testWidgets(
      'subscriptions unavailable canonical preferences load and retry without invented defaults',
      (tester) async {
    final harness = _Harness(existingThread: true);
    addTearDown(() => _disposeLifecycleHarness(tester, harness));
    await _prepareLifecycle(tester, harness);
    await _mountLifecycle(tester, harness);
    // A recovered cache can lack canonical private state while a caller still
    // retains the open handle. Do not invent replacement preferences.
    harness.transport.lifecycleRead =
        () async => const HandrailChatHttpResponse(statusCode: 500, body: '{}');
    harness.store.installPersistedSnapshot(NormalizedSnapshotState.empty());
    await _settleLifecycle(tester);
    expect(
        harness.store.conversationPreference(_threadId).authoritativePreference,
        isNull,
        reason: '${harness.transport.requests.map((r) => r.uri.path)}');
    expect(
        find.textContaining('Thread preferences unavailable'), findsOneWidget);
    await _subscriptionMenu(tester);
    final notification = tester.widget<PopupMenuItem<dynamic>>(find
        .ancestor(
            of: find.text('Notifications: all'),
            matching: find.byWidgetPredicate((w) => w is PopupMenuItem))
        .first);
    expect(notification.enabled, isFalse);
    final pending = Completer<HandrailChatHttpResponse>();
    harness.transport.lifecycleRead = () => pending.future;
    await tester.tap(find.text('Retry loading subscriptions'));
    await _settleLifecycle(tester);
    expect(
        find.bySemanticsLabel('Loading thread subscriptions…'), findsOneWidget);
    pending
        .complete(const HandrailChatHttpResponse(statusCode: 500, body: '{}'));
    await _settleLifecycle(tester);
    expect(
        find.textContaining('Thread preferences unavailable'), findsOneWidget);
    expect(harness.transport.subscriptionWrites, isEmpty);
    harness.transport.lifecycleRead = null;
    await _subscriptionChoose(tester, 'Retry loading subscriptions');
    expect(
        harness.store.conversationPreference(_threadId).authoritativePreference,
        isNotNull);
    expect(find.textContaining('Notifications: all'), findsOneWidget);
    harness.transport.subscriptionWrite = (_) async =>
        const HandrailChatHttpResponse(statusCode: 500, body: '{}');
    await _subscriptionChoose(tester, 'Mute indefinitely');
    expect(find.textContaining('Subscription change failed'), findsOneWidget);
    expect(
        harness.store
            .conversationPreference(_threadId)
            .authoritativePreference!
            .mute
            .muted,
        isFalse);
    harness.transport.subscriptionWrite = null;
    await _subscriptionChoose(tester, 'Retry subscription change');
    expect(
        harness.store
            .conversationPreference(_threadId)
            .authoritativePreference!
            .mute
            .muted,
        isTrue);
  });

  testWidgets(
      'subscriptions ignore stale popup callbacks and late results after scope replacement and disposal',
      (tester) async {
    final first = _Harness(existingThread: true);
    final second = _Harness(existingThread: true);
    addTearDown(() => _disposeLifecycleHarness(tester, first));
    addTearDown(() => _disposeLifecycleHarness(tester, second));
    await _prepareLifecycle(tester, first);
    await _prepareLifecycle(tester, second);
    await _mountLifecycle(tester, first);
    await _subscriptionMenu(tester);
    await _mountLifecycle(tester, second);
    await tester.tap(find.text('Follow'));
    await _settleLifecycle(tester);
    expect(first.transport.subscriptionWrites, isEmpty);
    expect(second.transport.subscriptionWrites, isEmpty);
    final pending = Completer<HandrailChatHttpResponse>();
    second.transport.subscriptionWrite = (_) => pending.future;
    await _subscriptionChoose(tester, 'Follow');
    await _mountLifecycle(tester, first);
    pending
        .complete(const HandrailChatHttpResponse(statusCode: 500, body: '{}'));
    await _settleLifecycle(tester);
    expect(find.textContaining('Subscription change failed'), findsNothing);
    final unmounted = Completer<HandrailChatHttpResponse>();
    first.transport.subscriptionWrite = (_) => unmounted.future;
    await _subscriptionChoose(tester, 'Follow');
    await tester.pumpWidget(const SizedBox());
    unmounted.complete(
        _subscriptionResponse(first.transport.subscriptionWrites.last));
    await _settleLifecycle(tester);
    expect(tester.takeException(), isNull);
    expect(
        first.client.threads
            .forThread(_threadId)
            .state
            .authoritativeFollow
            ?.isFollowing,
        isTrue);
  });
}

Future<void> _subscriptionMenu(WidgetTester tester) async {
  await _settleLifecycle(tester);
  await tester.tap(find.byTooltip('Thread subscriptions'));
  await _settleLifecycle(tester);
}

Future<void> _subscriptionChoose(WidgetTester tester, String label) async {
  await _subscriptionMenu(tester);
  await tester.ensureVisible(find.text(label));
  await tester.tap(find.text(label));
  await _settleLifecycle(tester);
}

HandrailChatHttpResponse _subscriptionResponse(
    HandrailChatHttpRequest request) {
  final input = jsonDecode(request.body!) as Map<String, dynamic>;
  return _lifecycleResponse(request.uri.path.endsWith('/follow')
      ? settledThreadFollowResultFixture(input, 'applied')
      : settledPreferenceResult(input, 'applied'));
}

void _seedSubscriptionPreference(_Harness harness,
    {required bool starred, required Map<String, Object?> mute}) {
  final input = UpdateConversationPreferenceInput.fromJson({
    ...allUnmutedPreferenceInput,
    'conversationId': _threadId.value,
    'expectedPreferenceRevision':
        harness.store.conversationPreference(_threadId).authoritativeRevision,
    'isStarred': starred,
    'mute': mute,
  });
  harness.store.reconcileConversationPreferenceMutation(
      input,
      UpdateConversationPreferenceResult.fromJson(
          settledPreferenceResult(input.toJson(), 'applied'),
          expectedInput: input));
}

void _seedSubscriptionDraft(_Harness harness) {
  final input = <String, Object?>{
    'operation': 'synchronize_draft',
    'intent': 'replace',
    'conversationId': _threadId.value,
    'baseRevision': 0,
    'deviceMutationId': 'seed-subscription',
    'idempotencyKey': 'seed-subscription',
    'content': {
      'format': 'plain',
      'text': 'Retained Friday',
      'attachments': <Object?>[]
    },
  };
  harness.client.reconcileDraftEvent(ConversationDraftUpdatedEvent.fromJson({
    'eventId': 'subscription-draft-seed',
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
