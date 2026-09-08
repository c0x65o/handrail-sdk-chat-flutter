export const threadFollowUpdatedAt = "2026-08-26T06:30:00.000Z";

export const followThreadInput = Object.freeze({
  operation: "set_thread_follow",
  intent: "follow",
  target: Object.freeze({ type: "thread", id: "thread-alpha" }),
  expectedFollowRevision: 2,
  idempotencyKey: "thread-follow:alpha:3",
});

export const unfollowThreadInput = Object.freeze({
  operation: "set_thread_follow",
  intent: "unfollow",
  target: Object.freeze({ type: "thread", id: "thread-beta" }),
  expectedFollowRevision: 7,
  idempotencyKey: "thread-unfollow:beta:8",
});

export const threadFollowInputs = Object.freeze([
  followThreadInput,
  unfollowThreadInput,
]);

export function settledThreadFollowResult(
  input,
  reconciliationStatus = "applied",
) {
  const isFollowing = input.intent === "follow";
  return {
    operation: "set_thread_follow",
    intent: input.intent,
    reconciliationStatus,
    target: input.target,
    expectedFollowRevision: input.expectedFollowRevision,
    idempotencyKey: input.idempotencyKey,
    followRevision:
      reconciliationStatus === "already_requested_state"
        ? input.expectedFollowRevision
        : input.expectedFollowRevision + 1,
    follow: {
      target: input.target,
      isFollowing,
      source: "manual",
      updatedAt: threadFollowUpdatedAt,
    },
  };
}

export function conflictingThreadFollowResult(
  input,
  followRevision,
  source = "manual",
) {
  return {
    operation: "set_thread_follow",
    intent: input.intent,
    reconciliationStatus: "follow_revision_conflict",
    target: input.target,
    expectedFollowRevision: input.expectedFollowRevision,
    idempotencyKey: input.idempotencyKey,
    followRevision,
    follow: {
      target: input.target,
      isFollowing: input.intent !== "follow",
      source,
      updatedAt: threadFollowUpdatedAt,
    },
  };
}
