import 'dart:async';
import 'dart:convert';

import 'package:handrail_chat/core.dart';
import 'package:test/test.dart';

void main() {
  group('durable realtime integration', () {
    test('recovery includes a conversation retained during snapshot reads',
        () async {
      final socket = _FakeSocket();
      final session =
          _session(socketFactory: (_, __) => socket, clock: _FakeClock());
      final store = NormalizedSnapshotStore();
      final pending = Completer<void>();
      final http = _RecoveryHttpTransport()
        ..beforeRead = (request) async {
          if (request.uri.path.endsWith('/message-reminders')) {
            await pending.future;
          }
        };
      final client = HandrailChatClient(
        apiBaseUri: Uri.parse('https://chat.example/api/chat'),
        tokenProvider: () async => 'token',
        transport: http,
        normalizedSnapshotStore: store,
        realtimeSession: session,
      );
      addTearDown(client.dispose);
      addTearDown(session.dispose);
      addTearDown(store.close);
      await session.start();
      socket.emitJson(_accepted());
      socket.emitJson(_event('unknown-event')..['type'] = 'future.event');
      await _pump();
      expect(session.state.state, 'hydratingSnapshot');
      final release =
          session.subscribeConversation(const ConversationId('conversation-1'));
      addTearDown(release);
      store.hydrateConversationDetail(ConversationDetailSnapshot.fromJson(
          _detailSnapshot('conversation-1')));
      pending.complete();
      await _pump(30);
      expect(store.state.timelines.keys,
          contains(const ConversationId('conversation-1')));
      expect(
          store
              .conversation(const ConversationId('conversation-1'))
              .currentPreference,
          isNotNull);
      expect(store.state.latestReplayCursor?.eventId, 'hydrated-cursor');
    });

    test('private event recovery hydrates its unretained resource', () async {
      final socket = _FakeSocket();
      final session =
          _session(socketFactory: (_, __) => socket, clock: _FakeClock());
      final store = NormalizedSnapshotStore();
      final http = _RecoveryHttpTransport();
      final client = HandrailChatClient(
        apiBaseUri: Uri.parse('https://chat.example/api/chat'),
        tokenProvider: () async => 'token',
        transport: http,
        normalizedSnapshotStore: store,
        realtimeSession: session,
      );
      addTearDown(client.dispose);
      addTearDown(session.dispose);
      addTearDown(store.close);
      await session.start();
      socket.emitJson(_accepted());
      socket.emitJson({
        ..._event('private-read'),
        'streamId': 'user:user-1',
        'type': 'conversation.read_cursor_updated',
        'payload': {
          'kind': 'conversation_read_cursor',
          'actorUserId': 'user-1',
          'operation': 'mark_read',
          'conversationId': 'conversation-1',
          'readState': {
            'conversationId': 'conversation-1',
            'userId': 'user-1',
            'lastReadSequence': 0,
            'updatedAt': '2026-08-26T12:00:00.000Z'
          },
          'latestSequence': 0,
          'unreadCount': 0,
        },
      });
      await _pump(30);
      expect(store.state.conversations.keys,
          contains(const ConversationId('conversation-1')));
      expect(store.state.latestReplayCursor?.eventId, 'hydrated-cursor');
    });

    for (final stabilizes in [true, false]) {
      test('inconsistent snapshot cursors retry with a bound: $stabilizes',
          () async {
        final store = NormalizedSnapshotStore();
        final http = _RecoveryHttpTransport();
        var timelineReads = 0;
        http.respond = (request) {
          if (request.uri.path.endsWith('/messages')) {
            timelineReads++;
            final id = request.uri.path.split('/').reversed.skip(1).first;
            return _httpResponse({
              ..._timelineSnapshot(id),
              'replay': {
                'resumeFrom': {
                  'eventId': stabilizes && timelineReads > 2
                      ? 'stable-cursor'
                      : 'cursor-$timelineReads'
                }
              },
            });
          }
          if (request.uri.path.endsWith('/conversation-3')) {
            return _httpResponse(_detailSnapshot('conversation-3'));
          }
          return null;
        };
        final client = HandrailChatClient(
          apiBaseUri: Uri.parse('https://chat.example/api/chat'),
          tokenProvider: () async => 'token',
          transport: http,
          normalizedSnapshotStore: store,
        );
        addTearDown(client.dispose);
        addTearDown(store.close);
        final before = store.state;
        final hydration = client.hydrateRealtimeSnapshots(
          const ChatRealtimeSnapshotHydrationInput(
            reason: ChatRealtimeSnapshotRecoveryReason.eventGap,
            expiredCursor: EventCursor(eventId: 'expired'),
            retainedConversationIds: [
              ConversationId('conversation-1'),
              ConversationId('conversation-3')
            ],
          ),
        );
        if (stabilizes) {
          expect((await hydration)?.eventId, 'stable-cursor');
          expect(timelineReads, 4);
          expect(store.state.timelines, hasLength(2));
        } else {
          await expectLater(hydration, throwsException);
          expect(timelineReads, 6);
          expect(store.state, same(before));
        }
      });
    }

    test('reduces, settles, persists, then publishes exactly once', () async {
      final order = <String>[];
      final socket = _FakeSocket();
      final storage = _FakeStorage(onWrite: (_) => order.add('persist'));
      final session = _session(
        socketFactory: (_, __) => socket,
        storage: storage,
        onCanonicalEvent: (_) => order.add('settle'),
      );
      var reductionCalls = 0;
      session.bindDurableState(
        reduceDurableEvent: (event) {
          order.add('reduce');
          reductionCalls += 1;
          return DurableEventReduction(
            status: reductionCalls == 1
                ? DurableEventReductionStatus.applied
                : DurableEventReductionStatus.duplicate,
            state: NormalizedSnapshotState.empty(),
          );
        },
        hydrateSnapshot: (_) => null,
      );
      final delivered = <KnownDurableEvent>[];
      final subscription = session.canonicalEvents.listen(delivered.add);

      await session.start();
      socket.emitJson(_accepted());
      socket.emitJson(_event('event-1'));
      await _pump();

      expect(order, ['reduce', 'settle', 'persist']);
      expect(delivered.map((event) => event.eventId), ['event-1']);
      expect(storage.writes, [
        jsonEncode({'eventId': 'event-1'})
      ]);

      socket.emitJson(_event('event-1'));
      await _pump();
      expect(order, ['reduce', 'settle', 'persist', 'reduce']);

      await subscription.cancel();
      await session.dispose();
    });

    test('maps invalid, incompatible, and reducer-gap frames to recovery',
        () async {
      final cases = <(
        String,
        Map<String, Object?>,
        DurableEventReductionError?,
        ChatRealtimeSnapshotRecoveryReason
      )>[
        (
          'invalid',
          _event('invalid')..['tenantId'] = 'tenant-other',
          null,
          ChatRealtimeSnapshotRecoveryReason.eventInvalid,
        ),
        (
          'incompatible',
          _event('incompatible')..['type'] = 'future.event',
          null,
          ChatRealtimeSnapshotRecoveryReason.eventIncompatible,
        ),
        (
          'gap',
          _event('gap'),
          DurableEventReductionError(
            DurableEventDiagnostic(
              code: DurableEventDiagnosticCode.orderingGap,
              reason: DurableEventRecoveryReason.eventGap,
              eventId: 'gap',
              streamId: 'conversation-1',
              eventType: 'huddle.updated',
              message: 'safe gap',
            ),
          ),
          ChatRealtimeSnapshotRecoveryReason.eventGap,
        ),
      ];

      for (final entry in cases) {
        final socket = _FakeSocket();
        final storage = _FakeStorage();
        final hydration = Completer<EventCursor?>();
        final diagnostics = <ChatRealtimeDiagnostic>[];
        final inputs = <ChatRealtimeSnapshotHydrationInput>[];
        final session = _session(
          socketFactory: (_, __) => socket,
          storage: storage,
          onDiagnostic: diagnostics.add,
        );
        session.bindDurableState(
          reduceDurableEvent: (event) {
            if (entry.$3 case final error?) throw error;
            return DurableEventReduction(
              status: DurableEventReductionStatus.applied,
              state: NormalizedSnapshotState.empty(),
            );
          },
          hydrateSnapshot: (input) {
            inputs.add(input);
            return hydration.future;
          },
        );

        await session.start();
        socket.emitJson(_accepted());
        socket.emitJson(entry.$2);
        await _pump();

        expect(session.state, isA<ChatRealtimeHydratingSnapshotState>(),
            reason: entry.$1);
        expect(inputs.single.reason, entry.$4, reason: entry.$1);
        expect(storage.clearCount, 1, reason: entry.$1);
        expect(storage.writes, isEmpty, reason: entry.$1);
        expect(
          diagnostics.single.code,
          ChatRealtimeDiagnosticCode.durableEventRecovery,
          reason: entry.$1,
        );
        expect(diagnostics.single.toString(), isNot(contains('tenant-other')));

        await session.dispose();
        hydration.complete(null);
      }
    });

    test('callback and required-storage failures never advance the cursor',
        () async {
      for (final failStorage in [false, true]) {
        final socket = _FakeSocket();
        final storage = _FakeStorage()..throwOnWrite = failStorage;
        final hydration = Completer<EventCursor?>();
        final session = _session(
          socketFactory: (_, __) => socket,
          storage: storage,
          onCanonicalEvent: failStorage
              ? null
              : (_) => throw StateError('callback payload secret'),
        );
        session.bindDurableState(
          reduceDurableEvent: (_) => DurableEventReduction(
            status: DurableEventReductionStatus.applied,
            state: NormalizedSnapshotState.empty(),
          ),
          hydrateSnapshot: (_) => hydration.future,
        );

        await session.start();
        socket.emitJson(_accepted());
        socket.emitJson(_event('unsafe-event'));
        await _pump();

        expect(session.state.state, 'hydratingSnapshot');
        expect(storage.value, isNull);
        expect(storage.clearCount, 1);
        await session.dispose();
        hydration.complete(null);
      }
    });

    test('coalesces queued triggers and close cancels every late effect',
        () async {
      final socket = _FakeSocket();
      final storage = _FakeStorage();
      final hydration = Completer<EventCursor?>();
      var hydrationCalls = 0;
      final clock = _FakeClock();
      final session = _session(
        socketFactory: (_, __) => socket,
        storage: storage,
        clock: clock,
      );
      session.bindDurableState(
        reduceDurableEvent: (event) => throw DurableEventReductionError(
          DurableEventDiagnostic(
            code: DurableEventDiagnosticCode.orderingGap,
            reason: DurableEventRecoveryReason.eventGap,
            eventId: event.eventId,
            streamId: event.streamId,
            eventType: event.type,
            message: 'safe gap',
          ),
        ),
        hydrateSnapshot: (_) {
          hydrationCalls += 1;
          return hydration.future;
        },
      );

      await session.start();
      socket.emitJson(_accepted());
      socket.emitJson(_event('gap-1'));
      socket.emitJson(_event('gap-2'));
      await _pump();
      expect(hydrationCalls, 1);

      await session.close();
      hydration.complete(const EventCursor(eventId: 'late-cursor'));
      await _pump();
      expect(storage.writes, isEmpty);
      expect(clock.activeCount, 0);
      expect(session.state.state, 'idle');
      await session.dispose();
    });

    test('close cleans a required cursor write that completes after authority',
        () async {
      final socket = _FakeSocket();
      final storage = _DelayedStorage();
      final session = _session(
        socketFactory: (_, __) => socket,
        storage: storage,
      );
      session.bindDurableState(
        reduceDurableEvent: (_) => DurableEventReduction(
          status: DurableEventReductionStatus.applied,
          state: NormalizedSnapshotState.empty(),
        ),
        hydrateSnapshot: (_) => null,
      );

      await session.start();
      socket.emitJson(_accepted());
      socket.emitJson(_event('late-write'));
      await storage.started.future;
      await session.close();
      storage.release.complete();
      await _pump();

      expect(storage.value, isNull);
      expect(session.state.state, 'idle');
      await session.dispose();
    });

    test('repeated hydration failures stay observable and serialize retries',
        () async {
      final first = _FakeSocket();
      final second = _FakeSocket();
      final sockets = <_FakeSocket>[first, second];
      final clock = _FakeClock();
      final diagnostics = <ChatRealtimeDiagnostic>[];
      var socketIndex = 0;
      var hydrationCalls = 0;
      final session = _session(
        socketFactory: (_, __) => sockets[socketIndex++],
        clock: clock,
        onDiagnostic: diagnostics.add,
      );
      session.bindDurableState(
        reduceDurableEvent: (_) => throw const DurableEventReductionError(
          DurableEventDiagnostic(
            code: DurableEventDiagnosticCode.orderingGap,
            reason: DurableEventRecoveryReason.eventGap,
            eventId: 'gap',
            streamId: 'conversation-1',
            eventType: 'huddle.updated',
            message: 'safe gap',
          ),
        ),
        hydrateSnapshot: (_) {
          hydrationCalls += 1;
          throw StateError('snapshot secret');
        },
      );

      await session.start();
      first.emitJson(_accepted());
      first.emitJson(_event('gap-1'));
      await _pump();
      expect(session.state.state, 'reconnecting');
      expect(clock.activeCount, 1);

      clock.runNext();
      await _pump();
      second.emitJson(_accepted());
      second.emitJson(_event('gap-2'));
      await _pump();

      expect(hydrationCalls, 2);
      expect(clock.activeCount, 1);
      expect(
        diagnostics.where((value) =>
            value.code == ChatRealtimeDiagnosticCode.snapshotHydrationFailed),
        hasLength(2),
      );
      expect(diagnostics.join(), isNot(contains('snapshot secret')));
      await session.dispose();
    });

    test('client hydrates retained authorized scope and resumes canonical flow',
        () async {
      final store = NormalizedSnapshotStore();
      store.hydrateConversationList(
        ConversationListSnapshot.fromJson(_listSnapshot([
          'conversation-1',
          'conversation-2',
        ])),
      );
      store.reduceDurableEvent(
        KnownDurableEvent.fromJson(
          _event('seed-event'),
          trustedIdentity: const DurableEventTrustedIdentity(
            tenantId: TenantId('tenant-1'),
            userId: UserId('user-1'),
          ),
        ),
      );
      expect(store.state.durableStreams, isNotEmpty);

      final first = _FakeSocket();
      final second = _FakeSocket();
      final sockets = <_FakeSocket>[first, second];
      var socketIndex = 0;
      final storage = _FakeStorage();
      final clock = _FakeClock();
      final session = _session(
        socketFactory: (_, __) => sockets[socketIndex++],
        storage: storage,
        clock: clock,
      );
      final releaseOne =
          session.subscribeConversation(const ConversationId('conversation-1'));
      final releaseTwo =
          session.subscribeConversation(const ConversationId('conversation-2'));
      final http = _RecoveryHttpTransport();
      final client = HandrailChatClient(
        apiBaseUri: Uri.parse('https://chat.example/api/chat'),
        tokenProvider: () async => 'token',
        transport: http,
        normalizedSnapshotStore: store,
        realtimeSession: session,
      );

      await session.start();
      first.emitJson(_accepted());
      first.emitJson(_event('unknown-event')..['type'] = 'future.event');
      await _pump(30);

      expect(
        http.requests.map((request) => request.uri.path),
        [
          '/api/chat/message-reminders',
          '/api/chat/conversations',
          '/api/chat/conversations/conversation-1',
          '/api/chat/conversations/conversation-1/messages',
          '/api/chat/conversations/conversation-2',
        ],
      );
      expect(
        session.conversationSubscriptionStatesById['conversation-2'],
        isA<ChatRealtimeConversationSubscriptionRemovedState>(),
      );
      expect(store.state.durableStreams, isEmpty);
      expect(store.state.latestReplayCursor?.eventId, 'hydrated-cursor');
      expect(
        store
            .messageReminder(const MessageId('message-reminder-recovered'))
            .dueAt,
        const IsoTimestamp('2099-08-28T20:00:00.000Z'),
      );
      expect(storage.value, jsonEncode({'eventId': 'hydrated-cursor'}));
      expect(session.state.state, 'reconnecting');

      clock.runNext();
      await _pump();
      expect(
        jsonDecode(second.sent.single),
        {
          'clientPackageVersion': '0.1.3',
          'protocolVersion': handrailChatDurableEventProtocolVersion,
          'resumeFrom': {'eventId': 'hydrated-cursor'},
        },
      );
      second.emitJson(_accepted());
      second.emitJson(_event('post-hydration')
        ..['occurredAt'] = '2026-08-26T12:00:01.000Z');
      await _pump();
      expect(store.state.latestReplayCursor?.eventId, 'post-hydration');
      expect(storage.value, jsonEncode({'eventId': 'post-hydration'}));

      releaseOne();
      releaseTwo();
      await client.dispose();
      await session.dispose();
      await store.close();
    });
  });
}

