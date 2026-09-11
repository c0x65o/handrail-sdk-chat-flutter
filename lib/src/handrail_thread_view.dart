import 'dart:async';

import 'package:flutter/material.dart';

import '../core.dart';
import 'chat_application_delegates.dart';
import 'chat_scope.dart';
import 'chat_state_builders.dart';
import 'chat_widget_builders.dart';
import 'handrail_chat_theme.dart';
import 'handrail_message_composer.dart';
import 'handrail_message_timeline.dart';

/// Builds the root-message context shown above a thread timeline.
typedef HandrailThreadRootBuilder = Widget Function(
  BuildContext context,
  HandrailThreadRootBuilderInput input,
);

/// Builds the opening state shown while a thread controller resolves.
typedef HandrailThreadOpeningBuilder = Widget Function(
  BuildContext context,
  ChatThreadOpeningState state,
);

/// Builds an unavailable, access-denied, or general thread-opening failure.
typedef HandrailThreadFailureBuilder = Widget Function(
  BuildContext context,
  HandrailThreadFailureBuilderInput input,
);

/// Stable categories used by [HandrailThreadFailureBuilder].
enum HandrailThreadFailureKind { unavailable, accessDenied, error }

/// Immutable public input for a thread root-context builder.
@immutable
final class HandrailThreadRootBuilderInput {
  const HandrailThreadRootBuilderInput({
    required this.rootMessageId,
    required this.message,
    required this.actions,
  });

  final MessageId rootMessageId;
  final MessageTimelineMessage? message;
  final ChatMessageActions? actions;
}

/// Immutable public input for a thread-opening failure builder.
@immutable
final class HandrailThreadFailureBuilderInput {
  const HandrailThreadFailureBuilderInput({
    required this.kind,
    required this.error,
    required this.retry,
  });

  final HandrailThreadFailureKind kind;
  final ChatThreadOpeningErrorState error;
  final VoidCallback retry;
}

/// A layout-neutral view of one root message and its canonical thread.
///
/// Supply a [rootMessage] or [rootMessageId] to resolve the thread from
/// [threads] (or the nearest [ChatScope]). Alternatively, supply a caller-owned
/// [openingController] or an already-retained caller-owned [openHandle]. The
/// widget releases only handles it acquires by calling `open`; it never
/// disposes controllers or releases [openHandle].
///
/// Under a bounded height the reply timeline expands into the available space.
/// Under an unbounded height it uses [unboundedTimelineHeight], allowing the
/// same widget to be embedded in a route, sheet, panel, or inline region.
final class HandrailThreadView extends StatefulWidget {
  const HandrailThreadView({
    this.rootMessage,
    this.rootMessageId,
    this.threads,
    this.openingController,
    this.openHandle,
    this.lifecycleController,
    this.onClose,
    this.title,
    this.builders = const ChatWidgetBuilders(),
    this.delegates = const ChatApplicationDelegates(),
    this.rootBuilder,
    this.openingBuilder = defaultHandrailThreadOpeningBuilder,
    this.failureBuilder = defaultHandrailThreadFailureBuilder,
    this.timelineScrollController,
    this.composerController,
    this.composerFocusNode,
    this.composerEnabled = true,
    this.unboundedTimelineHeight = 320,
    super.key,
  })  : assert(
          rootMessage != null ||
              rootMessageId != null ||
              openingController != null ||
              openHandle != null,
          'A root message, root message identifier, opening controller, or '
          'open handle is required.',
        ),
        assert(
          openingController == null || openHandle == null,
          'Supply either openingController or openHandle, not both.',
        ),
        assert(
          threads == null || (openingController == null && openHandle == null),
          'threads is used only when opening from a root message.',
        ),
        assert(unboundedTimelineHeight > 0);

  /// Optional rich root projection. Its identifier is also an opening source.
  final MessageTimelineMessage? rootMessage;

  /// Root identifier used when no controller or handle is supplied.
  final MessageId? rootMessageId;

  /// Optional caller-owned thread registry used to resolve [rootMessageId].
  final ChatThreadsController? threads;

  /// Optional caller-owned root controller. The widget calls `open` on it and
  /// releases the resulting retain, but never disposes the controller.
  final ChatThreadOpeningController? openingController;

  /// An already-retained caller-owned handle. The widget never releases it.
  final ChatThreadOpenHandle? openHandle;

