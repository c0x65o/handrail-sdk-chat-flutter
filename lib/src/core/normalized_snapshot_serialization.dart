part of 'normalized_snapshot_state.dart';

/// Closed-schema codec used by application-owned persistence adapters.
abstract final class NormalizedSnapshotStateStorageCodec {
  static Map<String, Object?> encode(NormalizedSnapshotState state) => {
        'conversations': [
          for (final value in state.conversations.values) value.toJson(),
        ],
        'canonicalMessages': [
          for (final value in state.canonicalMessages.values) value.toJson(),
        ],
        'messages': [
          for (final value in state.messages.values) value.toJson(),
        ],
        'membersByConversation': [
          for (final entry in state.membersByConversation.entries)
            {
              'conversationId': entry.key.toJson(),
              'members': [
                for (final member in entry.value.values) member.toJson(),
              ],
            },
        ],
        'memberUserIdsByConversation': [
          for (final entry in state.memberUserIdsByConversation.entries)
            {
              'conversationId': entry.key.toJson(),
              'userIds': [for (final id in entry.value) id.toJson()],
            },
        ],
        'lifecycleRevisions': [
          for (final entry in state.lifecycleRevisions.entries)
            {
              'conversationId': entry.key.toJson(),
              'revision': entry.value,
            },
        ],
        'lifecycleArchivedStates': [
          for (final entry in state.lifecycleArchivedStates.entries)
            {
              'conversationId': entry.key.toJson(),
              'archived': entry.value,
            },
        ],
        'memberListRevisions': [
          for (final entry in state.memberListRevisions.entries)
            {
              'conversationId': entry.key.toJson(),
              'revision': entry.value,
            },
        ],
        'currentUserReadStates': [
          for (final value in state.authoritativeCurrentUserReadStates.values)
            value.toJson(),
        ],
        'currentUserPreferences': [
          for (final value in state.authoritativeCurrentUserPreferences.values)
            value.toJson(),
        ],
        'preferenceRevisions': [
          for (final entry in state.preferenceRevisions.entries)
            {
              'conversationId': entry.key.toJson(),
              'revision': entry.value,
            },
        ],
        'threadFollows': [
          for (final value
              in state.authoritativeCurrentUserThreadFollows.values)
            value.toJson(),
        ],
        'threadFollowRevisions': [
          for (final entry in state.threadFollowRevisions.entries)
            {
              'conversationId': entry.key.toJson(),
              'revision': entry.value,
            },
        ],
        'savedMessages': [
          for (final entry in state.currentUserSavedMessages.entries)
            {
              'messageId': entry.key.toJson(),
              'savedMessageRevision': state.savedMessageRevisions[entry.key]!,
              'savedMessage': entry.value.toJson(),
            },
        ],
        'messageReminders': [
          for (final entry
              in state.authoritativeCurrentUserMessageReminders.entries)
            {
              'conversationId':
                  state.messageReminderConversationIds[entry.key]!.toJson(),
              'messageId': entry.key.toJson(),
              'reminderRevision': state.messageReminderRevisions[entry.key]!,
              'reminder': entry.value.toJson(),
            },
        ],
        'drafts': [
          for (final entry in state.currentUserDrafts.entries)
            {
              'conversationId': entry.key.toJson(),
              'draftRevision': state.draftRevisions[entry.key]!,
              'draft': entry.value.toJson(),
            },
        ],
        'conversationMetadata': [
          for (final entry in state.conversationMetadata.entries)
            {
              'conversationId': entry.key.toJson(),
              'latestSequence': entry.value.latestSequence.toJson(),
              'activityAt': entry.value.activityAt.toJson(),
            },
        ],
        'durableStreams': [
          for (final entry in state.durableStreams.entries)
            {
              'streamId': entry.key,
              'lastEventId': entry.value.lastEventId,
              'lastOccurredAt': entry.value.lastOccurredAt.toJson(),
              'recentEventIds': entry.value.recentEventIds,
            },
        ],
        'conversationLists': [
          for (final entry in state.conversationLists.entries)
            {
              'key': entry.key,
              'scope': entry.value.scope.toJson(),
              'conversationIds': [
                for (final id in entry.value.conversationIds) id.toJson(),
              ],
              'nextCursor': entry.value.nextCursor?.toJson(),
              'metadata': entry.value.metadata.toJson(),
              'pages': [
                for (final page in entry.value.pages.entries)
                  {
                    'key': page.key,
                    'requestCursor': page.value.requestCursor?.toJson(),
                    'conversationIds': [
                      for (final id in page.value.conversationIds) id.toJson(),
                    ],
                    'nextCursor': page.value.nextCursor?.toJson(),
                    'metadata': page.value.metadata.toJson(),
                  },
              ],
            },
        ],
        'conversationDetails': [
          for (final entry in state.conversationDetails.entries)
            {
              'conversationId': entry.key.toJson(),
              'metadata': entry.value.toJson(),
            },
        ],
        'timelines': [
          for (final entry in state.timelines.entries)
            {
              'conversationId': entry.key.toJson(),
              'messageIds': [
                for (final id in entry.value.messageIds) id.toJson(),
              ],
              'pagination': entry.value.pagination.toJson(),
              'replayCursor': entry.value.replayCursor?.toJson(),
            },
        ],
        'attachments': [
          for (final value in state.attachments.values) value.toJson(),
        ],
        'attachmentUploads': [
          for (final value in state.attachmentUploads.values) value.toJson(),
        ],
        'huddles': [
          for (final value in state.huddles.values) value.toJson(),
        ],
        'latestReplayCursor': state.latestReplayCursor?.toJson(),
      };

