export const preferenceUpdatedAt = "2026-08-26T05:30:00.000Z";

export const allUnmutedInput = Object.freeze({
  operation: "update_conversation_preference",
  conversationId: "conversation-all",
  expectedPreferenceRevision: 0,
  idempotencyKey: "preference:conversation-all:1",
  notificationPreference: "all",
  isStarred: false,
  mute: Object.freeze({ muted: false }),
});

export const mentionsIndefinitelyMutedInput = Object.freeze({
  operation: "update_conversation_preference",
  conversationId: "conversation-mentions",
  expectedPreferenceRevision: 4,
  idempotencyKey: "preference:conversation-mentions:5",
  notificationPreference: "mentions",
  isStarred: true,
  mute: Object.freeze({ muted: true }),
});

export const noneMutedUntilInput = Object.freeze({
  operation: "update_conversation_preference",
  conversationId: "conversation-none",
  expectedPreferenceRevision: 9,
  idempotencyKey: "preference:conversation-none:10",
  notificationPreference: "none",
  isStarred: false,
  mute: Object.freeze({
    muted: true,
    mutedUntil: "2030-02-03T04:05:06.000Z",
  }),
});

export const preferenceMutationInputs = Object.freeze([
  allUnmutedInput,
  mentionsIndefinitelyMutedInput,
  noneMutedUntilInput,
]);

export function desiredPreference(input) {
  return {
    notificationPreference: input.notificationPreference,
    isStarred: input.isStarred,
    mute: input.mute,
  };
}

export function settledPreferenceResult(
  input,
  reconciliationStatus = "applied",
) {
  return {
    operation: "update_conversation_preference",
    reconciliationStatus,
    conversationId: input.conversationId,
    expectedPreferenceRevision: input.expectedPreferenceRevision,
    idempotencyKey: input.idempotencyKey,
    requestedPreference: desiredPreference(input),
    preferenceRevision:
      reconciliationStatus === "already_requested_state"
        ? input.expectedPreferenceRevision
        : input.expectedPreferenceRevision + 1,
    preference: {
      ...desiredPreference(input),
      updatedAt: preferenceUpdatedAt,
    },
  };
}

export function conflictingPreferenceResult(
  input,
  preferenceRevision,
  preference,
) {
  return {
    operation: "update_conversation_preference",
    reconciliationStatus: "preference_revision_conflict",
    conversationId: input.conversationId,
    expectedPreferenceRevision: input.expectedPreferenceRevision,
    idempotencyKey: input.idempotencyKey,
    requestedPreference: desiredPreference(input),
    preferenceRevision,
    preference: { ...preference, updatedAt: preferenceUpdatedAt },
  };
}