  /// Optional caller-owned controller for the resolved thread. Defaults to
  /// `ChatScope.client.threadLifecycles.forThread(threadId)`.
  ///
  /// The host must supply trusted authority with `setAuthority` and call `load`
  /// on that controller, updating it when actor/access changes. The view
  /// observes host configuration and never replaces authority or disposes it.
  /// Missing authority/capability hides shared actions, preserving legacy use.
  /// Host-only send restrictions still belong in [composerEnabled].
  final ChatThreadLifecycleController? lifecycleController;

  /// Host-owned navigation callback. No route or navigator behavior is assumed.
  final VoidCallback? onClose;
  final Widget? title;
  final ChatWidgetBuilders builders;
  final ChatApplicationDelegates delegates;
  final HandrailThreadRootBuilder? rootBuilder;
  final HandrailThreadOpeningBuilder openingBuilder;
  final HandrailThreadFailureBuilder failureBuilder;
  final ScrollController? timelineScrollController;
  final TextEditingController? composerController;
  final FocusNode? composerFocusNode;
  final bool composerEnabled;
  final double unboundedTimelineHeight;

  @override
  State<HandrailThreadView> createState() => _HandrailThreadViewState();
}

final class _HandrailThreadViewState extends State<HandrailThreadView> {
  final _composerKey = GlobalKey<HandrailMessageComposerState>();

  bool _selectReply(MessageContextRequest source) =>
      _composerKey.currentState?.selectReply(source) ?? false;

  bool _continueThreadReply() =>
      _composerKey.currentState?.focusComposition() ?? false;

