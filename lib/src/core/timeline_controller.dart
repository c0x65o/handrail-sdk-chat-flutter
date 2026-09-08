import 'dart:async';

import '../generated/conversation.dart';
import '../generated/conversation_snapshot.dart';
import '../generated/delete_message.dart';
import '../generated/edit_message.dart';
import '../generated/ephemeral_signals.dart';
import '../generated/forward_message.dart';
import '../generated/identifiers.dart';
import '../generated/message.dart';
import '../generated/message_context.dart';
import '../generated/message_reminder.dart';
import '../generated/message_timeline.dart';
import '../generated/read_cursor_mutation.dart';
import '../generated/reaction_mutations.dart';
import '../generated/realtime_session.dart';
import '../generated/send_message.dart';
import '../realtime_session_transport.dart';
import '../handrail_chat_client.dart';
import 'command_dispatcher.dart';
import 'normalized_snapshot_state.dart';

/// Stable lifecycle outcomes for a headless message timeline.
enum ChatTimelineControllerStatus {
  loading,
  ready,
  error,
  accessRevoked,
  disposed,
}

/// Stable, non-sensitive failure categories surfaced by a timeline.
enum ChatTimelineControllerErrorCode {
  authentication,
  rejected,
  malformedResponse,
  transport,
  aborted,
  closed,
  realtimeRejected,
  normalization,
  disposed,
}

/// Immutable controller failure details without request bodies or credentials.
final class ChatTimelineControllerError {
  const ChatTimelineControllerError({
    required this.code,
    required this.message,
    this.httpStatus,
    this.realtimeCode,
  });

  final ChatTimelineControllerErrorCode code;
  final String message;
  final int? httpStatus;
  final ChatRealtimeSubscriptionErrorCode? realtimeCode;

  @override
  bool operator ==(Object other) =>
      other is ChatTimelineControllerError &&
      other.code == code &&
      other.message == message &&
      other.httpStatus == httpStatus &&
      other.realtimeCode == realtimeCode;

  @override
  int get hashCode => Object.hash(code, message, httpStatus, realtimeCode);
}

/// One immutable, framework-neutral projection of an ascending timeline.
final class ChatTimelineControllerState {
  ChatTimelineControllerState._({
    required this.status,
    required this.conversationId,
    required this.conversation,
    required List<MessageTimelineMessage> messages,
    required this.older,
    required this.newer,
    required this.currentUserReadState,
    required this.unreadBoundary,
    required this.firstUnreadMessage,
    required List<TypingSignalEvent> typingSignals,
    required List<UserId> typingUserIds,
    required this.error,
  })  : messages = List.unmodifiable(messages),
        typingSignals = List.unmodifiable(typingSignals),
        typingUserIds = List.unmodifiable(typingUserIds);

  factory ChatTimelineControllerState.initial(ConversationId conversationId) =>
      ChatTimelineControllerState._(
        status: ChatTimelineControllerStatus.loading,
        conversationId: conversationId,
        conversation: null,
        messages: const [],
        older: const MessageTimelineBoundary.unavailable(),
        newer: const MessageTimelineBoundary.unavailable(),
        currentUserReadState: null,
        unreadBoundary: null,
        firstUnreadMessage: null,
        typingSignals: const [],
        typingUserIds: const [],
        error: null,
      );

  final ChatTimelineControllerStatus status;
  final ConversationId conversationId;

  /// The public conversation projection when it has already been hydrated.
  final Conversation? conversation;

  /// Ascending message projections from the public normalized store.
  final List<MessageTimelineMessage> messages;
  final MessageTimelineBoundary older;
  final MessageTimelineBoundary newer;
  final ConversationSnapshotReadState? currentUserReadState;

  /// First unread sequence, including a server-managed manual-unread marker.
  final MessageSequence? unreadBoundary;

  /// The first unread row when that exact sequence is currently hydrated.
  final MessageTimelineMessage? firstUnreadMessage;

  /// Live conversation-scoped typing signals and their distinct actors.
  final List<TypingSignalEvent> typingSignals;
  final List<UserId> typingUserIds;
  final ChatTimelineControllerError? error;

