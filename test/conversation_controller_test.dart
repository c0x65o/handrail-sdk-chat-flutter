import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:handrail_chat/testing.dart';
import 'package:test/test.dart';

const _conversationId = ConversationId('conversation-controller');
const _tenantId = 'tenant-controller';
const _userId = 'user-controller';
const _now = '2026-08-26T20:00:00.000Z';
const _entity = HostEntityReference(type: 'project', id: 'project-42');

void main() {
  for (final revoked in [false, true]) {
    for (final httpStatus in [200, 401, 403]) {
      test(
          'archived conversation rechecks HTTP after ${revoked ? "revocation" : "denial"} ($httpStatus)',
          () async {
        final socket = _FakeSocket();
        final realtime = _realtime(socket: socket);
        final transport = _FixtureTransport(archived: true);
        final client = _client(transport, realtime: realtime);
        addTearDown(client.dispose);
        addTearDown(realtime.dispose);

        final controller = client.conversations.forId(_conversationId);
        final subscription = controller.states.listen((_) {});
        addTearDown(subscription.cancel);
        await controller.refresh();
        expect(controller.state.isReady, isTrue);
        await realtime.start();
        socket.emitJson(_acceptedFrame());
        await _pump(4);
        final subscribe = socket.sent
            .map((frame) => jsonDecode(frame) as Map<String, Object?>)
            .firstWhere((frame) =>
                frame['type'] == 'chat.subscribe' &&
                frame['streamId'] == _conversationId.value);
        await controller.refresh();
        final readsBefore =
            transport.requests.where((r) => r.method == 'GET').length;
        transport.detailStatus = httpStatus;
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
        await _pump(10);
        expect(transport.requests.where((r) => r.method == 'GET').length,
            greaterThan(readsBefore));
        expect(
            controller.state.status,
            httpStatus == 200
                ? ChatConversationControllerStatus.ready
                : ChatConversationControllerStatus.accessRevoked);
        if (httpStatus == 200) {
          expect(controller.state.error, isNull);
          expect(controller.state.conversation?.archivedAt, isNotNull);
        } else {
          expect(controller.state.error?.httpStatus, httpStatus);
          // A retry must not expose the cache before a successful read.
          transport.detailStatus = 500;
          final failedRetry = controller.refresh();
          expect(controller.state.status,
              ChatConversationControllerStatus.accessRevoked);
          await failedRetry;
          expect(controller.state.status,
              ChatConversationControllerStatus.accessRevoked);
          transport.detailStatus = 200;
          final recovery = controller.refresh();
          expect(controller.state.status,
              ChatConversationControllerStatus.accessRevoked);
          await recovery;
          expect(controller.state.status, ChatConversationControllerStatus.ready);
          expect(controller.state.error, isNull);
        }
      });
    }
  }

  test('a fresh conversation controller restores the actor-private draft',
      () async {
    final transport = _FixtureTransport();
    final client = _client(transport);
    final controller = client.conversations.forId(_conversationId);
    addTearDown(client.dispose);

    await controller.refresh();

    expect(controller.state.draft?.revision, 4);
    expect(
        (controller.state.draft?.draft as CanonicalReplacedDraft).content.text,
        'QA 298e20b4 durable draft');
  });

  test('clear tombstones and never-authored drafts restore without text',
      () async {
    for (final revision in [0, 5]) {
      final client = _client(_FixtureTransport(
          draftSnapshot: () async => {
                ..._draftSnapshot(),
                'state': 'absent',
                'canonicalRevision': revision,
                'canonicalUpdatedAt': revision == 0 ? null : _now,
                'content': null,
              }));
      await client.conversations.forId(_conversationId).refresh();
      expect(client.draftFor(_conversationId)?.revision, revision);
      expect(client.draftFor(_conversationId)?.draft,
          isA<CanonicalClearDraftTombstone>());
      await client.dispose();
    }
  });

  test('malformed or wrong-conversation private snapshots are rejected',
      () async {
    for (final change in <Map<String, Object?>>[
      {'conversationId': 'another-conversation'},
      {'privacy': 'shared'},
      {'canonicalRevision': -1},
      {'canonicalRevision': 0},
      {'canonicalUpdatedAt': null},
      {'canonicalUpdatedAt': 'not-a-timestamp'},
      {'canonicalUpdatedAt': '2026-08-26'},
      {
        'content': {'privacy': 'shared', 'value': {}}
      },
      {'state': 'absent'},
      {'unexpected': true},
    ]) {
      final client = _client(_FixtureTransport(
          draftSnapshot: () async => {
                ..._draftSnapshot(),
                ...change,
              }));
      expect(await client.loadDraft(_conversationId),
          isA<ChatSnapshotQueryMalformedResponse<ChatDraftProjection>>());
      expect(client.draftFor(_conversationId), isNull);
      await client.dispose();
    }
  });

  test('an older snapshot cannot replace a newer canonical draft', () async {
    final pending = Completer<Map<String, Object?>>();
    var reads = 0;
    final client = _client(_FixtureTransport(draftSnapshot: () async {
      if (++reads == 1) return pending.future;
      return {..._draftSnapshot(), 'canonicalRevision': 6};
    }));
    final oldRead = client.loadDraft(_conversationId);
    await _pump();
    await client.loadDraft(_conversationId);
    pending.complete(_draftSnapshot());
    await oldRead;
    expect(client.draftFor(_conversationId)?.revision, 6);
    await client.dispose();
  });

  test('a snapshot preserves an unsynchronized local draft', () async {
    final client = _client(_FixtureTransport());
    client.setApplicationForeground(false);
    final write = client.synchronizeDraft(ChatReplaceDraftInput(
      conversationId: _conversationId,
      baseRevision: 4,
      content: DraftContent(
          format: DraftTextFormat.plain,
          text: 'new local text',
          attachments: const []),
    ));
    await client.loadDraft(_conversationId);
    expect(
        (client.draftFor(_conversationId)?.draft as CanonicalReplacedDraft)
            .content
            .text,
        'new local text');
    expect(client.draftFor(_conversationId)?.isPending, isTrue);
    await client.dispose();
    await write;
  });

  test('late private draft reads cannot cross actor changes or disposal',
      () async {
    for (final dispose in [false, true]) {
      final pending = Completer<Map<String, Object?>>();
      final storage = InMemoryApplicationChatStorage();
      final client = HandrailChatClient(
        apiBaseUri: Uri.parse('https://chat.test/api/chat'),
        tokenProvider: () async => 'token',
        transport: _FixtureTransport(draftSnapshot: () => pending.future),
        localStorage: storage,
      );
      await client.activateStorageIdentity(ApplicationChatStorageIdentity(
        tenantId: const TenantId(_tenantId),
        userId: const UserId('alice'),
        deviceId: const DeviceId('browser'),
      ));
      final read = client.loadDraft(_conversationId);
      await _pump();
      if (dispose) {
        await client.dispose();
      } else {
        await client.activateStorageIdentity(ApplicationChatStorageIdentity(
          tenantId: const TenantId(_tenantId),
          userId: const UserId('bob'),
          deviceId: const DeviceId('browser'),
        ));
      }
      pending.complete(_draftSnapshot());
      expect(await read, isA<ChatSnapshotQueryAborted<ChatDraftProjection>>());
      expect(client.draftFor(_conversationId), isNull);
      await client.dispose();
    }
  });

  group('ChatConversationController resolution and state', () {
    test('resolves direct ID and host entity to canonical immutable state',
        () async {
      final directTransport = _FixtureTransport();
      final directClient = _client(directTransport);
      final direct = directClient.conversations.forId(_conversationId);

      final directState = await direct.refresh();

      expect(directState.status, ChatConversationControllerStatus.ready);
      expect(directState.conversationId, _conversationId);
      expect(directState.conversation?.id, _conversationId);
      expect(directState.currentUserReadState?.lastReadSequence.value, 11);
      expect(directState.currentUserPreference?.notificationPreference,
          'mentions');
      expect(directState.memberUserIds, hasLength(2));
      expect(() => directState.memberUserIds.add(const UserId('nope')),
          throwsUnsupportedError);
      expect(
        identical(
          direct,
          directClient.conversations.forConversation(_conversationId),
        ),
        isTrue,
      );

      final entityTransport = _FixtureTransport(
        entityConversationIds: const ['conversation-z', 'conversation-a'],
      );
      final entityClient = _client(entityTransport);
      final entity = entityClient.conversations.forEntity(_entity);

      final entityState = await entity.refresh();

      expect(entityState.status, ChatConversationControllerStatus.ready);
      expect(entityState.requestedEntity?.toJson(), _entity.toJson());
      expect(
          entityState.conversationId, const ConversationId('conversation-a'));
      expect(
        identical(entity, entityClient.conversations.forEntity(_entity)),
        isTrue,
      );
      expect(entityTransport.requests.map((request) => request.method),
          ['GET', 'GET', 'GET']);
      await direct.dispose();
      await entity.dispose();
      await directClient.dispose();
      await entityClient.dispose();
    });

    test('is current-first and suppresses structurally unchanged state',
        () async {
      final transport = _FixtureTransport();
      final client = _client(transport);
      final controller = client.conversations.forId(_conversationId);
      final states = <ChatConversationControllerState>[];
      final initial = controller.state;
      final subscription = controller.states.listen(states.add);

      await _pump();
      expect(states.first, same(initial));
      await _waitFor(() => controller.state.isReady);
      final readyCount = states.length;
      final immutable = controller.state;

      client.normalizedState.hydrateConversationDetail(
        ConversationDetailSnapshot.fromJson(
            _detailFixture(_conversationId.value)),
      );
      await _pump();

      expect(states, hasLength(readyCount));
      expect(immutable, equals(controller.state));
      await subscription.cancel();
      await controller.dispose();
      await client.dispose();
    });

    test('projects conversation typing and only relevant member presence',
        () async {
      final client = _client(_FixtureTransport());
      final controller = client.conversations.forId(_conversationId);
      final states = <ChatConversationControllerState>[];
      final subscription = controller.states.listen(states.add);
      await _waitFor(() => controller.state.isReady);
      final sentAt = DateTime.now().toUtc();

      expect(
        client.applyEphemeralSignal(_typingSignal(sentAt)),
        isTrue,
      );
      expect(
        client.applyEphemeralSignal(
          _presenceSignal(sentAt, scopedUserId: 'user-other'),
        ),
        isTrue,
      );
      expect(controller.state.typing, hasLength(1));
      expect(controller.state.presence, hasLength(1));
      expect(() => controller.state.typing.clear(), throwsUnsupportedError);

      final visibleCount = states.length;
      expect(
        client.applyEphemeralSignal(
          _presenceSignal(sentAt, scopedUserId: 'unrelated-user'),
        ),
        isTrue,
      );
      expect(states, hasLength(visibleCount));

      await subscription.cancel();
      await controller.dispose();
      await client.dispose();
    });

    test('surfaces not-found, access-revoked, and query error outcomes',
        () async {
      for (final entry in <int, ChatConversationControllerStatus>{
        404: ChatConversationControllerStatus.notFound,
        403: ChatConversationControllerStatus.accessRevoked,
        500: ChatConversationControllerStatus.error,
      }.entries) {
        final transport = _FixtureTransport(detailStatus: entry.key);
        final client = _client(transport);
        final controller = client.conversations.forId(_conversationId);
        final state = await controller.refresh();
        expect(state.status, entry.value, reason: 'HTTP ${entry.key}');
        if (entry.key != 404) expect(state.error, isNotNull);
        await controller.dispose();
        await client.dispose();
      }

      final emptyTransport = _FixtureTransport(entityConversationIds: const []);
      final emptyClient = _client(emptyTransport);
      final empty =
          await emptyClient.conversations.forEntity(_entity).refresh();
      expect(empty.status, ChatConversationControllerStatus.notFound);
      await emptyClient.conversations.dispose();
      await emptyClient.dispose();
    });
  });

  group('ChatConversationController listener lifecycle', () {
    test('retains once for concurrent consumers and releases after the last',
        () async {
      final subscriptionStates = <ChatRealtimeConversationSubscriptionState>[];
      final realtime = _realtime(
        onSubscriptionState: subscriptionStates.add,
      );
      final client = _client(_FixtureTransport(), realtime: realtime);
      final controller = client.conversations.forId(_conversationId);

      final first = controller.states.listen((_) {});
      final second = controller.states.listen((_) {});
      await _pump();

      expect(
        subscriptionStates
            .whereType<ChatRealtimeConversationSubscriptionPendingState>(),
        hasLength(1),
      );
      await first.cancel();
      expect(
        subscriptionStates
            .whereType<ChatRealtimeConversationSubscriptionRemovedState>(),
        isEmpty,
      );
      await second.cancel();
      expect(
        subscriptionStates
            .whereType<ChatRealtimeConversationSubscriptionRemovedState>(),
        hasLength(1),
      );

      await controller.dispose();
      await controller.dispose();
      expect(
          controller.state.status, ChatConversationControllerStatus.disposed);
      expect(realtime.isDisposed, isFalse);
      expect(client.normalizedState.conversation(_conversationId), isNotNull);
      await client.dispose();
      await realtime.dispose();
    });

    test('surfaces a realtime access revocation as stable controller state',
        () async {
      final socket = _FakeSocket();
      final realtime = _realtime(socket: socket);
      final client = _client(_FixtureTransport(), realtime: realtime);
      final controller = client.conversations.forId(_conversationId);
      final subscription = controller.states.listen((_) {});
      await realtime.start();
      socket.emitJson(_acceptedFrame());
      await _pump(4);
      final subscribe = socket.sent
          .map((frame) => jsonDecode(frame) as Map<String, Object?>)
          .firstWhere(
            (frame) =>
                frame['type'] == 'chat.subscribe' &&
                frame['streamId'] == _conversationId.value,
          );
      socket.emitJson({
        'type': 'chat.subscription.accepted',
        'requestId': subscribe['requestId'],
        'streamId': _conversationId.value,
      });
      await _pump(2);
      socket.emitJson({
        'type': 'chat.subscription.revoked',
        'code': 'access_revoked',
        'streamId': _conversationId.value,
      });
      await _pump(4);

      expect(controller.state.status,
          ChatConversationControllerStatus.accessRevoked);
      expect(controller.state.error?.realtimeCode,
          ChatRealtimeSubscriptionErrorCode.accessRevoked);
      await _pump();
      expect(controller.state.status,
          ChatConversationControllerStatus.accessRevoked);

      await subscription.cancel();
      await controller.dispose();
      await client.dispose();
      await realtime.dispose();
    });
  });

  test('delegates every conversation command family through public APIs',
      () async {
    final transport = _FixtureTransport(commandStatus: 500);
    final realtime = _realtime();
    final client = _client(transport, realtime: realtime);
    final controller = client.conversations.forId(_conversationId);
    await controller.refresh();
    transport.requests.clear();

    await controller.archive(expectedLifecycleRevision: 1);
    await controller.restore(expectedLifecycleRevision: 1);
    await controller.addMember(
      userId: const UserId('user-added'),
      role: ConversationMembershipMemberRole.member,
      expectedMemberListRevision: 1,
    );
    await controller.updateMemberRole(
      userId: const UserId('user-added'),
      role: ConversationMembershipMemberRole.moderator,
      expectedMemberListRevision: 1,
    );
    await controller.removeMember(
      userId: const UserId('user-added'),
      expectedMemberListRevision: 1,
    );
    await controller.updatePreferences(
      notificationPreference: ConversationNotificationPreference.all,
      mute: const UnmutedConversationPreference(),
      isStarred: false,
    );
    final content = DraftContent(
      format: DraftTextFormat.plain,
      text: 'controller draft',
      attachments: const [],
    );
    await controller.synchronizeDraft(content: content, baseRevision: 0);
    await controller.clearDraft(baseRevision: 0);
    await controller.markRead(const MessageSequence(12));
    await controller.markUnread(const MessageSequence(11));
    client.normalizedState.reconcileMessage(Message.fromJson({
      'id': 'root-message',
      'tenantId': _tenantId,
      'conversationId': _conversationId.value,
      'author': {'type': 'user', 'userId': _userId},
      'sequence': 1,
      'createdAt': _now,
      'updatedAt': _now,
      'revision': {'revision': 1},
      'content': {'format': 'plain', 'text': 'root'},
    }));
    await controller.openThread(const MessageId('root-message'));
    final upload = controller.uploadAttachment(
      metadata: AttachmentMetadata(
        fileName: 'note.txt',
        contentType: 'text/plain',
        sizeBytes: 1,
      ),
      source: Stream.value(const [65]),
    );
    await upload.completion;
    expect(controller.startTyping(), isFalse);
    controller.stopTyping();
    controller.setPresence(PresenceSignalState.away);
    controller.notifyActivity();
    expect(controller.huddle,
        same(client.huddles.forConversation(_conversationId)));

    final paths =
        transport.requests.map((request) => request.uri.path).toList();
    expect(paths,
        contains('/api/chat/conversations/${_conversationId.value}/lifecycle'));
    expect(
      paths.where((path) => path.endsWith('/membership')),
      hasLength(greaterThanOrEqualTo(3)),
    );
    expect(
        paths,
        contains(
            '/api/chat/conversations/${_conversationId.value}/preference'));
    expect(
      paths.where((path) => path.endsWith('/draft')),
      hasLength(greaterThanOrEqualTo(2)),
    );
    expect(
      paths.where((path) => path.endsWith('/read-cursor')),
      hasLength(greaterThanOrEqualTo(2)),
    );
    expect(paths, contains('/api/chat/messages/root-message/thread'));
    expect(
      paths,
      contains('/api/chat/conversations/${_conversationId.value}/attachments'),
    );

    await controller.dispose();
    await client.dispose();
    await realtime.dispose();
  });

  test('controller source stays pure Dart and uses public selectors', () async {
    final source = await File(
      'lib/src/core/conversation_controller.dart',
    ).readAsString();
    expect(source, isNot(contains('package:flutter')));
    expect(source, isNot(contains('normalizedState.state')));
  });
}

