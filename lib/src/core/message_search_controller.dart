import 'dart:async';

import '../handrail_chat_client.dart';
import '../message_search.dart';
import 'command_dispatcher.dart';

/// Stable lifecycle outcomes for framework-neutral message search.
enum ChatMessageSearchStatus {
  idle,
  loading,
  ready,
  empty,
  error,
  accessDenied,
  accessRevoked,
  disposed,
}

/// Stable, non-sensitive error categories surfaced by message search.
enum ChatMessageSearchErrorCode {
  validation,
  authentication,
  rejected,
  malformedResponse,
  transport,
  aborted,
  closed,
  disposed,
}

/// Public search failure details without query text, snippets, or credentials.
final class ChatMessageSearchError {
  const ChatMessageSearchError({
    required this.code,
    required this.message,
    this.httpStatus,
  });

  final ChatMessageSearchErrorCode code;
  final String message;
  final int? httpStatus;
}

/// Immutable current state for [ChatMessageSearchController].
final class ChatMessageSearchState {
  const ChatMessageSearchState._({
    required this.status,
    required this.page,
    required this.isBusy,
    required this.error,
  });

  factory ChatMessageSearchState.initial() => ChatMessageSearchState._(
        status: ChatMessageSearchStatus.idle,
        page: HandrailMessageSearchPage(hits: const []),
        isBusy: false,
        error: null,
      );

  final ChatMessageSearchStatus status;
  final HandrailMessageSearchPage page;
  final bool isBusy;
  final ChatMessageSearchError? error;

  List<HandrailMessageSearchHit> get hits => page.hits;
  String? get nextPageToken => page.nextPageToken;
  bool get hasMore => nextPageToken != null;
  bool get isDisposed => status == ChatMessageSearchStatus.disposed;
}

/// Pure-Dart, transient paging over [HandrailChatClient.searchMessages].
///
/// A new [search] cancels and supersedes any active request. Results live only
/// in this controller and are never written to the client's normalized store.
final class ChatMessageSearchController {
  ChatMessageSearchController({required HandrailChatClient client})
      : _client = client,
        _state = ChatMessageSearchState.initial() {
    _states = _createStateStream();
  }

  final HandrailChatClient _client;
  final StreamController<ChatMessageSearchState> _changes =
      StreamController<ChatMessageSearchState>.broadcast(sync: true);
  late final Stream<ChatMessageSearchState> _states;
  ChatMessageSearchState _state;
  _MessageSearchOperation? _activeOperation;
  ChatCommandCancellationController? _activeCancellation;
  HandrailMessageSearchRequest? _lastRequest;
  HandrailMessageSearchRequest? _failedRequest;
  bool _failedReplace = true;
  final Set<String> _seenPageTokens = <String>{};
  var _hasLoadedSuccessfully = false;
  var _disposed = false;

  ChatMessageSearchState get state => _state;
  Stream<ChatMessageSearchState> get states => _states;

  /// Starts a new search and supersedes any in-flight search or page request.
  Future<ChatMessageSearchState> search(
    HandrailMessageSearchRequest request, {
    ChatCommandCancellationSignal? cancellationSignal,
  }) {
    if (_disposed) return Future.value(_state);
    _activeCancellation?.cancel();
    _seenPageTokens.clear();
    _lastRequest = request;
    return _start(
      request: request,
      replace: true,
      cancellationSignal: cancellationSignal,
    );
  }

  /// Loads the next opaque page. Concurrent page requests are coalesced.
  Future<ChatMessageSearchState> loadMore({
    ChatCommandCancellationSignal? cancellationSignal,
  }) {
    if (_disposed) return Future.value(_state);
    final active = _activeOperation;
    if (active != null) return active.future;
    final previous = _lastRequest;
    final token = _state.nextPageToken;
    if (previous == null || token == null) return Future.value(_state);
    return _start(
      request: HandrailMessageSearchRequest(
        query: previous.query,
        filters: previous.filters,
        pageSize: previous.pageSize,
        pageToken: token,
      ),
      replace: false,
      cancellationSignal: cancellationSignal,
    );
  }

  /// Retries the exact request that most recently failed.
  Future<ChatMessageSearchState> retry({
    ChatCommandCancellationSignal? cancellationSignal,
  }) {
    if (_disposed) return Future.value(_state);
    final active = _activeOperation;
    if (active != null) return active.future;
    final request = _failedRequest;
    if (request == null) return Future.value(_state);
    return _start(
      request: request,
      replace: _failedReplace,
      cancellationSignal: cancellationSignal,
    );
  }

  Future<ChatMessageSearchState> _start({
    required HandrailMessageSearchRequest request,
    required bool replace,
    ChatCommandCancellationSignal? cancellationSignal,
  }) {
    final operation = _MessageSearchOperation(request, replace);
    _activeOperation = operation;
    final cancellation = ChatCommandCancellationController();
    _activeCancellation = cancellation;
    _failedRequest = null;
    StreamSubscription<void>? callerCancellation;
    if (cancellationSignal != null) {
      callerCancellation = cancellationSignal.onCancelled.listen((_) {
        cancellation.cancel();
      });
      if (cancellationSignal.isCancelled) cancellation.cancel();
    }

    _emit(
      ChatMessageSearchState._(
        status: replace ? ChatMessageSearchStatus.loading : _state.status,
        page: replace ? HandrailMessageSearchPage(hits: const []) : _state.page,
        isBusy: true,
        error: null,
      ),
    );

    unawaited(
      _perform(operation, cancellation)
          .then(
            (value) => _finish(operation, value),
            onError: (Object _, StackTrace __) => _finish(
              operation,
              _stateForUnexpectedFailure(operation),
            ),
          )
          .whenComplete(() => callerCancellation?.cancel()),
    );
    return operation.future;
  }