  bool get isLoading => status == ChatTimelineControllerStatus.loading;
  bool get isReady => status == ChatTimelineControllerStatus.ready;
  bool get isDisposed => status == ChatTimelineControllerStatus.disposed;
  bool get hasEarlier => older.available;
  bool get hasNewer => newer.available;
  MessageTimelineBoundary get olderBoundary => older;
  MessageTimelineBoundary get newerBoundary => newer;
  MessageTimelinePagination get pagination =>
      MessageTimelinePagination(older: older, newer: newer);

  /// Alias matching the normalized read selector's terminology.
  MessageSequence? get firstUnreadSequence => unreadBoundary;

  /// Short alias useful to custom view-model bindings.
  List<TypingSignalEvent> get typing => typingSignals;
  List<UserId> get typingUsers => typingUserIds;
}

/// One explicit non-stream retain on a [ChatTimelineController].
///
/// Releasing is idempotent. The final observer or retain releases the
/// controller's single realtime conversation subscription.
final class ChatTimelineRetainHandle {
  ChatTimelineRetainHandle._(void Function() release) : _release = release;

  final void Function() _release;
  bool _released = false;

  bool get isReleased => _released;

  void release() {
    if (_released) return;
    _released = true;
    _release();
  }
}

typedef ChatTimelineRetention = ChatTimelineRetainHandle;

/// Stable client-owned registry for per-conversation timelines.
final class ChatTimelineControllers {
  ChatTimelineControllers._(this._client);

  final HandrailChatClient _client;
  final Map<ConversationId, ChatTimelineController> _controllers = {};
  bool _disposed = false;

  ChatTimelineController forConversation(ConversationId conversationId) {
    if (_disposed) {
      throw StateError('The timeline controller registry is disposed.');
    }
    return _controllers.putIfAbsent(
      conversationId,
      () => ChatTimelineController._(
        client: _client,
        conversationId: conversationId,
        pageSize: 50,
      ),
    );
  }

  ChatTimelineController forId(ConversationId conversationId) =>
      forConversation(conversationId);

  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    final controllers = _controllers.values.toList(growable: false);
    _controllers.clear();
    await Future.wait(controllers.map((controller) => controller.dispose()));
  }
}

final Expando<ChatTimelineControllers> _timelineRegistries =
    Expando<ChatTimelineControllers>('handrail timeline controllers');

/// Ergonomic timeline registry attached to each public chat client.
extension HandrailChatTimelineControllerRegistry on HandrailChatClient {
  ChatTimelineControllers get timelines =>
      _timelineRegistries[this] ??= ChatTimelineControllers._(this);

  ChatTimelineController timeline(ConversationId conversationId) =>
      timelines.forConversation(conversationId);
}

/// Pure-Dart timeline state, pagination, commands, and live observation.
final class ChatTimelineController {
  ChatTimelineController._({
    required HandrailChatClient client,
    required this.conversationId,
    required this.pageSize,
  })  : _client = client,
        _state = ChatTimelineControllerState.initial(conversationId) {
    _states = _createStateStream();
  }

  final HandrailChatClient _client;
  final ConversationId conversationId;
  final int pageSize;
  final StreamController<ChatTimelineControllerState> _changes =
      StreamController<ChatTimelineControllerState>.broadcast(sync: true);
  late final Stream<ChatTimelineControllerState> _states;
  ChatTimelineControllerState _state;
  ChatRealtimeConversationSubscriptionRelease? _releaseRealtime;
  final List<StreamSubscription<Object?>> _subscriptions = [];
  Future<ChatTimelineControllerState>? _refreshOperation;
  Future<ChatTimelineControllerState>? _earlierOperation;
  Future<ChatTimelineControllerState>? _newerOperation;
  var _listenerCount = 0;
  var _retainCount = 0;
  var _observationEpoch = 0;
  var _disposed = false;
  // Keep denial status until an HTTP read restores access.
  var _httpReadAccessDenied = false;

  ChatTimelineControllerState get state => _state;

  /// Shared ephemeral context in this timeline's conversation. The host must
  /// configure authority through client.messageContexts from its trusted
  /// current identity/access scope. A loaded timeline never grants authority.
  /// Consumers observe this controller without disposing or resetting it.
  ChatMessageContextController messageContext(MessageId messageId) =>
      _client.messageContexts.forMessage(MessageContextRequest(
        conversationId: conversationId,
        messageId: messageId,
      ));

