import 'dart:async';

import '../generated/attachment_transport.dart';
import '../generated/conversation.dart';
import '../generated/conversation_archive.dart';
import '../generated/conversation_membership.dart';
import '../generated/conversation_preference.dart';
import '../generated/conversation_snapshot.dart';
import '../generated/draft_mutation.dart';
import '../generated/ephemeral_signals.dart';
import '../generated/identifiers.dart';
import '../generated/read_cursor_mutation.dart';
import '../generated/realtime_session.dart';
import '../realtime_session_transport.dart';
import '../handrail_chat_client.dart';
import 'attachment_upload_manager.dart';
import 'command_dispatcher.dart';
import 'normalized_snapshot_state.dart';

/// Stable lifecycle outcomes for a headless conversation controller.
enum ChatConversationControllerStatus {
  resolving,
  loading,
  ready,
  notFound,
  accessRevoked,
  error,
  disposed,
}

/// Stable, non-sensitive error categories surfaced by a controller.
enum ChatConversationControllerErrorCode {
  invalidResolution,
  authentication,
  rejected,
  malformedResponse,
  transport,
  aborted,
  closed,
  realtimeRejected,
  disposed,
}

/// Immutable controller failure details without request bodies or credentials.
final class ChatConversationControllerError {
  const ChatConversationControllerError({
    required this.code,
    required this.message,
    this.httpStatus,
    this.realtimeCode,
  });

  final ChatConversationControllerErrorCode code;
  final String message;
  final int? httpStatus;
  final ChatRealtimeSubscriptionErrorCode? realtimeCode;

  @override
  bool operator ==(Object other) =>
      other is ChatConversationControllerError &&
      other.code == code &&
      other.message == message &&
      other.httpStatus == httpStatus &&
      other.realtimeCode == realtimeCode;

  @override
  int get hashCode => Object.hash(code, message, httpStatus, realtimeCode);
}

/// One immutable, framework-neutral projection of a conversation.
final class ChatConversationControllerState {
  ChatConversationControllerState._({
    required this.status,
    required this.requestedConversationId,
    required this.requestedEntity,
    required this.conversationId,
    required this.conversation,
    required this.lifecycle,
    required Map<UserId, ConversationSnapshotMember> members,
    required List<UserId> memberUserIds,
    required this.memberListRevision,
    required this.currentUserPreference,
    required this.currentUserReadState,
    required this.draft,
    required List<TypingSignalEvent> typing,
    required List<PresenceSignalEvent> presence,
    required this.error,
  })  : members = Map.unmodifiable(members),
        memberUserIds = List.unmodifiable(memberUserIds),
        typing = List.unmodifiable(typing),
        presence = List.unmodifiable(presence);

  factory ChatConversationControllerState.initial({
    ConversationId? conversationId,
    HostEntityReference? entity,
  }) =>
      ChatConversationControllerState._(
        status: conversationId == null
            ? ChatConversationControllerStatus.resolving
            : ChatConversationControllerStatus.loading,
        requestedConversationId: conversationId,
        requestedEntity: entity,
        conversationId: conversationId,
        conversation: null,
        lifecycle: null,
        members: const {},
        memberUserIds: const [],
        memberListRevision: null,
        currentUserPreference: null,
        currentUserReadState: null,
        draft: null,
        typing: const [],
        presence: const [],
        error: null,
      );

  final ChatConversationControllerStatus status;
  final ConversationId? requestedConversationId;
  final HostEntityReference? requestedEntity;
  final ConversationId? conversationId;
  final Conversation? conversation;
  final NormalizedConversationLifecycleProjection? lifecycle;
  final Map<UserId, ConversationSnapshotMember> members;
  final List<UserId> memberUserIds;
  final int? memberListRevision;
  final ConversationSnapshotPreference? currentUserPreference;
  final ConversationSnapshotReadState? currentUserReadState;
  final ChatDraftProjection? draft;
  final List<TypingSignalEvent> typing;
  final List<PresenceSignalEvent> presence;
  final ChatConversationControllerError? error;

