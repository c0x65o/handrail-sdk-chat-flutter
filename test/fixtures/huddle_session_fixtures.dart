const fixtureNow = '2026-08-25T20:00:00.000Z';
const startedAt = '2026-08-25T20:00:10.000Z';
const aliceJoinedAt = '2026-08-25T20:00:20.000Z';
const bobJoinedAt = '2026-08-25T20:00:30.000Z';
const endedAt = '2026-08-25T20:10:00.000Z';

const inactiveHuddle = <String, Object?>{'status': 'inactive', 'conversationId': 'conversation-1'};
const startingHuddle = <String, Object?>{
  'status': 'starting', 'conversationId': 'conversation-1', 'huddleSessionId': 'huddle-1',
  'startedAt': startedAt, 'participants': <Object?>[], 'screenShareOwnerUserId': null,
};
const aliceParticipant = <String, Object?>{'userId': 'user-alice', 'status': 'joined', 'joinedAt': aliceJoinedAt};
const bobParticipant = <String, Object?>{'userId': 'user-bob', 'status': 'joined', 'joinedAt': bobJoinedAt};
final activeAliceHuddle = <String, Object?>{...startingHuddle, 'status': 'active', 'participants': <Object?>[aliceParticipant]};
final activeBothHuddle = <String, Object?>{...activeAliceHuddle, 'participants': <Object?>[aliceParticipant, bobParticipant]};
final sharingHuddle = <String, Object?>{...activeBothHuddle, 'screenShareOwnerUserId': 'user-bob'};
final bobLeftHuddle = <String, Object?>{
  ...activeBothHuddle,
  'participants': <Object?>[
    aliceParticipant,
    {'userId': 'user-bob', 'status': 'left', 'joinedAt': bobJoinedAt, 'leftAt': '2026-08-25T20:05:00.000Z'},
  ],
};
final endedHuddle = <String, Object?>{
  'status': 'ended', 'conversationId': 'conversation-1', 'huddleSessionId': 'huddle-1',
  'startedAt': startedAt, 'endedAt': endedAt, 'endedByUserId': 'user-alice',
  'participants': <Object?>[
    {'userId': 'user-alice', 'status': 'left', 'joinedAt': aliceJoinedAt, 'leftAt': endedAt},
    {'userId': 'user-bob', 'status': 'left', 'joinedAt': bobJoinedAt, 'leftAt': endedAt},
  ],
  'screenShareOwnerUserId': null,
};
const mediaJoin = <String, Object?>{'kind': 'opaque_media_join', 'descriptor': 'opaque-client-join-material', 'expiresAt': '2026-08-25T20:04:00.000Z'};

const startInput = <String, Object?>{'operation': 'start_huddle', 'conversationId': 'conversation-1', 'idempotencyKey': 'start-1'};
const joinInput = <String, Object?>{'operation': 'join_huddle', 'huddleSessionId': 'huddle-1', 'idempotencyKey': 'join-1'};
const leaveInput = <String, Object?>{'operation': 'leave_huddle', 'huddleSessionId': 'huddle-1', 'idempotencyKey': 'leave-1'};
const setShareInput = <String, Object?>{'operation': 'set_huddle_screen_share', 'huddleSessionId': 'huddle-1', 'intent': 'set', 'idempotencyKey': 'share-1'};
const clearShareInput = <String, Object?>{'operation': 'set_huddle_screen_share', 'huddleSessionId': 'huddle-1', 'intent': 'clear', 'idempotencyKey': 'clear-1'};
const endInput = <String, Object?>{'operation': 'end_huddle', 'huddleSessionId': 'huddle-1', 'idempotencyKey': 'end-1'};

Map<String, Object?> success(Map<String, Object?> input, Map<String, Object?> state, {Map<String, Object?>? descriptor}) => {
  'operation': input['operation'], 'outcome': 'ok', 'reconciliationStatus': 'applied', 'state': state,
  if (descriptor != null) 'mediaJoin': descriptor,
};
Map<String, Object?> disabled(Map<String, Object?> input, Map<String, Object?> state) => {
  'operation': input['operation'], 'outcome': 'feature_disabled', 'reconciliationStatus': 'applied',
  'feature': 'huddles', 'reason': 'media_unavailable', 'state': state,
};
