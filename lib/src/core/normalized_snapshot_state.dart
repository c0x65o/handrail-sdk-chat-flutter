import 'dart:async';
import 'dart:convert';

import '../generated/attachment_transport.dart';
import '../generated/conversation.dart';
import '../generated/conversation_archive.dart';
import '../generated/conversation_creation.dart';
import '../generated/conversation_membership.dart';
import '../generated/conversation_preference.dart';
import '../generated/conversation_snapshot.dart';
import '../generated/delete_message.dart';
import '../generated/draft_mutation.dart';
import '../generated/durable_events.dart';
import '../generated/edit_message.dart';
import '../generated/huddle_session.dart';
import '../generated/identifiers.dart';
import '../generated/message.dart';
import '../generated/message_reminder.dart';
import '../generated/message_timeline.dart';
import '../generated/read_cursor_mutation.dart';
import '../generated/reaction_mutations.dart';
import '../generated/realtime_session.dart' show EventCursor;
import '../generated/thread_creation.dart';
import '../generated/thread_follow_mutation.dart';

part 'conversation_archive_state.dart';
part 'conversation_preference_state.dart';
part 'durable_conversation_event_reducer.dart';
part 'durable_message_event_reducer.dart';
part 'durable_resource_event_reducer.dart';
part 'message_reminder_state.dart';
part 'normalized_snapshot_serialization.dart';
part 'thread_follow_state.dart';
part 'thread_lifecycle_state.dart';

/// A normalized snapshot payload contradicted canonical state already accepted
/// by the store.
final class NormalizedSnapshotConflict implements Exception {
  const NormalizedSnapshotConflict(this.message);

  final String message;

  @override
  String toString() => 'NormalizedSnapshotConflict: $message';
}

/// Snapshot-only metadata associated with a canonical conversation.
final class NormalizedConversationMetadata {
  const NormalizedConversationMetadata({
    required this.latestSequence,
    required this.activityAt,
    this.unreadMentionCount = 0,
  });

  final MessageSequence latestSequence;
  final IsoTimestamp activityAt;

  /// Last server snapshot count; refreshed after message changes/reconnect.
  /// This projection is not part of the offline persistence schema.
  final int unreadMentionCount;
}

/// Bounded replay-order metadata for one durable event stream.
final class DurableStreamMetadata {
  DurableStreamMetadata({
    required this.lastEventId,
    required this.lastOccurredAt,
    required List<String> recentEventIds,
  }) : recentEventIds = List.unmodifiable(recentEventIds) {
    if (lastEventId.trim().isEmpty ||
        recentEventIds.isEmpty ||
        recentEventIds.length > durableEventRecentIdLimit ||
        recentEventIds.any((id) => id.trim().isEmpty) ||
        recentEventIds.toSet().length != recentEventIds.length ||
        recentEventIds.last != lastEventId) {
      throw const FormatException('Durable stream metadata is invalid.');
    }
  }

  final String lastEventId;
  final IsoTimestamp lastOccurredAt;
  final List<String> recentEventIds;
}

/// Canonical saved-message state visible only to the authenticated actor.
final class CanonicalActorPrivateSavedMessageState {
  const CanonicalActorPrivateSavedMessageState({
    required this.messageId,
    required this.isSaved,
    this.privateNote,
  });

  factory CanonicalActorPrivateSavedMessageState.fromJson(Object? json) {
    if (json is! Map<Object?, Object?> ||
        json.keys.any((key) => key is! String)) {
      throw const FormatException('Saved-message state must be an object.');
    }
    final object = json.cast<String, Object?>();
    final allowed = object.containsKey('privateNote')
        ? const {'messageId', 'isSaved', 'privateNote'}
        : const {'messageId', 'isSaved'};
    if (object.keys.toSet().difference(allowed).isNotEmpty ||
        object.length != allowed.length ||
        object['isSaved'] is! bool ||
        (object.containsKey('privateNote') &&
            object['privateNote'] is! String) ||
        (object['isSaved'] == false && object.containsKey('privateNote'))) {
      throw const FormatException('Saved-message state is malformed.');
    }
    return CanonicalActorPrivateSavedMessageState(
      messageId: MessageId.fromJson(object['messageId']),
      isSaved: object['isSaved']! as bool,
      privateNote: object['privateNote'] as String?,
    );
  }

  final MessageId messageId;
  final bool isSaved;
  final String? privateNote;

  Map<String, Object?> toJson() => {
        'messageId': messageId.toJson(),
        'isSaved': isSaved,
        if (privateNote != null) 'privateNote': privateNote,
      };
}

/// One retained page in a normalized conversation-list snapshot.
final class NormalizedConversationListPage {
  NormalizedConversationListPage({
    required List<ConversationId> conversationIds,
    required this.metadata,
    this.requestCursor,
    this.nextCursor,
  }) : conversationIds = List.unmodifiable(conversationIds);

  final ConversationSnapshotCursor? requestCursor;
  final List<ConversationId> conversationIds;
  final ConversationSnapshotCursor? nextCursor;
  final ConversationSnapshotMetadata metadata;
}

/// Canonical list membership and its cursor-linked pages for one scope.
final class NormalizedConversationListEntry {
  NormalizedConversationListEntry({
    required this.scope,
    required List<ConversationId> conversationIds,
    required this.metadata,
    required Map<String, NormalizedConversationListPage> pages,
    this.nextCursor,
  })  : conversationIds = List.unmodifiable(conversationIds),
        pages = Map.unmodifiable(pages);

  final ConversationSnapshotScope scope;
  final List<ConversationId> conversationIds;
  final ConversationSnapshotCursor? nextCursor;
  final ConversationSnapshotMetadata metadata;
  final Map<String, NormalizedConversationListPage> pages;
}

/// Ordered message references and pagination retained for one conversation.
final class NormalizedTimelineEntry {
  NormalizedTimelineEntry({
    required List<MessageId> messageIds,
    required this.pagination,
    required this.replayCursor,
  }) : messageIds = List.unmodifiable(messageIds);

  final List<MessageId> messageIds;
  final MessageTimelinePagination pagination;
  final EventCursor? replayCursor;
}

/// Client-observable phase of one attachment upload.
enum ChatAttachmentUploadStatus {
  preparing,
  pending,
  uploading,
  finalizing,
  finalized,
  attached,
  rejected,
  abandoned,
  failed,
  cancelled,
}

/// Canonical, descriptor-free state for one attachment upload.
///
/// Byte sources, bearer credentials, and opaque transfer descriptors are
/// deliberately excluded so normalized state remains safe to inspect and
/// persist.
final class ChatAttachmentUploadState {
  ChatAttachmentUploadState({
    required this.uploadId,
    required this.conversationId,
    required this.metadata,
    required this.status,
    required this.uploadedBytes,
    AttachmentLifecycleState? attachment,
    MessageAttachmentMetadata? messageAttachment,
  })  : attachment = attachment == null
            ? null
            : AttachmentLifecycleState.fromJson(attachment.toJson()),
        messageAttachment = messageAttachment == null
            ? null
            : MessageAttachmentMetadata.fromJson(messageAttachment.toJson()) {
    if (uploadId.trim().isEmpty ||
        uploadedBytes < 0 ||
        uploadedBytes > metadata.sizeBytes) {
      throw const FormatException('Invalid attachment upload state.');
    }
    final canonical = this.attachment;
    final settledMessageAttachment = this.messageAttachment;
    if (canonical != null &&
        (!_sameValue(canonical.metadata.toJson(), metadata.toJson()) ||
            (status != ChatAttachmentUploadStatus.attached &&
                !_attachmentMatchesUploadStatus(status, canonical.status)))) {
      throw const FormatException(
        'Attachment upload state contradicts canonical lifecycle state.',
      );
    }
    if (status == ChatAttachmentUploadStatus.attached) {
      if (canonical == null ||
          settledMessageAttachment == null ||
          canonical.attachmentId != settledMessageAttachment.attachmentId ||
          !_messageAttachmentMatchesUploadMetadata(
            settledMessageAttachment,
            metadata,
          )) {
        throw const FormatException(
          'Attached upload state requires matching canonical message metadata.',
        );
      }
    } else if (settledMessageAttachment != null) {
      throw const FormatException(
        'Only attached upload state can retain message metadata.',
      );
    }
    if ((status == ChatAttachmentUploadStatus.pending ||
            status == ChatAttachmentUploadStatus.uploading ||
            status == ChatAttachmentUploadStatus.finalizing ||
            status == ChatAttachmentUploadStatus.finalized ||
            status == ChatAttachmentUploadStatus.rejected ||
            status == ChatAttachmentUploadStatus.abandoned) &&
        canonical == null) {
      throw const FormatException(
        'This attachment upload phase requires canonical lifecycle state.',
      );
    }
  }

  factory ChatAttachmentUploadState.fromJson(Object? json) {
    if (json is! Map<Object?, Object?> ||
        json.keys.any((key) => key is! String)) {
      throw const FormatException('Attachment upload state must be an object.');
    }
    final object = json.cast<String, Object?>();
    const fields = {
      'uploadId',
      'conversationId',
      'metadata',
      'status',
      'uploadedBytes',
      'attachment',
      'messageAttachment',
    };
    if ((object.length != fields.length &&
            object.length != fields.length - 1) ||
        object.keys.any((key) => !fields.contains(key))) {
      throw const FormatException(
          'Attachment upload state has invalid fields.');
    }
    final uploadId = object['uploadId'];
    final uploadedBytes = object['uploadedBytes'];
    if (uploadId is! String || uploadedBytes is! int) {
      throw const FormatException('Attachment upload state is malformed.');
    }
    final statusValue = object['status'];
    final status = ChatAttachmentUploadStatus.values.where(
      (candidate) => candidate.name == statusValue,
    );
    if (status.length != 1) {
      throw const FormatException('Attachment upload status is invalid.');
    }
    return ChatAttachmentUploadState(
      uploadId: uploadId,
      conversationId: ConversationId.fromJson(object['conversationId']),
      metadata: AttachmentMetadata.fromJson(object['metadata']),
      status: status.single,
      uploadedBytes: uploadedBytes,
      attachment: object['attachment'] == null
          ? null
          : AttachmentLifecycleState.fromJson(object['attachment']),
      messageAttachment: object['messageAttachment'] == null
          ? null
          : MessageAttachmentMetadata.fromJson(object['messageAttachment']),
    );
  }

  final String uploadId;
  final ConversationId conversationId;
  final AttachmentMetadata metadata;
  final ChatAttachmentUploadStatus status;
  final int uploadedBytes;
  final AttachmentLifecycleState? attachment;
  final MessageAttachmentMetadata? messageAttachment;

  Map<String, Object?> toJson() => {
        'uploadId': uploadId,
        'conversationId': conversationId.toJson(),
        'metadata': metadata.toJson(),
        'status': status.name,
        'uploadedBytes': uploadedBytes,
        'attachment': attachment?.toJson(),
        'messageAttachment': messageAttachment?.toJson(),
      };
}

/// The complete immutable canonical state owned by a
/// [NormalizedSnapshotStore].
final class NormalizedSnapshotState {
  NormalizedSnapshotState._({
    required Map<ConversationId, Conversation> conversations,
    required Map<MessageId, Message> canonicalMessages,
    required Map<MessageId, MessageTimelineMessage> messages,
    required Map<ConversationId, Map<UserId, ConversationSnapshotMember>>
        membersByConversation,
    required Map<ConversationId, List<UserId>> memberUserIdsByConversation,
    required Map<ConversationId, int> lifecycleRevisions,
    required Map<ConversationId, bool> lifecycleArchivedStates,
    required Map<ConversationId, List<ConversationArchiveInput>>
        pendingConversationArchiveInputs,
    required Map<ConversationId, int> memberListRevisions,
    required Map<ConversationId, ConversationSnapshotReadState>
        currentUserReadStates,
    required Map<ConversationId, ConversationSnapshotReadState>
        authoritativeCurrentUserReadStates,
    required Map<ConversationId, ConversationSnapshotPreference>
        currentUserPreferences,
    required Map<ConversationId, ConversationSnapshotPreference>
        authoritativeCurrentUserPreferences,
    required Map<ConversationId, int> preferenceRevisions,
    required Map<ConversationId, List<PendingConversationPreferenceIntent>>
        pendingConversationPreferenceIntents,
    required Map<ConversationId, CanonicalThreadFollowState>
        currentUserThreadFollows,
    required Map<ConversationId, CanonicalThreadFollowState>
        authoritativeCurrentUserThreadFollows,
    required Map<ConversationId, int> threadFollowRevisions,
    required Map<ConversationId, List<PendingThreadFollowIntent>>
        pendingThreadFollowIntents,
    required Map<MessageId, CanonicalActorPrivateSavedMessageState>
        currentUserSavedMessages,
    required Map<MessageId, int> savedMessageRevisions,
    required Map<MessageId, CanonicalMessageReminder>
        currentUserMessageReminders,
    required Map<MessageId, CanonicalMessageReminder>
        authoritativeCurrentUserMessageReminders,
    required Map<MessageId, ConversationId> messageReminderConversationIds,
    required Map<MessageId, int> messageReminderRevisions,
    required Map<MessageId, List<PendingMessageReminderIntent>>
        pendingMessageReminderIntents,
    required Map<ConversationId, CanonicalDraftState> currentUserDrafts,
    required Map<ConversationId, int> draftRevisions,
    required Map<ConversationId, NormalizedConversationMetadata>
        conversationMetadata,
    required Map<String, DurableStreamMetadata> durableStreams,
    required Map<String, NormalizedConversationListEntry> conversationLists,
    required Map<ConversationId, ConversationSnapshotMetadata>
        conversationDetails,
    required Map<ConversationId, NormalizedTimelineEntry> timelines,
    required Map<AttachmentId, MessageAttachmentMetadata> attachments,
    required Map<String, ChatAttachmentUploadState> attachmentUploads,
    required Map<ConversationId, HuddleSessionState> huddles,
    required this.latestReplayCursor,
  })  : conversations = Map.unmodifiable(conversations),
        canonicalMessages = Map.unmodifiable(canonicalMessages),
        messages = Map.unmodifiable(messages),
        membersByConversation = Map<ConversationId,
            Map<UserId, ConversationSnapshotMember>>.unmodifiable(
          membersByConversation.map(
            (id, members) => MapEntry(
              id,
              Map<UserId, ConversationSnapshotMember>.unmodifiable(members),
            ),
          ),
        ),
        memberUserIdsByConversation =
            Map<ConversationId, List<UserId>>.unmodifiable(
          memberUserIdsByConversation.map(
            (id, members) => MapEntry(id, List<UserId>.unmodifiable(members)),
          ),
        ),
        lifecycleRevisions = Map.unmodifiable(lifecycleRevisions),
        lifecycleArchivedStates = Map.unmodifiable(lifecycleArchivedStates),
        pendingConversationArchiveInputs =
            Map<ConversationId, List<ConversationArchiveInput>>.unmodifiable(
          pendingConversationArchiveInputs.map(
            (id, inputs) => MapEntry(
              id,
              List<ConversationArchiveInput>.unmodifiable(inputs),
            ),
          ),
        ),
        memberListRevisions = Map.unmodifiable(memberListRevisions),
        currentUserReadStates = Map.unmodifiable(currentUserReadStates),
        authoritativeCurrentUserReadStates =
            Map.unmodifiable(authoritativeCurrentUserReadStates),
        currentUserPreferences = Map.unmodifiable(currentUserPreferences),
        authoritativeCurrentUserPreferences =
            Map.unmodifiable(authoritativeCurrentUserPreferences),
        preferenceRevisions = Map.unmodifiable(preferenceRevisions),
        pendingConversationPreferenceIntents = Map<ConversationId,
            List<PendingConversationPreferenceIntent>>.unmodifiable(
          pendingConversationPreferenceIntents.map(
            (id, intents) => MapEntry(
              id,
              List<PendingConversationPreferenceIntent>.unmodifiable(intents),
            ),
          ),
        ),
        currentUserThreadFollows = Map.unmodifiable(currentUserThreadFollows),
        authoritativeCurrentUserThreadFollows =
            Map.unmodifiable(authoritativeCurrentUserThreadFollows),
        threadFollowRevisions = Map.unmodifiable(threadFollowRevisions),
        pendingThreadFollowIntents =
            Map<ConversationId, List<PendingThreadFollowIntent>>.unmodifiable(
          pendingThreadFollowIntents.map(
            (id, intents) => MapEntry(
              id,
              List<PendingThreadFollowIntent>.unmodifiable(intents),
            ),
          ),
        ),
        currentUserSavedMessages = Map.unmodifiable(currentUserSavedMessages),
        savedMessageRevisions = Map.unmodifiable(savedMessageRevisions),
        currentUserMessageReminders =
            Map.unmodifiable(currentUserMessageReminders),
        authoritativeCurrentUserMessageReminders =
            Map.unmodifiable(authoritativeCurrentUserMessageReminders),
        messageReminderConversationIds =
            Map.unmodifiable(messageReminderConversationIds),
        messageReminderRevisions = Map.unmodifiable(messageReminderRevisions),
        pendingMessageReminderIntents =
            Map<MessageId, List<PendingMessageReminderIntent>>.unmodifiable(
          pendingMessageReminderIntents.map(
            (id, intents) => MapEntry(
              id,
              List<PendingMessageReminderIntent>.unmodifiable(intents),
            ),
          ),
        ),
        currentUserDrafts = Map.unmodifiable(currentUserDrafts),
        draftRevisions = Map.unmodifiable(draftRevisions),
        conversationMetadata = Map.unmodifiable(conversationMetadata),
        durableStreams = Map.unmodifiable(durableStreams),
        conversationLists = Map.unmodifiable(conversationLists),
        conversationDetails = Map.unmodifiable(conversationDetails),
        timelines = Map.unmodifiable(timelines),
        attachments = Map.unmodifiable(attachments),
        attachmentUploads = Map.unmodifiable(attachmentUploads),
        huddles = Map.unmodifiable(huddles);

