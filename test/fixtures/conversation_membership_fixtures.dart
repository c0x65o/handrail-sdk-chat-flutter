const membershipTimestamp = '2026-08-26T04:30:00.000Z';

const membershipInputFixtures = <String, Map<String, Object?>>{
  'join': {
    'operation': 'mutate_conversation_membership',
    'intent': 'join',
    'conversationId': 'conversation-1',
    'expectedMemberListRevision': 4,
    'idempotencyKey': 'join-conversation-1',
  },
  'leave': {
    'operation': 'mutate_conversation_membership',
    'intent': 'leave',
    'conversationId': 'conversation-1',
    'expectedMemberListRevision': 5,
    'idempotencyKey': 'leave-conversation-1',
  },
  'add_member': {
    'operation': 'mutate_conversation_membership',
    'intent': 'add_member',
    'conversationId': 'conversation-1',
    'targetUserId': 'user-c',
    'requestedRole': 'moderator',
    'expectedMemberListRevision': 6,
    'idempotencyKey': 'add-user-c',
  },
  'remove_member': {
    'operation': 'mutate_conversation_membership',
    'intent': 'remove_member',
    'conversationId': 'conversation-1',
    'targetUserId': 'user-c',
    'expectedMemberListRevision': 7,
    'idempotencyKey': 'remove-user-c',
  },
  'change_member_role': {
    'operation': 'mutate_conversation_membership',
    'intent': 'change_member_role',
    'conversationId': 'conversation-1',
    'targetUserId': 'user-b',
    'requestedRole': 'moderator',
    'expectedMemberListRevision': 8,
    'idempotencyKey': 'moderate-user-b',
  },
};

Map<String, Object?> membershipMember(
  String userId,
  String role, [
  String state = 'active',
]) =>
    {
      'userId': userId,
      'role': role,
      'state': state,
      'joinedAt': membershipTimestamp,
      'updatedAt': membershipTimestamp,
    };

Map<String, Object?> appliedMembershipFixture(Map<String, Object?> input) {
  final intent = input['intent']! as String;
  final target = input['targetUserId'] as String?;
  final members = switch (intent) {
    'join' => [
        membershipMember('user-actor', 'member'),
        membershipMember('user-b', 'owner'),
      ],
    'leave' => [
        membershipMember('user-actor', 'member', 'left'),
        membershipMember('user-b', 'owner'),
      ],
    'add_member' => [
        membershipMember('user-actor', 'member'),
        membershipMember('user-b', 'owner'),
        membershipMember('user-c', 'moderator'),
      ],
    'remove_member' => [
        membershipMember('user-actor', 'member'),
        membershipMember('user-b', 'owner'),
        membershipMember('user-c', 'moderator', 'removed'),
      ],
    _ => [
        membershipMember('user-actor', 'member'),
        membershipMember('user-b', 'moderator'),
        membershipMember('user-c', 'owner'),
      ],
  };
  return {
    'operation': input['operation'],
    'intent': intent,
    'reconciliationStatus': 'applied',
    'conversationId': input['conversationId'],
    'expectedMemberListRevision': input['expectedMemberListRevision'],
    'memberListRevision': (input['expectedMemberListRevision']! as int) + 1,
    'memberUserId': target ?? 'user-actor',
    'members': members,
    if (target != null) 'targetUserId': target,
    if (input['requestedRole'] case final String role?) 'requestedRole': role,
  };
}

List<({Map<String, Object?> input, Map<String, Object?> result})>
    get membershipOutcomeFixtures {
  final applied = [
    for (final input in membershipInputFixtures.values)
      (input: input, result: appliedMembershipFixture(input)),
  ];
  final add = membershipInputFixtures['add_member']!;
  final replayed = {
    ...appliedMembershipFixture(add),
    'reconciliationStatus': 'replayed',
  };
  final already = {
    ...appliedMembershipFixture(add),
    'reconciliationStatus': 'already_requested_state',
    'memberListRevision': add['expectedMemberListRevision'],
  };
  final conflict = {
    ...appliedMembershipFixture(add),
    'reconciliationStatus': 'member_list_conflict',
    'memberListRevision': (add['expectedMemberListRevision']! as int) + 3,
  };
  final roleInput = membershipInputFixtures['change_member_role']!;
  final lastOwner = {
    'operation': roleInput['operation'],
    'intent': roleInput['intent'],
    'reconciliationStatus': 'safety_rejected',
    'conversationId': roleInput['conversationId'],
    'expectedMemberListRevision': roleInput['expectedMemberListRevision'],
    'memberListRevision': roleInput['expectedMemberListRevision'],
    'memberUserId': roleInput['targetUserId'],
    'members': [
      membershipMember('user-actor', 'member'),
      membershipMember('user-b', 'owner'),
    ],
    'targetUserId': roleInput['targetUserId'],
    'requestedRole': roleInput['requestedRole'],
    'safetyError': {
      'code': 'last_owner',
      'message': 'A conversation must retain an owner.',
    },
  };
  final leaveInput = membershipInputFixtures['leave']!;
  final lastActive = {
    'operation': leaveInput['operation'],
    'intent': leaveInput['intent'],
    'reconciliationStatus': 'safety_rejected',
    'conversationId': leaveInput['conversationId'],
    'expectedMemberListRevision': leaveInput['expectedMemberListRevision'],
    'memberListRevision': leaveInput['expectedMemberListRevision'],
    'memberUserId': 'user-actor',
    'members': [membershipMember('user-actor', 'owner')],
    'safetyError': {
      'code': 'last_active_member',
      'message': 'The last active member cannot leave.',
    },
  };
  return [
    ...applied,
    (input: add, result: replayed),
    (input: add, result: already),
    (input: add, result: conflict),
    (input: roleInput, result: lastOwner),
    (input: leaveInput, result: lastActive),
  ];
}