  static NormalizedSnapshotState decode(Object? json) {
    final decoded = _storageObject(json, 'NormalizedSnapshotState');
    final hasStoredAttachments = decoded.containsKey('attachments');
    final object = <String, Object?>{
      ...decoded,
      if (!decoded.containsKey('attachmentUploads'))
        'attachmentUploads': const <Object?>[],
      if (!decoded.containsKey('attachments')) 'attachments': const <Object?>[],
      if (!decoded.containsKey('huddles')) 'huddles': const <Object?>[],
      if (!decoded.containsKey('preferenceRevisions'))
        'preferenceRevisions': const <Object?>[],
      if (!decoded.containsKey('threadFollows'))
        'threadFollows': const <Object?>[],
      if (!decoded.containsKey('threadFollowRevisions'))
        'threadFollowRevisions': const <Object?>[],
      if (!decoded.containsKey('messageReminders'))
        'messageReminders': const <Object?>[],
      if (!decoded.containsKey('savedMessages'))
        'savedMessages': const <Object?>[],
      if (!decoded.containsKey('drafts')) 'drafts': const <Object?>[],
      if (!decoded.containsKey('lifecycleArchivedStates'))
        'lifecycleArchivedStates': const <Object?>[],
      if (!decoded.containsKey('durableStreams'))
        'durableStreams': const <Object?>[],
    };
    _storageFields(
      object,
      const {
        'conversations',
        'canonicalMessages',
        'messages',
        'membersByConversation',
        'memberUserIdsByConversation',
        'lifecycleRevisions',
        'lifecycleArchivedStates',
        'memberListRevisions',
        'currentUserReadStates',
        'currentUserPreferences',
        'preferenceRevisions',
        'threadFollows',
        'threadFollowRevisions',
        'savedMessages',
        'messageReminders',
        'drafts',
        'conversationMetadata',
        'durableStreams',
        'conversationLists',
        'conversationDetails',
        'timelines',
        'attachments',
        'attachmentUploads',
        'huddles',
        'latestReplayCursor',
      },
      'NormalizedSnapshotState',
    );

    final conversations = <ConversationId, Conversation>{};
    for (final json in _storageRequiredList(
      object,
      'conversations',
      'NormalizedSnapshotState',
    )) {
      final value = Conversation.fromJson(json);
      _storageAddUnique(
        conversations,
        value.id,
        value,
        'NormalizedSnapshotState.conversations',
      );
    }

    final canonicalMessages = <MessageId, Message>{};
    for (final json in _storageRequiredList(
      object,
      'canonicalMessages',
      'NormalizedSnapshotState',
    )) {
      final value = Message.fromJson(json);
      _storageAddUnique(
        canonicalMessages,
        value.id,
        value,
        'NormalizedSnapshotState.canonicalMessages',
      );
    }

    final messages = <MessageId, MessageTimelineMessage>{};
    for (final json in _storageRequiredList(
      object,
      'messages',
      'NormalizedSnapshotState',
    )) {
      final value = MessageTimelineMessage.fromJson(json);
      _storageAddUnique(
        messages,
        value.id,
        value,
        'NormalizedSnapshotState.messages',
      );
    }

    final membersByConversation =
        <ConversationId, Map<UserId, ConversationSnapshotMember>>{};
    for (final json in _storageRequiredList(
      object,
      'membersByConversation',
      'NormalizedSnapshotState',
    )) {
      final entry = _storageObject(json, 'MembersByConversationEntry');
      _storageFields(
        entry,
        const {'conversationId', 'members'},
        'MembersByConversationEntry',
      );
      final conversationId = ConversationId.fromJson(entry['conversationId']);
      final members = <UserId, ConversationSnapshotMember>{};
      for (final memberJson in _storageList(
        entry['members'],
        'MembersByConversationEntry.members',
      )) {
        final member = ConversationSnapshotMember.fromJson(memberJson);
        if (member.conversationId != conversationId) {
          throw const FormatException(
            'Stored member has a mismatched conversation identity.',
          );
        }
        _storageAddUnique(
          members,
          member.userId,
          member,
          'MembersByConversationEntry.members',
        );
      }
      _storageAddUnique(
        membersByConversation,
        conversationId,
        Map<UserId, ConversationSnapshotMember>.unmodifiable(members),
        'NormalizedSnapshotState.membersByConversation',
      );
    }

    final memberUserIdsByConversation = <ConversationId, List<UserId>>{};
    for (final json in _storageRequiredList(
      object,
      'memberUserIdsByConversation',
      'NormalizedSnapshotState',
    )) {
      final entry = _storageObject(json, 'MemberUserIdsEntry');
      _storageFields(
        entry,
        const {'conversationId', 'userIds'},
        'MemberUserIdsEntry',
      );
      final conversationId = ConversationId.fromJson(entry['conversationId']);
      final userIds = <UserId>[];
      final seen = <UserId>{};
      for (final userIdJson in _storageList(
        entry['userIds'],
        'MemberUserIdsEntry.userIds',
      )) {
        final userId = UserId.fromJson(userIdJson);
        if (!seen.add(userId)) {
          throw const FormatException('Stored member user IDs repeat.');
        }
        userIds.add(userId);
      }
      _storageAddUnique(
        memberUserIdsByConversation,
        conversationId,
        List<UserId>.unmodifiable(userIds),
        'NormalizedSnapshotState.memberUserIdsByConversation',
      );
    }

    final currentUserReadStates =
        <ConversationId, ConversationSnapshotReadState>{};

    final lifecycleRevisions = <ConversationId, int>{};
    final storedLifecycleRevisions = object['lifecycleRevisions'];
    if (storedLifecycleRevisions != null) {
      for (final json in _storageList(
        storedLifecycleRevisions,
        'NormalizedSnapshotState.lifecycleRevisions',
      )) {
        final entry = _storageObject(json, 'LifecycleRevisionEntry');
        _storageFields(
          entry,
          const {'conversationId', 'revision'},
          'LifecycleRevisionEntry',
        );
        final revision = entry['revision'];
        if (revision is! int || revision < 1 || revision > 9007199254740991) {
          throw const FormatException('Stored lifecycle revision is invalid.');
        }
        _storageAddUnique(
          lifecycleRevisions,
          ConversationId.fromJson(entry['conversationId']),
          revision,
          'NormalizedSnapshotState.lifecycleRevisions',
        );
      }
    }

    final lifecycleArchivedStates = <ConversationId, bool>{
      for (final entry in conversations.entries)
        entry.key: entry.value.archivedAt != null,
    };
    for (final json in _storageRequiredList(
      object,
      'lifecycleArchivedStates',
      'NormalizedSnapshotState',
    )) {
      final entry = _storageObject(json, 'LifecycleArchivedStateEntry');
      _storageFields(
        entry,
        const {'conversationId', 'archived'},
        'LifecycleArchivedStateEntry',
      );
      final archived = entry['archived'];
      if (archived is! bool) {
        throw const FormatException(
          'Stored lifecycle archived state is invalid.',
        );
      }
      lifecycleArchivedStates[
          ConversationId.fromJson(entry['conversationId'])] = archived;
    }

    final memberListRevisions = <ConversationId, int>{};
    final storedMemberListRevisions = object['memberListRevisions'];
    if (storedMemberListRevisions != null) {
      for (final json in _storageList(
        storedMemberListRevisions,
        'NormalizedSnapshotState.memberListRevisions',
      )) {
        final entry = _storageObject(json, 'MemberListRevisionEntry');
        _storageFields(
          entry,
          const {'conversationId', 'revision'},
          'MemberListRevisionEntry',
        );
        final revision = entry['revision'];
        if (revision is! int || revision < 1 || revision > 9007199254740991) {
          throw const FormatException(
              'Stored member-list revision is invalid.');
        }
        _storageAddUnique(
          memberListRevisions,
          ConversationId.fromJson(entry['conversationId']),
          revision,
          'NormalizedSnapshotState.memberListRevisions',
        );
      }
    }

    for (final json in _storageRequiredList(
      object,
      'currentUserReadStates',
      'NormalizedSnapshotState',
    )) {
      final value = ConversationSnapshotReadState.fromJson(json);
      _storageAddUnique(
        currentUserReadStates,
        value.conversationId,
        value,
        'NormalizedSnapshotState.currentUserReadStates',
      );
    }

    final currentUserPreferences =
        <ConversationId, ConversationSnapshotPreference>{};
    for (final json in _storageRequiredList(
      object,
      'currentUserPreferences',
      'NormalizedSnapshotState',
    )) {
      final value = ConversationSnapshotPreference.fromJson(json);
      _storageAddUnique(
        currentUserPreferences,
        value.conversationId,
        value,
        'NormalizedSnapshotState.currentUserPreferences',
      );
    }

    final preferenceRevisions = <ConversationId, int>{};
    for (final json in _storageRequiredList(
      object,
      'preferenceRevisions',
      'NormalizedSnapshotState',
    )) {
      final entry = _storageObject(json, 'PreferenceRevisionEntry');
      _storageFields(
        entry,
        const {'conversationId', 'revision'},
        'PreferenceRevisionEntry',
      );
      final revision = entry['revision'];
      if (revision is! int || revision < 0 || revision > 9007199254740991) {
        throw const FormatException('Stored preference revision is invalid.');
      }
      _storageAddUnique(
        preferenceRevisions,
        ConversationId.fromJson(entry['conversationId']),
        revision,
        'NormalizedSnapshotState.preferenceRevisions',
      );
    }

    final threadFollows = <ConversationId, CanonicalThreadFollowState>{};
    for (final json in _storageRequiredList(
      object,
      'threadFollows',
      'NormalizedSnapshotState',
    )) {
      final value = CanonicalThreadFollowState.fromJson(json);
      _storageAddUnique(
        threadFollows,
        value.target.id,
        value,
        'NormalizedSnapshotState.threadFollows',
      );
    }
    final threadFollowRevisions = <ConversationId, int>{};
    for (final json in _storageRequiredList(
      object,
      'threadFollowRevisions',
      'NormalizedSnapshotState',
    )) {
      final entry = _storageObject(json, 'ThreadFollowRevisionEntry');
      _storageFields(
        entry,
        const {'conversationId', 'revision'},
        'ThreadFollowRevisionEntry',
      );
      final revision = entry['revision'];
      if (revision is! int || revision < 1 || revision > 9007199254740991) {
        throw const FormatException(
            'Stored thread follow revision is invalid.');
      }
      _storageAddUnique(
        threadFollowRevisions,
        ConversationId.fromJson(entry['conversationId']),
        revision,
        'NormalizedSnapshotState.threadFollowRevisions',
      );
    }

    final savedMessages = <MessageId, CanonicalActorPrivateSavedMessageState>{};
    final savedMessageRevisions = <MessageId, int>{};
    for (final json in _storageRequiredList(
      object,
      'savedMessages',
      'NormalizedSnapshotState',
    )) {
      final entry = _storageObject(json, 'SavedMessageEntry');
      _storageFields(
        entry,
        const {'messageId', 'savedMessageRevision', 'savedMessage'},
        'SavedMessageEntry',
      );
      final messageId = MessageId.fromJson(entry['messageId']);
      final revision = entry['savedMessageRevision'];
      final savedMessage = CanonicalActorPrivateSavedMessageState.fromJson(
        entry['savedMessage'],
      );
      if (revision is! int ||
          revision < 1 ||
          revision > 9007199254740991 ||
          savedMessage.messageId != messageId) {
        throw const FormatException('Stored saved-message state is invalid.');
      }
      _storageAddUnique(
        savedMessages,
        messageId,
        savedMessage,
        'NormalizedSnapshotState.savedMessages',
      );
      _storageAddUnique(
        savedMessageRevisions,
        messageId,
        revision,
        'NormalizedSnapshotState.savedMessageRevisions',
      );
    }

    final messageReminders = <MessageId, CanonicalMessageReminder>{};
    final messageReminderConversationIds = <MessageId, ConversationId>{};
    final messageReminderRevisions = <MessageId, int>{};
    for (final json in _storageRequiredList(
      object,
      'messageReminders',
      'NormalizedSnapshotState',
    )) {
      final entry = _storageObject(json, 'MessageReminderEntry');
      _storageFields(
        entry,
        const {
          'conversationId',
          'messageId',
          'reminderRevision',
          'reminder',
        },
        'MessageReminderEntry',
      );
      final messageId = MessageId.fromJson(entry['messageId']);
      final revision = entry['reminderRevision'];
      if (revision is! int || revision < 0 || revision > 9007199254740991) {
        throw const FormatException('Stored reminder revision is invalid.');
      }
      _storageAddUnique(
        messageReminders,
        messageId,
        CanonicalMessageReminder.fromJson(entry['reminder']),
        'NormalizedSnapshotState.messageReminders',
      );
      _storageAddUnique(
        messageReminderConversationIds,
        messageId,
        ConversationId.fromJson(entry['conversationId']),
        'NormalizedSnapshotState.messageReminderConversationIds',
      );
      _storageAddUnique(
        messageReminderRevisions,
        messageId,
        revision,
        'NormalizedSnapshotState.messageReminderRevisions',
      );
    }

    final drafts = <ConversationId, CanonicalDraftState>{};
    final draftRevisions = <ConversationId, int>{};
    for (final json in _storageRequiredList(
      object,
      'drafts',
      'NormalizedSnapshotState',
    )) {
      final entry = _storageObject(json, 'DraftEntry');
      _storageFields(
        entry,
        const {'conversationId', 'draftRevision', 'draft'},
        'DraftEntry',
      );
      final conversationId = ConversationId.fromJson(entry['conversationId']);
      final revision = entry['draftRevision'];
      if (revision is! int || revision < 1 || revision > 9007199254740991) {
        throw const FormatException('Stored draft revision is invalid.');
      }
      _storageAddUnique(
        drafts,
        conversationId,
        CanonicalDraftState.fromJson(entry['draft']),
        'NormalizedSnapshotState.drafts',
      );
      _storageAddUnique(
        draftRevisions,
        conversationId,
        revision,
        'NormalizedSnapshotState.draftRevisions',
      );
    }

    final conversationMetadata =
        <ConversationId, NormalizedConversationMetadata>{};
    for (final json in _storageRequiredList(
      object,
      'conversationMetadata',
      'NormalizedSnapshotState',
    )) {
      final entry = _storageObject(json, 'ConversationMetadataEntry');
      _storageFields(
        entry,
        const {'conversationId', 'latestSequence', 'activityAt'},
        'ConversationMetadataEntry',
      );
      final conversationId = ConversationId.fromJson(entry['conversationId']);
      _storageAddUnique(
        conversationMetadata,
        conversationId,
        NormalizedConversationMetadata(
          latestSequence: MessageSequence.fromJson(entry['latestSequence']),
          activityAt: IsoTimestamp.fromJson(entry['activityAt']),
        ),
        'NormalizedSnapshotState.conversationMetadata',
      );
    }

    final conversationLists = <String, NormalizedConversationListEntry>{};

    final durableStreams = <String, DurableStreamMetadata>{};
    for (final json in _storageRequiredList(
      object,
      'durableStreams',
      'NormalizedSnapshotState',
    )) {
      final entry = _storageObject(json, 'DurableStreamEntry');
      _storageFields(
        entry,
        const {
          'streamId',
          'lastEventId',
          'lastOccurredAt',
          'recentEventIds',
        },
        'DurableStreamEntry',
      );
      final streamId = _storageString(
        entry['streamId'],
        'DurableStreamEntry.streamId',
      );
      final recentEventIds = _storageList(
        entry['recentEventIds'],
        'DurableStreamEntry.recentEventIds',
      )
          .map((value) => _storageString(
                value,
                'DurableStreamEntry.recentEventIds',
              ))
          .toList(growable: false);
      _storageAddUnique(
        durableStreams,
        streamId,
        DurableStreamMetadata(
          lastEventId: _storageString(
            entry['lastEventId'],
            'DurableStreamEntry.lastEventId',
          ),
          lastOccurredAt: IsoTimestamp.fromJson(entry['lastOccurredAt']),
          recentEventIds: recentEventIds,
        ),
        'NormalizedSnapshotState.durableStreams',
      );
    }

    for (final json in _storageRequiredList(
      object,
      'conversationLists',
      'NormalizedSnapshotState',
    )) {
      final parsed = _decodeConversationListEntry(json);
      _storageAddUnique(
        conversationLists,
        parsed.key,
        parsed.value,
        'NormalizedSnapshotState.conversationLists',
      );
    }

    final conversationDetails =
        <ConversationId, ConversationSnapshotMetadata>{};
    for (final json in _storageRequiredList(
      object,
      'conversationDetails',
      'NormalizedSnapshotState',
    )) {
      final entry = _storageObject(json, 'ConversationDetailEntry');
      _storageFields(
        entry,
        const {'conversationId', 'metadata'},
        'ConversationDetailEntry',
      );
      _storageAddUnique(
        conversationDetails,
        ConversationId.fromJson(entry['conversationId']),
        ConversationSnapshotMetadata.fromJson(entry['metadata']),
        'NormalizedSnapshotState.conversationDetails',
      );
    }

    final timelines = <ConversationId, NormalizedTimelineEntry>{};
    for (final json in _storageRequiredList(
      object,
      'timelines',
      'NormalizedSnapshotState',
    )) {
      final parsed = _decodeTimelineEntry(json, canonicalMessages);
      _storageAddUnique(
        timelines,
        parsed.key,
        parsed.value,
        'NormalizedSnapshotState.timelines',
      );
    }

    final attachmentUploads = <String, ChatAttachmentUploadState>{};
    for (final json in _storageRequiredList(
      object,
      'attachmentUploads',
      'NormalizedSnapshotState',
    )) {
      final upload = ChatAttachmentUploadState.fromJson(json);
      _storageAddUnique(
        attachmentUploads,
        upload.uploadId,
        upload,
        'NormalizedSnapshotState.attachmentUploads',
      );
    }

    final attachments = <AttachmentId, MessageAttachmentMetadata>{};
    for (final json in _storageRequiredList(
      object,
      'attachments',
      'NormalizedSnapshotState',
    )) {
      final metadata = MessageAttachmentMetadata.fromJson(json);
      _storageAddUnique(
        attachments,
        metadata.attachmentId,
        metadata,
        'NormalizedSnapshotState.attachments',
      );
    }
    if (!hasStoredAttachments) {
      for (final message in messages.values) {
        for (final metadata in message.attachmentMetadata) {
          final existing = attachments[metadata.attachmentId];
          if (existing != null &&
              !_sameValue(existing.toJson(), metadata.toJson())) {
            throw const FormatException(
              'Stored messages contain conflicting attachment metadata.',
            );
          }
          attachments[metadata.attachmentId] = metadata;
        }
      }
    }

    final huddles = <ConversationId, HuddleSessionState>{};
    for (final json in _storageRequiredList(
      object,
      'huddles',
      'NormalizedSnapshotState',
    )) {
      final huddle = HuddleSessionState.fromJson(json);
      _storageAddUnique(
        huddles,
        huddle.conversationId,
        huddle,
        'NormalizedSnapshotState.huddles',
      );
    }

    _validateNormalizedReferences(
      conversations: conversations,
      canonicalMessages: canonicalMessages,
      messages: messages,
      membersByConversation: membersByConversation,
      memberUserIdsByConversation: memberUserIdsByConversation,
      currentUserReadStates: currentUserReadStates,
      currentUserPreferences: currentUserPreferences,
      conversationMetadata: conversationMetadata,
      conversationLists: conversationLists,
      conversationDetails: conversationDetails,
      timelines: timelines,
      attachments: attachments,
      huddles: huddles,
    );

    final latestReplayCursorJson = object['latestReplayCursor'];
    return NormalizedSnapshotState._(
      conversations: conversations,
      canonicalMessages: canonicalMessages,
      messages: messages,
      membersByConversation: membersByConversation,
      memberUserIdsByConversation: memberUserIdsByConversation,
      lifecycleRevisions: lifecycleRevisions,
      lifecycleArchivedStates: lifecycleArchivedStates,
      pendingConversationArchiveInputs: const {},
      memberListRevisions: memberListRevisions,
      currentUserReadStates: currentUserReadStates,
      authoritativeCurrentUserReadStates: currentUserReadStates,
      currentUserPreferences: currentUserPreferences,
      authoritativeCurrentUserPreferences: currentUserPreferences,
      preferenceRevisions: preferenceRevisions,
      pendingConversationPreferenceIntents: const {},
      currentUserThreadFollows: threadFollows,
      authoritativeCurrentUserThreadFollows: threadFollows,
      threadFollowRevisions: threadFollowRevisions,
      pendingThreadFollowIntents: const {},
      currentUserSavedMessages: savedMessages,
      savedMessageRevisions: savedMessageRevisions,
      currentUserMessageReminders: messageReminders,
      authoritativeCurrentUserMessageReminders: messageReminders,
      messageReminderConversationIds: messageReminderConversationIds,
      messageReminderRevisions: messageReminderRevisions,
      pendingMessageReminderIntents: const {},
      currentUserDrafts: drafts,
      draftRevisions: draftRevisions,
      conversationMetadata: conversationMetadata,
      durableStreams: durableStreams,
      conversationLists: conversationLists,
      conversationDetails: conversationDetails,
      timelines: timelines,
      attachments: attachments,
      attachmentUploads: attachmentUploads,
      huddles: huddles,
      latestReplayCursor: latestReplayCursorJson == null
          ? null
          : EventCursor.fromJson(latestReplayCursorJson),
    );
  }
}

