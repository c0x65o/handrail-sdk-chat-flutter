import 'dart:async';

import 'package:flutter/widgets.dart';

import '../core.dart';
import 'chat_scope.dart';

/// Builds a widget from an immutable public chat state.
typedef ChatStateWidgetBuilder<Value> = Widget Function(
  BuildContext context,
  Value state,
);

/// Determines whether two states have the same rendering meaning.
typedef ChatStateEquality<Value> = bool Function(Value previous, Value next);

bool _defaultStateEquality(Object? previous, Object? next) =>
    identical(previous, next) || previous == next;

/// Framework-neutral bridge from a current snapshot and stream to a widget.
///
/// [initialState] is rendered on the first build. Later values from [states]
/// rebuild the subtree only when [equals] reports a change. [source] identifies
/// the owner of both values; replacing it cancels the old subscription before
/// observing the replacement. Stream errors remain uncaught so Flutter's
/// current error zone receives them.
final class ChatStateBuilder<Value> extends StatefulWidget {
  const ChatStateBuilder({
    required this.source,
    required this.initialState,
    required this.states,
    required this.builder,
    this.equals = _defaultStateEquality,
    super.key,
  });

  final Object source;
  final Value initialState;
  final Stream<Value> states;
  final ChatStateWidgetBuilder<Value> builder;
  final ChatStateEquality<Value> equals;

  @override
  State<ChatStateBuilder<Value>> createState() =>
      _ChatStateBuilderState<Value>();
}

