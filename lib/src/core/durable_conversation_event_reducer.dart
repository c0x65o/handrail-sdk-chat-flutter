part of 'normalized_snapshot_state.dart';

_DurableMessageMutation _reduceDurableConversationCreated(
  NormalizedSnapshotStore store,
  NormalizedSnapshotState state,
  KnownDurableEvent event,
) {
  final payload = event.payload.data;
  final conversationJson =
      Map<String, Object?>.from(payload['conversation'] as Map);
  // Creation events include an unrevisioned member list alongside the
  // canonical conversation. Detail/membership snapshots own that authority.
  if (conversationJson.containsKey('memberUserIds')) {
    final members = conversationJson.remove('memberUserIds');
    if (members is! List ||
        members.any((id) => id is! String || id.trim().isEmpty) ||
        members.toSet().length != members.length) {
      _durableInvalid(event);
    }
  }
  var incoming = Conversation.fromJson(conversationJson);
  if (event.streamId != incoming.id.value ||
      incoming.tenantId != event.tenantId) {
    _durableInvalid(event);
  }

  final original = state.conversations[incoming.id];
  final existing = original == null ? null : _mergeThreadLifecycle(original, incoming);
  incoming = _mergeThreadLifecycle(incoming, original);
  if (existing != null) {
    _validateDurableConversationIdentity(existing, incoming, event);
    final updatedAtComparison = DateTime.parse(incoming.updatedAt.value)
        .compareTo(DateTime.parse(existing.updatedAt.value));
    if (updatedAtComparison < 0) {
      return _DurableMessageMutation(identical(existing, original) ? state :
          _copyState(state, conversations: Map.unmodifiable({
            ...state.conversations, existing.id: existing,
          })));
    }
    if (updatedAtComparison == 0 &&
        !_sameValue(existing.toJson(), incoming.toJson())) {
      _durableInvalid(event);
    }
  }

  var next = state;
  if (existing != null && !identical(existing, original)) {
    next = _copyState(state, conversations: Map.unmodifiable({
      ...state.conversations, existing.id: existing,
    }));
  }
  if (existing == null ||
      DateTime.parse(incoming.updatedAt.value)
          .isAfter(DateTime.parse(existing.updatedAt.value))) {
    final metadata = state.conversationMetadata[incoming.id];
    next = _copyState(
      state,
      conversations: Map.unmodifiable({
        ...state.conversations,
        incoming.id: incoming,
      }),
      conversationMetadata: metadata == null
          ? Map.unmodifiable({
              ...state.conversationMetadata,
              incoming.id: NormalizedConversationMetadata(
                latestSequence: const MessageSequence(0),
                activityAt: incoming.updatedAt,
              ),
            })
          : state.conversationMetadata,
      lifecycleArchivedStates: Map.unmodifiable({
        ...state.lifecycleArchivedStates,
        incoming.id: incoming.archivedAt != null,
      }),
    );
  }

  next = _withDurableConversationListVisibility(
    next,
    incoming.id,
    visible: incoming.archivedAt == null,
  );
  return _DurableMessageMutation(next);
}

