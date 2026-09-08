const sendMessageRequestFixture = <String, Object?>{
  'operation': 'send',
  'conversationId': 'conversation-1',
  'content': <String, Object?>{
    'format': 'markdown',
    'text': 'Order **42** is ready',
    'mentions': <Object?>[
      <String, Object?>{'type': 'user', 'userId': 'user-2'},
    ],
    'attachments': <Object?>[
      <String, Object?>{'attachmentId': 'attachment-1'},
    ],
    'blocks': <Object?>[
      <String, Object?>{
        'type': 'order',
        'data': <String, Object?>{'orderId': '42'},
      },
    ],
  },
  'clientMessageId': 'optimistic-1',
  'idempotencyKey': 'send-attempt-1',
};

Map<String, Object?> sendMessageResultFixture(String reconciliationStatus) =>
    <String, Object?>{
      'operation': 'send',
      'reconciliationStatus': reconciliationStatus,
      'clientMessageId': 'optimistic-1',
      'message': <String, Object?>{
        'id': 'message-1',
        'tenantId': 'tenant-from-session',
        'conversationId': 'conversation-1',
        'author': <String, Object?>{
          'type': 'user',
          'userId': 'user-from-session',
        },
        'sequence': 7,
        'createdAt': '2026-08-25T20:00:00.000Z',
        'updatedAt': '2026-08-25T20:00:00.000Z',
        'revision': <String, Object?>{'revision': 1},
        'content': sendMessageRequestFixture['content'],
      },
      'canonicalRevision': 1,
    };