  ChatThreadOpeningController? _openingController;
  StreamSubscription<ChatThreadOpeningState>? _openingSubscription;
  ChatThreadOpenHandle? _handle;
  ChatThreadOpeningState? _openingState;
  bool _ownsHandle = false;
  HandrailChatClient? _lifecycleClient;
  ChatThreadLifecycleController? _lifecycleController;
  final _lifecycleSubscriptions = <StreamSubscription<dynamic>>[];
  var _lifecycleGeneration = 0;
  var _bindingGeneration = 0;
  var _disposed = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _bind();
    _bindLifecycle();
  }

  @override
  void didUpdateWidget(covariant HandrailThreadView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.openHandle, widget.openHandle) ||
        !identical(oldWidget.openingController, widget.openingController) ||
        !identical(oldWidget.threads, widget.threads) ||
        oldWidget.rootMessageId != widget.rootMessageId ||
        oldWidget.rootMessage?.id != widget.rootMessage?.id) {
      _bind(force: true);
    }
    _bindLifecycle();
  }

  MessageId _resolveRootMessageId() {
    final candidates = <MessageId?>[
      widget.rootMessage?.id,
      widget.rootMessageId,
      widget.openingController?.rootMessageId,
      widget.openHandle?.rootMessageId,
    ].whereType<MessageId>().toList(growable: false);
    final rootMessageId = candidates.first;
    if (candidates.any((candidate) => candidate != rootMessageId)) {
      throw FlutterError(
        'HandrailThreadView received thread sources for different root '
        'message identifiers.',
      );
    }
    return rootMessageId;
  }

  void _bind({bool force = false}) {
    final rootMessageId = _resolveRootMessageId();
    final suppliedHandle = widget.openHandle;
    if (suppliedHandle != null) {
      if (!force &&
          identical(_handle, suppliedHandle) &&
          !_ownsHandle &&
          _openingController == null) {
        return;
      }
      _releaseBinding();
      _handle = suppliedHandle;
      _openingState = suppliedHandle.state;
      _bindLifecycle();
      return;
    }

    final controller = widget.openingController ??
        (widget.threads ?? ChatScope.of(context).client.threads)
            .forRoot(rootMessageId);
    if (!force && identical(_openingController, controller)) return;

    _releaseBinding();
    final generation = _bindingGeneration;
    _openingController = controller;
    _openingState = controller.state;
    _openingSubscription = controller.states.listen((state) {
      if (_disposed || generation != _bindingGeneration) return;
      if (identical(_openingState, state)) return;
      setState(() => _openingState = state);
    });
    unawaited(_open(controller, generation));
  }

  Future<void> _open(
    ChatThreadOpeningController controller,
    int generation,
  ) async {
    final result = await controller.open();
    if (_disposed ||
        generation != _bindingGeneration ||
        !identical(controller, _openingController)) {
      if (result case ChatThreadOpenSuccess(:final handle)) handle.release();
      return;
    }
    switch (result) {
      case ChatThreadOpenSuccess(:final handle):
        if (_ownsHandle) _handle?.release();
        setState(() {
          _handle = handle;
          _ownsHandle = true;
          _openingState = handle.state;
          _bindLifecycle();
        });
      case ChatThreadOpenFailure(:final error):
        setState(() => _openingState = error);
    }
  }

  void _retry() {
    final controller = _openingController;
    if (controller == null) return;
    final generation = _bindingGeneration;
    setState(() => _openingState = controller.state);
    unawaited(_open(controller, generation));
  }

  void _releaseBinding() {
    _releaseLifecycle();
    _bindingGeneration += 1;
    final subscription = _openingSubscription;
    _openingSubscription = null;
    if (subscription != null) unawaited(subscription.cancel());
    if (_ownsHandle) _handle?.release();
    _ownsHandle = false;
    _handle = null;
    _openingController = null;
    _openingState = null;
  }

  void _releaseLifecycle() {
    ++_lifecycleGeneration;
    for (final subscription in _lifecycleSubscriptions) {
      unawaited(subscription.cancel());
    }
    _lifecycleSubscriptions.clear();
    _lifecycleController = null;
    _lifecycleClient = null;
  }

  void _bindLifecycle() {
    final handle = _handle;
    if (handle == null) return;
    final client = ChatScope.of(context).client;
    final controller = widget.lifecycleController ??
        client.threadLifecycles.forThread(handle.conversationId);
    if (controller.threadId != handle.conversationId) {
      throw FlutterError(
          'Lifecycle controller must belong to the displayed thread.');
    }
    if (identical(controller, _lifecycleController) &&
        identical(client, _lifecycleClient)) {
      return;
    }
    _releaseLifecycle();
    _lifecycleClient = client;
    _lifecycleController = controller;
    final generation = _lifecycleGeneration;
    void changed(Object? _) {
      if (_disposed || generation != _lifecycleGeneration) return;
      setState(() {});
    }

    _lifecycleSubscriptions.add(controller.states.listen(changed));
    // Observe restrictions even when lifecycle management is unsupported or
    // unconfigured. The opening handle is a snapshot, not current authority.
    for (final id in [
      handle.conversationId,
      handle.state.parentConversationId
    ]) {
      _lifecycleSubscriptions
          .add(client.normalizedState.watchConversation(id).listen(changed));
    }
  }

  bool get _archived {
    if (_lifecycleController?.state.isArchived == true ||
        _lifecycleController?.state.isParentArchived == true) {
      return true;
    }
    final handle = _handle;
    final store = _lifecycleClient?.normalizedState.state;
    if (handle == null || store == null) return false;
    return [handle.conversationId, handle.state.parentConversationId].any(
        (id) =>
            store.lifecycleArchivedStates[id] ??
            (store.conversations[id]?.archivedAt != null));
  }

  ThreadLifecycle? get _currentLifecycle {
    final cached = _lifecycleClient
        ?.normalizedState.state.conversations[_handle?.conversationId];
    final observed = _lifecycleController?.state.lifecycle;
    final current =
        cached is ThreadConversation ? cached.threadLifecycle : null;
    return current != null && current.revision > (observed?.revision ?? 0)
        ? current
        : observed;
  }

  bool get _composerEnabled =>
      widget.composerEnabled &&
      !_archived &&
      !(_currentLifecycle?.locked ?? false) &&
      _lifecycleController?.state.error != ChatThreadLifecycleError.denied;

  @override
  Widget build(BuildContext context) {
    final rootMessageId = _resolveRootMessageId();
    final tokens = HandrailChatTheme.of(context);
    final colors = Theme.of(context).colorScheme;
    final root = _buildRootContext(context, rootMessageId, tokens, colors);
    final content = _buildContent(context, rootMessageId);

    return LayoutBuilder(
      builder: (context, constraints) {
        final boundedHeight = constraints.hasBoundedHeight;
        Widget body(double? maxHeight) {
          final handle = _handle;
          final composer = handle == null
              ? null
              : KeyedSubtree(
                  key: ValueKey<String>(
                    'handrail-thread-composer-${handle.conversationId.value}',
                  ),
                  child: HandrailMessageComposer(
                    key: _composerKey,
                    conversationId: handle.conversationId,
                    delegates: widget.delegates,
                    controller: widget.composerController,
                    focusNode: widget.composerFocusNode,
                    enabled: _composerEnabled,
                    showFormatSelector: constraints.maxWidth >= 320,
                  ),
                );
          return Column(
            mainAxisSize:
                maxHeight == null ? MainAxisSize.min : MainAxisSize.max,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (maxHeight != null)
                Expanded(child: content)
              else
                SizedBox(
                    height: widget.unboundedTimelineHeight, child: content),
              if (composer != null)
                if (maxHeight != null)
                  // Keep all draft controls reachable when header/root context and
                  // the composer together exceed the panel's available height.
                  ConstrainedBox(
                    constraints: BoxConstraints(maxHeight: maxHeight),
                    child: SingleChildScrollView(child: composer),
                  )
                else
                  composer,
            ],
          );
        }

        return Material(
          color: colors.surface,
          child: Column(
            mainAxisSize: boundedHeight ? MainAxisSize.max : MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _buildHeader(context, tokens),
              if (_handle != null) _buildLifecycleStatus(),
              Divider(height: 1, color: colors.outlineVariant),
              root,
              Divider(height: 1, color: colors.outlineVariant),
              if (boundedHeight)
                Expanded(
                  child: LayoutBuilder(
                    builder: (context, remaining) => body(remaining.maxHeight),
                  ),
                )
              else
                body(null),
            ],
          ),
        );
      },
    );
  }

  Widget _buildHeader(BuildContext context, HandrailChatThemeData tokens) {
    Widget header(Widget? menu, Widget? status) => Semantics(
          container: true,
          header: true,
          child: Padding(
            padding: EdgeInsetsDirectional.only(
              start: tokens.spacing.medium,
              end: tokens.spacing.extraSmall,
              top: tokens.spacing.extraSmall,
              bottom: tokens.spacing.extraSmall,
            ),
            child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Row(children: [
                    Expanded(
                      child: DefaultTextStyle(
                        style: tokens.typography.conversationTitle,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        child: widget.title ??
                            Text(_handle?.conversation.name ?? 'Thread'),
                      ),
                    ),
                    if (menu != null) menu,
                    if (_handle != null) _buildLifecycleMenu(),
                    if (widget.onClose case final onClose?)
                      IconButton(
                        key: const ValueKey<String>('handrail-thread-close'),
                        tooltip: 'Close panel',
                        onPressed: onClose,
                        icon: const Icon(Icons.close),
                      ),
                  ]),
                  if (status != null) status,
                ]),
          ),
        );
    final handle = _handle;
    if (handle == null) return header(null, null);
    final client = ChatScope.of(context).client;
    return _ThreadSubscriptions(
      key: ValueKey((client, handle.conversationId)),
      client: client,
      threadId: handle.conversationId,
      builder: header,
    );
  }

  Widget _buildLifecycleStatus() {
    final state = _lifecycleController?.state;
    final lifecycle = _currentLifecycle;
    final message = switch (state?.status) {
      ChatThreadLifecycleStatus.loading => 'Loading thread controls…',
      ChatThreadLifecycleStatus.saving => 'Saving thread change…',
      ChatThreadLifecycleStatus.conflict =>
        'Thread changed elsewhere. Review its current state before choosing another action.',
      ChatThreadLifecycleStatus.error => state?.error ==
              ChatThreadLifecycleError.denied
          ? 'Thread lifecycle access denied. Your draft is retained.'
          : 'Thread controls could not be updated or loaded. Your draft is retained.',
      _ => null,
    };
    final restriction = _archived
        ? 'Thread or parent administratively archived. Sending is disabled; your draft is retained.'
        : lifecycle?.locked == true
            ? 'Thread locked and closed. Unlocking leaves it closed. Your draft is retained.'
            : lifecycle?.closedAt != null
                ? 'Thread closed. An authorized send reopens it atomically. Opening this panel does not.'
                : 'Thread open';
    final availability = state?.capabilities.supported != true
        ? 'Shared thread controls are unavailable on this server.'
        : state?.conversation == null && message == null
            ? 'Shared thread controls require current host authority and loading.'
            : null;
    final description = [
      restriction,
      if (message != null) message,
      if (availability != null) availability,
    ].join(' ');
    return Semantics(
      liveRegion: true,
      label: description,
      excludeSemantics: true,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
        child: Tooltip(
          message: description,
          child: Text(description,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: Theme.of(context).textTheme.bodySmall),
        ),
      ),
    );
  }

  Widget _buildLifecycleMenu() {
    final controller = _lifecycleController;
    if (controller == null) return const SizedBox.shrink();
    final state = controller.state;
    final busy =
        state.isSaving || state.status == ChatThreadLifecycleStatus.loading;
    final locked = _currentLifecycle?.locked ?? false;
    final closed = _currentLifecycle?.closedAt != null;
    final actions = <String, Future<ChatThreadLifecycleState> Function()>{};
    if (!busy && !_archived && !state.canRetry) {
      if (!closed && state.capabilities.canClose) {
        actions['Close shared thread'] = controller.close;
      }
      if (closed && !locked && state.capabilities.canReopen) {
        actions['Reopen thread'] = controller.reopen;
      }
      if (!locked && state.capabilities.canLock) {
        actions['Lock and close thread'] = controller.lock;
      }
      if (locked && state.capabilities.canUnlock) {
        actions['Unlock thread (leaves closed)'] = controller.unlock;
      }
    }
    if (!busy && state.canRetry) {
      actions['Retry thread change'] = controller.retry;
    } else if (!busy &&
        state.conversation == null &&
        state.error == ChatThreadLifecycleError.transport) {
      actions['Retry loading thread controls'] = controller.load;
    }
    if (actions.isEmpty && !busy) return const SizedBox.shrink();
    final generation = _lifecycleGeneration;
    return PopupMenuButton<String>(
      tooltip: 'Shared thread controls',
      icon: const Icon(Icons.more_vert),
      itemBuilder: (_) => [
        if (busy)
          PopupMenuItem<String>(
            enabled: false,
            child: Text(state.isSaving
                ? 'Saving thread change…'
                : 'Loading thread controls…'),
          ),
        for (final label in actions.keys)
          PopupMenuItem(value: label, child: Text(label)),
      ],
      onSelected: (label) {
        if (_disposed || generation != _lifecycleGeneration) return;
        // Menu routes can outlive the state they displayed. Recheck current
        // availability before dispatching an intent (the controller also gates).
        final currentMenuState = controller.state;
        if (!identical(currentMenuState, state)) return;
        unawaited(actions[label]!());
      },
    );
  }

  Widget _buildRootContext(
    BuildContext context,
    MessageId rootMessageId,
    HandrailChatThemeData tokens,
    ColorScheme colors,
  ) {
    final message = widget.rootMessage;
    ChatMessageActions? actions;
    if (message != null) {
      final controller = ChatScope.of(context)
          .client
          .timelines
          .forConversation(message.conversationId);
      actions = ChatMessageActions.forMessage(
        controller: controller,
        message: message,
      );
    }
    final input = HandrailThreadRootBuilderInput(
      rootMessageId: rootMessageId,
      message: message,
      actions: actions,
    );
    final customBuilder = widget.rootBuilder;
    if (customBuilder != null) return customBuilder(context, input);

    final handle = _handle;
    Widget rootBox(String parentLabel, Widget root) => Semantics(
      container: true,
      label: 'Thread root message',
      child: ColoredBox(
        key: const ValueKey<String>('handrail-thread-root-context'),
        color: colors.surfaceContainerLow,
        child: Padding(
          padding: EdgeInsets.all(tokens.spacing.medium),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                parentLabel,
                style: tokens.typography.metadata,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
              root,
            ],
          ),
        ),
      ),
    );
    if (handle == null) {
      return rootBox(
        'Parent conversation',
        const Text('Root message unavailable'),
      );
    }
    // Observe current access rather than treating cached names/content as authority.
    return ConversationStateBuilder.forConversation(
      conversationId: handle.state.parentConversationId,
      builder: (context, parent) {
        if (parent.status != ChatConversationControllerStatus.ready) {
          return rootBox(
            'Parent conversation unavailable',
            const Text('Root message unavailable'),
          );
        }
        final label = switch (parent.conversation) {
          ChannelConversation(:final name) => 'In $name',
          DirectConversation() => 'In direct conversation',
          GroupDirectConversation() => 'In group conversation',
          _ => 'Parent conversation',
        };
        final timeline = ChatScope.of(
          context,
        ).client.timelines.forConversation(handle.state.parentConversationId);
        return TimelineStateBuilder(
          controller: timeline,
          builder: (context, state) {
            if (state.status == ChatTimelineControllerStatus.accessRevoked) {
              return rootBox(
                'Parent conversation unavailable',
                const Text('Root message unavailable'),
              );
            }
            final latest = state.messages
                .where((message) => message.id == rootMessageId)
                .firstOrNull;
            // Existing-thread reads carry explicit root access/deletion results.
            final authorizedRead = handle.state.detail != null;
            final root = authorizedRead
                ? handle.state.rootMessage
                : latest?.message;
            final deleted =
                latest?.message is DeletedMessage ||
                handle.state.rootContextStatus ==
                    ChatThreadRootContextStatus.deleted;
            if (deleted || root == null) {
              return rootBox(
                label,
                Text(
                  deleted ? 'Root message deleted' : 'Root message unavailable',
                ),
              );
            }
            final projection = authorizedRead
                ? MessageTimelineMessage(
                    message: root,
                    isThreadRoot: true,
                    reactions: const [],
                    attachmentMetadata: const [],
                  )
                : latest!;
            return rootBox(
              label,
              Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  widget.builders.message(
                    context,
                    ChatMessageBuilderInput(
                      message: projection,
                      actions: ChatMessageActions.forMessage(
                        controller: timeline,
                        message: projection,
                      ),
                    ),
                  ),
                  for (final attachment in projection.attachmentMetadata)
                    Padding(
                      padding: EdgeInsets.only(top: tokens.spacing.small),
                      child: widget.builders.attachmentPreview(
                        context,
                        ChatAttachmentPreviewBuilderInput(
                          attachment: attachment,
                        ),
                      ),
                    ),
                ],
              ),
            );
          },
        );
      },
    );
  }

  Widget _buildContent(BuildContext context, MessageId rootMessageId) {
    final handle = _handle;
    if (handle != null) {
      return HandrailMessageTimeline(
        key: ValueKey<String>(
          'handrail-thread-timeline-${handle.conversationId.value}',
        ),
        conversationId: handle.conversationId,
        builders: widget.builders,
        scrollController: widget.timelineScrollController,
        onReplyRequested: _composerEnabled ? _selectReply : null,
        onThreadReplyRequested: _composerEnabled ? _continueThreadReply : null,
      );
    }

    final state = _openingController?.state ??
        _openingState ??
        ChatThreadOpeningIdleState(rootMessageId: rootMessageId);
    if (state case final ChatThreadOpeningErrorState error) {
      return widget.failureBuilder(
        context,
        HandrailThreadFailureBuilderInput(
          kind: _failureKind(error),
          error: error,
          retry: _retry,
        ),
      );
    }
    return widget.openingBuilder(context, state);
  }

  @override
  void dispose() {
    _disposed = true;
    _releaseBinding();
    super.dispose();
  }
}

