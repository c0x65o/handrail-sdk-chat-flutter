import 'dart:async';
import 'dart:convert';

import 'package:handrail_chat/core.dart';
import 'package:test/test.dart';

import 'fixtures/draft_mutation_fixtures.dart';

const _tenantId = 'tenant-1';
const _conversationId = 'conversation-1';
const _otherConversationId = 'conversation-2';
const _messageId = 'message-1';
const _attachmentId = 'attachment-1';
const _userId = 'user-current';
const _baseTime = '2026-08-26T15:00:00.000Z';

void main() {
  test('unloaded private resources identify the snapshot needed for recovery', () async {
    final store = NormalizedSnapshotStore();
    addTearDown(store.close);
    for (final event in [
      _readEvent(eventId: 'unloaded-read', conversationId: _conversationId,
          occurredAt: _baseTime, updatedAt: _baseTime, lastReadSequence: 0),
      _preferenceEvent(eventId: 'unloaded-preference', conversationId: _conversationId,
          occurredAt: _baseTime),
      _draftEvent(eventId: 'unloaded-draft', conversationId: _conversationId,
          occurredAt: _baseTime),
    ]) {
      final before = store.state;
      expect(() => store.reduceDurableEvent(event), throwsA(
        isA<DurableEventReductionError>().having(
          (error) => error.diagnostic.conversationId, 'resource',
          const ConversationId(_conversationId))));
      expect(store.state, same(before));
    }
  });

  group('conversation membership observer clock collisions', () {
    const conversationId = ConversationId(_conversationId);
    const affectedUserId = UserId('user-target');
    const observerId = UserId(_userId);
    const trustedObserver = DurableEventTrustedIdentity(
      tenantId: TenantId(_tenantId),
      userId: observerId,
    );
    late NormalizedSnapshotStore store;
    late List<NormalizedConversationSnapshot> notifications;
    late List<ConversationId> revoked;

    KnownDurableEvent membership({
      required String eventId,
      required String occurredAt,
      int revision = 6,
      String state = 'left',
    }) =>
        _membershipEvent(
          eventId: eventId,
          occurredAt: occurredAt,
          revision: revision,
          intent: state == 'active' ? 'join' : 'leave',
          memberState: state,
          memberUserId: affectedUserId.value,
          streamId: _conversationId,
          trustedUserId: observerId.value,
          otherMembers: const [
            {
              'userId': _userId,
              'role': 'member',
              'state': 'active',
              'joinedAt': _baseTime,
              'updatedAt': _baseTime,
            },
          ],
        );

    setUp(() {
      store = _seedStore(
          conversationList: ConversationListSnapshot.fromJson({
        ..._conversationList().toJson(),
        'items': [
          {..._conversationSummary(_conversationId, 1), 'visibility': 'private'},
          _conversationSummary(_otherConversationId, 0),
        ],
      }));
      addTearDown(store.close);
      store.reduceDurableEvent(membership(
        eventId: 'observer-seed',
        occurredAt: _eventTime(3),
        revision: 5,
        state: 'active',
      ));
      expect(store.conversation(conversationId).memberListRevision, 5);
      expect(store.conversation(conversationId).memberUserIds,
          [observerId, affectedUserId]);
      notifications = [];
      revoked = [];
      final subscription =
          store.watchConversation(conversationId).listen(notifications.add);
      addTearDown(subscription.cancel);
    });

    for (final clock in <String, String>{
      'tied': '2026-08-26T15:00:03.000Z',
      '1ms older': '2026-08-26T15:00:02.999Z',
    }.entries) {
      test('${clock.key} clock applies revision 6 leave and replay', () {
        final before = store.state;
        final event = membership(
          eventId: 'observer-leave',
          occurredAt: clock.value,
        );
        final consumed = ['observer-seed'];
        void consume(KnownDurableEvent incoming) {
          expect(
              store
                  .reduceDurableEvent(incoming,
                      onConversationAccessRevoked: revoked.add)
                  .status,
              DurableEventReductionStatus.applied);
          consumed.add(incoming.eventId);
          final stream = store.state.durableStreams[_conversationId]!;
          expect(stream.recentEventIds, consumed);
          expect(stream.lastEventId, incoming.eventId);
          expect(stream.lastOccurredAt.value, _eventTime(3));
          expect(store.state.latestReplayCursor?.eventId, incoming.eventId);
          expect(store.state.memberListRevisions[conversationId], 6);
          expect(store.state.membersByConversation[conversationId]!
              [affectedUserId]!.state, 'left');
          final selected = store.conversation(conversationId);
          expect(selected.members[affectedUserId]!.state, 'left');
          expect(selected.memberUserIds, [observerId]);
          expect(selected.memberListRevision, 6);
          expect(notifications, hasLength(1));
          expect(notifications.single.memberUserIds, [observerId]);
          // Another member leaving must not revoke the observer's access.
          expect(store.state.messages, before.messages);
          expect(store.state.timelines, before.timelines);
          expect(store.state.currentUserReadStates,
              before.currentUserReadStates);
          expect(store.state.currentUserPreferences,
              before.currentUserPreferences);
          expect(store.state.conversationLists, before.conversationLists);
          expect(revoked, isEmpty);
        }

        consume(event);
        final canonicalMembers = store.state.membersByConversation;
        consume(membership(
          eventId: 'observer-stale-join',
          occurredAt: clock.value,
          revision: 5,
          state: 'active',
        ));
        expect(store.state.membersByConversation, canonicalMembers);
        // Equal, consistent revisions also consume a fresh envelope only.
        consume(KnownDurableEvent.fromJson({
          ...event.toJson(),
          'eventId': 'observer-equal-revision',
        }, trustedIdentity: trustedObserver));
        expect(store.state.membersByConversation, canonicalMembers);
        final accepted = store.state;
        expect(
            store
                .reduceDurableEvent(event,
                    onConversationAccessRevoked: revoked.add)
                .status,
            DurableEventReductionStatus.duplicate);
        expect(store.state, same(accepted));
        expect(store.state.durableStreams, same(accepted.durableStreams));
        expect(store.state.latestReplayCursor, same(accepted.latestReplayCursor));
        expect(notifications, hasLength(1));
        expect(revoked, isEmpty);
      });

      test('${clock.key} clock rejects equal revision conflict atomically', () {
        final before = store.state;
        expect(
            () => store.reduceDurableEvent(
                membership(
                  eventId: 'observer-conflicting-leave',
                  occurredAt: clock.value,
                  revision: 5,
                ),
                onConversationAccessRevoked: revoked.add),
            throwsA(isA<DurableEventReductionError>().having(
                (error) => error.diagnostic.code,
                'code',
                DurableEventDiagnosticCode.incoherentPayload)));
        expect(store.state, same(before));
        expect(store.state.durableStreams, same(before.durableStreams));
        expect(store.state.latestReplayCursor, same(before.latestReplayCursor));
        expect(notifications, isEmpty);
        expect(revoked, isEmpty);
      });

      test('${clock.key} clock rejects wrong stream identities atomically', () {
        final event = membership(
          eventId: 'observer-wrong-stream',
          occurredAt: clock.value,
        );
        final before = store.state;
        for (final stream in [
          _otherConversationId,
          'user:$_userId',
          'user:${affectedUserId.value}',
        ]) {
          expect(
              () => store.reduceDurableEvent(
                  KnownDurableEvent.fromJson({
                    ...event.toJson(),
                    'streamId': stream,
                  }, trustedIdentity: trustedObserver),
                  onConversationAccessRevoked: revoked.add),
              throwsA(isA<DurableEventFormatException>().having(
                  (error) => error.code,
                  'code',
                  stream == _otherConversationId
                      ? DurableEventParseErrorCode.incoherentPayload
                      : DurableEventParseErrorCode.privateStreamMismatch)));
        }
        // A valid private event for the affected member still cannot enter a
        // store whose current user is the observer, even at a lower revision.
        expect(
            () => store.reduceDurableEvent(
                _membershipEvent(
                  eventId: 'observer-wrong-private-user',
                  occurredAt: clock.value,
                  revision: 4,
                  intent: 'leave',
                  memberState: 'left',
                  memberUserId: affectedUserId.value,
                ),
                onConversationAccessRevoked: revoked.add),
            throwsA(isA<DurableEventReductionError>().having(
                (error) => error.diagnostic.code,
                'code',
                DurableEventDiagnosticCode.privateStreamMismatch)));
        expect(store.state, same(before));
        expect(store.state.durableStreams, same(before.durableStreams));
        expect(store.state.latestReplayCursor, same(before.latestReplayCursor));
        expect(notifications, isEmpty);
        expect(revoked, isEmpty);
      });
    }
  });

  group('conversation.membership.updated stream clock collisions', () {
    const conversationId = ConversationId(_conversationId);
    const userId = UserId(_userId);
    late NormalizedSnapshotStore store;
    late List<ConversationId> revoked;
    late KnownDurableEvent baseline;

    setUp(() {
      store = _seedStore(
          conversationList: ConversationListSnapshot.fromJson({
        ..._conversationList().toJson(),
        'items': [
          {
            ..._conversationSummary(_conversationId, 1),
            'visibility': 'private'
          },
          _conversationSummary(_otherConversationId, 0),
        ],
      }));
      addTearDown(store.close);
      revoked = [];
      expect(
        store
            .reduceDurableEvent(_membershipEvent(
              eventId: 'membership-seed',
              occurredAt: _eventTime(1),
              revision: 2,
              intent: 'join',
              memberState: 'active',
            ))
            .status,
        DurableEventReductionStatus.applied,
      );
      baseline = _readEvent(
        eventId: 'membership-other-conversation-read',
        conversationId: _otherConversationId,
        occurredAt: _eventTime(3),
        updatedAt: _eventTime(3),
        lastReadSequence: 1,
      );
      expect(store.reduceDurableEvent(baseline).status,
          DurableEventReductionStatus.applied);
      expect(store.state.memberListRevisions[conversationId], 2);
      expect(store.state.membersByConversation[conversationId]?[userId]?.state,
          'active');
      expect(store.state.messages, contains(const MessageId(_messageId)));
      expect(store.state.timelines, contains(conversationId));
      expect(store.state.currentUserReadStates, contains(conversationId));
      expect(store.state.currentUserPreferences, contains(conversationId));
    });

    void expectAccessCleared() {
      expect(
          store.state.messages, isNot(contains(const MessageId(_messageId))));
      expect(store.state.canonicalMessages,
          isNot(contains(const MessageId(_messageId))));
      expect(store.state.timelines, isNot(contains(conversationId)));
      expect(
          store.state.currentUserReadStates, isNot(contains(conversationId)));
      expect(store.state.authoritativeCurrentUserReadStates,
          isNot(contains(conversationId)));
      expect(
          store.state.currentUserPreferences, isNot(contains(conversationId)));
      expect(store.state.authoritativeCurrentUserPreferences,
          isNot(contains(conversationId)));
      expect(store.state.conversationLists.values.single.conversationIds,
          [const ConversationId(_otherConversationId)]);
    }

    for (final clock in <String, String>{
      'tied': '2026-08-26T15:00:03.000Z',
      '1ms older': '2026-08-26T15:00:02.999Z',
    }.entries) {
      for (final mutation
          in {'leave': 'left', 'remove_member': 'removed'}.entries) {
        test('${clock.key} clock applies ${mutation.key} revision and replay',
            () {
          final event = _membershipEvent(
            eventId: 'membership-revoked',
            occurredAt: clock.value,
            revision: 3,
            intent: mutation.key,
            memberState: mutation.value,
          );
          void onRevoked(ConversationId id) {
            expectAccessCleared();
            revoked.add(id);
          }

          final consumed = ['membership-seed', baseline.eventId];
          void consume(KnownDurableEvent event) {
            expect(
              store
                  .reduceDurableEvent(event,
                      onConversationAccessRevoked: onRevoked)
                  .status,
              DurableEventReductionStatus.applied,
            );
            consumed.add(event.eventId);
            expect(store.state.latestReplayCursor?.eventId, event.eventId);
            final stream = store.state.durableStreams['user:$_userId']!;
            expect(stream.lastEventId, event.eventId);
            expect(stream.recentEventIds, consumed);
            expect(stream.lastOccurredAt.value, _eventTime(3));
            expect(store.state.memberListRevisions[conversationId], 3);
            expect(
                store.state.membersByConversation[conversationId]?[userId]
                    ?.state,
                mutation.value);
            expect(store.state.memberUserIdsByConversation[conversationId],
                isEmpty);
            expectAccessCleared();
            expect(revoked, [conversationId]);
          }

          consume(event);
          final canonicalMembers = store
              .state.membersByConversation[conversationId]!
              .map((id, member) => MapEntry(id.value, member.toJson()));
          final otherRead = store
              .state
              .currentUserReadStates[
                  const ConversationId(_otherConversationId)]!
              .toJson();
          // A fresh envelope carrying an older active membership cannot restore
          // access, even though it still advances replay bookkeeping.
          consume(_membershipEvent(
            eventId: 'membership-stale-join',
            occurredAt: clock.value,
            revision: 2,
            intent: 'join',
            memberState: 'active',
          ));
          expect(
              store.state.membersByConversation[conversationId]!
                  .map((id, member) => MapEntry(id.value, member.toJson())),
              canonicalMembers);
          expect(
              store
                  .state
                  .currentUserReadStates[
                      const ConversationId(_otherConversationId)]!
                  .toJson(),
              otherRead);

          final accepted = store.state;
          expect(
              store
                  .reduceDurableEvent(event,
                      onConversationAccessRevoked: onRevoked)
                  .status,
              DurableEventReductionStatus.duplicate);
          expect(store.state, same(accepted));
          expect(store.state.durableStreams, same(accepted.durableStreams));
          expect(store.state.latestReplayCursor,
              same(accepted.latestReplayCursor));
          expect(revoked, [conversationId]);
        });
      }

      test('${clock.key} clock rejects a wrong membership user atomically', () {
        final other = _conversationSummary(_otherConversationId, 0);
        for (final field in [
          'currentMember',
          'currentReadState',
          'currentPreference'
        ]) {
          other[field] = {
            ...other[field] as Map<String, Object?>,
            'userId': 'user-other',
            'updatedAt': _eventTime(4),
          };
        }
        store.hydrateConversationList(ConversationListSnapshot.fromJson({
          ..._conversationList().toJson(),
          'items': [
            {
              ..._conversationSummary(_conversationId, 1),
              'visibility': 'private'
            },
            other,
          ],
        }));
        expect(
            store
                .reduceDurableEvent(_readEvent(
                  eventId: 'membership-other-user-read',
                  conversationId: _otherConversationId,
                  actorUserId: 'user-other',
                  occurredAt: _eventTime(3),
                  updatedAt: _eventTime(5),
                  lastReadSequence: 2,
                ))
                .status,
            DurableEventReductionStatus.applied);
        final wrongUser = _membershipEvent(
          eventId: 'membership-wrong-user',
          occurredAt: clock.value,
          revision: 3,
          intent: 'leave',
          memberState: 'left',
          memberUserId: 'user-other',
        );
        final before = store.state;
        // The parser also rejects an affected user that disagrees with the
        // authenticated stream, before the event can reach the reducer.
        expect(
          () => store.reduceDurableEvent(
              KnownDurableEvent.fromJson({
                ...wrongUser.toJson(),
                'streamId': 'user:$_userId',
              },
                  trustedIdentity: const DurableEventTrustedIdentity(
                    tenantId: TenantId(_tenantId),
                    userId: userId,
                  )),
              onConversationAccessRevoked: revoked.add),
          throwsA(isA<DurableEventFormatException>().having(
              (error) => error.code,
              'code',
              DurableEventParseErrorCode.privateStreamMismatch)),
        );
        expect(
            () => store.reduceDurableEvent(wrongUser,
                onConversationAccessRevoked: revoked.add),
            throwsA(isA<DurableEventReductionError>()
                .having((error) => error.diagnostic.reason, 'reason',
                    DurableEventRecoveryReason.eventInvalid)
                .having((error) => error.diagnostic.code, 'code',
                    DurableEventDiagnosticCode.privateStreamMismatch)));
        expect(store.state, same(before));
        expect(store.state.membersByConversation,
            same(before.membersByConversation));
        expect(
            store.state.memberListRevisions, same(before.memberListRevisions));
        expect(store.state.durableStreams, same(before.durableStreams));
        expect(store.state.latestReplayCursor, same(before.latestReplayCursor));
        expect(revoked, isEmpty);
      });
    }
  });

  group('conversation.read_cursor_updated stream clock collisions', () {
    for (final clock in <String, String>{
      'tied': '2026-08-26T15:00:03.000Z',
      '1ms older': '2026-08-26T15:00:02.999Z',
    }.entries) {
      test('${clock.key} clock preserves per-conversation reads and replay', () {
        final store = _seedStore();
        addTearDown(store.close);
        final callbacks = <ReadCursorUpdatedEvent>[];
        final consumed = <KnownDurableEvent>[];
        void consume(KnownDurableEvent event) {
          expect(
            store
                .reduceDurableEvent(event, onReadCursorUpdated: callbacks.add)
                .status,
            DurableEventReductionStatus.applied,
          );
          consumed.add(event);
          expect(store.state.latestReplayCursor?.eventId, event.eventId);
          final stream = store.state.durableStreams['user:$_userId']!;
          expect(stream.lastEventId, event.eventId);
          expect(stream.recentEventIds, consumed.map((event) => event.eventId));
          expect(stream.lastOccurredAt.value, _eventTime(3));
          expect(callbacks.length, consumed.length);
          final callback = callbacks.last;
          expect(callback.eventId, event.eventId);
          expect(callback.streamId, event.streamId);
          expect(callback.occurredAt, event.occurredAt);
          expect(callback.payload.toJson(),
              Map<String, Object?>.from(event.payload.data)
                ..remove('reconciliationStatus'));
        }

        void expectRead(KnownDurableEvent event) {
          final id =
              ConversationId(event.payload.data['conversationId'] as String);
          final expected = event.payload.data['readState'];
          expect(store.state.currentUserReadStates[id]?.toJson(), expected);
          expect(store.state.authoritativeCurrentUserReadStates[id]?.toJson(),
              expected);
        }

        final first = _readEvent(
          eventId: 'read-first',
          conversationId: _conversationId,
          occurredAt: _eventTime(3),
          updatedAt: _eventTime(4),
          lastReadSequence: 1,
        );
        final second = _readEvent(
          eventId: 'read-second',
          conversationId: _otherConversationId,
          occurredAt: clock.value,
          updatedAt: _eventTime(2),
          lastReadSequence: 2,
        );
        consume(first);
        expectRead(first);
        consume(second);
        expectRead(first);
        expectRead(second);

        // The same sequence can change manual-unread state using payload time,
        // even when its envelope ties the preceding event's wall clock.
        final manualUnread = _readEvent(
          eventId: 'read-manual-unread',
          conversationId: _otherConversationId,
          occurredAt: clock.value,
          updatedAt: _eventTime(5),
          lastReadSequence: 2,
          manualUnreadFromSequence: 1,
        );
        consume(manualUnread);
        expectRead(first);
        expectRead(manualUnread);
        final canonical = store.state;

        // Fresh envelopes still advance replay and deliver their payloads when
        // an older payload time or lower sequence loses canonical ordering.
        for (final stale in [
          _readEvent(
            eventId: 'read-older-payload',
            conversationId: _otherConversationId,
            occurredAt: clock.value,
            updatedAt: _eventTime(4),
            lastReadSequence: 2,
          ),
          _readEvent(
            eventId: 'read-lower-sequence',
            conversationId: _otherConversationId,
            occurredAt: clock.value,
            updatedAt: _eventTime(6),
            lastReadSequence: 1,
          ),
        ]) {
          consume(stale);
          // Replay commits copy the maps; canonical values must stay unchanged.
          expect(
            store.state.currentUserReadStates
                .map((id, read) => MapEntry(id.value, read.toJson())),
            canonical.currentUserReadStates
                .map((id, read) => MapEntry(id.value, read.toJson())),
          );
          expect(
            store.state.authoritativeCurrentUserReadStates
                .map((id, read) => MapEntry(id.value, read.toJson())),
            canonical.authoritativeCurrentUserReadStates
                .map((id, read) => MapEntry(id.value, read.toJson())),
          );
          expect(
            store.state.conversationMetadata.map((id, metadata) =>
                MapEntry(id.value, {
                  'latestSequence': metadata.latestSequence.value,
                  'activityAt': metadata.activityAt.value,
                })),
            canonical.conversationMetadata.map((id, metadata) =>
                MapEntry(id.value, {
                  'latestSequence': metadata.latestSequence.value,
                  'activityAt': metadata.activityAt.value,
                })),
          );
          expectRead(first);
          expectRead(manualUnread);
        }

        final accepted = store.state;
        for (final event in consumed) {
          expect(
            store
                .reduceDurableEvent(event, onReadCursorUpdated: callbacks.add)
                .status,
            DurableEventReductionStatus.duplicate,
          );
          expect(store.state, same(accepted));
          expect(store.state.currentUserReadStates,
              same(accepted.currentUserReadStates));
          expect(store.state.authoritativeCurrentUserReadStates,
              same(accepted.authoritativeCurrentUserReadStates));
          expect(store.state.durableStreams, same(accepted.durableStreams));
          expect(store.state.latestReplayCursor,
              same(accepted.latestReplayCursor));
          expect(callbacks.length, consumed.length);
        }
      });

      test('${clock.key} clock rejects a wrong read actor atomically', () {
        final store = _seedStore();
        addTearDown(store.close);
        final other = _conversationSummary(_otherConversationId, 0);
        for (final field in [
          'currentMember',
          'currentReadState',
          'currentPreference',
        ]) {
          other[field] = {
            ...other[field] as Map<String, Object?>,
            'userId': 'user-other',
            'updatedAt': _eventTime(1),
          };
        }
        store.hydrateConversationList(ConversationListSnapshot.fromJson({
          ..._conversationList().toJson(),
          'items': [_conversationSummary(_conversationId, 1), other],
        }));
        final callbacks = <ReadCursorUpdatedEvent>[];
        // Establish the exact other actor's stream on conversation-2 before
        // targeting conversation-1, whose private state belongs to our user.
        final baseline = _readEvent(
          eventId: 'other-actor-read-baseline',
          conversationId: _otherConversationId,
          actorUserId: 'user-other',
          occurredAt: _eventTime(3),
          updatedAt: _eventTime(2),
          lastReadSequence: 1,
        );
        expect(
          store
              .reduceDurableEvent(baseline, onReadCursorUpdated: callbacks.add)
              .status,
          DurableEventReductionStatus.applied,
        );
        expect(callbacks.single.eventId, baseline.eventId);
        expect(
          store.state.durableStreams['user:user-other']!.lastOccurredAt.value,
          _eventTime(3),
        );
        callbacks.clear();
        final wrongActor = _readEvent(
          eventId: 'wrong-actor-read',
          conversationId: _conversationId,
          actorUserId: 'user-other',
          occurredAt: clock.value,
          updatedAt: _eventTime(4),
          lastReadSequence: 2,
        );
        final before = store.state;
        expect(
          () => store.reduceDurableEvent(
            wrongActor,
            onReadCursorUpdated: callbacks.add,
          ),
          throwsA(isA<DurableEventReductionError>()
              .having((error) => error.diagnostic.reason, 'reason',
                  DurableEventRecoveryReason.eventInvalid)
              .having((error) => error.diagnostic.code, 'code',
                  DurableEventDiagnosticCode.privateStreamMismatch)),
        );
        expect(store.state, same(before));
        expect(store.state.currentUserReadStates,
            same(before.currentUserReadStates));
        expect(store.state.authoritativeCurrentUserReadStates,
            same(before.authoritativeCurrentUserReadStates));
        expect(store.state.conversationMetadata,
            same(before.conversationMetadata));
        expect(store.state.durableStreams, same(before.durableStreams));
        expect(store.state.latestReplayCursor, same(before.latestReplayCursor));
        expect(callbacks, isEmpty);
      });
    }
  });

  group('saved_message.updated stream clock collisions', () {
    for (final clock in <String, String>{
      'tied': '2026-08-26T15:00:03.000Z',
      '1ms older': '2026-08-26T15:00:02.999Z',
    }.entries) {
      test('${clock.key} clock preserves per-message revisions and replay', () {
        final store = _seedStore();
        addTearDown(store.close);
        store.hydrateMessageTimeline(_timeline(withSecondMessage: true));
        final first = _savedMessageEvent(
          eventId: 'saved-first',
          occurredAt: _eventTime(3),
        );
        final second = _savedMessageEvent(
          eventId: 'saved-second',
          messageId: 'message-2',
          occurredAt: clock.value,
        );
        final consumed = <String>[];
        void consume(KnownDurableEvent event) {
          expect(store.reduceDurableEvent(event).status,
              DurableEventReductionStatus.applied);
          consumed.add(event.eventId);
          expect(store.state.latestReplayCursor?.eventId, event.eventId);
          final stream = store.state.durableStreams['user:$_userId']!;
          expect(stream.lastEventId, event.eventId);
          expect(stream.recentEventIds, consumed);
          expect(stream.lastOccurredAt.value, _eventTime(3));
        }

        consume(first);
        consume(second);
        expect(store.state.savedMessageRevisions, {
          const MessageId(_messageId): 1,
          const MessageId('message-2'): 1,
        });
        for (final id in [_messageId, 'message-2']) {
          expect(store.state.currentUserSavedMessages[MessageId(id)]?.toJson(), {
            'messageId': id,
            'isSaved': true,
          });
        }
        final accepted = store.state;
        for (final event in [first, second]) {
          expect(store.reduceDurableEvent(event).status,
              DurableEventReductionStatus.duplicate);
          expect(store.state, same(accepted));
          expect(store.state.durableStreams, same(accepted.durableStreams));
          expect(store.state.latestReplayCursor, same(accepted.latestReplayCursor));
        }

        consume(_savedMessageEvent(
          eventId: 'saved-newer',
          messageId: 'message-2',
          occurredAt: clock.value,
          revision: 2,
          savedMessage: {'messageId': 'message-2', 'isSaved': false},
        ));
        final newer = store.state;
        expect(newer.savedMessageRevisions[const MessageId('message-2')], 2);
        expect(newer.currentUserSavedMessages[const MessageId('message-2')]
            ?.isSaved, isFalse);
        consume(_savedMessageEvent(
          eventId: 'saved-lower',
          messageId: 'message-2',
          occurredAt: clock.value,
        ));
        expect(store.state.savedMessageRevisions, newer.savedMessageRevisions);
        expect(store.state.currentUserSavedMessages, newer.currentUserSavedMessages);
      });

      for (final failure in ['malformed state',
        'wrong actor', 'equal revision conflict']) {
        test('${clock.key} $failure is rejected atomically', () {
          final store = _seedStore();
          addTearDown(store.close);
          store.hydrateMessageTimeline(_timeline(withSecondMessage: true));
          // A valid preference establishes the wrong actor's exact stream;
          // saved-message identity must still match the known message owner.
          final actor = failure == 'wrong actor' ? 'user-other' : _userId;
          if (actor != _userId) {
            final other = _conversationSummary(_otherConversationId, 0);
            for (final field in ['currentMember', 'currentReadState', 'currentPreference']) {
              other[field] = {
                ...other[field] as Map<String, Object?>,
                'userId': actor,
                'updatedAt': _eventTime(1),
              };
            }
            store.hydrateConversationList(ConversationListSnapshot.fromJson({
              ..._conversationList().toJson(),
              'items': [_conversationSummary(_conversationId, 2), other],
            }));
            store.reduceDurableEvent(_preferenceEvent(
              eventId: 'other-actor-baseline',
              conversationId: _otherConversationId,
              occurredAt: _eventTime(3),
              actorUserId: actor,
            ));
          } else {
            store.reduceDurableEvent(_savedMessageEvent(
              eventId: 'saved-baseline',
              occurredAt: _eventTime(3),
            ));
          }
          final event = _savedMessageEvent(
            eventId: 'saved-rejected',
            occurredAt: clock.value,
            actorUserId: actor,
            savedMessage: switch (failure) {
              'malformed state' => {'messageId': _messageId, 'isSaved': 'yes'},
              'equal revision conflict' => {'messageId': _messageId, 'isSaved': false},
              _ => {'messageId': _messageId, 'isSaved': true},
            },
          );
          final before = store.state;
          expect(() => store.reduceDurableEvent(event),
              throwsA(isA<DurableEventReductionError>().having(
                (error) => error.diagnostic.reason, 'reason',
                DurableEventRecoveryReason.eventInvalid,
              ).having(
                (error) => error.diagnostic.code,
                'code',
                failure == 'wrong actor'
                    ? DurableEventDiagnosticCode.privateStreamMismatch
                    : DurableEventDiagnosticCode.incoherentPayload,
              )));
          expect(store.state, same(before));
          expect(store.state.currentUserSavedMessages, same(before.currentUserSavedMessages));
          expect(store.state.savedMessageRevisions, same(before.savedMessageRevisions));
          expect(store.state.durableStreams, same(before.durableStreams));
          expect(store.state.latestReplayCursor, same(before.latestReplayCursor));
        });
      }
    }
  });

  group('preference.updated stream clock collisions', () {
    for (final clock in <String, String>{
      'tied': '2026-08-26T15:00:03.000Z',
      '1ms older': '2026-08-26T15:00:02.999Z',
    }.entries) {
      test('${clock.key} clock preserves independent revisions and replay', () {
        final store = _seedStore();
        addTearDown(store.close);
        final firstTime = _eventTime(3);
        final first = _preferenceEvent(
          eventId: 'preference-first',
          conversationId: _conversationId,
          occurredAt: firstTime,
        );
        final second = _preferenceEvent(
          eventId: 'preference-second',
          conversationId: _otherConversationId,
          occurredAt: clock.value,
        );

        for (final event in [first, second]) {
          expect(store.reduceDurableEvent(event).status,
              DurableEventReductionStatus.applied);
        }
        expect(store.state.preferenceRevisions, {
          const ConversationId(_conversationId): 1,
          const ConversationId(_otherConversationId): 1,
        });
        for (final entry in {
          _conversationId: firstTime,
          _otherConversationId: clock.value,
        }.entries) {
          final expected = {
            'conversationId': entry.key,
            'userId': _userId,
            ..._canonicalPreference(entry.value),
          };
          final id = ConversationId(entry.key);
          expect(store.state.currentUserPreferences[id]?.toJson(), expected);
          expect(store.state.authoritativeCurrentUserPreferences[id]?.toJson(),
              expected);
        }
        final stream = store.state.durableStreams['user:$_userId']!;
        expect(stream.lastOccurredAt.value, firstTime);
        expect(stream.lastEventId, second.eventId);
        expect(stream.recentEventIds, [first.eventId, second.eventId]);

        final accepted = store.state;
        expect(store.reduceDurableEvent(second).status,
            DurableEventReductionStatus.duplicate);
        expect(store.state, same(accepted));
        expect(store.state.durableStreams, same(accepted.durableStreams));
        expect(store.state.latestReplayCursor, same(accepted.latestReplayCursor));

        expect(
          store.reduceDurableEvent(_preferenceEvent(
            eventId: 'preference-newer-revision',
            conversationId: _otherConversationId,
            occurredAt: clock.value,
            revision: 2,
            isStarred: false,
          )).status,
          DurableEventReductionStatus.applied,
        );
        final newer = store.state;
        expect(
          newer.preferenceRevisions[const ConversationId(_otherConversationId)],
          2,
        );
        expect(
          newer.currentUserPreferences[const ConversationId(_otherConversationId)]
              ?.isStarred,
          isFalse,
        );

        // A fresh envelope is consumed, but its lower resource revision loses.
        expect(
          store.reduceDurableEvent(_preferenceEvent(
            eventId: 'preference-lower-revision',
            conversationId: _otherConversationId,
            occurredAt: clock.value,
            revision: 1,
            isStarred: true,
          )).status,
          DurableEventReductionStatus.applied,
        );
        expect(store.state.preferenceRevisions, newer.preferenceRevisions);
        expect(store.state.currentUserPreferences,
            newer.currentUserPreferences);
        expect(store.state.authoritativeCurrentUserPreferences,
            newer.authoritativeCurrentUserPreferences);
        expect(store.state.durableStreams['user:$_userId']!.lastOccurredAt.value,
            firstTime);
      });

      test('${clock.key} clock does not hide a wrong actor', () {
        final store = _seedStore();
        addTearDown(store.close);
        // Establish the other actor's stream on a conversation they own in
        // this fixture; conversation-1 still belongs to the current user.
        final other = _conversationSummary(_otherConversationId, 0);
        for (final field in [
          'currentMember',
          'currentReadState',
          'currentPreference',
        ]) {
          other[field] = {
            ...other[field] as Map<String, Object?>,
            'userId': 'user-other',
            'updatedAt': _eventTime(1),
          };
        }
        store.hydrateConversationList(ConversationListSnapshot.fromJson({
          ..._conversationList().toJson(),
          'items': [_conversationSummary(_conversationId, 1), other],
        }));
        expect(
          store.reduceDurableEvent(_preferenceEvent(
            eventId: 'other-actor-baseline',
            conversationId: _otherConversationId,
            occurredAt: _eventTime(3),
            actorUserId: 'user-other',
          )).status,
          DurableEventReductionStatus.applied,
        );
        final wrongActor = _preferenceEvent(
          eventId: 'wrong-actor-fresh',
          conversationId: _conversationId,
          occurredAt: clock.value,
          actorUserId: 'user-other',
        );
        final before = store.state;
        expect(
          () => store.reduceDurableEvent(wrongActor),
          throwsA(isA<DurableEventReductionError>()
              .having((error) => error.diagnostic.reason, 'reason',
                  DurableEventRecoveryReason.eventInvalid)
              .having((error) => error.diagnostic.code, 'code',
                  DurableEventDiagnosticCode.privateStreamMismatch)),
        );
        expect(store.state, same(before));
        expect(store.state.durableStreams, same(before.durableStreams));
        expect(store.state.latestReplayCursor, same(before.latestReplayCursor));
      });
    }
  });

  group('draft.updated stream clock collisions', () {
    for (final clock in <String, String>{
      'tied': '2026-08-26T15:00:03.000Z',
      '1ms older': '2026-08-26T15:00:02.999Z',
    }.entries) {
      for (final preferenceFirst in [false, true]) {
        test('${clock.key} clock accepts draft after '
            '${preferenceFirst ? 'preference' : 'draft'}', () {
          final store = _seedStore();
          addTearDown(store.close);
          final callbacks = <ConversationDraftUpdatedEvent>[];
          final firstTime = _eventTime(3);
          final first = preferenceFirst
              ? _preferenceEvent(
                  eventId: 'preference-first',
                  conversationId: _conversationId,
                  occurredAt: firstTime,
                )
              : _draftEvent(
                  eventId: 'draft-first',
                  conversationId: _conversationId,
                  occurredAt: firstTime,
                );
          final second = _draftEvent(
            eventId: 'draft-second',
            conversationId: _otherConversationId,
            occurredAt: clock.value,
            clear: true,
          );
          final consumed = <String>[];
          for (final event in [first, second]) {
            expect(
              store
                  .reduceDurableEvent(event, onDraftUpdated: callbacks.add)
                  .status,
              DurableEventReductionStatus.applied,
            );
            consumed.add(event.eventId);
            expect(store.state.latestReplayCursor?.eventId, event.eventId);
            final stream = store.state.durableStreams['user:$_userId']!;
            expect(stream.lastEventId, event.eventId);
            expect(stream.recentEventIds, consumed);
            expect(stream.lastOccurredAt.value, firstTime);
          }
          expect(store.state.draftRevisions, {
            if (!preferenceFirst) const ConversationId(_conversationId): 1,
            const ConversationId(_otherConversationId): 1,
          });
          expect(
            {
              for (final entry in store.state.currentUserDrafts.entries)
                entry.key: entry.value.toJson(),
            },
            {
              if (!preferenceFirst)
                const ConversationId(_conversationId): {
                  'kind': 'replaced',
                  'content': replaceDraftInputFixture['content'],
                },
              const ConversationId(_otherConversationId): {
                'kind': 'clear_tombstone',
                'content': null,
              },
            },
          );
          if (preferenceFirst) {
            expect(store.state.preferenceRevisions, {
              const ConversationId(_conversationId): 1,
            });
            final expected = {
              'conversationId': _conversationId,
              'userId': _userId,
              ..._canonicalPreference(firstTime),
            };
            expect(
              store
                  .state
                  .currentUserPreferences[const ConversationId(_conversationId)]
                  ?.toJson(),
              expected,
            );
            expect(
              store
                  .state
                  .authoritativeCurrentUserPreferences[const ConversationId(
                    _conversationId,
                  )]
                  ?.toJson(),
              expected,
            );
          }
          expect(callbacks.map((event) => event.eventId), [
            if (!preferenceFirst) first.eventId,
            second.eventId,
          ]);
          for (final callback in callbacks) {
            final result = callback.payload.result;
            expect(result.canonicalRevision, 1);
            expect(
              result.draft.toJson(),
              store.state.currentUserDrafts[result.conversationId]?.toJson(),
            );
          }

          final accepted = store.state;
          final callbackCount = callbacks.length;
          expect(
            store
                .reduceDurableEvent(second, onDraftUpdated: callbacks.add)
                .status,
            DurableEventReductionStatus.duplicate,
          );
          expect(store.state, same(accepted));
          expect(
            store.state.latestReplayCursor,
            same(accepted.latestReplayCursor),
          );
          expect(store.state.durableStreams, same(accepted.durableStreams));
          expect(callbacks, hasLength(callbackCount));
        });
      }

      test(
        '${clock.key} lower draft revision is consumed without overwriting',
        () {
          final store = _seedStore();
          addTearDown(store.close);
          final callbacks = <ConversationDraftUpdatedEvent>[];
          final newer = _draftEvent(
            eventId: 'draft-newer-revision',
            conversationId: _conversationId,
            occurredAt: _eventTime(3),
            revision: 2,
          );
          expect(
            store
                .reduceDurableEvent(newer, onDraftUpdated: callbacks.add)
                .status,
            DurableEventReductionStatus.applied,
          );
          final before = store.state;
          expect(
            before.draftRevisions[const ConversationId(_conversationId)],
            2,
          );
          expect(
            before.currentUserDrafts[const ConversationId(_conversationId)]
                ?.toJson(),
            {
              'kind': 'replaced',
              'content': replaceDraftInputFixture['content'],
            },
          );
          final lower = _draftEvent(
            eventId: 'draft-lower-revision',
            conversationId: _conversationId,
            occurredAt: clock.value,
            clear: true,
          );
          expect(
            store
                .reduceDurableEvent(lower, onDraftUpdated: callbacks.add)
                .status,
            DurableEventReductionStatus.applied,
          );
          expect(store.state.currentUserDrafts, before.currentUserDrafts);
          expect(store.state.draftRevisions, before.draftRevisions);
          expect(store.state.latestReplayCursor?.eventId, lower.eventId);
          final stream = store.state.durableStreams['user:$_userId']!;
          expect(stream.lastEventId, lower.eventId);
          expect(stream.recentEventIds, [newer.eventId, lower.eventId]);
          expect(stream.lastOccurredAt.value, _eventTime(3));
          // Fresh lower revisions still settle the originating draft mutation.
          expect(callbacks.map((event) => event.eventId), [
            newer.eventId,
            lower.eventId,
          ]);
          expect(callbacks.last.payload.result.canonicalRevision, 1);
          expect(callbacks.last.payload.result.draft.kind, 'clear_tombstone');
        },
      );

      test('${clock.key} draft clock does not hide a wrong actor', () {
        final store = _seedStore();
        addTearDown(store.close);
        final other = _conversationSummary(_otherConversationId, 0);
        for (final field in [
          'currentMember',
          'currentReadState',
          'currentPreference',
        ]) {
          other[field] = {
            ...other[field] as Map<String, Object?>,
            'userId': 'user-other',
            'updatedAt': _eventTime(1),
          };
        }
        store.hydrateConversationList(
          ConversationListSnapshot.fromJson({
            ..._conversationList().toJson(),
            'items': [_conversationSummary(_conversationId, 1), other],
          }),
        );
        final callbacks = <ConversationDraftUpdatedEvent>[];
        // Seed the exact actor stream that the invalid event will target.
        final baseline = _draftEvent(
          eventId: 'other-actor-draft-baseline',
          conversationId: _otherConversationId,
          occurredAt: _eventTime(3),
          actorUserId: 'user-other',
        );
        expect(
          store
              .reduceDurableEvent(baseline, onDraftUpdated: callbacks.add)
              .status,
          DurableEventReductionStatus.applied,
        );
        expect(callbacks.single.eventId, baseline.eventId);
        expect(
          store.state.durableStreams['user:user-other']!.lastOccurredAt.value,
          _eventTime(3),
        );
        callbacks.clear();
        final wrongActor = _draftEvent(
          eventId: 'wrong-actor-draft',
          conversationId: _conversationId,
          occurredAt: clock.value,
          actorUserId: 'user-other',
        );
        final before = store.state;
        expect(
          () => store.reduceDurableEvent(
            wrongActor,
            onDraftUpdated: callbacks.add,
          ),
          throwsA(
            isA<DurableEventReductionError>()
                .having(
                  (error) => error.diagnostic.reason,
                  'reason',
                  DurableEventRecoveryReason.eventInvalid,
                )
                .having(
                  (error) => error.diagnostic.code,
                  'code',
                  DurableEventDiagnosticCode.privateStreamMismatch,
                ),
          ),
        );
        expect(store.state, same(before));
        expect(store.state.latestReplayCursor, same(before.latestReplayCursor));
        expect(store.state.durableStreams, same(before.durableStreams));
        expect(callbacks, isEmpty);
      });
    }
  });

  group('attachment.updated durable reduction', () {
    test('enriches metadata, settles upload, persists, and stays immutable',
        () async {
      final store = _seedStore(withAttachment: true);
      store.reduceDurableEvent(_huddleEvent(
        eventId: 'huddle-unrelated',
        second: 1,
        state: _inactiveHuddle,
      ));
      _seedPendingUpload(store);
      final before = store.state;
      final oldMetadata =
          before.attachments[const AttachmentId(_attachmentId)]!;
      final unrelatedHuddles = before.huddles;
      final unrelatedHuddle =
          unrelatedHuddles[const ConversationId(_conversationId)];
      expect(
        store
            .reduceDurableEvent(_attachmentEvent(
              eventId: 'attachment-stable',
              second: 2,
              attachment: _attachmentMetadata(),
            ))
            .status,
        DurableEventReductionStatus.applied,
      );
      final event = _attachmentEvent(
        eventId: 'attachment-enriched',
        second: 3,
        attachment: _attachmentMetadata(enriched: true),
      );

      final reduced = store.reduceDurableEvent(event);

      expect(reduced.status, DurableEventReductionStatus.applied);
      final metadata =
          store.state.attachments[const AttachmentId(_attachmentId)]!;
      expect(metadata.previewUrl, 'https://chat.example/attachment-1/preview');
      expect(metadata.width, 640);
      expect(metadata.height, 480);
      expect(metadata.altText, 'Invoice preview');
      expect(
        store.state.messages[const MessageId(_messageId)]!.attachmentMetadata
            .single
            .toJson(),
        metadata.toJson(),
      );
      final upload = store.state.attachmentUploads['upload-1']!;
      expect(upload.status, ChatAttachmentUploadStatus.attached);
      expect(upload.messageAttachment?.toJson(), metadata.toJson());
      expect(
        identical(
          store.state.huddles[const ConversationId(_conversationId)],
          unrelatedHuddle,
        ),
        isTrue,
      );
      expect(oldMetadata.previewUrl, isNull);
      expect(() => store.state.attachments.clear(), throwsUnsupportedError);
      expect(
        () => store
            .state.messages[const MessageId(_messageId)]!.attachmentMetadata
            .add(metadata),
        throwsUnsupportedError,
      );

      final accepted = store.state;
      final duplicate = store.reduceDurableEvent(event);
      expect(duplicate.status, DurableEventReductionStatus.duplicate);
      expect(identical(store.state, accepted), isTrue);
      final stale = store.reduceDurableEvent(_attachmentEvent(
        eventId: 'attachment-stale',
        second: 2,
        attachment: _attachmentMetadata(enriched: true),
      ));
      expect(stale.status, DurableEventReductionStatus.stale);
      expect(identical(store.state, accepted), isTrue);

      final restored = NormalizedSnapshotStateStorageCodec.decode(
        NormalizedSnapshotStateStorageCodec.encode(store.state),
      );
      expect(
        restored.attachments[const AttachmentId(_attachmentId)]?.toJson(),
        metadata.toJson(),
      );
      expect(restored.huddles[const ConversationId(_conversationId)]?.status,
          HuddleSessionStatus.inactive);
      expect(restored.attachmentUploads['upload-1']?.status,
          ChatAttachmentUploadStatus.attached);

      final laterCommandState = ChatAttachmentUploadState(
        uploadId: 'upload-1',
        conversationId: const ConversationId(_conversationId),
        metadata: _uploadMetadata,
        status: ChatAttachmentUploadStatus.finalized,
        uploadedBytes: 42,
        attachment: AttachmentLifecycleState.fromJson(_finalizedAttachment),
      );
      expect(
        identical(
          store.reconcileAttachmentUpload(laterCommandState),
          accepted,
        ),
        isTrue,
      );
      expect(store.state.attachmentUploads['upload-1']?.status,
          ChatAttachmentUploadStatus.attached);
      await store.close();
    });

    test(
        'allows metadata to lead its message, gaps missing references, and rejects regression',
        () async {
      for (final store in <NormalizedSnapshotStore>[
        NormalizedSnapshotStore(),
        _seedStore(),
      ]) {
        final before = store.state;
        expect(
          () => store.reduceDurableEvent(_attachmentEvent(
            eventId: 'attachment-gap-${store.state.conversations.length}',
            second: 2,
            attachment: _attachmentMetadata(),
          )),
          throwsA(_recovery(DurableEventRecoveryReason.eventGap)),
        );
        expect(identical(store.state, before), isTrue);
        await store.close();
      }

      final missingMessage = _seedStore(withAttachment: true);
      final missingMessageBefore = missingMessage.state;
      expect(
        missingMessage
            .reduceDurableEvent(_attachmentEvent(
              eventId: 'attachment-missing-message',
              second: 2,
              messageId: 'message-missing',
              attachment: _attachmentMetadata(),
            ))
            .status,
        DurableEventReductionStatus.applied,
      );
      expect(identical(missingMessage.state, missingMessageBefore), isFalse);
      expect(
        missingMessage.state.attachments,
        contains(const AttachmentId(_attachmentId)),
      );
      await missingMessage.close();

      final store = _seedStore(withAttachment: true);
      _seedPendingUpload(store);
      store.reduceDurableEvent(_attachmentEvent(
        eventId: 'attachment-valid',
        second: 2,
        attachment: _attachmentMetadata(enriched: true),
      ));
      final before = store.state;
      final cursor = before.latestReplayCursor;
      final uploads = before.attachmentUploads;
      expect(
        () => store.reduceDurableEvent(_attachmentEvent(
          eventId: 'attachment-regression',
          second: 3,
          attachment: {
            ..._attachmentMetadata(enriched: true),
            'fileName': 'different.pdf',
          },
        )),
        throwsA(_recovery(DurableEventRecoveryReason.eventInvalid)),
      );
      expect(identical(store.state, before), isTrue);
      expect(identical(store.state.attachmentUploads, uploads), isTrue);
      expect(identical(store.state.latestReplayCursor, cursor), isTrue);
      await store.close();
    });
  });

  group('huddle.updated durable reduction', () {
    test('accepts stable states and direct starting-to-ended transition',
        () async {
      final store = _seedStore();
      final endedWithoutParticipants = <String, Object?>{
        ..._endedHuddle,
        'participants': <Object?>[],
      };
      var callbacks = 0;
      final states = <Map<String, Object?>>[
        _inactiveHuddle,
        _inactiveHuddle,
        _startingHuddle,
        _startingHuddle,
        endedWithoutParticipants,
        endedWithoutParticipants,
      ];
      for (var index = 0; index < states.length; index += 1) {
        expect(
          store
              .reduceDurableEvent(
                _huddleEvent(
                  eventId: 'stable-huddle-$index',
                  second: index + 1,
                  state: states[index],
                ),
                onHuddleUpdated: (_) => callbacks += 1,
              )
              .status,
          DurableEventReductionStatus.applied,
        );
      }
      expect(callbacks, states.length);
      await store.close();
    });

    test('accepts legal lifecycle, participant, and replacement transitions',
        () async {
      final store = _seedStore();
      _seedPreparingUpload(store);
      final uploads = store.state.attachmentUploads;
      final unrelatedUpload = uploads['unrelated-upload'];
      final callbacks = <HuddleSessionState>[];
      final states = <Map<String, Object?>>[
        _inactiveHuddle,
        _startingHuddle,
        _activeHuddle,
        _sharingHuddle,
        _twoParticipantHuddle,
        _aliceLeftHuddle,
        _endedHuddle,
        _replacementStartingHuddle,
      ];
      NormalizedSnapshotState? activeSnapshot;
      for (var index = 0; index < states.length; index += 1) {
        final reduction = store.reduceDurableEvent(
          _huddleEvent(
            eventId: 'huddle-${index + 1}',
            second: index + 1,
            state: states[index],
          ),
          onHuddleUpdated: callbacks.add,
        );
        expect(reduction.status, DurableEventReductionStatus.applied);
        if (index == 2) activeSnapshot = store.state;
      }

      expect(callbacks, hasLength(states.length));
      expect(
          store.state.huddles[const ConversationId(_conversationId)]?.toJson(),
          _replacementStartingHuddle);
      expect(
        identical(
          store.state.attachmentUploads['unrelated-upload'],
          unrelatedUpload,
        ),
        isTrue,
      );
      expect(
        (activeSnapshot!.huddles[const ConversationId(_conversationId)]
                as ActiveHuddleState)
            .participants,
        hasLength(1),
      );
      expect(() => store.state.huddles.clear(), throwsUnsupportedError);
      expect(
        () => (store.state.huddles[const ConversationId(_conversationId)]
                as StartingHuddleState)
            .participants
            .add(HuddleJoinedParticipant(
              userId: const UserId('user-x'),
              joinedAt: const IsoTimestamp('2030-01-01T00:00:09.000Z'),
            )),
        throwsUnsupportedError,
      );

      final accepted = store.state;
      expect(
        store
            .reduceDurableEvent(
              _huddleEvent(
                eventId: 'huddle-8',
                second: 8,
                state: _replacementStartingHuddle,
              ),
              onHuddleUpdated: callbacks.add,
            )
            .status,
        DurableEventReductionStatus.duplicate,
      );
      expect(callbacks, hasLength(states.length));
      expect(identical(store.state, accepted), isTrue);
      expect(
        store
            .reduceDurableEvent(_huddleEvent(
              eventId: 'huddle-stale',
              second: 2,
              state: _startingHuddle,
            ))
            .status,
        DurableEventReductionStatus.stale,
      );
      expect(identical(store.state, accepted), isTrue);
      await store.close();
    });

    test('accepts a renewed participant join and ignores its duplicate replay',
        () async {
      final store = _activeHuddleStore();
      addTearDown(store.close);
      final leftEvent = _huddleEvent(
        eventId: 'alice-left-before-renewed-join',
        second: 4,
        state: _aliceOnlyLeftHuddle,
      );
      expect(store.reduceDurableEvent(leftEvent).status,
          DurableEventReductionStatus.applied);
      final beforeRejoin = store.state;
      final leftHuddle = beforeRejoin
          .huddles[const ConversationId(_conversationId)] as ActiveHuddleState;
      final leftParticipant =
          leftHuddle.participants.single as HuddleLeftParticipant;
      expect(beforeRejoin.latestReplayCursor?.eventId, leftEvent.eventId);

      const renewedJoinedAt = '2030-01-01T00:00:05.000Z';
      expect(
        DateTime.parse(renewedJoinedAt)
            .isAfter(DateTime.parse(leftParticipant.leftAt.value)),
        isTrue,
      );
      final rejoinEvent = _huddleEvent(
        eventId: 'alice-renewed-join',
        second: 5,
        state: {
          ..._activeHuddle,
          'participants': <Object?>[
            {..._aliceJoined, 'joinedAt': renewedJoinedAt},
          ],
        },
      );
      final callbacks = <HuddleSessionState>[];

      final reduction = store.reduceDurableEvent(
        rejoinEvent,
        onHuddleUpdated: callbacks.add,
      );

      expect(reduction.status, DurableEventReductionStatus.applied);
      final accepted = store.state;
      final canonical = accepted.huddles[const ConversationId(_conversationId)]
          as ActiveHuddleState;
      expect(canonical.participants.single, isA<HuddleJoinedParticipant>());
      expect(canonical.participants.single.status, HuddleParticipantStatus.joined);
      expect(canonical.participants.single.userId, const UserId('user-alice'));
      expect(canonical.participants.single.joinedAt.value, renewedJoinedAt);
      expect(accepted.latestReplayCursor?.eventId, rejoinEvent.eventId);
      expect(identical(accepted, beforeRejoin), isFalse);
      expect(callbacks, hasLength(1));
      expect(identical(callbacks.single, canonical), isTrue);

      final duplicate = store.reduceDurableEvent(
        rejoinEvent,
        onHuddleUpdated: callbacks.add,
      );

      expect(duplicate.status, DurableEventReductionStatus.duplicate);
      expect(identical(store.state, accepted), isTrue);
      expect(
        identical(store.state.latestReplayCursor, accepted.latestReplayCursor),
        isTrue,
      );
      expect(identical(store.state.durableStreams, accepted.durableStreams),
          isTrue);
      expect(callbacks, hasLength(1));
    });

    test(
        'rejects missing baselines, illegal sessions, and participant rewrites',
        () async {
      final missingConversation = NormalizedSnapshotStore();
      expect(
        () => missingConversation.reduceDurableEvent(_huddleEvent(
          eventId: 'missing-conversation',
          second: 1,
          state: _inactiveHuddle,
        )),
        throwsA(_recovery(DurableEventRecoveryReason.eventGap)),
      );
      await missingConversation.close();

      final missingBaseline = _seedStore();
      expect(
        () => missingBaseline.reduceDurableEvent(_huddleEvent(
          eventId: 'missing-huddle-baseline',
          second: 1,
          state: _activeHuddle,
        )),
        throwsA(_recovery(DurableEventRecoveryReason.eventGap)),
      );
      await missingBaseline.close();

      final invalidStates = <Map<String, Object?>>[
        _inactiveHuddle,
        {
          ..._activeHuddle,
          'huddleSessionId': 'huddle-replaced-illegally',
        },
        {
          ..._activeHuddle,
          'participants': <Object?>[],
        },
        {
          ..._activeHuddle,
          'participants': <Object?>[
            {
              ...(_activeHuddle['participants']! as List<Object?>).single
                  as Map<String, Object?>,
              'joinedAt': '2030-01-01T00:00:03.000Z',
            },
          ],
        },
        {
          ..._activeHuddle,
          'participants': <Object?>[
            ..._activeHuddle['participants']! as List<Object?>,
            {
              'userId': 'user-new',
              'status': 'left',
              'joinedAt': '2030-01-01T00:00:03.000Z',
              'leftAt': '2030-01-01T00:00:04.000Z',
            },
          ],
        },
      ];
      for (var index = 0; index < invalidStates.length; index += 1) {
        final store = _activeHuddleStore();
        final before = store.state;
        final cursor = before.latestReplayCursor;
        final streams = before.durableStreams;
        final pendingUpload = before.attachmentUploads['unrelated-upload'];
        var callbacks = 0;
        expect(
          () => store.reduceDurableEvent(
            _huddleEvent(
              eventId: 'invalid-huddle-$index',
              second: 4,
              state: invalidStates[index],
            ),
            onHuddleUpdated: (_) => callbacks += 1,
          ),
          throwsA(_recovery(DurableEventRecoveryReason.eventInvalid)),
        );
        expect(identical(store.state, before), isTrue);
        expect(identical(store.state.latestReplayCursor, cursor), isTrue);
        expect(identical(store.state.durableStreams, streams), isTrue);
        expect(
          identical(
            store.state.attachmentUploads['unrelated-upload'],
            pendingUpload,
          ),
          isTrue,
        );
        expect(callbacks, 0);
        await store.close();
      }

      final leftStore = _activeHuddleStore();
      leftStore.reduceDurableEvent(_huddleEvent(
        eventId: 'alice-left',
        second: 4,
        state: _aliceOnlyLeftHuddle,
      ));
      final beforeRejoin = leftStore.state;
      expect(
        () => leftStore.reduceDurableEvent(_huddleEvent(
          eventId: 'alice-rejoined',
          second: 5,
          state: _activeHuddle,
        )),
        throwsA(_recovery(DurableEventRecoveryReason.eventInvalid)),
      );
      expect(identical(leftStore.state, beforeRejoin), isTrue);
      await leftStore.close();

      final endedStore = _activeHuddleStore();
      endedStore.reduceDurableEvent(_huddleEvent(
        eventId: 'ended-for-replacement',
        second: 4,
        state: <String, Object?>{
          ..._endedHuddle,
          'participants': <Object?>[_aliceLeft],
        },
      ));
      final endedBefore = endedStore.state;
      expect(
        () => endedStore.reduceDurableEvent(_huddleEvent(
          eventId: 'invalid-session-reuse',
          second: 5,
          state: <String, Object?>{
            ..._replacementStartingHuddle,
            'huddleSessionId': 'huddle-1',
          },
        )),
        throwsA(_recovery(DurableEventRecoveryReason.eventInvalid)),
      );
      expect(identical(endedStore.state, endedBefore), isTrue);
      await endedStore.close();
    });

    test('client settlement prevents an older command response from winning',
        () async {
      final response = Completer<HandrailChatHttpResponse>();
      final client = HandrailChatClient(
        apiBaseUri: Uri.parse('https://chat.example.test/api/chat'),
        tokenProvider: () async => 'token',
        transport: _FakeTransport((_) => response.future),
        generateIdempotencyKey: () => 'huddle-command-1',
        huddleClock: () => DateTime.utc(2030),
      );
      _seedClient(client);
      client.reduceDurableEvent(_huddleEvent(
        eventId: 'client-inactive',
        second: 1,
        state: _inactiveHuddle,
      ));
      final controller = client.huddles.forConversation(
        const ConversationId(_conversationId),
      );
      final command = controller.start();
      await Future<void>.delayed(Duration.zero);
      client.reduceDurableEvent(_huddleEvent(
        eventId: 'client-starting',
        second: 2,
        state: _startingHuddle,
      ));
      client.reduceDurableEvent(_huddleEvent(
        eventId: 'client-active',
        second: 3,
        state: _activeHuddle,
      ));
      response.complete(_commandResponse(_startingHuddle));

      final result = await command as ChatHuddleActionSuccess;
      expect(result.applied, isFalse);
      expect(controller.state.canonicalState, isA<ActiveHuddleState>());
      expect(
        client.normalizedState.state
            .huddles[const ConversationId(_conversationId)],
        isA<ActiveHuddleState>(),
      );
      expect(controller.state.pendingOperation, isNull);
      await client.dispose();
    });
  });
}

