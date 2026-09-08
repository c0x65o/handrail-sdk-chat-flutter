import 'dart:async';
import 'dart:convert';

import 'package:unorm_dart/unorm_dart.dart' as unorm;

import 'generated/conversation.dart';
import 'generated/conversation_snapshot.dart';
import 'generated/identifiers.dart';
import 'generated/message.dart';
import 'generated/message_timeline.dart';
import 'handrail_chat_client.dart';

/// Stable reasons why a chat deep link could not be parsed safely.
enum ChatDeepLinkMalformedReason {
  invalidUri('invalid_uri'),
  unapprovedOrigin('unapproved_origin'),
  unexpectedUriData('unexpected_uri_data'),
  ambiguousPath('ambiguous_path'),
  invalidIdentifier('invalid_identifier'),
  malformedResponse('malformed_response');

  const ChatDeepLinkMalformedReason(this.value);

  final String value;
}

/// A parsed, router-neutral chat destination.
sealed class ChatDeepLinkTarget {
  const ChatDeepLinkTarget({required this.conversationId});

  final ConversationId conversationId;
  String get kind;
}

/// A link to one conversation.
final class ChatConversationDeepLinkTarget extends ChatDeepLinkTarget {
  const ChatConversationDeepLinkTarget({required super.conversationId});

  @override
  String get kind => 'conversation';
}

/// A link to one message in a conversation.
final class ChatMessageDeepLinkTarget extends ChatDeepLinkTarget {
  const ChatMessageDeepLinkTarget({
    required super.conversationId,
    required this.messageId,
  });

  final MessageId messageId;

  @override
  String get kind => 'message';
}

/// A link to the thread rooted at one message in a parent conversation.
final class ChatThreadDeepLinkTarget extends ChatDeepLinkTarget {
  const ChatThreadDeepLinkTarget({
    required super.conversationId,
    required this.rootMessageId,
  });

  final MessageId rootMessageId;

  @override
  String get kind => 'thread';
}

/// A canonical thread-ID link, optionally targeting a message in its history.
final class ChatExistingThreadDeepLinkTarget extends ChatDeepLinkTarget {
  const ChatExistingThreadDeepLinkTarget(
      {required ConversationId threadId, this.messageId})
      : super(conversationId: threadId);

  ConversationId get threadId => conversationId;
  final MessageId? messageId;

  @override
  String get kind => messageId == null ? 'thread' : 'message';
}

/// The result of parsing a URI against configured chat link prefixes.
sealed class ChatDeepLinkParseResult {
  const ChatDeepLinkParseResult();

  String get status;
}

final class ChatDeepLinkParseSuccess extends ChatDeepLinkParseResult {
  const ChatDeepLinkParseSuccess(this.target);

  final ChatDeepLinkTarget target;

  @override
  String get status => 'success';
}

final class ChatDeepLinkParseFailure extends ChatDeepLinkParseResult {
  const ChatDeepLinkParseFailure(this.reason);

  final ChatDeepLinkMalformedReason reason;

  @override
  String get status => 'malformed';
}

/// Parses only links below explicitly approved absolute URI prefixes.
///
/// A prefix such as `https://erp.example.com/chat` accepts exactly these
/// shapes below `/chat`:
///
/// * `conversations/:conversationId`
/// * `conversations/:conversationId/messages/:messageId`
/// * `conversations/:conversationId/threads/:rootMessageId` (legacy root)
/// * `threads/:threadId`
/// * `threads/:threadId/messages/:messageId`
/// Conversation/message links whose conversation is a thread also open by ID.
///
/// Scheme, host, effective port, and complete prefix path segments must match.
/// Identifiers are decoded exactly once by [Uri.pathSegments].
final class ChatDeepLinkParser {
  ChatDeepLinkParser({required Iterable<Uri> approvedUriPrefixes})
      : _prefixes = _validatedPrefixes(approvedUriPrefixes);

  final List<_ApprovedChatUriPrefix> _prefixes;

  ChatDeepLinkParseResult parse(String location) {
    late final Uri uri;
    try {
      uri = Uri.parse(location);
    } catch (_) {
      return const ChatDeepLinkParseFailure(
        ChatDeepLinkMalformedReason.invalidUri,
      );
    }
    return parseUri(uri);
  }