({String key, NormalizedConversationListEntry value})
    _decodeConversationListEntry(Object? json) {
  final entry = _storageObject(json, 'ConversationListEntry');
  _storageFields(
    entry,
    const {
      'key',
      'scope',
      'conversationIds',
      'nextCursor',
      'metadata',
      'pages',
    },
    'ConversationListEntry',
  );
  final key = _storageString(entry['key'], 'ConversationListEntry.key');
  final scope = ConversationSnapshotScope.fromJson(entry['scope']);
  if (key != conversationSnapshotScopeKey(scope)) {
    throw const FormatException('Stored conversation-list key is invalid.');
  }
  final pages = <String, NormalizedConversationListPage>{};
  for (final json
      in _storageList(entry['pages'], 'ConversationListEntry.pages')) {
    final page = _storageObject(json, 'ConversationListPageEntry');
    _storageFields(
      page,
      const {
        'key',
        'requestCursor',
        'conversationIds',
        'nextCursor',
        'metadata',
      },
      'ConversationListPageEntry',
    );
    final pageKey =
        _storageString(page['key'], 'ConversationListPageEntry.key');
    final requestCursor = page['requestCursor'] == null
        ? null
        : ConversationSnapshotCursor.fromJson(page['requestCursor']);
    if (pageKey != _conversationListPageKey(requestCursor)) {
      throw const FormatException(
          'Stored conversation-list page key is invalid.');
    }
    _storageAddUnique(
      pages,
      pageKey,
      NormalizedConversationListPage(
        requestCursor: requestCursor,
        conversationIds: _decodeConversationIds(
          page['conversationIds'],
          'ConversationListPageEntry.conversationIds',
        ),
        nextCursor: page['nextCursor'] == null
            ? null
            : ConversationSnapshotCursor.fromJson(page['nextCursor']),
        metadata: ConversationSnapshotMetadata.fromJson(page['metadata']),
      ),
      'ConversationListEntry.pages',
    );
  }
  return (
    key: key,
    value: NormalizedConversationListEntry(
      scope: scope,
      conversationIds: _decodeConversationIds(
        entry['conversationIds'],
        'ConversationListEntry.conversationIds',
      ),
      nextCursor: entry['nextCursor'] == null
          ? null
          : ConversationSnapshotCursor.fromJson(entry['nextCursor']),
      metadata: ConversationSnapshotMetadata.fromJson(entry['metadata']),
      pages: pages,
    ),
  );
}

