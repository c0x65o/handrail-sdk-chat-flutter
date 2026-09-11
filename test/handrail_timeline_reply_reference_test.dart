import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:handrail_chat/ui.dart';

import 'fixtures/existing_thread_opening_fixtures.dart';

const _conversation = ConversationId('conversation-thread');
const _sourceId = MessageId('source-10');
const _tenant = TenantId('tenant-from-session');
const _user = UserId('user-current');
const _authority = ChatMessageContextAuthority(
  tenantId: _tenant,
  userId: _user,
  canRead: true,
);
const _sourceText = 'Which launch date?';

void main() {
  testWidgets(
      'authorized reference and additive input preserve legacy builders',
      (tester) async {
    final h = await _Harness.create(tester);
    ChatMessageBuilderInput? input;
    await h.mount(tester, builders: ChatWidgetBuilders(message: (_, value) {
      input = value;
      return Text(value.message.content!.text);
    }));
    await _settle(tester);
    expect(find.text('Reply to alice: $_sourceText'), findsOneWidget);
    expect(find.text('Friday'), findsOneWidget);
    expect(input!.replyContext!.state.source!.author.userId.value, 'alice');
    expect(input!.replyContext!.jumpToSource, isNotNull);
    expect(input!.replyContext!.retry, isNull);
    final legacy = ChatMessageBuilderInput(
      message: input!.message,
      actions: input!.actions,
    );
    expect(legacy.replyContext, isNull);
    expect(h.http.contextReads, 1);
    await h.mount(tester); // Ordinary rebuilds do not reset shared authority.
    await _settle(tester);
    expect(h.http.contextReads, 1);
    await tester.pumpWidget(const SizedBox.shrink());
    expect(h.source.state.status, ChatMessageContextStatus.available);
    expect(h.source.state.source!.content.text, _sourceText);
  });

  testWidgets('tap unloaded source opens bounded window, focuses and returns',
      (tester) async {
    final h = await _Harness.create(tester);
    final scroll = ScrollController();
    addTearDown(scroll.dispose);
    final semantics = tester.ensureSemantics();
    try {
      await h.mount(tester, scroll: scroll);
      await _settle(tester);
      expect(
          h.client.normalizedState.state.canonicalMessages[_sourceId], isNull);
      final offset = scroll.offset;
      expect(
          find.bySemanticsLabel(
              'Jump to original message. Reply to alice: $_sourceText'),
          findsOneWidget);
      await tester.tap(find.text('Reply to alice: $_sourceText'));
      await _settle(tester);
      expect(find.text('alice: $_sourceText'), findsOneWidget);
      expect(FocusManager.instance.primaryFocus!.debugLabel,
          'Original reply source');
      final target = tester.getRect(find.text('alice: $_sourceText'));
      final viewport = tester.getRect(find.byType(SingleChildScrollView));
      expect(viewport.overlaps(target), isTrue);
      expect(h.http.pages.length, 3); // newest + one page on either side
      expect(h.http.pages[1].uri.queryParameters['before'], '10');
      expect(h.http.pages[2].uri.queryParameters['after'], '10');
      expect(
          h.http.pages
              .skip(1)
              .every((r) => r.uri.queryParameters['limit'] == '2'),
          isTrue);
      expect(
          h.client.normalizedState.state.canonicalMessages[_sourceId], isNull);
      expect(h.timeline.state.messages.map((m) => m.sequence.value), [20]);
      expect(h.http.requests.every((r) => r.method == 'GET'), isTrue);
      await tester.tap(find.byTooltip('Return to replies'));
      await _settle(tester);
      expect(find.byType(Dialog), findsNothing);
      expect(scroll.offset, offset);
      expect(find.text('Friday'), findsOneWidget);
    } finally {
      semantics.dispose();
    }
  });

  testWidgets('source author is current and reply ancestry is never expanded',
      (tester) async {
    final h = await _Harness.create(tester);
    final source = h.http.value['message'] as Map<String, Object?>;
    source['replyTo'] = {'messageId': 'nested-source', 'notifyAuthor': true};
    source['content'] = <String, Object?>{
      ...source['content'] as Map<String, Object?>,
      'forwarded': {
        'sourceMessageId': 'forward-source',
        'originalAuthor': {
          'userId': 'forward-author',
          'displayName': 'Historical author'
        },
        'originalCreatedAt': existingThreadFixtureTime,
      },
    };
    await h.mount(tester);
    await _settle(tester);
    expect(find.text('Reply to alice: $_sourceText'), findsOneWidget);
    expect(find.textContaining('Historical author'), findsNothing);
    await tester.tap(find.text('Reply to alice: $_sourceText'));
    await _settle(tester);
    expect(find.text('alice: $_sourceText'), findsOneWidget);
    expect(h.http.contextReads, 1);
    expect(
        h.http.requests.any((r) =>
            r.uri.path.contains('nested-source') ||
            r.uri.path.contains('forward-source')),
        isFalse);
  });

  testWidgets('source window page error clears text and supports fresh retry',
      (tester) async {
    final h = await _Harness.create(tester);
    await h.mount(tester);
    await _settle(tester);
    h.http.adjacent = (_) async => _response({}, 503);
    await tester.tap(find.text('Reply to alice: $_sourceText'));
    await _settle(tester);
    expect(find.textContaining(_sourceText, skipOffstage: false), findsNothing);
    expect(
        find.descendant(
            of: find.byType(Dialog),
            matching: find.text('Original message could not be loaded')),
        findsOneWidget);
    h.http.adjacent = null;
    await tester.tap(find.descendant(
        of: find.byType(Dialog),
        matching: find.text('Retry original message')));
    await _settle(tester);
    expect(find.text('alice: $_sourceText'), findsOneWidget);
    expect(h.http.contextReads, 2);
    expect(FocusManager.instance.primaryFocus!.debugLabel,
        'Original reply source');
  });

  for (final key in [LogicalKeyboardKey.enter, LogicalKeyboardKey.space]) {
    testWidgets(
        '${key.keyLabel} activates reference and focuses mounted source',
        (tester) async {
      final h = await _Harness.create(tester, loaded: true);
      await h.mount(tester);
      await _settle(tester);
      final button =
          find.widgetWithText(TextButton, 'Reply to alice: $_sourceText');
      final focusContext = tester.element(find.descendant(
        of: button,
        matching: find.byType(Text),
      ));
      Focus.of(focusContext).requestFocus();
      await tester.pump();
      await tester.sendKeyEvent(key);
      await _settle(tester);
      expect(
          FocusManager.instance.primaryFocus!.debugLabel, 'Message source-10');
      expect(find.byType(Dialog), findsNothing);
      expect(h.http.pages.length, 1);
    });
  }

  testWidgets('loading, error and explicit retry replace source context',
      (tester) async {
    final held = Completer<HandrailChatHttpResponse>();
    final h = await _Harness.create(tester);
    h.http.lookup = (_) => held.future;
    await h.mount(tester);
    await _settle(tester);
    expect(find.text('Loading original message'), findsOneWidget);
    expect(find.textContaining(_sourceText), findsNothing);
    held.complete(_response({'error': 'fixture'}, 503));
    await _settle(tester);
    expect(find.text('Original message could not be loaded'), findsOneWidget);
    expect(find.text('Retry original message'), findsOneWidget);
    h.http.lookup = null;
    await tester.tap(find.text('Retry original message'));
    await _settle(tester);
    expect(find.text('Reply to alice: $_sourceText'), findsOneWidget);
    expect(h.http.contextReads, 2);
  });

  testWidgets('unconfigured authority never borrows loaded source text',
      (tester) async {
    final h = await _Harness.create(tester, loaded: true, authorized: false);
    ChatMessageReplyContext? reply;
    await h.mount(tester, builders: ChatWidgetBuilders(message: (_, input) {
      if (input.message.message.replyTo != null) reply = input.replyContext;
      return const Text('custom row');
    }));
    await _settle(tester);
    expect(find.text('Original message unavailable'), findsOneWidget);
    expect(find.textContaining(_sourceText), findsNothing);
    expect(reply!.state.source, isNull);
    expect(reply!.jumpToSource, isNull);
    expect(h.http.contextReads, 0);
    h.source.setAuthority(_authority);
    await _settle(tester);
    expect(find.text('Reply to alice: $_sourceText'), findsOneWidget);
    expect(h.http.contextReads, 1);
  });

  for (final deleted in [false, true]) {
    testWidgets('${deleted ? "deleted" : "unavailable"} source has no jump',
        (tester) async {
      final h = await _Harness.create(tester);
      h.http.value = deleted
          ? _context(deleted: true)
          : {
              'status': 'unavailable',
              'conversationId': _conversation.value,
              'messageId': _sourceId.value,
            };
      ChatMessageReplyContext? reply;
      await h.mount(tester, builders: ChatWidgetBuilders(message: (_, input) {
        reply = input.replyContext;
        return const Text('Friday');
      }));
      await _settle(tester);
      expect(
          find.text(deleted
              ? 'Original message deleted'
              : 'Original message unavailable'),
          findsOneWidget);
      expect(reply!.jumpToSource, isNull);
      expect(reply!.retry, isNull);
      expect(find.textContaining(_sourceText), findsNothing);
    });
  }

  testWidgets('deletion invalidates rendered text and rejects late lookup',
      (tester) async {
    final h = await _Harness.create(tester, loaded: true);
    await h.mount(tester);
    await _settle(tester);
    expect(find.text('Reply to alice: $_sourceText'), findsOneWidget);
    final held = Completer<HandrailChatHttpResponse>();
    h.http.lookup = (_) => held.future;
    final pending = h.source.retry();
    await _settle(tester);
    final deletion = KnownDurableEvent.fromJson({
      'eventId': 'source-deleted',
      'tenantId': _tenant.value,
      'streamId': _conversation.value,
      'type': 'message.deleted',
      'protocolVersion': 4,
      'occurredAt': existingThreadFixtureTime,
      'payload': {'message': _message(10, deleted: true, revision: 3)},
    },
        trustedIdentity: const DurableEventTrustedIdentity(
            tenantId: _tenant, userId: _user));
    expect(h.client.reduceDurableEvent(deletion).status,
        DurableEventReductionStatus.applied);
    await _settle(tester);
    expect(find.text('Original message deleted'), findsOneWidget);
    held.complete(_response(_context()));
    await pending;
    await _settle(tester);
    expect(find.textContaining(_sourceText), findsNothing);
    expect(find.text('Original message deleted'), findsOneWidget);
  });

  for (final phase in ['lookup', 'window']) {
    testWidgets(
        'parent access revoked during $phase removes text despite stale completion',
        (tester) async {
      final h = await _Harness.create(tester);
      h.client.normalizedState.hydrateConversationDetail(
          ConversationDetailSnapshot.fromJson(_parentDetail()));
      await h.mount(tester);
      await _settle(tester);
      expect(find.text('Reply to alice: $_sourceText'), findsOneWidget);
      final held = Completer<HandrailChatHttpResponse>();
      Future<ChatMessageContextState>? pending;
      if (phase == 'lookup') {
        h.http.lookup = (_) => held.future;
        pending = h.source.retry();
      } else {
        h.http.adjacent = (_) => held.future;
        await tester.tap(find.text('Reply to alice: $_sourceText'));
      }
      await _settle(tester);
      h.client.normalizedState.hydrateConversationDetail(
          ConversationDetailSnapshot.fromJson(_parentDetail(left: true)));
      await _settle(tester);
      expect(
          find.textContaining(_sourceText, skipOffstage: false), findsNothing);
      expect(find.text('Original message unavailable'), findsWidgets);
      held.complete(_response(phase == 'lookup' ? _context() : _page([9])));
      if (pending != null) await pending;
      await _settle(tester);
      expect(
          find.textContaining(_sourceText, skipOffstage: false), findsNothing);
      expect(h.source.state.source, isNull);
      expect(h.http.contextReads, phase == 'lookup' ? 2 : 1);
    });
  }

  testWidgets(
      'identity change clears custom builder input and retained jump is safe',
      (tester) async {
    final h = await _Harness.create(tester);
    ChatMessageReplyContext? reply;
    await h.mount(tester, builders: ChatWidgetBuilders(message: (_, input) {
      reply = input.replyContext;
      return Text(
          input.replyContext?.state.source?.content.text ?? 'No source');
    }));
    await _settle(tester);
    final oldJump = reply!.jumpToSource!;
    h.source.setAuthority(null);
    await _settle(tester);
    expect(reply!.state.source, isNull);
    expect(find.textContaining(_sourceText), findsNothing);
    await oldJump();
    expect(find.byType(Dialog), findsNothing);
  });

  testWidgets('source replacement never displays previous reference text',
      (tester) async {
    final h = await _Harness.create(tester);
    await h.mount(tester);
    await _settle(tester);
    h.client.normalizedState
        .hydrateMessageTimeline(MessageTimelinePage.fromJson(
      _page([20], replySource: 'other-source'),
      request: MessageTimelineRequest(
          conversationId: _conversation,
          direction: MessageTimelineDirection.backward,
          limit: 30),
    ));
    await _settle(tester);
    expect(find.text('Original message unavailable'), findsOneWidget);
    expect(find.textContaining(_sourceText), findsNothing);
    expect(h.source.state.source!.content.text, _sourceText);
  });

  testWidgets(
      'narrow large text wraps reference and source window without overflow',
      (tester) async {
    tester.view.physicalSize = const Size(320, 720);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final h = await _Harness.create(tester);
    h.http.value =
        _context(text: List.filled(40, 'A long source sentence.').join(' '));
    await h.mount(tester, scale: 2.5);
    await _settle(tester);
    expect(tester.takeException(), isNull);
    final reference = find.textContaining('Reply to alice:');
    await tester.ensureVisible(reference);
    // Apply the scroll's layout before hit testing the enlarged reference.
    await tester.pump();
    expect(reference.hitTestable(), findsOneWidget);
    await tester.tap(reference.hitTestable());
    await _settle(tester);
    expect(find.byType(Dialog), findsOneWidget);
    expect(tester.takeException(), isNull);
    expect(FocusManager.instance.primaryFocus!.debugLabel,
        'Original reply source');
  });
}