_DurableMessageMutation _reduceDurableConversationLifecycle(
  NormalizedSnapshotState state,
  KnownDurableEvent event,
  bool archived,
) {
  final payload = event.payload.data;
  final conversationId = ConversationId.fromJson(payload['conversationId']);
  final conversation = state.conversations[conversationId];
  if (event.streamId != conversationId.value) _durableInvalid(event);
  if (conversation == null || conversation.tenantId != event.tenantId) {
    _durableGap(event);
  }

  final previousRevision = payload['previousLifecycleRevision'];
  final currentRevision = payload['currentLifecycleRevision'];
  if (previousRevision is! int || currentRevision is! int) {
    _durableInvalid(event);
  }
  final knownRevision = state.lifecycleRevisions[conversationId];
  final knownArchived = state.lifecycleArchivedStates[conversationId] ??
      conversation.archivedAt != null;
  var acceptsCanonical = true;
  if (knownRevision != null) {
    if (currentRevision < knownRevision) {
      acceptsCanonical = false;
    } else if (currentRevision == knownRevision) {
      if (knownArchived != archived) _durableInvalid(event);
      acceptsCanonical = false;
    } else if (previousRevision != knownRevision) {
      _durableGap(event);
    }
  }

  final pending = <ConversationArchiveInput>[
    ...?state.pendingConversationArchiveInputs[conversationId],
  ];
  final expectedIntent = archived
      ? ConversationArchiveIntent.archive
      : ConversationArchiveIntent.restore;
  final matchingIndex = pending.indexWhere(
    (intent) => intent.intent == expectedIntent,
  );
  if (matchingIndex >= 0) pending.removeAt(matchingIndex);
  final pendingByConversation =
      <ConversationId, List<ConversationArchiveInput>>{
    ...state.pendingConversationArchiveInputs,
  };
  if (pending.isEmpty) {
    pendingByConversation.remove(conversationId);
  } else {
    pendingByConversation[conversationId] = List.unmodifiable(pending);
  }

  var next = _copyState(
    state,
    lifecycleRevisions: acceptsCanonical
        ? Map.unmodifiable({
            ...state.lifecycleRevisions,
            conversationId: currentRevision,
          })
        : state.lifecycleRevisions,
    lifecycleArchivedStates: acceptsCanonical
        ? Map.unmodifiable({
            ...state.lifecycleArchivedStates,
            conversationId: archived,
          })
        : state.lifecycleArchivedStates,
    pendingConversationArchiveInputs: Map.unmodifiable(pendingByConversation),
  );
  if (acceptsCanonical) {
    next = _withDurableConversationListVisibility(
      next,
      conversationId,
      visible: !archived,
    );
  }
  return _DurableMessageMutation(next);
}

_DurableMessageMutation _reduceDurableConversationMembership(
  NormalizedSnapshotStore store,
  NormalizedSnapshotState state,
  MembershipUpdatedDurableEvent event,
  void Function(ConversationId conversationId)? onAccessRevoked,
) {
  final payload = event.payload.data;
  final input = ConversationMembershipMutationInput.fromJson(payload['input']);
  final result = ConversationMembershipMutationResult.fromJson(
    payload['result'],
    expectedInput: input,
  );
  final conversation = state.conversations[result.conversationId];
  if (conversation == null || conversation.tenantId != event.tenantId) {
    _durableGap(event);
  }
  final privateActor = _durablePrivateActor(event);
  final knownCurrentUser =
      _currentUserIdForConversation(state, result.conversationId);
  if (privateActor != null &&
      knownCurrentUser != null &&
      privateActor != knownCurrentUser) {
    _durablePrivateMismatch(event);
  }

  final knownRevision = state.memberListRevisions[result.conversationId];
  if (knownRevision != null && result.memberListRevision < knownRevision) {
    return _DurableMessageMutation(state);
  }
  final canonicalMembers = <UserId, ConversationSnapshotMember>{
    for (final member in result.members)
      member.userId: ConversationSnapshotMember.fromJson({
        'tenantId': event.tenantId.toJson(),
        'conversationId': result.conversationId.toJson(),
        ...member.toJson(),
      }),
  };
  final existingMembers = state.membersByConversation[result.conversationId];
  if (knownRevision == result.memberListRevision &&
      existingMembers != null &&
      !_sameMemberMaps(existingMembers, canonicalMembers)) {
    _durableInvalid(event);
  }
  if (knownRevision == result.memberListRevision && existingMembers != null) {
    return _DurableMessageMutation(state);
  }

  final activeUserIds = <UserId>[
    for (final member in result.members)
      if (member.state == ConversationMembershipMemberState.active)
        member.userId,
  ];
  var next = _copyState(
    state,
    membersByConversation: Map.unmodifiable({
      ...state.membersByConversation,
      result.conversationId:
          Map<UserId, ConversationSnapshotMember>.unmodifiable(
        canonicalMembers,
      ),
    }),
    memberUserIdsByConversation: Map.unmodifiable({
      ...state.memberUserIdsByConversation,
      result.conversationId: List<UserId>.unmodifiable(activeUserIds),
    }),
    memberListRevisions: Map.unmodifiable({
      ...state.memberListRevisions,
      result.conversationId: result.memberListRevision,
    }),
  );

  final currentUserId = privateActor ?? knownCurrentUser;
  final revokesAccess = privateActor != null &&
      currentUserId != null &&
      conversation.visibility == ConversationVisibility.private &&
      canonicalMembers[currentUserId]?.state != 'active';
  Set<MessageId> clearedMessageIds = const {};
  if (revokesAccess) {
    final cleared = _clearConversationAccessState(next, result.conversationId);
    next = cleared.state;
    clearedMessageIds = cleared.messageIds;
  }
  return _DurableMessageMutation(
    next,
    !revokesAccess
        ? null
        : () {
            store._pendingOptimisticMessageSends.removeWhere(
              (_, messageId) => clearedMessageIds.contains(messageId),
            );
            store._pendingOptimisticMessageEdits.removeWhere(
              (messageId, _) => clearedMessageIds.contains(messageId),
            );
            store._pendingOptimisticMessageDeletes.removeWhere(
              (messageId, _) => clearedMessageIds.contains(messageId),
            );
            store._pendingOptimisticReactions.removeWhere(
              (_, lane) => clearedMessageIds.contains(lane.messageId),
            );
            onAccessRevoked?.call(result.conversationId);
          },
  );
}

