import 'dart:async';
import 'dart:convert';

import 'package:handrail_chat/core.dart';
import 'package:handrail_chat/src/testing/in_memory_application_chat_storage.dart';
import 'package:test/test.dart';

const _sourceMessageId = MessageId('message-source');
const _destinationConversationId = ConversationId('conversation-destination');
const _destinationMessageId = MessageId('message-destination');

void main() {
  test('posts the exact authorized request and reconciles applied success',
      () async {
    final store = NormalizedSnapshotStore();
    final transport = _RecordingTransport((request) async {
      final body = jsonDecode(request.body!) as Map<String, Object?>;
      return _response(_forwardResult(body, 'applied'));
    });
    final client = _client(transport: transport, store: store);

    final result = await client.forwardMessage(const ChatForwardMessageInput(
      sourceMessageId: MessageId('source /?#'),
      destinationConversationId: ConversationId('destination /?#'),
    ));

    expect(result, isA<ChatCommandSuccess<ForwardMessageResult>>());
    final value = (result as ChatCommandSuccess<ForwardMessageResult>).value;
    expect(
      value.reconciliationStatus,
      ForwardMessageReconciliationStatus.applied,
    );
    expect(value.message.content.forwarded?.sourceMessageId,
        const MessageId('source /?#'));
    expect(transport.requests, hasLength(1));
    final request = transport.requests.single;
    expect(request.method, 'POST');
    expect(
      request.uri.toString(),
      'https://chat.example.test/api/chat/messages/forward',
    );
    expect(request.headers, <String, String>{
      'Accept': 'application/json',
      'Authorization': 'Bearer access-token',
      'Idempotency-Key': 'forward-key-1',
      'Content-Type': 'application/json',
    });
    expect(jsonDecode(request.body!), <String, Object?>{
      'operation': 'forward_message.v1',
      'sourceMessageId': 'source /?#',
      'destinationConversationId': 'destination /?#',
      'clientCorrelationId': 'forward-correlation-1',
      'idempotencyKey': 'forward-key-1',
    });
    expect(store.state.canonicalMessages, hasLength(1));
    expect(
      store.timeline(const ConversationId('destination /?#')).messageIds,
      const [_destinationMessageId],
    );

    await client.dispose();
    await store.close();
  });

  test('applied, replayed, and repeated canonical reconciliation insert once',
      () async {
    final store = NormalizedSnapshotStore();
    var calls = 0;
    final transport = _RecordingTransport((request) async {
      calls += 1;
      final body = jsonDecode(request.body!) as Map<String, Object?>;
      return _response(_forwardResult(
        body,
        calls == 1 ? 'applied' : 'replayed',
      ));
    });
    var correlation = 0;
    var key = 0;
    final client = _client(
      transport: transport,
      store: store,
      generateCorrelationId: () => 'forward-correlation-${++correlation}',
      generateIdempotencyKey: () => 'forward-key-${++key}',
    );
    var timelineEffects = 0;
    final subscription = store
        .watchTimeline(_destinationConversationId)
        .listen((_) => timelineEffects += 1);

    final applied = await client.forwardMessage(_input);
    final replayed = await client.forwardMessage(_input);
    final replayedValue =
        (replayed as ChatCommandSuccess<ForwardMessageResult>).value;
    store.reconcileMessage(replayedValue.message);

    expect(
      (applied as ChatCommandSuccess<ForwardMessageResult>)
          .value
          .reconciliationStatus,
      ForwardMessageReconciliationStatus.applied,
    );
    expect(
      replayedValue.reconciliationStatus,
      ForwardMessageReconciliationStatus.replayed,
    );
    expect(store.state.canonicalMessages, hasLength(1));
    expect(
      store.timeline(_destinationConversationId).messageIds,
      const [_destinationMessageId],
    );
    expect(timelineEffects, 1);

    await subscription.cancel();
    await client.dispose();
    await store.close();
  });

  test('keeps correlation, idempotency, and body stable across safe retry',
      () async {
    var attempts = 0;
    var correlationCalls = 0;
    var keyCalls = 0;
    final transport = _RecordingTransport((request) async {
      attempts += 1;
      if (attempts == 1) {
        return const HandrailChatHttpResponse(statusCode: 503, body: '');
      }
      final body = jsonDecode(request.body!) as Map<String, Object?>;
      return _response(_forwardResult(body, 'replayed'));
    });
    final client = _client(
      transport: transport,
      generateCorrelationId: () {
        correlationCalls += 1;
        return 'stable-correlation';
      },
      generateIdempotencyKey: () {
        keyCalls += 1;
        return 'stable-forward-key';
      },
      retryOptions: ChatCommandRetryOptions(
        maxAttempts: 2,
        backoff: (_) => Duration.zero,
        wait: (_, __) async {},
      ),
    );

    final result = await client.forwardMessage(_input);

    expect(result, isA<ChatCommandSuccess<ForwardMessageResult>>());
    expect(correlationCalls, 1);
    expect(keyCalls, 1);
    expect(transport.requests, hasLength(2));
    expect(transport.requests[0].body, transport.requests[1].body);
    expect(
      transport.requests.map((request) => request.headers['Idempotency-Key']),
      everyElement('stable-forward-key'),
    );

    await client.dispose();
  });

  test('returns a terminal HTTP failure without retry or reconciliation',
      () async {
    final store = NormalizedSnapshotStore();
    final transport = _RecordingTransport((_) async => _response(
          <String, Object?>{
            'error': <String, Object?>{
              'code': 'FORWARD_REJECTED',
              'message': 'Forwarding rejected.',
            },
          },
          statusCode: 400,
        ));
    final client = _client(
      transport: transport,
      store: store,
      retryOptions: ChatCommandRetryOptions(
        maxAttempts: 3,
        backoff: (_) => Duration.zero,
        wait: (_, __) async {},
      ),
    );

    final result = await client.forwardMessage(_input);

    expect(result, isA<ChatCommandRejected<ForwardMessageResult>>());
    expect(
      (result as ChatCommandRejected<ForwardMessageResult>).httpStatus,
      400,
    );
    expect(transport.requests, hasLength(1));
    expect(store.state.canonicalMessages, isEmpty);

    await client.dispose();
    await store.close();
  });

  test('rejects malformed JSON and generated-contract response failures',
      () async {
    final fixtures = <Future<HandrailChatHttpResponse> Function(
      HandrailChatHttpRequest,
    )>[
      (_) async =>
          const HandrailChatHttpResponse(statusCode: 200, body: '{not-json'),
      (request) async {
        final body = jsonDecode(request.body!) as Map<String, Object?>;
        final wire = _forwardResult(body, 'applied')..remove('operation');
        return _response(wire);
      },
      (request) async {
        final body = jsonDecode(request.body!) as Map<String, Object?>;
        final wire = _forwardResult(body, 'applied');
        wire['canonicalRevision'] = 2;
        return _response(wire);
      },
    ];

    for (final handler in fixtures) {
      final store = NormalizedSnapshotStore();
      final transport = _RecordingTransport(handler);
      final client = _client(transport: transport, store: store);

      final result = await client.forwardMessage(_input);

      expect(result, isA<ChatCommandMalformedResponse<ForwardMessageResult>>());
      expect(store.state.canonicalMessages, isEmpty);
      await client.dispose();
      await store.close();
    }
  });

  test('rejects correlation, source, and destination binding mismatches',
      () async {
    final mutations = <void Function(Map<String, Object?>)>[
      (wire) => wire['clientCorrelationId'] = 'other-correlation',
      (wire) => wire['destinationConversationId'] = 'other-conversation',
      (wire) {
        final message = wire['message']! as Map<String, Object?>;
        final content = message['content']! as Map<String, Object?>;
        final forwarded = content['forwarded']! as Map<String, Object?>;
        forwarded['sourceMessageId'] = 'other-source';
      },
      (wire) {
        final message = wire['message']! as Map<String, Object?>;
        message['conversationId'] = 'other-conversation';
      },
    ];

    for (final mutate in mutations) {
      final store = NormalizedSnapshotStore();
      final transport = _RecordingTransport((request) async {
        final body = jsonDecode(request.body!) as Map<String, Object?>;
        final wire = _forwardResult(body, 'applied');
        mutate(wire);
        return _response(wire);
      });
      final client = _client(transport: transport, store: store);

      final result = await client.forwardMessage(_input);

      expect(result, isA<ChatCommandMalformedResponse<ForwardMessageResult>>());
      expect(store.state.canonicalMessages, isEmpty);
      await client.dispose();
      await store.close();
    }
  });

  test('supports caller cancellation and closes active forwarding commands',
      () async {
    final before = ChatCommandCancellationController()..cancel();
    final beforeTransport = _RecordingTransport(
      (_) async => throw StateError('HTTP must not run'),
    );
    final beforeClient = _client(transport: beforeTransport);
    final beforeResult = await beforeClient.forwardMessage(
      _input,
      cancellationSignal: before.signal,
    );
    expect(beforeResult, isA<ChatCommandAborted<ForwardMessageResult>>());
    expect(beforeTransport.requests, isEmpty);
    await beforeClient.dispose();

    final cancelStarted = Completer<void>();
    final cancelResponse = Completer<HandrailChatHttpResponse>();
    final cancelTransport = _RecordingTransport((_) {
      cancelStarted.complete();
      return cancelResponse.future;
    });
    final cancelClient = _client(transport: cancelTransport);
    final cancellation = ChatCommandCancellationController();
    final cancelFuture = cancelClient.forwardMessage(
      _input,
      cancellationSignal: cancellation.signal,
    );
    await cancelStarted.future;
    cancellation.cancel();
    expect(await cancelFuture, isA<ChatCommandAborted<ForwardMessageResult>>());
    expect(
      (cancelTransport.requests.single.cancellationSignal!
              as ChatCommandCancellationSignal)
          .isCancelled,
      isTrue,
    );
    cancelResponse.complete(_response(<String, Object?>{}));
    await cancelClient.dispose();

    final closeStore = NormalizedSnapshotStore();
    final closeStarted = Completer<void>();
    final closeResponse = Completer<HandrailChatHttpResponse>();
    final closeTransport = _RecordingTransport((_) {
      closeStarted.complete();
      return closeResponse.future;
    });
    final closeClient = _client(transport: closeTransport, store: closeStore);
    final closeFuture = closeClient.forwardMessage(_input);
    await closeStarted.future;
    final disposeFuture = closeClient.dispose();
    expect(await closeFuture, isA<ChatCommandClosed<ForwardMessageResult>>());
    await disposeFuture;
    expect(closeStore.state.canonicalMessages, isEmpty);
    expect(
      await closeClient.forwardMessage(_input),
      isA<ChatCommandClosed<ForwardMessageResult>>(),
    );
    closeResponse.complete(_response(<String, Object?>{}));
    await closeStore.close();
  });

  test('identity change clears old pending reconciliation authority', () async {
    final store = _forwardAccessStore(_identity('user-old'));
    final started = Completer<void>();
    final oldResponse = Completer<HandrailChatHttpResponse>();
    final transport = _RecordingTransport((request) {
      started.complete();
      return oldResponse.future;
    });
    var correlation = 0;
    final client = _client(
      transport: transport,
      store: store,
      storage: InMemoryApplicationChatStorage(),
      storageIdentity: _identity('user-old'),
      generateCorrelationId: () => 'identity-correlation-${++correlation}',
    );

    final oldCommand = client.forwardMessage(_input);
    await started.future;
    await client.activateStorageIdentity(_identity('user-new'));
    _installForwardAccess(store, _identity('user-new'));
    final oldBody =
        jsonDecode(transport.requests.single.body!) as Map<String, Object?>;
    oldResponse.complete(_response(_forwardResult(oldBody, 'applied')));

    expect(
        oldCommand, completion(isA<ChatCommandClosed<ForwardMessageResult>>()));
    await oldCommand;
    expect(store.state.canonicalMessages[_destinationMessageId], isNull,
        reason: 'The prior identity no longer owns this correlation.');

    transport.handler = (request) async {
      final body = jsonDecode(request.body!) as Map<String, Object?>;
      return _response(_forwardResult(body, 'applied'));
    };
    final current = await client.forwardMessage(_input);
    expect(current, isA<ChatCommandSuccess<ForwardMessageResult>>());
    expect(store.state.canonicalMessages[_destinationMessageId],
        isA<ActiveMessage>());

    await client.dispose();
    await store.close();
  });
}

