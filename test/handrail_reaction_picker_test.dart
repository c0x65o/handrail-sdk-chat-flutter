import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:handrail_chat/ui.dart';

const _messageId = MessageId('message-reaction-picker');
const _conversationId = ConversationId('conversation-reaction-picker');

void main() {
  testWidgets(
    'renders selected state and only the bounded configured reaction set',
    (tester) async {
      final harness = _Harness((request) async => _successFor(request));
      addTearDown(harness.dispose);

      await _pumpPicker(
        tester,
        harness: harness,
        maxVisibleReactions: 2,
        options: const [
          HandrailReactionOption(
            reactionKey: 'thumbsup',
            label: '👍',
            semanticLabel: 'Thumbs up',
          ),
          HandrailReactionOption(
            reactionKey: 'heart',
            label: '❤️',
            semanticLabel: 'Heart',
          ),
          HandrailReactionOption(reactionKey: 'laugh', label: '😂'),
          HandrailReactionOption(reactionKey: 'heart', label: 'duplicate'),
        ],
        aggregates: const [
          MessageReactionAggregate(
            reactionKey: 'thumbsup',
            count: 3,
            reactedByCurrentUser: true,
          ),
          MessageReactionAggregate(
            reactionKey: 'heart',
            count: 1,
            reactedByCurrentUser: false,
          ),
          MessageReactionAggregate(
            reactionKey: 'outside-host-set',
            count: 7,
            reactedByCurrentUser: true,
          ),
        ],
      );

      expect(_chip(tester, 'thumbsup').selected, isTrue);
      expect(_chip(tester, 'heart').selected, isFalse);
      expect(find.text('👍 3'), findsOneWidget);
      expect(find.text('❤️ 1'), findsOneWidget);
      expect(
          find.byKey(const ValueKey('handrail-reaction-laugh')), findsNothing);
      expect(find.text('duplicate'), findsNothing);
      expect(find.text('outside-host-set'), findsNothing);
    },
  );

  testWidgets(
    'sends explicit add and remove intent serially while showing pending state',
    (tester) async {
      final responses = <Completer<HandrailChatHttpResponse>>[];
      final harness = _Harness((_) {
        final response = Completer<HandrailChatHttpResponse>();
        responses.add(response);
        return response.future;
      });
      addTearDown(harness.dispose);
      await _pumpPicker(tester, harness: harness);

      await tester.tap(_reaction('thumbsup'));
      await tester.pump();
      expect(harness.transport.requests, hasLength(1));
      expect(_operation(harness.transport.requests.single), 'add_reaction');
      expect(_chip(tester, 'thumbsup').selected, isTrue);
      expect(
        find.descendant(
          of: _reaction('thumbsup'),
          matching: find.byType(CircularProgressIndicator),
        ),
        findsOneWidget,
      );

      // A second rapid activation changes desired state but does not dispatch
      // a conflicting request before the add has settled.
      await tester.tap(_reaction('thumbsup'));
      await tester.pump();
      expect(harness.transport.requests, hasLength(1));
      expect(_chip(tester, 'thumbsup').selected, isFalse);

      responses[0].complete(_success(
        operation: 'add_reaction',
        reactionKey: 'thumbsup',
        count: 1,
        selected: true,
      ));
      await _pumpUntil(tester, () => harness.transport.requests.length == 2);
      expect(_operation(harness.transport.requests[1]), 'remove_reaction');

      responses[1].complete(_success(
        operation: 'remove_reaction',
        reactionKey: 'thumbsup',
        count: 0,
        selected: false,
      ));
      await tester.pump();
      expect(_chip(tester, 'thumbsup').selected, isFalse);
      expect(find.byType(CircularProgressIndicator), findsNothing);
    },
  );

  testWidgets('restores selection and shows generic feedback after failure', (
    tester,
  ) async {
    final response = Completer<HandrailChatHttpResponse>();
    final harness = _Harness((_) => response.future);
    addTearDown(harness.dispose);
    await _pumpPicker(
      tester,
      harness: harness,
      aggregates: const [
        MessageReactionAggregate(
          reactionKey: 'thumbsup',
          count: 2,
          reactedByCurrentUser: true,
        ),
      ],
    );

    await tester.tap(_reaction('thumbsup'));
    await tester.pump();
    expect(_chip(tester, 'thumbsup').selected, isFalse);
    expect(find.text('👍 1'), findsOneWidget);

    response.complete(const HandrailChatHttpResponse(
      statusCode: 500,
      body: '{"error":"private-token-should-not-render"}',
    ));
    await tester.pump();
    await tester.pump();

    expect(_chip(tester, 'thumbsup').selected, isTrue);
    expect(find.text('👍 2'), findsOneWidget);
    expect(
        find.text('Reaction could not be updated. Try again.'), findsOneWidget);
    expect(find.textContaining('private-token'), findsNothing);
  });

  testWidgets('capability-disabled reactions cannot be invoked', (
    tester,
  ) async {
    final semantics = tester.ensureSemantics();
    final harness = _Harness((request) async => _successFor(request));
    addTearDown(harness.dispose);
    await _pumpPicker(
      tester,
      harness: harness,
      capabilityEnabled: false,
    );

    expect(_chip(tester, 'thumbsup').onSelected, isNull);
    expect(find.text('Reactions are unavailable.'), findsOneWidget);
    expect(
      find.bySemanticsLabel(RegExp('Thumbs up.*not selected.*0 reactions')),
      findsOneWidget,
    );

    await tester.tap(_reaction('thumbsup'));
    await tester.sendKeyEvent(LogicalKeyboardKey.space);
    await tester.pump();
    expect(harness.transport.requests, isEmpty);
    semantics.dispose();
  });

  testWidgets('keyboard activation follows predictable configured order', (
    tester,
  ) async {
    final semantics = tester.ensureSemantics();
    final harness = _Harness((request) async => _successFor(request));
    addTearDown(harness.dispose);
    await _pumpPicker(
      tester,
      harness: harness,
      autofocus: true,
      options: const [
        HandrailReactionOption(
          reactionKey: 'thumbsup',
          label: '👍',
          semanticLabel: 'Thumbs up',
        ),
        HandrailReactionOption(
          reactionKey: 'heart',
          label: '❤️',
          semanticLabel: 'Heart',
        ),
        HandrailReactionOption(
          reactionKey: 'laugh',
          label: '😂',
          semanticLabel: 'Laugh',
        ),
      ],
    );

    expect(
      tester.binding.focusManager.primaryFocus?.debugLabel,
      contains('thumbsup'),
    );
    expect(
      find.bySemanticsLabel(RegExp('Thumbs up.*not selected.*0 reactions')),
      findsOneWidget,
    );

    await tester.sendKeyEvent(LogicalKeyboardKey.space);
    await _pumpUntil(tester, () => harness.transport.requests.length == 1);
    expect(_operation(harness.transport.requests[0]), 'add_reaction');

    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.pump();
    expect(
      tester.binding.focusManager.primaryFocus?.debugLabel,
      contains('heart'),
    );
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await _pumpUntil(tester, () => harness.transport.requests.length == 2);
    expect(
      _body(harness.transport.requests[1])['reactionKey'],
      'heart',
    );
    semantics.dispose();
  });

  testWidgets('remains inside its host-owned placement surface', (
    tester,
  ) async {
    final harness = _Harness((request) async => _successFor(request));
    addTearDown(harness.dispose);
    await _pumpPicker(tester, harness: harness);

    expect(
      find.descendant(
        of: find.byKey(const ValueKey('host-owned-placement')),
        matching: find.byKey(const ValueKey('handrail-reaction-picker')),
      ),
      findsOneWidget,
    );

    final source =
        File('lib/src/handrail_reaction_picker.dart').readAsStringSync();
    expect(source, contains('widget.actions.setReaction'));
    expect(source, isNot(contains('HandrailChatClient')));
    expect(source, isNot(contains('normalizedState')));
    expect(source, isNot(contains('HandrailChatHttpTransport')));
    expect(source, isNot(contains('OverlayEntry')));
    expect(source, isNot(contains('showDialog')));
    expect(source, isNot(contains('Navigator.')));
  });
}

