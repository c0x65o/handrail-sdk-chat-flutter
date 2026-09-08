import 'package:unorm_dart/unorm_dart.dart' as unorm;

import 'generated/identifiers.dart';

/// Canonical handshake capability for authorized server message search.
const String messageSearchFeature = 'message_search';

/// Explicit host-owned constraints for one message-search request.
///
/// Collections are defensively copied. The SDK does not interpret these
/// filters against normalized state or cached messages; it passes them to the
/// injected search boundary unchanged.
final class HandrailMessageSearchFilter {
  factory HandrailMessageSearchFilter({
    Iterable<ConversationId> conversationIds = const <ConversationId>[],
    Iterable<UserId> authorUserIds = const <UserId>[],
    IsoTimestamp? sentAfter,
    IsoTimestamp? sentBefore,
    bool includeConversationHits = true,
    bool includeMessageHits = true,
  }) {
    if (!includeConversationHits && !includeMessageHits) {
      throw ArgumentError(
        'At least one search hit type must be included.',
      );
    }
    return HandrailMessageSearchFilter._(
      conversationIds: List<ConversationId>.unmodifiable(conversationIds),
      authorUserIds: List<UserId>.unmodifiable(authorUserIds),
      sentAfter: sentAfter,
      sentBefore: sentBefore,
      includeConversationHits: includeConversationHits,
      includeMessageHits: includeMessageHits,
    );
  }

  const HandrailMessageSearchFilter._({
    required this.conversationIds,
    required this.authorUserIds,
    required this.sentAfter,
    required this.sentBefore,
    required this.includeConversationHits,
    required this.includeMessageHits,
  });

  /// A filter that asks the host boundary for both supported hit types.
  static const empty = HandrailMessageSearchFilter._(
    conversationIds: <ConversationId>[],
    authorUserIds: <UserId>[],
    sentAfter: null,
    sentBefore: null,
    includeConversationHits: true,
    includeMessageHits: true,
  );

  final List<ConversationId> conversationIds;
  final List<UserId> authorUserIds;
  final IsoTimestamp? sentAfter;
  final IsoTimestamp? sentBefore;
  final bool includeConversationHits;
  final bool includeMessageHits;

  @override
  bool operator ==(Object other) =>
      other is HandrailMessageSearchFilter &&
      _messageSearchListsEqual(other.conversationIds, conversationIds) &&
      _messageSearchListsEqual(other.authorUserIds, authorUserIds) &&
      other.sentAfter == sentAfter &&
      other.sentBefore == sentBefore &&
      other.includeConversationHits == includeConversationHits &&
      other.includeMessageHits == includeMessageHits;

  @override
  int get hashCode => Object.hash(
        Object.hashAll(conversationIds),
        Object.hashAll(authorUserIds),
        sentAfter,
        sentBefore,
        includeConversationHits,
        includeMessageHits,
      );
}

/// One transport-neutral request sent to [HandrailMessageSearchDelegate].
///
/// [query] is NFC-normalized, trimmed, and has runs of whitespace collapsed.
/// [pageToken] is opaque and must be passed to the host unchanged.
final class HandrailMessageSearchRequest {
  HandrailMessageSearchRequest({
    required String query,
    required this.filters,
    required this.pageSize,
    this.pageToken,
  }) : query = normalizeHandrailMessageSearchQuery(query) {
    if (pageSize <= 0) {
      throw ArgumentError.value(pageSize, 'pageSize', 'must be positive');
    }
    if (pageToken != null && pageToken!.isEmpty) {
      throw ArgumentError.value(
        pageToken,
        'pageToken',
        'must be null or non-empty',
      );
    }
  }

  final String query;
  final HandrailMessageSearchFilter filters;
  final int pageSize;
  final String? pageToken;
}

/// Normalizes user-entered search text before it reaches a host boundary.
String normalizeHandrailMessageSearchQuery(String value) =>
    unorm.nfc(value.trim().replaceAll(RegExp(r'\s+'), ' '));

/// A typed, immutable result that a host search implementation may return.
sealed class HandrailMessageSearchHit {
  const HandrailMessageSearchHit({
    required this.conversationId,
    required this.title,
    required this.snippet,
  })  : assert(title != ''),
        assert(snippet != '');

  final ConversationId conversationId;

  /// A host-authored display title rendered as plain text.
  final String title;

  /// A host-authored excerpt rendered strictly as plain text.
  ///
  /// HTML, Markdown, and executable markup are never interpreted by the SDK.
  final String snippet;

  /// Stable identity used only to suppress duplicate pages in this widget.
  Object get identityKey;
}

/// A conversation-level search result.
final class HandrailMessageSearchConversationHit
    extends HandrailMessageSearchHit {
  const HandrailMessageSearchConversationHit({
    required super.conversationId,
    required super.title,
    required super.snippet,
  });

  @override
  Object get identityKey =>
      (HandrailMessageSearchConversationHit, conversationId);
}

/// A message-level search result with typed navigation identifiers.
final class HandrailMessageSearchMessageHit extends HandrailMessageSearchHit {
  const HandrailMessageSearchMessageHit({
    required this.messageId,
    required super.conversationId,
    required super.title,
    required super.snippet,
    this.authorUserId,
    this.authorDisplayName,
    this.sentAt,
  });

  final MessageId messageId;
  final UserId? authorUserId;
  final String? authorDisplayName;
  final IsoTimestamp? sentAt;

  @override
  Object get identityKey => (HandrailMessageSearchMessageHit, messageId);
}

/// An immutable host-provided search page.
final class HandrailMessageSearchPage {
  HandrailMessageSearchPage({
    required Iterable<HandrailMessageSearchHit> hits,
    this.nextPageToken,
  }) : hits = List<HandrailMessageSearchHit>.unmodifiable(hits) {
    if (nextPageToken != null && nextPageToken!.isEmpty) {
      throw ArgumentError.value(
        nextPageToken,
        'nextPageToken',
        'must be null or non-empty',
      );
    }
  }

  final List<HandrailMessageSearchHit> hits;

  /// An opaque host-owned token returned unchanged on the next request.
  final String? nextPageToken;
}

/// Searches a host/server-owned index without coupling the UI to a route,
/// local cache, normalized state, or state-management library.
typedef HandrailMessageSearchDelegate = Future<HandrailMessageSearchPage>
    Function(HandrailMessageSearchRequest request);

bool _messageSearchListsEqual<T>(List<T> left, List<T> right) {
  if (identical(left, right)) return true;
  if (left.length != right.length) return false;
  for (var index = 0; index < left.length; index += 1) {
    if (left[index] != right[index]) return false;
  }
  return true;
}
