import 'dart:async';
import 'dart:convert';

import 'package:handrail_chat/src/core/command_dispatcher.dart';
import 'package:handrail_chat/src/core/normalized_snapshot_state.dart';
import 'package:handrail_chat/src/generated/conversation_membership.dart';
import 'package:handrail_chat/src/generated/conversation_snapshot.dart';
import 'package:handrail_chat/src/generated/identifiers.dart';
import 'package:handrail_chat/src/generated/message.dart';
import 'package:handrail_chat/src/generated/message_timeline.dart';
import 'package:handrail_chat/src/handrail_chat_client.dart';
import 'package:handrail_chat/src/realtime_session_transport.dart';
import 'package:test/test.dart';

import 'fixtures/conversation_membership_fixtures.dart';

const _tenantId = 'tenant-1';
const _currentUserId = 'user-actor';
const _timestamp = '2026-08-26T04:30:00.000Z';

void main() {
  group('HandrailChatClient conversation membership', () {
    test('exposes all five commands with exact PATCH routes and bodies',
        () async {
      const encodedConversationId = 'conversation /one';
      var identity = 0;
      final transport = _RecordingTransport((request) {
        final body = _body(request);
        return Future.value(_response(appliedMembershipFixture(body)));
      });
      final store = NormalizedSnapshotStore()
        ..hydrateConversationDetail(_detail(encodedConversationId));
      final client = _client(
        transport,
        store: store,
        idempotencyKey: () => 'membership-id-${++identity}',
      );
      final commands =
          <Future<ChatCommandResult<ConversationMembershipMutationResult>>>[
        client.joinConversation(const ChatJoinConversationInput(
          conversationId: ConversationId(encodedConversationId),
          expectedMemberListRevision: 4,
        )),
        client.leaveConversation(const ChatLeaveConversationInput(
          conversationId: ConversationId(encodedConversationId),
          expectedMemberListRevision: 5,
        )),
        client.addConversationMember(const ChatAddConversationMemberInput(
          conversationId: ConversationId(encodedConversationId),
          targetUserId: UserId('user-c'),
          requestedRole: ConversationMembershipMemberRole.moderator,
          expectedMemberListRevision: 6,
        )),
        client.removeConversationMember(
          const ChatRemoveConversationMemberInput(
            conversationId: ConversationId(encodedConversationId),
            targetUserId: UserId('user-c'),
            expectedMemberListRevision: 7,
          ),
        ),
        client.changeConversationMemberRole(
          const ChatChangeConversationMemberRoleInput(
            conversationId: ConversationId(encodedConversationId),
            targetUserId: UserId('user-b'),
            requestedRole: ConversationMembershipMemberRole.moderator,
            expectedMemberListRevision: 8,
          ),
        ),
      ];

      for (final command in commands) {
        expect((await command).category, ChatCommandResultCategory.success);
      }
      expect(transport.requests, hasLength(5));
      final intents = membershipInputFixtures.keys.toList(growable: false);
      for (var index = 0; index < transport.requests.length; index++) {
        final request = transport.requests[index];
        final fixture = membershipInputFixtures[intents[index]]!;
        expect(request.method, 'PATCH');
        expect(
          request.uri.toString(),
          'https://chat.test/api/conversations/'
          'conversation%20%2Fone/membership',
        );
        expect(_body(request), {
          ...fixture,
          'conversationId': encodedConversationId,
          'idempotencyKey': 'membership-id-${index + 1}',
        });
        expect(
          request.headers['Idempotency-Key'],
          _body(request)['idempotencyKey'],
        );
      }
      await client.dispose();
      await store.close();
    });

    test('serializes per conversation while unrelated conversations proceed',
        () async {
      final firstResponse = Completer<HandrailChatHttpResponse>();
      var conversationOneRequests = 0;
      final transport = _RecordingTransport((request) {
        final body = _body(request);
        if (body['conversationId'] == 'conversation-1') {
          conversationOneRequests += 1;
          if (conversationOneRequests == 1) return firstResponse.future;
        }
        return Future.value(_response(appliedMembershipFixture(body)));
      });
      final store = NormalizedSnapshotStore()
        ..hydrateConversationDetail(_detail('conversation-1'))
        ..hydrateConversationDetail(_detail('conversation-2'));
      final client = _client(transport, store: store);

      final first = client.addConversationMember(
        const ChatAddConversationMemberInput(
          conversationId: ConversationId('conversation-1'),
          targetUserId: UserId('user-c'),
          requestedRole: ConversationMembershipMemberRole.moderator,
          expectedMemberListRevision: 4,
        ),
      );
      await _waitFor(() => transport.requests.length == 1);
      final second = client.changeConversationMemberRole(
        const ChatChangeConversationMemberRoleInput(
          conversationId: ConversationId('conversation-1'),
          targetUserId: UserId('user-b'),
          requestedRole: ConversationMembershipMemberRole.moderator,
          expectedMemberListRevision: 5,
        ),
      );
      final unrelated = client.addConversationMember(
        const ChatAddConversationMemberInput(
          conversationId: ConversationId('conversation-2'),
          targetUserId: UserId('user-c'),
          requestedRole: ConversationMembershipMemberRole.moderator,
          expectedMemberListRevision: 4,
        ),
      );
      await _waitFor(() => transport.requests.length == 2);
      expect(
        transport.requests.map((request) => _body(request)['conversationId']),
        ['conversation-1', 'conversation-2'],
      );
      expect((await unrelated).category, ChatCommandResultCategory.success);
      firstResponse.complete(
        _response(appliedMembershipFixture(_body(transport.requests.first))),
      );
      expect((await first).category, ChatCommandResultCategory.success);
      expect((await second).category, ChatCommandResultCategory.success);
      expect(transport.requests, hasLength(3));
      await client.dispose();
      await store.close();
    });

    test('keeps one idempotency key and body across safe retries', () async {
      var attempts = 0;
      var generated = 0;
      final transport = _RecordingTransport((request) {
        attempts += 1;
        if (attempts == 1) throw StateError('retry');
        return Future.value(
            _response(appliedMembershipFixture(_body(request))));
      });
      final store = NormalizedSnapshotStore()
        ..hydrateConversationDetail(_detail('conversation-1'));
      final client = _client(
        transport,
        store: store,
        idempotencyKey: () => 'stable-membership-${++generated}',
        retryOptions: ChatCommandRetryOptions(
          maxAttempts: 2,
          wait: (_, __) async {},
        ),
      );

      final result = await client.joinConversation(
        const ChatJoinConversationInput(
          conversationId: ConversationId('conversation-1'),
          expectedMemberListRevision: 4,
        ),
      );

      expect(result.category, ChatCommandResultCategory.success);
      expect(generated, 1);
      expect(transport.requests, hasLength(2));
      expect(transport.requests.first.body, transport.requests.last.body);
      expect(
        transport.requests.first.headers['Idempotency-Key'],
        transport.requests.last.headers['Idempotency-Key'],
      );
      await client.dispose();
      await store.close();
    });

    test('reconciles applied, replayed, conflict, safety, and stale outcomes',
        () async {
      final responses = <({int status, Map<String, Object?> body})>[];
      final transport = _RecordingTransport((request) {
        final next = responses.removeAt(0);
        return Future.value(_response(next.body, statusCode: next.status));
      });
      final store = NormalizedSnapshotStore()
        ..hydrateConversationDetail(_detail('conversation-1'))
        ..hydrateConversationDetail(_detail('conversation-2'));
      final client = _client(transport, store: store);

      final addInput = <String, Object?>{
        ...membershipInputFixtures['add_member']!,
        'expectedMemberListRevision': 4,
      };
      final applied = appliedMembershipFixture(addInput);
      responses.add((status: 200, body: applied));
      expect(
        (await client.addConversationMember(
          const ChatAddConversationMemberInput(
            conversationId: ConversationId('conversation-1'),
            targetUserId: UserId('user-c'),
            requestedRole: ConversationMembershipMemberRole.moderator,
            expectedMemberListRevision: 4,
          ),
        ))
            .category,
        ChatCommandResultCategory.success,
      );

      final already = <String, Object?>{
        ...applied,
        'reconciliationStatus': 'already_requested_state',
        'expectedMemberListRevision': 5,
        'memberListRevision': 5,
      };
      responses.add((status: 200, body: already));
      expect(
        (await client.addConversationMember(
          const ChatAddConversationMemberInput(
            conversationId: ConversationId('conversation-1'),
            targetUserId: UserId('user-c'),
            requestedRole: ConversationMembershipMemberRole.moderator,
            expectedMemberListRevision: 5,
          ),
        ))
            .category,
        ChatCommandResultCategory.success,
      );
      expect(
          store.state
              .memberListRevisions[const ConversationId('conversation-1')],
          5);
      expect(
        store
            .state
            .membersByConversation[const ConversationId('conversation-1')]![
                const UserId('user-c')]!
            .role,
        'moderator',
      );

      responses.add((
        status: 200,
        body: {...applied, 'reconciliationStatus': 'replayed'},
      ));
      expect(
        (await client.addConversationMember(
          const ChatAddConversationMemberInput(
            conversationId: ConversationId('conversation-1'),
            targetUserId: UserId('user-c'),
            requestedRole: ConversationMembershipMemberRole.moderator,
            expectedMemberListRevision: 4,
          ),
        ))
            .category,
        ChatCommandResultCategory.success,
      );

      final conflict = <String, Object?>{
        ...applied,
        'reconciliationStatus': 'member_list_conflict',
        'memberListRevision': 8,
        'members': [
          membershipMember('user-actor', 'member'),
          membershipMember('user-b', 'owner'),
          membershipMember('user-c', 'member'),
        ],
      };
      responses.add((status: 409, body: conflict));
      final conflictResult = await client.addConversationMember(
        const ChatAddConversationMemberInput(
          conversationId: ConversationId('conversation-1'),
          targetUserId: UserId('user-c'),
          requestedRole: ConversationMembershipMemberRole.moderator,
          expectedMemberListRevision: 4,
        ),
      );
      expect(conflictResult.category, ChatCommandResultCategory.success);
      expect(
          store.state
              .memberListRevisions[const ConversationId('conversation-1')],
          8);
      expect(
        store
            .state
            .membersByConversation[const ConversationId('conversation-1')]![
                const UserId('user-c')]!
            .role,
        'member',
      );
      final restored = NormalizedSnapshotStateStorageCodec.decode(
        NormalizedSnapshotStateStorageCodec.encode(store.state),
      );
      expect(restored.memberListRevisions, {
        const ConversationId('conversation-1'): 8,
      });

      final safetyInput = membershipInputFixtures['leave']!;
      final safety = <String, Object?>{
        'operation': 'mutate_conversation_membership',
        'intent': 'leave',
        'reconciliationStatus': 'safety_rejected',
        'conversationId': 'conversation-2',
        'expectedMemberListRevision': 5,
        'memberListRevision': 5,
        'memberUserId': _currentUserId,
        'members': [membershipMember(_currentUserId, 'owner')],
        'safetyError': {
          'code': 'last_active_member',
          'message': 'The last active member cannot leave.',
        },
      };
      expect(safetyInput['intent'], 'leave');
      responses.add((status: 409, body: safety));
      final safetyResult = await client.leaveConversation(
        const ChatLeaveConversationInput(
          conversationId: ConversationId('conversation-2'),
          expectedMemberListRevision: 5,
        ),
      );
      expect(safetyResult.category, ChatCommandResultCategory.success);
      expect(
          store.state
              .memberListRevisions[const ConversationId('conversation-2')],
          5);
      expect(
        store.state.currentUserReadStates,
        contains(const ConversationId('conversation-2')),
      );

      final stale = appliedMembershipFixture(addInput);
      responses.add((status: 200, body: stale));
      expect(
        (await client.addConversationMember(
          const ChatAddConversationMemberInput(
            conversationId: ConversationId('conversation-1'),
            targetUserId: UserId('user-c'),
            requestedRole: ConversationMembershipMemberRole.moderator,
            expectedMemberListRevision: 4,
          ),
        ))
            .category,
        ChatCommandResultCategory.success,
      );
      expect(
          store.state
              .memberListRevisions[const ConversationId('conversation-1')],
          8);
      expect(
        store
            .state
            .membersByConversation[const ConversationId('conversation-1')]![
                const UserId('user-c')]!
            .role,
        'member',
      );
      await client.dispose();
      await store.close();
    });

    test('leave clears only revoked conversation access and subscription state',
        () async {
      final store = _hydratedAccessStore();
      final realtime = _idleRealtimeSession()
        ..subscribeConversation(const ConversationId('conversation-1'))
        ..subscribeConversation(const ConversationId('conversation-2'));
      final transport = _RecordingTransport((request) => Future.value(
            _response(appliedMembershipFixture(_body(request))),
          ));
      final client = _client(
        transport,
        store: store,
        realtimeSession: realtime,
      );

      final result = await client.leaveConversation(
        const ChatLeaveConversationInput(
          conversationId: ConversationId('conversation-1'),
          expectedMemberListRevision: 5,
        ),
      );

      expect(result.category, ChatCommandResultCategory.success);
      _expectAccessCleared(store, 'conversation-1');
      _expectAccessPreserved(store, 'conversation-2');
      expect(
        realtime.conversationSubscriptionStatesById['conversation-1'],
        isA<ChatRealtimeConversationSubscriptionRemovedState>(),
      );
      expect(
        realtime.conversationSubscriptionStatesById['conversation-2'],
        isA<ChatRealtimeConversationSubscriptionPendingState>(),
      );
      await client.dispose();
      await realtime.dispose();
      await store.close();
    });

    test('current-user removal clears access; another removal preserves it',
        () async {
      for (final removesCurrentUser in [true, false]) {
        final store = _hydratedAccessStore();
        final realtime = _idleRealtimeSession()
          ..subscribeConversation(const ConversationId('conversation-1'));
        final transport = _RecordingTransport((request) {
          final body = _body(request);
          final target = body['targetUserId']! as String;
          return Future.value(_response({
            'operation': 'mutate_conversation_membership',
            'intent': 'remove_member',
            'reconciliationStatus': 'applied',
            'conversationId': 'conversation-1',
            'targetUserId': target,
            'expectedMemberListRevision': 7,
            'memberListRevision': 8,
            'memberUserId': target,
            'members': [
              membershipMember(
                _currentUserId,
                'member',
                removesCurrentUser ? 'removed' : 'active',
              ),
              membershipMember(
                'user-other',
                'owner',
                removesCurrentUser ? 'active' : 'removed',
              ),
            ],
          }));
        });
        final client = _client(
          transport,
          store: store,
          realtimeSession: realtime,
        );

        final result = await client.removeConversationMember(
          ChatRemoveConversationMemberInput(
            conversationId: const ConversationId('conversation-1'),
            targetUserId: UserId(
              removesCurrentUser ? _currentUserId : 'user-other',
            ),
            expectedMemberListRevision: 7,
          ),
        );
        expect(result.category, ChatCommandResultCategory.success);
        if (removesCurrentUser) {
          _expectAccessCleared(store, 'conversation-1');
          expect(
            realtime.conversationSubscriptionStatesById['conversation-1'],
            isA<ChatRealtimeConversationSubscriptionRemovedState>(),
          );
        } else {
          _expectAccessPreserved(store, 'conversation-1');
          expect(
            realtime.conversationSubscriptionStatesById['conversation-1'],
            isA<ChatRealtimeConversationSubscriptionPendingState>(),
          );
        }
        _expectAccessPreserved(store, 'conversation-2');
        await client.dispose();
        await realtime.dispose();
        await store.close();
      }
    });

    test('cancels before, while queued, during dispatch, and on disposal',
        () async {
      var tokenCalls = 0;
      final response = Completer<HandrailChatHttpResponse>();
      final transport = _RecordingTransport((_) => response.future);
      final store = NormalizedSnapshotStore()
        ..hydrateConversationDetail(_detail('conversation-1'));
      final client = _client(
        transport,
        store: store,
        tokenProvider: () async {
          tokenCalls += 1;
          return 'access-token';
        },
      );

      final cancelled = ChatCommandCancellationController()..cancel();
      final before = await client.joinConversation(
        const ChatJoinConversationInput(
          conversationId: ConversationId('conversation-1'),
          expectedMemberListRevision: 4,
        ),
        cancellationSignal: cancelled.signal,
      );
      expect(before.category, ChatCommandResultCategory.aborted);
      expect(tokenCalls, 0);

      final activeCancellation = ChatCommandCancellationController();
      final active = client.joinConversation(
        const ChatJoinConversationInput(
          conversationId: ConversationId('conversation-1'),
          expectedMemberListRevision: 4,
        ),
        cancellationSignal: activeCancellation.signal,
      );
      await _waitFor(() => transport.requests.length == 1);
      final queuedCancellation = ChatCommandCancellationController();
      final queued = client.leaveConversation(
        const ChatLeaveConversationInput(
          conversationId: ConversationId('conversation-1'),
          expectedMemberListRevision: 5,
        ),
        cancellationSignal: queuedCancellation.signal,
      );
      queuedCancellation.cancel();
      expect((await queued).category, ChatCommandResultCategory.aborted);
      expect(transport.requests, hasLength(1));
      expect(store.state.memberListRevisions, isEmpty);

      activeCancellation.cancel();
      expect((await active).category, ChatCommandResultCategory.aborted);
      expect(store.state.memberListRevisions, isEmpty);

      final closing = client.joinConversation(
        const ChatJoinConversationInput(
          conversationId: ConversationId('conversation-1'),
          expectedMemberListRevision: 4,
        ),
      );
      await _waitFor(() => transport.requests.length == 2);
      final queuedAtClose = client.leaveConversation(
        const ChatLeaveConversationInput(
          conversationId: ConversationId('conversation-1'),
          expectedMemberListRevision: 5,
        ),
      );
      final dispose = client.dispose();
      expect((await queuedAtClose).category, ChatCommandResultCategory.closed);
      expect((await closing).category, ChatCommandResultCategory.closed);
      await dispose;
      expect(
        (await client.joinConversation(const ChatJoinConversationInput(
          conversationId: ConversationId('conversation-1'),
          expectedMemberListRevision: 4,
        )))
            .category,
        ChatCommandResultCategory.closed,
      );
      expect(store.state.memberListRevisions, isEmpty);
      await store.close();
    });
  });
}

