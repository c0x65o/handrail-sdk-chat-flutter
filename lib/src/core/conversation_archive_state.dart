part of 'normalized_snapshot_state.dart';

/// Canonical and optimistic lifecycle state exposed with conversation
/// selectors.
///
/// [authoritativeConversation] always remains the latest server-backed row.
/// [projectedArchived] overlays only the explicit pending intent, so an
/// optimistic archive never fabricates an archive timestamp or actor identity.
final class NormalizedConversationLifecycleProjection {
  NormalizedConversationLifecycleProjection({
    required this.conversationId,
    required this.authoritativeConversation,
    required this.authoritativeRevision,
    required this.authoritativeArchived,
    required List<ConversationArchiveInput> pendingIntents,
  }) : pendingIntents = List.unmodifiable(pendingIntents);

  final ConversationId conversationId;
  final Conversation? authoritativeConversation;
  final int? authoritativeRevision;
  final List<ConversationArchiveInput> pendingIntents;

  ConversationArchiveIntent? get pendingIntent =>
      pendingIntents.isEmpty ? null : pendingIntents.last.intent;

  final bool? authoritativeArchived;

  bool? get projectedArchived => switch (pendingIntent) {
        ConversationArchiveIntent.archive => true,
        ConversationArchiveIntent.restore => false,
        null => authoritativeArchived,
      };

  ConversationArchiveState? get authoritativeArchiveState {
    final conversation = authoritativeConversation;
    if (conversation == null) return null;
    if (authoritativeArchived == false) {
      return const ActiveConversationArchiveState();
    }
    final archivedAt = conversation.archivedAt;
    final archivedByUserId = conversation.archivedByUserId;
    if (archivedAt == null || archivedByUserId == null) {
      return authoritativeArchived == true
          ? null
          : const ActiveConversationArchiveState();
    }
    return ArchivedConversationArchiveState(
      archivedAt: archivedAt,
      archivedByUserId: archivedByUserId,
    );
  }
}

/// Optimistic conversation lifecycle support for [NormalizedSnapshotStore].
extension NormalizedConversationArchiveStateStore on NormalizedSnapshotStore {
  void beginOptimisticConversationArchive(ConversationArchiveInput input) {
    _ensureOpen();
    final validated = ConversationArchiveInput.fromJson(input.toJson());
    final previous = _state;
    final current =
        previous.pendingConversationArchiveInputs[validated.conversationId] ??
            const <ConversationArchiveInput>[];
    if (current.any(
      (pending) => pending.idempotencyKey == validated.idempotencyKey,
    )) {
      throw NormalizedSnapshotConflict(
        'Conversation archive idempotency keys must be unique per lane.',
      );
    }
    _commit(
      previous,
      _copyState(
        previous,
        pendingConversationArchiveInputs: Map.unmodifiable({
          ...previous.pendingConversationArchiveInputs,
          validated.conversationId: List<ConversationArchiveInput>.unmodifiable(
            [...current, validated],
          ),
        }),
      ),
    );
  }

  void reconcileOptimisticConversationArchive(
    String idempotencyKey,
    ConversationArchiveResult result,
  ) {
    _ensureOpen();
    final previous = _state;
    final pending =
        previous.pendingConversationArchiveInputs[result.conversationId] ??
            const <ConversationArchiveInput>[];
    final requestIndex = pending.indexWhere(
      (input) => input.idempotencyKey == idempotencyKey,
    );
    if (requestIndex < 0) {
      throw NormalizedSnapshotConflict(
        'Conversation archive result has no matching pending intent.',
      );
    }
    final request = pending[requestIndex];
    ConversationArchiveResult.fromJson(
      result.toJson(),
      expectedInput: request,
    );

    var conversations = previous.conversations;
    var lifecycleRevisions = previous.lifecycleRevisions;
    var lifecycleArchivedStates = previous.lifecycleArchivedStates;
    final knownRevision = lifecycleRevisions[result.conversationId];
    if (knownRevision == null || result.lifecycleRevision >= knownRevision) {
      final existing = conversations[result.conversationId];
      if (existing == null &&
          result.reconciliationStatus !=
              ConversationArchiveReconciliationStatus.lifecycleConflict) {
        throw NormalizedSnapshotConflict(
          'Canonical archive state for ${result.conversationId} requires a '
          'known conversation.',
        );
      }
      if (existing != null) {
        final authoritative = _conversationWithArchiveState(
          existing,
          result.archiveState,
        );
        if (knownRevision == result.lifecycleRevision &&
            !_sameValue(existing.toJson(), authoritative.toJson())) {
          throw NormalizedSnapshotConflict(
            'Conversation ${result.conversationId} changed at lifecycle '
            'revision $knownRevision.',
          );
        }
        if (!_sameValue(existing.toJson(), authoritative.toJson())) {
          conversations = Map.unmodifiable({
            ...conversations,
            result.conversationId: authoritative,
          });
        }
      }
      lifecycleRevisions = Map.unmodifiable({
        ...lifecycleRevisions,
        result.conversationId: result.lifecycleRevision,
      });
      lifecycleArchivedStates = Map.unmodifiable({
        ...lifecycleArchivedStates,
        result.conversationId:
            result.archiveState is ArchivedConversationArchiveState,
      });
    }

    _commit(
      previous,
      _copyState(
        previous,
        conversations: conversations,
        lifecycleRevisions: lifecycleRevisions,
        lifecycleArchivedStates: lifecycleArchivedStates,
        pendingConversationArchiveInputs: _withoutConversationArchiveIntent(
          previous.pendingConversationArchiveInputs,
          result.conversationId,
          idempotencyKey,
        ),
      ),
    );
  }