_DurableMessageMutation _reduceDurableReadCursor(
  NormalizedSnapshotState state,
  ReadCursorUpdatedDurableEvent event,
  void Function(ReadCursorUpdatedEvent event)? onReadCursorUpdated,
) {
  final readPayloadJson = Map<String, Object?>.from(event.payload.data)
    ..remove('reconciliationStatus');
  final payload = ReadCursorUpdatedPayload.fromJson(readPayloadJson);
  final conversation = state.conversations[payload.conversationId];
  final metadata = state.conversationMetadata[payload.conversationId];
  if (conversation == null ||
      metadata == null ||
      conversation.tenantId != event.tenantId) {
    _durableGap(event, conversationId: payload.conversationId);
  }
  final privateActor = _requireDurablePrivateActor(event);
  final knownCurrentUser =
      _currentUserIdForConversation(state, payload.conversationId);
  if (payload.actorUserId != privateActor ||
      (knownCurrentUser != null && knownCurrentUser != privateActor)) {
    _durablePrivateMismatch(event);
  }

  final existing = state.currentUserReadStates[payload.conversationId];
  var acceptsRead = existing == null;
  if (existing != null) {
    if (existing.userId != payload.readState.userId) {
      _durablePrivateMismatch(event);
    }
    acceptsRead = payload.readState.lastReadSequence.value >
            existing.lastReadSequence.value ||
        (payload.readState.lastReadSequence == existing.lastReadSequence &&
            DateTime.parse(payload.readState.updatedAt.value)
                .isAfter(DateTime.parse(existing.updatedAt.value)));
  }

  var next = state;
  if (acceptsRead ||
      payload.latestSequence.value > metadata.latestSequence.value) {
    next = _copyState(
      state,
      currentUserReadStates: acceptsRead
          ? Map.unmodifiable({
              ...state.currentUserReadStates,
              payload.conversationId: ConversationSnapshotReadState.fromJson(
                payload.readState.toJson(),
              ),
            })
          : state.currentUserReadStates,
      authoritativeCurrentUserReadStates: acceptsRead
          ? Map.unmodifiable({
              ...state.authoritativeCurrentUserReadStates,
              payload.conversationId: ConversationSnapshotReadState.fromJson(
                payload.readState.toJson(),
              ),
            })
          : state.authoritativeCurrentUserReadStates,
      conversationMetadata:
          payload.latestSequence.value > metadata.latestSequence.value
              ? Map.unmodifiable({
                  ...state.conversationMetadata,
                  payload.conversationId: NormalizedConversationMetadata(
                    latestSequence: payload.latestSequence,
                    activityAt: metadata.activityAt,
                    unreadMentionCount: metadata.unreadMentionCount,
                  ),
                })
              : state.conversationMetadata,
    );
  }
  final runtimeEvent = ReadCursorUpdatedEvent.fromJson(
    {...event.toJson(), 'payload': readPayloadJson},
    expectedTenantId: event.tenantId,
  );
  return _DurableMessageMutation(
    next,
    onReadCursorUpdated == null
        ? null
        : () => onReadCursorUpdated(runtimeEvent),
  );
}