HandrailChatClient _client(
  _RecordingTransport transport, {
  required NormalizedSnapshotStore store,
  Future<String> Function()? tokenProvider,
  String Function()? idempotencyKey,
  ChatCommandRetryOptions retryOptions =
      const ChatCommandRetryOptions(maxAttempts: 1),
  ChatRealtimeSessionTransport? realtimeSession,
}) =>
    HandrailChatClient(
      apiBaseUri: Uri.parse('https://chat.test/api'),
      tokenProvider: tokenProvider ?? () async => 'access-token',
      transport: transport,
      normalizedSnapshotStore: store,
      generateIdempotencyKey: idempotencyKey ?? () => 'membership-id',
      commandRetryOptions: retryOptions,
      realtimeSession: realtimeSession,
    );

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

Map<String, Object?> _body(HandrailChatHttpRequest request) =>
    Map<String, Object?>.from(
      jsonDecode(request.body!) as Map<Object?, Object?>,
    );

HandrailChatHttpResponse _response(Object? body, {int statusCode = 200}) =>
    HandrailChatHttpResponse(
      statusCode: statusCode,
      body: jsonEncode(body),
    );

ConversationDetailSnapshot _detail(String conversationId) =>
    ConversationDetailSnapshot.fromJson({
      'kind': 'conversation_detail',
      'conversation': {
        ..._summary(conversationId),
        'memberUserIds': [_currentUserId, 'user-other'],
        'currentPreference': {
          'conversationId': conversationId,
          'userId': _currentUserId,
          'notificationPreference': 'mentions',
          'isStarred': false,
          'mute': {'muted': false},
          'updatedAt': _timestamp,
        },
      },
      '_meta': _metadata(),
    });