  void rollbackOptimisticConversationArchive(
    ConversationId conversationId,
    String idempotencyKey,
  ) {
    _ensureOpen();
    final previous = _state;
    final pending = previous.pendingConversationArchiveInputs[conversationId];
    if (pending == null ||
        !pending.any((input) => input.idempotencyKey == idempotencyKey)) {
      return;
    }
    _commit(
      previous,
      _copyState(
        previous,
        pendingConversationArchiveInputs: _withoutConversationArchiveIntent(
          previous.pendingConversationArchiveInputs,
          conversationId,
          idempotencyKey,
        ),
      ),
    );
  }

  void rollbackAllOptimisticConversationArchives() {
    _ensureOpen();
    if (_state.pendingConversationArchiveInputs.isEmpty) return;
    final previous = _state;
    _commit(
      previous,
      _copyState(
        previous,
        pendingConversationArchiveInputs: const {},
      ),
    );
  }
}

NormalizedConversationLifecycleProjection? _conversationLifecycleFrom(
  NormalizedSnapshotState state,
  ConversationId conversationId,
) {
  final conversation = state.conversations[conversationId];
  final revision = state.lifecycleRevisions[conversationId];
  final pending = state.pendingConversationArchiveInputs[conversationId] ??
      const <ConversationArchiveInput>[];
  if (conversation == null && revision == null && pending.isEmpty) return null;
  return NormalizedConversationLifecycleProjection(
    conversationId: conversationId,
    authoritativeConversation: conversation,
    authoritativeRevision: revision,
    authoritativeArchived: state.lifecycleArchivedStates[conversationId] ??
        (conversation == null ? null : conversation.archivedAt != null),
    pendingIntents: pending,
  );
}

Map<ConversationId, List<ConversationArchiveInput>>
    _withoutConversationArchiveIntent(
  Map<ConversationId, List<ConversationArchiveInput>> pendingByConversation,
  ConversationId conversationId,
  String idempotencyKey,
) {
  final remaining = (pendingByConversation[conversationId] ?? const [])
      .where((input) => input.idempotencyKey != idempotencyKey)
      .toList(growable: false);
  return Map.unmodifiable({
    for (final entry in pendingByConversation.entries)
      if (entry.key != conversationId) entry.key: entry.value,
    if (remaining.isNotEmpty)
      conversationId: List<ConversationArchiveInput>.unmodifiable(remaining),
  });
}

Conversation _conversationWithArchiveState(
  Conversation conversation,
  ConversationArchiveState state,
) {
  final json = Map<String, Object?>.from(conversation.toJson());
  if (state case ArchivedConversationArchiveState archived) {
    json['archivedAt'] = archived.archivedAt.toJson();
    json['archivedByUserId'] = archived.archivedByUserId.toJson();
    if (DateTime.parse(archived.archivedAt.value)
        .isAfter(DateTime.parse(conversation.updatedAt.value))) {
      json['updatedAt'] = archived.archivedAt.toJson();
    }
  } else {
    json.remove('archivedAt');
    json.remove('archivedByUserId');
  }
  return Conversation.fromJson(json);
}

Object? _conversationLifecycleValue(
  NormalizedConversationLifecycleProjection? lifecycle,
) =>
    lifecycle == null
        ? null
        : {
            'conversationId': lifecycle.conversationId.toJson(),
            'authoritativeConversation':
                lifecycle.authoritativeConversation?.toJson(),
            'authoritativeRevision': lifecycle.authoritativeRevision,
            'pendingIntents': [
              for (final input in lifecycle.pendingIntents) input.toJson(),
            ],
            'projectedArchived': lifecycle.projectedArchived,
          };
