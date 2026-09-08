export const tenantId = "tenant-1";
export const enabledEphemeralFeatures = { typing: true, presence: true };

export const typingStartEvent = {
  eventId: "event-typing-start",
  protocolVersion: 4,
  tenantId,
  streamId: "conversation-9",
  type: "typing.signal",
  occurredAt: "2026-08-25T20:00:00.000Z",
  payload: {
    capability: "typing",
    durability: "ephemeral",
    actorUserId: "user-2",
    deviceId: "device-browser",
    sessionId: "session-tab-1",
    sequence: 1,
    sentAt: "2026-08-25T20:00:00.000Z",
    expiresAt: "2026-08-25T20:00:10.000Z",
    state: "start",
    scope: {
      type: "conversation",
      conversationId: "conversation-9",
      visibility: "private",
      audience: "members",
    },
  },
};

export const presenceOnlineEvent = {
  eventId: "event-presence-online",
  protocolVersion: 4,
  tenantId,
  streamId: "user:user-1",
  type: "presence.signal",
  occurredAt: "2026-08-25T20:00:00.000Z",
  payload: {
    capability: "presence",
    durability: "ephemeral",
    actorUserId: "user-2",
    deviceId: "device-browser",
    sessionId: "session-tab-1",
    sequence: 1,
    sentAt: "2026-08-25T20:00:00.000Z",
    expiresAt: "2026-08-25T20:01:00.000Z",
    state: "online",
    scope: { type: "user_private", userId: "user-1" },
  },
};
