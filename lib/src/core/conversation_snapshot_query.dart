part of '../handrail_chat_client.dart';

/// Per-query options for pure-Dart conversation snapshot reads.
final class ChatSnapshotQueryOptions {
  const ChatSnapshotQueryOptions({this.cancellationSignal});

  final ChatCommandCancellationSignal? cancellationSignal;
}

/// Stable names for supported snapshot reads.
enum ChatSnapshotQueryName {
  replyStylePreference('reply.style.preference'),
  conversationList('conversation.list'),
  threadList('thread.list'),
  conversationDetail('conversation.detail'),
  conversationDraft('conversation.draft'),
  messageTimeline('message.timeline'),
  messageContext('message.context'),
  messageReminderList('message_reminder.list'),
  messageSearch('message.search'),
  attachmentDownload('attachment.download');

  const ChatSnapshotQueryName(this.value);

  final String value;
}

/// Stable, structurally redacted diagnostic events.
enum ChatSnapshotQueryDiagnosticEvent {
  validationFailed('validation_failed'),
  tokenFailed('token_failed'),
  authenticationRefresh('auth_refresh'),
  requestFailed('request_failed'),
  responseRejected('response_rejected'),
  responseMalformed('response_malformed'),
  completed('completed'),
  aborted('aborted'),
  closed('closed');

  const ChatSnapshotQueryDiagnosticEvent(this.value);

  final String value;
}

/// Result categories shared with the JavaScript snapshot reader.
enum ChatSnapshotQueryResultCategory {
  success('success'),
  validation('validation'),
  authentication('authentication'),
  rejected('rejected'),
  malformedResponse('malformed_response'),
  transport('transport'),
  aborted('aborted'),
  closed('closed');

  const ChatSnapshotQueryResultCategory(this.value);

  final String value;
}

/// Structurally redacted snapshot telemetry.
///
/// URLs, headers, request/response bodies, tokens, and thrown values cannot be
/// represented by this type.
final class ChatSnapshotQueryDiagnostic {
  const ChatSnapshotQueryDiagnostic({
    required this.event,
    required this.query,
    required this.attempt,
    this.httpStatus,
  });

  final ChatSnapshotQueryDiagnosticEvent event;
  final ChatSnapshotQueryName query;
  final int attempt;
  final int? httpStatus;

  @override
  String toString() => 'ChatSnapshotQueryDiagnostic(event: ${event.value}, '
      'query: ${query.value}, attempt: $attempt, httpStatus: $httpStatus)';
}

typedef ChatSnapshotQueryDiagnosticCallback = void Function(
  ChatSnapshotQueryDiagnostic diagnostic,
);

/// Base result for an immutable snapshot query outcome.
sealed class ChatSnapshotQueryResult<Value> {
  const ChatSnapshotQueryResult();

  ChatSnapshotQueryResultCategory get category;
  String get status => category.value;

  @override
  String toString() => '$runtimeType(status: $status)';
}

final class ChatSnapshotQuerySuccess<Value>
    extends ChatSnapshotQueryResult<Value> {
  const ChatSnapshotQuerySuccess(this.value);

  final Value value;

  @override
  ChatSnapshotQueryResultCategory get category =>
      ChatSnapshotQueryResultCategory.success;
}

sealed class ChatSnapshotQueryFailure<Value>
    extends ChatSnapshotQueryResult<Value> {
  const ChatSnapshotQueryFailure(this.message, {this.httpStatus});

  final String message;
  final int? httpStatus;
}

final class ChatSnapshotQueryValidationFailure<Value>
    extends ChatSnapshotQueryFailure<Value> {
  const ChatSnapshotQueryValidationFailure()
      : super('The snapshot query input is invalid.');

  @override
  ChatSnapshotQueryResultCategory get category =>
      ChatSnapshotQueryResultCategory.validation;
}

final class ChatSnapshotQueryAuthenticationFailure<Value>
    extends ChatSnapshotQueryFailure<Value> {
  const ChatSnapshotQueryAuthenticationFailure({super.httpStatus})
      : super('Chat authentication failed.');

  @override
  ChatSnapshotQueryResultCategory get category =>
      ChatSnapshotQueryResultCategory.authentication;
}

