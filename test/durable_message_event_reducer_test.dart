import 'package:handrail_chat/core.dart';
import 'package:test/test.dart';

const _tenantId = 'tenant-1';
const _userId = 'user-current';
const _baseTime = '2026-08-26T15:00:00.000Z';
const _parentId = 'conversation-1';
const _otherId = 'conversation-2';
const _threadId = 'thread-1';

final _trustedIdentity = DurableEventTrustedIdentity(
  tenantId: const TenantId(_tenantId),
  userId: const UserId(_userId),
);

void main() {
  group('message.created durable reduction', () {
    test('HTTP-first thread reply is visible and increments its root once', () {
      final store = _seedThreadStore();
      addTearDown(store.close);
      final message = _canonicalMessage(1, conversationId: _threadId);
      store.reconcileMessage(Message.fromJson(message));
      final event = _event(type: 'message.created', eventId: 'thread-http-first',
          streamId: _threadId, second: 2,
          payload: {'message': message, 'clientMessageId': 'thread-client-1'});
      store.reduceDurableEvent(event);
      expect(store.timeline(const ConversationId(_threadId)).messages.single.id,
          const MessageId('message-1'));
      expect(store.state.canonicalMessages[const MessageId('message-root')]!
          .threadSummary!.replyCount, 1);
      store.reduceDurableEvent(_event(type: event.type, eventId: 'redelivery',
          streamId: _threadId, second: 3, payload: event.payload.data));
      expect(store.state.canonicalMessages[const MessageId('message-root')]!
          .threadSummary!.replyCount, 1);
    });
    for (final latest in [0, 1]) {
      test(
          'HTTP-first send receives its projection with latest sequence $latest',
          () {
        final store = _seedStore(latestSequence: latest, messages: const []);
        addTearDown(store.close);
        final message = _canonicalMessage(1);
        store.reconcileMessage(Message.fromJson(message));
        expect(
            store.timeline(const ConversationId(_parentId)).messages, isEmpty);
        final event = _event(
            type: 'message.created',
            eventId: 'http-first',
            second: 2,
            payload: {'message': message, 'clientMessageId': 'client-1'});
        expect(store.reduceDurableEvent(event).status,
            DurableEventReductionStatus.applied);
        expect(
            store.timeline(const ConversationId(_parentId)).messages.single.id,
            const MessageId('message-1'));
        expect(
            store.state.conversationMetadata[const ConversationId(_parentId)]!.latestSequence.value,
            1);
        expect(store.reduceDurableEvent(event).status,
            DurableEventReductionStatus.duplicate);
        expect(store.timeline(const ConversationId(_parentId)).messages,
            hasLength(1));
      });
    }
    for (final clock in {
      'equal': _time(2),
      '1ms earlier': '2026-08-26T15:00:01.999Z',
    }.entries) {
      test('accepts next sequence and replays at ${clock.key} clocks', () {
        final store = _seedStore(latestSequence: 0, messages: const []);
        addTearDown(store.close);
        var emissions = 0;
        final subscription = store
            .watchTimeline(const ConversationId(_parentId))
            .listen((_) => emissions += 1);
        addTearDown(subscription.cancel);

        // Establish the stream clock through actual durable reduction.
        expect(
          store
              .reduceDurableEvent(_event(
                type: 'message.created',
                eventId: 'created-1',
                second: 2,
                payload: {
                  'message': _canonicalMessage(1),
                  'clientMessageId': 'client-1',
                },
              ))
              .status,
          DurableEventReductionStatus.applied,
        );
        expect(store.state.latestReplayCursor?.eventId, 'created-1');
        expect(store.state.durableStreams[_parentId]?.lastOccurredAt.value,
            _time(2));
        expect(emissions, 1);

        final event = _event(
          type: 'message.created',
          eventId: 'created-2',
          second: 2,
          occurredAt: clock.value,
          payload: {
            'message': _canonicalMessage(2),
            'clientMessageId': 'client-2',
          },
        );
        expect(store.reduceDurableEvent(event).status,
            DurableEventReductionStatus.applied);

        void expectCanonicalTimeline() {
          expect(
            store.state.canonicalMessages.map(
              (id, message) => MapEntry(id, message.toJson()),
            ),
            {
              const MessageId('message-1'): _canonicalMessage(1),
              const MessageId('message-2'): _canonicalMessage(2),
            },
          );
          expect(
              store.state.messages.keys,
              unorderedEquals(const [
                MessageId('message-1'),
                MessageId('message-2'),
              ]));
          expect(store.timeline(const ConversationId(_parentId)).messageIds,
              const [MessageId('message-1'), MessageId('message-2')]);
          expect(
            store.state.conversationMetadata[const ConversationId(_parentId)]
                ?.latestSequence.value,
            2,
          );
          expect(store.state.durableStreams[_parentId]?.lastOccurredAt.value,
              _time(2));
          expect(emissions, 2);
        }

        expectCanonicalTimeline();
        expect(store.state.latestReplayCursor?.eventId, 'created-2');
        expect(store.state.durableStreams[_parentId]?.lastEventId, 'created-2');
        expect(store.state.durableStreams[_parentId]?.recentEventIds,
            ['created-1', 'created-2']);
        expect(
            store.state.timelines[const ConversationId(_parentId)]?.replayCursor
                ?.eventId,
            'created-2');

        final accepted = store.state;
        expect(store.reduceDurableEvent(event).status,
            DurableEventReductionStatus.duplicate);
        expect(store.state, same(accepted));
        expectCanonicalTimeline();

        // A known row with a new event ID still advances replay bookkeeping.
        expect(
          store
              .reduceDurableEvent(_event(
                type: 'message.created',
                eventId: 'created-2-redelivered',
                second: 2,
                occurredAt: clock.value,
                payload: event.payload.data,
              ))
              .status,
          DurableEventReductionStatus.applied,
        );
        expectCanonicalTimeline();
        expect(
            store.state.latestReplayCursor?.eventId, 'created-2-redelivered');
        expect(store.state.durableStreams[_parentId]?.lastEventId,
            'created-2-redelivered');
        expect(store.state.durableStreams[_parentId]?.recentEventIds,
            ['created-1', 'created-2', 'created-2-redelivered']);
        expect(store.state.timelines, accepted.timelines);
      });

      for (final wrongStream in [false, true]) {
        test(
            'rejects ${wrongStream ? 'wrong stream identity' : 'sequence jump'} '
            'atomically at ${clock.key} clocks', () {
          final store = _seedStore(latestSequence: 0, messages: const []);
          addTearDown(store.close);
          var emissions = 0;
          final subscription = store
              .watchTimeline(const ConversationId(_parentId))
              .listen((_) => emissions += 1);
          addTearDown(subscription.cancel);
          expect(
            store
                .reduceDurableEvent(_event(
                  type: 'message.created',
                  eventId: 'created-1',
                  second: 2,
                  payload: {
                    'message': _canonicalMessage(1),
                    'clientMessageId': 'client-1',
                  },
                ))
                .status,
            DurableEventReductionStatus.applied,
          );
          final before = store.state;
          expect(before.latestReplayCursor?.eventId, 'created-1');
          expect(
              before.durableStreams[_parentId]?.lastOccurredAt.value, _time(2));
          expect(emissions, 1);

          expect(
            // Keep parsing inside the assertion: mismatched stream identity
            // must be rejected at the trusted parser/reducer boundary.
            () => store.reduceDurableEvent(_event(
              type: 'message.created',
              eventId: 'rejected',
              second: 2,
              occurredAt: clock.value,
              payload: {
                'message': _canonicalMessage(
                  wrongStream ? 2 : 3,
                  conversationId: wrongStream ? _otherId : _parentId,
                ),
                'clientMessageId': 'client-rejected',
              },
            )),
            throwsA(wrongStream
                ? isA<DurableEventFormatException>().having(
                    (error) => error.code,
                    'code',
                    DurableEventParseErrorCode.incoherentPayload,
                  )
                : _recovery(
                    DurableEventDiagnosticCode.orderingGap,
                    DurableEventRecoveryReason.eventGap,
                  )),
          );
          expect(store.state, same(before));
          expect(
              store.state.latestReplayCursor, same(before.latestReplayCursor));
          expect(store.state.durableStreams, same(before.durableStreams));
          expect(store.state.timelines, same(before.timelines));
          expect(emissions, 1);
        });
      }
    }

    test('settles optimistic send, orders once, and emits only its scopes',
        () async {
      final store = _seedStore(latestSequence: 1, messages: [_message(1)]);
      final optimistic = MessageTimelineMessage.fromJson(
        _message(2, id: 'optimistic-client-2', text: 'Sending'),
      );
      store.beginOptimisticMessageSend(
        clientMessageId: 'client-2',
        projection: optimistic,
      );
      final before = store.state;
      var parentTimelineEvents = 0;
      var otherTimelineEvents = 0;
      var parentConversationEvents = 0;
      final subscriptions = [
        store.watchTimeline(const ConversationId(_parentId)).listen(
              (_) => parentTimelineEvents += 1,
            ),
        store.watchTimeline(const ConversationId(_otherId)).listen(
              (_) => otherTimelineEvents += 1,
            ),
        store.watchConversation(const ConversationId(_parentId)).listen(
              (_) => parentConversationEvents += 1,
            ),
      ];

      final event = _event(
        type: 'message.created',
        eventId: 'created-2',
        second: 2,
        payload: {
          'message': _canonicalMessage(2, id: 'message-2', text: 'Sent'),
          'clientMessageId': 'client-2',
        },
      );
      final reduction = store.reduceDurableEvent(event);

      expect(reduction.status, DurableEventReductionStatus.applied);
      expect(store.pendingOptimisticSendClientMessageIds, isEmpty);
      expect(
        store.timeline(const ConversationId(_parentId)).messageIds,
        const [MessageId('message-1'), MessageId('message-2')],
      );
      expect(store.state.canonicalMessages, isNot(contains(optimistic.id)));
      expect(store.state.messages, isNot(contains(optimistic.id)));
      expect(before.canonicalMessages, contains(optimistic.id));
      expect(before.timelines[const ConversationId(_parentId)]!.messageIds,
          contains(optimistic.id));
      expect(store.state.latestReplayCursor?.eventId, 'created-2');
      expect(
        store.state.durableStreams[_parentId]?.recentEventIds,
        ['created-2'],
      );
      final restored = NormalizedSnapshotStateStorageCodec.decode(
        NormalizedSnapshotStateStorageCodec.encode(store.state),
      );
      expect(restored.latestReplayCursor?.eventId, 'created-2');
      expect(restored.durableStreams[_parentId]?.recentEventIds, ['created-2']);
      expect(parentTimelineEvents, 1);
      expect(otherTimelineEvents, 0);
      expect(parentConversationEvents, 1);

      final accepted = store.state;
      final duplicate = store.reduceDurableEvent(event);
      expect(duplicate.status, DurableEventReductionStatus.duplicate);
      expect(identical(store.state, accepted), isTrue);
      expect(parentTimelineEvents, 1);

      final duplicateRow = store.reduceDurableEvent(
        _event(
          type: 'message.created',
          eventId: 'created-2-replayed',
          second: 3,
          payload: {
            'message': _canonicalMessage(2, id: 'message-2', text: 'Sent'),
            'clientMessageId': 'client-2',
          },
        ),
      );
      expect(duplicateRow.status, DurableEventReductionStatus.applied);
      expect(
        store.timeline(const ConversationId(_parentId)).messageIds,
        const [MessageId('message-1'), MessageId('message-2')],
      );
      expect(parentTimelineEvents, 1);

      for (final subscription in subscriptions) {
        await subscription.cancel();
      }
      await store.close();
    });
  });

  group('scoped optimistic send reconciliation', () {
    test(
        'renders colliding sends and settles only the matching acknowledgement',
        () async {
      final store = _seedStore(latestSequence: 1, messages: [_message(1)]);
      addTearDown(store.close);
      store.hydrateMessageTimeline(_timelinePage(_otherId, []));
      // Leave room for canonical arrivals while the local send is pending.
      final optimistic = MessageTimelineMessage.fromJson(
        _message(4, id: 'optimistic-shared'),
      );
      store.beginOptimisticMessageSend(
        clientMessageId: 'shared-client',
        projection: optimistic,
      );
      var removals = 0;
      var hadOptimistic = true;
      final subscription =
          store.watchTimeline(const ConversationId(_parentId)).listen((_) {
        final hasOptimistic = store
            .timeline(const ConversationId(_parentId))
            .messageIds
            .contains(optimistic.id);
        if (hadOptimistic && !hasOptimistic) removals += 1;
        hadOptimistic = hasOptimistic;
      });
      addTearDown(subscription.cancel);

      final collisions = [
        _canonicalMessage(2, id: 'teammate-parent', authorId: 'teammate'),
        _canonicalMessage(1,
            id: 'teammate-other',
            authorId: 'teammate',
            conversationId: _otherId),
        _canonicalMessage(2, id: 'own-other', conversationId: _otherId),
      ];
      for (var index = 0; index < collisions.length; index += 1) {
        final message = collisions[index];
        final conversationId = message['conversationId']! as String;
        final result = store.reduceDurableEvent(_event(
          type: 'message.created',
          eventId: 'collision-$index',
          second: index + 2,
          streamId: conversationId,
          payload: {'message': message, 'clientMessageId': 'shared-client'},
        ));
        expect(result.status, DurableEventReductionStatus.applied);
        expect(store.timeline(ConversationId(conversationId)).messageIds,
            contains(MessageId(message['id']! as String)));
        expect(store.state.messages,
            contains(MessageId(message['id']! as String)));
        expect(store.pendingOptimisticSendClientMessageIds, {'shared-client'});
        expect(store.state.canonicalMessages[optimistic.id],
            same(optimistic.message));
        expect(store.state.messages[optimistic.id], same(optimistic));
        expect(store.timeline(const ConversationId(_parentId)).messageIds,
            contains(optimistic.id));
        expect(removals, 0);
      }

      final acknowledgement = _event(
        type: 'message.created',
        eventId: 'own-acknowledgement',
        second: 5,
        payload: {
          'message': _canonicalMessage(3, id: 'own-parent'),
          'clientMessageId': 'shared-client',
        },
      );
      expect(store.reduceDurableEvent(acknowledgement).status,
          DurableEventReductionStatus.applied);
      expect(store.pendingOptimisticSendClientMessageIds, isEmpty);
      expect(store.state.canonicalMessages, isNot(contains(optimistic.id)));
      expect(store.state.messages, isNot(contains(optimistic.id)));
      expect(store.timeline(const ConversationId(_parentId)).messageIds, const [
        MessageId('message-1'),
        MessageId('teammate-parent'),
        MessageId('own-parent'),
      ]);
      expect(store.timeline(const ConversationId(_otherId)).messageIds, const [
        MessageId('teammate-other'),
        MessageId('own-other'),
      ]);
      final accepted = store.state;
      expect(store.reduceDurableEvent(acknowledgement).status,
          DurableEventReductionStatus.duplicate);
      expect(store.state, same(accepted));
      expect(
          store
              .reduceDurableEvent(_event(
                type: 'message.created',
                eventId: 'own-acknowledgement-redelivered',
                second: 6,
                payload: acknowledgement.payload.data,
              ))
              .status,
          DurableEventReductionStatus.applied);
      expect(store.pendingOptimisticSendClientMessageIds, isEmpty);
      expect(store.timeline(const ConversationId(_parentId)).messageIds,
          accepted.timelines[const ConversationId(_parentId)]!.messageIds);
      expect(store.timeline(const ConversationId(_otherId)).messageIds,
          accepted.timelines[const ConversationId(_otherId)]!.messageIds);
      expect(removals, 1);
    });

    for (final existing in [true, false]) {
      for (final matchingAuthor in [true, false]) {
        test(
            '${existing ? 'existing row' : 'older sequence'} '
            '${matchingAuthor ? 'settles matching' : 'preserves nonmatching'} author',
            () async {
          final authorId = matchingAuthor ? _userId : 'teammate';
          final store = _seedStore(
            latestSequence: 2,
            messages: [_message(1, authorId: authorId)],
          );
          addTearDown(store.close);
          final optimistic = MessageTimelineMessage.fromJson(
            _message(4, id: 'optimistic-shared'),
          );
          store.beginOptimisticMessageSend(
            clientMessageId: 'shared-client',
            projection: optimistic,
          );
          final result = store.reduceDurableEvent(_event(
            type: 'message.created',
            eventId: 'early-return',
            second: 2,
            payload: {
              'message':
                  _canonicalMessage(existing ? 1 : 2, authorId: authorId),
              'clientMessageId': 'shared-client',
            },
          ));
          expect(result.status, DurableEventReductionStatus.applied);
          expect(store.pendingOptimisticSendClientMessageIds,
              matchingAuthor ? isEmpty : equals({'shared-client'}));
          expect(store.state.canonicalMessages.containsKey(optimistic.id),
              !matchingAuthor);
          expect(
              store.state.messages.containsKey(optimistic.id), !matchingAuthor);
          expect(
              store
                  .timeline(const ConversationId(_parentId))
                  .messageIds
                  .contains(optimistic.id),
              !matchingAuthor);
        });
      }
    }

    test('a different projection tenant cannot settle a pending send',
        () async {
      final store = _seedStore(latestSequence: 1, messages: [_message(1)]);
      addTearDown(store.close);
      // The public begin API accepts caller-created projections. Exercise its
      // tenant guard without relaxing trusted canonical event validation.
      final optimistic = MessageTimelineMessage.fromJson({
        ..._message(3, id: 'optimistic-other-tenant'),
        'tenantId': 'tenant-2',
      });
      store.beginOptimisticMessageSend(
        clientMessageId: 'shared-client',
        projection: optimistic,
      );
      expect(
          store
              .reduceDurableEvent(_event(
                type: 'message.created',
                eventId: 'same-author-other-tenant',
                second: 2,
                payload: {
                  'message': _canonicalMessage(2),
                  'clientMessageId': 'shared-client',
                },
              ))
              .status,
          DurableEventReductionStatus.applied);
      expect(store.pendingOptimisticSendClientMessageIds, {'shared-client'});
      expect(store.state.canonicalMessages[optimistic.id],
          same(optimistic.message));
      expect(store.state.messages[optimistic.id], same(optimistic));
      expect(store.timeline(const ConversationId(_parentId)).messageIds, const [
        MessageId('message-1'),
        MessageId('message-2'),
        MessageId('optimistic-other-tenant'),
      ]);
    });
  });

  group('stream ordering and atomic recovery', () {
    test('bounds IDs and distinguishes duplicate, stale, and ambiguous order',
        () async {
      final store = _seedStore(latestSequence: 1, messages: [_message(1)]);
      var emissions = 0;
      final subscription = store
          .watchTimeline(const ConversationId(_parentId))
          .listen((_) => emissions += 1);

      for (var index = 1; index <= 65; index += 1) {
        store.reduceDurableEvent(
          _reactionEvent(
            eventId: 'reaction-$index',
            second: index,
            count: 1,
          ),
        );
      }
      final stream = store.state.durableStreams[_parentId]!;
      expect(stream.recentEventIds, hasLength(durableEventRecentIdLimit));
      expect(stream.recentEventIds.first, 'reaction-2');
      expect(stream.recentEventIds.last, 'reaction-65');

      final accepted = store.state;
      final acceptedEmissions = emissions;
      final stale = store.reduceDurableEvent(
        _reactionEvent(eventId: 'pruned-old', second: 1, count: 99),
      );
      expect(stale.status, DurableEventReductionStatus.stale);
      expect(identical(store.state, accepted), isTrue);

      final ambiguous = _reactionEvent(
        eventId: 'ambiguous',
        second: 65,
        count: 2,
      );
      expect(
        () => store.reduceDurableEvent(ambiguous),
        throwsA(_recovery(
          DurableEventDiagnosticCode.orderingGap,
          DurableEventRecoveryReason.eventGap,
        )),
      );
      expect(identical(store.state, accepted), isTrue);
      expect(emissions, acceptedEmissions);

      await subscription.cancel();
      await store.close();
    });

    test('all recovery categories preserve cursor, state, lanes, and emissions',
        () async {
      final store = _seedStore(latestSequence: 1, messages: [_message(1)]);
      final edit = EditMessageRequest.fromJson({
        'operation': 'edit',
        'messageId': 'message-1',
        'expectedRevision': 1,
        'content': {'format': 'markdown', 'text': 'Optimistic'},
        'idempotencyKey': 'edit-gap',
      });
      store.beginOptimisticMessageEdit(edit);
      var emissions = 0;
      final subscription = store
          .watchTimeline(const ConversationId(_parentId))
          .listen((_) => emissions += 1);

      void expectAtomicFailure(
        KnownDurableEvent event,
        DurableEventDiagnosticCode code,
        DurableEventRecoveryReason reason,
      ) {
        final before = store.state;
        final cursor = before.latestReplayCursor?.eventId;
        final streams = before.durableStreams;
        final beforeEmissions = emissions;
        expect(
          () => store.reduceDurableEvent(event),
          throwsA(_recovery(code, reason)),
        );
        expect(identical(store.state, before), isTrue);
        expect(store.state.latestReplayCursor?.eventId, cursor);
        expect(identical(store.state.durableStreams, streams), isTrue);
        expect(emissions, beforeEmissions);
      }

      expectAtomicFailure(
        _event(
          type: 'message.created',
          eventId: 'sequence-gap',
          second: 10,
          payload: {
            'message': _canonicalMessage(3),
            'clientMessageId': 'client-gap',
          },
        ),
        DurableEventDiagnosticCode.orderingGap,
        DurableEventRecoveryReason.eventGap,
      );
      expectAtomicFailure(
        _event(
          type: 'message.updated',
          eventId: 'revision-gap',
          second: 11,
          payload: {
            'message': _canonicalMessage(
              1,
              revision: 3,
              text: 'Skipped revision',
            ),
          },
        ),
        DurableEventDiagnosticCode.orderingGap,
        DurableEventRecoveryReason.eventGap,
      );
      expectAtomicFailure(
        _event(
          type: 'message.updated',
          eventId: 'protocol-mismatch',
          second: 12,
          protocolVersion: 5,
          payload: {
            'message': _canonicalMessage(1, revision: 2, text: 'Edit'),
          },
        ),
        DurableEventDiagnosticCode.protocolMismatch,
        DurableEventRecoveryReason.eventIncompatible,
      );
      expectAtomicFailure(
        _event(
          type: 'attachment.updated',
          eventId: 'missing-attachment-reference',
          second: 13,
          payload: {
            'conversationId': _parentId,
            'messageId': 'message-1',
            'attachment': {
              'attachmentId': 'attachment-1',
              'fileName': 'invoice.pdf',
              'contentType': 'application/pdf',
              'sizeBytes': 42,
              'downloadUrl': 'https://chat.example/attachment-1',
            },
          },
        ),
        DurableEventDiagnosticCode.orderingGap,
        DurableEventRecoveryReason.eventGap,
      );

      final wrongThreadStore = _seedThreadStore();
      final wrongThreadBefore = wrongThreadStore.state;
      expect(
        () => wrongThreadStore.reduceDurableEvent(
          _threadSummaryEvent(threadId: 'conversation-2'),
        ),
        throwsA(_recovery(
          DurableEventDiagnosticCode.incoherentPayload,
          DurableEventRecoveryReason.eventInvalid,
        )),
      );
      expect(identical(wrongThreadStore.state, wrongThreadBefore), isTrue);

      store.rollbackOptimisticMessageEdit(
        const MessageId('message-1'),
        'edit-gap',
      );
      expect(
        (store.state.canonicalMessages[const MessageId('message-1')]!
                as ActiveMessage)
            .content
            .text,
        'Message 1',
      );

      await subscription.cancel();
      await store.close();
      await wrongThreadStore.close();
    });
  });

  group('message revisions', () {
    for (final clock in {
      'equal': _time(2),
      '1ms earlier': '2026-08-26T15:00:01.999Z',
    }.entries) {
      for (final optimistic in [false, true]) {
        test(
            'accepts revision-2 edit at ${clock.key} clocks '
            '(optimistic: $optimistic)', () {
          final store = _seedStore(latestSequence: 1, messages: [_message(1)]);
          addTearDown(store.close);
          // A different message establishes this conversation's stream clock.
          store.reduceDurableEvent(_event(
            type: 'message.created',
            eventId: 'clock-message-2',
            second: 2,
            payload: {
              'message': _canonicalMessage(2),
              'clientMessageId': 'client-2',
            },
          ));
          if (optimistic) {
            store.beginOptimisticMessageEdit(EditMessageRequest.fromJson({
              'operation': 'edit',
              'messageId': 'message-1',
              'expectedRevision': 1,
              'content': {'format': 'markdown', 'text': 'Optimistic edit'},
              'idempotencyKey': 'edit-1',
            }));
          }
          final before = store.state;
          var emissions = 0;
          final subscription = store
              .watchTimeline(const ConversationId(_parentId))
              .listen((_) => emissions += 1);
          addTearDown(subscription.cancel);
          final event = _event(
            type: 'message.updated',
            eventId: 'updated-2',
            second: 2,
            occurredAt: clock.value,
            payload: {
              'message':
                  _canonicalMessage(1, revision: 2, text: 'Canonical edit'),
            },
          );

          expect(store.reduceDurableEvent(event).status,
              DurableEventReductionStatus.applied);
          final accepted = store.state;
          expect(
              accepted.canonicalMessages[const MessageId('message-1')]!
                  .toJson(),
              _canonicalMessage(1, revision: 2, text: 'Canonical edit'));
          expect(
              accepted.messages[const MessageId('message-1')]!.message.toJson(),
              _canonicalMessage(1, revision: 2, text: 'Canonical edit'));
          expect(accepted.canonicalMessages[const MessageId('message-2')],
              same(before.canonicalMessages[const MessageId('message-2')]));
          expect(store.timeline(const ConversationId(_parentId)).messageIds,
              const [MessageId('message-1'), MessageId('message-2')]);
          expect(accepted.conversationMetadata, before.conversationMetadata);
          expect(accepted.latestReplayCursor?.eventId, 'updated-2');
          expect(accepted.durableStreams[_parentId]?.lastEventId, 'updated-2');
          expect(accepted.durableStreams[_parentId]?.lastOccurredAt.value,
              _time(2));
          expect(accepted.durableStreams[_parentId]?.recentEventIds,
              ['clock-message-2', 'updated-2']);
          expect(emissions, 1);

          expect(store.reduceDurableEvent(event).status,
              DurableEventReductionStatus.duplicate);
          expect(store.state, same(accepted));
          expect(emissions, 1);
          // A subsequent edit can start only if the previous lane was settled.
          store.beginOptimisticMessageEdit(EditMessageRequest.fromJson({
            'operation': 'edit',
            'messageId': 'message-1',
            'expectedRevision': 2,
            'content': {'format': 'markdown', 'text': 'Next edit'},
            'idempotencyKey': 'edit-2',
          }));
          final nextPending = store.state;
          store.rollbackOptimisticMessageEdit(
              const MessageId('message-1'), 'edit-1');
          expect(store.state, same(nextPending));
          store.rollbackOptimisticMessageEdit(
              const MessageId('message-1'), 'edit-2');
          expect(
              store.state.canonicalMessages[const MessageId('message-1')]!
                  .toJson(),
              _canonicalMessage(1, revision: 2, text: 'Canonical edit'));
        });
      }

      for (final stale in [false, true]) {
        test(
            '${stale ? 'preserves stale revision' : 'rejects true revision gap'} '
            'with pending edit at ${clock.key} clocks', () {
          final baselineRevision = stale ? 2 : 1;
          final store = _seedStore(
            latestSequence: 1,
            messages: [_message(1, revision: baselineRevision)],
          );
          addTearDown(store.close);
          store.reduceDurableEvent(_event(
            type: 'message.created',
            eventId: 'clock-message-2',
            second: 2,
            payload: {
              'message': _canonicalMessage(2),
              'clientMessageId': 'client-2',
            },
          ));
          final authoritative =
              store.state.canonicalMessages[const MessageId('message-1')];
          final edit = EditMessageRequest.fromJson({
            'operation': 'edit',
            'messageId': 'message-1',
            'expectedRevision': baselineRevision,
            'content': {'format': 'markdown', 'text': 'Pending edit'},
            'idempotencyKey': 'pending-edit',
          });
          store.beginOptimisticMessageEdit(edit);
          final before = store.state;
          var emissions = 0;
          final subscription = store
              .watchTimeline(const ConversationId(_parentId))
              .listen((_) => emissions += 1);
          addTearDown(subscription.cancel);
          final event = _event(
            type: 'message.updated',
            eventId: 'colliding-revision',
            second: 2,
            occurredAt: clock.value,
            payload: {
              'message': _canonicalMessage(1,
                  revision: stale ? 1 : 3,
                  text: 'Must not replace pending edit'),
            },
          );

          if (stale) {
            // Stale content is ignored, but valid delivery advances replay.
            expect(store.reduceDurableEvent(event).status,
                DurableEventReductionStatus.applied);
            expect(
                store.state.latestReplayCursor?.eventId, 'colliding-revision');
            expect(store.state.durableStreams[_parentId]?.lastEventId,
                'colliding-revision');
            expect(store.state.durableStreams[_parentId]?.recentEventIds,
                ['clock-message-2', 'colliding-revision']);
          } else {
            expect(
                () => store.reduceDurableEvent(event),
                throwsA(_recovery(DurableEventDiagnosticCode.orderingGap,
                    DurableEventRecoveryReason.eventGap)));
            expect(store.state, same(before));
            expect(store.state.latestReplayCursor,
                same(before.latestReplayCursor));
            expect(store.state.durableStreams, same(before.durableStreams));
          }
          expect(store.state.durableStreams[_parentId]?.lastOccurredAt.value,
              _time(2));
          expect(store.state.canonicalMessages, before.canonicalMessages);
          expect(store.state.messages, before.messages);
          expect(store.state.timelines, before.timelines);
          expect(emissions, 0);
          expect(() => store.beginOptimisticMessageEdit(edit),
              throwsA(isA<NormalizedSnapshotConflict>()));
          store.rollbackOptimisticMessageEdit(
              const MessageId('message-1'), 'pending-edit');
          expect(store.state.canonicalMessages[const MessageId('message-1')],
              same(authoritative));
        });
      }
    }

    test('applies update/delete, settles lanes, and preserves newer revisions',
        () async {
      final store = _seedStore(latestSequence: 1, messages: [_message(1)]);
      store.beginOptimisticMessageEdit(EditMessageRequest.fromJson({
        'operation': 'edit',
        'messageId': 'message-1',
        'expectedRevision': 1,
        'content': {'format': 'markdown', 'text': 'Optimistic edit'},
        'idempotencyKey': 'edit-1',
      }));

      store.reduceDurableEvent(_event(
        type: 'message.updated',
        eventId: 'updated-2',
        second: 2,
        payload: {
          'message': _canonicalMessage(1, revision: 2, text: 'Canonical edit'),
        },
      ));
      final revisionTwo = store.state;
      expect(
        (revisionTwo.canonicalMessages[const MessageId('message-1')]!
                as ActiveMessage)
            .content
            .text,
        'Canonical edit',
      );
      expect(
        revisionTwo
            .messages[const MessageId('message-1')]!.message.revision.revision,
        2,
      );

      final secondEdit = EditMessageRequest.fromJson({
        'operation': 'edit',
        'messageId': 'message-1',
        'expectedRevision': 2,
        'content': {'format': 'markdown', 'text': 'Second optimistic'},
        'idempotencyKey': 'edit-2',
      });
      store.beginOptimisticMessageEdit(secondEdit);
      store.rollbackOptimisticMessageEdit(
        const MessageId('message-1'),
        'edit-2',
      );

      store.reduceDurableEvent(_event(
        type: 'message.updated',
        eventId: 'stale-revision-1',
        second: 3,
        payload: {'message': _canonicalMessage(1, text: 'Old')},
      ));
      expect(
        store.state.canonicalMessages[const MessageId('message-1')]!.revision
            .revision,
        2,
      );

      store.beginOptimisticMessageDelete(SoftDeleteMessageRequest.fromJson({
        'operation': 'soft_delete',
        'messageId': 'message-1',
        'expectedRevision': 2,
        'idempotencyKey': 'delete-2',
      }));
      store.reduceDurableEvent(_event(
        type: 'message.deleted',
        eventId: 'deleted-3',
        second: 4,
        payload: {'message': _deletedMessage(1, revision: 3)},
      ));
      expect(
        store.state.canonicalMessages[const MessageId('message-1')],
        isA<DeletedMessage>(),
      );
      expect(
        () => store.beginOptimisticMessageDelete(
          SoftDeleteMessageRequest.fromJson({
            'operation': 'soft_delete',
            'messageId': 'message-1',
            'expectedRevision': 3,
            'idempotencyKey': 'impossible-deleted-row',
          }),
        ),
        throwsA(isA<NormalizedSnapshotConflict>()),
      );
      expect(revisionTwo.canonicalMessages[const MessageId('message-1')],
          isA<ActiveMessage>());

      await store.close();
    });
  });

  group('message.deleted clock collisions', () {
    for (final clock in {
      'equal': _time(2),
      '1ms earlier': '2026-08-26T15:00:01.999Z',
    }.entries) {
      for (final optimistic in [false, true]) {
        test(
            'accepts revision-2 deletion at ${clock.key} clocks '
            '(optimistic: $optimistic)', () {
          final store = _seedStore(latestSequence: 1, messages: [_message(1)]);
          addTearDown(store.close);
          // A different message establishes this conversation's stream clock.
          expect(
            store
                .reduceDurableEvent(_event(
                  type: 'message.created',
                  eventId: 'clock-message-2',
                  second: 2,
                  payload: {
                    'message': _canonicalMessage(2),
                    'clientMessageId': 'client-2',
                  },
                ))
                .status,
            DurableEventReductionStatus.applied,
          );
          if (optimistic) {
            store.beginOptimisticMessageDelete(
                SoftDeleteMessageRequest.fromJson({
              'operation': 'soft_delete',
              'messageId': 'message-1',
              'expectedRevision': 1,
              'idempotencyKey': 'delete-1',
            }));
          }
          final before = store.state;
          var emissions = 0;
          final subscription = store
              .watchTimeline(const ConversationId(_parentId))
              .listen((_) => emissions += 1);
          addTearDown(subscription.cancel);
          final tombstone = _deletedMessage(1, revision: 2);
          final event = _event(
            type: 'message.deleted',
            eventId: 'deleted-2',
            second: 2,
            occurredAt: clock.value,
            payload: {'message': tombstone},
          );

          expect(store.reduceDurableEvent(event).status,
              DurableEventReductionStatus.applied);
          final accepted = store.state;
          expect(accepted.canonicalMessages[const MessageId('message-1')],
              isA<DeletedMessage>());
          expect(
              accepted.canonicalMessages[const MessageId('message-1')]!
                  .toJson(),
              tombstone);
          expect(
              accepted.messages[const MessageId('message-1')]!.message.toJson(),
              tombstone);
          expect(accepted.canonicalMessages[const MessageId('message-2')],
              same(before.canonicalMessages[const MessageId('message-2')]));
          expect(accepted.messages[const MessageId('message-2')],
              same(before.messages[const MessageId('message-2')]));
          expect(store.timeline(const ConversationId(_parentId)).messageIds,
              const [MessageId('message-1'), MessageId('message-2')]);
          expect(accepted.timelines, before.timelines);
          expect(accepted.conversationMetadata, before.conversationMetadata);
          expect(accepted.latestReplayCursor?.eventId, 'deleted-2');
          expect(accepted.durableStreams[_parentId]?.lastEventId, 'deleted-2');
          expect(accepted.durableStreams[_parentId]?.lastOccurredAt.value,
              _time(2));
          expect(accepted.durableStreams[_parentId]?.recentEventIds,
              ['clock-message-2', 'deleted-2']);
          expect(emissions, 1);

          // An unsettled delete lane would export its old active baseline.
          expect(
              store
                  .canonicalPersistenceSnapshot()
                  .canonicalMessages[const MessageId('message-1')]!
                  .toJson(),
              tombstone);
          expect(store.reduceDurableEvent(event).status,
              DurableEventReductionStatus.duplicate);
          expect(store.state, same(accepted));
          expect(emissions, 1);
          store.rollbackOptimisticMessageDelete(
              const MessageId('message-1'), 'delete-1');
          expect(store.state, same(accepted));
          expect(emissions, 1);
        });
      }

      for (final wrongStream in [false, true]) {
        test(
            'rejects ${wrongStream ? 'wrong stream' : 'true revision gap'} '
            'with pending deletion at ${clock.key} clocks', () {
          final store = _seedStore(latestSequence: 1, messages: [_message(1)]);
          addTearDown(store.close);
          expect(
            store
                .reduceDurableEvent(_event(
                  type: 'message.created',
                  eventId: 'clock-message-2',
                  second: 2,
                  payload: {
                    'message': _canonicalMessage(2),
                    'clientMessageId': 'client-2',
                  },
                ))
                .status,
            DurableEventReductionStatus.applied,
          );
          final authoritative =
              store.state.canonicalMessages[const MessageId('message-1')];
          store.beginOptimisticMessageDelete(SoftDeleteMessageRequest.fromJson({
            'operation': 'soft_delete',
            'messageId': 'message-1',
            'expectedRevision': 1,
            'idempotencyKey': 'pending-delete',
          }));
          final before = store.state;
          var emissions = 0;
          final subscription = store
              .watchTimeline(const ConversationId(_parentId))
              .listen((_) => emissions += 1);
          addTearDown(subscription.cancel);

          expect(
            // Wrong-stream identity is rejected by the trusted parser.
            () => store.reduceDurableEvent(_event(
              type: 'message.deleted',
              eventId: 'rejected-deletion',
              second: 2,
              occurredAt: clock.value,
              payload: {
                'message': {
                  ..._deletedMessage(1, revision: wrongStream ? 2 : 3),
                  if (wrongStream) 'conversationId': _otherId,
                },
              },
            )),
            throwsA(wrongStream
                ? isA<DurableEventFormatException>().having(
                    (error) => error.code,
                    'code',
                    DurableEventParseErrorCode.incoherentPayload,
                  )
                : _recovery(DurableEventDiagnosticCode.orderingGap,
                    DurableEventRecoveryReason.eventGap)),
          );
          expect(store.state, same(before));
          expect(
              store.state.latestReplayCursor, same(before.latestReplayCursor));
          expect(store.state.latestReplayCursor?.eventId, 'clock-message-2');
          expect(store.state.durableStreams, same(before.durableStreams));
          expect(store.state.durableStreams[_parentId]?.lastEventId,
              'clock-message-2');
          expect(store.state.durableStreams[_parentId]?.recentEventIds,
              ['clock-message-2']);
          expect(store.state.durableStreams[_parentId]?.lastOccurredAt.value,
              _time(2));
          expect(store.state.canonicalMessages, same(before.canonicalMessages));
          expect(store.state.messages, same(before.messages));
          expect(store.state.timelines, same(before.timelines));
          expect(emissions, 0);
          // Rollback must still own the pending shell after atomic rejection.
          store.rollbackOptimisticMessageDelete(
              const MessageId('message-1'), 'pending-delete');
          expect(store.state.canonicalMessages[const MessageId('message-1')],
              same(authoritative));
          expect(store.state.messages[const MessageId('message-1')]!.message,
              isA<ActiveMessage>());
          expect(emissions, 1);
        });
      }
    }
  });

  group('thread and reaction durable reduction', () {
    for (final clock in {
      'equal': _time(2),
      '1ms earlier': '2026-08-26T15:00:01.999Z',
    }.entries) {
      for (final independentRoot in [false, true]) {
        test(
            'thread summary progress and replay for '
            '${independentRoot ? 'independent roots' : 'one root'} '
            'at ${clock.key} clocks', () {
          final firstSummary = {
            'threadId': _threadId,
            'replyCount': 5,
            'participantIds': [_userId, 'user-other'],
            'unreadCount': 4,
            'lastReplyAt': _time(2),
          };
          final store = _seedStore(
            latestSequence: 2,
            messages: [
              _message(1, id: 'message-root'),
              _message(2, id: 'another-root'),
            ],
            // A real summary delivery establishes the shared stream clock.
            durableEvents: [
              _event(
                type: 'message.thread_summary.updated',
                eventId: 'first-summary',
                second: 2,
                payload: {
                  'parentConversationId': _parentId,
                  'rootMessageId': 'message-root',
                  'rootThreadSummary': firstSummary,
                },
              ),
            ],
          );
          addTearDown(store.close);
          final before = store.state;
          expect(before.latestReplayCursor?.eventId, 'first-summary');
          expect(
              before.durableStreams[_parentId]?.lastOccurredAt.value, _time(2));
          var parentEvents = 0;
          final subscription = store
              .watchTimeline(const ConversationId(_parentId))
              .listen((_) => parentEvents += 1);
          addTearDown(subscription.cancel);

          final rootId = independentRoot ? 'another-root' : 'message-root';
          final replyCount = independentRoot ? 2 : 6;
          final nextSummary = {
            'threadId': independentRoot ? 'another-thread' : _threadId,
            'replyCount': replyCount,
            'participantIds': ['user-other', 'user-third'],
            // More replies can arrive with fewer unread replies.
            'unreadCount': 0,
            'lastReplyAt': _time(3),
          };
          final expectedSummaries = <String, Map<String, Object?>?>{
            'message-root': firstSummary,
            'another-root': null,
          };
          void expectSummaries() {
            for (final entry in expectedSummaries.entries) {
              final id = MessageId(entry.key);
              expect(store.state.canonicalMessages[id]!.threadSummary?.toJson(),
                  entry.value);
              expect(store.state.messages[id]!.message.threadSummary?.toJson(),
                  entry.value);
            }
            expect(store.state.conversations, before.conversations);
            expect(store.state.conversations[const ConversationId(_threadId)],
                isNull);
            expect(
                store.state
                    .conversations[const ConversationId('another-thread')],
                isNull);
            expect(store.state.timelines, before.timelines);
            expect(store.state.durableStreams[_parentId]?.lastOccurredAt.value,
                _time(2));
          }

          expectSummaries();
          final eventIds = ['first-summary'];
          for (final delivery in [
            (id: 'progress', count: replyCount, unread: 0, lastReply: 3),
            (
              id: 'lower-replay',
              count: replyCount - 1,
              unread: 1,
              lastReply: 8
            ),
            (id: 'equal-replay', count: replyCount, unread: 2, lastReply: 9),
          ]) {
            final previous = store.state;
            final event = _event(
              type: 'message.thread_summary.updated',
              eventId: delivery.id,
              second: 2,
              occurredAt: clock.value,
              payload: {
                'parentConversationId': _parentId,
                'rootMessageId': rootId,
                'rootThreadSummary': {
                  ...nextSummary,
                  'replyCount': delivery.count,
                  'unreadCount': delivery.unread,
                  'lastReplyAt': _time(delivery.lastReply),
                  if (delivery.id != 'progress') 'participantIds': [_userId],
                },
              },
            );
            expect(store.reduceDurableEvent(event).status,
                DurableEventReductionStatus.applied);
            expectedSummaries[rootId] = nextSummary;
            eventIds.add(event.eventId);
            expectSummaries();
            expect(store.state.latestReplayCursor?.eventId, event.eventId);
            expect(store.state.durableStreams[_parentId]?.lastEventId,
                event.eventId);
            expect(store.state.durableStreams[_parentId]?.recentEventIds,
                eventIds);
            expect(parentEvents, 1);
            if (delivery.id != 'progress') {
              // New event IDs advance replay bookkeeping, preserving all facts
              // even with larger unreadCount and later lastReplyAt values.
              expect(store.state.canonicalMessages, previous.canonicalMessages);
              expect(store.state.messages, previous.messages);
            }
            final accepted = store.state;
            expect(store.reduceDurableEvent(event).status,
                DurableEventReductionStatus.duplicate);
            expect(store.state, same(accepted));
            expect(store.state.latestReplayCursor,
                same(accepted.latestReplayCursor));
            expect(store.state.durableStreams, same(accepted.durableStreams));
            expectSummaries();
            expect(parentEvents, 1);
          }
        });
      }

      test('initial zero-reply thread summary applies at ${clock.key} clocks',
          () {
        final store = _seedStore(
          latestSequence: 1,
          messages: [_message(1, id: 'message-root')],
          durableEvents: [
            _event(
              type: 'message.created',
              eventId: 'clock-message-2',
              second: 2,
              payload: {
                'message': _canonicalMessage(2),
                'clientMessageId': 'client-2',
              },
            ),
          ],
        );
        addTearDown(store.close);
        final before = store.state;
        expect(
            before.canonicalMessages[const MessageId('message-root')]!
                .threadSummary,
            isNull);
        expect(
            before.messages[const MessageId('message-root')]!.message
                .threadSummary,
            isNull);
        expect(before.latestReplayCursor?.eventId, 'clock-message-2');
        expect(
            before.durableStreams[_parentId]?.lastOccurredAt.value, _time(2));
        var parentEvents = 0;
        final subscription = store
            .watchTimeline(const ConversationId(_parentId))
            .listen((_) => parentEvents += 1);
        addTearDown(subscription.cancel);
        final summary = {
          'threadId': _threadId,
          'replyCount': 0,
          'participantIds': <String>[],
          'unreadCount': 0,
        };
        final event = _event(
          type: 'message.thread_summary.updated',
          eventId: 'zero-summary',
          second: 2,
          occurredAt: clock.value,
          payload: {
            'parentConversationId': _parentId,
            'rootMessageId': 'message-root',
            'rootThreadSummary': summary,
          },
        );
        expect(store.reduceDurableEvent(event).status,
            DurableEventReductionStatus.applied);
        expect(
            store.state.canonicalMessages[const MessageId('message-root')]!
                .threadSummary
                ?.toJson(),
            summary);
        expect(
            store.state.messages[const MessageId('message-root')]!.message
                .threadSummary
                ?.toJson(),
            summary);
        expect(store.state.conversations, before.conversations);
        expect(store.state.timelines, before.timelines);
        expect(store.state.latestReplayCursor?.eventId, event.eventId);
        expect(
            store.state.durableStreams[_parentId]?.lastEventId, event.eventId);
        expect(store.state.durableStreams[_parentId]?.recentEventIds,
            ['clock-message-2', event.eventId]);
        expect(store.state.durableStreams[_parentId]?.lastOccurredAt.value,
            _time(2));
        expect(parentEvents, 1);
        final accepted = store.state;
        expect(store.reduceDurableEvent(event).status,
            DurableEventReductionStatus.duplicate);
        expect(store.state, same(accepted));
        expect(
            store.state.latestReplayCursor, same(accepted.latestReplayCursor));
        expect(store.state.durableStreams, same(accepted.durableStreams));
        expect(parentEvents, 1);
      });
    }

    test('unopened thread summary updates the root and replays idempotently',
        () {
      final store = _seedStore(
        latestSequence: 1,
        messages: [
          _message(1, id: 'message-root', threadSummary: {
            'threadId': _threadId,
            'replyCount': 1,
            'participantIds': [_userId],
            'unreadCount': 1,
            'lastReplyAt': _time(1),
          }),
        ],
        durableEvents: [
          _event(
            type: 'message.created',
            eventId: 'clock-message-2',
            second: 2,
            payload: {
              'message': _canonicalMessage(2),
              'clientMessageId': 'client-2',
            },
          ),
        ],
      );
      addTearDown(store.close);
      final before = store.state;
      expect(before.conversations[const ConversationId(_threadId)], isNull);
      expect(before.latestReplayCursor?.eventId, 'clock-message-2');
      expect(before.durableStreams[_parentId]?.lastOccurredAt.value, _time(2));
      var parentEvents = 0;
      final subscription = store
          .watchTimeline(const ConversationId(_parentId))
          .listen((_) => parentEvents += 1);
      addTearDown(subscription.cancel);
      final event = _threadSummaryEvent();

      expect(store.reduceDurableEvent(event).status,
          DurableEventReductionStatus.applied);
      final accepted = store.state;
      final expectedSummary = {
        'threadId': _threadId,
        'replyCount': 5,
        'participantIds': ['user-other', 'user-third'],
        'unreadCount': 2,
        'lastReplyAt': _time(3),
      };
      expect(
          accepted
              .canonicalMessages[const MessageId('message-root')]!.threadSummary
              ?.toJson(),
          expectedSummary);
      expect(
          accepted
              .messages[const MessageId('message-root')]!.message.threadSummary
              ?.toJson(),
          expectedSummary);
      expect(accepted.conversations, before.conversations);
      expect(accepted.conversations[const ConversationId(_threadId)], isNull);
      expect(accepted.latestReplayCursor?.eventId, event.eventId);
      expect(accepted.durableStreams[_parentId]?.lastEventId, event.eventId);
      expect(
          accepted.durableStreams[_parentId]?.lastOccurredAt.value, _time(3));
      expect(accepted.durableStreams[_parentId]?.recentEventIds,
          ['clock-message-2', event.eventId]);
      expect(parentEvents, 1);

      expect(store.reduceDurableEvent(event).status,
          DurableEventReductionStatus.duplicate);
      expect(store.state, same(accepted));
      expect(store.state.latestReplayCursor, same(accepted.latestReplayCursor));
      expect(store.state.durableStreams, same(accepted.durableStreams));
      expect(parentEvents, 1);

      // A parent GET after replay must agree with the independently updated
      // summary even though the root's content revision is still one.
      final refreshed = store.hydrateMessageTimeline(_timelinePage(_parentId, [
        _message(1, id: 'message-root', threadSummary: expectedSummary),
        _message(2),
      ]));
      expect(refreshed.canonicalMessages, accepted.canonicalMessages);
      expect(refreshed.messages, accepted.messages);
      expect(refreshed.latestReplayCursor, same(accepted.latestReplayCursor));
      expect(refreshed.durableStreams, accepted.durableStreams);
      expect(refreshed.timelines.keys, [const ConversationId(_parentId)]);
      expect(refreshed.timelines[const ConversationId(_parentId)]!.messageIds,
          [const MessageId('message-root'), const MessageId('message-2')]);
      final emissionsAfterRefresh = parentEvents;
      expect(store.reduceDurableEvent(event).status,
          DurableEventReductionStatus.duplicate);
      expect(store.state, same(refreshed));
      expect(
          store.hydrateMessageTimeline(_timelinePage(_parentId, [
            _message(1, id: 'message-root', threadSummary: expectedSummary),
            _message(2),
          ])),
          same(refreshed));
      expect(parentEvents, emissionsAfterRefresh);
    });

    for (final snapshotSummary in ['viewer unread', 'older replies', 'absent']) {
      test('parent hydration preserves replayed summary over $snapshotSummary', () {
        final store = _seedStore(latestSequence: 1, messages: [
          _message(1, id: 'message-root'),
        ]);
        addTearDown(store.close);
        final event = _threadSummaryEvent();
        store.reduceDurableEvent(event);
        final before = store.state;
        final summary = before.canonicalMessages[const MessageId('message-root')]!
            .threadSummary!.toJson();
        final page = _timelinePage(_parentId, [
          _message(1, id: 'message-root', threadSummary: switch (snapshotSummary) {
            'viewer unread' => {...summary, 'unreadCount': 0},
            'older replies' => {
              ...summary, 'replyCount': 1, 'lastReplyAt': _time(1),
            },
            _ => null,
          }),
        ]);
        final refreshed = store.hydrateMessageTimeline(page);
        expect(refreshed.canonicalMessages, before.canonicalMessages);
        expect(refreshed.messages, before.messages);
        expect(refreshed.latestReplayCursor, same(before.latestReplayCursor));
        expect(refreshed.durableStreams, before.durableStreams);
        expect(refreshed.timelines.keys, [const ConversationId(_parentId)]);
        expect(store.hydrateMessageTimeline(page), same(refreshed));
        expect(store.reduceDurableEvent(event).status,
            DurableEventReductionStatus.duplicate);
        expect(store.state, same(refreshed));
      });
    }

    for (final conflict in ['tenant', 'conversation', 'sequence', 'thread', 'content']) {
      test('parent hydration rejects $conflict conflict atomically after replay', () {
        final store = _seedStore(latestSequence: 2, messages: [
          _message(2, id: 'message-root', revision: 2),
        ]);
        addTearDown(store.close);
        store.reduceDurableEvent(_threadSummaryEvent());
        final accepted = store.state;
        // A delayed older content revision cannot replace newer content or the
        // independently replayed summary, even when its summary is absent.
        store.hydrateMessageTimeline(_timelinePage(_parentId, [
          _message(2, id: 'message-root'),
        ]));
        expect(store.state.canonicalMessages, accepted.canonicalMessages);
        expect(store.state.messages, accepted.messages);
        final before = store.state;
        var emissions = 0;
        final subscription = store.watchTimeline(const ConversationId(_parentId))
            .listen((_) => emissions++);
        addTearDown(subscription.cancel);
        final conversationId = conflict == 'conversation' ? _otherId : _parentId;
        final root = before.messages[const MessageId('message-root')]!.toJson();
        final summary = Map<String, Object?>.from(root['threadSummary'] as Map);
        // A harmless summary difference must not mask a real conflict later
        // in the page, nor publish the valid first message or advance cursors.
        root['threadSummary'] = {...summary, 'unreadCount': 0};
        switch (conflict) {
          case 'tenant': root['tenantId'] = 'other-tenant';
          case 'conversation': root['conversationId'] = conversationId;
          case 'sequence': root['sequence'] = 3;
          case 'thread': root['threadSummary'] = {...summary, 'threadId': 'other-thread'};
          case 'content': root['content'] = {'format': 'markdown', 'text': 'Conflicting content'};
        }
        final page = _timelinePage(conversationId, [
          _message(1, id: 'new-message', conversationId: conversationId), root,
        ]);
        expect(() => store.hydrateMessageTimeline(page),
            throwsA(isA<NormalizedSnapshotConflict>()));
        expect(store.state, same(before));
        expect(emissions, 0);
      });
    }

    for (final conflict in ['type', 'parent', 'root']) {
      for (final scenario in [
        (name: 'without a summary', count: null, clock: _time(3)),
        for (final clock in {
          'equal': _time(2),
          '1ms earlier': '2026-08-26T15:00:01.999Z',
        }.entries)
          for (final count in [5, 6])
            (
              name:
                  '${count == 5 ? 'equal' : 'lower'} progress at ${clock.key} clocks',
              count: count,
              clock: clock.value,
            ),
      ]) {
        test(
            'thread summary atomically rejects cached $conflict conflict '
            '${scenario.name}', () {
          final store = _seedStore(
            latestSequence: 1,
            messages: [
              _message(1,
                  id: 'message-root',
                  threadSummary: scenario.count == null
                      ? null
                      : {
                          'threadId': _threadId,
                          'replyCount': scenario.count,
                          'participantIds': [_userId],
                          'unreadCount': 0,
                          'lastReplyAt': _time(1),
                        }),
            ],
          );
          addTearDown(store.close);
          store.hydrateConversationList(_conversationListSnapshot([
            _conversationSummary(_parentId, latestSequence: 1),
            _conversationSummary(_otherId, latestSequence: 0),
            if (conflict == 'type')
              _conversationSummary(_threadId, latestSequence: 0)
            else
              {
                ..._threadSummary(latestSequence: 0),
                if (conflict == 'parent') 'parentConversationId': _otherId,
                if (conflict == 'root') 'rootMessageId': 'another-root',
              },
          ]));
          store.reduceDurableEvent(_event(
            type: 'message.created',
            eventId: 'clock-message-2',
            second: 2,
            payload: {
              'message': _canonicalMessage(2),
              'clientMessageId': 'client-2',
            },
          ));
          final before = store.state;
          expect(before.latestReplayCursor?.eventId, 'clock-message-2');
          var parentEvents = 0;
          var threadEvents = 0;
          final parentSubscription = store
              .watchTimeline(const ConversationId(_parentId))
              .listen((_) => parentEvents += 1);
          final threadSubscription = store
              .watchTimeline(const ConversationId(_threadId))
              .listen((_) => threadEvents += 1);
          addTearDown(parentSubscription.cancel);
          addTearDown(threadSubscription.cancel);
          // Parse before the rejection assertion: only cached identity conflicts.
          final event = _event(
            type: 'message.thread_summary.updated',
            eventId: 'conflicting-summary',
            second: 3,
            occurredAt: scenario.clock,
            payload: _threadSummaryEvent().payload.data,
          );

          expect(
            () => store.reduceDurableEvent(event),
            throwsA(_recovery(
              DurableEventDiagnosticCode.incoherentPayload,
              DurableEventRecoveryReason.eventInvalid,
            )),
          );
          expect(store.state, same(before));
          expect(
              store.state.latestReplayCursor, same(before.latestReplayCursor));
          expect(store.state.durableStreams, same(before.durableStreams));
          expect(store.state.durableStreams[_parentId]?.lastEventId,
              'clock-message-2');
          expect(store.state.durableStreams[_parentId]?.lastOccurredAt.value,
              _time(2));
          expect(store.state.durableStreams[_parentId]?.recentEventIds,
              ['clock-message-2']);
          expect(store.state.canonicalMessages, same(before.canonicalMessages));
          expect(store.state.messages, same(before.messages));
          expect(store.state.timelines, same(before.timelines));
          expect(parentEvents, 0);
          expect(threadEvents, 0);
        });
      }
    }

    test(
        'thread reply updates its root, then authoritative summary replaces it',
        () async {
      final store = _seedThreadStore();
      var parentEvents = 0;
      var threadEvents = 0;
      final subscriptions = [
        store.watchTimeline(const ConversationId(_parentId)).listen(
              (_) => parentEvents += 1,
            ),
        store.watchTimeline(const ConversationId(_threadId)).listen(
              (_) => threadEvents += 1,
            ),
      ];

      store.reduceDurableEvent(_event(
        type: 'message.created',
        streamId: _threadId,
        eventId: 'thread-reply-1',
        second: 2,
        payload: {
          'message': _canonicalMessage(
            1,
            id: 'reply-1',
            conversationId: _threadId,
            authorId: 'user-other',
            text: 'Reply',
          ),
          'clientMessageId': 'reply-client-1',
        },
      ));
      final rootAfterReply =
          store.state.canonicalMessages[const MessageId('message-root')]!;
      expect(rootAfterReply.threadSummary?.replyCount, 1);
      expect(rootAfterReply.threadSummary?.unreadCount, 1);
      expect(rootAfterReply.threadSummary?.participantIds,
          const [UserId('user-other')]);
      expect(
        store.timeline(const ConversationId(_threadId)).messageIds,
        const [MessageId('reply-1')],
      );
      expect(parentEvents, 1);
      expect(threadEvents, 1);

      store.reduceDurableEvent(_threadSummaryEvent());
      final authoritative = store.state
          .canonicalMessages[const MessageId('message-root')]!.threadSummary!;
      expect(authoritative.replyCount, 5);
      expect(authoritative.unreadCount, 2);
      expect(authoritative.participantIds,
          const [UserId('user-other'), UserId('user-third')]);
      expect(parentEvents, 2);
      expect(threadEvents, 1);

      for (final subscription in subscriptions) {
        await subscription.cancel();
      }
      await store.close();
    });

    for (final viewerReacted in [false, true]) {
      for (final teammateAdds in [true, false]) {
        final operation = teammateAdds ? 'add' : 'remove';
        final sharedCount = teammateAdds ? 4 : 2;
        test('teammate $operation preserves idle viewer=$viewerReacted', () {
          final store = _seedReactionStore(viewerReacted: viewerReacted);
          addTearDown(store.close);
          store.reduceDurableEvent(_reactionEvent(
            eventId: 'teammate-$operation',
            second: 2,
            count: sharedCount,
            reactedByCurrentUser: teammateAdds,
          ));
          _expectReaction(store, sharedCount, viewerReacted);
        });

        for (final succeeds in [true, false]) {
          final desired = !viewerReacted;
          test(
              'teammate $operation retains pending viewer=$desired until '
              'exact-key ${succeeds ? 'success' : 'rollback'}', () {
            final store = _seedReactionStore(viewerReacted: viewerReacted);
            addTearDown(store.close);
            store.beginOptimisticReaction(_reactionInput('pending', desired));
            final event = _reactionEvent(
              eventId: 'teammate-$operation',
              second: 2,
              count: sharedCount,
              reactedByCurrentUser: teammateAdds,
            );
            store.reduceDurableEvent(event);
            final projectedCount = sharedCount + (desired ? 1 : -1);
            _expectReaction(store, projectedCount, desired);
            final accepted = store.state;
            expect(store.reduceDurableEvent(event).status,
                DurableEventReductionStatus.duplicate);
            expect(store.state, same(accepted));

            final result = _reactionResult(projectedCount, desired);
            store.reconcileOptimisticReaction('wrong-key', result);
            store.rollbackOptimisticReaction(
                const MessageId('message-1'), 'thumbs-up', 'wrong-key');
            expect(store.state, same(accepted));
            // Reusing the key proves the unrelated broadcast retained the work,
            // even when its actor flag equals the pending desired state.
            expect(
                () => store.beginOptimisticReaction(
                    _reactionInput('pending', desired)),
                throwsA(isA<NormalizedSnapshotConflict>()));

            if (succeeds) {
              store.reconcileOptimisticReaction('pending', result);
              _expectReaction(store, projectedCount, desired);
            } else {
              store.rollbackOptimisticReaction(
                  const MessageId('message-1'), 'thumbs-up', 'pending');
              _expectReaction(store, sharedCount, viewerReacted);
            }
            final settled = store.state;
            store.rollbackOptimisticReaction(
                const MessageId('message-1'), 'thumbs-up', 'pending');
            store.reconcileOptimisticReaction('pending', result);
            expect(store.state, same(settled));
          });
        }
      }
    }

    test('absent baseline pending add stays sorted and rolls back shared count',
        () {
      final store = _seedStore(
        latestSequence: 1,
        messages: [
          _message(1, reactions: [
            {
              'reactionKey': 'z-last',
              'count': 1,
              'reactedByCurrentUser': false,
            },
          ]),
        ],
      );
      addTearDown(store.close);
      store.beginOptimisticReaction(
          _reactionInput('pending', true, reactionKey: 'a-first'));
      final event = _reactionEvent(
        eventId: 'teammate-add',
        second: 2,
        count: 3,
        reactionKey: 'a-first',
      );
      store.reduceDurableEvent(event);
      final message = store.state.messages[const MessageId('message-1')]!;
      expect(message.reactions.map((reaction) => reaction.reactionKey),
          ['a-first', 'z-last']);
      _expectReaction(store, 4, true, reactionKey: 'a-first');
      expect(message.reactions.last.count, 1);
      expect(message.reactions.last.reactedByCurrentUser, isFalse);
      final accepted = store.state;
      expect(store.reduceDurableEvent(event).status,
          DurableEventReductionStatus.duplicate);
      expect(store.state, same(accepted));
      store.rollbackOptimisticReaction(
          const MessageId('message-1'), 'a-first', 'pending');
      _expectReaction(store, 3, false, reactionKey: 'a-first');
    });

    test(
        'teammate add to absent idle aggregate does not grant viewer ownership',
        () {
      final store = _seedStore(latestSequence: 1, messages: [_message(1)]);
      addTearDown(store.close);
      store.reduceDurableEvent(
          _reactionEvent(eventId: 'teammate-add', second: 2, count: 1));
      _expectReaction(store, 1, false);
    });

    for (final firstDesired in [true, false]) {
      test(
          'queued intents survive broadcasts and exact-key $firstDesired success',
          () {
        final store = _seedReactionStore(viewerReacted: !firstDesired);
        addTearDown(store.close);
        store.beginOptimisticReaction(_reactionInput('first', firstDesired));
        store.beginOptimisticReaction(_reactionInput('last', !firstDesired));
        store.reduceDurableEvent(_reactionEvent(
          eventId: 'teammate-first',
          second: 2,
          count: 4,
          reactedByCurrentUser: firstDesired,
        ));
        _expectReaction(store, 4, !firstDesired);
        store.reconcileOptimisticReaction(
            'first', _reactionResult(firstDesired ? 5 : 3, firstDesired));
        _expectReaction(store, 4, !firstDesired);
        final settledFirst = store.state;
        store.rollbackOptimisticReaction(
            const MessageId('message-1'), 'thumbs-up', 'first');
        expect(store.state, same(settledFirst));

        store.reduceDurableEvent(_reactionEvent(
          eventId: 'teammate-last',
          second: 3,
          count: 6,
          reactedByCurrentUser: !firstDesired,
        ));
        _expectReaction(store, firstDesired ? 5 : 7, !firstDesired);
        store.rollbackOptimisticReaction(
            const MessageId('message-1'), 'thumbs-up', 'last');
        _expectReaction(store, 6, firstDesired);
      });
    }

    for (final viewerReacted in [false, true]) {
      for (final pending in [false, true]) {
        test(
            'zero count removes baseline for viewer=$viewerReacted pending=$pending',
            () {
          final store = _seedReactionStore(viewerReacted: viewerReacted);
          addTearDown(store.close);
          final desired = !viewerReacted;
          if (pending) {
            store.beginOptimisticReaction(_reactionInput('pending', desired));
          }
          store.reduceDurableEvent(_reactionEvent(
            eventId: 'teammate-remove',
            second: 2,
            count: 0,
            reactedByCurrentUser: false,
          ));
          if (pending && desired) {
            _expectReaction(store, 1, true);
          } else {
            expect(
                store.state.messages[const MessageId('message-1')]!.reactions,
                isEmpty);
          }
          if (pending) {
            expect(
                () => store.beginOptimisticReaction(
                    _reactionInput('pending', desired)),
                throwsA(isA<NormalizedSnapshotConflict>()));
            store.rollbackOptimisticReaction(
                const MessageId('message-1'), 'thumbs-up', 'pending');
            expect(
                store.state.messages[const MessageId('message-1')]!.reactions,
                isEmpty);
          }
        });
      }
    }

    test('rejected reaction broadcast leaves pending lane and baseline intact',
        () {
      final store = _seedReactionStore(viewerReacted: false);
      addTearDown(store.close);
      store.reduceDurableEvent(
          _reactionEvent(eventId: 'accepted', second: 2, count: 4));
      store.beginOptimisticReaction(_reactionInput('pending', true));
      final before = store.state;
      expect(
        () => store.reduceDurableEvent(
            _reactionEvent(eventId: 'ambiguous', second: 2, count: 99)),
        throwsA(_recovery(DurableEventDiagnosticCode.orderingGap,
            DurableEventRecoveryReason.eventGap)),
      );
      expect(store.state, same(before));
      store.rollbackOptimisticReaction(
          const MessageId('message-1'), 'thumbs-up', 'pending');
      _expectReaction(store, 4, false);
    });
  });

  group('conversation durable reduction', () {
    test('creates canonically, updates hydrated list scopes, and is immutable',
        () async {
      final store = _seedStore(latestSequence: 0, messages: const []);
      final entityScope = EntityConversationSnapshotScope(
        entity: HostEntityReference(type: 'erp.order', id: 'order-42'),
      );
      store.hydrateConversationList(
        _conversationListSnapshot(const []),
      );
      store.hydrateConversationList(
        _conversationListSnapshot(const [], scope: entityScope),
      );
      var organizationEvents = 0;
      var entityEvents = 0;
      var otherConversationEvents = 0;
      final subscriptions = [
        store
            .watchConversationList(
                const OrganizationConversationSnapshotScope())
            .listen((_) => organizationEvents += 1),
        store
            .watchConversationList(entityScope)
            .listen((_) => entityEvents += 1),
        store
            .watchConversation(const ConversationId(_otherId))
            .listen((_) => otherConversationEvents += 1),
      ];
      final before = store.state;
      final event = _event(
        type: 'conversation.created',
        eventId: 'conversation-created',
        second: 2,
        streamId: 'conversation-created',
        payload: {
          'conversation': {
            'id': 'conversation-created',
            'tenantId': _tenantId,
            'type': 'channel',
            'name': 'Order 42',
            'visibility': 'private',
            'entity': {'type': 'erp.order', 'id': 'order-42'},
            'createdAt': _baseTime,
            'updatedAt': _time(2),
          },
          'clientRequestId': 'create-request-1',
        },
      );

      final reduction = store.reduceDurableEvent(event);
      expect(reduction.status, DurableEventReductionStatus.applied);
      expect(before.conversations,
          isNot(contains(const ConversationId('conversation-created'))));
      expect(store.state.conversations,
          contains(const ConversationId('conversation-created')));
      expect(
        store
            .conversationList(const OrganizationConversationSnapshotScope())
            .conversationIds,
        contains(const ConversationId('conversation-created')),
      );
      expect(
        store.conversationList(entityScope).conversationIds,
        contains(const ConversationId('conversation-created')),
      );
      expect(organizationEvents, 1);
      expect(entityEvents, 1);
      expect(otherConversationEvents, 0);

      final accepted = store.state;
      expect(store.reduceDurableEvent(event).status,
          DurableEventReductionStatus.duplicate);
      expect(identical(store.state, accepted), isTrue);
      expect(organizationEvents, 1);

      for (final subscription in subscriptions) {
        await subscription.cancel();
      }
      await store.close();
    });

    for (final clock in {
      'tied': _time(10),
      '1ms older': '2026-08-26T15:00:09.999Z',
      'older': _time(2),
    }.entries) {
      // Separate restore admission from archive admission so both exemptions
      // have an independent regression when the timestamp gate is restored.
      for (final collideOnArchive in [true, false]) {
        test(
            'lifecycle revisions admit ${clock.key} clocks '
            'starting with ${collideOnArchive ? 'archive' : 'restore'}', () {
          final store = _seedStore(
            latestSequence: 0,
            messages: const [],
            durableEvents: [
              if (!collideOnArchive)
                _lifecycleEvent(
                  archived: true,
                  eventId: 'initial-archive',
                  second: 1,
                  previousRevision: 1,
                  currentRevision: 2,
                ),
              _event(
                type: 'message.created',
                eventId: 'unrelated-message',
                second: 10,
                payload: {
                  'message': _canonicalMessage(1),
                  'clientMessageId': 'client-1',
                },
              ),
            ],
          );
          addTearDown(store.close);
          const id = ConversationId(_parentId);
          const scope = OrganizationConversationSnapshotScope();
          var conversationEmissions = 0;
          var listEmissions = 0;
          final conversationSubscription = store.watchConversation(id).listen(
                (_) => conversationEmissions += 1,
              );
          final listSubscription = store.watchConversationList(scope).listen(
                (_) => listEmissions += 1,
              );
          addTearDown(conversationSubscription.cancel);
          addTearDown(listSubscription.cancel);
          expect(store.state.durableStreams[_parentId]?.lastOccurredAt.value,
              _time(10));
          expect(store.state.latestReplayCursor?.eventId, 'unrelated-message');

          void expectLifecycle(bool archived, int revision, String eventId) {
            expect(store.state.lifecycleRevisions[id], revision);
            expect(store.state.lifecycleArchivedStates[id], archived);
            expect(
                store.conversation(id).lifecycle?.projectedArchived, archived);
            expect(store.conversationList(scope).conversationIds.contains(id),
                !archived);
            expect(store.state.durableStreams[_parentId]?.lastOccurredAt.value,
                _time(10));
            expect(store.state.durableStreams[_parentId]?.lastEventId, eventId);
            expect(store.state.latestReplayCursor?.eventId, eventId);
          }

          var transitions = 0;
          for (final archived in [if (collideOnArchive) true, false]) {
            final event = _lifecycleEvent(
              archived: archived,
              eventId: archived ? 'collision-archive' : 'collision-restore',
              second: 10,
              occurredAt: clock.value,
              previousRevision: archived ? 1 : 2,
              currentRevision: archived ? 2 : 3,
            );
            expect(store.reduceDurableEvent(event).status,
                DurableEventReductionStatus.applied);
            transitions += 1;
            expectLifecycle(archived, archived ? 2 : 3, event.eventId);
            expect(conversationEmissions, transitions);
            expect(listEmissions, transitions);

            final accepted = store.state;
            expect(store.reduceDurableEvent(event).status,
                DurableEventReductionStatus.duplicate);
            expect(store.state, same(accepted));
            expectLifecycle(archived, archived ? 2 : 3, event.eventId);
            expect(conversationEmissions, transitions);
            expect(listEmissions, transitions);
          }

          // New delivery IDs advance replay metadata, but lower revisions and
          // consistent same-revision redelivery cannot change lifecycle state.
          for (final archived in [true, false]) {
            final event = _lifecycleEvent(
              archived: archived,
              eventId: archived ? 'lower-revision' : 'same-revision',
              second: 10,
              occurredAt: clock.value,
              previousRevision: archived ? 1 : 2,
              currentRevision: archived ? 2 : 3,
            );
            expect(store.reduceDurableEvent(event).status,
                DurableEventReductionStatus.applied);
            expectLifecycle(false, 3, event.eventId);
            expect(conversationEmissions, transitions);
            expect(listEmissions, transitions);
            final accepted = store.state;
            expect(store.reduceDurableEvent(event).status,
                DurableEventReductionStatus.duplicate);
            expect(store.state, same(accepted));
            expect(conversationEmissions, transitions);
            expect(listEmissions, transitions);
          }

          for (final invalid in ['stream', 'same-revision', 'gap']) {
            final before = store.state;
            expect(
              // Stream identity is rejected by the trusted parser; revision
              // consistency and continuity are rejected by the reducer.
              () => store.reduceDurableEvent(_lifecycleEvent(
                archived: true,
                eventId: 'invalid-$invalid',
                second: 10,
                occurredAt: clock.value,
                conversationId: invalid == 'stream' ? _otherId : _parentId,
                previousRevision: invalid == 'same-revision' ? 2 : 4,
                currentRevision: invalid == 'same-revision' ? 3 : 5,
              )),
              throwsA(invalid == 'stream'
                  ? isA<DurableEventFormatException>().having(
                      (error) => error.code,
                      'code',
                      DurableEventParseErrorCode.incoherentPayload,
                    )
                  : _recovery(
                      invalid == 'gap'
                          ? DurableEventDiagnosticCode.orderingGap
                          : DurableEventDiagnosticCode.incoherentPayload,
                      invalid == 'gap'
                          ? DurableEventRecoveryReason.eventGap
                          : DurableEventRecoveryReason.eventInvalid,
                    )),
            );
            expect(store.state, same(before));
            expect(store.state.durableStreams, same(before.durableStreams));
            expect(store.state.latestReplayCursor,
                same(before.latestReplayCursor));
            expectLifecycle(false, 3, 'same-revision');
            expect(conversationEmissions, transitions);
            expect(listEmissions, transitions);
          }
        });
      }
    }

    test('archives/restores hydrated visibility and settles matching intent',
        () async {
      final store = _seedStore(latestSequence: 0, messages: const []);
      final archiveInput = ConversationArchiveInput.fromJson({
        'operation': 'set_conversation_archive',
        'intent': 'archive',
        'conversationId': _parentId,
        'expectedLifecycleRevision': 1,
        'idempotencyKey': 'archive-1',
      });
      store.beginOptimisticConversationArchive(archiveInput);
      final before = store.state;

      store.reduceDurableEvent(_lifecycleEvent(
        archived: true,
        eventId: 'archived-1',
        second: 2,
        previousRevision: 1,
        currentRevision: 2,
      ));
      expect(before.pendingConversationArchiveInputs, isNotEmpty);
      expect(store.state.pendingConversationArchiveInputs, isEmpty);
      expect(
          store
              .conversation(const ConversationId(_parentId))
              .lifecycle
              ?.projectedArchived,
          isTrue);
      expect(
        store
            .conversationList(const OrganizationConversationSnapshotScope())
            .conversationIds,
        isNot(contains(const ConversationId(_parentId))),
      );

      store.reduceDurableEvent(_lifecycleEvent(
        archived: false,
        eventId: 'restored-2',
        second: 3,
        previousRevision: 2,
        currentRevision: 3,
      ));
      expect(
          store
              .conversation(const ConversationId(_parentId))
              .lifecycle
              ?.projectedArchived,
          isFalse);
      expect(
        store
            .conversationList(const OrganizationConversationSnapshotScope())
            .conversationIds,
        contains(const ConversationId(_parentId)),
      );

      final restored = store.state;
      store.reduceDurableEvent(_lifecycleEvent(
        archived: true,
        eventId: 'stale-archive',
        second: 4,
        previousRevision: 1,
        currentRevision: 2,
      ));
      expect(
          store.state.lifecycleRevisions[const ConversationId(_parentId)], 3);
      expect(
          store
              .conversation(const ConversationId(_parentId))
              .lifecycle
              ?.projectedArchived,
          isFalse);
      expect(restored.conversationLists.values.single.conversationIds,
          contains(const ConversationId(_parentId)));
      await store.close();
    });

    test(
        'applies membership and atomically revokes private current-user access',
        () async {
      final store = _privateSeedStore(withTimeline: true);
      var revoked = 0;
      final before = store.state;
      final event = _membershipEvent(
        streamId: 'user:$_userId',
        eventId: 'membership-left',
        second: 2,
        currentUserState: 'left',
      );

      store.reduceDurableEvent(
        event,
        onConversationAccessRevoked: (_) => revoked += 1,
      );
      expect(revoked, 1);
      expect(before.timelines, contains(const ConversationId(_parentId)));
      expect(before.currentUserReadStates,
          contains(const ConversationId(_parentId)));
      expect(store.state.timelines,
          isNot(contains(const ConversationId(_parentId))));
      expect(store.state.currentUserReadStates,
          isNot(contains(const ConversationId(_parentId))));
      expect(
        store
            .conversationList(const OrganizationConversationSnapshotScope())
            .conversationIds,
        isNot(contains(const ConversationId(_parentId))),
      );
      expect(
        store
            .state
            .membersByConversation[const ConversationId(_parentId)]
                ?[const UserId(_userId)]
            ?.state,
        'left',
      );

      final accepted = store.state;
      store.reduceDurableEvent(
        event,
        onConversationAccessRevoked: (_) => revoked += 1,
      );
      expect(identical(store.state, accepted), isTrue);
      expect(revoked, 1);
      await store.close();
    });

    test('client revocation clears retained realtime subscription intent',
        () async {
      final store = _privateSeedStore(withTimeline: true);
      final session = ChatRealtimeSessionTransport(
        endpoint: Uri.parse('https://chat.example/api/chat'),
        clientPackageVersion: '0.1.3',
        protocolVersion: handrailChatDurableEventProtocolVersion,
        tokenProvider: () => 'token',
        socketFactory: (_, __) => throw StateError('not connected'),
      );
      final release =
          session.subscribeConversation(const ConversationId(_parentId));
      expect(
        session.conversationSubscriptionStatesById[_parentId],
        isA<ChatRealtimeConversationSubscriptionPendingState>(),
      );
      final client = HandrailChatClient(
        apiBaseUri: Uri.parse('https://chat.example/api/chat'),
        tokenProvider: () async => 'token',
        transport: _UnusedHttpTransport(),
        normalizedSnapshotStore: store,
        realtimeSession: session,
      );

      client.reduceDurableEvent(_membershipEvent(
        streamId: 'user:$_userId',
        eventId: 'membership-client-left',
        second: 2,
        currentUserState: 'left',
      ));
      expect(
        session.conversationSubscriptionStatesById[_parentId],
        isA<ChatRealtimeConversationSubscriptionRemovedState>(),
      );
      release();

      await client.dispose();
      await session.dispose();
      await store.close();
    });

    test('reduces read, preference, and draft private event families',
        () async {
      final store = _privateSeedStore();
      final preferenceInput = UpdateConversationPreferenceInput.fromJson(
        _preferenceInput(),
      );
      store.beginOptimisticConversationPreference(
        preferenceInput,
        IsoTimestamp(_time(1)),
      );
      var readCallbacks = 0;
      var draftCallbacks = 0;

      store.reduceDurableEvent(
        _readEvent(eventId: 'read-1', second: 2, lastReadSequence: 1),
        onReadCursorUpdated: (_) => readCallbacks += 1,
      );
      expect(
        store.state.currentUserReadStates[const ConversationId(_parentId)]
            ?.lastReadSequence,
        const MessageSequence(1),
      );
      expect(readCallbacks, 1);

      store.reduceDurableEvent(_preferenceEvent(
        eventId: 'preference-1',
        second: 3,
        input: _preferenceInput(),
        revision: 1,
      ));
      expect(store.state.pendingConversationPreferenceIntents, isEmpty);
      expect(
          store.state.preferenceRevisions[const ConversationId(_parentId)], 1);
      expect(
        store.state.currentUserPreferences[const ConversationId(_parentId)]
            ?.notificationPreference,
        'mentions',
      );
      expect(
        store.state.currentUserPreferences[const ConversationId(_parentId)]
            ?.isStarred,
        isTrue,
      );
      final restored = NormalizedSnapshotStateStorageCodec.decode(
        NormalizedSnapshotStateStorageCodec.encode(store.state),
      );
      expect(
        restored
            .currentUserPreferences[const ConversationId(_parentId)]?.isStarred,
        isTrue,
      );

      final accepted = store.state;
      var preferenceEmissions = 0;
      final preferenceSubscription = store
          .watchConversation(const ConversationId(_parentId))
          .listen((_) => preferenceEmissions += 1);
      // Older timestamps do not bypass preference payload validation: an
      // applied result must advance expected revision 0 to revision 1.
      expect(
        () => store.reduceDurableEvent(_preferenceEvent(
          eventId: 'preference-lower',
          second: 2,
          input: _preferenceInput(isStarred: false),
          revision: 0,
        )),
        throwsA(_recovery(
          DurableEventDiagnosticCode.incoherentPayload,
          DurableEventRecoveryReason.eventInvalid,
        )),
      );
      expect(identical(store.state, accepted), isTrue);
      expect(preferenceEmissions, 0);

      // A valid no-op result preserves its expected revision. Admit it for
      // replay bookkeeping, but do not replace the newer canonical preference.
      // Reusing the rejected ID also proves rejection did not consume it.
      final lowerRevision = _preferenceEvent(
        eventId: 'preference-lower',
        second: 2,
        input: _preferenceInput(isStarred: false),
        revision: 0,
        reconciliationStatus: 'already_requested_state',
      );
      expect(
        store.reduceDurableEvent(lowerRevision).status,
        DurableEventReductionStatus.applied,
      );
      expect(store.state.preferenceRevisions, accepted.preferenceRevisions);
      expect(store.state.authoritativeCurrentUserPreferences,
          accepted.authoritativeCurrentUserPreferences);
      expect(store.state.currentUserPreferences, accepted.currentUserPreferences);
      expect(
        store.state.currentUserPreferences[const ConversationId(_parentId)]
            ?.isStarred,
        isTrue,
      );
      final reconciled = store.state;
      expect(
        store.reduceDurableEvent(lowerRevision).status,
        DurableEventReductionStatus.duplicate,
      );
      expect(identical(store.state, reconciled), isTrue);
      expect(
        store
            .reduceDurableEvent(_preferenceEvent(
              eventId: 'preference-1',
              second: 3,
              input: _preferenceInput(),
              revision: 1,
            ))
            .status,
        DurableEventReductionStatus.duplicate,
      );
      expect(identical(store.state, reconciled), isTrue);
      await preferenceSubscription.cancel();

      final draft = _draftEvent(eventId: 'draft-1', second: 5, revision: 1);
      store.reduceDurableEvent(
        draft,
        onDraftUpdated: (_) => draftCallbacks += 1,
      );
      expect(draftCallbacks, 1);
      store.reduceDurableEvent(
        draft,
        onDraftUpdated: (_) => draftCallbacks += 1,
      );
      expect(draftCallbacks, 1);
      await store.close();
    });

    test('rejects actor mismatch and gaps without state/cursor emissions',
        () async {
      final store = _privateSeedStore();
      var emissions = 0;
      final subscription = store
          .watchConversation(const ConversationId(_parentId))
          .listen((_) => emissions += 1);
      final before = store.state;
      final wrongActor = _preferenceEvent(
        eventId: 'wrong-actor',
        second: 2,
        input: _preferenceInput(),
        revision: 1,
        actorUserId: 'user-other',
      );
      expect(
        () => store.reduceDurableEvent(wrongActor),
        throwsA(_recovery(
          DurableEventDiagnosticCode.privateStreamMismatch,
          DurableEventRecoveryReason.eventInvalid,
        )),
      );
      expect(identical(store.state, before), isTrue);
      expect(emissions, 0);

      store.reduceDurableEvent(_lifecycleEvent(
        archived: true,
        eventId: 'lifecycle-baseline',
        second: 3,
        previousRevision: 1,
        currentRevision: 2,
      ));
      emissions = 0;
      final gapBefore = store.state;
      expect(
        () => store.reduceDurableEvent(_lifecycleEvent(
          archived: true,
          eventId: 'lifecycle-gap',
          second: 4,
          previousRevision: 4,
          currentRevision: 5,
        )),
        throwsA(_recovery(
          DurableEventDiagnosticCode.orderingGap,
          DurableEventRecoveryReason.eventGap,
        )),
      );
      expect(identical(store.state, gapBefore), isTrue);
      expect(store.state.latestReplayCursor, gapBefore.latestReplayCursor);
      expect(emissions, 0);

      await subscription.cancel();
      await store.close();
    });

    test('strict parser rejects conversation/private stream mismatches', () {
      expect(
        () => KnownDurableEvent.fromJson(
          {
            ..._preferenceEvent(
              eventId: 'private-on-conversation',
              second: 2,
              input: _preferenceInput(),
              revision: 1,
            ).toJson(),
            'streamId': _parentId,
          },
          trustedIdentity: _trustedIdentity,
        ),
        throwsA(isA<DurableEventFormatException>()),
      );
      expect(
        () => KnownDurableEvent.fromJson(
          {
            ..._event(
              type: 'conversation.created',
              eventId: 'conversation-on-private',
              second: 2,
              streamId: 'new-conversation',
              payload: {
                'conversation': {
                  'id': 'new-conversation',
                  'tenantId': _tenantId,
                  'type': 'channel',
                  'name': 'New',
                  'visibility': 'public',
                  'createdAt': _baseTime,
                  'updatedAt': _time(2),
                },
              },
            ).toJson(),
            'streamId': 'user:$_userId',
          },
          trustedIdentity: _trustedIdentity,
        ),
        throwsA(isA<DurableEventFormatException>()),
      );
    });
  });
}

