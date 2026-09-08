import 'dart:async';
import 'dart:convert';

import 'package:handrail_chat/testing.dart';
import 'package:test/test.dart';

const _conversationId = ConversationId('conversation-1');
const _messageId = MessageId('message-1');
const _messageId2 = MessageId('message-2');
const _due1 = IsoTimestamp('2099-08-28T20:00:00.000Z');
const _due2 = IsoTimestamp('2099-08-29T20:00:00.000Z');
const _due3 = IsoTimestamp('2099-08-30T20:00:00.000Z');

void main() {
  test('hydrates all strict actor-private reminder pages during recovery',
      () async {
    final transport = ScriptedHandrailChatHttpTransport();
    final firstCursor = _cursor(_due1, _messageId);
    transport.enqueueJson(_snapshot([
      _snapshotEntry(_conversationId, _messageId, 2, _due1),
    ], nextCursor: firstCursor));
    transport.enqueueJson(_snapshot([
      _snapshotEntry(
        const ConversationId('conversation-2'),
        const MessageId('message-2'),
        4,
        _due2,
      ),
    ]));
    final fixture = _fixture(transport);

    final cursor = await fixture.client.hydrateRealtimeSnapshots(
      const ChatRealtimeSnapshotHydrationInput(
        reason: ChatRealtimeSnapshotRecoveryReason.replayExpired,
        expiredCursor: EventCursor(eventId: 'expired'),
        retainedConversationIds: [],
      ),
    );

    expect(cursor, isNull);
    expect(transport.requests, hasLength(2));
    expect(transport.requests.first.uri.path, '/api/chat/message-reminders');
    expect(transport.requests.first.uri.queryParameters, {'limit': '100'});
    expect(
      transport.requests.last.uri.queryParameters,
      {'limit': '100', 'cursor': firstCursor},
    );
    expect(fixture.store.messageReminder(_messageId).dueAt, _due1);
    expect(fixture.store.messageReminder(_messageId).authoritativeRevision, 2);
    expect(
      fixture.store
          .messageReminder(const MessageId('message-2'))
          .authoritativeRevision,
      4,
    );
    final restored = NormalizedSnapshotStateStorageCodec.decode(
      NormalizedSnapshotStateStorageCodec.encode(fixture.store.state),
    );
    expect(restored.messageReminderRevisions[_messageId], 2);
    expect(
      restored.authoritativeCurrentUserMessageReminders[_messageId],
      isA<CanonicalScheduledMessageReminder>(),
    );

    await _close(fixture);
  });

  test('serializes set, explicit reschedule, and cancel per message', () async {
    final transport = ScriptedHandrailChatHttpTransport()
      ..enqueueJson(_result('reminder-key-1', 0, 'set', _due1, 'applied'))
      ..enqueueJson(_result('reminder-key-2', 1, 'set', _due2, 'applied'))
      ..enqueueJson(_result('reminder-key-3', 2, 'cancel', null, 'applied'));
    final fixture = _fixture(transport);

    final set = fixture.client.setMessageReminder(
      conversationId: _conversationId,
      messageId: _messageId,
      dueAt: _due1,
    );
    final reschedule = fixture.client.rescheduleMessageReminder(
      conversationId: _conversationId,
      messageId: _messageId,
      dueAt: _due2,
    );
    final cancel = fixture.client.cancelMessageReminder(
      conversationId: _conversationId,
      messageId: _messageId,
    );
    expect(fixture.store.messageReminder(_messageId).isScheduled, isFalse);

    expect(await set, isA<ChatCommandSuccess<MessageReminderResult>>());
    expect(await reschedule, isA<ChatCommandSuccess<MessageReminderResult>>());
    expect(await cancel, isA<ChatCommandSuccess<MessageReminderResult>>());
    final bodies = transport.requests.map(_body).toList(growable: false);
    expect(bodies.map((body) => body['intent']), ['set', 'set', 'cancel']);
    expect(
      bodies.map((body) => body['expectedReminderRevision']),
      [0, 1, 2],
    );
    expect(bodies.map((body) => body['idempotencyKey']), [
      'reminder-key-1',
      'reminder-key-2',
      'reminder-key-3',
    ]);
    expect(
        transport.requests.every((request) => request.method == 'PUT'), isTrue);
    expect(
      transport.requests
          .singleWhere((request) => _body(request)['intent'] == 'cancel')
          .uri
          .path,
      '/api/chat/conversations/conversation-1/messages/message-1/reminder',
    );
    expect(fixture.store.messageReminder(_messageId).authoritativeRevision, 3);
    expect(
      fixture.store.messageReminder(_messageId).authoritativeReminder,
      isA<CanonicalCancelledMessageReminder>(),
    );

    await _close(fixture);
  });

  test('retry keeps one idempotency key and replay installs canonical state',
      () async {
    final transport = ScriptedHandrailChatHttpTransport()
      ..enqueueError(StateError('offline'))
      ..enqueueJson(_result('reminder-key-1', 0, 'set', _due1, 'replayed'));
    final fixture = _fixture(
      transport,
      retryOptions: ChatCommandRetryOptions(
        maxAttempts: 2,
        backoff: (_) => Duration.zero,
        wait: (_, __) async {},
      ),
    );

    final result = await fixture.client.setMessageReminder(
      conversationId: _conversationId,
      messageId: _messageId,
      dueAt: _due1,
    );

    expect(result, isA<ChatCommandSuccess<MessageReminderResult>>());
    expect(transport.requests, hasLength(2));
    expect(_body(transport.requests[0]), _body(transport.requests[1]));
    expect(
      transport.requests.map((request) => request.headers['Idempotency-Key']),
      everyElement('reminder-key-1'),
    );
    expect(fixture.store.messageReminder(_messageId).dueAt, _due1);
    await _close(fixture);
  });

  test('revision conflict converges and transport failure rolls back its owner',
      () async {
    final conflictTransport = ScriptedHandrailChatHttpTransport()
      ..enqueueJson(
        _result(
          'reminder-key-1',
          0,
          'set',
          _due1,
          'revision-conflict',
          revision: 4,
          canonical: const CanonicalCancelledMessageReminder(),
        ),
        statusCode: 409,
      );
    final conflict = _fixture(conflictTransport);
    expect(
      await conflict.client.setMessageReminder(
        conversationId: _conversationId,
        messageId: _messageId,
        dueAt: _due1,
      ),
      isA<ChatCommandSuccess<MessageReminderResult>>(),
    );
    expect(conflict.store.messageReminder(_messageId).authoritativeRevision, 4);
    expect(conflict.store.messageReminder(_messageId).isScheduled, isFalse);
    await _close(conflict);

    final failedTransport = ScriptedHandrailChatHttpTransport()
      ..enqueueError(StateError('network'));
    final failed = _fixture(failedTransport);
    failed.store.reconcileMessageReminderCanonical(
      conversationId: _conversationId,
      messageId: _messageId,
      reminderRevision: 1,
      reminder: const CanonicalScheduledMessageReminder(_due1),
    );
    final pending = failed.client.rescheduleMessageReminder(
      conversationId: _conversationId,
      messageId: _messageId,
      dueAt: _due2,
    );
    expect(failed.store.messageReminder(_messageId).dueAt, _due2);
    expect(await pending,
        isA<ChatCommandTransportFailure<MessageReminderResult>>());
    expect(failed.store.messageReminder(_messageId).dueAt, _due1);
    expect(failed.store.messageReminder(_messageId).isPending, isFalse);
    await _close(failed);
  });

  test('newer private event wins over a late older HTTP settlement', () async {
    final transport = _DelayedTransport();
    final fixture = _fixture(transport);
    final pending = fixture.client.setMessageReminder(
      conversationId: _conversationId,
      messageId: _messageId,
      dueAt: _due1,
    );
    await transport.started.future;

    final reduction = fixture.client.reduceDurableEvent(
      _event(2, const CanonicalScheduledMessageReminder(_due2)),
    );
    expect(reduction.status, DurableEventReductionStatus.applied);
    expect(fixture.store.messageReminder(_messageId).dueAt, _due1,
        reason:
            'the active optimistic intent remains visible until settlement');

    transport.release.complete(HandrailChatHttpResponse(
      statusCode: 200,
      body: jsonEncode(_result(
        'reminder-key-1',
        0,
        'set',
        _due1,
        'applied',
      )),
    ));
    expect(await pending, isA<ChatCommandSuccess<MessageReminderResult>>());
    expect(fixture.store.messageReminder(_messageId).dueAt, _due2);
    expect(fixture.store.messageReminder(_messageId).authoritativeRevision, 2);
    await _close(fixture);
  });

  test(
      'private realtime parsing is trusted and revisions converge monotonically',
      () async {
    final fixture = _fixture(ScriptedHandrailChatHttpTransport());
    fixture.client.reduceDurableEvent(
      _event(1, const CanonicalScheduledMessageReminder(_due1)),
    );
    fixture.client.reduceDurableEvent(
      _event(
        2,
        const CanonicalCancelledMessageReminder(),
        eventId: 'reminder-event-2',
        occurredAt: '2099-08-28T19:01:00.000Z',
      ),
    );
    fixture.client.reduceDurableEvent(
      _event(
        1,
        const CanonicalScheduledMessageReminder(_due3),
        eventId: 'reminder-event-stale',
        occurredAt: '2099-08-28T19:02:00.000Z',
      ),
    );
    expect(fixture.store.messageReminder(_messageId).authoritativeRevision, 2);
    expect(fixture.store.messageReminder(_messageId).isScheduled, isFalse);
    expect(
      () => KnownDurableEvent.fromJson(
        _eventJson(3, const CanonicalScheduledMessageReminder(_due3))
          ..['streamId'] = 'user:someone-else',
        trustedIdentity: _trustedIdentity,
      ),
      throwsA(isA<DurableEventFormatException>()),
    );
    await _close(fixture);
  });

  for (final occurredAt in [
    '2099-08-28T19:00:00.000Z',
    '2099-08-28T18:59:59.999Z',
  ]) {
    test('reminder revisions admit independent clocks at $occurredAt', () async {
      final fixture = _fixture(ScriptedHandrailChatHttpTransport());
      addTearDown(() => _close(fixture));
      fixture.client.reduceDurableEvent(
        _event(2, const CanonicalScheduledMessageReminder(_due1)),
      );
      final second = _event(
        3,
        const CanonicalScheduledMessageReminder(_due2),
        messageId: _messageId2,
        eventId: 'reminder-second',
        occurredAt: occurredAt,
      );
      expect(fixture.client.reduceDurableEvent(second).status,
          DurableEventReductionStatus.applied);

      void expectCanonicalAndReplay(String eventId) {
        final state = fixture.store.state;
        expect(state.messageReminderRevisions, {_messageId: 2, _messageId2: 3});
        expect(
          state.authoritativeCurrentUserMessageReminders[_messageId]!.toJson(),
          const CanonicalScheduledMessageReminder(_due1).toJson(),
        );
        expect(
          state.authoritativeCurrentUserMessageReminders[_messageId2]!.toJson(),
          const CanonicalScheduledMessageReminder(_due2).toJson(),
        );
        expect(state.latestReplayCursor!.eventId, eventId);
        expect(state.durableStreams['user:user-1']!.lastEventId, eventId);
        expect(state.durableStreams['user:user-1']!.lastOccurredAt,
            const IsoTimestamp('2099-08-28T19:00:00.000Z'));
      }

      expectCanonicalAndReplay('reminder-second');
      for (final messageId in [_messageId, _messageId2]) {
        final eventId = 'lower-${messageId.value}';
        expect(
          fixture.client.reduceDurableEvent(_event(
            1,
            const CanonicalCancelledMessageReminder(),
            messageId: messageId,
            eventId: eventId,
            occurredAt: occurredAt,
          )).status,
          DurableEventReductionStatus.applied,
        );
        expectCanonicalAndReplay(eventId);
      }
      final beforeDuplicate = fixture.store.state;
      expect(fixture.client.reduceDurableEvent(second).status,
          DurableEventReductionStatus.duplicate);
      expect(fixture.store.state, same(beforeDuplicate));

      for (final messageId in [_messageId, _messageId2]) {
        for (final invalid in [
          _event(
            messageId == _messageId ? 2 : 3,
            const CanonicalScheduledMessageReminder(_due3),
            messageId: messageId,
            eventId: 'equal-conflict-${messageId.value}',
            occurredAt: occurredAt,
          ),
          _event(
            4,
            const CanonicalScheduledMessageReminder(_due3),
            messageId: messageId,
            conversationId: const ConversationId('changed-conversation'),
            eventId: 'identity-conflict-${messageId.value}',
            occurredAt: occurredAt,
          ),
        ]) {
          final before = fixture.store.state;
          expect(() => fixture.client.reduceDurableEvent(invalid),
              throwsA(isA<DurableEventReductionError>()));
          expect(fixture.store.state, same(before));
        }
        final malformed = _eventJson(
          4,
          const CanonicalScheduledMessageReminder(_due3),
          messageId: messageId,
        )
          ..['eventId'] = 'malformed-${messageId.value}'
          ..['occurredAt'] = occurredAt;
        (malformed['payload'] as Map<String, Object?>)['reminder'] = {
          'kind': 'scheduled',
          'dueAt': 'invalid-timestamp',
        };
        final before = fixture.store.state;
        expect(
          () => fixture.client.reduceDurableEvent(KnownDurableEvent.fromJson(
            malformed,
            trustedIdentity: _trustedIdentity,
          )),
          throwsA(isA<DurableEventFormatException>()),
        );
        expect(fixture.store.state, same(before));
      }
    });
  }

  test('identity change and dispose revoke late reminder completions',
      () async {
    final storage = InMemoryApplicationChatStorage();
    final identityTransport = _DelayedTransport();
    final identityFixture = _fixture(
      identityTransport,
      storage: storage,
      storageIdentity: _identity('user-1'),
    );
    expect(
      await identityFixture.client.initialize(),
      isA<ChatClientReadyState>(),
    );
    final identityPending = identityFixture.client.setMessageReminder(
      conversationId: _conversationId,
      messageId: _messageId,
      dueAt: _due1,
    );
    await identityTransport.started.future;
    await identityFixture.client.activateStorageIdentity(_identity('user-2'));
    expect(
        await identityPending, isA<ChatCommandClosed<MessageReminderResult>>());
    expect(identityFixture.store.state.currentUserMessageReminders, isEmpty);
    identityTransport.release.complete(HandrailChatHttpResponse(
      statusCode: 200,
      body: jsonEncode(
        _result('reminder-key-1', 0, 'set', _due1, 'applied'),
      ),
    ));
    await Future<void>.delayed(Duration.zero);
    expect(identityFixture.store.state.currentUserMessageReminders, isEmpty);
    await _close(identityFixture);

    final disposeTransport = _DelayedTransport();
    final disposeFixture = _fixture(disposeTransport);
    final disposePending = disposeFixture.client.setMessageReminder(
      conversationId: _conversationId,
      messageId: _messageId,
      dueAt: _due1,
    );
    await disposeTransport.started.future;
    final close = disposeFixture.client.dispose();
    expect(
        await disposePending, isA<ChatCommandClosed<MessageReminderResult>>());
    disposeTransport.release.complete(HandrailChatHttpResponse(
      statusCode: 200,
      body: jsonEncode(
        _result('reminder-key-1', 0, 'set', _due1, 'applied'),
      ),
    ));
    await close;
    expect(disposeFixture.store.state.currentUserMessageReminders, isEmpty);
    expect(
      await disposeFixture.client.setMessageReminder(
        conversationId: _conversationId,
        messageId: _messageId,
        dueAt: _due1,
      ),
      isA<ChatCommandClosed<MessageReminderResult>>(),
    );
    await disposeFixture.store.close();
  });
}