ChatRealtimeSessionTransport _session({
  required ChatRealtimeSocketFactory socketFactory,
  ChatRealtimeCursorStorage? storage,
  ChatRealtimeClock? clock,
  ChatRealtimeDiagnosticListener? onDiagnostic,
  ChatRealtimeCanonicalEventListener? onCanonicalEvent,
}) =>
    ChatRealtimeSessionTransport(
      endpoint: Uri.parse('https://chat.example/api/chat'),
      clientPackageVersion: '0.1.3',
      protocolVersion: handrailChatDurableEventProtocolVersion,
      tokenProvider: () => 'token',
      socketFactory: socketFactory,
      cursorStorage: storage,
      cursorStorageScope: storage == null ? null : 'account-a:device-1',
      clock: clock,
      random: () => 0.5,
      onDiagnostic: onDiagnostic,
      onCanonicalEvent: onCanonicalEvent,
    );

Map<String, Object?> _accepted() => <String, Object?>{
      'type': 'chat.session.accepted',
      'metadata': _metadata,
      'tenantId': 'tenant-1',
      'actorStreamId': 'user:user-1',
      'deviceId': 'device-1',
      'sessionId': 'session-1',
    };

Map<String, Object?> _event(String eventId) => <String, Object?>{
      'eventId': eventId,
      'protocolVersion': handrailChatDurableEventProtocolVersion,
      'tenantId': 'tenant-1',
      'streamId': 'conversation-1',
      'type': 'huddle.updated',
      'occurredAt': '2026-08-26T12:00:00.000Z',
      'payload': <String, Object?>{
        'state': <String, Object?>{
          'status': 'inactive',
          'conversationId': 'conversation-1',
        },
      },
    };