final class ChatSnapshotQueryRejected<Value>
    extends ChatSnapshotQueryFailure<Value> {
  const ChatSnapshotQueryRejected({required int httpStatus})
      : super(
          'The chat server rejected the snapshot query.',
          httpStatus: httpStatus,
        );

  @override
  ChatSnapshotQueryResultCategory get category =>
      ChatSnapshotQueryResultCategory.rejected;
}

final class ChatSnapshotQueryMalformedResponse<Value>
    extends ChatSnapshotQueryFailure<Value> {
  const ChatSnapshotQueryMalformedResponse({super.httpStatus})
      : super('The chat server returned an invalid snapshot response.');

  @override
  ChatSnapshotQueryResultCategory get category =>
      ChatSnapshotQueryResultCategory.malformedResponse;
}

final class ChatSnapshotQueryTransportFailure<Value>
    extends ChatSnapshotQueryFailure<Value> {
  const ChatSnapshotQueryTransportFailure({super.httpStatus})
      : super('The chat snapshot query could not be completed.');

  @override
  ChatSnapshotQueryResultCategory get category =>
      ChatSnapshotQueryResultCategory.transport;
}

final class ChatSnapshotQueryAborted<Value>
    extends ChatSnapshotQueryFailure<Value> {
  const ChatSnapshotQueryAborted()
      : super('The chat snapshot query was aborted.');

  @override
  ChatSnapshotQueryResultCategory get category =>
      ChatSnapshotQueryResultCategory.aborted;
}

final class ChatSnapshotQueryClosed<Value>
    extends ChatSnapshotQueryFailure<Value> {
  const ChatSnapshotQueryClosed() : super('The chat client was closed.');

  @override
  ChatSnapshotQueryResultCategory get category =>
      ChatSnapshotQueryResultCategory.closed;
}

final class _SnapshotQueryInterrupted implements Exception {
  const _SnapshotQueryInterrupted();
}

final class _ActiveSnapshotQuery {
  _ActiveSnapshotQuery() : controller = ChatCommandCancellationController();

  final ChatCommandCancellationController controller;
  bool closed = false;
}

final class _ConversationSnapshotQueryReader {
  _ConversationSnapshotQueryReader({
    required this.apiBaseUri,
    required this.tokenProvider,
    required this.transport,
    required this.onDiagnostic,
  });

  final Uri apiBaseUri;
  final HandrailChatAccessTokenProvider tokenProvider;
  final HandrailChatHttpTransport transport;
  final ChatSnapshotQueryDiagnosticCallback? onDiagnostic;
  final Set<_ActiveSnapshotQuery> _active = <_ActiveSnapshotQuery>{};
  bool _closed = false;

  Future<ChatSnapshotQueryResult<ConversationListSnapshot>> listConversations(
    ConversationListSnapshotInput input, {
    required ChatSnapshotQueryOptions options,
  }) {
    late final ConversationListSnapshotInput validated;
    try {
      validated = ConversationListSnapshotInput.fromJson(input.toJson());
    } catch (_) {
      _diagnose(
        const ChatSnapshotQueryDiagnostic(
          event: ChatSnapshotQueryDiagnosticEvent.validationFailed,
          query: ChatSnapshotQueryName.conversationList,
          attempt: 0,
        ),
      );
      return Future.value(
        const ChatSnapshotQueryValidationFailure<ConversationListSnapshot>(),
      );
    }

    return _run<ConversationListSnapshot>(
      query: ChatSnapshotQueryName.conversationList,
      uri: _conversationListUri(apiBaseUri, validated),
      options: options,
      parse: (value) {
        final snapshot = ConversationListSnapshot.fromJson(value);
        if (!_sameConversationScope(snapshot.scope, validated.scope)) {
          throw const FormatException();
        }
        return snapshot;
      },
    );
  }

