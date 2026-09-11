import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../core.dart';
import 'chat_read_tracker.dart';
import 'chat_scope.dart';
import 'chat_state_builders.dart';
import 'chat_widget_builders.dart';
import 'handrail_chat_theme.dart';
import 'handrail_named_thread_dialog.dart' show namedThreadsAvailable;

/// Supplies the current instant used to calculate reminder presets.
typedef HandrailReminderClock = DateTime Function();

/// Converts a UTC instant into the wall-clock time shown by reminder UI.
typedef HandrailReminderToLocalTime = DateTime Function(DateTime utcInstant);

/// Converts a wall-clock picker value into the UTC instant sent to Chat.
typedef HandrailReminderToUtcTime = DateTime Function(DateTime localTime);

/// Presents the calendar portion of a custom reminder picker.
typedef HandrailReminderDatePicker = Future<DateTime?> Function(
  BuildContext context,
  DateTime initialDate,
  DateTime firstDate,
  DateTime lastDate,
);

/// Presents the clock portion of a custom reminder picker.
typedef HandrailReminderTimePicker = Future<TimeOfDay?> Function(
  BuildContext context,
  TimeOfDay initialTime,
);

DateTime _systemReminderClock() => DateTime.now();
DateTime _systemReminderToLocalTime(DateTime instant) => instant.toLocal();
DateTime _systemReminderToUtcTime(DateTime localTime) => localTime.toUtc();
Future<DateTime?> _systemReminderDatePicker(
  BuildContext context,
  DateTime initialDate,
  DateTime firstDate,
  DateTime lastDate,
) =>
    showDatePicker(
      context: context,
      initialDate: initialDate,
      firstDate: firstDate,
      lastDate: lastDate,
      helpText: 'Choose reminder date',
    );
Future<TimeOfDay?> _systemReminderTimePicker(
  BuildContext context,
  TimeOfDay initialTime,
) =>
    showTimePicker(
      context: context,
      initialTime: initialTime,
      helpText: 'Choose reminder time',
    );

/// Lets a host present a thread request without coupling the timeline to
/// navigation. The callback receives only public message actions.
typedef HandrailThreadRequested = Future<void> Function(
  ChatMessageActions actions,
);

/// Selects an inline source in the current conversation's composer.
/// Return false if the composer cannot accept it. Never open a thread here.
typedef HandrailReplyRequested = bool Function(MessageContextRequest source);

/// Lets a host choose a destination for one eligible canonical message.
typedef HandrailForwardRequested = Future<void> Function(
  ChatMessageActions actions,
);

/// Lets a host present a reaction picker for an immutable public message.
typedef HandrailReactionRequested = void Function(
  ChatMessageBuilderInput input,
);

/// A composable, controller-backed timeline for one conversation.
///
/// The widget observes and commands only the public [ChatTimelineController]
/// contract. It retains, but never disposes, the client-owned controller.
/// Reply references observe client.messageContexts. Hosts configure each shared
/// source controller's authority from trusted current identity/access, as for
/// the composer; this widget never infers access from a loaded message.
final class HandrailMessageTimeline extends StatefulWidget {
  const HandrailMessageTimeline({
    required this.conversationId,
    this.controller,
    this.builders = const ChatWidgetBuilders(),
    this.scrollController,
    this.reads,
    this.padding = const EdgeInsets.symmetric(vertical: 8),
    this.liveEdgeThreshold = 96,
    this.earlierLoadThreshold = 80,
    this.isConversationActive = true,
    this.readVisibilityDelegate,
    this.minimumReadVisibleFraction = 0,
    this.onThreadRequested,
    this.onCreateThreadRequested,
    this.onReplyRequested,
    this.onThreadReplyRequested,
    this.onForwardRequested,
    this.onReactionRequested,
    this.reminderClock = _systemReminderClock,
    this.reminderToLocalTime = _systemReminderToLocalTime,
    this.reminderToUtcTime = _systemReminderToUtcTime,
    this.reminderDatePicker = _systemReminderDatePicker,
    this.reminderTimePicker = _systemReminderTimePicker,
    super.key,
  })  : assert(liveEdgeThreshold >= 0),
        assert(earlierLoadThreshold >= 0),
        assert(
          minimumReadVisibleFraction >= 0 && minimumReadVisibleFraction <= 1,
        );

  final ConversationId conversationId;

  /// A caller-owned controller. When omitted, [ChatScope] resolves one.
  final ChatTimelineController? controller;
  final ChatWidgetBuilders builders;
  final ScrollController? scrollController;

  /// An explicit public read coordinator, or the one supplied by [ChatScope].
  final ChatReadVisibilityCoordinator? reads;
  final EdgeInsetsGeometry padding;
  final double liveEdgeThreshold;
  final double earlierLoadThreshold;
  final bool isConversationActive;
  final ChatReadVisibilityDelegate? readVisibilityDelegate;
  final double minimumReadVisibleFraction;
  final HandrailThreadRequested? onThreadRequested;

  /// Presents named creation separately from Reply. The host owns navigation.
  final HandrailThreadRequested? onCreateThreadRequested;
  final HandrailReplyRequested? onReplyRequested;

  /// Focuses the existing thread composer in Current mode, preserving its draft.
  /// Return false when composition is unavailable. Never create a thread here.
  final bool Function()? onThreadReplyRequested;
  final HandrailForwardRequested? onForwardRequested;
  final HandrailReactionRequested? onReactionRequested;

  /// Injectable boundaries for deterministic reminder presets and pickers.
  final HandrailReminderClock reminderClock;
  final HandrailReminderToLocalTime reminderToLocalTime;
  final HandrailReminderToUtcTime reminderToUtcTime;
  final HandrailReminderDatePicker reminderDatePicker;
  final HandrailReminderTimePicker reminderTimePicker;

  @override
  State<HandrailMessageTimeline> createState() =>
      _HandrailMessageTimelineState();
}

