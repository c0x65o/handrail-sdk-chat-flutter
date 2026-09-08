import 'dart:async';
import 'dart:convert';

import 'package:handrail_chat/core.dart';
import 'package:test/test.dart';

const _conversationId = ConversationId('conversation-1');
const _sessionId = HuddleSessionId('huddle-1');
final _now = DateTime.utc(2030, 1, 1);
const _descriptorSecret = 'OPAQUE_MEDIA_DESCRIPTOR_SENTINEL';

void main() {
  group('ChatHuddleController', () {
    test('hydrates inactive and active snapshots with current-first state',
        () async {
      for (final snapshot in <Map<String, Object?>>[
        _inactive,
        _active,
      ]) {
        final transport = _FakeHttpTransport(
          (_) async => _jsonResponse(snapshot),
        );
        final client = _client(transport);
        final controller = client.huddles.forConversation(_conversationId);
        final transitions = <ChatHuddleState>[];
        final subscription = controller.states.listen(transitions.add);

        final result = await controller.hydrate();
        await Future<void>.delayed(Duration.zero);

        expect(result, isA<ChatHuddleActionSuccess>());
        expect((result as ChatHuddleActionSuccess).applied, isTrue);
        expect(transport.requests.single.method, 'GET');
        expect(
          transport.requests.single.uri,
          Uri.parse(
            'https://chat.example.test/api/chat/conversations/'
            'conversation-1/huddle',
          ),
        );
        expect(controller.state.canonicalState.status.name, snapshot['status']);
        expect(
            controller.state.hydrationStatus, ChatHuddleHydrationStatus.ready);
        expect(
          controller.state.media,
          snapshot['status'] == 'active'
              ? isA<ChatHuddleMediaRejoinRequiredState>()
              : isA<ChatHuddleMediaIdleState>(),
        );
        expect(
            transitions.first.hydrationStatus, ChatHuddleHydrationStatus.idle);
        expect(
          transitions.map((state) => state.hydrationStatus),
          containsAllInOrder(<ChatHuddleHydrationStatus>[
            ChatHuddleHydrationStatus.loading,
            ChatHuddleHydrationStatus.ready,
          ]),
        );

        await subscription.cancel();
        await client.dispose();
      }
    });

    test('serializes exact retry-safe lifecycle methods and paths', () async {
      final firstShare = Completer<HandrailChatHttpResponse>();
      var delayFirstShare = true;
      final transport = _FakeHttpTransport((request) async {
        final input = jsonDecode(request.body!) as Map<String, Object?>;
        final operation = input['operation'];
        if (operation == 'start_huddle') {
          return _commandResponse(input, _starting, media: true);
        }
        if (operation == 'join_huddle') {
          return _commandResponse(input, _active, media: true);
        }
        if (operation == 'set_huddle_screen_share') {
          if (input['intent'] == 'set' && delayFirstShare) {
            delayFirstShare = false;
            return firstShare.future;
          }
          return _commandResponse(input, _active);
        }
        if (operation == 'leave_huddle') {
          return _commandResponse(input, _left);
        }
        return _commandResponse(input, _ended);
      });
      var keySequence = 0;
      final client = _client(
        transport,
        currentUser: const UserId('user-alice'),
        generateIdempotencyKey: () => 'huddle-key-${++keySequence}',
      );
      final controller = client.huddles.forConversation(_conversationId);

      expect(await controller.start(), isA<ChatHuddleActionSuccess>());
      expect(await controller.join(), isA<ChatHuddleActionSuccess>());
      final set = controller.setScreenShare(HuddleScreenShareIntent.set);
      final clear = controller.clearScreenShare();
      await Future<void>.delayed(Duration.zero);
      expect(transport.requests, hasLength(3));
      firstShare.complete(
        _commandResponseValue(
          const SetHuddleScreenShareInput(
            huddleSessionId: _sessionId,
            intent: HuddleScreenShareIntent.set,
            idempotencyKey: 'huddle-key-3',
          ).toJson(),
          _sharing,
        ),
      );
      expect(await set, isA<ChatHuddleActionSuccess>());
      expect(await clear, isA<ChatHuddleActionSuccess>());
      expect(await controller.leave(), isA<ChatHuddleActionSuccess>());
      expect(controller.mediaBoundary.readJoinDescriptor(), isNull);
      expect(
        controller.state.media,
        isA<ChatHuddleMediaRejoinRequiredState>().having(
          (state) => state.reason,
          'reason',
          ChatHuddleRejoinReason.notJoined,
        ),
      );
      expect(await controller.end(), isA<ChatHuddleActionSuccess>());

      expect(
        transport.requests.map((request) => <Object?>[
              request.method,
              request.uri.path,
            ]),
        <List<Object?>>[
          <Object?>['POST', '/api/chat/conversations/conversation-1/huddles'],
          <Object?>['POST', '/api/chat/huddles/huddle-1/join'],
          <Object?>['PATCH', '/api/chat/huddles/huddle-1/screen-share'],
          <Object?>['PATCH', '/api/chat/huddles/huddle-1/screen-share'],
          <Object?>['POST', '/api/chat/huddles/huddle-1/leave'],
          <Object?>['POST', '/api/chat/huddles/huddle-1/end'],
        ],
      );
      expect(
        transport.requests.map((request) => request.headers['Idempotency-Key']),
        <String?>[
          'huddle-key-1',
          'huddle-key-2',
          'huddle-key-3',
          'huddle-key-4',
          'huddle-key-5',
          'huddle-key-6',
        ],
      );
      expect(
        transport.requests.map((request) =>
            (jsonDecode(request.body!) as Map<String, Object?>)['intent']),
        <Object?>[null, null, 'set', 'clear', null, null],
      );
      expect(controller.state.canonicalState, isA<EndedHuddleState>());
      await client.dispose();
    });

    test('transport retry preserves command body and idempotency key',
        () async {
      var attempts = 0;
      final transport = _FakeHttpTransport((request) async {
        attempts += 1;
        if (attempts == 1) {
          return const HandrailChatHttpResponse(
            statusCode: 503,
            body: 'retry',
          );
        }
        final input = jsonDecode(request.body!) as Map<String, Object?>;
        return _commandResponse(input, _starting, media: true);
      });
      final client = _client(
        transport,
        commandRetryOptions: ChatCommandRetryOptions(
          maxAttempts: 2,
          backoff: (_) => Duration.zero,
          wait: (_, __) async {},
        ),
      );

      final result =
          await client.huddles.forConversation(_conversationId).start();

      expect(result, isA<ChatHuddleActionSuccess>());
      expect(transport.requests, hasLength(2));
      expect(transport.requests[0].body, transport.requests[1].body);
      expect(
        transport.requests.map((request) => request.headers['Idempotency-Key']),
        everyElement('huddle-key-1'),
      );
      await client.dispose();
    });

    test('successful leave clears a prior denied end media error', () async {
      final transport = _FakeHttpTransport((request) async {
        final input = jsonDecode(request.body!) as Map<String, Object?>;
        return switch (input['operation']) {
          'start_huddle' =>
            await _commandResponse(input, _starting, media: true),
          'join_huddle' => await _commandResponse(input, _active, media: true),
          'end_huddle' => const HandrailChatHttpResponse(
              statusCode: 403,
              body: 'private authorization detail',
            ),
          'leave_huddle' => await _commandResponse(input, _left),
          _ => throw StateError('Unexpected huddle operation'),
        };
      });
      final client = _client(transport, currentUser: const UserId('user-alice'));
      final controller = client.huddles.forConversation(_conversationId);

      expect(await controller.start(), isA<ChatHuddleActionSuccess>());
      expect(await controller.join(), isA<ChatHuddleActionSuccess>());

      final deniedEnd = await controller.end();
      expect(deniedEnd, isA<ChatHuddleActionFailure>());
      expect(controller.state.canonicalState, isA<ActiveHuddleState>());
      expect(controller.state.media, isA<ChatHuddleMediaErrorState>());

      expect(await controller.leave(), isA<ChatHuddleActionSuccess>());
      expect(controller.state.canonicalState, isA<ActiveHuddleState>());
      expect(
        (controller.state.canonicalState as ActiveHuddleState)
            .participants
            .single
            .status,
        HuddleParticipantStatus.left,
      );
      expect(
        controller.state.media,
        isA<ChatHuddleMediaRejoinRequiredState>().having(
          (state) => state.reason,
          'reason',
          ChatHuddleRejoinReason.notJoined,
        ),
      );

      await client.dispose();
    });

    test('applied join accepts unseen Bob from a stale participant snapshot',
        () async {
      final transport = _FakeHttpTransport((request) async {
        final input = jsonDecode(request.body!) as Map<String, Object?>;
        expect(input['operation'], 'join_huddle');
        return _commandResponse(input, _joinedWithBob, media: true);
      });
      final client = _client(transport, currentUser: const UserId('user-alice'));
      addTearDown(client.dispose);
      final controller = client.huddles.forConversation(_conversationId);
      // Seed before dispatch: no realtime reconciliation advances the watermark.
      expect(controller.reconcileCanonicalState(_state(_left)), isTrue);
      expect(controller.mediaBoundary.readJoinDescriptor(), isNull);

      final result = await controller.join();

      expect(result, isA<ChatHuddleActionSuccess>());
      final success = result as ChatHuddleActionSuccess;
      expect(success.applied, isTrue);
      expect(success.reconciliationStatus, HuddleReconciliationStatus.applied);
      expect(success.state.toJson(), _joinedWithBob);
      expect(controller.state.canonicalState.toJson(), _joinedWithBob);
      expect(controller.mediaBoundary.readJoinDescriptor()?.descriptor,
          _descriptorSecret);
      expect(transport.requests, hasLength(1));
    });

    test('applied leave accepts unseen Bob from a stale participant snapshot',
        () async {
      final transport = _FakeHttpTransport((request) async {
        final input = jsonDecode(request.body!) as Map<String, Object?>;
        return switch (input['operation']) {
          'join_huddle' => await _commandResponse(input, _active, media: true),
          'leave_huddle' => await _commandResponse(input, _leftWithBob),
          _ => throw StateError('Unexpected huddle operation'),
        };
      });
      final client = _client(transport, currentUser: const UserId('user-alice'));
      addTearDown(client.dispose);
      final controller = client.huddles.forConversation(_conversationId);
      expect(controller.reconcileCanonicalState(_state(_starting)), isTrue);
      expect(await controller.join(), isA<ChatHuddleActionSuccess>());
      expect(controller.state.canonicalState.toJson(), _active);
      expect(controller.mediaBoundary.readJoinDescriptor()?.descriptor,
          _descriptorSecret);

      // Bob is first seen in HTTP; no reconciliation occurs during leave.
      final result = await controller.leave();

      expect(result, isA<ChatHuddleActionSuccess>());
      final success = result as ChatHuddleActionSuccess;
      expect(success.applied, isTrue);
      expect(success.reconciliationStatus, HuddleReconciliationStatus.applied);
      expect(success.state.toJson(), _leftWithBob);
      expect(controller.state.canonicalState.toJson(), _leftWithBob);
      expect(controller.mediaBoundary.readJoinDescriptor(), isNull);
      expect(transport.requests, hasLength(2));
    });

    test('applied join rejects an absent actor despite a supplied descriptor',
        () async {
      final transport = _FakeHttpTransport((request) async {
        final input = jsonDecode(request.body!) as Map<String, Object?>;
        expect(input['operation'], 'join_huddle');
        return _commandResponse(input, _onlyBob, media: true);
      });
      final client = _client(transport, currentUser: const UserId('user-alice'));
      addTearDown(client.dispose);
      final controller = client.huddles.forConversation(_conversationId);
      expect(controller.reconcileCanonicalState(_state(_left)), isTrue);
      final previousState = controller.state.canonicalState;

      final result = await controller.join();

      expect(result, isA<ChatHuddleActionFailure>().having(
        (failure) => failure.code,
        'code',
        ChatHuddleErrorCode.malformedResponse,
      ));
      expect(controller.state.canonicalState, same(previousState));
      expect(controller.state.canonicalState.toJson(), _left);
      expect(controller.mediaBoundary.readJoinDescriptor(), isNull);
      expect(transport.requests, hasLength(1));
    });

    test('applied join rejects missing actor identity despite a supplied descriptor',
        () async {
      final transport = _FakeHttpTransport((request) async {
        final input = jsonDecode(request.body!) as Map<String, Object?>;
        expect(input['operation'], 'join_huddle');
        return _commandResponse(input, _active, media: true);
      });
      final client = _client(transport);
      addTearDown(client.dispose);
      final controller = client.huddles.forConversation(_conversationId);
      expect(controller.reconcileCanonicalState(_state(_left)), isTrue);
      final previousState = controller.state.canonicalState;

      final result = await controller.join();

      expect(result, isA<ChatHuddleActionFailure>().having(
        (failure) => failure.code,
        'code',
        ChatHuddleErrorCode.malformedResponse,
      ));
      expect(controller.state.canonicalState, same(previousState));
      expect(controller.state.canonicalState.toJson(), _left);
      expect(controller.mediaBoundary.readJoinDescriptor(), isNull);
      expect(transport.requests, hasLength(1));
    });

    test('reconciles applied, replayed, event, and stale responses', () async {
      final hydrationResponse = Completer<HandrailChatHttpResponse>();
      final hydrationClient = _client(
        _FakeHttpTransport((_) => hydrationResponse.future),
      );
      final hydrationController =
          hydrationClient.huddles.forConversation(_conversationId);
      final hydration = hydrationController.hydrate();
      await Future<void>.delayed(Duration.zero);
      expect(
        hydrationController.reconcileCanonicalState(_state(_active)),
        isTrue,
      );
      hydrationResponse.complete(_jsonResponse(_inactive));
      final staleHydration = await hydration as ChatHuddleActionSuccess;
      expect(staleHydration.applied, isFalse);
      expect(
          hydrationController.state.canonicalState, isA<ActiveHuddleState>());
      await hydrationClient.dispose();

      final commandResponse = Completer<HandrailChatHttpResponse>();
      final commandClient = _client(
        _FakeHttpTransport((_) => commandResponse.future),
      );
      final commandController =
          commandClient.huddles.forConversation(_conversationId);
      final start = commandController.start();
      await Future<void>.delayed(Duration.zero);
      commandController.reconcileCanonicalState(_state(_active));
      commandResponse.complete(
        _commandResponseValue(
          const StartHuddleInput(
            conversationId: _conversationId,
            idempotencyKey: 'huddle-key-1',
          ).toJson(),
          _starting,
          media: true,
        ),
      );
      final staleCommand = await start as ChatHuddleActionSuccess;
      expect(staleCommand.applied, isFalse);
      expect(commandController.state.canonicalState, isA<ActiveHuddleState>());
      expect(commandController.mediaBoundary.readJoinDescriptor(), isNull);
      await commandClient.dispose();

      final replayClient = _client(
        _FakeHttpTransport((request) async {
          final input = jsonDecode(request.body!) as Map<String, Object?>;
          return _commandResponse(
            input,
            _sharing,
            reconciliationStatus: 'replayed',
          );
        }),
      );
      final replayController =
          replayClient.huddles.forConversation(_conversationId);
      replayController.reconcileCanonicalState(_state(_sharing));
      final replayed =
          await replayController.setScreenShare(HuddleScreenShareIntent.set)
              as ChatHuddleActionSuccess;
      expect(replayed.applied, isTrue);
      expect(
        replayed.reconciliationStatus,
        HuddleReconciliationStatus.replayed,
      );
      expect(
        (replayController.state.canonicalState as ActiveHuddleState)
            .screenShareOwnerUserId,
        const UserId('user-alice'),
      );
      await replayClient.dispose();
    });

    test('negotiated feature disable preserves state without huddle I/O',
        () async {
      final transport = _FakeHttpTransport((request) async {
        if (request.uri.path.endsWith('/_meta')) {
          return _jsonResponse(_metadata(huddles: false));
        }
        throw StateError('huddle network work is prohibited');
      });
      final client = _client(
        transport,
        requestedCapabilities: const <String, bool>{'huddles': true},
      );
      await client.initialize();
      final controller = client.huddles.forConversation(_conversationId);

      final hydration = await controller.hydrate();
      final start = await controller.start();

      expect(hydration, isA<ChatHuddleActionFeatureDisabled>());
      expect(start, isA<ChatHuddleActionFeatureDisabled>());
      expect(controller.state.canonicalState, isA<InactiveHuddleState>());
      expect(controller.state.media, isA<ChatHuddleMediaUnavailableState>());
      expect(transport.requests, hasLength(1));
      await client.dispose();
    });

    test('keeps descriptors private, ephemeral, and safely printable',
        () async {
      final transport = _FakeHttpTransport((request) async {
        final input = jsonDecode(request.body!) as Map<String, Object?>;
        return _commandResponse(input, _starting, media: true);
      });
      final client = _client(transport);
      final controller = client.huddles.forConversation(_conversationId);

      final result = await controller.start();
      final descriptor = controller.mediaBoundary.readJoinDescriptor();

      expect(descriptor?.descriptor, _descriptorSecret);
      final publicText = <String>[
        controller.toString(),
        controller.state.toString(),
        controller.state.media.toString(),
        controller.mediaBoundary.toString(),
        result.toString(),
        jsonEncode(controller.state.canonicalState.toJson()),
      ].join('\n');
      expect(publicText, isNot(contains(_descriptorSecret)));
      expect(controller.state.canonicalState.toJson(),
          isNot(contains('mediaJoin')));

      await client.dispose();
      expect(controller.mediaBoundary.readJoinDescriptor(), isNull);
    });

    test('retains one realtime subscription for all observers', () async {
      final realtime = _realtime();
      final realtimeStates = <ChatRealtimeConversationSubscriptionState>[];
      final realtimeSubscription =
          realtime.conversationSubscriptionStates.listen(realtimeStates.add);
      final client = _client(
        _FakeHttpTransport((_) async => _jsonResponse(_inactive)),
        realtime: realtime,
      );
      final controller = client.huddles.forConversation(_conversationId);

      final firstStates = <ChatHuddleState>[];
      final first = controller.states.listen(firstStates.add);
      final second = controller.states.listen((_) {});
      await Future<void>.delayed(Duration.zero);
      expect(firstStates.single, same(controller.state));
      expect(
        realtimeStates
            .whereType<ChatRealtimeConversationSubscriptionPendingState>()
            .where((state) =>
                state.operation ==
                ChatRealtimeConversationSubscriptionOperation.subscribe),
        hasLength(1),
      );

      await first.cancel();
      expect(
        realtimeStates
            .whereType<ChatRealtimeConversationSubscriptionRemovedState>(),
        isEmpty,
      );
      await second.cancel();
      expect(
        realtimeStates
            .whereType<ChatRealtimeConversationSubscriptionRemovedState>(),
        hasLength(1),
      );

      await client.dispose();
      await realtimeSubscription.cancel();
      await realtime.dispose();
    });

    test('cancels commands and makes controller/client disposal idempotent',
        () async {
      final response = Completer<HandrailChatHttpResponse>();
      final transport = _FakeHttpTransport((_) => response.future);
      final client = _client(transport);
      final controller = client.huddles.forConversation(_conversationId);
      final cancellation = ChatCommandCancellationController();

      final start = controller.start(
        options: ChatHuddleActionOptions(
          cancellationSignal: cancellation.signal,
        ),
      );
      await Future<void>.delayed(Duration.zero);
      cancellation.cancel();
      final cancelled = await start as ChatHuddleActionFailure;
      expect(cancelled.code, ChatHuddleErrorCode.aborted);

      await client.dispose();
      await client.dispose();
      await controller.dispose();
      expect(
        await controller.start(),
        isA<ChatHuddleActionFailure>().having(
          (result) => result.code,
          'code',
          ChatHuddleErrorCode.closed,
        ),
      );
      expect(
        client.huddles.forConversation(_conversationId),
        same(controller),
      );
      response.complete(
        _commandResponseValue(
          const StartHuddleInput(
            conversationId: _conversationId,
            idempotencyKey: 'huddle-key-1',
          ).toJson(),
          _starting,
          media: true,
        ),
      );
    });
  });
}