  ChatDeepLinkParseResult parseUri(Uri uri) {
    if (!uri.hasScheme || !uri.hasAuthority || uri.host.isEmpty) {
      return const ChatDeepLinkParseFailure(
        ChatDeepLinkMalformedReason.invalidUri,
      );
    }
    if (uri.userInfo.isNotEmpty || uri.hasQuery || uri.hasFragment) {
      return const ChatDeepLinkParseFailure(
        ChatDeepLinkMalformedReason.unexpectedUriData,
      );
    }

    late final List<String> segments;
    try {
      segments = uri.pathSegments;
    } catch (_) {
      return const ChatDeepLinkParseFailure(
        ChatDeepLinkMalformedReason.invalidUri,
      );
    }

    _ApprovedChatUriPrefix? matched;
    for (final prefix in _prefixes) {
      if (!prefix.matchesOrigin(uri) ||
          !_startsWithSegments(segments, prefix.pathSegments)) {
        continue;
      }
      if (matched == null ||
          prefix.pathSegments.length > matched.pathSegments.length) {
        matched = prefix;
      }
    }
    if (matched == null) {
      return const ChatDeepLinkParseFailure(
        ChatDeepLinkMalformedReason.unapprovedOrigin,
      );
    }

    final route = segments.sublist(matched.pathSegments.length);
    if (route.any((segment) => segment.isEmpty)) {
      return const ChatDeepLinkParseFailure(
        ChatDeepLinkMalformedReason.ambiguousPath,
      );
    }
    if (route.length != 2 && route.length != 4) {
      return const ChatDeepLinkParseFailure(
        ChatDeepLinkMalformedReason.ambiguousPath,
      );
    }
    if (route[0] == 'threads') {
      if (!_isValidDeepLinkIdentifier(route[1]) ||
          (route.length == 4 && !_isValidDeepLinkIdentifier(route[3]))) {
        return const ChatDeepLinkParseFailure(
            ChatDeepLinkMalformedReason.invalidIdentifier);
      }
      if (route.length == 4 && route[2] != 'messages') {
        return const ChatDeepLinkParseFailure(
            ChatDeepLinkMalformedReason.ambiguousPath);
      }
      return ChatDeepLinkParseSuccess(ChatExistingThreadDeepLinkTarget(
        threadId: ConversationId(route[1]),
        messageId: route.length == 4 ? MessageId(route[3]) : null,
      ));
    }
    if (route[0] != 'conversations') {
      return const ChatDeepLinkParseFailure(
        ChatDeepLinkMalformedReason.ambiguousPath,
      );
    }
    if (!_isValidDeepLinkIdentifier(route[1])) {
      return const ChatDeepLinkParseFailure(
        ChatDeepLinkMalformedReason.invalidIdentifier,
      );
    }
    final conversationId = ConversationId(route[1]);
    if (route.length == 2) {
      return ChatDeepLinkParseSuccess(
        ChatConversationDeepLinkTarget(conversationId: conversationId),
      );
    }
    if (!_isValidDeepLinkIdentifier(route[3])) {
      return const ChatDeepLinkParseFailure(
        ChatDeepLinkMalformedReason.invalidIdentifier,
      );
    }
    return switch (route[2]) {
      'messages' => ChatDeepLinkParseSuccess(
          ChatMessageDeepLinkTarget(
            conversationId: conversationId,
            messageId: MessageId(route[3]),
          ),
        ),
      'threads' => ChatDeepLinkParseSuccess(
          ChatThreadDeepLinkTarget(
            conversationId: conversationId,
            rootMessageId: MessageId(route[3]),
          ),
        ),
      _ => const ChatDeepLinkParseFailure(
          ChatDeepLinkMalformedReason.ambiguousPath,
        ),
    };
  }
}

/// A fully authorized and hydrated destination passed to the host application.
sealed class ChatResolvedDeepLinkTarget {
  const ChatResolvedDeepLinkTarget({
    required this.target,
    required this.conversation,
    this.threadOpeningState,
  });

  final ChatDeepLinkTarget target;
  final ConversationDetailSnapshot conversation;
  final ChatThreadOpeningReadyState? threadOpeningState;
  String get kind => target.kind;
}

