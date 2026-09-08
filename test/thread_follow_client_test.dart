import 'dart:async';
import 'dart:convert';

import 'package:handrail_chat/core.dart';
import 'package:test/test.dart';

import 'fixtures/thread_creation_fixtures.dart';

const _threadId = ConversationId('conversation-thread');
const _thread2Id = ConversationId('conversation-thread-2');
const _now = '2026-08-26T20:00:00.000Z';

void main() {
  test('unloaded follow target identifies the thread to recover', () async {
    final store = NormalizedSnapshotStore();
    addTearDown(store.close);
    expect(() => store.reduceDurableEvent(
        _event(1, true, ThreadFollowSource.manual, eventId: 'unloaded-follow')),
        throwsA(isA<DurableEventReductionError>().having(
            (error) => error.diagnostic.conversationId, 'resource', _threadId)));
    expect(store.state.conversations, isEmpty);
  });

  test('projects immediately, emits through controller, and sends exact PATCH',
      () async {
    late Map<String, Object?> wire;
    final release = Completer<HandrailChatHttpResponse>();
    final fixture = _fixture(_Transport((request) {
      wire = _body(request);
      return release.future;
    }));
    final controller = fixture.client.threads.forThread(_threadId);
    final states = <NormalizedThreadFollowState>[];
    final subscription = controller.states.listen(states.add);

    final pending = controller.follow();
    await Future<void>.delayed(Duration.zero);
    expect(controller.state.isFollowing, isTrue);
    expect(controller.state.isPending, isTrue);
    expect(states.last.isFollowing, isTrue);
    final request = fixture.transport.requests.single;
    expect(request.method, 'PATCH');
    expect(
      request.uri.toString(),
      'https://chat.example.test/api/chat/conversations/'
      'conversation-thread/follow',
    );
    expect(request.headers['Idempotency-Key'], 'follow-key-1');
    expect(wire, {
      'operation': 'set_thread_follow',
      'intent': 'follow',
      'target': {'type': 'thread', 'id': 'conversation-thread'},
      'expectedFollowRevision': 0,
      'idempotencyKey': 'follow-key-1',
    });
    release.complete(_response(wire, 'applied'));
    expect(await pending, isA<ChatCommandSuccess<SetThreadFollowResult>>());
    expect(controller.state.authoritativeRevision, 1);
    expect(controller.state.isPending, isFalse);
    expect(states.last.isPending, isFalse);

    await subscription.cancel();
    await fixture.client.dispose();
    await fixture.store.close();
  });

  test('serializes opposite intents and rebases from authoritative revision',
      () async {
    final first = Completer<HandrailChatHttpResponse>();
    final bodies = <Map<String, Object?>>[];
    final fixture = _fixture(_Transport((request) {
      final body = _body(request);
      bodies.add(body);
      return bodies.length == 1
          ? first.future
          : Future.value(_response(body, 'applied'));
    }));

    final follow = fixture.client.followThread(_threadId);
    final unfollow = fixture.client.unfollowThread(_threadId);
    expect(fixture.store.threadFollow(_threadId).isFollowing, isFalse);
    await Future<void>.delayed(Duration.zero);
    expect(bodies, hasLength(1));
    first.complete(_response(bodies.single, 'applied'));
    await follow;
    await unfollow;

    expect(bodies.map((body) => body['intent']), ['follow', 'unfollow']);
    expect(bodies.map((body) => body['expectedFollowRevision']), [0, 1]);
    expect(fixture.store.threadFollow(_threadId).authoritativeRevision, 2);
    expect(fixture.store.threadFollow(_threadId).isFollowing, isFalse);
    await fixture.client.dispose();
    await fixture.store.close();
  });

  test('different thread lanes dispatch independently', () async {
    final releases = <String, Completer<HandrailChatHttpResponse>>{};
    final fixture = _fixture(
      _Transport((request) {
        final body = _body(request);
        final id = ((body['target']! as Map)['id'])! as String;
        final release = Completer<HandrailChatHttpResponse>();
        releases[id] = release;
        return release.future;
      }),
      secondThread: true,
    );
    final first = fixture.client.followThread(_threadId);
    final second = fixture.client.followThread(_thread2Id);
    await Future<void>.delayed(Duration.zero);
    expect(fixture.transport.requests, hasLength(2));
    for (final request in fixture.transport.requests) {
      final body = _body(request);
      final id = ((body['target']! as Map)['id'])! as String;
      releases[id]!.complete(_response(body, 'applied'));
    }
    await Future.wait([first, second]);
    await fixture.client.dispose();
    await fixture.store.close();
  });

  test('applied, replayed, already-state, and conflict all reconcile',
      () async {
    for (final status in [
      'applied',
      'replayed',
      'follow_revision_conflict',
    ]) {
      final fixture = _fixture(_Transport((request) async {
        final body = _body(request);
        return _response(
          body,
          status,
          statusCode: status == 'follow_revision_conflict' ? 409 : 200,
        );
      }));
      final result = await fixture.client.followThread(_threadId);
      expect(result, isA<ChatCommandSuccess<SetThreadFollowResult>>());
      expect(fixture.store.threadFollow(_threadId).isPending, isFalse);
      expect(
        fixture.store.threadFollow(_threadId).isFollowing,
        status == 'follow_revision_conflict' ? isFalse : isTrue,
      );
      await fixture.client.dispose();
      await fixture.store.close();
    }

    final fixture = _fixture(_Transport((request) async {
      final body = _body(request);
      return _response(body, 'already_requested_state');
    }));
    fixture.store.reconcileThreadFollowCanonical(
      _threadId,
      1,
      _follow(_threadId, true, ThreadFollowSource.manual),
    );
    final result = await fixture.client.followThread(_threadId);
    expect(result, isA<ChatCommandSuccess<SetThreadFollowResult>>());
    expect(fixture.store.threadFollow(_threadId).authoritativeRevision, 1);
    await fixture.client.dispose();
    await fixture.store.close();
  });

  test('newer auto-follow event survives an older HTTP settlement', () async {
    late Map<String, Object?> wire;
    final release = Completer<HandrailChatHttpResponse>();
    final fixture = _fixture(_Transport((request) {
      wire = _body(request);
      return release.future;
    }));
    final pending = fixture.client.followThread(_threadId);
    await Future<void>.delayed(Duration.zero);
    final reduction = fixture.client.reduceDurableEvent(
      _event(2, true, ThreadFollowSource.reply, eventId: 'event-auto'),
    );
    expect(reduction.status, DurableEventReductionStatus.applied);
    expect(
      fixture.store.threadFollow(_threadId).authoritativeFollow?.source,
      ThreadFollowSource.reply,
    );
    release.complete(_response(wire, 'applied'));
    await pending;
    final state = fixture.store.threadFollow(_threadId);
    expect(state.authoritativeRevision, 2);
    expect(state.follow?.source, ThreadFollowSource.reply);
    expect(state.isPending, isFalse);
    await fixture.client.dispose();
    await fixture.store.close();
  });

  test(
      'manual unfollow wins over auto-follow and divergent equal revision fails',
      () async {
    final fixture = _fixture(
      _Transport((_) async => throw StateError('transport unused')),
    );
    fixture.store.reconcileThreadFollowCanonical(
      _threadId,
      1,
      _follow(_threadId, false, ThreadFollowSource.manual),
    );
    fixture.client.reduceDurableEvent(
      _event(2, true, ThreadFollowSource.mention, eventId: 'event-mention'),
    );
    expect(fixture.store.threadFollow(_threadId).isFollowing, isFalse);
    expect(fixture.store.threadFollow(_threadId).authoritativeRevision, 1);

    expect(
      () => fixture.client.reduceDurableEvent(
        _event(
          1,
          true,
          ThreadFollowSource.manual,
          eventId: 'event-conflict',
          occurredAt: '2026-08-26T21:00:00.000Z',
        ),
      ),
      throwsA(isA<DurableEventReductionError>()),
    );
    await fixture.client.dispose();
    await fixture.store.close();
  });

  test('stale private follow event cannot replace a newer revision', () async {
    final fixture = _fixture(
      _Transport((_) async => throw StateError('transport unused')),
    );
    fixture.store.reconcileThreadFollowCanonical(
      _threadId,
      3,
      _follow(_threadId, true, ThreadFollowSource.reply),
    );
    fixture.client.reduceDurableEvent(
      _event(2, false, ThreadFollowSource.manual, eventId: 'event-stale'),
    );
    final state = fixture.store.threadFollow(_threadId);
    expect(state.authoritativeRevision, 3);
    expect(state.isFollowing, isTrue);
    expect(state.follow?.source, ThreadFollowSource.reply);
    await fixture.client.dispose();
    await fixture.store.close();
  });

  for (final clock in {
    'tied': _now,
    'decreasing': '2026-08-26T19:59:59.999Z',
  }.entries) {
    test('${clock.key} clocks admit independent thread revisions', () async {
      final fixture = _fixture(
        _Transport((_) async => throw StateError('transport unused')),
        secondThread: true,
      );
      addTearDown(fixture.store.close);
      addTearDown(fixture.client.dispose);
      final first = _event(1, true, ThreadFollowSource.reply,
          eventId: 'event-first');
      final second = _event(1, false, ThreadFollowSource.manual,
          eventId: 'event-second',
          threadId: _thread2Id,
          occurredAt: clock.value);
      expect(fixture.client.reduceDurableEvent(first).status,
          DurableEventReductionStatus.applied);
      expect(fixture.client.reduceDurableEvent(second).status,
          DurableEventReductionStatus.applied);

      final accepted = fixture.store.state;
      expect(accepted.threadFollowRevisions, {_threadId: 1, _thread2Id: 1});
      for (final entry in {
        _threadId: _follow(_threadId, true, ThreadFollowSource.reply),
        _thread2Id: _follow(_thread2Id, false, ThreadFollowSource.manual),
      }.entries) {
        expect(accepted.authoritativeCurrentUserThreadFollows[entry.key]?.toJson(),
            entry.value.toJson());
        expect(accepted.currentUserThreadFollows[entry.key]?.toJson(),
            entry.value.toJson());
      }
      expect(accepted.latestReplayCursor?.eventId, second.eventId);
      final stream = accepted.durableStreams[second.streamId]!;
      expect(stream.lastEventId, second.eventId);
      expect(stream.lastOccurredAt.value, _now);
      expect(stream.recentEventIds, [first.eventId, second.eventId]);
      for (final replay in [first, second]) {
        final result = fixture.client.reduceDurableEvent(replay);
        expect(result.status, DurableEventReductionStatus.duplicate);
        expect(result.state, same(accepted));
        expect(fixture.store.state, same(accepted));
      }

      final newer = _event(3, true, ThreadFollowSource.manual,
          eventId: 'event-newer', occurredAt: clock.value);
      fixture.client.reduceDurableEvent(newer);
      final lower = _event(2, false, ThreadFollowSource.manual,
          eventId: 'event-lower', occurredAt: clock.value);
      expect(fixture.client.reduceDurableEvent(lower).status,
          DurableEventReductionStatus.applied);
      expect(fixture.store.threadFollow(_threadId).authoritativeRevision, 3);
      expect(fixture.store.threadFollow(_threadId).isFollowing, isTrue);
      expect(fixture.store.threadFollow(_thread2Id).authoritativeRevision, 1);
      expect(fixture.store.threadFollow(_thread2Id).isFollowing, isFalse);
      expect(fixture.store.state.latestReplayCursor?.eventId, lower.eventId);
      expect(fixture.store.state.durableStreams[lower.streamId]!.lastOccurredAt.value,
          _now);
    });

    test('${clock.key} malformed follow events reject atomically', () async {
      final fixture = _fixture(
        _Transport((_) async => throw StateError('transport unused')),
        secondThread: true,
      );
      addTearDown(fixture.store.close);
      addTearDown(fixture.client.dispose);
      fixture.client.reduceDurableEvent(_event(
          1, true, ThreadFollowSource.manual, eventId: 'event-baseline'));
      fixture.store.beginOptimisticThreadFollow(
        SetThreadFollowInput.fromJson({
          'operation': 'set_thread_follow',
          'intent': 'unfollow',
          'target': {'type': 'thread', 'id': _threadId.value},
          'expectedFollowRevision': 1,
          'idempotencyKey': 'pending-unfollow',
        }),
        const IsoTimestamp(_now),
      );
      final before = fixture.store.state;
      void expectUnchanged() {
        expect(fixture.store.state, same(before));
        expect(fixture.store.state.latestReplayCursor, same(before.latestReplayCursor));
        expect(fixture.store.state.durableStreams, same(before.durableStreams));
        expect(fixture.store.state.pendingThreadFollowIntents,
            same(before.pendingThreadFollowIntents));
        final follow = fixture.store.threadFollow(_threadId);
        expect(follow.authoritativeRevision, 1);
        expect(follow.authoritativeFollow?.isFollowing, isTrue);
        expect(follow.isFollowing, isFalse);
        expect(follow.isPending, isTrue);
        expect(follow.pendingIntents.single.idempotencyKey, 'pending-unfollow');
      }

      // A valid envelope with divergent equal-revision state reaches the reducer.
      expect(
        () => fixture.client.reduceDurableEvent(_event(
            1, false, ThreadFollowSource.manual,
            eventId: 'event-divergent', occurredAt: clock.value)),
        throwsA(isA<DurableEventReductionError>().having(
            (error) => error.diagnostic.code, 'code',
            DurableEventDiagnosticCode.incoherentPayload)),
      );
      expectUnchanged();

      final valid = _event(2, true, ThreadFollowSource.manual,
          eventId: 'event-invalid', threadId: _thread2Id,
          occurredAt: clock.value).toJson();
      for (final malformed in [
        {...valid, 'streamId': 'user:other'},
        {...valid, 'payload': {
          ...valid['payload']! as Map<String, Object?>,
          'followRevision': 0,
        }},
        {...valid, 'payload': {
          ...valid['payload']! as Map<String, Object?>,
          'target': {'type': 'thread', 'id': _threadId.value},
        }},
      ]) {
        expect(
          () => fixture.client.reduceDurableEvent(KnownDurableEvent.fromJson(
            malformed,
            trustedIdentity: const DurableEventTrustedIdentity(
              tenantId: TenantId('tenant-from-session'),
              userId: UserId('user-current'),
            ),
          )),
          throwsFormatException,
        );
        expectUnchanged();
      }
      // Rejection must not consume the ID or settle the pending local intent.
      final corrected = _event(2, true, ThreadFollowSource.manual,
          eventId: 'event-divergent', occurredAt: clock.value);
      expect(fixture.client.reduceDurableEvent(corrected).status,
          DurableEventReductionStatus.applied);
      final follow = fixture.store.threadFollow(_threadId);
      expect(follow.authoritativeRevision, 2);
      expect(follow.authoritativeFollow?.isFollowing, isTrue);
      expect(follow.isFollowing, isFalse);
      expect(follow.isPending, isTrue);
      expect(fixture.store.state.pendingThreadFollowIntents,
          before.pendingThreadFollowIntents);
      expect(fixture.store.state.latestReplayCursor?.eventId, corrected.eventId);
      expect(fixture.store.state.durableStreams[corrected.streamId]!.lastOccurredAt.value,
          _now);
    });
  }

  test('failure rollback preserves newer projection', () async {
    final first = Completer<HandrailChatHttpResponse>();
    var calls = 0;
    final fixture = _fixture(_Transport((_) {
      calls += 1;
      return calls == 1
          ? first.future
          : Future.value(const HandrailChatHttpResponse(
              statusCode: 403,
              body: '{"error":{"code":"FORBIDDEN"}}',
            ));
    }));
    final older = fixture.client.followThread(_threadId);
    final newer = fixture.client.unfollowThread(_threadId);
    first.complete(const HandrailChatHttpResponse(
      statusCode: 403,
      body: '{"error":{"code":"FORBIDDEN"}}',
    ));
    await older;
    expect(fixture.store.threadFollow(_threadId).isFollowing, isFalse);
    await newer;
    expect(fixture.store.threadFollow(_threadId).follow, isNull);
    await fixture.client.dispose();
    await fixture.store.close();
  });

  test('queued cancellation and disposal settle without controller updates',
      () async {
    final fixture = _fixture(
      _Transport((_) => Completer<HandrailChatHttpResponse>().future),
    );
    final active = fixture.client.followThread(_threadId);
    final cancellation = ChatCommandCancellationController();
    final queued = fixture.client.unfollowThread(
      _threadId,
      cancellationSignal: cancellation.signal,
    );
    cancellation.cancel();
    expect(await queued, isA<ChatCommandAborted<SetThreadFollowResult>>());
    expect(fixture.store.threadFollow(_threadId).isFollowing, isTrue);

    final controller = fixture.client.threads.forThread(_threadId);
    final states = <NormalizedThreadFollowState>[];
    final subscription = controller.states.listen(states.add);
    await Future<void>.delayed(Duration.zero);
    await fixture.client.dispose();
    expect(await active, isA<ChatCommandClosed<SetThreadFollowResult>>());
    expect(
      await fixture.client.followThread(_threadId),
      isA<ChatCommandClosed<SetThreadFollowResult>>(),
    );
    final countAfterClose = states.length;
    fixture.store.reconcileThreadFollowCanonical(
      _threadId,
      3,
      _follow(_threadId, true, ThreadFollowSource.reply),
    );
    expect(states, hasLength(countAfterClose));
    await subscription.cancel();
    await fixture.store.close();
  });
}

