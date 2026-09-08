import 'dart:convert';

import 'package:handrail_chat/core.dart';
import 'package:test/test.dart';

import 'fixtures/message_search_fixtures.dart';

void main() {
  test('normalizes and round-trips valid filtered opaque pagination', () {
    final request = MessageSearchRequest.fromJson(
      _roundTrip(messageSearchRequestFixture),
    );
    expect(request.query, 'Café order updates');
    expect(request.filters?.conversationIds, const [
      ConversationId('conversation-1'),
      ConversationId('conversation-2'),
    ]);
    expect(request.filters?.authorUserIds, const [UserId('user-1')]);
    expect(request.cursor?.value, 'opaque.page.2');
    expect(request.toJson(), normalizedMessageSearchRequestFixture);
    expect(normalizeMessageSearchQuery(' \tCafe\u0301\n order '), 'Café order');
  });

  test('rejects empty queries, malformed filters, timestamps, and ranges', () {
    final invalid = <(Map<String, Object?>, MessageSearchParseErrorCode)>[
      (
        {'query': ' \n ', 'pageSize': 10},
        MessageSearchParseErrorCode.malformedRequest
      ),
      (
        {...messageSearchRequestFixture, 'filters': null},
        MessageSearchParseErrorCode.malformedFilters
      ),
      (
        {
          ...messageSearchRequestFixture,
          'filters': {'conversationIds': 'one'}
        },
        MessageSearchParseErrorCode.malformedFilters
      ),
      (
        {
          ...messageSearchRequestFixture,
          'filters': {
            'conversationIds': [' ']
          }
        },
        MessageSearchParseErrorCode.invalidIdentifier
      ),
      (
        {
          ...messageSearchRequestFixture,
          'filters': {
            'authorUserIds': ['user-1', 'user-1']
          }
        },
        MessageSearchParseErrorCode.duplicateIdentifier
      ),
      (
        {
          ...messageSearchRequestFixture,
          'filters': {'sentAfter': 'August 1'}
        },
        MessageSearchParseErrorCode.invalidTimestamp
      ),
      (
        {
          ...messageSearchRequestFixture,
          'filters': {'sentAfter': '2026-02-31T00:00:00Z'}
        },
        MessageSearchParseErrorCode.invalidTimestamp
      ),
      (
        {
          ...messageSearchRequestFixture,
          'filters': {
            'sentAfter': '2026-08-02T00:00:00Z',
            'sentBefore': '2026-08-01T00:00:00Z'
          }
        },
        MessageSearchParseErrorCode.invalidTimeRange
      ),
      (
        {
          ...messageSearchRequestFixture,
          'filters': {
            'sentAfter': '2026-08-01T00:00:00Z',
            'sentBefore': '2026-08-01T00:00:00Z'
          }
        },
        MessageSearchParseErrorCode.invalidTimeRange
      ),
    ];
    for (final (wire, code) in invalid) {
      expect(
          () => MessageSearchRequest.fromJson(wire), throwsA(_errorCode(code)));
    }
  });

  test('rejects page-size bounds and malformed request/result cursors', () {
    for (final pageSize in <Object?>[0, 101, 1.5, '10', null]) {
      expect(
        () => MessageSearchRequest.fromJson(
            {'query': 'orders', 'pageSize': pageSize}),
        throwsA(_errorCode(MessageSearchParseErrorCode.invalidPageSize)),
      );
    }
    for (final cursor in <Object?>['', ' \n ', 'x' * 2049, 42, null]) {
      expect(
        () => MessageSearchRequest.fromJson(
            {'query': 'orders', 'pageSize': 10, 'cursor': cursor}),
        throwsA(_errorCode(MessageSearchParseErrorCode.malformedCursor)),
      );
      expect(
        () => MessageSearchResponse.fromJson(
            {'hits': <Object?>[], 'nextCursor': cursor}),
        throwsA(_errorCode(MessageSearchParseErrorCode.malformedCursor)),
      );
    }
  });

  test('rejects normalized trusted aliases recursively', () {
    for (final alias in <String>[
      'tenant-id',
      'ORGANIZATION_id',
      'Actor.User.ID',
      'current_user_id',
      'session-id',
      'AUTHORIZATION',
      'roles',
      'capabilities',
      'per-missions',
    ]) {
      expect(
        () => MessageSearchRequest.fromJson(
            {...messageSearchRequestFixture, alias: 'spoofed'}),
        throwsA(_errorCode(MessageSearchParseErrorCode.trustedIdentityField)),
        reason: alias,
      );
    }
    expect(
      () => MessageSearchRequest.fromJson({
        ...messageSearchRequestFixture,
        'filters': {
          'conversationIds': ['conversation-1'],
          'nested': {'currentActorId': 'spoofed'},
        },
      }),
      throwsA(_errorCode(MessageSearchParseErrorCode.trustedIdentityField)),
    );
  });

  test('decodes and encodes ordered discriminated result hits', () {
    final response = MessageSearchResponse.fromJson(
      _roundTrip(messageSearchResponseFixture),
    );
    expect(response.hits[0], isA<MessageMessageSearchHit>());
    expect(response.hits[1], isA<ConversationMessageSearchHit>());
    expect(response.nextCursor?.value, 'opaque.page.3');
    expect(response.toJson(), messageSearchResponseFixture);
  });

  test('rejects malformed hit unions, blank snippets, and duplicates', () {
    final fixtureHits = messageSearchResponseFixture['hits']! as List<Object?>;
    final message = Map<String, Object?>.from(
      fixtureHits.first! as Map,
    );
    final conversation = Map<String, Object?>.from(
      fixtureHits[1]! as Map,
    );
    final invalid = <(Map<String, Object?>, MessageSearchParseErrorCode)>[
      ({...message, 'type': 'file'}, MessageSearchParseErrorCode.malformedHit),
      (
        {...message}..remove('messageId'),
        MessageSearchParseErrorCode.invalidIdentifier
      ),
      ({...message, 'snippet': '  '}, MessageSearchParseErrorCode.malformedHit),
      (
        {...message, 'sentAt': 'not-a-time'},
        MessageSearchParseErrorCode.malformedHit
      ),
      ({...message, 'extra': true}, MessageSearchParseErrorCode.malformedHit),
      (
        {...conversation, 'messageId': 'message-2'},
        MessageSearchParseErrorCode.malformedHit
      ),
      (
        {...conversation, 'authorUserId': 'user-1'},
        MessageSearchParseErrorCode.malformedHit
      ),
    ];
    for (final (hit, code) in invalid) {
      expect(
        () => MessageSearchResponse.fromJson({
          'hits': [hit]
        }),
        throwsA(_errorCode(code)),
      );
    }
    expect(
      () => MessageSearchResponse.fromJson({
        'hits': [
          message,
          {...message, 'conversationId': 'conversation-2'}
        ]
      }),
      throwsA(_errorCode(MessageSearchParseErrorCode.duplicateHitIdentity)),
    );
    expect(
      () => MessageSearchResponse.fromJson({
        'hits': [
          conversation,
          {...conversation, 'title': 'Duplicate'}
        ]
      }),
      throwsA(_errorCode(MessageSearchParseErrorCode.duplicateHitIdentity)),
    );
  });
}

Matcher _errorCode(MessageSearchParseErrorCode code) =>
    isA<MessageSearchFormatException>()
        .having((error) => error.code, 'code', code);

Object? _roundTrip(Object? value) => jsonDecode(jsonEncode(value));
