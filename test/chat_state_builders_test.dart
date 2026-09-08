import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:handrail_chat/flutter.dart';

void main() {
  testWidgets(
    'ChatStateBuilder renders current state, deduplicates, replaces, and cancels',
    (tester) async {
      final first = _StateSource<int>(0);
      final second = _StateSource<int>(7);
      var builds = 0;

      Widget stateBuilder(_StateSource<int> source) => _host(
            ChatStateBuilder<int>(
              source: source,
              initialState: source.state,
              states: source.states,
              builder: (context, state) {
                builds += 1;
                return Text('$state');
              },
            ),
          );

      await tester.pumpWidget(stateBuilder(first));
      expect(find.text('0'), findsOneWidget);
      expect(builds, 1);

      first.emit(1);
      await tester.pump();
      expect(find.text('1'), findsOneWidget);
      expect(builds, 2);

      first.emit(1);
      await tester.pump();
      expect(builds, 2);

      await tester.pumpWidget(stateBuilder(second));
      expect(find.text('7'), findsOneWidget);
      expect(first.cancelCount, 1);

      final buildsAfterReplacement = builds;
      first.emit(2);
      second.emit(8);
      await tester.pump();
      expect(find.text('8'), findsOneWidget);
      expect(builds, buildsAfterReplacement + 1);

      await tester.pumpWidget(_host(const SizedBox.shrink()));
      expect(second.cancelCount, 1);
      final buildsAfterDispose = builds;
      second.emit(9);
      await tester.pump();
      expect(builds, buildsAfterDispose);
      expect(tester.takeException(), isNull);

      await first.close();
      await second.close();
    },
  );

  testWidgets('client and scoped controller builders use the nearest scope', (
    tester,
  ) async {
    final outer = _client(const _FixedTransport(_forbiddenResponse));
    final inner = _client(const _FixedTransport(_forbiddenResponse));
    final lifecycleStates = <ChatClientLifecycleState>[];
    final huddleStates = <ChatHuddleState>[];
    const conversationId = ConversationId('conversation-nearest-scope');

    await tester.pumpWidget(
      _host(
        ChatScope(
          client: outer,
          child: ChatScope(
            client: inner,
            child: Column(
              children: <Widget>[
                ChatClientLifecycleStateBuilder(
                  builder: (context, state) {
                    lifecycleStates.add(state);
                    return Text('client:${state.state}');
                  },
                ),
                HuddleStateBuilder.forConversation(
                  conversationId: conversationId,
                  builder: (context, state) {
                    huddleStates.add(state);
                    return Text('huddle:${state.hydrationStatus.name}');
                  },
                ),
              ],
            ),
          ),
        ),
      ),
    );

    expect(lifecycleStates.single, same(inner.state));
    expect(find.text('client:idle'), findsOneWidget);
    expect(find.text('huddle:idle'), findsOneWidget);

    await inner.initialize();
    await inner.huddles.forConversation(conversationId).hydrate();
    await tester.pump();

    expect(inner.state, isA<ChatClientErrorState>());
    expect(outer.state, isA<ChatClientIdleState>());
    expect(find.text('client:error'), findsOneWidget);
    expect(find.text('huddle:error'), findsOneWidget);
    expect(
        huddleStates.last,
        same(inner.huddles
            .forConversation(
              conversationId,
            )
            .state));
    expect(
      outer.huddles.forConversation(conversationId).state.hydrationStatus,
      ChatHuddleHydrationStatus.idle,
    );

    await tester.pumpWidget(_host(const SizedBox.shrink()));
    await outer.dispose();
    await inner.dispose();
  });

  testWidgets(
      'typed builder cancels and resubscribes on controller replacement',
      (tester) async {
    final firstClient = _client(const _FixedTransport(_forbiddenResponse));
    final secondClient = _client(const _FixedTransport(_forbiddenResponse));
    const conversationId = ConversationId('conversation-replacement');
    final first = firstClient.huddles.forConversation(conversationId);
    final second = secondClient.huddles.forConversation(conversationId);
    await first.hydrate();
    var builds = 0;

    Widget huddleBuilder(ChatHuddleController controller) => _host(
          HuddleStateBuilder(
            controller: controller,
            builder: (context, state) {
              builds += 1;
              return Text(state.hydrationStatus.name);
            },
          ),
        );

    await tester.pumpWidget(huddleBuilder(first));
    expect(find.text('error'), findsOneWidget);

    await tester.pumpWidget(huddleBuilder(second));
    expect(find.text('idle'), findsOneWidget);
    final buildsAfterReplacement = builds;

    await first.hydrate();
    await tester.pump();
    expect(find.text('idle'), findsOneWidget);
    expect(builds, buildsAfterReplacement);

    await tester.pumpWidget(_host(const SizedBox.shrink()));
    await firstClient.dispose();
    await secondClient.dispose();
  });

  testWidgets('typed builders pass error and access-revoked states unchanged', (
    tester,
  ) async {
    final client = _client(const _FixedTransport(_forbiddenResponse));
    const conversationId = ConversationId('conversation-errors');
    final conversation = client.conversations.forConversation(conversationId);
    final timeline = client.timelines.forConversation(conversationId);
    final thread = client.threads.forRoot(const MessageId(' invalid'));
    final huddle = client.huddles.forConversation(conversationId);
    final conversationStates = <ChatConversationControllerState>[];
    final timelineStates = <ChatTimelineControllerState>[];
    final threadStates = <ChatThreadOpeningState>[];
    final huddleStates = <ChatHuddleState>[];

    await tester.pumpWidget(
      _host(
        Column(
          children: <Widget>[
            ConversationStateBuilder(
              conversation: conversation,
              builder: (context, state) {
                conversationStates.add(state);
                return Text('conversation:${state.status.name}');
              },
            ),
            TimelineStateBuilder(
              controller: timeline,
              builder: (context, state) {
                timelineStates.add(state);
                return Text('timeline:${state.status.name}');
              },
            ),
            ThreadOpeningStateBuilder(
              controller: thread,
              builder: (context, state) {
                threadStates.add(state);
                return Text('thread:${state.state}');
              },
            ),
            HuddleStateBuilder(
              controller: huddle,
              builder: (context, state) {
                huddleStates.add(state);
                return Text('huddle:${state.hydrationStatus.name}');
              },
            ),
          ],
        ),
      ),
    );

    expect(conversationStates.first.status,
        ChatConversationControllerStatus.loading);
    expect(timelineStates.first.status, ChatTimelineControllerStatus.loading);
    expect(threadStates.first, isA<ChatThreadOpeningIdleState>());
    expect(huddleStates.first.hydrationStatus, ChatHuddleHydrationStatus.idle);

    await thread.open();
    await huddle.hydrate();
    await tester.pumpAndSettle();

    expect(find.text('conversation:accessRevoked'), findsOneWidget);
    expect(find.text('timeline:accessRevoked'), findsOneWidget);
    expect(find.text('thread:error'), findsOneWidget);
    expect(find.text('huddle:error'), findsOneWidget);
    expect(conversationStates.last, same(conversation.state));
    expect(
        conversationStates.last.error, isA<ChatConversationControllerError>());
    expect(timelineStates.last, same(timeline.state));
    expect(timelineStates.last.error, isA<ChatTimelineControllerError>());
    expect(threadStates.last, same(thread.state));
    expect(threadStates.last, isA<ChatThreadOpeningErrorState>());
    expect(huddleStates.last, same(huddle.state));
    expect(huddleStates.last.media, isA<ChatHuddleMediaErrorState>());

    await tester.pumpWidget(_host(const SizedBox.shrink()));
    await client.dispose();
  });
}

Widget _host(Widget child) => Directionality(
      textDirection: TextDirection.ltr,
      child: child,
    );

HandrailChatClient _client(HandrailChatHttpTransport transport) =>
    HandrailChatClient(
      apiBaseUri: Uri.parse('https://chat.example.test/api/chat'),
      tokenProvider: () async => 'access-token',
      transport: transport,
    );

const _forbiddenResponse = HandrailChatHttpResponse(
  statusCode: 403,
  body: '{"error":{"code":"ACCESS_DENIED"}}',
);

final class _FixedTransport implements HandrailChatHttpTransport {
  const _FixedTransport(this.response);

  final HandrailChatHttpResponse response;

  @override
  Future<HandrailChatHttpResponse> send(
          HandrailChatHttpRequest request) async =>
      response;
}

final class _StateSource<Value> {
  _StateSource(this.state) {
    _changes = StreamController<Value>.broadcast(
      sync: true,
      onCancel: () => cancelCount += 1,
    );
  }

  Value state;
  late final StreamController<Value> _changes;
  var cancelCount = 0;

  Stream<Value> get states => _changes.stream;

  void emit(Value next) {
    state = next;
    _changes.add(next);
  }

  Future<void> close() => _changes.close();
}