final class ChatResolvedConversationDeepLinkTarget
    extends ChatResolvedDeepLinkTarget {
  const ChatResolvedConversationDeepLinkTarget({
    required ChatConversationDeepLinkTarget target,
    required super.conversation,
    super.threadOpeningState,
  }) : super(target: target);

  @override
  ChatConversationDeepLinkTarget get target =>
      super.target as ChatConversationDeepLinkTarget;
}

final class ChatResolvedMessageDeepLinkTarget
    extends ChatResolvedDeepLinkTarget {
  const ChatResolvedMessageDeepLinkTarget({
    required ChatMessageDeepLinkTarget target,
    required super.conversation,
    super.threadOpeningState,
    required this.message,
  }) : super(target: target);

  @override
  ChatMessageDeepLinkTarget get target =>
      super.target as ChatMessageDeepLinkTarget;

  final Message message;
}

final class ChatResolvedThreadDeepLinkTarget
    extends ChatResolvedDeepLinkTarget {
  const ChatResolvedThreadDeepLinkTarget({
    required ChatThreadDeepLinkTarget target,
    required super.conversation,
    super.threadOpeningState,
    required this.rootMessage,
    required this.threadConversation,
  }) : super(target: target);

  @override
  ChatThreadDeepLinkTarget get target =>
      super.target as ChatThreadDeepLinkTarget;

  final Message rootMessage;
  final ThreadConversation threadConversation;
}

/// Canonical thread history, including safe deleted/unavailable root context.
final class ChatResolvedExistingThreadDeepLinkTarget
    extends ChatResolvedDeepLinkTarget {
  const ChatResolvedExistingThreadDeepLinkTarget({
    required super.target,
    required super.conversation,
    required ChatThreadOpeningReadyState openingState,
    this.message,
  }) : super(threadOpeningState: openingState);

  final Message? message;
}

/// Router-neutral host callback invoked after successful hydration.
typedef ChatDeepLinkOpenDelegate = FutureOr<void> Function(
  ChatResolvedDeepLinkTarget target,
);

enum ChatDeepLinkUnavailableReason {
  clientError('client_error'),
  refreshRequired('refresh_required'),
  transport('transport'),
  closed('closed'),
  aborted('aborted'),
  threadOpening('thread_opening'),
  hostDelegate('host_delegate');

  const ChatDeepLinkUnavailableReason(this.value);

  final String value;
}

/// Stable result of resolving and, on success, opening one chat deep link.
sealed class ChatDeepLinkResolutionResult {
  const ChatDeepLinkResolutionResult();

  String get status;
}

final class ChatDeepLinkResolutionSuccess extends ChatDeepLinkResolutionResult {
  const ChatDeepLinkResolutionSuccess(this.target);

  final ChatResolvedDeepLinkTarget target;

  @override
  String get status => 'success';
}

final class ChatDeepLinkResolutionMalformed
    extends ChatDeepLinkResolutionResult {
  const ChatDeepLinkResolutionMalformed(this.reason);

  final ChatDeepLinkMalformedReason reason;

  @override
  String get status => 'malformed';
}

final class ChatDeepLinkResolutionDenied extends ChatDeepLinkResolutionResult {
  const ChatDeepLinkResolutionDenied();

  @override
  String get status => 'denied';
}

final class ChatDeepLinkResolutionNotFound
    extends ChatDeepLinkResolutionResult {
  const ChatDeepLinkResolutionNotFound();

  @override
  String get status => 'not_found';
}

final class ChatDeepLinkResolutionUnavailable
    extends ChatDeepLinkResolutionResult {
  const ChatDeepLinkResolutionUnavailable(this.reason);

  final ChatDeepLinkUnavailableReason reason;

  @override
  String get status => 'unavailable';
}

/// Authorizes, hydrates, and hands chat deep links to a host-owned navigator.
///
/// Parsing and identifier validation always finish before client readiness,
/// authentication, transport, normalized-state, controller, or delegate work.
final class ChatDeepLinkResolver {
  ChatDeepLinkResolver({
    required HandrailChatClient client,
    required Iterable<Uri> approvedUriPrefixes,
    required ChatDeepLinkOpenDelegate openTarget,
  })  : _client = client,
        _parser = ChatDeepLinkParser(
          approvedUriPrefixes: approvedUriPrefixes,
        ),
        _openTarget = openTarget;

