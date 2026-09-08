const softDeleteMessageRequestFixture = <String, Object?>{
  'operation': 'soft_delete',
  'messageId': 'message-1',
  'expectedRevision': 2,
  'idempotencyKey': 'delete-attempt-1',
};

Map<String, Object?> softDeleteMessageResultFixture(
  String reconciliationStatus,
) {
  final isConflict = reconciliationStatus == 'revision_conflict';
  final expectedRevision = isConflict ? 1 : 2;
  const canonicalRevision = 3;
  return <String, Object?>{
    'operation': 'soft_delete',
    'reconciliationStatus': reconciliationStatus,
    'expectedRevision': expectedRevision,
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
      'updatedAt': '2026-08-25T20:02:00.000Z',
      'revision': <String, Object?>{
        'revision': canonicalRevision,
      },
      'content': null,
      'deletedAt': '2026-08-25T20:02:00.000Z',
      'deletedByUserId': 'user-from-session',
    },
    'canonicalRevision': canonicalRevision,
  };
}
