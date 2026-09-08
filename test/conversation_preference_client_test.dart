import 'dart:async';
import 'dart:convert';

import 'package:handrail_chat/core.dart';
import 'package:test/test.dart';

const _conversation1 = ConversationId('conversation /?#');
const _conversation2 = ConversationId('conversation-2');
const _userId = 'user-current';
const _initialAt = '2026-08-26T15:00:00.000Z';
const _projectedAt = '2026-08-26T16:00:00.000Z';

void main() {
  test('first save uses the snapshot revision and stale snapshots cannot regress it', () async {
    final transport = _Transport((request) async {
      final input = jsonDecode(request.body!) as Map<String, Object?>;
      expect(input['expectedPreferenceRevision'], 1);
      return _response(input, 'applied');
    });
    final fixture = _fixture(transport);
    fixture.store.hydrateConversationDetail(_detail(_conversation1.value, revision: 1));
    final saved = await fixture.client.updateConversationPreference(
      const ChatUpdateConversationPreferenceInput(
        conversationId: _conversation1,
        notificationPreference: ConversationNotificationPreference.none,
        isStarred: false,
        mute: UnmutedConversationPreference(),
      ),
    );
    expect(saved, isA<ChatCommandSuccess<UpdateConversationPreferenceResult>>());
    expect(transport.requests, hasLength(1));
    fixture.store.hydrateConversationDetail(_detail(_conversation1.value, revision: 1));
    expect(fixture.store.conversationPreference(_conversation1).authoritativeRevision, 2);
    expect(fixture.store.conversationPreference(_conversation1).preference?.notificationPreference, 'none');
    fixture.store.hydrateConversationDetail(_detail(_conversation1.value, revision: 3));
    expect(fixture.store.conversationPreference(_conversation1).authoritativeRevision, 3);
    expect(fixture.store.conversationPreference(_conversation1).preference?.notificationPreference, 'mentions');
    await fixture.client.dispose();
  });

  test('normalized store accepts a validated optimistic replacement', () {
    final fixture = _fixture(
      _Transport((_) async => throw StateError('unused')),
    );
    fixture.store.beginOptimisticConversationPreference(
      UpdateConversationPreferenceInput.fromJson({
        'operation': 'update_conversation_preference',
        'conversationId': _conversation1.value,
        'expectedPreferenceRevision': 0,
        'idempotencyKey': 'direct-key',
        'notificationPreference': 'none',
        'isStarred': true,
        'mute': {'muted': false},
      }),
      const IsoTimestamp(_projectedAt),
    );
    expect(
      fixture.store
          .conversationPreference(_conversation1)
          .preference
          ?.notificationPreference,
      'none',
    );
    expect(
      fixture.store
          .conversationPreference(_conversation1)
          .preference
          ?.isStarred,
      isTrue,
    );
  });

  test('encodes exact PATCH request and preserves identity across retry',
      () async {
    var attempts = 0;
    var keyCalls = 0;
    final transport = _Transport((request) async {
      attempts += 1;
      if (attempts == 1) {
        return const HandrailChatHttpResponse(statusCode: 503, body: '{}');
      }
      final input = jsonDecode(request.body!) as Map<String, Object?>;
      return _response(input, 'applied');
    });
    final fixture = _fixture(
      transport,
      key: () => 'stable-key-${++keyCalls}',
      retryOptions: ChatCommandRetryOptions(
        maxAttempts: 2,
        backoff: (_) => Duration.zero,
        wait: (_, __) async {},
      ),
    );

    final pending = fixture.client.updateConversationPreference(
      const ChatUpdateConversationPreferenceInput(
        conversationId: _conversation1,
        notificationPreference: ConversationNotificationPreference.none,
        isStarred: true,
        mute: IndefinitelyMutedConversationPreference(),
      ),
    );
    expect(
      fixture.store
          .conversationPreference(_conversation1)
          .preference
          ?.notificationPreference,
      'none',
    );
    expect(await pending,
        isA<ChatCommandSuccess<UpdateConversationPreferenceResult>>());
    expect(transport.requests, hasLength(2));
    expect(keyCalls, 1);
    expect(transport.requests.first.method, 'PATCH');
    expect(
      transport.requests.first.uri.toString(),
      'https://chat.example.test/api/chat/conversations/'
      'conversation%20%2F%3F%23/preference',
    );
    expect(transport.requests.first.headers,
        containsPair('Accept', 'application/json'));
    expect(transport.requests.first.headers,
        containsPair('Authorization', 'Bearer token'));
    expect(transport.requests.first.headers,
        containsPair('Content-Type', 'application/json'));
    expect(transport.requests.first.headers,
        containsPair('Idempotency-Key', 'stable-key-1'));
    expect(transport.requests[0].body, transport.requests[1].body);
    expect(jsonDecode(transport.requests.first.body!), {
      'operation': 'update_conversation_preference',
      'conversationId': _conversation1.value,
      'expectedPreferenceRevision': 0,
      'idempotencyKey': 'stable-key-1',
      'notificationPreference': 'none',
      'isStarred': true,
      'mute': {'muted': true},
    });
    expect(
      fixture.store
          .conversationPreference(_conversation1)
          .authoritativeRevision,
      1,
    );
    expect(
      fixture.store
          .conversationPreference(_conversation1)
          .authoritativePreference
          ?.isStarred,
      isTrue,
    );
    await fixture.client.dispose();
  });

  test('serializes replacements per conversation and rebases at dispatch',
      () async {
    final first = Completer<HandrailChatHttpResponse>();
    final requests = <Map<String, Object?>>[];
    final transport = _Transport((request) {
      final input = jsonDecode(request.body!) as Map<String, Object?>;
      requests.add(input);
      if (requests.length == 1) return first.future;
      return Future.value(_response(input, 'applied'));
    });
    var key = 0;
    final fixture = _fixture(transport, key: () => 'rapid-${++key}');
    final older = fixture.client.updateConversationPreference(
      const ChatUpdateConversationPreferenceInput(
        conversationId: _conversation1,
        notificationPreference: ConversationNotificationPreference.mentions,
        isStarred: true,
        mute: IndefinitelyMutedConversationPreference(),
      ),
    );
    final newer = fixture.client.updateConversationPreference(
      const ChatUpdateConversationPreferenceInput(
        conversationId: _conversation1,
        notificationPreference: ConversationNotificationPreference.none,
        isStarred: false,
        mute: UnmutedConversationPreference(),
      ),
    );
    expect(
        fixture.store
            .conversationPreference(_conversation1)
            .preference
            ?.notificationPreference,
        'none');
    await Future<void>.delayed(Duration.zero);
    expect(requests, hasLength(1));
    first.complete(_response(requests.first, 'applied'));
    expect(await older,
        isA<ChatCommandSuccess<UpdateConversationPreferenceResult>>());
    expect(await newer,
        isA<ChatCommandSuccess<UpdateConversationPreferenceResult>>());
    expect(
        requests.map((input) => input['expectedPreferenceRevision']), [0, 1]);
    expect(fixture.store.conversationPreference(_conversation1).isPending,
        isFalse);
    await fixture.client.dispose();
  });

  test('unrelated conversation lanes dispatch independently', () async {
    final releases = <String, Completer<HandrailChatHttpResponse>>{};
    final transport = _Transport((request) {
      final input = jsonDecode(request.body!) as Map<String, Object?>;
      final completer = Completer<HandrailChatHttpResponse>();
      releases[input['conversationId']! as String] = completer;
      return completer.future;
    });
    var key = 0;
    final fixture = _fixture(transport, key: () => 'lane-${++key}');
    final first = fixture.client.updateConversationPreference(
      const ChatUpdateConversationPreferenceInput(
        conversationId: _conversation1,
        notificationPreference: ConversationNotificationPreference.none,
        isStarred: true,
        mute: UnmutedConversationPreference(),
      ),
    );
    final second = fixture.client.updateConversationPreference(
      const ChatUpdateConversationPreferenceInput(
        conversationId: _conversation2,
        notificationPreference: ConversationNotificationPreference.all,
        isStarred: false,
        mute: IndefinitelyMutedConversationPreference(),
      ),
    );
    await Future<void>.delayed(Duration.zero);
    expect(transport.requests, hasLength(2));
    for (final request in transport.requests) {
      final input = jsonDecode(request.body!) as Map<String, Object?>;
      releases[input['conversationId']]!.complete(_response(input, 'applied'));
    }
    await Future.wait([first, second]);
    await fixture.client.dispose();
  });

  test('current-first stream reports optimistic and authoritative states',
      () async {
    final release = Completer<HandrailChatHttpResponse>();
    late Map<String, Object?> requestInput;
    final fixture = _fixture(_Transport((request) {
      requestInput = jsonDecode(request.body!) as Map<String, Object?>;
      return release.future;
    }));
    final states = <NormalizedConversationPreferenceState>[];
    final subscription = fixture.store
        .conversationPreferenceStates(_conversation1)
        .listen(states.add);
    await Future<void>.delayed(Duration.zero);
    expect(states.single.preference?.notificationPreference, 'mentions');
    final pending = fixture.client.updateConversationPreference(
      const ChatUpdateConversationPreferenceInput(
        conversationId: _conversation1,
        notificationPreference: ConversationNotificationPreference.none,
        isStarred: true,
        mute: UnmutedConversationPreference(),
      ),
    );
    await Future<void>.delayed(Duration.zero);
    expect(states.last.preference?.notificationPreference, 'none');
    expect(states.last.preference?.isStarred, isTrue);
    expect(states.last.isPending, isTrue);
    release.complete(_response(requestInput, 'applied'));
    await pending;
    expect(states.last.authoritativeRevision, 1);
    expect(states.last.isPending, isFalse);
    await subscription.cancel();
    await fixture.client.dispose();
  });

  test('all settlement statuses are typed successes', () async {
    for (final status in <String>[
      'applied',
      'replayed',
      'already_requested_state',
      'preference_revision_conflict',
    ]) {
      final fixture = _fixture(_Transport((request) async {
        final input = jsonDecode(request.body!) as Map<String, Object?>;
        if (status == 'already_requested_state') {
          input['notificationPreference'] = 'mentions';
          input['isStarred'] = false;
          input['mute'] = {'muted': false};
        }
        return _response(
          input,
          status,
          statusCode: status == 'preference_revision_conflict' ? 409 : 200,
          revision: status == 'preference_revision_conflict' ? 4 : null,
          canonical: status == 'preference_revision_conflict'
              ? {
                  'notificationPreference': 'all',
                  'isStarred': true,
                  'mute': {'muted': false},
                }
              : null,
        );
      }));
      final desired = status == 'already_requested_state'
          ? ConversationNotificationPreference.mentions
          : ConversationNotificationPreference.none;
      final result = await fixture.client.updateConversationPreference(
        ChatUpdateConversationPreferenceInput(
          conversationId: _conversation1,
          notificationPreference: desired,
          isStarred: false,
          mute: const UnmutedConversationPreference(),
        ),
      );
      expect(
          result, isA<ChatCommandSuccess<UpdateConversationPreferenceResult>>(),
          reason: status);
      expect(
        fixture.store
            .conversationPreference(_conversation1)
            .preference
            ?.isStarred,
        status == 'preference_revision_conflict',
        reason: status,
      );
      await fixture.client.dispose();
    }
  });

  test('HTTP/event ordering converges and newer canonical state wins',
      () async {
    for (final eventFirst in [true, false]) {
      late Map<String, Object?> wire;
      final release = Completer<HandrailChatHttpResponse>();
      final fixture = _fixture(_Transport((request) {
        wire = jsonDecode(request.body!) as Map<String, Object?>;
        return release.future;
      }));
      final pending = fixture.client.updateConversationPreference(
        const ChatUpdateConversationPreferenceInput(
          conversationId: _conversation1,
          notificationPreference: ConversationNotificationPreference.none,
          isStarred: true,
          mute: UnmutedConversationPreference(),
        ),
      );
      await Future<void>.delayed(Duration.zero);
      final input = UpdateConversationPreferenceInput.fromJson(wire);
      final canonical = UpdateConversationPreferenceResult.fromJson(
        jsonDecode(_response(wire, 'applied').body),
        expectedInput: input,
      );
      if (eventFirst) {
        fixture.client.reconcileConversationPreference(input, canonical);
      }
      release.complete(_response(wire, 'applied'));
      await pending;
      if (!eventFirst) {
        expect(fixture.client.reconcileConversationPreference(input, canonical),
            isFalse);
      }
      expect(
          fixture.store
              .conversationPreference(_conversation1)
              .authoritativeRevision,
          1);

      final crossInput = UpdateConversationPreferenceInput.fromJson({
        ...wire,
        'idempotencyKey': 'cross-device',
        'expectedPreferenceRevision': 1,
        'notificationPreference': 'all',
        'isStarred': false,
        'mute': {'muted': true},
      });
      final cross = UpdateConversationPreferenceResult.fromJson(
        _resultJson(crossInput.toJson(), 'applied', canonical: {
          'notificationPreference': 'all',
          'isStarred': false,
          'mute': {'muted': true},
        }),
        expectedInput: crossInput,
      );
      expect(fixture.client.reconcileConversationPreference(crossInput, cross),
          isTrue);
      expect(
          fixture.store
              .conversationPreference(_conversation1)
              .preference
              ?.notificationPreference,
          'all');
      expect(
        fixture.store
            .conversationPreference(_conversation1)
            .preference
            ?.isStarred,
        isFalse,
      );
      expect(fixture.client.reconcileConversationPreference(input, canonical),
          isFalse);
      await fixture.client.dispose();
    }
  });

  test('equal-revision divergence is rejected atomically', () async {
    final fixture = _fixture(
        _Transport((_) async => throw StateError('transport is unused')));
    final input = UpdateConversationPreferenceInput.fromJson({
      'operation': 'update_conversation_preference',
      'conversationId': _conversation1.value,
      'expectedPreferenceRevision': 0,
      'idempotencyKey': 'equal-key',
      'notificationPreference': 'all',
      'isStarred': true,
      'mute': {'muted': false},
    });
    final result = UpdateConversationPreferenceResult.fromJson(
      _resultJson(input.toJson(), 'already_requested_state'),
      expectedInput: input,
    );
    final before = fixture.store.state;
    expect(
      () => fixture.client.reconcileConversationPreference(input, result),
      throwsA(isA<NormalizedSnapshotConflict>()),
    );
    expect(identical(fixture.store.state, before), isTrue);
    await fixture.client.dispose();
  });

  test(
      'older failure preserves newer intent and latest failure restores baseline',
      () async {
    var calls = 0;
    final first = Completer<HandrailChatHttpResponse>();
    final fixture = _fixture(_Transport((request) async {
      calls += 1;
      if (calls == 1) return first.future;
      return const HandrailChatHttpResponse(
        statusCode: 403,
        body: '{"error":{"code":"FORBIDDEN","message":"denied"}}',
      );
    }));
    final older = fixture.client.updateConversationPreference(
      const ChatUpdateConversationPreferenceInput(
        conversationId: _conversation1,
        notificationPreference: ConversationNotificationPreference.all,
        isStarred: true,
        mute: IndefinitelyMutedConversationPreference(),
      ),
    );
    final newer = fixture.client.updateConversationPreference(
      const ChatUpdateConversationPreferenceInput(
        conversationId: _conversation1,
        notificationPreference: ConversationNotificationPreference.none,
        isStarred: false,
        mute: UnmutedConversationPreference(),
      ),
    );
    first.complete(const HandrailChatHttpResponse(
      statusCode: 403,
      body: '{"error":{"code":"FORBIDDEN","message":"denied"}}',
    ));
    expect(
        await older,
        isA<
            ChatCommandAuthenticationFailure<
                UpdateConversationPreferenceResult>>());
    expect(
        fixture.store
            .conversationPreference(_conversation1)
            .preference
            ?.notificationPreference,
        'none');
    expect(
      fixture.store
          .conversationPreference(_conversation1)
          .preference
          ?.isStarred,
      isFalse,
    );
    expect(
        await newer,
        isA<
            ChatCommandAuthenticationFailure<
                UpdateConversationPreferenceResult>>());
    expect(
        fixture.store
            .conversationPreference(_conversation1)
            .preference
            ?.notificationPreference,
        'mentions');
    expect(
      fixture.store
          .conversationPreference(_conversation1)
          .preference
          ?.isStarred,
      isFalse,
    );
    await fixture.client.dispose();
  });

  test('queued and active cancellation settle and roll back independently',
      () async {
    final activeRelease = Completer<HandrailChatHttpResponse>();
    final fixture = _fixture(_Transport((_) => activeRelease.future));
    final activeController = ChatCommandCancellationController();
    final queuedController = ChatCommandCancellationController();
    final active = fixture.client.updateConversationPreference(
      const ChatUpdateConversationPreferenceInput(
        conversationId: _conversation1,
        notificationPreference: ConversationNotificationPreference.all,
        isStarred: true,
        mute: UnmutedConversationPreference(),
      ),
      cancellationSignal: activeController.signal,
    );
    final queued = fixture.client.updateConversationPreference(
      const ChatUpdateConversationPreferenceInput(
        conversationId: _conversation1,
        notificationPreference: ConversationNotificationPreference.none,
        isStarred: false,
        mute: UnmutedConversationPreference(),
      ),
      cancellationSignal: queuedController.signal,
    );
    queuedController.cancel();
    expect(await queued,
        isA<ChatCommandAborted<UpdateConversationPreferenceResult>>());
    expect(
        fixture.store
            .conversationPreference(_conversation1)
            .preference
            ?.notificationPreference,
        'all');
    activeController.cancel();
    expect(await active,
        isA<ChatCommandAborted<UpdateConversationPreferenceResult>>());
    expect(
        fixture.store
            .conversationPreference(_conversation1)
            .preference
            ?.notificationPreference,
        'mentions');
    await fixture.client.dispose();
  });

  test('validation avoids transport and dispose cleans externally owned state',
      () async {
    var tokenCalls = 0;
    final transport =
        _Transport((_) async => throw StateError('transport must not run'));
    final fixture = _fixture(
      transport,
      key: () => '   ',
      tokenProvider: () async {
        tokenCalls += 1;
        return 'token';
      },
    );
    final invalid = await fixture.client.updateConversationPreference(
      const ChatUpdateConversationPreferenceInput(
        conversationId: _conversation1,
        notificationPreference: ConversationNotificationPreference.none,
        isStarred: true,
        mute: UnmutedConversationPreference(),
      ),
    );
    expect(
        invalid,
        isA<
            ChatCommandValidationFailure<
                UpdateConversationPreferenceResult>>());
    expect(tokenCalls, 0);
    expect(transport.requests, isEmpty);

    final hanging =
        _Transport((_) => Completer<HandrailChatHttpResponse>().future);
    final external = _fixture(hanging);
    final pending = external.client.updateConversationPreference(
      const ChatUpdateConversationPreferenceInput(
        conversationId: _conversation1,
        notificationPreference: ConversationNotificationPreference.none,
        isStarred: true,
        mute: UnmutedConversationPreference(),
      ),
    );
    await external.client.dispose();
    expect(await pending,
        isA<ChatCommandClosed<UpdateConversationPreferenceResult>>());
    expect(external.store.conversationPreference(_conversation1).isPending,
        isFalse);
    expect(
        external.store
            .conversationPreference(_conversation1)
            .preference
            ?.notificationPreference,
        'mentions');
    expect(
      external.store
          .conversationPreference(_conversation1)
          .preference
          ?.isStarred,
      isFalse,
    );
    expect(() => external.store.state, returnsNormally);
    await external.store.close();
    await fixture.client.dispose();
  });
}

