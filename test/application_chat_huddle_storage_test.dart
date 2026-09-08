import 'dart:convert';

import 'package:handrail_chat/core.dart';
import 'package:handrail_chat/testing.dart' show InMemoryApplicationChatStorage;
import 'package:test/test.dart';

void main() {
  group('queued huddle-command storage', () {
    test('round-trips every closed command and preserves correlation exactly',
        () {
      final intents = <ApplicationChatQueuedHuddleCommandIntent>[
        _intent(1, 'start_huddle', idempotencyKey: ' Start Key '),
        _intent(2, 'join_huddle', idempotencyKey: 'join/key'),
        _intent(3, 'leave_huddle', idempotencyKey: 'leave:key'),
        _intent(4, 'set', idempotencyKey: 'screen set'),
        _intent(5, 'clear', idempotencyKey: 'screen clear'),
        _intent(6, 'end_huddle', idempotencyKey: 'END-key'),
      ];

      for (final intent in intents) {
        final decoded = ApplicationChatQueuedHuddleCommandIntent.fromJson(
          jsonDecode(jsonEncode(intent.toJson())),
        );
        expect(decoded.toJson(), intent.toJson());
        expect(decoded.request.idempotencyKey, intent.request.idempotencyKey);
        expect(decoded.enqueueOrder, intent.enqueueOrder);
        expect(decoded.enqueuedAt, intent.enqueuedAt);
      }
    });

    test('validates bounded FIFO order and enqueue timestamps', () {
      expect(
        () => _intent(0, 'start_huddle'),
        throwsArgumentError,
      );
      expect(
        () => _intent(9007199254740992, 'start_huddle'),
        throwsArgumentError,
      );
      expect(
        () => _intent(
          1,
          'start_huddle',
          enqueuedAt: 'not-a-timestamp',
        ),
        throwsArgumentError,
      );
      expect(
        () => _intent(
          1,
          'start_huddle',
          enqueuedAt: '${'2' * 65}Z',
        ),
        throwsArgumentError,
      );

      final invalidOrder = _intent(1, 'start_huddle').toJson()
        ..['enqueueOrder'] = 0;
      final invalidTimestamp = _intent(1, 'start_huddle').toJson()
        ..['enqueuedAt'] = '2026-02-30T12:00:00Z';
      expect(
        () => ApplicationChatQueuedHuddleCommandIntent.fromJson(invalidOrder),
        throwsFormatException,
      );
      expect(
        () => ApplicationChatQueuedHuddleCommandIntent.fromJson(
          invalidTimestamp,
        ),
        throwsFormatException,
      );
    });

    test('enforces count, per-intent, and total-record byte limits', () {
      final atCapacity = List.generate(
        maxApplicationChatQueuedHuddleCommandIntents,
        (index) => _intent(
          index + 1,
          'start_huddle',
          conversationId: 'conversation-${index + 1}',
          idempotencyKey: 'key-${index + 1}',
        ),
      );
      expect(
        ApplicationChatQueuedHuddleCommandIntentsRecord(
          identity: _identity(),
          intents: atCapacity,
        ).intents,
        hasLength(maxApplicationChatQueuedHuddleCommandIntents),
      );
      expect(
        () => ApplicationChatQueuedHuddleCommandIntentsRecord(
          identity: _identity(),
          intents: [
            ...atCapacity,
            _intent(
              maxApplicationChatQueuedHuddleCommandIntents + 1,
              'start_huddle',
              conversationId: 'over-capacity',
              idempotencyKey: 'over-capacity',
            ),
          ],
        ),
        throwsArgumentError,
      );

      final oversizedIntent = _intent(1, 'start_huddle').toJson()
        ..['padding'] = 'x' * maxApplicationChatQueuedHuddleCommandIntentBytes;
      expect(
        () => ApplicationChatQueuedHuddleCommandIntent.fromJson(
          oversizedIntent,
        ),
        throwsA(
          isA<FormatException>().having(
            (error) => error.message,
            'message',
            contains('exceeds 1024 encoded bytes'),
          ),
        ),
      );

      final maximumId = 'c${'x' * (maxHuddleIdentifierUtf8Bytes - 1)}';
      final maximumSession = 's${'x' * (maxHuddleIdentifierUtf8Bytes - 1)}';
      final maximumKey = 'k${'x' * (maxHuddleIdempotencyKeyUtf8Bytes - 1)}';
      final largeIntents = List.generate(
        400,
        (index) => _intent(
          index + 1,
          'join_huddle',
          conversationId: '$index$maximumId'.substring(
            0,
            maxHuddleIdentifierUtf8Bytes,
          ),
          huddleSessionId: '$index$maximumSession'.substring(
            0,
            maxHuddleIdentifierUtf8Bytes,
          ),
          idempotencyKey: '$index$maximumKey'.substring(
            0,
            maxHuddleIdempotencyKeyUtf8Bytes,
          ),
        ),
      );
      expect(
        () => ApplicationChatQueuedHuddleCommandIntentsRecord(
          identity: _identity(),
          intents: largeIntents,
        ),
        throwsA(
          isA<ArgumentError>().having(
            (error) => error.message,
            'message',
            contains('exceeds 262144 encoded bytes'),
          ),
        ),
      );
    });

    test('coalesces only compatible latest desired session work', () {
      final record = ApplicationChatQueuedHuddleCommandIntentsRecord(
        identity: _identity(),
        intents: [
          _intent(1, 'join_huddle', idempotencyKey: 'join'),
          _intent(2, 'set', idempotencyKey: 'set'),
          _intent(3, 'leave_huddle', idempotencyKey: 'leave'),
          _intent(4, 'clear', idempotencyKey: 'clear'),
        ],
      );

      expect(record.intents, hasLength(2));
      expect(record.intents[0].request, isA<LeaveHuddleInput>());
      expect(record.intents[0].request.idempotencyKey, 'leave');
      expect(record.intents[0].enqueueOrder, 1);
      expect(
        record.intents[0].enqueuedAt,
        const IsoTimestamp('2026-09-04T12:00:00.001Z'),
      );
      expect(
        (record.intents[1].request as SetHuddleScreenShareInput).intent,
        HuddleScreenShareIntent.clear,
      );
      expect(record.intents[1].request.idempotencyKey, 'clear');
      expect(record.intents[1].enqueueOrder, 2);
    });

    test('rejects duplicate, incompatible, and conflicting correlations', () {
      void rejects(List<ApplicationChatQueuedHuddleCommandIntent> intents) {
        expect(
          () => ApplicationChatQueuedHuddleCommandIntentsRecord(
            identity: _identity(),
            intents: intents,
          ),
          throwsArgumentError,
        );
      }

      rejects([
        _intent(1, 'join_huddle', idempotencyKey: 'duplicate'),
        _intent(
          2,
          'set',
          conversationId: 'conversation-2',
          huddleSessionId: 'session-2',
          idempotencyKey: 'duplicate',
        ),
      ]);
      rejects([
        _intent(1, 'join_huddle'),
        _intent(
          2,
          'leave_huddle',
          conversationId: 'conversation-2',
        ),
      ]);
      rejects([
        _intent(1, 'join_huddle'),
        _intent(2, 'set', huddleSessionId: 'session-2'),
      ]);
      rejects([
        _intent(1, 'start_huddle'),
        _intent(2, 'join_huddle'),
      ]);
      rejects([
        _intent(1, 'join_huddle'),
        _intent(2, 'end_huddle'),
      ]);
      rejects([
        _intent(1, 'end_huddle'),
        _intent(2, 'end_huddle', idempotencyKey: 'second-end'),
      ]);
      rejects([
        _intent(1, 'start_huddle'),
        _intent(2, 'start_huddle', idempotencyKey: 'second-start'),
      ]);
    });

    test('storage isolates identities and quarantines only the corrupt kind',
        () async {
      final storage = InMemoryApplicationChatStorage();
      final identity = _identity();
      final otherTenant = _identity(tenant: 'tenant-2');
      final otherUser = _identity(user: 'user-2');
      final otherDevice = _identity(device: 'device-2');
      for (final scopedIdentity in [
        identity,
        otherTenant,
        otherUser,
        otherDevice,
      ]) {
        await storage.replace(
          ApplicationChatQueuedHuddleCommandIntentsRecord(
            identity: scopedIdentity,
            intents: [_intent(1, 'start_huddle')],
          ),
        );
      }
      await storage.replace(
        ApplicationChatRealtimeCursorRecord(
          identity: identity,
          cursor: const EventCursor(eventId: 'sibling'),
        ),
      );

      final corrupt = ApplicationChatQueuedHuddleCommandIntentsRecord(
        identity: identity,
        intents: [_intent(1, 'start_huddle')],
      ).toJson();
      _wireIntents(corrupt).single['idempotencyKey'] = ' ';
      storage.putRawRecordForTesting(
        identity,
        ApplicationChatStorageRecordKind.queuedHuddleCommandIntents,
        corrupt,
      );
      await expectLater(
        storage.read(
          identity,
          ApplicationChatStorageRecordKind.queuedHuddleCommandIntents,
        ),
        throwsFormatException,
      );

      await storage.remove(
        identity,
        ApplicationChatStorageRecordKind.queuedHuddleCommandIntents,
      );
      expect(
        await storage.read(
          identity,
          ApplicationChatStorageRecordKind.queuedHuddleCommandIntents,
        ),
        isNull,
      );
      expect(
        await storage.read(
          identity,
          ApplicationChatStorageRecordKind.realtimeCursor,
        ),
        isNotNull,
      );
      for (final scopedIdentity in [otherTenant, otherUser, otherDevice]) {
        expect(
          await storage.read(
            scopedIdentity,
            ApplicationChatStorageRecordKind.queuedHuddleCommandIntents,
          ),
          isNotNull,
        );
      }
    });

    test('returns immutable detached intents and storage values', () async {
      final source = [_intent(1, 'start_huddle')];
      final record = ApplicationChatQueuedHuddleCommandIntentsRecord(
        identity: _identity(),
        intents: source,
      );
      source.clear();
      expect(record.intents, hasLength(1));
      expect(
        () => record.intents.add(_intent(2, 'start_huddle')),
        throwsUnsupportedError,
      );

      final json = record.toJson();
      _wireIntents(json).single['idempotencyKey'] = 'tampered';
      expect(record.intents.single.request.idempotencyKey, 'key-1');

      final storage = InMemoryApplicationChatStorage();
      await storage.replace(record);
      final first = await storage.read(
        _identity(),
        ApplicationChatStorageRecordKind.queuedHuddleCommandIntents,
      ) as ApplicationChatQueuedHuddleCommandIntentsRecord;
      first.toJson()['kind'] = 'tampered';
      final second = await storage.read(
        _identity(),
        ApplicationChatStorageRecordKind.queuedHuddleCommandIntents,
      ) as ApplicationChatQueuedHuddleCommandIntentsRecord;
      expect(second.toJson(), record.toJson());
      expect(identical(first, second), isFalse);
      expect(identical(second.intents.single, record.intents.single), isFalse);
    });

    test('structurally rejects media, secret, provider, and transport data',
        () {
      final forbiddenFields = <String, Object?>{
        'mediaJoin': {
          'kind': 'opaque_media_join',
          'descriptor': 'opaque',
          'expiresAt': '2026-09-04T12:05:00.000Z',
        },
        'accessToken': 'secret',
        'providerToken': 'secret',
        'url': 'https://media.example.test',
        'headers': {'authorization': 'secret'},
        'socket': {'id': 'socket-1'},
        'diagnostics': {'raw': 'private'},
        'result': {'outcome': 'ok'},
      };
      for (final entry in forbiddenFields.entries) {
        final wire = _intent(1, 'start_huddle').toJson()
          ..[entry.key] = entry.value;
        expect(
          () => ApplicationChatQueuedHuddleCommandIntent.fromJson(wire),
          throwsFormatException,
          reason: entry.key,
        );
      }
      final urlValue = _intent(1, 'start_huddle').toJson()
        ..['idempotencyKey'] = 'wss://socket.example.test/huddle';
      expect(
        () => ApplicationChatQueuedHuddleCommandIntent.fromJson(urlValue),
        throwsFormatException,
      );
    });
  });
}