  factory NormalizedSnapshotState.empty() => NormalizedSnapshotState._(
        conversations: const {},
        canonicalMessages: const {},
        messages: const {},
        membersByConversation: const {},
        memberUserIdsByConversation: const {},
        lifecycleRevisions: const {},
        lifecycleArchivedStates: const {},
        pendingConversationArchiveInputs: const {},
        memberListRevisions: const {},
        currentUserReadStates: const {},
        authoritativeCurrentUserReadStates: const {},
        currentUserPreferences: const {},
        authoritativeCurrentUserPreferences: const {},
        preferenceRevisions: const {},
        pendingConversationPreferenceIntents: const {},
        currentUserThreadFollows: const {},
        authoritativeCurrentUserThreadFollows: const {},
        threadFollowRevisions: const {},
        pendingThreadFollowIntents: const {},
        currentUserSavedMessages: const {},
        savedMessageRevisions: const {},
        currentUserMessageReminders: const {},
        authoritativeCurrentUserMessageReminders: const {},
        messageReminderConversationIds: const {},
        messageReminderRevisions: const {},
        pendingMessageReminderIntents: const {},
        currentUserDrafts: const {},
        draftRevisions: const {},
        conversationMetadata: const {},
        durableStreams: const {},
        conversationLists: const {},
        conversationDetails: const {},
        timelines: const {},
        attachments: const {},
        attachmentUploads: const {},
        huddles: const {},
        latestReplayCursor: null,
      );

  final Map<ConversationId, Conversation> conversations;

  /// Authoritative message rows shared by snapshots and command results.
  final Map<MessageId, Message> canonicalMessages;

  /// Timeline-query projections. Command results do not supply these fields.
  final Map<MessageId, MessageTimelineMessage> messages;
  final Map<ConversationId, Map<UserId, ConversationSnapshotMember>>
      membersByConversation;
  final Map<ConversationId, List<UserId>> memberUserIdsByConversation;
  final Map<ConversationId, int> lifecycleRevisions;

  /// Canonical visibility from full snapshots and transition-only durable
  /// lifecycle events. Transition events omit archive actor/timestamp fields,
  /// so this projection must remain distinct from the conversation row.
  final Map<ConversationId, bool> lifecycleArchivedStates;

  /// In-memory optimistic intents. Canonical storage deliberately omits these.
  final Map<ConversationId, List<ConversationArchiveInput>>
      pendingConversationArchiveInputs;
  final Map<ConversationId, int> memberListRevisions;
  final Map<ConversationId, ConversationSnapshotReadState>
      currentUserReadStates;

  /// Latest accepted server read rows, excluding runtime projections.
  final Map<ConversationId, ConversationSnapshotReadState>
      authoritativeCurrentUserReadStates;
  final Map<ConversationId, ConversationSnapshotPreference>
      currentUserPreferences;

  /// Latest accepted server preference rows, excluding optimistic intents.
  final Map<ConversationId, ConversationSnapshotPreference>
      authoritativeCurrentUserPreferences;
  final Map<ConversationId, int> preferenceRevisions;

  /// Ordered in-memory replacements. The last intent is the visible state.
  final Map<ConversationId, List<PendingConversationPreferenceIntent>>
      pendingConversationPreferenceIntents;
  final Map<ConversationId, CanonicalThreadFollowState>
      currentUserThreadFollows;
  final Map<ConversationId, CanonicalThreadFollowState>
      authoritativeCurrentUserThreadFollows;
  final Map<ConversationId, int> threadFollowRevisions;
  final Map<ConversationId, List<PendingThreadFollowIntent>>
      pendingThreadFollowIntents;
  final Map<MessageId, CanonicalActorPrivateSavedMessageState>
      currentUserSavedMessages;
  final Map<MessageId, int> savedMessageRevisions;
  final Map<MessageId, CanonicalMessageReminder> currentUserMessageReminders;
  final Map<MessageId, CanonicalMessageReminder>
      authoritativeCurrentUserMessageReminders;
  final Map<MessageId, ConversationId> messageReminderConversationIds;
  final Map<MessageId, int> messageReminderRevisions;
  final Map<MessageId, List<PendingMessageReminderIntent>>
      pendingMessageReminderIntents;
  final Map<ConversationId, CanonicalDraftState> currentUserDrafts;
  final Map<ConversationId, int> draftRevisions;
  final Map<ConversationId, NormalizedConversationMetadata>
      conversationMetadata;
  final Map<String, DurableStreamMetadata> durableStreams;
  final Map<String, NormalizedConversationListEntry> conversationLists;
  final Map<ConversationId, ConversationSnapshotMetadata> conversationDetails;
  final Map<ConversationId, NormalizedTimelineEntry> timelines;

  /// Canonical renderer metadata keyed independently of message projections.
  final Map<AttachmentId, MessageAttachmentMetadata> attachments;
  final Map<String, ChatAttachmentUploadState> attachmentUploads;
  final Map<ConversationId, HuddleSessionState> huddles;
  final EventCursor? latestReplayCursor;
}

/// Immutable selection for one conversation and its snapshot-only state.
final class NormalizedConversationSnapshot {
  NormalizedConversationSnapshot({
    required this.conversationId,
    required this.conversation,
    required this.metadata,
    required Map<UserId, ConversationSnapshotMember> members,
    required List<UserId> memberUserIds,
    required this.memberListRevision,
    required this.lifecycle,
    required this.currentReadState,
    required this.currentPreference,
  })  : members = Map.unmodifiable(members),
        memberUserIds = List.unmodifiable(memberUserIds);

  final ConversationId conversationId;
  final Conversation? conversation;
  final NormalizedConversationMetadata? metadata;
  final Map<UserId, ConversationSnapshotMember> members;
  final List<UserId> memberUserIds;
  final int? memberListRevision;
  final NormalizedConversationLifecycleProjection? lifecycle;
  final ConversationSnapshotReadState? currentReadState;
  final ConversationSnapshotPreference? currentPreference;
}

/// Immutable selection for a cursor-linked conversation list.
final class NormalizedConversationListSnapshot {
  NormalizedConversationListSnapshot({
    required this.scope,
    required List<ConversationId> conversationIds,
    required List<Conversation> conversations,
    required Map<ConversationId, NormalizedConversationLifecycleProjection>
        lifecycles,
    required Map<String, NormalizedConversationListPage> pages,
    required this.metadata,
    this.nextCursor,
  })  : conversationIds = List.unmodifiable(conversationIds),
        conversations = List.unmodifiable(conversations),
        lifecycles = Map.unmodifiable(lifecycles),
        pages = Map.unmodifiable(pages);

  final ConversationSnapshotScope scope;
  final List<ConversationId> conversationIds;
  final List<Conversation> conversations;
  final Map<ConversationId, NormalizedConversationLifecycleProjection>
      lifecycles;
  final ConversationSnapshotCursor? nextCursor;
  final ConversationSnapshotMetadata? metadata;
  final Map<String, NormalizedConversationListPage> pages;
}

/// Immutable selection for one ascending message timeline.
final class NormalizedTimelineSnapshot {
  NormalizedTimelineSnapshot({
    required this.conversationId,
    required List<MessageId> messageIds,
    required List<Message> canonicalMessages,
    required List<MessageTimelineMessage> messages,
    required this.pagination,
    required this.replayCursor,
  })  : messageIds = List.unmodifiable(messageIds),
        canonicalMessages = List.unmodifiable(canonicalMessages),
        messages = List.unmodifiable(messages);

  final ConversationId conversationId;
  final List<MessageId> messageIds;
  final List<Message> canonicalMessages;

  /// Query-only projections with reaction and attachment metadata.
  final List<MessageTimelineMessage> messages;
  final MessageTimelinePagination pagination;
  final EventCursor? replayCursor;
}

final class _PendingOptimisticMessageEdit {
  const _PendingOptimisticMessageEdit({
    required this.idempotencyKey,
    required this.expectedRevision,
    required this.authoritativeMessage,
    required this.projection,
  });

  final String idempotencyKey;
  final int expectedRevision;
  final ActiveMessage authoritativeMessage;
  final ActiveMessage projection;
}

final class _PendingOptimisticMessageDelete {
  const _PendingOptimisticMessageDelete({
    required this.idempotencyKey,
    required this.expectedRevision,
    required this.authoritativeMessage,
    required this.projection,
  });

  final String idempotencyKey;
  final int expectedRevision;
  final ActiveMessage authoritativeMessage;
  final DeletedMessage projection;
}

final class _PendingOptimisticReactionIntent {
  const _PendingOptimisticReactionIntent({
    required this.idempotencyKey,
    required this.reactedByCurrentUser,
  });

  final String idempotencyKey;
  final bool reactedByCurrentUser;
}

final class _PendingOptimisticReactionLane {
  _PendingOptimisticReactionLane({
    required this.messageId,
    required this.reactionKey,
    required this.authoritativeAggregate,
  });

  final MessageId messageId;
  final String reactionKey;
  MessageReactionAggregate? authoritativeAggregate;
  final List<_PendingOptimisticReactionIntent> intents = [];
}

/// A framework-neutral, pure-Dart normalized store for parsed GET snapshots.
///
/// Streams are broadcast change streams. Call the corresponding synchronous
/// selector before listening when an initial value is needed.
final class NormalizedSnapshotStore {
  NormalizedSnapshotStore() : _state = NormalizedSnapshotState.empty();

  NormalizedSnapshotState _state;
  bool _closed = false;
  final Map<MessageId, _PendingOptimisticMessageEdit>
      _pendingOptimisticMessageEdits = {};
  final Map<MessageId, _PendingOptimisticMessageDelete>
      _pendingOptimisticMessageDeletes = {};
  final Map<String, _PendingOptimisticReactionLane>
      _pendingOptimisticReactions = {};
  final Map<String, MessageId> _pendingOptimisticMessageSends = {};
  final Map<ConversationId, StreamController<NormalizedConversationSnapshot>>
      _conversationControllers = {};
  final Map<String, StreamController<NormalizedConversationListSnapshot>>
      _listControllers = {};
  final Map<ConversationId, StreamController<NormalizedTimelineSnapshot>>
      _timelineControllers = {};
  final StreamController<ConversationSnapshotReadState>
      _currentUserReadStateChanges =
      StreamController<ConversationSnapshotReadState>.broadcast(sync: true);
  final StreamController<ConversationId> _conversationPreferenceChanges =
      StreamController<ConversationId>.broadcast(sync: true);
  final StreamController<ConversationId> _threadFollowChanges =
      StreamController<ConversationId>.broadcast(sync: true);
  final StreamController<MessageId> _messageReminderChanges =
      StreamController<MessageId>.broadcast(sync: true);
  final StreamController<NormalizedSnapshotState> _acceptedCommitChanges =
      StreamController<NormalizedSnapshotState>.broadcast(sync: true);

  NormalizedSnapshotState get state => _state;

  /// Every state transition accepted by this store, including optimistic
  /// projections whose canonical persistence export may remain unchanged.
  Stream<NormalizedSnapshotState> get acceptedCommitChanges {
    _ensureOpen();
    return _acceptedCommitChanges.stream;
  }

  /// Whether [messageId] represents a server-confirmed message row.
  ///
  /// Optimistic sends temporarily participate in the normalized timeline and
  /// canonical message map so selectors remain coherent, but must not expose
  /// actions that require an existing server sequence.
  bool isCanonicalMessage(MessageId messageId) =>
      _state.canonicalMessages.containsKey(messageId) &&
      !_pendingOptimisticMessageSends.containsValue(messageId);

  /// Conversation-list scopes currently represented or actively observed.
  /// Recovery uses this bounded set instead of broadening authorization.
  List<ConversationSnapshotScope> get recoveryConversationListScopes {
    final scopes = <String, ConversationSnapshotScope>{
      for (final entry in _state.conversationLists.entries)
        entry.key: entry.value.scope,
      for (final entry in _listControllerScopes.entries) entry.key: entry.value,
    };
    final keys = scopes.keys.toList(growable: false)..sort();
    return List<ConversationSnapshotScope>.unmodifiable(
      keys.map((key) => scopes[key]!),
    );
  }

  /// Synchronous changes to current-user read rows, including snapshot
  /// hydration and optimistic projections.
  Stream<ConversationSnapshotReadState> get currentUserReadStateChanges {
    _ensureOpen();
    return _currentUserReadStateChanges.stream;
  }