Map<String, Object?> _summary(String conversationId) => {
      'id': conversationId,
      'tenantId': _tenantId,
      'type': 'channel',
      'name': 'Channel $conversationId',
      'visibility': 'public',
      'createdAt': _timestamp,
      'updatedAt': _timestamp,
      'latestSequence': 3,
      'activityAt': _timestamp,
      'unreadMentionCount': 0,
      'currentMember': {
        'tenantId': _tenantId,
        'conversationId': conversationId,
        'userId': _currentUserId,
        'role': 'member',
        'state': 'active',
        'joinedAt': _timestamp,
        'updatedAt': _timestamp,
      },
      'currentReadState': {
        'conversationId': conversationId,
        'userId': _currentUserId,
        'lastReadSequence': 2,
        'updatedAt': _timestamp,
      },
      'currentPreference': {
        'conversationId': conversationId,
        'userId': _currentUserId,
        'notificationPreference': 'mentions',
        'isStarred': false,
        'mute': {'muted': false},
        'updatedAt': _timestamp,
      },
      'activeMemberUserIds': [_currentUserId],
    };

NormalizedSnapshotStore _hydratedAccessStore() {
  final store = NormalizedSnapshotStore();
  store.hydrateConversationList(ConversationListSnapshot.fromJson({
    'kind': 'conversation_list',
    'scope': {'type': 'organization'},
    'items': [_summary('conversation-1'), _summary('conversation-2')],
    'page': <String, Object?>{},
    '_meta': _metadata(),
  }));
  store
    ..hydrateConversationDetail(_detail('conversation-1'))
    ..hydrateConversationDetail(_detail('conversation-2'))
    ..hydrateMessageTimeline(_timeline('conversation-1'))
    ..hydrateMessageTimeline(_timeline('conversation-2'));
  return store;
}

