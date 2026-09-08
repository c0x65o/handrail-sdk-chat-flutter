import {
  createConversationSnapshotMetadata,
  decodeConversationSnapshotCursor,
  encodeConversationSnapshotCursor,
  parseConversationListSnapshotInput,
} from "@handrail/chat/client";

const cursor = encodeConversationSnapshotCursor({
  isStarred: false,
  navigationRank: 0,
  activityAt: "2026-08-25T20:00:00.000Z",
  conversationId: "conversation-1" as never,
});

export const browserSnapshotProof = {
  cursor: decodeConversationSnapshotCursor(cursor),
  input: parseConversationListSnapshotInput({
    scope: { type: "organization" },
    cursor,
  }),
  metadata: createConversationSnapshotMetadata({
    packageVersion: "0.1.2",
    protocolVersion: 1,
    schemaVersion: 0,
    enabledFeatures: { threads: true },
  }),
};