class _Harness {
  _Harness(this.client, this.http, this.source);
  final HandrailChatClient client;
  final _Http http;
  final ChatMessageContextController source;
  ChatTimelineController get timeline =>
      client.timelines.forConversation(_conversation);

  static Future<_Harness> create(WidgetTester tester,
      {bool loaded = false, bool authorized = true}) async {
    final http = _Http(loaded: loaded);
    final client = HandrailChatClient(
      apiBaseUri: Uri.parse('https://chat.test/api/chat'),
      tokenProvider: () async => 'test-token',
      transport: http,
      commandRetryOptions: const ChatCommandRetryOptions(maxAttempts: 1),
    );
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox.shrink());
      final closing = client.dispose();
      await _settle(tester);
      await closing;
    });
    await tester.runAsync(client.initialize);
    if (loaded) {
      client.normalizedState.hydrateConversationDetail(
          ConversationDetailSnapshot.fromJson(existingThreadDetailFixture()));
    }
    final source = client.messageContexts.forMessage(
      MessageContextRequest(
          conversationId: _conversation, messageId: _sourceId),
      pageSize: 2,
    );
    if (authorized) source.setAuthority(_authority);
    return _Harness(client, http, source);
  }

  Future<void> mount(
    WidgetTester tester, {
    ChatWidgetBuilders builders = const ChatWidgetBuilders(),
    ScrollController? scroll,
    double scale = 1,
  }) =>
      tester.pumpWidget(MaterialApp(
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context)
              .copyWith(textScaler: TextScaler.linear(scale)),
          child: child!,
        ),
        home: ChatScope(
          client: client,
          child: Scaffold(
              body: HandrailMessageTimeline(
            conversationId: _conversation,
            controller: timeline,
            scrollController: scroll,
            builders: builders,
            isConversationActive: false,
          )),
        ),
      ));
}