HandrailChatClient _client(
  _FakeHttpTransport transport, {
  ChatCommandIdempotencyKeyGenerator? generateIdempotencyKey,
  ChatCommandRetryOptions commandRetryOptions = const ChatCommandRetryOptions(),
  Map<String, bool> requestedCapabilities = const <String, bool>{},
  ChatRealtimeSessionTransport? realtime,
  UserId? currentUser,
}) {
  var sequence = 0;
  final client = HandrailChatClient(
    apiBaseUri: Uri.parse('https://chat.example.test/api/chat'),
    tokenProvider: () async => 'access-token',
    transport: transport,
    requestedCapabilities: requestedCapabilities,
    generateIdempotencyKey:
        generateIdempotencyKey ?? () => 'huddle-key-${++sequence}',
    commandRetryOptions: commandRetryOptions,
    huddleClock: () => _now,
    realtimeSession: realtime,
  );
  // Applied join/leave outcomes require an actor from authenticated identity or
  // the current-user cache, never inferred from response participants. These
  // HTTP-boundary fixtures use the supported cache fallback via currentUser;
  // the opaque token above does not establish identity. Keep omission explicit.
  if (currentUser != null) {
    client.normalizedState.projectCurrentUserReadState(ConversationReadState(
      conversationId: _conversationId,
      userId: currentUser,
      lastReadSequence: const MessageSequence(0),
      updatedAt: const IsoTimestamp('2030-01-01T00:00:00.000Z'),
    ));
  }
  return client;
}

