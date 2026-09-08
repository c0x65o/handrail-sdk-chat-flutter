import 'dart:async';
import 'dart:convert';

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:handrail_chat/flutter.dart';
import 'package:handrail_chat/testing.dart'
    show FakeChatClock, FakeChatRealtimeNetwork, InMemoryApplicationChatStorage;

const _conversationId = ConversationId('conversation-1');
final _storageIdentity = ApplicationChatStorageIdentity(
  tenantId: TenantId('tenant-1'),
  userId: UserId('user-1'),
  deviceId: DeviceId('device-1'),
);

void main() {
  group('ChatScope application lifecycle', () {
    testWidgets(
      'background states coalesce, emit terminal signals, and preserve reads',
      (tester) async {
        await _ensureResumed(tester);
        final fixture = await _LifecycleFixture.create(seedReadState: true);
        addTearDown(fixture.dispose);

        await tester.pumpWidget(_host(fixture.scope));
        await _pumpUntil(tester, () => fixture.sockets.isNotEmpty);
        fixture.sockets.single.emitJson(_acceptedFrame(
          resumeFrom: 'accepted-cursor',
        ));
        await _pumpUntil(
          tester,
          () => fixture.session.state is ChatRealtimeConnectedState,
        );

        final readState =
            fixture.store.state.currentUserReadStates[_conversationId]!;
        fixture.sockets.single.resetSends();
        expect(
          fixture.client.startTyping(
            _conversationId,
            visibility: ChatRealtimeConversationVisibility.publicConversation,
          ),
          isTrue,
        );
        await _transition(tester, AppLifecycleState.inactive);
        final terminalFrames = fixture.sockets.single.sentJsonFrames;
        expect(
          terminalFrames,
          contains(
            isA<Map<String, Object?>>()
                .having((frame) => frame['type'], 'type', 'typing.signal')
                .having(
                  (frame) =>
                      (frame['payload']! as Map<String, Object?>)['state'],
                  'state',
                  'stop',
                ),
          ),
        );
        expect(
          terminalFrames,
          contains(
            isA<Map<String, Object?>>()
                .having((frame) => frame['type'], 'type', 'presence.signal')
                .having(
                  (frame) =>
                      (frame['payload']! as Map<String, Object?>)['state'],
                  'state',
                  'offline',
                ),
          ),
        );
        expect(fixture.sockets.single.closeCount, 1);

        final outboundAfterInactive = fixture.sockets.single.sent.length;
        await _transition(tester, AppLifecycleState.hidden);
        await _transition(tester, AppLifecycleState.paused);
        await _transition(tester, AppLifecycleState.detached);
        fixture.network
          ..setOnline(false)
          ..setOnline(true);
        fixture.clock.elapse(const Duration(days: 1));
        await _flushAsync(tester);

        expect(fixture.sockets, hasLength(1));
        expect(fixture.sockets.single.closeCount, 1);
        expect(fixture.sockets.single.sent, hasLength(outboundAfterInactive));
        expect(
          fixture.client.startTyping(
            _conversationId,
            visibility: ChatRealtimeConversationVisibility.publicConversation,
          ),
          isFalse,
        );
        expect(
          fixture.store.state.currentUserReadStates[_conversationId],
          same(readState),
          reason: 'lifecycle work must not rewrite cross-device read state',
        );
        expect(readState.lastReadSequence, const MessageSequence(4));
        expect(
          readState.manualUnreadFromSequence,
          const MessageSequence(3),
        );

        await _transition(tester, AppLifecycleState.resumed);
        await _pumpUntil(tester, () => fixture.sockets.length == 2);
        await _transition(tester, AppLifecycleState.inactive);
        await tester.pumpWidget(_host(const SizedBox.shrink()));
        await _pumpUntil(tester, () => fixture.session.isDisposed);
        await _flushAsync(tester);
        final socketCountAfterDispose = fixture.sockets.length;
        final eventCountAfterDispose = fixture.events.length;
        await _transition(tester, AppLifecycleState.hidden);
        await _transition(tester, AppLifecycleState.paused);
        await _transition(tester, AppLifecycleState.detached);
        await _transition(tester, AppLifecycleState.resumed);
        fixture.clock.elapse(const Duration(days: 1));
        await _flushAsync(tester);

        expect(fixture.connectivity.cancelCount, 1);
        expect(fixture.sockets, hasLength(socketCountAfterDispose));
        expect(fixture.events, hasLength(eventCountAfterDispose));
        expect(tester.takeException(), isNull);
      },
    );

    testWidgets(
      'foreground waits for cursor recovery and connected readiness before flush',
      (tester) async {
        await _ensureResumed(tester);
        await _transition(tester, AppLifecycleState.inactive);
        final fixture = await _LifecycleFixture.create(
          queuedSend: true,
          queuedRead: true,
          initialCursor: 'persisted-cursor',
        );
        addTearDown(fixture.dispose);

        await tester.pumpWidget(_host(fixture.scope));
        await _flushAsync(tester);
        expect(fixture.sockets, isEmpty);
        expect(fixture.http.posts, isEmpty);
        expect(fixture.http.patches, isEmpty);
        expect(fixture.client.queuedSendMessages, hasLength(1));

        await _transition(tester, AppLifecycleState.resumed);
        await _transition(tester, AppLifecycleState.resumed);
        await _pumpUntil(tester, () => fixture.sockets.length == 1);
        expect(
          fixture.sockets.first.handshakes.single['resumeFrom'],
          <String, Object?>{'eventId': 'persisted-cursor'},
        );

        fixture.sockets.first.emitJson(_snapshotRequiredFrame(
          'persisted-cursor',
        ));
        await _pumpUntil(
          tester,
          () => fixture.events.contains('state:hydratingSnapshot'),
        );
        expect(fixture.http.posts, isEmpty);
        expect(fixture.http.patches, isEmpty);
        expect(fixture.client.queuedSendMessages, hasLength(1));

        await _pumpUntil(
          tester,
          () => fixture.events.contains('state:reconnecting'),
        );
        expect(fixture.clock.runNext(), isTrue);
        await _pumpUntil(tester, () => fixture.sockets.length == 2);
        expect(fixture.sockets.last.handshakes.single['resumeFrom'], isNull);
        expect(fixture.http.posts, isEmpty);
        expect(fixture.http.patches, isEmpty);

        fixture.sockets.last.emitJson(_acceptedFrame(sessionId: 'session-2'));
        await _pumpUntil(
          tester,
          () =>
              fixture.client.queuedSendMessages.isEmpty &&
              fixture.http.patches.length == 1,
        );
        expect(fixture.http.posts, hasLength(1));
        expect(fixture.http.patches, hasLength(1));
        expect(
          fixture.http.patches.single.headers['Idempotency-Key'],
          'retained-read-key',
        );
        expect(fixture.client.queuedSendMessages, isEmpty);
        expect(fixture.sockets, hasLength(2));

        expect(
          fixture.events.indexOf('cursor:read'),
          lessThan(fixture.events.indexOf('handshake:persisted-cursor')),
        );
        expect(
          fixture.events.indexOf('handshake:persisted-cursor'),
          lessThan(fixture.events.indexOf('state:hydratingSnapshot')),
        );
        expect(
          fixture.events.indexOf('state:hydratingSnapshot'),
          lessThan(fixture.events.indexOf('cursor:clear')),
        );
        expect(
          fixture.events.indexOf('cursor:clear'),
          lessThan(fixture.events.indexOf('handshake:none')),
        );
        expect(
          fixture.events.indexOf('handshake:none'),
          lessThan(fixture.events.indexOf('state:connected')),
        );
        expect(
          fixture.events.indexOf('state:connected'),
          lessThan(fixture.events.indexOf('queue:flush')),
        );
        expect(
          fixture.events.indexOf('state:connected'),
          lessThan(fixture.events.indexOf('read:flush')),
        );

        await tester.pumpWidget(_host(const SizedBox.shrink()));
        await _pumpUntil(tester, () => fixture.session.isDisposed);
      },
    );

    testWidgets('disposal prevents later reconnect and queued-send flush', (
      tester,
    ) async {
      await _ensureResumed(tester);
      await _transition(tester, AppLifecycleState.inactive);
      final fixture = await _LifecycleFixture.create(queuedSend: true);
      addTearDown(fixture.dispose);

      await tester.pumpWidget(_host(fixture.scope));
      await _flushAsync(tester);
      expect(fixture.sockets, isEmpty);
      expect(fixture.http.posts, isEmpty);
      expect(fixture.client.queuedSendMessages, hasLength(1));

      await tester.pumpWidget(_host(const SizedBox.shrink()));
      await _pumpUntil(tester, () => fixture.session.isDisposed);
      await _transition(tester, AppLifecycleState.hidden);
      await _transition(tester, AppLifecycleState.paused);
      await _transition(tester, AppLifecycleState.detached);
      await _transition(tester, AppLifecycleState.resumed);
      fixture.clock.elapse(const Duration(days: 1));
      await _flushAsync(tester);

      expect(fixture.connectivity.cancelCount, 1);
      expect(fixture.sockets, isEmpty);
      expect(fixture.http.posts, isEmpty);
      expect(fixture.client.queuedSendMessages, hasLength(1));
      expect(tester.takeException(), isNull);
    });
  });
}

