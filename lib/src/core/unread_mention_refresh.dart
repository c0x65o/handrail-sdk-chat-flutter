part of '../handrail_chat_client.dart';

/// Serializes snapshot authority per conversation. New changes during a query
/// invalidate its result and coalesce into one subsequent query.
final class _UnreadMentionRefreshCoordinator {
  _UnreadMentionRefreshCoordinator(this.client) {
    var previous = client.normalizedState.state;
    _subscription =
        client.normalizedState.acceptedCommitChanges.listen((state) {
      final before = previous;
      previous = state;
      for (final id in _pending.keys.toList()) {
        if (!state.conversations.containsKey(id) ||
            !state.currentUserReadStates.containsKey(id)) {
          _pending.remove(id)?.cancellation.cancel();
        }
      }
      // HTTP command settlements use the same store as durable events.
      // Optimistic copies and replay keep their revision and cannot add pings.
      if (!_paused &&
          !identical(before.canonicalMessages, state.canonicalMessages)) {
        for (final message in state.canonicalMessages.values) {
          final old = before.canonicalMessages[message.id];
          if ((old == null && message.replyTo != null) ||
              (old != null &&
                  message.revision.revision > old.revision.revision)) {
            request(message.conversationId);
          }
        }
      }
    });
  }

  final HandrailChatClient client;
  NormalizedSnapshotState? recoveredState;
  bool _paused = false;
  final Set<ConversationId> _deferred = {};
  final Map<ConversationId, _UnreadMentionRefresh> _pending = {};
  late final StreamSubscription<NormalizedSnapshotState> _subscription;

  void connected() {
    final recovered = recoveredState;
    recoveredState = null;
    if (identical(recovered, client.normalizedState.state)) return;
    for (final id in client.normalizedState.state.conversations.keys) {
      request(id);
    }
  }

  void pause() {
    invalidate();
    _paused = true;
  }

  void resume() {
    _paused = false;
    final deferred = _deferred.toList();
    _deferred.clear();
    for (final id in deferred) {
      request(id);
    }
  }

  void request(ConversationId id) {
    if (_paused) {
      _deferred.add(id);
      return;
    }
    if (client._disposed ||
        !client.normalizedState.state.conversations.containsKey(id)) {
      return;
    }
    final existing = _pending[id];
    if (existing != null) {
      existing.dirty = true;
      return;
    }
    final refresh = _UnreadMentionRefresh();
    _pending[id] = refresh;
    // Coalesce synchronous event bursts before starting transport work.
    unawaited(Future<void>.microtask(() => _drain(id, refresh)));
  }

  Future<void> _drain(ConversationId id, _UnreadMentionRefresh refresh) async {
    try {
      while (identical(_pending[id], refresh) && !client._disposed) {
        refresh.dirty = false;
        final before = client.normalizedState.state;
        final conversation = before.conversations[id];
        final read = before.currentUserReadStates[id];
        final members = before.membersByConversation[id];
        if (conversation == null || read == null) return;
        final result = await client.getConversation(
          ConversationDetailSnapshotInput(conversationId: id),
          options: ChatSnapshotQueryOptions(
            cancellationSignal: refresh.cancellation.signal,
          ),
        );
        if (client._disposed || !identical(_pending[id], refresh)) return;
        if (refresh.dirty) continue;
        final current = client.normalizedState.state;
        if (current.conversations[id] == null) return;
        if (!identical(current.currentUserReadStates[id], read) ||
            !identical(current.membersByConversation[id], members) ||
            !identical(current.durableStreams[id.value],
                before.durableStreams[id.value])) {
          continue;
        }
        if (result
            case ChatSnapshotQuerySuccess<ConversationDetailSnapshot>(
              :final value,
            )) {
          final summary = value.conversation.summary;
          if (summary.conversation.tenantId != conversation.tenantId ||
              summary.currentReadState.userId != read.userId ||
              summary.currentReadState.lastReadSequence.value <
                  read.lastReadSequence.value ||
              (summary.currentReadState.lastReadSequence ==
                      read.lastReadSequence &&
                  summary.currentReadState.updatedAt.value
                          .compareTo(read.updatedAt.value) <
                      0)) {
            return;
          }
          client.normalizedState.hydrateConversationDetail(value);
        } else if (_isRevokedSnapshotResult(result)) {
          client.realtimeSession?.clearConversationSubscription(id);
        }
        return;
      }
    } catch (_) {
      // Snapshot failures cannot fail canonical delivery. A later event or
      // connected session requests fresh authority again.
    } finally {
      if (identical(_pending[id], refresh)) _pending.remove(id);
      refresh.cancellation.cancel();
    }
  }

  void invalidate() {
    for (final refresh in _pending.values) {
      refresh.cancellation.cancel();
    }
    _pending.clear();
    _deferred.clear();
    recoveredState = null;
  }

  void close() {
    invalidate();
    unawaited(_subscription.cancel());
  }
}

final class _UnreadMentionRefresh {
  final cancellation = ChatCommandCancellationController();
  bool dirty = false;
}