const Map<String, Object?> _metadata = <String, Object?>{
  'packageVersion': '0.1.3',
  'protocolVersion': handrailChatDurableEventProtocolVersion,
  'schemaVersion': 1,
  'enabledFeatures': <String, Object?>{},
  'supportedProtocolRange': <String, Object?>{
    'minimumVersion': 3,
    'maximumVersion': handrailChatDurableEventProtocolVersion,
  },
};

Future<void> _pump([int times = 12]) async {
  for (var index = 0; index < times; index += 1) {
    await Future<void>.delayed(Duration.zero);
  }
}

final class _FakeSocket implements ChatRealtimeSocket {
  final StreamController<Object?> _frames =
      StreamController<Object?>.broadcast(sync: true);
  final List<String> sent = <String>[];
  var closeCount = 0;

  @override
  Stream<Object?> get frames => _frames.stream;

  void emitJson(Object? value) => _frames.add(jsonEncode(value));

  @override
  void send(String data) => sent.add(data);

  @override
  void close() => closeCount += 1;
}

final class _FakeStorage implements ChatRealtimeCursorStorage {
  _FakeStorage({this.onWrite});

  final void Function(String value)? onWrite;
  String? value;
  final List<String> writes = <String>[];
  var clearCount = 0;
  var throwOnWrite = false;

