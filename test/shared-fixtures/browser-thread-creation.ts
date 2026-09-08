import {
  parseThreadCreationInput,
  type ThreadCreationInput,
} from "@handrail/chat/client";

const input: ThreadCreationInput = {
  operation: "create_thread",
  parentConversationId: "conversation-parent" as never,
  rootMessageId: "message-root" as never,
  initialFollow: true,
  idempotencyKey: "browser-create-thread-1",
};

export const browserThreadCreationProof = parseThreadCreationInput(input);
