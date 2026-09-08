part of 'normalized_snapshot_state.dart';

/// Lifecycle has its own revision clock, independent of conversation activity.
Conversation _mergeThreadLifecycle(Conversation base, Conversation? other) {
  if (base is! ThreadConversation || other is! ThreadConversation) return base;
  if (base.id != other.id ||
      base.tenantId != other.tenantId ||
      base.parentConversationId != other.parentConversationId ||
      base.rootMessageId != other.rootMessageId) {
    throw const NormalizedSnapshotConflict('Thread identity changed.');
  }
  final a = base.threadLifecycle, b = other.threadLifecycle;
  if (b == null) return base;
  if (a != null &&
      a.revision == b.revision &&
      !_sameValue(a.toJson(), b.toJson())) {
    throw const NormalizedSnapshotConflict(
        'Conflicting thread lifecycle revision.');
  }
  if (a != null && a.revision >= b.revision) return base;
  return ThreadConversation.fromJson(
      {...base.toJson(), 'threadLifecycle': b.toJson()});
}

NormalizedSnapshotState _withThreadLifecycle(NormalizedSnapshotState state,
    ConversationId threadId, ThreadLifecycle lifecycle) {
  final existing = state.conversations[threadId];
  if (existing is! ThreadConversation) {
    throw const NormalizedSnapshotConflict('Canonical thread is unavailable.');
  }
  final incoming = ThreadConversation.fromJson({
    ...existing.toJson(),
    'threadLifecycle': lifecycle.toJson(),
  });
  final merged = _mergeThreadLifecycle(existing, incoming);
  if (identical(merged, existing)) return state;
  return _copyState(state,
      conversations: Map.unmodifiable({
        ...state.conversations,
        threadId: merged,
      }));
}

_DurableMessageMutation _reduceThreadLifecycle(
    NormalizedSnapshotState state, ThreadLifecycleUpdatedDurableEvent event) {
  final payload = event.payload.data;
  final id = ConversationId.fromJson(payload['threadId']);
  final thread = state.conversations[id];
  if (thread == null) _durableGap(event);
  if (thread is! ThreadConversation ||
      thread.tenantId != event.tenantId ||
      thread.parentConversationId.value != payload['parentConversationId'] ||
      event.streamId != id.value) {
    _durableInvalid(event);
  }
  return _DurableMessageMutation(_withThreadLifecycle(
      state, id, ThreadLifecycle.fromJson(payload['threadLifecycle'])));
}

_DurableMessageMutation _reduceThreadLifecycleInvalidation(
    NormalizedSnapshotState state, ThreadLifecycleChangedDurableEvent event) {
  final parent = state.conversations[
      ConversationId.fromJson(event.payload.data['parentConversationId'])];
  if (parent == null) _durableGap(event);
  if (parent.tenantId != event.tenantId || event.streamId != parent.id.value) {
    _durableInvalid(event);
  }
  // Discovery invalidation contains no canonical lifecycle state.
  return _DurableMessageMutation(state);
}
