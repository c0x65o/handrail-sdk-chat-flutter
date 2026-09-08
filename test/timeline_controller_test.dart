import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:handrail_chat/core.dart';
import 'package:test/test.dart';

const _conversationId = ConversationId('conversation-timeline-controller');
const _tenantId = 'tenant-timeline-controller';
const _userId = 'user-current';
const _now = '2026-08-26T21:00:00.000Z';

void main() {
  for (final revoked in [false, true]) {
    for (final httpStatus in [200, 401, 403]) {
      test(
          'archived timeline rechecks HTTP after ${revoked ? "revocation" : "denial"} ($httpStatus)',
          () async {
        final socket = _FakeSocket();
        final realtime = _realtime(socket: socket);
        final transport = _TimelineTransport();
        final client = _client(transport, realtime: realtime);
        addTearDown(client.dispose);
        addTearDown(realtime.dispose);
        client.normalizedState.hydrateConversationDetail(
          ConversationDetailSnapshot.fromJson(
              _conversationDetailFixture(archived: true)),
        );
        final controller = client.timeline(_conversationId);
        final subscription = controller.states.listen((_) {});
        addTearDown(subscription.cancel);
        await controller.refresh();
        expect(controller.state.isReady, isTrue);
        await realtime.start();
        socket.emitJson(_acceptedFrame());
        await _waitFor(
            () => socket.sent.any((frame) => frame.contains("chat.subscribe")));
        final subscribe = socket.sent
            .map((frame) => jsonDecode(frame) as Map<String, Object?>)
            .firstWhere((frame) =>
                frame['type'] == 'chat.subscribe' &&
                frame['streamId'] == _conversationId.value);
        await controller.refresh();
        final readsBefore =
            transport.requests.where((r) => r.method == 'GET').length;
        transport.timelineStatus = httpStatus;
        if (revoked) {
          socket.emitJson({
            'type': 'chat.subscription.accepted',
            'requestId': subscribe['requestId'],
            'streamId': _conversationId.value
          });
        }
        socket.emitJson({
          'type': revoked
              ? 'chat.subscription.revoked'
              : 'chat.subscription.rejected',
          if (!revoked) 'requestId': subscribe['requestId'],
          if (revoked) 'streamId': _conversationId.value,
          'code': revoked ? 'access_revoked' : 'access_denied',
        });
        await Future<void>.delayed(const Duration(milliseconds: 30));
        expect(transport.requests.where((r) => r.method == 'GET').length,
            greaterThan(readsBefore));
        expect(
            controller.state.status,
            httpStatus == 200
                ? ChatTimelineControllerStatus.ready
                : ChatTimelineControllerStatus.accessRevoked);
        if (httpStatus == 200) {
          expect(controller.state.error, isNull);
          expect(_sequences(controller.state), [2, 3]);
        } else {
          expect(controller.state.error?.httpStatus, httpStatus);
          // A retry must not expose the cache before a successful read.
          transport.timelineStatus = 500;
          final failedRetry = controller.refresh();
          expect(controller.state.status,
              ChatTimelineControllerStatus.accessRevoked);
          await failedRetry;
          expect(controller.state.status,
              ChatTimelineControllerStatus.accessRevoked);
          transport.timelineStatus = 200;
          final recovery = controller.refresh();
          expect(controller.state.status,
              ChatTimelineControllerStatus.accessRevoked);
          await recovery;
          expect(controller.state.status, ChatTimelineControllerStatus.ready);
          expect(controller.state.error, isNull);
        }
      });
    }
  }

  test('hydrates initial, earlier, and newer pages with overlap deduplication',
      () async {
    final transport = _TimelineTransport();
    final client = _client(transport);
    final controller = client.timelines.forConversation(_conversationId);
    expect(client.timeline(_conversationId), same(controller));
    final states = <ChatTimelineControllerState>[];
    final subscription = controller.states.listen(states.add);

    await _waitFor(() => controller.state.isReady);
    expect(_sequences(controller.state), [2, 3]);
    expect(controller.state.hasEarlier, isTrue);
    expect(controller.state.hasNewer, isTrue);
    final initial = controller.state;
    expect(() => initial.messages.clear(), throwsUnsupportedError);

    await controller.loadEarlier();
    expect(_sequences(controller.state), [1, 2, 3]);
    expect(controller.state.hasEarlier, isFalse);
    expect(transport.timelineRequests.last.uri.queryParameters['before'], '2');

    await controller.loadNewer();
    expect(_sequences(controller.state), [1, 2, 3, 4]);
    expect(controller.state.hasNewer, isFalse);
    expect(transport.timelineRequests.last.uri.queryParameters['after'], '3');

    await controller.refresh();
    expect(_sequences(controller.state), [1, 2, 3, 4]);
    expect(_sequences(initial), [2, 3]);
    expect(states.where((state) => state.isReady), isNotEmpty);

    await subscription.cancel();
    await controller.dispose();
    await client.dispose();
  });

  test('coalesces concurrent pagination in each direction', () async {
    final earlier = Completer<HandrailChatHttpResponse>();
    final transport = _TimelineTransport(earlierResponse: earlier);
    final client = _client(transport);
    final controller = client.timeline(_conversationId);
    final subscription = controller.states.listen((_) {});
    await _waitFor(() => controller.state.isReady);

    final first = controller.loadEarlier();
    final second = controller.loadEarlier();
    expect(identical(first, second), isTrue);
    await _waitFor(() => transport.earlierRequestCount == 1);
    earlier.complete(_response(
      200,
      _timelineFixture(messages: [_messageFixture(1)], newer: 1),
    ));
    await Future.wait([first, second]);

    expect(transport.earlierRequestCount, 1);
    expect(_sequences(controller.state), [1, 2, 3]);
    await subscription.cancel();
    await controller.dispose();
    await client.dispose();
  });

  test('projects unread state and typing, then applies a durable live event',
      () async {
    final transport = _TimelineTransport();
    final client = _client(transport);
    client.normalizedState.hydrateConversationDetail(
      ConversationDetailSnapshot.fromJson(_conversationDetailFixture()),
    );
    final controller = client.timeline(_conversationId);
    final subscription = controller.states.listen((_) {});
    await _waitFor(() => controller.state.isReady);

    expect(controller.state.currentUserReadState?.lastReadSequence.value, 3);
    expect(controller.state.unreadBoundary, const MessageSequence(2));
    expect(controller.state.firstUnreadMessage?.sequence.value, 2);

    final sentAt = DateTime.now().toUtc();
    expect(client.applyEphemeralSignal(_typingSignal(sentAt)), isTrue);
    expect(controller.state.typingSignals, hasLength(1));
    expect(controller.state.typingUserIds, const [UserId('user-typing')]);
    expect(
        () => controller.state.typingSignals.clear(), throwsUnsupportedError);

    final reduction = client.reduceDurableEvent(_createdEvent(4));
    expect(reduction.status, DurableEventReductionStatus.applied);
    expect(_sequences(controller.state), [2, 3, 4]);

    await subscription.cancel();
    await controller.dispose();
    await client.dispose();
  });

  test('delegates message, thread, and read-visibility commands', () async {
    final transport = _TimelineTransport(commandStatus: 400);
    final client = _client(
      transport,
      readVisibilityMinimumExposure: Duration.zero,
    );
    final controller = client.timeline(_conversationId);
    await controller.refresh();
    client.normalizedState.hydrateConversationDetail(
      ConversationDetailSnapshot.fromJson(_conversationDetailFixture()),
    );
    transport.requests.clear();

    final content = MessageContent(
      format: MessageContentFormat.plain,
      text: 'delegated',
    );
    await controller.send(content);
    await controller.edit(
      messageId: const MessageId('message-2'),
      expectedRevision: 1,
      content: content,
      idempotencyKey: 'timeline-edit-key',
    );
    await controller.delete(
      messageId: const MessageId('message-2'),
      expectedRevision: 1,
      idempotencyKey: 'timeline-delete-key',
    );
    await controller.setReaction(
      messageId: const MessageId('message-2'),
      reactionKey: 'thumbsup',
      reactedByCurrentUser: true,
      idempotencyKey: 'timeline-reaction-key',
    );
    await controller.openThread(const MessageId('message-2'));

    client.reads.setApplicationForeground(true);
    client.reads.setConversationActive(_conversationId, isActive: true);
    controller.reportVisibleThrough(const MessageSequence(3));
    await _waitFor(() => transport.requests.length >= 6);

    expect(
      transport.requests.map((request) => request.method),
      containsAll(<String>['POST', 'PATCH', 'DELETE']),
    );
    expect(
      transport.requests.map((request) => request.uri.path),
      containsAll(<String>[
        '/api/chat/conversations/${_conversationId.value}/messages',
        '/api/chat/messages/message-2',
        '/api/chat/messages/message-2/reactions/thumbsup',
        '/api/chat/messages/message-2/thread',
        '/api/chat/conversations/${_conversationId.value}/read-cursor',
      ]),
    );

    await controller.dispose();
    await client.dispose();
  });

  test('maps HTTP and realtime denial, retains once, and disposes safely',
      () async {
    final deniedClient = _client(_TimelineTransport(timelineStatus: 403));
    final denied = deniedClient.timeline(_conversationId);
    expect((await denied.refresh()).status,
        ChatTimelineControllerStatus.accessRevoked);
    expect(denied.state.error?.httpStatus, 403);
    await denied.dispose();
    await deniedClient.dispose();

    final socket = _FakeSocket();
    final subscriptionStates = <ChatRealtimeConversationSubscriptionState>[];
    final realtime = _realtime(
      socket: socket,
      onSubscriptionState: subscriptionStates.add,
    );
    final client = _client(_TimelineTransport(), realtime: realtime);
    final controller = client.timeline(_conversationId);
    final retain = controller.retain();
    final first = controller.states.listen((_) {});
    final second = controller.states.listen((_) {});
    await _waitFor(() => controller.state.isReady);
    expect(
      subscriptionStates
          .whereType<ChatRealtimeConversationSubscriptionPendingState>(),
      hasLength(1),
    );

    await realtime.start();
    socket.emitJson(_acceptedFrame());
    await _waitFor(() => socket.sent.any((frame) {
          final value = jsonDecode(frame) as Map<String, Object?>;
          return value['type'] == 'chat.subscribe' &&
              value['streamId'] == _conversationId.value;
        }));
    final subscribe = socket.sent
        .map((frame) => jsonDecode(frame) as Map<String, Object?>)
        .firstWhere((frame) =>
            frame['type'] == 'chat.subscribe' &&
            frame['streamId'] == _conversationId.value);
    socket.emitJson({
      'type': 'chat.subscription.accepted',
      'requestId': subscribe['requestId'],
      'streamId': _conversationId.value,
    });
    await _waitFor(() => subscriptionStates.any(
        (state) => state is ChatRealtimeConversationSubscriptionAcceptedState));
    socket.emitJson({
      'type': 'chat.subscription.revoked',
      'streamId': _conversationId.value,
      'code': 'access_revoked',
    });
    await _waitFor(() =>
        controller.state.status == ChatTimelineControllerStatus.accessRevoked);
    expect(controller.state.error?.realtimeCode,
        ChatRealtimeSubscriptionErrorCode.accessRevoked);

    await first.cancel();
    await second.cancel();
    expect(
      subscriptionStates
          .whereType<ChatRealtimeConversationSubscriptionRemovedState>(),
      isEmpty,
    );
    retain.release();
    retain.release();
    await _waitFor(() =>
        socket.sent.where((frame) {
          final value = jsonDecode(frame) as Map<String, Object?>;
          return value['type'] == 'chat.unsubscribe' &&
              value['streamId'] == _conversationId.value;
        }).length ==
        1);

    final beforeDispose = controller.state;
    await controller.dispose();
    await controller.dispose();
    expect(controller.state.status, ChatTimelineControllerStatus.disposed);
    expect(_sequences(beforeDispose), [2, 3]);
    expect(await controller.refresh(), same(controller.state));
    expect(() => controller.retain(), throwsStateError);
    await client.dispose();
    await realtime.dispose();
  });

  test('ignores a timeline completion that arrives after disposal', () async {
    final pending = Completer<HandrailChatHttpResponse>();
    final transport = _TimelineTransport(initialResponse: pending);
    final client = _client(transport);
    final controller = client.timeline(_conversationId);
    final refresh = controller.refresh();
    await _waitFor(() => transport.timelineRequests.isNotEmpty);
    await controller.dispose();
    pending.complete(_response(
      200,
      _timelineFixture(messages: [_messageFixture(2), _messageFixture(3)]),
    ));
    await refresh;
    expect(controller.state.status, ChatTimelineControllerStatus.disposed);
    await client.dispose();
  });

  test('controller source stays inside the pure-Dart public boundary',
      () async {
    final source =
        await File('lib/src/core/timeline_controller.dart').readAsString();
    expect(source, isNot(contains('package:flutter')));
  });
}