Matcher _recovery(
  DurableEventDiagnosticCode code,
  DurableEventRecoveryReason reason,
) =>
    isA<DurableEventReductionError>()
        .having((error) => error.diagnostic.code, 'code', code)
        .having((error) => error.diagnostic.reason, 'reason', reason);

NormalizedSnapshotStore _seedStore({
  required int latestSequence,
  required List<Map<String, Object?>> messages,
  List<KnownDurableEvent> durableEvents = const [],
}) {
  final store = NormalizedSnapshotStore();
  store.hydrateConversationList(_conversationListSnapshot([
    _conversationSummary(_parentId, latestSequence: latestSequence),
    _conversationSummary(_otherId, latestSequence: 0),
  ]));
  if (messages.isNotEmpty) {
    store.hydrateMessageTimeline(_timelinePage(_parentId, messages));
  }
  for (final event in durableEvents) {
    store.reduceDurableEvent(event);
  }
  return store;
}

NormalizedSnapshotStore _privateSeedStore({bool withTimeline = false}) {
  final store = NormalizedSnapshotStore();
  store.hydrateConversationList(_conversationListSnapshot([
    _conversationSummary(
      _parentId,
      latestSequence: withTimeline ? 1 : 2,
      visibility: 'private',
    ),
    _conversationSummary(_otherId, latestSequence: 0),
  ]));
  if (withTimeline) {
    store.hydrateMessageTimeline(_timelinePage(_parentId, [_message(1)]));
  }
  return store;
}