HandrailChatClient _client(
  _FixtureTransport transport, {
  ChatRealtimeSessionTransport? realtime,
}) =>
    HandrailChatClient(
      apiBaseUri: Uri.parse('https://chat.test/api/chat'),
      tokenProvider: () async => 'controller-token',
      transport: transport,
      realtimeSession: realtime,
      attachmentTransferTransport: const _ByteTransport(),
      generateAttachmentUploadId: () => 'controller-upload',
      generateIdempotencyKey: _IdGenerator().next,
      generateDraftDeviceMutationId: () => 'controller-device-mutation',
    );

final class _IdGenerator {
  var value = 0;
  String next() => 'controller-key-${value += 1}';
}

final class _FixtureTransport implements HandrailChatHttpTransport {
  _FixtureTransport({
    this.draftSnapshot,
    this.detailStatus = 200,
    this.archived = false,
    this.commandStatus = 500,
    this.entityConversationIds = const [_conversationIdValue],
  });

  static const _conversationIdValue = 'conversation-controller';
  int detailStatus;
  final bool archived;
  final Future<Map<String, Object?>> Function()? draftSnapshot;
  final int commandStatus;
  final List<String> entityConversationIds;
  final List<HandrailChatHttpRequest> requests = [];

  @override
  Future<HandrailChatHttpResponse> send(HandrailChatHttpRequest request) async {
    requests.add(request);
    if (request.method == 'GET' && request.uri.path.endsWith('/draft')) {
      if (draftSnapshot != null) return _response(200, await draftSnapshot!());
      return _response(200, {
        'kind': 'conversation_draft',
        'privacy': 'actor_private',
        'conversationId': request.uri.pathSegments[3],
        'state': 'present',
        'canonicalRevision': 4,
        'canonicalUpdatedAt': _now,
        'content': {
          'privacy': 'actor_private',
          'value': {
            'format': 'plain',
            'text': 'QA 298e20b4 durable draft',
            'attachments': [],
          },
        },
      });
    }
    if (request.method == 'GET' &&
        request.uri.path.endsWith('/conversations')) {
      return _response(200, _listFixture(entityConversationIds));
    }
    if (request.method == 'GET' &&
        request.uri.path.contains('/conversations/')) {
      final id = Uri.decodeComponent(request.uri.pathSegments.last);
      return _response(detailStatus, _detailFixture(id, archived: archived));
    }
    return _response(commandStatus, const {'error': 'fixture rejection'});
  }
}

