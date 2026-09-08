const editMessageRequestFixture = <String, Object?>{
  'operation': 'edit',
  'messageId': 'message-1',
  'expectedRevision': 2,
  'content': <String, Object?>{
    'format': 'markdown',
    'text': 'Edited **order 42**',
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
  'idempotencyKey': 'edit-attempt-1',
};

Map<String, Object?> editMessageResultFixture(
  String reconciliationStatus, {
  bool? notifyAuthor,
  String replyMessageId = 'source-message',
}) {
  final isConflict = reconciliationStatus == 'revision_conflict';
  final expectedRevision = isConflict ? 1 : 2;
  final canonicalRevision = 3;
  return <String, Object?>{
    'operation': 'edit',
    'reconciliationStatus': reconciliationStatus,
    'expectedRevision': expectedRevision,
    'message': <String, Object?>{
      'id': 'message-1',
      'tenantId': 'tenant-from-session',
      'conversationId': 'conversation-1',
      if (notifyAuthor != null)
        'replyTo': <String, Object?>{
          'messageId': replyMessageId,
          'notifyAuthor': notifyAuthor,
        },
      'author': <String, Object?>{
        'type': 'user',
        'userId': 'user-from-session',
      },
      'sequence': 7,
      'createdAt': '2026-08-25T20:00:00.000Z',
      'updatedAt': '2026-08-25T20:01:00.000Z',
      'revision': <String, Object?>{
        'revision': canonicalRevision,
        'editedAt': '2026-08-25T20:01:00.000Z',
        'editedByUserId': isConflict ? 'other-user' : 'user-from-session',
      },
      'content': isConflict
          ? <String, Object?>{
              'format': 'plain',
              'text': 'Current canonical content',
            }
          : editMessageRequestFixture['content'],
    },
    'canonicalRevision': canonicalRevision,
  };
}
