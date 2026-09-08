import 'dart:convert';

import 'package:handrail_chat/core.dart';
import 'package:test/test.dart';

import 'fixtures/thread_follow_mutation_fixtures.dart';

void main() {
  test('matching state at a different revision is a valid conflict', () {
    final result = {
      ...settledThreadFollowResultFixture(followThreadInputFixture, 'applied'),
      'reconciliationStatus': 'follow_revision_conflict',
      'followRevision': 12,
    };
    final parsed = SetThreadFollowResult.fromJson(result,
      expectedInput: SetThreadFollowInput.fromJson(followThreadInputFixture));
    expect(parsed.followRevision, 12);
  });

  test('manual follow and explicit manual unfollow inputs round-trip immutably',
      () {
    final follow =
        SetThreadFollowInput.fromJson(_roundTrip(followThreadInputFixture));
    final unfollow =
        SetThreadFollowInput.fromJson(_roundTrip(unfollowThreadInputFixture));
    expect(follow, isA<FollowThreadInput>());
    expect(unfollow, isA<UnfollowThreadInput>());
    expect(follow.toJson(), followThreadInputFixture);
    expect(unfollow.toJson(), unfollowThreadInputFixture);

    final mutable = follow.toJson();
    (mutable['target']! as Map<String, Object?>)['id'] = 'mutated';
    expect(follow.target.id.value, 'thread-alpha');
    expect(follow.toJson(), followThreadInputFixture);
  });

  test('manual, reply, and mention canonical states preserve private semantics',
      () {
    final manualFollow = CanonicalThreadFollowState.fromJson(
      settledThreadFollowResultFixture(
          followThreadInputFixture, 'applied')['follow'],
    );
    final manualUnfollow = CanonicalThreadFollowState.fromJson(
      settledThreadFollowResultFixture(
          unfollowThreadInputFixture, 'applied')['follow'],
    );
    final reply =
        CanonicalThreadFollowState.fromJson(autoFollowStateFixture('reply'));
    final mention =
        CanonicalThreadFollowState.fromJson(autoFollowStateFixture('mention'));

    expect(manualFollow, isA<CanonicalFollowingThreadState>());
    expect(manualFollow.source, ThreadFollowSource.manual);
    expect(manualUnfollow, isA<CanonicalManualThreadUnfollowState>());
    expect(manualUnfollow.isFollowing, false);
    expect(reply.source, ThreadFollowSource.reply);
    expect(mention.source, ThreadFollowSource.mention);
    expect(reply.isFollowing, true);
    expect(mention.isFollowing, true);

    const replyPolicy = ServerDerivedThreadParticipationAutoFollow(
      ServerDerivedThreadAutoFollowSource.reply,
    );
    expect(replyPolicy.origin, 'server_policy');
    expect(replyPolicy.whenExplicitlyUnfollowed, 'preserve_explicit_unfollow');
  });

  test(
      'every reconciliation status obeys its revision and canonical-state rule',
      () {
    final cases = <({Map<String, Object?> input, Map<String, Object?> result})>[
      (
        input: followThreadInputFixture,
        result: settledThreadFollowResultFixture(
            followThreadInputFixture, 'applied'),
      ),
      (
        input: followThreadInputFixture,
        result: settledThreadFollowResultFixture(
            followThreadInputFixture, 'replayed'),
      ),
      (
        input: unfollowThreadInputFixture,
        result: settledThreadFollowResultFixture(
          unfollowThreadInputFixture,
          'already_requested_state',
        ),
      ),
      (
        input: followThreadInputFixture,
        result:
            conflictingThreadFollowResultFixture(followThreadInputFixture, 8),
      ),
      (
        input: unfollowThreadInputFixture,
        result: conflictingThreadFollowResultFixture(
          unfollowThreadInputFixture,
          11,
          source: 'mention',
        ),
      ),
    ];
    for (final fixture in cases) {
      final input = SetThreadFollowInput.fromJson(fixture.input);
      final result = SetThreadFollowResult.fromJson(
        _roundTrip(fixture.result),
        expectedInput: input,
      );
      expect(result.toJson(), fixture.result);
    }
  });

  test('rejects caller-authored auto-follow sources and trusted identity', () {
    for (final entry in <(String, Object?)>[
      ('source', 'manual'),
      ('followSource', 'reply'),
      ('auto-follow_source', 'mention'),
      ('participation cause', 'reply'),
    ]) {
      expect(
        () => SetThreadFollowInput.fromJson({
          ...followThreadInputFixture,
          entry.$1: entry.$2,
        }),
        _throwsCode(
            ThreadFollowMutationParseErrorCode.callerAuthoredAutoFollow),
      );
    }
    for (final entry in <(String, Object?)>[
      ('tenant-id', 'tenant-spoof'),
      ('organization.id', 'organization-spoof'),
      ('Actor_User_ID', 'user-spoof'),
      ('current user', const {'id': 'user-spoof'}),
      ('authentication', const {'user': 'user-spoof'}),
      ('authorization', 'Bearer spoof'),
      ('roles', const ['admin']),
      ('permissions', const ['thread-follow:any']),
    ]) {
      expect(
        () => SetThreadFollowInput.fromJson({
          ...followThreadInputFixture,
          entry.$1: entry.$2,
        }),
        _throwsCode(ThreadFollowMutationParseErrorCode.trustedIdentityField),
      );
    }
  });

  test('validates thread target, bounded identity, and explicit input shape',
      () {
    for (final invalid in <Map<String, Object?>>[
      {...followThreadInputFixture, 'operation': 'toggle_thread_follow'},
      {...followThreadInputFixture, 'intent': 'toggle'},
      {...followThreadInputFixture, 'toggle': true},
      {...followThreadInputFixture, 'isFollowing': true},
      {
        ...followThreadInputFixture,
        'target': const {'type': 'channel', 'id': 'channel-parent'}
      },
      {
        ...followThreadInputFixture,
        'target': const {'type': 'thread', 'id': ''}
      },
      {...followThreadInputFixture, 'channelId': 'channel-parent'},
      {...followThreadInputFixture, 'expectedFollowRevision': -1},
      {...followThreadInputFixture, 'expectedFollowRevision': 1.5},
      {...followThreadInputFixture, 'expectedFollowRevision': 9007199254740991},
      {...followThreadInputFixture, 'idempotencyKey': ''},
      {...followThreadInputFixture, 'idempotencyKey': ' surrounded '},
      {...followThreadInputFixture, 'idempotencyKey': 'x' * 256},
    ]) {
      expect(
        () => SetThreadFollowInput.fromJson(invalid),
        throwsA(isA<ThreadFollowMutationFormatException>()),
      );
    }
  });

  test(
      'rejects incoherent echoes, status revisions, canonical state, and timestamps',
      () {
    final input = SetThreadFollowInput.fromJson(followThreadInputFixture);
    final applied =
        settledThreadFollowResultFixture(followThreadInputFixture, 'applied');
    final canonical = applied['follow']! as Map<String, Object?>;
    for (final invalid in <Map<String, Object?>>[
      {...applied, 'intent': 'unfollow'},
      {
        ...applied,
        'target': const {'type': 'thread', 'id': 'thread-other'}
      },
      {...applied, 'expectedFollowRevision': 1},
      {...applied, 'idempotencyKey': 'thread-follow:other'},
      {...applied, 'followRevision': 2},
      {...applied, 'reconciliationStatus': 'already_requested_state'},
      {...applied, 'reconciliationStatus': 'follow_revision_conflict', 'followRevision': 2},
      {
        ...applied,
        'follow': {
          ...canonical,
          'target': const {'type': 'thread', 'id': 'thread-other'}
        }
      },
      {
        ...applied,
        'follow': {...canonical, 'isFollowing': false}
      },
      {
        ...applied,
        'follow': {...canonical, 'source': 'reply'}
      },
      {
        ...applied,
        'follow': {...canonical, 'updatedAt': '2030-02-30T04:05:06.000Z'}
      },
      {...applied, 'actorUserId': 'server-only'},
    ]) {
      expect(
        () => SetThreadFollowResult.fromJson(invalid, expectedInput: input),
        throwsA(isA<ThreadFollowMutationFormatException>()),
      );
    }

    expect(
      () => CanonicalThreadFollowState.fromJson({
        ...autoFollowStateFixture('mention'),
        'isFollowing': false,
      }),
      _throwsCode(ThreadFollowMutationParseErrorCode.incoherentResult),
    );
  });
}

Matcher _throwsCode(ThreadFollowMutationParseErrorCode code) => throwsA(
      isA<ThreadFollowMutationFormatException>().having(
        (error) => error.code,
        'code',
        code,
      ),
    );

Object? _roundTrip(Object? value) => jsonDecode(jsonEncode(value));
