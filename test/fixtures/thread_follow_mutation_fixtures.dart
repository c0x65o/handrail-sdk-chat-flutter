const threadFollowUpdatedAt = '2026-08-26T20:00:00.000Z';

const followThreadInputFixture = <String, Object?>{
  'operation': 'set_thread_follow',
  'intent': 'follow',
  'target': <String, Object?>{'type': 'thread', 'id': 'thread-alpha'},
  'expectedFollowRevision': 2,
  'idempotencyKey': 'thread-follow:alpha:3',
};

const unfollowThreadInputFixture = <String, Object?>{
  'operation': 'set_thread_follow',
  'intent': 'unfollow',
  'target': <String, Object?>{'type': 'thread', 'id': 'thread-beta'},
  'expectedFollowRevision': 7,
  'idempotencyKey': 'thread-unfollow:beta:8',
};

Map<String, Object?> settledThreadFollowResultFixture(
  Map<String, Object?> input,
  String status,
) =>
    <String, Object?>{
      'operation': 'set_thread_follow',
      'intent': input['intent'],
      'reconciliationStatus': status,
      'target': input['target'],
      'expectedFollowRevision': input['expectedFollowRevision'],
      'idempotencyKey': input['idempotencyKey'],
      'followRevision': status == 'already_requested_state'
          ? input['expectedFollowRevision']
          : (input['expectedFollowRevision']! as int) + 1,
      'follow': <String, Object?>{
        'target': input['target'],
        'isFollowing': input['intent'] == 'follow',
        'source': 'manual',
        'updatedAt': threadFollowUpdatedAt,
      },
    };

Map<String, Object?> conflictingThreadFollowResultFixture(
  Map<String, Object?> input,
  int followRevision, {
  String source = 'manual',
}) =>
    <String, Object?>{
      'operation': 'set_thread_follow',
      'intent': input['intent'],
      'reconciliationStatus': 'follow_revision_conflict',
      'target': input['target'],
      'expectedFollowRevision': input['expectedFollowRevision'],
      'idempotencyKey': input['idempotencyKey'],
      'followRevision': followRevision,
      'follow': <String, Object?>{
        'target': input['target'],
        'isFollowing': input['intent'] != 'follow',
        'source': source,
        'updatedAt': threadFollowUpdatedAt,
      },
    };

Map<String, Object?> autoFollowStateFixture(String source) => <String, Object?>{
      'target': const <String, Object?>{'type': 'thread', 'id': 'thread-auto'},
      'isFollowing': true,
      'source': source,
      'updatedAt': threadFollowUpdatedAt,
    };