_DurableMessageMutation _reduceDurableConversationPreference(
  NormalizedSnapshotState state,
  PreferenceUpdatedDurableEvent event,
) {
  final payload = event.payload.data;
  final actorUserId = UserId.fromJson(payload['actorUserId']);
  final privateActor = _requireDurablePrivateActor(event);
  if (actorUserId != privateActor) _durablePrivateMismatch(event);
  final input = UpdateConversationPreferenceInput.fromJson(payload['input']);
  final result = UpdateConversationPreferenceResult.fromJson(
    payload['result'],
    expectedInput: input,
  );
  final conversation = state.conversations[result.conversationId];
  if (conversation == null || conversation.tenantId != event.tenantId) {
    _durableGap(event, conversationId: result.conversationId);
  }
  final knownCurrentUser =
      _currentUserIdForConversation(state, result.conversationId);
  if (knownCurrentUser != null && knownCurrentUser != actorUserId) {
    _durablePrivateMismatch(event);
  }

  final incoming = _snapshotPreference(
    result.conversationId,
    actorUserId,
    result.preference.preference,
    result.preference.updatedAt,
  );
  final knownRevision = state.preferenceRevisions[result.conversationId] ?? 0;
  final authoritative =
      state.authoritativeCurrentUserPreferences[result.conversationId];
  if (result.preferenceRevision == knownRevision &&
      authoritative != null &&
      !_sameValue(authoritative.toJson(), incoming.toJson())) {
    _durableInvalid(event);
  }

  final intents = <PendingConversationPreferenceIntent>[
    ...?state.pendingConversationPreferenceIntents[result.conversationId],
  ];
  intents.removeWhere(
    (intent) => intent.idempotencyKey == result.idempotencyKey,
  );
  final acceptsCanonical = result.preferenceRevision > knownRevision ||
      (result.preferenceRevision == knownRevision && authoritative == null);
  final nextAuthoritative = acceptsCanonical ? incoming : authoritative;
  final pending = <ConversationId, List<PendingConversationPreferenceIntent>>{
    ...state.pendingConversationPreferenceIntents,
  };
  if (intents.isEmpty) {
    pending.remove(result.conversationId);
  } else {
    pending[result.conversationId] = List.unmodifiable(intents);
  }
  final preferences = <ConversationId, ConversationSnapshotPreference>{
    ...state.currentUserPreferences,
  };
  if (intents.isNotEmpty) {
    final latest = intents.last;
    preferences[result.conversationId] = _snapshotPreference(
      result.conversationId,
      actorUserId,
      latest.desiredPreference,
      latest.projectedAt,
    );
  } else if (nextAuthoritative != null) {
    preferences[result.conversationId] = nextAuthoritative;
  }
  return _DurableMessageMutation(
    _copyState(
      state,
      currentUserPreferences: Map.unmodifiable(preferences),
      authoritativeCurrentUserPreferences: nextAuthoritative == null
          ? state.authoritativeCurrentUserPreferences
          : Map.unmodifiable({
              ...state.authoritativeCurrentUserPreferences,
              result.conversationId: nextAuthoritative,
            }),
      preferenceRevisions: acceptsCanonical
          ? Map.unmodifiable({
              ...state.preferenceRevisions,
              result.conversationId: result.preferenceRevision,
            })
          : state.preferenceRevisions,
      pendingConversationPreferenceIntents: Map.unmodifiable(pending),
    ),
  );
}