HandrailThreadFailureKind _failureKind(ChatThreadOpeningErrorState error) {
  if (error.code == ChatThreadOpeningErrorCode.rootMessageUnavailable) {
    return HandrailThreadFailureKind.unavailable;
  }
  if (error.code == ChatThreadOpeningErrorCode.authentication ||
      error.httpStatus == 401 ||
      error.httpStatus == 403) {
    return HandrailThreadFailureKind.accessDenied;
  }
  return HandrailThreadFailureKind.error;
}

/// Default accessible opening renderer for [HandrailThreadView].
Widget defaultHandrailThreadOpeningBuilder(
  BuildContext context,
  ChatThreadOpeningState state,
) {
  return Semantics(
    container: true,
    liveRegion: true,
    label: 'Opening thread',
    child: const Center(child: CircularProgressIndicator()),
  );
}

/// Default accessible failure renderer for [HandrailThreadView].
Widget defaultHandrailThreadFailureBuilder(
  BuildContext context,
  HandrailThreadFailureBuilderInput input,
) {
  final (semanticsLabel, message) = switch (input.kind) {
    HandrailThreadFailureKind.unavailable => (
        'Thread unavailable',
        'This thread is unavailable.',
      ),
    HandrailThreadFailureKind.accessDenied => (
        'Thread access denied',
        'You do not have access to this thread.',
      ),
    HandrailThreadFailureKind.error => (
        'Thread opening error',
        input.error.message,
      ),
  };
  return Semantics(
    container: true,
    liveRegion: true,
    label: semanticsLabel,
    child: Center(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(message, textAlign: TextAlign.center),
            const SizedBox(height: 8),
            TextButton(onPressed: input.retry, child: const Text('Retry')),
          ],
        ),
      ),
    ),
  );
}