final class _LifecycleFixture {
  _LifecycleFixture._({
    required this.events,
    required this.clock,
    required this.network,
    required this.cursorStorage,
    required this.http,
    required this.connectivity,
    required this.store,
    required this.sockets,
    required this.session,
    required this.client,
    required bool ownsDisposableClient,
  }) : _ownsDisposableClient = ownsDisposableClient;

  static Future<_LifecycleFixture> create({
    bool seedReadState = false,
    bool queuedSend = false,
    bool queuedRead = false,
    String? initialCursor,
  }) async {
    final events = <String>[];
    final clock = FakeChatClock(DateTime.utc(2026, 8, 26, 20));
    final durableWork = queuedSend || queuedRead;
    final network = FakeChatRealtimeNetwork(isOnline: !durableWork);
    final cursorStorage = _CursorStorage(events, initialCursor);
    final http = _HttpTransport(events);
    final connectivity = _Connectivity();
    final store =
        seedReadState || queuedRead ? _readStore() : NormalizedSnapshotStore();
    final sockets = <_RecordingSocket>[];
    final session = ChatRealtimeSessionTransport(
      endpoint: Uri.parse('https://chat.example.test/api/chat'),
      clientPackageVersion: '0.1.3',
      protocolVersion: handrailChatProtocolVersion,
      tokenProvider: () => 'realtime-token',
      socketFactory: (_, __) {
        final socket = _RecordingSocket(events);
        sockets.add(socket);
        events.add('socket:open:${sockets.length}');
        return socket;
      },
      network: network,
      cursorStorage: cursorStorage,
      cursorStorageScope: 'login-a:device-1',
      clock: clock,
      ephemeralSignals: ChatRealtimeEphemeralSignalOptions(
        clock: clock,
        conversationVisibilityResolver: (_, requested) => requested,
      ),
      onStateChange: (state) => events.add('state:${state.state}'),
    );
    final storage = durableWork ? InMemoryApplicationChatStorage() : null;
    if (queuedRead) {
      await storage!.replace(
        ApplicationChatQueuedReadCursorIntentsRecord(
          identity: _storageIdentity,
          intents: [
            ApplicationChatQueuedReadCursorIntent(
              request: MarkReadInput(
                conversationId: _conversationId,
                throughSequence: const MessageSequence(7),
                idempotencyKey: 'retained-read-key',
              ),
              acknowledgedReadState: ConversationReadState(
                conversationId: _conversationId,
                userId: const UserId('user-1'),
                lastReadSequence: const MessageSequence(4),
                manualUnreadFromSequence: const MessageSequence(3),
                updatedAt: const IsoTimestamp('2026-08-26T20:00:00.000Z'),
              ),
              enqueueOrder: 1,
              enqueuedAt: const IsoTimestamp('2026-08-26T20:01:00.000Z'),
            ),
          ],
        ),
      );
    }
    final client = HandrailChatClient(
      apiBaseUri: Uri.parse('https://chat.example.test/api/chat'),
      tokenProvider: () async => 'access-token',
      transport: http,
      realtimeSession: session,
      localStorage: storage,
      storageIdentity: durableWork ? _storageIdentity : null,
      normalizedSnapshotStore: store,
      generateClientMessageId: () => 'client-queued',
      generateIdempotencyKey: () => 'key-queued',
      commandRetryOptions: const ChatCommandRetryOptions(maxAttempts: 1),
    );
    expect(await client.initialize(), isA<ChatClientReadyState>());
    if (queuedSend) {
      await client.activateStorageIdentity(_storageIdentity);
      final result = await client.sendMessage(
        ChatSendMessageInput(
          conversationId: _conversationId,
          content: MessageContent(
            format: MessageContentFormat.markdown,
            text: 'queued while offline',
          ),
        ),
      );
      expect(result, isA<ChatCommandQueued<SendMessageResult>>());
    }
    if (durableWork) {
      network.setOnline(true);
    }
    return _LifecycleFixture._(
      events: events,
      clock: clock,
      network: network,
      cursorStorage: cursorStorage,
      http: http,
      connectivity: connectivity,
      store: store,
      sockets: sockets,
      session: session,
      client: client,
      ownsDisposableClient: !durableWork,
    );
  }

