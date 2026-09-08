import 'dart:async';

import '../generated/conversation.dart';
import '../generated/conversation_preference.dart';
import '../generated/conversation_snapshot.dart';
import '../generated/identifiers.dart';
import '../handrail_chat_client.dart';
import 'command_dispatcher.dart';
import 'normalized_snapshot_state.dart';

/// Stable lifecycle outcomes for a framework-neutral conversation list.
enum ChatConversationListStatus {
  loading,
  ready,
  empty,
  error,
  accessDenied,
  accessRevoked,
  disposed,
}

/// Stable, non-sensitive error categories surfaced by a conversation list.
enum ChatConversationListErrorCode {
  validation,
  authentication,
  rejected,
  malformedResponse,
  transport,
  aborted,
  closed,
  disposed,
}

/// Public failure details without request bodies, credentials, or cache state.
final class ChatConversationListError {
  const ChatConversationListError({
    required this.code,
    required this.message,
    this.httpStatus,
  });

  final ChatConversationListErrorCode code;
  final String message;
  final int? httpStatus;
}

/// One stable list-row projection derived from a public snapshot summary.
final class ChatConversationListItem {
  const ChatConversationListItem({
    required this.conversation,
    required this.displayName,
    required this.unreadCount,
    required this.activityAt,
  });

  factory ChatConversationListItem.fromSummary(
    ConversationSnapshotSummary summary,
  ) {
    final conversation = summary.conversation;
    final latest = summary.latestSequence.value;
    final readState = summary.currentReadState;
    final unreadFrom = readState.manualUnreadFromSequence?.value ??
        readState.lastReadSequence.value + 1;
    final unreadCount = latest < unreadFrom ? 0 : latest - unreadFrom + 1;

    return ChatConversationListItem(
      conversation: conversation,
      displayName: switch (conversation) {
        ChannelConversation(:final name) => name,
        DirectConversation() => 'Direct message',
        GroupDirectConversation() => 'Group conversation',
        ThreadConversation() => 'Thread',
      },
      unreadCount: unreadCount,
      activityAt: summary.activityAt,
    );
  }

  final Conversation conversation;
  final String displayName;
  final int unreadCount;
  final IsoTimestamp activityAt;

  ConversationId get conversationId => conversation.id;
  bool get isArchived => conversation.archivedAt != null;
}

/// Immutable current state for [ChatConversationListController].
final class ChatConversationListState {
  ChatConversationListState._({
    required this.status,
    required this.scope,
    required List<ChatConversationListItem> items,
    required this.hasMore,
    required this.isBusy,
    required this.error,
  }) : items = List<ChatConversationListItem>.unmodifiable(items);

  factory ChatConversationListState.initial(ConversationSnapshotScope scope) =>
      ChatConversationListState._(
        status: ChatConversationListStatus.loading,
        scope: scope,
        items: const [],
        hasMore: false,
        isBusy: false,
        error: null,
      );

  final ChatConversationListStatus status;
  final ConversationSnapshotScope scope;
  final List<ChatConversationListItem> items;
  final bool hasMore;
  final bool isBusy;
  final ChatConversationListError? error;

  /// Backwards-compatible alias for the authoritative page-request busy state.
  bool get isLoadingMore => isBusy;

  bool get isReady => status == ChatConversationListStatus.ready;
  bool get isEmpty => status == ChatConversationListStatus.empty;
  bool get isDisposed => status == ChatConversationListStatus.disposed;

  ChatConversationListState _copyWith({
    ChatConversationListStatus? status,
    List<ChatConversationListItem>? items,
    bool? hasMore,
    bool? isBusy,
    ChatConversationListError? error,
    bool clearError = false,
  }) =>
      ChatConversationListState._(
        status: status ?? this.status,
        scope: scope,
        items: items ?? this.items,
        hasMore: hasMore ?? this.hasMore,
        isBusy: isBusy ?? this.isBusy,
        error: clearError ? null : error ?? this.error,
      );
}

/// Pure-Dart scoped paging over [HandrailChatClient.listConversations].
///
/// The controller owns no navigation. Its [states] stream emits the immutable
/// current value first, while row preference access stays narrowly scoped to
/// the actor-private normalized projection.
final class ChatConversationListController {
  ChatConversationListController({
    required HandrailChatClient client,
    required ConversationSnapshotScope scope,
    this.pageSize = 50,
  })  : assert(pageSize >= 1 && pageSize <= 100),
        _client = client,
        scope = ConversationSnapshotScope.fromJson(scope.toJson()),
        _state = ChatConversationListState.initial(
          ConversationSnapshotScope.fromJson(scope.toJson()),
        ) {
    _states = _createStateStream();
  }

  final HandrailChatClient _client;
  final ConversationSnapshotScope scope;
  final int pageSize;
  final StreamController<ChatConversationListState> _changes =
      StreamController<ChatConversationListState>.broadcast(sync: true);
  late final Stream<ChatConversationListState> _states;
  ChatConversationListState _state;
  ConversationSnapshotCursor? _nextCursor;
  ConversationSnapshotCursor? _failedCursor;
  ChatCommandCancellationController? _activeCancellation;
  _ConversationListPageOperation? _activeOperation;
  _ConversationListPageOperation? _queuedRefreshOperation;
  var _hasLoadedSuccessfully = false;
  var _disposed = false;

