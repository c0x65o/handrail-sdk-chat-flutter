part of 'normalized_snapshot_state.dart';

/// One explicit local replacement waiting to settle.
final class PendingConversationPreferenceIntent {
  const PendingConversationPreferenceIntent({
    required this.idempotencyKey,
    required this.desiredPreference,
    required this.projectedAt,
  });

  final String idempotencyKey;
  final ConversationPreferenceDesiredState desiredPreference;
  final IsoTimestamp projectedAt;
}

/// Current renderer-facing and authoritative state for one conversation.
final class NormalizedConversationPreferenceState {
  NormalizedConversationPreferenceState({
    required this.conversationId,
    required this.authoritativeRevision,
    required List<PendingConversationPreferenceIntent> pendingIntents,
    this.preference,
    this.authoritativePreference,
  }) : pendingIntents = List.unmodifiable(pendingIntents);

  final ConversationId conversationId;
  final ConversationSnapshotPreference? preference;
  final ConversationSnapshotPreference? authoritativePreference;
  final int authoritativeRevision;
  final List<PendingConversationPreferenceIntent> pendingIntents;

  bool get isPending => pendingIntents.isNotEmpty;
}

extension NormalizedConversationPreferenceRuntime on NormalizedSnapshotStore {
  /// Returns the synchronous latest-local projection and canonical baseline.
  NormalizedConversationPreferenceState conversationPreference(
    ConversationId conversationId,
  ) {
    final state = _state;
    return NormalizedConversationPreferenceState(
      conversationId: conversationId,
      preference: state.currentUserPreferences[conversationId],
      authoritativePreference:
          state.authoritativeCurrentUserPreferences[conversationId],
      authoritativeRevision: state.preferenceRevisions[conversationId] ?? 0,
      pendingIntents:
          state.pendingConversationPreferenceIntents[conversationId] ??
              const [],
    );
  }

  /// A framework-neutral stream that emits current state immediately.
  Stream<NormalizedConversationPreferenceState> conversationPreferenceStates(
    ConversationId conversationId,
  ) {
    _ensureOpen();
    return Stream.multi((events) {
      final subscription = _conversationPreferenceChanges.stream
          .where((id) => id == conversationId)
          .listen((_) => events.add(conversationPreference(conversationId)));
      events.add(conversationPreference(conversationId));
      events.onCancel = subscription.cancel;
    });
  }

  /// Publishes an explicit desired state synchronously.
  NormalizedSnapshotState beginOptimisticConversationPreference(
    UpdateConversationPreferenceInput input,
    IsoTimestamp projectedAt,
  ) {
    _ensureOpen();
    final request = UpdateConversationPreferenceInput.fromJson(input.toJson());
    final previous = _state;
    if (!previous.conversations.containsKey(request.conversationId)) {
      throw NormalizedSnapshotConflict(
        'Preference update requires a known conversation.',
      );
    }
    final userId = _currentUserIdForConversation(
      previous,
      request.conversationId,
    );
    if (userId == null) {
      throw NormalizedSnapshotConflict(
        'Preference update requires known current-user state.',
      );
    }
    final knownRevision =
        previous.preferenceRevisions[request.conversationId] ?? 0;
    if (request.expectedPreferenceRevision != knownRevision) {
      throw NormalizedSnapshotConflict(
        'Preference update did not use the authoritative revision.',
      );
    }
    final intents = <PendingConversationPreferenceIntent>[
      ...?previous.pendingConversationPreferenceIntents[request.conversationId],
      PendingConversationPreferenceIntent(
        idempotencyKey: request.idempotencyKey,
        desiredPreference: request.preference,
        projectedAt: projectedAt,
      ),
    ];
    final authoritative =
        previous.authoritativeCurrentUserPreferences[request.conversationId] ??
            previous.currentUserPreferences[request.conversationId];
    final projection = _snapshotPreference(
      request.conversationId,
      userId,
      request.preference,
      projectedAt,
    );
    return _commit(
      previous,
      _copyState(
        previous,
        currentUserPreferences: Map.unmodifiable({
          ...previous.currentUserPreferences,
          request.conversationId: projection,
        }),
        authoritativeCurrentUserPreferences: authoritative == null
            ? previous.authoritativeCurrentUserPreferences
            : Map.unmodifiable({
                ...previous.authoritativeCurrentUserPreferences,
                request.conversationId: authoritative,
              }),
        pendingConversationPreferenceIntents: Map<ConversationId,
            List<PendingConversationPreferenceIntent>>.unmodifiable({
          ...previous.pendingConversationPreferenceIntents,
          request.conversationId:
              List<PendingConversationPreferenceIntent>.unmodifiable(intents),
        }),
      ),
    );
  }

