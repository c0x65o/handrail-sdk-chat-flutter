part of 'main.dart';

/// Two deterministic authenticated fixture actors, with independent saved styles.
enum TimelineLabReplyActor {
  alice(UserId('alice')),
  bob(UserId('bob'));

  const TimelineLabReplyActor(this.userId);
  final UserId userId;
}

const _replyScenarioFeatures = <String, bool>{
  replyStylePreferenceFeature: true,
  ChatReplyThreadFeatures.inlineReplies: true,
  ChatReplyThreadFeatures.namedThreads: true,
  ChatReplyThreadFeatures.threadDiscovery: true,
  ChatReplyThreadFeatures.threadLifecycle: true,
};

/// Opt-in HTTP fixture for production workspace widgets. Keep one instance in
/// the host while recreating [HandrailTimelineLabApp] with a new key/actor.
/// This is deterministic fixture evidence, not a backend or persistence service.
/// Device records use the existing SDK storage adapter and queue, not a lab queue.
final class TimelineLabReplyStyleScenario {
  TimelineLabReplyStyleScenario({ApplicationChatStorage? storage})
      : storage = storage ?? InMemoryApplicationChatStorage();

  static const channelId = _publicChannelId;
  static const discussionId = ConversationId('flutter-reply-discussion');
  static const launchThreadId = ConversationId('flutter-reply-launch-thread');
  static const discussionRootId = MessageId('flutter-reply-discussion-root');
  final ApplicationChatStorage storage;
  int _counter = 0;
  String nextId(String kind) => 'reply-lab-$kind-${++_counter}';

  ApplicationChatStorageIdentity identity(TimelineLabReplyActor actor) =>
      ApplicationChatStorageIdentity(
          tenantId: const TenantId(_tenantId),
          userId: actor.userId,
          deviceId: DeviceId('reply-lab-${actor.name}'));

  final _styles = <TimelineLabReplyActor, ReplyStylePreferenceState>{
    TimelineLabReplyActor.alice:
        SavedReplyStylePreference(revision: 1, style: 'current'),
    TimelineLabReplyActor.bob:
        SavedReplyStylePreference(revision: 1, style: 'discord'),
  };
  final _draftEvents = <(TimelineLabReplyActor, ConversationId),
      ConversationDraftUpdatedEvent>{};
  final _readStates =
      <(TimelineLabReplyActor, ConversationId), ConversationReadState>{};
  final _roots = <ConversationId, MessageId>{discussionId: discussionRootId};
  final _names = <ConversationId, String>{discussionId: 'Launch planning'};
  final _lifecycles = <ConversationId, ThreadLifecycle>{};
  final _follows =
      <(TimelineLabReplyActor, ConversationId), Map<String, Object?>>{};
  final _preferences =
      <(TimelineLabReplyActor, ConversationId), Map<String, Object?>>{};
  final _messages = <ConversationId, List<Map<String, Object?>>>{
    channelId: [
      _messageFixture(
          conversationId: channelId,
          id: discussionRootId.value,
          sequence: 1,
          authorId: 'alice',
          text: 'Plan the launch together.'),
    ],
    discussionId: [
      _messageFixture(
          conversationId: discussionId,
          id: 'flutter-reply-discussion-history',
          sequence: 1,
          authorId: 'bob',
          text: 'The launch checklist stays here.'),
    ],
  };

  ThreadLifecycle _lifecycle(ConversationId id) => _lifecycles.putIfAbsent(
      id, () => ThreadLifecycle.fromJson({'revision': 1, 'locked': false}));

  Map<String, Object?> _follow(
          TimelineLabReplyActor actor, ConversationId id) =>
      _follows.putIfAbsent(
          (actor, id),
          () => {
                'followRevision': 0,
                'follow': null,
              });

