import 'dart:async';
import 'dart:convert';

import 'package:handrail_chat/core.dart';
import 'package:handrail_chat/src/testing/in_memory_application_chat_storage.dart';
import 'package:test/test.dart';

const _conversationOne = ConversationId('conversation-1');
const _conversationTwo = ConversationId('conversation-2');
const _tenantId = TenantId('tenant-1');
const _userId = UserId('user-1');
final _storageIdentity = ApplicationChatStorageIdentity(
  tenantId: _tenantId,
  userId: _userId,
  deviceId: const DeviceId('device-1'),
);
final _otherStorageIdentity = ApplicationChatStorageIdentity(
  tenantId: const TenantId('tenant-2'),
  userId: const UserId('user-2'),
  deviceId: const DeviceId('device-2'),
);

void main() {
  for (final cancelWrite in [false, true]) {
    test('remote event cannot imply local durability: cancel=$cancelWrite',
        () async {
      final gate = Completer<void>();
      final storage = _RecordingStorage()
        ..draftWriteGate = gate
        ..failDraftWrites = !cancelWrite;
      final transport = _RecordingTransport(
        (_) async => fail('event-settled draft reached transport'),
      );
      final client = _client(transport,
          storage: storage, storageIdentity: _storageIdentity);
      await client.activateStorageIdentity(_storageIdentity);
      final cancellation = ChatCommandCancellationController();
      final mutation = client.synchronizeDraftWithLocalPersistence(
        ChatReplaceDraftInput(
          conversationId: _conversationOne,
          baseRevision: 0,
          content: _content('event during write'),
          deviceMutationId: 'pending-event-device',
          idempotencyKey: 'pending-event-key',
        ),
        cancellationSignal: cancellation.signal,
      );
      ChatDraftLocalPersistenceResult? local;
      unawaited(mutation.localPersistence.then((result) => local = result));
      await _until(() => storage.draftWriteStarted == 1);
      expect(
          client.reconcileDraftEvent(_draftEvent(
            canonicalRevision: 1,
            updatedAt: '2026-08-26T15:00:00.000Z',
            text: 'event during write',
            deviceMutationId: 'pending-event-device',
            idempotencyKey: 'pending-event-key',
          )),
          isTrue);
      expect(await mutation.remoteSettlement,
          isA<ChatCommandSuccess<SynchronizeDraftResult>>());
      expect(local, isNull);
      if (cancelWrite) {
        cancellation.cancel();
        await _eventLoop();
        expect(local, isA<ChatDraftNotPersisted>());
        expect(gate.isCompleted, isFalse);
      }
      gate.complete();
      expect(
        (await mutation.localPersistence as ChatDraftNotPersisted).reason,
        cancelWrite
            ? ChatDraftNotPersistedReason.aborted
            : ChatDraftNotPersistedReason.storageFailure,
      );
      if (cancelWrite) {
        // Local cancellation settles before the write and its later cleanup.
        await _until(() => storage.removals.any((removal) =>
            removal.$2 == ApplicationChatStorageRecordKind.queuedDraftIntents));
      }
      await client.dispose();
      expect(storage.draftIntents(_storageIdentity), isEmpty);
      expect(transport.requests, isEmpty);
    });
  }

  test('missing storage reports no durability and preserves legacy remote use',
      () async {
    final transport = _RecordingTransport(
      (request) async => _draftResponse(request, status: 'applied'),
    );
    final client = _client(transport);
    final mutation = client.synchronizeDraftWithLocalPersistence(
      const ChatClearDraftInput(
        conversationId: _conversationOne,
        baseRevision: 0,
      ),
    );
    expect(
      (await mutation.localPersistence as ChatDraftNotPersisted).reason,
      ChatDraftNotPersistedReason.storageUnavailable,
    );
    expect(await mutation.remoteSettlement,
        isA<ChatCommandSuccess<SynchronizeDraftResult>>());
    expect(transport.requests, hasLength(1));
    await client.dispose();
  });

  test('local completion reports unavailable identity, validation and closure',
      () async {
    final storage = _RecordingStorage();
    final transport = _RecordingTransport(
      (_) async => fail('rejected draft reached transport'),
    );
    final client = _client(transport, storage: storage);
    const input = ChatClearDraftInput(
      conversationId: _conversationOne,
      baseRevision: 0,
    );
    final unavailable = client.synchronizeDraftWithLocalPersistence(input);
    expect(
      (await unavailable.localPersistence as ChatDraftNotPersisted).reason,
      ChatDraftNotPersistedReason.identityUnavailable,
    );
    expect(await unavailable.remoteSettlement,
        isA<ChatCommandTransportFailure<SynchronizeDraftResult>>());

    final invalid = client.synchronizeDraftWithLocalPersistence(
      const ChatClearDraftInput(
        conversationId: _conversationOne,
        baseRevision: -1,
      ),
    );
    expect(
      (await invalid.localPersistence as ChatDraftNotPersisted).reason,
      ChatDraftNotPersistedReason.validationFailure,
    );
    expect(await invalid.remoteSettlement,
        isA<ChatCommandValidationFailure<SynchronizeDraftResult>>());

    final cancellation = ChatCommandCancellationController()..cancel();
    final aborted = client.synchronizeDraftWithLocalPersistence(
      input,
      cancellationSignal: cancellation.signal,
    );
    expect(
      (await aborted.localPersistence as ChatDraftNotPersisted).reason,
      ChatDraftNotPersistedReason.aborted,
    );
    expect(await aborted.remoteSettlement,
        isA<ChatCommandAborted<SynchronizeDraftResult>>());

    await client.dispose();
    final closed = client.synchronizeDraftWithLocalPersistence(input);
    expect(
      (await closed.localPersistence as ChatDraftNotPersisted).reason,
      ChatDraftNotPersistedReason.closed,
    );
    expect(await closed.remoteSettlement,
        isA<ChatCommandClosed<SynchronizeDraftResult>>());
    expect(storage.draftWriteStarted, 0);
    expect(transport.requests, isEmpty);
  });

  test('cancellation settles local completion before a delayed write returns',
      () async {
    final gate = Completer<void>();
    final storage = _RecordingStorage()..draftWriteGate = gate;
    final transport = _RecordingTransport(
      (_) async => fail('cancelled draft reached transport'),
    );
    final client =
        _client(transport, storage: storage, storageIdentity: _storageIdentity);
    await client.activateStorageIdentity(_storageIdentity);
    final cancellation = ChatCommandCancellationController();
    final mutation = client.synchronizeDraftWithLocalPersistence(
      ChatReplaceDraftInput(
        conversationId: _conversationOne,
        baseRevision: 0,
        content: _replyContent('cancelled-source', false),
      ),
      cancellationSignal: cancellation.signal,
    );
    await _until(() => storage.draftWriteStarted == 1);
    cancellation.cancel();
    final local = await mutation.localPersistence;
    expect((local as ChatDraftNotPersisted).reason,
        ChatDraftNotPersistedReason.aborted);
    expect(gate.isCompleted, isFalse);
    gate.complete();
    expect(await mutation.remoteSettlement,
        isA<ChatCommandAborted<SynchronizeDraftResult>>());
    expect(await mutation.localPersistence, same(local));
    expect(storage.draftIntents(_storageIdentity), isEmpty);
    expect(transport.requests, isEmpty);
    await client.dispose();
  });

  test('encodes exact replace and clear PATCH requests and projects locally',
      () async {
    const conversationId = ConversationId('conversation /?#');
    final transport = _RecordingTransport((request) async => _draftResponse(
          request,
          status: request.body!.contains('"replace"') ? 'applied' : 'replayed',
        ));
    final client = _client(transport);
    final emissions = <ChatDraftProjection?>[];
    final subscription =
        client.draftStatesFor(conversationId).listen(emissions.add);

    final replace = client.synchronizeDraft(
      ChatReplaceDraftInput(
        conversationId: conversationId,
        baseRevision: 0,
        content: _content('hello'),
        deviceMutationId: 'device-replace',
        idempotencyKey: 'replace-key',
      ),
    );
    expect(_projectionText(client.draftFor(conversationId)), 'hello');
    expect(client.draftFor(conversationId)?.isPending, isTrue);
    final replaceResult = await replace;

    final clear = client.synchronizeDraft(
      const ChatClearDraftInput(
        conversationId: conversationId,
        baseRevision: 1,
        deviceMutationId: 'device-clear',
        idempotencyKey: 'clear-key',
      ),
    );
    expect(
      client.draftFor(conversationId)?.draft,
      isA<CanonicalClearDraftTombstone>(),
    );
    final clearResult = await clear;

    expect(
      (replaceResult as ChatCommandSuccess<SynchronizeDraftResult>)
          .value
          .reconciliationStatus,
      DraftMutationReconciliationStatus.applied,
    );
    expect(
      (clearResult as ChatCommandSuccess<SynchronizeDraftResult>)
          .value
          .reconciliationStatus,
      DraftMutationReconciliationStatus.replayed,
    );
    expect(transport.requests, hasLength(2));
    expect(transport.requests.map((request) => request.method),
        everyElement('PATCH'));
    expect(
      transport.requests.map((request) => request.uri.toString()),
      everyElement(
        'https://chat.example.test/api/chat/conversations/'
        'conversation%20%2F%3F%23/draft',
      ),
    );
    expect(jsonDecode(transport.requests[0].body!), {
      'operation': 'synchronize_draft',
      'intent': 'replace',
      'conversationId': conversationId.value,
      'baseRevision': 0,
      'deviceMutationId': 'device-replace',
      'idempotencyKey': 'replace-key',
      'content': {
        'format': 'markdown',
        'text': 'hello',
        'attachments': <Object?>[],
      },
    });
    expect(jsonDecode(transport.requests[1].body!), {
      'operation': 'synchronize_draft',
      'intent': 'clear',
      'conversationId': conversationId.value,
      'baseRevision': 1,
      'deviceMutationId': 'device-clear',
      'idempotencyKey': 'clear-key',
    });
    expect(client.draftFor(conversationId)?.revision, 2);
    expect(client.draftFor(conversationId)?.isPending, isFalse);
    expect(emissions.whereType<ChatDraftProjection>(), hasLength(4));

    await subscription.cancel();
    await client.dispose();
  });

  test('reply-only replacements emit and retain the exact complete draft',
      () async {
    final storage = _RecordingStorage();
    final transport = _RecordingTransport((_) async =>
        const HandrailChatHttpResponse(statusCode: 503, body: '{}'));
    final client = _client(transport,
        storage: storage, storageIdentity: _storageIdentity);
    await client.activateStorageIdentity(_storageIdentity);
    final emissions = <ChatDraftProjection?>[];
    final subscription =
        client.draftStatesFor(_conversationOne).listen(emissions.add);
    final contents = [
      _replyContent('source-a', true),
      _replyContent('source-b', true),
      _replyContent('source-b', false),
      _replyContent(null, false),
    ];

    for (var index = 0; index < contents.length; index += 1) {
      final before = emissions.length;
      final content = contents[index];
      final result = await client.synchronizeDraft(ChatReplaceDraftInput(
        conversationId: _conversationOne,
        baseRevision: 0,
        content: content,
        deviceMutationId: 'reply-edit-$index',
        idempotencyKey: 'reply-key-$index',
      ));
      expect(result, isA<ChatCommandTransportFailure<SynchronizeDraftResult>>());
      await _eventLoop();
      // Revision, pending status, text, mentions, and attachments stay equal:
      // the reply edit itself must cause the observable change.
      expect(emissions.length, greaterThan(before));
      final projection = client.draftFor(_conversationOne)!;
      expect(projection.conversationId, _conversationOne);
      expect(projection.revision, 1);
      expect(projection.isPending, isTrue);
      expect(projection.draft.toJson(),
          {'kind': 'replaced', 'content': content.toJson()});
      expect(emissions.last?.draft.toJson(), projection.draft.toJson());
      final expected = {
        'operation': 'synchronize_draft',
        'intent': 'replace',
        'conversationId': _conversationOne.value,
        'baseRevision': 0,
        'deviceMutationId': 'reply-edit-$index',
        'idempotencyKey': 'reply-key-$index',
        'content': content.toJson(),
      };
      expect(jsonDecode(transport.requests.last.body!), expected);
      expect(storage.draftIntents(_storageIdentity).single.request.toJson(),
          expected);
    }
    expect(transport.requests, hasLength(contents.length));
    await subscription.cancel();
    await client.dispose();
  });

  test('reply draft survives client restart and exact retained retries',
      () async {
    final content = _replyContent('source-restart', false);
    final storage = _RecordingStorage();
    final offline = _RecordingTransport((_) async =>
        const HandrailChatHttpResponse(statusCode: 503, body: '{}'));
    final first = _client(offline,
        storage: storage, storageIdentity: _storageIdentity);
    await first.activateStorageIdentity(_storageIdentity);
    await first.synchronizeDraft(ChatReplaceDraftInput(
      conversationId: _conversationOne,
      baseRevision: 1,
      content: content,
      deviceMutationId: 'restart-device',
      idempotencyKey: 'restart-key',
    ));
    final retained = storage.draftIntents(_storageIdentity).single.toJson();
    await first.dispose();

    final store = NormalizedSnapshotStore();
    _installCanonicalDraft(store, canonicalRevision: 1, text: 'base');
    final retryGate = Completer<void>();
    final waits = <Duration>[];
    final transport = _RecordingTransport((request) async {
      if (waits.isEmpty) throw StateError('ambiguous transport');
      return _draftResponse(request, status: 'replayed');
    });
    final restarted = _client(transport,
        storage: storage,
        storageIdentity: _storageIdentity,
        normalizedStore: store,
        retainedDraftRetryBackoff: (_) => const Duration(seconds: 1),
        retainedDraftRetryWait: (delay, _) {
          waits.add(delay);
          return retryGate.future;
        });
    await restarted.activateStorageIdentity(_storageIdentity);
    await _until(() => waits.isNotEmpty);
    expect(storage.draftIntents(_storageIdentity).single.toJson(), retained);
    expect(restarted.draftFor(_conversationOne)?.draft.toJson(),
        {'kind': 'replaced', 'content': content.toJson()});
    expect(restarted.draftFor(_conversationOne)?.isPending, isTrue);
    retryGate.complete();
    await _until(() => storage.draftIntents(_storageIdentity).isEmpty);
    expect(transport.requests, hasLength(2));
    expect(waits, [const Duration(seconds: 1)]);
    for (final request in transport.requests) {
      expect(request.body, offline.requests.single.body);
    }
    expect(restarted.draftFor(_conversationOne)?.isPending, isFalse);
    expect(restarted.draftFor(_conversationOne)?.draft.toJson(),
        {'kind': 'replaced', 'content': content.toJson()});
    await restarted.dispose();
    await store.close();
  });

  test('retained conflict preserves local and canonical reply metadata',
      () async {
    final local = _replyContent('local-source', false);
    final canonical = _replyContent('server-source', true);
    final store = NormalizedSnapshotStore();
    _installCanonicalDraft(store,
        canonicalRevision: 3, text: canonical.text, content: canonical);
    final storage = _RecordingStorage();
    await storage.replace(_retainedDraftRecord(
      baseRevision: 2,
      text: local.text,
      content: local,
      deviceMutationId: 'reply-conflict-device',
      idempotencyKey: 'reply-conflict-key',
    ));
    final retained = storage.draftIntents(_storageIdentity).single.toJson();
    final transport = _RecordingTransport(
        (_) async => fail('conflicted reply draft must not dispatch'));
    final client = _client(transport,
        storage: storage,
        storageIdentity: _storageIdentity,
        normalizedStore: store);
    await client.activateStorageIdentity(_storageIdentity);
    final projection = client.draftFor(_conversationOne)!;
    expect(projection.draft.toJson(),
        {'kind': 'replaced', 'content': local.toJson()});
    expect(projection.conflict?.canonicalRevision, 3);
    expect(projection.conflict?.canonicalDraft.toJson(),
        {'kind': 'replaced', 'content': canonical.toJson()});
    expect(storage.draftIntents(_storageIdentity).single.toJson(), retained);
    expect(await client.discardRetainedDraftConflict(_conversationOne), isTrue);
    expect(client.draftFor(_conversationOne)?.draft.toJson(),
        {'kind': 'replaced', 'content': canonical.toJson()});
    expect(storage.draftIntents(_storageIdentity), isEmpty);
    expect(transport.requests, isEmpty);
    await client.dispose();
    await store.close();
  });

  for (final nextIdentity in [
    ApplicationChatStorageIdentity(
        tenantId: const TenantId('other-tenant'),
        userId: _userId,
        deviceId: _storageIdentity.deviceId),
    ApplicationChatStorageIdentity(
        tenantId: _tenantId,
        userId: const UserId('other-user'),
        deviceId: _storageIdentity.deviceId),
  ]) {
    test('reply drafts isolate delayed HTTP across ${nextIdentity.tenantId.value}'
        '/${nextIdentity.userId.value}', () async {
      final response = Completer<HandrailChatHttpResponse>();
      final currentResponse = Completer<HandrailChatHttpResponse>();
      final storage = _RecordingStorage();
      var calls = 0;
      final transport = _RecordingTransport((_) =>
          calls++ == 0 ? response.future : currentResponse.future);
      final client = _client(transport,
          storage: storage, storageIdentity: _storageIdentity);
      await client.activateStorageIdentity(_storageIdentity);
      final oldContent = _replyContent('old-source', true);
      final command = client.synchronizeDraft(ChatReplaceDraftInput(
        conversationId: _conversationOne,
        baseRevision: 0,
        content: oldContent,
        deviceMutationId: 'old-reply-device',
        idempotencyKey: 'old-reply-key',
      ));
      await _until(() => transport.requests.isNotEmpty);
      final oldRequest = transport.requests.single;
      await client.activateStorageIdentity(nextIdentity);
      expect(await command, isA<ChatCommandClosed<SynchronizeDraftResult>>());
      expect(client.draftFor(_conversationOne), isNull);
      final newContent = _replyContent('new-source', false);
      final newCommand = client.synchronizeDraft(ChatReplaceDraftInput(
        conversationId: _conversationOne,
        baseRevision: 0,
        content: newContent,
        deviceMutationId: 'new-reply-device',
        idempotencyKey: 'new-reply-key',
      ));
      await _until(() => transport.requests.length == 2);
      final current = storage.draftIntents(nextIdentity).single.toJson();
      response.complete(_draftResponse(oldRequest, status: 'applied'));
      await _eventLoop();
      expect(client.draftFor(_conversationOne)?.draft.toJson(),
          {'kind': 'replaced', 'content': newContent.toJson()});
      expect(storage.draftIntents(nextIdentity).single.toJson(), current);
      expect(storage.draftIntents(_storageIdentity).single.request.toJson(),
          jsonDecode(oldRequest.body!));
      currentResponse.complete(
          _draftResponse(transport.requests.last, status: 'applied'));
      expect(await newCommand,
          isA<ChatCommandSuccess<SynchronizeDraftResult>>());
      expect(storage.draftIntents(nextIdentity), isEmpty);
      expect(client.draftFor(_conversationOne)?.draft.toJson(),
          {'kind': 'replaced', 'content': newContent.toJson()});
      await client.dispose();
    });
  }

  test('retains generated identities and the body across safe retries',
      () async {
    var attempts = 0;
    var deviceCalls = 0;
    var keyCalls = 0;
    final transport = _RecordingTransport((request) async {
      attempts += 1;
      if (attempts == 1) throw StateError('offline');
      return _draftResponse(request, status: 'replayed');
    });
    final client = _client(
      transport,
      generateDeviceMutationId: () {
        deviceCalls += 1;
        return 'stable-device-mutation';
      },
      generateIdempotencyKey: () {
        keyCalls += 1;
        return 'stable-idempotency-key';
      },
      retryOptions: ChatCommandRetryOptions(
        maxAttempts: 2,
        backoff: (_) => Duration.zero,
        wait: (_, __) async {},
      ),
    );

    final result = await client.synchronizeDraft(
      ChatReplaceDraftInput(
        conversationId: _conversationOne,
        baseRevision: 0,
        content: _content('retry me'),
      ),
    );

    expect(result, isA<ChatCommandSuccess<SynchronizeDraftResult>>());
    expect((deviceCalls, keyCalls), (1, 1));
    expect(transport.requests, hasLength(2));
    expect(transport.requests[0].body, transport.requests[1].body);
    expect(
      transport.requests
          .map((request) => request.headers['Idempotency-Key'])
          .toSet(),
      {'stable-idempotency-key'},
    );
    final body =
        jsonDecode(transport.requests.first.body!) as Map<String, Object?>;
    expect(body['deviceMutationId'], 'stable-device-mutation');

    await client.dispose();
  });

  test('validates the complete generated request before auth or transport',
      () async {
    var tokenCalls = 0;
    final storage = _RecordingStorage();
    final transport = _RecordingTransport(
      (_) async => fail('invalid draft reached transport'),
    );
    final client = _client(
      transport,
      tokenProvider: () async {
        tokenCalls += 1;
        return 'access-token';
      },
      generateIdempotencyKey: () => '',
      storage: storage,
      storageIdentity: _storageIdentity,
    );
    await client.activateStorageIdentity(_storageIdentity);

    final result = await client.synchronizeDraft(
      ChatReplaceDraftInput(
        conversationId: _conversationOne,
        baseRevision: 0,
        content: _content('invalid generated identity'),
      ),
    );

    expect(result, isA<ChatCommandValidationFailure<SynchronizeDraftResult>>());
    expect(storage.draftWriteStarted, 0);
    expect(tokenCalls, 0);
    expect(transport.requests, isEmpty);
    await client.dispose();
  });

  test('serializes per conversation while unrelated conversations progress',
      () async {
    final responses = <String, Completer<HandrailChatHttpResponse>>{};
    final transport = _RecordingTransport((request) {
      final body = jsonDecode(request.body!) as Map<String, Object?>;
      final key = body['idempotencyKey']! as String;
      return (responses[key] = Completer<HandrailChatHttpResponse>()).future;
    });
    final client = _client(transport);

    final first = client.synchronizeDraft(
      ChatReplaceDraftInput(
        conversationId: _conversationOne,
        baseRevision: 0,
        content: _content('one-first'),
        deviceMutationId: 'device-one-first',
        idempotencyKey: 'one-first',
      ),
    );
    final second = client.synchronizeDraft(
      ChatReplaceDraftInput(
        conversationId: _conversationOne,
        baseRevision: 1,
        content: _content('one-second'),
        deviceMutationId: 'device-one-second',
        idempotencyKey: 'one-second',
      ),
    );
    final other = client.synchronizeDraft(
      ChatReplaceDraftInput(
        conversationId: _conversationTwo,
        baseRevision: 0,
        content: _content('two-first'),
        deviceMutationId: 'device-two-first',
        idempotencyKey: 'two-first',
      ),
    );

    expect(_projectionText(client.draftFor(_conversationOne)), 'one-second');
    await _eventLoop();
    expect(responses.keys, containsAll(['one-first', 'two-first']));
    expect(responses, isNot(contains('one-second')));

    final firstRequest = _requestWithKey(transport, 'one-first');
    responses['one-first']!.complete(
      _draftResponse(firstRequest, status: 'applied'),
    );
    await _eventLoop();
    expect(responses, contains('one-second'));
    expect(_projectionText(client.draftFor(_conversationOne)), 'one-second');

    responses['one-second']!.complete(
      _draftResponse(
        _requestWithKey(transport, 'one-second'),
        status: 'replayed',
      ),
    );
    responses['two-first']!.complete(
      _draftResponse(
        _requestWithKey(transport, 'two-first'),
        status: 'applied',
      ),
    );
    expect(await first, isA<ChatCommandSuccess<SynchronizeDraftResult>>());
    expect(await second, isA<ChatCommandSuccess<SynchronizeDraftResult>>());
    expect(await other, isA<ChatCommandSuccess<SynchronizeDraftResult>>());
    expect(client.draftFor(_conversationOne)?.revision, 2);
    expect(client.draftFor(_conversationTwo)?.revision, 1);

    await client.dispose();
  });

  test('installs stale-base canonical state', () async {
    final transport = _RecordingTransport(
      (request) async => _draftResponse(
        request,
        status: 'stale_base',
        canonicalRevision: 5,
        canonicalText: 'server canonical',
      ),
    );
    final client = _client(transport);

    final result = await client.synchronizeDraft(
      ChatReplaceDraftInput(
        conversationId: _conversationOne,
        baseRevision: 1,
        content: _content('local stale'),
        deviceMutationId: 'stale-device',
        idempotencyKey: 'stale-key',
      ),
    );

    final value = (result as ChatCommandSuccess<SynchronizeDraftResult>).value;
    expect(
      value.reconciliationStatus,
      DraftMutationReconciliationStatus.staleBase,
    );
    expect(client.draftFor(_conversationOne)?.revision, 2);
    expect(_projectionText(client.draftFor(_conversationOne)), 'local stale');
    expect(client.draftFor(_conversationOne)?.isPending, isTrue);
    expect(client.draftFor(_conversationOne)?.conflict?.canonicalRevision, 5);

    await client.dispose();
  });

  test('newer private durable event wins over an older in-flight response',
      () async {
    final response = Completer<HandrailChatHttpResponse>();
    final transport = _RecordingTransport((_) => response.future);
    final client = _client(transport);
    final command = client.synchronizeDraft(
      ChatReplaceDraftInput(
        conversationId: _conversationOne,
        baseRevision: 0,
        content: _content('old local'),
        deviceMutationId: 'old-device',
        idempotencyKey: 'old-key',
      ),
    );
    await _eventLoop();

    expect(
      client.reconcileDraftEvent(
        _draftEvent(
          canonicalRevision: 2,
          updatedAt: '2026-08-26T15:02:00.000Z',
          text: 'new event',
        ),
      ),
      isTrue,
    );
    expect(
      client.reconcileDraftEvent(
        _draftEvent(
          canonicalRevision: 2,
          updatedAt: '2026-08-26T15:01:00.000Z',
          text: 'older timestamp',
          identity: 'older-timestamp',
        ),
      ),
      isFalse,
    );
    expect(
      client.reconcileDraftEvent(
        _draftEvent(
          canonicalRevision: 1,
          updatedAt: '2026-08-26T15:03:00.000Z',
          text: 'stale event',
          identity: 'stale',
        ),
      ),
      isFalse,
    );

    response.complete(
      _draftResponse(
        transport.requests.single,
        status: 'applied',
        updatedAt: '2026-08-26T15:04:00.000Z',
      ),
    );
    expect(await command, isA<ChatCommandSuccess<SynchronizeDraftResult>>());
    expect(client.draftFor(_conversationOne)?.revision, 2);
    expect(_projectionText(client.draftFor(_conversationOne)), 'new event');
    expect(client.draftFor(_conversationOne)?.isPending, isFalse);

    await client.dispose();
  });

  test('matching private event settles the optimistic draft immediately',
      () async {
    final response = Completer<HandrailChatHttpResponse>();
    final transport = _RecordingTransport((_) => response.future);
    final client = _client(transport);
    final command = client.synchronizeDraft(
      ChatReplaceDraftInput(
        conversationId: _conversationOne,
        baseRevision: 0,
        content: _content('matching canonical'),
        deviceMutationId: 'matching-device',
        idempotencyKey: 'matching-key',
      ),
    );
    await _eventLoop();
    expect(client.draftFor(_conversationOne)?.isPending, isTrue);

    expect(
      client.reconcileDraftEvent(
        _draftEvent(
          canonicalRevision: 1,
          updatedAt: '2026-08-26T15:02:00.000Z',
          text: 'matching canonical',
          identity: 'matching',
        ),
      ),
      isTrue,
    );
    expect(await command, isA<ChatCommandSuccess<SynchronizeDraftResult>>());
    expect(client.draftFor(_conversationOne)?.isPending, isFalse);
    expect(
      _projectionText(client.draftFor(_conversationOne)),
      'matching canonical',
    );

    response.complete(
      _draftResponse(
        transport.requests.single,
        status: 'replayed',
        updatedAt: '2026-08-26T15:02:00.000Z',
      ),
    );
    await _eventLoop();
    await client.dispose();
  });

  test('persists exact correlation before projection and transport', () async {
    final writeGate = Completer<void>();
    final response = Completer<HandrailChatHttpResponse>();
    var tokenCalls = 0;
    final storage = _RecordingStorage()..draftWriteGate = writeGate;
    final transport = _RecordingTransport((_) => response.future);
    final client = _client(
      transport,
      storage: storage,
      storageIdentity: _storageIdentity,
      tokenProvider: () async {
        tokenCalls += 1;
        return 'access-token';
      },
    );
    await client.activateStorageIdentity(_storageIdentity);

    final command = client.synchronizeDraft(
      ChatReplaceDraftInput(
        conversationId: _conversationOne,
        baseRevision: 0,
        content: _content('durable first'),
        deviceMutationId: 'persisted-device',
        idempotencyKey: 'persisted-key',
      ),
    );
    await _until(() => storage.draftWriteStarted == 1);
    expect(client.draftFor(_conversationOne), isNull);
    expect(transport.requests, isEmpty);
    expect(tokenCalls, 0);

    writeGate.complete();
    await _until(() => transport.requests.isNotEmpty);
    final firstRequest = transport.requests.first;
    final stored = storage.draftIntents(_storageIdentity).single.request;
    final transported = jsonDecode(firstRequest.body!) as Map<String, Object?>;
    expect(stored.deviceMutationId, 'persisted-device');
    expect(stored.idempotencyKey, 'persisted-key');
    expect(transported['deviceMutationId'], stored.deviceMutationId);
    expect(transported['idempotencyKey'], stored.idempotencyKey);
    expect(_projectionText(client.draftFor(_conversationOne)), 'durable first');

    final otherCommand = client.synchronizeDraft(
      ChatReplaceDraftInput(
        conversationId: _conversationOne,
        baseRevision: 1,
        content: _content('newer durable'),
        deviceMutationId: 'newer-device',
        idempotencyKey: 'newer-key',
      ),
    );
    await _until(() {
      final intents = storage.draftIntents(_storageIdentity);
      return intents.length == 1 &&
          intents.single.request.idempotencyKey == 'newer-key';
    });
    expect(transport.requests, hasLength(1));

    response.complete(
      _draftResponse(firstRequest, status: 'applied'),
    );
    expect(await command, isA<ChatCommandSuccess<SynchronizeDraftResult>>());
    await _until(() => transport.requests.length == 2);
    expect(
      await otherCommand,
      isA<ChatCommandMalformedResponse<SynchronizeDraftResult>>(),
    );
    expect(storage.draftIntents(_storageIdentity), hasLength(1));
    expect(
      storage.draftIntents(_storageIdentity).single.request.idempotencyKey,
      'newer-key',
    );
    await client.dispose();
  });

  test('coalescing and event settlement preserve newer exact intents',
      () async {
    final scheduler = _FakeDraftScheduler();
    final storage = _RecordingStorage();
    final transport = _RecordingTransport(
      (_) async => fail('debounced draft reached transport'),
    );
    final client = _client(
      transport,
      storage: storage,
      storageIdentity: _storageIdentity,
      scheduler: scheduler,
      debounce: const Duration(hours: 1),
    );
    await client.activateStorageIdentity(_storageIdentity);

    final first = client.synchronizeDraft(
      ChatReplaceDraftInput(
        conversationId: _conversationOne,
        baseRevision: 0,
        content: _content('first'),
        deviceMutationId: 'first-device',
        idempotencyKey: 'first-key',
      ),
    );
    final latest = client.synchronizeDraft(
      ChatReplaceDraftInput(
        conversationId: _conversationOne,
        baseRevision: 1,
        content: _content('latest'),
        deviceMutationId: 'latest-device',
        idempotencyKey: 'latest-key',
      ),
    );
    final other = client.synchronizeDraft(
      ChatReplaceDraftInput(
        conversationId: _conversationTwo,
        baseRevision: 0,
        content: _content('other'),
        deviceMutationId: 'other-device',
        idempotencyKey: 'other-key',
      ),
    );
    await _until(() => storage.draftIntents(_storageIdentity).length == 2);
    expect(
      storage
          .draftIntents(_storageIdentity)
          .map((intent) => intent.request.idempotencyKey),
      ['latest-key', 'other-key'],
    );

    expect(
      client.reconcileDraftEvent(
        _draftEvent(
          canonicalRevision: 1,
          updatedAt: '2026-08-26T15:02:00.000Z',
          text: 'first',
          identity: 'first-event',
          deviceMutationId: 'first-device',
          idempotencyKey: 'first-key',
        ),
      ),
      isTrue,
    );
    expect(await first, isA<ChatCommandSuccess<SynchronizeDraftResult>>());
    await _until(() => storage.draftIntents(_storageIdentity).length == 2);
    expect(
      storage
          .draftIntents(_storageIdentity)
          .map((intent) => intent.request.idempotencyKey),
      ['latest-key', 'other-key'],
    );

    expect(
      client.reconcileDraftEvent(
        _draftEvent(
          canonicalRevision: 2,
          updatedAt: '2026-08-26T15:03:00.000Z',
          text: 'latest',
          identity: 'latest-event',
          deviceMutationId: 'latest-device',
          idempotencyKey: 'latest-key',
        ),
      ),
      isTrue,
    );
    expect(await latest, isA<ChatCommandSuccess<SynchronizeDraftResult>>());
    await _until(() => storage.draftIntents(_storageIdentity).length == 1);
    expect(
      storage.draftIntents(_storageIdentity).single.request.idempotencyKey,
      'other-key',
    );
    expect(transport.requests, isEmpty);

    await client.dispose();
    expect(await other, isA<ChatCommandClosed<SynchronizeDraftResult>>());
  });

  test('concurrent runtimes atomically retain different conversations',
      () async {
    final storage = _AtomicDraftStorage();
    final first = _client(
      _RecordingTransport(
        (_) async => fail('debounced first draft reached transport'),
      ),
      storage: storage,
      storageIdentity: _storageIdentity,
      scheduler: _FakeDraftScheduler(),
      debounce: const Duration(hours: 1),
    );
    final second = _client(
      _RecordingTransport(
        (_) async => fail('debounced second draft reached transport'),
      ),
      storage: storage,
      storageIdentity: _storageIdentity,
      scheduler: _FakeDraftScheduler(),
      debounce: const Duration(hours: 1),
    );
    await first.activateStorageIdentity(_storageIdentity);
    await second.activateStorageIdentity(_storageIdentity);
    storage.blockNextDraftReads(2);

    final firstCommand = first.synchronizeDraft(
      ChatReplaceDraftInput(
        conversationId: _conversationOne,
        baseRevision: 0,
        content: _content('first conversation'),
        deviceMutationId: 'concurrent-first-device',
        idempotencyKey: 'concurrent-first-key',
      ),
    );
    final secondCommand = second.synchronizeDraft(
      ChatReplaceDraftInput(
        conversationId: _conversationTwo,
        baseRevision: 0,
        content: _content('second conversation'),
        deviceMutationId: 'concurrent-second-device',
        idempotencyKey: 'concurrent-second-key',
      ),
    );
    await storage.blockedDraftReads;
    storage.releaseDraftReads();
    await _until(() => storage.draftIntents(_storageIdentity).length == 2);

    final retained = storage.draftIntents(_storageIdentity);
    expect(
      retained.map((intent) => intent.request.conversationId).toSet(),
      {_conversationOne, _conversationTwo},
    );
    expect(retained.map((intent) => intent.enqueueOrder), [1, 2]);

    await first.dispose();
    await second.dispose();
    expect(
        await firstCommand, isA<ChatCommandClosed<SynchronizeDraftResult>>());
    expect(
      await secondCommand,
      isA<ChatCommandClosed<SynchronizeDraftResult>>(),
    );
  });

  test('stale settlement preserves a newer exact-correlation replacement',
      () async {
    final response = Completer<HandrailChatHttpResponse>();
    final storage = _AtomicDraftStorage();
    final client = _client(
      _RecordingTransport((_) => response.future),
      storage: storage,
      storageIdentity: _storageIdentity,
    );
    await client.activateStorageIdentity(_storageIdentity);

    final command = client.synchronizeDraft(
      ChatReplaceDraftInput(
        conversationId: _conversationOne,
        baseRevision: 0,
        content: _content('original'),
        deviceMutationId: 'exact-replacement-device',
        idempotencyKey: 'exact-replacement-key',
      ),
    );
    await _until(() => storage.draftIntents(_storageIdentity).isNotEmpty);
    final original = storage.draftIntents(_storageIdentity).single;
    final replacement = ApplicationChatQueuedDraftIntent(
      request: original.request,
      enqueueOrder: original.enqueueOrder + 1,
      enqueuedAt: const IsoTimestamp('2026-08-26T16:00:00.000Z'),
    );
    await storage.replace(
      ApplicationChatQueuedDraftIntentsRecord(
        identity: _storageIdentity,
        intents: [replacement],
      ),
    );

    response.complete(const HandrailChatHttpResponse(
      statusCode: 403,
      body: '{"error":{"code":"FORBIDDEN","message":"Forbidden."}}',
    ));
    expect(
      await command,
      isA<ChatCommandAuthenticationFailure<SynchronizeDraftResult>>(),
    );
    final retained = storage.draftIntents(_storageIdentity).single;
    expect(retained.enqueueOrder, replacement.enqueueOrder);
    expect(retained.enqueuedAt, replacement.enqueuedAt);
    expect(retained.request.idempotencyKey, 'exact-replacement-key');

    await client.dispose();
  });

  test('stale cancellation preserves a newer same-conversation intent',
      () async {
    final storage = _AtomicDraftStorage();
    final cancellation = ChatCommandCancellationController();
    final first = _client(
      _RecordingTransport(
        (_) async => fail('cancelled draft reached transport'),
      ),
      storage: storage,
      storageIdentity: _storageIdentity,
      scheduler: _FakeDraftScheduler(),
      debounce: const Duration(hours: 1),
    );
    final second = _client(
      _RecordingTransport(
        (_) async => fail('replacement draft reached transport'),
      ),
      storage: storage,
      storageIdentity: _storageIdentity,
      scheduler: _FakeDraftScheduler(),
      debounce: const Duration(hours: 1),
    );
    await first.activateStorageIdentity(_storageIdentity);

    final cancelled = first.synchronizeDraft(
      ChatReplaceDraftInput(
        conversationId: _conversationOne,
        baseRevision: 0,
        content: _content('cancel me'),
        deviceMutationId: 'stale-cancel-device',
        idempotencyKey: 'stale-cancel-key',
      ),
      cancellationSignal: cancellation.signal,
    );
    await _until(() => storage.draftIntents(_storageIdentity).isNotEmpty);
    await second.activateStorageIdentity(_storageIdentity);
    final replacement = second.synchronizeDraft(
      ChatReplaceDraftInput(
        conversationId: _conversationOne,
        baseRevision: 1,
        content: _content('keep me'),
        deviceMutationId: 'newer-cancel-device',
        idempotencyKey: 'newer-cancel-key',
      ),
    );
    await _until(
      () =>
          storage
              .draftIntents(_storageIdentity)
              .single
              .request
              .idempotencyKey ==
          'newer-cancel-key',
    );

    cancellation.cancel();
    expect(await cancelled, isA<ChatCommandAborted<SynchronizeDraftResult>>());
    expect(
      storage.draftIntents(_storageIdentity).single.request.idempotencyKey,
      'newer-cancel-key',
    );

    await first.dispose();
    await second.dispose();
    expect(await replacement, isA<ChatCommandClosed<SynchronizeDraftResult>>());
  });

  test('exact malformed quarantine preserves a concurrent valid replacement',
      () async {
    final storage = _AtomicDraftStorage()
      ..putRawDraftRecord({'malformed': true})
      ..blockNextDraftQuarantine();
    final diagnostics = <ChatClientDiagnostic>[];
    final client = _client(
      _RecordingTransport(
        (_) async => fail('retained draft without a baseline dispatched'),
      ),
      storage: storage,
      storageIdentity: _storageIdentity,
      onStorageDiagnostic: diagnostics.add,
    );

    final activation = client.activateStorageIdentity(_storageIdentity);
    await storage.quarantineStarted;
    await storage.replace(_retainedDraftRecord(
      baseRevision: 0,
      text: 'valid replacement',
      deviceMutationId: 'valid-replacement-device',
      idempotencyKey: 'valid-replacement-key',
    ));
    storage.releaseQuarantine();
    await activation;

    expect(storage.removeCount, 0);
    expect(
      storage.draftIntents(_storageIdentity).single.request.idempotencyKey,
      'valid-replacement-key',
    );
    expect(diagnostics.map((diagnostic) => diagnostic.code),
        contains('draft_intents_rejected'));

    await client.dispose();
  });

  test('optimistic draft overlays never mutate the canonical snapshot',
      () async {
    final store = NormalizedSnapshotStore();
    _installCanonicalDraft(
      store,
      canonicalRevision: 4,
      text: 'canonical server draft',
    );
    final storage = _AtomicDraftStorage();
    final client = _client(
      _RecordingTransport(
        (_) async => fail('debounced optimistic draft reached transport'),
      ),
      storage: storage,
      storageIdentity: _storageIdentity,
      normalizedStore: store,
      scheduler: _FakeDraftScheduler(),
      debounce: const Duration(hours: 1),
    );
    await client.activateStorageIdentity(_storageIdentity);

    final command = client.synchronizeDraft(
      ChatReplaceDraftInput(
        conversationId: _conversationOne,
        baseRevision: 4,
        content: _content('optimistic local draft'),
        deviceMutationId: 'canonical-overlay-device',
        idempotencyKey: 'canonical-overlay-key',
      ),
    );
    await _until(() => storage.draftIntents(_storageIdentity).isNotEmpty);

    expect(_projectionText(client.draftFor(_conversationOne)),
        'optimistic local draft');
    expect(client.draftFor(_conversationOne)?.isPending, isTrue);
    expect(store.state.draftRevisions[_conversationOne], 4);
    expect(
      switch (store.state.currentUserDrafts[_conversationOne]) {
        CanonicalReplacedDraft(:final content) => content.text,
        _ => null,
      },
      'canonical server draft',
    );

    await client.dispose();
    expect(await command, isA<ChatCommandClosed<SynchronizeDraftResult>>());
    await store.close();
  });

  test('retains durable intent and optimistic state for ambiguous outcomes',
      () async {
    for (final response in <HandrailChatHttpResponse>[
      const HandrailChatHttpResponse(statusCode: 503, body: '{}'),
      const HandrailChatHttpResponse(statusCode: 200, body: '{}'),
    ]) {
      final storage = _RecordingStorage();
      final transport = _RecordingTransport((_) async => response);
      final client = _client(
        transport,
        storage: storage,
        storageIdentity: _storageIdentity,
      );
      await client.activateStorageIdentity(_storageIdentity);

      final result = await client.synchronizeDraft(
        ChatReplaceDraftInput(
          conversationId: _conversationOne,
          baseRevision: 0,
          content: _content('retain me'),
          deviceMutationId: 'retain-device-${response.statusCode}',
          idempotencyKey: 'retain-key-${response.statusCode}',
        ),
      );

      if (response.statusCode == 503) {
        expect(
            result, isA<ChatCommandTransportFailure<SynchronizeDraftResult>>());
      } else {
        expect(result,
            isA<ChatCommandMalformedResponse<SynchronizeDraftResult>>());
      }
      expect(storage.draftIntents(_storageIdentity), hasLength(1));
      expect(client.draftFor(_conversationOne)?.isPending, isTrue);
      expect(_projectionText(client.draftFor(_conversationOne)), 'retain me');
      await client.dispose();
    }
  });

  test('conflict preserves the durable local intent for explicit resolution',
      () async {
    final storage = _RecordingStorage();
    final transport = _RecordingTransport(
      (_) async => const HandrailChatHttpResponse(
        statusCode: 409,
        body: '{"error":{"code":"CONFLICT","message":"Conflict."}}',
      ),
    );
    final client = _client(
      transport,
      storage: storage,
      storageIdentity: _storageIdentity,
    );
    await client.activateStorageIdentity(_storageIdentity);
    expect(
      client.reconcileDraftEvent(
        _draftEvent(
          canonicalRevision: 4,
          updatedAt: '2026-08-26T15:00:00.000Z',
          text: 'authoritative',
        ),
      ),
      isTrue,
    );

    final result = await client.synchronizeDraft(
      ChatReplaceDraftInput(
        conversationId: _conversationOne,
        baseRevision: 4,
        content: _content('rejected local'),
        deviceMutationId: 'terminal-device',
        idempotencyKey: 'terminal-key',
      ),
    );

    expect(result, isA<ChatCommandConflict<SynchronizeDraftResult>>());
    expect(storage.draftIntents(_storageIdentity), hasLength(1));
    expect(client.draftFor(_conversationOne)?.isPending, isTrue);
    expect(
        _projectionText(client.draftFor(_conversationOne)), 'rejected local');
    expect(client.draftFor(_conversationOne)?.conflict?.canonicalRevision, 4);
    await client.dispose();
  });

  test('terminal authorization failure removes the optimistic intent',
      () async {
    final storage = _RecordingStorage();
    final transport = _RecordingTransport(
      (_) async => const HandrailChatHttpResponse(
        statusCode: 403,
        body: '{"error":{"code":"FORBIDDEN","message":"Forbidden."}}',
      ),
    );
    final client = _client(
      transport,
      storage: storage,
      storageIdentity: _storageIdentity,
    );
    await client.activateStorageIdentity(_storageIdentity);

    final result = await client.synchronizeDraft(
      ChatReplaceDraftInput(
        conversationId: _conversationOne,
        baseRevision: 0,
        content: _content('not authorized'),
        deviceMutationId: 'forbidden-device',
        idempotencyKey: 'forbidden-key',
      ),
    );

    expect(
      result,
      isA<ChatCommandAuthenticationFailure<SynchronizeDraftResult>>(),
    );
    expect(storage.draftIntents(_storageIdentity), isEmpty);
    expect(client.draftFor(_conversationOne), isNull);
    await client.dispose();
  });

  test('storage failure prevents projection, authentication, and transport',
      () async {
    var tokenCalls = 0;
    final storage = _RecordingStorage()..failDraftWrites = true;
    final transport = _RecordingTransport(
      (_) async => fail('unpersisted draft reached transport'),
    );
    final client = _client(
      transport,
      storage: storage,
      storageIdentity: _storageIdentity,
      tokenProvider: () async {
        tokenCalls += 1;
        return 'access-token';
      },
    );
    await client.activateStorageIdentity(_storageIdentity);

    final mutation = client.synchronizeDraftWithLocalPersistence(
      ChatReplaceDraftInput(
        conversationId: _conversationOne,
        baseRevision: 0,
        content: _content('never visible'),
        deviceMutationId: 'failed-device',
        idempotencyKey: 'failed-key',
      ),
    );

    expect(
      (await mutation.localPersistence as ChatDraftNotPersisted).reason,
      ChatDraftNotPersistedReason.storageFailure,
    );
    expect(await mutation.remoteSettlement,
        isA<ChatCommandTransportFailure<SynchronizeDraftResult>>());
    expect(storage.draftIntents(_storageIdentity), isEmpty);
    expect(client.draftFor(_conversationOne), isNull);
    expect(tokenCalls, 0);
    expect(transport.requests, isEmpty);
    await client.dispose();
  });

  test('cancellation removes only never-dispatched durable work', () async {
    final scheduler = _FakeDraftScheduler();
    final activeResponse = Completer<HandrailChatHttpResponse>();
    final storage = _RecordingStorage();
    final transport = _RecordingTransport((_) => activeResponse.future);
    final client = _client(
      transport,
      storage: storage,
      storageIdentity: _storageIdentity,
      scheduler: scheduler,
      debounce: const Duration(milliseconds: 10),
    );
    await client.activateStorageIdentity(_storageIdentity);

    final scheduledCancellation = ChatCommandCancellationController();
    final scheduled = client.synchronizeDraft(
      ChatReplaceDraftInput(
        conversationId: _conversationOne,
        baseRevision: 0,
        content: _content('cancel before send'),
        deviceMutationId: 'scheduled-durable-device',
        idempotencyKey: 'scheduled-durable-key',
      ),
      cancellationSignal: scheduledCancellation.signal,
    );
    await _until(() => storage.draftIntents(_storageIdentity).isNotEmpty);
    scheduledCancellation.cancel();
    expect(await scheduled, isA<ChatCommandAborted<SynchronizeDraftResult>>());
    expect(storage.draftIntents(_storageIdentity), isEmpty);
    expect(client.draftFor(_conversationOne), isNull);

    final activeCancellation = ChatCommandCancellationController();
    final active = client.synchronizeDraft(
      ChatReplaceDraftInput(
        conversationId: _conversationOne,
        baseRevision: 0,
        content: _content('cancel after send'),
        deviceMutationId: 'active-durable-device',
        idempotencyKey: 'active-durable-key',
      ),
      cancellationSignal: activeCancellation.signal,
    );
    await _until(() => storage.draftIntents(_storageIdentity).isNotEmpty);
    scheduler.advance(const Duration(milliseconds: 10));
    await _until(() => transport.requests.isNotEmpty);
    activeCancellation.cancel();
    expect(await active, isA<ChatCommandAborted<SynchronizeDraftResult>>());
    expect(storage.draftIntents(_storageIdentity), hasLength(1));
    expect(client.draftFor(_conversationOne)?.isPending, isTrue);

    activeResponse.complete(
      _draftResponse(transport.requests.single, status: 'applied'),
    );
    await client.dispose();
  });

  test('delayed old-identity HTTP completion cannot settle current state',
      () async {
    final response = Completer<HandrailChatHttpResponse>();
    final storage = _RecordingStorage();
    final transport = _RecordingTransport((_) => response.future);
    final client = _client(
      transport,
      storage: storage,
      storageIdentity: _storageIdentity,
    );
    await client.activateStorageIdentity(_storageIdentity);
    final command = client.synchronizeDraft(
      ChatReplaceDraftInput(
        conversationId: _conversationOne,
        baseRevision: 0,
        content: _content('old in flight'),
        deviceMutationId: 'old-http-device',
        idempotencyKey: 'old-http-key',
      ),
    );
    await _until(() => transport.requests.isNotEmpty);

    await client.activateStorageIdentity(_otherStorageIdentity);
    expect(await command, isA<ChatCommandClosed<SynchronizeDraftResult>>());
    response.complete(
      _draftResponse(transport.requests.single, status: 'applied'),
    );
    await _eventLoop();

    expect(client.draftFor(_conversationOne), isNull);
    expect(storage.draftIntents(_storageIdentity), hasLength(1));
    expect(storage.draftIntents(_otherStorageIdentity), isEmpty);
    await client.dispose();
  });

  test('delayed persistence is isolated after identity change and dispose',
      () async {
    final firstGate = Completer<void>();
    final storage = _RecordingStorage()..draftWriteGate = firstGate;
    final transport = _RecordingTransport(
      (_) async => fail('invalidated draft reached transport'),
    );
    final client = _client(
      transport,
      storage: storage,
      storageIdentity: _storageIdentity,
    );
    await client.activateStorageIdentity(_storageIdentity);
    final oldCommand = client.synchronizeDraftWithLocalPersistence(
      ChatReplaceDraftInput(
        conversationId: _conversationOne,
        baseRevision: 0,
        content: _replyContent('old-persisted-source', false),
        deviceMutationId: 'old-identity-device',
        idempotencyKey: 'old-identity-key',
      ),
    );
    await _until(() => storage.draftWriteStarted == 1);
    final activation = client.activateStorageIdentity(_otherStorageIdentity);
    final oldLocal = await oldCommand.localPersistence;
    expect((oldLocal as ChatDraftNotPersisted).reason,
        ChatDraftNotPersistedReason.identityChanged);
    expect(await oldCommand.remoteSettlement,
        isA<ChatCommandClosed<SynchronizeDraftResult>>());
    expect(firstGate.isCompleted, isFalse);
    firstGate.complete();
    await activation;
    await _eventLoop();
    expect(await oldCommand.localPersistence, same(oldLocal));
    expect(client.draftFor(_conversationOne), isNull);
    expect(
        (storage.draftIntents(_storageIdentity).single.request
                as ReplaceDraftInput)
            .content
            .toJson(),
        _replyContent('old-persisted-source', false).toJson());
    expect(storage.draftIntents(_otherStorageIdentity), isEmpty);
    expect(transport.requests, isEmpty);

    final secondGate = Completer<void>();
    storage.draftWriteGate = secondGate;
    final disposedCommand = client.synchronizeDraftWithLocalPersistence(
      ChatReplaceDraftInput(
        conversationId: _conversationOne,
        baseRevision: 0,
        content: _replyContent('disposed-source', true),
        deviceMutationId: 'dispose-device',
        idempotencyKey: 'dispose-key',
      ),
    );
    await _until(() => storage.draftWriteStarted == 2);
    final disposal = client.dispose();
    final disposedLocal = await disposedCommand.localPersistence;
    expect((disposedLocal as ChatDraftNotPersisted).reason,
        ChatDraftNotPersistedReason.closed);
    expect(
      await disposedCommand.remoteSettlement,
      isA<ChatCommandClosed<SynchronizeDraftResult>>(),
    );
    expect(secondGate.isCompleted, isFalse);
    secondGate.complete();
    await disposal;
    expect(await disposedCommand.localPersistence, same(disposedLocal));
    expect(transport.requests, isEmpty);
    expect(
        (storage.draftIntents(_otherStorageIdentity).single.request
                as ReplaceDraftInput)
            .content
            .toJson(),
        _replyContent('disposed-source', true).toJson());
  });

  test('uses the injected scheduler for deterministic debounce', () async {
    final scheduler = _FakeDraftScheduler();
    final transport = _RecordingTransport(
      (request) async => _draftResponse(request, status: 'applied'),
    );
    final client = _client(
      transport,
      scheduler: scheduler,
      debounce: const Duration(milliseconds: 100),
    );
    final first = client.synchronizeDraft(
      ChatReplaceDraftInput(
        conversationId: _conversationOne,
        baseRevision: 0,
        content: _content('first'),
        deviceMutationId: 'first-device',
        idempotencyKey: 'first-key',
      ),
    );
    scheduler.advance(const Duration(milliseconds: 60));
    final second = client.synchronizeDraft(
      ChatReplaceDraftInput(
        conversationId: _conversationOne,
        baseRevision: 1,
        content: _content('second'),
        deviceMutationId: 'second-device',
        idempotencyKey: 'second-key',
      ),
    );

    expect(transport.requests, isEmpty);
    expect(scheduler.cancelledCount, 1);
    scheduler.advance(const Duration(milliseconds: 99));
    await _eventLoop();
    expect(transport.requests, isEmpty);
    scheduler.advance(const Duration(milliseconds: 1));
    await _eventLoop();
    expect(transport.requests, hasLength(2));
    expect(await first, isA<ChatCommandSuccess<SynchronizeDraftResult>>());
    expect(await second, isA<ChatCommandSuccess<SynchronizeDraftResult>>());
    expect(_projectionText(client.draftFor(_conversationOne)), 'second');

    await client.dispose();
  });

  test('cancels before dispatch, while scheduled and queued, and in transport',
      () async {
    final scheduler = _FakeDraftScheduler();
    final activeResponse = Completer<HandrailChatHttpResponse>();
    final transport = _RecordingTransport((_) => activeResponse.future);
    final client = _client(
      transport,
      scheduler: scheduler,
      debounce: const Duration(milliseconds: 10),
    );

    final beforeController = ChatCommandCancellationController()..cancel();
    final before = await client.synchronizeDraft(
      ChatClearDraftInput(
        conversationId: _conversationOne,
        baseRevision: 0,
        deviceMutationId: 'before-device',
        idempotencyKey: 'before-key',
      ),
      cancellationSignal: beforeController.signal,
    );
    expect(before, isA<ChatCommandAborted<SynchronizeDraftResult>>());

    final scheduledController = ChatCommandCancellationController();
    final scheduled = client.synchronizeDraft(
      ChatReplaceDraftInput(
        conversationId: _conversationOne,
        baseRevision: 0,
        content: _content('scheduled'),
        deviceMutationId: 'scheduled-device',
        idempotencyKey: 'scheduled-key',
      ),
      cancellationSignal: scheduledController.signal,
    );
    scheduledController.cancel();
    expect(await scheduled, isA<ChatCommandAborted<SynchronizeDraftResult>>());
    expect(client.draftFor(_conversationOne), isNull);

    final activeController = ChatCommandCancellationController();
    final active = client.synchronizeDraft(
      ChatReplaceDraftInput(
        conversationId: _conversationOne,
        baseRevision: 0,
        content: _content('active'),
        deviceMutationId: 'active-device',
        idempotencyKey: 'active-key',
      ),
      cancellationSignal: activeController.signal,
    );
    scheduler.advance(const Duration(milliseconds: 10));
    await _eventLoop();
    expect(transport.requests, hasLength(1));

    final queuedController = ChatCommandCancellationController();
    final queued = client.synchronizeDraft(
      ChatReplaceDraftInput(
        conversationId: _conversationOne,
        baseRevision: 1,
        content: _content('queued'),
        deviceMutationId: 'queued-device',
        idempotencyKey: 'queued-key',
      ),
      cancellationSignal: queuedController.signal,
    );
    queuedController.cancel();
    expect(await queued, isA<ChatCommandAborted<SynchronizeDraftResult>>());
    expect(_projectionText(client.draftFor(_conversationOne)), 'active');

    activeController.cancel();
    expect(await active, isA<ChatCommandAborted<SynchronizeDraftResult>>());
    final signal = transport.requests.single.cancellationSignal
        as ChatCommandCancellationSignal;
    expect(signal.isCancelled, isTrue);
    expect(transport.requests, hasLength(1));

    await client.dispose();
  });

  test('close settles scheduled, queued, and active work without later emits',
      () async {
    final scheduler = _FakeDraftScheduler();
    final activeResponse = Completer<HandrailChatHttpResponse>();
    final transport = _RecordingTransport((_) => activeResponse.future);
    final client = _client(
      transport,
      scheduler: scheduler,
      debounce: const Duration(milliseconds: 10),
    );
    final emissions = <ChatDraftProjection?>[];
    final done = Completer<void>();
    client.draftStatesFor(_conversationOne).listen(
          emissions.add,
          onDone: done.complete,
        );

    final active = client.synchronizeDraft(
      ChatReplaceDraftInput(
        conversationId: _conversationOne,
        baseRevision: 0,
        content: _content('active'),
        deviceMutationId: 'close-active-device',
        idempotencyKey: 'close-active',
      ),
    );
    scheduler.advance(const Duration(milliseconds: 10));
    await _eventLoop();
    final queued = client.synchronizeDraft(
      ChatReplaceDraftInput(
        conversationId: _conversationOne,
        baseRevision: 1,
        content: _content('queued'),
        deviceMutationId: 'close-queued-device',
        idempotencyKey: 'close-queued',
      ),
    );
    final scheduled = client.synchronizeDraft(
      const ChatClearDraftInput(
        conversationId: _conversationTwo,
        baseRevision: 0,
        deviceMutationId: 'close-scheduled-device',
        idempotencyKey: 'close-scheduled',
      ),
    );
    await _eventLoop();
    final beforeClose = emissions.length;

    await client.dispose();
    expect(await active, isA<ChatCommandClosed<SynchronizeDraftResult>>());
    expect(await queued, isA<ChatCommandClosed<SynchronizeDraftResult>>());
    expect(await scheduled, isA<ChatCommandClosed<SynchronizeDraftResult>>());
    await done.future;
    expect(scheduler.activeCount, 0);
    expect(
      await client.synchronizeDraft(
        const ChatClearDraftInput(
          conversationId: _conversationOne,
          baseRevision: 2,
        ),
      ),
      isA<ChatCommandClosed<SynchronizeDraftResult>>(),
    );

    activeResponse.complete(
      _draftResponse(
        transport.requests.single,
        status: 'applied',
      ),
    );
    await _eventLoop();
    expect(emissions, hasLength(beforeClose));
  });

  group('retained draft recovery', () {
    test('waits for an equal authoritative base and replays exact correlation',
        () async {
      final store = NormalizedSnapshotStore();
      _installCanonicalDraft(
        store,
        canonicalRevision: 1,
        text: 'older canonical',
      );
      final storage = _RecordingStorage();
      await storage.replace(_retainedDraftRecord(
        baseRevision: 2,
        text: 'retained local',
        deviceMutationId: 'retained-device',
        idempotencyKey: 'retained-key',
      ));
      final transport = _RecordingTransport(
        (request) async => _draftResponse(request, status: 'replayed'),
      );
      final client = _client(
        transport,
        storage: storage,
        storageIdentity: _storageIdentity,
        normalizedStore: store,
      );
      await client.activateStorageIdentity(_storageIdentity);
      await _eventLoop();
      expect(transport.requests, isEmpty);
      expect(client.draftFor(_conversationOne), isNull);

      _installCanonicalDraft(
        store,
        canonicalRevision: 2,
        text: 'authoritative base',
      );
      await _until(() => transport.requests.length == 1);
      final body =
          jsonDecode(transport.requests.single.body!) as Map<String, Object?>;
      expect(body['baseRevision'], 2);
      expect(body['deviceMutationId'], 'retained-device');
      expect(body['idempotencyKey'], 'retained-key');
      await _until(() => storage.draftIntents(_storageIdentity).isEmpty);
      await client.dispose();
      await store.close();
    });

    test('retries only an ambiguous retained result with bounded hooks',
        () async {
      final store = NormalizedSnapshotStore();
      _installCanonicalDraft(
        store,
        canonicalRevision: 2,
        text: 'authoritative base',
      );
      final storage = _RecordingStorage();
      await storage.replace(_retainedDraftRecord(
        baseRevision: 2,
        text: 'retry local',
        deviceMutationId: 'retry-retained-device',
        idempotencyKey: 'retry-retained-key',
      ));
      var attempt = 0;
      final waits = <Duration>[];
      final transport = _RecordingTransport((request) async {
        attempt += 1;
        if (attempt == 1) throw StateError('ambiguous transport');
        return _draftResponse(request, status: 'replayed');
      });
      final client = _client(
        transport,
        storage: storage,
        storageIdentity: _storageIdentity,
        normalizedStore: store,
        retainedDraftRetryBackoff: (_) => const Duration(days: 1),
        retainedDraftRetryWait: (delay, _) async => waits.add(delay),
      );
      await client.activateStorageIdentity(_storageIdentity);
      await _until(() => transport.requests.length == 2);
      expect(waits, [const Duration(seconds: 30)]);
      expect(transport.requests[0].body, transport.requests[1].body);
      await _until(() => storage.draftIntents(_storageIdentity).isEmpty);
      await client.dispose();
      await store.close();
    });

    test('preserves newer-server conflict and local content until discard',
        () async {
      final store = NormalizedSnapshotStore();
      _installCanonicalDraft(
        store,
        canonicalRevision: 3,
        text: 'newer server',
      );
      final storage = _RecordingStorage();
      await storage.replace(_retainedDraftRecord(
        baseRevision: 2,
        text: 'preserve local',
        deviceMutationId: 'conflict-retained-device',
        idempotencyKey: 'conflict-retained-key',
      ));
      final transport = _RecordingTransport(
        (_) async => fail('conflicted retained draft must not dispatch'),
      );
      final client = _client(
        transport,
        storage: storage,
        storageIdentity: _storageIdentity,
        normalizedStore: store,
      );
      await client.activateStorageIdentity(_storageIdentity);
      final projection = client.draftFor(_conversationOne);
      expect(_projectionText(projection), 'preserve local');
      expect(projection?.conflict?.canonicalRevision, 3);
      expect(storage.draftIntents(_storageIdentity), hasLength(1));
      expect(transport.requests, isEmpty);

      expect(
          await client.discardRetainedDraftConflict(_conversationOne), isTrue);
      expect(storage.draftIntents(_storageIdentity), isEmpty);
      expect(
          _projectionText(client.draftFor(_conversationOne)), 'newer server');
      await client.dispose();
      await store.close();
    });

    test('matching canonical event settles before ambiguous HTTP completes',
        () async {
      final store = NormalizedSnapshotStore();
      _installCanonicalDraft(
        store,
        canonicalRevision: 2,
        text: 'authoritative base',
      );
      final storage = _RecordingStorage();
      await storage.replace(_retainedDraftRecord(
        baseRevision: 2,
        text: 'event local',
        deviceMutationId: 'event-retained-device',
        idempotencyKey: 'event-retained-key',
      ));
      final response = Completer<HandrailChatHttpResponse>();
      final transport = _RecordingTransport((_) => response.future);
      final client = _client(
        transport,
        storage: storage,
        storageIdentity: _storageIdentity,
        normalizedStore: store,
      );
      await client.activateStorageIdentity(_storageIdentity);
      await _until(() => transport.requests.length == 1);
      expect(
        client.reconcileDraftEvent(_draftEvent(
          canonicalRevision: 3,
          updatedAt: '2026-08-26T15:00:01.000Z',
          text: 'event local',
          deviceMutationId: 'event-retained-device',
          idempotencyKey: 'event-retained-key',
        )),
        isTrue,
      );
      await _until(() => storage.draftIntents(_storageIdentity).isEmpty);
      expect(client.draftFor(_conversationOne)?.isPending, isFalse);
      await client.dispose();
      await store.close();
    });

    test('quarantines only a corrupt active-identity draft record', () async {
      final store = NormalizedSnapshotStore();
      _installCanonicalDraft(
        store,
        canonicalRevision: 2,
        text: 'authoritative base',
      );
      final storage = _RecordingStorage();
      await storage.replace(ApplicationChatQueuedDraftIntentsRecord(
        identity: _otherStorageIdentity,
        intents: [
          _retainedDraftRecord(
            baseRevision: 2,
            text: 'other local',
            deviceMutationId: 'other-device',
            idempotencyKey: 'other-key',
          ).intents.single,
        ],
      ));
      storage.draftReadOverride = ApplicationChatRealtimeCursorRecord(
        identity: _storageIdentity,
        cursor: const EventCursor(eventId: 'wrong-kind'),
      );
      final diagnostics = <ChatClientDiagnostic>[];
      final client = HandrailChatClient(
        apiBaseUri: Uri.parse('https://chat.example.test/api/chat'),
        tokenProvider: () async => 'access-token',
        transport: _RecordingTransport(
          (_) async => fail('corrupt retained draft must not dispatch'),
        ),
        localStorage: storage,
        storageIdentity: _storageIdentity,
        normalizedSnapshotStore: store,
        onStorageDiagnostic: diagnostics.add,
      );
      await client.activateStorageIdentity(_storageIdentity);
      expect(
        storage.removals,
        contains((
          _storageIdentity,
          ApplicationChatStorageRecordKind.queuedDraftIntents,
        )),
      );
      expect(
        storage.draftIntents(_otherStorageIdentity),
        hasLength(1),
      );
      expect(diagnostics.single.code, 'draft_intents_rejected');
      await client.dispose();
      await store.close();
    });

    test('dispose cancels retained HTTP and leaves storage recoverable',
        () async {
      final store = NormalizedSnapshotStore();
      _installCanonicalDraft(
        store,
        canonicalRevision: 2,
        text: 'authoritative base',
      );
      final storage = _RecordingStorage();
      await storage.replace(_retainedDraftRecord(
        baseRevision: 2,
        text: 'dispose retained',
        deviceMutationId: 'dispose-retained-device',
        idempotencyKey: 'dispose-retained-key',
      ));
      final response = Completer<HandrailChatHttpResponse>();
      final transport = _RecordingTransport((_) => response.future);
      final client = _client(
        transport,
        storage: storage,
        storageIdentity: _storageIdentity,
        normalizedStore: store,
      );
      await client.activateStorageIdentity(_storageIdentity);
      await _until(() => transport.requests.length == 1);
      await client.dispose();
      expect(
        (transport.requests.single.cancellationSignal
                as ChatCommandCancellationSignal?)
            ?.isCancelled,
        isTrue,
      );
      expect(storage.draftIntents(_storageIdentity), hasLength(1));
      await store.close();
    });

    test('offline local ack precedes remote settlement and retained recovery',
        () async {
      final store = NormalizedSnapshotStore();
      _installCanonicalDraft(
        store,
        canonicalRevision: 2,
        text: 'authoritative base',
      );
      final storage = _RecordingStorage();
      await storage.replace(_retainedDraftRecord(
        baseRevision: 2,
        text: 'lifecycle retained',
        deviceMutationId: 'lifecycle-device',
        idempotencyKey: 'lifecycle-key',
      ));
      final network = _MutableRealtimeNetwork(false);
      final sockets = <_DraftRealtimeSocket>[];
      final realtime = ChatRealtimeSessionTransport(
        endpoint: Uri.parse('https://chat.example.test/api/chat'),
        clientPackageVersion: '0.1.3',
        protocolVersion: handrailChatProtocolVersion,
        tokenProvider: () async => 'realtime-token',
        socketFactory: (_, __) {
          final socket = _DraftRealtimeSocket();
          sockets.add(socket);
          return socket;
        },
        network: network,
      );
      final transport = _RecordingTransport((request) async {
        if (request.method == 'GET') {
          return HandrailChatHttpResponse(
            statusCode: 200,
            body: jsonEncode({
              'packageVersion': '0.1.3',
              'protocolVersion': handrailChatProtocolVersion,
              'schemaVersion': 1,
              'enabledFeatures': <String, Object?>{'realtime': true},
              'supportedProtocolRange': <String, Object?>{
                'minimumVersion': 3,
                'maximumVersion': handrailChatProtocolVersion,
              },
            }),
          );
        }
        return _draftResponse(request, status: 'replayed');
      });
      var deviceCalls = 0;
      var keyCalls = 0;
      final client = HandrailChatClient(
        apiBaseUri: Uri.parse('https://chat.example.test/api/chat'),
        tokenProvider: () async => 'access-token',
        transport: transport,
        localStorage: storage,
        storageIdentity: _storageIdentity,
        normalizedSnapshotStore: store,
        realtimeSession: realtime,
        generateDraftDeviceMutationId: () {
          deviceCalls += 1;
          return 'offline-device';
        },
        generateIdempotencyKey: () {
          keyCalls += 1;
          return 'offline-key';
        },
      );
      await client.initialize();
      client.setApplicationForeground(false);
      await realtime.start();
      expect(transport.requests.where((request) => request.method == 'PATCH'),
          isEmpty);

      final gate = Completer<void>();
      storage.draftWriteGate = gate;
      final writesBefore = storage.draftWriteStarted;
      final content = _replyContent('offline-source', false);
      final mutation = client.synchronizeDraftWithLocalPersistence(
        ChatReplaceDraftInput(
          conversationId: _conversationTwo,
          baseRevision: 0,
          content: content,
        ),
      );
      var localCompleted = false;
      var remoteCompleted = false;
      unawaited(mutation.localPersistence.then((_) => localCompleted = true));
      unawaited(mutation.remoteSettlement.then((_) => remoteCompleted = true));
      await _until(() => storage.draftWriteStarted > writesBefore);
      await _eventLoop();
      expect(localCompleted, isFalse);
      expect(remoteCompleted, isFalse);
      expect(storage.draftIntents(_storageIdentity), hasLength(1));
      gate.complete();
      final local =
          await mutation.localPersistence as ChatDraftLocallyPersisted;
      final expected = {
        'operation': 'synchronize_draft',
        'intent': 'replace',
        'conversationId': _conversationTwo.value,
        'baseRevision': 0,
        'deviceMutationId': 'offline-device',
        'idempotencyKey': 'offline-key',
        'content': content.toJson(),
      };
      expect(local.identity, _storageIdentity);
      expect(local.request.toJson(), expected);
      expect(storage.draftIntents(_storageIdentity).last.request.toJson(),
          expected);
      expect(client.draftFor(_conversationTwo)?.draft.toJson(),
          {'kind': 'replaced', 'content': content.toJson()});
      expect((deviceCalls, keyCalls), (1, 1));
      await _eventLoop();
      expect(remoteCompleted, isFalse);
      expect(transport.requests.where((request) => request.method == 'PATCH'),
          isEmpty);

      network.setOnline(true);
      await _until(() => sockets.isNotEmpty);
      sockets.single.emit({
        'type': 'chat.session.accepted',
        'metadata': {
          'packageVersion': '0.1.3',
          'protocolVersion': handrailChatProtocolVersion,
          'schemaVersion': 1,
          'enabledFeatures': <String, Object?>{'realtime': true},
          'supportedProtocolRange': <String, Object?>{
            'minimumVersion': 3,
            'maximumVersion': handrailChatProtocolVersion,
          },
        },
        'tenantId': _tenantId.value,
        'actorStreamId': 'user:${_userId.value}',
        'deviceId': _storageIdentity.deviceId.value,
        'sessionId': 'session-1',
      });
      await _eventLoop();
      expect(transport.requests.where((request) => request.method == 'PATCH'),
          isEmpty);

      client.setApplicationForeground(true);
      await _until(() =>
          transport.requests
              .where((request) => request.method == 'PATCH')
              .length ==
          2);
      final remote = await mutation.remoteSettlement
          as ChatCommandSuccess<SynchronizeDraftResult>;
      expect(remote.value.reconciliationStatus,
          DraftMutationReconciliationStatus.replayed);
      expect(remote.value.deviceMutationId, local.request.deviceMutationId);
      expect(remote.value.idempotencyKey, local.request.idempotencyKey);
      final authoredRequest = transport.requests.singleWhere((request) =>
          request.method == 'PATCH' &&
          request.uri.path.contains(_conversationTwo.value));
      expect(jsonDecode(authoredRequest.body!), expected);
      expect(authoredRequest.headers['Idempotency-Key'], 'offline-key');
      expect((deviceCalls, keyCalls), (1, 1));
      await _until(() => storage.draftIntents(_storageIdentity).isEmpty);
      await client.dispose();
      await realtime.dispose();
      await store.close();
    });
  });
}

