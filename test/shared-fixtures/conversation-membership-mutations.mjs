export const timestamp = "2026-08-26T04:30:00.000Z";

export const membershipInputs = {
  join: {
    operation: "mutate_conversation_membership",
    intent: "join",
    conversationId: "conversation-1",
    expectedMemberListRevision: 4,
    idempotencyKey: "join-conversation-1",
  },
  leave: {
    operation: "mutate_conversation_membership",
    intent: "leave",
    conversationId: "conversation-1",
    expectedMemberListRevision: 5,
    idempotencyKey: "leave-conversation-1",
  },
  addMember: {
    operation: "mutate_conversation_membership",
    intent: "add_member",
    conversationId: "conversation-1",
    targetUserId: "user-c",
    requestedRole: "moderator",
    expectedMemberListRevision: 6,
    idempotencyKey: "add-user-c",
  },
  removeMember: {
    operation: "mutate_conversation_membership",
    intent: "remove_member",
    conversationId: "conversation-1",
    targetUserId: "user-c",
    expectedMemberListRevision: 7,
    idempotencyKey: "remove-user-c",
  },
  changeRole: {
    operation: "mutate_conversation_membership",
    intent: "change_member_role",
    conversationId: "conversation-1",
    targetUserId: "user-b",
    requestedRole: "moderator",
    expectedMemberListRevision: 8,
    idempotencyKey: "moderate-user-b",
  },
};

function member(userId, role, state = "active") {
  return { userId, role, state, joinedAt: timestamp, updatedAt: timestamp };
}

const statesByIntent = {
  join: [member("user-actor", "member"), member("user-b", "owner")],
  leave: [member("user-actor", "member", "left"), member("user-b", "owner")],
  add_member: [
    member("user-actor", "member"),
    member("user-b", "owner"),
    member("user-c", "moderator"),
  ],
  remove_member: [
    member("user-actor", "member"),
    member("user-b", "owner"),
    member("user-c", "moderator", "removed"),
  ],
  change_member_role: [
    member("user-actor", "member"),
    member("user-b", "moderator"),
    member("user-c", "owner"),
  ],
};

export function appliedMembershipResult(input) {
  const targeted = "targetUserId" in input;
  const memberUserId = targeted ? input.targetUserId : "user-actor";
  return {
    operation: input.operation,
    intent: input.intent,
    reconciliationStatus: "applied",
    conversationId: input.conversationId,
    expectedMemberListRevision: input.expectedMemberListRevision,
    memberListRevision: input.expectedMemberListRevision + 1,
    memberUserId,
    members: statesByIntent[input.intent],
    ...(targeted ? { targetUserId: input.targetUserId } : {}),
    ...(input.requestedRole !== undefined
      ? { requestedRole: input.requestedRole }
      : {}),
  };
}

export const validMembershipCases = Object.values(membershipInputs).map(
  (input) => ({ input, result: appliedMembershipResult(input) }),
);