NormalizedSnapshotStore _seedThreadStore() {
  final store = NormalizedSnapshotStore();
  store.hydrateConversationList(_conversationListSnapshot([
    _conversationSummary(_parentId, latestSequence: 1),
    _threadSummary(latestSequence: 0),
    _conversationSummary(_otherId, latestSequence: 0),
  ]));
  store.hydrateMessageTimeline(_timelinePage(
    _parentId,
    [
      _message(
        1,
        id: 'message-root',
        threadSummary: {
          'threadId': _threadId,
          'replyCount': 0,
          'participantIds': <Object?>[],
          'unreadCount': 0,
        },
      ),
    ],
  ));
  return store;
}

ConversationListSnapshot _conversationListSnapshot(
  List<Map<String, Object?>> items, {
  ConversationSnapshotScope scope =
      const OrganizationConversationSnapshotScope(),
}) =>
    ConversationListSnapshot.fromJson({
      'kind': 'conversation_list',
      'scope': scope.toJson(),
      'items': items,
      'page': <String, Object?>{},
      '_meta': _metadata(),
    });

Map<String, Object?> _conversationSummary(
  String id, {
  required int latestSequence,
  String visibility = 'public',
}) =>
    {
      'id': id,
      'tenantId': _tenantId,
      'type': 'channel',
      'name': 'Channel $id',
      'visibility': visibility,
      'createdAt': _baseTime,
      'updatedAt': _baseTime,
      'latestSequence': latestSequence,
      'activityAt': _baseTime,
      'unreadMentionCount': 0,
      'currentMember': _member(id),
      'currentReadState': _readState(id),
      'currentPreference': _preference(id),
      'activeMemberUserIds': [_userId],
    };