DraftContent _replyContent(String? messageId, bool notifyAuthor) =>
    DraftContent.fromJson({
      'format': 'markdown',
      'text': 'Friday **works**',
      'mentions': [
        {'type': 'user', 'userId': 'mentioned-user'},
      ],
      'attachments': [
        {'attachmentId': 'draft-attachment'},
      ],
      if (messageId != null)
        'replyTo': {'messageId': messageId, 'notifyAuthor': notifyAuthor},
    });

DraftContent _content(String text) => DraftContent(
      format: DraftTextFormat.markdown,
      text: text,
      attachments: const [],
    );

String? _projectionText(ChatDraftProjection? projection) =>
    switch (projection?.draft) {
      CanonicalReplacedDraft(:final content) => content.text,
      _ => null,
    };

HandrailChatClient _client(
  _RecordingTransport transport, {
  ChatDraftDeviceMutationIdGenerator? generateDeviceMutationId,
  ChatCommandIdempotencyKeyGenerator? generateIdempotencyKey,
  ChatCommandRetryOptions retryOptions =
      const ChatCommandRetryOptions(maxAttempts: 1),
  ChatDraftMutationScheduler? scheduler,
  Duration debounce = Duration.zero,
  HandrailChatAccessTokenProvider? tokenProvider,
  ApplicationChatStorage? storage,
  ApplicationChatStorageIdentity? storageIdentity,
  NormalizedSnapshotStore? normalizedStore,
  ChatRetainedDraftRetryBackoff? retainedDraftRetryBackoff,
  ChatRetainedDraftRetryWait? retainedDraftRetryWait,
  ChatClientDiagnosticCallback? onStorageDiagnostic,
}) =>
    HandrailChatClient(
      apiBaseUri: Uri.parse(
        'https://chat.example.test/api/chat/?ignored=true#fragment',
      ),
      tokenProvider: tokenProvider ?? () async => 'access-token',
      transport: transport,
      generateDraftDeviceMutationId:
          generateDeviceMutationId ?? () => 'generated-device-mutation',
      generateIdempotencyKey:
          generateIdempotencyKey ?? () => 'generated-idempotency-key',
      commandRetryOptions: retryOptions,
      draftMutationScheduler: scheduler,
      draftDebounce: debounce,
      localStorage: storage,
      storageIdentity: storageIdentity,
      normalizedSnapshotStore: normalizedStore,
      retainedDraftRetryBackoff: retainedDraftRetryBackoff,
      retainedDraftRetryWait: retainedDraftRetryWait,
      onStorageDiagnostic: onStorageDiagnostic,
    );