  bool get isResolving => status == ChatConversationControllerStatus.resolving;
  bool get isLoading => status == ChatConversationControllerStatus.loading;
  bool get isReady => status == ChatConversationControllerStatus.ready;
  bool get isDisposed => status == ChatConversationControllerStatus.disposed;

  @override
  bool operator ==(Object other) =>
      other is ChatConversationControllerState &&
      other.status == status &&
      other.requestedConversationId == requestedConversationId &&
      _sameEntity(other.requestedEntity, requestedEntity) &&
      other.conversationId == conversationId &&
      _sameJson(other.conversation?.toJson(), conversation?.toJson()) &&
      _sameLifecycle(other.lifecycle, lifecycle) &&
      _sameMemberMap(other.members, members) &&
      _sameIdList(other.memberUserIds, memberUserIds) &&
      other.memberListRevision == memberListRevision &&
      _sameJson(
        other.currentUserPreference?.toJson(),
        currentUserPreference?.toJson(),
      ) &&
      _sameJson(
        other.currentUserReadState?.toJson(),
        currentUserReadState?.toJson(),
      ) &&
      _sameDraft(other.draft, draft) &&
      _sameEventList(other.typing, typing) &&
      _sameEventList(other.presence, presence) &&
      other.error == error;

  @override
  int get hashCode => Object.hash(
        status,
        requestedConversationId,
        requestedEntity?.type,
        requestedEntity?.id,
        conversationId,
        memberListRevision,
        error,
      );
}

/// Stable client-owned registry for ID- and entity-scoped controllers.
final class ChatConversationControllers {
  ChatConversationControllers._(this._client);

  final HandrailChatClient _client;
  final Map<ConversationId, ChatConversationController> _byId = {};
  final Map<String, ChatConversationController> _byEntity = {};
  bool _disposed = false;

  ChatConversationController forConversation(ConversationId conversationId) {
    if (_disposed) {
      throw StateError('The conversation controller registry is disposed.');
    }
    return _byId.putIfAbsent(
      conversationId,
      () => ChatConversationController._(
        client: _client,
        requestedConversationId: conversationId,
      ),
    );
  }

  ChatConversationController forId(ConversationId conversationId) =>
      forConversation(conversationId);

  ChatConversationController forEntity(HostEntityReference entity) {
    if (_disposed) {
      throw StateError('The conversation controller registry is disposed.');
    }
    final validated = HostEntityReference.fromJson(entity.toJson());
    if (validated.type.trim().isEmpty || validated.id.trim().isEmpty) {
      throw ArgumentError.value(entity, 'entity', 'must not be blank');
    }
    final key = '${validated.type.length}:${validated.type}${validated.id}';
    return _byEntity.putIfAbsent(
      key,
      () => ChatConversationController._(
        client: _client,
        requestedEntity: validated,
      ),
    );
  }

  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    final controllers = <ChatConversationController>{
      ..._byId.values,
      ..._byEntity.values,
    };
    _byId.clear();
    _byEntity.clear();
    await Future.wait(controllers.map((controller) => controller.dispose()));
  }
}

final Expando<ChatConversationControllers> _conversationRegistries =
    Expando<ChatConversationControllers>('handrail conversation controllers');

/// Ergonomic controller registry attached to each public chat client.
extension HandrailChatConversationControllerRegistry on HandrailChatClient {
  ChatConversationControllers get conversations =>
      _conversationRegistries[this] ??= ChatConversationControllers._(this);
}

/// Pure-Dart state and commands for one canonical conversation.
final class ChatConversationController {
  ChatConversationController._({
    required HandrailChatClient client,
    this.requestedConversationId,
    this.requestedEntity,
  })  : _client = client,
        _canonicalConversationId = requestedConversationId,
        _state = ChatConversationControllerState.initial(
          conversationId: requestedConversationId,
          entity: requestedEntity,
        ) {
    _states = _createStateStream();
  }

