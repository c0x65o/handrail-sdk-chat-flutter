import {
  deriveCanonicalParticipantIdentity,
  parseConversationCreationInput,
} from "@handrail/chat/client";

const input = parseConversationCreationInput({
  operation: "create_conversation",
  type: "group_direct",
  visibility: "private",
  intendedMemberUserIds: ["user-c", "user-b"],
  idempotencyKey: "browser-create-1",
  clientRequestId: "browser-request-1",
});

export const browserConversationCreationProof = {
  input,
  identity: deriveCanonicalParticipantIdentity("user-a" as never, [
    "user-c" as never,
    "user-b" as never,
  ]),
};