final class _HandrailMessageTimelineState
    extends State<HandrailMessageTimeline> {
  HandrailChatClient? _styleClient;
  final List<StreamSubscription<dynamic>> _styleSubscriptions = [];

  void _bindStyle() {
    final client = ChatScope.maybeOf(context)?.client;
    if (identical(client, _styleClient)) return;
    _detachStyle();
    _styleClient = client;
    if (client == null) return;
    void changed(Object? _) {
      if (mounted && identical(client, _styleClient)) setState(() {});
    }

    _styleSubscriptions.add(client.replyStyles.states.listen(changed));
    _styleSubscriptions.add(client.states.listen(changed));
    final session = client.realtimeSession;
    if (session != null) {
      _styleSubscriptions.add(session.states.listen(changed));
    }
  }

  void _detachStyle() {
    for (final subscription in _styleSubscriptions) {
      unawaited(subscription.cancel());
    }
    _styleSubscriptions.clear();
    _styleClient = null;
  }

  String? get _inlineDisabledReason {
    final client = _styleClient;
    final lifecycle = client?.state;
    final realtime = client?.realtimeSession?.state;
    final features = client?.realtimeSession != null
        ? (realtime is ChatRealtimeConnectedState
            ? realtime.metadata.enabledFeatures.values
            : const <String, bool>{})
        : (lifecycle is ChatClientReadyState
            ? lifecycle.negotiatedCapabilities
            : const <String, bool>{});
    if (features[ChatReplyThreadFeatures.inlineReplies] != true) {
      return 'Inline replies are unavailable until supported by this server.';
    }
    if (widget.onReplyRequested == null) {
      return 'Inline replies require a composer reply handler.';
    }
    return null;
  }

  ChatTimelineController? _controller;
  ChatTimelineRetainHandle? _retain;
  late ScrollController _scrollController;
  late bool _ownsScrollController;
  var _bindingGeneration = 0;

  @override
  void initState() {
    super.initState();
    _ownsScrollController = widget.scrollController == null;
    _scrollController = widget.scrollController ?? ScrollController();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _bindStyle();
    _bindController();
  }

  @override
  void didUpdateWidget(covariant HandrailMessageTimeline oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.scrollController, widget.scrollController)) {
      final previous = _scrollController;
      final ownedPrevious = _ownsScrollController;
      _ownsScrollController = widget.scrollController == null;
      _scrollController = widget.scrollController ?? ScrollController();
      if (ownedPrevious) previous.dispose();
    }
    if (!identical(oldWidget.controller, widget.controller) ||
        oldWidget.conversationId != widget.conversationId) {
      _bindController(force: true);
    }
  }

  void _bindController({bool force = false}) {
    final resolved = widget.controller ??
        ChatScope.of(context)
            .client
            .timelines
            .forConversation(widget.conversationId);
    if (resolved.conversationId != widget.conversationId) {
      throw FlutterError(
        'HandrailMessageTimeline received a controller for '
        '${resolved.conversationId.value}, but conversationId is '
        '${widget.conversationId.value}.',
      );
    }
    if (!force && identical(_controller, resolved)) return;

    _bindingGeneration += 1;
    _retain?.release();
    _controller = resolved;
    _retain = resolved.retain();
    unawaited(resolved.refresh());
  }

  @override
  Widget build(BuildContext context) {
    final controller = _controller;
    if (controller == null) return const SizedBox.shrink();
    return TimelineStateBuilder(
      controller: controller,
      builder: (context, state) => _HandrailMessageTimelineBody(
        key: ValueKey<Object>(controller),
        controller: controller,
        bindingGeneration: _bindingGeneration,
        state: state,
        builders: widget.builders,
        scrollController: _scrollController,
        reads: widget.reads,
        padding: widget.padding,
        liveEdgeThreshold: widget.liveEdgeThreshold,
        earlierLoadThreshold: widget.earlierLoadThreshold,
        isConversationActive: widget.isConversationActive,
        readVisibilityDelegate: widget.readVisibilityDelegate,
        minimumReadVisibleFraction: widget.minimumReadVisibleFraction,
        onThreadRequested: widget.onThreadRequested,
        onCreateThreadRequested: widget.onCreateThreadRequested,
        namedThreadsEnabled:
            _styleClient != null && namedThreadsAvailable(_styleClient!),
        existingRoots: {
          for (final thread in _styleClient
                  ?.normalizedState.state.conversations.values
                  .whereType<ThreadConversation>() ??
              const <ThreadConversation>[])
            if (thread.parentConversationId == widget.conversationId)
              thread.rootMessageId,
        },
        isThread: state.conversation is ThreadConversation,
        onReplyRequested: widget.onReplyRequested,
        onThreadReplyRequested: widget.onThreadReplyRequested,
        inlineReply: _styleClient?.replyStyles.state.effectiveStyle ==
            ReplyStyle.discord,
        inlineDisabledReason: _inlineDisabledReason,
        onForwardRequested: widget.onForwardRequested,
        onReactionRequested: widget.onReactionRequested,
        reminderClock: widget.reminderClock,
        reminderToLocalTime: widget.reminderToLocalTime,
        reminderToUtcTime: widget.reminderToUtcTime,
        reminderDatePicker: widget.reminderDatePicker,
        reminderTimePicker: widget.reminderTimePicker,
      ),
    );
  }

  @override
  void dispose() {
    _bindingGeneration += 1;
    _retain?.release();
    _retain = null;
    _detachStyle();
    if (_ownsScrollController) _scrollController.dispose();
    super.dispose();
  }
}

final class _HandrailMessageTimelineBody extends StatefulWidget {
  const _HandrailMessageTimelineBody({
    required this.controller,
    required this.bindingGeneration,
    required this.state,
    required this.builders,
    required this.scrollController,
    required this.reads,
    required this.padding,
    required this.liveEdgeThreshold,
    required this.earlierLoadThreshold,
    required this.isConversationActive,
    required this.readVisibilityDelegate,
    required this.minimumReadVisibleFraction,
    required this.onThreadRequested,
    required this.onCreateThreadRequested,
    required this.namedThreadsEnabled,
    required this.isThread,
    required this.existingRoots,
    required this.onReplyRequested,
    required this.onThreadReplyRequested,
    required this.inlineReply,
    required this.inlineDisabledReason,
    required this.onForwardRequested,
    required this.onReactionRequested,
    required this.reminderClock,
    required this.reminderToLocalTime,
    required this.reminderToUtcTime,
    required this.reminderDatePicker,
    required this.reminderTimePicker,
    super.key,
  });

  final ChatTimelineController controller;
  final int bindingGeneration;
  final ChatTimelineControllerState state;
  final ChatWidgetBuilders builders;
  final ScrollController scrollController;
  final ChatReadVisibilityCoordinator? reads;
  final EdgeInsetsGeometry padding;
  final double liveEdgeThreshold;
  final double earlierLoadThreshold;
  final bool isConversationActive;
  final ChatReadVisibilityDelegate? readVisibilityDelegate;
  final double minimumReadVisibleFraction;
  final HandrailThreadRequested? onThreadRequested;
  final HandrailThreadRequested? onCreateThreadRequested;
  final bool namedThreadsEnabled;
  final bool isThread;
  final Set<MessageId> existingRoots;
  final HandrailReplyRequested? onReplyRequested;
  final bool Function()? onThreadReplyRequested;
  final bool inlineReply;
  final String? inlineDisabledReason;
  final HandrailForwardRequested? onForwardRequested;
  final HandrailReactionRequested? onReactionRequested;
  final HandrailReminderClock reminderClock;
  final HandrailReminderToLocalTime reminderToLocalTime;
  final HandrailReminderToUtcTime reminderToUtcTime;
  final HandrailReminderDatePicker reminderDatePicker;
  final HandrailReminderTimePicker reminderTimePicker;

  @override
  State<_HandrailMessageTimelineBody> createState() =>
      _HandrailMessageTimelineBodyState();
}