  @override
  String? read({required String scope}) => value;

  @override
  void write({required String scope, required String value}) {
    writes.add(value);
    if (throwOnWrite) throw StateError('storage secret');
    onWrite?.call(value);
    this.value = value;
  }

  @override
  void clear({required String scope}) {
    clearCount += 1;
    value = null;
  }
}

final class _DelayedStorage implements ChatRealtimeCursorStorage {
  final Completer<void> started = Completer<void>();
  final Completer<void> release = Completer<void>();
  String? value;

  @override
  String? read({required String scope}) => value;

  @override
  Future<void> write({required String scope, required String value}) async {
    if (!started.isCompleted) started.complete();
    await release.future;
    this.value = value;
  }

  @override
  void clear({required String scope}) => value = null;
}

final class _FakeClock implements ChatRealtimeClock {
  final List<_FakeTimer> _timers = <_FakeTimer>[];

  int get activeCount => _timers.where((timer) => !timer.cancelled).length;

  @override
  ChatRealtimeTimer schedule(Duration delay, void Function() callback) {
    final timer = _FakeTimer(callback);
    _timers.add(timer);
    return timer;
  }

  void runNext() {
    final timer = _timers.firstWhere((timer) => !timer.cancelled);
    timer.cancelled = true;
    timer.callback();
  }
}

