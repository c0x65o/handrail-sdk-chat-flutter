part of 'normalized_snapshot_state.dart';

/// Matches the bounded per-stream replay window used by the JavaScript SDK.
const int durableEventRecentIdLimit = 64;

/// Durable events are currently emitted with the product protocol version.
const int handrailChatDurableEventProtocolVersion = 4;

enum DurableEventReductionStatus { applied, duplicate, stale }

enum DurableEventRecoveryReason {
  eventGap('event_gap'),
  eventIncompatible('event_incompatible'),
  eventInvalid('event_invalid');

  const DurableEventRecoveryReason(this.wireValue);
  final String wireValue;
}

enum DurableEventDiagnosticCode {
  protocolMismatch('protocol_mismatch'),
  privateStreamMismatch('private_stream_mismatch'),
  unsupportedEventType('unknown_event_type'),
  orderingGap('ordering_gap'),
  incoherentPayload('incoherent_payload');

  const DurableEventDiagnosticCode(this.wireValue);
  final String wireValue;
}

final class DurableEventDiagnostic {
  const DurableEventDiagnostic({
    required this.code,
    required this.reason,
    required this.eventId,
    required this.streamId,
    required this.eventType,
    required this.message,
    this.conversationId,
  });

  final DurableEventDiagnosticCode code;
  final DurableEventRecoveryReason reason;
  final String eventId;
  final String streamId;
  final String eventType;

  /// Stable and safe to serialize. Event payloads are never included.
  final String message;

  /// Resource requiring an authorized snapshot, including on a user stream.
  final ConversationId? conversationId;
}

final class DurableEventReductionError implements Exception {
  const DurableEventReductionError(this.diagnostic);

  final DurableEventDiagnostic diagnostic;

  @override
  String toString() => 'DurableEventReductionError: ${diagnostic.message}';
}

final class DurableEventReduction {
  const DurableEventReduction({required this.status, required this.state});

  final DurableEventReductionStatus status;
  final NormalizedSnapshotState state;
}

final class _DurableMessageMutation {
  const _DurableMessageMutation(this.state, [this.settle]);

  final NormalizedSnapshotState state;
  final void Function()? settle;
}