  /// Broadcast state stream that emits the immutable current value first.
  Stream<ChatTimelineControllerState> get states => _states;

  /// Keeps normalized, typing, and realtime observation alive without a
  /// stream listener.
  ChatTimelineRetainHandle retain() {
    if (_disposed) {
      throw StateError('The timeline controller is disposed.');
    }
    _retainCount += 1;
    if (_consumerCount == 1) _startObservation();
    return ChatTimelineRetainHandle._(_releaseRetain);
  }

  /// Hydrates the newest page. Concurrent refreshes share one operation.
  Future<ChatTimelineControllerState> refresh({
    ChatCommandCancellationSignal? cancellationSignal,
  }) {
    if (_disposed) return Future.value(_state);
    return _refreshOperation ??= _load(
      direction: MessageTimelineDirection.backward,
      cursor: null,
      showLoading: true,
      cancellationSignal: cancellationSignal,
    ).whenComplete(() => _refreshOperation = null);
  }

  /// Hydrates the page advertised by the current older boundary.
  Future<ChatTimelineControllerState> loadEarlier({
    ChatCommandCancellationSignal? cancellationSignal,
  }) {
    if (_disposed) return Future.value(_state);
    final boundary =
        _client.normalizedState.timeline(conversationId).pagination.older;
    if (!boundary.available || boundary.cursor == null) {
      return Future.value(_state);
    }
    return _earlierOperation ??= _load(
      direction: MessageTimelineDirection.backward,
      cursor: boundary.cursor,
      cancellationSignal: cancellationSignal,
    ).whenComplete(() => _earlierOperation = null);
  }

  /// Hydrates the page advertised by the current newer boundary.
  Future<ChatTimelineControllerState> loadNewer({
    ChatCommandCancellationSignal? cancellationSignal,
  }) {
    if (_disposed) return Future.value(_state);
    final boundary =
        _client.normalizedState.timeline(conversationId).pagination.newer;
    if (!boundary.available || boundary.cursor == null) {
      return Future.value(_state);
    }
    return _newerOperation ??= _load(
      direction: MessageTimelineDirection.forward,
      cursor: boundary.cursor,
      cancellationSignal: cancellationSignal,
    ).whenComplete(() => _newerOperation = null);
  }

  Future<ChatCommandResult<SendMessageResult>> send(
    MessageContent content, {
    ChatCommandCancellationSignal? cancellationSignal,
  }) =>
      _client.sendMessage(
        ChatSendMessageInput(
          conversationId: conversationId,
          content: content,
        ),
        cancellationSignal: cancellationSignal,
      );

  Future<ChatCommandResult<SendMessageResult>> sendMessage(
    MessageContent content, {
    ChatCommandCancellationSignal? cancellationSignal,
  }) =>
      send(content, cancellationSignal: cancellationSignal);

  /// Marks one canonical, already-read timeline sequence and everything after
  /// it unread through the client's read-cursor runtime.
  Future<ChatCommandResult<ReadCursorMutationResult>> markUnread(
    MessageSequence fromSequence,
  ) =>
      _client.markUnread(ChatMarkUnreadInput(
        conversationId: conversationId,
        fromSequence: fromSequence,
      ));

  /// Distinguishes server-confirmed rows from optimistic send projections.
  bool isCanonicalMessage(MessageId messageId) =>
      _client.normalizedState.isCanonicalMessage(messageId);

  /// Current actor-private reminder state for one selected message.
  NormalizedMessageReminderState messageReminder(MessageId messageId) =>
      _client.normalizedState.messageReminder(messageId);

  /// Actor-private reminder updates for one selected message only.
  Stream<NormalizedMessageReminderState> messageReminderStates(
    MessageId messageId,
  ) =>
      _client.normalizedState.messageReminderStates(messageId);

  Future<ChatCommandResult<MessageReminderResult>> setMessageReminder({
    required MessageId messageId,
    required IsoTimestamp dueAt,
    ChatCommandCancellationSignal? cancellationSignal,
  }) =>
      _client.setMessageReminder(
        conversationId: conversationId,
        messageId: messageId,
        dueAt: dueAt,
        cancellationSignal: cancellationSignal,
      );