  /// Shared HTTP/realtime convergence for canonical private preference state.
  ///
  /// Returns false for stale or duplicate canonical state. Equal-revision
  /// divergent rows throw without publishing a partial change.
  bool reconcileConversationPreferenceMutation(
    UpdateConversationPreferenceInput input,
    UpdateConversationPreferenceResult result,
  ) {
    _ensureOpen();
    final request = UpdateConversationPreferenceInput.fromJson(input.toJson());
    final parsed = UpdateConversationPreferenceResult.fromJson(
      result.toJson(),
      expectedInput: request,
    );
    final previous = _state;
    final id = parsed.conversationId;
    if (!previous.conversations.containsKey(id)) {
      throw NormalizedSnapshotConflict(
        'Canonical preference requires a known conversation.',
      );
    }
    final userId = _currentUserIdForConversation(previous, id);
    if (userId == null) {
      throw NormalizedSnapshotConflict(
        'Canonical preference requires known current-user state.',
      );
    }
    final incoming = _snapshotPreference(
      id,
      userId,
      parsed.preference.preference,
      parsed.preference.updatedAt,
    );
    final knownRevision = previous.preferenceRevisions[id] ?? 0;
    final authoritative = previous.authoritativeCurrentUserPreferences[id];
    if (parsed.preferenceRevision == knownRevision &&
        authoritative != null &&
        !_sameValue(authoritative.toJson(), incoming.toJson())) {
      throw NormalizedSnapshotConflict(
        'Preference $id changed at revision $knownRevision.',
      );
    }

    final intents = <PendingConversationPreferenceIntent>[
      ...?previous.pendingConversationPreferenceIntents[id],
    ];
    final removed = intents.length;
    intents.removeWhere(
      (intent) => intent.idempotencyKey == parsed.idempotencyKey,
    );
    final settledIntent = removed != intents.length;
    final acceptsCanonical = parsed.preferenceRevision > knownRevision ||
        (parsed.preferenceRevision == knownRevision && authoritative == null);
    if (!acceptsCanonical && !settledIntent) return false;

    final nextAuthoritative = acceptsCanonical ? incoming : authoritative;
    final pending = <ConversationId, List<PendingConversationPreferenceIntent>>{
      ...previous.pendingConversationPreferenceIntents,
    };
    if (intents.isEmpty) {
      pending.remove(id);
    } else {
      pending[id] =
          List<PendingConversationPreferenceIntent>.unmodifiable(intents);
    }
    final preferences = <ConversationId, ConversationSnapshotPreference>{
      ...previous.currentUserPreferences,
    };
    if (intents.isNotEmpty) {
      final latest = intents.last;
      preferences[id] = _snapshotPreference(
        id,
        userId,
        latest.desiredPreference,
        latest.projectedAt,
      );
    } else if (nextAuthoritative != null) {
      preferences[id] = nextAuthoritative;
    } else {
      preferences.remove(id);
    }
    final next = _copyState(
      previous,
      currentUserPreferences: Map.unmodifiable(preferences),
      authoritativeCurrentUserPreferences: nextAuthoritative == null
          ? previous.authoritativeCurrentUserPreferences
          : Map.unmodifiable({
              ...previous.authoritativeCurrentUserPreferences,
              id: nextAuthoritative,
            }),
      preferenceRevisions: acceptsCanonical
          ? Map.unmodifiable({
              ...previous.preferenceRevisions,
              id: parsed.preferenceRevision,
            })
          : previous.preferenceRevisions,
      pendingConversationPreferenceIntents: Map<ConversationId,
          List<PendingConversationPreferenceIntent>>.unmodifiable(pending),
    );
    _commit(previous, next);
    return acceptsCanonical || settledIntent;
  }

  /// Removes only the named intent and reprojects any newer replacement.
  NormalizedSnapshotState rollbackOptimisticConversationPreference(
    ConversationId conversationId,
    String idempotencyKey,
  ) {
    _ensureOpen();
    final previous = _state;
    final existing =
        previous.pendingConversationPreferenceIntents[conversationId];
    if (existing == null ||
        !existing.any((intent) => intent.idempotencyKey == idempotencyKey)) {
      return previous;
    }
    final intents = existing
        .where((intent) => intent.idempotencyKey != idempotencyKey)
        .toList(growable: false);
    return _settleConversationPreferenceIntents(
      previous,
      conversationId,
      intents,
    );
  }

  /// Clears optimistic-only preference work while retaining canonical rows.
  NormalizedSnapshotState rollbackAllOptimisticConversationPreferences() {
    _ensureOpen();
    var next = _state;
    for (final id in next.pendingConversationPreferenceIntents.keys.toList()) {
      next = _settleConversationPreferenceIntents(next, id, const []);
    }
    return next;
  }

