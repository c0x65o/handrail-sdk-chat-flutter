import 'dart:convert';

import 'package:handrail_chat/core.dart';
import 'package:test/test.dart';

void main() {
  test('archive and restore inputs round-trip explicit intents', () {
    for (final wire in [_archiveInput, _restoreInput]) {
      final parsed = ConversationArchiveInput.fromJson(_roundTrip(wire));
      expect(parsed.toJson(), wire);
    }

    expect(
      ConversationArchiveInput.fromJson(_archiveInput).intent,
      ConversationArchiveIntent.archive,
    );
    expect(
      ConversationArchiveInput.fromJson(_restoreInput).intent,
      ConversationArchiveIntent.restore,
    );
  });

  test('both intents accept every valid reconciliation state', () {
    final archiveInput = ConversationArchiveInput.fromJson(_archiveInput);
    final restoreInput = ConversationArchiveInput.fromJson(_restoreInput);
    final cases = <({
      ConversationArchiveInput input,
      String status,
      int revision,
      Map<String, Object?> state,
    })>[
      (input: archiveInput, status: 'applied', revision: 5, state: _archived),
      (input: archiveInput, status: 'replayed', revision: 5, state: _archived),
      (
        input: archiveInput,
        status: 'already_requested_state',
        revision: 8,
        state: _archived,
      ),
      (
        input: archiveInput,
        status: 'lifecycle_conflict',
        revision: 7,
        state: _active,
      ),
      (input: restoreInput, status: 'applied', revision: 10, state: _active),
      (input: restoreInput, status: 'replayed', revision: 10, state: _active),
      (
        input: restoreInput,
        status: 'already_requested_state',
        revision: 12,
        state: _active,
      ),
      (
        input: restoreInput,
        status: 'lifecycle_conflict',
        revision: 11,
        state: _archived,
      ),
    ];

    for (final fixture in cases) {
      final wire = _result(
        fixture.input.toJson(),
        fixture.status,
        fixture.revision,
        fixture.state,
      );
      final parsed = ConversationArchiveResult.fromJson(
        _roundTrip(wire),
        expectedInput: fixture.input,
      );
      expect(parsed.toJson(), wire);
      if (parsed.archiveState case ArchivedConversationArchiveState state) {
        expect(state.archivedByUserId, const UserId('user-from-session'));
      }
    }
  });

  test('rejects toggle requests, malformed fields, extras, and trusted aliases',
      () {
    for (final invalid in <Map<String, Object?>>[
      {..._archiveInput, 'intent': 'toggle'},
      {..._archiveInput, 'operation': 'toggle_conversation_archive'},
      {..._archiveInput, 'toggle': true},
      {..._archiveInput, 'archived': true},
      {..._archiveInput, 'expectedLifecycleRevision': 0},
      {..._archiveInput, 'expectedLifecycleRevision': 9007199254740992},
      {..._archiveInput, 'idempotencyKey': ' '},
    ]) {
      expect(
        () => ConversationArchiveInput.fromJson(invalid),
        throwsA(isA<ConversationArchiveFormatException>()),
      );
    }

    for (final alias in <String>[
      'tenant-id',
      'Actor_User_ID',
      'current-user',
      'authorization',
      'roles',
      'capabilities',
      'permissions',
      'host-entity-authorization',
    ]) {
      expect(
        () => ConversationArchiveInput.fromJson({
          ..._archiveInput,
          alias: alias == 'roles' ? <String>['admin'] : 'spoofed',
        }),
        throwsA(
          isA<ConversationArchiveFormatException>().having(
            (error) => error.code,
            'code',
            ConversationArchiveParseErrorCode.trustedIdentityField,
          ),
        ),
      );
    }
  });

  test('rejects impossible intent, state, identity, and revision results', () {
    final archiveInput = ConversationArchiveInput.fromJson(_archiveInput);
    final restoreInput = ConversationArchiveInput.fromJson(_restoreInput);
    final invalid = <({
      ConversationArchiveInput input,
      Map<String, Object?> result,
    })>[
      (
        input: archiveInput,
        result: _result(_archiveInput, 'applied', 4, _archived),
      ),
      (
        input: archiveInput,
        result: _result(_archiveInput, 'applied', 5, _active),
      ),
      (
        input: archiveInput,
        result: _result(_archiveInput, 'lifecycle_conflict', 4, _active),
      ),
      (
        input: archiveInput,
        result: _result(_archiveInput, 'lifecycle_conflict', 7, _archived),
      ),
      (
        input: restoreInput,
        result: _result(_restoreInput, 'applied', 10, _archived),
      ),
      (
        input: restoreInput,
        result: _result(_restoreInput, 'lifecycle_conflict', 11, _active),
      ),
      (
        input: archiveInput,
        result: _result(_archiveInput, 'applied', 5, {
          'status': 'archived',
          'archivedAt': _archivedAt,
        }),
      ),
      (
        input: archiveInput,
        result: {
          ..._result(_archiveInput, 'applied', 5, _archived),
          'expectedLifecycleRevision': 3,
        },
      ),
      (
        input: archiveInput,
        result: {
          ..._result(_archiveInput, 'applied', 5, _archived),
          'serverRoute': '/internal/archive',
        },
      ),
    ];

    for (final fixture in invalid) {
      expect(
        () => ConversationArchiveResult.fromJson(
          fixture.result,
          expectedInput: fixture.input,
        ),
        throwsA(isA<ConversationArchiveFormatException>()),
      );
    }
  });
}

const _archivedAt = '2026-08-25T22:00:00.000Z';
const _archiveInput = <String, Object?>{
  'operation': 'set_conversation_archive',
  'intent': 'archive',
  'conversationId': 'conversation-1',
  'expectedLifecycleRevision': 4,
  'idempotencyKey': 'archive-conversation-1',
};
const _restoreInput = <String, Object?>{
  'operation': 'set_conversation_archive',
  'intent': 'restore',
  'conversationId': 'conversation-1',
  'expectedLifecycleRevision': 9,
  'idempotencyKey': 'restore-conversation-1',
};
const _active = <String, Object?>{'status': 'active'};
const _archived = <String, Object?>{
  'status': 'archived',
  'archivedAt': _archivedAt,
  'archivedByUserId': 'user-from-session',
};

Map<String, Object?> _result(
  Map<String, Object?> input,
  String status,
  int lifecycleRevision,
  Map<String, Object?> state,
) =>
    {
      'operation': input['operation'],
      'intent': input['intent'],
      'reconciliationStatus': status,
      'conversationId': input['conversationId'],
      'expectedLifecycleRevision': input['expectedLifecycleRevision'],
      'lifecycleRevision': lifecycleRevision,
      'archiveState': state,
    };

Object? _roundTrip(Object? value) => jsonDecode(jsonEncode(value));