extension NormalizedSnapshotDurableMessageEvents on NormalizedSnapshotStore {
  /// Atomically validates and reduces one supported durable message event.
  ///
  /// Recovery errors do not mutate normalized state, ordering metadata,
  /// optimistic lanes, cursors, or selector streams.
  DurableEventReduction reduceDurableEvent(
    KnownDurableEvent event, {
    int supportedProtocolVersion = handrailChatDurableEventProtocolVersion,
    void Function(ReadCursorUpdatedEvent event)? onReadCursorUpdated,
    void Function(ConversationDraftUpdatedEvent event)? onDraftUpdated,
    void Function(HuddleSessionState state)? onHuddleUpdated,
    void Function(ConversationId conversationId)? onConversationAccessRevoked,
  }) {
    _ensureOpen();
    final previous = _state;
    if (event.protocolVersion != supportedProtocolVersion) {
      _durableFailure(
        event,
        DurableEventDiagnosticCode.protocolMismatch,
        DurableEventRecoveryReason.eventIncompatible,
        'The durable event protocol is incompatible with this client.',
      );
    }

    final stream = previous.durableStreams[event.streamId];
    if (stream?.recentEventIds.contains(event.eventId) == true) {
      return DurableEventReduction(
        status: DurableEventReductionStatus.duplicate,
        state: previous,
      );
    }
    // Read cursors, preferences, drafts, thread follows, saved messages, and
    // reminders share a user stream across independent resource clocks.
    // Resource revisions determine canonical order (including
    // savedMessageRevision and reminderRevision per message), not these
    // timestamps; replay admission still preserves the timestamp high-water.
    // Read-cursor freshness is ordered per conversation by lastReadSequence,
    // then updatedAt, independently of tied or decreasing stream wall clocks.
    // Membership freshness on both conversation and user-private streams belongs
    // to per-conversation memberListRevisions; timestamps remain replay high-water
    // metadata and must not preempt resource revision or identity validation.
    // Message creation is admitted by canonical identity and sequence; envelope
    // clocks may tie, decrease, or reflect unrelated stream events. They remain
    // timestamp high-water metadata and must not preempt that reconciliation.
    // Message edits are ordered by validated canonical revision; their envelope
    // timestamps likewise remain replay high-water metadata.
    // Deletions are admitted by canonical identity and consecutive revision;
    // their envelope timestamps also remain replay high-water metadata.
    // Archive and restore ordering belongs to canonical lifecycle revisions;
    // envelope timestamps remain replay high-water metadata.
    if (stream != null &&
        event is! ConversationArchivedDurableEvent &&
        event is! ConversationRestoredDurableEvent &&
        event is! MessageCreatedDurableEvent &&
        event is! MessageUpdatedDurableEvent &&
        event is! MessageDeletedDurableEvent &&
        event is! ThreadLifecycleUpdatedDurableEvent &&
        event is! ThreadLifecycleChangedDurableEvent &&
        event is! ThreadSummaryUpdatedDurableEvent &&
        event is! MembershipUpdatedDurableEvent &&
        event is! ReadCursorUpdatedDurableEvent &&
        event is! PreferenceUpdatedDurableEvent &&
        event is! DraftUpdatedDurableEvent &&
        event is! ThreadFollowUpdatedDurableEvent &&
        event is! SavedMessageUpdatedDurableEvent &&
        event is! MessageReminderUpdatedDurableEvent) {
      final occurredAt = DateTime.parse(event.occurredAt.value);
      final lastOccurredAt = DateTime.parse(stream.lastOccurredAt.value);
      if (occurredAt.isBefore(lastOccurredAt)) {
        return DurableEventReduction(
          status: DurableEventReductionStatus.stale,
          state: previous,
        );
      }
      if (occurredAt.isAtSameMomentAs(lastOccurredAt) &&
          event.eventId != stream.lastEventId) {
        _durableFailure(
          event,
          DurableEventDiagnosticCode.orderingGap,
          DurableEventRecoveryReason.eventGap,
          'Two distinct durable events have an ambiguous stream order.',
        );
      }
    }

    late final _DurableMessageMutation mutation;
    try {
      mutation = switch (event) {
        ConversationCreatedDurableEvent event =>
          _reduceDurableConversationCreated(this, previous, event),
        ThreadLifecycleUpdatedDurableEvent event =>
          _reduceThreadLifecycle(previous, event),
        ThreadLifecycleChangedDurableEvent event =>
          _reduceThreadLifecycleInvalidation(previous, event),
        ThreadCreatedDurableEvent event =>
          _reduceDurableConversationCreated(this, previous, event),
        ConversationArchivedDurableEvent event =>
          _reduceDurableConversationLifecycle(previous, event, true),
        ConversationRestoredDurableEvent event =>
          _reduceDurableConversationLifecycle(previous, event, false),
        MembershipUpdatedDurableEvent event =>
          _reduceDurableConversationMembership(
            this,
            previous,
            event,
            onConversationAccessRevoked,
          ),
        MessageCreatedDurableEvent event =>
          _reduceDurableMessageCreated(this, previous, event),
        MessageUpdatedDurableEvent event =>
          _reduceDurableMessageRevision(this, previous, event, false),
        MessageDeletedDurableEvent event =>
          _reduceDurableMessageRevision(this, previous, event, true),
        ThreadSummaryUpdatedDurableEvent event =>
          _reduceDurableThreadSummary(previous, event),
        ReactionUpdatedDurableEvent event =>
          _reduceDurableReaction(this, previous, event),
        ReadCursorUpdatedDurableEvent event => _reduceDurableReadCursor(
            previous,
            event,
            onReadCursorUpdated,
          ),
        PreferenceUpdatedDurableEvent event =>
          _reduceDurableConversationPreference(previous, event),
        ThreadFollowUpdatedDurableEvent event =>
          _reduceDurableThreadFollow(previous, event),
        SavedMessageUpdatedDurableEvent event =>
          _reduceDurableSavedMessage(previous, event),
        MessageReminderUpdatedDurableEvent event =>
          _reduceDurableMessageReminder(previous, event),
        DraftUpdatedDurableEvent event => _reduceDurableConversationDraft(
            previous,
            event,
            onDraftUpdated,
          ),
        AttachmentUpdatedDurableEvent event =>
          _reduceDurableAttachment(previous, event),
        HuddleUpdatedDurableEvent event => _reduceDurableHuddle(
            previous,
            event,
            onHuddleUpdated,
          ),
        _ => _durableFailure(
            event,
            DurableEventDiagnosticCode.unsupportedEventType,
            DurableEventRecoveryReason.eventIncompatible,
            'The durable event requires a newer client reducer.',
          ),
      };
    } on DurableEventReductionError {
      rethrow;
    } on FormatException {
      _durableInvalid(event);
    } on NormalizedSnapshotConflict {
      _durableInvalid(event);
    }

    final recentEventIds = <String>[
      ...?stream?.recentEventIds,
      event.eventId,
    ];
    if (recentEventIds.length > durableEventRecentIdLimit) {
      recentEventIds.removeRange(
        0,
        recentEventIds.length - durableEventRecentIdLimit,
      );
    }
    final next = _copyState(
      mutation.state,
      durableStreams: Map.unmodifiable({
        ...mutation.state.durableStreams,
        event.streamId: DurableStreamMetadata(
          lastEventId: event.eventId,
          lastOccurredAt: stream != null &&
                  DateTime.parse(event.occurredAt.value)
                      .isBefore(DateTime.parse(stream.lastOccurredAt.value))
              ? stream.lastOccurredAt
              : event.occurredAt,
          recentEventIds: recentEventIds,
        ),
      }),
      latestReplayCursor: EventCursor(eventId: event.eventId),
      replaceLatestReplayCursor: true,
    );
    final committed = _commit(previous, next);
    mutation.settle?.call();
    return DurableEventReduction(
      status: DurableEventReductionStatus.applied,
      state: committed,
    );
  }