final class _HandrailMessageTimelineBodyState
    extends State<_HandrailMessageTimelineBody> {
  final Map<MessageId, GlobalKey> _rowKeys = <MessageId, GlobalKey>{};
  final Map<MessageId, FocusNode> _sourceFocusNodes = {};
  final Map<MessageId, FocusNode> _markUnreadFocusNodes =
      <MessageId, FocusNode>{};
  final Set<MessageId> _markUnreadPending = <MessageId>{};
  var _loadingEarlier = false;
  var _earlierLoadFailed = false;
  var _loadGeneration = 0;
  var _initialPositionApplied = false;
  var _initialPositionScheduled = false;
  MessageSequence? _entryUnreadBoundary;

  @override
  void initState() {
    super.initState();
    widget.scrollController.addListener(_handleScroll);
    _scheduleInitialPosition();
  }

  @override
  void didUpdateWidget(covariant _HandrailMessageTimelineBody oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.scrollController, widget.scrollController)) {
      oldWidget.scrollController.removeListener(_handleScroll);
      widget.scrollController.addListener(_handleScroll);
    }
    if (!identical(oldWidget.controller, widget.controller) ||
        oldWidget.bindingGeneration != widget.bindingGeneration) {
      _loadGeneration += 1;
      _loadingEarlier = false;
      _earlierLoadFailed = false;
      _initialPositionApplied = false;
      _initialPositionScheduled = false;
      _entryUnreadBoundary = null;
      _rowKeys.clear();
      _disposeMarkUnreadFocusNodes();
      _markUnreadPending.clear();
      _scheduleInitialPosition();
      return;
    }
    _scheduleScrollRetention(oldWidget.state, widget.state);
  }

  void _scheduleInitialPosition() {
    if (_initialPositionApplied ||
        _initialPositionScheduled ||
        widget.state.messages.isEmpty) {
      return;
    }
    _entryUnreadBoundary = widget.state.unreadBoundary;
    final unread = _firstEntryUnreadMessage();
    if (unread != null) {
      _initialPositionScheduled = true;
      _revealInitialUnreadAfterLayout(unread.id, widget.bindingGeneration);
      return;
    }
    _initialPositionApplied = true;
    _followLiveEdgeAfterLayout(remainingPasses: 3);
  }

  MessageTimelineMessage? _firstEntryUnreadMessage() {
    final boundary = widget.state.currentUserReadState?.manualUnreadFromSequence ??
        _entryUnreadBoundary;
    if (boundary == null) return null;
    for (final message in widget.state.messages) {
      if (message.sequence.value >= boundary.value) {
        return message;
      }
    }
    return null;
  }

  void _revealInitialUnreadAfterLayout(MessageId messageId, int generation) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted ||
          generation != widget.bindingGeneration ||
          !_initialPositionScheduled) {
        return;
      }
      final position = _singleScrollPosition();
      if (position == null) {
        // Retry on the next state/layout update if no single viewport exists.
        _initialPositionScheduled = false;
        return;
      }
      final target = _rowKeys[messageId]?.currentContext?.findRenderObject();
      if (target != null && target.attached) {
        unawaited(position.ensureVisible(target, alignment: 0));
        setState(() {
          _initialPositionApplied = true;
          _initialPositionScheduled = false;
        });
        return;
      }
      // ListView builds lazily. Walk one viewport at a time until the unread
      // row is mounted, without estimating heights or mounting the full list.
      final targetIndex = widget.state.messages.indexWhere(
        (message) => message.id == messageId,
      );
      final firstMounted = widget.state.messages.indexWhere(
        (message) => _rowKeys[message.id]?.currentContext != null,
      );
      final direction = firstMounted > targetIndex ? -1 : 1;
      final next = (position.pixels + direction * position.viewportDimension)
          .clamp(position.minScrollExtent, position.maxScrollExtent);
      if (targetIndex < 0 || next == position.pixels) {
        setState(() {
          _initialPositionApplied = true;
          _initialPositionScheduled = false;
        });
        return;
      }
      position.jumpTo(next);
      _revealInitialUnreadAfterLayout(messageId, generation);
      WidgetsBinding.instance.ensureVisualUpdate();
    });
  }

  void _followLiveEdgeAfterLayout({required int remainingPasses, int? generation}) {
    final expectedGeneration = generation ?? widget.bindingGeneration;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || widget.bindingGeneration != expectedGeneration) return;
      final position = _singleScrollPosition();
      if (position == null) {
        if (remainingPasses > 1) {
          _followLiveEdgeAfterLayout(
            remainingPasses: remainingPasses - 1,
            generation: expectedGeneration,
          );
        }
        return;
      }
      if (remainingPasses < 3 &&
          position.maxScrollExtent - position.pixels >
              widget.liveEdgeThreshold) {
        return;
      }
      position.jumpTo(position.maxScrollExtent);
      if (remainingPasses > 1) {
        _followLiveEdgeAfterLayout(
          remainingPasses: remainingPasses - 1,
          generation: expectedGeneration,
        );
      }
    });
  }

  void _scheduleScrollRetention(
    ChatTimelineControllerState previous,
    ChatTimelineControllerState next,
  ) {
    if (!_initialPositionApplied) {
      _scheduleInitialPosition();
      return;
    }
    final previousMessages = previous.messages;
    final nextMessages = next.messages;
    if (previousMessages.isEmpty) {
      _scheduleInitialPosition();
      return;
    }
    if (nextMessages.isEmpty) return;
    final prepended = _isSuffix(previousMessages, nextMessages);
    final appended = _isPrefix(previousMessages, nextMessages);
    if (!prepended && !appended) return;
    final position = _singleScrollPosition();
    if (position == null) return;

    final oldExtent = position.maxScrollExtent;
    final oldOffset = position.pixels;
    final wasNearLiveEdge = oldExtent - oldOffset <= widget.liveEdgeThreshold;

    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final nextPosition = _singleScrollPosition();
      if (nextPosition == null) return;
      if (prepended) {
        final extentDelta = nextPosition.maxScrollExtent - oldExtent;
        nextPosition.jumpTo(
          (oldOffset + extentDelta).clamp(
            nextPosition.minScrollExtent,
            nextPosition.maxScrollExtent,
          ),
        );
      } else if (appended && wasNearLiveEdge) {
        nextPosition.jumpTo(nextPosition.maxScrollExtent);
      }
      _pruneRowKeys(nextMessages);
    });
  }

  ScrollPosition? _singleScrollPosition() {
    final positions = widget.scrollController.positions;
    if (positions.length != 1) return null;
    final position = positions.first;
    // A web ScrollPosition can be attached while its first layout (or a
    // semantics-driven relayout) has not populated pixels and content
    // dimensions yet. Reading maxScrollExtent/pixels in that interval uses
    // null-backed framework fields and throws in optimized web builds.
    if (!position.hasPixels || !position.hasContentDimensions) return null;
    return position;
  }

  bool _isSuffix(
    List<MessageTimelineMessage> previous,
    List<MessageTimelineMessage> next,
  ) {
    if (next.length <= previous.length) return false;
    final offset = next.length - previous.length;
    for (var index = 0; index < previous.length; index += 1) {
      if (previous[index].id != next[index + offset].id) return false;
    }
    return true;
  }

  bool _isPrefix(
    List<MessageTimelineMessage> previous,
    List<MessageTimelineMessage> next,
  ) {
    if (next.length <= previous.length) return false;
    for (var index = 0; index < previous.length; index += 1) {
      if (previous[index].id != next[index].id) return false;
    }
    return true;
  }

  void _pruneRowKeys(List<MessageTimelineMessage> messages) {
    final retained = messages.map((message) => message.id).toSet();
    _rowKeys.removeWhere((messageId, _) => !retained.contains(messageId));
    final removedFocusNodes = <FocusNode>[];
    _markUnreadFocusNodes.removeWhere((messageId, focusNode) {
      if (retained.contains(messageId)) return false;
      removedFocusNodes.add(focusNode);
      return true;
    });
    for (final focusNode in removedFocusNodes) {
      focusNode.dispose();
    }
    _markUnreadPending
        .removeWhere((messageId) => !retained.contains(messageId));
  }

  void _handleScroll() {
    if (_initialPositionScheduled ||
        _loadingEarlier || _earlierLoadFailed || !widget.state.hasEarlier) {
      return;
    }
    final position = _singleScrollPosition();
    if (position == null ||
        position.maxScrollExtent <= 0 ||
        position.pixels > widget.earlierLoadThreshold) {
      return;
    }
    unawaited(_loadEarlier());
  }

  Future<void> _loadEarlier() async {
    if (_loadingEarlier || !widget.state.hasEarlier) return;
    final controller = widget.controller;
    final generation = ++_loadGeneration;
    setState(() {
      _loadingEarlier = true;
      _earlierLoadFailed = false;
    });
    ChatTimelineControllerState? result;
    try {
      result = await controller.loadEarlier();
    } catch (_) {
      // Keep unexpected transport details out of the widget projection.
    } finally {
      if (mounted &&
          generation == _loadGeneration &&
          identical(controller, widget.controller)) {
        setState(() {
          _loadingEarlier = false;
          _earlierLoadFailed = result == null ||
              (result.status == ChatTimelineControllerStatus.error &&
                  result.messages.isNotEmpty);
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final state = widget.state;
    final actions = ChatTimelineActions(widget.controller);
    if (state.status == ChatTimelineControllerStatus.loading &&
        state.messages.isEmpty) {
      return Semantics(
        container: true,
        liveRegion: true,
        label: 'Loading messages',
        child: widget.builders.loading(
          context,
          ChatLoadingBuilderInput(
            target: ChatLoadingTarget.timeline,
            conversationId: state.conversationId,
          ),
        ),
      );
    }
    if (state.status == ChatTimelineControllerStatus.accessRevoked) {
      return Semantics(
        container: true,
        liveRegion: true,
        label: 'Conversation access revoked',
        child: widget.builders.error(
          context,
          ChatErrorBuilderInput.timeline(
            error: state.error ??
                const ChatTimelineControllerError(
                  code: ChatTimelineControllerErrorCode.realtimeRejected,
                  message: 'Conversation access was revoked.',
                ),
          ),
        ),
      );
    }
    if (state.status == ChatTimelineControllerStatus.error &&
        state.messages.isEmpty) {
      return Semantics(
        container: true,
        liveRegion: true,
        label: 'Message timeline error',
        child: widget.builders.error(
          context,
          ChatErrorBuilderInput.timeline(
            error: state.error ??
                const ChatTimelineControllerError(
                  code: ChatTimelineControllerErrorCode.transport,
                  message: 'The message timeline could not be loaded.',
                ),
            timelineActions: actions,
          ),
        ),
      );
    }
    if (state.status == ChatTimelineControllerStatus.disposed) {
      return const SizedBox.shrink();
    }
    if (state.isReady && state.messages.isEmpty) {
      final conversation = state.conversation;
      return Semantics(
        container: true,
        label: 'Empty conversation',
        child: conversation == null
            ? const Center(child: Text('No messages yet'))
            : widget.builders.emptyConversation(
                context,
                ChatEmptyConversationBuilderInput(
                  conversation: conversation,
                  actions: actions,
                ),
              ),
      );
    }

    final messages = state.messages;
    final firstUnreadMessage = _firstEntryUnreadMessage();
    final trackedItems = <ChatReadTrackedItem>[
      for (final message in messages)
        ChatReadTrackedItem(
          key: _rowKeys.putIfAbsent(message.id, GlobalKey.new),
          sequence: message.sequence,
        ),
    ];
    final hasEarlierRow =
        state.hasEarlier || _loadingEarlier || _earlierLoadFailed;
    final itemCount = messages.length + (hasEarlierRow ? 1 : 0);
    return Semantics(
      container: true,
      label: 'Message timeline',
      explicitChildNodes: true,
      child: ChatReadTracker(
        conversationId: state.conversationId,
        items: trackedItems,
        reads: widget.reads,
        visibilityDelegate: widget.readVisibilityDelegate,
        minimumVisibleFraction: widget.minimumReadVisibleFraction,
        isConversationActive:
            widget.isConversationActive && !_initialPositionScheduled,
        child: ListView.builder(
          key: const ValueKey<String>('handrail-message-timeline-list'),
          controller: widget.scrollController,
          padding: widget.padding,
          itemCount: itemCount,
          findChildIndexCallback: (key) {
            if (key is! GlobalKey) return null;
            for (var index = 0; index < messages.length; index += 1) {
              if (identical(trackedItems[index].key, key)) {
                return index + (hasEarlierRow ? 1 : 0);
              }
            }
            return null;
          },
          itemBuilder: (context, index) {
            if (hasEarlierRow && index == 0) {
              return _buildEarlierLoader(context, state);
            }
            final messageIndex = index - (hasEarlierRow ? 1 : 0);
            final message = messages[messageIndex];
            return _buildMessageRow(
              context,
              message,
              trackedItems[messageIndex].key,
              firstUnreadMessage?.id == message.id,
            );
          },
        ),
      ),
    );
  }

  Widget _buildEarlierLoader(
    BuildContext context,
    ChatTimelineControllerState state,
  ) {
    if (_loadingEarlier) {
      return Semantics(
        container: true,
        liveRegion: true,
        label: 'Loading earlier messages',
        child: KeyedSubtree(
          key: const ValueKey<String>('handrail-timeline-earlier-loading'),
          child: widget.builders.loading(
            context,
            ChatLoadingBuilderInput(
              target: ChatLoadingTarget.timeline,
              conversationId: state.conversationId,
            ),
          ),
        ),
      );
    }
    if (_earlierLoadFailed) {
      const diagnostic = "Earlier messages couldn't be loaded";
      return Semantics(
        key: const ValueKey<String>('handrail-timeline-earlier-error'),
        container: true,
        explicitChildNodes: true,
        liveRegion: true,
        label: diagnostic,
        child: Center(
          child: Wrap(
            alignment: WrapAlignment.center,
            crossAxisAlignment: WrapCrossAlignment.center,
            spacing: HandrailChatTheme.of(context).spacing.small,
            children: [
              const ExcludeSemantics(child: Text(diagnostic)),
              TextButton(
                key: const ValueKey<String>(
                  'handrail-timeline-retry-earlier',
                ),
                onPressed: _loadEarlier,
                child: const Text('Retry earlier messages'),
              ),
            ],
          ),
        ),
      );
    }
    return Center(
      child: TextButton(
        key: const ValueKey<String>('handrail-timeline-load-earlier'),
        onPressed: _loadEarlier,
        child: const Text('Load earlier messages'),
      ),
    );
  }

  Widget _buildMessageRow(
    BuildContext context,
    MessageTimelineMessage message,
    GlobalKey rowKey,
    bool showUnreadBoundary,
  ) {
    final theme = HandrailChatTheme.of(context);
    final actions = ChatMessageActions.forMessage(
      controller: widget.controller,
      message: message,
    );
    final deleted = message.message is DeletedMessage;
    final canonical = widget.controller.isCanonicalMessage(message.id);
    final canReact = !deleted && canonical;
    final threadSummary = message.threadSummary;
    final hasThread =
        threadSummary != null || widget.existingRoots.contains(message.id);
    final readState = widget.state.currentUserReadState;
    final canMarkUnread = !deleted &&
        canonical &&
        readState != null &&
        message.sequence.value >= 1 &&
        message.sequence.value <= readState.lastReadSequence.value;
    final canForward = !deleted &&
        canonical &&
        widget.onForwardRequested != null &&
        message.attachmentMetadata.isEmpty &&
        (message.content?.attachments?.isEmpty ?? true) &&
        message.content?.blocks == null;
    final canRemind = !deleted && canonical;
    final markUnreadPending = _markUnreadPending.contains(message.id);
    return KeyedSubtree(
      key: rowKey,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (showUnreadBoundary)
            _UnreadBoundary(
              key: ValueKey<String>(
                'handrail-unread-${message.sequence.value}',
              ),
            ),
          Semantics(
            container: true,
            label: deleted
                ? 'Deleted message ${message.sequence.value}'
                : 'Message ${message.sequence.value} from '
                    '${message.author.userId.value}',
            child: Padding(
              padding: EdgeInsets.symmetric(
                horizontal: theme.spacing.medium,
                vertical: theme.spacing.small,
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  KeyedSubtree(
                    key: ValueKey<String>(
                      'handrail-message-${message.id.value}',
                    ),
                    child: Focus(
                      skipTraversal: true,
                      focusNode: _sourceFocusNodes.putIfAbsent(
                        message.id,
                        () => FocusNode(debugLabel: 'Message ${message.id.value}'),
                      ),
                      child: _ReplyMessageContent(
                        message: message,
                        actions: actions,
                        builder: widget.builders.message,
                        source: !deleted && message.message.replyTo != null
                            ? widget.controller.messageContext(
                                message.message.replyTo!.messageId,
                              )
                            : null,
                        onJump: _jumpToSource,
                      ),
                    ),
                  ),
                  for (final attachment in message.attachmentMetadata)
                    Padding(
                      padding: EdgeInsets.only(top: theme.spacing.small),
                      child: widget.builders.attachmentPreview(
                        context,
                        ChatAttachmentPreviewBuilderInput(
                          attachment: attachment,
                        ),
                      ),
                    ),
                  if (canReact && message.reactions.isNotEmpty)
                    Padding(
                      padding: EdgeInsets.only(top: theme.spacing.small),
                      child: Wrap(
                        spacing: theme.spacing.extraSmall,
                        runSpacing: theme.spacing.extraSmall,
                        children: [
                          for (final reaction in message.reactions)
                            ActionChip(
                              key: ValueKey<String>(
                                'handrail-reaction-${message.id.value}-'
                                '${reaction.reactionKey}',
                              ),
                              label: Text(
                                '${reaction.reactionKey} ${reaction.count}',
                              ),
                              tooltip: reaction.reactedByCurrentUser
                                  ? 'Remove ${reaction.reactionKey} reaction'
                                  : 'Add ${reaction.reactionKey} reaction',
                              onPressed: () {
                                unawaited(actions.setReaction(
                                  reactionKey: reaction.reactionKey,
                                  reactedByCurrentUser:
                                      !reaction.reactedByCurrentUser,
                                ));
                              },
                            ),
                        ],
                      ),
                    ),
                  if (canReact && widget.onReactionRequested != null)
                    Align(
                      alignment: AlignmentDirectional.centerStart,
                      child: IconButton(
                        key: ValueKey<String>(
                          'handrail-add-reaction-${message.id.value}',
                        ),
                        tooltip: 'Add reaction',
                        onPressed: () => widget.onReactionRequested!(
                          ChatMessageBuilderInput(
                            message: message,
                            actions: actions,
                          ),
                        ),
                        icon: const Icon(Icons.add_reaction_outlined),
                      ),
                    ),
                  if (!deleted || hasThread)
                    Align(
                      alignment: AlignmentDirectional.centerStart,
                      child: Wrap(
                        spacing: theme.spacing.extraSmall,
                        children: [
                          if (!deleted)
                            TextButton(
                              key: ValueKey<String>(
                                'handrail-copy-${message.id.value}',
                              ),
                              onPressed: () => unawaited(
                                _copyMessage(
                                  context,
                                  message.content!.text,
                                ),
                              ),
                              child: const Text('Copy'),
                            ),
                          if (canMarkUnread)
                            Semantics(
                              container: true,
                              liveRegion: markUnreadPending,
                              button: true,
                              label: markUnreadPending
                                  ? 'Marking unread from message '
                                      '${message.sequence.value}'
                                  : 'Mark unread from message '
                                      '${message.sequence.value}',
                              child: TextButton(
                                key: ValueKey<String>(
                                  'handrail-mark-unread-${message.id.value}',
                                ),
                                focusNode: _markUnreadFocusNodes.putIfAbsent(
                                  message.id,
                                  FocusNode.new,
                                ),
                                onPressed: markUnreadPending
                                    ? null
                                    : () => unawaited(
                                          _markUnread(context, message),
                                        ),
                                child: ExcludeSemantics(
                                  child: Text(
                                    markUnreadPending
                                        ? 'Marking unread…'
                                        : 'Mark unread',
                                  ),
                                ),
                              ),
                            ),
                          if (canForward)
                            TextButton(
                              key: ValueKey<String>(
                                'handrail-forward-${message.id.value}',
                              ),
                              onPressed: () => unawaited(
                                widget.onForwardRequested!(actions),
                              ),
                              child: const Text('Forward'),
                            ),
                          if (canRemind)
                            TextButton(
                              key: ValueKey<String>(
                                'handrail-remind-${message.id.value}',
                              ),
                              onPressed: () => unawaited(
                                _showReminderSheet(context, actions),
                              ),
                              child: const Text('Remind me'),
                            ),
                          if (threadSummary != null)
                            TextButton(
                              key: ValueKey<String>(
                                'handrail-thread-${message.id.value}',
                              ),
                              onPressed: () => _requestThread(actions),
                              child: Text(
                                '${threadSummary.replyCount} '
                                '${threadSummary.replyCount == 1 ? 'reply' : 'replies'}'
                                '${threadSummary.unreadCount > 0 ? ' · ${threadSummary.unreadCount} unread' : ''}',
                              ),
                            ),
                          if (canonical &&
                              !widget.isThread &&
                              (hasThread || !deleted))
                            Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                TextButton(
                                  key: ValueKey(
                                    'handrail-create-thread-${message.id.value}',
                                  ),
                                  onPressed: hasThread
                                      ? () => _requestThread(actions)
                                      : widget.namedThreadsEnabled &&
                                            widget.onCreateThreadRequested !=
                                                null
                                      ? () => unawaited(
                                          widget.onCreateThreadRequested!(
                                            actions,
                                          ),
                                        )
                                      : null,
                                  child: Text(
                                    hasThread ? 'Open Thread' : 'Create Thread',
                                  ),
                                ),
                                if (!hasThread && !widget.namedThreadsEnabled)
                                  const Text(
                                    'Named threads are unavailable on this server.',
                                  ),
                                if (!hasThread &&
                                    widget.namedThreadsEnabled &&
                                    widget.onCreateThreadRequested == null)
                                  const Text(
                                    'Named threads require a creation handler.',
                                  ),
                              ],
                            ),
                          if (canonical &&
                              !deleted &&
                              (widget.inlineReply || threadSummary == null))
                            Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                TextButton(
                                  key: ValueKey<String>(
                                    'handrail-reply-${message.id.value}',
                                  ),
                                  onPressed: widget.inlineReply &&
                                          widget.inlineDisabledReason != null
                                      ? null
                                      : () => _requestReply(message),
                                  onLongPress: widget.inlineReply &&
                                          widget.inlineDisabledReason != null
                                      ? null
                                      : () =>
                                          unawaited(_showReplyMenu(message)),
                                  child: const Text('Reply'),
                                ),
                                if (widget.inlineReply &&
                                    widget.inlineDisabledReason != null)
                                  Text(widget.inlineDisabledReason!),
                              ],
                            ),
                        ],
                      ),
                    ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  void _requestReply(MessageTimelineMessage message) {
    // Recheck current style, capability and canonical eligibility after a menu
    // closes. A loaded row is not authority for source-context access.
    MessageTimelineMessage? current;
    for (final candidate in widget.controller.state.messages) {
      if (candidate.id == message.id) current = candidate;
    }
    if (current == null ||
        !widget.controller.isCanonicalMessage(message.id) ||
        current.message is DeletedMessage) {
      return;
    }
    if (widget.inlineReply) {
      final accepted = widget.inlineDisabledReason == null &&
          (widget.onReplyRequested?.call(MessageContextRequest(
                conversationId: widget.controller.conversationId,
                messageId: message.id,
              )) ??
              false);
      if (!accepted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text(widget.inlineDisabledReason ??
              'The composer cannot accept a reply right now.'),
        ));
      }
      return;
    }
    if (widget.isThread) {
      if (!(widget.onThreadReplyRequested?.call() ?? false)) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text('The thread composer cannot accept a reply right now.'),
        ));
      }
      return;
    }
    final actions = ChatMessageActions.forMessage(
      controller: widget.controller,
      message: message,
    );
    _requestThread(actions);
  }

  void _requestThread(ChatMessageActions actions) {
    final callback = widget.onThreadRequested;
    if (callback != null) {
      unawaited(callback(actions));
    } else {
      unawaited(
        actions.openThread().then((result) {
          if (result case ChatThreadOpenSuccess(:final handle)) {
            handle.release();
          }
        }),
      );
    }
  }

  Future<void> _showReplyMenu(MessageTimelineMessage message) async {
    final generation = widget.bindingGeneration;
    // Return a choice before focusing the composer so dismissing the modal
    // cannot steal focus back from the input.
    final selected = await showModalBottomSheet<bool>(
      context: context,
      useSafeArea: true,
      builder: (context) => ListTile(
        leading: const Icon(Icons.reply),
        title: const Text('Reply'),
        onTap: () => Navigator.of(context).pop(true),
      ),
    );
    if (mounted && selected == true && generation == widget.bindingGeneration) {
      _requestReply(message);
    }
  }

  Future<void> _copyMessage(BuildContext context, String visibleText) async {
    var feedback = 'Message copied';
    try {
      await Clipboard.setData(ClipboardData(text: visibleText));
    } catch (_) {
      feedback = "Message couldn't be copied";
    }
    if (!mounted || !context.mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          content: Semantics(
            container: true,
            liveRegion: true,
            label: feedback,
            child: ExcludeSemantics(child: Text(feedback)),
          ),
        ),
      );
  }

  Future<void> _showReminderSheet(
    BuildContext context,
    ChatMessageActions actions,
  ) async {
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      builder: (context) => _MessageReminderSheet(
        actions: actions,
        clock: widget.reminderClock,
        toLocalTime: widget.reminderToLocalTime,
        toUtcTime: widget.reminderToUtcTime,
        datePicker: widget.reminderDatePicker,
        timePicker: widget.reminderTimePicker,
      ),
    );
  }

  Future<void> _markUnread(
    BuildContext context,
    MessageTimelineMessage message,
  ) async {
    if (!_markUnreadPending.add(message.id)) return;
    final controller = widget.controller;
    final bindingGeneration = widget.bindingGeneration;
    final focusNode = _markUnreadFocusNodes.putIfAbsent(
      message.id,
      FocusNode.new,
    );
    final restoreFocus = focusNode.hasFocus;
    setState(() {});

    ChatCommandResult<ReadCursorMutationResult>? result;
    try {
      result = await ChatTimelineActions(controller).markUnread(
        message.sequence,
      );
    } catch (_) {
      // Unexpected transport details remain outside the widget projection.
    }
    if (!mounted ||
        !context.mounted ||
        !identical(controller, widget.controller) ||
        bindingGeneration != widget.bindingGeneration) {
      return;
    }

    setState(() => _markUnreadPending.remove(message.id));
    final feedback = result is ChatCommandSuccess<ReadCursorMutationResult>
        ? 'Message marked unread'
        : "Message couldn't be marked unread";
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          content: Semantics(
            container: true,
            liveRegion: true,
            label: feedback,
            child: ExcludeSemantics(child: Text(feedback)),
          ),
        ),
      );
    if (restoreFocus) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && focusNode.canRequestFocus) focusNode.requestFocus();
      });
    }
  }

  void _disposeMarkUnreadFocusNodes() {
    for (final focusNode in _markUnreadFocusNodes.values) {
      focusNode.dispose();
    }
    _markUnreadFocusNodes.clear();
  }

  @override
  void dispose() {
    _loadGeneration += 1;
    widget.scrollController.removeListener(_handleScroll);
    _disposeMarkUnreadFocusNodes();
    for (final node in _sourceFocusNodes.values) {
      node.dispose();
    }
    super.dispose();
  }

  Future<void> _jumpToSource(ChatMessageContextController source) async {
    if (!mounted || source.state.source == null) return;
    final id = source.request.messageId;
    final target = _rowKeys[id]?.currentContext;
    if (target != null) {
      // Reuse the existing viewport and row anchors when the source is mounted.
      _sourceFocusNodes[id]?.requestFocus();
      await Scrollable.ensureVisible(target, alignment: 0.5);
      return;
    }
    // The timeline API has no seek/isolated-window operation. Keep its scroll
    // anchor and read tracker intact while showing bounded ephemeral context.
    await showDialog<void>(
      context: context,
      builder: (_) => _ReplySourceWindow(source: source),
    );
  }
}