  final HandrailChatClient _client;
  final ConversationId? requestedConversationId;
  final HostEntityReference? requestedEntity;
  final StreamController<ChatConversationControllerState> _changes =
      StreamController<ChatConversationControllerState>.broadcast(sync: true);
  late final Stream<ChatConversationControllerState> _states;
  ChatConversationControllerState _state;
  ConversationId? _canonicalConversationId;
  ChatDraftProjection? _draft;
  ChatRealtimeConversationSubscriptionRelease? _releaseRealtime;
  final List<StreamSubscription<Object?>> _subscriptions = [];
  final List<StreamSubscription<Object?>> _canonicalSubscriptions = [];
  ConversationId? _watchedConversationId;
  Future<ChatConversationControllerState>? _refreshOperation;
  var _listenerCount = 0;
  var _observationEpoch = 0;
  var _disposed = false;
  // Keep denial status until an HTTP read restores access.
  var _httpReadAccessDenied = false;

  ChatConversationControllerState get state => _state;

  /// Broadcast state stream that emits the immutable current value first.
  Stream<ChatConversationControllerState> get states => _states;

  ConversationId? get conversationId => _canonicalConversationId;

  ChatHuddleController get huddle =>
      _client.huddles.forConversation(_requireConversationId());

  /// The latest projected and authoritative private preference state.
  NormalizedConversationPreferenceState get conversationPreferenceState =>
      _client.normalizedState.conversationPreference(_requireConversationId());

  /// Current-first private preference updates for this conversation.
  Stream<NormalizedConversationPreferenceState>
      get conversationPreferenceStates => _client.normalizedState
          .conversationPreferenceStates(_requireConversationId());

  Future<ChatConversationControllerState> refresh() {
    if (_disposed) return Future.value(_state);
    return _refreshOperation ??= _refresh().whenComplete(() {
      _refreshOperation = null;
    });
  }

  Future<ChatConversationControllerState> _refresh() async {
    _emit(_compose(
      status: requestedEntity == null
          ? ChatConversationControllerStatus.loading
          : ChatConversationControllerStatus.resolving,
    ));
    if (requestedEntity case final entity?) {
      final scope = EntityConversationSnapshotScope(entity: entity);
      final listResult = await _client.listConversations(
        ConversationListSnapshotInput(scope: scope, limit: 100),
      );
      if (_disposed) return _state;
      if (listResult case ChatSnapshotQuerySuccess(:final value)) {
        try {
          _client.normalizedState.hydrateConversationList(value);
        } catch (_) {
          return _emit(_malformedState());
        }
        final resolved = _resolveEntityConversation(value);
        if (resolved == null) {
          return _emit(_compose(
            status: ChatConversationControllerStatus.notFound,
            clearError: true,
          ));
        }
        _setCanonicalConversation(resolved);
      } else {
        return _emit(_stateForQueryFailure(listResult));
      }
    }

    final id = _canonicalConversationId;
    if (id == null) {
      return _emit(_compose(
        status: ChatConversationControllerStatus.error,
        error: const ChatConversationControllerError(
          code: ChatConversationControllerErrorCode.invalidResolution,
          message: 'The conversation could not be resolved.',
        ),
      ));
    }
    final detailResult = await _client.getConversation(
      ConversationDetailSnapshotInput(conversationId: id),
    );
    if (_disposed) return _state;
    if (detailResult case ChatSnapshotQuerySuccess(:final value)) {
      try {
        _client.normalizedState.hydrateConversationDetail(value);
      } catch (_) {
        return _emit(_malformedState());
      }
      // Detail snapshots do not contain private drafts. Read the actor's
      // canonical draft before the composer becomes ready after a reload.
      // A failed optional read is diagnosed by the query layer and must not
      // make otherwise accessible conversation history unavailable.
      await _client.loadDraft(id);
      if (_disposed) return _state;
      _draft = _client.draftFor(id);
      _httpReadAccessDenied = false;
      return _emit(_compose(
        status: ChatConversationControllerStatus.ready,
        clearError: true,
      ));
    }
    return _emit(_stateForQueryFailure(detailResult));
  }