  /// Installs a caller-created provisional row for send reconciliation.
  ///
  /// The canonical `message.created` event replaces this row by
  /// [clientMessageId] only when tenant, author identity, and conversation also
  /// match, even when the provisional and canonical IDs differ. Unrelated
  /// canonical messages sharing the client key leave this send pending.
  NormalizedSnapshotState beginOptimisticMessageSend({
    required String clientMessageId,
    required MessageTimelineMessage projection,
  }) {
    _ensureOpen();
    if (clientMessageId.trim().isEmpty ||
        _pendingOptimisticMessageSends.containsKey(clientMessageId) ||
        _pendingOptimisticMessageSends.containsValue(projection.id) ||
        _state.canonicalMessages.containsKey(projection.id) ||
        _state.conversations[projection.conversationId] == null) {
      throw const NormalizedSnapshotConflict(
        'The optimistic send cannot begin from the current state.',
      );
    }
    final previous = _state;
    final canonicalMessages = Map<MessageId, Message>.unmodifiable({
      ...previous.canonicalMessages,
      projection.id: projection.message,
    });
    final existingTimeline = previous.timelines[projection.conversationId];
    final messageIds = _sortAndValidateTimelineIds(
      <MessageId>[...?existingTimeline?.messageIds, projection.id],
      canonicalMessages,
      projection.conversationId,
    );
    final timeline = NormalizedTimelineEntry(
      messageIds: messageIds,
      pagination: existingTimeline?.pagination ?? _emptyPagination,
      replayCursor: existingTimeline?.replayCursor,
    );
    _pendingOptimisticMessageSends[clientMessageId] = projection.id;
    try {
      return _commit(
        previous,
        _copyState(
          previous,
          canonicalMessages: canonicalMessages,
          messages: Map<MessageId, MessageTimelineMessage>.unmodifiable({
            ...previous.messages,
            projection.id: projection,
          }),
          timelines: Map<ConversationId, NormalizedTimelineEntry>.unmodifiable({
            ...previous.timelines,
            projection.conversationId: timeline,
          }),
        ),
      );
    } catch (_) {
      _pendingOptimisticMessageSends.remove(clientMessageId);
      rethrow;
    }
  }

