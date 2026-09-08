import 'dart:async';
import 'dart:convert';

import 'package:handrail_chat/core.dart';
import 'package:test/test.dart';

const _tenantId = 'tenant-1';
const _userId = 'user-current';
const _now = '2026-08-26T15:00:00.000Z';
const _organizationScope = OrganizationConversationSnapshotScope();

void main() {
  group('NormalizedSnapshotStore conversation hydration', () {
    test('links overlapping pages in either arrival order and stays immutable',
        () {
      final cursor = _cursor('conversation-2');
      final initial = _listSnapshot(
        [
          _summary('conversation-1', isStarred: true),
          _summary('conversation-2'),
        ],
        nextCursor: cursor,
      );
      final continuation = _listSnapshot(
        [
          _summary('conversation-2'),
          _summary('conversation-3', isStarred: true),
        ],
      );

      final store = NormalizedSnapshotStore();
      store.hydrateConversationList(continuation, requestCursor: cursor);
      final disconnected = store.conversationList(_organizationScope);
      expect(disconnected.conversationIds, isEmpty);
      expect(disconnected.pages, hasLength(1));

      store.hydrateConversationList(initial);
      final linked = store.conversationList(_organizationScope);
      expect(
        linked.conversationIds,
        const [
          ConversationId('conversation-1'),
          ConversationId('conversation-2'),
          ConversationId('conversation-3'),
        ],
      );
      expect(linked.conversations, hasLength(3));
      expect(linked.pages, hasLength(2));
      expect(linked.nextCursor, isNull);
      expect(store.state.conversations, hasLength(3));
      expect(store.state.membersByConversation, hasLength(3));
      expect(store.state.currentUserReadStates, hasLength(3));
      expect(store.state.currentUserPreferences, hasLength(3));
      expect(
        store
            .state
            .currentUserPreferences[const ConversationId('conversation-1')]
            ?.isStarred,
        isTrue,
      );
      expect(
        store
            .state
            .currentUserPreferences[const ConversationId('conversation-2')]
            ?.isStarred,
        isFalse,
      );
      expect(
        () => linked.conversationIds.add(const ConversationId('other')),
        throwsUnsupportedError,
      );
      expect(
        () => linked.pages.clear(),
        throwsUnsupportedError,
      );

      final beforeEquivalentHydration = store.state;
      store.hydrateConversationList(initial);
      expect(identical(store.state, beforeEquivalentHydration), isTrue);

      final reverse = NormalizedSnapshotStore();
      reverse.hydrateConversationList(initial);
      final firstPageView = reverse.conversationList(_organizationScope);
      reverse.hydrateConversationList(continuation, requestCursor: cursor);
      expect(
        reverse
            .conversationList(_organizationScope)
            .conversationIds
            .map((id) => id.value),
        linked.conversationIds.map((id) => id.value),
      );
      expect(firstPageView.conversationIds, const [
        ConversationId('conversation-1'),
        ConversationId('conversation-2'),
      ]);
      expect(firstPageView.pages, hasLength(1));
    });

    test('detail hydration fills canonical membership and preference maps', () {
      final detail = _detailSnapshot('conversation-1');
      final store = NormalizedSnapshotStore();
      store.hydrateConversationDetail(detail);

      final selected =
          store.conversation(const ConversationId('conversation-1'));
      expect(selected.conversation?.id.value, 'conversation-1');
      expect(selected.members.keys, const [UserId(_userId)]);
      expect(selected.memberUserIds, const [
        UserId(_userId),
        UserId('user-other'),
      ]);
      expect(selected.currentReadState?.lastReadSequence.value, 2);
      expect(selected.currentPreference?.notificationPreference, 'mentions');
      expect(selected.currentPreference?.isStarred, isTrue);
      expect(store.state.currentUserPreferences, hasLength(1));
      expect(
        () => selected.memberUserIds.add(const UserId('user-third')),
        throwsUnsupportedError,
      );

      final stable = store.state;
      store.hydrateConversationDetail(_detailSnapshot('conversation-1'));
      expect(identical(store.state, stable), isTrue);
    });
  });

  group('NormalizedSnapshotStore timeline hydration', () {
    test(
        'deduplicates overlap, sorts ascending, and preserves outer boundaries',
        () {
      final newer = _timelinePage(
        [3, 4],
        older: 3,
        replayEventId: 'event-newest',
      );
      final older = _timelinePage(
        [1, 2],
        requestCursor: 3,
        direction: MessageTimelineDirection.backward,
        newer: 2,
        replayEventId: 'event-older',
      );
      final overlap = _timelinePage(
        [2, 3],
        older: 2,
        newer: 3,
        replayEventId: 'event-overlap',
      );

      final store = NormalizedSnapshotStore();
      store.hydrateMessageTimeline(newer);
      final prior = store.timeline(const ConversationId('conversation-1'));
      store.hydrateMessageTimeline(older);
      store.hydrateMessageTimeline(overlap);
      final timeline = store.timeline(const ConversationId('conversation-1'));

      expect(
        timeline.messages.map((message) => message.sequence.value),
        [1, 2, 3, 4],
      );
      expect(timeline.messageIds.toSet(), hasLength(4));
      expect(store.state.messages, hasLength(4));
      expect(timeline.pagination.older.available, isFalse);
      expect(timeline.pagination.newer.available, isFalse);
      expect(timeline.replayCursor?.eventId, 'event-newest');
      expect(store.state.latestReplayCursor?.eventId, 'event-newest');
      expect(prior.messages.map((message) => message.sequence.value), [3, 4]);
      expect(
        () => prior.messages.add(prior.messages.first),
        throwsUnsupportedError,
      );

      final stable = store.state;
      store.hydrateMessageTimeline(overlap);
      expect(identical(store.state, stable), isTrue);

      final reverse = NormalizedSnapshotStore();
      reverse.hydrateMessageTimeline(older);
      reverse.hydrateMessageTimeline(newer);
      reverse.hydrateMessageTimeline(overlap);
      final reverseTimeline =
          reverse.timeline(const ConversationId('conversation-1'));
      expect(
        reverseTimeline.messages.map((message) => message.sequence.value),
        [1, 2, 3, 4],
      );
      expect(reverseTimeline.pagination.older.available, isFalse);
      expect(reverseTimeline.pagination.newer.available, isFalse);
    });

    test('rejects conflicting identity and sequence data safely', () {
      final store = NormalizedSnapshotStore();
      store.hydrateMessageTimeline(_timelinePage([1]));
      final conflict = _timelinePage(
        [1],
        messageIdForSequence: (_) => 'different-message',
      );

      expect(
        () => store.hydrateMessageTimeline(conflict),
        throwsA(isA<NormalizedSnapshotConflict>()),
      );
      expect(
        store.timeline(const ConversationId('conversation-1')).messageIds,
        const [MessageId('message-1')],
      );
    });
  });

  test('broadcast selectors emit only for changed selections', () async {
    final store = NormalizedSnapshotStore();
    var conversationOneEvents = 0;
    var conversationTwoEvents = 0;
    var listEvents = 0;
    var timelineOneEvents = 0;
    var timelineTwoEvents = 0;
    final subscriptions = [
      store
          .watchConversation(const ConversationId('conversation-1'))
          .listen((_) => conversationOneEvents += 1),
      store
          .watchConversation(const ConversationId('conversation-2'))
          .listen((_) => conversationTwoEvents += 1),
      store
          .watchConversationList(_organizationScope)
          .listen((_) => listEvents += 1),
      store
          .watchTimeline(const ConversationId('conversation-1'))
          .listen((_) => timelineOneEvents += 1),
      store
          .watchTimeline(const ConversationId('conversation-2'))
          .listen((_) => timelineTwoEvents += 1),
    ];

    final list = _listSnapshot([_summary('conversation-1')]);
    store.hydrateConversationList(list);
    expect(conversationOneEvents, 1);
    expect(conversationTwoEvents, 0);
    expect(listEvents, 1);
    expect(timelineOneEvents, 0);
    expect(timelineTwoEvents, 0);

    store.hydrateConversationList(list);
    expect(conversationOneEvents, 1);
    expect(listEvents, 1);

    final page = _timelinePage([1]);
    store.hydrateMessageTimeline(page);
    expect(timelineOneEvents, 1);
    expect(timelineTwoEvents, 0);
    expect(conversationOneEvents, 1);
    expect(listEvents, 1);

    store.hydrateMessageTimeline(page);
    expect(timelineOneEvents, 1);

    for (final subscription in subscriptions) {
      await subscription.cancel();
    }
    await store.close();
  });

  group('NormalizedSnapshotStore persisted installation', () {
    test('replaces all rows and publishes one complete coherent state',
        () async {
      final source = NormalizedSnapshotStore();
      source.hydrateConversationList(
        _listSnapshot([_summary('conversation-1', isStarred: true)]),
      );
      source.hydrateMessageTimeline(_timelinePage([1]));
      final persisted = NormalizedSnapshotStateStorageCodec.decode(
        NormalizedSnapshotStateStorageCodec.encode(source.state),
      );

      final store = NormalizedSnapshotStore();
      store.hydrateConversationList(
        _listSnapshot([_summary('stale-conversation')]),
      );
      final events = <String, int>{};
      final initialPreference = Completer<void>();
      final installedPreference = Completer<void>();
      var installing = false;
      void observe(String surface) {
        events[surface] = (events[surface] ?? 0) + 1;
        expect(store.state.conversations.keys,
            const [ConversationId('conversation-1')]);
        expect(
          store.conversationList(_organizationScope).conversationIds,
          const [ConversationId('conversation-1')],
        );
        expect(
          store.timeline(const ConversationId('conversation-1')).messageIds,
          const [MessageId('message-1')],
        );
        expect(
          store
              .conversationPreference(const ConversationId('conversation-1'))
              .preference
              ?.isStarred,
          isTrue,
        );
      }

      final subscriptions = [
        store
            .watchConversation(const ConversationId('conversation-1'))
            .listen((_) => observe('conversation')),
        store
            .watchConversationList(_organizationScope)
            .listen((_) => observe('list')),
        store
            .watchTimeline(const ConversationId('conversation-1'))
            .listen((_) => observe('timeline')),
        store.currentUserReadStateChanges.listen((_) => observe('read')),
        store
            .conversationPreferenceStates(
          const ConversationId('conversation-1'),
        )
            .listen((_) {
          if (!installing) {
            if (!initialPreference.isCompleted) initialPreference.complete();
            return;
          }
          observe('preference');
          if (!installedPreference.isCompleted) installedPreference.complete();
        }),
      ];

      await initialPreference.future;
      installing = true;
      final installed = store.installPersistedSnapshot(persisted);
      await installedPreference.future;

      expect(store.state, same(installed));
      expect(store.state, isNot(same(persisted)));
      expect(store.state.conversations,
          isNot(contains(const ConversationId('stale-conversation'))));
      expect(events, {
        'conversation': 1,
        'list': 1,
        'timeline': 1,
        'read': 1,
        'preference': 1,
      });

      for (final subscription in subscriptions) {
        await subscription.cancel();
      }
      await source.close();
      await store.close();
    });

    test('clears embedded intents and every private optimistic lane', () async {
      final store = NormalizedSnapshotStore();
      store.hydrateConversationList(_listSnapshot([
        _summary('conversation-1'),
        _threadSummary('thread-1'),
      ]));
      store.hydrateMessageTimeline(_timelinePage([1, 2, 3]));
      final canonical = NormalizedSnapshotStateStorageCodec.decode(
        NormalizedSnapshotStateStorageCodec.encode(store.state),
      );

      store.beginOptimisticMessageEdit(EditMessageRequest.fromJson({
        'operation': 'edit',
        'messageId': 'message-1',
        'expectedRevision': 1,
        'content': {'format': 'markdown', 'text': 'Edited'},
        'idempotencyKey': 'edit-1',
      }));
      store.beginOptimisticMessageDelete(SoftDeleteMessageRequest.fromJson({
        'operation': 'soft_delete',
        'messageId': 'message-2',
        'expectedRevision': 1,
        'idempotencyKey': 'delete-2',
      }));
      store.beginOptimisticReaction(ReactionMutationInput.fromJson({
        'operation': 'add_reaction',
        'messageId': 'message-3',
        'reactionKey': 'thumbsup',
        'idempotencyKey': 'reaction-3',
      }));
      store.beginOptimisticMessageSend(
        clientMessageId: 'send-4',
        projection: MessageTimelineMessage.fromJson(
          _message(4, id: 'optimistic-message-4'),
        ),
      );
      store.beginOptimisticConversationArchive(
        ConversationArchiveInput.fromJson({
          'operation': 'set_conversation_archive',
          'intent': 'archive',
          'conversationId': 'conversation-1',
          'expectedLifecycleRevision': 1,
          'idempotencyKey': 'archive-1',
        }),
      );
      store.beginOptimisticConversationPreference(
        UpdateConversationPreferenceInput.fromJson({
          'operation': 'update_conversation_preference',
          'conversationId': 'conversation-1',
          'expectedPreferenceRevision': 0,
          'idempotencyKey': 'preference-1',
          'notificationPreference': 'mentions',
          'isStarred': true,
          'mute': {'muted': false},
        }),
        const IsoTimestamp(_now),
      );
      store.beginOptimisticThreadFollow(
        SetThreadFollowInput.fromJson({
          'operation': 'set_thread_follow',
          'intent': 'follow',
          'target': {'type': 'thread', 'id': 'thread-1'},
          'expectedFollowRevision': 0,
          'idempotencyKey': 'follow-1',
        }),
        const IsoTimestamp(_now),
      );
      store.beginOptimisticMessageReminder(
        MessageReminderRequest.fromJson({
          'operation': 'message_reminder.v1',
          'intent': 'set',
          'conversationId': 'conversation-1',
          'messageId': 'message-3',
          'expectedReminderRevision': 0,
          'idempotencyKey': 'reminder-3',
          'dueAt': '2099-08-26T15:00:00.000Z',
        }),
      );

      store.installPersistedSnapshot(canonical);
      final installed = store.state;

      expect(installed.pendingConversationArchiveInputs, isEmpty);
      expect(installed.pendingConversationPreferenceIntents, isEmpty);
      expect(installed.pendingThreadFollowIntents, isEmpty);
      expect(installed.pendingMessageReminderIntents, isEmpty);
      expect(store.pendingOptimisticSendClientMessageIds, isEmpty);
      expect(store.isCanonicalMessage(const MessageId('message-1')), isTrue);
      expect(
        store.rollbackOptimisticMessageEdit(
          const MessageId('message-1'),
          'edit-1',
        ),
        same(installed),
      );
      expect(
        store.rollbackOptimisticMessageDelete(
          const MessageId('message-2'),
          'delete-2',
        ),
        same(installed),
      );
      expect(
        store.rollbackOptimisticReaction(
          const MessageId('message-3'),
          'thumbsup',
          'reaction-3',
        ),
        same(installed),
      );
      expect(
          store.state.canonicalMessages,
          isNot(contains(
            const MessageId('optimistic-message-4'),
          )));

      await store.close();
    });

    test('invalid state leaves canonical and private state untouched',
        () async {
      final store = NormalizedSnapshotStore();
      store.hydrateConversationList(
        _listSnapshot([_summary('conversation-1')]),
      );
      store.beginOptimisticMessageSend(
        clientMessageId: 'pending-send',
        projection: MessageTimelineMessage.fromJson(
          _message(1, id: 'optimistic-message'),
        ),
      );
      final before = store.state;
      final invalidJson = NormalizedSnapshotStateStorageCodec.encode(
        NormalizedSnapshotState.empty(),
      )..['lifecycleRevisions'] = [
          {'conversationId': 'missing-conversation', 'revision': 1},
        ];
      final invalid = NormalizedSnapshotStateStorageCodec.decode(invalidJson);

      expect(
        () => store.installPersistedSnapshot(invalid),
        throwsA(
          isA<FormatException>().having(
            (error) => error.message,
            'message',
            'Persisted normalized state references an unknown conversation.',
          ),
        ),
      );
      expect(store.state, same(before));
      expect(store.pendingOptimisticSendClientMessageIds, {'pending-send'});

      await store.close();
    });

    test('rejects installation after close', () async {
      final store = NormalizedSnapshotStore();
      await store.close();

      expect(
        () => store.installPersistedSnapshot(NormalizedSnapshotState.empty()),
        throwsA(
          isA<StateError>().having(
            (error) => error.message,
            'message',
            'The normalized snapshot store is closed.',
          ),
        ),
      );
    });
  });

  group('NormalizedSnapshotStore canonical persistence export', () {
    test('detaches acknowledged baselines from every optimistic family',
        () async {
      const conversationId = ConversationId('conversation-1');
      const threadId = ConversationId('thread-1');
      const message1 = MessageId('message-1');
      const message2 = MessageId('message-2');
      const message3 = MessageId('message-3');
      const optimisticMessage = MessageId('optimistic-message-4');
      const attachmentId = AttachmentId('attachment-1');
      const acknowledgedAt = IsoTimestamp('2026-08-26T16:00:00.000Z');
      const pendingAt = IsoTimestamp('2026-08-26T17:00:00.000Z');
      final store = NormalizedSnapshotStore();
      store.hydrateConversationList(_listSnapshot([
        _summary(conversationId.value),
        _threadSummary(threadId.value),
      ]));
      store.hydrateMessageTimeline(_timelinePage(
        [1, 2, 3],
        messageForSequence: (sequence) {
          final message = _message(sequence);
          if (sequence == 1) {
            message['content'] = {
              'format': 'markdown',
              'text': 'Message 1',
              'attachments': [
                {'attachmentId': attachmentId.value},
              ],
            };
            message['attachmentMetadata'] = [
              {
                'attachmentId': attachmentId.value,
                'fileName': 'canonical.pdf',
                'contentType': 'application/pdf',
                'sizeBytes': 42,
                'downloadUrl': 'https://cdn.example.test/canonical.pdf',
              },
            ];
          }
          if (sequence == 3) {
            message['reactions'] = [
              {
                'reactionKey': 'thumbsup',
                'count': 2,
                'reactedByCurrentUser': false,
              },
            ];
          }
          return message;
        },
      ));
      store.reconcileThreadFollowCanonical(
        threadId,
        2,
        CanonicalThreadFollowState.fromJson({
          'target': {'type': 'thread', 'id': threadId.value},
          'isFollowing': true,
          'source': 'manual',
          'updatedAt': _now,
        }),
      );
      store.reconcileMessageReminderCanonical(
        conversationId: conversationId,
        messageId: message3,
        reminderRevision: 3,
        reminder: const CanonicalScheduledMessageReminder(
          IsoTimestamp('2099-08-26T15:00:00.000Z'),
        ),
      );

      final seeded = NormalizedSnapshotStateStorageCodec.encode(store.state)
        ..['preferenceRevisions'] = [
          {'conversationId': conversationId.value, 'revision': 2},
        ]
        ..['drafts'] = [
          {
            'conversationId': conversationId.value,
            'draftRevision': 4,
            'draft': {
              'kind': 'replaced',
              'content': {
                'format': 'markdown',
                'text': 'Acknowledged draft',
                'attachments': <Object?>[],
              },
            },
          },
        ]
        ..['durableStreams'] = [
          {
            'streamId': conversationId.value,
            'lastEventId': 'durable-event-9',
            'lastOccurredAt': _now,
            'recentEventIds': ['durable-event-8', 'durable-event-9'],
          },
        ];
      store.installPersistedSnapshot(
        NormalizedSnapshotStateStorageCodec.decode(seeded),
      );

      final acknowledgedRead = ConversationReadState(
        conversationId: conversationId,
        userId: const UserId(_userId),
        lastReadSequence: const MessageSequence(3),
        updatedAt: acknowledgedAt,
      );
      store.projectCurrentUserReadState(
        acknowledgedRead,
        authoritativeReadState: acknowledgedRead,
      );
      store.projectCurrentUserReadState(ConversationReadState(
        conversationId: conversationId,
        userId: const UserId(_userId),
        lastReadSequence: const MessageSequence(3),
        manualUnreadFromSequence: const MessageSequence(2),
        updatedAt: pendingAt,
      ));
      store.beginOptimisticMessageEdit(EditMessageRequest.fromJson({
        'operation': 'edit',
        'messageId': message1.value,
        'expectedRevision': 1,
        'content': {'format': 'markdown', 'text': 'Optimistic edit'},
        'idempotencyKey': 'edit-1',
      }));
      store.beginOptimisticMessageDelete(SoftDeleteMessageRequest.fromJson({
        'operation': 'soft_delete',
        'messageId': message2.value,
        'expectedRevision': 1,
        'idempotencyKey': 'delete-2',
      }));
      store.beginOptimisticReaction(ReactionMutationInput.fromJson({
        'operation': 'add_reaction',
        'messageId': message3.value,
        'reactionKey': 'thumbsup',
        'idempotencyKey': 'reaction-3',
      }));
      store.beginOptimisticMessageSend(
        clientMessageId: 'send-4',
        projection: MessageTimelineMessage.fromJson(
          _message(4, id: optimisticMessage.value),
        ),
      );
      store.beginOptimisticConversationArchive(
        ConversationArchiveInput.fromJson({
          'operation': 'set_conversation_archive',
          'intent': 'archive',
          'conversationId': conversationId.value,
          'expectedLifecycleRevision': 1,
          'idempotencyKey': 'archive-1',
        }),
      );
      store.beginOptimisticConversationPreference(
        UpdateConversationPreferenceInput.fromJson({
          'operation': 'update_conversation_preference',
          'conversationId': conversationId.value,
          'expectedPreferenceRevision': 2,
          'idempotencyKey': 'preference-1',
          'notificationPreference': 'all',
          'isStarred': true,
          'mute': {'muted': true},
        }),
        pendingAt,
      );
      store.beginOptimisticThreadFollow(
        SetThreadFollowInput.fromJson({
          'operation': 'set_thread_follow',
          'intent': 'unfollow',
          'target': {'type': 'thread', 'id': threadId.value},
          'expectedFollowRevision': 2,
          'idempotencyKey': 'follow-1',
        }),
        pendingAt,
      );
      store.beginOptimisticMessageReminder(
        MessageReminderRequest.fromJson({
          'operation': 'message_reminder.v1',
          'intent': 'cancel',
          'conversationId': conversationId.value,
          'messageId': message3.value,
          'expectedReminderRevision': 3,
          'idempotencyKey': 'reminder-3',
        }),
      );
      store.reconcileAttachmentUpload(ChatAttachmentUploadState(
        uploadId: 'provider-descriptor-secret-upload',
        conversationId: conversationId,
        metadata: AttachmentMetadata(
          fileName: 'local-media-secret.pdf',
          contentType: 'application/pdf',
          sizeBytes: 99,
        ),
        status: ChatAttachmentUploadStatus.preparing,
        uploadedBytes: 0,
      ));

      var selectorEvents = 0;
      final subscriptions = <StreamSubscription<Object?>>[
        store.watchConversation(conversationId).listen((_) {
          selectorEvents += 1;
        }),
        store.watchTimeline(conversationId).listen((_) {
          selectorEvents += 1;
        }),
        store.currentUserReadStateChanges.listen((_) {
          selectorEvents += 1;
        }),
      ];
      final live = store.state;
      final liveEdit = live.canonicalMessages[message1]!.toJson();
      final liveDelete = live.canonicalMessages[message2]!.toJson();
      final liveReaction = live.messages[message3]!.toJson();
      final liveRead = live.currentUserReadStates[conversationId]!.toJson();

      final exported = store.canonicalPersistenceSnapshot();
      final encoded = NormalizedSnapshotStateStorageCodec.encode(exported);
      final decoded = NormalizedSnapshotStateStorageCodec.decode(encoded);
      final repeated = store.canonicalPersistenceSnapshot();

      expect(store.state, same(live));
      expect(store.state.canonicalMessages[message1]!.toJson(), liveEdit);
      expect(store.state.canonicalMessages[message2]!.toJson(), liveDelete);
      expect(store.state.messages[message3]!.toJson(), liveReaction);
      expect(store.state.currentUserReadStates[conversationId]!.toJson(),
          liveRead);
      expect(selectorEvents, 0);
      expect(store.pendingOptimisticSendClientMessageIds, {'send-4'});
      expect(
        jsonEncode(encoded),
        jsonEncode(NormalizedSnapshotStateStorageCodec.encode(repeated)),
      );

      for (final canonical in [exported, decoded]) {
        expect(
          (canonical.canonicalMessages[message1] as ActiveMessage).content.text,
          'Message 1',
        );
        expect(canonical.canonicalMessages[message2], isA<ActiveMessage>());
        expect(canonical.canonicalMessages, isNot(contains(optimisticMessage)));
        expect(canonical.messages, isNot(contains(optimisticMessage)));
        expect(canonical.timelines[conversationId]!.messageIds,
            [message1, message2, message3]);
        final reaction = canonical.messages[message3]!.reactions.single;
        expect(reaction.count, 2);
        expect(reaction.reactedByCurrentUser, isFalse);
        expect(canonical.pendingConversationArchiveInputs, isEmpty);
        expect(canonical.pendingConversationPreferenceIntents, isEmpty);
        expect(canonical.pendingThreadFollowIntents, isEmpty);
        expect(canonical.pendingMessageReminderIntents, isEmpty);
        expect(canonical.currentUserPreferences[conversationId]!.isStarred,
            isFalse);
        expect(canonical.preferenceRevisions[conversationId], 2);
        expect(
            canonical.currentUserThreadFollows[threadId]!.isFollowing, isTrue);
        expect(canonical.threadFollowRevisions[threadId], 2);
        expect(
          canonical.currentUserMessageReminders[message3],
          isA<CanonicalScheduledMessageReminder>(),
        );
        expect(canonical.messageReminderRevisions[message3], 3);
        expect(
          canonical.currentUserReadStates[conversationId]!.lastReadSequence,
          const MessageSequence(3),
        );
        expect(
          canonical
              .currentUserReadStates[conversationId]!.manualUnreadFromSequence,
          isNull,
        );
        expect(
          (canonical.currentUserDrafts[conversationId]
                  as CanonicalReplacedDraft)
              .content
              .text,
          'Acknowledged draft',
        );
        expect(canonical.draftRevisions[conversationId], 4);
        expect(canonical.attachments[attachmentId]!.fileName, 'canonical.pdf');
        expect(canonical.attachmentUploads, isEmpty);
        expect(canonical.durableStreams[conversationId.value]!.lastEventId,
            'durable-event-9');
        expect(canonical.latestReplayCursor?.eventId, 'event-snapshot');
      }
      expect(jsonEncode(encoded), isNot(contains('local-media-secret')));
      expect(
          jsonEncode(encoded), isNot(contains('provider-descriptor-secret')));
      expect(exported.conversations, isNot(same(live.conversations)));
      expect(exported.conversations[conversationId],
          isNot(same(live.conversations[conversationId])));
      expect(decoded.conversations, isNot(same(exported.conversations)));
      expect(() => exported.timelines.clear(), throwsUnsupportedError);
      expect(() => decoded.attachments.clear(), throwsUnsupportedError);

      store.rollbackOptimisticMessageEdit(message1, 'edit-1');
      store.rollbackOptimisticMessageDelete(message2, 'delete-2');
      store.rollbackOptimisticReaction(message3, 'thumbsup', 'reaction-3');
      store.rollbackOptimisticConversationArchive(
        conversationId,
        'archive-1',
      );
      store.rollbackOptimisticConversationPreference(
        conversationId,
        'preference-1',
      );
      store.rollbackOptimisticThreadFollow(threadId, 'follow-1');
      store.rollbackOptimisticMessageReminder(message3, 'reminder-3');
      expect(
        (store.state.canonicalMessages[message1] as ActiveMessage).content.text,
        'Message 1',
      );
      expect(store.state.canonicalMessages[message2], isA<ActiveMessage>());
      expect(store.state.messages[message3]!.reactions.single.count, 2);
      expect(store.state.pendingConversationArchiveInputs, isEmpty);
      expect(store.state.pendingConversationPreferenceIntents, isEmpty);
      expect(store.state.pendingThreadFollowIntents, isEmpty);
      expect(store.state.pendingMessageReminderIntents, isEmpty);
      expect(store.pendingOptimisticSendClientMessageIds, {'send-4'});

      for (final subscription in subscriptions) {
        await subscription.cancel();
      }
      await store.close();
    });
  });
}

