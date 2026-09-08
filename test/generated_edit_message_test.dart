import 'dart:convert';

import 'package:handrail_chat/core.dart';
import 'package:test/test.dart';

import 'fixtures/edit_message_fixtures.dart';

void main() {
  test('request and all result statuses round-trip exact camelCase JSON', () {
    final request = EditMessageRequest.fromJson(
      _roundTrip(editMessageRequestFixture),
    );

    expect(request.toJson(), editMessageRequestFixture);
    expect(request.operation, 'edit');
    expect(request.messageId, const MessageId('message-1'));
    expect(request.expectedRevision, 2);

    for (final status in ['applied', 'replayed', 'revision_conflict']) {
      final wire = editMessageResultFixture(status);
      final result = EditMessageResult.fromJson(_roundTrip(wire));

      expect(result.toJson(), wire);
      expect(result.reconciliationStatus.toJson(), status);
      expect(result.message.id, const MessageId('message-1'));
      expect(result.canonicalRevision, 3);
    }
  });

  for (final status in ['applied', 'replayed', 'revision_conflict']) {
    test('$status round-trips legacy replies and both notification choices',
        () {
      for (final notifyAuthor in <bool?>[null, false, true]) {
        for (final messageId in [
          'source-message',
          'source with space',
          'x' * 255,
          '${'é' * 127}a',
        ]) {
          final wire = editMessageResultFixture(status,
              notifyAuthor: notifyAuthor, replyMessageId: messageId);
          final result = EditMessageResult.fromJson(_roundTrip(wire));
          expect(result.toJson(), wire);
          expect(result.message.replyTo?.notifyAuthor, notifyAuthor);
          expect(result.message.replyTo?.messageId,
              notifyAuthor == null ? null : MessageId(messageId));
          expect((result.toJson()['message']! as Map).containsKey('replyTo'),
              notifyAuthor != null);
          expect(result.message.revision.revision, 3);
        }
      }
    });

    test('$status rejects malformed and enriched canonical reply metadata', () {
      const reply = <String, Object?>{
        'messageId': 'source-message',
        'notifyAuthor': false,
      };
      final invalid = <Object?>[
        null,
        [],
        'source-message',
        42,
        true,
        <String, Object?>{},
        <String, Object?>{'messageId': 'source-message'},
        <String, Object?>{'notifyAuthor': false},
        for (final notifyAuthor in <Object?>[null, 'false', 0, 1, {}, []])
          <String, Object?>{...reply, 'notifyAuthor': notifyAuthor},
        for (final messageId in <Object?>[
          null,
          42,
          true,
          {},
          [],
          '',
          ' ',
          ' source',
          'source ',
          '\u00a0source',
          'source\nline',
          'source\tline',
          'source\u0000',
          'source\u007f',
          'source\u0085',
          'source\u2028line',
          'source\u2029line',
          'x' * 256,
          'é' * 128,
        ])
          <String, Object?>{...reply, 'messageId': messageId},
        for (final field in [
          'tenantId',
          'actor',
          'actorId',
          'userId',
          'author',
          'authorId',
          'sourceMessageId',
          'originalAuthor',
          'originalCreatedAt',
          'displayName',
          'sourceDisplay',
          'source',
          'content',
          'unknown',
        ])
          <String, Object?>{...reply, field: 'injected'},
      ];
      for (final replyTo in invalid) {
        final wire = editMessageResultFixture(status);
        (wire['message']! as Map<String, Object?>)['replyTo'] = replyTo;
        expect(() => EditMessageResult.fromJson(_roundTrip(wire)),
            throwsA(_editError(EditMessageParseErrorCode.malformedResult)),
            reason: jsonEncode(replyTo));
      }
    });

    test('$status replies preserve revision and active-message checks', () {
      final wire = editMessageResultFixture(status, notifyAuthor: false);
      expect(
        () => EditMessageResult.fromJson({...wire, 'canonicalRevision': 4}),
        throwsA(_editError(EditMessageParseErrorCode.revisionMismatch)),
      );
      expect(
        () => EditMessageResult.fromJson({
          ...wire,
          'expectedRevision': status == 'revision_conflict' ? 3 : 1,
        }),
        throwsA(_editError(EditMessageParseErrorCode.revisionMismatch)),
      );
      final message = wire['message']! as Map<String, Object?>;
      message.addAll({
        'content': null,
        'deletedAt': '2026-08-25T20:02:00.000Z',
        'deletedByUserId': 'user-from-session',
      });
      if (status == 'revision_conflict') {
        expect(EditMessageResult.fromJson(_roundTrip(wire)).toJson(), wire);
      } else {
        expect(() => EditMessageResult.fromJson(wire),
            throwsA(_editError(EditMessageParseErrorCode.malformedResult)));
      }
    });
  }

  test('edit requests reject reply metadata at top level and inside content',
      () {
    for (final replyTo in <Object?>[
      null,
      for (final notifyAuthor in [false, true])
        <String, Object?>{
          'messageId': 'source-message',
          'notifyAuthor': notifyAuthor
        },
    ]) {
      expect(
        () => EditMessageRequest.fromJson(
            {...editMessageRequestFixture, 'replyTo': replyTo}),
        throwsA(_editError(EditMessageParseErrorCode.malformedInput)),
      );
      expect(
        () => EditMessageRequest.fromJson({
          ...editMessageRequestFixture,
          'content': <String, Object?>{
            ...editMessageRequestFixture['content']! as Map<String, Object?>,
            'replyTo': replyTo,
          },
        }),
        throwsA(_editError(EditMessageParseErrorCode.malformedContent)),
      );
    }
  });

  test('request rejects normalized trusted identity aliases', () {
    for (final alias in <String>[
      'tenant-id',
      'organization_id',
      'Actor_User_ID',
      'current-user',
      'userId',
      'author',
      'principal-id',
      'subject_id',
      'session-id',
      'authentication',
      'authorization',
      'role',
    ]) {
      expect(
        () => EditMessageRequest.fromJson(<String, Object?>{
          ...editMessageRequestFixture,
          alias: 'spoofed',
        }),
        throwsA(_editError(EditMessageParseErrorCode.trustedIdentityField)),
        reason: alias,
      );
    }
  });

  test('request rejects malformed content, revisions, identifiers, and fields',
      () {
    for (final content in <Object?>[
      <String, Object?>{'text': 'missing format'},
      <String, Object?>{'format': 'html', 'text': 'unsupported'},
      <String, Object?>{'format': 'plain'},
      <String, Object?>{'format': 'plain', 'text': 42},
      <String, Object?>{
        'format': 'plain',
        'text': 'extra',
        'authorId': 'spoofed',
      },
    ]) {
      expect(
        () => EditMessageRequest.fromJson(<String, Object?>{
          ...editMessageRequestFixture,
          'content': content,
        }),
        throwsA(_editError(EditMessageParseErrorCode.malformedContent)),
      );
    }

    for (final revision in <Object?>[0, -1, 1.5, 9007199254740992]) {
      expect(
        () => EditMessageRequest.fromJson(<String, Object?>{
          ...editMessageRequestFixture,
          'expectedRevision': revision,
        }),
        throwsA(_editError(EditMessageParseErrorCode.malformedInput)),
      );
    }
    for (final field in <String>['messageId', 'idempotencyKey']) {
      expect(
        () => EditMessageRequest.fromJson(<String, Object?>{
          ...editMessageRequestFixture,
          field: '  ',
        }),
        throwsA(_editError(EditMessageParseErrorCode.malformedInput)),
      );
    }
    expect(
      () => EditMessageRequest.fromJson(<String, Object?>{
        ...editMessageRequestFixture,
        'clientMessageId': 'not-an-edit-field',
      }),
      throwsA(_editError(EditMessageParseErrorCode.malformedInput)),
    );
  });

  test('results reject malformed messages, fields, and revisions', () {
    final malformedContent = editMessageResultFixture('applied');
    final malformedMessage =
        malformedContent['message']! as Map<String, Object?>;
    malformedMessage['content'] = <String, Object?>{'format': 'plain'};
    expect(
      () => EditMessageResult.fromJson(malformedContent),
      throwsA(_editError(EditMessageParseErrorCode.malformedResult)),
    );

    final unknownField = editMessageResultFixture('applied')
      ..['messageId'] = 'message-1';
    expect(
      () => EditMessageResult.fromJson(unknownField),
      throwsA(_editError(EditMessageParseErrorCode.malformedResult)),
    );

    for (final field in <String>['expectedRevision', 'canonicalRevision']) {
      for (final revision in <Object?>[0, 1.5, 9007199254740992]) {
        final malformed = editMessageResultFixture('applied')
          ..[field] = revision;
        expect(
          () => EditMessageResult.fromJson(malformed),
          throwsA(_editError(EditMessageParseErrorCode.malformedResult)),
        );
      }
    }

    final inconsistent = editMessageResultFixture('applied')
      ..['canonicalRevision'] = 4;
    expect(
      () => EditMessageResult.fromJson(inconsistent),
      throwsA(_editError(EditMessageParseErrorCode.revisionMismatch)),
    );

    final skippedRevision = editMessageResultFixture('replayed')
      ..['expectedRevision'] = 1;
    expect(
      () => EditMessageResult.fromJson(skippedRevision),
      throwsA(_editError(EditMessageParseErrorCode.revisionMismatch)),
    );

    final incoherentConflict = editMessageResultFixture('revision_conflict')
      ..['expectedRevision'] = 3;
    expect(
      () => EditMessageResult.fromJson(incoherentConflict),
      throwsA(_editError(EditMessageParseErrorCode.revisionMismatch)),
    );
  });
}

Matcher _editError(EditMessageParseErrorCode code) =>
    isA<EditMessageFormatException>().having(
      (error) => error.code,
      'code',
      code,
    );

Object? _roundTrip(Object? value) => jsonDecode(jsonEncode(value));