  NormalizedSnapshotState _settleConversationPreferenceIntents(
    NormalizedSnapshotState previous,
    ConversationId conversationId,
    List<PendingConversationPreferenceIntent> intents,
  ) {
    final pending = <ConversationId, List<PendingConversationPreferenceIntent>>{
      ...previous.pendingConversationPreferenceIntents,
    };
    if (intents.isEmpty) {
      pending.remove(conversationId);
    } else {
      pending[conversationId] =
          List<PendingConversationPreferenceIntent>.unmodifiable(intents);
    }
    final preferences = <ConversationId, ConversationSnapshotPreference>{
      ...previous.currentUserPreferences,
    };
    if (intents.isNotEmpty) {
      final userId = _currentUserIdForConversation(previous, conversationId);
      if (userId == null) {
        throw NormalizedSnapshotConflict(
          'Pending preference lost current-user identity.',
        );
      }
      final latest = intents.last;
      preferences[conversationId] = _snapshotPreference(
        conversationId,
        userId,
        latest.desiredPreference,
        latest.projectedAt,
      );
    } else if (previous.authoritativeCurrentUserPreferences[conversationId]
        case final authoritative?) {
      preferences[conversationId] = authoritative;
    } else {
      preferences.remove(conversationId);
    }
    return _commit(
      previous,
      _copyState(
        previous,
        currentUserPreferences: Map.unmodifiable(preferences),
        pendingConversationPreferenceIntents: Map<ConversationId,
            List<PendingConversationPreferenceIntent>>.unmodifiable(pending),
      ),
    );
  }
}

NormalizedSnapshotState _mergeHydratedConversationPreference(
  NormalizedSnapshotState state,
  ConversationSnapshotPreference incoming,
) {
  final id = incoming.conversationId;
  final existing = state.authoritativeCurrentUserPreferences[id] ??
      (state.pendingConversationPreferenceIntents[id] == null
          ? state.currentUserPreferences[id]
          : null);
  final revision = incoming.preferenceRevision;
  final knownRevision = state.preferenceRevisions[id] ?? 0;
  final acceptsRevision = revision != null && revision >= knownRevision;
  final authoritative = revision != null
      ? (acceptsRevision ? incoming : existing ?? incoming)
      : _pickTimestamped(
          existing,
          incoming,
          (value) => value.updatedAt,
          'preference for $id',
          // Legacy detail reads omit the revision carried by creation and
          // mutation results. Equal preference values still represent the same
          // state; retain the existing revision and reject actual conflicts.
          (value) => value.toJson()..remove('preferenceRevision'),
        );
  final revisions = acceptsRevision && state.preferenceRevisions[id] != revision
      ? Map<ConversationId, int>.unmodifiable({
          ...state.preferenceRevisions,
          id: revision,
        })
      : state.preferenceRevisions;
  final hasPending =
      state.pendingConversationPreferenceIntents[id]?.isNotEmpty == true;
  final projected =
      hasPending ? state.currentUserPreferences[id] : authoritative;
  if (identical(revisions, state.preferenceRevisions) &&
      identical(authoritative, state.authoritativeCurrentUserPreferences[id]) &&
      identical(projected, state.currentUserPreferences[id])) {
    return state;
  }
  return _copyState(
    state,
    preferenceRevisions: revisions,
    currentUserPreferences: projected == null
        ? state.currentUserPreferences
        : Map.unmodifiable({...state.currentUserPreferences, id: projected}),
    authoritativeCurrentUserPreferences: Map.unmodifiable({
      ...state.authoritativeCurrentUserPreferences,
      id: authoritative,
    }),
  );
}

ConversationSnapshotPreference _snapshotPreference(
  ConversationId conversationId,
  UserId userId,
  ConversationPreferenceDesiredState desired,
  IsoTimestamp updatedAt,
) =>
    ConversationSnapshotPreference.fromJson({
      'conversationId': conversationId.toJson(),
      'userId': userId.toJson(),
      'notificationPreference': desired.notificationPreference.toJson(),
      'isStarred': desired.isStarred,
      'mute': desired.mute.toJson(),
      'updatedAt': updatedAt.toJson(),
    });

Object? _conversationPreferenceStateValue(
  NormalizedSnapshotState state,
  ConversationId conversationId,
) =>
    {
      'preference': state.currentUserPreferences[conversationId]?.toJson(),
      'authoritative':
          state.authoritativeCurrentUserPreferences[conversationId]?.toJson(),
      'revision': state.preferenceRevisions[conversationId] ?? 0,
      'pending': [
        for (final intent
            in state.pendingConversationPreferenceIntents[conversationId] ??
                const <PendingConversationPreferenceIntent>[])
          {
            'idempotencyKey': intent.idempotencyKey,
            'desiredPreference': intent.desiredPreference.toJson(),
            'projectedAt': intent.projectedAt.toJson(),
          },
      ],
    };