/// Observes current state directly: queued events from an earlier access
/// generation must never put their source snapshot back on screen.
final class _ReplyContextObserver extends StatefulWidget {
  const _ReplyContextObserver({required this.source, required this.builder});
  final ChatMessageContextController source;
  final Widget Function(BuildContext, ChatMessageContextState) builder;

  @override
  State<_ReplyContextObserver> createState() => _ReplyContextObserverState();
}

final class _ReplyContextObserverState extends State<_ReplyContextObserver> {
  StreamSubscription<ChatMessageContextState>? _subscription;

  @override
  void initState() {
    super.initState();
    _bind();
  }

  void _bind() {
    final source = widget.source;
    _subscription = source.states.listen((_) {
      if (!mounted || !identical(source, widget.source)) return;
      if (source.state.status == ChatMessageContextStatus.idle) {
        unawaited(source.load());
      }
      setState(() {});
    });
    if (source.state.status == ChatMessageContextStatus.idle) {
      unawaited(source.load());
    }
  }

  @override
  void didUpdateWidget(covariant _ReplyContextObserver oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.source, widget.source)) {
      unawaited(_subscription?.cancel());
      _bind();
    }
  }

  @override
  Widget build(BuildContext context) =>
      widget.builder(context, widget.source.state);

  @override
  void dispose() {
    unawaited(_subscription?.cancel());
    super.dispose();
  }
}