Finder _reaction(String key) => find.byKey(ValueKey('handrail-reaction-$key'));

FilterChip _chip(WidgetTester tester, String key) =>
    tester.widget<FilterChip>(_reaction(key));

const _defaultOptions = [
  HandrailReactionOption(
    reactionKey: 'thumbsup',
    label: '👍',
    semanticLabel: 'Thumbs up',
  ),
];

Future<void> _pumpPicker(
  WidgetTester tester, {
  required _Harness harness,
  List<HandrailReactionOption> options = _defaultOptions,
  List<MessageReactionAggregate> aggregates = const [],
  bool capabilityEnabled = true,
  bool autofocus = false,
  int maxVisibleReactions = HandrailReactionPicker.defaultMaxVisibleReactions,
}) {
  return tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: Align(
          alignment: Alignment.topLeft,
          child: Material(
            key: const ValueKey('host-owned-placement'),
            child: HandrailReactionPicker(
              actions: harness.actions,
              availableReactions: options,
              reactionAggregates: aggregates,
              capabilityEnabled: capabilityEnabled,
              autofocus: autofocus,
              maxVisibleReactions: maxVisibleReactions,
            ),
          ),
        ),
      ),
    ),
  );
}

Future<void> _pumpUntil(
  WidgetTester tester,
  bool Function() condition,
) async {
  for (var attempt = 0; attempt < 30 && !condition(); attempt += 1) {
    await tester.pump();
  }
  expect(condition(), isTrue);
}

