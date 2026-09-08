part of 'normalized_snapshot_state.dart';

/// One explicit local follow replacement waiting to settle.
final class PendingThreadFollowIntent {
  const PendingThreadFollowIntent({
    required this.idempotencyKey,
    required this.intent,
    required this.expectedFollowRevision,
    required this.projectedAt,
  });

  final String idempotencyKey;
  final ThreadFollowMutationIntent intent;
  final int expectedFollowRevision;
  final IsoTimestamp projectedAt;
}

/// Renderer-facing projected and authoritative follow state for one thread.
final class NormalizedThreadFollowState {
  NormalizedThreadFollowState({
    required this.threadId,
    required this.authoritativeRevision,
    required List<PendingThreadFollowIntent> pendingIntents,
    this.follow,
    this.authoritativeFollow,
  }) : pendingIntents = List.unmodifiable(pendingIntents);

  final ConversationId threadId;
  final CanonicalThreadFollowState? follow;
  final CanonicalThreadFollowState? authoritativeFollow;
  final int authoritativeRevision;
  final List<PendingThreadFollowIntent> pendingIntents;

  bool get isPending => pendingIntents.isNotEmpty;
  bool? get isFollowing => follow?.isFollowing;
}

extension NormalizedThreadFollowRuntime on NormalizedSnapshotStore {
  NormalizedThreadFollowState threadFollow(ConversationId threadId) {
    final state = _state;
    return NormalizedThreadFollowState(
      threadId: threadId,
      follow: state.currentUserThreadFollows[threadId],
      authoritativeFollow:
          state.authoritativeCurrentUserThreadFollows[threadId],
      authoritativeRevision: state.threadFollowRevisions[threadId] ?? 0,
      pendingIntents: state.pendingThreadFollowIntents[threadId] ?? const [],
    );
  }

  /// A framework-neutral stream that emits current state immediately.
  Stream<NormalizedThreadFollowState> threadFollowStates(
    ConversationId threadId,
  ) {
    _ensureOpen();
    return Stream.multi((events) {
      final subscription = _threadFollowChanges.stream
          .where((id) => id == threadId)
          .listen((_) => events.add(threadFollow(threadId)));
      events.add(threadFollow(threadId));
      events.onCancel = subscription.cancel;
    });
  }

  /// Publishes a manual follow or unfollow projection synchronously.
  NormalizedSnapshotState beginOptimisticThreadFollow(
    SetThreadFollowInput input,
    IsoTimestamp projectedAt,
  ) {
    _ensureOpen();
    final request = SetThreadFollowInput.fromJson(input.toJson());
    final previous = _state;
    _requireKnownThreadFollowTarget(previous, request.target.id);
    final knownRevision =
        previous.threadFollowRevisions[request.target.id] ?? 0;
    if (request.expectedFollowRevision != knownRevision) {
      throw const NormalizedSnapshotConflict(
        'Thread follow did not use the authoritative revision.',
      );
    }
    final intents = <PendingThreadFollowIntent>[
      ...?previous.pendingThreadFollowIntents[request.target.id],
      PendingThreadFollowIntent(
        idempotencyKey: request.idempotencyKey,
        intent: request.intent,
        expectedFollowRevision: request.expectedFollowRevision,
        projectedAt: projectedAt,
      ),
    ];
    final authoritative =
        previous.authoritativeCurrentUserThreadFollows[request.target.id] ??
            (previous.pendingThreadFollowIntents[request.target.id] == null
                ? previous.currentUserThreadFollows[request.target.id]
                : null);
    return _commit(
      previous,
      _copyState(
        previous,
        currentUserThreadFollows: Map.unmodifiable({
          ...previous.currentUserThreadFollows,
          request.target.id:
              _projectThreadFollow(request.target.id, intents.last),
        }),
        authoritativeCurrentUserThreadFollows: authoritative == null
            ? previous.authoritativeCurrentUserThreadFollows
            : Map.unmodifiable({
                ...previous.authoritativeCurrentUserThreadFollows,
                request.target.id: authoritative,
              }),
        pendingThreadFollowIntents: Map.unmodifiable({
          ...previous.pendingThreadFollowIntents,
          request.target.id:
              List<PendingThreadFollowIntent>.unmodifiable(intents),
        }),
      ),
    );
  }