({
  HandrailChatClient client,
  NormalizedSnapshotStore store,
  _Transport transport,
}) _fixture(
  _Transport transport, {
  bool secondThread = false,
}) {
  final store = NormalizedSnapshotStore();
  _seedThread(store, _threadId, 'message-root', 'conversation-parent');
  if (secondThread) {
    _seedThread(store, _thread2Id, 'message-root-2', 'conversation-parent-2');
  }
  var key = 0;
  final client = HandrailChatClient(
    apiBaseUri: Uri.parse('https://chat.example.test/api/chat'),
    tokenProvider: () async => 'token',
    transport: transport,
    commandRetryOptions: const ChatCommandRetryOptions(maxAttempts: 1),
    generateIdempotencyKey: () => 'follow-key-${++key}',
    threadFollowClock: () => const IsoTimestamp(_now),
    normalizedSnapshotStore: store,
  );
  return (client: client, store: store, transport: transport);
}

void _seedThread(
  NormalizedSnapshotStore store,
  ConversationId threadId,
  String rootId,
  String parentId,
) {
  store.hydrateConversationDetail(_channelDetail(parentId));
  store.reconcileMessage(Message.fromJson({
    'id': rootId,
    'tenantId': 'tenant-from-session',
    'conversationId': parentId,
    'author': {'type': 'user', 'userId': 'user-current'},
    'sequence': 1,
    'createdAt': _now,
    'updatedAt': _now,
    'revision': {'revision': 1},
    'content': {'format': 'plain', 'text': 'root'},
  }));
  final input = ThreadCreationInput.fromJson({
    'operation': 'create_thread',
    'parentConversationId': parentId,
    'rootMessageId': rootId,
    'idempotencyKey': 'seed-$rootId',
  });
  store.reconcileThreadOpening(ThreadCreationResult.fromJson(
    threadCreationResultFixture(
      'created',
      parentConversationId: parentId,
      rootMessageId: rootId,
      threadId: threadId.value,
      summaryThreadId: threadId.value,
    ),
    expectedInput: input,
  ));
}

