import 'dart:convert';

import 'package:handrail_chat/core.dart';
import 'package:test/test.dart';

void main() {
  final referenceTime = DateTime.utc(2026, 8, 28, 12);

  test('initial set, reschedule, and cancel requests round-trip', () {
    for (final fixture in [_initialSet, _reschedule, _cancel]) {
      final request = MessageReminderRequest.fromJson(
        _roundTrip(fixture),
        referenceTime: referenceTime,
      );
      expect(request.toJson(), fixture);
    }
    expect(
      MessageReminderRequest.fromJson(
        _initialSet,
        referenceTime: referenceTime,
      ),
      isA<SetMessageReminderRequest>(),
    );
    expect(
      MessageReminderRequest.fromJson(
        _cancel,
        referenceTime: referenceTime,
      ),
      isA<CancelMessageReminderRequest>(),
    );
  });

  test('every reconciliation status round-trips actor-private state', () {
    final cases = <(Map<String, Object?>, Map<String, Object?>)>[
      (_initialSet, _result(_initialSet, 'applied', 1)),
      (_reschedule, _result(_reschedule, 'applied', 2)),
      (_cancel, _result(_cancel, 'applied', 3)),
      (_initialSet, _result(_initialSet, 'replayed', 1)),
      (_reschedule, _result(_reschedule, 'already-requested', 1)),
      (
        _reschedule,
        _result(
          _reschedule,
          'revision-conflict',
          7,
          reminder: _cancelled,
        ),
      ),
      (
        _cancel,
        _result(_cancel, 'unavailable-source', null, reminder: null),
      ),
    ];
    for (final (inputWire, resultWire) in cases) {
      final input = MessageReminderRequest.fromJson(
        inputWire,
        referenceTime: referenceTime,
      );
      final result = MessageReminderResult.fromJson(
        _roundTrip(resultWire),
        expectedInput: input,
      );
      expect(result.toJson(), resultWire);
    }
  });

  test('rejects toggle, conditional due-time, unknown, and identity fields', () {
    final withoutDue = {..._initialSet}..remove('dueAt');
    final invalid = <(Map<String, Object?>, MessageReminderParseErrorCode)>[
      (
        {..._initialSet, 'operation': 'toggle_message_reminder'},
        MessageReminderParseErrorCode.malformedInput,
      ),
      (
        {..._initialSet, 'intent': 'toggle'},
        MessageReminderParseErrorCode.malformedInput,
      ),
      (
        {..._initialSet, 'toggle': true},
        MessageReminderParseErrorCode.toggleSemantics,
      ),
      (
        {..._initialSet, 'Reminder-Enabled': true},
        MessageReminderParseErrorCode.toggleSemantics,
      ),
      (
        {..._cancel, 'dueAt': _initialSet['dueAt']},
        MessageReminderParseErrorCode.malformedInput,
      ),
      (withoutDue, MessageReminderParseErrorCode.malformedInput),
      (
        {..._initialSet, 'unexpected': true},
        MessageReminderParseErrorCode.malformedInput,
      ),
      (
        {
          ..._initialSet,
          'extra': {
            'nested': {'Actor_User-ID': 'spoofed'}
          },
        },
        MessageReminderParseErrorCode.trustedIdentityField,
      ),
      (
        {
          ..._initialSet,
          'extra': [
            {'session.id': 'spoofed'}
          ],
        },
        MessageReminderParseErrorCode.trustedIdentityField,
      ),
    ];
    for (final (wire, code) in invalid) {
      expect(
        () => MessageReminderRequest.fromJson(
          wire,
          referenceTime: referenceTime,
        ),
        _throwsCode(code),
      );
    }
  });

  test('rejects malformed, numeric, non-finite, equal, and past timestamps', () {
    for (final (dueAt, code) in <(Object?, MessageReminderParseErrorCode)>[
      ('not-a-time', MessageReminderParseErrorCode.malformedTimestamp),
      ('2026-02-30T09:00:00.000Z', MessageReminderParseErrorCode.malformedTimestamp),
      ('2026-08-29', MessageReminderParseErrorCode.malformedTimestamp),
      (1787983200000, MessageReminderParseErrorCode.malformedTimestamp),
      (double.nan, MessageReminderParseErrorCode.malformedTimestamp),
      (double.infinity, MessageReminderParseErrorCode.malformedTimestamp),
      ('2026-08-28T12:00:00.000Z', MessageReminderParseErrorCode.dueTimeNotFuture),
      ('2026-08-28T11:59:59.999Z', MessageReminderParseErrorCode.dueTimeNotFuture),
    ]) {
      expect(
        () => MessageReminderRequest.fromJson(
          {..._initialSet, 'dueAt': dueAt},
          referenceTime: referenceTime,
        ),
        _throwsCode(code),
      );
    }
  });

  test('rejects unsafe revisions and bounded idempotency violations', () {
    for (final revision in <Object?>[
      -1,
      1.5,
      double.nan,
      double.infinity,
      9007199254740991,
      9007199254740992,
    ]) {
      expect(
        () => MessageReminderRequest.fromJson(
          {..._initialSet, 'expectedReminderRevision': revision},
          referenceTime: referenceTime,
        ),
        _throwsCode(MessageReminderParseErrorCode.malformedRevision),
      );
    }
    for (final key in ['', '   ', ' surrounded ', 'x' * 256]) {
      expect(
        () => MessageReminderRequest.fromJson(
          {..._initialSet, 'idempotencyKey': key},
          referenceTime: referenceTime,
        ),
        _throwsCode(MessageReminderParseErrorCode.malformedIdempotencyKey),
      );
    }
  });

  test('result enforces correlation and status/revision/state coherence', () {
    final input = MessageReminderRequest.fromJson(
      _initialSet,
      referenceTime: referenceTime,
    );
    final applied = _result(_initialSet, 'applied', 1);
    for (final wire in <Map<String, Object?>>[
      {...applied, 'intent': 'cancel'},
      {...applied, 'conversationId': 'conversation-other'},
      {...applied, 'messageId': 'message-other'},
      {...applied, 'expectedReminderRevision': 1},
      {...applied, 'idempotencyKey': 'reminder:other'},
    ]) {
      expect(
        () => MessageReminderResult.fromJson(wire, expectedInput: input),
        _throwsCode(MessageReminderParseErrorCode.correlationMismatch),
      );
    }
    for (final wire in <Map<String, Object?>>[
      {...applied, 'reminderRevision': 0},
      {...applied, 'reconciliationStatus': 'replayed', 'reminderRevision': 0},
      {
        ...applied,
        'reconciliationStatus': 'already-requested',
        'reminderRevision': 1,
      },
      {...applied, 'reconciliationStatus': 'revision-conflict'},
      {...applied, 'reminder': _cancelled},
      {
        ...applied,
        'reconciliationStatus': 'unavailable-source',
        'reminder': null,
      },
      {
        ...applied,
        'reconciliationStatus': 'unavailable-source',
        'reminderRevision': null,
      },
    ]) {
      expect(
        () => MessageReminderResult.fromJson(wire, expectedInput: input),
        _throwsCode(MessageReminderParseErrorCode.incoherentResult),
      );
    }
    expect(
      () => MessageReminderResult.fromJson(
        {...applied, 'actorUserId': 'other-actor'},
        expectedInput: input,
      ),
      _throwsCode(MessageReminderParseErrorCode.malformedResult),
    );
    final scheduled = applied['reminder']! as Map<String, Object?>;
    expect(
      () => MessageReminderResult.fromJson(
        {
          ...applied,
          'reminder': {...scheduled, 'userId': 'other-actor'},
        },
        expectedInput: input,
      ),
      _throwsCode(MessageReminderParseErrorCode.malformedResult),
    );
  });
}