  ChatConversationListState get state => _state;
  Stream<ChatConversationListState> get states => _states;

  /// Latest projected and canonical preference state for one rendered row.
  NormalizedConversationPreferenceState conversationPreference(
    ConversationId conversationId,
  ) =>
      _client.normalizedState.conversationPreference(conversationId);

  /// Current-first preference updates for one rendered row.
  Stream<NormalizedConversationPreferenceState> conversationPreferenceStates(
    ConversationId conversationId,
  ) =>
      _client.normalizedState.conversationPreferenceStates(conversationId);

  /// Sets an explicit desired star value while retaining canonical settings.
  Future<ChatCommandResult<UpdateConversationPreferenceResult>>
      setConversationStarred(
    ConversationId conversationId, {
    required bool isStarred,
  }) {
    final preferenceState = conversationPreference(conversationId);
    final canonical = preferenceState.authoritativePreference;
    if (canonical == null || preferenceState.isPending) {
      return Future.value(
        const ChatCommandValidationFailure<
            UpdateConversationPreferenceResult>(),
      );
    }
    try {
      return _client.updateConversationPreference(
        ChatUpdateConversationPreferenceInput(
          conversationId: conversationId,
          notificationPreference: ConversationNotificationPreference.fromJson(
            canonical.notificationPreference,
            ConversationPreferenceParseErrorCode.malformedPreference,
          ),
          isStarred: isStarred,
          mute: ConversationPreferenceMuteState.fromJson(
            canonical.mute.toJson(),
          ),
        ),
      );
    } on FormatException {
      return Future.value(
        const ChatCommandValidationFailure<
            UpdateConversationPreferenceResult>(),
      );
    }
  }

  Future<ChatConversationListState> refresh() {
    if (_disposed) return Future.value(_state);
    final active = _activeOperation;
    if (active == null) {
      return _startOperation(cursor: null, replace: true);
    }
    if (active.replace) return active.future;

    final queued = _queuedRefreshOperation ??=
        _ConversationListPageOperation(cursor: null, replace: true);
    return queued.future;
  }

  Future<ChatConversationListState> loadMore() {
    if (_disposed) return Future.value(_state);
    final active = _activeOperation;
    if (active != null) return active.future;

    final cursor = _nextCursor;
    if (cursor == null) return Future.value(_state);
    return _startOperation(cursor: cursor, replace: false);
  }

  /// Retries the operation that most recently failed.
  Future<ChatConversationListState> retry() {
    if (_disposed) return Future.value(_state);
    final active = _activeOperation;
    if (active != null) return active.future;

    final cursor = _failedCursor;
    return _startOperation(cursor: cursor, replace: cursor == null);
  }

  Future<ChatConversationListState> _startOperation({
    required ConversationSnapshotCursor? cursor,
    required bool replace,
  }) {
    final operation = _ConversationListPageOperation(
      cursor: cursor,
      replace: replace,
    );
    _beginOperation(operation);
    return operation.future;
  }

  void _beginOperation(_ConversationListPageOperation operation) {
    assert(_activeOperation == null);
    _activeOperation = operation;
    final cancellation = ChatCommandCancellationController();
    _activeCancellation = cancellation;
    _failedCursor = null;

    if (operation.replace) {
      _emit(_state._copyWith(
        status: ChatConversationListStatus.loading,
        isBusy: true,
        clearError: true,
      ));
    } else {
      _emit(_state._copyWith(isBusy: true, clearError: true));
    }

    unawaited(
      _performOperation(operation, cancellation).then(
        (_) => _finishOperation(operation),
        onError: (Object error, StackTrace stackTrace) =>
            _finishOperation(operation, error: error, stackTrace: stackTrace),
      ),
    );
  }

