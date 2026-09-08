import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:handrail_chat/testing.dart' show ChatReadVisibilityFixture;
import 'package:handrail_chat/ui.dart';

const _conversationId = ConversationId('conversation-timeline-widget');
const _otherConversationId = ConversationId('conversation-timeline-other');
const _tenantId = 'tenant-timeline-widget';
const _userId = 'user-current';
const _now = '2026-08-26T22:00:00.000Z';

void main() {
  for (final warm in [false, true]) {
    for (final boundary in [1, 18, 40]) {
      testWidgets('opens ${warm ? "warm" : "cold"} chat at unread $boundary',
          (tester) async {
        final transport = _TimelineTransport(
          initialResponse: Completer<HandrailChatHttpResponse>()
            ..complete(_response(_timeline(messages: [
              for (var value = 1; value <= 40; value++) _message(value),
            ]))),
        );
        final client = _client(transport);
        client.normalizedState.hydrateConversationDetail(
          ConversationDetailSnapshot.fromJson(_conversationDetail(
            latestSequence: 40,
            lastReadSequence: boundary - 1,
          )),
        );
        final controller = client.timeline(_conversationId);
        if (warm) await tester.runAsync(controller.refresh);
        final scroll = ScrollController();
        addTearDown(scroll.dispose);
        addTearDown(client.dispose);
        await tester.pumpWidget(_host(client, SizedBox(
          height: 300,
          child: HandrailMessageTimeline(
            conversationId: _conversationId,
            controller: controller,
            scrollController: scroll,
            isConversationActive: false,
            builders: ChatWidgetBuilders(message: (context, input) => SizedBox(
              height: input.message.sequence.value.isEven ? 95 : 45,
              child: Text(input.message.content!.text),
            )),
          ),
        )));
        await _pumpUntil(tester, () => controller.state.isReady);
        for (var frame = 0; frame < 60; frame++) {
          await tester.pump();
        }
        final divider = find.byKey(ValueKey<String>('handrail-unread-$boundary'));
        expect(divider, findsOneWidget);
        final viewport = tester.getRect(find.byKey(
          const ValueKey<String>('handrail-message-timeline-list'),
        ));
        expect(viewport.overlaps(tester.getRect(divider)), isTrue);
        if (boundary < 40) {
          expect(scroll.position.maxScrollExtent - scroll.offset, greaterThan(300));
          final offset = scroll.offset;
          client.normalizedState.hydrateConversationDetail(
            ConversationDetailSnapshot.fromJson(_conversationDetail(
              latestSequence: 40,
              lastReadSequence: 40,
              readUpdatedAt: '2026-08-26T22:01:00.000Z',
            )),
          );
          await tester.pump();
          expect(divider, findsOneWidget);
          expect(scroll.offset, closeTo(offset, 1));
          client.reduceDurableEvent(_createdEvent(41,
            clientMessageId: 'unread-append',
            eventId: 'unread-append',
            text: 'new arrival',
          ));
          await tester.pump();
          expect(scroll.offset, closeTo(offset, 1));
        }
        await tester.pumpWidget(const SizedBox.shrink());
      });
    }
  }

  testWidgets(
      'shows initial and earlier loading and retains the pagination anchor',
      (tester) async {
    final initial = Completer<HandrailChatHttpResponse>();
    final earlier = Completer<HandrailChatHttpResponse>();
    final transport = _TimelineTransport(
      initialResponse: initial,
      earlierResponse: earlier,
    );
    final client = _client(transport);
    final controller = client.timeline(_conversationId);
    final scrollController = ScrollController();
    final semantics = tester.ensureSemantics();
    addTearDown(scrollController.dispose);
    addTearDown(client.dispose);
    final builtElements = <MessageId, Element>{};
    final builders = ChatWidgetBuilders(
      message: (context, input) {
        builtElements[input.message.id] = context as Element;
        return SizedBox(
          height: 64,
          child: Text(input.message.content?.text ?? 'deleted'),
        );
      },
      loading: (context, input) => Text(
        input.target == ChatLoadingTarget.timeline
            ? 'timeline loading'
            : 'other loading',
      ),
    );

    await tester.pumpWidget(_host(
      client,
      SizedBox(
        height: 260,
        child: HandrailMessageTimeline(
          conversationId: _conversationId,
          controller: controller,
          builders: builders,
          scrollController: scrollController,
        ),
      ),
    ));
    expect(find.text('timeline loading'), findsOneWidget);
    expect(find.bySemanticsLabel(RegExp('Loading messages')), findsOneWidget);

    initial.complete(_response(_timeline(
      messages: [for (var value = 10; value <= 18; value++) _message(value)],
      older: 10,
    )));
    await _pumpUntil(tester, () => controller.state.isReady);
    expect(
      controller.state.messages.map((message) => message.sequence.value),
      orderedEquals([10, 11, 12, 13, 14, 15, 16, 17, 18]),
    );
    expect(
      scrollController.position.maxScrollExtent - scrollController.offset,
      lessThanOrEqualTo(1),
    );

    scrollController.jumpTo(0);
    await tester.pump();
    final anchoredElement = builtElements[const MessageId('message-10')];
    expect(anchoredElement, isNotNull);
    await _pumpUntil(tester, () => transport.earlierRequestCount == 1);
    expect(
      find.byKey(const ValueKey<String>('handrail-timeline-earlier-loading')),
      findsOneWidget,
    );
    final offsetBeforePrepend = scrollController.offset;
    final extentBeforePrepend = scrollController.position.maxScrollExtent;

    earlier.complete(_response(_timeline(
      messages: [for (var value = 5; value < 10; value++) _message(value)],
      newer: 9,
    )));
    await _pumpUntil(
      tester,
      () => controller.state.messages.first.sequence.value == 5,
    );
    final extentDelta =
        scrollController.position.maxScrollExtent - extentBeforePrepend;
    expect(
        scrollController.offset, closeTo(offsetBeforePrepend + extentDelta, 1));
    expect(builtElements[const MessageId('message-10')], same(anchoredElement));
    semantics.dispose();
  });

  testWidgets(
      'shows an accessible earlier-page failure and retries without losing the anchor',
      (tester) async {
    final failedEarlier = Completer<HandrailChatHttpResponse>();
    final successfulEarlier = Completer<HandrailChatHttpResponse>();
    final transport = _TimelineTransport(
      initialResponse: Completer<HandrailChatHttpResponse>()
        ..complete(_response(_timeline(
          messages: [
            for (var value = 10; value <= 18; value++) _message(value)
          ],
          older: 10,
        ))),
      earlierResponses: [failedEarlier.future, successfulEarlier.future],
    );
    final client = _client(transport);
    final controller = client.timeline(_conversationId);
    final scrollController = ScrollController();
    final semantics = tester.ensureSemantics();
    addTearDown(scrollController.dispose);
    addTearDown(client.dispose);
    final builtElements = <MessageId, Element>{};
    final builders = ChatWidgetBuilders(
      message: (context, input) {
        builtElements[input.message.id] = context as Element;
        return SizedBox(
          height: 64,
          child: Text(input.message.content?.text ?? 'deleted'),
        );
      },
      error: (context, input) => const Text('Full timeline error'),
    );

    await tester.pumpWidget(_host(
      client,
      SizedBox(
        height: 260,
        child: HandrailMessageTimeline(
          conversationId: _conversationId,
          controller: controller,
          builders: builders,
          scrollController: scrollController,
        ),
      ),
    ));
    await _pumpUntil(tester, () => controller.state.isReady);
    scrollController.jumpTo(0);
    await _pumpUntil(tester, () => transport.earlierRequestCount == 1);
    final anchoredElement = builtElements[const MessageId('message-10')];
    expect(anchoredElement, isNotNull);
    final offsetBeforeFailure = scrollController.offset;

    failedEarlier.complete(HandrailChatHttpResponse(
      statusCode: 500,
      body: jsonEncode(const {
        'error': 'raw fixture response that must not be rendered',
      }),
    ));
    await _pumpUntil(
      tester,
      () => controller.state.status == ChatTimelineControllerStatus.error,
    );

    expect(controller.state.messages, hasLength(9));
    expect(find.text('message 10'), findsOneWidget);
    expect(find.text('Full timeline error'), findsNothing);
    expect(
      find.bySemanticsLabel("Earlier messages couldn't be loaded"),
      findsOneWidget,
    );
    expect(
      find.bySemanticsLabel('Retry earlier messages'),
      findsOneWidget,
    );
    expect(
      find.textContaining('raw fixture response'),
      findsNothing,
    );
    expect(scrollController.offset, closeTo(offsetBeforeFailure, 1));
    expect(
      builtElements[const MessageId('message-10')],
      same(anchoredElement),
    );

    await tester.tap(find.bySemanticsLabel('Retry earlier messages'));
    await _pumpUntil(tester, () => transport.earlierRequestCount == 2);
    expect(
      find.bySemanticsLabel("Earlier messages couldn't be loaded"),
      findsNothing,
    );
    expect(
      find.byKey(const ValueKey<String>('handrail-timeline-earlier-loading')),
      findsOneWidget,
    );
    expect(scrollController.offset, closeTo(offsetBeforeFailure, 1));
    final offsetBeforePrepend = scrollController.offset;
    final extentBeforePrepend = scrollController.position.maxScrollExtent;

    successfulEarlier.complete(_response(_timeline(
      messages: [for (var value = 5; value < 10; value++) _message(value)],
      newer: 9,
    )));
    await _pumpUntil(
      tester,
      () => controller.state.messages.first.sequence.value == 5,
    );

    final extentDelta =
        scrollController.position.maxScrollExtent - extentBeforePrepend;
    expect(
      scrollController.offset,
      closeTo(offsetBeforePrepend + extentDelta, 1),
    );
    expect(
      builtElements[const MessageId('message-10')],
      same(anchoredElement),
    );
    expect(
      find.bySemanticsLabel("Earlier messages couldn't be loaded"),
      findsNothing,
    );
    semantics.dispose();
  });

  testWidgets(
      'response-only rebuild ignores transient duplicate scroll attachments',
      (tester) async {
    final transport = _TimelineTransport(
      initialResponse: Completer<HandrailChatHttpResponse>()
        ..complete(_response(_timeline(messages: [_message(1)]))),
    );
    final client = _client(transport);
    final controller = client.timeline(_conversationId);
    final scrollController = ScrollController();
    addTearDown(scrollController.dispose);
    addTearDown(client.dispose);
    late StateSetter rebuild;
    var attachTransientPosition = false;

    await tester.pumpWidget(StatefulBuilder(builder: (context, setState) {
      rebuild = setState;
      return _host(
        client,
        Column(
          children: [
            Expanded(
              child: HandrailMessageTimeline(
                conversationId: _conversationId,
                controller: controller,
                scrollController: scrollController,
              ),
            ),
            if (attachTransientPosition)
              SizedBox(
                height: 1,
                child: ListView(
                  controller: scrollController,
                  children: const [SizedBox(height: 1)],
                ),
              ),
          ],
        ),
      );
    }));
    await _pumpUntil(tester, () => controller.state.isReady);

    rebuild(() => attachTransientPosition = true);
    await tester.pump();
    expect(scrollController.positions, hasLength(2));

    // Response selectors and reminder reconciliation rebuild the timeline even
    // though the ordered message set has not changed.
    rebuild(() {});
    await tester.pump();

    expect(tester.takeException(), isNull);
    expect(
      find.byKey(const ValueKey<String>('handrail-message-timeline-list')),
      findsOneWidget,
    );
    expect(find.text('message 1'), findsOneWidget);
  });

  testWidgets(
      'keeps chronological keyed rows through optimistic, replayed, and live appends',
      (tester) async {
    final transport = _TimelineTransport(
      initialResponse: Completer<HandrailChatHttpResponse>()
        ..complete(_response(_timeline(
          messages: [
            for (var value = 1; value <= 8; value++)
              _message(
                value,
                id: value == 7 ? 'failed-7' : null,
                text: value == 7 ? 'Failed message' : null,
              ),
          ],
        ))),
    );
    final client = _client(transport);
    client.normalizedState.hydrateConversationDetail(
      ConversationDetailSnapshot.fromJson(_conversationDetail(
        latestSequence: 8,
        lastReadSequence: 8,
      )),
    );
    final controller = client.timeline(_conversationId);
    final scrollController = ScrollController();
    addTearDown(scrollController.dispose);
    addTearDown(client.dispose);
    final seen = <String>[];
    final builders = ChatWidgetBuilders(
      message: (context, input) {
        seen.add(input.message.id.value);
        return SizedBox(
          height: 72,
          child: Text(input.message.content?.text ?? 'deleted'),
        );
      },
    );
    await tester.pumpWidget(_host(
      client,
      SizedBox(
        height: 260,
        child: HandrailMessageTimeline(
          conversationId: _conversationId,
          controller: controller,
          builders: builders,
          scrollController: scrollController,
        ),
      ),
    ));
    await _pumpUntil(tester, () => controller.state.isReady);

    client.normalizedState.beginOptimisticMessageSend(
      clientMessageId: 'client-optimistic-9',
      projection: MessageTimelineMessage.fromJson(
        _message(9, id: 'optimistic-9', text: 'Optimistic message'),
      ),
    );
    await tester.pump();
    expect(find.text('Optimistic message'), findsOneWidget);
    expect(scrollController.offset, scrollController.position.maxScrollExtent);

    client.reduceDurableEvent(_createdEvent(
      9,
      clientMessageId: 'client-optimistic-9',
      eventId: 'replayed-created-9',
      text: 'Replayed message',
    ));
    await tester.pump();
    expect(find.text('Optimistic message'), findsNothing);
    expect(find.text('Replayed message'), findsOneWidget);

    scrollController.jumpTo(80);
    await tester.pump();
    final readingOffset = scrollController.offset;
    client.reduceDurableEvent(_createdEvent(
      10,
      clientMessageId: 'client-live-10',
      eventId: 'live-created-10',
      text: 'Live message',
    ));
    await tester.pump();
    expect(scrollController.offset, closeTo(readingOffset, 1));
    expect(
      controller.state.messages.map((message) => message.sequence.value),
      orderedEquals([1, 2, 3, 4, 5, 6, 7, 8, 9, 10]),
    );
    for (var index = 0; index < 3; index += 1) {
      scrollController.jumpTo(scrollController.position.maxScrollExtent);
      await tester.pump();
    }
    expect(find.text('Live message'), findsOneWidget);
    expect(
      seen,
      containsAll(
        <String>['failed-7', 'optimistic-9', 'message-9', 'message-10'],
      ),
    );
  });

  testWidgets(
      'renders deletion, thread, reaction, attachment, unread, actions, and read tracking',
      (tester) async {
    final rich = _message(
      3,
      text: 'Rich message',
      threadSummary: const <String, Object?>{
        'threadId': 'thread-3',
        'replyCount': 4,
        'participantIds': ['user-2', 'user-3'],
        'unreadCount': 2,
        'lastReplyAt': _now,
      },
      reactions: const [
        {
          'reactionKey': 'thumbsup',
          'count': 2,
          'reactedByCurrentUser': true,
        },
      ],
      attachment: true,
    );
    final transport = _TimelineTransport(
      initialResponse: Completer<HandrailChatHttpResponse>()
        ..complete(_response(_timeline(messages: [
          _message(1, text: 'Active message'),
          _message(2, deleted: true),
          rich,
        ]))),
    );
    final client = _client(transport, minimumExposure: Duration.zero);
    client.normalizedState.hydrateConversationDetail(
      ConversationDetailSnapshot.fromJson(_conversationDetail(
        latestSequence: 3,
        lastReadSequence: 1,
        manualUnreadFromSequence: 1,
      )),
    );
    final controller = client.timeline(_conversationId);
    addTearDown(client.dispose);
    final reads = ChatReadVisibilityFixture(minimumExposure: Duration.zero);
    addTearDown(reads.dispose);
    final recordedMessages = <ChatMessageBuilderInput>[];
    final recordedAttachments = <ChatAttachmentPreviewBuilderInput>[];
    final builders = ChatWidgetBuilders(
      message: (context, input) {
        recordedMessages.add(input);
        return Text(input.message.content?.text ?? 'Deleted shell');
      },
      attachmentPreview: (context, input) {
        recordedAttachments.add(input);
        return Text('Attachment ${input.attachment.fileName}');
      },
    );
    final semantics = tester.ensureSemantics();

    await tester.pumpWidget(_host(
      client,
      SizedBox(
        height: 500,
        child: HandrailMessageTimeline(
          conversationId: _conversationId,
          controller: controller,
          builders: builders,
          reads: reads.coordinator,
        ),
      ),
    ));
    await _pumpUntil(tester, () => controller.state.isReady);

    expect(find.text('Active message'), findsOneWidget);
    expect(find.text('Deleted shell'), findsOneWidget);
    expect(find.text('Rich message'), findsOneWidget);
    expect(find.text('Attachment report.pdf'), findsOneWidget);
    expect(find.text('thumbsup 2'), findsOneWidget);
    expect(find.text('4 replies · 2 unread'), findsOneWidget);
    expect(find.text('Reply'), findsOneWidget);
    expect(
      find.byKey(const ValueKey<String>('handrail-reply-message-1')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey<String>('handrail-reply-message-2')),
      findsNothing,
    );
    expect(
      find.byKey(const ValueKey<String>('handrail-reply-message-3')),
      findsNothing,
    );
    expect(find.text('New messages'), findsOneWidget);
    expect(find.bySemanticsLabel(RegExp('Message timeline')), findsOneWidget);
    expect(
      find.bySemanticsLabel(RegExp('Deleted message 2')),
      findsOneWidget,
    );
    expect(find.bySemanticsLabel(RegExp('Unread messages')), findsOneWidget);
    expect(recordedMessages.map((input) => input.message.sequence.value),
        containsAllInOrder([1, 2, 3]));
    expect(recordedAttachments.single.attachment.fileName, 'report.pdf');

    await tester.tap(find.text('thumbsup 2'));
    await tester.tap(find.text('4 replies · 2 unread'));
    await _pumpUntil(
      tester,
      () => transport.requests
          .any((request) => request.uri.path.endsWith('/reactions/thumbsup')),
    );
    expect(
      transport.requests.any(
        (request) => request.uri.path.endsWith('/messages/message-3/thread'),
      ),
      isTrue,
    );
    reads.clock.elapse(Duration.zero);
    await tester.pump();
    expect(reads.markReadInputs, isNotEmpty);
    expect(reads.markReadInputs.last.throughSequence.value, 3);
    semantics.dispose();
  });

  testWidgets(
      'Reply opens canonical zero-reply threads but excludes optimistic rows',
      (tester) async {
    final transport = _TimelineTransport(
      initialResponse: Completer<HandrailChatHttpResponse>()
        ..complete(_response(_timeline(messages: [
          _message(1, text: 'Start a thread'),
        ]))),
    );
    final client = _client(transport);
    client.normalizedState.hydrateConversationDetail(
      ConversationDetailSnapshot.fromJson(_conversationDetail(
        latestSequence: 2,
        lastReadSequence: 0,
      )),
    );
    final controller = client.timeline(_conversationId);
    addTearDown(client.dispose);
    final requested = <ChatMessageActions>[];

    await tester.pumpWidget(_host(
      client,
      HandrailMessageTimeline(
        conversationId: _conversationId,
        controller: controller,
        onThreadRequested: (actions) async => requested.add(actions),
      ),
    ));
    await _pumpUntil(tester, () => controller.state.isReady);

    client.normalizedState.beginOptimisticMessageSend(
      clientMessageId: 'client-optimistic-reply',
      projection: MessageTimelineMessage.fromJson(
        _message(
          2,
          id: 'message-optimistic',
          text: 'Optimistic reply target',
        ),
      ),
    );
    await tester.pump();

    final canonicalReply = find.byKey(
      const ValueKey<String>('handrail-reply-message-1'),
    );
    final optimisticReply = find.byKey(
      const ValueKey<String>('handrail-reply-message-optimistic'),
    );
    expect(canonicalReply, findsOneWidget);
    expect(optimisticReply, findsNothing);
    expect(find.text('Reply'), findsOneWidget);

    await tester.tap(canonicalReply);
    await tester.pump();

    expect(requested, hasLength(1));
    expect(requested.single.messageId, const MessageId('message-1'));
    expect(
      transport.requests.where(
        (request) => request.uri.path.endsWith('/messages/message-1/thread'),
      ),
      isEmpty,
    );
  });

  testWidgets('Reactions are interactive only for canonical active messages',
      (tester) async {
    const canonicalReaction = <String, Object?>{
      'reactionKey': 'thumbsup',
      'count': 2,
      'reactedByCurrentUser': false,
    };
    const deletedReaction = <String, Object?>{
      'reactionKey': 'eyes',
      'count': 1,
      'reactedByCurrentUser': false,
    };
    const optimisticReaction = <String, Object?>{
      'reactionKey': 'tada',
      'count': 1,
      'reactedByCurrentUser': false,
    };
    final transport = _TimelineTransport(
      initialResponse: Completer<HandrailChatHttpResponse>()
        ..complete(_response(_timeline(messages: [
          _message(1, reactions: const [canonicalReaction]),
          _message(2, deleted: true, reactions: const [deletedReaction]),
        ]))),
    );
    final client = _client(transport);
    client.normalizedState.hydrateConversationDetail(
      ConversationDetailSnapshot.fromJson(_conversationDetail(
        latestSequence: 3,
        lastReadSequence: 0,
      )),
    );
    final controller = client.timeline(_conversationId);
    final requested = <ChatMessageBuilderInput>[];
    addTearDown(client.dispose);

    await tester.pumpWidget(_host(
      client,
      HandrailMessageTimeline(
        conversationId: _conversationId,
        controller: controller,
        onReactionRequested: requested.add,
      ),
    ));
    await _pumpUntil(tester, () => controller.state.isReady);
    client.normalizedState.beginOptimisticMessageSend(
      clientMessageId: 'optimistic-reaction',
      projection: MessageTimelineMessage.fromJson(
        _message(
          3,
          id: 'optimistic-3',
          reactions: const [optimisticReaction],
        ),
      ),
    );
    await tester.pump();

    final canonicalAggregate = find.byKey(
      const ValueKey<String>('handrail-reaction-message-1-thumbsup'),
    );
    final canonicalPicker = find.byKey(
      const ValueKey<String>('handrail-add-reaction-message-1'),
    );
    expect(canonicalAggregate, findsOneWidget);
    expect(canonicalPicker, findsOneWidget);
    expect(
      find.byKey(
        const ValueKey<String>('handrail-reaction-message-2-eyes'),
      ),
      findsNothing,
    );
    expect(
      find.byKey(const ValueKey<String>('handrail-add-reaction-message-2')),
      findsNothing,
    );
    expect(
      find.byKey(
        const ValueKey<String>('handrail-reaction-optimistic-3-tada'),
      ),
      findsNothing,
    );
    expect(
      find.byKey(
        const ValueKey<String>('handrail-add-reaction-optimistic-3'),
      ),
      findsNothing,
    );

    await tester.tap(canonicalPicker);
    await tester.pump();
    expect(requested, hasLength(1));
    expect(requested.single.message.id, const MessageId('message-1'));

    await tester.tap(canonicalAggregate);
    await _pumpUntil(
      tester,
      () => transport.requests.any(
        (request) => request.uri.path.endsWith(
          '/messages/message-1/reactions/thumbsup',
        ),
      ),
    );
    expect(
      transport.requests.where(
        (request) => request.uri.path.contains('/reactions/'),
      ),
      hasLength(1),
    );
  });

  testWidgets('Forward appears only for eligible canonical active messages',
      (tester) async {
    final transport = _TimelineTransport(
      initialResponse: Completer<HandrailChatHttpResponse>()
        ..complete(_response(_timeline(messages: [
          _message(1, text: 'Eligible source'),
          _message(2, deleted: true),
          _message(3, attachment: true),
          _message(4, block: true),
        ]))),
    );
    final client = _client(transport);
    client.normalizedState.hydrateConversationDetail(
      ConversationDetailSnapshot.fromJson(_conversationDetail(
        latestSequence: 4,
        lastReadSequence: 0,
      )),
    );
    final controller = client.timeline(_conversationId);
    final requested = <ChatMessageActions>[];
    addTearDown(client.dispose);

    await tester.pumpWidget(_host(
      client,
      HandrailMessageTimeline(
        conversationId: _conversationId,
        controller: controller,
        onForwardRequested: (actions) async => requested.add(actions),
      ),
    ));
    await _pumpUntil(tester, () => controller.state.isReady);
    client.normalizedState.beginOptimisticMessageSend(
      clientMessageId: 'optimistic-forward',
      projection: MessageTimelineMessage.fromJson(
        _message(5, id: 'optimistic-message'),
      ),
    );
    await tester.pump();

    final eligible = find.byKey(
      const ValueKey<String>('handrail-forward-message-1'),
    );
    expect(eligible, findsOneWidget);
    expect(find.text('Forward'), findsOneWidget);
    expect(
      find.byKey(const ValueKey<String>('handrail-forward-message-2')),
      findsNothing,
    );
    expect(
      find.byKey(const ValueKey<String>('handrail-forward-message-3')),
      findsNothing,
    );
    expect(
      find.byKey(const ValueKey<String>('handrail-forward-message-4')),
      findsNothing,
    );
    expect(
      find.byKey(const ValueKey<String>(
        'handrail-forward-optimistic-message',
      )),
      findsNothing,
    );

    await tester.tap(eligible);
    await tester.pump();
    expect(requested, hasLength(1));
    expect(requested.single.messageId, const MessageId('message-1'));
    expect(
      transport.requests.where(
        (request) => request.uri.path.endsWith('/messages/forward'),
      ),
      isEmpty,
    );
  });

  testWidgets('Forward stays absent when no destination host is available',
      (tester) async {
    final transport = _TimelineTransport(
      initialResponse: Completer<HandrailChatHttpResponse>()
        ..complete(_response(_timeline(messages: [_message(1)]))),
    );
    final client = _client(transport);
    final controller = client.timeline(_conversationId);
    addTearDown(client.dispose);

    await tester.pumpWidget(_host(
      client,
      HandrailMessageTimeline(
        conversationId: _conversationId,
        controller: controller,
      ),
    ));
    await _pumpUntil(tester, () => controller.state.isReady);

    expect(
      find.byKey(const ValueKey<String>('handrail-forward-message-1')),
      findsNothing,
    );
  });

  testWidgets(
      'Remind me schedules a preset with pending feedback then reschedules and cancels by revision',
      (tester) async {
    final firstResponse = Completer<void>();
    final transport = _TimelineTransport(
      initialResponse: Completer<HandrailChatHttpResponse>()
        ..complete(_response(_timeline(messages: [_message(1)]))),
      reminderHandler: (request, requestIndex) async {
        if (requestIndex == 0) await firstResponse.future;
        return _reminderResponse(
          request,
          reminderRevision: requestIndex + 1,
        );
      },
    );
    final client = _client(transport);
    final controller = client.timeline(_conversationId);
    final now = DateTime.utc(2030, 3, 10, 15);
    DateTime toLocal(DateTime utc) => utc.subtract(const Duration(hours: 5));
    DateTime toUtc(DateTime local) => DateTime.utc(
          local.year,
          local.month,
          local.day,
          local.hour + 5,
          local.minute,
        );
    addTearDown(client.dispose);

    await tester.pumpWidget(_host(
      client,
      HandrailMessageTimeline(
        conversationId: _conversationId,
        controller: controller,
        reminderClock: () => now,
        reminderToLocalTime: toLocal,
        reminderToUtcTime: toUtc,
      ),
    ));
    await _pumpUntil(tester, () => controller.state.isReady);

    await tester.tap(find.byKey(
      const ValueKey<String>('handrail-remind-message-1'),
    ));
    await tester.pumpAndSettle();
    expect(find.text('No reminder scheduled'), findsOneWidget);

    await tester.tap(find.byKey(
      const ValueKey<String>('handrail-reminder-preset-20-minutes'),
    ));
    await _pumpUntil(tester, () => transport.reminderRequests.length == 1);
    expect(find.text('Updating reminder…'), findsOneWidget);
    expect(
      find.bySemanticsLabel('Updating reminder'),
      findsOneWidget,
    );
    final firstBody =
        jsonDecode(transport.reminderRequests[0].body!) as Map<String, Object?>;
    expect(firstBody['intent'], 'set');
    expect(firstBody['expectedReminderRevision'], 0);
    expect(firstBody['dueAt'], '2030-03-10T15:20:00.000Z');

    firstResponse.complete();
    await _waitForReminderIdle(tester, controller);
    await _pumpUntil(
      tester,
      () => find.text('Reminder scheduled').evaluate().isNotEmpty,
    );
    expect(find.textContaining('Revision 1'), findsOneWidget);
    expect(
      controller
          .messageReminder(const MessageId('message-1'))
          .authoritativeRevision,
      1,
    );
    expect(
      find.byKey(const ValueKey<String>('handrail-reminder-cancel')),
      findsOneWidget,
    );

    await tester.tap(find.byKey(
      const ValueKey<String>('handrail-reminder-preset-tomorrow'),
    ));
    await _pumpUntil(tester, () => transport.reminderRequests.length == 2);
    await _waitForReminderIdle(tester, controller);
    await _pumpUntil(
      tester,
      () => find.text('Reminder rescheduled').evaluate().isNotEmpty,
    );
    final secondBody =
        jsonDecode(transport.reminderRequests[1].body!) as Map<String, Object?>;
    expect(secondBody['intent'], 'set');
    expect(secondBody['expectedReminderRevision'], 1);
    expect(secondBody['dueAt'], '2030-03-11T14:00:00.000Z');
    expect(find.textContaining('Revision 2'), findsOneWidget);

    await tester.tap(find.byKey(
      const ValueKey<String>('handrail-reminder-cancel'),
    ));
    await _pumpUntil(tester, () => transport.reminderRequests.length == 3);
    await _waitForReminderIdle(tester, controller);
    await _pumpUntil(
      tester,
      () => find.text('Reminder cancelled').evaluate().isNotEmpty,
    );
    final thirdBody =
        jsonDecode(transport.reminderRequests[2].body!) as Map<String, Object?>;
    expect(thirdBody['intent'], 'cancel');
    expect(thirdBody['expectedReminderRevision'], 2);
    expect(thirdBody.containsKey('dueAt'), isFalse);
    expect(find.text('No reminder scheduled'), findsOneWidget);
    expect(
      controller
          .messageReminder(const MessageId('message-1'))
          .authoritativeRevision,
      3,
    );
  });

  testWidgets('custom reminder picker converts local wall time to UTC',
      (tester) async {
    final pickedDates = <DateTime>[];
    final pickedTimes = <TimeOfDay>[];
    final transport = _TimelineTransport(
      initialResponse: Completer<HandrailChatHttpResponse>()
        ..complete(_response(_timeline(messages: [_message(1)]))),
      reminderHandler: (request, requestIndex) async =>
          _reminderResponse(request, reminderRevision: 1),
    );
    final client = _client(transport);
    final controller = client.timeline(_conversationId);
    final now = DateTime.utc(2030, 3, 10, 15);
    DateTime toLocal(DateTime utc) => utc.subtract(const Duration(hours: 5));
    DateTime toUtc(DateTime local) => DateTime.utc(
          local.year,
          local.month,
          local.day,
          local.hour + 5,
          local.minute,
        );
    ChatMessageActions? renderedActions;
    addTearDown(client.dispose);

    await tester.pumpWidget(_host(
      client,
      HandrailMessageTimeline(
        conversationId: _conversationId,
        controller: controller,
        builders: ChatWidgetBuilders(message: (context, input) {
          renderedActions = input.actions;
          return Text(input.message.content!.text);
        }),
        reminderClock: () => now,
        reminderToLocalTime: toLocal,
        reminderToUtcTime: toUtc,
        reminderDatePicker: (context, initial, first, last) async {
          pickedDates.add(initial);
          return DateTime(2030, 3, 12);
        },
        reminderTimePicker: (context, initial) async {
          pickedTimes.add(initial);
          return const TimeOfDay(hour: 16, minute: 30);
        },
      ),
    ));
    await _pumpUntil(tester, () => controller.state.isReady);
    expect(renderedActions, isNotNull);
    expect(renderedActions!.reminderState.authoritativeRevision, 0);
    expect(
      renderedActions!.reminderStates,
      isA<Stream<NormalizedMessageReminderState>>(),
    );

    await tester.tap(find.byKey(
      const ValueKey<String>('handrail-remind-message-1'),
    ));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(
      const ValueKey<String>('handrail-reminder-custom'),
    ));
    await _pumpUntil(tester, () => transport.reminderRequests.length == 1);
    await _waitForReminderIdle(tester, controller);
    await _pumpUntil(
      tester,
      () => find.text('Reminder scheduled').evaluate().isNotEmpty,
    );

    expect(pickedDates.single, DateTime.utc(2030, 3, 10, 11));
    expect(pickedTimes.single, const TimeOfDay(hour: 11, minute: 0));
    final body = jsonDecode(transport.reminderRequests.single.body!)
        as Map<String, Object?>;
    expect(body['dueAt'], '2030-03-12T21:30:00.000Z');
    expect(body['expectedReminderRevision'], 0);
  });

  testWidgets(
      'reminder failure is sanitized and revision conflict reconciles authoritative state',
      (tester) async {
    const rawFailure = 'private upstream reminder failure details';
    const initialDue = IsoTimestamp('2030-03-11T15:00:00.000Z');
    const serverDue = '2030-03-12T18:00:00.000Z';
    final transport = _TimelineTransport(
      initialResponse: Completer<HandrailChatHttpResponse>()
        ..complete(_response(_timeline(messages: [_message(1)]))),
      reminderHandler: (request, requestIndex) async {
        if (requestIndex == 0) {
          return HandrailChatHttpResponse(
            statusCode: 503,
            body: jsonEncode(const {'error': rawFailure}),
          );
        }
        return _reminderResponse(
          request,
          statusCode: 409,
          reconciliationStatus: 'revision-conflict',
          reminderRevision: 5,
          authoritativeDueAt: serverDue,
        );
      },
    );
    final client = _client(transport);
    client.normalizedState.reconcileMessageReminderCanonical(
      conversationId: _conversationId,
      messageId: const MessageId('message-1'),
      reminderRevision: 3,
      reminder: const CanonicalScheduledMessageReminder(initialDue),
    );
    final controller = client.timeline(_conversationId);
    final now = DateTime.utc(2030, 3, 10, 15);
    addTearDown(client.dispose);

    await tester.pumpWidget(_host(
      client,
      HandrailMessageTimeline(
        conversationId: _conversationId,
        controller: controller,
        reminderClock: () => now,
        reminderToLocalTime: (instant) => instant,
        reminderToUtcTime: (instant) => instant,
      ),
    ));
    await _pumpUntil(tester, () => controller.state.isReady);
    await tester.tap(find.byKey(
      const ValueKey<String>('handrail-remind-message-1'),
    ));
    await tester.pumpAndSettle();
    expect(find.textContaining('Revision 3'), findsOneWidget);

    await tester.tap(find.byKey(
      const ValueKey<String>('handrail-reminder-preset-1-hour'),
    ));
    await _pumpUntil(tester, () => transport.reminderRequests.length == 1);
    await _waitForReminderIdle(tester, controller);
    await _pumpUntil(
      tester,
      () => find.text("Reminder couldn't be updated").evaluate().isNotEmpty,
    );
    expect(find.textContaining(rawFailure), findsNothing);
    expect(find.textContaining('Revision 3'), findsOneWidget);
    expect(
      controller.messageReminder(const MessageId('message-1')).dueAt,
      initialDue,
    );

    await tester.tap(find.byKey(
      const ValueKey<String>('handrail-reminder-preset-20-minutes'),
    ));
    await _pumpUntil(tester, () => transport.reminderRequests.length == 2);
    await _waitForReminderIdle(tester, controller);
    await _pumpUntil(
      tester,
      () => find
          .text('Reminder changed on the server. Showing the latest schedule.')
          .evaluate()
          .isNotEmpty,
    );
    final conflictState =
        controller.messageReminder(const MessageId('message-1'));
    expect(conflictState.authoritativeRevision, 5);
    expect(conflictState.dueAt, const IsoTimestamp(serverDue));
    expect(conflictState.isPending, isFalse);
    expect(find.textContaining('Revision 5'), findsOneWidget);
    final requestBodies = transport.reminderRequests
        .map((request) => jsonDecode(request.body!) as Map<String, Object?>)
        .toList(growable: false);
    expect(
      requestBodies.map((body) => body['expectedReminderRevision']),
      orderedEquals([3, 3]),
    );
  });

  testWidgets(
      'Mark unread sends the read cursor mutation, exposes pending, and retains focus and scroll',
      (tester) async {
    final readCursorResponse = Completer<HandrailChatHttpResponse>();
    final transport = _TimelineTransport(
      initialResponse: Completer<HandrailChatHttpResponse>()
        ..complete(_response(_timeline(messages: [
          for (var value = 1; value <= 8; value++) _message(value),
        ]))),
      readCursorResponse: readCursorResponse,
    );
    final client = _client(transport);
    client.normalizedState.hydrateConversationDetail(
      ConversationDetailSnapshot.fromJson(_conversationDetail(
        latestSequence: 8,
        lastReadSequence: 8,
      )),
    );
    final controller = client.timeline(_conversationId);
    final scrollController = ScrollController();
    final semantics = tester.ensureSemantics();
    addTearDown(scrollController.dispose);
    addTearDown(client.dispose);

    await tester.pumpWidget(_host(
      client,
      SizedBox(
        height: 360,
        child: HandrailMessageTimeline(
          conversationId: _conversationId,
          controller: controller,
          scrollController: scrollController,
          isConversationActive: false,
        ),
      ),
    ));
    await _pumpUntil(tester, () => controller.state.isReady);
    for (var index = 0; index < 4; index += 1) {
      scrollController.jumpTo(scrollController.position.maxScrollExtent);
      await tester.pump();
    }

    final action = find.byKey(
      const ValueKey<String>('handrail-mark-unread-message-8'),
    );
    expect(action, findsOneWidget);
    final focusNode = tester.widget<TextButton>(action).focusNode!;
    focusNode.requestFocus();
    await tester.pump();
    expect(focusNode.hasFocus, isTrue);
    final offsetBefore = scrollController.offset;
    final invoke = tester.widget<TextButton>(action).onPressed!;

    invoke();
    invoke();
    await _pumpUntil(tester, () => transport.readCursorRequests.length == 1);

    expect(find.text('Marking unread…'), findsOneWidget);
    expect(
      find.bySemanticsLabel('Marking unread from message 8'),
      findsOneWidget,
    );
    expect(tester.widget<TextButton>(action).onPressed, isNull);
    expect(
      controller.state.currentUserReadState?.manualUnreadFromSequence,
      const MessageSequence(8),
    );
    expect(
      find.byKey(const ValueKey<String>('handrail-unread-8')),
      findsOneWidget,
    );
    expect(scrollController.offset, closeTo(offsetBefore, 1));

    final request = transport.readCursorRequests.single;
    final body = jsonDecode(request.body!) as Map<String, Object?>;
    expect(request.method, 'PATCH');
    expect(
      request.uri.path,
      '/api/chat/conversations/${_conversationId.value}/read-cursor',
    );
    expect(body['operation'], 'mark_unread');
    expect(body['fromSequence'], 8);
    readCursorResponse.complete(_readCursorSuccess(request));
    await _pumpUntil(
      tester,
      () => find.text('Message marked unread').evaluate().isNotEmpty,
    );

    expect(find.text('Mark unread'), findsWidgets);
    expect(find.bySemanticsLabel('Message marked unread'), findsOneWidget);
    expect(
      controller.state.currentUserReadState?.manualUnreadFromSequence,
      const MessageSequence(8),
    );
    expect(
      find.byKey(const ValueKey<String>('handrail-unread-8')),
      findsOneWidget,
    );
    expect(focusNode.hasFocus, isTrue);
    expect(scrollController.offset, closeTo(offsetBefore, 1));
    semantics.dispose();
  });

  testWidgets(
      'Mark unread announces sanitized failure and restores action focus',
      (tester) async {
    const rawFailure = 'raw upstream trace must stay private';
    final readCursorResponse = Completer<HandrailChatHttpResponse>();
    final transport = _TimelineTransport(
      initialResponse: Completer<HandrailChatHttpResponse>()
        ..complete(_response(_timeline(messages: [
          _message(1),
          _message(2),
          _message(3),
        ]))),
      readCursorResponse: readCursorResponse,
    );
    final client = _client(transport);
    client.normalizedState.hydrateConversationDetail(
      ConversationDetailSnapshot.fromJson(_conversationDetail(
        latestSequence: 3,
        lastReadSequence: 3,
      )),
    );
    final controller = client.timeline(_conversationId);
    final semantics = tester.ensureSemantics();
    addTearDown(client.dispose);

    await tester.pumpWidget(_host(
      client,
      HandrailMessageTimeline(
        conversationId: _conversationId,
        controller: controller,
        isConversationActive: false,
      ),
    ));
    await _pumpUntil(tester, () => controller.state.isReady);

    final action = find.byKey(
      const ValueKey<String>('handrail-mark-unread-message-2'),
    );
    final focusNode = tester.widget<TextButton>(action).focusNode!;
    focusNode.requestFocus();
    await tester.pump();
    tester.widget<TextButton>(action).onPressed!();
    await _pumpUntil(tester, () => transport.readCursorRequests.length == 1);

    readCursorResponse.complete(HandrailChatHttpResponse(
      statusCode: 400,
      body: jsonEncode(const {'error': rawFailure}),
    ));
    await _pumpUntil(
      tester,
      () =>
          find.text("Message couldn't be marked unread").evaluate().isNotEmpty,
    );

    expect(
      find.bySemanticsLabel("Message couldn't be marked unread"),
      findsOneWidget,
    );
    expect(find.textContaining(rawFailure), findsNothing);
    expect(
      tester.widget<SnackBar>(find.byType(SnackBar)).content.toStringDeep(),
      isNot(contains(rawFailure)),
    );
    expect(
      controller.state.currentUserReadState?.manualUnreadFromSequence,
      isNull,
    );
    expect(
        find.byKey(const ValueKey<String>('handrail-unread-2')), findsNothing);
    expect(tester.widget<TextButton>(action).onPressed, isNotNull);
    expect(focusNode.hasFocus, isTrue);
    semantics.dispose();
  });

  testWidgets('Mark unread excludes deleted and optimistic-only rows',
      (tester) async {
    final transport = _TimelineTransport(
      initialResponse: Completer<HandrailChatHttpResponse>()
        ..complete(_response(_timeline(messages: [
          _message(1),
          _message(2, deleted: true),
        ]))),
    );
    final client = _client(transport);
    client.normalizedState.hydrateConversationDetail(
      ConversationDetailSnapshot.fromJson(_conversationDetail(
        latestSequence: 3,
        lastReadSequence: 3,
      )),
    );
    final controller = client.timeline(_conversationId);
    addTearDown(client.dispose);

    await tester.pumpWidget(_host(
      client,
      HandrailMessageTimeline(
        conversationId: _conversationId,
        controller: controller,
        isConversationActive: false,
      ),
    ));
    await _pumpUntil(tester, () => controller.state.isReady);
    client.normalizedState.beginOptimisticMessageSend(
      clientMessageId: 'optimistic-mark-unread',
      projection: MessageTimelineMessage.fromJson(
        _message(3, id: 'optimistic-3'),
      ),
    );
    await tester.pump();

    expect(
      find.byKey(const ValueKey<String>('handrail-mark-unread-message-1')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey<String>('handrail-mark-unread-message-2')),
      findsNothing,
    );
    expect(
      find.byKey(const ValueKey<String>('handrail-mark-unread-optimistic-3')),
      findsNothing,
    );
    expect(
      find.byKey(const ValueKey<String>('handrail-remind-message-1')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey<String>('handrail-remind-message-2')),
      findsNothing,
    );
    expect(
      find.byKey(const ValueKey<String>('handrail-remind-optimistic-3')),
      findsNothing,
    );
  });

  testWidgets(
      'Copy writes visible text and confirms without exposing tombstones',
      (tester) async {
    const visibleText = 'Exact visible message text';
    final clipboardCalls = <MethodCall>[];
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async {
        if (call.method == 'Clipboard.setData') clipboardCalls.add(call);
        return null;
      },
    );
    addTearDown(() {
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        null,
      );
    });
    final transport = _TimelineTransport(
      initialResponse: Completer<HandrailChatHttpResponse>()
        ..complete(_response(_timeline(messages: [
          _message(1, text: visibleText),
          _message(2, deleted: true),
        ]))),
    );
    final client = _client(transport);
    final controller = client.timeline(_conversationId);
    final semantics = tester.ensureSemantics();
    addTearDown(client.dispose);

    await tester.pumpWidget(_host(
      client,
      HandrailMessageTimeline(
        conversationId: _conversationId,
        controller: controller,
      ),
    ));
    await _pumpUntil(tester, () => controller.state.isReady);

    final copy = find.byKey(
      const ValueKey<String>('handrail-copy-message-1'),
    );
    expect(copy, findsOneWidget);
    expect(
      find.byKey(const ValueKey<String>('handrail-copy-message-2')),
      findsNothing,
    );

    await tester.tap(copy);
    await tester.pump();

    expect(clipboardCalls, hasLength(1));
    expect(clipboardCalls.single.method, 'Clipboard.setData');
    expect(clipboardCalls.single.arguments, const {'text': visibleText});
    expect(find.text('Message copied'), findsOneWidget);
    expect(find.bySemanticsLabel('Message copied'), findsOneWidget);
    expect(find.textContaining(visibleText), findsOneWidget);
    final snackBar = tester.widget<SnackBar>(find.byType(SnackBar));
    expect(snackBar.content.toStringDeep(), isNot(contains(visibleText)));
    semantics.dispose();
  });

  testWidgets('Copy announces clipboard failure without echoing message text',
      (tester) async {
    const visibleText = 'Clipboard payload must stay private';
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async {
        if (call.method == 'Clipboard.setData') {
          throw PlatformException(code: 'clipboard-unavailable');
        }
        return null;
      },
    );
    addTearDown(() {
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        null,
      );
    });
    final transport = _TimelineTransport(
      initialResponse: Completer<HandrailChatHttpResponse>()
        ..complete(_response(_timeline(messages: [
          _message(1, text: visibleText),
        ]))),
    );
    final client = _client(transport);
    final controller = client.timeline(_conversationId);
    final semantics = tester.ensureSemantics();
    addTearDown(client.dispose);

    await tester.pumpWidget(_host(
      client,
      HandrailMessageTimeline(
        conversationId: _conversationId,
        controller: controller,
      ),
    ));
    await _pumpUntil(tester, () => controller.state.isReady);

    await tester.tap(find.byKey(
      const ValueKey<String>('handrail-copy-message-1'),
    ));
    await tester.pump();

    expect(find.text("Message couldn't be copied"), findsOneWidget);
    expect(
      find.bySemanticsLabel("Message couldn't be copied"),
      findsOneWidget,
    );
    final snackBar = tester.widget<SnackBar>(find.byType(SnackBar));
    expect(
      snackBar.content.toStringDeep(),
      isNot(contains(visibleText)),
    );
    semantics.dispose();
  });

  testWidgets('renders empty, retryable error, and access-revoked builders',
      (tester) async {
    final emptyTransport = _TimelineTransport(
      initialResponse: Completer<HandrailChatHttpResponse>()
        ..complete(_response(_timeline(messages: const []))),
    );
    final emptyClient = _client(emptyTransport);
    emptyClient.normalizedState.hydrateConversationDetail(
      ConversationDetailSnapshot.fromJson(_conversationDetail(
        latestSequence: 0,
        lastReadSequence: 0,
      )),
    );
    final emptyController = emptyClient.timeline(_conversationId);
    final invoked = <String>[];
    final builders = ChatWidgetBuilders(
      emptyConversation: (context, input) {
        invoked.add('empty:${input.conversation.id.value}');
        return const Text('Custom empty');
      },
      error: (context, input) {
        invoked.add(
          'error:${input.timelineActions == null ? 'terminal' : 'retryable'}',
        );
        return Text('Custom error: ${input.message}');
      },
    );
    await tester.pumpWidget(_host(
      emptyClient,
      HandrailMessageTimeline(
        conversationId: _conversationId,
        controller: emptyController,
        builders: builders,
      ),
    ));
    await _pumpUntil(tester, () => emptyController.state.isReady);
    expect(find.text('Custom empty'), findsOneWidget);
    expect(invoked, contains('empty:${_conversationId.value}'));
    await tester.pumpWidget(const SizedBox.shrink());
    await emptyClient.dispose();

    final errorTransport = _TimelineTransport(statusCode: 500);
    final errorClient = _client(errorTransport);
    final errorController = errorClient.timeline(_conversationId);
    await tester.pumpWidget(_host(
      errorClient,
      HandrailMessageTimeline(
        conversationId: _conversationId,
        controller: errorController,
        builders: builders,
      ),
    ));
    await _pumpUntil(
      tester,
      () => errorController.state.status == ChatTimelineControllerStatus.error,
    );
    expect(find.textContaining('Custom error:'), findsOneWidget);
    expect(invoked, contains('error:retryable'));
    await tester.pumpWidget(const SizedBox.shrink());
    await errorClient.dispose();

    final deniedTransport = _TimelineTransport(statusCode: 403);
    final deniedClient = _client(deniedTransport);
    final deniedController = deniedClient.timeline(_conversationId);
    final semantics = tester.ensureSemantics();
    await tester.pumpWidget(_host(
      deniedClient,
      HandrailMessageTimeline(
        conversationId: _conversationId,
        controller: deniedController,
        builders: builders,
      ),
    ));
    await _pumpUntil(
      tester,
      () =>
          deniedController.state.status ==
          ChatTimelineControllerStatus.accessRevoked,
    );
    expect(
      find.bySemanticsLabel(RegExp('Conversation access revoked')),
      findsOneWidget,
    );
    expect(invoked, contains('error:terminal'));
    semantics.dispose();
    await tester.pumpWidget(const SizedBox.shrink());
    await deniedClient.dispose();
  });

  testWidgets(
      'releases listeners on controller replacement and ignores late pagination',
      (tester) async {
    final lateEarlier = Completer<HandrailChatHttpResponse>();
    final firstTransport = _TimelineTransport(
      initialResponse: Completer<HandrailChatHttpResponse>()
        ..complete(_response(_timeline(
          messages: [for (var value = 3; value <= 8; value++) _message(value)],
          older: 3,
        ))),
      earlierResponses: [
        Future.value(HandrailChatHttpResponse(
          statusCode: 500,
          body: jsonEncode(const {'error': 'fixture failure'}),
        )),
        lateEarlier.future,
      ],
    );
    final secondTransport = _TimelineTransport(
      conversationId: _otherConversationId,
      initialResponse: Completer<HandrailChatHttpResponse>()
        ..complete(_response(_timeline(
          conversationId: _otherConversationId,
          messages: [
            _message(
              1,
              conversationId: _otherConversationId,
              id: 'other-message-1',
              text: 'Replacement message',
            )
          ],
        ))),
    );
    final firstClient = _client(firstTransport);
    final secondClient = _client(secondTransport);
    final firstController = firstClient.timeline(_conversationId);
    final secondController = secondClient.timeline(_otherConversationId);
    final scrollController = ScrollController();
    addTearDown(scrollController.dispose);
    late StateSetter rebuild;
    var useFirst = true;

    await tester.pumpWidget(StatefulBuilder(builder: (context, setState) {
      rebuild = setState;
      final client = useFirst ? firstClient : secondClient;
      final controller = useFirst ? firstController : secondController;
      final conversationId = useFirst ? _conversationId : _otherConversationId;
      return _host(
        client,
        SizedBox(
          height: 240,
          child: HandrailMessageTimeline(
            conversationId: conversationId,
            controller: controller,
            scrollController: scrollController,
          ),
        ),
      );
    }));
    await _pumpUntil(tester, () => firstController.state.isReady);
    scrollController.jumpTo(0);
    await _pumpUntil(tester, () => firstTransport.earlierRequestCount == 1);
    await _pumpUntil(
      tester,
      () => find
          .byKey(
            const ValueKey<String>('handrail-timeline-earlier-error'),
          )
          .evaluate()
          .isNotEmpty,
    );
    scrollController.jumpTo(0);
    await tester.pump();
    await tester.tap(
      find.byKey(
        const ValueKey<String>('handrail-timeline-retry-earlier'),
      ),
    );
    await _pumpUntil(tester, () => firstTransport.earlierRequestCount == 2);

    rebuild(() => useFirst = false);
    await _pumpUntil(tester, () => secondController.state.isReady);
    expect(find.text('Replacement message'), findsOneWidget);
    expect(
      find.byKey(const ValueKey<String>('handrail-timeline-earlier-error')),
      findsNothing,
    );
    lateEarlier
        .complete(_response(_timeline(messages: [_message(2)], newer: 2)));
    await tester.pump();
    await tester.pump();
    expect(tester.takeException(), isNull);
    expect(firstController.state.isDisposed, isFalse);
    expect(secondController.state.isDisposed, isFalse);

    await tester.pumpWidget(const SizedBox.shrink());
    expect(firstController.state.isDisposed, isFalse);
    expect(secondController.state.isDisposed, isFalse);
    await firstClient.dispose();
    await secondClient.dispose();
  });
}