  Set<String> get pendingOptimisticSendClientMessageIds =>
      Set.unmodifiable(_pendingOptimisticMessageSends.keys);
}

_DurableMessageMutation _reduceDurableSavedMessage(
  NormalizedSnapshotState state,
  SavedMessageUpdatedDurableEvent event,
) {
  final payload = event.payload.data;
  if (payload.length != 4 || payload['operation'] != 'set_saved_message') {
    _durableInvalid(event);
  }
  final messageId = MessageId.fromJson(payload['messageId']);
  final revision = payload['savedMessageRevision'];
  if (revision is! int || revision < 1) _durableInvalid(event);
  final savedMessage =
      CanonicalActorPrivateSavedMessageState.fromJson(payload['savedMessage']);
  if (savedMessage.messageId != messageId) _durableInvalid(event);

  final privateActor = _requireDurablePrivateActor(event);
  final conversationId = state.canonicalMessages[messageId]?.conversationId;
  final knownCurrentUser = conversationId == null
      ? null
      : _currentUserIdForConversation(state, conversationId);
  if (knownCurrentUser != null && knownCurrentUser != privateActor) {
    _durablePrivateMismatch(event);
  }

  final knownRevision = state.savedMessageRevisions[messageId] ?? 0;
  final existing = state.currentUserSavedMessages[messageId];
  if (revision < knownRevision) return _DurableMessageMutation(state);
  if (revision == knownRevision) {
    if (existing != null &&
        !_sameValue(existing.toJson(), savedMessage.toJson())) {
      _durableInvalid(event);
    }
    return _DurableMessageMutation(state);
  }
  return _DurableMessageMutation(
    _copyState(
      state,
      currentUserSavedMessages: Map.unmodifiable({
        ...state.currentUserSavedMessages,
        messageId: savedMessage,
      }),
      savedMessageRevisions: Map.unmodifiable({
        ...state.savedMessageRevisions,
        messageId: revision,
      }),
    ),
  );
}

_DurableMessageMutation _reduceDurableMessageReminder(
  NormalizedSnapshotState state,
  MessageReminderUpdatedDurableEvent event,
) {
  final payload = event.payload.data;
  final conversationId = ConversationId.fromJson(payload['conversationId']);
  final messageId = MessageId.fromJson(payload['messageId']);
  final revision = payload['reminderRevision'];
  if (revision is! int || revision < 1) _durableInvalid(event);
  final reminder = CanonicalMessageReminder.fromJson(payload['reminder']);
  return _DurableMessageMutation(
    _reconcileMessageReminderCanonicalState(
      state,
      conversationId: conversationId,
      messageId: messageId,
      reminderRevision: revision,
      reminder: reminder,
    ),
  );
}

