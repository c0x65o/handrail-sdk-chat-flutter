import {
  parseConversationArchiveInput,
  type ConversationArchiveInput,
} from "@handrail/chat/client";

const input: ConversationArchiveInput = {
  operation: "set_conversation_archive",
  intent: "archive",
  conversationId: "conversation-browser" as never,
  expectedLifecycleRevision: 1,
  idempotencyKey: "browser-archive-conversation-1",
};

export const browserConversationArchiveProof =
  parseConversationArchiveInput(input);