class _Http implements HandrailChatHttpTransport {
  _Http({required this.loaded});
  final bool loaded;
  final requests = <HandrailChatHttpRequest>[];
  Map<String, Object?> value = _context();
  Future<HandrailChatHttpResponse> Function(HandrailChatHttpRequest)? lookup,
      adjacent;
  int get contextReads =>
      requests.where((r) => r.uri.path.endsWith('/context')).length;
  List<HandrailChatHttpRequest> get pages =>
      requests.where((r) => r.uri.path.endsWith('/messages')).toList();

  @override
  Future<HandrailChatHttpResponse> send(HandrailChatHttpRequest r) async {
    requests.add(r);
    if (r.uri.path.endsWith('/_meta')) {
      return _response({
        'packageVersion': '0.1.4',
        'protocolVersion': 4,
        'schemaVersion': 1,
        'enabledFeatures': <String, Object?>{},
        'supportedProtocolRange': {'minimumVersion': 1, 'maximumVersion': 4},
      });
    }
    if (r.uri.path.endsWith('/context')) {
      return lookup == null ? _response(value) : await lookup!(r);
    }
    if (r.uri.path.endsWith('/messages')) {
      final before = r.uri.queryParameters['before'];
      final after = r.uri.queryParameters['after'];
      if (before != null || after != null) {
        return adjacent == null
            ? _response(_page(before != null ? [9] : [11]))
            : await adjacent!(r);
      }
      return _response(_page(loaded ? [10, 20] : [20]));
    }
    return _response(existingThreadDetailFixture());
  }
}