  Future<ChatCommandResult<ConversationArchiveResult>> archive({
    int? expectedLifecycleRevision,
    ChatCommandCancellationSignal? cancellationSignal,
  }) =>
      _client.archiveConversation(
        ChatSetConversationArchiveInput(
          conversationId: _requireConversationId(),
          expectedLifecycleRevision:
              expectedLifecycleRevision ?? _requireLifecycleRevision(),
        ),
        cancellationSignal: cancellationSignal,
      );

  Future<ChatCommandResult<ConversationArchiveResult>> restore({
    int? expectedLifecycleRevision,
    ChatCommandCancellationSignal? cancellationSignal,
  }) =>
      _client.restoreConversation(
        ChatSetConversationArchiveInput(
          conversationId: _requireConversationId(),
          expectedLifecycleRevision:
              expectedLifecycleRevision ?? _requireLifecycleRevision(),
        ),
        cancellationSignal: cancellationSignal,
      );

  Future<ChatCommandResult<ConversationMembershipMutationResult>> addMember({
    required UserId userId,
    required ConversationMembershipMemberRole role,
    int? expectedMemberListRevision,
    ChatCommandCancellationSignal? cancellationSignal,
  }) =>
      _client.addConversationMember(
        ChatAddConversationMemberInput(
          conversationId: _requireConversationId(),
          targetUserId: userId,
          requestedRole: role,
          expectedMemberListRevision:
              expectedMemberListRevision ?? _requireMemberListRevision(),
        ),
        cancellationSignal: cancellationSignal,
      );

  Future<ChatCommandResult<ConversationMembershipMutationResult>>
      updateMemberRole({
    required UserId userId,
    required ConversationMembershipMemberRole role,
    int? expectedMemberListRevision,
    ChatCommandCancellationSignal? cancellationSignal,
  }) =>
          _client.changeConversationMemberRole(
            ChatChangeConversationMemberRoleInput(
              conversationId: _requireConversationId(),
              targetUserId: userId,
              requestedRole: role,
              expectedMemberListRevision:
                  expectedMemberListRevision ?? _requireMemberListRevision(),
            ),
            cancellationSignal: cancellationSignal,
          );

  Future<ChatCommandResult<ConversationMembershipMutationResult>> removeMember({
    required UserId userId,
    int? expectedMemberListRevision,
    ChatCommandCancellationSignal? cancellationSignal,
  }) =>
      _client.removeConversationMember(
        ChatRemoveConversationMemberInput(
          conversationId: _requireConversationId(),
          targetUserId: userId,
          expectedMemberListRevision:
              expectedMemberListRevision ?? _requireMemberListRevision(),
        ),
        cancellationSignal: cancellationSignal,
      );

  Future<ChatCommandResult<UpdateConversationPreferenceResult>>
      updatePreferences({
    required ConversationNotificationPreference notificationPreference,
    required bool isStarred,
    required ConversationPreferenceMuteState mute,
    ChatCommandCancellationSignal? cancellationSignal,
  }) =>
          _client.updateConversationPreference(
            ChatUpdateConversationPreferenceInput(
              conversationId: _requireConversationId(),
              notificationPreference: notificationPreference,
              isStarred: isStarred,
              mute: mute,
            ),
            cancellationSignal: cancellationSignal,
          );

  Future<ChatCommandResult<SynchronizeDraftResult>> synchronizeDraft({
    required DraftContent content,
    int? baseRevision,
    ChatCommandCancellationSignal? cancellationSignal,
  }) =>
      _client.synchronizeDraft(
        ChatReplaceDraftInput(
          conversationId: _requireConversationId(),
          baseRevision: baseRevision ?? _state.draft?.revision ?? 0,
          content: content,
        ),
        cancellationSignal: cancellationSignal,
      );

