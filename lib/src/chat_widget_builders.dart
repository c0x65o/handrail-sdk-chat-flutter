import 'package:flutter/material.dart';

import '../core.dart';

/// Builds one message from immutable public timeline data and public actions.
typedef ChatMessageWidgetBuilder = Widget Function(
  BuildContext context,
  ChatMessageBuilderInput input,
);

/// Builds an avatar for one immutable public conversation member.
typedef ChatAvatarWidgetBuilder = Widget Function(
  BuildContext context,
  ChatAvatarBuilderInput input,
);

/// Builds a host-application entity reference.
typedef ChatEntityReferenceWidgetBuilder = Widget Function(
  BuildContext context,
  ChatEntityReferenceBuilderInput input,
);

/// Builds a preview for immutable attachment metadata.
typedef ChatAttachmentPreviewWidgetBuilder = Widget Function(
  BuildContext context,
  ChatAttachmentPreviewBuilderInput input,
);

/// Builds the state shown when a ready conversation has no messages.
typedef ChatEmptyConversationWidgetBuilder = Widget Function(
  BuildContext context,
  ChatEmptyConversationBuilderInput input,
);

/// Builds a loading state for a public chat controller.
typedef ChatLoadingWidgetBuilder = Widget Function(
  BuildContext context,
  ChatLoadingBuilderInput input,
);

/// Builds a failure state from a public controller error.
typedef ChatErrorWidgetBuilder = Widget Function(
  BuildContext context,
  ChatErrorBuilderInput input,
);

/// Builds the visual contents of one accessible channel-list row.
typedef ChatChannelWidgetBuilder = Widget Function(
  BuildContext context,
  ChatChannelBuilderInput input,
);

/// Immutable rendering input for [ChatChannelWidgetBuilder].
@immutable
final class ChatChannelBuilderInput {
  const ChatChannelBuilderInput({
    required this.item,
    required this.selected,
  });

  final ChatConversationListItem item;
  final bool selected;
}

/// Immutable rendering input for [ChatMessageWidgetBuilder].
@immutable
final class ChatMessageBuilderInput {
  const ChatMessageBuilderInput({
    required this.message,
    required this.actions,
    this.replyContext,
  });

  final MessageTimelineMessage message;
  final ChatMessageActions actions;

  /// Immediate, ephemeral reply context. Replace this input on each build;
  /// never retain source text in drafts or durable preview metadata.
  final ChatMessageReplyContext? replyContext;
}

/// Authorized current source state and accessible reply-reference actions.
@immutable
final class ChatMessageReplyContext {
  const ChatMessageReplyContext({
    required this.reference,
    required this.state,
    this.jumpToSource,
    this.retry,
  });

  final MessageReplyReference reference;
  final ChatMessageContextState state;
  final Future<void> Function()? jumpToSource;
  final Future<void> Function()? retry;
}

/// Immutable rendering input for [ChatAvatarWidgetBuilder].
@immutable
final class ChatAvatarBuilderInput {
  const ChatAvatarBuilderInput({required this.member});

  final ConversationSnapshotMember member;
}

/// Immutable rendering input for [ChatEntityReferenceWidgetBuilder].
@immutable
final class ChatEntityReferenceBuilderInput {
  const ChatEntityReferenceBuilderInput({required this.reference});

  final HostEntityReference reference;
}

/// Immutable rendering input for [ChatAttachmentPreviewWidgetBuilder].
@immutable
final class ChatAttachmentPreviewBuilderInput {
  const ChatAttachmentPreviewBuilderInput({required this.attachment});

  final MessageAttachmentMetadata attachment;
}

/// Immutable rendering input for [ChatEmptyConversationWidgetBuilder].
@immutable
final class ChatEmptyConversationBuilderInput {
  const ChatEmptyConversationBuilderInput({
    required this.conversation,
    required this.actions,
  });

  final Conversation conversation;
  final ChatTimelineActions actions;
}

/// Identifies which public controller is waiting for data.
enum ChatLoadingTarget { conversation, conversationList, timeline }

/// Immutable rendering input for [ChatLoadingWidgetBuilder].
@immutable
final class ChatLoadingBuilderInput {
  const ChatLoadingBuilderInput({
    required this.target,
    this.conversationId,
  });

  final ChatLoadingTarget target;
  final ConversationId? conversationId;
}