HandrailChatClient _client(
  _TimelineTransport transport, {
  Duration minimumExposure = const Duration(milliseconds: 500),
}) =>
    HandrailChatClient(
      apiBaseUri: Uri.parse('https://chat.test/api/chat'),
      tokenProvider: () async => 'timeline-widget-token',
      transport: transport,
      readVisibilityMinimumExposure: minimumExposure,
      generateClientMessageId: () => 'widget-client-message',
      generateIdempotencyKey: () => 'widget-idempotency-key',
      commandRetryOptions: const ChatCommandRetryOptions(maxAttempts: 1),
    );

Widget _host(HandrailChatClient client, Widget child) => MaterialApp(
      home: ChatScope(client: client, child: Scaffold(body: child)),
    );

final class _TimelineTransport implements HandrailChatHttpTransport {
  _TimelineTransport({
    this.conversationId = _conversationId,
    this.statusCode = 200,
    this.initialResponse,
    this.earlierResponse,
    this.earlierResponses = const [],
    this.readCursorResponse,
    this.reminderHandler,
  });

  final ConversationId conversationId;
  int statusCode;
  final Completer<HandrailChatHttpResponse>? initialResponse;
  final Completer<HandrailChatHttpResponse>? earlierResponse;
  final List<Future<HandrailChatHttpResponse>> earlierResponses;
  final Completer<HandrailChatHttpResponse>? readCursorResponse;
  final Future<HandrailChatHttpResponse> Function(
    HandrailChatHttpRequest request,
    int requestIndex,
  )? reminderHandler;
  final List<HandrailChatHttpRequest> requests = [];