ConversationDetailSnapshot _channelDetail(String id) =>
    ConversationDetailSnapshot.fromJson({
      'kind': 'conversation_detail',
      'conversation': {
        'id': id,
        'tenantId': 'tenant-from-session',
        'type': 'channel',
        'name': 'Parent',
        'visibility': 'public',
        'createdAt': _now,
        'updatedAt': _now,
        'latestSequence': 1,
        'activityAt': _now,
        'unreadMentionCount': 0,
        'currentMember': {
          'tenantId': 'tenant-from-session',
          'conversationId': id,
          'userId': 'user-current',
          'role': 'member',
          'state': 'active',
          'joinedAt': _now,
          'updatedAt': _now,
        },
        'currentReadState': {
          'conversationId': id,
          'userId': 'user-current',
          'lastReadSequence': 0,
          'updatedAt': _now,
        },
        'memberUserIds': ['user-current'],
        'currentPreference': {
          'conversationId': id,
          'userId': 'user-current',
          'notificationPreference': 'mentions',
          'isStarred': false,
          'mute': {'muted': false},
          'updatedAt': _now,
        },
        'activeMemberUserIds': ['user-current'],
      },
      '_meta': {
        'packageVersion': '0.1.4',
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

Map<String, Object?> _body(HandrailChatHttpRequest request) =>
    (jsonDecode(request.body!) as Map).cast<String, Object?>();

HandrailChatHttpResponse _response(
  Map<String, Object?> input,
  String status, {
  int statusCode = 200,
}) {
  final expected = input['expectedFollowRevision']! as int;
  final conflict = status == 'follow_revision_conflict';
  final following =
      conflict ? input['intent'] != 'follow' : input['intent'] == 'follow';
  return HandrailChatHttpResponse(
    statusCode: statusCode,
    body: jsonEncode({
      'operation': 'set_thread_follow',
      'intent': input['intent'],
      'reconciliationStatus': status,
      'target': input['target'],
      'expectedFollowRevision': expected,
      'idempotencyKey': input['idempotencyKey'],
      'followRevision': conflict
          ? expected + 3
          : status == 'already_requested_state'
              ? expected
              : expected + 1,
      'follow': {
        'target': input['target'],
        'isFollowing': following,
        'source': 'manual',
        'updatedAt': _now,
      },
    }),
  );
}

CanonicalThreadFollowState _follow(
  ConversationId threadId,
  bool following,
  ThreadFollowSource source,
) =>
    CanonicalThreadFollowState.fromJson({
      'target': {'type': 'thread', 'id': threadId.value},
      'isFollowing': following,
      'source': source.toJson(),
      'updatedAt': _now,
    });

ThreadFollowUpdatedDurableEvent _event(
  int revision,
  bool following,
  ThreadFollowSource source, {
  required String eventId,
  String occurredAt = _now,
  ConversationId threadId = _threadId,
}) =>
    KnownDurableEvent.fromJson(
      {
        'eventId': eventId,
        'protocolVersion': 4,
        'tenantId': 'tenant-from-session',
        'streamId': 'user:user-current',
        'type': 'thread.follow.updated',
        'occurredAt': occurredAt,
        'payload': {
          'operation': 'set_thread_follow',
          'target': {'type': 'thread', 'id': threadId.value},
          'followRevision': revision,
          'follow': _follow(threadId, following, source).toJson(),
        },
      },
      trustedIdentity: const DurableEventTrustedIdentity(
        tenantId: TenantId('tenant-from-session'),
        userId: UserId('user-current'),
      ),
    ) as ThreadFollowUpdatedDurableEvent;
