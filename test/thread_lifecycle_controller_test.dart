import 'dart:async';
import 'dart:convert';
import 'package:handrail_chat/core.dart';
import 'package:test/test.dart';
import 'fixtures/existing_thread_opening_fixtures.dart';

const threadId = ConversationId('conversation-thread');
const tenant = TenantId('tenant-from-session');
const user = UserId('user-current');
const authority = ChatThreadLifecycleAuthority(
    tenantId: tenant,
    userId: user,
    canRead: true,
    canSend: true,
    canManage: true);
const time = existingThreadFixtureTime;
Map<String, Object?> lifecycle(int revision,
        {bool closed = false, bool locked = false}) =>
    {
      'revision': revision,
      'locked': locked,
      if (closed || locked) 'closedAt': time,
      if (closed || locked) 'closedByUserId': user.value,
    };
Map<String, Object?> detail(
    {Map<String, Object?>? state, bool archived = false}) {
  final json = existingThreadDetailFixture();
  final conversation = json['conversation'] as Map<String, Object?>;
  if (state != null) conversation['threadLifecycle'] = state;
  if (archived) {
    conversation['archivedAt'] = time;
    conversation['archivedByUserId'] = user.value;
  }
  return json;
}

Map<String, Object?> get metadata => {
      'packageVersion': '0.1.4',
      'protocolVersion': 4,
      'schemaVersion': 1,
      'enabledFeatures': {ChatReplyThreadFeatures.threadLifecycle: true},
      'supportedProtocolRange': {'minimumVersion': 1, 'maximumVersion': 4},
    };
HandrailChatHttpResponse response(Object? body, [int status = 200]) =>
    HandrailChatHttpResponse(statusCode: status, body: jsonEncode(body));
Map<String, Object?> result(HandrailChatHttpRequest request,
        {int before = 1,
        int after = 2,
        bool locked = false,
        bool closed = true,
        String status = 'applied'}) =>
    {
      ...jsonDecode(request.body!) as Map<String, dynamic>,
      'threadId': threadId.value,
      'reconciliationStatus': status,
      'previousLifecycle': lifecycle(before,
          closed: status == 'lifecycle_conflict' && closed,
          locked: status == 'lifecycle_conflict' && locked),
      'threadLifecycle': lifecycle(after, closed: closed, locked: locked),
    };
KnownDurableEvent event(int revision,
        {bool locked = false, String? id, String? occurredAt}) =>
    KnownDurableEvent.fromJson({
      'eventId': id ?? 'event-$revision',
      'tenantId': tenant.value,
      'streamId': threadId.value,
      'type': 'thread.lifecycle.updated',
      'protocolVersion': 4,
      'occurredAt': occurredAt ?? time,
      'payload': {
        'threadId': threadId.value,
        'parentConversationId': 'conversation-parent',
        'threadLifecycle': lifecycle(revision, closed: true, locked: locked)
      },
    },
        trustedIdentity:
            const DurableEventTrustedIdentity(tenantId: tenant, userId: user));
