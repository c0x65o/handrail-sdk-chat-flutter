import {
  parseSynchronizeDraftInput,
  parseSynchronizeDraftResult,
  type SynchronizeDraftInput,
} from "@handrail/chat/client";

const input: SynchronizeDraftInput = {
  operation: "synchronize_draft",
  intent: "replace",
  conversationId: "conversation-browser" as never,
  baseRevision: 0,
  deviceMutationId: "browser:mutation-1",
  idempotencyKey: "browser:draft:mutation-1",
  content: {
    format: "plain",
    text: "Browser draft",
    mentions: [
      { type: "user", userId: "browser-user" as never },
      { type: "conversation", conversationId: "browser-conversation" as never },
      { type: "entity", entity: { type: "browser-ticket", id: "browser-ticket-7" } },
    ],
    attachments: [],
  },
};

export const browserDraftInputProof = parseSynchronizeDraftInput(input);
export const browserDraftResultProof = parseSynchronizeDraftResult(
  {
    operation: "synchronize_draft",
    intent: "replace",
    reconciliationStatus: "applied",
    conversationId: input.conversationId,
    baseRevision: 0,
    deviceMutationId: input.deviceMutationId,
    idempotencyKey: input.idempotencyKey,
    canonicalRevision: 1,
    canonicalUpdatedAt: "2026-08-26T05:15:00.000Z",
    draft: { kind: "replaced", content: input.content },
  },
  input,
);