Matcher _recovery(DurableEventRecoveryReason reason) =>
    isA<DurableEventReductionError>()
        .having((error) => error.diagnostic.reason, 'reason', reason);

NormalizedSnapshotStore _seedStore({
  bool withAttachment = false,
  ConversationListSnapshot? conversationList,
}) {
  final store = NormalizedSnapshotStore();
  store.hydrateConversationList(conversationList ?? _conversationList());
  store.hydrateMessageTimeline(_timeline(withAttachment: withAttachment));
  return store;
}

NormalizedSnapshotStore _activeHuddleStore() {
  final store = _seedStore();
  _seedPreparingUpload(store);
  for (final entry in <(String, int, Map<String, Object?>)>[
    ('inactive', 1, _inactiveHuddle),
    ('starting', 2, _startingHuddle),
    ('active', 3, _activeHuddle),
  ]) {
    store.reduceDurableEvent(_huddleEvent(
      eventId: entry.$1,
      second: entry.$2,
      state: entry.$3,
    ));
  }
  return store;
}

void _seedClient(HandrailChatClient client) {
  client.normalizedState.hydrateConversationList(_conversationList());
  client.normalizedState.hydrateMessageTimeline(_timeline());
}

ConversationListSnapshot _conversationList() =>
    ConversationListSnapshot.fromJson({
      'kind': 'conversation_list',
      'scope': {'type': 'organization'},
      'items': [
        _conversationSummary(_conversationId, 1),
        _conversationSummary(_otherConversationId, 0),
      ],
      'page': <String, Object?>{},
      '_meta': _metadata,
    });

