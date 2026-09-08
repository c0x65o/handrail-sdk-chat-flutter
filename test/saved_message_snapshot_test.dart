import 'dart:convert';

import 'package:handrail_chat/saved_message_snapshot.dart';
import 'package:handrail_chat/src/generated/identifiers.dart';
import 'package:handrail_chat/src/generated/message.dart';
import 'package:test/test.dart';

void main() {
  test(
      'legacy and both notification choices round-trip without changing content',
      () {
    for (final notifyAuthor in [null, true, false]) {
      final wire = _available();
      if (notifyAuthor != null) {
        _current(wire)['replyTo'] = {
          'messageId': 'message-source',
          'notifyAuthor': notifyAuthor,
        };
      }
      final parsed =
          _parse(_roundTrip(wire)) as AvailableSavedMessageProjection;
      expect(parsed.toJson(), wire);
      expect(_parse(_roundTrip(parsed.toJson())).toJson(), wire);
      final MessageReplyReference? reference = parsed.current.replyTo;
      expect(reference?.notifyAuthor, notifyAuthor);
      expect(reference?.messageId,
          notifyAuthor == null ? null : const MessageId('message-source'));
      expect(
          parsed.current.toJson().containsKey('replyTo'), notifyAuthor != null);
      expect(
          parsed.current.content.toJson(), _current(_available())['content']);
    }
  });

  test('canonical reply identifier boundaries and decomposed Unicode survive',
      () {
    for (final messageId in ['x' * 255, '${'é' * 127}x', 'e\u0301']) {
      final wire = _available();
      _current(wire)['replyTo'] = {
        'messageId': messageId,
        'notifyAuthor': false
      };
      expect(_parse(_roundTrip(wire)).toJson(), wire);
    }
  });

  test('malformed references and source or destination fields are rejected',
      () {
    final reference = {'messageId': 'message-source', 'notifyAuthor': false};
    final invalid = <Object?>[
      null,
      [],
      'message-source',
      {},
      {'messageId': 'message-source'},
      {'notifyAuthor': false},
      for (final notifyAuthor in [null, 0, 'false'])
        {...reference, 'notifyAuthor': notifyAuthor},
      for (final messageId in [
        null,
        1,
        '',
        ' x',
        'x ',
        'x\n',
        'x\u0085',
        'x\u2028',
        'x\u2029',
        'x' * 256,
        'é' * 128
      ])
        {...reference, 'messageId': messageId},
      for (final key in [
        'unknown',
        'conversationId',
        'tenantId',
        'actor',
        'actorId',
        'userId',
        'author',
        'sourceMessageId',
        'originalAuthor',
        'content',
        'source',
        'forwarded'
      ])
        {...reference, key: 'forbidden'},
    ];
    for (final replyTo in invalid) {
      final wire = _available();
      _current(wire)['replyTo'] = replyTo;
      expect(() => _parse(_roundTrip(wire)), throwsFormatException,
          reason: '$replyTo');
    }
  });

  test(
      'deleted and inaccessible shells remain exact and reject stale additions',
      () {
    for (final reason in ['deleted', 'inaccessible']) {
      final shell = {'availability': 'unavailable', 'reason': reason};
      expect(_parse(_roundTrip(shell)).toJson(), shell);
      for (final entry in {
        'current': _current(_available()),
        'replyTo': {'messageId': 'message-source', 'notifyAuthor': false},
        'content': {'format': 'plain', 'text': 'stale'},
        'author': {'type': 'user', 'userId': 'stale'},
        'attachmentMetadata': [],
      }.entries) {
        expect(() => _parse({...shell, entry.key: entry.value}),
            throwsFormatException);
      }
    }
  });

  test(
      'identity, required fields, content boundary, and attachment order remain checked',
      () {
    final wire = _available();
    expect(
        () => SavedMessageProjection.fromJson(wire,
            expectedMessageId: const MessageId('other')),
        throwsFormatException);
    for (final key in _current(wire).keys.toList()) {
      final missing = _available();
      _current(missing).remove(key);
      expect(() => _parse(missing), throwsFormatException, reason: key);
    }
    for (final key in ['replyTo', 'forwarded', 'source']) {
      final invalid = _available();
      (_current(invalid)['content'] as Map<String, Object?>)[key] = {};
      expect(() => _parse(invalid), throwsFormatException);
    }
    final invalid = _available();
    _current(invalid)['attachmentMetadata'] = [];
    expect(() => _parse(invalid), throwsFormatException);
  });
}

SavedMessageProjection _parse(Object? json) =>
    SavedMessageProjection.fromJson(json,
        expectedMessageId: const MessageId('message-visible'));
Object? _roundTrip(Object? value) => jsonDecode(jsonEncode(value));
Map<String, Object?> _current(Map<String, Object?> wire) =>
    wire['current'] as Map<String, Object?>;
Map<String, Object?> _available() => {
      'availability': 'available',
      'current': <String, Object?>{
        'id': 'message-visible',
        'conversationId': 'conversation-private-state',
        'author': {'type': 'user', 'userId': 'user-author'},
        'sequence': 42,
        'createdAt': '2026-08-26T11:00:00.000Z',
        'updatedAt': '2026-08-26T11:05:00.000Z',
        'revision': {
          'revision': 2,
          'editedAt': '2026-08-26T11:05:00.000Z',
          'editedByUserId': 'user-author'
        },
        'content': <String, Object?>{
          'format': 'markdown',
          'text': 'Current **safe** message body',
          'mentions': [
            {'type': 'user', 'userId': 'user-mentioned'}
          ],
          'attachments': [
            {'attachmentId': 'attachment-visible'}
          ],
          'blocks': [
            {
              'type': 'erp.reference',
              'data': {'id': 'invoice-42'}
            }
          ],
        },
        'attachmentMetadata': [
          {
            'attachmentId': 'attachment-visible',
            'fileName': 'invoice.pdf',
            'contentType': 'application/pdf',
            'sizeBytes': 2048,
            'downloadUrl': 'https://cdn.example.test/invoice.pdf'
          },
        ],
      },
    };