  Future<ChatCommandResult<SynchronizeDraftResult>> clearDraft({
    int? baseRevision,
    ChatCommandCancellationSignal? cancellationSignal,
  }) =>
      _client.synchronizeDraft(
        ChatClearDraftInput(
          conversationId: _requireConversationId(),
          baseRevision: baseRevision ?? _state.draft?.revision ?? 0,
        ),
        cancellationSignal: cancellationSignal,
      );

  bool startTyping({ChatRealtimeConversationVisibility? visibility}) =>
      _client.startTyping(
        _requireConversationId(),
        visibility: visibility,
      );

  void stopTyping() => _client.stopTyping(_requireConversationId());
  void setPresence(PresenceSignalState presence) =>
      _client.setPresence(presence);
  void notifyActivity() => _client.notifyActivity();

  Future<ChatCommandResult<ReadCursorMutationResult>> markRead(
    MessageSequence throughSequence,
  ) =>
      _client.markRead(ChatMarkReadInput(
        conversationId: _requireConversationId(),
        throughSequence: throughSequence,
      ));

  Future<ChatCommandResult<ReadCursorMutationResult>> markUnread(
    MessageSequence fromSequence,
  ) =>
      _client.markUnread(ChatMarkUnreadInput(
        conversationId: _requireConversationId(),
        fromSequence: fromSequence,
      ));

  Future<ChatThreadOpenResult> openThread(MessageId rootMessageId) =>
      _client.threads.open(rootMessageId: rootMessageId);