/// Immutable rendering input for [ChatErrorWidgetBuilder].
///
/// Exactly one controller error is present. The matching public actions are
/// supplied when the caller can retry that controller.
@immutable
final class ChatErrorBuilderInput {
  const ChatErrorBuilderInput.conversation({
    required ChatConversationControllerError error,
    this.conversationActions,
  })  : conversationError = error,
        conversationListError = null,
        timelineError = null,
        conversationListActions = null,
        timelineActions = null;

  const ChatErrorBuilderInput.conversationList({
    required ChatConversationListError error,
    this.conversationListActions,
  })  : conversationListError = error,
        conversationError = null,
        timelineError = null,
        conversationActions = null,
        timelineActions = null;

  const ChatErrorBuilderInput.timeline({
    required ChatTimelineControllerError error,
    this.timelineActions,
  })  : timelineError = error,
        conversationError = null,
        conversationListError = null,
        conversationListActions = null,
        conversationActions = null;

  final ChatConversationControllerError? conversationError;
  final ChatConversationListError? conversationListError;
  final ChatTimelineControllerError? timelineError;
  final ChatConversationActions? conversationActions;
  final ChatConversationListActions? conversationListActions;
  final ChatTimelineActions? timelineActions;

  String get message =>
      conversationError?.message ??
      conversationListError?.message ??
      timelineError!.message;
}

/// Immutable actions for one message, backed only by the public timeline API.
@immutable
final class ChatMessageActions {
  const ChatMessageActions({
    required ChatTimelineController controller,
    required this.messageId,
    required this.sequence,
    required this.expectedRevision,
  }) : _controller = controller;

  factory ChatMessageActions.forMessage({
    required ChatTimelineController controller,
    required MessageTimelineMessage message,
  }) {
    return ChatMessageActions(
      controller: controller,
      messageId: message.id,
      sequence: message.sequence,
      expectedRevision: message.revision.revision,
    );
  }

  final ChatTimelineController _controller;
  final MessageId messageId;
  final MessageSequence sequence;
  final int expectedRevision;

  /// Latest actor-private reminder projection for this selected message.
  NormalizedMessageReminderState get reminderState =>
      _controller.messageReminder(messageId);

  /// Actor-private reminder updates scoped to this selected message.
  Stream<NormalizedMessageReminderState> get reminderStates =>
      _controller.messageReminderStates(messageId);

  Future<ChatCommandResult<EditMessageResult>> edit(
    MessageContent content, {
    int? expectedRevision,
    String? idempotencyKey,
    ChatCommandCancellationSignal? cancellationSignal,
  }) {
    return _controller.editMessage(
      messageId: messageId,
      expectedRevision: expectedRevision ?? this.expectedRevision,
      content: content,
      idempotencyKey: idempotencyKey,
      cancellationSignal: cancellationSignal,
    );
  }

  Future<ChatCommandResult<SoftDeleteMessageResult>> delete({
    int? expectedRevision,
    String? idempotencyKey,
    ChatCommandCancellationSignal? cancellationSignal,
  }) {
    return _controller.deleteMessage(
      messageId: messageId,
      expectedRevision: expectedRevision ?? this.expectedRevision,
      idempotencyKey: idempotencyKey,
      cancellationSignal: cancellationSignal,
    );
  }

  Future<ChatCommandResult<ReactionMutationResult>> setReaction({
    required String reactionKey,
    required bool reactedByCurrentUser,
    String? idempotencyKey,
    ChatCommandCancellationSignal? cancellationSignal,
  }) {
    return _controller.setReaction(
      messageId: messageId,
      reactionKey: reactionKey,
      reactedByCurrentUser: reactedByCurrentUser,
      idempotencyKey: idempotencyKey,
      cancellationSignal: cancellationSignal,
    );
  }

  Future<ChatThreadOpenResult> openThread() =>
      _controller.openThread(messageId);

  Future<ChatCommandResult<ForwardMessageResult>> forward(
    ConversationId destinationConversationId, {
    ChatCommandCancellationSignal? cancellationSignal,
  }) =>
      _controller.forwardMessage(
        sourceMessageId: messageId,
        destinationConversationId: destinationConversationId,
        cancellationSignal: cancellationSignal,
      );