HandrailChatClient _client(
  _TimelineTransport transport, {
  ChatRealtimeSessionTransport? realtime,
  Duration readVisibilityMinimumExposure = const Duration(milliseconds: 500),
}) =>
    HandrailChatClient(
      apiBaseUri: Uri.parse('https://chat.test/api/chat'),
      tokenProvider: () async => 'timeline-token',
      transport: transport,
      realtimeSession: realtime,
      readVisibilityMinimumExposure: readVisibilityMinimumExposure,
      generateClientMessageId: () => 'timeline-client-message',
      generateIdempotencyKey: _IdGenerator().next,
    );

final class _IdGenerator {
  var value = 0;
  String next() => 'timeline-key-${value += 1}';
}

final class _TimelineTransport implements HandrailChatHttpTransport {
  _TimelineTransport({
    this.timelineStatus = 200,
    this.commandStatus = 400,
    this.initialResponse,
    this.earlierResponse,
  });

  int timelineStatus;
  final int commandStatus;
  final Completer<HandrailChatHttpResponse>? initialResponse;
  final Completer<HandrailChatHttpResponse>? earlierResponse;
  final List<HandrailChatHttpRequest> requests = [];

  List<HandrailChatHttpRequest> get timelineRequests => requests
      .where((request) =>
          request.method == 'GET' && request.uri.path.endsWith('/messages'))
      .toList(growable: false);