  /// Reconciles a descriptor-free upload projection into normalized state.
  NormalizedSnapshotState reconcileAttachmentUpload(
    ChatAttachmentUploadState upload,
  ) {
    _ensureOpen();
    final previous = _state;
    final existing = previous.attachmentUploads[upload.uploadId];
    if (existing != null) {
      if (existing.status == ChatAttachmentUploadStatus.attached &&
          upload.status != ChatAttachmentUploadStatus.attached) {
        if (existing.conversationId != upload.conversationId ||
            !_sameValue(existing.metadata.toJson(), upload.metadata.toJson()) ||
            upload.uploadedBytes < existing.uploadedBytes ||
            (upload.attachment != null &&
                upload.attachment!.attachmentId !=
                    existing.attachment!.attachmentId)) {
          throw NormalizedSnapshotConflict(
            'Attachment upload ${upload.uploadId} contradicts accepted state.',
          );
        }
        return previous;
      }
      if (existing.conversationId != upload.conversationId ||
          !_sameValue(existing.metadata.toJson(), upload.metadata.toJson()) ||
          upload.uploadedBytes < existing.uploadedBytes ||
          !_allowedUploadStatusTransition(existing.status, upload.status)) {
        throw NormalizedSnapshotConflict(
          'Attachment upload ${upload.uploadId} contradicts accepted state.',
        );
      }
    } else if (upload.status != ChatAttachmentUploadStatus.preparing) {
      throw NormalizedSnapshotConflict(
        'Attachment upload ${upload.uploadId} must begin in preparing state.',
      );
    }
    if (existing != null && _sameValue(existing.toJson(), upload.toJson())) {
      return previous;
    }
    return _commit(
      previous,
      _copyState(
        previous,
        attachmentUploads: Map.unmodifiable({
          ...previous.attachmentUploads,
          upload.uploadId: upload,
        }),
      ),
    );
  }

  /// Installs a validated read-cursor projection in normalized state.
  ///
  /// Canonical freshness is owned by the read-cursor runtime; this store
  /// remains the single observable surface for canonical and optimistic rows.
  /// When [authoritativeReadState] is supplied, it records the acknowledged
  /// baseline independently of the renderer-facing projection.
  NormalizedSnapshotState projectCurrentUserReadState(
    ConversationReadState readState, {
    ConversationReadState? authoritativeReadState,
  }) {
    _ensureOpen();
    final projected = ConversationSnapshotReadState.fromJson(
      readState.toJson(),
    );
    final authoritative = authoritativeReadState == null
        ? null
        : ConversationSnapshotReadState.fromJson(
            authoritativeReadState.toJson(),
          );
    if (authoritative != null &&
        (authoritative.conversationId != projected.conversationId ||
            authoritative.userId != projected.userId)) {
      throw const NormalizedSnapshotConflict(
        'A read projection and its authoritative baseline must identify the '
        'same conversation and user.',
      );
    }
    final previous = _state;
    final existing = previous.currentUserReadStates[projected.conversationId];
    final existingAuthoritative =
        previous.authoritativeCurrentUserReadStates[projected.conversationId];
    if (existing != null && existing.userId != projected.userId) {
      throw NormalizedSnapshotConflict(
        'Read state for ${projected.conversationId} changed user identity.',
      );
    }
    if (existingAuthoritative != null &&
        authoritative != null &&
        existingAuthoritative.userId != authoritative.userId) {
      throw NormalizedSnapshotConflict(
        'Read state for ${projected.conversationId} changed user identity.',
      );
    }
    final projectionChanged =
        existing == null || !_sameValue(existing.toJson(), projected.toJson());
    final authoritativeChanged = authoritative != null &&
        (existingAuthoritative == null ||
            !_sameValue(
              existingAuthoritative.toJson(),
              authoritative.toJson(),
            ));
    if (!projectionChanged && !authoritativeChanged) return previous;
    return _commit(
      previous,
      _copyState(
        previous,
        currentUserReadStates: projectionChanged
            ? Map.unmodifiable({
                ...previous.currentUserReadStates,
                projected.conversationId: projected,
              })
            : previous.currentUserReadStates,
        authoritativeCurrentUserReadStates: authoritativeChanged
            ? Map.unmodifiable({
                ...previous.authoritativeCurrentUserReadStates,
                authoritative.conversationId: authoritative,
              })
            : previous.authoritativeCurrentUserReadStates,
      ),
    );
  }

  NormalizedConversationSnapshot conversation(ConversationId conversationId) {
    final state = _state;
    return NormalizedConversationSnapshot(
      conversationId: conversationId,
      conversation: state.conversations[conversationId],
      metadata: state.conversationMetadata[conversationId],
      members: state.membersByConversation[conversationId] ?? const {},
      memberUserIds:
          state.memberUserIdsByConversation[conversationId] ?? const [],
      memberListRevision: state.memberListRevisions[conversationId],
      lifecycle: _conversationLifecycleFrom(state, conversationId),
      currentReadState: state.currentUserReadStates[conversationId],
      currentPreference: state.currentUserPreferences[conversationId],
    );
  }

  NormalizedConversationListSnapshot conversationList(
    ConversationSnapshotScope scope,
  ) {
    final state = _state;
    final entry = state.conversationLists[conversationSnapshotScopeKey(scope)];
    final ids = entry?.conversationIds ?? const <ConversationId>[];
    return NormalizedConversationListSnapshot(
      scope: scope,
      conversationIds: ids,
      conversations: [
        for (final id in ids)
          if (state.conversations[id] case final conversation?) conversation,
      ],
      lifecycles: {
        for (final id in ids)
          if (_conversationLifecycleFrom(state, id) case final lifecycle?)
            id: lifecycle,
      },
      nextCursor: entry?.nextCursor,
      metadata: entry?.metadata,
      pages: entry?.pages ?? const {},
    );
  }

  NormalizedTimelineSnapshot timeline(ConversationId conversationId) {
    final entry = _state.timelines[conversationId];
    final ids = entry?.messageIds ?? const <MessageId>[];
    return NormalizedTimelineSnapshot(
      conversationId: conversationId,
      messageIds: ids,
      canonicalMessages: [
        for (final id in ids)
          if (_state.canonicalMessages[id] case final message?) message,
      ],
      messages: [
        for (final id in ids)
          if (_state.messages[id] case final message?) message,
      ],
      pagination: entry?.pagination ?? _emptyPagination,
      replayCursor: entry?.replayCursor,
    );
  }

  Stream<NormalizedConversationSnapshot> watchConversation(
    ConversationId conversationId,
  ) {
    _ensureOpen();
    final existing = _conversationControllers[conversationId];
    if (existing != null) return existing.stream;
    late final StreamController<NormalizedConversationSnapshot> controller;
    controller = StreamController.broadcast(
      sync: true,
      onCancel: () {
        if (!controller.hasListener) {
          _conversationControllers.remove(conversationId);
        }
      },
    );
    _conversationControllers[conversationId] = controller;
    return controller.stream;
  }

  Stream<NormalizedConversationListSnapshot> watchConversationList(
    ConversationSnapshotScope scope,
  ) {
    _ensureOpen();
    final key = conversationSnapshotScopeKey(scope);
    final existing = _listControllers[key];
    if (existing != null) return existing.stream;
    late final StreamController<NormalizedConversationListSnapshot> controller;
    controller = StreamController.broadcast(
      sync: true,
      onCancel: () {
        if (!controller.hasListener) {
          _listControllers.remove(key);
          _listControllerScopes.remove(key);
        }
      },
    );
    _listControllers[key] = controller;
    _listControllerScopes[key] = scope;
    return controller.stream;
  }

  Stream<NormalizedTimelineSnapshot> watchTimeline(
    ConversationId conversationId,
  ) {
    _ensureOpen();
    final existing = _timelineControllers[conversationId];
    if (existing != null) return existing.stream;
    late final StreamController<NormalizedTimelineSnapshot> controller;
    controller = StreamController.broadcast(
      sync: true,
      onCancel: () {
        if (!controller.hasListener) {
          _timelineControllers.remove(conversationId);
        }
      },
    );
    _timelineControllers[conversationId] = controller;
    return controller.stream;
  }

  NormalizedSnapshotState hydrateConversationList(
    ConversationListSnapshot snapshot, {
    ConversationSnapshotCursor? requestCursor,
  }) {
    _ensureOpen();
    final previous = _state;
    var next = _normalizeSummaries(previous, snapshot.items);
    final scopeKey = conversationSnapshotScopeKey(snapshot.scope);
    final existing = next.conversationLists[scopeKey];
    final page = NormalizedConversationListPage(
      requestCursor: requestCursor,
      conversationIds: [
        for (final item in snapshot.items) item.conversation.id,
      ],
      nextCursor: snapshot.page.nextCursor,
      metadata: snapshot.metadata,
    );
    final pageKey = _conversationListPageKey(requestCursor);
    final existingPage = existing?.pages[pageKey];
    final pages = _sameListPage(existingPage, page)
        ? existing!.pages
        : Map<String, NormalizedConversationListPage>.unmodifiable({
            ...?existing?.pages,
            pageKey: page,
          });
    final linked = _linkConversationListPages(pages);
    final entry = NormalizedConversationListEntry(
      scope: snapshot.scope,
      conversationIds: linked.ids,
      nextCursor: linked.nextCursor,
      metadata: snapshot.metadata,
      pages: pages,
    );
    final lists = _sameListEntry(existing, entry)
        ? next.conversationLists
        : Map<String, NormalizedConversationListEntry>.unmodifiable({
            ...next.conversationLists,
            scopeKey: entry,
          });
    if (!identical(lists, next.conversationLists)) {
      next = _copyState(next, conversationLists: lists);
    }
    return _commit(previous, next);
  }

  /// Installs a validated canonical lifecycle without touching private state.
  NormalizedSnapshotState reconcileThreadLifecycle(
      ConversationId threadId, ThreadLifecycle lifecycle) {
    _ensureOpen();
    return _commit(_state, _withThreadLifecycle(_state, threadId, lifecycle));
  }

  NormalizedSnapshotState hydrateConversationDetail(
    ConversationDetailSnapshot snapshot,
  ) {
    _ensureOpen();
    final previous = _state;
    return _commit(
      previous,
      _hydrateConversationDetailState(previous, snapshot),
    );
  }

  /// Returns a detached snapshot containing acknowledged server state only.
  ///
  /// This is a pure export: it does not publish, settle, or discard any live
  /// optimistic lane. The storage codec supplies the final defensive deep
  /// copy and keeps the returned value inside the persistence schema.
  NormalizedSnapshotState canonicalPersistenceSnapshot() {
    _ensureOpen();
    final live = _state;
    final optimisticSendIds = _pendingOptimisticMessageSends.values.toSet();

    final canonicalMessages = <MessageId, Message>{
      ...live.canonicalMessages,
      for (final entry in _pendingOptimisticMessageEdits.entries)
        entry.key: entry.value.authoritativeMessage,
      for (final entry in _pendingOptimisticMessageDeletes.entries)
        entry.key: entry.value.authoritativeMessage,
    }..removeWhere((id, _) => optimisticSendIds.contains(id));

    final messages = <MessageId, MessageTimelineMessage>{...live.messages};
    for (final lane in _pendingOptimisticReactions.values) {
      final current = messages[lane.messageId];
      if (current != null) {
        messages[lane.messageId] = _withReactionAggregate(
          current,
          lane.reactionKey,
          lane.authoritativeAggregate,
        );
      }
    }
    messages.removeWhere((id, _) => optimisticSendIds.contains(id));

    final timelines = <ConversationId, NormalizedTimelineEntry>{
      for (final entry in live.timelines.entries)
        entry.key: NormalizedTimelineEntry(
          messageIds: [
            for (final id in entry.value.messageIds)
              if (!optimisticSendIds.contains(id)) id,
          ],
          pagination: entry.value.pagination,
          replayCursor: entry.value.replayCursor,
        ),
    };

    final canonical = _copyState(
      live,
      canonicalMessages: Map.unmodifiable(canonicalMessages),
      messages: Map.unmodifiable(messages),
      timelines: Map.unmodifiable(timelines),
      pendingConversationArchiveInputs: const {},
      currentUserReadStates: live.authoritativeCurrentUserReadStates,
      currentUserPreferences: live.authoritativeCurrentUserPreferences,
      pendingConversationPreferenceIntents: const {},
      currentUserThreadFollows: live.authoritativeCurrentUserThreadFollows,
      pendingThreadFollowIntents: const {},
      currentUserMessageReminders:
          live.authoritativeCurrentUserMessageReminders,
      pendingMessageReminderIntents: const {},
      attachmentUploads: const {},
    );
    return NormalizedSnapshotStateStorageCodec.decode(
      NormalizedSnapshotStateStorageCodec.encode(canonical),
    );
  }

  /// Validates and atomically replaces the store with persisted canonical
  /// state.
  ///
  /// The storage round trip provides a defensive immutable copy and removes
  /// process-only optimistic projections. Validation completes before the
  /// live state or its private reconciliation lanes are changed.
  NormalizedSnapshotState installPersistedSnapshot(
    NormalizedSnapshotState snapshot,
  ) {
    _ensureOpen();
    final persisted = NormalizedSnapshotStateStorageCodec.decode(
      NormalizedSnapshotStateStorageCodec.encode(snapshot),
    );
    _validatePersistedInstallReferences(persisted);

    _pendingOptimisticMessageEdits.clear();
    _pendingOptimisticMessageDeletes.clear();
    _pendingOptimisticReactions.clear();
    _pendingOptimisticMessageSends.clear();
    return _commit(_state, persisted);
  }

  /// Atomically replaces durable snapshot state after replay recovery.
  ///
  /// Validation and normalization happen in an unobserved staging store. The
  /// live store publishes at most one commit, with all per-stream ordering
  /// history reset and every retained timeline anchored to [safeCursor].
  NormalizedSnapshotState installRecoveredSnapshots({
    required List<ConversationListSnapshot> conversationLists,
    required List<ConversationDetailSnapshot> conversationDetails,
    required List<MessageTimelinePage> messageTimelines,
    List<MessageReminderListSnapshot> messageReminderPages = const [],
    required EventCursor? safeCursor,
  }) {
    _ensureOpen();
    final validatedCursor =
        safeCursor == null ? null : EventCursor.fromJson(safeCursor.toJson());
    final staging = NormalizedSnapshotStore();
    try {
      for (final snapshot in conversationLists) {
        staging.hydrateConversationList(snapshot);
      }
      for (final snapshot in conversationDetails) {
        staging.hydrateConversationDetail(snapshot);
      }
      for (final page in messageTimelines) {
        staging.hydrateMessageTimeline(page);
      }
      for (final page in messageReminderPages) {
        staging.hydrateMessageReminderList(page);
      }
      final staged = staging.state;
      final timelines = <ConversationId, NormalizedTimelineEntry>{
        for (final entry in staged.timelines.entries)
          entry.key: NormalizedTimelineEntry(
            messageIds: entry.value.messageIds,
            pagination: entry.value.pagination,
            replayCursor: validatedCursor,
          ),
      };
      final recovered = _copyState(
        staged,
        durableStreams: const <String, DurableStreamMetadata>{},
        timelines: Map.unmodifiable(timelines),
        latestReplayCursor: validatedCursor,
        replaceLatestReplayCursor: true,
      );
      return _commit(_state, recovered);
    } finally {
      unawaited(staging.close());
    }
  }