final class _FakeTimer implements ChatRealtimeTimer {
  _FakeTimer(this.callback);

  final void Function() callback;
  var cancelled = false;

  @override
  void cancel() => cancelled = true;
}

final class _RecoveryHttpTransport implements HandrailChatHttpTransport {
  Future<void> Function(HandrailChatHttpRequest)? beforeRead;
  HandrailChatHttpResponse? Function(HandrailChatHttpRequest)? respond;
  final List<HandrailChatHttpRequest> requests = <HandrailChatHttpRequest>[];

  @override
  Future<HandrailChatHttpResponse> send(
    HandrailChatHttpRequest request,
  ) async {
    requests.add(request);
    await beforeRead?.call(request);
    final overridden = respond?.call(request);
    if (overridden != null) return overridden;
    final path = request.uri.path;
    if (path == '/api/chat/message-reminders') {
      return _httpResponse({
        'kind': 'message_reminder_list',
        'privacy': 'actor_private',
        'items': [
          {
            'conversationId': 'conversation-1',
            'messageId': 'message-reminder-recovered',
            'reminderRevision': 2,
            'reminder': {
              'privacy': 'affected_authenticated_actor',
              'state': 'scheduled',
              'dueAt': '2099-08-28T20:00:00.000Z',
            },
          },
        ],
        'page': {'nextCursor': null},
      });
    }
    if (path == '/api/chat/conversations') {
      return _httpResponse(_listSnapshot(['conversation-1']));
    }
    if (path == '/api/chat/conversations/conversation-1') {
      return _httpResponse(_detailSnapshot('conversation-1'));
    }
    if (path == '/api/chat/conversations/conversation-1/messages') {
      return _httpResponse(_timelineSnapshot('conversation-1'));
    }
    if (path == '/api/chat/conversations/conversation-2') {
      return const HandrailChatHttpResponse(statusCode: 404, body: '{}');
    }
    throw StateError('Unexpected recovery request path.');
  }
}