({
  HandrailChatClient client,
  NormalizedSnapshotStore store,
  HandrailChatHttpTransport transport,
}) _fixture(
  HandrailChatHttpTransport transport, {
  ChatCommandRetryOptions retryOptions =
      const ChatCommandRetryOptions(maxAttempts: 1),
  ApplicationChatStorage? storage,
  ApplicationChatStorageIdentity? storageIdentity,
}) {
  final store = NormalizedSnapshotStore();
  var key = 0;
  return (
    client: HandrailChatClient(
      apiBaseUri: Uri.parse('https://chat.example.test/api/chat'),
      tokenProvider: () async => 'token',
      transport: transport,
      normalizedSnapshotStore: store,
      commandRetryOptions: retryOptions,
      generateIdempotencyKey: () => 'reminder-key-${++key}',
      localStorage: storage,
      storageIdentity: storageIdentity,
    ),
    store: store,
    transport: transport,
  );
}

Future<void> _close(
    ({
      HandrailChatClient client,
      NormalizedSnapshotStore store,
      HandrailChatHttpTransport transport,
    }) fixture) async {
  await fixture.client.dispose();
  await fixture.store.close();
}

Map<String, Object?> _body(HandrailChatHttpRequest request) =>
    (jsonDecode(request.body!) as Map).cast<String, Object?>();