  /// Atomically installs one canonical conversation-creation result.
  ///
  /// The returned detail is authoritative for every reconciliation status.
  /// Lists that are already hydrated are updated only when their scope applies,
  /// and retain one canonical reference to the returned conversation ID.
  NormalizedSnapshotState reconcileConversationCreation(
    ConversationCreationResult result,
  ) {
    _ensureOpen();
    final previous = _state;
    var next = _hydrateConversationDetailState(
      previous,
      result.conversation,
    );
    final summary = result.conversation.conversation.summary;
    final conversation = summary.conversation;
    final conversationId = conversation.id;
    Map<String, NormalizedConversationListEntry>? changedLists;

    for (final mapEntry in next.conversationLists.entries) {
      final entry = mapEntry.value;
      if (!_conversationCreationAppliesToScope(conversation, entry.scope)) {
        continue;
      }

      final alreadySelected = entry.conversationIds.contains(conversationId);
      final selectionIds = <ConversationId>[
        if (!alreadySelected) conversationId,
        ...entry.conversationIds.where((id) => id != conversationId),
        if (alreadySelected) conversationId,
      ];
      var pages = entry.pages;
      if (pages.containsKey(_conversationListPageKey(null))) {
        final updatedPages = <String, NormalizedConversationListPage>{};
        for (final pageEntry in pages.entries) {
          final page = pageEntry.value;
          final ids = <ConversationId>[
            if (page.requestCursor == null) conversationId,
            ...page.conversationIds.where((id) => id != conversationId),
          ];
          updatedPages[pageEntry.key] = NormalizedConversationListPage(
            requestCursor: page.requestCursor,
            conversationIds: ids,
            nextCursor: page.nextCursor,
            metadata: page.metadata,
          );
        }
        pages = Map.unmodifiable(updatedPages);
      }

      final linked = pages.containsKey(_conversationListPageKey(null))
          ? _linkConversationListPages(pages)
          : null;
      final updated = NormalizedConversationListEntry(
        scope: entry.scope,
        conversationIds: linked?.ids ?? selectionIds,
        nextCursor: linked?.nextCursor ?? entry.nextCursor,
        metadata: entry.metadata,
        pages: pages,
      );
      if (_sameListEntry(entry, updated)) continue;
      changedLists ??= {...next.conversationLists};
      changedLists[mapEntry.key] = updated;
    }

    if (changedLists != null) {
      next = _copyState(
        next,
        conversationLists: Map.unmodifiable(changedLists),
      );
    }
    return _commit(previous, next);
  }

  /// Installs a complete canonical membership list when it is not stale.
  ///
  /// Equal revisions must carry the same complete list. The return value is
  /// true only when a settled leave or current-user removal revoked access and
  /// access-dependent state was cleared for that conversation.
  bool reconcileConversationMembership(
    ConversationMembershipMutationResult result,
  ) {
    _ensureOpen();
    final previous = _state;
    final conversationId = result.conversationId;
    final knownRevision = previous.memberListRevisions[conversationId];
    if (knownRevision != null && result.memberListRevision < knownRevision) {
      return false;
    }

    final conversation = previous.conversations[conversationId];
    if (conversation == null) {
      throw NormalizedSnapshotConflict(
        'Canonical membership for $conversationId requires a known '
        'conversation.',
      );
    }
    final canonicalMembers = <UserId, ConversationSnapshotMember>{
      for (final member in result.members)
        member.userId: ConversationSnapshotMember.fromJson({
          'tenantId': conversation.tenantId.toJson(),
          'conversationId': conversationId.toJson(),
          ...member.toJson(),
        }),
    };
    final existingMembers = previous.membersByConversation[conversationId];
    if (knownRevision == result.memberListRevision &&
        existingMembers != null &&
        !_sameMemberMaps(existingMembers, canonicalMembers)) {
      throw NormalizedSnapshotConflict(
        'Member list $conversationId changed at revision $knownRevision.',
      );
    }

    final activeUserIds = <UserId>[
      for (final member in result.members)
        if (member.state == ConversationMembershipMemberState.active)
          member.userId,
    ];
    final currentUserId =
        _currentUserIdForConversation(previous, conversationId) ??
            ((result.intent == ConversationMembershipMutationIntent.join ||
                    result.intent == ConversationMembershipMutationIntent.leave)
                ? result.memberUserId
                : null);
    final settled = result.reconciliationStatus ==
            ConversationMembershipReconciliationStatus.applied ||
        result.reconciliationStatus ==
            ConversationMembershipReconciliationStatus.replayed ||
        result.reconciliationStatus ==
            ConversationMembershipReconciliationStatus.alreadyRequestedState;
    final revokesCurrentUser = settled &&
        currentUserId != null &&
        ((result.intent == ConversationMembershipMutationIntent.leave &&
                result.memberUserId == currentUserId) ||
            (result.intent ==
                    ConversationMembershipMutationIntent.removeMember &&
                result.memberUserId == currentUserId)) &&
        canonicalMembers[currentUserId]?.state != 'active';

    var next = _copyState(
      previous,
      membersByConversation: Map.unmodifiable({
        ...previous.membersByConversation,
        conversationId: Map<UserId, ConversationSnapshotMember>.unmodifiable(
          canonicalMembers,
        ),
      }),
      memberUserIdsByConversation: Map.unmodifiable({
        ...previous.memberUserIdsByConversation,
        conversationId: List<UserId>.unmodifiable(activeUserIds),
      }),
      memberListRevisions: Map.unmodifiable({
        ...previous.memberListRevisions,
        conversationId: result.memberListRevision,
      }),
    );
    Set<MessageId> clearedMessageIds = const {};
    if (revokesCurrentUser) {
      final cleared = _clearConversationAccessState(next, conversationId);
      next = cleared.state;
      clearedMessageIds = cleared.messageIds;
    }
    _commit(previous, next);
    if (clearedMessageIds.isNotEmpty) {
      _pendingOptimisticMessageEdits.removeWhere(
        (messageId, _) => clearedMessageIds.contains(messageId),
      );
      _pendingOptimisticMessageDeletes.removeWhere(
        (messageId, _) => clearedMessageIds.contains(messageId),
      );
      _pendingOptimisticReactions.removeWhere(
        (_, lane) => clearedMessageIds.contains(lane.messageId),
      );
    }
    return revokesCurrentUser;
  }

  /// Atomically installs a resolved thread detail and its root summary.
  ///
  /// Validation and normalization complete against an unpublished state. A
  /// conflict therefore leaves both the thread conversation and root message
  /// unchanged.
  NormalizedSnapshotState reconcileThreadOpening(
    ThreadCreationResult result,
  ) {
    _ensureOpen();
    final previous = _state;
    final root = previous.canonicalMessages[result.rootMessageId];
    if (root == null || root.conversationId != result.parentConversationId) {
      throw NormalizedSnapshotConflict(
        'The canonical thread root is unavailable or belongs to another '
        'conversation.',
      );
    }
    final thread = result.conversation.thread;
    if (thread.tenantId != root.tenantId) {
      throw const NormalizedSnapshotConflict(
        'The thread and root message must belong to one tenant.',
      );
    }
    final existingSummary = root.threadSummary;
    if (existingSummary != null &&
        existingSummary.threadId != result.rootThreadSummary.threadId) {
      throw const NormalizedSnapshotConflict(
        'The root message already identifies another thread.',
      );
    }

    final rootJson = Map<String, Object?>.from(root.toJson())
      ..['threadSummary'] = result.rootThreadSummary.toJson();
    final hydratedRoot = Message.fromJson(rootJson);
    var next = _hydrateConversationDetailState(
      previous,
      result.conversation.snapshot,
    );
    var timelineMessages = next.messages;
    if (timelineMessages[result.rootMessageId] case final projection?) {
      final projectionJson = Map<String, Object?>.from(projection.toJson())
        ..['threadSummary'] = result.rootThreadSummary.toJson()
        ..['isThreadRoot'] = true;
      timelineMessages = Map.unmodifiable({
        ...timelineMessages,
        result.rootMessageId: MessageTimelineMessage.fromJson(projectionJson),
      });
    }
    next = _copyState(
      next,
      canonicalMessages: Map.unmodifiable({
        ...next.canonicalMessages,
        result.rootMessageId: hydratedRoot,
      }),
      messages: timelineMessages,
    );
    return _commit(previous, next);
  }

  NormalizedSnapshotState _hydrateConversationDetailState(
    NormalizedSnapshotState previous,
    ConversationDetailSnapshot snapshot,
  ) {
    final item = snapshot.conversation;
    final summary = item.summary;
    final id = summary.conversation.id;
    final previousConversation = previous.conversations[id];
    final previousMetadata = previous.conversationMetadata[id];
    final incomingRank = _compareSummary(
      summary,
      previousConversation,
      previousMetadata,
    );
    var next = _normalizeSummaries(previous, [summary]);

    final existingIds = next.memberUserIdsByConversation[id];
    var memberIds = next.memberUserIdsByConversation;
    var memberListRevisions = next.memberListRevisions;
    if (existingIds == null || incomingRank > 0) {
      memberIds = Map.unmodifiable({
        ...memberIds,
        id: List<UserId>.unmodifiable(item.memberUserIds),
      });
    }
    final incomingMemberListRevision = item.memberListRevision;
    final existingMemberListRevision = memberListRevisions[id];
    if (incomingMemberListRevision != null &&
        (existingMemberListRevision == null ||
            incomingMemberListRevision > existingMemberListRevision)) {
      memberListRevisions = Map.unmodifiable({
        ...memberListRevisions,
        id: incomingMemberListRevision,
      });
    }

    next = _mergeHydratedConversationPreference(next, item.currentPreference);

    final existingDetail = next.conversationDetails[id];
    var details = next.conversationDetails;
    if (existingDetail == null || incomingRank > 0) {
      details = Map.unmodifiable({...details, id: snapshot.metadata});
    }

    if (!identical(memberIds, next.memberUserIdsByConversation) ||
        !identical(memberListRevisions, next.memberListRevisions) ||
        !identical(details, next.conversationDetails)) {
      next = _copyState(
        next,
        memberUserIdsByConversation: memberIds,
        memberListRevisions: memberListRevisions,
        conversationDetails: details,
      );
    }
    final authority = item.currentThreadFollow;
    if (authority != null) {
      final follow = authority.follow;
      if (follow != null) {
        next = _mergeThreadFollowCanonical(
            next, id, authority.followRevision, follow);
      }
      // Missing follow rows retain Dart's implicit revision zero; persisted
      // revision entries represent stored rows and must remain positive.
    }
    return next;
  }

  NormalizedSnapshotState hydrateMessageTimeline(MessageTimelinePage page) {
    _ensureOpen();
    final previous = _state;
    var canonicalMessages = previous.canonicalMessages;
    Map<MessageId, Message>? changedCanonical;
    var messages = previous.messages;
    Map<MessageId, MessageTimelineMessage>? changed;
    var attachments = previous.attachments;
    Map<AttachmentId, MessageAttachmentMetadata>? changedAttachments;
    final reactionBaselineUpdates =
        <_PendingOptimisticReactionLane, MessageReactionAggregate?>{};
    for (final snapshotMessage in page.messages) {
      final existingCanonical = canonicalMessages[snapshotMessage.id];
      final incoming = _preserveSameRevisionThreadSummary(
        existingCanonical,
        snapshotMessage,
      );
      final canonical = incoming.message;
      _validateCanonicalMessage(existingCanonical, canonical);
      if (existingCanonical == null ||
          canonical.revision.revision > existingCanonical.revision.revision) {
        changedCanonical ??= {...canonicalMessages};
        changedCanonical[incoming.id] = canonical;
      }

      final existing = messages[incoming.id];
      if (existing != null &&
          (existing.tenantId != incoming.tenantId ||
              existing.conversationId != incoming.conversationId ||
              existing.sequence != incoming.sequence)) {
        throw NormalizedSnapshotConflict(
          'Message ${incoming.id} changed tenant, conversation, or sequence.',
        );
      }
      if (existing != null &&
          incoming.revision.revision < existing.revision.revision) {
        continue;
      }
      final projectedIncoming = _projectPendingReactionsFromSnapshot(
        incoming,
        reactionBaselineUpdates,
      );
      if (existing != null &&
          existing.revision.revision == incoming.revision.revision &&
          !_sameTimelineMessageWithoutReactions(existing, incoming)) {
        throw NormalizedSnapshotConflict(
          'Message ${incoming.id} has conflicting data at one revision.',
        );
      }
      if (existing == null ||
          incoming.revision.revision > existing.revision.revision ||
          !_sameValue(existing.toJson(), projectedIncoming.toJson())) {
        changed ??= {...messages};
        changed[incoming.id] = projectedIncoming;
      }
      for (final metadata in incoming.attachmentMetadata) {
        final existingMetadata = attachments[metadata.attachmentId];
        if (existingMetadata != null &&
            !_sameValue(existingMetadata.toJson(), metadata.toJson())) {
          throw NormalizedSnapshotConflict(
            'Attachment ${metadata.attachmentId} has conflicting canonical metadata.',
          );
        }
        if (existingMetadata == null) {
          changedAttachments ??= {...attachments};
          changedAttachments[metadata.attachmentId] = metadata;
        }
      }
    }
    if (changedCanonical != null) {
      canonicalMessages = Map.unmodifiable(changedCanonical);
    }
    if (changed != null) messages = Map.unmodifiable(changed);
    if (changedAttachments != null) {
      attachments = Map.unmodifiable(changedAttachments);
    }

    final existingTimeline = previous.timelines[page.conversationId];
    final mergedIds = <MessageId>[
      ...?existingTimeline?.messageIds,
      ...page.messages.map((message) => message.id),
    ];
    final messageIds = _sortAndValidateTimelineIds(
      mergedIds,
      canonicalMessages,
      page.conversationId,
    );
    final pagination = _mergePagination(
      existingTimeline,
      page,
      canonicalMessages,
    );
    final acceptedCursor =
        previous.latestReplayCursor ?? page.replay.resumeFrom;
    final timelineEntry = NormalizedTimelineEntry(
      messageIds: messageIds,
      pagination: pagination,
      replayCursor: acceptedCursor,
    );
    final timelines = _sameTimelineEntry(existingTimeline, timelineEntry)
        ? previous.timelines
        : Map<ConversationId, NormalizedTimelineEntry>.unmodifiable({
            ...previous.timelines,
            page.conversationId: timelineEntry,
          });

    var metadata = previous.conversationMetadata;
    final known = metadata[page.conversationId];
    if (known != null && page.messages.isNotEmpty) {
      final latest = page.messages.fold<int>(
        known.latestSequence.value,
        (value, message) =>
            message.sequence.value > value ? message.sequence.value : value,
      );
      if (latest != known.latestSequence.value) {
        metadata = Map.unmodifiable({
          ...metadata,
          page.conversationId: NormalizedConversationMetadata(
            latestSequence: MessageSequence(latest),
            activityAt: known.activityAt,
            unreadMentionCount: known.unreadMentionCount,
          ),
        });
      }
    }

    if (identical(canonicalMessages, previous.canonicalMessages) &&
        identical(messages, previous.messages) &&
        identical(attachments, previous.attachments) &&
        identical(timelines, previous.timelines) &&
        identical(metadata, previous.conversationMetadata) &&
        previous.latestReplayCursor != null) {
      _applyReactionBaselineUpdates(reactionBaselineUpdates);
      return previous;
    }
    final next = _copyState(
      previous,
      canonicalMessages: canonicalMessages,
      messages: messages,
      attachments: attachments,
      timelines: timelines,
      conversationMetadata: metadata,
      latestReplayCursor: acceptedCursor,
      replaceLatestReplayCursor: true,
    );
    final committed = _commit(previous, next);
    _applyReactionBaselineUpdates(reactionBaselineUpdates);
    return committed;
  }