  ChatAttachmentUploadHandle uploadAttachment({
    required AttachmentMetadata metadata,
    required Stream<List<int>> source,
    ChatCommandCancellationSignal? cancellationSignal,
    ChatAttachmentTemporaryResource? temporaryResource,
  }) =>
      _client.uploadAttachment(ChatAttachmentUploadInput(
        conversationId: _requireConversationId(),
        metadata: metadata,
        source: source,
        cancellationSignal: cancellationSignal,
        temporaryResource: temporaryResource,
      ));

  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    ++_observationEpoch;
    _releaseRealtime?.call();
    _releaseRealtime = null;
    final subscriptions = List<StreamSubscription<Object?>>.of(_subscriptions)
      ..addAll(_canonicalSubscriptions);
    _subscriptions.clear();
    _canonicalSubscriptions.clear();
    _watchedConversationId = null;
    _listenerCount = 0;
    _emit(_compose(
      status: ChatConversationControllerStatus.disposed,
      error: const ChatConversationControllerError(
        code: ChatConversationControllerErrorCode.disposed,
        message: 'The conversation controller was disposed.',
      ),
    ));
    await Future.wait(
        subscriptions.map((subscription) => subscription.cancel()));
    await _changes.close();
  }

  Stream<ChatConversationControllerState> _createStateStream() =>
      Stream<ChatConversationControllerState>.multi(
        (events) {
          if (!_disposed) _retainListener();
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

  void _retainListener() {
    if (_disposed) return;
    _listenerCount += 1;
    if (_listenerCount != 1) return;
    _observe();
    unawaited(refresh());
  }

  void _releaseListener() {
    if (_listenerCount == 0) return;
    _listenerCount -= 1;
    if (_listenerCount != 0) return;
    ++_observationEpoch;
    _releaseRealtime?.call();
    _releaseRealtime = null;
    final subscriptions = List<StreamSubscription<Object?>>.of(_subscriptions)
      ..addAll(_canonicalSubscriptions);
    _subscriptions.clear();
    _canonicalSubscriptions.clear();
    _watchedConversationId = null;
    for (final subscription in subscriptions) {
      unawaited(subscription.cancel());
    }
  }

  void _observe() {
    final epoch = ++_observationEpoch;
    if (requestedEntity case final entity?) {
      final scope = EntityConversationSnapshotScope(entity: entity);
      _subscriptions.add(
        _client.normalizedState
            .watchConversationList(scope)
            .cast<Object?>()
            .listen((value) {
          if (!_isObserving(epoch)) return;
          final snapshot = value! as NormalizedConversationListSnapshot;
          final resolved = _resolveNormalizedEntityConversation(snapshot);
          if (resolved != null) _setCanonicalConversation(resolved);
        }),
      );
      final cached = _resolveNormalizedEntityConversation(
        _client.normalizedState.conversationList(scope),
      );
      if (cached != null) _setCanonicalConversation(cached);
    } else if (_canonicalConversationId case final id?) {
      _watchCanonicalConversation(id, epoch);
    }

    _subscriptions.add(
      _client.ephemeralSignals.snapshots.cast<Object?>().listen((_) {
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
            if (subscription.conversationId != _canonicalConversationId) {
              return;
            }
            _handleRealtimeState(subscription);
          },
        ),
      );
    }
  }

  void _setCanonicalConversation(ConversationId conversationId) {
    if (_canonicalConversationId == conversationId) {
      if (_listenerCount > 0 && _watchedConversationId != conversationId) {
        _watchCanonicalConversation(conversationId, _observationEpoch);
      }
      return;
    }
    _canonicalConversationId = conversationId;
    if (_listenerCount > 0) {
      _watchCanonicalConversation(conversationId, _observationEpoch);
    }
    _emit(_compose());
  }

  void _watchCanonicalConversation(ConversationId id, int epoch) {
    final previous = List<StreamSubscription<Object?>>.of(
      _canonicalSubscriptions,
    );
    _canonicalSubscriptions.clear();
    for (final subscription in previous) {
      unawaited(subscription.cancel());
    }
    _releaseRealtime?.call();
    _releaseRealtime = null;
    _watchedConversationId = id;
    _draft = _client.draftFor(id);
    _canonicalSubscriptions.add(
      _client.normalizedState.watchConversation(id).cast<Object?>().listen((_) {
        if (_isObserving(epoch)) _emit(_compose());
      }),
    );
    _canonicalSubscriptions.add(
      _client.draftStatesFor(id).cast<Object?>().listen((value) {
        if (!_isObserving(epoch)) return;
        _draft = value as ChatDraftProjection?;
        _emit(_compose());
      }),
    );
    _releaseRealtime ??= _client.realtimeSession?.subscribeConversation(id);
  }

  bool _isObserving(int epoch) =>
      !_disposed && _listenerCount > 0 && epoch == _observationEpoch;

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
        status: ChatConversationControllerStatus.accessRevoked,
        error: const ChatConversationControllerError(
          code: ChatConversationControllerErrorCode.realtimeRejected,
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
            ? ChatConversationControllerStatus.accessRevoked
            : ChatConversationControllerStatus.error,
        error: ChatConversationControllerError(
          code: ChatConversationControllerErrorCode.realtimeRejected,
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
      status: ChatConversationControllerStatus.loading,
      clearError: true,
    ));
    // An in-flight read may predate the denial; require a new authorized GET.
    await _refreshOperation;
    if (!_disposed) await refresh();
  }

  ChatConversationControllerState _compose({
    ChatConversationControllerStatus? status,
    ChatConversationControllerError? error,
    bool clearError = false,
  }) {
    final id = _canonicalConversationId;
    final snapshot =
        id == null ? null : _client.normalizedState.conversation(id);
    final conversation = snapshot?.conversation;
    final tenantId = conversation?.tenantId;
    final ephemeral = _client.ephemeralSignals.snapshot;
    final typing = tenantId == null || id == null
        ? const <TypingSignalEvent>[]
        : ephemeral.typing.forConversation(tenantId, id);
    final relevantUsers = <UserId>{
      ...?snapshot?.memberUserIds,
      ...?snapshot?.members.keys,
    };
    final presence = tenantId == null
        ? const <PresenceSignalEvent>[]
        : <PresenceSignalEvent>[
            for (final entry in ephemeral.presence.entries.entries)
              if (entry.key.tenantId == tenantId &&
                  relevantUsers.contains(entry.key.scopedUserId))
                entry.value,
          ];
    return ChatConversationControllerState._(
      status: _httpReadAccessDenied && !_disposed
          ? ChatConversationControllerStatus.accessRevoked
          : status ?? _state.status,
      requestedConversationId: requestedConversationId,
      requestedEntity: requestedEntity,
      conversationId: id,
      conversation: conversation,
      lifecycle: snapshot?.lifecycle,
      members: snapshot?.members ?? const {},
      memberUserIds: snapshot?.memberUserIds ?? const [],
      memberListRevision: snapshot?.memberListRevision,
      currentUserPreference: snapshot?.currentPreference,
      currentUserReadState: snapshot?.currentReadState,
      draft: id == null ? null : (_draft ?? _client.draftFor(id)),
      typing: typing,
      presence: presence,
      error: clearError ? null : (error ?? _state.error),
    );
  }

  ChatConversationControllerState _stateForQueryFailure<Value>(
    ChatSnapshotQueryResult<Value> result,
  ) {
    final failure = result as ChatSnapshotQueryFailure<Value>;
    final accessRevoked =
        failure.httpStatus == 401 || failure.httpStatus == 403;
    if (accessRevoked) _httpReadAccessDenied = true;
    if (result is ChatSnapshotQueryRejected && failure.httpStatus == 404) {
      return _compose(
        status: ChatConversationControllerStatus.notFound,
        clearError: true,
      );
    }
    final code = switch (result) {
      ChatSnapshotQueryAuthenticationFailure() =>
        ChatConversationControllerErrorCode.authentication,
      ChatSnapshotQueryRejected() =>
        ChatConversationControllerErrorCode.rejected,
      ChatSnapshotQueryMalformedResponse() =>
        ChatConversationControllerErrorCode.malformedResponse,
      ChatSnapshotQueryTransportFailure() =>
        ChatConversationControllerErrorCode.transport,
      ChatSnapshotQueryAborted() => ChatConversationControllerErrorCode.aborted,
      ChatSnapshotQueryClosed() => ChatConversationControllerErrorCode.closed,
      _ => ChatConversationControllerErrorCode.transport,
    };
    return _compose(
      status: accessRevoked
          ? ChatConversationControllerStatus.accessRevoked
          : ChatConversationControllerStatus.error,
      error: ChatConversationControllerError(
        code: code,
        message: accessRevoked
            ? 'Conversation access was rejected.'
            : failure.message,
        httpStatus: failure.httpStatus,
      ),
    );
  }

  ChatConversationControllerState _malformedState() => _compose(
        status: ChatConversationControllerStatus.error,
        error: const ChatConversationControllerError(
          code: ChatConversationControllerErrorCode.malformedResponse,
          message: 'The conversation snapshot could not be normalized.',
        ),
      );

  ConversationId? _resolveEntityConversation(ConversationListSnapshot value) {
    final entity = requestedEntity!;
    final ids = <ConversationId>[
      for (final item in value.items)
        if (_conversationMatchesEntity(item.conversation, entity))
          item.conversation.id,
    ]..sort((left, right) => left.value.compareTo(right.value));
    return ids.firstOrNull;
  }

  ConversationId? _resolveNormalizedEntityConversation(
    NormalizedConversationListSnapshot value,
  ) {
    final entity = requestedEntity!;
    final ids = <ConversationId>[
      for (final conversation in value.conversations)
        if (_conversationMatchesEntity(conversation, entity)) conversation.id,
    ]..sort((left, right) => left.value.compareTo(right.value));
    return ids.firstOrNull;
  }

  ConversationId _requireConversationId() =>
      _canonicalConversationId ??
      (throw StateError('The conversation has not been resolved.'));

  int _requireLifecycleRevision() =>
      _state.lifecycle?.authoritativeRevision ??
      (throw StateError('The conversation lifecycle is not loaded.'));

  int _requireMemberListRevision() =>
      _state.memberListRevision ??
      (throw StateError('The conversation membership is not loaded.'));

  ChatConversationControllerState _emit(
    ChatConversationControllerState next,
  ) {
    if (next == _state) return _state;
    _state = next;
    if (!_changes.isClosed) _changes.add(next);
    return next;
  }
}

