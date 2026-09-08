import 'dart:async';
import 'dart:convert';

import 'package:handrail_chat/core.dart';
import 'package:test/test.dart';

const _tenantId = 'tenant-1';
const _currentUserId = 'user-current';
const _timestamp = '2026-08-26T04:30:00.000Z';
const _laterTimestamp = '2026-08-26T05:30:00.000Z';
const _organizationScope = OrganizationConversationSnapshotScope();

void main() {
  group('HandrailChatClient conversation archive commands', () {
    test(
        'archive and restore use the exact retry-stable PATCH wire contract '
        'and project list/detail state immediately', () async {
      const conversationId = 'conversation /one';
      var archiveAttempts = 0;
      final transport = _RecordingTransport((request) {
        final body = _body(request);
        if (body['intent'] == 'archive') {
          archiveAttempts += 1;
          if (archiveAttempts == 1) throw StateError('retry');
        }
        return Future.value(_response(_archiveResult(body)));
      });
      final store = _store([conversationId]);
      final client = _client(
        transport,
        store: store,
        idempotencyKey: () => 'generated-archive-key',
        retryOptions: ChatCommandRetryOptions(
          maxAttempts: 2,
          wait: (_, __) async {},
        ),
      );

      final archive = client.archiveConversation(
        const ChatSetConversationArchiveInput(
          conversationId: ConversationId(conversationId),
          expectedLifecycleRevision: 4,
        ),
      );

      final detailProjection =
          store.conversation(const ConversationId(conversationId));
      final listProjection = store.conversationList(_organizationScope);
      expect(detailProjection.lifecycle?.projectedArchived, isTrue);
      expect(
        detailProjection.lifecycle?.authoritativeConversation?.archivedAt,
        isNull,
      );
      expect(
        listProjection.lifecycles[const ConversationId(conversationId)]
            ?.projectedArchived,
        isTrue,
      );

      expect((await archive).category, ChatCommandResultCategory.success);
      expect(transport.requests, hasLength(2));
      for (final request in transport.requests) {
        expect(request.method, 'PATCH');
        expect(
          request.uri.toString(),
          'https://chat.test/api/conversations/'
          'conversation%20%2Fone/lifecycle',
        );
        expect(_body(request), {
          'operation': 'set_conversation_archive',
          'intent': 'archive',
          'conversationId': conversationId,
          'expectedLifecycleRevision': 4,
          'idempotencyKey': 'generated-archive-key',
        });
        expect(request.headers['Idempotency-Key'], 'generated-archive-key');
      }
      expect(transport.requests.first.body, transport.requests.last.body);
      expect(
        store
            .conversation(const ConversationId(conversationId))
            .conversation
            ?.archivedByUserId,
        const UserId(_currentUserId),
      );
      expect(
        store.state.lifecycleRevisions[const ConversationId(conversationId)],
        5,
      );

      final restore = await client.restoreConversation(
        const ChatSetConversationArchiveInput(
          conversationId: ConversationId(conversationId),
          expectedLifecycleRevision: 5,
          idempotencyKey: 'caller-restore-key',
        ),
      );
      expect(restore.category, ChatCommandResultCategory.success);
      expect(_body(transport.requests.last)['intent'], 'restore');
      expect(
        store
            .conversation(const ConversationId(conversationId))
            .conversation
            ?.archivedAt,
        isNull,
      );
      await client.dispose();
      await store.close();
    });

    test(
        'serializes opposite intents per conversation while other lanes run '
        'and unrelated selectors stay quiet', () async {
      final firstConversationResponse = Completer<HandrailChatHttpResponse>();
      var firstConversationRequests = 0;
      final transport = _RecordingTransport((request) {
        final body = _body(request);
        if (body['conversationId'] == 'conversation-1') {
          firstConversationRequests += 1;
          if (firstConversationRequests == 1) {
            return firstConversationResponse.future;
          }
        }
        return Future.value(_response(_archiveResult(body)));
      });
      final store = _store([
        'conversation-1',
        'conversation-2',
        'conversation-3',
      ]);
      const unrelatedScope = EntityConversationSnapshotScope(
        entity: HostEntityReference(type: 'project', id: 'unrelated'),
      );
      store.hydrateConversationList(ConversationListSnapshot.fromJson({
        'kind': 'conversation_list',
        'scope': unrelatedScope.toJson(),
        'items': <Object?>[],
        'page': <String, Object?>{},
        '_meta': _metadata(),
      }));
      var conversationOneEvents = 0;
      var conversationTwoEvents = 0;
      var conversationThreeEvents = 0;
      var unrelatedListEvents = 0;
      final subscriptions = [
        store
            .watchConversation(const ConversationId('conversation-1'))
            .listen((_) => conversationOneEvents += 1),
        store
            .watchConversation(const ConversationId('conversation-2'))
            .listen((_) => conversationTwoEvents += 1),
        store
            .watchConversation(const ConversationId('conversation-3'))
            .listen((_) => conversationThreeEvents += 1),
        store
            .watchConversationList(unrelatedScope)
            .listen((_) => unrelatedListEvents += 1),
      ];
      final client = _client(transport, store: store);

      final archiveOne = client.archiveConversation(
        const ChatSetConversationArchiveInput(
          conversationId: ConversationId('conversation-1'),
          expectedLifecycleRevision: 1,
        ),
      );
      await _waitFor(() => transport.requests.length == 1);
      final restoreOne = client.restoreConversation(
        const ChatSetConversationArchiveInput(
          conversationId: ConversationId('conversation-1'),
          expectedLifecycleRevision: 2,
        ),
      );
      final archiveTwo = client.archiveConversation(
        const ChatSetConversationArchiveInput(
          conversationId: ConversationId('conversation-2'),
          expectedLifecycleRevision: 1,
        ),
      );

      await _waitFor(() => transport.requests.length == 2);
      expect(
        transport.requests.map((request) => _body(request)['conversationId']),
        ['conversation-1', 'conversation-2'],
      );
      expect(
        store
            .conversation(const ConversationId('conversation-1'))
            .lifecycle
            ?.projectedArchived,
        isFalse,
      );
      expect(conversationOneEvents, 2);
      expect(conversationTwoEvents, 2);
      expect(conversationThreeEvents, 0);
      expect(unrelatedListEvents, 0);
      expect((await archiveTwo).category, ChatCommandResultCategory.success);

      firstConversationResponse.complete(
        _response(_archiveResult(_body(transport.requests.first))),
      );
      expect((await archiveOne).category, ChatCommandResultCategory.success);
      expect((await restoreOne).category, ChatCommandResultCategory.success);
      expect(transport.requests, hasLength(3));
      expect(_body(transport.requests.last)['intent'], 'restore');
      expect(
        store
            .conversation(const ConversationId('conversation-1'))
            .lifecycle
            ?.projectedArchived,
        isFalse,
      );
      expect(conversationThreeEvents, 0);
      expect(unrelatedListEvents, 0);

      for (final subscription in subscriptions) {
        await subscription.cancel();
      }
      await client.dispose();
      await store.close();
    });

    test('installs applied, replayed, and already-requested authoritative rows',
        () async {
      final statuses = <String>[
        'applied',
        'replayed',
        'already_requested_state',
      ];
      var requestIndex = 0;
      final transport = _RecordingTransport((request) {
        final body = _body(request);
        final status = statuses[requestIndex++];
        final revision = switch (status) {
          'applied' => (body['expectedLifecycleRevision']! as int) + 1,
          'replayed' => 3,
          _ => 7,
        };
        return Future.value(_response(_archiveResult(
          body,
          reconciliationStatus: status,
          lifecycleRevision: revision,
        )));
      });
      final store = _store(['conversation-1']);
      final client = _client(transport, store: store);

      final results = [
        await client.archiveConversation(
          const ChatSetConversationArchiveInput(
            conversationId: ConversationId('conversation-1'),
            expectedLifecycleRevision: 1,
          ),
        ),
        await client.restoreConversation(
          const ChatSetConversationArchiveInput(
            conversationId: ConversationId('conversation-1'),
            expectedLifecycleRevision: 2,
          ),
        ),
        await client.archiveConversation(
          const ChatSetConversationArchiveInput(
            conversationId: ConversationId('conversation-1'),
            expectedLifecycleRevision: 3,
          ),
        ),
      ];

      expect(
        results.map((result) => result.category),
        everyElement(ChatCommandResultCategory.success),
      );
      expect(
        store.state.lifecycleRevisions[const ConversationId('conversation-1')],
        7,
      );
      expect(
        store
            .conversation(const ConversationId('conversation-1'))
            .conversation
            ?.archivedByUserId,
        const UserId(_currentUserId),
      );
      final restored = NormalizedSnapshotStateStorageCodec.decode(
        NormalizedSnapshotStateStorageCodec.encode(store.state),
      );
      expect(
        restored.lifecycleRevisions[const ConversationId('conversation-1')],
        7,
      );
      expect(restored.pendingConversationArchiveInputs, isEmpty);
      await client.dispose();
      await store.close();
    });

    test('parses HTTP 409 lifecycle conflict as structured reconciliation',
        () async {
      final transport = _RecordingTransport((request) {
        final body = _body(request);
        return Future.value(_response(
          _archiveResult(
            body,
            reconciliationStatus: 'lifecycle_conflict',
            lifecycleRevision: 3,
            forceArchived: false,
          ),
          statusCode: 409,
        ));
      });
      final store = _store(['conversation-1']);
      final client = _client(transport, store: store);

      final result = await client.archiveConversation(
        const ChatSetConversationArchiveInput(
          conversationId: ConversationId('conversation-1'),
          expectedLifecycleRevision: 1,
        ),
      );

      expect(result, isA<ChatCommandSuccess<ConversationArchiveResult>>());
      expect(
        (result as ChatCommandSuccess<ConversationArchiveResult>)
            .value
            .reconciliationStatus,
        ConversationArchiveReconciliationStatus.lifecycleConflict,
      );
      final selected =
          store.conversation(const ConversationId('conversation-1'));
      expect(selected.lifecycle?.authoritativeRevision, 3);
      expect(selected.lifecycle?.projectedArchived, isFalse);
      expect(selected.conversation?.archivedAt, isNull);
      expect(selected.conversation?.archivedByUserId, isNull);
      await client.dispose();
      await store.close();
    });

    test(
        'malformed, HTTP, and transport failures roll back to the latest '
        'authoritative snapshot row', () async {
      final failures = <Future<HandrailChatHttpResponse> Function()>[
        () async => _response({'malformed': true}),
        () async => _response({
              'error': {
                'code': 'CHAT_FORBIDDEN',
                'message': 'Forbidden',
                'refreshable': false,
              },
            }, statusCode: 403),
        () => Future.error(StateError('transport')),
      ];
      final categories = [
        ChatCommandResultCategory.malformedResponse,
        ChatCommandResultCategory.authentication,
        ChatCommandResultCategory.transport,
      ];

      for (var index = 0; index < failures.length; index++) {
        final requestStarted = Completer<void>();
        final release = Completer<void>();
        final transport = _RecordingTransport((_) async {
          requestStarted.complete();
          await release.future;
          return failures[index]();
        });
        final store = _store(['conversation-1'], archived: true);
        final client = _client(
          transport,
          store: store,
          retryOptions: const ChatCommandRetryOptions(maxAttempts: 1),
        );
        final pending = client.restoreConversation(
          const ChatSetConversationArchiveInput(
            conversationId: ConversationId('conversation-1'),
            expectedLifecycleRevision: 1,
          ),
        );
        await requestStarted.future;
        expect(
          store
              .conversation(const ConversationId('conversation-1'))
              .lifecycle
              ?.projectedArchived,
          isFalse,
        );

        store.hydrateConversationList(_listSnapshot(
          ['conversation-1'],
          archived: true,
          timestamp: _laterTimestamp,
          archivedByUserId: 'user-latest',
        ));
        release.complete();
        expect((await pending).category, categories[index]);
        final rolledBack =
            store.conversation(const ConversationId('conversation-1'));
        expect(rolledBack.lifecycle?.projectedArchived, isTrue);
        expect(
          rolledBack.conversation?.archivedByUserId,
          const UserId('user-latest'),
        );
        expect(rolledBack.lifecycle?.pendingIntents, isEmpty);
        await client.dispose();
        await store.close();
      }
    });

    test('caller cancellation removes only its intent and restores projection',
        () async {
      final requestStarted = Completer<void>();
      final never = Completer<HandrailChatHttpResponse>();
      final transport = _RecordingTransport((_) {
        requestStarted.complete();
        return never.future;
      });
      final store = _store(['conversation-1']);
      final client = _client(transport, store: store);
      final cancellation = ChatCommandCancellationController();

      final pending = client.archiveConversation(
        const ChatSetConversationArchiveInput(
          conversationId: ConversationId('conversation-1'),
          expectedLifecycleRevision: 1,
        ),
        cancellationSignal: cancellation.signal,
      );
      await requestStarted.future;
      expect(
        store
            .conversation(const ConversationId('conversation-1'))
            .lifecycle
            ?.projectedArchived,
        isTrue,
      );
      cancellation.cancel();

      expect((await pending).category, ChatCommandResultCategory.aborted);
      expect(
        store
            .conversation(const ConversationId('conversation-1'))
            .lifecycle
            ?.projectedArchived,
        isFalse,
      );
      await client.dispose();
      await store.close();
    });

    test('dispose closes active and queued work and clears both projections',
        () async {
      final requestStarted = Completer<void>();
      final never = Completer<HandrailChatHttpResponse>();
      final transport = _RecordingTransport((_) {
        requestStarted.complete();
        return never.future;
      });
      final store = _store(['conversation-1']);
      final client = _client(transport, store: store);

      final active = client.archiveConversation(
        const ChatSetConversationArchiveInput(
          conversationId: ConversationId('conversation-1'),
          expectedLifecycleRevision: 1,
        ),
      );
      await requestStarted.future;
      final queued = client.restoreConversation(
        const ChatSetConversationArchiveInput(
          conversationId: ConversationId('conversation-1'),
          expectedLifecycleRevision: 2,
        ),
      );
      final dispose = client.dispose();

      expect((await queued).category, ChatCommandResultCategory.closed);
      expect((await active).category, ChatCommandResultCategory.closed);
      await dispose;
      final selected =
          store.conversation(const ConversationId('conversation-1'));
      expect(selected.lifecycle?.pendingIntents, isEmpty);
      expect(selected.lifecycle?.projectedArchived, isFalse);
      expect(transport.requests, hasLength(1));
      await store.close();
    });
  });
}