final class _FakeHttpTransport implements HandrailChatHttpTransport {
  _FakeHttpTransport(this._handler);

  final Future<HandrailChatHttpResponse> Function(HandrailChatHttpRequest)
      _handler;
  final List<HandrailChatHttpRequest> requests = <HandrailChatHttpRequest>[];

  @override
  Future<HandrailChatHttpResponse> send(HandrailChatHttpRequest request) {
    requests.add(request);
    return _handler(request);
  }
}

HandrailChatHttpResponse _jsonResponse(Object? value, {int statusCode = 200}) =>
    HandrailChatHttpResponse(
      statusCode: statusCode,
      body: jsonEncode(value),
    );

Future<HandrailChatHttpResponse> _commandResponse(
  Map<String, Object?> input,
  Map<String, Object?> state, {
  bool media = false,
  String reconciliationStatus = 'applied',
}) async =>
    _commandResponseValue(
      input,
      state,
      media: media,
      reconciliationStatus: reconciliationStatus,
    );

HandrailChatHttpResponse _commandResponseValue(
  Map<String, Object?> input,
  Map<String, Object?> state, {
  bool media = false,
  String reconciliationStatus = 'applied',
}) =>
    _jsonResponse(<String, Object?>{
      'operation': input['operation'],
      'outcome': 'ok',
      'reconciliationStatus': reconciliationStatus,
      'state': state,
      if (media)
        'mediaJoin': <String, Object?>{
          'kind': 'opaque_media_join',
          'descriptor': _descriptorSecret,
          'expiresAt': '2030-01-01T00:04:00.000Z',
        },
    });