  final List<String> events;
  final FakeChatClock clock;
  final FakeChatRealtimeNetwork network;
  final _CursorStorage cursorStorage;
  final _HttpTransport http;
  final _Connectivity connectivity;
  final NormalizedSnapshotStore store;
  final List<_RecordingSocket> sockets;
  final ChatRealtimeSessionTransport session;
  final HandrailChatClient client;
  final bool _ownsDisposableClient;

  ChatScope get scope => ChatScope(
        client: client,
        connectivityDelegate: connectivity,
        deviceIdentityDelegate: const _Identity(),
        identityScopeKey: 'login-a',
        realtimeSessionFactory: (_) => session,
        child: const SizedBox.shrink(),
      );

  Future<void> dispose() async {
    if (_ownsDisposableClient) await client.dispose();
    await session.dispose();
    await network.dispose();
    await connectivity.dispose();
    await store.close();
    clock.dispose();
  }
}

final class _Connectivity implements ChatConnectivityDelegate {
  _Connectivity() {
    _changes = StreamController<ChatConnectivityStatus>.broadcast(
      sync: true,
      onCancel: () => cancelCount += 1,
    );
  }

  late final StreamController<ChatConnectivityStatus> _changes;
  int cancelCount = 0;

  @override
  Stream<ChatConnectivityStatus> get connectivityChanges => _changes.stream;