HandrailChatHttpResponse _response(Object? body, [int status = 200]) =>
    HandrailChatHttpResponse(statusCode: status, body: jsonEncode(body));

Map<String, Object?> _message(
  int sequence, {
  bool deleted = false,
  int revision = 2,
  String text = _sourceText,
  String replySource = 'source-10',
}) =>
    {
      'id': sequence == 10 ? _sourceId.value : 'message-$sequence',
      'tenantId': _tenant.value,
      'conversationId': _conversation.value,
      'author': {'type': 'user', 'userId': sequence == 10 ? 'alice' : 'bob'},
      'sequence': sequence,
      'createdAt': existingThreadFixtureTime,
      'updatedAt': existingThreadFixtureTime,
      'revision': {'revision': revision},
      'content': deleted
          ? null
          : {
              'format': 'plain',
              'text': sequence == 10
                  ? text
                  : sequence == 20
                      ? 'Friday'
                      : 'Nearby $sequence'
            },
      if (sequence == 20)
        'replyTo': {'messageId': replySource, 'notifyAuthor': true},
      if (deleted) ...{
        'deletedAt': existingThreadFixtureTime,
        'deletedByUserId': 'alice'
      },
    };

Map<String, Object?> _context(
        {bool deleted = false, String text = _sourceText}) =>
    {
      'status': deleted ? 'deleted' : 'available',
      'conversationId': _conversation.value,
      'messageId': _sourceId.value,
      'sequence': 10,
      'message': _message(10, deleted: deleted, text: text),
    };