Map<String, Object?> _result(
  String key,
  int expectedRevision,
  String intent,
  IsoTimestamp? dueAt,
  String status, {
  int? revision,
  CanonicalMessageReminder? canonical,
}) {
  final reminder = canonical ??
      (intent == 'set'
          ? CanonicalScheduledMessageReminder(dueAt!)
          : const CanonicalCancelledMessageReminder());
  return {
    'operation': 'message_reminder.v1',
    'intent': intent,
    'reconciliationStatus': status,
    'conversationId': _conversationId.toJson(),
    'messageId': _messageId.toJson(),
    'expectedReminderRevision': expectedRevision,
    'idempotencyKey': key,
    'reminderRevision': revision ??
        (status == 'already-requested'
            ? expectedRevision
            : expectedRevision + 1),
    'reminder': reminder.toJson(),
  };
}

Map<String, Object?> _snapshot(
  List<Map<String, Object?>> items, {
  String? nextCursor,
}) =>
    {
      'kind': 'message_reminder_list',
      'privacy': 'actor_private',
      'items': items,
      'page': {'nextCursor': nextCursor},
    };

Map<String, Object?> _snapshotEntry(
  ConversationId conversationId,
  MessageId messageId,
  int revision,
  IsoTimestamp dueAt,
) =>
    {
      'conversationId': conversationId.toJson(),
      'messageId': messageId.toJson(),
      'reminderRevision': revision,
      'reminder': CanonicalScheduledMessageReminder(dueAt).toJson(),
    };

