import 'dart:convert';

import 'package:handrail_chat/core.dart';
import 'package:test/test.dart';

import 'fixtures/conversation_preference_fixtures.dart';

void main() {
  test('all notification, starred, and explicit mute states round-trip immutably', () {
    final expectedNotifications = [
      ConversationNotificationPreference.all,
      ConversationNotificationPreference.mentions,
      ConversationNotificationPreference.none,
    ];
    for (var index = 0; index < conversationPreferenceInputs.length; index++) {
      final wire = conversationPreferenceInputs[index];
      final parsed = UpdateConversationPreferenceInput.fromJson(_roundTrip(wire));
      expect(parsed.toJson(), wire);
      expect(parsed.notificationPreference, expectedNotifications[index]);
      expect(parsed.isStarred, [false, true, false][index]);
      expect(parsed.mute, [
        isA<UnmutedConversationPreference>(),
        isA<IndefinitelyMutedConversationPreference>(),
        isA<MutedUntilConversationPreference>(),
      ][index]);

      final mutableJson = parsed.toJson();
      try {
        (mutableJson['mute']! as Map<String, Object?>)['muted'] = index != 0;
      } on UnsupportedError {
        // Const wire maps are an even stronger immutable boundary.
      }
      expect(parsed.toJson(), wire, reason: 'toJson must not expose mutable model state');
    }
  });

  test('every reconciliation status round-trips with status-specific rules', () {
    final cases = <({Map<String, Object?> input, Map<String, Object?> result})>[
      (
        input: allUnmutedPreferenceInput,
        result: settledPreferenceResult(allUnmutedPreferenceInput, 'applied'),
      ),
      (
        input: mentionsIndefinitePreferenceInput,
        result: settledPreferenceResult(mentionsIndefinitePreferenceInput, 'replayed'),
      ),
      (
        input: noneFinitePreferenceInput,
        result: settledPreferenceResult(noneFinitePreferenceInput, 'already_requested_state'),
      ),
      (
        input: noneFinitePreferenceInput,
        result: conflictingPreferenceResult(noneFinitePreferenceInput, 12),
      ),
    ];
    for (final fixture in cases) {
      final input = UpdateConversationPreferenceInput.fromJson(fixture.input);
      final parsed = UpdateConversationPreferenceResult.fromJson(
        _roundTrip(fixture.result),
        expectedInput: input,
      );
      expect(parsed.toJson(), fixture.result);
    }
  });

  test('rejects trusted aliases, toggles, unknown fields, and malformed preferences', () {
    for (final alias in [
      'tenant-id',
      'organization.id',
      'Actor_User_ID',
      'current user',
      'authentication',
      'authorization',
      'roles',
      'capabilities',
      'permissions',
    ]) {
      expect(
        () => UpdateConversationPreferenceInput.fromJson({
          ...allUnmutedPreferenceInput,
          alias: alias == 'roles' ? <String>['admin'] : 'spoofed',
        }),
        throwsA(isA<ConversationPreferenceFormatException>().having(
          (error) => error.code,
          'code',
          ConversationPreferenceParseErrorCode.trustedIdentityField,
        )),
      );
    }

    final missingStarred = Map<String, Object?>.of(allUnmutedPreferenceInput)
      ..remove('isStarred');
    expect(
      () => UpdateConversationPreferenceInput.fromJson(missingStarred),
      throwsA(isA<ConversationPreferenceFormatException>()),
    );

    for (final invalid in <Map<String, Object?>>[
      {...allUnmutedPreferenceInput, 'operation': 'toggle_conversation_preference'},
      {...allUnmutedPreferenceInput, 'toggleMute': true},
      {...allUnmutedPreferenceInput, 'toggleIsStarred': true},
      {...allUnmutedPreferenceInput, 'notificationPreference': 'important'},
      {...allUnmutedPreferenceInput, 'isStarred': 'true'},
      {...allUnmutedPreferenceInput, 'isStarred': 1},
      {...allUnmutedPreferenceInput, 'mute': <String, Object?>{}},
      {...allUnmutedPreferenceInput, 'mute': <String, Object?>{'muted': false, 'mutedUntil': preferenceUpdatedAt}},
      {...allUnmutedPreferenceInput, 'mute': <String, Object?>{'muted': true, 'mutedUntil': null}},
      {...allUnmutedPreferenceInput, 'mute': <String, Object?>{'muted': true, 'mutedUntil': '2030-02-30T04:05:06.000Z'}},
    ]) {
      expect(() => UpdateConversationPreferenceInput.fromJson(invalid), throwsA(isA<ConversationPreferenceFormatException>()));
    }
  });

  test('enforces revision, idempotency, timestamp, echo, and result coherence', () {
    for (final revision in [-1, 1.5, 9007199254740991, 9007199254740992]) {
      expect(
        () => UpdateConversationPreferenceInput.fromJson({...allUnmutedPreferenceInput, 'expectedPreferenceRevision': revision}),
        throwsA(isA<ConversationPreferenceFormatException>()),
      );
    }
    for (final key in ['', '   ', ' surrounded ', 'x' * 256]) {
      expect(
        () => UpdateConversationPreferenceInput.fromJson({...allUnmutedPreferenceInput, 'idempotencyKey': key}),
        throwsA(isA<ConversationPreferenceFormatException>()),
      );
    }

    final input = UpdateConversationPreferenceInput.fromJson(mentionsIndefinitePreferenceInput);
    final applied = settledPreferenceResult(mentionsIndefinitePreferenceInput, 'applied');
    for (final invalid in <Map<String, Object?>>[
      {...applied, 'conversationId': 'other'},
      {...applied, 'expectedPreferenceRevision': 3},
      {...applied, 'idempotencyKey': 'other'},
      {...applied, 'preferenceRevision': 4},
      {...applied, 'requestedPreference': {...desiredPreference(mentionsIndefinitePreferenceInput), 'notificationPreference': 'none'}},
      {...applied, 'requestedPreference': {...desiredPreference(mentionsIndefinitePreferenceInput), 'isStarred': false}},
      {...applied, 'preference': {...(applied['preference']! as Map<String, Object?>), 'notificationPreference': 'none'}},
      {...applied, 'preference': {...(applied['preference']! as Map<String, Object?>), 'isStarred': false}},
      {...applied, 'preference': {...(applied['preference']! as Map<String, Object?>), 'updatedAt': 'not-a-timestamp'}},
      {...applied, 'actorUserId': 'spoofed'},
      {...applied, 'reconciliationStatus': 'preference_revision_conflict', 'preferenceRevision': 4},
    ]) {
      expect(
        () => UpdateConversationPreferenceResult.fromJson(invalid, expectedInput: input),
        throwsA(isA<ConversationPreferenceFormatException>()),
      );
    }
  });
}

Object? _roundTrip(Object? value) => jsonDecode(jsonEncode(value));
