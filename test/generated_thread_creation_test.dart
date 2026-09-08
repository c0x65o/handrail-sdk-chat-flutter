import 'dart:convert';

import 'package:handrail_chat/core.dart';
import 'package:test/test.dart';

import 'fixtures/thread_creation_fixtures.dart';

void main() {
  test('named and unnamed inputs round-trip exact names and follow intent', () {
    for (final name in <String?>[null, ..._validNames]) {
      for (final follow in <bool?>[null, false, true]) {
        final wire = Map<String, Object?>.from(threadCreationInputFixture)
          ..remove('initialFollow');
        if (name != null) wire['name'] = name;
        if (follow != null) wire['initialFollow'] = follow;
        final parsed = parseThreadCreationInput(_roundTrip(wire));
        expect(parsed.name, name);
        expect(parsed.toJson(), wire);
        expect(_roundTrip(parsed.toJson()), wire);
        final constructed = ThreadCreationInput(
          parentConversationId: parsed.parentConversationId,
          rootMessageId: parsed.rootMessageId,
          name: name,
          initialFollow: follow,
          idempotencyKey: parsed.idempotencyKey,
        );
        expect(constructed.toJson(), wire);
      }
    }
  });

  test('malformed supplied names retain malformedInput errors', () {
    for (final name in _malformedNames) {
      expect(
        () => parseThreadCreationInput(_roundTrip({
          ...threadCreationInputFixture,
          'name': name,
        })),
        _throwsThreadError(ThreadCreationParseErrorCode.malformedInput),
        reason: jsonEncode(name),
      );
      if (name is String) {
        expect(
          () => ThreadCreationInput(
            parentConversationId: const ConversationId('conversation-parent'),
            rootMessageId: const MessageId('message-root'),
            name: name,
            idempotencyKey: 'create-thread-1',
          ),
          _throwsThreadError(ThreadCreationParseErrorCode.malformedInput),
        );
      }
    }
  });

  test('creation names use frozen whitespace without normalization', () {
    const whitespace = [
      9,
      10,
      11,
      12,
      13,
      32,
      133,
      160,
      5760,
      8192,
      8193,
      8194,
      8195,
      8196,
      8197,
      8198,
      8199,
      8200,
      8201,
      8202,
      8232,
      8233,
      8239,
      8287,
      12288,
      65279
    ];
    for (final point in whitespace) {
      final space = String.fromCharCode(point);
      for (final name in [space, '${space}Launch', 'Launch$space']) {
        expect(
          () => parseThreadCreationInput(
              {...threadCreationInputFixture, 'name': name}),
          _throwsThreadError(ThreadCreationParseErrorCode.malformedInput),
        );
      }
      final name = 'a${space}b';
      expect(
          parseThreadCreationInput(
              {...threadCreationInputFixture, 'name': name}).name,
          name);
    }
  });

  for (final status in ['created', 'existing_for_root', 'replayed']) {
    test('$status retains authoritative named result and ID', () {
      for (final name in _validNames) {
        final wire = _resultWithName(status, name);
        for (final proposal in <String?>[null, 'Proposed different name']) {
          final input = ThreadCreationInput.fromJson({
            ...threadCreationInputFixture,
            if (proposal != null) 'name': proposal,
          });
          final parsed =
              parseThreadCreationResult(_roundTrip(wire), expectedInput: input);
          expect(parsed.conversation.thread.name, name);
          expect(parsed.conversation.thread.id,
              const ConversationId('canonical-thread'));
          expect(parsed.rootThreadSummary.threadId,
              const ConversationId('canonical-thread'));
          expect(parsed.toJson(), wire);
          expect(
              parseThreadCreationResult(_roundTrip(parsed.toJson()),
                      expectedInput: input)
                  .toJson(),
              wire);
        }
      }
    });
  }

  test(
      'proposal never fills an unnamed authoritative existing or replayed result',
      () {
    final input = ThreadCreationInput.fromJson(
        {...threadCreationInputFixture, 'name': 'Proposal'});
    for (final status in ['existing_for_root', 'replayed']) {
      final wire = threadCreationResultFixture(status);
      final parsed = parseThreadCreationResult(wire, expectedInput: input);
      expect(parsed.conversation.thread.name, isNull);
      expect(parsed.toJson(), wire);
    }
  });

  test(
      'malformed result names retain snapshot validation and malformedResult errors',
      () {
    final input = ThreadCreationInput.fromJson(threadCreationInputFixture);
    for (final name in _malformedNames) {
      expect(
        () => parseThreadCreationResult(
            _roundTrip(_resultWithName('created', name)),
            expectedInput: input),
        _throwsThreadError(ThreadCreationParseErrorCode.malformedResult),
      );
    }
  });

  test('input preserves optional follow intent and exact JSON', () {
    final input =
        parseThreadCreationInput(_roundTrip(threadCreationInputFixture));
    expect(input.initialFollow, isTrue);
    expect(input.toJson(), threadCreationInputFixture);

    final omitted = Map<String, Object?>.from(threadCreationInputFixture)
      ..remove('initialFollow');
    expect(parseThreadCreationInput(omitted).toJson(), omitted);

    final falseFollow = {...threadCreationInputFixture, 'initialFollow': false};
    expect(ThreadCreationInput.fromJson(falseFollow).toJson(), falseFollow);
  });

  test('all reconciliation statuses round-trip one canonical shape', () {
    final input = ThreadCreationInput.fromJson(threadCreationInputFixture);
    final cases = <String, ThreadCreationReconciliationStatus>{
      'created': ThreadCreationReconciliationStatus.created,
      'existing_for_root': ThreadCreationReconciliationStatus.existingForRoot,
      'replayed': ThreadCreationReconciliationStatus.replayed,
    };

    for (final entry in cases.entries) {
      final wire = threadCreationResultFixture(entry.key);
      final parsed = parseThreadCreationResult(
        _roundTrip(wire),
        expectedInput: input,
      );
      expect(parsed.reconciliationStatus, entry.value);
      expect(parsed.conversation.thread.id,
          const ConversationId('conversation-thread'));
      expect(parsed.toJson(), wire);
    }
  });

  test('rejects normalized trusted identity aliases anywhere in input', () {
    for (final alias in <String>[
      'tenant-id',
      'Actor_User_ID',
      'current.user.id',
      'session-id',
      'authorization',
      'roles',
      'capabilities',
      'permissions',
    ]) {
      expect(
        () => ThreadCreationInput.fromJson({
          ...threadCreationInputFixture,
          alias: 'spoofed',
        }),
        throwsA(
          isA<ThreadCreationFormatException>().having(
            (error) => error.code,
            'code',
            ThreadCreationParseErrorCode.trustedIdentityField,
          ),
        ),
        reason: alias,
      );
    }

    expect(
      () => ThreadCreationInput.fromJson({
        ...threadCreationInputFixture,
        'extra': {
          'actor-id': 'spoofed',
        },
      }),
      throwsA(
        isA<ThreadCreationFormatException>().having(
          (error) => error.code,
          'code',
          ThreadCreationParseErrorCode.trustedIdentityField,
        ),
      ),
    );
  });

  test('rejects malformed input and result envelopes', () {
    final input = ThreadCreationInput.fromJson(threadCreationInputFixture);
    final invalidInputs = <Object?>[
      null,
      {...threadCreationInputFixture, 'operation': 'open_thread'},
      {...threadCreationInputFixture, 'parentConversationId': ' '},
      {...threadCreationInputFixture, 'rootMessageId': ''},
      {...threadCreationInputFixture, 'initialFollow': 'yes'},
      {...threadCreationInputFixture, 'idempotencyKey': '\t'},
      {...threadCreationInputFixture, 'unexpected': true},
    ];
    for (final invalid in invalidInputs) {
      expect(
        () => parseThreadCreationInput(invalid),
        throwsA(isA<ThreadCreationFormatException>()),
      );
    }

    final valid = threadCreationResultFixture('created');
    final invalidResults = <Object?>[
      null,
      {...valid, 'operation': 'open_thread'},
      {...valid, 'reconciliationStatus': 'existing'},
      {...valid, 'rootThreadSummary': 'not-an-object'},
      {
        ...valid,
        'rootThreadSummary': {
          ...(valid['rootThreadSummary']! as Map<String, Object?>),
          'participantIds': 'not-an-array',
        },
      },
      {...valid, 'unexpected': true},
    ];
    for (final invalid in invalidResults) {
      expect(
        () => parseThreadCreationResult(invalid, expectedInput: input),
        throwsA(isA<ThreadCreationFormatException>()),
      );
    }
  });

  test('enforces request, parent, root, thread, and summary coherence', () {
    final input = ThreadCreationInput.fromJson(threadCreationInputFixture);
    final valid = threadCreationResultFixture('existing_for_root');
    final invalid = <Map<String, Object?>>[
      {...valid, 'parentConversationId': 'conversation-other'},
      {...valid, 'rootMessageId': 'message-other'},
      threadCreationResultFixture(
        'created',
        threadParentConversationId: 'conversation-other',
      ),
      threadCreationResultFixture(
        'created',
        threadRootMessageId: 'message-other',
      ),
      threadCreationResultFixture(
        'created',
        summaryThreadId: 'conversation-other-thread',
      ),
      threadCreationResultFixture('created', threadConversation: false),
    ];

    for (final wire in invalid) {
      expect(
        () => parseThreadCreationResult(wire, expectedInput: input),
        throwsA(
          isA<ThreadCreationFormatException>().having(
            (error) => error.code,
            'code',
            ThreadCreationParseErrorCode.incoherentResult,
          ),
        ),
      );
    }
  });

  test('canonical snapshot and root summary collections are immutable', () {
    final input = ThreadCreationInput.fromJson(threadCreationInputFixture);
    final result = ThreadCreationResult.fromJson(
      threadCreationResultFixture('replayed'),
      expectedInput: input,
    );

    expect(
      () => result.conversation.conversation.memberUserIds
          .add(const UserId('user-third')),
      throwsUnsupportedError,
    );
    expect(
      () => result.rootThreadSummary.participantIds
          .add(const UserId('user-third')),
      throwsUnsupportedError,
    );
  });
}

Object? _roundTrip(Object? value) => jsonDecode(jsonEncode(value));

final _validNames = <String>[
  'Launch 🚀',
  '🚀',
  'a' * 100,
  '🚀' * 100,
  'e\u0301' * 50,
  'a  b',
  'a\u0085b',
  '\u200b',
  '\u180e',
];
final _malformedNames = <Object?>[
  null,
  42,
  true,
  [],
  <String, Object?>{},
  '',
  ' ',
  '  \t\n',
  ' leading',
  'trailing ',
  'a' * 101,
  '🚀' * 101,
  'e\u0301' * 51,
  '\ud800',
  '\udfff',
  'x\ud800y',
];

Matcher _throwsThreadError(ThreadCreationParseErrorCode code) => throwsA(
      isA<ThreadCreationFormatException>()
          .having((error) => error.code, 'code', code),
    );

Map<String, Object?> _resultWithName(String status, Object? name) {
  final wire = threadCreationResultFixture(
    status,
    threadId: 'canonical-thread',
    summaryThreadId: 'canonical-thread',
  );
  final detail = wire['conversation']! as Map<String, Object?>;
  final thread = detail['conversation']! as Map<String, Object?>;
  thread['name'] = name;
  return wire;
}
