import 'dart:async';

import 'package:handrail_chat/core.dart';

/// Supplies the lab host's authenticated identity to shared reply controllers.
/// Merely knowing a source ID does not grant access: every load still goes
/// through the SDK's authorized context and conversation-detail endpoints.
final class BackendLabReplyContexts {
  BackendLabReplyContexts(this.client, this.session) {
    _commits =
        client.normalizedState.acceptedCommitChanges.listen((_) => _sync());
    _sessions = session.states.listen((_) => _sync());
    _sync();
  }

  final HandrailChatClient client;
  final ChatRealtimeSessionTransport session;
  late final StreamSubscription<NormalizedSnapshotState> _commits;
  late final StreamSubscription<ChatRealtimeLifecycleState> _sessions;
  final _configured = <ChatMessageContextController>{};
  (TenantId, UserId, DeviceId)? _identity;
  bool _disposed = false;

  void _sync() {
    if (_disposed) return;
    final connected = session.state;
    if (connected is! ChatRealtimeConnectedState) return;
    final identity = connected.identity;
    // The lab assigns a new device ID on reconnect. SDK storage activation
    // clears source authority at that boundary even for the same user.
    final key = (identity.tenantId, identity.userId, identity.deviceId);
    if (_identity != key) {
      _identity = key;
      _configured.clear();
    }
    final authority = ChatMessageContextAuthority(
      tenantId: identity.tenantId,
      userId: identity.userId,
      canRead: true,
    );
    void configure(ConversationId conversationId, MessageId messageId) {
      final controller =
          client.messageContexts.forMessage(MessageContextRequest(
        conversationId: conversationId,
        messageId: messageId,
      ));
      // Do not reset shared reads or regrant a revoked source on unrelated
      // commits. The SDK owns reconnect, revocation and identity invalidation.
      if (_configured.add(controller)) controller.setAuthority(authority);
    }

    final state = client.normalizedState.state;
    for (final message in state.canonicalMessages.values) {
      if (message.tenantId != identity.tenantId) continue;
      configure(message.conversationId, message.id);
      if (message.replyTo case final reply?) {
        configure(message.conversationId, reply.messageId);
      }
    }
    // A restored draft may refer to a source outside the loaded timeline.
    for (final entry in state.currentUserDrafts.entries) {
      if (entry.value case CanonicalReplacedDraft(:final content)) {
        if (content.replyTo case final reply?) {
          configure(entry.key, reply.messageId);
        }
      }
    }
  }

  Future<void> dispose() async {
    _disposed = true;
    await _commits.cancel();
    await _sessions.cancel();
    _configured.clear();
  }
}