final class _ReplyMessageContent extends StatelessWidget {
  const _ReplyMessageContent({
    required this.message,
    required this.actions,
    required this.builder,
    required this.source,
    required this.onJump,
  });
  final MessageTimelineMessage message;
  final ChatMessageActions actions;
  final ChatMessageWidgetBuilder builder;
  final ChatMessageContextController? source;
  final Future<void> Function(ChatMessageContextController) onJump;

  @override
  Widget build(BuildContext context) {
    final controller = source;
    if (controller == null) {
      return builder(
        context,
        ChatMessageBuilderInput(message: message, actions: actions),
      );
    }
    return _ReplyContextObserver(
      source: controller,
      builder: (context, state) {
        final reply = ChatMessageReplyContext(
          reference: message.message.replyTo!,
          state: state,
          jumpToSource: state.source == null
              ? null
              : () async {
                  if (controller.state.source != null) await onJump(controller);
                },
          retry: state.canRetry
              ? () async {
                  if (controller.state.canRetry) await controller.retry();
                }
              : null,
        );
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _ReplyReference(reply: reply),
            builder(
              context,
              ChatMessageBuilderInput(
                message: message,
                actions: actions,
                replyContext: reply,
              ),
            ),
          ],
        );
      },
    );
  }
}

String _replyLabel(ChatMessageContextState state) {
  final source = state.source;
  if (source != null) {
    final text = source.content.text.replaceAll(RegExp(r'\s+'), ' ').trim();
    final excerpt = text.isEmpty
        ? 'Message with attachment or content'
        : text.characters.take(160).toString();
    return 'Reply to ${source.author.userId.value}: $excerpt';
  }
  return switch (state.status) {
    ChatMessageContextStatus.loading => 'Loading original message',
    ChatMessageContextStatus.deleted => 'Original message deleted',
    ChatMessageContextStatus.error => 'Original message could not be loaded',
    _ => 'Original message unavailable',
  };
}