Map<String, Object?> _page(List<int> sequences,
        {String replySource = 'source-10'}) =>
    {
      'conversationId': _conversation.value,
      'messages': [
        for (final sequence in sequences)
          {
            ..._message(sequence,
                replySource: replySource,
                revision: replySource == 'source-10' ? 2 : 3),
            'isThreadRoot': false,
            'reactions': <Object?>[],
            'attachmentMetadata': <Object?>[],
          }
      ],
      'pagination': {
        'older': {'available': false},
        'newer': {'available': false}
      },
      'replay': {
        'resumeFrom': {'eventId': 'reply-widget-page'}
      },
    };

Map<String, Object?> _parentDetail({bool left = false}) {
  final detail = jsonDecode(jsonEncode(existingThreadDetailFixture())
          .replaceAll(_conversation.value, 'conversation-parent'))
      as Map<String, dynamic>;
  final c = detail['conversation'] as Map<String, dynamic>;
  c.remove('parentConversationId');
  c.remove('rootMessageId');
  c['type'] = 'channel';
  c['name'] = 'Parent';
  c['visibility'] = 'private';
  if (left) c['updatedAt'] = '2026-08-27T16:00:00.000Z';
  (c['currentMember'] as Map)['state'] = left ? 'left' : 'active';
  if (left) {
    (c['currentMember'] as Map)['updatedAt'] = '2026-08-27T16:00:00.000Z';
  }
  return detail;
}

Future<void> _settle(WidgetTester tester) async {
  for (var frame = 0; frame < 20; frame++) {
    await tester.pump(const Duration(milliseconds: 50));
    // Match the composer harness: cancellation drains in the real async zone.
    await tester.runAsync(() => Future<void>.delayed(Duration.zero));
  }
}
