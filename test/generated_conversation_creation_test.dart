import 'dart:convert';

import 'package:handrail_chat/core.dart';
import 'package:test/test.dart';

import 'fixtures/conversation_creation_fixtures.dart';

void main() {
  test('all three creation variants JSON-round-trip through typed models', () {
    final cases = <Map<String, Object?>>[
      channelConversationCreationInputFixture,
      directConversationCreationInputFixture,
      groupDirectConversationCreationInputFixture,
    ];
    final inputs = cases
        .map((fixture) => parseConversationCreationInput(_roundTrip(fixture)))
        .toList();

    expect(inputs[0], isA<CreateChannelConversationInput>());
    expect(inputs[1], isA<CreateDirectConversationInput>());
    expect(inputs[2], isA<CreateGroupDirectConversationInput>());
    for (var index = 0; index < inputs.length; index += 1) {
      expect(inputs[index].toJson(), cases[index]);
    }
  });

  test('every allowed reconciliation status round-trips for each variant', () {
    final cases =
        <(Map<String, Object?>, List<String>, ConversationCreationType)>[
      (
        channelConversationCreationInputFixture,
        ['created', 'replayed'],
        ConversationCreationType.channel,
      ),
      (
        directConversationCreationInputFixture,
        ['created', 'existing_equivalent', 'replayed'],
        ConversationCreationType.direct,
      ),
      (
        groupDirectConversationCreationInputFixture,
        ['created', 'existing_equivalent', 'replayed'],
        ConversationCreationType.groupDirect,
      ),
    ];

    for (final (inputFixture, statuses, type) in cases) {
      final input = ConversationCreationInput.fromJson(inputFixture);
      for (final status in statuses) {
        final wire = conversationCreationResultFixture(type.wireValue, status);
        final result = parseConversationCreationResult(
          _roundTrip(wire),
          expectedInput: input,
        );
        expect(result.type, type);
        expect(result.reconciliationStatus.toJson(), status);
        expect(result.toJson(), wire);
      }
    }
  });

  test('trusted identity and authorization aliases are rejected recursively',
      () {
    for (final alias in <String>[
      'tenant-id',
      'organization_id',
      'Actor.User.ID',
      'current-user-id',
      'session_id',
      'authorization',
      'roles',
      'capabilities',
      'permissions',
    ]) {
      expect(
        () => parseConversationCreationInput({
          ...channelConversationCreationInputFixture,
          alias: 'spoofed',
        }),
        throwsA(_errorCode(
          ConversationCreationParseErrorCode.trustedIdentityField,
        )),
        reason: alias,
      );
    }
    expect(
      () => parseConversationCreationInput({
        ...channelConversationCreationInputFixture,
        'entity': {
          'type': 'erp.order',
          'id': '42',
          'nested': {'actorId': 'spoofed'},
        },
      }),
      throwsA(_errorCode(
        ConversationCreationParseErrorCode.trustedIdentityField,
      )),
    );
  });

  test('participant cardinality, blank IDs, and duplicates are rejected', () {
    final invalid = <Map<String, Object?>>[
      {...directConversationCreationInputFixture, 'intendedMemberUserIds': []},
      {
        ...directConversationCreationInputFixture,
        'intendedMemberUserIds': ['user-b', 'user-c'],
      },
      {
        ...directConversationCreationInputFixture,
        'intendedMemberUserIds': [' '],
      },
      {
        ...groupDirectConversationCreationInputFixture,
        'intendedMemberUserIds': ['user-b'],
      },
      {
        ...groupDirectConversationCreationInputFixture,
        'intendedMemberUserIds': ['user-b', ''],
      },
      {
        ...groupDirectConversationCreationInputFixture,
        'intendedMemberUserIds': ['user-b', 'user-b'],
      },
    ];
    for (final fixture in invalid) {
      expect(
        () => parseConversationCreationInput(fixture),
        throwsA(isA<ConversationCreationFormatException>()),
      );
    }

    expect(
      () => deriveCanonicalParticipantIdentity(
        const UserId('user-actor'),
        [const UserId('user-actor')],
      ),
      throwsA(_errorCode(
        ConversationCreationParseErrorCode.duplicateMemberId,
      )),
    );
  });

  test('canonical participant identity is complete and order-independent', () {
    final forward = deriveCanonicalParticipantIdentity(
      const UserId('user-actor'),
      [const UserId('user-b'), const UserId('user-c')],
    );
    final reversed = deriveCanonicalParticipantIdentity(
      const UserId('user-actor'),
      [const UserId('user-c'), const UserId('user-b')],
    );

    expect(forward.toJson(), reversed.toJson());
    expect(
      forward.participantUserIds,
      const [UserId('user-actor'), UserId('user-b'), UserId('user-c')],
    );
    expect(forward.key, startsWith('handrail-participants.v1.'));
    expect(
      () => forward.participantUserIds.add(const UserId('user-d')),
      throwsUnsupportedError,
    );
  });

  test('result and input type, request, snapshot, and identity stay coherent',
      () {
    final direct = parseCreateDirectConversationInput(
      directConversationCreationInputFixture,
    );
    final valid = conversationCreationResultFixture(
      'direct',
      'existing_equivalent',
    );
    final invalid = <Map<String, Object?>>[
      {...valid, 'clientRequestId': 'other-request'},
      conversationCreationResultFixture(
        'direct',
        'created',
        conversationTypeOverride: 'group_direct',
      ),
      conversationCreationResultFixture(
        'direct',
        'created',
        participantUserIds: ['user-actor', 'user-c'],
      ),
      conversationCreationResultFixture(
        'direct',
        'created',
        participantUserIds: ['user-b', 'user-actor'],
      ),
      conversationCreationResultFixture(
        'direct',
        'created',
        participantKey: 'wrong',
      ),
      conversationCreationResultFixture(
        'direct',
        'created',
        includeParticipantIdentity: false,
      ),
    ];
    for (final wire in invalid) {
      expect(
        () => parseConversationCreationResult(wire, expectedInput: direct),
        throwsA(isA<ConversationCreationFormatException>()),
      );
    }

    expect(
      () => parseConversationCreationResult(
        conversationCreationResultFixture('channel', 'existing_equivalent'),
        expectedInput: parseCreateChannelConversationInput(
          channelConversationCreationInputFixture,
        ),
      ),
      throwsA(_errorCode(
        ConversationCreationParseErrorCode.incoherentResult,
      )),
    );
    expect(
      () => parseConversationCreationResult({
        ...conversationCreationResultFixture('channel', 'created'),
        'participantIdentity': {
          'participantUserIds': ['user-actor'],
          'key': 'not-allowed',
        },
      }),
      throwsA(_errorCode(
        ConversationCreationParseErrorCode.malformedResult,
      )),
    );
  });
}

Matcher _errorCode(ConversationCreationParseErrorCode code) =>
    isA<ConversationCreationFormatException>().having(
      (error) => error.code,
      'code',
      code,
    );

Object? _roundTrip(Object? value) => jsonDecode(jsonEncode(value));