  Future<ChatMessageSearchState> _perform(
    _MessageSearchOperation operation,
    ChatCommandCancellationController cancellation,
  ) async {
    final result = await _client.searchMessages(
      operation.request,
      options: ChatSnapshotQueryOptions(
        cancellationSignal: cancellation.signal,
      ),
    );
    if (_disposed || !identical(operation, _activeOperation)) return _state;

    if (result case ChatSnapshotQuerySuccess<HandrailMessageSearchPage>()) {
      _hasLoadedSuccessfully = true;
      _failedRequest = null;
      final page = _mergePage(result.value, replace: operation.replace);
      _lastRequest = operation.request;
      return _emit(
        ChatMessageSearchState._(
          status: page.hits.isEmpty
              ? ChatMessageSearchStatus.empty
              : ChatMessageSearchStatus.ready,
          page: page,
          isBusy: false,
          error: null,
        ),
      );
    }

    _failedRequest = operation.request;
    _failedReplace = operation.replace;
    return _emit(_stateForFailure(result));
  }

  HandrailMessageSearchPage _mergePage(
    HandrailMessageSearchPage incoming, {
    required bool replace,
  }) {
    final hits = <HandrailMessageSearchHit>[
      if (!replace) ..._state.hits,
    ];
    final identities = hits.map((hit) => hit.identityKey).toSet();
    for (final hit in incoming.hits) {
      if (identities.add(hit.identityKey)) hits.add(hit);
    }

    var nextPageToken = incoming.nextPageToken;
    if (nextPageToken != null && !_seenPageTokens.add(nextPageToken)) {
      nextPageToken = null;
    }
    return HandrailMessageSearchPage(
      hits: hits,
      nextPageToken: nextPageToken,
    );
  }

  ChatMessageSearchState _stateForFailure(
    ChatSnapshotQueryResult<HandrailMessageSearchPage> result,
  ) {
    final failure = result as ChatSnapshotQueryFailure;
    final code = switch (result) {
      ChatSnapshotQueryValidationFailure() =>
        ChatMessageSearchErrorCode.validation,
      ChatSnapshotQueryAuthenticationFailure() =>
        ChatMessageSearchErrorCode.authentication,
      ChatSnapshotQueryRejected() => ChatMessageSearchErrorCode.rejected,
      ChatSnapshotQueryMalformedResponse() =>
        ChatMessageSearchErrorCode.malformedResponse,
      ChatSnapshotQueryTransportFailure() =>
        ChatMessageSearchErrorCode.transport,
      ChatSnapshotQueryAborted() => ChatMessageSearchErrorCode.aborted,
      ChatSnapshotQueryClosed() => ChatMessageSearchErrorCode.closed,
      _ => ChatMessageSearchErrorCode.transport,
    };
    final accessFailure = code == ChatMessageSearchErrorCode.authentication;
    return ChatMessageSearchState._(
      status: accessFailure
          ? (_hasLoadedSuccessfully
              ? ChatMessageSearchStatus.accessRevoked
              : ChatMessageSearchStatus.accessDenied)
          : ChatMessageSearchStatus.error,
      page: _state.page,
      isBusy: false,
      error: ChatMessageSearchError(
        code: code,
        message: failure.message,
        httpStatus: failure.httpStatus,
      ),
    );
  }

  ChatMessageSearchState _stateForUnexpectedFailure(
    _MessageSearchOperation operation,
  ) {
    if (_disposed || !identical(operation, _activeOperation)) return _state;
    _failedRequest = operation.request;
    _failedReplace = operation.replace;
    return _emit(
      ChatMessageSearchState._(
        status: ChatMessageSearchStatus.error,
        page: _state.page,
        isBusy: false,
        error: const ChatMessageSearchError(
          code: ChatMessageSearchErrorCode.transport,
          message: 'The chat message search could not be completed.',
        ),
      ),
    );
  }

  void _finish(
    _MessageSearchOperation operation,
    ChatMessageSearchState value,
  ) {
    if (identical(operation, _activeOperation)) {
      _activeOperation = null;
      _activeCancellation = null;
    }
    if (!operation.completer.isCompleted) operation.completer.complete(value);
  }

  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    _activeCancellation?.cancel();
    _emit(
      ChatMessageSearchState._(
        status: ChatMessageSearchStatus.disposed,
        page: _state.page,
        isBusy: false,
        error: const ChatMessageSearchError(
          code: ChatMessageSearchErrorCode.disposed,
          message: 'The message search controller was disposed.',
        ),
      ),
    );
    await _changes.close();
  }

  ChatMessageSearchState _emit(ChatMessageSearchState next) {
    _state = next;
    if (!_changes.isClosed) _changes.add(next);
    return next;
  }

  Stream<ChatMessageSearchState> _createStateStream() =>
      Stream<ChatMessageSearchState>.multi(
        (controller) {
          controller.add(_state);
          final subscription = _changes.stream.listen(
            controller.add,
            onError: controller.addError,
            onDone: controller.close,
          );
          controller.onCancel = subscription.cancel;
        },
        isBroadcast: true,
      );
}

final class _MessageSearchOperation {
  _MessageSearchOperation(this.request, this.replace);

  final HandrailMessageSearchRequest request;
  final bool replace;
  final Completer<ChatMessageSearchState> completer = Completer();

  Future<ChatMessageSearchState> get future => completer.future;
}