  /// Rebases a queued intent immediately before dispatch.
  void rebaseOptimisticThreadFollow(
    ConversationId threadId,
    String idempotencyKey,
    int expectedFollowRevision,
  ) {
    _ensureOpen();
    final previous = _state;
    final existing = previous.pendingThreadFollowIntents[threadId];
    if (existing == null) return;
    final index = existing.indexWhere(
      (intent) => intent.idempotencyKey == idempotencyKey,
    );
    if (index < 0 ||
        existing[index].expectedFollowRevision == expectedFollowRevision) {
      return;
    }
    final intents = existing.toList(growable: false);
    final old = intents[index];
    intents[index] = PendingThreadFollowIntent(
      idempotencyKey: old.idempotencyKey,
      intent: old.intent,
      expectedFollowRevision: expectedFollowRevision,
      projectedAt: old.projectedAt,
    );
    _commit(
      previous,
      _copyState(
        previous,
        pendingThreadFollowIntents: Map.unmodifiable({
          ...previous.pendingThreadFollowIntents,
          threadId: List<PendingThreadFollowIntent>.unmodifiable(intents),
        }),
      ),
    );
  }

  /// Reconciles an HTTP settlement without allowing an older response to
  /// replace newer private canonical state.
  bool reconcileThreadFollowMutation(
    SetThreadFollowInput input,
    SetThreadFollowResult result,
  ) {
    _ensureOpen();
    final request = SetThreadFollowInput.fromJson(input.toJson());
    final parsed = SetThreadFollowResult.fromJson(
      result.toJson(),
      expectedInput: request,
    );
    _requireKnownThreadFollowTarget(_state, parsed.target.id);
    return _reconcileThreadFollowCanonical(
      parsed.target.id,
      parsed.followRevision,
      parsed.follow,
      settlingIdempotencyKey: parsed.idempotencyKey,
    );
  }

  /// Accepts canonical private-event state by monotonically increasing
  /// follow revision.
  bool reconcileThreadFollowCanonical(
    ConversationId threadId,
    int followRevision,
    CanonicalThreadFollowState follow,
  ) {
    _ensureOpen();
    _requireKnownThreadFollowTarget(_state, threadId);
    if (follow.target.id != threadId || followRevision < 1) {
      throw const NormalizedSnapshotConflict(
        'Canonical thread follow payload is incoherent.',
      );
    }
    return _reconcileThreadFollowCanonical(
      threadId,
      followRevision,
      follow,
    );
  }

  bool _reconcileThreadFollowCanonical(
    ConversationId threadId,
    int followRevision,
    CanonicalThreadFollowState follow, {
    String? settlingIdempotencyKey,
  }) {
    final previous = _state;
    final next = _mergeThreadFollowCanonical(
        previous, threadId, followRevision, follow,
        settlingIdempotencyKey: settlingIdempotencyKey);
    _commit(previous, next);
    return !identical(previous, next);
  }

  NormalizedSnapshotState _mergeThreadFollowCanonical(
    NormalizedSnapshotState previous,
    ConversationId threadId,
    int followRevision,
    CanonicalThreadFollowState follow, {
    String? settlingIdempotencyKey,
  }) {
    final knownRevision = previous.threadFollowRevisions[threadId] ?? 0;
    final authoritative =
        previous.authoritativeCurrentUserThreadFollows[threadId];
    final intents = <PendingThreadFollowIntent>[
      ...?previous.pendingThreadFollowIntents[threadId],
    ];
    final matchingSettlement = settlingIdempotencyKey != null &&
        intents
            .any((intent) => intent.idempotencyKey == settlingIdempotencyKey);

    if (followRevision == knownRevision &&
        authoritative != null &&
        !_sameValue(authoritative.toJson(), follow.toJson())) {
      if (follow.source != ThreadFollowSource.manual &&
          !authoritative.isFollowing &&
          authoritative.source == ThreadFollowSource.manual) {
        return previous;
      }
      throw NormalizedSnapshotConflict(
        'Thread $threadId changed at follow revision $knownRevision.',
      );
    }

    final latestIntent = intents.isEmpty ? null : intents.last;
    if (follow.source != ThreadFollowSource.manual &&
        (latestIntent?.intent == ThreadFollowMutationIntent.unfollow ||
            (latestIntent == null &&
                authoritative != null &&
                !authoritative.isFollowing &&
                authoritative.source == ThreadFollowSource.manual))) {
      return previous;
    }

    if (matchingSettlement) {
      intents.removeWhere(
        (intent) => intent.idempotencyKey == settlingIdempotencyKey,
      );
    }
    final acceptsCanonical = followRevision > knownRevision ||
        (followRevision == knownRevision && authoritative == null);
    if (!acceptsCanonical && !matchingSettlement) return previous;
    final nextAuthoritative = acceptsCanonical ? follow : authoritative;
    return _threadFollowState(
      previous,
      threadId,
      intents,
      nextAuthoritative,
      acceptsCanonical ? followRevision : knownRevision,
    );
  }