  Future<ChatSnapshotQueryResult<ConversationDetailSnapshot>> getConversation(
    ConversationDetailSnapshotInput input, {
    required ChatSnapshotQueryOptions options,
  }) {
    late final ConversationDetailSnapshotInput validated;
    try {
      validated = ConversationDetailSnapshotInput.fromJson(input.toJson());
    } catch (_) {
      _diagnose(
        const ChatSnapshotQueryDiagnostic(
          event: ChatSnapshotQueryDiagnosticEvent.validationFailed,
          query: ChatSnapshotQueryName.conversationDetail,
          attempt: 0,
        ),
      );
      return Future.value(
        const ChatSnapshotQueryValidationFailure<ConversationDetailSnapshot>(),
      );
    }

    return _run<ConversationDetailSnapshot>(
      query: ChatSnapshotQueryName.conversationDetail,
      uri: _conversationDetailUri(apiBaseUri, validated),
      options: options,
      parse: (value) {
        final snapshot = ConversationDetailSnapshot.fromJson(value);
        if (snapshot.conversation.summary.conversation.id !=
            validated.conversationId) {
          throw const FormatException();
        }
        return snapshot;
      },
    );
  }

  Future<ChatSnapshotQueryResult<ChatDraftProjection>> getConversationDraft(
    ConversationId conversationId, {
    required ChatSnapshotQueryOptions options,
  }) {
    try {
      ConversationDetailSnapshotInput.fromJson({
        'conversationId': conversationId.toJson(),
      });
    } catch (_) {
      _diagnose(const ChatSnapshotQueryDiagnostic(
        event: ChatSnapshotQueryDiagnosticEvent.validationFailed,
        query: ChatSnapshotQueryName.conversationDraft,
        attempt: 0,
      ));
      return Future.value(
          const ChatSnapshotQueryValidationFailure<ChatDraftProjection>());
    }
    return _run<ChatDraftProjection>(
      query: ChatSnapshotQueryName.conversationDraft,
      uri: _snapshotEndpointUri(
          apiBaseUri, ['conversations', conversationId.toJson(), 'draft']),
      options: options,
      parse: (value) => _parseDraftSnapshot(value, conversationId),
    );
  }

  Future<ChatSnapshotQueryResult<MessageReminderListSnapshot>>
      listMessageReminders(
    MessageReminderListSnapshotInput input, {
    required ChatSnapshotQueryOptions options,
  }) {
    late final MessageReminderListSnapshotInput validated;
    try {
      validated = MessageReminderListSnapshotInput.fromJson(input.toJson());
    } catch (_) {
      _diagnose(
        const ChatSnapshotQueryDiagnostic(
          event: ChatSnapshotQueryDiagnosticEvent.validationFailed,
          query: ChatSnapshotQueryName.messageReminderList,
          attempt: 0,
        ),
      );
      return Future.value(
        const ChatSnapshotQueryValidationFailure<MessageReminderListSnapshot>(),
      );
    }
    return _run<MessageReminderListSnapshot>(
      query: ChatSnapshotQueryName.messageReminderList,
      uri: _messageReminderListUri(apiBaseUri, validated),
      options: options,
      parse: (value) => MessageReminderListSnapshot.fromJson(
        value,
        expectedInput: validated,
      ),
    );
  }

  Future<ChatSnapshotQueryResult<HandrailMessageSearchPage>> searchMessages(
    HandrailMessageSearchRequest input, {
    required ChatSnapshotQueryOptions options,
  }) {
    late final MessageSearchRequest validated;
    try {
      validated = _validatedMessageSearchRequest(input);
    } catch (_) {
      _diagnose(
        const ChatSnapshotQueryDiagnostic(
          event: ChatSnapshotQueryDiagnosticEvent.validationFailed,
          query: ChatSnapshotQueryName.messageSearch,
          attempt: 0,
        ),
      );
      return Future.value(
        const ChatSnapshotQueryValidationFailure<HandrailMessageSearchPage>(),
      );
    }

    return _run<HandrailMessageSearchPage>(
      query: ChatSnapshotQueryName.messageSearch,
      uri: _snapshotEndpointUri(
        apiBaseUri,
        const <String>['messages', 'search'],
      ),
      options: options,
      method: 'POST',
      body: jsonEncode(validated.toJson()),
      parse: (value) => _adaptMessageSearchResponse(
        MessageSearchResponse.fromJson(value),
        input.filters,
      ),
    );
  }

