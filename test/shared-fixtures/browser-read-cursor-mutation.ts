import {
  applyReadCursorMutation,
  createReadCursorUpdatedEvent,
  parseReadCursorUpdatedEvent,
} from "@handrail/chat";

const tenantId = "tenant-1" as never;
const result = applyReadCursorMutation(
  {
    operation: "mark_read",
    conversationId: "conversation-1",
    throughSequence: 3,
    idempotencyKey: "browser-read-1",
  },
  {
    currentReadState: {
      conversationId: "conversation-1" as never,
      userId: "user-1" as never,
      lastReadSequence: 2,
      updatedAt: "2026-08-25T20:00:00.000Z",
    },
    latestSequence: 4,
    updatedAt: "2026-08-25T20:01:00.000Z",
  },
);

const event = createReadCursorUpdatedEvent({
  eventId: "event-1",
  protocolVersion: 4,
  tenantId,
  occurredAt: "2026-08-25T20:01:00.000Z",
  result,
});

export const browserReadCursorMutationProof =
  parseReadCursorUpdatedEvent(event, tenantId);
