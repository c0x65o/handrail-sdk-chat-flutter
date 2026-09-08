import 'dart:convert';

import 'package:handrail_chat/core.dart';
import 'package:test/test.dart';

import 'fixtures/reaction_mutation_fixtures.dart';

void main() {
  test('add and remove inputs round-trip as deterministic immutable models',
      () {
    final add =
        ReactionMutationInput.fromJson(_roundTrip(addReactionInputFixture));
    final remove =
        ReactionMutationInput.fromJson(_roundTrip(removeReactionInputFixture));

    expect(add, isA<AddReactionInput>());
    expect(add.operation, ReactionMutationOperation.addReaction);
    expect(add.toJson(), addReactionInputFixture);
    expect(remove, isA<RemoveReactionInput>());
    expect(remove.operation, ReactionMutationOperation.removeReaction);
    expect(remove.toJson(), removeReactionInputFixture);
  });

  test('applied and replayed add/remove results preserve canonical aggregates',
      () {
    for (final fixtureBuilder in <Map<String, Object?> Function(String)>[
      addReactionResultFixture,
      removeReactionResultFixture,
    ]) {
      final applied = ReactionMutationResult.fromJson(
        _roundTrip(fixtureBuilder('applied')),
      );
      final replayed = ReactionMutationResult.fromJson(
        _roundTrip(fixtureBuilder('replayed')),
      );

      expect(
        applied.reconciliationStatus,
        ReactionMutationReconciliationStatus.applied,
      );
      expect(
        replayed.reconciliationStatus,
        ReactionMutationReconciliationStatus.replayed,
      );
      expect(
        {...replayed.toJson(), 'reconciliationStatus': 'applied'},
        applied.toJson(),
      );
    }
  });

  test('rejects non-NFC, oversized, blank, and padded reaction keys', () {
    for (final reactionKey in <String>[
      '',
      ' ',
      ' 👍',
      '👍 ',
      'e\u0301',
      'x' * 65,
      '👍' * 17,
    ]) {
      expect(
        () => ReactionMutationInput.fromJson({
          ...addReactionInputFixture,
          'reactionKey': reactionKey,
        }),
        throwsA(
          isA<ReactionMutationFormatException>().having(
            (error) => error.code,
            'code',
            ReactionMutationParseErrorCode.malformedReactionKey,
          ),
        ),
        reason: jsonEncode(reactionKey),
      );
    }

    expect(
      ReactionMutationInput.fromJson({
        ...addReactionInputFixture,
        'reactionKey': 'é',
      }).reactionKey,
      'é',
    );
    expect(
      ReactionMutationInput.fromJson({
        ...addReactionInputFixture,
        'reactionKey': 'x' * maxReactionKeyUtf8Bytes,
      }).reactionKey.length,
      maxReactionKeyUtf8Bytes,
    );
  });

  test('rejects extra input fields and normalized trusted identity aliases',
      () {
    for (final alias in <String>[
      'tenant-id',
      'organization_id',
      'Actor_User_ID',
      'current-user-id',
      'session',
      'authorization',
      'role',
      'roles',
    ]) {
      expect(
        () => ReactionMutationInput.fromJson({
          ...addReactionInputFixture,
          alias: alias == 'roles' ? <String>['admin'] : 'spoofed',
        }),
        throwsA(
          isA<ReactionMutationFormatException>().having(
            (error) => error.code,
            'code',
            ReactionMutationParseErrorCode.trustedIdentityField,
          ),
        ),
      );
    }

    expect(
      () => ReactionMutationInput.fromJson({
        ...removeReactionInputFixture,
        'desiredState': true,
      }),
      throwsA(isA<ReactionMutationFormatException>()),
    );
    expect(
      () => ReactionMutationInput.fromJson({
        ...removeReactionInputFixture,
        'idempotencyKey': '🙂' * 64,
      }),
      throwsA(isA<ReactionMutationFormatException>()),
    );
  });

  test(
      'rejects malformed aggregates, incoherent state, and extra result fields',
      () {
    final add = addReactionResultFixture('applied');
    final remove = removeReactionResultFixture('applied');
    final invalid = <Map<String, Object?>>[
      {...add, 'count': -1},
      {...add, 'count': 1.5},
      {...add, 'count': 0},
      {...add, 'reactedByCurrentUser': false},
      {...remove, 'reactedByCurrentUser': true},
      {...remove, 'reactionKey': 'e\u0301'},
      {...remove, 'reactionKey': 'x' * 65},
      {...remove, 'extra': true},
    ];

    for (final result in invalid) {
      expect(
        () => ReactionMutationResult.fromJson(result),
        throwsA(isA<ReactionMutationFormatException>()),
      );
    }

    expect(
      ReactionMutationResult.fromJson({...remove, 'count': 0}).count,
      0,
    );
  });
}

Object? _roundTrip(Object? value) => jsonDecode(jsonEncode(value));