({ConversationId key, NormalizedTimelineEntry value}) _decodeTimelineEntry(
  Object? json,
  Map<MessageId, Message> canonicalMessages,
) {
  final entry = _storageObject(json, 'TimelineEntry');
  _storageFields(
    entry,
    const {'conversationId', 'messageIds', 'pagination', 'replayCursor'},
    'TimelineEntry',
  );
  final conversationId = ConversationId.fromJson(entry['conversationId']);
  final messageIds = <MessageId>[];
  final seen = <MessageId>{};
  var previousSequence = -1;
  for (final json
      in _storageList(entry['messageIds'], 'TimelineEntry.messageIds')) {
    final messageId = MessageId.fromJson(json);
    final message = canonicalMessages[messageId];
    if (!seen.add(messageId) ||
        message == null ||
        message.conversationId != conversationId ||
        message.sequence.value <= previousSequence) {
      throw const FormatException('Stored timeline message order is invalid.');
    }
    previousSequence = message.sequence.value;
    messageIds.add(messageId);
  }
  return (
    key: conversationId,
    value: NormalizedTimelineEntry(
      messageIds: messageIds,
      pagination: MessageTimelinePagination.fromJson(entry['pagination']),
      replayCursor: entry['replayCursor'] == null
          ? null
          : EventCursor.fromJson(entry['replayCursor']),
    ),
  );
}