ApplicationChatQueuedDraftIntentsRecord _retainedDraftRecord({
  required int baseRevision,
  required String text,
  DraftContent? content,
  required String deviceMutationId,
  required String idempotencyKey,
}) =>
    ApplicationChatQueuedDraftIntentsRecord(
      identity: _storageIdentity,
      intents: [
        ApplicationChatQueuedDraftIntent(
          request: ReplaceDraftInput(
            conversationId: _conversationOne,
            baseRevision: baseRevision,
            deviceMutationId: deviceMutationId,
            idempotencyKey: idempotencyKey,
            content: content ?? _content(text),
          ),
          enqueueOrder: 1,
          enqueuedAt: const IsoTimestamp('2026-08-26T14:59:00.000Z'),
        ),
      ],
    );

HandrailChatHttpResponse _draftResponse(
  HandrailChatHttpRequest request, {
  required String status,
  int? canonicalRevision,
  String? canonicalText,
  String updatedAt = '2026-08-26T15:01:00.000Z',
}) {
  final input = jsonDecode(request.body!) as Map<String, Object?>;
  final resolvedRevision =
      canonicalRevision ?? (input['baseRevision']! as int) + 1;
  final draft = canonicalText != null
      ? {
          'kind': 'replaced',
          'content': {
            'format': 'markdown',
            'text': canonicalText,
            'attachments': <Object?>[],
          },
        }
      : input['intent'] == 'replace'
          ? {'kind': 'replaced', 'content': input['content']}
          : {'kind': 'clear_tombstone', 'content': null};
  return HandrailChatHttpResponse(
    statusCode: 200,
    body: jsonEncode({
      'operation': input['operation'],
      'intent': input['intent'],
      'reconciliationStatus': status,
      'conversationId': input['conversationId'],
      'baseRevision': input['baseRevision'],
      'deviceMutationId': input['deviceMutationId'],
      'idempotencyKey': input['idempotencyKey'],
      'canonicalRevision': resolvedRevision,
      'canonicalUpdatedAt': updatedAt,
      'draft': draft,
    }),
  );
}

