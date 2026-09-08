import {
  parseUpdateConversationPreferenceInput,
  parseUpdateConversationPreferenceResult,
  type UpdateConversationPreferenceInput,
} from "@handrail/chat/client";

const input: UpdateConversationPreferenceInput = {
  operation: "update_conversation_preference",
  conversationId: "conversation-browser" as never,
  expectedPreferenceRevision: 2,
  idempotencyKey: "browser:preference:3",
  notificationPreference: "mentions",
  isStarred: true,
  mute: { muted: true, mutedUntil: "2030-02-03T04:05:06.000Z" as never },
};

export const browserConversationPreferenceInputProof =
  parseUpdateConversationPreferenceInput(input);

export const browserConversationPreferenceResultProof =
  parseUpdateConversationPreferenceResult(
    {
      operation: "update_conversation_preference",
      reconciliationStatus: "applied",
      conversationId: input.conversationId,
      expectedPreferenceRevision: input.expectedPreferenceRevision,
      idempotencyKey: input.idempotencyKey,
      requestedPreference: {
        notificationPreference: input.notificationPreference,
        isStarred: input.isStarred,
        mute: input.mute,
      },
      preferenceRevision: 3,
      preference: {
        notificationPreference: input.notificationPreference,
        isStarred: input.isStarred,
        mute: input.mute,
        updatedAt: "2026-08-26T05:30:00.000Z",
      },
    },
    input,
  );
