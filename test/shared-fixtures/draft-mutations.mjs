export const replaceDraftInput = Object.freeze({
  operation: "synchronize_draft",
  intent: "replace",
  conversationId: "conversation-1",
  baseRevision: 4,
  deviceMutationId: "browser-a:mutation-17",
  idempotencyKey: "draft:conversation-1:browser-a:17",
  content: Object.freeze({
    format: "markdown",
    text: "Review **invoice 42**",
    mentions: Object.freeze([
      Object.freeze({ type: "user", userId: "user-reviewer" }),
      Object.freeze({
        type: "conversation",
        conversationId: "conversation-reviews",
      }),
      Object.freeze({
        type: "entity",
        entity: Object.freeze({ type: "invoice", id: "invoice-42" }),
      }),
    ]),
    attachments: Object.freeze([
      Object.freeze({ attachmentId: "attachment-1" }),
      Object.freeze({ attachmentId: "attachment-2" }),
    ]),
  }),
});

export const clearDraftInput = Object.freeze({
  operation: "synchronize_draft",
  intent: "clear",
  conversationId: "conversation-1",
  baseRevision: 5,
  deviceMutationId: "phone-b:mutation-8",
  idempotencyKey: "draft:conversation-1:phone-b:8",
});

export const canonicalUpdatedAt = "2026-08-26T05:15:00.000Z";

export function draftUpdatedEvent(input, result = settledDraftResult(input)) {
  return {
    eventId: "event-draft-1",
    protocolVersion: 4,
    tenantId: "tenant-1",
    streamId: "user:user-1",
    type: "conversation.draft.updated",
    occurredAt: result.canonicalUpdatedAt,
    payload: {
      actorUserId: "user-1",
      input,
      result,
    },
  };
}

export function settledDraftResult(input, reconciliationStatus = "applied") {
  return {
    operation: "synchronize_draft",
    intent: input.intent,
    reconciliationStatus,
    conversationId: input.conversationId,
    baseRevision: input.baseRevision,
    deviceMutationId: input.deviceMutationId,
    idempotencyKey: input.idempotencyKey,
    canonicalRevision: input.baseRevision + 1,
    canonicalUpdatedAt,
    draft:
      input.intent === "replace"
        ? { kind: "replaced", content: input.content }
        : { kind: "clear_tombstone", content: null },
  };
}

export function staleDraftResult(input, canonicalRevision, draft) {
  return {
    operation: "synchronize_draft",
    intent: input.intent,
    reconciliationStatus: "stale_base",
    conversationId: input.conversationId,
    baseRevision: input.baseRevision,
    deviceMutationId: input.deviceMutationId,
    idempotencyKey: input.idempotencyKey,
    canonicalRevision,
    canonicalUpdatedAt,
    draft,
  };
}