  int get earlierRequestCount => timelineRequests
      .where((request) => request.uri.queryParameters.containsKey('before'))
      .length;

  @override
  Future<HandrailChatHttpResponse> send(HandrailChatHttpRequest request) async {
    requests.add(request);
    if (request.method != 'GET' || !request.uri.path.endsWith('/messages')) {
      return _response(commandStatus, const {'error': 'fixture rejection'});
    }
    if (timelineStatus != 200) {
      return HandrailChatHttpResponse(
        statusCode: timelineStatus,
        body: 'not inspected',
      );
    }
    if (request.uri.queryParameters['before'] case final before?) {
      if (earlierResponse != null) return earlierResponse!.future;
      expect(before, '2');
      return _response(
        200,
        _timelineFixture(messages: [_messageFixture(1)], newer: 1),
      );
    }
    if (request.uri.queryParameters['after'] case final after?) {
      expect(after, '3');
      return _response(
        200,
        _timelineFixture(messages: [_messageFixture(4)], older: 4),
      );
    }
    if (initialResponse != null) return initialResponse!.future;
    return _response(
      200,
      _timelineFixture(
        messages: [_messageFixture(2), _messageFixture(3)],
        older: 2,
        newer: 3,
      ),
    );
  }
}

HandrailChatHttpResponse _response(int statusCode, Object body) =>
    HandrailChatHttpResponse(
      statusCode: statusCode,
      body: jsonEncode(body),
    );