  Future<ChatCommandResult<MessageReminderResult>> scheduleReminder(
    IsoTimestamp dueAt, {
    ChatCommandCancellationSignal? cancellationSignal,
  }) =>
      _controller.setMessageReminder(
        messageId: messageId,
        dueAt: dueAt,
        cancellationSignal: cancellationSignal,
      );

  Future<ChatCommandResult<MessageReminderResult>> rescheduleReminder(
    IsoTimestamp dueAt, {
    ChatCommandCancellationSignal? cancellationSignal,
  }) =>
      _controller.rescheduleMessageReminder(
        messageId: messageId,
        dueAt: dueAt,
        cancellationSignal: cancellationSignal,
      );

  Future<ChatCommandResult<MessageReminderResult>> cancelReminder({
    ChatCommandCancellationSignal? cancellationSignal,
  }) =>
      _controller.cancelMessageReminder(
        messageId: messageId,
        cancellationSignal: cancellationSignal,
      );

  void reportVisible() => _controller.reportVisibleThrough(sequence);
}

/// Immutable timeline actions that preserve public controller result types.
@immutable
final class ChatTimelineActions {
  const ChatTimelineActions(ChatTimelineController controller)
      : _controller = controller;

  final ChatTimelineController _controller;

  Future<ChatTimelineControllerState> refresh({
    ChatCommandCancellationSignal? cancellationSignal,
  }) =>
      _controller.refresh(cancellationSignal: cancellationSignal);

  Future<ChatTimelineControllerState> loadEarlier({
    ChatCommandCancellationSignal? cancellationSignal,
  }) =>
      _controller.loadEarlier(cancellationSignal: cancellationSignal);

  Future<ChatTimelineControllerState> loadNewer({
    ChatCommandCancellationSignal? cancellationSignal,
  }) =>
      _controller.loadNewer(cancellationSignal: cancellationSignal);

  Future<ChatCommandResult<SendMessageResult>> send(
    MessageContent content, {
    ChatCommandCancellationSignal? cancellationSignal,
  }) =>
      _controller.sendMessage(
        content,
        cancellationSignal: cancellationSignal,
      );

  Future<ChatCommandResult<ReadCursorMutationResult>> markUnread(
    MessageSequence fromSequence,
  ) =>
      _controller.markUnread(fromSequence);

  void reportVisibleThrough(MessageSequence sequence) =>
      _controller.reportVisibleThrough(sequence);
}

/// Immutable conversation actions that preserve public controller types.
@immutable
final class ChatConversationActions {
  const ChatConversationActions(ChatConversationController controller)
      : _controller = controller;

  final ChatConversationController _controller;

  Future<ChatConversationControllerState> refresh() => _controller.refresh();

  Future<ChatCommandResult<ReadCursorMutationResult>> markRead(
    MessageSequence throughSequence,
  ) =>
      _controller.markRead(throughSequence);

  Future<ChatCommandResult<ReadCursorMutationResult>> markUnread(
    MessageSequence fromSequence,
  ) =>
      _controller.markUnread(fromSequence);

  Future<ChatThreadOpenResult> openThread(MessageId rootMessageId) =>
      _controller.openThread(rootMessageId);
}

/// Immutable paging actions backed only by the public list controller.
@immutable
final class ChatConversationListActions {
  const ChatConversationListActions(ChatConversationListController controller)
      : _controller = controller;

  final ChatConversationListController _controller;

  Future<ChatConversationListState> refresh() => _controller.refresh();
  Future<ChatConversationListState> loadMore() => _controller.loadMore();
  Future<ChatConversationListState> retry() => _controller.retry();
}

/// Nested builders for controller lifecycle states.
@immutable
final class ChatStateWidgetBuilders {
  const ChatStateWidgetBuilders({
    this.emptyConversation = defaultChatEmptyConversationBuilder,
    this.loading = defaultChatLoadingBuilder,
    this.error = defaultChatErrorBuilder,
  });

  final ChatEmptyConversationWidgetBuilder emptyConversation;
  final ChatLoadingWidgetBuilder loading;
  final ChatErrorWidgetBuilder error;

  ChatStateWidgetBuilders withOverrides(
    ChatStateWidgetBuilderOverrides overrides,
  ) {
    return ChatStateWidgetBuilders(
      emptyConversation: overrides.emptyConversation ?? emptyConversation,
      loading: overrides.loading ?? loading,
      error: overrides.error ?? error,
    );
  }
}