({HandrailChatClient client, NormalizedSnapshotStore store}) _fixture(
  _Transport transport, {
  String Function()? key,
  HandrailChatAccessTokenProvider? tokenProvider,
  ChatCommandRetryOptions retryOptions =
      const ChatCommandRetryOptions(maxAttempts: 1),
}) {
  final store = NormalizedSnapshotStore();
  store.hydrateConversationDetail(_detail(_conversation1.value));
  store.hydrateConversationDetail(_detail(_conversation2.value));
  var generated = 0;
  final client = HandrailChatClient(
    apiBaseUri: Uri.parse('https://chat.example.test/api/chat'),
    tokenProvider: tokenProvider ?? () async => 'token',
    transport: transport,
    commandRetryOptions: retryOptions,
    generateIdempotencyKey: key ?? () => 'preference-key-${++generated}',
    conversationPreferenceClock: () => const IsoTimestamp(_projectedAt),
    normalizedSnapshotStore: store,
  );
  return (client: client, store: store);
}

final class _Transport implements HandrailChatHttpTransport {
  _Transport(this.handler);

  final Future<HandrailChatHttpResponse> Function(HandrailChatHttpRequest)
      handler;
  final List<HandrailChatHttpRequest> requests = [];

  @override
  Future<HandrailChatHttpResponse> send(HandrailChatHttpRequest request) {
    requests.add(request);
    return handler(request);
  }
}

