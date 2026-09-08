import 'thread_creation_fixtures.dart';

Map<String, Object?> existingThreadDetailFixture() {
  final detail =
      threadCreationResultFixture('existing_for_root')['conversation']
          as Map<String, Object?>;
  final conversation = detail['conversation'] as Map<String, Object?>;
  conversation['name'] = 'Canonical discussion';
  // Authorized reader with no retained child membership or follow setup.
  conversation['memberUserIds'] = <String>[];
  conversation['activeMemberUserIds'] = <String>[];
  final member = conversation['currentMember'] as Map<String, Object?>;
  member['state'] = 'left';
  return detail;
}

Map<String, Object?> existingThreadTimelineFixture({
  bool parent = false,
  bool deletedRoot = true,
  bool missingRoot = false,
}) =>
    {
      'conversationId': parent ? 'conversation-parent' : 'conversation-thread',
      'messages': parent && missingRoot
          ? <Object?>[]
          : [
              {
                'id': parent ? 'message-root' : 'message-reply',
                'tenantId': 'tenant-from-session',
                'conversationId':
                    parent ? 'conversation-parent' : 'conversation-thread',
                'author': {'type': 'user', 'userId': 'user-other'},
                'sequence': parent ? 1 : 2,
                'createdAt': existingThreadFixtureTime,
                'updatedAt': existingThreadFixtureTime,
                'revision': {'revision': 2},
                'content': parent && deletedRoot
                    ? null
                    : {'format': 'plain', 'text': 'History'},
                if (parent && deletedRoot) ...{
                  'deletedAt': existingThreadFixtureTime,
                  'deletedByUserId': 'user-other',
                },
                'isThreadRoot': false,
                'reactions': <Object?>[],
                'attachmentMetadata': <Object?>[],
              },
            ],
      'pagination': {
        'older': {'available': false},
        'newer': {'available': false}
      },
      'replay': {
        'resumeFrom': {'eventId': 'event-existing-thread'}
      },
    };

const existingThreadFixtureTime = '2026-08-26T16:00:00.000Z';