  final HandrailChatClient _client;
  final ChatDeepLinkParser _parser;
  final ChatDeepLinkOpenDelegate _openTarget;

  ChatDeepLinkParser get parser => _parser;

  Future<ChatDeepLinkResolutionResult> resolve(String location) async {
    final parsed = _parser.parse(location);
    if (parsed case ChatDeepLinkParseFailure(:final reason)) {
      return ChatDeepLinkResolutionMalformed(reason);
    }
    return resolveTarget((parsed as ChatDeepLinkParseSuccess).target);
  }

  Future<ChatDeepLinkResolutionResult> resolveUri(Uri uri) async {
    final parsed = _parser.parseUri(uri);
    if (parsed case ChatDeepLinkParseFailure(:final reason)) {
      return ChatDeepLinkResolutionMalformed(reason);
    }
    return resolveTarget((parsed as ChatDeepLinkParseSuccess).target);
  }

  Future<ChatDeepLinkResolutionResult> resolveTarget(
    ChatDeepLinkTarget target,
  ) async {
    if (!_isValidTarget(target)) {
      return const ChatDeepLinkResolutionMalformed(
        ChatDeepLinkMalformedReason.invalidIdentifier,
      );
    }
    final readiness = await _awaitReadiness();
    if (readiness != null) return readiness;

    if (target is ChatExistingThreadDeepLinkTarget) {
      return _openExisting(target, target.threadId,
          messageId: target.messageId);
    }

    final hydratedConversation = await _hydrateConversation(
      target.conversationId,
    );
    if (hydratedConversation is ChatDeepLinkResolutionResult) {
      return hydratedConversation;
    }
    final conversation = hydratedConversation as ConversationDetailSnapshot;

    if (conversation.conversation.summary.conversation is ThreadConversation &&
        target is! ChatThreadDeepLinkTarget) {
      return _openExisting(target, target.conversationId,
          messageId:
              target is ChatMessageDeepLinkTarget ? target.messageId : null);
    }

    if (target is ChatConversationDeepLinkTarget) {
      return _open(
        ChatResolvedConversationDeepLinkTarget(
          target: target,
          conversation: conversation,
        ),
      );
    }

    final messageId = switch (target) {
      ChatMessageDeepLinkTarget(:final messageId) => messageId,
      ChatThreadDeepLinkTarget(:final rootMessageId) => rootMessageId,
      _ => throw StateError('Unsupported chat deep-link target.'),
    };
    final hydratedMessage = await _hydrateMessage(
      target.conversationId,
      messageId,
    );
    if (hydratedMessage is ChatDeepLinkResolutionResult) {
      if (target is ChatThreadDeepLinkTarget &&
          hydratedMessage is ChatDeepLinkResolutionNotFound) {
        final known = _knownThread(target);
        if (known != null) return _openExisting(target, known.id);
        return const ChatDeepLinkResolutionUnavailable(
            ChatDeepLinkUnavailableReason.threadOpening);
      }
      return hydratedMessage;
    }
    final message = hydratedMessage as Message;

    if (target is ChatMessageDeepLinkTarget) {
      return _open(
        ChatResolvedMessageDeepLinkTarget(
          target: target,
          conversation: conversation,
          message: message,
        ),
      );
    }

    final threadTarget = target as ChatThreadDeepLinkTarget;
    final known = _knownThread(threadTarget);
    late final ChatThreadOpenHandle handle;
    if (known == null) {
      final opened =
          await _client.threads.open(rootMessageId: threadTarget.rootMessageId);
      if (opened case ChatThreadOpenFailure(:final error)) {
        return _mapThreadFailure(error);
      }
      handle = (opened as ChatThreadOpenSuccess).handle;
    } else {
      final opened = await _client.openExistingThread(known.id);
      if (opened
          case ChatExistingThreadOpenFailure(:final code, :final httpStatus)) {
        return _mapOpeningFailure(code, httpStatus);
      }
      handle = (opened as ChatExistingThreadOpenSuccess).handle;
    }
    try {
      if (!_matchesLegacyThread(threadTarget, handle)) {
        return const ChatDeepLinkResolutionMalformed(
            ChatDeepLinkMalformedReason.malformedResponse);
      }
      if (known != null &&
          handle.state.rootContextStatus !=
              ChatThreadRootContextStatus.available) {
        return await _open(ChatResolvedExistingThreadDeepLinkTarget(
            target: threadTarget,
            conversation: handle.state.detail!,
            openingState: handle.state));
      }
      return await _open(
        ChatResolvedThreadDeepLinkTarget(
          target: threadTarget,
          conversation: conversation,
          rootMessage: known == null ? message : handle.state.rootMessage!,
          threadConversation: handle.conversation,
          threadOpeningState: known == null ? null : handle.state,
        ),
      );
    } finally {
      handle.release();
    }
  }

