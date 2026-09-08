import 'dart:convert';

const channelConversationCreationInputFixture = <String, Object?>{
  'operation': 'create_conversation',
  'type': 'channel',
  'name': 'Order coordination',
  'visibility': 'private',
  'entity': {'type': 'erp.order', 'id': 'order/42'},
  'idempotencyKey': 'create-channel-1',
  'clientRequestId': 'request-channel-1',
};

const directConversationCreationInputFixture = <String, Object?>{
  'operation': 'create_conversation',
  'type': 'direct',
  'visibility': 'private',
  'intendedMemberUserIds': ['user-b'],
  'idempotencyKey': 'create-direct-1',
  'clientRequestId': 'request-direct-1',
};

const groupDirectConversationCreationInputFixture = <String, Object?>{
  'operation': 'create_conversation',
  'type': 'group_direct',
  'visibility': 'private',
  'intendedMemberUserIds': ['user-c', 'user-b'],
  'idempotencyKey': 'create-group-1',
  'clientRequestId': 'request-group-1',
};

Map<String, Object?> conversationCreationResultFixture(
  String type,
  String status, {
  String? clientRequestId,
  String conversationTypeOverride = '',
  List<String>? participantUserIds,
  String? participantKey,
  bool includeParticipantIdentity = true,
}) {
  final effectiveType =
      conversationTypeOverride.isEmpty ? type : conversationTypeOverride;
  final requestId = clientRequestId ??
      switch (type) {
        'channel' => 'request-channel-1',
        'direct' => 'request-direct-1',
        'group_direct' => 'request-group-1',
        _ => throw ArgumentError.value(type, 'type'),
      };
  final result = <String, Object?>{
    'operation': 'create_conversation',
    'type': type,
    'reconciliationStatus': status,
    'clientRequestId': requestId,
    'conversation': _conversationDetail(effectiveType),
  };
  if (type != 'channel' && includeParticipantIdentity) {
    final ids = participantUserIds ??
        (type == 'direct'
            ? <String>['user-actor', 'user-b']
            : <String>['user-actor', 'user-b', 'user-c']);
    result['participantIdentity'] = {
      'participantUserIds': ids,
      'key': participantKey ?? _participantKey(ids),
    };
  }
  return result;
}

String _participantKey(List<String> ids) =>
    'handrail-participants.v1.${Uri.encodeComponent(jsonEncode(ids))}';

Map<String, Object?> _conversationDetail(String type) {
  const conversationId = 'conversation-result';
  final participantIds = switch (type) {
    'channel' => <String>['user-actor'],
    'direct' => <String>['user-actor', 'user-b'],
    'group_direct' => <String>['user-actor', 'user-b', 'user-c'],
    _ => <String>['user-actor'],
  };
  final conversation = <String, Object?>{
    'id': conversationId,
    'tenantId': _tenantId,
    'type': type,
    if (type == 'channel') 'name': 'Order coordination',
    'visibility': 'private',
    'createdAt': _now,
    'updatedAt': _now,
    'latestSequence': 0,
    'activityAt': _now,
    'unreadMentionCount': 0,
    'currentMember': {
      'tenantId': _tenantId,
      'conversationId': conversationId,
      'userId': 'user-actor',
      'role': 'owner',
      'state': 'active',
      'joinedAt': _now,
      'updatedAt': _now,
    },
    'currentReadState': {
      'conversationId': conversationId,
      'userId': 'user-actor',
      'lastReadSequence': 0,
      'updatedAt': _now,
    },
    'memberUserIds': participantIds,
    'currentPreference': {
      'conversationId': conversationId,
      'userId': 'user-actor',
      'notificationPreference': 'all',
      'isStarred': false,
      'mute': {'muted': false},
      'updatedAt': _now,
    },
    'activeMemberUserIds': ['user-actor'],
  };
  return <String, Object?>{
    'kind': 'conversation_detail',
    'conversation': conversation,
    '_meta': {
      'packageVersion': '0.1.4',
      'protocolVersion': 1,
      'schemaVersion': 1,
      'enabledFeatures': {'conversation_creation': true},
      'supportedProtocolRange': {
        'minimumVersion': 1,
        'maximumVersion': 1,
      },
      'feature': {'name': 'conversation_snapshots', 'version': 1},
    },
  };
}

const _tenantId = 'tenant-from-session';
const _now = '2026-08-26T16:00:00.000Z';