  /// Reconciles one authoritative command result into canonical state and the
  /// ordered timeline without fabricating [MessageTimelineMessage] fields.
  NormalizedSnapshotState reconcileMessage(Message incoming) {
    _ensureOpen();
    final previous = _state;
    final existing = previous.canonicalMessages[incoming.id];
    final pendingEdit = _pendingOptimisticMessageEdits[incoming.id];
    final pendingDelete = _pendingOptimisticMessageDeletes[incoming.id];
    final validationBase = pendingEdit?.authoritativeMessage ??
        pendingDelete?.authoritativeMessage ??
        existing;
    _validateCanonicalMessage(validationBase, incoming);

    final pendingRevision =
        pendingEdit?.expectedRevision ?? pendingDelete?.expectedRevision;
    if (pendingRevision != null &&
        incoming.revision.revision <= pendingRevision) {
      return previous;
    }

    var canonicalMessages = previous.canonicalMessages;
    if (existing == null ||
        incoming.revision.revision > existing.revision.revision) {
      canonicalMessages = Map.unmodifiable({
        ...canonicalMessages,
        incoming.id: incoming,
      });
    }

    final existingTimeline = previous.timelines[incoming.conversationId];
    final messageIds = _sortAndValidateTimelineIds(
      <MessageId>[
        ...?existingTimeline?.messageIds,
        incoming.id,
      ],
      canonicalMessages,
      incoming.conversationId,
    );
    final timeline = NormalizedTimelineEntry(
      messageIds: messageIds,
      pagination: existingTimeline?.pagination ?? _emptyPagination,
      replayCursor: existingTimeline?.replayCursor,
    );
    final timelines = _sameTimelineEntry(existingTimeline, timeline)
        ? previous.timelines
        : Map<ConversationId, NormalizedTimelineEntry>.unmodifiable({
            ...previous.timelines,
            incoming.conversationId: timeline,
          });

    if (identical(canonicalMessages, previous.canonicalMessages) &&
        identical(timelines, previous.timelines)) {
      return previous;
    }
    final committed = _commit(
      previous,
      _copyState(
        previous,
        canonicalMessages: canonicalMessages,
        timelines: timelines,
      ),
    );
    if (pendingEdit != null) {
      _pendingOptimisticMessageEdits.remove(incoming.id);
    }
    if (pendingDelete != null) {
      _pendingOptimisticMessageDeletes.remove(incoming.id);
    }
    return committed;
  }

  /// Publishes replacement content without changing the canonical revision or
  /// any timeline-only projection data.
  NormalizedSnapshotState beginOptimisticMessageEdit(
    EditMessageRequest request,
  ) {
    _ensureOpen();
    final previous = _state;
    final existing = previous.canonicalMessages[request.messageId];
    if (existing is! ActiveMessage ||
        existing.revision.revision != request.expectedRevision ||
        _pendingOptimisticMessageEdits.containsKey(request.messageId) ||
        _pendingOptimisticMessageDeletes.containsKey(request.messageId)) {
      throw NormalizedSnapshotConflict(
        'Message ${request.messageId} cannot begin this optimistic edit.',
      );
    }

    final projection = ActiveMessage(
      id: existing.id,
      tenantId: existing.tenantId,
      conversationId: existing.conversationId,
      author: existing.author,
      sequence: existing.sequence,
      createdAt: existing.createdAt,
      updatedAt: existing.updatedAt,
      revision: existing.revision,
      content: request.content,
      threadSummary: existing.threadSummary,
      replyTo: existing.replyTo,
    );
    final pending = _PendingOptimisticMessageEdit(
      idempotencyKey: request.idempotencyKey,
      expectedRevision: request.expectedRevision,
      authoritativeMessage: existing,
      projection: projection,
    );
    final next = _copyState(
      previous,
      canonicalMessages: Map.unmodifiable({
        ...previous.canonicalMessages,
        request.messageId: projection,
      }),
    );
    _pendingOptimisticMessageEdits[request.messageId] = pending;
    try {
      return _commit(previous, next);
    } catch (_) {
      _pendingOptimisticMessageEdits.remove(request.messageId);
      rethrow;
    }
  }

  /// Installs an authoritative applied, replayed, or revision-conflict row
  /// only while it still owns the matching optimistic projection.
  NormalizedSnapshotState reconcileOptimisticMessageEdit(
    String idempotencyKey,
    EditMessageResult result,
  ) {
    _ensureOpen();
    final pending = _pendingOptimisticMessageEdits[result.message.id];
    if (pending == null || pending.idempotencyKey != idempotencyKey) {
      return _state;
    }
    if (pending.expectedRevision != result.expectedRevision) {
      throw NormalizedSnapshotConflict(
        'Message ${result.message.id} returned a mismatched edit revision.',
      );
    }
    _validateCanonicalMessage(pending.authoritativeMessage, result.message);

    final previous = _state;
    final current = previous.canonicalMessages[result.message.id];
    _pendingOptimisticMessageEdits.remove(result.message.id);
    if (current == null ||
        !_sameValue(current.toJson(), pending.projection.toJson())) {
      return previous;
    }
    return _commit(
      previous,
      _copyState(
        previous,
        canonicalMessages: Map.unmodifiable({
          ...previous.canonicalMessages,
          result.message.id: result.message,
        }),
      ),
    );
  }

  /// Restores this edit's authoritative row only if its projection is still
  /// current, so a newer durable or command reconciliation always wins.
  NormalizedSnapshotState rollbackOptimisticMessageEdit(
    MessageId messageId,
    String idempotencyKey,
  ) {
    _ensureOpen();
    final pending = _pendingOptimisticMessageEdits[messageId];
    if (pending == null || pending.idempotencyKey != idempotencyKey) {
      return _state;
    }

    final previous = _state;
    final current = previous.canonicalMessages[messageId];
    _pendingOptimisticMessageEdits.remove(messageId);
    if (current == null ||
        !_sameValue(current.toJson(), pending.projection.toJson())) {
      return previous;
    }
    return _commit(
      previous,
      _copyState(
        previous,
        canonicalMessages: Map.unmodifiable({
          ...previous.canonicalMessages,
          messageId: pending.authoritativeMessage,
        }),
      ),
    );
  }

  /// Publishes a provisional deletion shell without fabricating a future
  /// revision or server-only deletion time. The baseline author and updatedAt
  /// provide paired provisional metadata until authoritative settlement.
  NormalizedSnapshotState beginOptimisticMessageDelete(
    SoftDeleteMessageRequest request,
  ) {
    _ensureOpen();
    final previous = _state;
    final existing = previous.canonicalMessages[request.messageId];
    if (existing is! ActiveMessage ||
        existing.revision.revision != request.expectedRevision ||
        _pendingOptimisticMessageEdits.containsKey(request.messageId) ||
        _pendingOptimisticMessageDeletes.containsKey(request.messageId)) {
      throw NormalizedSnapshotConflict(
        'Message ${request.messageId} cannot begin this optimistic delete.',
      );
    }

    final projection = DeletedMessage(
      id: existing.id,
      tenantId: existing.tenantId,
      conversationId: existing.conversationId,
      author: existing.author,
      sequence: existing.sequence,
      createdAt: existing.createdAt,
      updatedAt: existing.updatedAt,
      revision: existing.revision,
      content: null,
      deletedAt: existing.updatedAt,
      deletedByUserId: existing.author.userId,
      threadSummary: existing.threadSummary,
      replyTo: existing.replyTo,
    );
    final pending = _PendingOptimisticMessageDelete(
      idempotencyKey: request.idempotencyKey,
      expectedRevision: request.expectedRevision,
      authoritativeMessage: existing,
      projection: projection,
    );
    final next = _copyState(
      previous,
      canonicalMessages: Map.unmodifiable({
        ...previous.canonicalMessages,
        request.messageId: projection,
      }),
    );
    _pendingOptimisticMessageDeletes[request.messageId] = pending;
    try {
      return _commit(previous, next);
    } catch (_) {
      _pendingOptimisticMessageDeletes.remove(request.messageId);
      rethrow;
    }
  }

  /// Installs an authoritative applied, replayed, or revision-conflict row
  /// only while this transaction still owns the matching deletion shell.
  NormalizedSnapshotState reconcileOptimisticMessageDelete(
    String idempotencyKey,
    SoftDeleteMessageResult result,
  ) {
    final pending = _pendingOptimisticMessageDeletes[result.message.id];
    if (pending == null || pending.idempotencyKey != idempotencyKey) {
      return _state;
    }
    _ensureOpen();
    if (pending.expectedRevision != result.expectedRevision) {
      throw NormalizedSnapshotConflict(
        'Message ${result.message.id} returned a mismatched delete revision.',
      );
    }
    _validateCanonicalMessage(pending.authoritativeMessage, result.message);

    final previous = _state;
    final current = previous.canonicalMessages[result.message.id];
    _pendingOptimisticMessageDeletes.remove(result.message.id);
    if (current == null ||
        !_sameValue(current.toJson(), pending.projection.toJson())) {
      return previous;
    }
    return _commit(
      previous,
      _copyState(
        previous,
        canonicalMessages: Map.unmodifiable({
          ...previous.canonicalMessages,
          result.message.id: result.message,
        }),
      ),
    );
  }

  /// Restores this delete's authoritative baseline only while its exact
  /// provisional shell remains current.
  NormalizedSnapshotState rollbackOptimisticMessageDelete(
    MessageId messageId,
    String idempotencyKey,
  ) {
    final pending = _pendingOptimisticMessageDeletes[messageId];
    if (pending == null || pending.idempotencyKey != idempotencyKey) {
      return _state;
    }
    _ensureOpen();

    final previous = _state;
    final current = previous.canonicalMessages[messageId];
    _pendingOptimisticMessageDeletes.remove(messageId);
    if (current == null ||
        !_sameValue(current.toJson(), pending.projection.toJson())) {
      return previous;
    }
    return _commit(
      previous,
      _copyState(
        previous,
        canonicalMessages: Map.unmodifiable({
          ...previous.canonicalMessages,
          messageId: pending.authoritativeMessage,
        }),
      ),
    );
  }

  /// Publishes the latest explicit current-user membership for one aggregate.
  /// Multiple intents for the same aggregate share one durable baseline while
  /// the newest desired state remains visible.
  NormalizedSnapshotState beginOptimisticReaction(
    ReactionMutationInput request,
  ) {
    _ensureOpen();
    final previous = _state;
    final current = previous.messages[request.messageId];
    if (current == null) {
      throw NormalizedSnapshotConflict(
        'Message ${request.messageId} has no timeline reaction projection.',
      );
    }
    final target = _reactionTargetKey(request.messageId, request.reactionKey);
    var lane = _pendingOptimisticReactions[target];
    if (lane == null) {
      lane = _PendingOptimisticReactionLane(
        messageId: request.messageId,
        reactionKey: request.reactionKey,
        authoritativeAggregate: _reactionAggregate(
          current,
          request.reactionKey,
        ),
      );
      _pendingOptimisticReactions[target] = lane;
    }
    if (lane.intents.any(
      (intent) => intent.idempotencyKey == request.idempotencyKey,
    )) {
      if (lane.intents.isEmpty) _pendingOptimisticReactions.remove(target);
      throw NormalizedSnapshotConflict(
        'Reaction $target already has this optimistic intent.',
      );
    }

    final intent = _PendingOptimisticReactionIntent(
      idempotencyKey: request.idempotencyKey,
      reactedByCurrentUser: request is AddReactionInput,
    );
    lane.intents.add(intent);
    final projection = _projectReactionLane(current, lane);
    try {
      return _commit(
        previous,
        _copyState(
          previous,
          messages: Map.unmodifiable({
            ...previous.messages,
            request.messageId: projection,
          }),
        ),
      );
    } catch (_) {
      lane.intents.remove(intent);
      if (lane.intents.isEmpty) _pendingOptimisticReactions.remove(target);
      rethrow;
    }
  }

  /// Installs the exact server aggregate once, then reapplies any later queued
  /// desired state for the same message and reaction key.
  NormalizedSnapshotState reconcileOptimisticReaction(
    String idempotencyKey,
    ReactionMutationResult result,
  ) {
    _ensureOpen();
    final target = _reactionTargetKey(result.messageId, result.reactionKey);
    final lane = _pendingOptimisticReactions[target];
    if (lane == null) return _state;
    final intentIndex = lane.intents.indexWhere(
      (intent) => intent.idempotencyKey == idempotencyKey,
    );
    if (intentIndex < 0) return _state;
    final intent = lane.intents[intentIndex];
    if (intent.reactedByCurrentUser != result.reactedByCurrentUser) {
      throw NormalizedSnapshotConflict(
        'Reaction $target returned a mismatched membership state.',
      );
    }

    lane.authoritativeAggregate = result.count == 0
        ? null
        : MessageReactionAggregate(
            reactionKey: result.reactionKey,
            count: result.count,
            reactedByCurrentUser: result.reactedByCurrentUser,
          );
    lane.intents.removeAt(intentIndex);
    return _settleReactionLane(target, lane);
  }

  /// Removes only the matching failed intent and projects a later queued
  /// intent, or restores the newest accepted snapshot baseline.
  NormalizedSnapshotState rollbackOptimisticReaction(
    MessageId messageId,
    String reactionKey,
    String idempotencyKey,
  ) {
    _ensureOpen();
    final target = _reactionTargetKey(messageId, reactionKey);
    final lane = _pendingOptimisticReactions[target];
    if (lane == null) return _state;
    final before = lane.intents.length;
    lane.intents.removeWhere(
      (intent) => intent.idempotencyKey == idempotencyKey,
    );
    if (lane.intents.length == before) return _state;
    return _settleReactionLane(target, lane);
  }

  NormalizedSnapshotState _settleReactionLane(
    String target,
    _PendingOptimisticReactionLane lane,
  ) {
    final previous = _state;
    final current = previous.messages[lane.messageId];
    if (lane.intents.isEmpty) _pendingOptimisticReactions.remove(target);
    if (current == null) return previous;
    final projection = _projectReactionLane(current, lane);
    if (_sameValue(current.toJson(), projection.toJson())) return previous;
    return _commit(
      previous,
      _copyState(
        previous,
        messages: Map.unmodifiable({
          ...previous.messages,
          lane.messageId: projection,
        }),
      ),
    );
  }

  Future<void> close() async {
    if (_closed) return;
    if (_pendingOptimisticReactions.isNotEmpty) {
      final previous = _state;
      final messages = {...previous.messages};
      var changed = false;
      for (final lane in _pendingOptimisticReactions.values) {
        final current = messages[lane.messageId];
        if (current == null) continue;
        final restored = _withReactionAggregate(
          current,
          lane.reactionKey,
          lane.authoritativeAggregate,
        );
        if (!_sameValue(current.toJson(), restored.toJson())) {
          messages[lane.messageId] = restored;
          changed = true;
        }
      }
      _pendingOptimisticReactions.clear();
      if (changed) {
        _commit(
          previous,
          _copyState(previous, messages: Map.unmodifiable(messages)),
        );
      }
    }
    if (_pendingOptimisticMessageDeletes.isNotEmpty) {
      final previous = _state;
      final canonicalMessages = {...previous.canonicalMessages};
      var changed = false;
      for (final entry in _pendingOptimisticMessageDeletes.entries) {
        final current = canonicalMessages[entry.key];
        if (current != null &&
            _sameValue(current.toJson(), entry.value.projection.toJson())) {
          canonicalMessages[entry.key] = entry.value.authoritativeMessage;
          changed = true;
        }
      }
      _pendingOptimisticMessageDeletes.clear();
      if (changed) {
        _commit(
          previous,
          _copyState(
            previous,
            canonicalMessages: Map.unmodifiable(canonicalMessages),
          ),
        );
      }
    }
    rollbackAllOptimisticConversationArchives();
    rollbackAllOptimisticConversationPreferences();
    rollbackAllOptimisticThreadFollows();
    clearActorPrivateMessageReminders();
    _closed = true;
    final controllers = <StreamController<Object?>>[
      ..._conversationControllers.values,
      ..._listControllers.values,
      ..._timelineControllers.values,
    ];
    _conversationControllers.clear();
    _listControllers.clear();
    _listControllerScopes.clear();
    _timelineControllers.clear();
    _pendingOptimisticMessageEdits.clear();
    await Future.wait(controllers.map((controller) => controller.close()));
    await _currentUserReadStateChanges.close();
    await _conversationPreferenceChanges.close();
    await _threadFollowChanges.close();
    await _messageReminderChanges.close();
    await _acceptedCommitChanges.close();
  }