Map<String, Object?> _conversationSummary(String id, int sequence) => {
      'id': id,
      'tenantId': _tenantId,
      'type': 'channel',
      'name': id,
      'visibility': 'public',
      'createdAt': _baseTime,
      'updatedAt': _baseTime,
      'latestSequence': sequence,
      'activityAt': _baseTime,
      'unreadMentionCount': 0,
      'currentMember': {
        'tenantId': _tenantId,
        'conversationId': id,
        'userId': _userId,
        'role': 'member',
        'state': 'active',
        'joinedAt': _baseTime,
        'updatedAt': _baseTime,
      },
      'currentReadState': {
        'conversationId': id,
        'userId': _userId,
        'lastReadSequence': 0,
        'updatedAt': _baseTime,
      },
      'currentPreference': {
        'conversationId': id,
        'userId': _userId,
        'notificationPreference': 'mentions',
        'isStarred': false,
        'mute': {'muted': false},
        'updatedAt': _baseTime,
      },
      'activeMemberUserIds': [_userId],
    };

MessageTimelinePage _timeline({
  bool withAttachment = false,
  bool withSecondMessage = false,
}) =>
    MessageTimelinePage.fromJson(
      {
        'conversationId': _conversationId,
        'messages': [
          for (final id in [_messageId, if (withSecondMessage) 'message-2'])
          {
            'id': id,
            'tenantId': _tenantId,
            'conversationId': _conversationId,
            'author': {'type': 'user', 'userId': _userId},
            'sequence': id == _messageId ? 1 : 2,
            'createdAt': _baseTime,
            'updatedAt': _baseTime,
            'revision': {'revision': 1},
            'content': {
              'format': 'markdown',
              'text': 'Message',
              if (withAttachment)
                'attachments': [
                  {'attachmentId': _attachmentId},
                ],
            },
            'isThreadRoot': false,
            'reactions': <Object?>[],
            'attachmentMetadata':
                withAttachment ? <Object?>[_attachmentMetadata()] : <Object?>[],
          },
        ],
        'pagination': {
          'older': {'available': false},
          'newer': {'available': false},
        },
        'replay': {
          'resumeFrom': {'eventId': 'snapshot'},
        },
      },
      request: MessageTimelineRequest.fromJson({
        'conversationId': _conversationId,
        'direction': 'backward',
        'limit': 20,
      }),
    );