  Future<ChatSnapshotQueryResult<Value>> _run<Value>({
    required ChatSnapshotQueryName query,
    required Uri uri,
    required ChatSnapshotQueryOptions options,
    required Value Function(Object? value) parse,
    String method = 'GET',
    String? body,
  }) async {
    if (_closed) {
      _diagnose(
        ChatSnapshotQueryDiagnostic(
          event: ChatSnapshotQueryDiagnosticEvent.closed,
          query: query,
          attempt: 0,
        ),
      );
      return ChatSnapshotQueryClosed<Value>();
    }

    final callerSignal = options.cancellationSignal;
    if (callerSignal?.isCancelled == true) {
      _diagnose(
        ChatSnapshotQueryDiagnostic(
          event: ChatSnapshotQueryDiagnosticEvent.aborted,
          query: query,
          attempt: 0,
        ),
      );
      return ChatSnapshotQueryAborted<Value>();
    }

    final active = _ActiveSnapshotQuery();
    StreamSubscription<void>? callerCancellation;
    if (callerSignal != null) {
      callerCancellation = callerSignal.onCancelled.listen((_) {
        active.controller.cancel();
      });
      if (callerSignal.isCancelled) active.controller.cancel();
    }
    _active.add(active);

    var attempt = 0;
    var interruptionDiagnosed = false;

    ChatSnapshotQueryResult<Value>? interruption() {
      if (!active.controller.signal.isCancelled) return null;
      final result = active.closed
          ? ChatSnapshotQueryClosed<Value>()
          : ChatSnapshotQueryAborted<Value>();
      if (!interruptionDiagnosed) {
        interruptionDiagnosed = true;
        _diagnose(
          ChatSnapshotQueryDiagnostic(
            event: active.closed
                ? ChatSnapshotQueryDiagnosticEvent.closed
                : ChatSnapshotQueryDiagnosticEvent.aborted,
            query: query,
            attempt: attempt,
          ),
        );
      }
      return result;
    }

    var accessToken = '';
    Future<bool> obtainToken() async {
      try {
        final token = await _raceSnapshotQueryWithCancellation(
          Future<String>.sync(tokenProvider),
          active.controller.signal,
        );
        if (token.trim().isEmpty) throw const FormatException();
        accessToken = token;
        return true;
      } catch (_) {
        if (interruption() != null) return false;
        _diagnose(
          ChatSnapshotQueryDiagnostic(
            event: ChatSnapshotQueryDiagnosticEvent.tokenFailed,
            query: query,
            attempt: attempt,
          ),
        );
        return false;
      }
    }

    try {
      if (!await obtainToken()) {
        return interruption() ??
            ChatSnapshotQueryAuthenticationFailure<Value>();
      }

      for (var authenticationRefreshes = 0;
          authenticationRefreshes <= 1;
          authenticationRefreshes += 1) {
        final stopped = interruption();
        if (stopped != null) return stopped;
        attempt += 1;

        late final HandrailChatHttpResponse response;
        try {
          response = await _raceSnapshotQueryWithCancellation(
            transport.send(
              HandrailChatHttpRequest(
                method: method,
                uri: uri,
                headers: <String, String>{
                  'Accept': 'application/json',
                  'Authorization': 'Bearer $accessToken',
                  if (body != null) 'Content-Type': 'application/json',
                },
                body: body,
                cancellationSignal: active.controller.signal,
              ),
            ),
            active.controller.signal,
          );
        } catch (_) {
          final stopped = interruption();
          if (stopped != null) return stopped;
          _diagnose(
            ChatSnapshotQueryDiagnostic(
              event: ChatSnapshotQueryDiagnosticEvent.requestFailed,
              query: query,
              attempt: attempt,
            ),
          );
          return ChatSnapshotQueryTransportFailure<Value>();
        }

        if (response.statusCode < 100 || response.statusCode > 599) {
          _diagnoseMalformed(query, attempt);
          return ChatSnapshotQueryMalformedResponse<Value>();
        }

        if (response.statusCode == 401 && authenticationRefreshes == 0) {
          _diagnose(
            ChatSnapshotQueryDiagnostic(
              event: ChatSnapshotQueryDiagnosticEvent.authenticationRefresh,
              query: query,
              attempt: attempt,
              httpStatus: response.statusCode,
            ),
          );
          if (await obtainToken()) continue;
          return interruption() ??
              ChatSnapshotQueryAuthenticationFailure<Value>(
                httpStatus: response.statusCode,
              );
        }

        if (response.statusCode < 200 || response.statusCode >= 300) {
          final result = _classifySnapshotHttpFailure<Value>(
            response.statusCode,
          );
          _diagnose(
            ChatSnapshotQueryDiagnostic(
              event: ChatSnapshotQueryDiagnosticEvent.responseRejected,
              query: query,
              attempt: attempt,
              httpStatus: response.statusCode,
            ),
          );
          return result;
        }

        late final Object? decoded;
        try {
          decoded = jsonDecode(response.body);
        } catch (_) {
          final stopped = interruption();
          if (stopped != null) return stopped;
          _diagnoseMalformed(
            query,
            attempt,
            httpStatus: response.statusCode,
          );
          return ChatSnapshotQueryMalformedResponse<Value>(
            httpStatus: response.statusCode,
          );
        }
        final afterDecode = interruption();
        if (afterDecode != null) return afterDecode;

        try {
          final value = parse(decoded);
          final stopped = interruption();
          if (stopped != null) return stopped;
          _diagnose(
            ChatSnapshotQueryDiagnostic(
              event: ChatSnapshotQueryDiagnosticEvent.completed,
              query: query,
              attempt: attempt,
            ),
          );
          return ChatSnapshotQuerySuccess<Value>(value);
        } catch (_) {
          final stopped = interruption();
          if (stopped != null) return stopped;
          _diagnoseMalformed(
            query,
            attempt,
            httpStatus: response.statusCode,
          );
          return ChatSnapshotQueryMalformedResponse<Value>(
            httpStatus: response.statusCode,
          );
        }
      }
      return ChatSnapshotQueryTransportFailure<Value>();
    } finally {
      await callerCancellation?.cancel();
      _active.remove(active);
    }
  }

