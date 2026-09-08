part of 'normalized_snapshot_state.dart';

_DurableMessageMutation _reduceDurableAttachment(
  NormalizedSnapshotState state,
  AttachmentUpdatedDurableEvent event,
) {
  final payload = event.payload.data;
  final conversationId = ConversationId.fromJson(payload['conversationId']);
  final messageId = MessageId.fromJson(payload['messageId']);
  final attachment = MessageAttachmentMetadata.fromJson(payload['attachment']);
  final conversation = state.conversations[conversationId];
  final message = state.canonicalMessages[messageId];
  final projection = state.messages[messageId];
  if (conversation == null) {
    _durableGap(event);
  }
  if (event.streamId != conversationId.value ||
      conversation.tenantId != event.tenantId) {
    _durableInvalid(event);
  }

  final existing = state.attachments[attachment.attachmentId];
  if (existing != null) {
    _validateDurableAttachmentTransition(existing, attachment, event);
  }
  final attachments =
      existing == null || !_sameValue(existing.toJson(), attachment.toJson())
          ? Map<AttachmentId, MessageAttachmentMetadata>.unmodifiable({
              ...state.attachments,
              attachment.attachmentId: attachment,
            })
          : state.attachments;

  // Metadata may lead its message on the same ordered stream. Retain it so
  // message creation can resolve attachment references without a snapshot.
  if (message == null && projection == null) {
    return _DurableMessageMutation(
      identical(attachments, state.attachments)
          ? state
          : _copyState(state, attachments: attachments),
    );
  }
  if (message == null ||
      projection == null ||
      message.tenantId != event.tenantId ||
      message.conversationId != conversationId ||
      projection.tenantId != event.tenantId ||
      projection.conversationId != conversationId ||
      projection.id != messageId) {
    _durableInvalid(event);
  }

  final canonicalReferences = message.content?.attachments ?? const [];
  final visibleReferences = projection.content?.attachments ?? const [];
  if (!canonicalReferences.any(
        (reference) => reference.attachmentId == attachment.attachmentId,
      ) ||
      !visibleReferences.any(
        (reference) => reference.attachmentId == attachment.attachmentId,
      )) {
    _durableGap(event);
  }
  for (final entry in state.messages.entries) {
    if (entry.key != messageId &&
        (entry.value.content?.attachments ?? const []).any(
          (reference) => reference.attachmentId == attachment.attachmentId,
        )) {
      _durableInvalid(event);
    }
  }

  final attachmentMetadata = <MessageAttachmentMetadata>[];
  for (final reference in visibleReferences) {
    final metadata = attachments[reference.attachmentId];
    if (metadata == null) _durableGap(event);
    attachmentMetadata.add(metadata);
  }

  var uploadMatchCount = 0;
  var attachmentUploads = state.attachmentUploads;
  for (final entry in state.attachmentUploads.entries) {
    final upload = entry.value;
    final lifecycle = upload.attachment;
    if (lifecycle?.attachmentId != attachment.attachmentId) continue;
    uploadMatchCount += 1;
    if (uploadMatchCount > 1 ||
        upload.conversationId != conversationId ||
        !_messageAttachmentMatchesUploadMetadata(
          attachment,
          upload.metadata,
        ) ||
        lifecycle is RejectedAttachmentState ||
        lifecycle is AbandonedAttachmentState) {
      _durableInvalid(event);
    }
    final settled = ChatAttachmentUploadState(
      uploadId: upload.uploadId,
      conversationId: upload.conversationId,
      metadata: upload.metadata,
      status: ChatAttachmentUploadStatus.attached,
      uploadedBytes: upload.uploadedBytes,
      attachment: lifecycle,
      messageAttachment: attachment,
    );
    if (!_sameValue(upload.toJson(), settled.toJson())) {
      attachmentUploads = Map<String, ChatAttachmentUploadState>.unmodifiable({
        ...attachmentUploads,
        entry.key: settled,
      });
    }
  }

  final updatedProjection = MessageTimelineMessage(
    message: projection.message,
    isThreadRoot: projection.isThreadRoot,
    reactions: projection.reactions,
    attachmentMetadata: attachmentMetadata,
  );
  return _DurableMessageMutation(
    _copyState(
      state,
      attachments: attachments,
      attachmentUploads: attachmentUploads,
      messages: _sameValue(projection.toJson(), updatedProjection.toJson())
          ? state.messages
          : Map<MessageId, MessageTimelineMessage>.unmodifiable({
              ...state.messages,
              messageId: updatedProjection,
            }),
    ),
  );
}

void _validateDurableAttachmentTransition(
  MessageAttachmentMetadata previous,
  MessageAttachmentMetadata next,
  AttachmentUpdatedDurableEvent event,
) {
  if (previous.attachmentId != next.attachmentId ||
      previous.fileName != next.fileName ||
      previous.contentType != next.contentType ||
      previous.sizeBytes != next.sizeBytes ||
      previous.downloadUrl != next.downloadUrl ||
      (previous.previewUrl != null && previous.previewUrl != next.previewUrl) ||
      (previous.width != null && previous.width != next.width) ||
      (previous.height != null && previous.height != next.height) ||
      (previous.altText != null && previous.altText != next.altText)) {
    _durableInvalid(event);
  }
}