  @override
  ChatConnectivityStatus getCurrentConnectivity() =>
      ChatConnectivityStatus.online;

  Future<void> dispose() => _changes.close();
}

final class _Identity implements ChatDeviceIdentityDelegate {
  const _Identity();

  @override
  String getOrCreateDeviceId({required Object? identityScopeKey}) => 'device-1';
}

final class _CursorStorage implements ChatRealtimeCursorStorage {
  _CursorStorage(this.events, String? cursor)
      : values = <String, String>{
          if (cursor != null)
            'login-a:device-1': jsonEncode({'eventId': cursor}),
        };

  final List<String> events;
  final Map<String, String> values;

  @override
  String? read({required String scope}) {
    events.add('cursor:read');
    return values[scope];
  }

  @override
  void write({required String scope, required String value}) {
    events.add('cursor:write');
    values[scope] = value;
  }

  @override
  void clear({required String scope}) {
    events.add('cursor:clear');
    values.remove(scope);
  }
}

final class _RecordingSocket implements ChatRealtimeSocket {
  _RecordingSocket(this.events);

  final List<String> events;
  final StreamController<Object?> _frames =
      StreamController<Object?>.broadcast(sync: true);
  final List<String> sent = <String>[];
  int closeCount = 0;

  @override
  Stream<Object?> get frames => _frames.stream;