HandrailChatHttpResponse _response(
  Map<String, Object?> input,
  String status, {
  int statusCode = 200,
  int? revision,
  Map<String, Object?>? canonical,
}) =>
    HandrailChatHttpResponse(
      statusCode: statusCode,
      body: jsonEncode(_resultJson(
        input,
        status,
        revision: revision,
        canonical: canonical,
      )),
    );

Map<String, Object?> _resultJson(
  Map<String, Object?> input,
  String status, {
  int? revision,
  Map<String, Object?>? canonical,
}) {
  final desired = <String, Object?>{
    'notificationPreference': input['notificationPreference'],
    'isStarred': input['isStarred'],
    'mute': input['mute'],
  };
  final expected = input['expectedPreferenceRevision']! as int;
  return {
    'operation': 'update_conversation_preference',
    'reconciliationStatus': status,
    'conversationId': input['conversationId'],
    'expectedPreferenceRevision': expected,
    'idempotencyKey': input['idempotencyKey'],
    'requestedPreference': desired,
    'preferenceRevision': revision ??
        (status == 'already_requested_state' ? expected : expected + 1),
    'preference': {
      ...?canonical,
      if (canonical == null) ...desired,
      'updatedAt': status == 'already_requested_state'
          ? _initialAt
          : '2026-08-26T17:00:00.000Z',
    },
  };
}

