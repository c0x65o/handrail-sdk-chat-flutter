import 'dart:async';

import 'core/attachment_upload_manager.dart'
    show ChatAttachmentTemporaryResource;
import 'generated/attachment_transport.dart' show AttachmentMetadata;
import 'generated/conversation.dart' show HostEntityReference;
import 'generated/identifiers.dart'
    show AttachmentId, ConversationId, MessageId, UserId;
import 'generated/message_timeline.dart' show MessageAttachmentMetadata;
import 'message_search.dart' show HandrailMessageSearchHit;

/// The outcome of a host-controlled application action.
///
/// Errors are deliberately not represented here. A synchronous exception or a
/// failed future from a host delegate is allowed to propagate to the caller.
enum ChatApplicationDelegateResult {
  /// The host handled the requested behavior.
  handled,

  /// The host presented or began the behavior and the user cancelled it.
  cancelled,

  /// The behavior is not available in the current host application.
  unavailable,
}

/// The result of asking the host application to pick attachments.
sealed class ChatAttachmentPickerResult {
  const ChatAttachmentPickerResult();
}

/// Attachment identifiers selected and prepared by the host application.
///
/// The identifiers are copied into an unmodifiable list. They identify
/// attachments that the host has made ready for the chat composer; this
/// contract intentionally does not prescribe a file picker or upload API.
final class ChatAttachmentPickerSelection extends ChatAttachmentPickerResult {
  ChatAttachmentPickerSelection(Iterable<AttachmentId> attachmentIds)
      : attachmentIds = List<AttachmentId>.unmodifiable(attachmentIds) {
    if (this.attachmentIds.isEmpty) {
      throw ArgumentError.value(
        attachmentIds,
        'attachmentIds',
        'A selection must contain at least one attachment.',
      );
    }
  }

  final List<AttachmentId> attachmentIds;
}

/// One host-selected attachment whose bytes should be uploaded by chat.
///
/// The host owns file selection and supplies a finite, single-use byte stream.
/// The composer passes this value to the public attachment upload command; it
/// never selects a platform picker or reads a platform file itself.
final class ChatAttachmentUploadSource {
  ChatAttachmentUploadSource({
    required AttachmentMetadata metadata,
    required this.source,
    this.temporaryResource,
  }) : metadata = AttachmentMetadata.fromJson(metadata.toJson());

  final AttachmentMetadata metadata;
  final Stream<List<int>> source;
  final ChatAttachmentTemporaryResource? temporaryResource;
}

/// Host-selected byte sources that the composer should upload.
final class ChatAttachmentPickerUploadSelection
    extends ChatAttachmentPickerResult {
  ChatAttachmentPickerUploadSelection(
    Iterable<ChatAttachmentUploadSource> uploads,
  ) : uploads = List<ChatAttachmentUploadSource>.unmodifiable(uploads) {
    if (this.uploads.isEmpty) {
      throw ArgumentError.value(
        uploads,
        'uploads',
        'An upload selection must contain at least one attachment.',
      );
    }
  }

  final List<ChatAttachmentUploadSource> uploads;
}

/// The user cancelled attachment selection in the host application.
final class ChatAttachmentPickerCancelled extends ChatAttachmentPickerResult {
  const ChatAttachmentPickerCancelled();
}

/// Attachment selection is not available in the host application.
final class ChatAttachmentPickerUnavailable extends ChatAttachmentPickerResult {
  const ChatAttachmentPickerUnavailable();
}

typedef ChatOpenUserDelegate = Future<ChatApplicationDelegateResult> Function(
  UserId userId,
);
typedef ChatOpenEntityDelegate = Future<ChatApplicationDelegateResult> Function(
    HostEntityReference reference);
typedef ChatOpenThreadDelegate = Future<ChatApplicationDelegateResult> Function(
  ConversationId threadId,
);
typedef ChatPickAttachmentDelegate = Future<ChatAttachmentPickerResult>
    Function();
typedef ChatOpenAttachmentDelegate = Future<ChatApplicationDelegateResult>
    Function(MessageAttachmentMetadata attachment);
typedef ChatReportMessageDelegate = Future<ChatApplicationDelegateResult>
    Function(MessageId messageId);
typedef ChatShowNotificationSettingsDelegate
    = Future<ChatApplicationDelegateResult> Function();
typedef ChatOpenExternalLinkDelegate = Future<ChatApplicationDelegateResult>
    Function(Uri uri);
