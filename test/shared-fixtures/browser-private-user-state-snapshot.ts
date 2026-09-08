import {
  ACTOR_PRIVATE_USER_STATE_PRIVACY,
  encodeSavedMessageSnapshotCursor,
  parseConversationDraftSnapshot,
  parseConversationDraftSnapshotInput,
  parseSavedMessageListSnapshot,
  parseSavedMessageListSnapshotInput,
  type ConversationId,
  type MessageId,
} from "@handrail/chat/client";

const conversationId = "conversation-browser-private" as ConversationId;
const draftInput = parseConversationDraftSnapshotInput({ conversationId });

export const browserDraftSnapshotProof = parseConversationDraftSnapshot(
  {
    kind: "conversation_draft",
    privacy: ACTOR_PRIVATE_USER_STATE_PRIVACY,
    conversationId,
    state: "present",
    canonicalRevision: 1,
    canonicalUpdatedAt: "2026-08-26T12:00:00.000Z",
    content: {
      privacy: ACTOR_PRIVATE_USER_STATE_PRIVACY,
      value: { format: "plain", text: "Browser draft", attachments: [] },
    },
  },
  draftInput,
);

const messageId = "message-browser-saved" as MessageId;
const savedInput = parseSavedMessageListSnapshotInput({ limit: 1 });
const nextCursor = encodeSavedMessageSnapshotCursor({
  savedAt: "2026-08-26T11:00:00.000Z",
  messageId,
});

export const browserSavedMessageSnapshotProof = parseSavedMessageListSnapshot(
  {
    kind: "saved_message_list",
    privacy: ACTOR_PRIVATE_USER_STATE_PRIVACY,
    items: [
      {
        messageId,
        savedMessageRevision: 1,
        savedAt: "2026-08-26T11:00:00.000Z",
        updatedAt: "2026-08-26T11:00:00.000Z",
        message: { availability: "unavailable", reason: "inaccessible" },
      },
    ],
    page: { nextCursor },
  },
  savedInput,
);