HandrailChatHttpResponse _httpResponse(Object? body) =>
    HandrailChatHttpResponse(statusCode: 200, body: jsonEncode(body));

Map<String, Object?> _listSnapshot(List<String> conversationIds) =>
    <String, Object?>{
      'kind': 'conversation_list',
      'scope': <String, Object?>{'type': 'organization'},
      'items': [for (final id in conversationIds) _summary(id)],
      'page': <String, Object?>{},
      '_meta': _snapshotMetadata(),
    };

Map<String, Object?> _detailSnapshot(String conversationId) =>
    <String, Object?>{
      'kind': 'conversation_detail',
      'conversation': <String, Object?>{
        ..._summary(conversationId),
        'memberUserIds': <String>['user-1'],
        'currentPreference': <String, Object?>{
          'conversationId': conversationId,
          'userId': 'user-1',
          'notificationPreference': 'all',
          'isStarred': false,
          'mute': <String, Object?>{'muted': false},
          'updatedAt': '2026-08-26T12:00:00.000Z',
        },
      },
      '_meta': _snapshotMetadata(),
    };

Map<String, Object?> _summary(String conversationId) => <String, Object?>{
      'id': conversationId,
      'tenantId': 'tenant-1',
      'type': 'channel',
      'name': 'Channel $conversationId',
      'visibility': 'public',
      'createdAt': '2026-08-26T12:00:00.000Z',
      'updatedAt': '2026-08-26T12:00:00.000Z',
      'latestSequence': 0,
      'activityAt': '2026-08-26T12:00:00.000Z',
      'unreadMentionCount': 0,
      'currentMember': <String, Object?>{
        'tenantId': 'tenant-1',
        'conversationId': conversationId,
        'userId': 'user-1',
        'role': 'member',
        'state': 'active',
        'joinedAt': '2026-08-26T12:00:00.000Z',
        'updatedAt': '2026-08-26T12:00:00.000Z',
      },
      'currentReadState': <String, Object?>{
        'conversationId': conversationId,
        'userId': 'user-1',
        'lastReadSequence': 0,
        'updatedAt': '2026-08-26T12:00:00.000Z',
      },
      'currentPreference': <String, Object?>{
        'conversationId': conversationId,
        'userId': 'user-1',
        'notificationPreference': 'all',
        'isStarred': false,
        'mute': <String, Object?>{'muted': false},
        'updatedAt': '2026-08-26T12:00:00.000Z',
      },
      'activeMemberUserIds': <String>['user-1'],
    };

Map<String, Object?> _timelineSnapshot(String conversationId) =>
    <String, Object?>{
      'conversationId': conversationId,
      'messages': <Object?>[],
      'pagination': <String, Object?>{
        'older': <String, Object?>{'available': false},
        'newer': <String, Object?>{'available': false},
      },
      'replay': <String, Object?>{
        'resumeFrom': <String, Object?>{'eventId': 'hydrated-cursor'},
      },
    };

Map<String, Object?> _snapshotMetadata() => <String, Object?>{
      ..._metadata,
      'schemaVersion': 9,
      'enabledFeatures': <String, Object?>{
        conversationSnapshotFeature: true,
      },
      'feature': <String, Object?>{
        'name': conversationSnapshotFeature,
        'version': conversationSnapshotVersion,
      },
    };