  NormalizedSnapshotState _normalizeSummaries(
    NormalizedSnapshotState state,
    Iterable<ConversationSnapshotSummary> summaries,
  ) {
    var conversations = state.conversations;
    var lifecycleArchivedStates = state.lifecycleArchivedStates;
    var metadata = state.conversationMetadata;
    var members = state.membersByConversation;
    var reads = state.currentUserReadStates;
    var authoritativeReads = state.authoritativeCurrentUserReadStates;
    Map<ConversationId, Conversation>? changedConversations;
    Map<ConversationId, bool>? changedLifecycleArchivedStates;
    Map<ConversationId, NormalizedConversationMetadata>? changedMetadata;
    Map<ConversationId, Map<UserId, ConversationSnapshotMember>>?
        changedMembers;
    Map<ConversationId, ConversationSnapshotReadState>? changedReads;
    Map<ConversationId, ConversationSnapshotReadState>?
        changedAuthoritativeReads;

    for (final summary in summaries) {
      var incoming = summary.conversation;
      final id = incoming.id;
      final original = conversations[id];
      final existing = original == null ? null : _mergeThreadLifecycle(original, incoming);
      incoming = _mergeThreadLifecycle(incoming, original);
      if (existing != null && !identical(existing, original)) {
        changedConversations ??= {...conversations};
        changedConversations[id] = existing;
      }
      final existingMetadata = metadata[id];
      if (existing != null &&
          (existing.tenantId != incoming.tenantId ||
              existing.createdAt != incoming.createdAt ||
              existing.type != incoming.type)) {
        throw NormalizedSnapshotConflict(
          'Conversation $id changed canonical identity fields.',
        );
      }
      final rank = _compareSummary(summary, existing, existingMetadata);
      if (rank == 0 &&
          existing != null &&
          (!_sameValue(existing.toJson(), incoming.toJson()) ||
              !_sameConversationMetadata(existingMetadata!, summary))) {
        throw NormalizedSnapshotConflict(
          'Conversation $id has conflicting data at one snapshot version.',
        );
      }
      final knownRead = state.currentUserReadStates[id];
      final incomingRead = summary.currentReadState;
      final acceptsMentionCount = knownRead == null ||
          (incomingRead.userId == knownRead.userId &&
              (incomingRead.lastReadSequence.value > knownRead.lastReadSequence.value ||
                  (incomingRead.lastReadSequence == knownRead.lastReadSequence &&
                      incomingRead.updatedAt.value.compareTo(knownRead.updatedAt.value) >= 0)));
      if (existing == null || rank > 0) {
        changedConversations ??= {...conversations};
        changedConversations[id] = incoming;
        changedMetadata ??= {...metadata};
        changedMetadata[id] = NormalizedConversationMetadata(
          latestSequence: summary.latestSequence,
          activityAt: summary.activityAt,
          unreadMentionCount: acceptsMentionCount
              ? summary.unreadMentionCount
              : existingMetadata?.unreadMentionCount ?? 0,
        );
        changedLifecycleArchivedStates ??= {...lifecycleArchivedStates};
        changedLifecycleArchivedStates[id] = incoming.archivedAt != null;
      }

      // Counts can change without conversation/read-cursor timestamps changing
      // (for example deleting a reply source). Never infer them from messages.
      if (rank == 0 &&
          existingMetadata != null &&
          existingMetadata.unreadMentionCount != summary.unreadMentionCount &&
          acceptsMentionCount) {
        changedMetadata ??= {...metadata};
        changedMetadata[id] = NormalizedConversationMetadata(
          latestSequence: existingMetadata.latestSequence,
          activityAt: existingMetadata.activityAt,
          unreadMentionCount: summary.unreadMentionCount,
        );
      }

      final member = summary.currentMember;
      final byUser =
          members[id] ?? const <UserId, ConversationSnapshotMember>{};
      final selectedMember = _pickTimestamped(
        byUser[member.userId],
        member,
        (value) => value.updatedAt,
        'membership for $id/${member.userId}',
        (value) => value.toJson(),
      );
      if (!identical(selectedMember, byUser[member.userId])) {
        changedMembers ??= {...members};
        changedMembers[id] = Map.unmodifiable({
          ...byUser,
          member.userId: selectedMember,
        });
      }

      final read = summary.currentReadState;
      final previousAuthoritativeRead = authoritativeReads[id];
      final selectedRead = _pickTimestamped(
        previousAuthoritativeRead,
        read,
        (value) => value.updatedAt,
        'read state for $id',
        (value) => value.toJson(),
      );
      if (!identical(selectedRead, previousAuthoritativeRead)) {
        changedAuthoritativeReads ??= {...authoritativeReads};
        changedAuthoritativeReads[id] = selectedRead;
        final visibleRead = reads[id];
        if (visibleRead == null ||
            !_sameValue(visibleRead.toJson(), selectedRead.toJson())) {
          changedReads ??= {...reads};
          changedReads[id] = selectedRead;
        }
      }
    }

    if (changedConversations != null) {
      conversations = Map.unmodifiable(changedConversations);
    }
    if (changedLifecycleArchivedStates != null) {
      lifecycleArchivedStates =
          Map.unmodifiable(changedLifecycleArchivedStates);
    }
    if (changedMetadata != null) metadata = Map.unmodifiable(changedMetadata);
    if (changedMembers != null) members = Map.unmodifiable(changedMembers);
    if (changedReads != null) reads = Map.unmodifiable(changedReads);
    if (changedAuthoritativeReads != null) {
      authoritativeReads = Map.unmodifiable(changedAuthoritativeReads);
    }
    final normalized = identical(conversations, state.conversations) &&
            identical(metadata, state.conversationMetadata) &&
            identical(lifecycleArchivedStates, state.lifecycleArchivedStates) &&
            identical(members, state.membersByConversation) &&
            identical(reads, state.currentUserReadStates) &&
            identical(
              authoritativeReads,
              state.authoritativeCurrentUserReadStates,
            )
        ? state
        : _copyState(
            state,
            conversations: conversations,
            lifecycleArchivedStates: lifecycleArchivedStates,
            conversationMetadata: metadata,
            membersByConversation: members,
            currentUserReadStates: reads,
            authoritativeCurrentUserReadStates: authoritativeReads,
          );
    var next = normalized;
    for (final summary in summaries) {
      next = _mergeHydratedConversationPreference(
        next,
        summary.currentPreference,
      );
    }
    return next;
  }

  NormalizedSnapshotState _commit(
    NormalizedSnapshotState previous,
    NormalizedSnapshotState next,
  ) {
    if (identical(previous, next)) return previous;
    final beforeConversations = {
      for (final id in _conversationControllers.keys)
        id: _conversationFrom(previous, id),
    };
    final beforeLists = {
      for (final key in _listControllers.keys) key: _listFrom(previous, key),
    };
    final beforeTimelines = {
      for (final id in _timelineControllers.keys)
        id: _timelineFrom(previous, id),
    };
    final changedPreferenceIds = <ConversationId>{
      ...previous.currentUserPreferences.keys,
      ...next.currentUserPreferences.keys,
      ...previous.authoritativeCurrentUserPreferences.keys,
      ...next.authoritativeCurrentUserPreferences.keys,
      ...previous.preferenceRevisions.keys,
      ...next.preferenceRevisions.keys,
      ...previous.pendingConversationPreferenceIntents.keys,
      ...next.pendingConversationPreferenceIntents.keys,
    }
        .where(
          (id) => !_sameValue(
            _conversationPreferenceStateValue(previous, id),
            _conversationPreferenceStateValue(next, id),
          ),
        )
        .toList(growable: false);
    final changedThreadFollowIds = <ConversationId>{
      ...previous.currentUserThreadFollows.keys,
      ...next.currentUserThreadFollows.keys,
      ...previous.authoritativeCurrentUserThreadFollows.keys,
      ...next.authoritativeCurrentUserThreadFollows.keys,
      ...previous.threadFollowRevisions.keys,
      ...next.threadFollowRevisions.keys,
      ...previous.pendingThreadFollowIntents.keys,
      ...next.pendingThreadFollowIntents.keys,
    }.where(
      (id) => !_sameValue(
        _threadFollowStateValue(previous, id),
        _threadFollowStateValue(next, id),
      ),
    );
    final changedMessageReminderIds = <MessageId>{
      ...previous.currentUserMessageReminders.keys,
      ...next.currentUserMessageReminders.keys,
      ...previous.authoritativeCurrentUserMessageReminders.keys,
      ...next.authoritativeCurrentUserMessageReminders.keys,
      ...previous.messageReminderConversationIds.keys,
      ...next.messageReminderConversationIds.keys,
      ...previous.messageReminderRevisions.keys,
      ...next.messageReminderRevisions.keys,
      ...previous.pendingMessageReminderIntents.keys,
      ...next.pendingMessageReminderIntents.keys,
    }.where(
      (id) => !_sameValue(
        _messageReminderStateValue(previous, id),
        _messageReminderStateValue(next, id),
      ),
    );
    _state = next;
    _acceptedCommitChanges.add(next);
    for (final id in changedPreferenceIds) {
      _conversationPreferenceChanges.add(id);
    }
    for (final id in changedThreadFollowIds) {
      _threadFollowChanges.add(id);
    }
    for (final id in changedMessageReminderIds) {
      _messageReminderChanges.add(id);
    }
    for (final entry in next.currentUserReadStates.entries) {
      final previousReadState = previous.currentUserReadStates[entry.key];
      if (previousReadState == null ||
          !_sameValue(previousReadState.toJson(), entry.value.toJson())) {
        _currentUserReadStateChanges.add(entry.value);
      }
    }
    for (final entry in _conversationControllers.entries.toList()) {
      final selected = conversation(entry.key);
      final before = beforeConversations[entry.key];
      // Synchronous commit observers can register a watcher after the baseline
      // was captured. Publish its current selection without dereferencing null.
      if (before == null || !_sameConversationSelection(before, selected)) {
        entry.value.add(selected);
      }
    }
    for (final entry in _listControllers.entries.toList()) {
      final selected = _listFrom(next, entry.key);
      final before = beforeLists[entry.key];
      if (before == null || !_sameListSelection(before, selected)) {
        entry.value.add(selected);
      }
    }
    for (final entry in _timelineControllers.entries.toList()) {
      final selected = timeline(entry.key);
      final before = beforeTimelines[entry.key];
      if (before == null || !_sameTimelineSelection(before, selected)) {
        entry.value.add(selected);
      }
    }
    return next;
  }

  NormalizedConversationSnapshot _conversationFrom(
    NormalizedSnapshotState state,
    ConversationId id,
  ) {
    final current = _state;
    _state = state;
    try {
      return conversation(id);
    } finally {
      _state = current;
    }
  }

  NormalizedConversationListSnapshot _listFrom(
    NormalizedSnapshotState state,
    String key,
  ) {
    final entry = state.conversationLists[key];
    final scope = entry?.scope ?? _scopeForListController(key);
    final ids = entry?.conversationIds ?? const <ConversationId>[];
    return NormalizedConversationListSnapshot(
      scope: scope,
      conversationIds: ids,
      conversations: [
        for (final id in ids)
          if (state.conversations[id] case final conversation?) conversation,
      ],
      lifecycles: {
        for (final id in ids)
          if (_conversationLifecycleFrom(state, id) case final lifecycle?)
            id: lifecycle,
      },
      nextCursor: entry?.nextCursor,
      metadata: entry?.metadata,
      pages: entry?.pages ?? const {},
    );
  }

  ConversationSnapshotScope _scopeForListController(String key) {
    final controllerKey = _listControllerScopes[key];
    if (controllerKey != null) return controllerKey;
    throw StateError('Missing conversation-list selector scope for $key.');
  }

  final Map<String, ConversationSnapshotScope> _listControllerScopes = {};

  NormalizedTimelineSnapshot _timelineFrom(
    NormalizedSnapshotState state,
    ConversationId id,
  ) {
    final current = _state;
    _state = state;
    try {
      return timeline(id);
    } finally {
      _state = current;
    }
  }

  MessageTimelineMessage _projectPendingReactionsFromSnapshot(
    MessageTimelineMessage incoming,
    Map<_PendingOptimisticReactionLane, MessageReactionAggregate?> updates,
  ) {
    var projected = incoming;
    for (final lane in _pendingOptimisticReactions.values) {
      if (lane.messageId != incoming.id) continue;
      final authoritative = _reactionAggregate(incoming, lane.reactionKey);
      updates[lane] = authoritative;
      final desired = lane.intents.last.reactedByCurrentUser;
      projected = _withReactionAggregate(
        projected,
        lane.reactionKey,
        _reactionProjection(authoritative, lane.reactionKey, desired),
      );
    }
    return projected;
  }

  void _applyReactionBaselineUpdates(
    Map<_PendingOptimisticReactionLane, MessageReactionAggregate?> updates,
  ) {
    for (final entry in updates.entries) {
      entry.key.authoritativeAggregate = entry.value;
    }
  }

  void _ensureOpen() {
    if (_closed) throw StateError('The normalized snapshot store is closed.');
  }
}

const _emptyPagination = MessageTimelinePagination(
  older: MessageTimelineBoundary.unavailable(),
  newer: MessageTimelineBoundary.unavailable(),
);

/// Stable key used to address a normalized conversation-list scope.
String conversationSnapshotScopeKey(ConversationSnapshotScope scope) {
  if (scope is OrganizationConversationSnapshotScope) return 'organization';
  final entity = (scope as EntityConversationSnapshotScope).entity;
  return 'entity:${entity.type.length}:${entity.type}:${entity.id}';
}

bool _conversationCreationAppliesToScope(
  Conversation conversation,
  ConversationSnapshotScope scope,
) {
  if (scope is OrganizationConversationSnapshotScope) return true;
  if (conversation is! ChannelConversation || conversation.entity == null) {
    return false;
  }
  final selected = (scope as EntityConversationSnapshotScope).entity;
  return conversation.entity!.type == selected.type &&
      conversation.entity!.id == selected.id;
}

String _conversationListPageKey(ConversationSnapshotCursor? cursor) =>
    cursor == null ? 'initial' : 'cursor:${cursor.toJson()}';

String _reactionTargetKey(MessageId messageId, String reactionKey) =>
    '${messageId.value.length}:${messageId.value}:$reactionKey';

MessageReactionAggregate? _reactionAggregate(
  MessageTimelineMessage message,
  String reactionKey,
) {
  for (final aggregate in message.reactions) {
    if (aggregate.reactionKey == reactionKey) return aggregate;
  }
  return null;
}