ConversationListSnapshot _listSnapshot(
  List<Map<String, Object?>> items, {
  ConversationSnapshotCursor? nextCursor,
}) =>
    ConversationListSnapshot.fromJson({
      'kind': 'conversation_list',
      'scope': {'type': 'organization'},
      'items': items,
      'page': {
        if (nextCursor != null) 'nextCursor': nextCursor.toJson(),
      },
      '_meta': _metadata(),
    });

ConversationDetailSnapshot _detailSnapshot(String conversationId) =>
    ConversationDetailSnapshot.fromJson({
      'kind': 'conversation_detail',
      'conversation': {
        ..._summary(conversationId),
        'memberUserIds': [_userId, 'user-other'],
        'currentPreference': {
          'conversationId': conversationId,
          'userId': _userId,
          'isStarred': true,
          'notificationPreference': 'mentions',
          'mute': {'muted': false},
          'updatedAt': _now,
        },
      },
      '_meta': _metadata(),
    });

Map<String, Object?> _summary(
  String conversationId, {
  bool isStarred = false,
}) =>
    {
      'id': conversationId,
      'tenantId': _tenantId,
      'type': 'channel',
      'name': 'Channel $conversationId',
      'visibility': 'public',
      'createdAt': _now,
      'updatedAt': _now,
      'latestSequence': 3,
      'activityAt': _now,
      'unreadMentionCount': 0,
      'currentMember': {
        'tenantId': _tenantId,
        'conversationId': conversationId,
        'userId': _userId,
        'role': 'member',
        'state': 'active',
        'joinedAt': _now,
        'updatedAt': _now,
      },
      'currentReadState': {
        'conversationId': conversationId,
        'userId': _userId,
        'lastReadSequence': 2,
        'updatedAt': _now,
      },
      'currentPreference': {
        'conversationId': conversationId,
        'userId': _userId,
        'isStarred': isStarred,
        'notificationPreference': 'mentions',
        'mute': {'muted': false},
        'updatedAt': _now,
      },
      'activeMemberUserIds': [_userId],
    };

