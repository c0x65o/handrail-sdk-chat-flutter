const preferenceUpdatedAt = '2026-08-26T05:30:00.000Z';

const allUnmutedPreferenceInput = <String, Object?>{
  'operation': 'update_conversation_preference',
  'conversationId': 'conversation-all',
  'expectedPreferenceRevision': 0,
  'idempotencyKey': 'preference-all-1',
  'notificationPreference': 'all',
  'isStarred': false,
  'mute': <String, Object?>{'muted': false},
};

const mentionsIndefinitePreferenceInput = <String, Object?>{
  'operation': 'update_conversation_preference',
  'conversationId': 'conversation-mentions',
  'expectedPreferenceRevision': 4,
  'idempotencyKey': 'preference-mentions-5',
  'notificationPreference': 'mentions',
  'isStarred': true,
  'mute': <String, Object?>{'muted': true},
};

const noneFinitePreferenceInput = <String, Object?>{
  'operation': 'update_conversation_preference',
  'conversationId': 'conversation-none',
  'expectedPreferenceRevision': 9,
  'idempotencyKey': 'preference-none-10',
  'notificationPreference': 'none',
  'isStarred': false,
  'mute': <String, Object?>{
    'muted': true,
    'mutedUntil': '2030-02-03T04:05:06.000Z',
  },
};

const conversationPreferenceInputs = <Map<String, Object?>>[
  allUnmutedPreferenceInput,
  mentionsIndefinitePreferenceInput,
  noneFinitePreferenceInput,
];

Map<String, Object?> desiredPreference(Map<String, Object?> input) => {
  'notificationPreference': input['notificationPreference'],
  'isStarred': input['isStarred'],
  'mute': input['mute'],
};

Map<String, Object?> settledPreferenceResult(
  Map<String, Object?> input,
  String status,
) => {
  'operation': input['operation'],
  'reconciliationStatus': status,
  'conversationId': input['conversationId'],
  'expectedPreferenceRevision': input['expectedPreferenceRevision'],
  'idempotencyKey': input['idempotencyKey'],
  'requestedPreference': desiredPreference(input),
  'preferenceRevision': status == 'already_requested_state'
      ? input['expectedPreferenceRevision']
      : (input['expectedPreferenceRevision']! as int) + 1,
  'preference': {
    ...desiredPreference(input),
    'updatedAt': preferenceUpdatedAt,
  },
};

Map<String, Object?> conflictingPreferenceResult(
  Map<String, Object?> input,
  int revision,
) => {
  'operation': input['operation'],
  'reconciliationStatus': 'preference_revision_conflict',
  'conversationId': input['conversationId'],
  'expectedPreferenceRevision': input['expectedPreferenceRevision'],
  'idempotencyKey': input['idempotencyKey'],
  'requestedPreference': desiredPreference(input),
  'preferenceRevision': revision,
  'preference': {
    'notificationPreference': 'all',
    'isStarred': true,
    'mute': <String, Object?>{'muted': false},
    'updatedAt': preferenceUpdatedAt,
  },
};