Map<String, Object?> _draftSnapshot() => {
      'kind': 'conversation_draft',
      'privacy': 'actor_private',
      'conversationId': _conversationId.value,
      'state': 'present',
      'canonicalRevision': 4,
      'canonicalUpdatedAt': _now,
      'content': {
        'privacy': 'actor_private',
        'value': {
          'format': 'plain',
          'text': 'QA 298e20b4 durable draft',
          'attachments': [],
        }
      },
    };

final class _ByteTransport implements ChatAttachmentByteTransferTransport {
  const _ByteTransport();

  @override
  Future<ChatAttachmentByteTransferResult> transfer(
    ChatAttachmentByteTransferRequest request,
  ) async =>
      const ChatAttachmentBytesUploaded();
}

ChatRealtimeSessionTransport _realtime({
  _FakeSocket? socket,
  ChatRealtimeConversationSubscriptionListener? onSubscriptionState,
}) =>
    ChatRealtimeSessionTransport(
      endpoint: Uri.parse('https://chat.test/api/chat'),
      clientPackageVersion: '0.1.3',
      protocolVersion: 4,
      tokenProvider: () async => 'realtime-token',
      socketFactory: (_, __) => socket ?? _FakeSocket(),
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

HandrailChatHttpResponse _response(int statusCode, Object body) =>
    HandrailChatHttpResponse(
      statusCode: statusCode,
      body: jsonEncode(body),
    );

Map<String, Object?> _listFixture(List<String> ids) => {
      'kind': 'conversation_list',
      'scope': {
        'type': 'entity',
        'entity': _entity.toJson(),
      },
      'items': [
        for (final id in ids) _summaryFixture(id, entity: _entity),
      ],
      'page': <String, Object?>{},
      '_meta': _metadata(),
    };

Map<String, Object?> _detailFixture(String id, {bool archived = false}) => {
      'kind': 'conversation_detail',
      'conversation': {
        ..._summaryFixture(id,
            entity: id == _conversationId.value ? null : _entity),
        if (archived) 'archivedAt': _now,
        if (archived) 'archivedByUserId': _userId,
        'memberUserIds': [_userId, 'user-other'],
        'currentPreference': {
          'conversationId': id,
          'userId': _userId,
          'notificationPreference': 'mentions',
          'mute': {'muted': false},
          'isStarred': false,
          'updatedAt': _now,
        },
      },
      '_meta': _metadata(),
    };

Map<String, Object?> _summaryFixture(
  String id, {
  HostEntityReference? entity,
}) =>
    {
      'id': id,
      'tenantId': _tenantId,
      'type': 'channel',
      'name': 'Controller fixture',
      'visibility': 'public',
      if (entity != null) 'entity': entity.toJson(),
      'createdAt': _now,
      'updatedAt': _now,
      'latestSequence': 12,
      'activityAt': _now,
      'unreadMentionCount': 0,
      'currentMember': {
        'tenantId': _tenantId,
        'conversationId': id,
        'userId': _userId,
        'role': 'member',
        'state': 'active',
        'joinedAt': _now,
        'updatedAt': _now,
      },
      'currentReadState': {
        'conversationId': id,
        'userId': _userId,
        'lastReadSequence': 11,
        'updatedAt': _now,
      },
      'currentPreference': {
        'conversationId': id,
        'userId': _userId,
        'notificationPreference': 'mentions',
        'isStarred': false,
        'mute': {'muted': false},
        'updatedAt': _now,
      },
      'activeMemberUserIds': [_userId],
    };

Map<String, Object?> _metadata() => {
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
    };

Map<String, Object?> _acceptedFrame() => {
      'type': 'chat.session.accepted',
      'metadata': {
        'packageVersion': '0.1.3',
        'protocolVersion': 4,
        'schemaVersion': 1,
        'enabledFeatures': {'typing': true, 'presence': true},
        'supportedProtocolRange': {
          'minimumVersion': 3,
          'maximumVersion': 4,
        },
      },
      'tenantId': _tenantId,
      'actorStreamId': 'user:$_userId',
      'deviceId': 'device-controller',
      'sessionId': 'session-controller',
    };

TypingSignalEvent _typingSignal(DateTime sentAt) => TypingSignalEvent(
      eventId: 'typing-controller',
      protocolVersion: 4,
      tenantId: const TenantId(_tenantId),
      streamId: _conversationId,
      occurredAt: IsoTimestamp(sentAt.toIso8601String()),
      payload: TypingSignalPayload(
        actorUserId: const UserId('user-other'),
        deviceId: const DeviceId('device-other'),
        sessionId: const SessionId('session-other'),
        sequence: 1,
        sentAt: IsoTimestamp(sentAt.toIso8601String()),
        expiresAt: IsoTimestamp(
          sentAt.add(const Duration(minutes: 1)).toIso8601String(),
        ),
        state: TypingSignalState.start,
        scope: const PublicConversationSignalScope(_conversationId),
      ),
    );

PresenceSignalEvent _presenceSignal(
  DateTime sentAt, {
  required String scopedUserId,
}) =>
    PresenceSignalEvent(
      eventId: 'presence-$scopedUserId',
      protocolVersion: 4,
      tenantId: const TenantId(_tenantId),
      streamId: 'user:$scopedUserId',
      occurredAt: IsoTimestamp(sentAt.toIso8601String()),
      payload: PresenceSignalPayload(
        actorUserId: UserId(scopedUserId),
        deviceId: const DeviceId('device-presence'),
        sessionId: const SessionId('session-presence'),
        sequence: 1,
        sentAt: IsoTimestamp(sentAt.toIso8601String()),
        expiresAt: IsoTimestamp(
          sentAt.add(const Duration(minutes: 1)).toIso8601String(),
        ),
        state: PresenceSignalState.online,
        scope: UserPrivateSignalScope(UserId(scopedUserId)),
      ),
    );

Future<void> _pump([int count = 1]) async {
  for (var index = 0; index < count; index += 1) {
    await Future<void>.delayed(Duration.zero);
  }
}

Future<void> _waitFor(bool Function() predicate) async {
  for (var index = 0; index < 100 && !predicate(); index += 1) {
    await _pump();
  }
  expect(predicate(), isTrue);
}