MessageTimelinePage _timeline(String conversationId) {
  final request = MessageTimelineRequest.fromJson({
    'conversationId': conversationId,
    'direction': 'backward',
    'limit': 20,
  });
  return MessageTimelinePage.fromJson(
    {
      'conversationId': conversationId,
      'messages': [
        {
          'id': 'message-$conversationId',
          'tenantId': _tenantId,
          'conversationId': conversationId,
          'author': {'type': 'user', 'userId': _currentUserId},
          'sequence': 1,
          'createdAt': _timestamp,
          'updatedAt': _timestamp,
          'revision': {'revision': 1},
          'content': {'format': 'markdown', 'text': 'message'},
          'isThreadRoot': false,
          'reactions': <Object?>[],
          'attachmentMetadata': <Object?>[],
        },
      ],
      'pagination': {
        'older': {'available': false},
        'newer': {'available': false},
      },
      'replay': {
        'resumeFrom': {'eventId': 'event-$conversationId'},
      },
    },
    request: request,
  );
}

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

ChatRealtimeSessionTransport _idleRealtimeSession() =>
    ChatRealtimeSessionTransport(
      endpoint: Uri.parse('https://chat.test/api'),
      clientPackageVersion: '0.1.3',
      protocolVersion: 4,
      tokenProvider: () => 'token',
      socketFactory: (_, __) => throw StateError('not started'),
    );