  bool _matchesLegacyThread(
          ChatThreadDeepLinkTarget target, ChatThreadOpenHandle handle) =>
      target.rootMessageId == handle.rootMessageId &&
      target.conversationId == handle.state.parentConversationId;

  ThreadConversation? _knownThread(ChatThreadDeepLinkTarget target) {
    ThreadConversation? found;
    for (final conversation
        in _client.normalizedState.state.conversations.values) {
      if (conversation is! ThreadConversation ||
          conversation.parentConversationId != target.conversationId ||
          conversation.rootMessageId != target.rootMessageId) {
        continue;
      }
      if (found != null && found.id != conversation.id) return null;
      found = conversation;
    }
    return found;
  }

  Future<ChatDeepLinkResolutionResult> _openExisting(
      ChatDeepLinkTarget target, ConversationId threadId,
      {MessageId? messageId}) async {
    final opened = await _client.openExistingThread(threadId);
    if (opened
        case ChatExistingThreadOpenFailure(:final code, :final httpStatus)) {
      return _mapOpeningFailure(code, httpStatus);
    }
    final handle = (opened as ChatExistingThreadOpenSuccess).handle;
    try {
      if (target is ChatThreadDeepLinkTarget &&
          !_matchesLegacyThread(target, handle)) {
        return const ChatDeepLinkResolutionMalformed(
            ChatDeepLinkMalformedReason.malformedResponse);
      }
      Message? message;
      if (messageId != null) {
        final result = await _hydrateMessage(threadId, messageId);
        if (result is ChatDeepLinkResolutionResult) return result;
        message = result as Message;
      }
      final detail = handle.state.detail!;
      if (target is ChatConversationDeepLinkTarget) {
        return await _open(ChatResolvedConversationDeepLinkTarget(
            target: target,
            conversation: detail,
            threadOpeningState: handle.state));
      }
      if (target is ChatMessageDeepLinkTarget) {
        return await _open(ChatResolvedMessageDeepLinkTarget(
            target: target,
            conversation: detail,
            message: message!,
            threadOpeningState: handle.state));
      }
      return await _open(ChatResolvedExistingThreadDeepLinkTarget(
          target: target,
          conversation: detail,
          openingState: handle.state,
          message: message));
    } finally {
      handle.release();
    }
  }

  Future<ChatDeepLinkResolutionResult?> _awaitReadiness() async {
    var state = _client.state;
    if (state is ChatClientIdleState || state is ChatClientInitializingState) {
      try {
        state = await _client.initialize();
      } catch (_) {
        return const ChatDeepLinkResolutionUnavailable(
          ChatDeepLinkUnavailableReason.closed,
        );
      }
    }
    return switch (state) {
      ChatClientReadyState() => null,
      ChatClientRefreshRequiredState() =>
        const ChatDeepLinkResolutionUnavailable(
          ChatDeepLinkUnavailableReason.refreshRequired,
        ),
      ChatClientErrorState() => const ChatDeepLinkResolutionUnavailable(
          ChatDeepLinkUnavailableReason.clientError,
        ),
      _ => const ChatDeepLinkResolutionUnavailable(
          ChatDeepLinkUnavailableReason.clientError,
        ),
    };
  }

  Future<Object> _hydrateConversation(ConversationId conversationId) async {
    final result = await _client.getConversation(
      ConversationDetailSnapshotInput(conversationId: conversationId),
    );
    if (result
        case ChatSnapshotQuerySuccess<ConversationDetailSnapshot>(
          :final value,
        )) {
      try {
        _client.normalizedState.hydrateConversationDetail(value);
      } catch (_) {
        return const ChatDeepLinkResolutionMalformed(
          ChatDeepLinkMalformedReason.malformedResponse,
        );
      }
      return value;
    }
    return _mapQueryFailure(result);
  }

