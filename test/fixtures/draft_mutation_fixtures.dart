const replaceDraftInputFixture = <String, Object?>{
  'operation': 'synchronize_draft',
  'intent': 'replace',
  'conversationId': 'conversation-1',
  'baseRevision': 4,
  'deviceMutationId': 'phone-a:mutation-17',
  'idempotencyKey': 'draft:conversation-1:phone-a:17',
  'content': <String, Object?>{
    'format': 'markdown',
    'text': 'Review **invoice 42**',
    'mentions': <Object?>[
      <String, Object?>{'type': 'user', 'userId': 'user-reviewer'},
      <String, Object?>{
        'type': 'conversation',
        'conversationId': 'conversation-reviews',
      },
      <String, Object?>{
        'type': 'entity',
        'entity': <String, Object?>{'type': 'invoice', 'id': 'invoice-42'},
      },
    ],
    'attachments': <Object?>[
      <String, Object?>{'attachmentId': 'attachment-1'},
      <String, Object?>{'attachmentId': 'attachment-2'},
    ],
  },
};

const clearDraftInputFixture = <String, Object?>{
  'operation': 'synchronize_draft',
  'intent': 'clear',
  'conversationId': 'conversation-1',
  'baseRevision': 5,
  'deviceMutationId': 'phone-b:mutation-8',
  'idempotencyKey': 'draft:conversation-1:phone-b:8',
};

const canonicalDraftUpdatedAtFixture = '2026-08-26T05:15:00.000Z';

Map<String, Object?> settledDraftResultFixture(
  Map<String, Object?> input, {
  String reconciliationStatus = 'applied',
}) =>
    <String, Object?>{
      'operation': 'synchronize_draft',
      'intent': input['intent'],
      'reconciliationStatus': reconciliationStatus,
      'conversationId': input['conversationId'],
      'baseRevision': input['baseRevision'],
      'deviceMutationId': input['deviceMutationId'],
      'idempotencyKey': input['idempotencyKey'],
      'canonicalRevision': (input['baseRevision']! as int) + 1,
      'canonicalUpdatedAt': canonicalDraftUpdatedAtFixture,
      'draft': input['intent'] == 'replace'
          ? <String, Object?>{
              'kind': 'replaced',
              'content': input['content'],
            }
          : const <String, Object?>{
              'kind': 'clear_tombstone',
              'content': null,
            },
    };

Map<String, Object?> staleDraftResultFixture(
  Map<String, Object?> input, {
  int canonicalRevision = 11,
}) =>
    <String, Object?>{
      'operation': 'synchronize_draft',
      'intent': input['intent'],
      'reconciliationStatus': 'stale_base',
      'conversationId': input['conversationId'],
      'baseRevision': input['baseRevision'],
      'deviceMutationId': input['deviceMutationId'],
      'idempotencyKey': input['idempotencyKey'],
      'canonicalRevision': canonicalRevision,
      'canonicalUpdatedAt': canonicalDraftUpdatedAtFixture,
      'draft': const <String, Object?>{
        'kind': 'replaced',
        'content': <String, Object?>{
          'format': 'plain',
          'text': 'Saved by another device',
          'attachments': <Object?>[],
        },
      },
    };

Map<String, Object?> draftUpdatedEventFixture(
  Map<String, Object?> input,
  Map<String, Object?> result,
) =>
    <String, Object?>{
      'eventId': 'event-draft-1',
      'protocolVersion': 4,
      'tenantId': 'tenant-1',
      'streamId': 'user:user-1',
      'type': 'conversation.draft.updated',
      'occurredAt': canonicalDraftUpdatedAtFixture,
      'payload': <String, Object?>{
        'actorUserId': 'user-1',
        'input': input,
        'result': result,
      },
    };