bool _conversationMatchesEntity(
  Conversation conversation,
  HostEntityReference entity,
) =>
    conversation is ChannelConversation &&
    conversation.entity?.type == entity.type &&
    conversation.entity?.id == entity.id;

bool _sameEntity(HostEntityReference? left, HostEntityReference? right) =>
    left?.type == right?.type && left?.id == right?.id;

bool _sameJson(Object? left, Object? right) {
  if (identical(left, right)) return true;
  if (left is Map && right is Map) {
    if (left.length != right.length) return false;
    for (final entry in left.entries) {
      if (!right.containsKey(entry.key) ||
          !_sameJson(entry.value, right[entry.key])) {
        return false;
      }
    }
    return true;
  }
  if (left is List && right is List) {
    if (left.length != right.length) return false;
    for (var index = 0; index < left.length; index += 1) {
      if (!_sameJson(left[index], right[index])) return false;
    }
    return true;
  }
  return left == right;
}

bool _sameLifecycle(
  NormalizedConversationLifecycleProjection? left,
  NormalizedConversationLifecycleProjection? right,
) =>
    left?.conversationId == right?.conversationId &&
    left?.authoritativeRevision == right?.authoritativeRevision &&
    left?.authoritativeArchived == right?.authoritativeArchived &&
    left?.projectedArchived == right?.projectedArchived &&
    _sameJson(
      left?.authoritativeConversation?.toJson(),
      right?.authoritativeConversation?.toJson(),
    ) &&
    _sameJson(
      left?.pendingIntents.map((intent) => intent.toJson()).toList(),
      right?.pendingIntents.map((intent) => intent.toJson()).toList(),
    );