Map<String, Object?> _threadSummary({required int latestSequence}) => {
      'id': _threadId,
      'tenantId': _tenantId,
      'type': 'thread',
      'visibility': 'public',
      'parentConversationId': _parentId,
      'rootMessageId': 'message-root',
      'createdAt': _baseTime,
      'updatedAt': _baseTime,
      'latestSequence': latestSequence,
      'activityAt': _baseTime,
      'unreadMentionCount': 0,
      'currentMember': _member(_threadId),
      'currentReadState': _readState(_threadId),
      'currentPreference': _preference(_threadId),
      'activeMemberUserIds': [_userId],
    };

Map<String, Object?> _member(String conversationId) => {
      'tenantId': _tenantId,
      'conversationId': conversationId,
      'userId': _userId,
      'role': 'member',
      'state': 'active',
      'joinedAt': _baseTime,
      'updatedAt': _baseTime,
    };

Map<String, Object?> _readState(String conversationId) => {
      'conversationId': conversationId,
      'userId': _userId,
      'lastReadSequence': 0,
      'updatedAt': _baseTime,
    };

Map<String, Object?> _preference(String conversationId) => {
      'conversationId': conversationId,
      'userId': _userId,
      'isStarred': false,
      'notificationPreference': 'mentions',
      'mute': {'muted': false},
      'updatedAt': _baseTime,
    };