HandrailChatClient _client(
  HandrailChatHttpTransport transport, {
  required NormalizedSnapshotStore store,
  ChatCommandIdempotencyKeyGenerator? idempotencyKey,
  ChatCommandRetryOptions retryOptions = const ChatCommandRetryOptions(
    maxAttempts: 1,
  ),
}) {
  var generated = 0;
  return HandrailChatClient(
    apiBaseUri: Uri.parse('https://chat.test/api'),
    tokenProvider: () async => 'token',
    transport: transport,
    normalizedSnapshotStore: store,
    commandRetryOptions: retryOptions,
    generateIdempotencyKey: idempotencyKey ?? () => 'generated-${++generated}',
  );
}

final class _RecordingTransport implements HandrailChatHttpTransport {
  _RecordingTransport(this._handler);

  final Future<HandrailChatHttpResponse> Function(HandrailChatHttpRequest)
      _handler;
  final List<HandrailChatHttpRequest> requests = [];

  @override
  Future<HandrailChatHttpResponse> send(HandrailChatHttpRequest request) {
    requests.add(request);
    return _handler(request);
  }
}

NormalizedSnapshotStore _store(
  List<String> conversationIds, {
  bool archived = false,
}) =>
    NormalizedSnapshotStore()
      ..hydrateConversationList(_listSnapshot(
        conversationIds,
        archived: archived,
      ));

