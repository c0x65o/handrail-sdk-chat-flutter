import 'dart:convert';
import 'dart:io';

import 'package:handrail_chat/src/generated/device_push_token.dart';
import 'package:test/test.dart';

void main() {
  late Map<String, Object?> fixtures;

  setUpAll(() async {
    fixtures = _object(
      jsonDecode(
        await File(
          'conformance-tests/device-push-token/fixtures.json',
        ).readAsString(),
      ),
    );
  });

  test('shared register, refresh, and unregister fixtures strictly round trip', () {
    for (final fixtureValue in fixtures['valid']! as List<Object?>) {
      final fixture = _object(fixtureValue);
      final inputJson = _object(fixture['input']);
      final input = DevicePushTokenInput.fromJson(
        _roundTrip(inputJson),
        currentTokenRevision: fixture['currentTokenRevision']! as int,
      );
      expect(input.toJson(), inputJson, reason: fixture['name']! as String);
      final resultJson = _object(fixture['result']);
      final result = DevicePushTokenResult.fromJson(
        _roundTrip(resultJson),
        expectedInput: input,
      );
      expect(result.toJson(), resultJson, reason: fixture['name']! as String);
    }
  });

  test('shared invalid coherence, revision, idempotency, identity, and exact keys are rejected', () {
    for (final fixtureValue in fixtures['invalidInputs']! as List<Object?>) {
      final fixture = _object(fixtureValue);
      expect(
        () => DevicePushTokenInput.fromJson(
          _roundTrip(fixture['input']),
          currentTokenRevision: fixture['currentTokenRevision'] as int?,
        ),
        throwsA(isA<DevicePushTokenFormatException>()),
        reason: fixture['name']! as String,
      );
    }

    final register = _object(
      _object((fixtures['valid']! as List<Object?>).first)['input'],
    );
    expect(
      () => DevicePushTokenInput.fromJson({
        ...register,
        'idempotencyKey': 'é' * maxDevicePushTokenIdempotencyKeyUtf8Bytes,
      }),
      throwsA(_code(DevicePushTokenParseErrorCode.invalidIdempotencyKey)),
    );
    expect(
      () => DevicePushTokenInput.fromJson({
        ...register,
        'nested': {
          'session': {'userId': 'spoofed'},
        },
      }),
      throwsA(_code(DevicePushTokenParseErrorCode.trustedIdentityField)),
    );
  });

  test('canonical server result is exact and coherent with the input', () {
    final fixture = _object((fixtures['valid']! as List<Object?>).first);
    final input = DevicePushTokenInput.fromJson(fixture['input']);
    final result = _object(fixture['result']);
    final state = _object(result['devicePushToken']);
    for (final invalid in <Map<String, Object?>>[
      {...result, 'idempotencyKey': 'other'},
      {...result, 'unexpected': true},
      {...result, 'devicePushToken': {...state, 'token': 'SECRET'}},
      {...result, 'devicePushToken': {...state, 'provider': 'fcm'}},
      {...result, 'devicePushToken': {...state, 'tokenRevision': 2}},
    ]) {
      expect(
        () => DevicePushTokenResult.fromJson(invalid, expectedInput: input),
        throwsA(isA<DevicePushTokenFormatException>()),
      );
    }
  });

  test('token-bearing diagnostic structures and strings redact recursively', () {
    final fixture = _object((fixtures['valid']! as List<Object?>).first);
    final input = DevicePushTokenInput.fromJson(fixture['input']);
    final tokenInput = input as RegisterDevicePushTokenInput;
    expect(tokenInput.token.toString(), devicePushTokenRedaction);
    expect(input.toString(), isNot(contains('SECRET_APNS_DEVICE_TOKEN')));
    expect(input.toDiagnosticSafeJson()['token'], devicePushTokenRedaction);

    final safe = _object(
      redactDevicePushTokenDiagnostics({
        'input': input.toJson(),
        'details': {
          'registrationToken': 'SECOND_SECRET',
          'safe': 'visible',
        },
      }),
    );
    final details = _object(safe['details']);
    expect(_object(safe['input'])['token'], devicePushTokenRedaction);
    expect(details['registrationToken'], devicePushTokenRedaction);
    expect(details['safe'], 'visible');
    final formatted = formatDevicePushTokenDiagnostic(safe);
    expect(formatted, isNot(contains('SECRET_APNS_DEVICE_TOKEN')));
    expect(formatted, isNot(contains('SECOND_SECRET')));
  });
}

Object? _roundTrip(Object? value) => jsonDecode(jsonEncode(value));

Map<String, Object?> _object(Object? value) =>
    (value! as Map).map((key, nested) => MapEntry(key! as String, nested));

Matcher _code(DevicePushTokenParseErrorCode code) =>
    isA<DevicePushTokenFormatException>().having(
      (error) => error.code,
      'code',
      code,
    );