MessageTimelinePage _timelinePage(
  String conversationId,
  List<Map<String, Object?>> messages,
) =>
    MessageTimelinePage.fromJson(
      {
        'conversationId': conversationId,
        'messages': messages,
        'pagination': {
          'older': {'available': false},
          'newer': {'available': false},
        },
        'replay': {
          'resumeFrom': {'eventId': 'snapshot-$conversationId'},
        },
      },
      request: MessageTimelineRequest.fromJson({
        'conversationId': conversationId,
        'direction': 'backward',
        'limit': 20,
      }),
    );

Map<String, Object?> _message(
  int sequence, {
  String? id,
  String conversationId = _parentId,
  String authorId = _userId,
  String? text,
  int revision = 1,
  List<Map<String, Object?>> reactions = const [],
  Map<String, Object?>? threadSummary,
}) =>
    {
      ..._canonicalMessage(
        sequence,
        id: id,
        conversationId: conversationId,
        authorId: authorId,
        text: text,
        revision: revision,
        threadSummary: threadSummary,
      ),
      'isThreadRoot': threadSummary != null,
      'reactions': reactions,
      'attachmentMetadata': <Object?>[],
    };

Map<String, Object?> _canonicalMessage(
  int sequence, {
  String? id,
  String conversationId = _parentId,
  String authorId = _userId,
  String? text,
  int revision = 1,
  Map<String, Object?>? threadSummary,
}) =>
    {
      'id': id ?? 'message-$sequence',
      'tenantId': _tenantId,
      'conversationId': conversationId,
      'author': {'type': 'user', 'userId': authorId},
      'sequence': sequence,
      'createdAt': _baseTime,
      'updatedAt': _time(revision),
      'revision': {
        'revision': revision,
        if (revision > 1) ...{
          'editedAt': _time(revision),
          'editedByUserId': authorId,
        },
      },
      if (threadSummary != null) 'threadSummary': threadSummary,
      'content': {'format': 'markdown', 'text': text ?? 'Message $sequence'},
    };