// Keyed by client and thread: an old popup or asynchronous completion cannot
// act on a replacement binding. These controllers remain client-owned.
final class _ThreadSubscriptions extends StatefulWidget {
  const _ThreadSubscriptions({
    required this.client,
    required this.threadId,
    required this.builder,
    super.key,
  });
  final Widget Function(Widget menu, Widget status) builder;
  final HandrailChatClient client;
  final ConversationId threadId;

  @override
  State<_ThreadSubscriptions> createState() => _ThreadSubscriptionsState();
}

enum _SubscriptionAction {
  follow,
  unfollow,
  all,
  mentions,
  none,
  unmute,
  mute,
  hour,
  load
}

final class _ThreadSubscriptionsState extends State<_ThreadSubscriptions> {
  late final _conversation =
      widget.client.conversations.forConversation(widget.threadId);
  late final _follow = widget.client.threads.forThread(widget.threadId);
  final _subscriptions = <StreamSubscription<dynamic>>[];
  bool _saving = false;
  bool _loading = false;
  String? _message;
  _SubscriptionAction? _retryAction;

  @override
  void initState() {
    super.initState();
    void changed(Object? _) {
      if (mounted) setState(() {});
    }

    _subscriptions.addAll([
      _conversation.states.listen(changed),
      _conversation.conversationPreferenceStates.listen(changed),
      _follow.states.listen(changed),
      widget.client.replyStyles.states.listen(changed),
    ]);
  }