  Future<ChatCommandResult<MessageReminderResult>> rescheduleMessageReminder({
    required MessageId messageId,
    required IsoTimestamp dueAt,
    ChatCommandCancellationSignal? cancellationSignal,
  }) =>
      _client.rescheduleMessageReminder(
        conversationId: conversationId,
        messageId: messageId,
        dueAt: dueAt,
        cancellationSignal: cancellationSignal,
      );

  Future<ChatCommandResult<MessageReminderResult>> cancelMessageReminder({
    required MessageId messageId,
    ChatCommandCancellationSignal? cancellationSignal,
  }) =>
      _client.cancelMessageReminder(
        conversationId: conversationId,
        messageId: messageId,
        cancellationSignal: cancellationSignal,
      );

  /// Forwards one canonical message into an explicit destination conversation.
  Future<ChatCommandResult<ForwardMessageResult>> forwardMessage({
    required MessageId sourceMessageId,
    required ConversationId destinationConversationId,
    ChatCommandCancellationSignal? cancellationSignal,
  }) =>
      _client.forwardMessage(
        ChatForwardMessageInput(
          sourceMessageId: sourceMessageId,
          destinationConversationId: destinationConversationId,
        ),
        cancellationSignal: cancellationSignal,
      );

  Future<ChatCommandResult<EditMessageResult>> edit({
    required MessageId messageId,
    required int expectedRevision,
    required MessageContent content,
    String? idempotencyKey,
    ChatCommandCancellationSignal? cancellationSignal,
  }) =>
      _client.editMessage(
        ChatEditMessageInput(
          messageId: messageId,
          expectedRevision: expectedRevision,
          content: content,
          idempotencyKey: idempotencyKey,
        ),
        cancellationSignal: cancellationSignal,
      );

  Future<ChatCommandResult<EditMessageResult>> editMessage({
    required MessageId messageId,
    required int expectedRevision,
    required MessageContent content,
    String? idempotencyKey,
    ChatCommandCancellationSignal? cancellationSignal,
  }) =>
      edit(
        messageId: messageId,
        expectedRevision: expectedRevision,
        content: content,
        idempotencyKey: idempotencyKey,
        cancellationSignal: cancellationSignal,
      );

  Future<ChatCommandResult<SoftDeleteMessageResult>> delete({
    required MessageId messageId,
    required int expectedRevision,
    String? idempotencyKey,
    ChatCommandCancellationSignal? cancellationSignal,
  }) =>
      _client.deleteMessage(
        ChatDeleteMessageInput(
          messageId: messageId,
          expectedRevision: expectedRevision,
          idempotencyKey: idempotencyKey,
        ),
        cancellationSignal: cancellationSignal,
      );

  Future<ChatCommandResult<SoftDeleteMessageResult>> deleteMessage({
    required MessageId messageId,
    required int expectedRevision,
    String? idempotencyKey,
    ChatCommandCancellationSignal? cancellationSignal,
  }) =>
      delete(
        messageId: messageId,
        expectedRevision: expectedRevision,
        idempotencyKey: idempotencyKey,
        cancellationSignal: cancellationSignal,
      );

  Future<ChatCommandResult<ReactionMutationResult>> setReaction({
    required MessageId messageId,
    required String reactionKey,
    required bool reactedByCurrentUser,
    String? idempotencyKey,
    ChatCommandCancellationSignal? cancellationSignal,
  }) =>
      _client.setReaction(
        ChatSetReactionInput(
          messageId: messageId,
          reactionKey: reactionKey,
          reactedByCurrentUser: reactedByCurrentUser,
          idempotencyKey: idempotencyKey,
        ),
        cancellationSignal: cancellationSignal,
      );

  Future<ChatThreadOpenResult> openThread(MessageId rootMessageId) =>
      _client.threads.open(rootMessageId: rootMessageId);

  /// Delegates visibility qualification to the client's public read runtime.
  void reportVisibleThrough(MessageSequence sequence) =>
      _client.reads.reportVisibleThrough(
        conversationId: conversationId,
        sequence: sequence,
      );