Map<String, Object?> _deletedMessage(int sequence, {required int revision}) => {
      ..._canonicalMessage(sequence, revision: revision),
      'content': null,
      'deletedAt': _time(revision),
      'deletedByUserId': _userId,
    };

KnownDurableEvent _lifecycleEvent({
  required bool archived,
  required String eventId,
  required int second,
  required int previousRevision,
  required int currentRevision,
  String? occurredAt,
  String conversationId = _parentId,
}) =>
    _event(
      type: archived ? 'conversation.archived' : 'conversation.restored',
      eventId: eventId,
      second: second,
      occurredAt: occurredAt,
      payload: {
        'conversationId': conversationId,
        'intent': archived ? 'archive' : 'restore',
        'previousState': archived ? 'active' : 'archived',
        'currentState': archived ? 'archived' : 'active',
        'previousLifecycleRevision': previousRevision,
        'currentLifecycleRevision': currentRevision,
      },
    );

KnownDurableEvent _membershipEvent({
  required String streamId,
  required String eventId,
  required int second,
  required String currentUserState,
}) {
  final input = <String, Object?>{
    'operation': 'mutate_conversation_membership',
    'intent': 'leave',
    'conversationId': _parentId,
    'expectedMemberListRevision': 1,
    'idempotencyKey': 'leave-1',
  };
  return _event(
    type: 'conversation.membership.updated',
    eventId: eventId,
    second: second,
    streamId: streamId,
    payload: {
      'input': input,
      'result': {
        'operation': 'mutate_conversation_membership',
        'intent': 'leave',
        'reconciliationStatus': 'applied',
        'conversationId': _parentId,
        'expectedMemberListRevision': 1,
        'memberListRevision': 2,
        'memberUserId': _userId,
        'members': [
          {
            'userId': _userId,
            'role': 'member',
            'state': currentUserState,
            'joinedAt': _baseTime,
            'updatedAt': _time(second),
          },
          {
            'userId': 'user-other',
            'role': 'owner',
            'state': 'active',
            'joinedAt': _baseTime,
            'updatedAt': _time(second),
          },
        ],
      },
    },
  );
}

