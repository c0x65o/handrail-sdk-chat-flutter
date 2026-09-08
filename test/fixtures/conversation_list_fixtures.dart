import 'dart:convert';

import 'package:handrail_chat/core.dart';

const conversationListTestNow = '2026-08-26T23:00:00.000Z';
const conversationListTestTenant = 'tenant-list';
const conversationListTestUser = 'user-list';

Map<String, Object?> conversationListPage({
  Map<String, Object?> scope = const {'type': 'organization'},
  List<Map<String, Object?>> items = const [],
  String? nextCursor,
}) =>
    {
      'kind': 'conversation_list',
      'scope': scope,
      'items': items,
      'page': {
        if (nextCursor != null) 'nextCursor': nextCursor,
      },
      '_meta': conversationListMetadata(),
    };

Map<String, Object?> conversationListSummary({
  required String id,
  required String name,
  String type = 'channel',
  String visibility = 'public',
  int latestSequence = 0,
  int lastReadSequence = 0,
  int? manualUnreadFromSequence,
  bool archived = false,
  bool isStarred = false,
  String notificationPreference = 'mentions',
  Map<String, Object?> mute = const {'muted': false},
}) =>
    {
      'id': id,
      'tenantId': conversationListTestTenant,
      'type': type,
      if (type == 'channel') 'name': name,
      'visibility': visibility,
      if (type == 'thread') ...{
        'parentConversationId': 'parent-$id',
        'rootMessageId': 'root-$id',
      },
      'createdAt': conversationListTestNow,
      'updatedAt': conversationListTestNow,
      if (archived) ...{
        'archivedAt': conversationListTestNow,
        'archivedByUserId': conversationListTestUser,
      },
      'latestSequence': latestSequence,
      'activityAt': conversationListTestNow,
      'unreadMentionCount': 0,
      'currentMember': {
        'tenantId': conversationListTestTenant,
        'conversationId': id,
        'userId': conversationListTestUser,
        'role': 'member',
        'state': 'active',
        'joinedAt': conversationListTestNow,
        'updatedAt': conversationListTestNow,
      },
      'currentReadState': {
        'conversationId': id,
        'userId': conversationListTestUser,
        'lastReadSequence': lastReadSequence,
        if (manualUnreadFromSequence != null)
          'manualUnreadFromSequence': manualUnreadFromSequence,
        'updatedAt': conversationListTestNow,
      },
      'currentPreference': {
        'conversationId': id,
        'userId': conversationListTestUser,
        'isStarred': isStarred,
        'notificationPreference': notificationPreference,
        'mute': mute,
        'updatedAt': conversationListTestNow,
      },
      'activeMemberUserIds': [conversationListTestUser],
    };

Map<String, Object?> conversationListMetadata() => {
      'packageVersion': '0.1.3',
      'protocolVersion': 4,
      'schemaVersion': 9,
      'enabledFeatures': {conversationSnapshotFeature: true},
      'supportedProtocolRange': {
        'minimumVersion': 3,
        'maximumVersion': 4,
      },
      'feature': {
        'name': conversationSnapshotFeature,
        'version': conversationSnapshotVersion,
      },
    };

String conversationListCursor(String id) =>
    'handrail-conversations.v1.${Uri.encodeComponent(jsonEncode([
          conversationListTestNow,
          id,
        ]))}';