Map<String, Object?> _threadSummary(String conversationId) {
  final summary = _summary(conversationId);
  summary
    ..['type'] = 'thread'
    ..remove('name')
    ..['parentConversationId'] = 'conversation-1'
    ..['rootMessageId'] = 'message-1';
  return summary;
}

MessageTimelinePage _timelinePage(
  List<int> sequences, {
  int? requestCursor,
  MessageTimelineDirection direction = MessageTimelineDirection.backward,
  int? older,
  int? newer,
  String replayEventId = 'event-snapshot',
  String Function(int sequence)? messageIdForSequence,
  Map<String, Object?> Function(int sequence)? messageForSequence,
}) {
  final request = MessageTimelineRequest.fromJson({
    'conversationId': 'conversation-1',
    'direction': direction.toJson(),
    if (requestCursor != null) 'cursor': requestCursor,
    'limit': 20,
  });
  return MessageTimelinePage.fromJson(
    {
      'conversationId': 'conversation-1',
      'messages': [
        for (final sequence in sequences)
          messageForSequence?.call(sequence) ??
              _message(
                sequence,
                id: messageIdForSequence?.call(sequence),
              ),
      ],
      'pagination': {
        'older': older == null
            ? {'available': false}
            : {'available': true, 'cursor': older},
        'newer': newer == null
            ? {'available': false}
            : {'available': true, 'cursor': newer},
      },
      'replay': {
        'resumeFrom': {'eventId': replayEventId},
      },
    },
    request: request,
  );
}

Map<String, Object?> _message(int sequence, {String? id}) => {
      'id': id ?? 'message-$sequence',
      'tenantId': _tenantId,
      'conversationId': 'conversation-1',
      'author': {'type': 'user', 'userId': _userId},
      'sequence': sequence,
      'createdAt': _now,
      'updatedAt': _now,
      'revision': {'revision': 1},
      'content': {'format': 'markdown', 'text': 'Message $sequence'},
      'isThreadRoot': false,
      'reactions': <Object?>[],
      'attachmentMetadata': <Object?>[],
    };

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

ConversationSnapshotCursor _cursor(String conversationId) =>
    ConversationSnapshotCursor.fromJson(
      'handrail-conversations.v1.${Uri.encodeComponent(jsonEncode([
            _now,
            conversationId
          ]))}',
    );