ConversationDraftUpdatedEvent _draftEvent({
  required int canonicalRevision,
  required String updatedAt,
  required String text,
  String identity = 'event',
  ConversationId conversationId = _conversationOne,
  String? deviceMutationId,
  String? idempotencyKey,
}) {
  final input = {
    'operation': 'synchronize_draft',
    'intent': 'replace',
    'conversationId': conversationId.value,
    'baseRevision': canonicalRevision - 1,
    'deviceMutationId': deviceMutationId ?? '$identity-device',
    'idempotencyKey': idempotencyKey ?? '$identity-key',
    'content': {
      'format': 'markdown',
      'text': text,
      'attachments': <Object?>[],
    },
  };
  final result = {
    'operation': input['operation'],
    'intent': input['intent'],
    'reconciliationStatus': 'applied',
    'conversationId': input['conversationId'],
    'baseRevision': input['baseRevision'],
    'deviceMutationId': input['deviceMutationId'],
    'idempotencyKey': input['idempotencyKey'],
    'canonicalRevision': canonicalRevision,
    'canonicalUpdatedAt': updatedAt,
    'draft': {
      'kind': 'replaced',
      'content': input['content'],
    },
  };
  return ConversationDraftUpdatedEvent.fromJson(
    {
      'eventId': '$identity-event',
      'protocolVersion': 4,
      'tenantId': _tenantId.value,
      'streamId': 'user:${_userId.value}',
      'type': draftUpdatedEventType,
      'occurredAt': updatedAt,
      'payload': {
        'actorUserId': _userId.value,
        'input': input,
        'result': result,
      },
    },
    expectedTenantId: _tenantId,
  );
}