  Future<ChatConversationListState> _performOperation(
    _ConversationListPageOperation operation,
    ChatCommandCancellationController cancellation,
  ) async {
    final result = await _client.listConversations(
      ConversationListSnapshotInput(
        scope: scope,
        cursor: operation.cursor,
        limit: pageSize,
      ),
      options: ChatSnapshotQueryOptions(
        cancellationSignal: cancellation.signal,
      ),
    );
    if (_disposed || !identical(operation, _activeOperation)) return _state;

    if (result
        case ChatSnapshotQuerySuccess<ConversationListSnapshot>(
          :final value,
        )) {
      try {
        _client.normalizedState.hydrateConversationList(
          value,
          requestCursor: operation.cursor,
        );
      } on NormalizedSnapshotConflict {
        // Keep the independently validated visual page usable when an older
        // normalized snapshot disagrees at the same canonical timestamp.
      }
      final byId = <ConversationId, ChatConversationListItem>{
        if (!operation.replace)
          for (final item in _state.items) item.conversationId: item,
      };
      for (final summary in value.items) {
        final item = ChatConversationListItem.fromSummary(summary);
        byId[item.conversationId] = item;
      }
      final items = byId.values.toList(growable: false);
      _nextCursor = value.page.nextCursor;
      _hasLoadedSuccessfully = true;
      return _emit(_state._copyWith(
        status: items.isEmpty
            ? ChatConversationListStatus.empty
            : ChatConversationListStatus.ready,
        items: items,
        hasMore: _nextCursor != null,
        clearError: true,
      ));
    }

    final failure =
        result as ChatSnapshotQueryFailure<ConversationListSnapshot>;
    final error = _errorFor(failure);
    _failedCursor = operation.cursor;
    final accessFailure =
        error.code == ChatConversationListErrorCode.authentication ||
            (error.code == ChatConversationListErrorCode.rejected &&
                (error.httpStatus == 401 || error.httpStatus == 403));
    return _emit(_state._copyWith(
      status: accessFailure
          ? (_hasLoadedSuccessfully
              ? ChatConversationListStatus.accessRevoked
              : ChatConversationListStatus.accessDenied)
          : ChatConversationListStatus.error,
      error: error,
    ));
  }

  void _finishOperation(
    _ConversationListPageOperation operation, {
    Object? error,
    StackTrace? stackTrace,
  }) {
    if (!identical(operation, _activeOperation)) return;
    _activeOperation = null;
    _activeCancellation = null;

    if (_disposed) {
      operation.complete(_state);
      return;
    }

    final queuedRefresh = _queuedRefreshOperation;
    _queuedRefreshOperation = null;
    if (queuedRefresh != null) {
      if (error == null) {
        operation.complete(_state);
      } else {
        operation.completeError(error, stackTrace!);
      }
      _beginOperation(queuedRefresh);
      return;
    }

    final settled = _emit(_state._copyWith(isBusy: false));
    if (error == null) {
      operation.complete(settled);
    } else {
      operation.completeError(error, stackTrace!);
    }
  }

  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    _activeCancellation?.cancel();
    _activeCancellation = null;
    final active = _activeOperation;
    final queuedRefresh = _queuedRefreshOperation;
    _activeOperation = null;
    _queuedRefreshOperation = null;
    _nextCursor = null;
    _failedCursor = null;
    final disposedState = _emit(_state._copyWith(
      status: ChatConversationListStatus.disposed,
      hasMore: false,
      isBusy: false,
      error: const ChatConversationListError(
        code: ChatConversationListErrorCode.disposed,
        message: 'The conversation list controller was disposed.',
      ),
    ));
    active?.complete(disposedState);
    queuedRefresh?.complete(disposedState);
    await _changes.close();
  }

  Stream<ChatConversationListState> _createStateStream() =>
      Stream<ChatConversationListState>.multi(
        (events) {
          events.add(_state);
          final subscription = _changes.stream.listen(
            events.add,
            onError: events.addError,
            onDone: events.close,
          );
          events.onCancel = subscription.cancel;
        },
        isBroadcast: true,
      );

  ChatConversationListState _emit(ChatConversationListState next) {
    _state = next;
    if (!_changes.isClosed) _changes.add(next);
    return next;
  }
}

final class _ConversationListPageOperation {
  _ConversationListPageOperation({
    required this.cursor,
    required this.replace,
  });

  final ConversationSnapshotCursor? cursor;
  final bool replace;
  final Completer<ChatConversationListState> _completer = Completer();

  Future<ChatConversationListState> get future => _completer.future;

  void complete(ChatConversationListState state) {
    if (!_completer.isCompleted) _completer.complete(state);
  }

  void completeError(Object error, StackTrace stackTrace) {
    if (!_completer.isCompleted) _completer.completeError(error, stackTrace);
  }
}

ChatConversationListError _errorFor(
  ChatSnapshotQueryFailure<ConversationListSnapshot> failure,
) =>
    ChatConversationListError(
      code: switch (failure) {
        ChatSnapshotQueryValidationFailure<ConversationListSnapshot>() =>
          ChatConversationListErrorCode.validation,
        ChatSnapshotQueryAuthenticationFailure<ConversationListSnapshot>() =>
          ChatConversationListErrorCode.authentication,
        ChatSnapshotQueryRejected<ConversationListSnapshot>() =>
          ChatConversationListErrorCode.rejected,
        ChatSnapshotQueryMalformedResponse<ConversationListSnapshot>() =>
          ChatConversationListErrorCode.malformedResponse,
        ChatSnapshotQueryTransportFailure<ConversationListSnapshot>() =>
          ChatConversationListErrorCode.transport,
        ChatSnapshotQueryAborted<ConversationListSnapshot>() =>
          ChatConversationListErrorCode.aborted,
        ChatSnapshotQueryClosed<ConversationListSnapshot>() =>
          ChatConversationListErrorCode.closed,
      },
      message: failure.message,
      httpStatus: failure.httpStatus,
    );
