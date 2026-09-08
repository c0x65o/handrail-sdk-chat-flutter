import 'dart:convert';

import 'package:handrail_chat/core.dart';
import 'package:test/test.dart';

import 'fixtures/delete_message_fixtures.dart';

void main() {
  test('request and applied, replayed, and conflict tombstones round-trip', () {
    final request = SoftDeleteMessageRequest.fromJson(
      _roundTrip(softDeleteMessageRequestFixture),
    );

    expect(request.toJson(), softDeleteMessageRequestFixture);
    expect(request.operation, 'soft_delete');
    expect(request.messageId, const MessageId('message-1'));
    expect(request.expectedRevision, 2);

    for (final status in ['applied', 'replayed', 'revision_conflict']) {
      final wire = softDeleteMessageResultFixture(status);
      final result = SoftDeleteMessageResult.fromJson(_roundTrip(wire));

      expect(result.toJson(), wire);
      expect(result.reconciliationStatus.toJson(), status);
      expect(result.message, isA<DeletedMessage>());
      expect(result.message.content, isNull);
      expect(result.canonicalRevision, 3);
    }
  });

  test('all result shapes retain replies and omit legacy references', () {
    for (final wire in _resultVariants()) {
      final legacy = SoftDeleteMessageResult.fromJson(_roundTrip(wire));
      expect(legacy.message.replyTo, isNull);
      expect(legacy.message.toJson().containsKey('replyTo'), isFalse);
      expect(_roundTrip(legacy.toJson()), wire);

      for (final notifyAuthor in [false, true]) {
        for (final messageId in [
          'source-message',
          'a' * 255,
          '${'é' * 127}a',
        ]) {
          final reference = <String, Object?>{
            'messageId': messageId,
            'notifyAuthor': notifyAuthor,
          };
          final replyWire = <String, Object?>{
            ...wire,
            'message': <String, Object?>{
              ...wire['message']! as Map<String, Object?>,
              'replyTo': reference,
            },
          };
          final parsed =
              SoftDeleteMessageResult.fromJson(_roundTrip(replyWire));
          expect(parsed.message.replyTo!.messageId, MessageId(messageId));
          expect(parsed.message.replyTo!.notifyAuthor, notifyAuthor);
          expect(_roundTrip(parsed.toJson()), replyWire);
          expect(
            SoftDeleteMessageResult.fromJson(_roundTrip(parsed.toJson()))
                .toJson(),
            replyWire,
          );
        }
      }
    }
  });

  test('all result shapes reject malformed MessageReplyReference values', () {
    final invalidReferences = <Object?>[
      null,
      false,
      1,
      'source',
      <Object?>[],
      <String, Object?>{},
      {'messageId': 'source'},
      {'notifyAuthor': true},
      for (final id in <Object?>[
        null,
        true,
        42,
        {},
        [],
        '',
        ' source',
        'source ',
        'a\n',
        'a\u007f',
        'a\u0085',
        'a\u2028',
        'a' * 256,
        'é' * 128,
      ])
        {'messageId': id, 'notifyAuthor': true},
      for (final ping in <Object?>[null, 'true', 'false', 0, 1, {}, []])
        {'messageId': 'source', 'notifyAuthor': ping},
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
        'unexpected',
      ])
        {'messageId': 'source', 'notifyAuthor': false, field: 'spoofed'},
    ];
    for (final wire in _resultVariants()) {
      for (final reference in invalidReferences) {
        expect(
          () => SoftDeleteMessageResult.fromJson(_roundTrip({
            ...wire,
            'message': {
              ...wire['message']! as Map<String, Object?>,
              'replyTo': reference,
            },
          })),
          throwsA(
              _deleteError(SoftDeleteMessageParseErrorCode.malformedResult)),
          reason: '${wire['reconciliationStatus']}: $reference',
        );
      }
    }
  });

  test('replyTo is forbidden on deletion requests, including null', () {
    for (final reference in <Object?>[
      null,
      for (final notifyAuthor in [false, true])
        {'messageId': 'source-message', 'notifyAuthor': notifyAuthor},
    ]) {
      expect(
        () => SoftDeleteMessageRequest.fromJson(_roundTrip({
          ...softDeleteMessageRequestFixture,
          'replyTo': reference,
        })),
        throwsA(_deleteError(SoftDeleteMessageParseErrorCode.malformedInput)),
      );
    }
  });

  test('reply shells enforce redaction, deletion metadata, and revisions', () {
    for (final status in ['applied', 'replayed', 'revision_conflict']) {
      for (final fault in [
        'content',
        'deletedByUserId',
        'deletedAt',
        'revision'
      ]) {
        final wire = softDeleteMessageResultFixture(status);
        final message = wire['message']! as Map<String, Object?>;
        message['replyTo'] = {
          'messageId': 'source-message',
          'notifyAuthor': false
        };
        switch (fault) {
          case 'content':
            message['content'] = {
              'format': 'plain',
              'text': 'must be redacted'
            };
          case 'deletedByUserId':
            message.remove('deletedByUserId');
          case 'deletedAt':
            message.remove('deletedAt');
          case 'revision':
            wire['canonicalRevision'] = 4;
        }
        expect(
          () => SoftDeleteMessageResult.fromJson(_roundTrip(wire)),
          throwsA(_deleteError(fault == 'revision'
              ? SoftDeleteMessageParseErrorCode.revisionMismatch
              : SoftDeleteMessageParseErrorCode.malformedResult)),
          reason: '$status: $fault',
        );
      }
    }
  });

  test('request rejects the complete normalized trusted identity surface', () {
    for (final alias in <String>[
      'tenant-id',
      'organization_id',
      'Actor_User_ID',
      'current-actor-id',
      'current-user',
      'userId',
      'author',
      'principal-id',
      'subject_id',
      'authenticated-user-id',
      'identity',
      'session-id',
      'auth',
      'authentication',
      'authorization',
      'role',
      'roles',
    ]) {
      expect(
        () => SoftDeleteMessageRequest.fromJson(<String, Object?>{
          ...softDeleteMessageRequestFixture,
          alias: 'spoofed',
        }),
        throwsA(_deleteError(
          SoftDeleteMessageParseErrorCode.trustedIdentityField,
        )),
        reason: alias,
      );
    }
  });

  test('request rejects invalid revisions, blank identifiers, and fields', () {
    for (final revision in <Object?>[0, -1, 1.5, 9007199254740992]) {
      expect(
        () => SoftDeleteMessageRequest.fromJson(<String, Object?>{
          ...softDeleteMessageRequestFixture,
          'expectedRevision': revision,
        }),
        throwsA(_deleteError(
          SoftDeleteMessageParseErrorCode.malformedInput,
        )),
      );
    }
    for (final field in <String>['messageId', 'idempotencyKey']) {
      expect(
        () => SoftDeleteMessageRequest.fromJson(<String, Object?>{
          ...softDeleteMessageRequestFixture,
          field: '  ',
        }),
        throwsA(_deleteError(
          SoftDeleteMessageParseErrorCode.malformedInput,
        )),
      );
    }
    expect(
      () => SoftDeleteMessageRequest.fromJson(<String, Object?>{
        ...softDeleteMessageRequestFixture,
        'content': null,
      }),
      throwsA(_deleteError(SoftDeleteMessageParseErrorCode.malformedInput)),
    );
  });

  test('results reject malformed revisions and unknown fields', () {
    for (final field in <String>['expectedRevision', 'canonicalRevision']) {
      for (final revision in <Object?>[0, 1.5, 9007199254740992]) {
        final malformed = softDeleteMessageResultFixture('applied')
          ..[field] = revision;
        expect(
          () => SoftDeleteMessageResult.fromJson(malformed),
          throwsA(_deleteError(
            SoftDeleteMessageParseErrorCode.malformedResult,
          )),
        );
      }
    }
    expect(
      () => SoftDeleteMessageResult.fromJson(
        softDeleteMessageResultFixture('applied')..['messageId'] = 'message-1',
      ),
      throwsA(_deleteError(SoftDeleteMessageParseErrorCode.malformedResult)),
    );

    final unknownMessageField = softDeleteMessageResultFixture('applied');
    final unknownMessage =
        unknownMessageField['message']! as Map<String, Object?>;
    unknownMessage['serverSecret'] = true;
    expect(
      () => SoftDeleteMessageResult.fromJson(unknownMessageField),
      throwsA(_deleteError(SoftDeleteMessageParseErrorCode.malformedResult)),
    );
  });

  test('results enforce tombstone and reconciliation coherence', () {
    final contentBearing = softDeleteMessageResultFixture('applied');
    final contentBearingMessage =
        contentBearing['message']! as Map<String, Object?>;
    contentBearingMessage['content'] = <String, Object?>{
      'format': 'plain',
      'text': 'must be redacted',
    };
    expect(
      () => SoftDeleteMessageResult.fromJson(contentBearing),
      throwsA(_deleteError(SoftDeleteMessageParseErrorCode.malformedResult)),
    );

    final unpairedDeletion = softDeleteMessageResultFixture('applied');
    final unpairedMessage =
        unpairedDeletion['message']! as Map<String, Object?>;
    unpairedMessage.remove('deletedByUserId');
    expect(
      () => SoftDeleteMessageResult.fromJson(unpairedDeletion),
      throwsA(_deleteError(SoftDeleteMessageParseErrorCode.malformedResult)),
    );

    final activeSuccess = softDeleteMessageResultFixture('applied');
    final activeMessage = activeSuccess['message']! as Map<String, Object?>;
    activeMessage
      ..remove('deletedAt')
      ..remove('deletedByUserId')
      ..['content'] = <String, Object?>{
        'format': 'plain',
        'text': 'still active',
      };
    expect(
      () => SoftDeleteMessageResult.fromJson(activeSuccess),
      throwsA(_deleteError(SoftDeleteMessageParseErrorCode.malformedResult)),
    );

    expect(
      () => SoftDeleteMessageResult.fromJson(
        softDeleteMessageResultFixture('applied')..['canonicalRevision'] = 4,
      ),
      throwsA(_deleteError(SoftDeleteMessageParseErrorCode.revisionMismatch)),
    );
    expect(
      () => SoftDeleteMessageResult.fromJson(
        softDeleteMessageResultFixture('replayed')..['expectedRevision'] = 1,
      ),
      throwsA(_deleteError(SoftDeleteMessageParseErrorCode.revisionMismatch)),
    );
    expect(
      () => SoftDeleteMessageResult.fromJson(
        softDeleteMessageResultFixture('revision_conflict')
          ..['expectedRevision'] = 3,
      ),
      throwsA(_deleteError(SoftDeleteMessageParseErrorCode.revisionMismatch)),
    );
  });
}

Matcher _deleteError(SoftDeleteMessageParseErrorCode code) =>
    isA<SoftDeleteMessageFormatException>().having(
      (error) => error.code,
      'code',
      code,
    );

Object? _roundTrip(Object? value) => jsonDecode(jsonEncode(value));

List<Map<String, Object?>> _resultVariants() {
  final liveConflict = softDeleteMessageResultFixture('revision_conflict');
  final message = liveConflict['message']! as Map<String, Object?>;
  message
    ..remove('deletedAt')
    ..remove('deletedByUserId')
    ..['content'] = {'format': 'plain', 'text': 'Friday'};
  return [
    for (final status in ['applied', 'replayed', 'revision_conflict'])
      softDeleteMessageResultFixture(status),
    liveConflict,
  ];
}