  Map<String, Object?> detail(ConversationId id, TimelineLabReplyActor actor) {
    final thread = _roots.containsKey(id);
    final result = thread
        ? _threadConversationDetailFixture(
            threadId: id,
            rootMessageId: _roots[id]!,
            latestSequence: _messages[id]?.length ?? 0)
        : _conversationDetailFixtures[id]!;
    final conversation =
        Map<String, Object?>.from(result['conversation']! as Map);
    conversation['latestSequence'] =
        _messages[id]?.length ?? conversation['latestSequence'];
    conversation['activeMemberUserIds'] = ['alice', 'bob'];
    conversation['memberUserIds'] = ['alice', 'bob'];
    for (final key in [
      'currentMember',
      'currentReadState',
      'currentPreference'
    ]) {
      if (conversation[key] case final Map value) {
        conversation[key] = {
          ...Map<String, Object?>.from(value),
          'userId': actor.userId.value
        };
      }
    }
    if (_readStates[(actor, id)] case final readState?) {
      conversation['currentReadState'] = readState.toJson();
    }
    if (_preferences[(actor, id)] case final preference?) {
      conversation['currentPreference'] = preference;
    }
    if (thread) {
      conversation['threadLifecycle'] = _lifecycle(id).toJson();
      if (_names[id] case final name?) conversation['name'] = name;
    }
    return {
      ...result,
      'conversation': conversation,
    };
  }

  Map<String, Object?> timeline(ConversationId id) =>
      _timelineFixture(id, messages: [
        for (final message in _messages[id] ?? <Map<String, Object?>>[])
          {
            ...message,
            'isThreadRoot':
                _roots.values.any((root) => root.value == message['id']),
            'reactions': const <Object?>[],
            'attachmentMetadata': const <Object?>[],
            if (_roots.entries
                    .where((entry) => entry.value.value == message['id'])
                    .firstOrNull
                case final root?)
              'threadSummary': _threadSummaryFixture(
                  threadId: root.key,
                  replyCount: _messages[root.key]?.length ?? 0,
                  participantIds: ['alice', 'bob']),
          }
      ]);