void _installCanonicalDraft(
  NormalizedSnapshotStore store, {
  required int canonicalRevision,
  required String text,
  DraftContent? content,
  ConversationId conversationId = _conversationOne,
}) {
  final encoded = NormalizedSnapshotStateStorageCodec.encode(
    NormalizedSnapshotState.empty(),
  );
  encoded['conversations'] = [
    ChannelConversation(
      id: conversationId,
      tenantId: _tenantId,
      createdAt: const IsoTimestamp('2026-08-26T14:00:00.000Z'),
      updatedAt: const IsoTimestamp('2026-08-26T15:00:00.000Z'),
      name: 'Draft recovery',
      visibility: ConversationVisibility.private,
    ).toJson(),
  ];
  encoded['drafts'] = [
    {
      'conversationId': conversationId.value,
      'draftRevision': canonicalRevision,
      'draft': {
        'kind': 'replaced',
        'content': (content ?? _content(text)).toJson(),
      },
    },
  ];
  store.installPersistedSnapshot(
    NormalizedSnapshotStateStorageCodec.decode(encoded),
  );
}

HandrailChatHttpRequest _requestWithKey(
  _RecordingTransport transport,
  String key,
) =>
    transport.requests.singleWhere((request) {
      final body = jsonDecode(request.body!) as Map<String, Object?>;
      return body['idempotencyKey'] == key;
    });

