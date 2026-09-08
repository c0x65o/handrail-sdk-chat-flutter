import {
  parseConversationMembershipMutationInput,
  type ConversationId,
  type ConversationMembershipMutationInput,
  type UserId,
} from "@handrail/chat/client";

const input: ConversationMembershipMutationInput = {
  operation: "mutate_conversation_membership",
  intent: "add_member",
  conversationId: "conversation-browser" as ConversationId,
  targetUserId: "user-browser" as UserId,
  requestedRole: "member",
  expectedMemberListRevision: 1,
  idempotencyKey: "browser-add-member-1",
};

export const browserConversationMembershipProof =
  parseConversationMembershipMutationInput(input);