  void close() {
    if (_closed) return;
    _closed = true;
    for (final active in _active.toList(growable: false)) {
      active.closed = true;
      active.controller.cancel();
    }
  }

  void _diagnose(ChatSnapshotQueryDiagnostic diagnostic) {
    try {
      onDiagnostic?.call(diagnostic);
    } catch (_) {
      // Diagnostics are observational; thrown values may contain secrets.
    }
  }

  void _diagnoseMalformed(
    ChatSnapshotQueryName query,
    int attempt, {
    int? httpStatus,
  }) {
    _diagnose(
      ChatSnapshotQueryDiagnostic(
        event: ChatSnapshotQueryDiagnosticEvent.responseMalformed,
        query: query,
        attempt: attempt,
        httpStatus: httpStatus,
      ),
    );
  }
}

MessageSearchRequest _validatedMessageSearchRequest(
  HandrailMessageSearchRequest input,
) {
  final filters = <String, Object?>{
    if (input.filters.conversationIds.isNotEmpty)
      'conversationIds': input.filters.conversationIds
          .map((identifier) => identifier.toJson())
          .toList(growable: false),
    if (input.filters.authorUserIds.isNotEmpty)
      'authorUserIds': input.filters.authorUserIds
          .map((identifier) => identifier.toJson())
          .toList(growable: false),
    if (input.filters.sentAfter case final sentAfter?)
      'sentAfter': sentAfter.toJson(),
    if (input.filters.sentBefore case final sentBefore?)
      'sentBefore': sentBefore.toJson(),
  };
  return MessageSearchRequest.fromJson(<String, Object?>{
    'query': input.query,
    if (filters.isNotEmpty) 'filters': filters,
    'pageSize': input.pageSize,
    if (input.pageToken case final pageToken?) 'cursor': pageToken,
  });
}

HandrailMessageSearchPage _adaptMessageSearchResponse(
  MessageSearchResponse response,
  HandrailMessageSearchFilter filters,
) {
  final hits = <HandrailMessageSearchHit>[];
  for (final hit in response.hits) {
    switch (hit) {
      case ConversationMessageSearchHit():
        if (!filters.includeConversationHits) continue;
        hits.add(
          HandrailMessageSearchConversationHit(
            conversationId: hit.conversationId,
            title: hit.title ?? 'Conversation',
            snippet: hit.snippet,
          ),
        );
      case MessageMessageSearchHit():
        if (!filters.includeMessageHits) continue;
        hits.add(
          HandrailMessageSearchMessageHit(
            conversationId: hit.conversationId,
            messageId: hit.messageId,
            title: hit.title ?? hit.authorDisplayName ?? 'Message',
            snippet: hit.snippet,
            authorUserId: hit.authorUserId,
            authorDisplayName: hit.authorDisplayName,
            sentAt: hit.sentAt,
          ),
        );
    }
  }
  return HandrailMessageSearchPage(
    hits: hits,
    nextPageToken: response.nextCursor?.value,
  );
}