const _initialSet = <String, Object?>{
  'operation': 'message_reminder.v1',
  'intent': 'set',
  'conversationId': 'conversation-alpha',
  'messageId': 'message-alpha',
  'expectedReminderRevision': 0,
  'idempotencyKey': 'reminder:set:initial',
  'dueAt': '2026-08-29T09:00:00.000Z',
};

const _reschedule = <String, Object?>{
  'operation': 'message_reminder.v1',
  'intent': 'set',
  'conversationId': 'conversation-alpha',
  'messageId': 'message-alpha',
  'expectedReminderRevision': 1,
  'idempotencyKey': 'reminder:set:reschedule',
  'dueAt': '2026-08-30T15:30:00.000Z',
};

const _cancel = <String, Object?>{
  'operation': 'message_reminder.v1',
  'intent': 'cancel',
  'conversationId': 'conversation-alpha',
  'messageId': 'message-alpha',
  'expectedReminderRevision': 2,
  'idempotencyKey': 'reminder:cancel',
};

const _cancelled = <String, Object?>{
  'privacy': 'affected_authenticated_actor',
  'state': 'cancelled',
};

Map<String, Object?> _canonical(Map<String, Object?> input) =>
    input['intent'] == 'set'
        ? <String, Object?>{
            'privacy': 'affected_authenticated_actor',
            'state': 'scheduled',
            'dueAt': input['dueAt'],
          }
        : {..._cancelled};

Map<String, Object?> _result(
  Map<String, Object?> input,
  String status,
  int? reminderRevision, {
  Object? reminder = _sentinel,
}) =>
    <String, Object?>{
      'operation': 'message_reminder.v1',
      'intent': input['intent'],
      'reconciliationStatus': status,
      'conversationId': input['conversationId'],
      'messageId': input['messageId'],
      'expectedReminderRevision': input['expectedReminderRevision'],
      'idempotencyKey': input['idempotencyKey'],
      'reminderRevision': reminderRevision,
      'reminder': identical(reminder, _sentinel) ? _canonical(input) : reminder,
    };

const _sentinel = Object();

Object? _roundTrip(Object? value) => jsonDecode(jsonEncode(value));

Matcher _throwsCode(MessageReminderParseErrorCode code) => throwsA(
      isA<MessageReminderFormatException>().having(
        (error) => error.code,
        'code',
        code,
      ),
    );