String _cursor(IsoTimestamp dueAt, MessageId messageId) =>
    'handrail-message-reminders.v1.'
    '${Uri.encodeComponent(jsonEncode([dueAt.toJson(), messageId.toJson()]))}';

const _trustedIdentity = DurableEventTrustedIdentity(
  tenantId: TenantId('tenant-1'),
  userId: UserId('user-1'),
);

MessageReminderUpdatedDurableEvent _event(
  int revision,
  CanonicalMessageReminder reminder, {
  MessageId messageId = _messageId,
  ConversationId conversationId = _conversationId,
  String eventId = 'reminder-event-1',
  String occurredAt = '2099-08-28T19:00:00.000Z',
}) =>
    KnownDurableEvent.fromJson(
      _eventJson(revision, reminder,
          messageId: messageId, conversationId: conversationId)
        ..['eventId'] = eventId
        ..['occurredAt'] = occurredAt,
      trustedIdentity: _trustedIdentity,
    ) as MessageReminderUpdatedDurableEvent;

Map<String, Object?> _eventJson(
  int revision,
  CanonicalMessageReminder reminder, {
  MessageId messageId = _messageId,
  ConversationId conversationId = _conversationId,
}) =>
    {
      'eventId': 'reminder-event',
      'protocolVersion': handrailChatDurableEventProtocolVersion,
      'tenantId': 'tenant-1',
      'streamId': 'user:user-1',
      'type': 'message_reminder.updated',
      'occurredAt': '2099-08-28T19:00:00.000Z',
      'payload': {
        'operation': 'message_reminder.v1',
        'conversationId': conversationId.toJson(),
        'messageId': messageId.toJson(),
        'reminderRevision': revision,
        'reminder': reminder.toJson(),
      },
    };