  Future<Object> _hydrateMessage(
    ConversationId conversationId,
    MessageId messageId,
  ) async {
    MessageSequence? cursor;
    final visitedCursors = <int>{};
    while (true) {
      final result = await _client.getMessageTimeline(
        MessageTimelineRequest(
          conversationId: conversationId,
          direction: MessageTimelineDirection.backward,
          cursor: cursor,
          limit: messageTimelineMaximumLimit,
        ),
      );
      if (result is! ChatSnapshotQuerySuccess<MessageTimelinePage>) {
        return _mapQueryFailure(result);
      }
      final page = result.value;
      try {
        _client.normalizedState.hydrateMessageTimeline(page);
      } catch (_) {
        return const ChatDeepLinkResolutionMalformed(
          ChatDeepLinkMalformedReason.malformedResponse,
        );
      }
      for (final row in page.messages) {
        if (row.id == messageId) {
          return row.message is DeletedMessage
              ? const ChatDeepLinkResolutionNotFound()
              : row.message;
        }
      }

      final older = page.pagination.older;
      final nextCursor = older.cursor;
      if (!older.available || nextCursor == null) {
        return const ChatDeepLinkResolutionNotFound();
      }
      if (!visitedCursors.add(nextCursor.value)) {
        return const ChatDeepLinkResolutionMalformed(
          ChatDeepLinkMalformedReason.malformedResponse,
        );
      }
      cursor = nextCursor;
    }
  }

  ChatDeepLinkResolutionResult _mapQueryFailure<Value>(
    ChatSnapshotQueryResult<Value> result,
  ) {
    if (result is ChatSnapshotQueryAuthenticationFailure<Value> ||
        (result is ChatSnapshotQueryRejected<Value> &&
            result.httpStatus == 403)) {
      return const ChatDeepLinkResolutionDenied();
    }
    if (result is ChatSnapshotQueryRejected<Value> &&
        result.httpStatus == 404) {
      return const ChatDeepLinkResolutionNotFound();
    }
    if (result is ChatSnapshotQueryMalformedResponse<Value> ||
        result is ChatSnapshotQueryValidationFailure<Value>) {
      return const ChatDeepLinkResolutionMalformed(
        ChatDeepLinkMalformedReason.malformedResponse,
      );
    }
    if (result is ChatSnapshotQueryClosed<Value>) {
      return const ChatDeepLinkResolutionUnavailable(
        ChatDeepLinkUnavailableReason.closed,
      );
    }
    if (result is ChatSnapshotQueryAborted<Value>) {
      return const ChatDeepLinkResolutionUnavailable(
        ChatDeepLinkUnavailableReason.aborted,
      );
    }
    return const ChatDeepLinkResolutionUnavailable(
      ChatDeepLinkUnavailableReason.transport,
    );
  }

  ChatDeepLinkResolutionResult _mapThreadFailure(
    ChatThreadOpeningErrorState error,
  ) =>
      _mapOpeningFailure(error.code, error.httpStatus);

  ChatDeepLinkResolutionResult _mapOpeningFailure(
    ChatThreadOpeningErrorCode code,
    int? httpStatus,
  ) =>
      switch (code) {
        ChatThreadOpeningErrorCode.authentication =>
          const ChatDeepLinkResolutionDenied(),
        ChatThreadOpeningErrorCode.rootMessageUnavailable =>
          const ChatDeepLinkResolutionNotFound(),
        ChatThreadOpeningErrorCode.http when httpStatus == 404 =>
          const ChatDeepLinkResolutionNotFound(),
        ChatThreadOpeningErrorCode.validation ||
        ChatThreadOpeningErrorCode.malformedResponse ||
        ChatThreadOpeningErrorCode.reconciliation =>
          const ChatDeepLinkResolutionMalformed(
            ChatDeepLinkMalformedReason.malformedResponse,
          ),
        ChatThreadOpeningErrorCode.closed =>
          const ChatDeepLinkResolutionUnavailable(
            ChatDeepLinkUnavailableReason.closed,
          ),
        ChatThreadOpeningErrorCode.aborted =>
          const ChatDeepLinkResolutionUnavailable(
            ChatDeepLinkUnavailableReason.aborted,
          ),
        _ => const ChatDeepLinkResolutionUnavailable(
            ChatDeepLinkUnavailableReason.threadOpening,
          ),
      };