ConversationListSnapshot _listSnapshot(
  List<String> conversationIds, {
  bool archived = false,
  String timestamp = _timestamp,
  String archivedByUserId = _currentUserId,
}) =>
    ConversationListSnapshot.fromJson({
      'kind': 'conversation_list',
      'scope': {'type': 'organization'},
      'items': [
        for (final id in conversationIds)
          _summary(
            id,
            archived: archived,
            timestamp: timestamp,
            archivedByUserId: archivedByUserId,
          ),
      ],
      'page': <String, Object?>{},
      '_meta': _metadata(),
    });

Map<String, Object?> _summary(
  String conversationId, {
  required bool archived,
  required String timestamp,
  required String archivedByUserId,
}) =>
    {
      'id': conversationId,
      'tenantId': _tenantId,
      'type': 'channel',
      'name': 'Channel $conversationId',
      'visibility': 'public',
      'createdAt': _timestamp,
      'updatedAt': timestamp,
      if (archived) 'archivedAt': timestamp,
      if (archived) 'archivedByUserId': archivedByUserId,
      'latestSequence': 3,
      'activityAt': timestamp,
      'unreadMentionCount': 0,
      'currentMember': {
        'tenantId': _tenantId,
        'conversationId': conversationId,
        'userId': _currentUserId,
        'role': 'member',
        'state': 'active',
        'joinedAt': _timestamp,
        'updatedAt': timestamp,
      },
      'currentReadState': {
        'conversationId': conversationId,
        'userId': _currentUserId,
        'lastReadSequence': 2,
        'updatedAt': timestamp,
      },
      'currentPreference': {
        'conversationId': conversationId,
        'userId': _currentUserId,
        'notificationPreference': 'mentions',
        'isStarred': false,
        'mute': {'muted': false},
        'updatedAt': timestamp,
      },
      'activeMemberUserIds': [_currentUserId],
    };