typedef ChatOpenMessageSearchHitDelegate = Future<ChatApplicationDelegateResult>
    Function(
  HandrailMessageSearchHit hit,
);

/// Immutable, router-neutral hooks for behavior owned by a host application.
///
/// Every delegate is optional. Calling an omitted action returns
/// [ChatApplicationDelegateResult.unavailable], or
/// [ChatAttachmentPickerUnavailable] for attachment selection, without
/// navigating, launching a URL, opening a picker, or invoking platform APIs.
/// Host exceptions and failed futures are not caught or converted to a result.
final class ChatApplicationDelegates {
  const ChatApplicationDelegates({
    ChatOpenUserDelegate? openUser,
    ChatOpenEntityDelegate? openEntity,
    ChatOpenThreadDelegate? openThread,
    ChatPickAttachmentDelegate? pickAttachment,
    ChatOpenAttachmentDelegate? openAttachment,
    ChatReportMessageDelegate? reportMessage,
    ChatShowNotificationSettingsDelegate? showNotificationSettings,
    ChatOpenExternalLinkDelegate? openExternalLink,
    ChatOpenMessageSearchHitDelegate? openMessageSearchHit,
  })  : _openUser = openUser,
        _openEntity = openEntity,
        _openThread = openThread,
        _pickAttachment = pickAttachment,
        _openAttachment = openAttachment,
        _reportMessage = reportMessage,
        _showNotificationSettings = showNotificationSettings,
        _openExternalLink = openExternalLink,
        _openMessageSearchHit = openMessageSearchHit;

  final ChatOpenUserDelegate? _openUser;
  final ChatOpenEntityDelegate? _openEntity;
  final ChatOpenThreadDelegate? _openThread;
  final ChatPickAttachmentDelegate? _pickAttachment;
  final ChatOpenAttachmentDelegate? _openAttachment;
  final ChatReportMessageDelegate? _reportMessage;
  final ChatShowNotificationSettingsDelegate? _showNotificationSettings;
  final ChatOpenExternalLinkDelegate? _openExternalLink;
  final ChatOpenMessageSearchHitDelegate? _openMessageSearchHit;

  Future<ChatApplicationDelegateResult> openUser(UserId userId) async {
    final delegate = _openUser;
    if (delegate == null) return ChatApplicationDelegateResult.unavailable;
    return delegate(userId);
  }

  Future<ChatApplicationDelegateResult> openEntity(
    HostEntityReference reference,
  ) async {
    final delegate = _openEntity;
    if (delegate == null) return ChatApplicationDelegateResult.unavailable;
    return delegate(reference);
  }

  Future<ChatApplicationDelegateResult> openThread(
    ConversationId threadId,
  ) async {
    final delegate = _openThread;
    if (delegate == null) return ChatApplicationDelegateResult.unavailable;
    return delegate(threadId);
  }

  Future<ChatAttachmentPickerResult> pickAttachment() async {
    final delegate = _pickAttachment;
    if (delegate == null) return const ChatAttachmentPickerUnavailable();
    return delegate();
  }

  Future<ChatApplicationDelegateResult> openAttachment(
    MessageAttachmentMetadata attachment,
  ) async {
    final delegate = _openAttachment;
    if (delegate == null) return ChatApplicationDelegateResult.unavailable;
    return delegate(attachment);
  }

  Future<ChatApplicationDelegateResult> reportMessage(
    MessageId messageId,
  ) async {
    final delegate = _reportMessage;
    if (delegate == null) return ChatApplicationDelegateResult.unavailable;
    return delegate(messageId);
  }

  Future<ChatApplicationDelegateResult> showNotificationSettings() async {
    final delegate = _showNotificationSettings;
    if (delegate == null) return ChatApplicationDelegateResult.unavailable;
    return delegate();
  }

  Future<ChatApplicationDelegateResult> openExternalLink(Uri uri) async {
    final delegate = _openExternalLink;
    if (delegate == null) return ChatApplicationDelegateResult.unavailable;
    return delegate(uri);
  }

  /// Asks the host router to open a typed conversation or message search hit.
  Future<ChatApplicationDelegateResult> openMessageSearchHit(
    HandrailMessageSearchHit hit,
  ) async {
    final delegate = _openMessageSearchHit;
    if (delegate == null) return ChatApplicationDelegateResult.unavailable;
    return delegate(hit);
  }
}
