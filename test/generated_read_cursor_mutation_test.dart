import 'dart:convert';

import 'package:handrail_chat/core.dart';
import 'package:test/test.dart';

void main() {
  test('mark-read and mark-unread inputs round-trip and enforce local bounds',
      () {
    final markRead = ReadCursorMutationInput.fromJson(_roundTrip(_markRead));
    final markUnread =
        ReadCursorMutationInput.fromJson(_roundTrip(_markUnread));
    expect(markRead, isA<MarkReadInput>());
    expect(markUnread, isA<MarkUnreadInput>());
    expect(markRead.toJson(), _markRead);
    expect(markUnread.toJson(), _markUnread);

    markRead.validateAgainst(
        currentReadState: _currentState,
        latestSequence: const MessageSequence(6));
    markUnread.validateAgainst(
        currentReadState: _currentState,
        latestSequence: const MessageSequence(6));

    for (final input in <Map<String, Object?>>[
      {..._markRead, 'throughSequence': 3},
      {..._markRead, 'throughSequence': 7},
      {..._markUnread, 'fromSequence': 5},
    ]) {
      final parsed = ReadCursorMutationInput.fromJson(input);
      expect(
          () => parsed.validateAgainst(
              currentReadState: _currentState,
              latestSequence: const MessageSequence(6)),
          throwsA(isA<ReadCursorMutationFormatException>()));
    }
  });

  test('parses applied and replayed outcomes into the same canonical state',
      () {
    final input = ReadCursorMutationInput.fromJson(_markRead);
    final applied = ReadCursorMutationResult.fromJson(_readResult('applied'),
        expectedInput: input);
    final replayed = ReadCursorMutationResult.fromJson(_readResult('replayed'),
        expectedInput: input);
    expect(
        applied.reconciliationStatus, ReadCursorReconciliationStatus.applied);
    expect(
        replayed.reconciliationStatus, ReadCursorReconciliationStatus.replayed);
    expect({...replayed.toJson(), 'reconciliationStatus': 'applied'},
        applied.toJson());
  });

  test('parses mark-unread outcomes and the private durable event', () {
    final input = ReadCursorMutationInput.fromJson(_markUnread);
    final result = ReadCursorMutationResult.fromJson(_unreadResult('applied'),
        expectedInput: input);
    expect(result.readState.lastReadSequence, const MessageSequence(4));
    expect(result.readState.manualUnreadFromSequence, const MessageSequence(3));
    expect(result.unreadCount, 4);

    final event = ReadCursorUpdatedEvent.fromJson(_roundTrip(_event),
        expectedTenantId: const TenantId('tenant-1'));
    expect(event.type, readCursorUpdatedEventType);
    expect(event.streamId, 'user:user-1');
    expect(event.payload.operation, ReadCursorMutationOperation.markUnread);
    expect(event.toJson(), _event);
  });

  test('rejects malformed inputs and caller-authored trusted identity', () {
    for (final invalid in <Map<String, Object?>>[
      {..._markRead, 'idempotencyKey': ' '},
      {..._markRead, 'idempotencyKey': List.filled(64, '🙂').join()},
      {..._markRead, 'throughSequence': -1},
      {..._markUnread, 'fromSequence': 0},
      {..._markRead, 'extra': true},
    ]) {
      expect(() => ReadCursorMutationInput.fromJson(invalid),
          throwsA(isA<ReadCursorMutationFormatException>()));
    }
    for (final alias in [
      'tenant-id',
      'Actor_User_ID',
      'session',
      'authorization',
      'roles'
    ]) {
      expect(
          () => ReadCursorMutationInput.fromJson({
                ..._markRead,
                alias: alias == 'roles' ? <String>['admin'] : 'spoofed',
              }),
          throwsA(isA<ReadCursorMutationFormatException>().having(
            (error) => error.code,
            'code',
            ReadCursorMutationErrorCode.trustedIdentityField,
          )));
    }
  });

  test('rejects incoherent or non-exact mutation results', () {
    final readInput = ReadCursorMutationInput.fromJson(_markRead);
    final unreadInput = ReadCursorMutationInput.fromJson(_markUnread);
    final invalid =
        <({ReadCursorMutationInput input, Map<String, Object?> value})>[
      (input: readInput, value: {..._readResult('applied'), 'unreadCount': 2}),
      (
        input: readInput,
        value: {..._readResult('applied'), 'reconciliationStatus': 'cached'}
      ),
      (
        input: readInput,
        value: {..._readResult('applied'), 'idempotencyKey': 'different'}
      ),
      (input: readInput, value: {..._readResult('applied'), 'extra': true}),
      (
        input: unreadInput,
        value: {
          ..._unreadResult('applied'),
          'readState': {..._unreadState, 'manualUnreadFromSequence': 2}
        }
      ),
    ];
    for (final fixture in invalid) {
      expect(
          () => ReadCursorMutationResult.fromJson(fixture.value,
              expectedInput: fixture.input),
          throwsA(isA<ReadCursorMutationFormatException>()));
    }
  });

  test('rejects malformed private streams and invalid event payloads', () {
    for (final invalid in <Map<String, Object?>>[
      {..._event, 'streamId': 'conversation:conversation-1'},
      {..._event, 'tenantId': 'tenant-other'},
      {..._event, 'type': 'message.updated'},
      {
        ..._event,
        'payload': {..._eventPayload, 'actorUserId': 'user-other'}
      },
      {
        ..._event,
        'payload': {..._eventPayload, 'reconciliationStatus': 'applied'}
      },
      {
        ..._event,
        'payload': {..._eventPayload, 'unreadCount': 2}
      },
    ]) {
      expect(
          () => ReadCursorUpdatedEvent.fromJson(invalid,
              expectedTenantId: const TenantId('tenant-1')),
          throwsA(isA<ReadCursorMutationFormatException>()));
    }
  });
}