  HandrailChatHttpResponse? _respond(HandrailChatHttpRequest request,
      TimelineLabReplyActor actor, _TimelineLabTransport transport) {
    final path = request.uri.path;
    final segments = request.uri.pathSegments;
    final body = request.body == null ? null : jsonDecode(request.body!);
    if (request.method == readCursorMutationMethod &&
        path.endsWith('/read-cursor')) {
      final input = ReadCursorMutationInput.fromJson(body);
      final id = input.conversationId;
      final latest = _messages[id]?.length ?? 1;
      final prior = _readStates[(actor, id)];
      final through = input is MarkReadInput
          ? input.throughSequence.value
          : prior?.lastReadSequence.value ?? 0;
      final marker = input is MarkUnreadInput ? input.fromSequence : null;
      final state = ConversationReadState(
          conversationId: id,
          userId: actor.userId,
          lastReadSequence: MessageSequence(through),
          manualUnreadFromSequence: marker,
          updatedAt: const IsoTimestamp(_fixtureTime));
      _readStates[(actor, id)] = state;
      return _jsonResponse(ReadCursorMutationResult(
        operation: input.operation,
        reconciliationStatus: ReadCursorReconciliationStatus.applied,
        idempotencyKey: input.idempotencyKey,
        conversationId: id,
        readState: state,
        latestSequence: MessageSequence(latest),
        unreadCount:
            marker == null ? latest - through : latest - marker.value + 1,
      ).toJson());
    }
    if (request.method == 'PATCH' && path.endsWith('/draft')) {
      final input = SynchronizeDraftInput.fromJson(body);
      final result = SynchronizeDraftResult.fromJson(
          _draftMutationResult(input.toJson()),
          expectedInput: input);
      transport.onDraftUpdated?.call(input.toJson(), result.toJson());
      return _jsonResponse(result.toJson());
    }
    if (path.endsWith('/preferences/reply-style')) {
      if (request.method == 'GET') {
        return _jsonResponse(_styles[actor]!.toJson());
      }
      final input = UpdateReplyStylePreferenceInput.fromJson(body);
      final previous = _styles[actor]!;
      final conflict = input.baseRevision != previous.revision;
      final same = previous.resolvedStyle == input.style;
      if (!conflict && !same) {
        _styles[actor] = SavedReplyStylePreference(
            revision: previous.revision + 1, style: input.style.wireValue);
      }
      return _jsonResponse(
          UpdateReplyStylePreferenceResult.fromJson({
            'operation': 'update_reply_style_preference',
            'reconciliationStatus': conflict
                ? 'preference_revision_conflict'
                : same
                    ? 'already_requested_state'
                    : 'applied',
            'baseRevision': input.baseRevision,
            'idempotencyKey': input.idempotencyKey,
            'requestedStyle': input.style.toJson(),
            'preference': _styles[actor]!.toJson(),
          }, expectedInput: input)
              .toJson(),
          conflict ? 409 : 200);
    }
    if (request.method == 'GET' && path.endsWith('/context')) {
      final input = MessageContextRequest(
          conversationId: ConversationId(segments[segments.length - 4]),
          messageId: MessageId(segments[segments.length - 2]));
      final message = _messages[input.conversationId]
          ?.where((m) => m['id'] == input.messageId.value)
          .firstOrNull;
      return _jsonResponse(MessageContextResult.fromJson({
        ...input.toJson(),
        'status': message == null ? 'unavailable' : 'available',
        if (message != null) ...{
          'sequence': message['sequence'],
          'message': _canonicalMessageFixture(message)
        },
      }, expectedRequest: input)
          .toJson());
    }
    if (request.method == 'GET' && path.endsWith('/threads')) {
      final input = parseThreadListHttpRequest(
          segments[segments.length - 2], request.uri.queryParameters);
      final ids = _roots.keys.toList()
        ..sort((a, b) => a.value.compareTo(b.value));
      final items = <Map<String, Object?>>[];
      if (input.parentConversationId == channelId) {
        for (final id in ids) {
          if (input.cursor != null &&
              id.value.compareTo(decodeThreadListCursor(input.cursor!, input)
                      .threadId
                      .value) <=
                  0) {
            continue;
          }
          if (input.view == 'active' && _lifecycle(id).closedAt != null) {
            continue;
          }
          final summary = Map<String, Object?>.from(
              detail(id, actor)['conversation']! as Map)
            ..remove('memberUserIds')
            ..remove('currentThreadFollow');
          items.add({
            'thread': summary,
            'currentThreadFollow': _follow(actor, id),
            'lastActivityAt': _fixtureTime,
            'hideAt': null
          });
        }
      }
      final page = items.take(input.limit).toList();
      return _jsonResponse(ThreadListResult.fromJson({
        'parentConversationId': input.parentConversationId.value,
        'view': input.view,
        'evaluatedAt': _fixtureTime,
        'lifecycleSupported': true,
        'items': page,
        if (items.length > page.length)
          'nextCursor': encodeThreadListCursor(ThreadListCursorPosition(
            parentConversationId: input.parentConversationId,
            view: input.view,
            createdAt: const IsoTimestamp(_fixtureTime),
            threadId:
                ConversationId((page.last['thread']! as Map)['id']! as String),
          )),
      }, expectedRequest: input)
          .toJson());
    }
    if (request.method == 'POST' && path.endsWith('/thread')) {
      final input = ThreadCreationInput.fromJson(body);
      final existing = _roots.entries
          .where((entry) => entry.value == input.rootMessageId)
          .firstOrNull;
      if (input.parentConversationId != channelId ||
          !_messages[channelId]!
              .any((message) => message['id'] == input.rootMessageId.value) ||
          (existing == null && _roots.containsKey(launchThreadId))) {
        return _jsonResponse({'error': 'outside bounded reply scenario'}, 404);
      }
      final id = existing?.key ?? launchThreadId;
      _roots[id] = input.rootMessageId;
      if (existing == null && input.name != null) _names[id] = input.name!;
      _messages.putIfAbsent(id, () => []);
      return _jsonResponse(
          ThreadCreationResult.fromJson({
            'operation': 'create_thread',
            'reconciliationStatus':
                existing == null ? 'created' : 'existing_for_root',
            'parentConversationId': channelId.value,
            'rootMessageId': input.rootMessageId.value,
            'conversation': detail(id, actor),
            'rootThreadSummary': _threadSummaryFixture(
                threadId: id,
                replyCount: _messages[id]!.length,
                participantIds: ['alice', 'bob']),
          }, expectedInput: input)
              .toJson(),
          existing == null ? 201 : 200);
    }
    if (request.method == 'PATCH' && path.endsWith('/lifecycle')) {
      final input =
          ThreadLifecycleInput.fromHttp(segments[segments.length - 2], body);
      final previous = _lifecycle(input.threadId);
      // Only the close/reopen demonstration is implemented at this HTTP edge.
      if (input.intent != ThreadLifecycleIntent.close &&
          input.intent != ThreadLifecycleIntent.reopen) {
        return _jsonResponse({'error': 'outside close/reopen scenario'}, 422);
      }
      final closing = input.intent == ThreadLifecycleIntent.close;
      final conflict = input.expectedLifecycleRevision != previous.revision;
      final same = closing == (previous.closedAt != null);
      final next = conflict || same
          ? previous
          : ThreadLifecycle.fromJson({
              'revision': previous.revision + 1,
              'locked': false,
              if (closing) ...{
                'closedAt': _fixtureTime,
                'closedByUserId': actor.userId.value
              },
            });
      _lifecycles[input.threadId] = next;
      return _jsonResponse(
          ThreadLifecycleResult(
                  input: input,
                  reconciliationStatus: conflict
                      ? ThreadLifecycleReconciliationStatus.lifecycleConflict
                      : same
                          ? ThreadLifecycleReconciliationStatus
                              .alreadyRequestedState
                          : ThreadLifecycleReconciliationStatus.applied,
                  previousLifecycle: previous,
                  threadLifecycle: next)
              .toJson(),
          conflict ? 409 : 200);
    }
    if (request.method == 'PATCH' && path.endsWith('/follow')) {
      final input = SetThreadFollowInput.fromJson(body);
      final previous = _follow(actor, input.target.id);
      final conflict =
          input.expectedFollowRevision != previous['followRevision'];
      final next = conflict
          ? previous
          : <String, Object?>{
              'followRevision': input.expectedFollowRevision + 1,
              'follow': {
                'target': input.target.toJson(),
                'isFollowing':
                    input.intent == ThreadFollowMutationIntent.follow,
                'source': 'manual',
                'updatedAt': _fixtureTime
              },
            };
      _follows[(actor, input.target.id)] = next;
      return _jsonResponse(
          SetThreadFollowResult.fromJson({
            ...input.toJson(),
            'reconciliationStatus':
                conflict ? 'follow_revision_conflict' : 'applied',
            ...next,
          }, expectedInput: input)
              .toJson(),
          conflict ? 409 : 200);
    }
    if (request.method == 'PATCH' && path.endsWith('/preference')) {
      final input = UpdateConversationPreferenceInput.fromJson(body);
      final next = CanonicalConversationPreferenceState(
          preference: input.preference,
          updatedAt: const IsoTimestamp(_fixtureTime));
      _preferences[(actor, input.conversationId)] = {
        ...next.toJson(),
        'conversationId': input.conversationId.value,
        'userId': actor.userId.value,
      };
      return _jsonResponse(transport
          ._preferenceResult(
              input, ConversationPreferenceReconciliationStatus.applied,
              preferenceRevision: input.expectedPreferenceRevision + 1,
              preference: next)
          .toJson());
    }
    if (request.method == 'GET' && path.endsWith('/conversations')) {
      return _jsonResponse({
        ..._conversationListFixture,
        'items': [
          for (final id in _conversationIds)
            Map<String, Object?>.from(detail(id, actor)['conversation']! as Map)
              ..remove('memberUserIds'),
        ]
      });
    }
    if (request.method == 'GET' && path.endsWith('/messages')) {
      final id = ConversationId(segments[segments.length - 2]);
      if (_messages.containsKey(id)) return _jsonResponse(timeline(id));
    }
    if (request.method == 'GET' && segments.contains('conversations')) {
      final id = ConversationId(segments.last);
      if (_roots.containsKey(id) || _conversationIds.contains(id)) {
        return _jsonResponse(detail(id, actor));
      }
    }
    if (request.method == 'POST' && path.endsWith('/messages')) {
      final input = SendMessageRequest.fromJson(body);
      final messages = _messages[input.conversationId];
      if (messages == null) return null;
      final existing = messages
          .where(
              (message) => message['id'] == 'message-${input.clientMessageId}')
          .firstOrNull;
      if (existing == null && messages.length >= 50) {
        return _jsonResponse(
            {'error': 'reply scenario is limited to 50 messages per stream'},
            422);
      }
      final message = existing ??
          <String, Object?>{
            ..._canonicalMessageFixture(_messageFixture(
                conversationId: input.conversationId,
                id: 'message-${input.clientMessageId}',
                sequence: messages.length + 1,
                authorId: actor.userId.value,
                text: input.content.text)),
            'content': input.content.toJson(),
            if (input.replyTo != null) 'replyTo': input.replyTo!.toJson(),
          };
      if (existing == null) messages.add(message);
      transport.onMessageSent
          ?.call(input.conversationId, message, input.clientMessageId);
      return _jsonResponse(SendMessageResult.fromJson({
        'operation': 'send',
        'reconciliationStatus': existing == null ? 'applied' : 'replayed',
        'clientMessageId': input.clientMessageId,
        'message': message,
        'canonicalRevision': 1,
      }).toJson());
    }
    return null;
  }
}
