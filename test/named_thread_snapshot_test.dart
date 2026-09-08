import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:handrail_chat/core.dart';
import 'package:test/test.dart';

Map<String, dynamic> campaignDetail() => (jsonDecode(File(
      'docs/validation/flutter-named-threads/campaign/flutter-thread-retry.json',
    ).readAsStringSync())['recent'] as List)
        .last['body'] as Map<String, dynamic>;

Map<String, Object?> follow(String id, bool following) => {
      'target': {'type': 'thread', 'id': id},
      'isFollowing': following,
      'source': 'manual',
      'updatedAt': '2026-09-07T17:47:26.284Z',
    };

void main() {
  test('newly created thread accepts subsequent server detail enrichment', () {
    final wire = jsonDecode(File(
      'docs/validation/flutter-named-threads/created-detail-sequence.json',
    ).readAsStringSync());
    final store = NormalizedSnapshotStore();
    addTearDown(store.close);
    store.hydrateConversationDetail(
        ConversationDetailSnapshot.fromJson(wire['created']['conversation']));
    for (final event in wire['events'] as List) {
      expect(store.reduceDurableEvent(KnownDurableEvent.fromJson(event,
          trustedIdentity: const DurableEventTrustedIdentity(
              tenantId: TenantId('chat-lab'), userId: UserId('bob')))).status,
          DurableEventReductionStatus.applied);
    }
    store.hydrateConversationDetail(
        ConversationDetailSnapshot.fromJson(wire['detail']));
    final id = ConversationId(wire['detail']['conversation']['id']);
    expect(store.threadFollow(id).isFollowing, true);
    expect(store.conversationPreference(id).authoritativeRevision, 1);
    expect(store.conversationPreference(id).authoritativePreference!.preferenceRevision, 1);
    wire['detail']['conversation']['currentPreference']['isStarred'] = true;
    expect(() => store.hydrateConversationDetail(
        ConversationDetailSnapshot.fromJson(wire['detail'])),
        throwsA(isA<NormalizedSnapshotConflict>()));
  });
  test('server thread.created member enrichment stays outside canonical model',
      () {
    final wire = campaignDetail();
    final detail = ConversationDetailSnapshot.fromJson(wire);
    final store = NormalizedSnapshotStore();
    addTearDown(store.close);
    store.hydrateConversationDetail(detail);
    final conversation = detail.conversation.summary.conversation;
    final payload = {
      'conversation': {
        ...conversation.toJson(),
        'memberUserIds': ['bob']
      },
      'rootThreadSummary': {
        'threadId': conversation.id.value,
        'replyCount': 0,
        'participantIds': <String>[],
        'unreadCount': 0,
      },
    };
    KnownDurableEvent event() => KnownDurableEvent.fromJson({
          'eventId': 'server-thread-created',
          'protocolVersion': 4,
          'tenantId': conversation.tenantId.value,
          'streamId': conversation.id.value,
          'type': 'thread.created',
          'occurredAt': conversation.updatedAt.value,
          'payload': payload,
        },
            trustedIdentity: const DurableEventTrustedIdentity(
                tenantId: TenantId('chat-lab'), userId: UserId('bob')));
    final members = store.state.memberUserIdsByConversation;
    expect(store.reduceDurableEvent(event()).status,
        DurableEventReductionStatus.applied);
    expect(store.state.memberUserIdsByConversation, members);
    expect(store.state.conversations[conversation.id]!.toJson(),
        conversation.toJson());
    for (final invalid in [
      null,
      ['bob', 'bob'],
      [123]
    ]) {
      (payload['conversation'] as Map)['memberUserIds'] = invalid;
      final bad = event().toJson()..['eventId'] = 'invalid-$invalid';
      expect(
          () => store.reduceDurableEvent(KnownDurableEvent.fromJson(bad,
              trustedIdentity: const DurableEventTrustedIdentity(
                  tenantId: TenantId('chat-lab'), userId: UserId('bob')))),
          throwsA(isA<DurableEventReductionError>()));
    }
  });
  test('watchers registered by a commit observer receive the accepted snapshot',
      () async {
    final store = NormalizedSnapshotStore();
    final snapshot = ConversationDetailSnapshot.fromJson(campaignDetail());
    final id = snapshot.conversation.summary.conversation.id;
    final conversations = <NormalizedConversationSnapshot>[];
    final lists = <NormalizedConversationListSnapshot>[];
    final timelines = <NormalizedTimelineSnapshot>[];
    final subscriptions = <StreamSubscription<dynamic>>[];
    subscriptions.add(store.acceptedCommitChanges.listen((_) {
      subscriptions.addAll([
        store.watchConversation(id).listen(conversations.add),
        store
            .watchConversationList(
                const OrganizationConversationSnapshotScope())
            .listen(lists.add),
        store.watchTimeline(id).listen(timelines.add),
      ]);
    }));
    store.hydrateConversationDetail(snapshot);
    expect(conversations.single.conversation, isA<ThreadConversation>());
    expect(lists, hasLength(1));
    expect(timelines, hasLength(1));
    for (final subscription in subscriptions) {
      await subscription.cancel();
    }
    await store.close();
  });
  test('campaign HTTP 200 detail parses and hydrates for both actors',
      () async {
    for (final actor in ['alice', 'bob']) {
      final wire = campaignDetail();
      final conversation = wire['conversation'] as Map<String, dynamic>;
      for (final field in [
        'currentMember',
        'currentReadState',
        'currentPreference'
      ]) {
        (conversation[field] as Map)['userId'] = actor;
      }
      final client = HandrailChatClient(
        apiBaseUri: Uri.parse('https://chat.example.test/api/chat'),
        tokenProvider: () async => 'test-token',
        transport: _Http(wire),
      );
      final id = ConversationId(conversation['id'] as String);
      final result = await client
          .getConversation(ConversationDetailSnapshotInput(conversationId: id));
      expect(
          result, isA<ChatSnapshotQuerySuccess<ConversationDetailSnapshot>>());
      final snapshot =
          (result as ChatSnapshotQuerySuccess<ConversationDetailSnapshot>)
              .value;
      expect(snapshot.toJson(), wire);
      client.normalizedState.hydrateConversationDetail(snapshot);
      expect(client.normalizedState.state.conversations[id],
          isA<ThreadConversation>());
      expect(client.normalizedState.threadFollow(id).authoritativeRevision, 0);
      expect(
          client.normalizedState
              .canonicalPersistenceSnapshot()
              .threadFollowRevisions[id],
          isNull);
      expect(
          client.normalizedState.state.currentUserPreferences[id], isNotNull);
      await client.dispose();
    }
  });
  test('stored follow revision hydrates without replacing newer pending intent',
      () {
    final wire = campaignDetail();
    final conversation = wire['conversation'] as Map<String, dynamic>;
    final id = ConversationId(conversation['id'] as String);
    final store = NormalizedSnapshotStore();
    addTearDown(store.close);
    final recent = jsonDecode(File(
      'docs/validation/flutter-named-threads/campaign/flutter-thread-retry.json',
    ).readAsStringSync())['recent'] as List;
    final parent = recent.first['body'];
    store
        .hydrateConversationDetail(ConversationDetailSnapshot.fromJson(parent));
    final timeline = recent.firstWhere((entry) =>
        (entry['body'] as Map?)?.containsKey('messages') == true)['body'];
    store.hydrateMessageTimeline(MessageTimelinePage.fromJson(
      timeline,
      request: MessageTimelineRequest(
        conversationId: ConversationId(timeline['conversationId'] as String),
        direction: MessageTimelineDirection.backward,
        limit: 50,
      ),
    ));
    void hydrate(int revision, bool? following) {
      conversation['currentThreadFollow'] = {
        'followRevision': revision,
        'follow': following == null ? null : follow(id.value, following)
      };
      store
          .hydrateConversationDetail(ConversationDetailSnapshot.fromJson(wire));
    }

    hydrate(3, true);
    expect(store.threadFollow(id).authoritativeRevision, 3);
    store.beginOptimisticThreadFollow(
        SetThreadFollowInput.fromJson({
          'target': {'type': 'thread', 'id': id.value},
          'intent': 'unfollow',
          'operation': 'set_thread_follow',
          'expectedFollowRevision': 3,
          'idempotencyKey': 'pending-unfollow',
        }),
        const IsoTimestamp('2026-09-07T18:00:00.000Z'));
    hydrate(0, null);
    hydrate(2, true);
    expect(store.threadFollow(id).authoritativeRevision, 3);
    expect(store.threadFollow(id).isFollowing, false);
    expect(store.threadFollow(id).isPending, true);
    hydrate(4, false);
    expect(store.threadFollow(id).authoritativeRevision, 4);
    expect(store.threadFollow(id).authoritativeFollow!.isFollowing, false);
    expect(store.threadFollow(id).isPending, true);
    expect(() => hydrate(4, true), throwsA(isA<NormalizedSnapshotConflict>()));
    expect(store.threadFollow(id).authoritativeFollow!.isFollowing, false);
  });
  test('legacy omission works; malformed or misplaced authority is rejected',
      () {
    final wire = campaignDetail();
    final conversation = wire['conversation'] as Map<String, dynamic>;
    final id = conversation['id'] as String;
    conversation.remove('currentThreadFollow');
    expect(ConversationDetailSnapshot.fromJson(wire).toJson(), wire);
    for (final invalid in [
      null,
      {},
      {'followRevision': 0},
      {'followRevision': 1, 'follow': null},
      {'followRevision': -1, 'follow': null},
      {'followRevision': 0.5, 'follow': null},
      {'followRevision': 9007199254740992, 'follow': follow(id, true)},
      {'followRevision': 0, 'follow': follow(id, true)},
      {'followRevision': 1, 'follow': follow('other-thread', true)},
      {'followRevision': 0, 'follow': null, 'unexpected': true},
    ]) {
      conversation['currentThreadFollow'] = invalid;
      expect(() => ConversationDetailSnapshot.fromJson(wire),
          throwsFormatException);
    }
    conversation['currentThreadFollow'] = {'followRevision': 0, 'follow': null};
    conversation['type'] = 'channel';
    conversation.remove('parentConversationId');
    conversation.remove('rootMessageId');
    conversation.remove('threadLifecycle');
    expect(
        () => ConversationDetailSnapshot.fromJson(wire), throwsFormatException);
  });
}

class _Http implements HandrailChatHttpTransport {
  _Http(this.wire);
  final Object wire;
  @override
  Future<HandrailChatHttpResponse> send(
          HandrailChatHttpRequest request) async =>
      HandrailChatHttpResponse(statusCode: 200, body: jsonEncode(wire));
}