_DurableMessageMutation _reduceDurableConversationDraft(
  NormalizedSnapshotState state,
  DraftUpdatedDurableEvent event,
  void Function(ConversationDraftUpdatedEvent event)? onDraftUpdated,
) {
  final runtimeEvent = ConversationDraftUpdatedEvent.fromJson(
    event.toJson(),
    expectedTenantId: event.tenantId,
  );
  final payload = runtimeEvent.payload;
  final privateActor = _requireDurablePrivateActor(event);
  final conversation = state.conversations[payload.result.conversationId];
  if (payload.actorUserId != privateActor) _durablePrivateMismatch(event);
  if (conversation == null || conversation.tenantId != event.tenantId) {
    _durableGap(event, conversationId: payload.result.conversationId);
  }
  final knownCurrentUser =
      _currentUserIdForConversation(state, payload.result.conversationId);
  if (knownCurrentUser != null && knownCurrentUser != privateActor) {
    _durablePrivateMismatch(event);
  }
  final knownRevision =
      state.draftRevisions[payload.result.conversationId] ?? 0;
  final existing = state.currentUserDrafts[payload.result.conversationId];
  if (payload.result.canonicalRevision < knownRevision) {
    return _DurableMessageMutation(
      state,
      onDraftUpdated == null ? null : () => onDraftUpdated(runtimeEvent),
    );
  }
  if (payload.result.canonicalRevision == knownRevision) {
    if (existing != null &&
        !_sameValue(existing.toJson(), payload.result.draft.toJson())) {
      return _DurableMessageMutation(
        state,
        onDraftUpdated == null ? null : () => onDraftUpdated(runtimeEvent),
      );
    }
    return _DurableMessageMutation(
      state,
      onDraftUpdated == null ? null : () => onDraftUpdated(runtimeEvent),
    );
  }
  final next = _copyState(
    state,
    currentUserDrafts: Map.unmodifiable({
      ...state.currentUserDrafts,
      payload.result.conversationId: payload.result.draft,
    }),
    draftRevisions: Map.unmodifiable({
      ...state.draftRevisions,
      payload.result.conversationId: payload.result.canonicalRevision,
    }),
  );
  return _DurableMessageMutation(
    next,
    onDraftUpdated == null ? null : () => onDraftUpdated(runtimeEvent),
  );
}

NormalizedSnapshotState _withDurableConversationListVisibility(
  NormalizedSnapshotState state,
  ConversationId conversationId, {
  required bool visible,
}) {
  final conversation = state.conversations[conversationId];
  if (conversation == null) return state;
  Map<String, NormalizedConversationListEntry>? changed;
  for (final mapEntry in state.conversationLists.entries) {
    final entry = mapEntry.value;
    final shouldInclude = visible &&
        _conversationCreationAppliesToScope(conversation, entry.scope);
    final selectionIds = <ConversationId>[
      if (shouldInclude) conversationId,
      ...entry.conversationIds.where((id) => id != conversationId),
    ];
    final pages = <String, NormalizedConversationListPage>{};
    for (final pageEntry in entry.pages.entries) {
      final page = pageEntry.value;
      pages[pageEntry.key] = NormalizedConversationListPage(
        requestCursor: page.requestCursor,
        conversationIds: <ConversationId>[
          if (shouldInclude && page.requestCursor == null) conversationId,
          ...page.conversationIds.where((id) => id != conversationId),
        ],
        nextCursor: page.nextCursor,
        metadata: page.metadata,
      );
    }
    final immutablePages =
        Map<String, NormalizedConversationListPage>.unmodifiable(pages);
    final linked = immutablePages.containsKey(_conversationListPageKey(null))
        ? _linkConversationListPages(immutablePages)
        : null;
    final updated = NormalizedConversationListEntry(
      scope: entry.scope,
      conversationIds: linked?.ids ?? selectionIds,
      nextCursor: linked?.nextCursor ?? entry.nextCursor,
      metadata: entry.metadata,
      pages: immutablePages,
    );
    if (_sameListEntry(entry, updated)) continue;
    changed ??= {...state.conversationLists};
    changed[mapEntry.key] = updated;
  }
  return changed == null
      ? state
      : _copyState(state, conversationLists: Map.unmodifiable(changed));
}

void _validateDurableConversationIdentity(
  Conversation existing,
  Conversation incoming,
  KnownDurableEvent event,
) {
  if (existing.id != incoming.id ||
      existing.tenantId != incoming.tenantId ||
      existing.type != incoming.type ||
      existing.createdAt != incoming.createdAt) {
    _durableInvalid(event);
  }
}

UserId? _durablePrivateActor(KnownDurableEvent event) {
  if (!event.streamId.startsWith('user:')) return null;
  final value = event.streamId.substring('user:'.length);
  if (value.trim().isEmpty) _durablePrivateMismatch(event);
  return UserId(value);
}

UserId _requireDurablePrivateActor(KnownDurableEvent event) =>
    _durablePrivateActor(event) ?? _durablePrivateMismatch(event);

Never _durablePrivateMismatch(KnownDurableEvent event) => _durableFailure(
      event,
      DurableEventDiagnosticCode.privateStreamMismatch,
      DurableEventRecoveryReason.eventInvalid,
      'The private durable event does not belong to the authenticated user stream.',
    );