final _currentState = ConversationReadState(
  conversationId: const ConversationId('conversation-1'),
  userId: const UserId('user-1'),
  lastReadSequence: const MessageSequence(4),
  manualUnreadFromSequence: const MessageSequence(2),
  updatedAt: const IsoTimestamp('2026-08-25T20:00:00.000Z'),
);

const _markRead = <String, Object?>{
  'operation': 'mark_read',
  'conversationId': 'conversation-1',
  'throughSequence': 5,
  'idempotencyKey': 'read-1',
};
const _markUnread = <String, Object?>{
  'operation': 'mark_unread',
  'conversationId': 'conversation-1',
  'fromSequence': 3,
  'idempotencyKey': 'unread-1',
};
const _readState = <String, Object?>{
  'conversationId': 'conversation-1',
  'userId': 'user-1',
  'lastReadSequence': 5,
  'updatedAt': '2026-08-25T20:01:00.000Z',
};
const _unreadState = <String, Object?>{
  'conversationId': 'conversation-1',
  'userId': 'user-1',
  'lastReadSequence': 4,
  'manualUnreadFromSequence': 3,
  'updatedAt': '2026-08-25T20:01:00.000Z',
};

Map<String, Object?> _readResult(String status) => {
      'operation': 'mark_read',
      'reconciliationStatus': status,
      'idempotencyKey': 'read-1',
      'conversationId': 'conversation-1',
      'readState': _readState,
      'latestSequence': 6,
      'unreadCount': 1,
    };
Map<String, Object?> _unreadResult(String status) => {
      'operation': 'mark_unread',
      'reconciliationStatus': status,
      'idempotencyKey': 'unread-1',
      'conversationId': 'conversation-1',
      'readState': _unreadState,
      'latestSequence': 6,
      'unreadCount': 4,
    };
const _eventPayload = <String, Object?>{
  'kind': 'conversation_read_cursor',
  'actorUserId': 'user-1',
  'operation': 'mark_unread',
  'conversationId': 'conversation-1',
  'readState': _unreadState,
  'latestSequence': 6,
  'unreadCount': 4,
};
const _event = <String, Object?>{
  'eventId': 'event-1',
  'protocolVersion': 4,
  'tenantId': 'tenant-1',
  'streamId': 'user:user-1',
  'type': 'conversation.read_cursor_updated',
  'occurredAt': '2026-08-25T20:01:00.000Z',
  'payload': _eventPayload,
};

Object? _roundTrip(Object? value) => jsonDecode(jsonEncode(value));