const _input = ChatForwardMessageInput(
  sourceMessageId: _sourceMessageId,
  destinationConversationId: _destinationConversationId,
);

HandrailChatClient _client({
  required _RecordingTransport transport,
  NormalizedSnapshotStore? store,
  ChatForwardMessageCorrelationIdGenerator? generateCorrelationId,
  ChatCommandIdempotencyKeyGenerator? generateIdempotencyKey,
  ChatCommandRetryOptions retryOptions = const ChatCommandRetryOptions(),
  ApplicationChatStorage? storage,
  ApplicationChatStorageIdentity? storageIdentity,
}) =>
    HandrailChatClient(
      apiBaseUri: Uri.parse(
        'https://chat.example.test/api/chat/?ignored=true#fragment',
      ),
      tokenProvider: () async => 'access-token',
      transport: transport,
      normalizedSnapshotStore: store,
      generateForwardMessageCorrelationId:
          generateCorrelationId ?? () => 'forward-correlation-1',
      generateIdempotencyKey: generateIdempotencyKey ?? () => 'forward-key-1',
      commandRetryOptions: retryOptions,
      localStorage: storage,
      storageIdentity: storageIdentity,
    );

ApplicationChatStorageIdentity _identity(String userId) =>
    ApplicationChatStorageIdentity(
      tenantId: const TenantId('tenant-1'),
      userId: UserId(userId),
      deviceId: const DeviceId('device-1'),
    );