_DurableMessageMutation _reduceDurableHuddle(
  NormalizedSnapshotState state,
  HuddleUpdatedDurableEvent event,
  void Function(HuddleSessionState state)? onHuddleUpdated,
) {
  final huddle = HuddleSessionState.fromJson(event.payload.data['state']);
  final conversation = state.conversations[huddle.conversationId];
  if (conversation == null) _durableGap(event);
  if (event.streamId != huddle.conversationId.value ||
      conversation.tenantId != event.tenantId) {
    _durableInvalid(event);
  }
  final existing = state.huddles[huddle.conversationId];
  if (existing == null &&
      huddle is! InactiveHuddleState &&
      huddle is! StartingHuddleState) {
    _durableGap(event);
  }
  if (existing != null) {
    _validateDurableHuddleTransition(existing, huddle, event);
  } else if (huddle is StartingHuddleState) {
    _validateEmptyStartingHuddle(huddle, event);
  }

  final unchanged =
      existing != null && _sameValue(existing.toJson(), huddle.toJson());
  return _DurableMessageMutation(
    unchanged
        ? state
        : _copyState(
            state,
            huddles: Map<ConversationId, HuddleSessionState>.unmodifiable({
              ...state.huddles,
              huddle.conversationId: huddle,
            }),
          ),
    onHuddleUpdated == null ? null : () => onHuddleUpdated(huddle),
  );
}

void _validateDurableHuddleTransition(
  HuddleSessionState previous,
  HuddleSessionState next,
  HuddleUpdatedDurableEvent event,
) {
  if (previous.conversationId != next.conversationId) {
    _durableInvalid(event);
  }
  if (previous is InactiveHuddleState) {
    if (next is InactiveHuddleState) return;
    if (next is StartingHuddleState) {
      _validateEmptyStartingHuddle(next, event);
      return;
    }
    _durableInvalid(event);
  }

  if (previous is EndedHuddleState) {
    if (next is EndedHuddleState) {
      if (!_sameValue(previous.toJson(), next.toJson())) {
        _durableInvalid(event);
      }
      return;
    }
    if (next is StartingHuddleState &&
        next.huddleSessionId != previous.huddleSessionId &&
        !DateTime.parse(next.startedAt.value)
            .isBefore(DateTime.parse(previous.endedAt.value))) {
      _validateEmptyStartingHuddle(next, event);
      return;
    }
    _durableInvalid(event);
  }

  final previousLive = previous as LiveHuddleState;
  if (next is! LiveHuddleState && next is! EndedHuddleState) {
    _durableInvalid(event);
  }
  final nextSessionId = switch (next) {
    LiveHuddleState state => state.huddleSessionId,
    EndedHuddleState state => state.huddleSessionId,
    _ => throw StateError('unreachable huddle state'),
  };
  final nextStartedAt = switch (next) {
    LiveHuddleState state => state.startedAt,
    EndedHuddleState state => state.startedAt,
    _ => throw StateError('unreachable huddle state'),
  };
  if (previousLive.huddleSessionId != nextSessionId ||
      previousLive.startedAt != nextStartedAt) {
    _durableInvalid(event);
  }
  if (previous is StartingHuddleState) {
    if (next is StartingHuddleState) {
      if (!_sameValue(previous.toJson(), next.toJson())) {
        _durableInvalid(event);
      }
      return;
    }
  } else if (previous is ActiveHuddleState && next is StartingHuddleState) {
    _durableInvalid(event);
  }
  _validateDurableParticipantSnapshot(previousLive, next, event);
}

void _validateEmptyStartingHuddle(
  StartingHuddleState state,
  HuddleUpdatedDurableEvent event,
) {
  if (state.participants.isNotEmpty || state.screenShareOwnerUserId != null) {
    _durableInvalid(event);
  }
}

void _validateDurableParticipantSnapshot(
  LiveHuddleState previous,
  HuddleSessionState next,
  HuddleUpdatedDurableEvent event,
) {
  final nextParticipants = switch (next) {
    LiveHuddleState state => state.participants,
    EndedHuddleState state => state.participants,
    _ => throw StateError('unreachable huddle state'),
  };
  final previousByUser = {
    for (final participant in previous.participants)
      participant.userId: participant,
  };
  final nextByUser = {
    for (final participant in nextParticipants) participant.userId: participant,
  };
  if (!nextByUser.keys.toSet().containsAll(previousByUser.keys)) {
    _durableInvalid(event);
  }
  for (final entry in previousByUser.entries) {
    final incoming = nextByUser[entry.key]!;
    final prior = entry.value;
    // A renewed join must follow the departure, not replay the old join.
    if (previous is ActiveHuddleState &&
        next is ActiveHuddleState &&
        prior is HuddleLeftParticipant &&
        incoming is HuddleJoinedParticipant &&
        DateTime.parse(incoming.joinedAt.value)
            .isAfter(DateTime.parse(prior.leftAt.value))) {
      continue;
    }
    if (entry.value.joinedAt != incoming.joinedAt ||
        (entry.value is HuddleLeftParticipant &&
            (incoming is! HuddleLeftParticipant ||
                incoming.leftAt !=
                    (entry.value as HuddleLeftParticipant).leftAt))) {
      _durableInvalid(event);
    }
  }
  for (final entry in nextByUser.entries) {
    if (!previousByUser.containsKey(entry.key) &&
        entry.value is HuddleLeftParticipant) {
      _durableInvalid(event);
    }
  }
  if (next is EndedHuddleState && nextByUser.length != previousByUser.length) {
    _durableInvalid(event);
  }
}