void _seedPreparingUpload(NormalizedSnapshotStore store) {
  store.reconcileAttachmentUpload(ChatAttachmentUploadState(
    uploadId: 'unrelated-upload',
    conversationId: const ConversationId(_otherConversationId),
    metadata: _uploadMetadata,
    status: ChatAttachmentUploadStatus.preparing,
    uploadedBytes: 0,
  ));
}

void _seedPendingUpload(NormalizedSnapshotStore store) {
  store.reconcileAttachmentUpload(ChatAttachmentUploadState(
    uploadId: 'upload-1',
    conversationId: const ConversationId(_conversationId),
    metadata: _uploadMetadata,
    status: ChatAttachmentUploadStatus.preparing,
    uploadedBytes: 0,
  ));
  store.reconcileAttachmentUpload(ChatAttachmentUploadState(
    uploadId: 'upload-1',
    conversationId: const ConversationId(_conversationId),
    metadata: _uploadMetadata,
    status: ChatAttachmentUploadStatus.pending,
    uploadedBytes: 0,
    attachment: AttachmentLifecycleState.fromJson(_pendingAttachment),
  ));
}

final _uploadMetadata = AttachmentMetadata(
  fileName: 'invoice.pdf',
  contentType: 'application/pdf',
  sizeBytes: 42,
);

