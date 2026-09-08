export const fixtureNow = "2026-08-25T20:00:00.000Z";
export const startedAt = "2026-08-25T20:00:10.000Z";
export const aliceJoinedAt = "2026-08-25T20:00:20.000Z";
export const bobJoinedAt = "2026-08-25T20:00:30.000Z";
export const endedAt = "2026-08-25T20:10:00.000Z";

export const inactiveHuddle = {
  status: "inactive",
  conversationId: "conversation-1",
};

export const startingHuddle = {
  status: "starting",
  conversationId: "conversation-1",
  huddleSessionId: "huddle-1",
  startedAt,
  participants: [],
  screenShareOwnerUserId: null,
};

export const activeAliceHuddle = {
  ...startingHuddle,
  status: "active",
  participants: [
    { userId: "user-alice", status: "joined", joinedAt: aliceJoinedAt },
  ],
};

export const activeBothHuddle = {
  ...activeAliceHuddle,
  participants: [
    ...activeAliceHuddle.participants,
    { userId: "user-bob", status: "joined", joinedAt: bobJoinedAt },
  ],
};

export const sharingHuddle = {
  ...activeBothHuddle,
  screenShareOwnerUserId: "user-bob",
};

export const bobLeftHuddle = {
  ...activeBothHuddle,
  participants: [
    activeBothHuddle.participants[0],
    {
      userId: "user-bob",
      status: "left",
      joinedAt: bobJoinedAt,
      leftAt: "2026-08-25T20:05:00.000Z",
    },
  ],
};

export const endedHuddle = {
  status: "ended",
  conversationId: "conversation-1",
  huddleSessionId: "huddle-1",
  startedAt,
  endedAt,
  endedByUserId: "user-alice",
  participants: [
    {
      userId: "user-alice",
      status: "left",
      joinedAt: aliceJoinedAt,
      leftAt: endedAt,
    },
    {
      userId: "user-bob",
      status: "left",
      joinedAt: bobJoinedAt,
      leftAt: endedAt,
    },
  ],
  screenShareOwnerUserId: null,
};

export const mediaJoin = {
  kind: "opaque_media_join",
  descriptor: "opaque-client-join-material",
  expiresAt: "2026-08-25T20:04:00.000Z",
};

export const startInput = {
  operation: "start_huddle",
  conversationId: "conversation-1",
  idempotencyKey: "start-huddle-1",
};

export const joinInput = {
  operation: "join_huddle",
  huddleSessionId: "huddle-1",
  idempotencyKey: "join-huddle-alice",
};

export const leaveInput = {
  operation: "leave_huddle",
  huddleSessionId: "huddle-1",
  idempotencyKey: "leave-huddle-bob",
};

export const setShareInput = {
  operation: "set_huddle_screen_share",
  huddleSessionId: "huddle-1",
  intent: "set",
  idempotencyKey: "share-huddle-bob",
};

export const clearShareInput = {
  ...setShareInput,
  intent: "clear",
  idempotencyKey: "clear-share-huddle-bob",
};

export const endInput = {
  operation: "end_huddle",
  huddleSessionId: "huddle-1",
  idempotencyKey: "end-huddle-1",
};

export function successfulResult(input, state, extra = {}) {
  return {
    operation: input.operation,
    outcome: "ok",
    reconciliationStatus: "applied",
    state,
    ...extra,
  };
}