Map<String, Object?> _timelineFixture({
  required List<Map<String, Object?>> messages,
  int? older,
  int? newer,
}) =>
    {
      'conversationId': _conversationId.value,
      'messages': messages,
      'pagination': {
        'older': older == null
            ? {'available': false}
            : {'available': true, 'cursor': older},
        'newer': newer == null
            ? {'available': false}
            : {'available': true, 'cursor': newer},
      },
      'replay': {
        'resumeFrom': {'eventId': 'timeline-snapshot-event'},
      },
    };

Map<String, Object?> _messageFixture(int sequence) => {
      ..._canonicalMessageFixture(sequence),
      'isThreadRoot': false,
      'reactions': <Object?>[],
      'attachmentMetadata': <Object?>[],
    };

Map<String, Object?> _canonicalMessageFixture(int sequence) => {
      'id': 'message-$sequence',
      'tenantId': _tenantId,
      'conversationId': _conversationId.value,
      'author': {'type': 'user', 'userId': 'user-$sequence'},
      'sequence': sequence,
      'createdAt': _now,
      'updatedAt': _now,
      'revision': {'revision': 1},
      'content': {'format': 'plain', 'text': 'message $sequence'},
    };

Map<String, Object?> _conversationDetailFixture({bool archived = false}) => {
      'kind': 'conversation_detail',
      'conversation': {
        'id': _conversationId.value,
        'tenantId': _tenantId,
        'type': 'channel',
        'name': 'Timeline fixture',
        if (archived) 'archivedAt': _now,
        if (archived) 'archivedByUserId': _userId,
        'visibility': 'public',
        'createdAt': _now,
        'updatedAt': _now,
        'latestSequence': 3,
        'activityAt': _now,
        'unreadMentionCount': 0,
        'currentMember': {
          'tenantId': _tenantId,
          'conversationId': _conversationId.value,
          'userId': _userId,
          'role': 'member',
          'state': 'active',
          'joinedAt': _now,
          'updatedAt': _now,
        },
        'currentReadState': {
          'conversationId': _conversationId.value,
          'userId': _userId,
          'lastReadSequence': 3,
          'manualUnreadFromSequence': 2,
          'updatedAt': _now,
        },
        'currentPreference': {
          'conversationId': _conversationId.value,
          'userId': _userId,
          'notificationPreference': 'all',
          'isStarred': false,
          'mute': {'muted': false},
          'updatedAt': _now,
        },
        'activeMemberUserIds': [_userId],
        'memberUserIds': [_userId, 'user-typing'],
      },
      '_meta': {
        'packageVersion': '0.1.3',
        'protocolVersion': 4,
        'schemaVersion': 9,
        'enabledFeatures': {conversationSnapshotFeature: true},
        'supportedProtocolRange': {
          'minimumVersion': 3,
          'maximumVersion': 4,
        },
        'feature': {
          'name': conversationSnapshotFeature,
          'version': conversationSnapshotVersion,
        },
      },
    };