const _pendingAttachment = <String, Object?>{
  'status': 'pending',
  'attachmentId': _attachmentId,
  'metadata': {
    'fileName': 'invoice.pdf',
    'contentType': 'application/pdf',
    'sizeBytes': 42,
  },
  'createdAt': '2026-08-26T15:00:00.000Z',
  'expiresAt': '2026-08-26T15:05:00.000Z',
};

final _finalizedAttachment = <String, Object?>{
  ..._pendingAttachment,
  'status': 'finalized',
  'checksum':
      'sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
  'finalizedAt': '2026-08-26T15:01:00.000Z',
};

Map<String, Object?> _attachmentMetadata({bool enriched = false}) => {
      'attachmentId': _attachmentId,
      'fileName': 'invoice.pdf',
      'contentType': 'application/pdf',
      'sizeBytes': 42,
      'downloadUrl': 'https://chat.example/attachment-1',
      if (enriched) ...{
        'previewUrl': 'https://chat.example/attachment-1/preview',
        'width': 640,
        'height': 480,
        'altText': 'Invoice preview',
      },
    };

Map<String, Object?> _canonicalPreference(String occurredAt,
        {bool isStarred = true}) =>
    {
      'notificationPreference': 'mentions',
      'isStarred': isStarred,
      'mute': {'muted': false},
      'updatedAt': occurredAt,
    };