final class _ReplyReference extends StatelessWidget {
  const _ReplyReference({required this.reply});
  final ChatMessageReplyContext reply;

  @override
  Widget build(BuildContext context) {
    final label = _replyLabel(reply.state);
    final jump = reply.jumpToSource;
    if (jump != null) {
      return Semantics(
        container: true,
        label: 'Jump to original message. $label',
        button: true,
        onTap: jump,
        excludeSemantics: true,
        child: TextButton(
          onPressed: jump,
          style: TextButton.styleFrom(
            alignment: AlignmentDirectional.centerStart,
          ),
          child: Text(label, maxLines: 3, overflow: TextOverflow.ellipsis),
        ),
      );
    }
    return Semantics(
      liveRegion: true,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label),
          if (reply.retry != null)
            TextButton(
              onPressed: reply.retry,
              child: const Text('Retry original message'),
            ),
        ],
      ),
    );
  }
}

final class _ReplySourceWindow extends StatefulWidget {
  const _ReplySourceWindow({required this.source});
  final ChatMessageContextController source;

  @override
  State<_ReplySourceWindow> createState() => _ReplySourceWindowState();
}

final class _ReplySourceWindowState extends State<_ReplySourceWindow> {
  final _sourceKey = GlobalKey();
  final _focus = FocusNode(debugLabel: 'Original reply source');