NormalizedSnapshotStore _forwardAccessStore(
  ApplicationChatStorageIdentity identity,
) {
  final store = NormalizedSnapshotStore();
  _installForwardAccess(store, identity);
  return store;
}

void _installForwardAccess(
  NormalizedSnapshotStore store,
  ApplicationChatStorageIdentity identity,
) {
  store.hydrateConversationList(ConversationListSnapshot.fromJson({
    'kind': 'conversation_list',
    'scope': const OrganizationConversationSnapshotScope().toJson(),
    'items': [
      {
        'id': _destinationConversationId.toJson(),
        'tenantId': identity.tenantId.toJson(),
        'type': 'channel',
        'name': 'Forward destination',
        'visibility': 'public',
        'createdAt': '2026-08-28T16:00:00.000Z',
        'updatedAt': '2026-08-28T16:00:00.000Z',
        'latestSequence': 1,
        'activityAt': '2026-08-28T16:00:00.000Z',
        'unreadMentionCount': 0,
        'currentMember': {
          'tenantId': identity.tenantId.toJson(),
          'conversationId': _destinationConversationId.toJson(),
          'userId': identity.userId.toJson(),
          'role': 'member',
          'state': 'active',
          'joinedAt': '2026-08-28T16:00:00.000Z',
          'updatedAt': '2026-08-28T16:00:00.000Z',
        },
        'currentReadState': {
          'conversationId': _destinationConversationId.toJson(),
          'userId': identity.userId.toJson(),
          'lastReadSequence': 0,
          'updatedAt': '2026-08-28T16:00:00.000Z',
        },
        'currentPreference': {
          'conversationId': _destinationConversationId.toJson(),
          'userId': identity.userId.toJson(),
          'notificationPreference': 'mentions',
          'isStarred': false,
          'mute': {'muted': false},
          'updatedAt': '2026-08-28T16:00:00.000Z',
        },
        'activeMemberUserIds': [identity.userId.toJson()],
      },
    ],
    'page': <String, Object?>{},
    '_meta': {
      'packageVersion': '0.1.3',
      'protocolVersion': handrailChatProtocolVersion,
      'schemaVersion': 1,
      'enabledFeatures': <String, Object?>{},
      'supportedProtocolRange': <String, Object?>{
        'minimumVersion': handrailChatProtocolVersion,
        'maximumVersion': handrailChatProtocolVersion,
      },
      'feature': {
        'name': conversationSnapshotFeature,
        'version': conversationSnapshotVersion,
      },
    },
  }));
  store.reconcileMessage(ActiveMessage(
    id: _sourceMessageId,
    tenantId: identity.tenantId,
    conversationId: const ConversationId('source-conversation'),
    author: const MessageAuthorIdentity(userId: UserId('source-author')),
    sequence: const MessageSequence(1),
    createdAt: const IsoTimestamp('2026-08-28T16:00:00.000Z'),
    updatedAt: const IsoTimestamp('2026-08-28T16:00:00.000Z'),
    revision: const MessageRevisionMetadata(revision: 1),
    content: MessageContent(
      format: MessageContentFormat.plain,
      text: 'forwardable source',
    ),
  ));
}