  bool get _busy =>
      _saving ||
      _loading ||
      _follow.state.isPending ||
      _conversation.conversationPreferenceState.isPending;
  bool get _ready =>
      _conversation.state.status == ChatConversationControllerStatus.ready;

  Future<void> _perform(_SubscriptionAction action) async {
    if (!mounted || _busy) return;
    if (action == _SubscriptionAction.load) {
      setState(() {
        _loading = true;
        _message = null;
      });
      try {
        await _conversation.refresh();
      } catch (_) {
        // Missing canonical state keeps the explicit loading retry available.
      } finally {
        if (mounted) setState(() => _loading = false);
      }
      return;
    }
    if (!_ready) return;
    final preference =
        _conversation.conversationPreferenceState.authoritativePreference;
    final following = action == _SubscriptionAction.follow ||
        action == _SubscriptionAction.unfollow;
    if (!following && preference == null) return;
    setState(() {
      _saving = true;
      _message = null;
      _retryAction = null;
    });
    var succeeded = false;
    var conflict = false;
    try {
      if (following) {
        final desired = action == _SubscriptionAction.follow;
        final result = await (desired ? _follow.follow() : _follow.unfollow());
        if (result
            case ChatCommandSuccess<SetThreadFollowResult>(:final value)) {
          conflict = value.reconciliationStatus ==
              ThreadFollowMutationReconciliationStatus.followRevisionConflict;
          succeeded = _follow.state.authoritativeFollow?.isFollowing == desired;
        } else {
          conflict = result is ChatCommandConflict<SetThreadFollowResult>;
        }
      } else {
        // updatePreferences replaces the entire record. Patch only the selected
        // field onto current confirmed state, including on explicit retry.
        final notification = switch (action) {
          _SubscriptionAction.all => ConversationNotificationPreference.all,
          _SubscriptionAction.mentions =>
            ConversationNotificationPreference.mentions,
          _SubscriptionAction.none => ConversationNotificationPreference.none,
          _ => ConversationNotificationPreference.values.firstWhere(
              (value) => value.wireValue == preference!.notificationPreference),
        };
        final mute = switch (action) {
          _SubscriptionAction.unmute => const UnmutedConversationPreference(),
          _SubscriptionAction.mute =>
            const IndefinitelyMutedConversationPreference(),
          _SubscriptionAction.hour => MutedUntilConversationPreference(
              IsoTimestamp(DateTime.now()
                  .toUtc()
                  .add(const Duration(hours: 1))
                  .toIso8601String())),
          _ =>
            ConversationPreferenceMuteState.fromJson(preference!.mute.toJson()),
        };
        final result = await _conversation.updatePreferences(
          notificationPreference: notification,
          isStarred: preference!.isStarred,
          mute: mute,
        );
        if (result
            case ChatCommandSuccess<UpdateConversationPreferenceResult>(
              :final value
            )) {
          conflict = value.reconciliationStatus ==
              ConversationPreferenceReconciliationStatus
                  .preferenceRevisionConflict;
          final confirmed =
              _conversation.conversationPreferenceState.authoritativePreference;
          final notificationAction = action == _SubscriptionAction.all ||
              action == _SubscriptionAction.mentions ||
              action == _SubscriptionAction.none;
          final satisfied = notificationAction
              ? confirmed?.notificationPreference == notification.wireValue
              : confirmed?.mute.muted == mute.muted &&
                  confirmed?.mute.mutedUntil == mute.mutedUntil;
          conflict = conflict || !satisfied;
          succeeded = !conflict;
        } else {
          conflict =
              result is ChatCommandConflict<UpdateConversationPreferenceResult>;
        }
      }
    } catch (_) {
      // Keep transport/host details out of user-facing status.
    }
    if (!mounted) return;
    setState(() {
      _saving = false;
      _retryAction = succeeded ? null : action;
      _message = succeeded
          ? 'Thread subscription saved. History and preferences are retained.'
          : conflict
              ? 'Subscription changed elsewhere. Review current settings, then retry your change.'
              : 'Subscription change failed. Retry your change. Your draft is retained.';
    });
  }