/// Nullable nested overrides used to retain omitted lifecycle defaults.
@immutable
final class ChatStateWidgetBuilderOverrides {
  const ChatStateWidgetBuilderOverrides({
    this.emptyConversation,
    this.loading,
    this.error,
  });

  final ChatEmptyConversationWidgetBuilder? emptyConversation;
  final ChatLoadingWidgetBuilder? loading;
  final ChatErrorWidgetBuilder? error;
}

/// Nullable customization values resolved by [ChatWidgetBuilders.withOverrides].
@immutable
final class ChatWidgetBuilderOverrides {
  const ChatWidgetBuilderOverrides({
    this.channel,
    this.message,
    this.avatar,
    this.entityReference,
    this.attachmentPreview,
    this.emptyConversation,
    this.loading,
    this.error,
    this.states = const ChatStateWidgetBuilderOverrides(),
  });

  final ChatChannelWidgetBuilder? channel;
  final ChatMessageWidgetBuilder? message;
  final ChatAvatarWidgetBuilder? avatar;
  final ChatEntityReferenceWidgetBuilder? entityReference;
  final ChatAttachmentPreviewWidgetBuilder? attachmentPreview;
  final ChatEmptyConversationWidgetBuilder? emptyConversation;
  final ChatLoadingWidgetBuilder? loading;
  final ChatErrorWidgetBuilder? error;
  final ChatStateWidgetBuilderOverrides states;
}

/// Immutable customization contract for optional Handrail Chat widgets.
///
/// Every builder is an ordinary public callback. [withOverrides] performs a
/// deterministic field-by-field merge, including the nested [states] group,
/// so a host can replace one renderer without losing the remaining defaults.
@immutable
final class ChatWidgetBuilders {
  const ChatWidgetBuilders({
    this.channel = defaultChatChannelBuilder,
    this.message = defaultChatMessageBuilder,
    this.avatar = defaultChatAvatarBuilder,
    this.entityReference = defaultChatEntityReferenceBuilder,
    this.attachmentPreview = defaultChatAttachmentPreviewBuilder,
    this.emptyConversation = defaultChatEmptyConversationBuilder,
    this.loading = defaultChatLoadingBuilder,
    this.error = defaultChatErrorBuilder,
  });

  /// Creates the same contract from a nested lifecycle-builder group.
  factory ChatWidgetBuilders.fromStates({
    ChatChannelWidgetBuilder channel = defaultChatChannelBuilder,
    ChatMessageWidgetBuilder message = defaultChatMessageBuilder,
    ChatAvatarWidgetBuilder avatar = defaultChatAvatarBuilder,
    ChatEntityReferenceWidgetBuilder entityReference =
        defaultChatEntityReferenceBuilder,
    ChatAttachmentPreviewWidgetBuilder attachmentPreview =
        defaultChatAttachmentPreviewBuilder,
    ChatStateWidgetBuilders states = const ChatStateWidgetBuilders(),
  }) {
    return ChatWidgetBuilders(
      channel: channel,
      message: message,
      avatar: avatar,
      entityReference: entityReference,
      attachmentPreview: attachmentPreview,
      emptyConversation: states.emptyConversation,
      loading: states.loading,
      error: states.error,
    );
  }

  final ChatChannelWidgetBuilder channel;
  final ChatMessageWidgetBuilder message;
  final ChatAvatarWidgetBuilder avatar;
  final ChatEntityReferenceWidgetBuilder entityReference;
  final ChatAttachmentPreviewWidgetBuilder attachmentPreview;
  final ChatEmptyConversationWidgetBuilder emptyConversation;
  final ChatLoadingWidgetBuilder loading;
  final ChatErrorWidgetBuilder error;

  ChatStateWidgetBuilders get states => ChatStateWidgetBuilders(
        emptyConversation: emptyConversation,
        loading: loading,
        error: error,
      );