ConversationDetailSnapshot _detail(String id, {int? revision}) =>
    ConversationDetailSnapshot.fromJson({
      'kind': 'conversation_detail',
      'conversation': {
        'id': id,
        'tenantId': 'tenant-1',
        'type': 'channel',
        'name': 'Channel $id',
        'visibility': 'public',
        'createdAt': _initialAt,
        'updatedAt': _initialAt,
        'latestSequence': 0,
        'activityAt': _initialAt,
        'unreadMentionCount': 0,
        'currentMember': {
          'tenantId': 'tenant-1',
          'conversationId': id,
          'userId': _userId,
          'role': 'member',
          'state': 'active',
          'joinedAt': _initialAt,
          'updatedAt': _initialAt,
        },
        'currentReadState': {
          'conversationId': id,
          'userId': _userId,
          'lastReadSequence': 0,
          'updatedAt': _initialAt,
        },
        'memberUserIds': [_userId],
        'activeMemberUserIds': [_userId],
        'currentPreference': {
          if (revision != null) 'preferenceRevision': revision,
          'conversationId': id,
          'userId': _userId,
          'isStarred': false,
          'notificationPreference': 'mentions',
          'mute': {'muted': false},
          'updatedAt': _initialAt,
        },
      },
      '_meta': {
        'packageVersion': '0.1.3',
        'protocolVersion': 4,
        'schemaVersion': 9,
        'enabledFeatures': {conversationSnapshotFeature: true},
        'supportedProtocolRange': {
          'minimumVersion': 1,
          'maximumVersion': 4,
        },
        'feature': {
          'name': conversationSnapshotFeature,
          'version': conversationSnapshotVersion,
        },
      },
    });