KnownDurableEvent _savedMessageEvent({
  required String eventId,
  required String occurredAt,
  String messageId = _messageId,
  int revision = 1,
  String actorUserId = _userId,
  Map<String, Object?>? savedMessage,
}) =>
    KnownDurableEvent.fromJson({
      'eventId': eventId,
      'protocolVersion': handrailChatDurableEventProtocolVersion,
      'tenantId': _tenantId,
      'streamId': 'user:$actorUserId',
      'type': 'saved_message.updated',
      'occurredAt': occurredAt,
      'payload': {
        'operation': 'set_saved_message',
        'messageId': messageId,
        'savedMessageRevision': revision,
        'savedMessage': savedMessage ?? {'messageId': messageId, 'isSaved': true},
      },
    }, trustedIdentity: DurableEventTrustedIdentity(
      tenantId: const TenantId(_tenantId),
      userId: UserId(actorUserId),
    ));

KnownDurableEvent _membershipEvent({
  required String eventId,
  required String occurredAt,
  required int revision,
  required String intent,
  required String memberState,
  String memberUserId = _userId,
  String? streamId,
  String? trustedUserId,
  List<Map<String, Object?>> otherMembers = const [],
}) {
  final input = <String, Object?>{
    'operation': 'mutate_conversation_membership',
    'intent': intent,
    'conversationId': _conversationId,
    'expectedMemberListRevision': revision - 1,
    'idempotencyKey': eventId,
    if (intent == 'remove_member') 'targetUserId': memberUserId,
  };
  return KnownDurableEvent.fromJson({
    'eventId': eventId,
    'protocolVersion': handrailChatDurableEventProtocolVersion,
    'tenantId': _tenantId,
    'streamId': streamId ?? 'user:$memberUserId',
    'type': 'conversation.membership.updated',
    'occurredAt': occurredAt,
    'payload': {
      'input': input,
      'result': {
        for (final entry in input.entries)
          if (entry.key != 'idempotencyKey') entry.key: entry.value,
        'reconciliationStatus': 'applied',
        'memberListRevision': revision,
        'memberUserId': memberUserId,
        'members': [
          ...otherMembers,
          {
            'userId': memberUserId,
            'role': 'member',
            'state': memberState,
            'joinedAt': _baseTime,
            'updatedAt': occurredAt,
          },
        ],
      },
    },
  },
      trustedIdentity: DurableEventTrustedIdentity(
        tenantId: const TenantId(_tenantId),
        userId: UserId(trustedUserId ?? memberUserId),
      ));
}