  /// Removes only the named failed/cancelled intent and preserves newer ones.
  NormalizedSnapshotState rollbackOptimisticThreadFollow(
    ConversationId threadId,
    String idempotencyKey,
  ) {
    _ensureOpen();
    final previous = _state;
    final existing = previous.pendingThreadFollowIntents[threadId];
    if (existing == null ||
        !existing.any((intent) => intent.idempotencyKey == idempotencyKey)) {
      return previous;
    }
    final intents = existing
        .where((intent) => intent.idempotencyKey != idempotencyKey)
        .toList(growable: false);
    return _commitThreadFollow(
      previous,
      threadId,
      intents,
      previous.authoritativeCurrentUserThreadFollows[threadId],
      previous.threadFollowRevisions[threadId] ?? 0,
    );
  }

  NormalizedSnapshotState rollbackAllOptimisticThreadFollows() {
    _ensureOpen();
    var next = _state;
    for (final threadId in next.pendingThreadFollowIntents.keys.toList()) {
      next = _commitThreadFollow(
        next,
        threadId,
        const [],
        next.authoritativeCurrentUserThreadFollows[threadId],
        next.threadFollowRevisions[threadId] ?? 0,
      );
    }
    return next;
  }

  NormalizedSnapshotState _commitThreadFollow(
    NormalizedSnapshotState previous,
    ConversationId threadId,
    List<PendingThreadFollowIntent> intents,
    CanonicalThreadFollowState? authoritative,
    int revision,
  ) =>
      _commit(
          previous,
          _threadFollowState(
              previous, threadId, intents, authoritative, revision));

  NormalizedSnapshotState _threadFollowState(
    NormalizedSnapshotState previous,
    ConversationId threadId,
    List<PendingThreadFollowIntent> intents,
    CanonicalThreadFollowState? authoritative,
    int revision,
  ) {
    final pending = <ConversationId, List<PendingThreadFollowIntent>>{
      ...previous.pendingThreadFollowIntents,
    };
    if (intents.isEmpty) {
      pending.remove(threadId);
    } else {
      pending[threadId] = List<PendingThreadFollowIntent>.unmodifiable(intents);
    }
    final projected = <ConversationId, CanonicalThreadFollowState>{
      ...previous.currentUserThreadFollows,
    };
    if (intents.isNotEmpty) {
      projected[threadId] = _projectThreadFollow(threadId, intents.last);
    } else if (authoritative != null) {
      projected[threadId] = authoritative;
    } else {
      projected.remove(threadId);
    }
    final authoritativeMap = <ConversationId, CanonicalThreadFollowState>{
      ...previous.authoritativeCurrentUserThreadFollows,
    };
    if (authoritative == null) {
      authoritativeMap.remove(threadId);
    } else {
      authoritativeMap[threadId] = authoritative;
    }
    return _copyState(
      previous,
      currentUserThreadFollows: Map.unmodifiable(projected),
      authoritativeCurrentUserThreadFollows: Map.unmodifiable(authoritativeMap),
      threadFollowRevisions: Map.unmodifiable({
        ...previous.threadFollowRevisions,
        if (revision > 0) threadId: revision,
      }),
      pendingThreadFollowIntents: Map.unmodifiable(pending),
    );
  }
}

CanonicalThreadFollowState _projectThreadFollow(
  ConversationId threadId,
  PendingThreadFollowIntent intent,
) {
  final target = ThreadFollowTarget(id: threadId);
  return intent.intent == ThreadFollowMutationIntent.follow
      ? CanonicalFollowingThreadState(
          target: target,
          source: ThreadFollowSource.manual,
          updatedAt: intent.projectedAt,
        )
      : CanonicalManualThreadUnfollowState(
          target: target,
          updatedAt: intent.projectedAt,
        );
}

