Map<String, Object?> typingSignalFixture({
  String state = 'start',
  String visibility = 'private',
  String audience = 'members',
  int sequence = 1,
}) =>
    {
      'eventId': 'event-typing-$state',
      'protocolVersion': 4,
      'tenantId': 'tenant-1',
      'streamId': 'conversation-9',
      'type': 'typing.signal',
      'occurredAt': '2026-08-25T20:00:00.000Z',
      'payload': {
        'capability': 'typing',
        'durability': 'ephemeral',
        'actorUserId': 'user-2',
        'deviceId': 'device-browser',
        'sessionId': 'session-tab-1',
        'sequence': sequence,
        'sentAt': '2026-08-25T20:00:00.000Z',
        'expiresAt': '2026-08-25T20:00:10.000Z',
        'state': state,
        'scope': {
          'type': 'conversation',
          'conversationId': 'conversation-9',
          'visibility': visibility,
          'audience': audience,
        },
      },
    };

Map<String, Object?> presenceSignalFixture({
  String state = 'online',
  int sequence = 1,
}) =>
    {
      'eventId': 'event-presence-$state',
      'protocolVersion': 4,
      'tenantId': 'tenant-1',
      'streamId': 'user:user-1',
      'type': 'presence.signal',
      'occurredAt': '2026-08-25T20:00:00.000Z',
      'payload': {
        'capability': 'presence',
        'durability': 'ephemeral',
        'actorUserId': 'user-2',
        'deviceId': 'device-browser',
        'sessionId': 'session-tab-1',
        'sequence': sequence,
        'sentAt': '2026-08-25T20:00:00.000Z',
        'expiresAt': '2026-08-25T20:01:00.000Z',
        'state': state,
        'scope': {'type': 'user_private', 'userId': 'user-1'},
      },
    };