bool _sameMemberMap(
  Map<UserId, ConversationSnapshotMember> left,
  Map<UserId, ConversationSnapshotMember> right,
) {
  if (left.length != right.length) return false;
  for (final entry in left.entries) {
    if (!_sameJson(entry.value.toJson(), right[entry.key]?.toJson())) {
      return false;
    }
  }
  return true;
}

bool _sameIdList(List<UserId> left, List<UserId> right) {
  if (left.length != right.length) return false;
  for (var index = 0; index < left.length; index += 1) {
    if (left[index] != right[index]) return false;
  }
  return true;
}

bool _sameDraft(ChatDraftProjection? left, ChatDraftProjection? right) =>
    left?.conversationId == right?.conversationId &&
    left?.revision == right?.revision &&
    left?.updatedAt == right?.updatedAt &&
    left?.isPending == right?.isPending &&
    _sameJson(left?.draft.toJson(), right?.draft.toJson());

bool _sameEventList(List<Object> left, List<Object> right) {
  if (left.length != right.length) return false;
  for (var index = 0; index < left.length; index += 1) {
    final leftEvent = left[index];
    final rightEvent = right[index];
    final leftJson = switch (leftEvent) {
      TypingSignalEvent() => leftEvent.toJson(),
      PresenceSignalEvent() => leftEvent.toJson(),
      _ => leftEvent,
    };
    final rightJson = switch (rightEvent) {
      TypingSignalEvent() => rightEvent.toJson(),
      PresenceSignalEvent() => rightEvent.toJson(),
      _ => rightEvent,
    };
    if (!_sameJson(leftJson, rightJson)) return false;
  }
  return true;
}

extension _FirstOrNull<Value> on List<Value> {
  Value? get firstOrNull => isEmpty ? null : first;
}