Map<String, Object?> _archiveResult(
  Map<String, Object?> input, {
  String reconciliationStatus = 'applied',
  int? lifecycleRevision,
  bool? forceArchived,
}) {
  final archived = forceArchived ?? input['intent'] == 'archive';
  return {
    'operation': 'set_conversation_archive',
    'intent': input['intent'],
    'reconciliationStatus': reconciliationStatus,
    'conversationId': input['conversationId'],
    'expectedLifecycleRevision': input['expectedLifecycleRevision'],
    'lifecycleRevision':
        lifecycleRevision ?? (input['expectedLifecycleRevision']! as int) + 1,
    'archiveState': archived
        ? {
            'status': 'archived',
            'archivedAt': _laterTimestamp,
            'archivedByUserId': _currentUserId,
          }
        : {'status': 'active'},
  };
}

Map<String, Object?> _body(HandrailChatHttpRequest request) =>
    (jsonDecode(request.body!) as Map).cast<String, Object?>();

HandrailChatHttpResponse _response(
  Object? body, {
  int statusCode = 200,
}) =>
    HandrailChatHttpResponse(
      statusCode: statusCode,
      body: jsonEncode(body),
    );

Map<String, Object?> _metadata() => {
      'packageVersion': '0.1.3',
      'protocolVersion': 4,
      'schemaVersion': 9,
      'enabledFeatures': {'threads': true, conversationSnapshotFeature: true},
      'supportedProtocolRange': {
        'minimumVersion': 1,
        'maximumVersion': 4,
      },
      'feature': {
        'name': conversationSnapshotFeature,
        'version': conversationSnapshotVersion,
      },
    };

Future<void> _waitFor(bool Function() condition) async {
  for (var attempt = 0; attempt < 100; attempt++) {
    if (condition()) return;
    await Future<void>.delayed(Duration.zero);
  }
  fail('Condition was not reached.');
}