  @override
  void initState() {
    super.initState();
    _reveal();
    unawaited(_loadWindow());
  }

  Future<void> _loadWindow() async {
    // Exactly one page in each direction; no history scan or pagination loop.
    final source = widget.source;
    if (source.state.source == null) return;
    if (source.state.before.isEmpty && source.state.canLoadBefore) {
      await source.loadBefore();
    }
    if (!mounted || source.state.source == null) return;
    if (source.state.after.isEmpty && source.state.canLoadAfter) {
      await source.loadAfter();
    }
    if (mounted) _reveal();
  }

  void _reveal() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || widget.source.state.source == null) return;
      final context = _sourceKey.currentContext;
      if (context == null) return;
      _focus.requestFocus();
      unawaited(Scrollable.ensureVisible(context, alignment: 0.5));
    });
  }

  @override
  Widget build(BuildContext context) => Dialog(
    child: SizedBox(
      width: 560,
      height: 420,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Expanded(
                  child: Semantics(
                    label: 'Original message in this conversation',
                    excludeSemantics: true,
                    child: const Text('Original message'),
                  ),
                ),
                IconButton(
                  tooltip: 'Return to replies',
                  onPressed: () => Navigator.of(context).pop(),
                  icon: const Icon(Icons.close),
                ),
              ],
            ),
            Expanded(
              child: _ReplyContextObserver(
                source: widget.source,
                builder: (context, state) {
                  final source = state.source;
                  return SingleChildScrollView(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        if (source == null) ...[
                          Text(_replyLabel(state)),
                          if (state.canRetry)
                            TextButton(
                              onPressed: () async {
                                await widget.source.retry();
                                if (mounted) await _loadWindow();
                              },
                              child: const Text('Retry original message'),
                            ),
                        ] else ...[
                          for (final message
                              in state.before.reversed
                                  .take(widget.source.pageSize)
                                  .toList()
                                  .reversed)
                            _sourceMessage(message.message),
                          Focus(
                            key: _sourceKey,
                            focusNode: _focus,
                            child: Semantics(
                              container: true,
                              label: 'Original message',
                              child: _sourceMessage(source),
                            ),
                          ),
                          for (final message in state.after.take(
                            widget.source.pageSize,
                          ))
                            _sourceMessage(message.message),
                          if (state.isLoadingPage)
                            const Text('Loading nearby messages'),
                        ],
                      ],
                    ),
                  );
                },
              ),
            ),
          ],
        ),
      ),
    ),
  );

  // Deliberately immediate: never recursively expand these messages' replyTo.
  Widget _sourceMessage(Message message) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 8),
    child: Text(
      message is ActiveMessage
          ? '${message.author.userId.value}: ${message.content.text}'
          : 'Message deleted',
    ),
  );

  @override
  void dispose() {
    _focus.dispose();
    super.dispose();
  }
}

final class _MessageReminderSheet extends StatefulWidget {
  const _MessageReminderSheet({
    required this.actions,
    required this.clock,
    required this.toLocalTime,
    required this.toUtcTime,
    required this.datePicker,
    required this.timePicker,
  });

  final ChatMessageActions actions;
  final HandrailReminderClock clock;
  final HandrailReminderToLocalTime toLocalTime;
  final HandrailReminderToUtcTime toUtcTime;
  final HandrailReminderDatePicker datePicker;
  final HandrailReminderTimePicker timePicker;

  @override
  State<_MessageReminderSheet> createState() => _MessageReminderSheetState();
}