  int get earlierRequestCount => requests
      .where((request) =>
          request.method == 'GET' &&
          request.uri.queryParameters.containsKey('before'))
      .length;

  List<HandrailChatHttpRequest> get reminderRequests => requests
      .where((request) =>
          request.method == 'PUT' && request.uri.path.endsWith('/reminder'))
      .toList(growable: false);

  @override
  Future<HandrailChatHttpResponse> send(HandrailChatHttpRequest request) async {
    requests.add(request);
    if (request.method == 'GET' && request.uri.path.endsWith('/messages')) {
      if (statusCode != 200) {
        return HandrailChatHttpResponse(
          statusCode: statusCode,
          body: jsonEncode(const {'error': 'fixture failure'}),
        );
      }
      if (request.uri.queryParameters.containsKey('before')) {
        final responseIndex = earlierRequestCount - 1;
        if (responseIndex < earlierResponses.length) {
          return await earlierResponses[responseIndex];
        }
        if (earlierResponse != null) return await earlierResponse!.future;
        return _response(
          _timeline(conversationId: conversationId, messages: const []),
        );
      }
      if (initialResponse != null) return await initialResponse!.future;
      return _response(
        _timeline(conversationId: conversationId, messages: const []),
      );
    }
    if (request.method == 'PATCH' &&
        request.uri.path.endsWith('/read-cursor') &&
        readCursorResponse != null) {
      return await readCursorResponse!.future;
    }
    if (request.method == 'PUT' &&
        request.uri.path.endsWith('/reminder') &&
        reminderHandler != null) {
      return reminderHandler!(request, reminderRequests.length - 1);
    }
    return HandrailChatHttpResponse(
      statusCode: 400,
      body: jsonEncode(const {'error': 'recorded fixture command'}),
    );
  }