KnownDurableEvent _readEvent({
  required String eventId,
  required String conversationId,
  required String occurredAt,
  required String updatedAt,
  required int lastReadSequence,
  String actorUserId = _userId,
  int? manualUnreadFromSequence,
}) =>
    KnownDurableEvent.fromJson({
      'eventId': eventId,
      'protocolVersion': handrailChatDurableEventProtocolVersion,
      'tenantId': _tenantId,
      'streamId': 'user:$actorUserId',
      'type': 'conversation.read_cursor_updated',
      'occurredAt': occurredAt,
      'payload': {
        'kind': 'conversation_read_cursor',
        'actorUserId': actorUserId,
        'operation': manualUnreadFromSequence == null ? 'mark_read' : 'mark_unread',
        'reconciliationStatus': 'applied',
        'conversationId': conversationId,
        'readState': {
          'conversationId': conversationId,
          'userId': actorUserId,
          'lastReadSequence': lastReadSequence,
          if (manualUnreadFromSequence != null)
            'manualUnreadFromSequence': manualUnreadFromSequence,
          'updatedAt': updatedAt,
        },
        'latestSequence': 2,
        'unreadCount': manualUnreadFromSequence == null
            ? 2 - lastReadSequence
            : 2 - manualUnreadFromSequence + 1,
      },
    }, trustedIdentity: DurableEventTrustedIdentity(
      tenantId: const TenantId(_tenantId),
      userId: UserId(actorUserId),
    ));

