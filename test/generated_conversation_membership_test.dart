import 'dart:convert';

import 'package:handrail_chat/core.dart';
import 'package:test/test.dart';

import 'fixtures/conversation_membership_fixtures.dart';

void main() {
  test('all five intent inputs round-trip with exact target and role shapes',
      () {
    final intents = <ConversationMembershipMutationIntent>{};
    for (final wire in membershipInputFixtures.values) {
      final parsed = ConversationMembershipMutationInput.fromJson(_copy(wire));
      expect(parsed.toJson(), wire);
      intents.add(parsed.intent);
    }
    expect(intents, ConversationMembershipMutationIntent.values.toSet());

    final invalid = <Map<String, Object?>>[
      {...membershipInputFixtures['join']!, 'targetUserId': 'user-actor'},
      {...membershipInputFixtures['leave']!, 'requestedRole': 'member'},
      {...membershipInputFixtures['add_member']!, 'targetUserId': null},
      {...membershipInputFixtures['add_member']!, 'requestedRole': null},
      {...membershipInputFixtures['remove_member']!, 'requestedRole': 'member'},
      {
        ...membershipInputFixtures['change_member_role']!,
        'requestedRole': null
      },
    ];
    for (final wire in invalid) {
      expect(
        () => ConversationMembershipMutationInput.fromJson(wire),
        throwsA(isA<ConversationMembershipFormatException>()),
      );
    }
  });

  test('fixtures cover every intent, reconciliation status, and safety code',
      () {
    final intents = <ConversationMembershipMutationIntent>{};
    final statuses = <ConversationMembershipReconciliationStatus>{};
    final safetyCodes = <ConversationMembershipSafetyErrorCode>{};
    for (final fixture in membershipOutcomeFixtures) {
      final input = ConversationMembershipMutationInput.fromJson(
        _copy(fixture.input),
      );
      final parsed = ConversationMembershipMutationResult.fromJson(
        _copy(fixture.result),
        expectedInput: input,
      );
      expect(parsed.toJson(), fixture.result);
      intents.add(parsed.intent);
      statuses.add(parsed.reconciliationStatus);
      if (parsed.safetyError case final safety?) safetyCodes.add(safety.code);
    }
    expect(intents, ConversationMembershipMutationIntent.values.toSet());
    expect(
      statuses,
      ConversationMembershipReconciliationStatus.values.toSet(),
    );
    expect(safetyCodes, ConversationMembershipSafetyErrorCode.values.toSet());
  });

  test('rejects normalized trusted identity and authorization aliases', () {
    for (final alias in <String>[
      'tenant-id',
      'organization.id',
      'Actor_User_ID',
      'current-user',
      'session id',
      'authorization',
      'roles',
      'capabilities',
      'permissions',
      'visibility-authorization',
      'host-entity-authorization',
    ]) {
      expect(
        () => ConversationMembershipMutationInput.fromJson({
          ...membershipInputFixtures['change_member_role']!,
          alias: alias == 'roles' ? ['owner'] : 'spoofed',
        }),
        throwsA(
          isA<ConversationMembershipFormatException>().having(
            (error) => error.code,
            'code',
            ConversationMembershipParseErrorCode.serverDerivedField,
          ),
        ),
        reason: alias,
      );
    }
  });

  test('enforces identifiers, roles, states, idempotency, and revisions', () {
    final join = membershipInputFixtures['join']!;
    final add = membershipInputFixtures['add_member']!;
    for (final invalid in <Map<String, Object?>>[
      {...join, 'conversationId': ' conversation-1'},
      {...join, 'expectedMemberListRevision': 0},
      {...join, 'expectedMemberListRevision': 9007199254740992},
      {...join, 'idempotencyKey': ' '},
      {...join, 'idempotencyKey': 'é' * 128},
      {...add, 'requestedRole': 'administrator'},
    ]) {
      expect(
        () => ConversationMembershipMutationInput.fromJson(invalid),
        throwsA(isA<ConversationMembershipFormatException>()),
      );
    }

    final input = ConversationMembershipMutationInput.fromJson(add);
    final result = appliedMembershipFixture(add);
    final members = result['members']! as List<Map<String, Object?>>;
    for (final invalidMembers in <List<Map<String, Object?>>>[
      [
        for (final member in members)
          {...member, if (member == members.last) 'role': 'admin'}
      ],
      [
        for (final member in members)
          {...member, if (member == members.last) 'state': 'invited'}
      ],
    ]) {
      expect(
        () => ConversationMembershipMutationResult.fromJson(
          {...result, 'members': invalidMembers},
          expectedInput: input,
        ),
        throwsA(isA<ConversationMembershipFormatException>()),
      );
    }
  });

  test('enforces canonical unique ordering and request/result coherence', () {
    final inputWire = membershipInputFixtures['add_member']!;
    final input = ConversationMembershipMutationInput.fromJson(inputWire);
    final valid = appliedMembershipFixture(inputWire);
    final members = valid['members']! as List<Map<String, Object?>>;
    final invalid = <Map<String, Object?>>[
      {
        ...valid,
        'members': [
          ...members,
          {...members.last}
        ]
      },
      {...valid, 'members': members.reversed.toList()},
      {...valid, 'targetUserId': 'user-other'},
      {...valid, 'memberUserId': 'user-other'},
      {...valid, 'requestedRole': 'owner'},
      {...valid, 'conversationId': 'conversation-other'},
      {...valid, 'expectedMemberListRevision': 5},
      {...valid, 'memberListRevision': 6},
      {...valid, 'toggle': true},
    ];
    for (final wire in invalid) {
      expect(
        () => ConversationMembershipMutationResult.fromJson(
          wire,
          expectedInput: input,
        ),
        throwsA(isA<ConversationMembershipFormatException>()),
      );
    }
  });

  test('enforces conflict and safety revision/member invariants', () {
    final leaveWire = membershipInputFixtures['leave']!;
    final leave = ConversationMembershipMutationInput.fromJson(leaveWire);
    final safety = membershipOutcomeFixtures
        .map((fixture) => fixture.result)
        .firstWhere((result) =>
            (result['safetyError'] as Map<String, Object?>?)?['code'] ==
            'last_active_member');
    final invalid = <Map<String, Object?>>[
      {...safety, 'memberListRevision': 6},
      {
        ...safety,
        'members': [
          ...(safety['members']! as List<Map<String, Object?>>),
          membershipMember('user-b', 'member'),
        ],
      },
      {
        ...safety,
        'members': [membershipMember('user-actor', 'owner', 'left')],
      },
    ];
    for (final wire in invalid) {
      expect(
        () => ConversationMembershipMutationResult.fromJson(
          wire,
          expectedInput: leave,
        ),
        throwsA(isA<ConversationMembershipFormatException>()),
      );
    }

    final addWire = membershipInputFixtures['add_member']!;
    final add = ConversationMembershipMutationInput.fromJson(addWire);
    final conflict = {
      ...appliedMembershipFixture(addWire),
      'reconciliationStatus': 'member_list_conflict',
      'memberListRevision': add.expectedMemberListRevision,
    };
    expect(
      () => ConversationMembershipMutationResult.fromJson(
        conflict,
        expectedInput: add,
      ),
      throwsA(isA<ConversationMembershipFormatException>()),
    );
  });

  test('parsed result collections are immutable and detached from wire lists',
      () {
    final inputWire = membershipInputFixtures['add_member']!;
    final input = ConversationMembershipMutationInput.fromJson(inputWire);
    final wire = appliedMembershipFixture(inputWire);
    final parsed = ConversationMembershipMutationResult.fromJson(
      wire,
      expectedInput: input,
    );
    final originalLength = parsed.members.length;
    expect(
      () => parsed.members.add(parsed.members.first),
      throwsUnsupportedError,
    );
    (wire['members']! as List<Object?>).clear();
    expect(parsed.members, hasLength(originalLength));
  });
}

Object? _copy(Object? value) => jsonDecode(jsonEncode(value));