Future<Value> _raceSnapshotQueryWithCancellation<Value>(
  Future<Value> future,
  ChatCommandCancellationSignal signal,
) {
  if (signal.isCancelled) {
    return Future<Value>.error(const _SnapshotQueryInterrupted());
  }
  final completer = Completer<Value>();
  late final StreamSubscription<void> subscription;
  subscription = signal.onCancelled.listen((_) {
    if (!completer.isCompleted) {
      completer.completeError(const _SnapshotQueryInterrupted());
    }
  });
  future.then(
    (value) {
      if (!completer.isCompleted) completer.complete(value);
    },
    onError: (Object error, StackTrace stackTrace) {
      if (!completer.isCompleted) completer.completeError(error, stackTrace);
    },
  ).whenComplete(subscription.cancel);
  return completer.future;
}

Uri _conversationListUri(
  Uri baseUri,
  ConversationListSnapshotInput input,
) {
  final parameters = <String, String>{'scope': input.scope.type};
  final scope = input.scope;
  if (scope is EntityConversationSnapshotScope) {
    parameters['entityType'] = scope.entity.type;
    parameters['entityId'] = scope.entity.id;
  }
  final cursor = input.cursor;
  if (cursor != null) parameters['cursor'] = cursor.toJson();
  final limit = input.limit;
  if (limit != null) parameters['limit'] = limit.toString();

  return _snapshotEndpointUri(
    baseUri,
    const <String>['conversations'],
    queryParameters: parameters,
  );
}

Uri _conversationDetailUri(
  Uri baseUri,
  ConversationDetailSnapshotInput input,
) =>
    _snapshotEndpointUri(
      baseUri,
      <String>['conversations', input.conversationId.toJson()],
    );

Uri _messageReminderListUri(
  Uri baseUri,
  MessageReminderListSnapshotInput input,
) =>
    _snapshotEndpointUri(
      baseUri,
      const <String>['message-reminders'],
      queryParameters: {
        'limit': input.limit.toString(),
        if (input.cursor case final cursor?) 'cursor': cursor.toJson(),
      },
    );

Uri _snapshotEndpointUri(
  Uri baseUri,
  List<String> endpointSegments, {
  Map<String, String>? queryParameters,
}) {
  final pathSegments = baseUri.pathSegments.toList();
  while (pathSegments.isNotEmpty && pathSegments.last.isEmpty) {
    pathSegments.removeLast();
  }
  pathSegments.addAll(endpointSegments);
  return Uri(
    scheme: baseUri.scheme,
    userInfo: baseUri.userInfo,
    host: baseUri.host,
    port: baseUri.hasPort ? baseUri.port : null,
    pathSegments: pathSegments,
    queryParameters: queryParameters,
  );
}

bool _sameConversationScope(
  ConversationSnapshotScope left,
  ConversationSnapshotScope right,
) {
  if (left.type != right.type) return false;
  if (left is OrganizationConversationSnapshotScope &&
      right is OrganizationConversationSnapshotScope) {
    return true;
  }
  return left is EntityConversationSnapshotScope &&
      right is EntityConversationSnapshotScope &&
      left.entity.type == right.entity.type &&
      left.entity.id == right.entity.id;
}

ChatSnapshotQueryResult<Value> _classifySnapshotHttpFailure<Value>(
  int httpStatus,
) {
  if (httpStatus == 401 || httpStatus == 403) {
    return ChatSnapshotQueryAuthenticationFailure<Value>(
      httpStatus: httpStatus,
    );
  }
  if (httpStatus >= 400 && httpStatus < 500) {
    return ChatSnapshotQueryRejected<Value>(httpStatus: httpStatus);
  }
  return ChatSnapshotQueryTransportFailure<Value>(httpStatus: httpStatus);
}
