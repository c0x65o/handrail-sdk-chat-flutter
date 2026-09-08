import 'dart:convert';

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:handrail_chat/testing.dart';

const _conversationId = ConversationId('fixture-conversation');

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  tearDown(() {
    final binding = TestWidgetsFlutterBinding.instance;
    if (binding.lifecycleState != AppLifecycleState.resumed) {
      binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    }
  });

  testWidgets('scripted state resets and cancels without late widget updates', (
    tester,
  ) async {
    final states = ScriptedChatStateStream<String>('idle');
    var builds = 0;

    await tester.pumpWidget(
      Directionality(
        textDirection: TextDirection.ltr,
        child: ChatStateBuilder<String>(
          source: states,
          initialState: states.state,
          states: states.states,
          builder: (context, state) {
            builds += 1;
            return Text(state);
          },
        ),
      ),
    );
    expect(find.text('idle'), findsOneWidget);
    expect(states.listenCount, 1);

    states.emitAll(const <String>['loading', 'ready']);
    await tester.pump();
    expect(find.text('ready'), findsOneWidget);
    expect(states.emissions, const <String>['loading', 'ready']);

    states.reset('idle');
    await tester.pump();
    expect(find.text('idle'), findsOneWidget);
    expect(states.emissions, isEmpty);
    expect(states.listenCount, 1);

    await tester.pumpWidget(const SizedBox.shrink());
    expect(states.cancelCount, 1);
    final buildsAfterUnmount = builds;
    states.emit('late');
    await tester.pump();
    expect(builds, buildsAfterUnmount);

    await states.dispose();
    expect(states.isDisposed, isTrue);
    expect(() => states.emit('post-disposal'), throwsStateError);
    expect(tester.takeException(), isNull);
  });

  testWidgets('real scope fixture drives readiness and timeline state', (
    tester,
  ) async {
    final harness = FlutterChatWidgetHarness();
    harness.enqueueReadyMetadata();
    await harness.initializeClient();
    harness.enqueueTimeline(
      conversationId: _conversationId,
      messages: <MessageTimelineMessage>[_message(sequence: 1)],
    );

    await tester.pumpWidget(
      harness.buildApp(
        withApplicationBindings: false,
        child: Column(
          children: <Widget>[
            ChatClientLifecycleStateBuilder(
              builder: (context, state) => Text('client:${state.state}'),
            ),
            TimelineStateBuilder.forConversation(
              conversationId: _conversationId,
              builder: (context, state) => Text(
                'timeline:${state.status.name}:${state.messages.length}',
              ),
            ),
          ],
        ),
      ),
    );
    await _flush(tester);

    expect(find.text('client:ready'), findsOneWidget);
    expect(find.text('timeline:ready:1'), findsOneWidget);
    expect(
      harness.http.requests.map((request) => request.uri.path),
      contains('/api/chat/conversations/${_conversationId.value}/messages'),
    );

    await tester.pumpWidget(const SizedBox.shrink());
    await _flush(tester);
    await harness.dispose();
    expect(harness.isDisposed, isTrue);
    expect(tester.takeException(), isNull);
  });

  testWidgets('lifecycle, connectivity, and push controls release on teardown',
      (
    tester,
  ) async {
    final harness = FlutterChatWidgetHarness(
      initialPushToken: _pushToken('fixture-push-secret'),
    );
    harness.enqueueReadyMetadata();
    await harness.initializeClient();
    harness.enqueuePushTokenSuccess();
    harness.enqueueRealtimeSocket();

    late ChatScopeBinding scope;
    await tester.pumpWidget(
      harness.buildApp(
        child: Builder(
          builder: (context) {
            scope = ChatScope.of(context);
            return Text(
              '${scope.connectivity.name}:${scope.integrationReadiness.name}',
            );
          },
        ),
      ),
    );
    await _flush(tester);
    expect(scope.connectivity, ChatConnectivityStatus.offline);

    harness.setApplicationForeground(false);

    harness.connectivity.emit(ChatConnectivityStatus.online);
    await _flush(tester);
    expect(
      harness.http.requests.where(_isPushRequest),
      isEmpty,
      reason: 'Background scopes must not register a push token.',
    );

    harness.setApplicationForeground(true);
    await _flush(tester);
    expect(scope.connectivity, ChatConnectivityStatus.online);
    expect(harness.realtimeSockets.uris, hasLength(1));
    expect(harness.http.requests.where(_isPushRequest), hasLength(1));
    expect(harness.pushTokens.listenCount, 1);
    expect(
      jsonDecode(harness.http.requests.where(_isPushRequest).single.body!)
          as Map<String, Object?>,
      containsPair('operation', 'register'),
    );

    await tester.pumpWidget(const SizedBox.shrink());
    await _flush(tester);
    expect(harness.pushTokens.cancelCount, 1);
    final requestCount = harness.http.requests.length;
    harness.pushTokens.emit(_pushToken('late-rotation'));
    harness.connectivity.emit(ChatConnectivityStatus.offline);
    await _flush(tester);
    expect(harness.http.requests, hasLength(requestCount));

    await harness.dispose();
    expect(
      () => harness.pushTokens.emit(_pushToken('post-disposal')),
      throwsStateError,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('visibility samples use the real coordinator deterministically', (
    tester,
  ) async {
    final visibility = ChatReadVisibilityFixture();
    final sample = ChatReadVisibilitySample(
      sequence: const MessageSequence(7),
    );

    await tester.pumpWidget(
      Directionality(
        textDirection: TextDirection.ltr,
        child: ChatReadTracker(
          conversationId: _conversationId,
          items: <ChatReadTrackedItem>[sample.trackedItem],
          reads: visibility.coordinator,
          child: sample.buildRow(child: const Text('visible row')),
        ),
      ),
    );
    await tester.pump();
    visibility.clock.elapse(const Duration(milliseconds: 499));
    expect(visibility.markReadInputs, isEmpty);
    visibility.clock.elapse(const Duration(milliseconds: 1));
    await _flush(tester);
    expect(
      visibility.markReadInputs.single.throughSequence,
      const MessageSequence(7),
    );

    await tester.pumpWidget(const SizedBox.shrink());
    visibility.reset();
    expect(visibility.markReadInputs, isEmpty);
    expect(visibility.clock.pendingTimerCount, 0);

    visibility.setEligible(_conversationId);
    visibility.report(_conversationId, const MessageSequence(8));
    visibility.clock.elapse(const Duration(milliseconds: 500));
    await _flush(tester);
    expect(
      visibility.markReadInputs.single.idempotencyKey,
      'fixture-read-1',
    );

    visibility.dispose();
    expect(visibility.isDisposed, isTrue);
    visibility.coordinator.reportVisibleThrough(
      conversationId: _conversationId,
      sequence: const MessageSequence(9),
    );
    expect(visibility.markReadInputs, hasLength(1));
    expect(tester.takeException(), isNull);
  });

  test('recording application delegates capture and reset public calls',
      () async {
    final recording = RecordingChatApplicationDelegates(
      attachmentResult: ChatAttachmentPickerSelection(
        const <AttachmentId>[AttachmentId('attachment-1')],
      ),
    );
    const userId = UserId('user-1');
    const threadId = ConversationId('thread-1');
    const messageId = MessageId('message-1');
    final entity = HostEntityReference(type: 'project', id: 'project-1');

    expect(
      await recording.delegates.openUser(userId),
      ChatApplicationDelegateResult.handled,
    );
    await recording.delegates.openEntity(entity);
    await recording.delegates.openThread(threadId);
    await recording.delegates.reportMessage(messageId);
    await recording.delegates.pickAttachment();
    await recording.delegates.showNotificationSettings();
    await recording.delegates.openExternalLink(
      Uri.parse('https://example.test/help'),
    );

    expect(recording.openedUsers, const <UserId>[userId]);
    expect(recording.openedEntities, <HostEntityReference>[entity]);
    expect(recording.openedThreads, const <ConversationId>[threadId]);
    expect(recording.reportedMessages, const <MessageId>[messageId]);
    expect(recording.attachmentPickerCallCount, 1);
    expect(recording.notificationSettingsCallCount, 1);
    expect(recording.openedExternalLinks, hasLength(1));

    recording.reset(result: ChatApplicationDelegateResult.cancelled);
    expect(recording.openedUsers, isEmpty);
    expect(recording.attachmentPickerCallCount, 0);
    expect(
      await recording.delegates.openUser(userId),
      ChatApplicationDelegateResult.cancelled,
    );
  });

  testWidgets('recording widget builders capture and reset public inputs', (
    tester,
  ) async {
    final harness = FlutterChatWidgetHarness();
    final timeline = harness.client.timeline(_conversationId);
    final message = _message(sequence: 2);
    final recording = RecordingChatWidgetBuilders();

    await tester.pumpWidget(
      Directionality(
        textDirection: TextDirection.ltr,
        child: Builder(
          builder: (context) => Column(
            children: <Widget>[
              recording.builders.message(
                context,
                ChatMessageBuilderInput(
                  message: message,
                  actions: ChatMessageActions.forMessage(
                    controller: timeline,
                    message: message,
                  ),
                ),
              ),
              recording.builders.loading(
                context,
                const ChatLoadingBuilderInput(
                  target: ChatLoadingTarget.timeline,
                  conversationId: _conversationId,
                ),
              ),
              recording.builders.error(
                context,
                const ChatErrorBuilderInput.timeline(
                  error: ChatTimelineControllerError(
                    code: ChatTimelineControllerErrorCode.transport,
                    message: 'fixture failure',
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );

    expect(recording.messages.single.message.id, message.id);
    expect(recording.loadingStates.single.conversationId, _conversationId);
    expect(recording.errors.single.message, 'fixture failure');
    expect(
      find.byKey(
        const ValueKey<String>('recording-chat-builder-message'),
      ),
      findsOneWidget,
    );

    recording.reset();
    expect(recording.messages, isEmpty);
    expect(recording.loadingStates, isEmpty);
    expect(recording.errors, isEmpty);

    await tester.pumpWidget(const SizedBox.shrink());
    await harness.dispose();
  });
}

MessageTimelineMessage _message({required int sequence}) =>
    MessageTimelineMessage(
      message: ActiveMessage(
        id: MessageId('message-$sequence'),
        tenantId: const TenantId('fixture-tenant'),
        conversationId: _conversationId,
        author: MessageAuthorIdentity(
          userId: UserId('author-$sequence'),
        ),
        sequence: MessageSequence(sequence),
        createdAt: const IsoTimestamp('2026-08-26T20:00:00.000Z'),
        updatedAt: const IsoTimestamp('2026-08-26T20:00:00.000Z'),
        revision: const MessageRevisionMetadata(revision: 1),
        content: MessageContent(
          format: MessageContentFormat.plain,
          text: 'message $sequence',
        ),
      ),
      isThreadRoot: false,
      reactions: const <MessageReactionAggregate>[],
      attachmentMetadata: const <MessageAttachmentMetadata>[],
    );

ChatPushToken _pushToken(String value) => ChatPushToken(
      token: value,
      platform: DevicePlatform.ios,
      provider: DevicePushProvider.apns,
      environment: DevicePushProviderEnvironment.sandbox,
    );

bool _isPushRequest(HandrailChatHttpRequest request) =>
    request.uri.path.endsWith('/push-token');

Future<void> _flush(WidgetTester tester) async {
  await tester.pump();
  await tester.runAsync(() async {
    for (var index = 0; index < 8; index += 1) {
      await Future<void>.delayed(Duration.zero);
    }
  });
  await tester.pump();
}