  List<Map<String, Object?>> get sentJsonFrames => sent
      .map((frame) => (jsonDecode(frame) as Map).cast<String, Object?>())
      .toList(growable: false);

  List<Map<String, Object?>> get handshakes => sentJsonFrames
      .where((frame) => frame.containsKey('clientPackageVersion'))
      .toList(growable: false);

  @override
  void send(String data) {
    sent.add(data);
    final frame = (jsonDecode(data) as Map).cast<String, Object?>();
    if (frame.containsKey('clientPackageVersion')) {
      final resume = frame['resumeFrom'];
      final cursor = resume is Map ? resume['eventId'] : null;
      events.add('handshake:${cursor ?? 'none'}');
    }
  }

  void emitJson(Object value) => _frames.add(jsonEncode(value));

  void resetSends() => sent.clear();

  @override
  void close() {
    closeCount += 1;
  }
}

final class _HttpTransport implements HandrailChatHttpTransport {
  _HttpTransport(this.events);

  final List<String> events;
  final List<HandrailChatHttpRequest> requests = <HandrailChatHttpRequest>[];

  Iterable<HandrailChatHttpRequest> get posts =>
      requests.where((request) => request.method == 'POST');

  Iterable<HandrailChatHttpRequest> get patches =>
      requests.where((request) => request.method == 'PATCH');

  @override
  Future<HandrailChatHttpResponse> send(HandrailChatHttpRequest request) async {
    requests.add(request);
    if (request.method == 'GET') {
      return HandrailChatHttpResponse(
        statusCode: 200,
        body: jsonEncode(_metadata),
      );
    }
    final body = (jsonDecode(request.body!) as Map).cast<String, Object?>();
    if (request.method == 'PATCH') {
      events.add('read:flush');
      final sequence = body['throughSequence']! as int;
      return HandrailChatHttpResponse(
        statusCode: 200,
        body: jsonEncode({
          'operation': 'mark_read',
          'reconciliationStatus': 'replayed',
          'idempotencyKey': body['idempotencyKey'],
          'conversationId': body['conversationId'],
          'readState': {
            'conversationId': body['conversationId'],
            'userId': 'user-1',
            'lastReadSequence': sequence,
            'updatedAt': '2026-08-26T20:02:00.000Z',
          },
          'latestSequence': 8,
          'unreadCount': 8 - sequence,
        }),
      );
    }
    events.add('queue:flush');
    return HandrailChatHttpResponse(
      statusCode: 200,
      body: jsonEncode({
        'operation': 'send',
        'reconciliationStatus': 'applied',
        'clientMessageId': body['clientMessageId'],
        'message': _message(body['clientMessageId']! as String),
        'canonicalRevision': 1,
      }),
    );
  }
}

NormalizedSnapshotStore _readStore() => NormalizedSnapshotStore()
  ..hydrateConversationList(
    ConversationListSnapshot.fromJson({
      'kind': 'conversation_list',
      'scope': {'type': 'organization'},
      'items': [
        {
          'id': _conversationId.value,
          'tenantId': 'tenant-1',
          'type': 'channel',
          'name': 'Lifecycle',
          'visibility': 'public',
          'createdAt': '2026-08-26T20:00:00.000Z',
          'updatedAt': '2026-08-26T20:00:00.000Z',
          'latestSequence': 8,
          'activityAt': '2026-08-26T20:00:00.000Z',
          'unreadMentionCount': 0,
          'currentMember': {
            'tenantId': 'tenant-1',
            'conversationId': _conversationId.value,
            'userId': 'user-1',
            'role': 'member',
            'state': 'active',
            'joinedAt': '2026-08-26T20:00:00.000Z',
            'updatedAt': '2026-08-26T20:00:00.000Z',
          },
          'currentReadState': {
            'conversationId': _conversationId.value,
            'userId': 'user-1',
            'lastReadSequence': 4,
            'manualUnreadFromSequence': 3,
            'updatedAt': '2026-08-26T20:00:00.000Z',
          },
          'currentPreference': {
            'conversationId': _conversationId.value,
            'userId': 'user-1',
            'notificationPreference': 'mentions',
            'isStarred': false,
            'mute': {'muted': false},
            'updatedAt': '2026-08-26T20:00:00.000Z',
          },
          'activeMemberUserIds': ['user-1'],
        },
      ],
      'page': <String, Object?>{},
      '_meta': {
        ..._metadata,
        'feature': {
          'name': conversationSnapshotFeature,
          'version': conversationSnapshotVersion,
        },
      },
    }),
  );

