import 'dart:convert';
import 'dart:io';

import 'package:handrail_chat/core.dart';
import 'package:test/test.dart';

void main() {
  late Map<String, Object?> fixture;

  setUpAll(() async {
    fixture = _map(jsonDecode(await File(
      'conformance-tests/normalized-reducer-outcomes/fixtures.json',
    ).readAsString()));
  });

  test(
      'shared ordered durable events produce the canonical normalized projection',
      () async {
    final store = _runFixture(fixture);
    addTearDown(store.close);
    expect(_project(store.state), equals(fixture['expected']));
    final restored = NormalizedSnapshotStateStorageCodec.decode(
      NormalizedSnapshotStateStorageCodec.encode(store.state),
    );
    expect(_project(restored), equals(fixture['expected']));

    for (final value in fixture['rejections']! as List<Object?>) {
      final rejection = _map(value);
      final parseAs = _map(rejection['parseAs']);
      final event = KnownDurableEvent.fromJson(
        _roundTrip(rejection['event']),
        trustedIdentity: DurableEventTrustedIdentity(
          tenantId: TenantId(parseAs['tenantId']! as String),
          userId: UserId(parseAs['userId']! as String),
        ),
      );
      final diagnostic = _map(rejection['diagnostic']);
      final before = store.state;
      expect(
        () => store.reduceDurableEvent(event),
        throwsA(
          isA<DurableEventReductionError>()
              .having((error) => error.diagnostic.code.wireValue, 'code',
                  diagnostic['code'])
              .having((error) => error.diagnostic.reason.wireValue, 'reason',
                  diagnostic['reason'])
              .having((error) => error.diagnostic.message, 'message',
                  diagnostic['message']),
        ),
        reason: rejection['id']! as String,
      );
      expect(identical(store.state, before), isTrue,
          reason: '${rejection['id']} must be atomic');
    }
  });

  test('mutating a shared expected revision is detected', () async {
    final store = _runFixture(fixture);
    addTearDown(store.close);
    final actual = _project(store.state);
    final mutated = _map(_roundTrip(fixture['expected']));
    final messages = mutated['messages']! as List<Object?>;
    final first = _map(messages.first);
    first['revision'] = (first['revision']! as int) + 1;
    expect(() => expect(actual, equals(mutated)), throwsA(isA<TestFailure>()));
  });
}

NormalizedSnapshotStore _runFixture(Map<String, Object?> fixture) {
  final identity = _map(fixture['trustedIdentity']);
  final trustedIdentity = DurableEventTrustedIdentity(
    tenantId: TenantId(identity['tenantId']! as String),
    userId: UserId(identity['userId']! as String),
  );
  final store = NormalizedSnapshotStore();
  for (final value in fixture['steps']! as List<Object?>) {
    final step = _map(value);
    final before = store.state;
    final event = KnownDurableEvent.fromJson(
      _roundTrip(step['event']),
      trustedIdentity: trustedIdentity,
    );
    late final DurableEventReduction reduction;
    try {
      reduction = store.reduceDurableEvent(event);
    } on DurableEventReductionError catch (error) {
      fail('${event.eventId}: ${error.diagnostic.message}');
    }
    expect(reduction.status.name, step['expectedStatus'],
        reason: event.eventId);
    if (reduction.status != DurableEventReductionStatus.applied) {
      expect(identical(store.state, before), isTrue, reason: event.eventId);
    }
  }
  return store;
}