Future<void> _eventLoop() => Future<void>.delayed(Duration.zero);

Future<void> _until(bool Function() predicate) async {
  for (var attempt = 0; attempt < 100; attempt += 1) {
    if (predicate()) return;
    await _eventLoop();
  }
  fail('Condition did not become true.');
}

final class _RecordingTransport implements HandrailChatHttpTransport {
  _RecordingTransport(this.handler);

  final Future<HandrailChatHttpResponse> Function(HandrailChatHttpRequest)
      handler;
  final List<HandrailChatHttpRequest> requests = [];

  @override
  Future<HandrailChatHttpResponse> send(HandrailChatHttpRequest request) {
    requests.add(request);
    return handler(request);
  }
}

final class _MutableRealtimeNetwork implements ChatRealtimeNetwork {
  _MutableRealtimeNetwork(this._online);

  bool _online;
  final StreamController<bool> _changes =
      StreamController<bool>.broadcast(sync: true);

  @override
  bool get isOnline => _online;

  @override
  Stream<bool> get changes => _changes.stream;

  void setOnline(bool online) {
    _online = online;
    _changes.add(online);
  }
}

final class _DraftRealtimeSocket implements ChatRealtimeSocket {
  final StreamController<Object?> _frames =
      StreamController<Object?>.broadcast(sync: true);