KnownDurableEvent _preferenceEvent({
  required String eventId,
  required String conversationId,
  required String occurredAt,
  int revision = 1,
  bool isStarred = true,
  String actorUserId = _userId,
}) {
  final preference = _canonicalPreference(occurredAt, isStarred: isStarred);
  final requested = {...preference}..remove('updatedAt');
  final input = {
    'operation': 'update_conversation_preference',
    'conversationId': conversationId,
    'expectedPreferenceRevision': revision - 1,
    'idempotencyKey': eventId,
    ...requested,
  };
  return KnownDurableEvent.fromJson(
    {
      'eventId': eventId,
      'protocolVersion': handrailChatDurableEventProtocolVersion,
      'tenantId': _tenantId,
      'streamId': 'user:$actorUserId',
      'type': 'conversation.preference.updated',
      'occurredAt': occurredAt,
      'payload': {
        'actorUserId': actorUserId,
        'input': input,
        'result': {
          'operation': 'update_conversation_preference',
          'reconciliationStatus': 'applied',
          'conversationId': conversationId,
          'expectedPreferenceRevision': revision - 1,
          'idempotencyKey': eventId,
          'requestedPreference': requested,
          'preferenceRevision': revision,
          'preference': preference,
        },
      },
    },
    trustedIdentity: DurableEventTrustedIdentity(
      tenantId: const TenantId(_tenantId),
      userId: UserId(actorUserId),
    ),
  );
}

KnownDurableEvent _draftEvent({
  required String eventId,
  required String conversationId,
  required String occurredAt,
  int revision = 1,
  bool clear = false,
  String actorUserId = _userId,
}) {
  final input = {
    ...(clear ? clearDraftInputFixture : replaceDraftInputFixture),
    'conversationId': conversationId,
    'baseRevision': revision - 1,
    'deviceMutationId': 'device:$eventId',
    'idempotencyKey': eventId,
  };
  final result = {
    ...settledDraftResultFixture(input),
    'canonicalUpdatedAt': occurredAt,
  };
  return KnownDurableEvent.fromJson(
    {
      ...draftUpdatedEventFixture(input, result),
      'eventId': eventId,
      'protocolVersion': handrailChatDurableEventProtocolVersion,
      'streamId': 'user:$actorUserId',
      'occurredAt': occurredAt,
      'payload': {'actorUserId': actorUserId, 'input': input, 'result': result},
    },
    trustedIdentity: DurableEventTrustedIdentity(
      tenantId: const TenantId(_tenantId),
      userId: UserId(actorUserId),
    ),
  );
}

KnownDurableEvent _attachmentEvent({
  required String eventId,
  required int second,
  required Map<String, Object?> attachment,
  String messageId = _messageId,
}) =>
    _event(
      type: 'attachment.updated',
      eventId: eventId,
      second: second,
      payload: {
        'conversationId': _conversationId,
        'messageId': messageId,
        'attachment': attachment,
      },
    );

KnownDurableEvent _huddleEvent({
  required String eventId,
  required int second,
  required Map<String, Object?> state,
}) =>
    _event(
      type: 'huddle.updated',
      eventId: eventId,
      second: second,
      payload: {'state': state},
    );

KnownDurableEvent _event({
  required String type,
  required String eventId,
  required int second,
  required Map<String, Object?> payload,
}) =>
    KnownDurableEvent.fromJson(
      {
        'eventId': eventId,
        'protocolVersion': handrailChatDurableEventProtocolVersion,
        'tenantId': _tenantId,
        'streamId': _conversationId,
        'type': type,
        'occurredAt': _eventTime(second),
        'payload': payload,
      },
      trustedIdentity: DurableEventTrustedIdentity(
        tenantId: const TenantId(_tenantId),
        userId: const UserId(_userId),
      ),
    );

String _eventTime(int second) =>
    '2026-08-26T15:00:${second.toString().padLeft(2, '0')}.000Z';

const _inactiveHuddle = <String, Object?>{
  'status': 'inactive',
  'conversationId': _conversationId,
};

const _startingHuddle = <String, Object?>{
  'status': 'starting',
  'conversationId': _conversationId,
  'huddleSessionId': 'huddle-1',
  'startedAt': '2030-01-01T00:00:01.000Z',
  'participants': <Object?>[],
  'screenShareOwnerUserId': null,
};

const _aliceJoined = <String, Object?>{
  'userId': 'user-alice',
  'status': 'joined',
  'joinedAt': '2030-01-01T00:00:02.000Z',
};

const _bobJoined = <String, Object?>{
  'userId': 'user-bob',
  'status': 'joined',
  'joinedAt': '2030-01-01T00:00:03.000Z',
};

final _aliceLeft = <String, Object?>{
  ..._aliceJoined,
  'status': 'left',
  'leftAt': '2030-01-01T00:00:04.000Z',
};

final _bobLeft = <String, Object?>{
  ..._bobJoined,
  'status': 'left',
  'leftAt': '2030-01-01T00:00:05.000Z',
};

final _activeHuddle = <String, Object?>{
  ..._startingHuddle,
  'status': 'active',
  'participants': <Object?>[_aliceJoined],
};

final _sharingHuddle = <String, Object?>{
  ..._activeHuddle,
  'screenShareOwnerUserId': 'user-alice',
};

final _twoParticipantHuddle = <String, Object?>{
  ..._activeHuddle,
  'participants': <Object?>[_aliceJoined, _bobJoined],
  'screenShareOwnerUserId': 'user-alice',
};

final _aliceLeftHuddle = <String, Object?>{
  ..._activeHuddle,
  'participants': <Object?>[_aliceLeft, _bobJoined],
  'screenShareOwnerUserId': 'user-bob',
};

final _aliceOnlyLeftHuddle = <String, Object?>{
  ..._activeHuddle,
  'participants': <Object?>[_aliceLeft],
  'screenShareOwnerUserId': null,
};

final _endedHuddle = <String, Object?>{
  'status': 'ended',
  'conversationId': _conversationId,
  'huddleSessionId': 'huddle-1',
  'startedAt': '2030-01-01T00:00:01.000Z',
  'endedAt': '2030-01-01T00:00:06.000Z',
  'endedByUserId': 'user-alice',
  'participants': <Object?>[_aliceLeft, _bobLeft],
  'screenShareOwnerUserId': null,
};

final _replacementStartingHuddle = <String, Object?>{
  ..._startingHuddle,
  'huddleSessionId': 'huddle-2',
  'startedAt': '2030-01-01T00:00:07.000Z',
};

const _metadata = <String, Object?>{
  'packageVersion': '0.1.3',
  'protocolVersion': handrailChatDurableEventProtocolVersion,
  'schemaVersion': 9,
  'enabledFeatures': {'huddles': true, conversationSnapshotFeature: true},
  'supportedProtocolRange': {
    'minimumVersion': 1,
    'maximumVersion': handrailChatDurableEventProtocolVersion,
  },
  'feature': {
    'name': conversationSnapshotFeature,
    'version': conversationSnapshotVersion,
  },
};

final class _FakeTransport implements HandrailChatHttpTransport {
  _FakeTransport(this.handler);

  final Future<HandrailChatHttpResponse> Function(HandrailChatHttpRequest)
      handler;

  @override
  Future<HandrailChatHttpResponse> send(HandrailChatHttpRequest request) =>
      handler(request);
}

HandrailChatHttpResponse _commandResponse(Map<String, Object?> state) =>
    HandrailChatHttpResponse(
      statusCode: 200,
      body: jsonEncode({
        'operation': 'start_huddle',
        'outcome': 'ok',
        'reconciliationStatus': 'applied',
        'state': state,
        'mediaJoin': {
          'kind': 'opaque_media_join',
          'descriptor': 'opaque-secret',
          'expiresAt': '2030-01-01T00:04:00.000Z',
        },
      }),
    );
