import {
  parseSetThreadFollowInput,
  parseSetThreadFollowResult,
  type SetThreadFollowInput,
} from "@handrail/chat/client";

const input: SetThreadFollowInput = {
  operation: "set_thread_follow",
  intent: "follow",
  target: { type: "thread", id: "thread-browser" as never },
  expectedFollowRevision: 3,
  idempotencyKey: "browser:thread-follow:4",
};

export const browserThreadFollowInputProof =
  parseSetThreadFollowInput(input);

export const browserThreadFollowResultProof = parseSetThreadFollowResult(
  {
    operation: "set_thread_follow",
    intent: "follow",
    reconciliationStatus: "applied",
    target: input.target,
    expectedFollowRevision: input.expectedFollowRevision,
    idempotencyKey: input.idempotencyKey,
    followRevision: 4,
    follow: {
      target: input.target,
      isFollowing: true,
      source: "manual",
      updatedAt: "2026-08-26T06:30:00.000Z",
    },
  },
  input,
);