  /// Releases subscriptions, emits disposed once, and ignores late work.
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    ++_observationEpoch;
    _releaseRealtime?.call();
    _releaseRealtime = null;
    final subscriptions = _subscriptions.toList(growable: false);
    _subscriptions.clear();
    _listenerCount = 0;
    _retainCount = 0;
    _emit(_compose(
      status: ChatTimelineControllerStatus.disposed,
      error: const ChatTimelineControllerError(
        code: ChatTimelineControllerErrorCode.disposed,
        message: 'The timeline controller was disposed.',
      ),
    ));
    await Future.wait(
        subscriptions.map((subscription) => subscription.cancel()));
    await _changes.close();
  }

  int get _consumerCount => _listenerCount + _retainCount;

  Stream<ChatTimelineControllerState> _createStateStream() =>
      Stream<ChatTimelineControllerState>.multi(
        (events) {
          if (!_disposed) {
            _listenerCount += 1;
            if (_consumerCount == 1) _startObservation();
          }
          events.add(_state);
          final subscription = _changes.stream.listen(
            events.add,
            onError: events.addError,
            onDone: events.close,
          );
          events.onCancel = () async {
            await subscription.cancel();
            _releaseListener();
          };
        },
        isBroadcast: true,
      );

  void _releaseListener() {
    if (_listenerCount == 0) return;
    _listenerCount -= 1;
    if (_consumerCount == 0) _stopObservation();
  }

  void _releaseRetain() {
    if (_retainCount == 0) return;
    _retainCount -= 1;
    if (_consumerCount == 0) _stopObservation();
  }

  void _startObservation() {
    if (_disposed || _subscriptions.isNotEmpty) return;
    final epoch = ++_observationEpoch;
    _subscriptions.add(
      _client.normalizedState
          .watchTimeline(conversationId)
          .cast<Object?>()
          .listen((_) {
        if (_isObserving(epoch)) _emit(_compose());
      }),
    );
    _subscriptions.add(
      _client.normalizedState
          .watchConversation(conversationId)
          .cast<Object?>()
          .listen((_) {
        if (_isObserving(epoch)) _emit(_compose());
      }),
    );
    _subscriptions.add(
      _client.ephemeralSignals.typingSnapshots.cast<Object?>().listen((_) {
        if (_isObserving(epoch)) _emit(_compose());
      }),
    );
    final realtime = _client.realtimeSession;
    if (realtime != null) {
      _subscriptions.add(
        realtime.conversationSubscriptionStates.cast<Object?>().listen(
          (value) {
            if (!_isObserving(epoch)) return;
            final subscription =
                value! as ChatRealtimeConversationSubscriptionState;
            if (subscription.conversationId != conversationId) return;
            _handleRealtimeState(subscription);
          },
        ),
      );
      _releaseRealtime = realtime.subscribeConversation(conversationId);
    }
    _emit(_compose());
    unawaited(refresh());
  }

  void _stopObservation() {
    ++_observationEpoch;
    _releaseRealtime?.call();
    _releaseRealtime = null;
    final subscriptions = _subscriptions.toList(growable: false);
    _subscriptions.clear();
    for (final subscription in subscriptions) {
      unawaited(subscription.cancel());
    }
  }

  bool _isObserving(int epoch) =>
      !_disposed && _consumerCount > 0 && epoch == _observationEpoch;

  Future<ChatTimelineControllerState> _load({
    required MessageTimelineDirection direction,
    required MessageSequence? cursor,
    bool showLoading = false,
    ChatCommandCancellationSignal? cancellationSignal,
  }) async {
    if (showLoading) {
      _emit(_compose(
        status: ChatTimelineControllerStatus.loading,
        clearError: true,
      ));
    }
    final result = await _client.getMessageTimeline(
      MessageTimelineRequest(
        conversationId: conversationId,
        direction: direction,
        cursor: cursor,
        limit: pageSize,
      ),
      options: ChatSnapshotQueryOptions(
        cancellationSignal: cancellationSignal,
      ),
    );
    if (_disposed) return _state;
    if (result case ChatSnapshotQuerySuccess(:final value)) {
      try {
        _client.normalizedState.hydrateMessageTimeline(value);
      } catch (_) {
        return _emit(_compose(
          status: ChatTimelineControllerStatus.error,
          error: const ChatTimelineControllerError(
            code: ChatTimelineControllerErrorCode.normalization,
            message: 'The message timeline could not be normalized.',
          ),
        ));
      }
      _httpReadAccessDenied = false;
      return _emit(_compose(
        status: ChatTimelineControllerStatus.ready,
        clearError: true,
      ));
    }
    return _emit(_stateForQueryFailure(result));
  }

  void _handleRealtimeState(
    ChatRealtimeConversationSubscriptionState subscription,
  ) {
    // Archived conversations can remain HTTP-readable even when the server
    // denies their realtime stream. Recheck read authority instead of treating
    // a subscription decision as a permanent history-access decision.
    final denied = subscription
            is ChatRealtimeConversationSubscriptionRevokedState ||
        subscription is ChatRealtimeConversationSubscriptionRejectedState &&
            subscription.code == ChatRealtimeSubscriptionErrorCode.accessDenied;
    if (denied && _state.conversation?.archivedAt != null) {
      unawaited(_revalidateArchivedReadAccess());
      return;
    }
    if (subscription case ChatRealtimeConversationSubscriptionRevokedState()) {
      _emit(_compose(
        status: ChatTimelineControllerStatus.accessRevoked,
        error: const ChatTimelineControllerError(
          code: ChatTimelineControllerErrorCode.realtimeRejected,
          message: 'Conversation realtime access was revoked.',
          realtimeCode: ChatRealtimeSubscriptionErrorCode.accessRevoked,
        ),
      ));
      return;
    }
    if (subscription
        case ChatRealtimeConversationSubscriptionRejectedState(:final code)) {
      final access = code == ChatRealtimeSubscriptionErrorCode.accessDenied ||
          code == ChatRealtimeSubscriptionErrorCode.accessRevoked;
      _emit(_compose(
        status: access
            ? ChatTimelineControllerStatus.accessRevoked
            : ChatTimelineControllerStatus.error,
        error: ChatTimelineControllerError(
          code: ChatTimelineControllerErrorCode.realtimeRejected,
          message: access
              ? 'Conversation realtime access was rejected.'
              : 'The conversation realtime subscription was rejected.',
          realtimeCode: code,
        ),
      ));
    }
  }

  Future<void> _revalidateArchivedReadAccess() async {
    _emit(_compose(
      status: ChatTimelineControllerStatus.loading,
      clearError: true,
    ));
    // An in-flight read may predate the denial; require a new authorized GET.
    await _refreshOperation;
    if (!_disposed) await refresh();
  }

  ChatTimelineControllerState _compose({
    ChatTimelineControllerStatus? status,
    ChatTimelineControllerError? error,
    bool clearError = false,
  }) {
    final timeline = _client.normalizedState.timeline(conversationId);
    final conversation = _client.normalizedState.conversation(conversationId);
    final tenantId = conversation.conversation?.tenantId ??
        timeline.messages.firstOrNull?.tenantId;
    final typing = tenantId == null
        ? const <TypingSignalEvent>[]
        : _client.ephemeralSignals.snapshot.typing
            .forConversation(tenantId, conversationId);
    final typingUsers = <UserId>{
      for (final signal in typing) signal.payload.actorUserId,
    }.toList(growable: false)
      ..sort((left, right) => left.value.compareTo(right.value));
    final normalized = _client.normalizedState.state;
    return ChatTimelineControllerState._(
      status: _httpReadAccessDenied && !_disposed
          ? ChatTimelineControllerStatus.accessRevoked
          : status ?? _state.status,
      conversationId: conversationId,
      conversation: conversation.conversation,
      messages: timeline.messages,
      older: timeline.pagination.older,
      newer: timeline.pagination.newer,
      currentUserReadState: conversation.currentReadState,
      unreadBoundary: selectFirstUnreadSequence(normalized, conversationId),
      firstUnreadMessage: selectFirstUnreadMessage(normalized, conversationId),
      typingSignals: typing,
      typingUserIds: typingUsers,
      error: clearError ? null : (error ?? _state.error),
    );
  }

  ChatTimelineControllerState _stateForQueryFailure<Value>(
    ChatSnapshotQueryResult<Value> result,
  ) {
    final failure = result as ChatSnapshotQueryFailure<Value>;
    final accessRevoked =
        failure.httpStatus == 401 || failure.httpStatus == 403;
    if (accessRevoked) _httpReadAccessDenied = true;
    final code = switch (result) {
      ChatSnapshotQueryAuthenticationFailure() =>
        ChatTimelineControllerErrorCode.authentication,
      ChatSnapshotQueryRejected() => ChatTimelineControllerErrorCode.rejected,
      ChatSnapshotQueryMalformedResponse() =>
        ChatTimelineControllerErrorCode.malformedResponse,
      ChatSnapshotQueryTransportFailure() =>
        ChatTimelineControllerErrorCode.transport,
      ChatSnapshotQueryAborted() => ChatTimelineControllerErrorCode.aborted,
      ChatSnapshotQueryClosed() => ChatTimelineControllerErrorCode.closed,
      _ => ChatTimelineControllerErrorCode.transport,
    };
    return _compose(
      status: accessRevoked
          ? ChatTimelineControllerStatus.accessRevoked
          : ChatTimelineControllerStatus.error,
      error: ChatTimelineControllerError(
        code: code,
        message: accessRevoked
            ? 'Conversation timeline access was rejected.'
            : failure.message,
        httpStatus: failure.httpStatus,
      ),
    );
  }

  ChatTimelineControllerState _emit(ChatTimelineControllerState next) {
    if (_sameState(_state, next)) return _state;
    _state = next;
    if (!_changes.isClosed) _changes.add(next);
    return next;
  }
}