  ChatWidgetBuilders withOverrides(ChatWidgetBuilderOverrides overrides) {
    final stateOverrides = ChatStateWidgetBuilderOverrides(
      emptyConversation:
          overrides.emptyConversation ?? overrides.states.emptyConversation,
      loading: overrides.loading ?? overrides.states.loading,
      error: overrides.error ?? overrides.states.error,
    );
    final resolvedStates = states.withOverrides(stateOverrides);
    return ChatWidgetBuilders(
      channel: overrides.channel ?? channel,
      message: overrides.message ?? message,
      avatar: overrides.avatar ?? avatar,
      entityReference: overrides.entityReference ?? entityReference,
      attachmentPreview: overrides.attachmentPreview ?? attachmentPreview,
      emptyConversation: resolvedStates.emptyConversation,
      loading: resolvedStates.loading,
      error: resolvedStates.error,
    );
  }

  /// Alias for [withOverrides] emphasizing default/override composition.
  ChatWidgetBuilders merge(ChatWidgetBuilderOverrides overrides) =>
      withOverrides(overrides);
}

/// Default visual contents for one channel row.
Widget defaultChatChannelBuilder(
  BuildContext context,
  ChatChannelBuilderInput input,
) {
  final theme = Theme.of(context);
  final titleStyle = DefaultTextStyle.of(context).style;
  final item = input.item;
  return LayoutBuilder(
    builder: (context, constraints) {
      final compact = constraints.maxWidth < 180;
      return Padding(
        padding: EdgeInsets.symmetric(
          horizontal: compact ? 8 : 12,
          vertical: 10,
        ),
        child: Row(
          children: [
            Expanded(
              child: Text(
                item.displayName,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: item.isArchived
                    ? titleStyle.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      )
                    : titleStyle,
              ),
            ),
            if (item.isArchived && !compact) ...[
              const SizedBox(width: 8),
              Text('Archived', style: theme.textTheme.labelSmall),
            ],
            if (item.unreadCount > 0) ...[
              SizedBox(width: compact ? 4 : 8),
              Badge(label: Text('${item.unreadCount}')),
            ],
          ],
        ),
      );
    },
  );
}

/// Default public message renderer used by [ChatWidgetBuilders].
Widget defaultChatMessageBuilder(
  BuildContext context,
  ChatMessageBuilderInput input,
) {
  if (input.message.message is DeletedMessage) {
    return const Text('Message deleted');
  }
  return Text(input.message.content?.text ?? 'Message unavailable');
}

/// Default public avatar renderer used by [ChatWidgetBuilders].
Widget defaultChatAvatarBuilder(
  BuildContext context,
  ChatAvatarBuilderInput input,
) {
  final value = input.member.userId.value;
  return CircleAvatar(
    child: Text(value.isEmpty ? '?' : value.characters.first.toUpperCase()),
  );
}

/// Default public entity-reference renderer used by [ChatWidgetBuilders].
Widget defaultChatEntityReferenceBuilder(
  BuildContext context,
  ChatEntityReferenceBuilderInput input,
) {
  return Text('${input.reference.type}: ${input.reference.id}');
}

/// Default public attachment renderer used by [ChatWidgetBuilders].
Widget defaultChatAttachmentPreviewBuilder(
  BuildContext context,
  ChatAttachmentPreviewBuilderInput input,
) {
  return Row(
    children: [
      const Icon(Icons.attachment),
      const SizedBox(width: 8),
      Expanded(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(input.attachment.fileName),
            Text(input.attachment.contentType),
          ],
        ),
      ),
    ],
  );
}

/// Default public empty-conversation renderer used by [ChatWidgetBuilders].
Widget defaultChatEmptyConversationBuilder(
  BuildContext context,
  ChatEmptyConversationBuilderInput input,
) {
  return const Center(child: Text('No messages yet'));
}

/// Default public loading renderer used by [ChatWidgetBuilders].
Widget defaultChatLoadingBuilder(
  BuildContext context,
  ChatLoadingBuilderInput input,
) {
  return const Center(child: CircularProgressIndicator());
}

/// Default public controller-error renderer used by [ChatWidgetBuilders].
Widget defaultChatErrorBuilder(
  BuildContext context,
  ChatErrorBuilderInput input,
) {
  final retry = input.conversationActions != null
      ? input.conversationActions!.refresh
      : input.conversationListActions != null
          ? input.conversationListActions!.retry
          : input.timelineActions?.refresh;
  return Column(
    mainAxisSize: MainAxisSize.min,
    children: [
      Text(input.message),
      if (retry != null)
        TextButton(
          onPressed: () {
            retry();
          },
          child: const Text('Retry'),
        ),
    ],
  );
}
