import 'dart:convert';

import 'package:handrail_chat/core.dart';
import 'package:test/test.dart';

void main() {
  test('request and applied/replayed authoritative results round-trip', () {
    final request = ForwardMessageRequest.fromJson(_roundTrip(_request));
    expect(request.toJson(), _request);

    for (final status in ['applied', 'replayed']) {
      final wire = _result(status);
      final result = ForwardMessageResult.fromJson(
        _roundTrip(wire),
        request: request,
      );
      expect(result.toJson(), wire);
      expect(result.message.author.userId, const UserId('forwarding-user'));
      expect(
        result.message.content.forwarded!.originalAuthor.displayName,
        'Original Author',
      );
      expect(result.canonicalRevision, 1);
    }
  });

  test('snapshot is copied during parsing and remains stable', () {
    final request = ForwardMessageRequest.fromJson(_request);
    final wire = _result('applied');
    final result = ForwardMessageResult.fromJson(wire, request: request);
    final message = wire['message']! as Map<String, Object?>;
    final content = message['content']! as Map<String, Object?>;
    content['text'] = 'later source edit';
    final forwarded = content['forwarded']! as Map<String, Object?>;
    final author = forwarded['originalAuthor']! as Map<String, Object?>;
    author['displayName'] = 'later renamed author';

    expect(result.message.content.text, 'Frozen **source** text');
    expect(
      result.message.content.forwarded!.originalAuthor.displayName,
      'Original Author',
    );
  });

  test('request recursively rejects trusted and server-owned fields', () {
    for (final fixture in <(String, Object?, ForwardMessageErrorCode)>[
      ('tenant-id', 'spoofed', ForwardMessageErrorCode.trustedIdentityField),
      (
        'author',
        {'userId': 'spoofed'},
        ForwardMessageErrorCode.trustedIdentityField
      ),
      (
        'destinationMessageId',
        'caller-message',
        ForwardMessageErrorCode.serverOwnedField
      ),
      (
        'content',
        {'text': 'caller copy'},
        ForwardMessageErrorCode.serverOwnedField
      ),
    ]) {
      expect(
        () => ForwardMessageRequest.fromJson({..._request, fixture.$1: fixture.$2}),
        throwsA(_code(fixture.$3)),
      );
    }
    expect(
      () => ForwardMessageRequest.fromJson({
        ..._request,
        'extra': {
          'nested': {'session-id': 'spoofed'}
        },
      }),
      throwsA(_code(ForwardMessageErrorCode.trustedIdentityField)),
    );
  });

  test('result rejects all attachment state and secret-bearing attribution', () {
    final request = ForwardMessageRequest.fromJson(_request);
    for (final attachments in <Object?>[
      <Object?>[],
      <Object?>[
        {'attachmentId': 'attachment-source'}
      ],
    ]) {
      final wire = _result('applied');
      final content = _content(wire);
      content['attachments'] = attachments;
      expect(
        () => ForwardMessageResult.fromJson(wire, request: request),
        throwsA(_code(ForwardMessageErrorCode.sourceAttachmentsUnsupported)),
      );
    }
    for (final extra in <Map<String, Object?>>[
      {
        'session': {'token': 'secret'}
      },
      {'authorization': 'private'},
      {'rawHtml': '<b>unsafe</b>'},
    ]) {
      final wire = _result('applied');
      final forwarded = _content(wire)['forwarded']! as Map<String, Object?>;
      forwarded.addAll(extra);
      expect(
        () => ForwardMessageResult.fromJson(wire, request: request),
        throwsA(_code(ForwardMessageErrorCode.malformedAttribution)),
      );
    }
  });

  test('result enforces request correlation and canonical identities', () {
    final request = ForwardMessageRequest.fromJson(_request);
    final fixtures = <(ForwardMessageErrorCode, void Function(Map<String, Object?>))>[
      (
        ForwardMessageErrorCode.correlationMismatch,
        (wire) => wire['clientCorrelationId'] = 'other'
      ),
      (
        ForwardMessageErrorCode.destinationConversationMismatch,
        (wire) => wire['destinationConversationId'] = 'other'
      ),
      (
        ForwardMessageErrorCode.destinationConversationMismatch,
        (wire) => (wire['message']! as Map<String, Object?>)['conversationId'] = 'other'
      ),
      (
        ForwardMessageErrorCode.sourceMessageMismatch,
        (wire) => (_content(wire)['forwarded']! as Map<String, Object?>)[
            'sourceMessageId'] = 'other'
      ),
      (
        ForwardMessageErrorCode.noncanonicalDestination,
        (wire) {
          wire['canonicalRevision'] = 2;
          final message = wire['message']! as Map<String, Object?>;
          (message['revision']! as Map<String, Object?>)['revision'] = 2;
        }
      ),
    ];
    for (final fixture in fixtures) {
      final wire = _result('applied');
      fixture.$2(wire);
      expect(
        () => ForwardMessageResult.fromJson(wire, request: request),
        throwsA(_code(fixture.$1)),
      );
    }
  });
}

const _request = <String, Object?>{
  'operation': 'forward_message.v1',
  'sourceMessageId': 'message-source',
  'destinationConversationId': 'conversation-destination',
  'clientCorrelationId': 'forward-client-1',
  'idempotencyKey': 'forward-attempt-1',
};

Map<String, Object?> _result(String status) => <String, Object?>{
      'operation': 'forward_message.v1',
      'reconciliationStatus': status,
      'clientCorrelationId': 'forward-client-1',
      'destinationConversationId': 'conversation-destination',
      'message': <String, Object?>{
        'id': 'message-destination',
        'tenantId': 'tenant-from-session',
        'conversationId': 'conversation-destination',
        'author': <String, Object?>{
          'type': 'user',
          'userId': 'forwarding-user'
        },
        'sequence': 42,
        'createdAt': '2026-08-28T16:00:00.000Z',
        'updatedAt': '2026-08-28T16:00:00.000Z',
        'revision': <String, Object?>{'revision': 1},
        'content': <String, Object?>{
          'format': 'markdown',
          'text': 'Frozen **source** text',
          'mentions': <Object?>[
            <String, Object?>{'type': 'user', 'userId': 'mentioned-user'}
          ],
          'forwarded': <String, Object?>{
            'sourceMessageId': 'message-source',
            'originalAuthor': <String, Object?>{
              'userId': 'original-user',
              'displayName': 'Original Author',
            },
            'originalCreatedAt': '2026-08-20T12:30:00.000Z',
          },
        },
      },
      'canonicalRevision': 1,
    };

Map<String, Object?> _content(Map<String, Object?> wire) =>
    ((wire['message']! as Map<String, Object?>)['content']!
        as Map<String, Object?>);

Object? _roundTrip(Object? value) => jsonDecode(jsonEncode(value));

Matcher _code(ForwardMessageErrorCode code) => isA<ForwardMessageFormatException>()
    .having((error) => error.code, 'code', code);