_DurableMessageMutation _reduceDurableMessageCreated(
  NormalizedSnapshotStore store,
  NormalizedSnapshotState state,
  MessageCreatedDurableEvent event,
) {
  final payload = event.payload.data;
  final message = Message.fromJson(payload['message']);
  final clientMessageId = payload['clientMessageId'];
  if (clientMessageId is! String ||
      clientMessageId.trim().isEmpty ||
      message.revision.revision != 1) {
    _durableInvalid(event);
  }
  final conversation = _knownDurableConversation(state, event, message);
  final knownMetadata = state.conversationMetadata[message.conversationId];
  if (knownMetadata == null) _durableGap(event);

  var canonicalMessages = state.canonicalMessages;
  var messages = state.messages;
  var timelines = state.timelines;
  final optimisticId = store._pendingOptimisticMessageSends[clientMessageId];
  final optimistic = canonicalMessages[optimisticId];
  // Server client keys are unique per tenant and author, not globally. Only
  // settle a projection in the same conversation and identity scope.
  final reconcilesOptimistic = optimistic != null &&
      optimistic.tenantId == message.tenantId &&
      optimistic.author.userId == message.author.userId &&
      optimistic.conversationId == message.conversationId;
  if (reconcilesOptimistic) {
    canonicalMessages =
        Map.unmodifiable({...canonicalMessages}..remove(optimisticId));
    messages = Map.unmodifiable({...messages}..remove(optimisticId));
    final optimisticTimeline = timelines[message.conversationId];
    if (optimisticTimeline != null &&
        optimisticTimeline.messageIds.contains(optimisticId)) {
      timelines = Map.unmodifiable({
        ...timelines,
        message.conversationId: NormalizedTimelineEntry(
          messageIds: optimisticTimeline.messageIds
              .where((id) => id != optimisticId)
              .toList(growable: false),
          pagination: optimisticTimeline.pagination,
          replayCursor: optimisticTimeline.replayCursor,
        ),
      });
    }
  }

  final existing = canonicalMessages[message.id];
  if (existing != null) {
    _validateDurableMessageIdentity(existing, message, event);
    // HTTP command reconciliation can precede this event and stores only the
    // canonical message. The event must still supply its timeline projection.
    if (messages.containsKey(message.id) || existing.revision.revision > 1) {
      return _DurableMessageMutation(
        _copyState(state,
            canonicalMessages: canonicalMessages,
            messages: messages,
            timelines: timelines),
        !reconcilesOptimistic
            ? null
            : () =>
                store._pendingOptimisticMessageSends.remove(clientMessageId),
      );
    }
  }

  final knownLatest = knownMetadata.latestSequence.value;
  if (message.sequence.value > knownLatest + 1) _durableGap(event);
  if (message.sequence.value <= knownLatest && existing == null) {
    return _DurableMessageMutation(
      _copyState(
        state,
        canonicalMessages: canonicalMessages,
        messages: messages,
        timelines: timelines,
      ),
      !reconcilesOptimistic
          ? null
          : () => store._pendingOptimisticMessageSends.remove(clientMessageId),
    );
  }

  final projection = _durableTimelineProjection(
    message,
    knownAttachments: state.attachments,
    event: event,
  );
  canonicalMessages = Map.unmodifiable({
    ...canonicalMessages,
    message.id: message,
  });
  messages = Map.unmodifiable({...messages, message.id: projection});
  final existingTimeline = timelines[message.conversationId];
  final messageIds = _sortAndValidateTimelineIds(
    <MessageId>[...?existingTimeline?.messageIds, message.id],
    canonicalMessages,
    message.conversationId,
  );
  timelines = Map.unmodifiable({
    ...timelines,
    message.conversationId: NormalizedTimelineEntry(
      messageIds: messageIds,
      pagination: existingTimeline?.pagination ?? _emptyPagination,
      replayCursor: EventCursor(eventId: event.eventId),
    ),
  });

  if (conversation is ThreadConversation &&
      message.sequence.value > knownLatest) {
    final root = canonicalMessages[conversation.rootMessageId];
    final rootProjection = messages[conversation.rootMessageId];
    final summary = root?.threadSummary;
    if (conversation.parentConversationId == conversation.id ||
        root == null ||
        rootProjection == null ||
        root.conversationId != conversation.parentConversationId ||
        summary == null ||
        summary.threadId != conversation.id) {
      _durableGap(event);
    }
    final participants = <UserId>[...summary.participantIds];
    if (!participants.contains(message.author.userId)) {
      participants.add(message.author.userId);
    }
    final currentUserId = state
            .currentUserReadStates[conversation.id]?.userId ??
        state.currentUserReadStates[conversation.parentConversationId]?.userId;
    final nextSummary = ThreadSummary(
      threadId: summary.threadId,
      replyCount: summary.replyCount + 1,
      participantIds: participants,
      unreadCount: summary.unreadCount +
          (currentUserId == message.author.userId ? 0 : 1),
      lastReplyAt: message.createdAt,
    );
    final nextRoot = _durableMessageWithThreadSummary(root, nextSummary);
    canonicalMessages = Map.unmodifiable({
      ...canonicalMessages,
      root.id: nextRoot,
    });
    messages = Map.unmodifiable({
      ...messages,
      root.id: _durableProjectionWithMessage(rootProjection, nextRoot),
    });
  }

  final latestActivity = DateTime.parse(knownMetadata.activityAt.value)
          .isAfter(DateTime.parse(message.updatedAt.value))
      ? knownMetadata.activityAt
      : message.updatedAt;
  return _DurableMessageMutation(
    _copyState(
      state,
      canonicalMessages: canonicalMessages,
      messages: messages,
      timelines: timelines,
      conversationMetadata: Map.unmodifiable({
        ...state.conversationMetadata,
        message.conversationId: NormalizedConversationMetadata(
          latestSequence: message.sequence.value > knownLatest
              ? message.sequence
              : knownMetadata.latestSequence,
          activityAt: latestActivity,
          unreadMentionCount: knownMetadata.unreadMentionCount,
        ),
      }),
    ),
    !reconcilesOptimistic
        ? null
        : () => store._pendingOptimisticMessageSends.remove(clientMessageId),
  );
}