HuddleSessionState _state(Map<String, Object?> value) =>
    HuddleSessionState.fromJson(value);

Map<String, Object?> _metadata({required bool huddles}) => <String, Object?>{
      'packageVersion': '0.1.3',
      'protocolVersion': handrailChatProtocolVersion,
      'schemaVersion': 1,
      'enabledFeatures': <String, Object?>{
        'huddles': huddles,
        'realtime': true,
      },
      'supportedProtocolRange': <String, Object?>{
        'minimumVersion': handrailChatProtocolVersion - 1,
        'maximumVersion': handrailChatProtocolVersion,
      },
    };

ChatRealtimeSessionTransport _realtime() => ChatRealtimeSessionTransport(
      endpoint: Uri.parse('https://chat.example.test/api/chat'),
      clientPackageVersion: '0.1.3',
      protocolVersion: handrailChatProtocolVersion,
      tokenProvider: () async => 'realtime-token',
      socketFactory: (_, __) => _FakeSocket(),
    );

final class _FakeSocket implements ChatRealtimeSocket {
  final StreamController<Object?> _frames = StreamController<Object?>();

  @override
  Stream<Object?> get frames => _frames.stream;

  @override
  Future<void> close() => _frames.close();

  @override
  void send(String data) {}
}

const _inactive = <String, Object?>{
  'status': 'inactive',
  'conversationId': 'conversation-1',
};