MessageReactionAggregate? _reactionProjection(
  MessageReactionAggregate? authoritative,
  String reactionKey,
  bool reactedByCurrentUser,
) {
  if (reactedByCurrentUser) {
    if (authoritative?.reactedByCurrentUser == true) return authoritative;
    return MessageReactionAggregate(
      reactionKey: reactionKey,
      count: (authoritative?.count ?? 0) + 1,
      reactedByCurrentUser: true,
    );
  }
  if (authoritative == null || !authoritative.reactedByCurrentUser) {
    return authoritative;
  }
  final count = authoritative.count - 1;
  return count == 0
      ? null
      : MessageReactionAggregate(
          reactionKey: reactionKey,
          count: count,
          reactedByCurrentUser: false,
        );
}

MessageTimelineMessage _projectReactionLane(
  MessageTimelineMessage current,
  _PendingOptimisticReactionLane lane,
) {
  final aggregate = lane.intents.isEmpty
      ? lane.authoritativeAggregate
      : _reactionProjection(
          lane.authoritativeAggregate,
          lane.reactionKey,
          lane.intents.last.reactedByCurrentUser,
        );
  return _withReactionAggregate(current, lane.reactionKey, aggregate);
}

MessageTimelineMessage _withReactionAggregate(
  MessageTimelineMessage message,
  String reactionKey,
  MessageReactionAggregate? aggregate,
) {
  final reactions = <MessageReactionAggregate>[];
  var replaced = false;
  for (final existing in message.reactions) {
    if (existing.reactionKey != reactionKey) {
      reactions.add(existing);
    } else if (aggregate != null) {
      reactions.add(aggregate);
      replaced = true;
    }
  }
  if (aggregate != null && !replaced) reactions.add(aggregate);
  return MessageTimelineMessage(
    message: message.message,
    isThreadRoot: message.isThreadRoot,
    reactions: reactions,
    attachmentMetadata: message.attachmentMetadata,
  );
}

bool _sameTimelineMessageWithoutReactions(
  MessageTimelineMessage left,
  MessageTimelineMessage right,
) {
  final leftJson = Map<String, Object?>.of(left.toJson())..remove('reactions');
  final rightJson = Map<String, Object?>.of(right.toJson())
    ..remove('reactions');
  return _sameValue(leftJson, rightJson);
}

({List<ConversationId> ids, ConversationSnapshotCursor? nextCursor})
    _linkConversationListPages(
  Map<String, NormalizedConversationListPage> pages,
) {
  var page = pages[_conversationListPageKey(null)];
  if (page == null) return (ids: const [], nextCursor: null);
  final ids = <ConversationId>[];
  final seenIds = <ConversationId>{};
  final visited = <String>{};
  while (page != null) {
    for (final id in page.conversationIds) {
      if (seenIds.add(id)) ids.add(id);
    }
    final nextCursor = page.nextCursor;
    if (nextCursor == null) {
      return (ids: List.unmodifiable(ids), nextCursor: null);
    }
    final key = _conversationListPageKey(nextCursor);
    if (!visited.add(key)) {
      return (ids: List.unmodifiable(ids), nextCursor: nextCursor);
    }
    final next = pages[key];
    if (next == null) {
      return (ids: List.unmodifiable(ids), nextCursor: nextCursor);
    }
    page = next;
  }
  return (ids: List.unmodifiable(ids), nextCursor: null);
}

int _compareSummary(
  ConversationSnapshotSummary incoming,
  Conversation? existing,
  NormalizedConversationMetadata? metadata,
) {
  if (existing == null || metadata == null) return 1;
  var compared =
      incoming.latestSequence.value.compareTo(metadata.latestSequence.value);
  if (compared != 0) return compared;
  compared =
      incoming.conversation.updatedAt.value.compareTo(existing.updatedAt.value);
  if (compared != 0) return compared;
  return incoming.activityAt.value.compareTo(metadata.activityAt.value);
}

T _pickTimestamped<T>(
  T? existing,
  T incoming,
  IsoTimestamp Function(T value) timestamp,
  String label,
  Object? Function(T value) json,
) {
  if (existing == null) return incoming;
  final comparison =
      timestamp(incoming).value.compareTo(timestamp(existing).value);
  if (comparison > 0) return incoming;
  if (comparison < 0) return existing;
  if (_sameValue(json(existing), json(incoming))) return existing;
  throw NormalizedSnapshotConflict('$label conflicts at one updatedAt value.');
}

MessageTimelineMessage _preserveSameRevisionThreadSummary(
  Message? existing,
  MessageTimelineMessage incoming,
) {
  if (existing == null) return incoming;
  final summary = existing.threadSummary;
  final incomingSummary = incoming.threadSummary;
  if (summary != null &&
      incomingSummary != null &&
      summary.threadId != incomingSummary.threadId) {
    throw NormalizedSnapshotConflict(
      'Message ${incoming.id} changed thread identity.',
    );
  }
  if (existing.revision.revision != incoming.revision.revision ||
      _sameValue(summary?.toJson(), incomingSummary?.toJson())) {
    return incoming;
  }

  // Reply summaries advance independently of the root's content revision.
  // A tied snapshot provides no ordering proof against an accepted summary
  // (and its viewer enrichment may differ). Retain that baseline, as in the
  // TS cache, while still validating every content and identity field below.
  // Fresh stores install snapshot summaries; durable events and explicit
  // thread reconciliation remain authoritative summary update paths.
  final json = incoming.toJson()
    ..remove('threadSummary')
    ..['isThreadRoot'] = summary != null;
  if (summary != null) json['threadSummary'] = summary.toJson();
  return MessageTimelineMessage.fromJson(json);
}

void _validateCanonicalMessage(Message? existing, Message incoming) {
  if (existing == null) return;
  if (existing.tenantId != incoming.tenantId ||
      existing.conversationId != incoming.conversationId ||
      existing.sequence != incoming.sequence) {
    throw NormalizedSnapshotConflict(
      'Message ${incoming.id} changed tenant, conversation, or sequence.',
    );
  }
  if (existing.revision.revision == incoming.revision.revision &&
      !_sameValue(existing.toJson(), incoming.toJson())) {
    throw NormalizedSnapshotConflict(
      'Message ${incoming.id} has conflicting data at one revision.',
    );
  }
}

List<MessageId> _sortAndValidateTimelineIds(
  List<MessageId> ids,
  Map<MessageId, Message> messages,
  ConversationId conversationId,
) {
  final unique = ids.toSet().toList()
    ..sort((left, right) {
      final leftMessage = messages[left]!;
      final rightMessage = messages[right]!;
      final sequence =
          leftMessage.sequence.value.compareTo(rightMessage.sequence.value);
      return sequence != 0 ? sequence : left.value.compareTo(right.value);
    });
  Message? previous;
  for (final id in unique) {
    final message = messages[id];
    if (message == null || message.conversationId != conversationId) {
      throw NormalizedSnapshotConflict(
        'Timeline $conversationId references a missing or unrelated message.',
      );
    }
    if (previous != null && previous.sequence == message.sequence) {
      throw NormalizedSnapshotConflict(
        'Timeline $conversationId has multiple messages at ${message.sequence}.',
      );
    }
    previous = message;
  }
  return List.unmodifiable(unique);
}

MessageTimelinePagination _mergePagination(
  NormalizedTimelineEntry? existing,
  MessageTimelinePage page,
  Map<MessageId, Message> messages,
) {
  if (existing == null || existing.messageIds.isEmpty) return page.pagination;
  if (page.messages.isEmpty) return existing.pagination;
  final existingFirst = messages[existing.messageIds.first]!;
  final existingLast = messages[existing.messageIds.last]!;
  final incomingFirst = page.messages.first;
  final incomingLast = page.messages.last;
  final firstComparison =
      incomingFirst.sequence.value.compareTo(existingFirst.sequence.value);
  final lastComparison =
      incomingLast.sequence.value.compareTo(existingLast.sequence.value);
  final merged = MessageTimelinePagination(
    older: firstComparison < 0
        ? page.pagination.older
        : firstComparison > 0
            ? existing.pagination.older
            : _mergeEqualBoundary(
                existing.pagination.older,
                page.pagination.older,
              ),
    newer: lastComparison > 0
        ? page.pagination.newer
        : lastComparison < 0
            ? existing.pagination.newer
            : _mergeEqualBoundary(
                existing.pagination.newer,
                page.pagination.newer,
              ),
  );
  return _sameValue(existing.pagination.toJson(), merged.toJson())
      ? existing.pagination
      : merged;
}

MessageTimelineBoundary _mergeEqualBoundary(
  MessageTimelineBoundary existing,
  MessageTimelineBoundary incoming,
) {
  if (!existing.available || !incoming.available) {
    return const MessageTimelineBoundary.unavailable();
  }
  if (existing.cursor != incoming.cursor) {
    throw const NormalizedSnapshotConflict(
      'Equal timeline edges advertise conflicting pagination cursors.',
    );
  }
  return existing;
}

NormalizedSnapshotState _copyState(
  NormalizedSnapshotState state, {
  Map<ConversationId, Conversation>? conversations,
  Map<MessageId, Message>? canonicalMessages,
  Map<MessageId, MessageTimelineMessage>? messages,
  Map<ConversationId, Map<UserId, ConversationSnapshotMember>>?
      membersByConversation,
  Map<ConversationId, List<UserId>>? memberUserIdsByConversation,
  Map<ConversationId, int>? lifecycleRevisions,
  Map<ConversationId, bool>? lifecycleArchivedStates,
  Map<ConversationId, List<ConversationArchiveInput>>?
      pendingConversationArchiveInputs,
  Map<ConversationId, int>? memberListRevisions,
  Map<ConversationId, ConversationSnapshotReadState>? currentUserReadStates,
  Map<ConversationId, ConversationSnapshotReadState>?
      authoritativeCurrentUserReadStates,
  Map<ConversationId, ConversationSnapshotPreference>? currentUserPreferences,
  Map<ConversationId, ConversationSnapshotPreference>?
      authoritativeCurrentUserPreferences,
  Map<ConversationId, int>? preferenceRevisions,
  Map<ConversationId, List<PendingConversationPreferenceIntent>>?
      pendingConversationPreferenceIntents,
  Map<ConversationId, CanonicalThreadFollowState>? currentUserThreadFollows,
  Map<ConversationId, CanonicalThreadFollowState>?
      authoritativeCurrentUserThreadFollows,
  Map<ConversationId, int>? threadFollowRevisions,
  Map<ConversationId, List<PendingThreadFollowIntent>>?
      pendingThreadFollowIntents,
  Map<MessageId, CanonicalActorPrivateSavedMessageState>?
      currentUserSavedMessages,
  Map<MessageId, int>? savedMessageRevisions,
  Map<MessageId, CanonicalMessageReminder>? currentUserMessageReminders,
  Map<MessageId, CanonicalMessageReminder>?
      authoritativeCurrentUserMessageReminders,
  Map<MessageId, ConversationId>? messageReminderConversationIds,
  Map<MessageId, int>? messageReminderRevisions,
  Map<MessageId, List<PendingMessageReminderIntent>>?
      pendingMessageReminderIntents,
  Map<ConversationId, CanonicalDraftState>? currentUserDrafts,
  Map<ConversationId, int>? draftRevisions,
  Map<ConversationId, NormalizedConversationMetadata>? conversationMetadata,
  Map<String, DurableStreamMetadata>? durableStreams,
  Map<String, NormalizedConversationListEntry>? conversationLists,
  Map<ConversationId, ConversationSnapshotMetadata>? conversationDetails,
  Map<ConversationId, NormalizedTimelineEntry>? timelines,
  Map<AttachmentId, MessageAttachmentMetadata>? attachments,
  Map<String, ChatAttachmentUploadState>? attachmentUploads,
  Map<ConversationId, HuddleSessionState>? huddles,
  EventCursor? latestReplayCursor,
  bool replaceLatestReplayCursor = false,
}) =>
    NormalizedSnapshotState._(
      conversations: conversations ?? state.conversations,
      canonicalMessages: canonicalMessages ?? state.canonicalMessages,
      messages: messages ?? state.messages,
      membersByConversation:
          membersByConversation ?? state.membersByConversation,
      memberUserIdsByConversation:
          memberUserIdsByConversation ?? state.memberUserIdsByConversation,
      lifecycleRevisions: lifecycleRevisions ?? state.lifecycleRevisions,
      lifecycleArchivedStates:
          lifecycleArchivedStates ?? state.lifecycleArchivedStates,
      pendingConversationArchiveInputs: pendingConversationArchiveInputs ??
          state.pendingConversationArchiveInputs,
      memberListRevisions: memberListRevisions ?? state.memberListRevisions,
      currentUserReadStates:
          currentUserReadStates ?? state.currentUserReadStates,
      authoritativeCurrentUserReadStates: authoritativeCurrentUserReadStates ??
          state.authoritativeCurrentUserReadStates,
      currentUserPreferences:
          currentUserPreferences ?? state.currentUserPreferences,
      authoritativeCurrentUserPreferences:
          authoritativeCurrentUserPreferences ??
              state.authoritativeCurrentUserPreferences,
      preferenceRevisions: preferenceRevisions ?? state.preferenceRevisions,
      pendingConversationPreferenceIntents:
          pendingConversationPreferenceIntents ??
              state.pendingConversationPreferenceIntents,
      currentUserThreadFollows:
          currentUserThreadFollows ?? state.currentUserThreadFollows,
      authoritativeCurrentUserThreadFollows:
          authoritativeCurrentUserThreadFollows ??
              state.authoritativeCurrentUserThreadFollows,
      threadFollowRevisions:
          threadFollowRevisions ?? state.threadFollowRevisions,
      pendingThreadFollowIntents:
          pendingThreadFollowIntents ?? state.pendingThreadFollowIntents,
      currentUserSavedMessages:
          currentUserSavedMessages ?? state.currentUserSavedMessages,
      savedMessageRevisions:
          savedMessageRevisions ?? state.savedMessageRevisions,
      currentUserMessageReminders:
          currentUserMessageReminders ?? state.currentUserMessageReminders,
      authoritativeCurrentUserMessageReminders:
          authoritativeCurrentUserMessageReminders ??
              state.authoritativeCurrentUserMessageReminders,
      messageReminderConversationIds: messageReminderConversationIds ??
          state.messageReminderConversationIds,
      messageReminderRevisions:
          messageReminderRevisions ?? state.messageReminderRevisions,
      pendingMessageReminderIntents:
          pendingMessageReminderIntents ?? state.pendingMessageReminderIntents,
      currentUserDrafts: currentUserDrafts ?? state.currentUserDrafts,
      draftRevisions: draftRevisions ?? state.draftRevisions,
      conversationMetadata: conversationMetadata ?? state.conversationMetadata,
      durableStreams: durableStreams ?? state.durableStreams,
      conversationLists: conversationLists ?? state.conversationLists,
      conversationDetails: conversationDetails ?? state.conversationDetails,
      timelines: timelines ?? state.timelines,
      attachments: attachments ?? state.attachments,
      attachmentUploads: attachmentUploads ?? state.attachmentUploads,
      huddles: huddles ?? state.huddles,
      latestReplayCursor: replaceLatestReplayCursor
          ? latestReplayCursor
          : state.latestReplayCursor,
    );

bool _attachmentMatchesUploadStatus(
  ChatAttachmentUploadStatus upload,
  AttachmentLifecycleStatus canonical,
) =>
    switch (upload) {
      ChatAttachmentUploadStatus.pending ||
      ChatAttachmentUploadStatus.uploading ||
      ChatAttachmentUploadStatus.finalizing =>
        canonical == AttachmentLifecycleStatus.pending,
      ChatAttachmentUploadStatus.finalized =>
        canonical == AttachmentLifecycleStatus.finalized,
      ChatAttachmentUploadStatus.attached => true,
      ChatAttachmentUploadStatus.rejected =>
        canonical == AttachmentLifecycleStatus.rejected,
      ChatAttachmentUploadStatus.abandoned =>
        canonical == AttachmentLifecycleStatus.abandoned,
      ChatAttachmentUploadStatus.preparing ||
      ChatAttachmentUploadStatus.failed ||
      ChatAttachmentUploadStatus.cancelled =>
        true,
    };