_DurableMessageMutation _reduceDurableMessageRevision(
  NormalizedSnapshotStore store,
  NormalizedSnapshotState state,
  KnownDurableEvent event,
  bool deleted,
) {
  final message = Message.fromJson(event.payload.data['message']);
  if ((deleted && message is! DeletedMessage) ||
      (!deleted && message is! ActiveMessage)) {
    _durableInvalid(event);
  }
  _knownDurableConversation(state, event, message);
  final pendingEdit = store._pendingOptimisticMessageEdits[message.id];
  final pendingDelete = store._pendingOptimisticMessageDeletes[message.id];
  final existing = state.canonicalMessages[message.id];
  final baseline = pendingEdit?.authoritativeMessage ??
      pendingDelete?.authoritativeMessage ??
      existing;
  if (baseline == null) _durableGap(event);
  _validateDurableMessageIdentity(baseline, message, event);
  if (message.revision.revision <= baseline.revision.revision) {
    return _DurableMessageMutation(state);
  }
  if (message.revision.revision != baseline.revision.revision + 1) {
    _durableGap(event);
  }

  var messages = state.messages;
  final projection = messages[message.id];
  if (projection != null) {
    messages = Map.unmodifiable({
      ...messages,
      message.id: _durableTimelineProjection(
        message,
        existing: projection,
        knownAttachments: state.attachments,
        event: event,
      ),
    });
  }
  return _DurableMessageMutation(
    _copyState(
      state,
      canonicalMessages: Map.unmodifiable({
        ...state.canonicalMessages,
        message.id: message,
      }),
      messages: messages,
    ),
    () {
      if (pendingEdit != null) {
        store._pendingOptimisticMessageEdits.remove(message.id);
      }
      if (pendingDelete != null) {
        store._pendingOptimisticMessageDeletes.remove(message.id);
      }
    },
  );
}