  List<HandrailChatHttpRequest> get readCursorRequests => requests
      .where((request) =>
          request.method == 'PATCH' &&
          request.uri.path.endsWith('/read-cursor'))
      .toList(growable: false);
}

HandrailChatHttpResponse _response(Object body) => HandrailChatHttpResponse(
      statusCode: 200,
      body: jsonEncode(body),
    );

HandrailChatHttpResponse _readCursorSuccess(HandrailChatHttpRequest request) {
  final body = jsonDecode(request.body!) as Map<String, Object?>;
  final fromSequence = body['fromSequence']! as int;
  return _response({
    'operation': 'mark_unread',
    'reconciliationStatus': 'applied',
    'idempotencyKey': body['idempotencyKey'],
    'conversationId': body['conversationId'],
    'readState': {
      'conversationId': body['conversationId'],
      'userId': _userId,
      'lastReadSequence': 8,
      'manualUnreadFromSequence': fromSequence,
      'updatedAt': '2026-08-26T22:01:00.000Z',
    },
    'latestSequence': 8,
    'unreadCount': 8 - (fromSequence - 1),
  });
}

HandrailChatHttpResponse _reminderResponse(
  HandrailChatHttpRequest request, {
  required int reminderRevision,
  String reconciliationStatus = 'applied',
  String? authoritativeDueAt,
  bool authoritativeCancelled = false,
  int statusCode = 200,
}) {
  final body = jsonDecode(request.body!) as Map<String, Object?>;
  final intent = body['intent']! as String;
  final reminder = authoritativeCancelled ||
          (intent == 'cancel' && authoritativeDueAt == null)
      ? const <String, Object?>{
          'privacy': 'affected_authenticated_actor',
          'state': 'cancelled',
        }
      : <String, Object?>{
          'privacy': 'affected_authenticated_actor',
          'state': 'scheduled',
          'dueAt': authoritativeDueAt ?? body['dueAt'],
        };
  return HandrailChatHttpResponse(
    statusCode: statusCode,
    body: jsonEncode({
      'operation': 'message_reminder.v1',
      'intent': intent,
      'reconciliationStatus': reconciliationStatus,
      'conversationId': body['conversationId'],
      'messageId': body['messageId'],
      'expectedReminderRevision': body['expectedReminderRevision'],
      'idempotencyKey': body['idempotencyKey'],
      'reminderRevision': reminderRevision,
      'reminder': reminder,
    }),
  );
}