void _expectAccessCleared(
  NormalizedSnapshotStore store,
  String conversationId,
) {
  final id = ConversationId(conversationId);
  expect(store.state.currentUserReadStates, isNot(contains(id)));
  expect(store.state.currentUserPreferences, isNot(contains(id)));
  expect(store.state.conversationDetails, isNot(contains(id)));
  expect(store.state.timelines, isNot(contains(id)));
  expect(
    store.state.canonicalMessages.values,
    everyElement(predicate<Message>((message) => message.conversationId != id)),
  );
  expect(
    store
        .conversationList(const OrganizationConversationSnapshotScope())
        .conversationIds,
    isNot(contains(id)),
  );
  expect(store.state.membersByConversation, contains(id));
}

void _expectAccessPreserved(
  NormalizedSnapshotStore store,
  String conversationId,
) {
  final id = ConversationId(conversationId);
  expect(store.state.currentUserReadStates, contains(id));
  expect(store.state.currentUserPreferences, contains(id));
  expect(store.state.conversationDetails, contains(id));
  expect(store.state.timelines, contains(id));
  expect(
    store.state.canonicalMessages.values,
    contains(predicate<Message>((message) => message.conversationId == id)),
  );
  expect(
    store
        .conversationList(const OrganizationConversationSnapshotScope())
        .conversationIds,
    contains(id),
  );
}

Future<void> _waitFor(bool Function() condition) async {
  for (var attempt = 0; attempt < 100; attempt++) {
    if (condition()) return;
    await Future<void>.delayed(Duration.zero);
  }
  fail('Condition was not reached.');
}