_DurableMessageMutation _reduceDurableThreadSummary(
  NormalizedSnapshotState state,
  ThreadSummaryUpdatedDurableEvent event,
) {
  final payload = event.payload.data;
  final parentConversationId =
      ConversationId.fromJson(payload['parentConversationId']);
  final rootMessageId = MessageId.fromJson(payload['rootMessageId']);
  final summary = ThreadSummary.fromJson(payload['rootThreadSummary']);
  final parent = state.conversations[parentConversationId];
  final thread = state.conversations[summary.threadId];
  final root = state.canonicalMessages[rootMessageId];
  if (event.streamId != parentConversationId.value ||
      parent == null ||
      parent.tenantId != event.tenantId ||
      root == null ||
      root.conversationId != parentConversationId) {
    _durableGap(event);
  }
  if (summary.threadId == parentConversationId ||
      (thread != null &&
          (thread is! ThreadConversation ||
              thread.parentConversationId != parentConversationId ||
              thread.rootMessageId != rootMessageId))) {
    _durableInvalid(event);
  }
  // Creation/send summaries count all replies, including soft-deleted rows:
  // canonical replyCount orders progress per root, independently of envelope
  // clocks or viewer unread counts. Equal progress preserves accepted facts.
  final existingSummary = root.threadSummary;
  if (existingSummary != null &&
      summary.replyCount <= existingSummary.replyCount) {
    return _DurableMessageMutation(state);
  }
  final nextRoot = _durableMessageWithThreadSummary(root, summary);
  var messages = state.messages;
  if (messages[rootMessageId] case final projection?) {
    messages = Map.unmodifiable({
      ...messages,
      rootMessageId: _durableProjectionWithMessage(projection, nextRoot),
    });
  }
  return _DurableMessageMutation(
    _copyState(
      state,
      canonicalMessages: Map.unmodifiable({
        ...state.canonicalMessages,
        rootMessageId: nextRoot,
      }),
      messages: messages,
    ),
  );
}

_DurableMessageMutation _reduceDurableReaction(
  NormalizedSnapshotStore store,
  NormalizedSnapshotState state,
  ReactionUpdatedDurableEvent event,
) {
  final payload = event.payload.data;
  final conversationId = ConversationId.fromJson(payload['conversationId']);
  final conversation = state.conversations[conversationId];
  final result = ReactionMutationResult.fromJson({
    'operation': payload['operation'],
    'reconciliationStatus': payload['reconciliationStatus'],
    'messageId': payload['messageId'],
    'reactionKey': payload['reactionKey'],
    'count': payload['count'],
    'reactedByCurrentUser': payload['reactedByCurrentUser'],
  });
  final message = state.messages[result.messageId];
  if (event.streamId != conversationId.value ||
      conversation == null ||
      conversation.tenantId != event.tenantId ||
      message == null ||
      message.conversationId != conversationId) {
    _durableGap(event);
  }
  final target = _reactionTargetKey(result.messageId, result.reactionKey);
  final lane = store._pendingOptimisticReactions[target];
  // Broadcast membership belongs to the command actor, not this viewer. Only
  // the shared count is authoritative; pending intents settle by exact HTTP key.
  // An absent lane baseline must not inherit optimistic visible membership.
  final baseline = lane == null
      ? _reactionAggregate(message, result.reactionKey)
      : lane.authoritativeAggregate;
  final authoritative = result.count == 0
      ? null
      : MessageReactionAggregate(
          reactionKey: result.reactionKey,
          count: result.count,
          reactedByCurrentUser: baseline?.reactedByCurrentUser ?? false,
        );
  final visible = lane == null || lane.intents.isEmpty
      ? authoritative
      : _reactionProjection(
          authoritative,
          result.reactionKey,
          lane.intents.last.reactedByCurrentUser,
        );
  final projection = _durableWithSortedReactionAggregate(
    message,
    result.reactionKey,
    visible,
  );
  return _DurableMessageMutation(
    _copyState(
      state,
      messages: Map.unmodifiable({
        ...state.messages,
        result.messageId: projection,
      }),
    ),
    lane == null
        ? null
        : () {
            lane.authoritativeAggregate = authoritative;
          },
  );
}

Conversation _knownDurableConversation(
  NormalizedSnapshotState state,
  KnownDurableEvent event,
  Message message,
) {
  final conversation = state.conversations[message.conversationId];
  if (event.streamId != message.conversationId.value ||
      conversation == null ||
      conversation.tenantId != event.tenantId) {
    _durableGap(event);
  }
  if (message.tenantId != event.tenantId) _durableInvalid(event);
  return conversation;
}