Map<String, Object?> _acceptedFrame({
  String sessionId = 'session-1',
  String? resumeFrom,
}) =>
    {
      'type': 'chat.session.accepted',
      'metadata': _metadata,
      'tenantId': 'tenant-1',
      'actorStreamId': 'user:user-1',
      'deviceId': 'device-1',
      'sessionId': sessionId,
      if (resumeFrom != null) 'resumeFrom': {'eventId': resumeFrom},
    };

Map<String, Object?> _snapshotRequiredFrame(String cursor) => {
      'type': 'chat.session.snapshot_required',
      'state': 'snapshot_required',
      'reason': 'replay_expired',
      'metadata': _metadata,
      'resumeFrom': {'eventId': cursor},
    };

Map<String, Object?> _message(String clientMessageId) => {
      'id': 'message-1',
      'tenantId': 'tenant-1',
      'conversationId': _conversationId.value,
      'author': {'type': 'user', 'userId': 'user-1'},
      'sequence': 1,
      'createdAt': '2026-08-26T20:01:00.000Z',
      'updatedAt': '2026-08-26T20:01:00.000Z',
      'revision': {'revision': 1},
      'content': {'format': 'markdown', 'text': clientMessageId},
    };

const Map<String, Object?> _metadata = {
  'packageVersion': '0.1.3',
  'protocolVersion': handrailChatProtocolVersion,
  'schemaVersion': 1,
  'enabledFeatures': <String, Object?>{
    'realtime': true,
    'typing': true,
    'presence': true,
  },
  'supportedProtocolRange': <String, Object?>{
    'minimumVersion': 3,
    'maximumVersion': handrailChatProtocolVersion,
  },
};

Widget _host(Widget child) => Directionality(
      textDirection: TextDirection.ltr,
      child: child,
    );

Future<void> _transition(
  WidgetTester tester,
  AppLifecycleState state,
) async {
  tester.binding.handleAppLifecycleStateChanged(state);
  await _flushAsync(tester);
}

Future<void> _ensureResumed(WidgetTester tester) async {
  switch (tester.binding.lifecycleState) {
    case null:
      await _transition(tester, AppLifecycleState.resumed);
      return;
    case AppLifecycleState.resumed:
      return;
    case AppLifecycleState.inactive:
      await _transition(tester, AppLifecycleState.resumed);
      return;
    case AppLifecycleState.hidden:
      await _transition(tester, AppLifecycleState.inactive);
      await _transition(tester, AppLifecycleState.resumed);
      return;
    case AppLifecycleState.paused:
      await _transition(tester, AppLifecycleState.hidden);
      await _transition(tester, AppLifecycleState.inactive);
      await _transition(tester, AppLifecycleState.resumed);
      return;
    case AppLifecycleState.detached:
      await _transition(tester, AppLifecycleState.resumed);
      return;
  }
}

Future<void> _flushAsync(WidgetTester tester) async {
  await tester.runAsync(() async {
    for (var index = 0; index < 20; index += 1) {
      await Future<void>.delayed(Duration.zero);
    }
  });
  await tester.pump();
}

Future<void> _pumpUntil(
  WidgetTester tester,
  bool Function() condition,
) async {
  for (var index = 0; index < 100; index += 1) {
    if (condition()) return;
    await _flushAsync(tester);
  }
  fail('Timed out waiting for lifecycle test condition.');
}