void _requireKnownThreadFollowTarget(
  NormalizedSnapshotState state,
  ConversationId threadId,
) {
  final conversation = state.conversations[threadId];
  if (conversation is! ThreadConversation) {
    throw const NormalizedSnapshotConflict(
      'Thread follow requires a known thread conversation.',
    );
  }
  final parent = state.conversations[conversation.parentConversationId];
  final root = state.canonicalMessages[conversation.rootMessageId];
  if (parent == null ||
      parent is ThreadConversation ||
      root == null ||
      root.conversationId != parent.id) {
    throw const NormalizedSnapshotConflict(
      'Thread follow requires a known parent and root relationship.',
    );
  }
}

Object _threadFollowStateValue(
  NormalizedSnapshotState state,
  ConversationId threadId,
) =>
    <String, Object?>{
      'follow': state.currentUserThreadFollows[threadId]?.toJson(),
      'authoritative':
          state.authoritativeCurrentUserThreadFollows[threadId]?.toJson(),
      'revision': state.threadFollowRevisions[threadId] ?? 0,
      'pending': [
        for (final intent
            in state.pendingThreadFollowIntents[threadId] ?? const [])
          {
            'idempotencyKey': intent.idempotencyKey,
            'intent': intent.intent.toJson(),
            'expectedFollowRevision': intent.expectedFollowRevision,
            'projectedAt': intent.projectedAt.toJson(),
          },
      ],
    };

_DurableMessageMutation _reduceDurableThreadFollow(
  NormalizedSnapshotState state,
  ThreadFollowUpdatedDurableEvent event,
) {
  final payload = event.payload.data;
  final revision = payload['followRevision'];
  if (revision is! int || revision < 1) _durableInvalid(event);
  final follow = CanonicalThreadFollowState.fromJson(payload['follow']);
  final threadId = follow.target.id;
  final conversation = state.conversations[threadId];
  if (conversation is! ThreadConversation ||
      conversation.tenantId != event.tenantId) {
    _durableGap(event, conversationId: threadId);
  }
  try {
    _requireKnownThreadFollowTarget(state, threadId);
  } on NormalizedSnapshotConflict {
    _durableGap(event, conversationId: threadId);
  }

  final knownRevision = state.threadFollowRevisions[threadId] ?? 0;
  final authoritative = state.authoritativeCurrentUserThreadFollows[threadId];
  if (revision < knownRevision) return _DurableMessageMutation(state);
  if (revision == knownRevision &&
      authoritative != null &&
      !_sameValue(authoritative.toJson(), follow.toJson())) {
    if (follow.source != ThreadFollowSource.manual &&
        !authoritative.isFollowing &&
        authoritative.source == ThreadFollowSource.manual) {
      return _DurableMessageMutation(state);
    }
    _durableInvalid(event);
  }

  final intents = state.pendingThreadFollowIntents[threadId] ?? const [];
  final latestIntent = intents.isEmpty ? null : intents.last;
  if (follow.source != ThreadFollowSource.manual &&
      (latestIntent?.intent == ThreadFollowMutationIntent.unfollow ||
          (latestIntent == null &&
              authoritative != null &&
              !authoritative.isFollowing &&
              authoritative.source == ThreadFollowSource.manual))) {
    return _DurableMessageMutation(state);
  }
  if (revision == knownRevision && authoritative != null) {
    return _DurableMessageMutation(state);
  }

  final projected = intents.isEmpty
      ? Map<ConversationId, CanonicalThreadFollowState>.unmodifiable({
          ...state.currentUserThreadFollows,
          threadId: follow,
        })
      : state.currentUserThreadFollows;
  return _DurableMessageMutation(
    _copyState(
      state,
      currentUserThreadFollows: projected,
      authoritativeCurrentUserThreadFollows: Map.unmodifiable({
        ...state.authoritativeCurrentUserThreadFollows,
        threadId: follow,
      }),
      threadFollowRevisions: Map.unmodifiable({
        ...state.threadFollowRevisions,
        threadId: revision,
      }),
    ),
  );
}