List<ConversationId> _decodeConversationIds(Object? json, String name) {
  final result = <ConversationId>[];
  final seen = <ConversationId>{};
  for (final value in _storageList(json, name)) {
    final id = ConversationId.fromJson(value);
    if (!seen.add(id)) throw FormatException('$name contains duplicates.');
    result.add(id);
  }
  return result;
}

void _validateNormalizedReferences({
  required Map<ConversationId, Conversation> conversations,
  required Map<MessageId, Message> canonicalMessages,
  required Map<MessageId, MessageTimelineMessage> messages,
  required Map<ConversationId, Map<UserId, ConversationSnapshotMember>>
      membersByConversation,
  required Map<ConversationId, List<UserId>> memberUserIdsByConversation,
  required Map<ConversationId, ConversationSnapshotReadState>
      currentUserReadStates,
  required Map<ConversationId, ConversationSnapshotPreference>
      currentUserPreferences,
  required Map<ConversationId, NormalizedConversationMetadata>
      conversationMetadata,
  required Map<String, NormalizedConversationListEntry> conversationLists,
  required Map<ConversationId, ConversationSnapshotMetadata>
      conversationDetails,
  required Map<ConversationId, NormalizedTimelineEntry> timelines,
  required Map<AttachmentId, MessageAttachmentMetadata> attachments,
  required Map<ConversationId, HuddleSessionState> huddles,
}) {
  final referencedConversations = <ConversationId>{
    ...membersByConversation.keys,
    ...memberUserIdsByConversation.keys,
    ...currentUserReadStates.keys,
    ...currentUserPreferences.keys,
    ...conversationMetadata.keys,
    ...conversationDetails.keys,
    for (final list in conversationLists.values) ...list.conversationIds,
    for (final list in conversationLists.values)
      for (final page in list.pages.values) ...page.conversationIds,
  };
  if (!conversations.keys.toSet().containsAll(referencedConversations)) {
    throw const FormatException(
      'Stored normalized state references an unknown conversation.',
    );
  }

  for (final entry in messages.entries) {
    for (final metadata in entry.value.attachmentMetadata) {
      final canonical = attachments[metadata.attachmentId];
      if (canonical == null ||
          !_sameValue(canonical.toJson(), metadata.toJson())) {
        throw const FormatException(
          'Stored message attachment metadata is not canonical.',
        );
      }
    }
  }
  for (final entry in huddles.entries) {
    if (entry.key != entry.value.conversationId ||
        !conversations.containsKey(entry.key)) {
      throw const FormatException(
        'Stored huddle references a missing or mismatched conversation.',
      );
    }
  }
  for (final entry in messages.entries) {
    final canonical = canonicalMessages[entry.key];
    final projection = entry.value;
    if (canonical == null ||
        canonical.tenantId != projection.tenantId ||
        canonical.conversationId != projection.conversationId ||
        canonical.sequence != projection.sequence) {
      throw const FormatException(
        'Stored timeline projection has no matching canonical message.',
      );
    }
  }
}