  Future<ChatDeepLinkResolutionResult> _open(
    ChatResolvedDeepLinkTarget target,
  ) async {
    try {
      await Future<void>.sync(() => _openTarget(target));
    } catch (_) {
      return const ChatDeepLinkResolutionUnavailable(
        ChatDeepLinkUnavailableReason.hostDelegate,
      );
    }
    return ChatDeepLinkResolutionSuccess(target);
  }
}

final class _ApprovedChatUriPrefix {
  const _ApprovedChatUriPrefix({
    required this.scheme,
    required this.host,
    required this.effectivePort,
    required this.pathSegments,
  });

  final String scheme;
  final String host;
  final int? effectivePort;
  final List<String> pathSegments;

  bool matchesOrigin(Uri uri) =>
      uri.scheme.toLowerCase() == scheme &&
      uri.host.toLowerCase() == host &&
      _effectivePort(uri) == effectivePort;
}

List<_ApprovedChatUriPrefix> _validatedPrefixes(Iterable<Uri> prefixes) {
  final approved = <_ApprovedChatUriPrefix>[];
  final seen = <String>{};
  for (final prefix in prefixes) {
    if (!prefix.hasScheme ||
        !prefix.hasAuthority ||
        prefix.host.isEmpty ||
        prefix.userInfo.isNotEmpty ||
        prefix.hasQuery ||
        prefix.hasFragment) {
      throw ArgumentError.value(
        prefix,
        'approvedUriPrefixes',
        'Each prefix must be an absolute host URI without user-info, query, '
            'or fragment data.',
      );
    }
    final pathSegments = prefix.pathSegments.toList(growable: true);
    while (pathSegments.isNotEmpty && pathSegments.last.isEmpty) {
      pathSegments.removeLast();
    }
    if (pathSegments.any((segment) => segment.isEmpty)) {
      throw ArgumentError.value(
        prefix,
        'approvedUriPrefixes',
        'Prefix paths must not contain empty segments.',
      );
    }
    final scheme = prefix.scheme.toLowerCase();
    final host = prefix.host.toLowerCase();
    final port = _effectivePort(prefix);
    final key = '$scheme|$host|$port|${jsonEncode(pathSegments)}';
    if (!seen.add(key)) continue;
    approved.add(_ApprovedChatUriPrefix(
      scheme: scheme,
      host: host,
      effectivePort: port,
      pathSegments: List.unmodifiable(pathSegments),
    ));
  }
  if (approved.isEmpty) {
    throw ArgumentError.value(
      prefixes,
      'approvedUriPrefixes',
      'At least one approved URI prefix is required.',
    );
  }
  return List.unmodifiable(approved);
}

int? _effectivePort(Uri uri) {
  if (uri.hasPort) return uri.port;
  return switch (uri.scheme.toLowerCase()) {
    'http' => 80,
    'https' => 443,
    _ => null,
  };
}

bool _startsWithSegments(List<String> value, List<String> prefix) {
  if (value.length < prefix.length) return false;
  for (var index = 0; index < prefix.length; index += 1) {
    if (value[index] != prefix[index]) return false;
  }
  return true;
}

bool _isValidTarget(ChatDeepLinkTarget target) {
  if (!_isValidDeepLinkIdentifier(target.conversationId.value)) return false;
  return switch (target) {
    ChatExistingThreadDeepLinkTarget(:final messageId) =>
      messageId == null || _isValidDeepLinkIdentifier(messageId.value),
    ChatMessageDeepLinkTarget(:final messageId) =>
      _isValidDeepLinkIdentifier(messageId.value),
    ChatThreadDeepLinkTarget(:final rootMessageId) =>
      _isValidDeepLinkIdentifier(rootMessageId.value),
    _ => true,
  };
}

bool _isValidDeepLinkIdentifier(String value) {
  try {
    return value.isNotEmpty &&
        value.trim() == value &&
        utf8.encode(value).length <= 256 &&
        unorm.nfc(value) == value &&
        !RegExp(r'[\u0000-\u001f\u007f-\u009f]').hasMatch(value);
  } catch (_) {
    return false;
  }
}
