import 'package:handrail_chat/core.dart';

NormalizedSnapshotStore seedStorageLabConversation() {
  final store = NormalizedSnapshotStore();
  store.hydrateConversationList(ConversationListSnapshot.fromJson({
    'kind': 'conversation_list',
    'scope': const OrganizationConversationSnapshotScope().toJson(),
    'items': [
      {
        'id': 'conversation-1',
        'tenantId': 'tenant-1',
        'type': 'channel',
        'name': 'Queue pump',
        'visibility': 'public',
        'createdAt': '2026-08-26T15:00:00.000Z',
        'updatedAt': '2026-08-26T15:00:00.000Z',
        'latestSequence': 8,
        'activityAt': '2026-08-26T15:00:00.000Z',
        'unreadMentionCount': 0,
        'currentMember': {
          'tenantId': 'tenant-1',
          'conversationId': 'conversation-1',
          'userId': 'user-1',
          'role': 'member',
          'state': 'active',
          'joinedAt': '2026-08-26T15:00:00.000Z',
          'updatedAt': '2026-08-26T15:00:00.000Z',
        },
        'currentReadState': {
          'conversationId': 'conversation-1',
          'userId': 'user-1',
          'lastReadSequence': 0,
          'updatedAt': '2026-08-26T15:00:00.000Z',
        },
        'currentPreference': {
          'conversationId': 'conversation-1',
          'userId': 'user-1',
          'notificationPreference': 'mentions',
          'isStarred': false,
          'mute': {'muted': false},
          'updatedAt': '2026-08-26T15:00:00.000Z',
        },
        'activeMemberUserIds': ['user-1'],
      },
    ],
    'page': <String, Object?>{},
    '_meta': {
      ...storageLabMetadata,
      'enabledFeatures': {
        'realtime': true,
        conversationSnapshotFeature: true,
      },
      'feature': {
        'name': conversationSnapshotFeature,
        'version': conversationSnapshotVersion,
      },
    },
  }));
  return store;
}

const Map<String, Object?> storageLabMetadata = {
  'packageVersion': '0.1.3',
  'protocolVersion': handrailChatProtocolVersion,
  'schemaVersion': 1,
  'enabledFeatures': <String, Object?>{'realtime': true},
  'supportedProtocolRange': <String, Object?>{
    'minimumVersion': 3,
    'maximumVersion': handrailChatProtocolVersion,
  },
};