KnownDurableEvent _readEvent({
  required String eventId,
  required int second,
  required int lastReadSequence,
}) =>
    _event(
      type: 'conversation.read_cursor_updated',
      eventId: eventId,
      second: second,
      streamId: 'user:$_userId',
      payload: {
        'kind': 'conversation_read_cursor',
        'actorUserId': _userId,
        'operation': 'mark_read',
        'reconciliationStatus': 'applied',
        'conversationId': _parentId,
        'readState': {
          'conversationId': _parentId,
          'userId': _userId,
          'lastReadSequence': lastReadSequence,
          'updatedAt': _time(second),
        },
        'latestSequence': 2,
        'unreadCount': 2 - lastReadSequence,
      },
    );

Map<String, Object?> _preferenceInput({bool isStarred = true}) => {
      'operation': 'update_conversation_preference',
      'conversationId': _parentId,
      'expectedPreferenceRevision': 0,
      'idempotencyKey': 'preference-1',
      'notificationPreference': 'mentions',
      'isStarred': isStarred,
      'mute': {'muted': false},
    };

KnownDurableEvent _preferenceEvent({
  required String eventId,
  required int second,
  required Map<String, Object?> input,
  required int revision,
  String actorUserId = _userId,
  String reconciliationStatus = 'applied',
}) =>
    _event(
      type: 'conversation.preference.updated',
      eventId: eventId,
      second: second,
      streamId: 'user:$actorUserId',
      trustedUserId: actorUserId,
      payload: {
        'actorUserId': actorUserId,
        'input': input,
        'result': {
          'operation': 'update_conversation_preference',
          'reconciliationStatus': reconciliationStatus,
          'conversationId': _parentId,
          'expectedPreferenceRevision': 0,
          'idempotencyKey': 'preference-1',
          'requestedPreference': {
            'notificationPreference': 'mentions',
            'isStarred': input['isStarred'],
            'mute': {'muted': false},
          },
          'preferenceRevision': revision,
          'preference': {
            'notificationPreference': 'mentions',
            'isStarred': input['isStarred'],
            'mute': {'muted': false},
            'updatedAt': _time(second),
          },
        },
      },
    );

