import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:handrail_chat/ui.dart';

import 'fixtures/thread_creation_fixtures.dart';
import 'fixtures/draft_mutation_fixtures.dart';
import 'fixtures/thread_follow_mutation_fixtures.dart';
import 'fixtures/conversation_preference_fixtures.dart';

part 'handrail_thread_lifecycle_cases.dart';
part 'handrail_thread_subscription_cases.dart';

const _rootId = MessageId('message-root');
const _parentId = ConversationId('conversation-parent');
const _threadId = ConversationId('conversation-thread');
const _otherRootId = MessageId('message-other-root');
const _otherThreadId = ConversationId('conversation-other-thread');
const _tenantId = 'tenant-from-session';
const _now = '2026-08-26T16:00:00.000Z';

void main() {
  _lifecycleTests();
  _subscriptionTests();
  testWidgets(
      'renders a caller-owned existing thread, root, replies, composer, and close callback',
      (tester) async {
    final harness = _Harness(existingThread: true);
    addTearDown(() => _disposeLifecycleHarness(tester, harness));
    final opened = await harness.client.threads.open(rootMessageId: _rootId)
        as ChatThreadOpenSuccess;
    var closeCount = 0;

    await tester.pumpWidget(_host(
      harness.client,
      SizedBox(
        width: 360,
        height: 640,
        child: HandrailThreadView(
          rootMessage: _rootMessage(),
          openHandle: opened.handle,
          onClose: () => closeCount += 1,
        ),
      ),
    ));
    await _pumpUntil(
      tester,
      () => find.text('First thread reply').evaluate().isNotEmpty,
    );

    // This fixture supplies no current parent access. Preserve the access-aware
    // root renderer rather than exposing the caller's cached root message.
    expect(find.text('Root message unavailable'), findsOneWidget);
    expect(find.text('First thread reply'), findsOneWidget);
    expect(find.byType(HandrailMessageTimeline), findsOneWidget);
    final composer = tester.widget<HandrailMessageComposer>(
      find.byType(HandrailMessageComposer),
    );
    expect(composer.conversationId, _threadId);
    await tester.tap(find.byKey(const ValueKey('handrail-thread-close')));
    expect(closeCount, 1);
    expect(find.byTooltip('Close panel'), findsOneWidget);
    expect(harness.transport.lifecycleWrites, isEmpty);

    await tester.pumpWidget(const SizedBox.shrink());
    expect(opened.handle.isReleased, isFalse);
    opened.handle.release();
  });

  for (final httpStatus in [401, 403]) {
    testWidgets(
        'hides cached archived replies after HTTP $httpStatus until recovery',
        (tester) async {
      final harness = _Harness(existingThread: true);
      addTearDown(() => _disposeLifecycleHarness(tester, harness));
      final archived = _lifecycleDetail(_rootId, _threadId);
      (archived['conversation'] as Map<String, Object?>)
        ..['updatedAt'] = '2026-08-26T16:01:00.000Z'
        ..['archivedAt'] = '2026-08-26T16:01:00.000Z'
        ..['archivedByUserId'] = 'user-current';
      harness.transport.lifecycleRead = () async => _lifecycleResponse(archived);
      await _prepareLifecycle(tester, harness);
      await _mountLifecycle(tester, harness, width: 390);
      expect(find.text('First thread reply'), findsOneWidget);
      expect(tester.widget<TextField>(find.byKey(_composerInput)).enabled,
          isFalse);

      final timeline = harness.client.timeline(_threadId);
      final conversation = harness.client.conversations.forId(_threadId);
      for (final status in [httpStatus, 500]) {
        harness.transport.timelineRead =
            () async => _lifecycleResponse({}, status);
        harness.transport.lifecycleRead =
            () async => _lifecycleResponse({}, status);
        await tester.runAsync(() async {
          await conversation.refresh();
          await timeline.refresh();
        });
        await _settleLifecycle(tester);
        expect(find.text('First thread reply'), findsNothing);
        expect(find.byType(HandrailMessageTimeline), findsOneWidget);
        expect(timeline.state.status,
            ChatTimelineControllerStatus.accessRevoked);
        // The cache still exists; access state must gate its rendering.
        expect(timeline.state.messages, isNotEmpty);
      }

      harness.transport.timelineRead = null;
      harness.transport.lifecycleRead = () async => _lifecycleResponse(archived);
      await tester.runAsync(() async {
        await conversation.refresh();
        await timeline.refresh();
      });
      await _settleLifecycle(tester);
      expect(find.text('First thread reply'), findsOneWidget);
      expect(tester.widget<TextField>(find.byKey(_composerInput)).enabled,
          isFalse);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('opens and creates a canonical thread then releases its retain',
      (tester) async {
    final creation = Completer<HandrailChatHttpResponse>();
    final harness = _Harness(threadCreation: creation);
    addTearDown(() => _disposeLifecycleHarness(tester, harness));
    final controller = harness.client.threads.forRoot(_rootId);

    await tester.pumpWidget(_host(
      harness.client,
      SizedBox(
        height: 600,
        child: HandrailThreadView(rootMessage: _rootMessage()),
      ),
    ));
    expect(find.bySemanticsLabel('Opening thread'), findsOneWidget);
    expect(controller.state, isA<ChatThreadOpeningLoadingState>());

    creation.complete(HandrailChatHttpResponse(
      statusCode: 201,
      body: jsonEncode(threadCreationResultFixture('created')),
    ));
    await tester.runAsync(() => Future<void>.delayed(Duration.zero));
    await _pumpUntil(
      tester,
      () => find.byType(HandrailMessageComposer).evaluate().isNotEmpty,
      diagnostic: () => 'controller=${controller.state}',
    );
    expect(
      harness.transport.requests.where(
        (request) =>
            request.method == 'POST' &&
            request.uri.path.endsWith('/messages/message-root/thread'),
      ),
      hasLength(1),
    );
    expect(controller.state, isA<ChatThreadOpeningReadyState>());

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
    expect(controller.state, isA<ChatThreadOpeningIdleState>());
    expect(controller.state.toString(), isNot(contains('closed')));
  });

  testWidgets('projects unavailable, access-denied, and general error states',
      (tester) async {
    final cases = <({
      _Harness harness,
      String label,
      HandrailThreadFailureKind kind,
    })>[
      (
        harness: _Harness(seedRoot: false),
        label: 'unavailable',
        kind: HandrailThreadFailureKind.unavailable,
      ),
      (
        harness: _Harness(threadStatusCode: 403),
        label: 'access denied',
        kind: HandrailThreadFailureKind.accessDenied,
      ),
      (
        harness: _Harness(threadStatusCode: 500),
        label: 'error',
        kind: HandrailThreadFailureKind.error,
      ),
    ];
    for (final testCase in cases) {
      addTearDown(() => _disposeLifecycleHarness(tester, testCase.harness));
      HandrailThreadFailureKind? observedKind;
      await tester.pumpWidget(_host(
        testCase.harness.client,
        SizedBox(
          height: 520,
          child: HandrailThreadView(
            rootMessageId: _rootId,
            failureBuilder: (context, input) {
              observedKind = input.kind;
              return Text('Thread ${testCase.label}');
            },
          ),
        ),
      ));
      await tester.runAsync(() => Future<void>.delayed(Duration.zero));
      await _pumpUntil(
        tester,
        () => find.text('Thread ${testCase.label}').evaluate().isNotEmpty,
        diagnostic: () =>
            'controller=${testCase.harness.client.threads.forRoot(_rootId).state}',
      );
      expect(observedKind, testCase.kind);
      await tester.pumpWidget(const SizedBox.shrink());
    }
  });

  testWidgets('applies root/message builders and Handrail theme tokens',
      (tester) async {
    final harness = _Harness(existingThread: true);
    addTearDown(() => _disposeLifecycleHarness(tester, harness));
    final theme = ThemeData(
      extensions: const [
        HandrailChatTheme(
          spacing: HandrailChatSpacing(medium: 23),
        ),
      ],
    );
    final builders = ChatWidgetBuilders(
      message: (context, input) => Text('built ${input.message.id.value}'),
    );

    await tester.pumpWidget(_host(
      harness.client,
      SizedBox(
        height: 620,
        child: HandrailThreadView(
          rootMessage: _rootMessage(),
          builders: builders,
          rootBuilder: (context, input) => Text(
            'root ${input.rootMessageId.value} spacing '
            '${HandrailChatTheme.of(context).spacing.medium}',
          ),
        ),
      ),
      theme: theme,
    ));
    await _pumpUntil(
      tester,
      () => find.text('built reply-1').evaluate().isNotEmpty,
    );

    expect(find.text('root message-root spacing 23.0'), findsOneWidget);
    expect(find.text('built reply-1'), findsOneWidget);
  });

  testWidgets('is safe under narrow, wide, and unbounded-height constraints',
      (tester) async {
    final harness = _Harness(existingThread: true);
    addTearDown(() => _disposeLifecycleHarness(tester, harness));

    for (final width in <double>[240, 760]) {
      await tester.pumpWidget(_host(
        harness.client,
        SizedBox(
          width: width,
          height: 560,
          child: HandrailThreadView(rootMessage: _rootMessage()),
        ),
      ));
      await _pumpUntil(
        tester,
        () => find.byType(HandrailMessageTimeline).evaluate().isNotEmpty,
      );
      expect(tester.takeException(), isNull);
      expect(
        tester.getSize(find.byType(HandrailThreadView)).width,
        width,
      );
    }

    await tester.pumpWidget(_host(
      harness.client,
      SingleChildScrollView(
        child: HandrailThreadView(
          rootMessage: _rootMessage(),
          unboundedTimelineHeight: 180,
        ),
      ),
    ));
    await tester.pump();
    expect(tester.takeException(), isNull);
    expect(
      tester
          .getSize(
            find.byKey(
              const ValueKey(
                'handrail-thread-timeline-conversation-thread',
              ),
            ),
          )
          .height,
      180,
    );
  });

  testWidgets(
      'rebinds controllers and releases a stale asynchronously opened handle',
      (tester) async {
    final firstCreation = Completer<HandrailChatHttpResponse>();
    final secondCreation = Completer<HandrailChatHttpResponse>();
    final first = _Harness(threadCreation: firstCreation);
    final second = _Harness(
      rootId: _otherRootId,
      threadId: _otherThreadId,
      threadCreation: secondCreation,
    );
    addTearDown(() => _disposeLifecycleHarness(tester, first));
    addTearDown(() => _disposeLifecycleHarness(tester, second));
    final firstController = first.client.threads.forRoot(_rootId);
    final secondController = second.client.threads.forRoot(_otherRootId);

    await tester.pumpWidget(_host(
      first.client,
      SizedBox(
        height: 560,
        child: HandrailThreadView(openingController: firstController),
      ),
    ));
    expect(firstController.state, isA<ChatThreadOpeningLoadingState>());

    await tester.pumpWidget(_host(
      first.client,
      SizedBox(
        height: 560,
        child: HandrailThreadView(openingController: secondController),
      ),
    ));
    secondCreation.complete(HandrailChatHttpResponse(
      statusCode: 201,
      body: jsonEncode(threadCreationResultFixture(
        'created',
        rootMessageId: _otherRootId.value,
        threadId: _otherThreadId.value,
        summaryThreadId: _otherThreadId.value,
      )),
    ));
    await tester.runAsync(() => Future<void>.delayed(Duration.zero));
    await _pumpUntil(
      tester,
      () => secondController.state is ChatThreadOpeningReadyState,
      diagnostic: () => 'second=$secondController',
    );

    firstCreation.complete(HandrailChatHttpResponse(
      statusCode: 201,
      body: jsonEncode(threadCreationResultFixture('created')),
    ));
    await tester.runAsync(() => Future<void>.delayed(Duration.zero));
    await _pumpUntil(
      tester,
      () => firstController.state is ChatThreadOpeningIdleState,
      diagnostic: () => 'first=${firstController.state}',
    );
    expect(secondController.state, isA<ChatThreadOpeningReadyState>());

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
    expect(secondController.state, isA<ChatThreadOpeningIdleState>());
    expect(firstController.state, isA<ChatThreadOpeningIdleState>());
  });
}

Widget _host(
  HandrailChatClient client,
  Widget child, {
  ThemeData? theme,
}) =>
    MaterialApp(
      theme: theme,
      home: ChatScope(
          key: ObjectKey(client), client: client, child: Scaffold(body: child)),
    );

final class _Harness {
  _Harness({
    bool seedRoot = true,
    bool existingThread = false,
    int threadStatusCode = 201,
    Completer<HandrailChatHttpResponse>? threadCreation,
    MessageId rootId = _rootId,
    ConversationId threadId = _threadId,
  })  : store = NormalizedSnapshotStore(),
        transport = _ThreadTransport(
          rootId: rootId,
          threadId: threadId,
          threadStatusCode: threadStatusCode,
          threadCreation: threadCreation,
        ) {
    if (seedRoot) _seedRoot(store, rootId: rootId);
    if (existingThread) {
      store.reconcileThreadOpening(_threadResult(
        rootId: rootId,
        threadId: threadId,
      ));
    }
    var commandKey = 0;
    client = HandrailChatClient(
      apiBaseUri: Uri.parse('https://chat.example.test/api/chat/'),
      tokenProvider: () async => 'thread-view-token',
      transport: transport,
      commandRetryOptions: const ChatCommandRetryOptions(maxAttempts: 1),
      generateIdempotencyKey: () => 'thread-view-${++commandKey}',
      normalizedSnapshotStore: store,
      requestedCapabilities: {
        ChatReplyThreadFeatures.threadLifecycle: true,
        'inline_replies_v1': true
      },
    );
  }

  final NormalizedSnapshotStore store;
  final _ThreadTransport transport;
  late final HandrailChatClient client;

  Future<void> dispose() async {
    await client.dispose();
    await store.close();
  }
}

final class _ThreadTransport implements HandrailChatHttpTransport {
  _ThreadTransport({
    required this.rootId,
    required this.threadId,
    required this.threadStatusCode,
    required this.threadCreation,
  });

  final MessageId rootId;
  final ConversationId threadId;
  final int threadStatusCode;
  final Completer<HandrailChatHttpResponse>? threadCreation;
  final List<HandrailChatHttpRequest> requests = [];
  bool lifecycleSupported = true;
  Future<HandrailChatHttpResponse> Function(HandrailChatHttpRequest)?
      lifecycleWrite;
  Future<HandrailChatHttpResponse> Function()? lifecycleRead;
  Future<HandrailChatHttpResponse> Function()? timelineRead;
  Future<HandrailChatHttpResponse> Function(HandrailChatHttpRequest)?
      subscriptionWrite;
  List<HandrailChatHttpRequest> get subscriptionWrites => requests
      .where((r) =>
          r.method == 'PATCH' &&
          (r.uri.path.endsWith('/follow') ||
              r.uri.path.endsWith('/preference')))
      .toList();
  List<HandrailChatHttpRequest> get lifecycleWrites => requests
      .where((r) => r.method == 'PATCH' && r.uri.path.endsWith('/lifecycle'))
      .toList();

  @override
  Future<HandrailChatHttpResponse> send(HandrailChatHttpRequest request) async {
    requests.add(request);
    if (request.method == 'PATCH' &&
        (request.uri.path.endsWith('/follow') ||
            request.uri.path.endsWith('/preference'))) {
      return subscriptionWrite != null
          ? await subscriptionWrite!(request)
          : _subscriptionResponse(request);
    }
    if (request.uri.path.endsWith('/_meta')) {
      return _lifecycleResponse({
        'packageVersion': '0.1.4',
        'protocolVersion': 4,
        'schemaVersion': 1,
        'enabledFeatures': {
          ChatReplyThreadFeatures.threadLifecycle: lifecycleSupported,
          'inline_replies_v1': true
        },
        'supportedProtocolRange': {'minimumVersion': 1, 'maximumVersion': 4},
      });
    }
    if (request.method == 'GET' &&
        request.uri.path.endsWith('/conversations/${threadId.value}')) {
      return lifecycleRead != null
          ? await lifecycleRead!()
          : _lifecycleResponse(_lifecycleDetail(rootId, threadId));
    }
    if (request.method == 'PATCH' && request.uri.path.endsWith('/lifecycle')) {
      return lifecycleWrite != null
          ? await lifecycleWrite!(request)
          : _lifecycleResponse(_lifecycleResult(request));
    }
    if (request.method == 'POST' &&
        request.uri.path.endsWith('/messages/${rootId.value}/thread')) {
      if (threadCreation != null) return threadCreation!.future;
      return HandrailChatHttpResponse(
        statusCode: threadStatusCode,
        body: threadStatusCode >= 200 && threadStatusCode < 300
            ? jsonEncode(threadCreationResultFixture(
                'created',
                rootMessageId: rootId.value,
                threadId: threadId.value,
                summaryThreadId: threadId.value,
              ))
            : jsonEncode(const {'error': 'thread fixture failure'}),
      );
    }
    if (request.method == 'GET' &&
        request.uri.path
            .endsWith('/conversations/${threadId.value}/messages')) {
      if (timelineRead != null) return timelineRead!();
      return HandrailChatHttpResponse(
        statusCode: 200,
        body: jsonEncode(_timelinePage(threadId)),
      );
    }
    return const HandrailChatHttpResponse(
      statusCode: 400,
      body: '{"error":"unexpected fixture request"}',
    );
  }
}

ThreadCreationResult _threadResult({
  required MessageId rootId,
  required ConversationId threadId,
}) =>
    ThreadCreationResult.fromJson(
      threadCreationResultFixture(
        'created',
        rootMessageId: rootId.value,
        threadId: threadId.value,
        summaryThreadId: threadId.value,
      ),
      expectedInput: ThreadCreationInput(
        parentConversationId: _parentId,
        rootMessageId: rootId,
        idempotencyKey: 'existing-thread',
      ),
    );

void _seedRoot(
  NormalizedSnapshotStore store, {
  MessageId rootId = _rootId,
}) {
  store.reconcileMessage(Message.fromJson(_rootMessageJson(rootId: rootId)));
}

MessageTimelineMessage _rootMessage() => MessageTimelineMessage.fromJson({
      ..._rootMessageJson(),
      'threadSummary': {
        'threadId': _threadId.value,
        'replyCount': 1,
        'participantIds': ['user-current'],
        'unreadCount': 0,
        'lastReplyAt': _now,
      },
      'isThreadRoot': true,
      'reactions': const <Object?>[],
      'attachmentMetadata': const <Object?>[],
    });

Map<String, Object?> _rootMessageJson({MessageId rootId = _rootId}) => {
      'id': rootId.value,
      'tenantId': _tenantId,
      'conversationId': _parentId.value,
      'author': {'type': 'user', 'userId': 'user-current'},
      'sequence': 1,
      'createdAt': _now,
      'updatedAt': _now,
      'revision': {'revision': 1},
      'content': {'format': 'plain', 'text': 'Root message context'},
    };

Map<String, Object?> _timelinePage(ConversationId conversationId) => {
      'conversationId': conversationId.value,
      'messages': [
        {
          'id': 'reply-1',
          'tenantId': _tenantId,
          'conversationId': conversationId.value,
          'author': {'type': 'user', 'userId': 'user-other'},
          'sequence': 1,
          'createdAt': _now,
          'updatedAt': _now,
          'revision': {'revision': 1},
          'content': {'format': 'plain', 'text': 'First thread reply'},
          'isThreadRoot': false,
          'reactions': const <Object?>[],
          'attachmentMetadata': const <Object?>[],
        },
      ],
      'pagination': {
        'older': {'available': false},
        'newer': {'available': false},
      },
      'replay': {
        'resumeFrom': {'eventId': 'thread-view-snapshot'},
      },
    };

Future<void> _pumpUntil(
  WidgetTester tester,
  bool Function() predicate, {
  String Function()? diagnostic,
}) async {
  for (var index = 0; index < 100 && !predicate(); index += 1) {
    await tester.pump(const Duration(milliseconds: 1));
  }
  expect(
    predicate(),
    isTrue,
    reason: 'Asynchronous thread widget work did not settle. Visible text: '
        '${tester.widgetList<Text>(find.byType(Text)).map((text) => text.data).toList()}. '
        '${diagnostic?.call() ?? ''}',
  );
  await tester.pump();
}