Map<String, Object?> _storageObject(Object? json, String name) {
  if (json is! Map<Object?, Object?>) {
    throw FormatException('$name must be a JSON object.');
  }
  final result = <String, Object?>{};
  for (final entry in json.entries) {
    final key = entry.key;
    if (key is! String) throw FormatException('$name keys must be strings.');
    result[key] = entry.value;
  }
  return result;
}

List<Object?> _storageRequiredList(
  Map<String, Object?> object,
  String key,
  String name,
) =>
    _storageList(object[key], '$name.$key');

List<Object?> _storageList(Object? json, String name) {
  if (json is! List<Object?>) throw FormatException('$name must be an array.');
  return json;
}

String _storageString(Object? json, String name) {
  if (json is! String || json.isEmpty) {
    throw FormatException('$name must be a non-empty string.');
  }
  return json;
}

void _storageFields(
  Map<String, Object?> object,
  Set<String> fields,
  String name,
) {
  for (final key in object.keys) {
    if (!fields.contains(key)) throw FormatException('$name.$key is unknown.');
  }
  for (final field in fields) {
    if (!object.containsKey(field)) {
      throw FormatException('$name.$field is required.');
    }
  }
}

void _storageAddUnique<K, V>(
  Map<K, V> values,
  K key,
  V value,
  String name,
) {
  if (values.containsKey(key)) {
    throw FormatException('$name contains duplicates.');
  }
  values[key] = value;
}