bool _sameState(
  ChatTimelineControllerState left,
  ChatTimelineControllerState right,
) {
  if (left.status != right.status ||
      left.conversationId != right.conversationId ||
      !_sameMapNullable(
        left.conversation?.toJson(),
        right.conversation?.toJson(),
      ) ||
      left.error != right.error ||
      !_sameBoundary(left.older, right.older) ||
      !_sameBoundary(left.newer, right.newer) ||
      !_sameReadState(left.currentUserReadState, right.currentUserReadState) ||
      left.unreadBoundary != right.unreadBoundary ||
      !_sameTimelineMessage(
          left.firstUnreadMessage, right.firstUnreadMessage) ||
      left.messages.length != right.messages.length ||
      left.typingSignals.length != right.typingSignals.length ||
      left.typingUserIds.length != right.typingUserIds.length) {
    return false;
  }
  for (var index = 0; index < left.messages.length; index += 1) {
    if (!_sameTimelineMessage(left.messages[index], right.messages[index])) {
      return false;
    }
  }
  for (var index = 0; index < left.typingSignals.length; index += 1) {
    if (!_sameMap(
      left.typingSignals[index].toJson(),
      right.typingSignals[index].toJson(),
    )) {
      return false;
    }
  }
  for (var index = 0; index < left.typingUserIds.length; index += 1) {
    if (left.typingUserIds[index] != right.typingUserIds[index]) return false;
  }
  return true;
}

