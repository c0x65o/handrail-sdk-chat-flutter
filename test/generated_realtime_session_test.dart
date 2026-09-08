import 'dart:convert';

import 'package:handrail_chat/core.dart';
import 'package:test/test.dart';

void main() {
  test('exports every exact realtime session wire constant', () {
    expect(chatRealtimeSubprotocol, 'handrail-chat.v1');
    expect(chatRealtimeBearerSubprotocolPrefix, 'handrail-chat.bearer.');
    expect(chatRefreshRequiredMessage, 'Chat was updated; refresh to continue.');
    expect(chatRealtimeSessionMessageTypes, {
      'accepted': 'chat.session.accepted',
      'refreshRequired': 'chat.session.refresh_required',
      'snapshotRequired': 'chat.session.snapshot_required',
    });
    expect(chatRealtimeSessionStates, {
      'accepted': 'accepted',
      'refreshRequired': 'refresh_required',
      'snapshotRequired': 'snapshot_required',
    });
    expect(chatRealtimeSubscriptionMessageTypes, {
      'subscribe': 'chat.subscribe',
      'unsubscribe': 'chat.unsubscribe',
      'subscribed': 'chat.subscription.accepted',
      'unsubscribed': 'chat.subscription.removed',
      'rejected': 'chat.subscription.rejected',
      'revoked': 'chat.subscription.revoked',
    });
    expect(chatRealtimeSubscriptionErrorCodes, {
      'malformedRequest': 'malformed_request',
      'identitySpoofing': 'identity_spoofing',
      'invalidStream': 'invalid_stream',
      'accessDenied': 'access_denied',
      'accessRevoked': 'access_revoked',
    });
    expect(chatRealtimeSnapshotRequiredReasons, [
      'replay_expired',
      'replay_unavailable',
      'replay_incompatible',
      'replay_overflow',
    ]);
    expect(chatRealtimeReplayCursorStatuses, [
      'available',
      'expired',
      'unavailable',
      'incompatible',
      'overflow',
    ]);
    expect(
      SnapshotRequiredReason.values.map((value) => value.toJson()),
      chatRealtimeSnapshotRequiredReasons,
    );
    expect(
      ReplayCursorStatus.values.map((value) => value.toJson()),
      chatRealtimeReplayCursorStatuses,
    );
    expect(
      ChatRealtimeSubscriptionErrorCode.values
          .map((value) => value.toJson()),
      chatRealtimeSubscriptionErrorCodes.values,
    );
  });

  test('round-trips ClientHandshakeInput and EventCursor', () {
    final wire = <String, Object?>{
      'clientPackageVersion': '0.1.3',
      'protocolVersion': 4,
      'resumeFrom': <String, Object?>{'eventId': 'event-1'},
    };
    final handshake = ClientHandshakeInput.fromJson(_roundTrip(wire));
    expect(handshake.clientPackageVersion, '0.1.3');
    expect(handshake.protocolVersion, 4);
    expect(handshake.resumeFrom?.eventId, 'event-1');
    expect(handshake.toJson(), wire);
    expect(
      EventCursor.fromJson(handshake.resumeFrom?.toJson()).toJson(),
      {'eventId': 'event-1'},
    );
  });

  test('parses and round-trips every control variant', () {
    final controls = <Map<String, Object?>>[
      {
        'type': 'chat.session.accepted',
        'metadata': _metadata,
        'tenantId': 'tenant-1',
        'actorStreamId': 'user:user-1',
        'deviceId': 'device-1',
        'sessionId': 'session-1',
        'resumeFrom': {'eventId': 'event-1'},
      },
      {
        'type': 'chat.session.refresh_required',
        'state': 'refresh_required',
        'reason': 'unsupported_protocol',
        'message': chatRefreshRequiredMessage,
        'requestedProtocolVersion': 5,
        'metadata': _metadata,
      },
      {
        'type': 'chat.session.snapshot_required',
        'state': 'snapshot_required',
        'reason': 'replay_overflow',
        'metadata': _metadata,
        'resumeFrom': {'eventId': 'event-1'},
      },
    ];

    final parsed = controls
        .map((wire) => ChatRealtimeControlMessage.fromJson(_roundTrip(wire)))
        .toList();
    expect(parsed[0], isA<ChatRealtimeSessionAcceptedMessage>());
    expect(parsed[1], isA<ChatRealtimeRefreshRequiredMessage>());
    expect(parsed[2], isA<ChatRealtimeSnapshotRequiredMessage>());
    for (var index = 0; index < controls.length; index += 1) {
      expect(parsed[index].toJson(), controls[index]);
    }
  });

  test('parses every subscription request and server variant', () {
    final requests = <Map<String, Object?>>[
      {
        'type': 'chat.subscribe',
        'requestId': 'request-1',
        'streamId': 'conversation-1',
      },
      {
        'type': 'chat.unsubscribe',
        'requestId': 'request-2',
        'streamId': 'conversation-1',
      },
    ];
    expect(
      ChatRealtimeSubscriptionRequest.fromJson(requests[0]),
      isA<ChatRealtimeSubscribeRequest>(),
    );
    expect(
      ChatRealtimeSubscriptionRequest.fromJson(requests[1]),
      isA<ChatRealtimeUnsubscribeRequest>(),
    );
    for (final request in requests) {
      expect(
        ChatRealtimeSubscriptionRequest.fromJson(request).toJson(),
        request,
      );
    }

    final messages = <Map<String, Object?>>[
      {
        'type': 'chat.subscription.accepted',
        'requestId': 'request-1',
        'streamId': 'conversation-1',
      },
      {
        'type': 'chat.subscription.removed',
        'requestId': 'request-2',
        'streamId': 'conversation-1',
      },
      {
        'type': 'chat.subscription.rejected',
        'code': 'malformed_request',
      },
      {
        'type': 'chat.subscription.rejected',
        'code': 'identity_spoofing',
        'requestId': 'request-3',
      },
      {
        'type': 'chat.subscription.rejected',
        'code': 'invalid_stream',
        'requestId': 'request-4',
      },
      {
        'type': 'chat.subscription.rejected',
        'code': 'access_denied',
        'requestId': 'request-5',
      },
      {
        'type': 'chat.subscription.revoked',
        'code': 'access_revoked',
        'streamId': 'conversation-1',
      },
    ];
    final parsed = messages
        .map(ChatRealtimeSubscriptionServerMessage.fromJson)
        .toList();
    expect(parsed[0], isA<ChatRealtimeSubscriptionAcceptedMessage>());
    expect(parsed[1], isA<ChatRealtimeSubscriptionRemovedMessage>());
    expect(parsed[2], isA<ChatRealtimeSubscriptionRejectedMessage>());
    expect(parsed.last, isA<ChatRealtimeSubscriptionRevokedMessage>());
    for (var index = 0; index < messages.length; index += 1) {
      expect(parsed[index].toJson(), messages[index]);
    }
  });

  test('round-trips an opaque event and freezes nested payload data', () {
    final wire = <String, Object?>{
      'eventId': 'event-2',
      'protocolVersion': 4,
      'tenantId': 'tenant-1',
      'streamId': 'conversation-1',
      'type': 'feature.owned',
      'occurredAt': '2026-08-26T12:00:00.000Z',
      'payload': <String, Object?>{
        'opaque': true,
        'nested': <Object?>['value'],
      },
    };
    final event = ChatEvent.fromJson(
      _roundTrip(wire),
      trustedTenantId: const TenantId('tenant-1'),
    );
    expect(event.toJson(), wire);
    final payload = event.payload! as Map<String, Object?>;
    expect(() => payload['opaque'] = false, throwsUnsupportedError);
    expect(
      () => (payload['nested']! as List<Object?>).add('other'),
      throwsUnsupportedError,
    );
    final serialized = event.toJson();
    (serialized['payload']! as Map<String, Object?>)['opaque'] = false;
    expect((event.payload! as Map<String, Object?>)['opaque'], isTrue);
  });

  test('rejects malformed scalar, object, and discriminator frames', () {
    final malformed = <void Function()>[
      () => ClientHandshakeInput.fromJson('handshake'),
      () => ClientHandshakeInput.fromJson({
            'clientPackageVersion': '0.1.3',
            'protocolVersion': '4',
          }),
      () => EventCursor.fromJson({'eventId': 1}),
      () => ChatRealtimeControlMessage.fromJson({'type': 'chat.unknown'}),
      () => ChatRealtimeControlMessage.fromJson({
            'type': 'chat.session.accepted',
            'metadata': _metadata,
            'tenantId': 'tenant-1',
            'actorStreamId': 'conversation-1',
            'deviceId': 'device-1',
            'sessionId': 'session-1',
          }),
      () => ChatRealtimeSubscriptionRequest.fromJson([]),
      () => ChatRealtimeSubscriptionRequest.fromJson({
            'type': 'chat.subscribe',
            'requestId': null,
            'streamId': 'conversation-1',
          }),
      () => ChatRealtimeSubscriptionServerMessage.fromJson({
            'type': 'chat.subscription.rejected',
            'code': 'access_revoked',
          }),
      () => ChatRealtimeSubscriptionServerMessage.fromJson({
            'type': 'chat.subscription.revoked',
            'code': 'access_denied',
            'streamId': 'conversation-1',
          }),
      () => ChatEvent.fromJson(
            {'eventId': 'event-1'},
            trustedTenantId: const TenantId('tenant-1'),
          ),
    ];
    for (final parse in malformed) {
      expect(parse, throwsFormatException);
    }
  });

  test('rejects generic events outside the trusted tenant', () {
    expect(
      () => ChatEvent.fromJson(
        {
          'eventId': 'event-2',
          'protocolVersion': 4,
          'tenantId': 'tenant-other',
          'streamId': 'conversation-1',
          'type': 'feature.owned',
          'occurredAt': '2026-08-26T12:00:00.000Z',
          'payload': {'opaque': true},
        },
        trustedTenantId: const TenantId('tenant-1'),
      ),
      throwsA(
        isA<ChatEventParseException>().having(
          (error) => error.code,
          'code',
          ChatEventParseErrorCode.tenantMismatch,
        ),
      ),
    );
  });
}

const Map<String, Object?> _metadata = {
  'packageVersion': '0.1.3',
  'protocolVersion': 4,
  'schemaVersion': 1,
  'enabledFeatures': <String, Object?>{'realtime': true},
  'supportedProtocolRange': <String, Object?>{
    'minimumVersion': 3,
    'maximumVersion': 4,
  },
};

Object? _roundTrip(Object? value) => jsonDecode(jsonEncode(value));