Future<void> pump() async {
  for (var i = 0; i < 8; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}

typedef Handler = Future<HandrailChatHttpResponse> Function(
    HandrailChatHttpRequest);

class Http implements HandrailChatHttpTransport {
  final requests = <HandrailChatHttpRequest>[];
  Handler? write;
  Handler? read;
  bool supported = true;
  Map<String, Object?> snapshot = detail(state: lifecycle(1));
  @override
  Future<HandrailChatHttpResponse> send(HandrailChatHttpRequest request) async {
    requests.add(request);
    if (request.method == 'GET' && !request.uri.path.endsWith(threadId.value)) {
      return response({
        ...metadata,
        'enabledFeatures': {ChatReplyThreadFeatures.threadLifecycle: supported}
      });
    }
    if (request.method == 'GET') {
      return read == null ? response(snapshot) : await read!(request);
    }
    return write == null ? response(result(request)) : await write!(request);
  }

  List<HandrailChatHttpRequest> get writes => requests
      .where((r) => r.method == 'PATCH' && r.uri.path.endsWith('/lifecycle'))
      .toList();
}

Future<HandrailChatClient> clientFor(Http http,
    {ChatRealtimeSessionTransport? realtime,
    bool requestSupport = true,
    int attempts = 1}) async {
  var key = 0;
  final client = HandrailChatClient(
      apiBaseUri: Uri.parse('https://chat.test/api/chat'),
      tokenProvider: () async => 'test-token',
      transport: http,
      requestedCapabilities: {ChatReplyThreadFeatures.threadLifecycle: requestSupport},
      generateIdempotencyKey: () => 'lifecycle-${++key}',
      commandRetryOptions: ChatCommandRetryOptions(
          maxAttempts: attempts, backoff: (_) => Duration.zero),
      realtimeSession: realtime);
  addTearDown(client.dispose);
  await client.initialize();
  return client;
}

Future<ChatThreadLifecycleController> loaded(HandrailChatClient client) async {
  final controller = client.threadLifecycles.forThread(threadId)
    ..setAuthority(authority);
  expect((await controller.load()).status, ChatThreadLifecycleStatus.ready);
  return controller;
}

void main() {
  group('normalized lifecycle reducer regressions', () {
    late NormalizedSnapshotStore store;
    setUp(() {
      store = NormalizedSnapshotStore();
      store.hydrateConversationDetail(
          ConversationDetailSnapshot.fromJson(detail(state: lifecycle(1))));
      addTearDown(store.close);
    });
    ThreadConversation current() =>
        store.state.conversations[threadId] as ThreadConversation;
    test(
        'revision clock wins over tied and older event clocks; preserves private state',
        () {
      final before = store.state;
      store.reduceDurableEvent(event(2));
      store.reduceDurableEvent(
          event(3, locked: true, occurredAt: '2026-08-25T16:00:00.000Z'));
      store.reduceDurableEvent(event(2, id: 'stale-lifecycle'));
      expect(current().threadLifecycle!.revision, 3);
      expect(current().threadLifecycle!.locked, isTrue);
      expect(store.state.currentUserPreferences, before.currentUserPreferences);
      expect(store.state.currentUserReadStates, before.currentUserReadStates);
      expect(store.state.currentUserThreadFollows,
          before.currentUserThreadFollows);
      expect(store.state.messages, before.messages);
      expect(store.state.durableStreams[threadId.value]!.lastEventId,
          'stale-lifecycle');
      final accepted = store.state;
      expect(() => store.reduceDurableEvent(event(3, id: 'contradictory')),
          throwsA(isA<DurableEventReductionError>()));
      expect(store.state, same(accepted));
      final restored = NormalizedSnapshotStateStorageCodec.decode(
          NormalizedSnapshotStateStorageCodec.encode(store.state));
      expect(
          (restored.conversations[threadId] as ThreadConversation)
              .threadLifecycle!
              .revision,
          3);
    });
    test(
        'equal timestamp detail can advance lifecycle; newer legacy detail cannot regress it',
        () {
      store.hydrateConversationDetail(ConversationDetailSnapshot.fromJson(
          detail(state: lifecycle(5, locked: true))));
      expect(current().threadLifecycle!.revision, 5);
      final legacy = detail(archived: true);
      (legacy['conversation'] as Map)['updatedAt'] = '2026-08-27T16:00:00.000Z';
      store.hydrateConversationDetail(
          ConversationDetailSnapshot.fromJson(legacy));
      expect(current().threadLifecycle!.revision, 5);
      expect(current().archivedAt, isNotNull);
      final old = detail(state: lifecycle(6));
      store.hydrateConversationDetail(ConversationDetailSnapshot.fromJson(old));
      expect(current().threadLifecycle!.revision, 6);
      expect(current().archivedAt, isNotNull);
    });
    test('stale thread-created metadata does not regress lifecycle', () {
      store.reduceDurableEvent(event(4, locked: true));
      final created = KnownDurableEvent.fromJson({
        'eventId': 'created-after-ack',
        'tenantId': tenant.value,
        'protocolVersion': 4,
        'streamId': threadId.value,
        'type': 'thread.created',
        'occurredAt': '2026-08-27T16:00:00.000Z',
        'payload': {
          'conversation': {
            ...current().toJson(),
            'threadLifecycle': lifecycle(1)
          },
          'rootThreadSummary': {
            'threadId': threadId.value,
            'replyCount': 0,
            'participantIds': [],
            'unreadCount': 0
          }
        },
      },
          trustedIdentity: const DurableEventTrustedIdentity(
              tenantId: tenant, userId: user));
      store.reduceDurableEvent(created);
      expect(current().threadLifecycle!.revision, 4);
    });
    test(
        'parent invalidation consumes its cursor without inventing child state',
        () {
      final parentJson = jsonDecode(jsonEncode(detail())
              .replaceAll('conversation-thread', 'conversation-parent'))
          as Map<String, dynamic>;
      final parent = parentJson['conversation'] as Map<String, dynamic>;
      parent.remove('parentConversationId');
      parent.remove('rootMessageId');
      parent['type'] = 'channel';
      parent['name'] = 'Parent';
      store.hydrateConversationDetail(
          ConversationDetailSnapshot.fromJson(parentJson));
      final before = current();
      final changed = KnownDurableEvent.fromJson({
        'eventId': 'parent-invalidation',
        'tenantId': tenant.value,
        'protocolVersion': 4,
        'streamId': 'conversation-parent',
        'type': 'thread.lifecycle.changed',
        'occurredAt': time,
        'payload': {
          'threadId': threadId.value,
          'parentConversationId': 'conversation-parent',
          'revision': 8
        },
      },
          trustedIdentity: const DurableEventTrustedIdentity(
              tenantId: tenant, userId: user));
      expect(store.reduceDurableEvent(changed).status,
          DurableEventReductionStatus.applied);
      expect(current(), same(before));
      expect(store.state.latestReplayCursor!.eventId, 'parent-invalidation');
    });
    test('mismatched parent cannot mutate state or consume event', () {
      final bad = KnownDurableEvent.fromJson({
        ...event(2).toJson(),
        'payload': {
          ...event(2).payload.data,
          'parentConversationId': 'wrong-parent'
        }
      },
          trustedIdentity: const DurableEventTrustedIdentity(
              tenantId: tenant, userId: user));
      final before = store.state;
      expect(() => store.reduceDurableEvent(bad),
          throwsA(isA<DurableEventReductionError>()));
      expect(store.state, same(before));
    });
  });
  test(
      'explicit close, lock, unlock and reopen use separate revisions and keys',
      () async {
    final http = Http();
    var canonical = lifecycle(1);
    http.write = (request) async {
      final input = ThreadLifecycleInput.fromHttp(
          threadId.value, jsonDecode(request.body!));
      final previous = canonical;
      canonical = lifecycle(input.expectedLifecycleRevision + 1,
          closed: input.intent != ThreadLifecycleIntent.reopen,
          locked: input.intent == ThreadLifecycleIntent.lock);
      return response({
        ...input.toJson(),
        'reconciliationStatus': 'applied',
        'previousLifecycle': previous,
        'threadLifecycle': canonical
      });
    };
    final client = await clientFor(http);
    final controller = await loaded(client);
    expect((await controller.close()).lifecycle!.revision, 2);
    expect((await controller.lock()).isLocked, isTrue);
    expect((await controller.unlock()).isOpen, isFalse);
    expect((await controller.reopen()).isOpen, isTrue);
    expect(controller.state.lifecycle!.revision, 5);
    expect(http.writes.map((r) => jsonDecode(r.body!)['intent']),
        ['close', 'lock', 'unlock', 'reopen']);
    expect(
        http.writes
            .map((r) => jsonDecode(r.body!)['expectedLifecycleRevision']),
        [1, 2, 3, 4]);
    expect(
        http.writes.map((r) => jsonDecode(r.body!)['idempotencyKey']).toSet(),
        hasLength(4));
  });
  test('remote event beats late acknowledgement and later stale detail',
      () async {
    final http = Http();
    final pending = Completer<HandrailChatHttpResponse>();
    http.write = (_) => pending.future;
    final client = await clientFor(http);
    final controller = await loaded(client);
    final states = <ChatThreadLifecycleState>[];
    final subscription = controller.states.listen(states.add);
    addTearDown(subscription.cancel);
    final save = controller.close();
    await pump();
    expect(controller.state.isSaving, isTrue);
    expect(client.reduceDurableEvent(event(3, locked: true)).status,
        DurableEventReductionStatus.applied);
    expect(controller.state.lifecycle!.revision, 3);
    pending.complete(response(result(http.writes.single)));
    expect((await save).lifecycle!.revision, 3);
    expect(controller.state.isLocked, isTrue);
    await controller.load();
    expect(controller.state.lifecycle!.revision, 3);
    expect(
        (client.normalizedState.state.conversations[threadId]
                as ThreadConversation)
            .threadLifecycle!
            .revision,
        3);
    expect(states.any((s) => s.isSaving), isTrue);
  });
  test('transport retries and explicit retry freeze the complete wire identity',
      () async {
    final http = Http();
    http.write = (_) async =>
        const HandrailChatHttpResponse(statusCode: 503, body: 'unavailable');
    final client = await clientFor(http, attempts: 2);
    final controller = await loaded(client);
    expect((await controller.close()).canRetry, isTrue);
    client.reduceDurableEvent(event(3));
    http.write =
        (request) async => response(result(request, status: 'replayed'));
    final retried = await controller.retry();
    expect(retried.status, ChatThreadLifecycleStatus.ready);
    expect(retried.lifecycle!.revision, 3);
    expect(http.writes, hasLength(3));
    for (final request in http.writes.skip(1)) {
      expect(request.body, http.writes.first.body);
      expect(request.uri, http.writes.first.uri);
      expect(request.headers, http.writes.first.headers);
    }
    final body = jsonDecode(http.writes.last.body!);
    expect(body['expectedLifecycleRevision'], 1);
    expect(body['intent'], 'close');
    expect(body.containsKey('threadId'), isFalse);
  });
  test('canonical 409 stays an explicit conflict; sanitized 409 is an error',
      () async {
    final http = Http();
    http.write = (r) async => response(
        result(r, before: 4, after: 4, status: 'lifecycle_conflict'), 409);
    final client = await clientFor(http);
    final controller = await loaded(client);
    final conflict = await controller.close();
    expect(conflict.status, ChatThreadLifecycleStatus.conflict);
    expect(conflict.lifecycle!.revision, 4);
    expect(conflict.canRetry, isFalse);
    await controller.retry();
    await controller.load();
    expect(controller.state.status, ChatThreadLifecycleStatus.conflict);
    expect(http.writes, hasLength(1));
    http.write = (_) async => response({
          'error': {'code': 'idempotency_key_reuse', 'message': 'secret'}
        }, 409);
    final failed = await controller.lock();
    expect(failed.status, ChatThreadLifecycleStatus.error);
    expect(failed.result, isNull);
    expect(failed.errorMessage, isNot(contains('secret')));
    expect(failed.lifecycle!.revision, 4);
    expect(jsonDecode(http.writes.last.body!)['idempotencyKey'], 'lifecycle-2');
  });
  for (final field in [
    'threadId',
    'intent',
    'expectedLifecycleRevision',
    'idempotencyKey'
  ]) {
    test('rejects mismatched result $field before applying state', () async {
      final http = Http();
      http.write = (r) async => response({
            ...result(r),
            field: field == 'expectedLifecycleRevision' ? 9 : 'wrong'
          });
      final client = await clientFor(http);
      final controller = await loaded(client);
      expect((await controller.close()).error,
          ChatThreadLifecycleError.malformedResponse);
      expect(controller.state.lifecycle!.revision, 1);
    });
  }
  for (final actorChange in [false, true]) {
    test(
        'drops pending reads and writes after ${actorChange ? 'actor' : 'access'} generation changes',
        () async {
      final http = Http();
      final pending = Completer<HandrailChatHttpResponse>();
      http.write = (_) => pending.future;
      final client = await clientFor(http);
      final controller = await loaded(client);
      final save = controller.close();
      await pump();
      controller.setAuthority(actorChange
          ? const ChatThreadLifecycleAuthority(
              tenantId: tenant,
              userId: UserId('other'),
              canRead: true,
              canManage: true)
          : null);
      pending.complete(response(result(http.writes.single)));
      await save;
      expect(controller.state.conversation, isNull);
      expect(
          (client.normalizedState.state.conversations[threadId]
                  as ThreadConversation)
              .threadLifecycle!
              .revision,
          1);
      final count = http.writes.length;
      await controller.retry();
      expect(http.writes, hasLength(count));
      controller.setAuthority(authority);
      final read = Completer<HandrailChatHttpResponse>();
      http.read = (_) => read.future;
      final loading = controller.load();
      await pump();
      controller.setAuthority(null);
      read.complete(response(detail(state: lifecycle(8, locked: true))));
      await loading;
      expect(controller.state.conversation, isNull);
      expect(
          (client.normalizedState.state.conversations[threadId]
                  as ThreadConversation)
              .threadLifecycle!
              .revision,
          1);
    });
  }
  test(
      'remote administrative archive and restore use their independent projection',
      () async {
    final http = Http()..snapshot = detail(state: lifecycle(1), archived: true);
    final client = await clientFor(http);
    final controller = await loaded(client);
    expect(controller.state.isArchived, isTrue);
    for (final restore in [true, false]) {
      client.reduceDurableEvent(KnownDurableEvent.fromJson({
        'eventId': 'archive-$restore',
        'tenantId': tenant.value,
        'protocolVersion': 4,
        'streamId': threadId.value,
        'type': restore ? 'conversation.restored' : 'conversation.archived',
        'occurredAt': time,
        'payload': {
          'conversationId': threadId.value,
          'intent': restore ? 'restore' : 'archive',
          'previousState': restore ? 'archived' : 'active',
          'currentState': restore ? 'active' : 'archived',
          'previousLifecycleRevision': restore ? 1 : 2,
          'currentLifecycleRevision': restore ? 2 : 3
        },
      },
          trustedIdentity: const DurableEventTrustedIdentity(
              tenantId: tenant, userId: user)));
      expect(controller.state.isArchived, !restore);
      expect(controller.state.capabilities.canClose, restore);
      expect(controller.state.lifecycle!.revision, 1);
      expect(controller.state.isOpen, isTrue);
    }
  });
  test('legacy defaults preserve administrative archive and authority gates',
      () async {
    final http = Http()..snapshot = detail();
    final client = await clientFor(http);
    final controller = await loaded(client);
    expect(controller.state.isOpen, isTrue);
    expect(controller.state.isLocked, isFalse);
    expect(controller.state.lifecycle!.revision, 1);
    controller.setAuthority(const ChatThreadLifecycleAuthority(
        tenantId: tenant, userId: user, canRead: true, canSend: true));
    await controller.load();
    expect(controller.state.capabilities.canClose, isFalse);
    expect(controller.state.capabilities.canReopen, isTrue);
    await controller.close();
    expect(http.writes, isEmpty);
    http.snapshot = detail(archived: true);
    (http.snapshot['conversation'] as Map)['updatedAt'] =
        '2026-08-27T16:00:00.000Z';
    controller.setAuthority(authority);
    await controller.load();
    expect(controller.state.isArchived, isTrue);
    expect(controller.state.isOpen, isTrue);
    expect(controller.state.capabilities.canReopen, isFalse);
    expect(controller.state.capabilities.canLock, isFalse);
  });
  for (final requestSupport in [false, true]) {
    test('unadvertised or unrequested support prevents writes $requestSupport',
        () async {
      final http = Http()..supported = !requestSupport;
      final client = await clientFor(http, requestSupport: requestSupport);
      final controller = await loaded(client);
      expect(controller.state.capabilities.supported, isFalse);
      expect((await controller.close()).error,
          ChatThreadLifecycleError.unsupported);
      await controller.retry();
      expect(http.writes, isEmpty);
    });
  }
  test('denial preserves composer draft and pending send destination',
      () async {
    final http = Http();
    final pendingSend = Completer<HandrailChatHttpResponse>();
    final pendingDraft = Completer<HandrailChatHttpResponse>();
    http.write = (r) {
      if (r.uri.path.endsWith('/messages')) return pendingSend.future;
      if (r.uri.path.endsWith('/draft')) return pendingDraft.future;
      return Future.value(response({
        'error': {'code': 'forbidden', 'message': 'private details'}
      }, 403));
    };
    final client = await clientFor(http);
    final controller = await loaded(client);
    final draft = client.synchronizeDraft(ChatReplaceDraftInput(
        conversationId: threadId,
        baseRevision: 0,
        content: DraftContent.fromJson(
            {'format': 'plain', 'text': 'Keep my draft', 'attachments': []})));
    final send = client.sendMessage(ChatSendMessageInput(
        conversationId: threadId,
        content: MessageContent.fromJson(
            {'format': 'plain', 'text': 'Pending send'})));
    await pump();
    final draftBefore = client.draftFor(threadId);
    expect(draftBefore, isNotNull);
    final denied = await controller.close();
    expect(denied.error, ChatThreadLifecycleError.denied);
    expect(client.draftFor(threadId), same(draftBefore));
    final sendRequest =
        http.requests.singleWhere((r) => r.uri.path.endsWith('/messages'));
    expect(sendRequest.uri.path, endsWith('/conversation-thread/messages'));
    expect(jsonDecode(sendRequest.body!)['conversationId'], threadId.value);
    expect(
        client.draftFor(const ConversationId('conversation-parent')), isNull);
    await client.dispose();
    await send;
    await draft;
  });
  test('accepted realtime metadata cannot widen missing support', () async {
    final socket = Socket();
    final realtime = ChatRealtimeSessionTransport(
        endpoint: Uri.parse('https://chat.test/api/chat'),
        clientPackageVersion: '0.1.4',
        protocolVersion: 4,
        tokenProvider: () => 'token',
        socketFactory: (_, __) => socket);
    addTearDown(realtime.dispose);
    final http = Http();
    final client = await clientFor(http, realtime: realtime);
    await realtime.start();
    socket.accept(supported: false);
    await pump();
    final controller = await loaded(client);
    expect(controller.state.capabilities.supported, isFalse);
    expect(
        (await controller.close()).error, ChatThreadLifecycleError.unsupported);
    expect(http.writes, isEmpty);
  });
  test('reconnect retries an interrupted initial lifecycle load', () async {
    final socket = Socket();
    final realtime = ChatRealtimeSessionTransport(
        endpoint: Uri.parse('https://chat.test/api/chat'),
        clientPackageVersion: '0.1.4', protocolVersion: 4,
        tokenProvider: () => 'socket-token', socketFactory: (_, __) => socket);
    addTearDown(realtime.dispose);
    final http = Http();
    final client = await clientFor(http, realtime: realtime);
    await realtime.start();
    socket.accept();
    await pump();
    final controller = client.threadLifecycles.forThread(threadId)..setAuthority(authority);
    final pending = Completer<HandrailChatHttpResponse>();
    http.read = (_) => pending.future;
    final loading = controller.load();
    await pump();
    await realtime.suspend();
    http.read = null;
    await realtime.start();
    socket.accept();
    await pump();
    pending.complete(response(detail(state: lifecycle(1))));
    await loading;
    expect(controller.state.status, ChatThreadLifecycleStatus.ready);
    expect(controller.state.capabilities.canClose, isTrue);
  });

  test('reconnect refresh and subscription revocation reject late write',
      () async {
    final socket = Socket();
    final realtime = ChatRealtimeSessionTransport(
        endpoint: Uri.parse('https://chat.test/api/chat'),
        clientPackageVersion: '0.1.4',
        protocolVersion: 4,
        tokenProvider: () => 'socket-token',
        socketFactory: (_, __) => socket);
    addTearDown(realtime.dispose);
    final http = Http();
    final client = await clientFor(http, realtime: realtime);
    await realtime.start();
    socket.accept();
    await pump();
    final controller = await loaded(client);
    final reads =
        http.requests.where((r) => r.uri.path.endsWith(threadId.value)).length;
    http.write = (_) async =>
        const HandrailChatHttpResponse(statusCode: 503, body: 'unavailable');
    expect((await controller.close()).canRetry, isTrue);
    final frozen = http.writes.single.body;
    await realtime.suspend();
    http.snapshot = detail(state: lifecycle(7, locked: true));
    await realtime.start();
    socket.accept();
    await pump();
    expect(controller.state.lifecycle!.revision, 7);
    expect(
        http.requests.where((r) => r.uri.path.endsWith(threadId.value)).length,
        greaterThan(reads));
    expect(controller.state.capabilities.canReopen, isFalse);
    expect(controller.state.canRetry, isTrue);
    http.write =
        (request) async => response(result(request, status: 'replayed'));
    expect((await controller.retry()).lifecycle!.revision, 7);
    expect(http.writes.last.body, frozen);
    final pending = Completer<HandrailChatHttpResponse>();
    http.write = (_) => pending.future;
    final save = controller.unlock();
    await pump();
    socket.emit({
      'type': 'chat.subscription.revoked',
      'code': 'access_revoked',
      'streamId': threadId.value
    });
    await pump();
    pending.complete(response({'not': 'canonical'}));
    await save;
    expect(controller.state.conversation, isNull);
    expect(controller.state.capabilities.canUnlock, isFalse);
    controller.setAuthority(authority);
    await controller.load();
    await pump();
    final unsubscribes =
        socket.sent.where((s) => s['type'] == 'chat.unsubscribe').length;
    await controller.dispose();
    expect(socket.sent.where((s) => s['type'] == 'chat.unsubscribe').length,
        unsubscribes + 1);
    expect(controller.state.status, ChatThreadLifecycleStatus.disposed);
  });
}

class Socket implements ChatRealtimeSocket {
  final controller = StreamController<Object?>.broadcast(sync: true);
  final sent = <Map<String, dynamic>>[];
  @override
  Stream<Object?> get frames => controller.stream;
  @override
  void close() {}
  @override
  void send(String data) {
    final json = jsonDecode(data) as Map<String, dynamic>;
    sent.add(json);
    if (json['type'] == 'chat.subscribe') {
      scheduleMicrotask(() => emit({
            'type': 'chat.subscription.accepted',
            'streamId': json['streamId'],
            'requestId': json['requestId']
          }));
    }
  }

  void emit(Map<String, Object?> json) => controller.add(jsonEncode(json));
  void accept({bool supported = true}) => emit({
        'type': 'chat.session.accepted',
        'metadata': {
          ...metadata,
          'enabledFeatures': {ChatReplyThreadFeatures.threadLifecycle: supported}
        },
        'tenantId': tenant.value,
        'actorStreamId': 'user:${user.value}',
        'deviceId': 'device-1',
        'sessionId': 'session-1'
      });
}