HandrailChatHttpResponse _response(
  Object? body, {
  int statusCode = 200,
}) =>
    HandrailChatHttpResponse(
      statusCode: statusCode,
      body: jsonEncode(body),
    );

Map<String, Object?> _forwardResult(
  Map<String, Object?> request,
  String reconciliationStatus,
) =>
    <String, Object?>{
      'operation': 'forward_message.v1',
      'reconciliationStatus': reconciliationStatus,
      'clientCorrelationId': request['clientCorrelationId'],
      'destinationConversationId': request['destinationConversationId'],
      'message': <String, Object?>{
        'id': _destinationMessageId.value,
        'tenantId': 'tenant-1',
        'conversationId': request['destinationConversationId'],
        'author': <String, Object?>{
          'type': 'user',
          'userId': 'forwarding-user',
        },
        'sequence': 42,
        'createdAt': '2026-08-28T16:00:00.000Z',
        'updatedAt': '2026-08-28T16:00:00.000Z',
        'revision': <String, Object?>{'revision': 1},
        'content': <String, Object?>{
          'format': 'markdown',
          'text': 'Frozen **source** text',
          'mentions': <Object?>[],
          'forwarded': <String, Object?>{
            'sourceMessageId': request['sourceMessageId'],
            'originalAuthor': <String, Object?>{
              'userId': 'original-user',
              'displayName': 'Original Author',
            },
            'originalCreatedAt': '2026-08-20T12:30:00.000Z',
          },
        },
      },
      'canonicalRevision': 1,
    };

final class _RecordingTransport implements HandrailChatHttpTransport {
  _RecordingTransport(this.handler);

  Future<HandrailChatHttpResponse> Function(HandrailChatHttpRequest request)
      handler;
  final List<HandrailChatHttpRequest> requests = <HandrailChatHttpRequest>[];

  @override
  Future<HandrailChatHttpResponse> send(HandrailChatHttpRequest request) {
    requests.add(request);
    return handler(request);
  }
}
