import 'dart:async';

import 'package:handrail_chat/core.dart';

/// Binds the reply-styles lab's host permissions to hydrated thread controllers.
/// Alice/Bob manage threads, Carol can send, and Dave has read-only grants in
/// examples/drop-in-react/scripts/chat-lab-backend.mjs. Server access checks
/// remain authoritative for every read and mutation.
final class BackendLabThreadLifecycles {
  BackendLabThreadLifecycles(this.client, this.session) {
    _commits =
        client.normalizedState.acceptedCommitChanges.listen((_) => _sync());
    _sessions = session.states.listen((_) => scheduleMicrotask(_sync));
    _sync();
  }

  final HandrailChatClient client;
  final ChatRealtimeSessionTransport session;
  late final StreamSubscription<NormalizedSnapshotState> _commits;
  late final StreamSubscription<ChatRealtimeLifecycleState> _sessions;
  final _configured = <ConversationId>{};
  (TenantId, UserId, DeviceId)? _identity;
  bool _disposed = false;

  void _sync() {
    if (_disposed) return;
    final connected = session.state;
    if (connected is! ChatRealtimeConnectedState) return;
    final identity = connected.identity;
    final key = (identity.tenantId, identity.userId, identity.deviceId);
    if (_identity != key) {
      _identity = key;
      _configured.clear();
    }
    for (final conversation
        in client.normalizedState.state.conversations.values) {
      if (conversation is! ThreadConversation ||
          conversation.tenantId != identity.tenantId ||
          !_configured.add(conversation.id)) {
        continue;
      }
      final controller = client.threadLifecycles.forThread(conversation.id);
      // Configure once per accepted identity, so unrelated commits cannot
      // regrant a revoked thread or cancel an in-flight operation.
      controller.setAuthority(ChatThreadLifecycleAuthority(
        tenantId: identity.tenantId,
        userId: identity.userId,
        canRead: true,
        canSend: identity.userId.value != 'dave',
        canManage: identity.userId.value == 'alice' || identity.userId.value == 'bob',
      ));
      unawaited(controller.load());
    }
  }

  Future<void> dispose() async {
    _disposed = true;
    await _commits.cancel();
    await _sessions.cancel();
    _configured.clear();
  }
}