const _starting = <String, Object?>{
  'status': 'starting',
  'conversationId': 'conversation-1',
  'huddleSessionId': 'huddle-1',
  'startedAt': '2030-01-01T00:00:01.000Z',
  'participants': <Object?>[],
  'screenShareOwnerUserId': null,
};

const _active = <String, Object?>{
  'status': 'active',
  'conversationId': 'conversation-1',
  'huddleSessionId': 'huddle-1',
  'startedAt': '2030-01-01T00:00:01.000Z',
  'participants': <Object?>[
    <String, Object?>{
      'userId': 'user-alice',
      'status': 'joined',
      'joinedAt': '2030-01-01T00:00:02.000Z',
    },
  ],
  'screenShareOwnerUserId': null,
};

final _sharing = <String, Object?>{
  ..._active,
  'screenShareOwnerUserId': 'user-alice',
};

final _left = <String, Object?>{
  ..._active,
  'participants': <Object?>[
    <String, Object?>{
      'userId': 'user-alice',
      'status': 'left',
      'joinedAt': '2030-01-01T00:00:02.000Z',
      'leftAt': '2030-01-01T00:00:03.000Z',
    },
  ],
};

const _bob = <String, Object?>{
  'userId': 'user-bob',
  'status': 'joined',
  'joinedAt': '2030-01-01T00:00:02.000Z',
};

final _joinedWithBob = <String, Object?>{
  ..._active,
  'participants': <Object?>[..._active['participants'] as List<Object?>, _bob],
};

final _leftWithBob = <String, Object?>{
  ..._left,
  'participants': <Object?>[..._left['participants'] as List<Object?>, _bob],
};

final _onlyBob = <String, Object?>{
  ..._active,
  'participants': <Object?>[_bob],
};

const _ended = <String, Object?>{
  'status': 'ended',
  'conversationId': 'conversation-1',
  'huddleSessionId': 'huddle-1',
  'startedAt': '2030-01-01T00:00:01.000Z',
  'endedAt': '2030-01-01T00:00:04.000Z',
  'endedByUserId': 'user-alice',
  'participants': <Object?>[
    <String, Object?>{
      'userId': 'user-alice',
      'status': 'left',
      'joinedAt': '2030-01-01T00:00:02.000Z',
      'leftAt': '2030-01-01T00:00:03.000Z',
    },
  ],
  'screenShareOwnerUserId': null,
};