final class _Harness {
  _Harness(this._send) {
    var idempotencySequence = 0;
    client = HandrailChatClient(
      apiBaseUri: Uri.parse('https://chat.test/api/chat'),
      tokenProvider: () async => 'reaction-picker-token',
      transport: transport,
      commandRetryOptions: const ChatCommandRetryOptions(maxAttempts: 1),
      generateIdempotencyKey: () => 'picker-${idempotencySequence += 1}',
    );
    client.normalizedState.hydrateMessageTimeline(_messagePage());
    controller = client.timeline(_conversationId);
    actions = ChatMessageActions(
      controller: controller,
      messageId: _messageId,
      sequence: const MessageSequence(1),
      expectedRevision: 1,
    );
  }

  final Future<HandrailChatHttpResponse> Function(HandrailChatHttpRequest)
      _send;
  late final _RecordingTransport transport = _RecordingTransport(_send);
  late final HandrailChatClient client;
  late final ChatTimelineController controller;
  late final ChatMessageActions actions;

  Future<void> dispose() async {
    await controller.dispose();
    await client.dispose();
  }
}

MessageTimelinePage _messagePage() {
  final request = MessageTimelineRequest(
    conversationId: _conversationId,
    direction: MessageTimelineDirection.backward,
    limit: 10,
  );
  return MessageTimelinePage.fromJson(
    {
      'conversationId': _conversationId.value,
      'messages': [
        {
          'id': _messageId.value,
          'tenantId': 'tenant-reaction-picker',
          'conversationId': _conversationId.value,
          'author': {'type': 'user', 'userId': 'author-reaction-picker'},
          'sequence': 1,
          'createdAt': '2026-08-26T00:00:00.000Z',
          'updatedAt': '2026-08-26T00:00:00.000Z',
          'revision': {'revision': 1},
          'content': {'format': 'plain', 'text': 'Reaction target'},
          'isThreadRoot': false,
          'reactions': <Object?>[],
          'attachmentMetadata': <Object?>[],
        },
      ],
      'pagination': {
        'older': {'available': false},
        'newer': {'available': false},
      },
      'replay': {
        'resumeFrom': {'eventId': 'event-reaction-picker'},
      },
    },
    request: request,
  );
}

final class _RecordingTransport implements HandrailChatHttpTransport {
  _RecordingTransport(this.sendRequest);

  final Future<HandrailChatHttpResponse> Function(HandrailChatHttpRequest)
      sendRequest;
  final List<HandrailChatHttpRequest> requests = [];

  @override
  Future<HandrailChatHttpResponse> send(HandrailChatHttpRequest request) {
    requests.add(request);
    return sendRequest(request);
  }
}

Map<String, Object?> _body(HandrailChatHttpRequest request) =>
    jsonDecode(request.body!) as Map<String, Object?>;

String _operation(HandrailChatHttpRequest request) =>
    _body(request)['operation']! as String;

HandrailChatHttpResponse _successFor(HandrailChatHttpRequest request) {
  final body = _body(request);
  final operation = body['operation']! as String;
  final selected = operation == 'add_reaction';
  return _success(
    operation: operation,
    reactionKey: body['reactionKey']! as String,
    count: selected ? 1 : 0,
    selected: selected,
  );
}

HandrailChatHttpResponse _success({
  required String operation,
  required String reactionKey,
  required int count,
  required bool selected,
}) {
  return HandrailChatHttpResponse(
    statusCode: 200,
    body: jsonEncode({
      'operation': operation,
      'reconciliationStatus': 'applied',
      'messageId': _messageId.value,
      'reactionKey': reactionKey,
      'count': count,
      'reactedByCurrentUser': selected,
    }),
  );
}