ApplicationChatStorageIdentity _identity(String userId) =>
    ApplicationChatStorageIdentity(
      tenantId: const TenantId('tenant-1'),
      userId: UserId(userId),
      deviceId: const DeviceId('device-1'),
    );

final class _DelayedTransport implements HandrailChatHttpTransport {
  final Completer<void> started = Completer<void>();
  final Completer<HandrailChatHttpResponse> release =
      Completer<HandrailChatHttpResponse>();
  HandrailChatHttpRequest? request;

  @override
  Future<HandrailChatHttpResponse> send(HandrailChatHttpRequest request) {
    this.request = request;
    if (request.method == 'GET' && request.uri.path.endsWith('/_meta')) {
      return Future.value(const HandrailChatHttpResponse(
        statusCode: 200,
        body: '''
{
  "packageVersion": "0.1.3",
  "protocolVersion": 4,
  "schemaVersion": 1,
  "enabledFeatures": {"conversation_snapshot": true},
  "supportedProtocolRange": {"minimumVersion": 4, "maximumVersion": 4}
}
''',
      ));
    }
    if (request.method == 'GET' &&
        request.uri.path.endsWith('/message-reminders')) {
      return Future.value(HandrailChatHttpResponse(
        statusCode: 200,
        body: jsonEncode(_snapshot([])),
      ));
    }
    if (!started.isCompleted) started.complete();
    return release.future;
  }
}
