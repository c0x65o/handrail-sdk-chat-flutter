import 'dart:convert';

import 'package:handrail_chat/core.dart';
import 'package:test/test.dart';

import 'fixtures/ephemeral_signal_fixtures.dart';

void main() {
  final options = EphemeralSignalParseOptions(
    expectedTenantId: const TenantId('tenant-1'),
    enabledFeatures: const {'typing': true, 'presence': true},
    now: DateTime.parse('2026-08-25T20:00:01.000Z'),
  );

  test('parses and round-trips typing start/stop in private and public scopes',
      () {
    for (final state in ['start', 'stop']) {
      for (final scope in [
        ('private', 'members'),
        ('public', 'active_participants'),
      ]) {
        final wire = typingSignalFixture(
          state: state,
          visibility: scope.$1,
          audience: scope.$2,
        );
        final event =
            EphemeralSignalEvent.fromJson(_roundTrip(wire), options: options);
        expect(event, isA<TypingSignalEvent>());
        expect((event as TypingSignalEvent).payload.state.toJson(), state);
        expect(event.payload.sequence, 1);
        expect(event.toJson(), wire);
      }
    }
  });

  test('parses and round-trips all presence states on a private user stream',
      () {
    for (final state in ['online', 'away', 'offline']) {
      final wire = presenceSignalFixture(state: state);
      final event =
          EphemeralSignalEvent.fromJson(_roundTrip(wire), options: options);
      expect(event, isA<PresenceSignalEvent>());
      expect((event as PresenceSignalEvent).payload.state.toJson(), state);
      expect(event.toJson(), wire);
    }
  });

  test('rejects expired, zero/negative, and over-maximum TTLs', () {
    final expired = typingSignalFixture();
    final expiredPayload = expired['payload']! as Map<String, Object?>;
    expiredPayload['expiresAt'] = '2026-08-25T20:00:01.000Z';

    final zero = typingSignalFixture();
    (zero['payload']! as Map<String, Object?>)['expiresAt'] =
        '2026-08-25T20:00:00.000Z';
    final negative = typingSignalFixture();
    (negative['payload']! as Map<String, Object?>)['expiresAt'] =
        '2026-08-25T19:59:59.999Z';
    final overTyping = typingSignalFixture();
    (overTyping['payload']! as Map<String, Object?>)['expiresAt'] =
        '2026-08-25T20:00:15.001Z';
    final overPresence = presenceSignalFixture();
    (overPresence['payload']! as Map<String, Object?>)['expiresAt'] =
        '2026-08-25T20:02:00.001Z';

    for (final wire in [expired, zero, negative, overTyping, overPresence]) {
      expect(
        () => EphemeralSignalEvent.fromJson(wire, options: options),
        throwsFormatException,
      );
    }
  });

  test('rejects invalid sequences and mismatched accepted-session provenance',
      () {
    for (final sequence in [0, -1, maxEphemeralSignalSequence + 1]) {
      expect(
        () => EphemeralSignalEvent.fromJson(
          typingSignalFixture(sequence: sequence),
          options: options,
        ),
        throwsFormatException,
      );
    }
    final trusted = EphemeralSignalParseOptions(
      expectedTenantId: const TenantId('tenant-1'),
      enabledFeatures: const {'typing': true, 'presence': true},
      now: options.now,
      trustedAcceptedSessionIdentity:
          const EphemeralSignalAcceptedSessionIdentity(
        actorUserId: UserId('user-other'),
        deviceId: DeviceId('device-browser'),
        sessionId: SessionId('session-tab-1'),
      ),
    );
    expect(
      () => EphemeralSignalEvent.fromJson(typingSignalFixture(),
          options: trusted),
      throwsFormatException,
    );
  });

  test('rejects disabled features, tenant mismatch, and unknown fields', () {
    final disabled = EphemeralSignalParseOptions(
      expectedTenantId: const TenantId('tenant-1'),
      enabledFeatures: const {'typing': false, 'presence': true},
      now: options.now,
    );
    expect(
      () => EphemeralSignalEvent.fromJson(typingSignalFixture(),
          options: disabled),
      throwsFormatException,
    );
    expect(
      () => EphemeralSignalEvent.fromJson(
        {...presenceSignalFixture(), 'tenantId': 'tenant-other'},
        options: options,
      ),
      throwsFormatException,
    );
    expect(
      () => EphemeralSignalEvent.fromJson(
        {...typingSignalFixture(), 'unknown': true},
        options: options,
      ),
      throwsFormatException,
    );
  });

  test('rejects stream/scope mismatch and invalid private/public scope rules',
      () {
    final wrongTypingStream = {
      ...typingSignalFixture(),
      'streamId': 'conversation-other'
    };
    final unrestrictedPublic = typingSignalFixture(
      visibility: 'public',
      audience: 'members',
    );
    final invalidPrivate = typingSignalFixture(
      visibility: 'private',
      audience: 'active_participants',
    );
    final wrongPresenceStream = {
      ...presenceSignalFixture(),
      'streamId': 'conversation-9'
    };
    final conversationPresence = presenceSignalFixture();
    (conversationPresence['payload']! as Map<String, Object?>)['scope'] = {
      'type': 'conversation',
      'conversationId': 'conversation-9',
    };
    for (final wire in [
      wrongTypingStream,
      unrestrictedPublic,
      invalidPrivate,
      wrongPresenceStream,
      conversationPresence,
    ]) {
      expect(
        () => EphemeralSignalEvent.fromJson(wire, options: options),
        throwsFormatException,
      );
    }
  });
}

Object? _roundTrip(Object? value) => jsonDecode(jsonEncode(value));