bool _sameMapNullable(
  Map<String, Object?>? left,
  Map<String, Object?>? right,
) =>
    left == null ? right == null : right != null && _sameMap(left, right);

bool _sameBoundary(
  MessageTimelineBoundary left,
  MessageTimelineBoundary right,
) =>
    left.available == right.available && left.cursor == right.cursor;

bool _sameReadState(
  ConversationSnapshotReadState? left,
  ConversationSnapshotReadState? right,
) =>
    left == null
        ? right == null
        : right != null && _sameMap(left.toJson(), right.toJson());

bool _sameTimelineMessage(
  MessageTimelineMessage? left,
  MessageTimelineMessage? right,
) =>
    left == null
        ? right == null
        : right != null && _sameMap(left.toJson(), right.toJson());

bool _sameMap(Map<String, Object?> left, Map<String, Object?> right) {
  if (left.length != right.length) return false;
  for (final entry in left.entries) {
    if (!right.containsKey(entry.key) ||
        !_sameValue(entry.value, right[entry.key])) {
      return false;
    }
  }
  return true;
}

bool _sameValue(Object? left, Object? right) {
  if (left is Map<String, Object?> && right is Map<String, Object?>) {
    return _sameMap(left, right);
  }
  if (left is List<Object?> && right is List<Object?>) {
    if (left.length != right.length) return false;
    for (var index = 0; index < left.length; index += 1) {
      if (!_sameValue(left[index], right[index])) return false;
    }
    return true;
  }
  return left == right;
}