TypingSignalEvent _typingSignal(DateTime sentAt) => TypingSignalEvent(
      eventId: 'typing-timeline',
      protocolVersion: 4,
      tenantId: const TenantId(_tenantId),
      streamId: _conversationId,
      occurredAt: IsoTimestamp(sentAt.toIso8601String()),
      payload: TypingSignalPayload(
        actorUserId: const UserId('user-typing'),
        deviceId: const DeviceId('device-typing'),
        sessionId: const SessionId('session-typing'),
        sequence: 1,
        sentAt: IsoTimestamp(sentAt.toIso8601String()),
        expiresAt: IsoTimestamp(
          sentAt.add(const Duration(minutes: 1)).toIso8601String(),
        ),
        state: TypingSignalState.start,
        scope: const PublicConversationSignalScope(_conversationId),
      ),
    );

KnownDurableEvent _createdEvent(int sequence) => KnownDurableEvent.fromJson(
      {
        'eventId': 'created-$sequence',
        'protocolVersion': handrailChatDurableEventProtocolVersion,
        'tenantId': _tenantId,
        'streamId': _conversationId.value,
        'type': 'message.created',
        'occurredAt': _now,
        'payload': {
          'message': _canonicalMessageFixture(sequence),
          'clientMessageId': 'live-client-$sequence',
        },
      },
      trustedIdentity: const DurableEventTrustedIdentity(
        tenantId: TenantId(_tenantId),
        userId: UserId(_userId),
      ),
    );

ChatRealtimeSessionTransport _realtime({
  required _FakeSocket socket,
  ChatRealtimeConversationSubscriptionListener? onSubscriptionState,
}) =>
    ChatRealtimeSessionTransport(
      endpoint: Uri.parse('https://chat.test/api/chat'),
      clientPackageVersion: '0.1.3',
      protocolVersion: 4,
      tokenProvider: () async => 'realtime-token',
      socketFactory: (_, __) => socket,
      onConversationSubscriptionStateChange: onSubscriptionState,
    );

final class _FakeSocket implements ChatRealtimeSocket {
  final StreamController<Object?> _frames =
      StreamController<Object?>.broadcast(sync: true);
  final List<String> sent = [];

  @override
  Stream<Object?> get frames => _frames.stream;

  @override
  void send(String data) => sent.add(data);

  @override
  void close() {}

  void emitJson(Map<String, Object?> value) => _frames.add(jsonEncode(value));
}

Map<String, Object?> _acceptedFrame() => {
      'type': 'chat.session.accepted',
      'metadata': {
        'packageVersion': '0.1.3',
        'protocolVersion': 4,
        'schemaVersion': 1,
        'enabledFeatures': {'typing': true},
        'supportedProtocolRange': {
          'minimumVersion': 3,
          'maximumVersion': 4,
        },
      },
      'tenantId': _tenantId,
      'actorStreamId': 'user:$_userId',
      'deviceId': 'device-timeline',
      'sessionId': 'session-timeline',
    };

List<int> _sequences(ChatTimelineControllerState state) =>
    state.messages.map((message) => message.sequence.value).toList();

Future<void> _pump([int count = 1]) async {
  for (var index = 0; index < count; index += 1) {
    await Future<void>.delayed(Duration.zero);
  }
}

Future<void> _waitFor(bool Function() predicate) async {
  for (var index = 0; index < 200 && !predicate(); index += 1) {
    await _pump();
  }
  expect(predicate(), isTrue, reason: 'Asynchronous work did not settle.');
}
