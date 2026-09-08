const messageSearchRequestFixture = <String, Object?>{
  'query': '  Cafe\u0301\t order\n updates  ',
  'filters': {
    'conversationIds': ['conversation-1', 'conversation-2'],
    'authorUserIds': ['user-1'],
    'sentAfter': '2026-08-01T10:00:00.000Z',
    'sentBefore': '2026-08-28T10:00:00-05:00',
  },
  'pageSize': 50,
  'cursor': 'opaque.page.2',
};

const normalizedMessageSearchRequestFixture = <String, Object?>{
  'query': 'Café order updates',
  'filters': {
    'conversationIds': ['conversation-1', 'conversation-2'],
    'authorUserIds': ['user-1'],
    'sentAfter': '2026-08-01T10:00:00.000Z',
    'sentBefore': '2026-08-28T10:00:00-05:00',
  },
  'pageSize': 50,
  'cursor': 'opaque.page.2',
};

const messageSearchResponseFixture = <String, Object?>{
  'hits': [
    {
      'type': 'message',
      'conversationId': 'conversation-1',
      'messageId': 'message-1',
      'title': 'Order coordination',
      'snippet': 'The café order is ready.',
      'authorUserId': 'user-1',
      'authorDisplayName': 'Ada',
      'sentAt': '2026-08-20T12:30:00.000Z',
    },
    {
      'type': 'conversation',
      'conversationId': 'conversation-2',
      'title': 'Café planning',
      'snippet': 'Conversation about the café launch.',
    },
  ],
  'nextCursor': 'opaque.page.3',
};