  @override
  Stream<Object?> get frames => _frames.stream;

  void emit(Object? value) => _frames.add(jsonEncode(value));

  @override
  void send(String _) {}

  @override
  Future<void> close() => _frames.close();
}

final class _AtomicDraftStorage implements AtomicApplicationChatStorage {
  final InMemoryApplicationChatStorage backing =
      InMemoryApplicationChatStorage();
  var _blockedDraftReadCount = 0;
  Completer<void> _blockedDraftReads = Completer<void>();
  Completer<void>? _draftReadsRelease;
  var _blockDraftQuarantine = false;
  Completer<void> _quarantineStarted = Completer<void>();
  Completer<void>? _quarantineRelease;
  var removeCount = 0;

  Future<void> get blockedDraftReads => _blockedDraftReads.future;
  Future<void> get quarantineStarted => _quarantineStarted.future;

  void blockNextDraftReads(int count) {
    _blockedDraftReadCount = count;
    _blockedDraftReads = Completer<void>();
    _draftReadsRelease = Completer<void>();
  }

  void releaseDraftReads() {
    final release = _draftReadsRelease;
    _draftReadsRelease = null;
    if (release != null && !release.isCompleted) release.complete();
  }

  void putRawDraftRecord(Object? json) {
    backing.putRawRecordForTesting(
      _storageIdentity,
      ApplicationChatStorageRecordKind.queuedDraftIntents,
      json,
    );
  }