Map<String, Object?> _project(NormalizedSnapshotState state) {
  final conversations = state.conversations.entries.toList()
    ..sort((left, right) => left.key.value.compareTo(right.key.value));
  final memberships = state.membersByConversation.entries.toList()
    ..sort((left, right) => left.key.value.compareTo(right.key.value));
  final timelines = state.timelines.entries.toList()
    ..sort((left, right) => left.key.value.compareTo(right.key.value));
  final messages = state.messages.entries.toList()
    ..sort((left, right) => left.key.value.compareTo(right.key.value));
  final reads = state.currentUserReadStates.entries.toList()
    ..sort((left, right) => left.key.value.compareTo(right.key.value));
  final preferences = state.currentUserPreferences.entries.toList()
    ..sort((left, right) => left.key.value.compareTo(right.key.value));
  final follows = state.currentUserThreadFollows.entries.toList()
    ..sort((left, right) => left.key.value.compareTo(right.key.value));
  final saved = state.currentUserSavedMessages.entries.toList()
    ..sort((left, right) => left.key.value.compareTo(right.key.value));
  final reminders = state.currentUserMessageReminders.entries.toList()
    ..sort((left, right) => left.key.value.compareTo(right.key.value));
  final drafts = state.currentUserDrafts.entries.toList()
    ..sort((left, right) => left.key.value.compareTo(right.key.value));
  final attachments = state.attachments.entries.toList()
    ..sort((left, right) => left.key.value.compareTo(right.key.value));
  final huddles = state.huddles.entries.toList()
    ..sort((left, right) => left.key.value.compareTo(right.key.value));

  return {
    'cursorEventId': state.latestReplayCursor?.eventId,
    'conversations': [
      for (final entry in conversations)
        {
          'id': entry.key.value,
          'type': entry.value.type.toJson(),
          'visibility': entry.value.visibility.toJson(),
          if (entry.value is ThreadConversation) ...{
            'parentConversationId':
                (entry.value as ThreadConversation).parentConversationId.value,
            'rootMessageId':
                (entry.value as ThreadConversation).rootMessageId.value,
          },
        },
    ],
    'memberships': [
      for (final entry in memberships)
        {
          'conversationId': entry.key.value,
          'revision': state.memberListRevisions[entry.key],
          'userIds': (state.memberUserIdsByConversation[entry.key]!
              .map((id) => id.value)
              .toList()
            ..sort()),
          'members': (entry.value.values
              .map((member) => {
                    'userId': member.userId.value,
                    'role': member.role,
                    'state': member.state,
                  })
              .toList()
            ..sort(
                (left, right) => left['userId']!.compareTo(right['userId']!))),
        },
    ],
    'timelines': [
      for (final entry in timelines)
        {
          'conversationId': entry.key.value,
          'messageIds': entry.value.messageIds.map((id) => id.value).toList(),
        },
    ],
    'messages': [
      for (final entry in messages) _projectMessage(entry.value),
    ],
    'readStates': [
      for (final entry in reads)
        {
          'conversationId': entry.key.value,
          'userId': entry.value.userId.value,
          'lastReadSequence': entry.value.lastReadSequence.value,
        },
    ],
    'preferences': [
      for (final entry in preferences)
        {
          'conversationId': entry.key.value,
          'userId': entry.value.userId.value,
          'revision': state.preferenceRevisions[entry.key],
          'notificationPreference': entry.value.notificationPreference,
          'isStarred': entry.value.isStarred,
          'muted': entry.value.mute.muted,
        },
    ],
    'threadFollows': [
      for (final entry in follows)
        {
          'threadId': entry.key.value,
          'revision': state.threadFollowRevisions[entry.key],
          'isFollowing': entry.value.isFollowing,
          'source': entry.value.source.toJson(),
        },
    ],
    'savedMessages': [
      for (final entry in saved)
        {
          'messageId': entry.key.value,
          'revision': state.savedMessageRevisions[entry.key],
          'isSaved': entry.value.isSaved,
          if (entry.value.privateNote != null)
            'privateNote': entry.value.privateNote,
        },
    ],
    'messageReminders': [
      for (final entry in reminders)
        {
          'conversationId':
              state.messageReminderConversationIds[entry.key]!.value,
          'messageId': entry.key.value,
          'revision': state.messageReminderRevisions[entry.key],
          'state': entry.value.state,
          if (entry.value is CanonicalScheduledMessageReminder)
            'dueAt':
                (entry.value as CanonicalScheduledMessageReminder).dueAt.value,
        },
    ],
    'drafts': [
      for (final entry in drafts)
        {
          'conversationId': entry.key.value,
          'revision': state.draftRevisions[entry.key],
          'kind': entry.value.kind,
          if (entry.value is CanonicalReplacedDraft)
            'text': (entry.value as CanonicalReplacedDraft).content.text,
        },
    ],
    'attachments': [
      for (final entry in attachments)
        {
          'attachmentId': entry.key.value,
          'fileName': entry.value.fileName,
          'contentType': entry.value.contentType,
          'sizeBytes': entry.value.sizeBytes,
        },
    ],
    'huddles': [
      for (final entry in huddles)
        {
          'conversationId': entry.key.value,
          'status': entry.value.status.name,
        },
    ],
  };
}

Map<String, Object?> _projectMessage(MessageTimelineMessage message) {
  final summary = message.threadSummary;
  final reactions = [...message.reactions]
    ..sort((left, right) => left.reactionKey.compareTo(right.reactionKey));
  return {
    'id': message.id.value,
    'conversationId': message.conversationId.value,
    'sequence': message.sequence.value,
    'revision': message.revision.revision,
    'deleted': message.content == null,
    'isThreadRoot': message.isThreadRoot,
    if (summary != null)
      'threadSummary': {
        'threadId': summary.threadId.value,
        'replyCount': summary.replyCount,
        'participantIds': (summary.participantIds.map((id) => id.value).toList()
          ..sort()),
        'unreadCount': summary.unreadCount,
        if (summary.lastReplyAt != null)
          'lastReplyAt': summary.lastReplyAt!.value,
      },
    'reactions': [
      for (final reaction in reactions)
        {
          'reactionKey': reaction.reactionKey,
          'count': reaction.count,
          'reactedByCurrentUser': reaction.reactedByCurrentUser,
        },
    ],
    'attachmentIds': (message.attachmentMetadata
        .map((attachment) => attachment.attachmentId.value)
        .toList()
      ..sort()),
  };
}

Object? _roundTrip(Object? value) => jsonDecode(jsonEncode(value));
Map<String, Object?> _map(Object? value) =>
    (value! as Map).cast<String, Object?>();