ApplicationChatQueuedHuddleCommandIntent _intent(
  int order,
  String command, {
  String conversationId = 'conversation-1',
  String huddleSessionId = 'session-1',
  String? idempotencyKey,
  String? enqueuedAt,
}) {
  final key = idempotencyKey ?? 'key-$order';
  final request = switch (command) {
    'start_huddle' => StartHuddleInput(
        conversationId: ConversationId(conversationId),
        idempotencyKey: key,
      ),
    'join_huddle' => JoinHuddleInput(
        huddleSessionId: HuddleSessionId(huddleSessionId),
        idempotencyKey: key,
      ),
    'leave_huddle' => LeaveHuddleInput(
        huddleSessionId: HuddleSessionId(huddleSessionId),
        idempotencyKey: key,
      ),
    'set' => SetHuddleScreenShareInput(
        huddleSessionId: HuddleSessionId(huddleSessionId),
        intent: HuddleScreenShareIntent.set,
        idempotencyKey: key,
      ),
    'clear' => SetHuddleScreenShareInput(
        huddleSessionId: HuddleSessionId(huddleSessionId),
        intent: HuddleScreenShareIntent.clear,
        idempotencyKey: key,
      ),
    'end_huddle' => EndHuddleInput(
        huddleSessionId: HuddleSessionId(huddleSessionId),
        idempotencyKey: key,
      ),
    _ => throw ArgumentError.value(command, 'command'),
  };
  return ApplicationChatQueuedHuddleCommandIntent(
    request: request,
    conversationId: ConversationId(conversationId),
    enqueueOrder: order,
    enqueuedAt: IsoTimestamp(
      enqueuedAt ?? '2026-09-04T12:00:00.${order.toString().padLeft(3, '0')}Z',
    ),
  );
}

ApplicationChatStorageIdentity _identity({
  String tenant = 'tenant-1',
  String user = 'user-1',
  String device = 'device-1',
}) =>
    ApplicationChatStorageIdentity(
      tenantId: TenantId(tenant),
      userId: UserId(user),
      deviceId: DeviceId(device),
    );

List<Map<String, Object?>> _wireIntents(Map<String, Object?> record) =>
    ((record['payload']! as Map<String, Object?>)['intents']! as List<Object?>)
        .cast<Map<String, Object?>>();