  void blockNextDraftQuarantine() {
    _blockDraftQuarantine = true;
    _quarantineStarted = Completer<void>();
    _quarantineRelease = Completer<void>();
  }

  void releaseQuarantine() {
    final release = _quarantineRelease;
    _quarantineRelease = null;
    if (release != null && !release.isCompleted) release.complete();
  }

  List<ApplicationChatQueuedDraftIntent> draftIntents(
    ApplicationChatStorageIdentity identity,
  ) {
    final raw = backing.rawRecordForTesting(
      identity,
      ApplicationChatStorageRecordKind.queuedDraftIntents,
    );
    if (raw == null) return const <ApplicationChatQueuedDraftIntent>[];
    return (ApplicationChatStorageRecord.decode(jsonEncode(raw))
            as ApplicationChatQueuedDraftIntentsRecord)
        .intents;
  }

  @override
  Future<String?> readEncoded(
    ApplicationChatStorageIdentity identity,
    ApplicationChatStorageRecordKind kind,
  ) async {
    final captured = await backing.readEncoded(identity, kind);
    if (kind == ApplicationChatStorageRecordKind.queuedDraftIntents &&
        _blockedDraftReadCount > 0) {
      _blockedDraftReadCount -= 1;
      if (_blockedDraftReadCount == 0 && !_blockedDraftReads.isCompleted) {
        _blockedDraftReads.complete();
      }
      final release = _draftReadsRelease;
      if (release != null) await release.future;
    }
    return captured;
  }

  @override
  Future<bool> compareExchange(
    ApplicationChatStorageIdentity identity,
    ApplicationChatStorageRecordKind kind,
    String? expectedEncodedRecord,
    String? replacementEncodedRecord,
  ) async {
    if (_blockDraftQuarantine &&
        kind == ApplicationChatStorageRecordKind.queuedDraftIntents &&
        expectedEncodedRecord != null &&
        replacementEncodedRecord == null) {
      _blockDraftQuarantine = false;
      if (!_quarantineStarted.isCompleted) _quarantineStarted.complete();
      final release = _quarantineRelease;
      if (release != null) await release.future;
    }
    return backing.compareExchange(
      identity,
      kind,
      expectedEncodedRecord,
      replacementEncodedRecord,
    );
  }

  @override
  Future<ApplicationChatStorageRecord?> read(
    ApplicationChatStorageIdentity identity,
    ApplicationChatStorageRecordKind kind,
  ) =>
      backing.read(identity, kind);

  @override
  Future<void> replace(ApplicationChatStorageRecord record) =>
      backing.replace(record);

  @override
  Future<void> remove(
    ApplicationChatStorageIdentity identity,
    ApplicationChatStorageRecordKind kind,
  ) {
    removeCount += 1;
    return backing.remove(identity, kind);
  }

  @override
  Future<void> clearForLogout(
    ApplicationChatStorageIdentity previousIdentity,
  ) =>
      backing.clearForLogout(previousIdentity);

  @override
  Future<void> clearForIdentityChange({
    required ApplicationChatStorageIdentity previousIdentity,
    required ApplicationChatStorageIdentity nextIdentity,
  }) =>
      backing.clearForIdentityChange(
        previousIdentity: previousIdentity,
        nextIdentity: nextIdentity,
      );
}

final class _RecordingStorage implements ApplicationChatStorage {
  final Map<String, ApplicationChatStorageRecord> _records = {};
  ApplicationChatStorageRecord? draftReadOverride;
  final List<(ApplicationChatStorageIdentity, ApplicationChatStorageRecordKind)>
      removals = [];
  Completer<void>? draftWriteGate;
  bool failDraftWrites = false;
  int draftWriteStarted = 0;

  List<ApplicationChatQueuedDraftIntent> draftIntents(
    ApplicationChatStorageIdentity identity,
  ) =>
      (_records[_key(
        identity,
        ApplicationChatStorageRecordKind.queuedDraftIntents,
      )] as ApplicationChatQueuedDraftIntentsRecord?)
          ?.intents ??
      const <ApplicationChatQueuedDraftIntent>[];

  @override
  Future<ApplicationChatStorageRecord?> read(
    ApplicationChatStorageIdentity identity,
    ApplicationChatStorageRecordKind kind,
  ) async {
    final override = draftReadOverride;
    if (identity == _storageIdentity &&
        kind == ApplicationChatStorageRecordKind.queuedDraftIntents &&
        override != null) {
      return override;
    }
    return _records[_key(identity, kind)];
  }

  @override
  Future<void> replace(ApplicationChatStorageRecord record) async {
    if (record is ApplicationChatQueuedDraftIntentsRecord) {
      draftWriteStarted += 1;
      final gate = draftWriteGate;
      if (gate != null) await gate.future;
      if (failDraftWrites) throw StateError('draft write failed');
    }
    _records[_key(record.identity, record.kind)] = record;
  }

  @override
  Future<void> remove(
    ApplicationChatStorageIdentity identity,
    ApplicationChatStorageRecordKind kind,
  ) async {
    removals.add((identity, kind));
    if (identity == _storageIdentity &&
        kind == ApplicationChatStorageRecordKind.queuedDraftIntents) {
      draftReadOverride = null;
    }
    _records.remove(_key(identity, kind));
  }

  @override
  Future<void> clearForIdentityChange({
    required ApplicationChatStorageIdentity previousIdentity,
    required ApplicationChatStorageIdentity nextIdentity,
  }) async {
    if (previousIdentity == nextIdentity) return;
    _records.removeWhere(
        (key, _) => key.startsWith('${_identityKey(previousIdentity)}|'));
  }

  @override
  Future<void> clearForLogout(
    ApplicationChatStorageIdentity previousIdentity,
  ) async {
    _records.removeWhere(
        (key, _) => key.startsWith('${_identityKey(previousIdentity)}|'));
  }

  static String _key(
    ApplicationChatStorageIdentity identity,
    ApplicationChatStorageRecordKind kind,
  ) =>
      '${_identityKey(identity)}|${kind.wireValue}';

  static String _identityKey(ApplicationChatStorageIdentity identity) =>
      '${identity.tenantId.value}|${identity.userId.value}|${identity.deviceId.value}';
}

final class _FakeDraftScheduler implements ChatDraftMutationScheduler {
  Duration _now = Duration.zero;
  final List<_FakeDraftTimer> _timers = [];
  var cancelledCount = 0;

  int get activeCount => _timers.where((timer) => timer.active).length;

  @override
  ChatDraftMutationTimer schedule(
    Duration delay,
    void Function() callback,
  ) {
    final timer = _FakeDraftTimer(
      due: _now + delay,
      callback: callback,
      onCancel: () => cancelledCount += 1,
    );
    _timers.add(timer);
    return timer;
  }

  void advance(Duration amount) {
    _now += amount;
    while (true) {
      final due = _timers.where((timer) => timer.active && timer.due <= _now);
      if (due.isEmpty) return;
      final timer =
          due.reduce((left, right) => left.due <= right.due ? left : right);
      timer.fire();
    }
  }
}

final class _FakeDraftTimer implements ChatDraftMutationTimer {
  _FakeDraftTimer({
    required this.due,
    required this.callback,
    required this.onCancel,
  });

  final Duration due;
  final void Function() callback;
  final void Function() onCancel;
  var active = true;

  void fire() {
    if (!active) return;
    active = false;
    callback();
  }

  @override
  void cancel() {
    if (!active) return;
    active = false;
    onCancel();
  }
}
