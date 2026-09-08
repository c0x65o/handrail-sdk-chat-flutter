const threadCreationInputFixture = <String, Object?>{
  'operation': 'create_thread',
  'parentConversationId': 'conversation-parent',
  'rootMessageId': 'message-root',
  'initialFollow': true,
  'idempotencyKey': 'create-thread-1',
};

Map<String, Object?> threadCreationResultFixture(
  String status, {
  String parentConversationId = 'conversation-parent',
  String rootMessageId = 'message-root',
  String threadId = 'conversation-thread',
  String summaryThreadId = 'conversation-thread',
  String? threadParentConversationId,
  String? threadRootMessageId,
  bool threadConversation = true,
}) =>
    <String, Object?>{
      'operation': 'create_thread',
      'reconciliationStatus': status,
      'parentConversationId': parentConversationId,
      'rootMessageId': rootMessageId,
      'conversation': _detailFixture(
        parentConversationId:
            threadParentConversationId ?? parentConversationId,
        rootMessageId: threadRootMessageId ?? rootMessageId,
        threadId: threadId,
        threadConversation: threadConversation,
      ),
      'rootThreadSummary': {
        'threadId': summaryThreadId,
        'replyCount': 2,
        'participantIds': ['user-current', 'user-other'],
        'unreadCount': 1,
        'lastReplyAt': _now,
      },
    };

Map<String, Object?> _detailFixture({
  required String parentConversationId,
  required String rootMessageId,
  required String threadId,
  required bool threadConversation,
}) {
  final conversation = threadConversation
      ? <String, Object?>{
          'id': threadId,
          'tenantId': _tenantId,
          'type': 'thread',
          'visibility': 'private',
          'parentConversationId': parentConversationId,
          'rootMessageId': rootMessageId,
          'createdAt': _now,
          'updatedAt': _now,
        }
      : <String, Object?>{
          'id': threadId,
          'tenantId': _tenantId,
          'type': 'channel',
          'name': 'Not a thread',
          'visibility': 'private',
          'createdAt': _now,
          'updatedAt': _now,
        };
  return <String, Object?>{
    'kind': 'conversation_detail',
    'conversation': {
      ...conversation,
      'latestSequence': 2,
      'activityAt': _now,
      'unreadMentionCount': 0,
      'currentMember': {
        'tenantId': _tenantId,
        'conversationId': threadId,
        'userId': 'user-current',
        'role': 'member',
        'state': 'active',
        'joinedAt': _now,
        'updatedAt': _now,
      },
      'currentReadState': {
        'conversationId': threadId,
        'userId': 'user-current',
        'lastReadSequence': 1,
        'updatedAt': _now,
      },
      'memberUserIds': ['user-current', 'user-other'],
      'currentPreference': {
        'conversationId': threadId,
        'userId': 'user-current',
        'notificationPreference': 'all',
        'isStarred': false,
        'mute': {'muted': false},
        'updatedAt': _now,
      },
      'activeMemberUserIds': ['user-current', 'user-other'],
    },
    '_meta': {
      'packageVersion': '0.1.4',
      'protocolVersion': 1,
      'schemaVersion': 1,
      'enabledFeatures': {'thread_creation': true},
      'supportedProtocolRange': {
        'minimumVersion': 1,
        'maximumVersion': 1,
      },
      'feature': {
        'name': 'conversation_snapshots',
        'version': 1,
      },
    },
  };
}

const _tenantId = 'tenant-from-session';
const _now = '2026-08-26T16:00:00.000Z';