bool _allowedUploadStatusTransition(
  ChatAttachmentUploadStatus from,
  ChatAttachmentUploadStatus to,
) {
  if (from == to) return true;
  return switch (from) {
    ChatAttachmentUploadStatus.preparing => {
        ChatAttachmentUploadStatus.pending,
        ChatAttachmentUploadStatus.failed,
        ChatAttachmentUploadStatus.cancelled,
      }.contains(to),
    ChatAttachmentUploadStatus.pending => {
        ChatAttachmentUploadStatus.uploading,
        ChatAttachmentUploadStatus.abandoned,
        ChatAttachmentUploadStatus.failed,
        ChatAttachmentUploadStatus.cancelled,
      }.contains(to),
    ChatAttachmentUploadStatus.uploading => {
        ChatAttachmentUploadStatus.finalizing,
        ChatAttachmentUploadStatus.abandoned,
        ChatAttachmentUploadStatus.failed,
        ChatAttachmentUploadStatus.cancelled,
      }.contains(to),
    ChatAttachmentUploadStatus.finalizing => {
        ChatAttachmentUploadStatus.finalized,
        ChatAttachmentUploadStatus.rejected,
        ChatAttachmentUploadStatus.abandoned,
        ChatAttachmentUploadStatus.failed,
        ChatAttachmentUploadStatus.cancelled,
      }.contains(to),
    ChatAttachmentUploadStatus.finalized ||
    ChatAttachmentUploadStatus.attached ||
    ChatAttachmentUploadStatus.rejected ||
    ChatAttachmentUploadStatus.abandoned ||
    ChatAttachmentUploadStatus.failed ||
    ChatAttachmentUploadStatus.cancelled =>
      false,
  };
}

bool _messageAttachmentMatchesUploadMetadata(
  MessageAttachmentMetadata messageAttachment,
  AttachmentMetadata uploadMetadata,
) =>
    messageAttachment.fileName == uploadMetadata.fileName &&
    messageAttachment.contentType == uploadMetadata.contentType &&
    messageAttachment.sizeBytes == uploadMetadata.sizeBytes;

UserId? _currentUserIdForConversation(
  NormalizedSnapshotState state,
  ConversationId conversationId,
) {
  final readUserId = state.currentUserReadStates[conversationId]?.userId;
  final preferenceUserId = state.currentUserPreferences[conversationId]?.userId;
  if (readUserId != null &&
      preferenceUserId != null &&
      readUserId != preferenceUserId) {
    throw NormalizedSnapshotConflict(
      'Current-user state for $conversationId has conflicting identities.',
    );
  }
  return readUserId ?? preferenceUserId;
}

bool _sameMemberMaps(
  Map<UserId, ConversationSnapshotMember> left,
  Map<UserId, ConversationSnapshotMember> right,
) {
  if (left.length != right.length) return false;
  for (final entry in left.entries) {
    final other = right[entry.key];
    if (other == null || !_sameValue(entry.value.toJson(), other.toJson())) {
      return false;
    }
  }
  return true;
}

({NormalizedSnapshotState state, Set<MessageId> messageIds})
    _clearConversationAccessState(
  NormalizedSnapshotState state,
  ConversationId conversationId,
) {
  final clearedMessageIds = <MessageId>{
    for (final entry in state.canonicalMessages.entries)
      if (entry.value.conversationId == conversationId) entry.key,
    for (final entry in state.messages.entries)
      if (entry.value.conversationId == conversationId) entry.key,
  };
  final conversationLists = <String, NormalizedConversationListEntry>{};
  for (final entry in state.conversationLists.entries) {
    final list = entry.value;
    final pages = <String, NormalizedConversationListPage>{
      for (final pageEntry in list.pages.entries)
        pageEntry.key: NormalizedConversationListPage(
          requestCursor: pageEntry.value.requestCursor,
          conversationIds: pageEntry.value.conversationIds
              .where((id) => id != conversationId)
              .toList(growable: false),
          nextCursor: pageEntry.value.nextCursor,
          metadata: pageEntry.value.metadata,
        ),
    };
    conversationLists[entry.key] = NormalizedConversationListEntry(
      scope: list.scope,
      conversationIds: list.conversationIds
          .where((id) => id != conversationId)
          .toList(growable: false),
      nextCursor: list.nextCursor,
      metadata: list.metadata,
      pages: pages,
    );
  }
  return (
    state: _copyState(
      state,
      canonicalMessages: Map.unmodifiable({
        for (final entry in state.canonicalMessages.entries)
          if (!clearedMessageIds.contains(entry.key)) entry.key: entry.value,
      }),
      messages: Map.unmodifiable({
        for (final entry in state.messages.entries)
          if (!clearedMessageIds.contains(entry.key)) entry.key: entry.value,
      }),
      currentUserReadStates: Map.unmodifiable({
        for (final entry in state.currentUserReadStates.entries)
          if (entry.key != conversationId) entry.key: entry.value,
      }),
      authoritativeCurrentUserReadStates: Map.unmodifiable({
        for (final entry in state.authoritativeCurrentUserReadStates.entries)
          if (entry.key != conversationId) entry.key: entry.value,
      }),
      currentUserPreferences: Map.unmodifiable({
        for (final entry in state.currentUserPreferences.entries)
          if (entry.key != conversationId) entry.key: entry.value,
      }),
      authoritativeCurrentUserPreferences: Map.unmodifiable({
        for (final entry in state.authoritativeCurrentUserPreferences.entries)
          if (entry.key != conversationId) entry.key: entry.value,
      }),
      preferenceRevisions: Map.unmodifiable({
        for (final entry in state.preferenceRevisions.entries)
          if (entry.key != conversationId) entry.key: entry.value,
      }),
      pendingConversationPreferenceIntents: Map.unmodifiable({
        for (final entry in state.pendingConversationPreferenceIntents.entries)
          if (entry.key != conversationId) entry.key: entry.value,
      }),
      currentUserThreadFollows: Map.unmodifiable({
        for (final entry in state.currentUserThreadFollows.entries)
          if (entry.key != conversationId) entry.key: entry.value,
      }),
      authoritativeCurrentUserThreadFollows: Map.unmodifiable({
        for (final entry in state.authoritativeCurrentUserThreadFollows.entries)
          if (entry.key != conversationId) entry.key: entry.value,
      }),
      threadFollowRevisions: Map.unmodifiable({
        for (final entry in state.threadFollowRevisions.entries)
          if (entry.key != conversationId) entry.key: entry.value,
      }),
      pendingThreadFollowIntents: Map.unmodifiable({
        for (final entry in state.pendingThreadFollowIntents.entries)
          if (entry.key != conversationId) entry.key: entry.value,
      }),
      currentUserSavedMessages: Map.unmodifiable({
        for (final entry in state.currentUserSavedMessages.entries)
          if (!clearedMessageIds.contains(entry.key)) entry.key: entry.value,
      }),
      savedMessageRevisions: Map.unmodifiable({
        for (final entry in state.savedMessageRevisions.entries)
          if (!clearedMessageIds.contains(entry.key)) entry.key: entry.value,
      }),
      currentUserMessageReminders: Map.unmodifiable({
        for (final entry in state.currentUserMessageReminders.entries)
          if (state.messageReminderConversationIds[entry.key] != conversationId)
            entry.key: entry.value,
      }),
      authoritativeCurrentUserMessageReminders: Map.unmodifiable({
        for (final entry
            in state.authoritativeCurrentUserMessageReminders.entries)
          if (state.messageReminderConversationIds[entry.key] != conversationId)
            entry.key: entry.value,
      }),
      messageReminderConversationIds: Map.unmodifiable({
        for (final entry in state.messageReminderConversationIds.entries)
          if (entry.value != conversationId) entry.key: entry.value,
      }),
      messageReminderRevisions: Map.unmodifiable({
        for (final entry in state.messageReminderRevisions.entries)
          if (state.messageReminderConversationIds[entry.key] != conversationId)
            entry.key: entry.value,
      }),
      pendingMessageReminderIntents: Map.unmodifiable({
        for (final entry in state.pendingMessageReminderIntents.entries)
          if (state.messageReminderConversationIds[entry.key] != conversationId)
            entry.key: entry.value,
      }),
      currentUserDrafts: Map.unmodifiable({
        for (final entry in state.currentUserDrafts.entries)
          if (entry.key != conversationId) entry.key: entry.value,
      }),
      draftRevisions: Map.unmodifiable({
        for (final entry in state.draftRevisions.entries)
          if (entry.key != conversationId) entry.key: entry.value,
      }),
      conversationMetadata: Map.unmodifiable({
        ...state.conversationMetadata,
        if (state.conversationMetadata[conversationId] case final metadata?)
          conversationId: NormalizedConversationMetadata(
            latestSequence: metadata.latestSequence,
            activityAt: metadata.activityAt,
          ),
      }),
      conversationLists: Map.unmodifiable(conversationLists),
      conversationDetails: Map.unmodifiable({
        for (final entry in state.conversationDetails.entries)
          if (entry.key != conversationId) entry.key: entry.value,
      }),
      timelines: Map.unmodifiable({
        for (final entry in state.timelines.entries)
          if (entry.key != conversationId) entry.key: entry.value,
      }),
    ),
    messageIds: Set<MessageId>.unmodifiable(clearedMessageIds),
  );
}

bool _sameConversationMetadata(
  NormalizedConversationMetadata metadata,
  ConversationSnapshotSummary summary,
) =>
    metadata.latestSequence == summary.latestSequence &&
    metadata.activityAt == summary.activityAt;

bool _sameListPage(
  NormalizedConversationListPage? left,
  NormalizedConversationListPage right,
) =>
    left != null && _sameValue(_listPageValue(left), _listPageValue(right));

bool _sameListEntry(
  NormalizedConversationListEntry? left,
  NormalizedConversationListEntry right,
) =>
    left != null && _sameValue(_listEntryValue(left), _listEntryValue(right));

bool _sameTimelineEntry(
  NormalizedTimelineEntry? left,
  NormalizedTimelineEntry right,
) =>
    left != null &&
    _sameValue(_timelineEntryValue(left), _timelineEntryValue(right));

void _validatePersistedInstallReferences(NormalizedSnapshotState state) {
  final referencedConversationIds = <ConversationId>{
    ...state.lifecycleRevisions.keys,
    ...state.lifecycleArchivedStates.keys,
    ...state.memberListRevisions.keys,
    ...state.preferenceRevisions.keys,
    ...state.threadFollowRevisions.keys,
    ...state.currentUserThreadFollows.keys,
    ...state.currentUserDrafts.keys,
    ...state.draftRevisions.keys,
  };
  if (!state.conversations.keys.toSet().containsAll(
        referencedConversationIds,
      )) {
    throw const FormatException(
      'Persisted normalized state references an unknown conversation.',
    );
  }
  for (final threadId in <ConversationId>{
    ...state.currentUserThreadFollows.keys,
    ...state.threadFollowRevisions.keys,
  }) {
    if (state.conversations[threadId] is! ThreadConversation) {
      throw const FormatException(
        'Persisted thread follow references a non-thread conversation.',
      );
    }
  }
}

bool _sameConversationSelection(
  NormalizedConversationSnapshot left,
  NormalizedConversationSnapshot right,
) =>
    _sameValue(
        _conversationSelectionValue(left), _conversationSelectionValue(right));

bool _sameListSelection(
  NormalizedConversationListSnapshot left,
  NormalizedConversationListSnapshot right,
) =>
    _sameValue(_listSelectionValue(left), _listSelectionValue(right));

bool _sameTimelineSelection(
  NormalizedTimelineSnapshot left,
  NormalizedTimelineSnapshot right,
) =>
    _sameValue(_timelineSelectionValue(left), _timelineSelectionValue(right));

Object? _conversationSelectionValue(NormalizedConversationSnapshot value) => {
      'conversation': value.conversation?.toJson(),
      'metadata': value.metadata == null
          ? null
          : {
              'latestSequence': value.metadata!.latestSequence.toJson(),
              'activityAt': value.metadata!.activityAt.toJson(),
              'unreadMentionCount': value.metadata!.unreadMentionCount,
            },
      'members': {
        for (final entry in value.members.entries)
          entry.key.toJson(): entry.value.toJson(),
      },
      'memberUserIds': value.memberUserIds.map((id) => id.toJson()).toList(),
      'lifecycle': _conversationLifecycleValue(value.lifecycle),
      'read': value.currentReadState?.toJson(),
      'preference': value.currentPreference?.toJson(),
    };

Object? _listSelectionValue(NormalizedConversationListSnapshot value) => {
      'scope': value.scope.toJson(),
      'conversationIds':
          value.conversationIds.map((id) => id.toJson()).toList(),
      'conversations':
          value.conversations.map((item) => item.toJson()).toList(),
      'lifecycles': {
        for (final entry in value.lifecycles.entries)
          entry.key.toJson(): _conversationLifecycleValue(entry.value),
      },
      'nextCursor': value.nextCursor?.toJson(),
      'metadata': value.metadata?.toJson(),
      'pages': {
        for (final entry in value.pages.entries)
          entry.key: _listPageValue(entry.value),
      },
    };

Object? _timelineSelectionValue(NormalizedTimelineSnapshot value) => {
      'messageIds': value.messageIds.map((id) => id.toJson()).toList(),
      'canonicalMessages':
          value.canonicalMessages.map((item) => item.toJson()).toList(),
      'messages': value.messages.map((item) => item.toJson()).toList(),
      'pagination': value.pagination.toJson(),
      'replayCursor': value.replayCursor?.toJson(),
    };

Object? _listPageValue(NormalizedConversationListPage value) => {
      'requestCursor': value.requestCursor?.toJson(),
      'conversationIds':
          value.conversationIds.map((id) => id.toJson()).toList(),
      'nextCursor': value.nextCursor?.toJson(),
      'metadata': value.metadata.toJson(),
    };

Object? _listEntryValue(NormalizedConversationListEntry value) => {
      'scope': value.scope.toJson(),
      'conversationIds':
          value.conversationIds.map((id) => id.toJson()).toList(),
      'nextCursor': value.nextCursor?.toJson(),
      'metadata': value.metadata.toJson(),
      'pages': {
        for (final entry in value.pages.entries)
          entry.key: _listPageValue(entry.value),
      },
    };

Object? _timelineEntryValue(NormalizedTimelineEntry value) => {
      'messageIds': value.messageIds.map((id) => id.toJson()).toList(),
      'pagination': value.pagination.toJson(),
      'replayCursor': value.replayCursor?.toJson(),
    };

bool _sameValue(Object? left, Object? right) {
  if (identical(left, right) || left == right) return true;
  if (left is List<Object?> && right is List<Object?>) {
    return left.length == right.length &&
        List.generate(
                left.length, (index) => _sameValue(left[index], right[index]))
            .every((value) => value);
  }
  if (left is Map<Object?, Object?> && right is Map<Object?, Object?>) {
    if (left.length != right.length) return false;
    for (final entry in left.entries) {
      if (!right.containsKey(entry.key) ||
          !_sameValue(entry.value, right[entry.key])) {
        return false;
      }
    }
    return true;
  }
  return false;
}
