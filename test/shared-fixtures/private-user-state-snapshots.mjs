import {
  ACTOR_PRIVATE_USER_STATE_PRIVACY,
  encodeSavedMessageSnapshotCursor,
} from "../../dist/index.js";

export const privateStateConversationId = "conversation-private-state";

export const draftSnapshotInput = {
  conversationId: privateStateConversationId,
};

export const presentDraftSnapshot = {
  kind: "conversation_draft",
  privacy: ACTOR_PRIVATE_USER_STATE_PRIVACY,
  conversationId: privateStateConversationId,
  state: "present",
  canonicalRevision: 7,
  canonicalUpdatedAt: "2026-08-26T12:07:00.000Z",
  content: {
    privacy: ACTOR_PRIVATE_USER_STATE_PRIVACY,
    value: {
      format: "markdown",
      text: "Review **invoice 42**",
      mentions: [
        { type: "user", userId: "user-reviewer" },
        { type: "conversation", conversationId: "conversation-reviews" },
        { type: "entity", entity: { type: "invoice", id: "invoice-42" } },
      ],
      attachments: [
        { attachmentId: "attachment-draft-1" },
        { attachmentId: "attachment-draft-2" },
      ],
    },
  },
};

export const replyDraftSnapshots = [true, false].map((notifyAuthor) => ({
  ...presentDraftSnapshot,
  content: {
    ...presentDraftSnapshot.content,
    value: {
      ...presentDraftSnapshot.content.value,
      replyTo: { messageId: "message-launch-date", notifyAuthor },
    },
  },
}));

export const absentDraftSnapshot = {
  kind: "conversation_draft",
  privacy: ACTOR_PRIVATE_USER_STATE_PRIVACY,
  conversationId: privateStateConversationId,
  state: "absent",
  canonicalRevision: 8,
  canonicalUpdatedAt: "2026-08-26T12:08:00.000Z",
  content: null,
};

const savedAt = {
  visible: "2026-08-26T12:30:00.000Z",
  deleted: "2026-08-26T12:20:00.000Z",
  inaccessible: "2026-08-26T12:10:00.000Z",
};

export const savedMessageFirstPageInput = { limit: 2 };

export const savedMessageFirstPage = {
  kind: "saved_message_list",
  privacy: ACTOR_PRIVATE_USER_STATE_PRIVACY,
  items: [
    {
      messageId: "message-visible",
      savedMessageRevision: 3,
      savedAt: savedAt.visible,
      updatedAt: "2026-08-26T12:31:00.000Z",
      privateNote: {
        privacy: ACTOR_PRIVATE_USER_STATE_PRIVACY,
        text: "Follow up with the customer",
      },
      message: {
        availability: "available",
        current: {
          id: "message-visible",
          conversationId: privateStateConversationId,
          author: { type: "user", userId: "user-author" },
          sequence: 42,
          createdAt: "2026-08-26T11:00:00.000Z",
          updatedAt: "2026-08-26T11:05:00.000Z",
          revision: {
            revision: 2,
            editedAt: "2026-08-26T11:05:00.000Z",
            editedByUserId: "user-author",
          },
          content: {
            format: "markdown",
            text: "Current **safe** message body",
            mentions: [{ type: "user", userId: "user-mentioned" }],
            attachments: [{ attachmentId: "attachment-visible" }],
            blocks: [{ type: "erp.reference", data: { id: "invoice-42" } }],
          },
          attachmentMetadata: [
            {
              attachmentId: "attachment-visible",
              fileName: "invoice.pdf",
              contentType: "application/pdf",
              sizeBytes: 2048,
              downloadUrl: "https://cdn.example.test/invoice.pdf",
            },
          ],
        },
      },
    },
    {
      messageId: "message-deleted",
      savedMessageRevision: 4,
      savedAt: savedAt.deleted,
      updatedAt: "2026-08-26T12:25:00.000Z",
      message: { availability: "unavailable", reason: "deleted" },
    },
  ],
  page: {
    nextCursor: encodeSavedMessageSnapshotCursor({
      savedAt: savedAt.deleted,
      messageId: "message-deleted",
    }),
  },
};

export const savedMessageSecondPageInput = {
  cursor: savedMessageFirstPage.page.nextCursor,
  limit: 2,
};

export const savedMessageTerminalPage = {
  kind: "saved_message_list",
  privacy: ACTOR_PRIVATE_USER_STATE_PRIVACY,
  items: [
    {
      messageId: "message-inaccessible",
      savedMessageRevision: 2,
      savedAt: savedAt.inaccessible,
      updatedAt: savedAt.inaccessible,
      message: { availability: "unavailable", reason: "inaccessible" },
    },
  ],
  page: { nextCursor: null },
};

export const replySavedMessagePages = [true, false].map((notifyAuthor) => ({
  ...savedMessageFirstPage,
  items: savedMessageFirstPage.items.map((entry, index) => index === 0 ? {
    ...entry,
    message: {
      ...entry.message,
      current: {
        ...entry.message.current,
        replyTo: { messageId: "message-launch-date", notifyAuthor },
      },
    },
  } : entry),
}));