  @override
  Widget build(BuildContext context) {
    final preference =
        _conversation.conversationPreferenceState.authoritativePreference;
    final following = _follow.state.authoritativeFollow?.isFollowing == true;
    final discord =
        widget.client.replyStyles.state.effectiveStyle == ReplyStyle.discord;
    final followLabel = following
        ? (discord ? 'Leave' : 'Unfollow')
        : (discord ? 'Join' : 'Follow');
    final loading = _loading ||
        _conversation.state.status == ChatConversationControllerStatus.loading;
    final mute = preference?.mute;
    final muteLabel = mute?.muted != true
        ? 'Unmuted'
        : mute?.mutedUntil != null
            ? 'Muted until ${mute!.mutedUntil!.value}'
            : 'Muted indefinitely';
    final description = loading
        ? 'Loading thread subscriptions…'
        : _busy
            ? 'Saving thread subscription…'
            : _message ??
                (preference == null || !_ready
                    ? 'Thread preferences unavailable. Retry loading subscriptions.'
                    : '${following ? 'Following' : 'Not following'}. Notifications: ${preference.notificationPreference}. $muteLabel.');
    PopupMenuItem<_SubscriptionAction> item(
            _SubscriptionAction action, String label,
            {bool selected = false, bool needsPreference = true}) =>
        PopupMenuItem(
          value: action,
          enabled: !_busy && _ready && (!needsPreference || preference != null),
          child: Semantics(
              selected: selected,
              child: Row(children: [
                if (selected)
                  const Padding(
                      padding: EdgeInsetsDirectional.only(end: 8),
                      child: Icon(Icons.check, size: 18)),
                Expanded(child: Text(label)),
              ])),
        );
    final status = Semantics(
      container: true,
      liveRegion: true,
      label: description,
      excludeSemantics: true,
      child: Tooltip(
          message: description,
          child: Text(description,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: Theme.of(context).textTheme.bodySmall)),
    );
    final menu = PopupMenuButton<_SubscriptionAction>(
      tooltip: 'Thread subscriptions',
      icon: const Icon(Icons.notifications_outlined),
      onSelected: (action) => unawaited(_perform(action)),
      itemBuilder: (_) => [
        item(
            following
                ? _SubscriptionAction.unfollow
                : _SubscriptionAction.follow,
            followLabel,
            needsPreference: false),
        const PopupMenuDivider(),
        for (final action in [
          _SubscriptionAction.all,
          _SubscriptionAction.mentions,
          _SubscriptionAction.none
        ])
          item(action, 'Notifications: ${action.name}',
              selected: preference?.notificationPreference == action.name),
        const PopupMenuDivider(),
        item(_SubscriptionAction.unmute, 'Unmute',
            selected: mute?.muted == false),
        item(_SubscriptionAction.mute, 'Mute indefinitely',
            selected: mute?.muted == true && mute?.mutedUntil == null),
        item(_SubscriptionAction.hour, 'Mute for 1 hour'),
        if (_retryAction case final retry?)
          item(retry, 'Retry subscription change',
              needsPreference: retry != _SubscriptionAction.follow &&
                  retry != _SubscriptionAction.unfollow),
        if (preference == null || !_ready)
          PopupMenuItem(
              value: _SubscriptionAction.load,
              enabled: !_busy && !loading,
              child: const Text('Retry loading subscriptions')),
      ],
    );
    return widget.builder(menu, status);
  }

  @override
  void dispose() {
    for (final subscription in _subscriptions) {
      unawaited(subscription.cancel());
    }
    super.dispose();
  }
}