Map<String, Object?> _timeline({
  ConversationId conversationId = _conversationId,
  required List<Map<String, Object?>> messages,
  int? older,
  int? newer,
}) =>
    {
      'conversationId': conversationId.value,
      'messages': messages,
      'pagination': {
        'older': older == null
            ? {'available': false}
            : {'available': true, 'cursor': older},
        'newer': newer == null
            ? {'available': false}
            : {'available': true, 'cursor': newer},
      },
      'replay': {
        'resumeFrom': {'eventId': 'timeline-widget-snapshot'},
      },
    };

Map<String, Object?> _message(
  int sequence, {
  ConversationId conversationId = _conversationId,
  String? id,
  String? text,
  bool deleted = false,
  Map<String, Object?>? threadSummary,
  List<Map<String, Object?>> reactions = const [],
  bool attachment = false,
  bool block = false,
}) {
  final attachmentId = 'attachment-$sequence';
  return {
    'id': id ?? 'message-$sequence',
    'tenantId': _tenantId,
    'conversationId': conversationId.value,
    'author': {'type': 'user', 'userId': 'user-$sequence'},
    'sequence': sequence,
    'createdAt': _now,
    'updatedAt': _now,
    'revision': {'revision': 1},
    if (threadSummary != null) 'threadSummary': threadSummary,
    if (!deleted)
      'content': {
        'format': 'plain',
        'text': text ?? 'message $sequence',
        if (attachment)
          'attachments': [
            {'attachmentId': attachmentId},
          ],
        if (block)
          'blocks': [
            {
              'type': 'unsupported-forward-block',
              'data': {'label': 'Structured content'},
            },
          ],
      },
    if (deleted) ...{
      'content': null,
      'deletedAt': _now,
      'deletedByUserId': _userId,
    },
    'isThreadRoot': threadSummary != null,
    'reactions': reactions,
    'attachmentMetadata': attachment
        ? [
            {
              'attachmentId': attachmentId,
              'fileName': 'report.pdf',
              'contentType': 'application/pdf',
              'sizeBytes': 42,
              'downloadUrl': 'https://files.test/report.pdf',
            }
          ]
        : <Object?>[],
  };
}