void _validateDurableMessageIdentity(
  Message existing,
  Message incoming,
  KnownDurableEvent event,
) {
  if (existing.id != incoming.id ||
      existing.tenantId != incoming.tenantId ||
      existing.conversationId != incoming.conversationId ||
      existing.sequence != incoming.sequence ||
      !_sameValue(existing.author.toJson(), incoming.author.toJson()) ||
      existing.createdAt != incoming.createdAt) {
    _durableInvalid(event);
  }
}

MessageTimelineMessage _durableTimelineProjection(
  Message message, {
  MessageTimelineMessage? existing,
  Map<AttachmentId, MessageAttachmentMetadata> knownAttachments = const {},
  required KnownDurableEvent event,
}) {
  final references = message.content?.attachments ?? const [];
  final metadataById = {
    ...knownAttachments,
    for (final metadata
        in existing?.attachmentMetadata ?? const <MessageAttachmentMetadata>[])
      metadata.attachmentId: metadata,
  };
  final attachmentMetadata = <MessageAttachmentMetadata>[];
  for (final reference in references) {
    final metadata = metadataById[reference.attachmentId];
    if (metadata == null) _durableGap(event);
    attachmentMetadata.add(metadata);
  }
  return MessageTimelineMessage(
    message: message,
    isThreadRoot: message.threadSummary != null,
    reactions: existing?.reactions ?? const [],
    attachmentMetadata: attachmentMetadata,
  );
}

Message _durableMessageWithThreadSummary(
  Message message,
  ThreadSummary summary,
) {
  final json = Map<String, Object?>.of(message.toJson());
  json['threadSummary'] = summary.toJson();
  return Message.fromJson(json);
}

MessageTimelineMessage _durableProjectionWithMessage(
  MessageTimelineMessage projection,
  Message message,
) =>
    MessageTimelineMessage(
      message: message,
      isThreadRoot: message.threadSummary != null,
      reactions: projection.reactions,
      attachmentMetadata: projection.attachmentMetadata,
    );

MessageTimelineMessage _durableWithSortedReactionAggregate(
  MessageTimelineMessage message,
  String reactionKey,
  MessageReactionAggregate? aggregate,
) {
  final reactions = <MessageReactionAggregate>[
    for (final existing in message.reactions)
      if (existing.reactionKey != reactionKey) existing,
    if (aggregate != null) aggregate,
  ]..sort((left, right) => left.reactionKey.compareTo(right.reactionKey));
  return MessageTimelineMessage(
    message: message.message,
    isThreadRoot: message.isThreadRoot,
    reactions: reactions,
    attachmentMetadata: message.attachmentMetadata,
  );
}

Never _durableGap(KnownDurableEvent event, {ConversationId? conversationId}) =>
    _durableFailure(
      event,
      DurableEventDiagnosticCode.orderingGap,
      DurableEventRecoveryReason.eventGap,
      'The durable event cannot be safely reduced without a snapshot.',
      conversationId: conversationId ??
          (event.streamId.startsWith('user:')
              ? null
              : ConversationId(event.streamId)),
    );

Never _durableInvalid(KnownDurableEvent event) => _durableFailure(
      event,
      DurableEventDiagnosticCode.incoherentPayload,
      DurableEventRecoveryReason.eventInvalid,
      'The durable event is incoherent with known normalized state.',
    );

Never _durableFailure(
  KnownDurableEvent event,
  DurableEventDiagnosticCode code,
  DurableEventRecoveryReason reason,
  String message, {
  ConversationId? conversationId,
}) =>
    throw DurableEventReductionError(
      DurableEventDiagnostic(
        code: code,
        reason: reason,
        eventId: event.eventId,
        streamId: event.streamId,
        eventType: event.type,
        message: message,
        conversationId: conversationId,
      ),
    );