final class _ChatStateBuilderState<Value>
    extends State<ChatStateBuilder<Value>> {
  late Value _value;
  StreamSubscription<Value>? _subscription;
  var _generation = 0;
  var _active = true;

  @override
  void initState() {
    super.initState();
    _value = widget.initialState;
    _subscribe();
  }

  @override
  void didUpdateWidget(ChatStateBuilder<Value> oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (identical(oldWidget.source, widget.source) &&
        identical(oldWidget.states, widget.states)) {
      return;
    }

    _generation += 1;
    final previous = _subscription;
    _subscription = null;
    if (previous != null) unawaited(previous.cancel());
    _value = widget.initialState;
    _subscribe();
  }

  void _subscribe() {
    final generation = _generation;
    _subscription = widget.states.listen((next) {
      if (!_active || generation != _generation) return;
      if (widget.equals(_value, next)) return;
      setState(() => _value = next);
    });
  }

  @override
  void dispose() {
    _active = false;
    _generation += 1;
    final subscription = _subscription;
    _subscription = null;
    if (subscription != null) unawaited(subscription.cancel());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.builder(context, _value);
}

/// Builds from a client's public lifecycle snapshot and current-first stream.
///
/// When [client] is omitted, the client from the nearest [ChatScope] is used.
final class ChatClientLifecycleStateBuilder extends StatelessWidget {
  const ChatClientLifecycleStateBuilder({
    required this.builder,
    this.client,
    this.equals = _defaultStateEquality,
    super.key,
  });

  final HandrailChatClient? client;
  final ChatStateWidgetBuilder<ChatClientLifecycleState> builder;
  final ChatStateEquality<ChatClientLifecycleState> equals;

  @override
  Widget build(BuildContext context) {
    final resolved = client ?? ChatScope.of(context).client;
    return ChatStateBuilder<ChatClientLifecycleState>(
      source: resolved,
      initialState: resolved.state,
      states: resolved.states,
      equals: equals,
      builder: builder,
    );
  }
}

/// Short name for [ChatClientLifecycleStateBuilder].
typedef ChatClientStateBuilder = ChatClientLifecycleStateBuilder;

/// Builds from one conversation controller's public state contract.
///
/// The default constructor observes a caller-owned [conversation]. The scoped
/// constructors resolve a stable controller from the nearest [ChatScope].
final class ConversationStateBuilder extends StatelessWidget {
  const ConversationStateBuilder({
    required ChatConversationController conversation,
    required this.builder,
    this.equals = _defaultStateEquality,
    super.key,
  })  : _conversation = conversation,
        _conversationId = null,
        _entity = null;

  const ConversationStateBuilder.forConversation({
    required ConversationId conversationId,
    required this.builder,
    this.equals = _defaultStateEquality,
    super.key,
  })  : _conversation = null,
        _conversationId = conversationId,
        _entity = null;

  const ConversationStateBuilder.forEntity({
    required HostEntityReference entity,
    required this.builder,
    this.equals = _defaultStateEquality,
    super.key,
  })  : _conversation = null,
        _conversationId = null,
        _entity = entity;

  final ChatConversationController? _conversation;
  final ConversationId? _conversationId;
  final HostEntityReference? _entity;
  final ChatStateWidgetBuilder<ChatConversationControllerState> builder;
  final ChatStateEquality<ChatConversationControllerState> equals;

  @override
  Widget build(BuildContext context) {
    final explicit = _conversation;
    final conversationId = _conversationId;
    final resolved = explicit ??
        (conversationId != null
            ? ChatScope.of(context)
                .client
                .conversations
                .forConversation(conversationId)
            : ChatScope.of(context).client.conversations.forEntity(_entity!));
    return ChatStateBuilder<ChatConversationControllerState>(
      source: resolved,
      initialState: resolved.state,
      states: resolved.states,
      equals: equals,
      builder: builder,
    );
  }
}

/// Builds from one timeline controller's public state contract.
final class TimelineStateBuilder extends StatelessWidget {
  const TimelineStateBuilder({
    required ChatTimelineController controller,
    required this.builder,
    this.equals = _defaultStateEquality,
    super.key,
  })  : _controller = controller,
        _conversationId = null;

  const TimelineStateBuilder.forConversation({
    required ConversationId conversationId,
    required this.builder,
    this.equals = _defaultStateEquality,
    super.key,
  })  : _controller = null,
        _conversationId = conversationId;

  final ChatTimelineController? _controller;
  final ConversationId? _conversationId;
  final ChatStateWidgetBuilder<ChatTimelineControllerState> builder;
  final ChatStateEquality<ChatTimelineControllerState> equals;

  @override
  Widget build(BuildContext context) {
    final resolved = _controller ??
        ChatScope.of(context).client.timelines.forConversation(
              _conversationId!,
            );
    return ChatStateBuilder<ChatTimelineControllerState>(
      source: resolved,
      initialState: resolved.state,
      states: resolved.states,
      equals: equals,
      builder: builder,
    );
  }
}

/// Builds from one root thread's public opening lifecycle.
///
/// This widget observes only; callers retain ownership of handles returned by
/// [ChatThreadOpeningController.open].
final class ThreadOpeningStateBuilder extends StatelessWidget {
  const ThreadOpeningStateBuilder({
    required ChatThreadOpeningController controller,
    required this.builder,
    this.equals = _defaultStateEquality,
    super.key,
  })  : _controller = controller,
        _rootMessageId = null;

  const ThreadOpeningStateBuilder.forRoot({
    required MessageId rootMessageId,
    required this.builder,
    this.equals = _defaultStateEquality,
    super.key,
  })  : _controller = null,
        _rootMessageId = rootMessageId;

  final ChatThreadOpeningController? _controller;
  final MessageId? _rootMessageId;
  final ChatStateWidgetBuilder<ChatThreadOpeningState> builder;
  final ChatStateEquality<ChatThreadOpeningState> equals;

  @override
  Widget build(BuildContext context) {
    final resolved = _controller ??
        ChatScope.of(context).client.threads.forRoot(_rootMessageId!);
    return ChatStateBuilder<ChatThreadOpeningState>(
      source: resolved,
      initialState: resolved.state,
      states: resolved.states,
      equals: equals,
      builder: builder,
    );
  }
}

/// Builds from one huddle controller's public renderer state.
final class HuddleStateBuilder extends StatelessWidget {
  const HuddleStateBuilder({
    required ChatHuddleController controller,
    required this.builder,
    this.equals = _defaultStateEquality,
    super.key,
  })  : _controller = controller,
        _conversationId = null;

  const HuddleStateBuilder.forConversation({
    required ConversationId conversationId,
    required this.builder,
    this.equals = _defaultStateEquality,
    super.key,
  })  : _controller = null,
        _conversationId = conversationId;

  final ChatHuddleController? _controller;
  final ConversationId? _conversationId;
  final ChatStateWidgetBuilder<ChatHuddleState> builder;
  final ChatStateEquality<ChatHuddleState> equals;

  @override
  Widget build(BuildContext context) {
    final resolved = _controller ??
        ChatScope.of(context).client.huddles.forConversation(
              _conversationId!,
            );
    return ChatStateBuilder<ChatHuddleState>(
      source: resolved,
      initialState: resolved.state,
      states: resolved.states,
      equals: equals,
      builder: builder,
    );
  }
}