Map<String, Object?> _canonicalMessage(
  int sequence, {
  required String text,
}) {
  final message = Map<String, Object?>.of(_message(sequence, text: text));
  message
    ..remove('isThreadRoot')
    ..remove('reactions')
    ..remove('attachmentMetadata');
  return message;
}

KnownDurableEvent _createdEvent(
  int sequence, {
  required String clientMessageId,
  required String eventId,
  required String text,
}) =>
    KnownDurableEvent.fromJson(
      {
        'eventId': eventId,
        'protocolVersion': handrailChatDurableEventProtocolVersion,
        'tenantId': _tenantId,
        'streamId': _conversationId.value,
        'type': 'message.created',
        'occurredAt': DateTime.parse(_now)
            .add(Duration(seconds: sequence))
            .toIso8601String(),
        'payload': {
          'message': _canonicalMessage(sequence, text: text),
          'clientMessageId': clientMessageId,
        },
      },
      trustedIdentity: const DurableEventTrustedIdentity(
        tenantId: TenantId(_tenantId),
        userId: UserId(_userId),
      ),
    );

Map<String, Object?> _conversationDetail({
  required int latestSequence,
  required int lastReadSequence,
  int? manualUnreadFromSequence,
  String readUpdatedAt = _now,
}) =>
    {
      'kind': 'conversation_detail',
      'conversation': {
        'id': _conversationId.value,
        'tenantId': _tenantId,
        'type': 'channel',
        'name': 'Timeline widget fixture',
        'visibility': 'public',
        'createdAt': _now,
        'updatedAt': _now,
        'latestSequence': latestSequence,
        'activityAt': _now,
        'unreadMentionCount': 0,
        'currentMember': {
          'tenantId': _tenantId,
          'conversationId': _conversationId.value,
          'userId': _userId,
          'role': 'member',
          'state': 'active',
          'joinedAt': _now,
          'updatedAt': _now,
        },
        'currentReadState': {
          'conversationId': _conversationId.value,
          'userId': _userId,
          'lastReadSequence': lastReadSequence,
          if (manualUnreadFromSequence != null)
            'manualUnreadFromSequence': manualUnreadFromSequence,
          'updatedAt': readUpdatedAt,
        },
        'currentPreference': {
          'conversationId': _conversationId.value,
          'userId': _userId,
          'notificationPreference': 'all',
          'isStarred': false,
          'mute': {'muted': false},
          'updatedAt': _now,
        },
        'activeMemberUserIds': [_userId],
        'memberUserIds': [_userId],
      },
      '_meta': {
        'packageVersion': '0.1.3',
        'protocolVersion': 4,
        'schemaVersion': 9,
        'enabledFeatures': {conversationSnapshotFeature: true},
        'supportedProtocolRange': {
          'minimumVersion': 3,
          'maximumVersion': 4,
        },
        'feature': {
          'name': conversationSnapshotFeature,
          'version': conversationSnapshotVersion,
        },
      },
    };

Future<void> _pumpUntil(
  WidgetTester tester,
  bool Function() predicate,
) async {
  for (var index = 0; index < 100 && !predicate(); index += 1) {
    await tester.pump();
  }
  expect(predicate(), isTrue,
      reason: 'Asynchronous widget work did not settle.');
  await tester.pump();
}

Future<void> _waitForReminderIdle(
  WidgetTester tester,
  ChatTimelineController controller,
) async {
  await tester.runAsync(() async {
    for (var index = 0;
        index < 100 &&
            controller.messageReminder(const MessageId('message-1')).isPending;
        index += 1) {
      await Future<void>.delayed(const Duration(milliseconds: 1));
    }
  });
  await tester.pump();
  expect(
    controller.messageReminder(const MessageId('message-1')).isPending,
    isFalse,
    reason: 'The reminder command did not settle.',
  );
}