final class _MessageReminderSheetState extends State<_MessageReminderSheet> {
  var _submitting = false;
  String? _feedback;

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<NormalizedMessageReminderState>(
      stream: widget.actions.reminderStates,
      initialData: widget.actions.reminderState,
      builder: (context, snapshot) {
        final state = snapshot.data ?? widget.actions.reminderState;
        final scheduled = state.isScheduled;
        final busy = _submitting || state.isPending;
        final dueLabel =
            state.dueAt == null ? null : _formatDueAt(context, state.dueAt!);
        return Padding(
          padding: EdgeInsets.fromLTRB(
            24,
            16,
            24,
            16 + MediaQuery.viewInsetsOf(context).bottom,
          ),
          child: Column(
            key: ValueKey<String>(
              'handrail-reminder-sheet-${widget.actions.messageId.value}',
            ),
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  const Expanded(
                    child: Text(
                      'Remind me',
                      style: TextStyle(
                        fontSize: 20,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                  IconButton(
                    tooltip: 'Close reminder',
                    onPressed: busy ? null : Navigator.of(context).pop,
                    icon: const Icon(Icons.close),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              Semantics(
                container: true,
                liveRegion: true,
                label: busy
                    ? 'Updating reminder'
                    : scheduled
                        ? 'Reminder scheduled for $dueLabel. '
                            'Revision ${state.authoritativeRevision}'
                        : 'No reminder scheduled. '
                            'Revision ${state.authoritativeRevision}',
                child: ExcludeSemantics(
                  child: Text(
                    busy
                        ? 'Updating reminder…'
                        : scheduled
                            ? 'Scheduled for $dueLabel\n'
                                'Revision ${state.authoritativeRevision}'
                            : 'No reminder scheduled',
                  ),
                ),
              ),
              const SizedBox(height: 12),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  OutlinedButton(
                    key: const ValueKey<String>(
                      'handrail-reminder-preset-20-minutes',
                    ),
                    onPressed: busy
                        ? null
                        : () => _schedule(
                              widget.clock().toUtc().add(
                                    const Duration(minutes: 20),
                                  ),
                              reschedule: scheduled,
                            ),
                    child: const Text('In 20 minutes'),
                  ),
                  OutlinedButton(
                    key: const ValueKey<String>(
                      'handrail-reminder-preset-1-hour',
                    ),
                    onPressed: busy
                        ? null
                        : () => _schedule(
                              widget.clock().toUtc().add(
                                    const Duration(hours: 1),
                                  ),
                              reschedule: scheduled,
                            ),
                    child: const Text('In 1 hour'),
                  ),
                  OutlinedButton(
                    key: const ValueKey<String>(
                      'handrail-reminder-preset-tomorrow',
                    ),
                    onPressed: busy
                        ? null
                        : () => _schedule(
                              _tomorrowAtNine(),
                              reschedule: scheduled,
                            ),
                    child: const Text('Tomorrow at 9:00 AM'),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              TextButton.icon(
                key: const ValueKey<String>('handrail-reminder-custom'),
                onPressed:
                    busy ? null : () => _pickCustomTime(reschedule: scheduled),
                icon: const Icon(Icons.calendar_today_outlined),
                label: Text(
                  scheduled
                      ? 'Choose a new date and time'
                      : 'Choose a date and time',
                ),
              ),
              if (scheduled)
                TextButton.icon(
                  key: const ValueKey<String>('handrail-reminder-cancel'),
                  onPressed: busy ? null : _cancel,
                  icon: const Icon(Icons.notifications_off_outlined),
                  label: const Text('Cancel reminder'),
                ),
              if (_feedback case final feedback?) ...[
                const SizedBox(height: 8),
                Semantics(
                  container: true,
                  liveRegion: true,
                  label: feedback,
                  child: ExcludeSemantics(child: Text(feedback)),
                ),
              ],
            ],
          ),
        );
      },
    );
  }

  DateTime _tomorrowAtNine() {
    final localNow = widget.toLocalTime(widget.clock().toUtc());
    final localDue = DateTime(
      localNow.year,
      localNow.month,
      localNow.day + 1,
      9,
    );
    return widget.toUtcTime(localDue).toUtc();
  }

  Future<void> _pickCustomTime({required bool reschedule}) async {
    final nowUtc = widget.clock().toUtc();
    final localNow = widget.toLocalTime(nowUtc);
    final initial = localNow.add(const Duration(hours: 1));
    final date = await widget.datePicker(
      context,
      initial,
      DateTime(localNow.year, localNow.month, localNow.day),
      DateTime(localNow.year + 5, localNow.month, localNow.day),
    );
    if (date == null || !mounted) return;
    final time = await widget.timePicker(
      context,
      TimeOfDay.fromDateTime(initial),
    );
    if (time == null || !mounted) return;
    final localDue = DateTime(
      date.year,
      date.month,
      date.day,
      time.hour,
      time.minute,
    );
    final dueUtc = widget.toUtcTime(localDue).toUtc();
    if (!dueUtc.isAfter(widget.clock().toUtc())) {
      setState(() => _feedback = 'Choose a future reminder time.');
      return;
    }
    await _schedule(dueUtc, reschedule: reschedule);
  }

  Future<void> _schedule(
    DateTime dueUtc, {
    required bool reschedule,
  }) async {
    if (_submitting) return;
    setState(() {
      _submitting = true;
      _feedback = null;
    });
    ChatCommandResult<MessageReminderResult>? result;
    try {
      final dueAt = IsoTimestamp(dueUtc.toUtc().toIso8601String());
      result = await (reschedule
          ? widget.actions.rescheduleReminder(dueAt)
          : widget.actions.scheduleReminder(dueAt));
    } catch (_) {
      // Command and transport internals remain outside the widget projection.
    }
    if (!mounted) return;
    setState(() {
      _submitting = false;
      _feedback = _commandFeedback(
        result,
        success: reschedule ? 'Reminder rescheduled' : 'Reminder scheduled',
      );
    });
  }

  Future<void> _cancel() async {
    if (_submitting) return;
    setState(() {
      _submitting = true;
      _feedback = null;
    });
    ChatCommandResult<MessageReminderResult>? result;
    try {
      result = await widget.actions.cancelReminder();
    } catch (_) {
      // Command and transport internals remain outside the widget projection.
    }
    if (!mounted) return;
    setState(() {
      _submitting = false;
      _feedback = _commandFeedback(result, success: 'Reminder cancelled');
    });
  }

  String _commandFeedback(
    ChatCommandResult<MessageReminderResult>? result, {
    required String success,
  }) {
    if (result case ChatCommandSuccess<MessageReminderResult>(:final value)) {
      return value.reconciliationStatus ==
              MessageReminderReconciliationStatus.revisionConflict
          ? 'Reminder changed on the server. Showing the latest schedule.'
          : success;
    }
    return "Reminder couldn't be updated";
  }

  String _formatDueAt(BuildContext context, IsoTimestamp dueAt) {
    final local = widget.toLocalTime(DateTime.parse(dueAt.value).toUtc());
    final localizations = MaterialLocalizations.of(context);
    return '${localizations.formatFullDate(local)} at '
        '${localizations.formatTimeOfDay(TimeOfDay.fromDateTime(local))}';
  }
}

final class _UnreadBoundary extends StatelessWidget {
  const _UnreadBoundary({super.key});

  @override
  Widget build(BuildContext context) {
    final theme = HandrailChatTheme.of(context);
    final color = Theme.of(context).colorScheme.error;
    return Semantics(
      container: true,
      label: 'Unread messages',
      child: Padding(
        padding: EdgeInsets.symmetric(vertical: theme.spacing.small),
        child: Row(
          children: [
            Expanded(child: Divider(color: color)),
            Padding(
              padding: EdgeInsets.symmetric(horizontal: theme.spacing.small),
              child: Text(
                'New messages',
                style: theme.typography.metadata.copyWith(color: color),
              ),
            ),
            Expanded(child: Divider(color: color)),
          ],
        ),
      ),
    );
  }
}