KnownDurableEvent _draftEvent({
  required String eventId,
  required int second,
  required int revision,
}) {
  final input = <String, Object?>{
    'operation': 'synchronize_draft',
    'intent': 'clear',
    'conversationId': _parentId,
    'baseRevision': revision - 1,
    'deviceMutationId': 'device-mutation-$revision',
    'idempotencyKey': 'draft-$revision',
  };
  return _event(
    type: 'conversation.draft.updated',
    eventId: eventId,
    second: second,
    streamId: 'user:$_userId',
    payload: {
      'actorUserId': _userId,
      'input': input,
      'result': {
        'operation': 'synchronize_draft',
        'intent': 'clear',
        'reconciliationStatus': 'applied',
        'conversationId': _parentId,
        'baseRevision': revision - 1,
        'deviceMutationId': 'device-mutation-$revision',
        'idempotencyKey': 'draft-$revision',
        'canonicalRevision': revision,
        'canonicalUpdatedAt': _time(second),
        'draft': {'kind': 'clear_tombstone', 'content': null},
      },
    },
  );
}

NormalizedSnapshotStore _seedReactionStore({required bool viewerReacted}) =>
    _seedStore(latestSequence: 1, messages: [
      _message(1, reactions: [
        {
          'reactionKey': 'thumbs-up',
          'count': 3,
          'reactedByCurrentUser': viewerReacted,
        },
      ]),
    ]);

ReactionMutationInput _reactionInput(String key, bool desired,
        {String reactionKey = 'thumbs-up'}) =>
    ReactionMutationInput.fromJson({
      'operation': desired ? 'add_reaction' : 'remove_reaction',
      'messageId': 'message-1',
      'reactionKey': reactionKey,
      'idempotencyKey': key,
    });

ReactionMutationResult _reactionResult(int count, bool desired) =>
    ReactionMutationResult.fromJson({
      'operation': desired ? 'add_reaction' : 'remove_reaction',
      'reconciliationStatus': 'applied',
      'messageId': 'message-1',
      'reactionKey': 'thumbs-up',
      'count': count,
      'reactedByCurrentUser': desired,
    });

void _expectReaction(
    NormalizedSnapshotStore store, int count, bool viewerReacted,
    {String reactionKey = 'thumbs-up'}) {
  final aggregate = store
      .state.messages[const MessageId('message-1')]!.reactions
      .singleWhere((reaction) => reaction.reactionKey == reactionKey);
  expect(aggregate.count, count);
  expect(aggregate.reactedByCurrentUser, viewerReacted);
}

KnownDurableEvent _reactionEvent({
  required String eventId,
  required int second,
  required int count,
  String reactionKey = 'thumbs-up',
  bool reactedByCurrentUser = true,
}) =>
    _event(
      type: 'reaction.updated',
      eventId: eventId,
      second: second,
      payload: {
        'conversationId': _parentId,
        'operation': reactedByCurrentUser ? 'add_reaction' : 'remove_reaction',
        'reconciliationStatus': 'applied',
        'messageId': 'message-1',
        'reactionKey': reactionKey,
        'count': count,
        'reactedByCurrentUser': reactedByCurrentUser,
      },
    );

KnownDurableEvent _threadSummaryEvent({String threadId = _threadId}) => _event(
      type: 'message.thread_summary.updated',
      eventId: 'thread-summary-$threadId',
      second: 3,
      payload: {
        'parentConversationId': _parentId,
        'rootMessageId': 'message-root',
        'rootThreadSummary': {
          'threadId': threadId,
          'replyCount': 5,
          'participantIds': ['user-other', 'user-third'],
          'unreadCount': 2,
          'lastReplyAt': _time(3),
        },
      },
    );

KnownDurableEvent _event({
  required String type,
  required String eventId,
  required int second,
  required Map<String, Object?> payload,
  String? occurredAt,
  String streamId = _parentId,
  String trustedUserId = _userId,
  int protocolVersion = handrailChatDurableEventProtocolVersion,
}) =>
    KnownDurableEvent.fromJson(
      {
        'eventId': eventId,
        'protocolVersion': protocolVersion,
        'tenantId': _tenantId,
        'streamId': streamId,
        'type': type,
        'occurredAt': occurredAt ?? _time(second),
        'payload': payload,
      },
      trustedIdentity: DurableEventTrustedIdentity(
        tenantId: const TenantId(_tenantId),
        userId: UserId(trustedUserId),
      ),
    );

Map<String, Object?> _metadata() => {
      'packageVersion': '0.1.3',
      'protocolVersion': handrailChatDurableEventProtocolVersion,
      'schemaVersion': 9,
      'enabledFeatures': {'threads': true, conversationSnapshotFeature: true},
      'supportedProtocolRange': {
        'minimumVersion': 1,
        'maximumVersion': handrailChatDurableEventProtocolVersion,
      },
      'feature': {
        'name': conversationSnapshotFeature,
        'version': conversationSnapshotVersion,
      },
    };

String _time(int second) =>
    '2026-08-26T15:${(second ~/ 60).toString().padLeft(2, '0')}:${(second % 60).toString().padLeft(2, '0')}.000Z';

final class _UnusedHttpTransport implements HandrailChatHttpTransport {
  @override
  Future<HandrailChatHttpResponse> send(HandrailChatHttpRequest request) =>
      Future.error(StateError('No HTTP request was expected.'));
}
