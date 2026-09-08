import 'dart:convert';

import 'package:handrail_chat/src/generated/identifiers.dart';
import 'package:handrail_chat/src/generated/message.dart';
import 'package:handrail_chat/src/generated/send_message.dart';
import 'package:test/test.dart';

import 'fixtures/send_message_fixtures.dart';

void main() {
  test('request and applied/replayed results round-trip exact JSON fields', () {
    final request = SendMessageRequest.fromJson(
      _roundTrip(sendMessageRequestFixture),
    );

    expect(request.toJson(), sendMessageRequestFixture);
    expect(request.operation, 'send');
    expect(request.conversationId, const ConversationId('conversation-1'));
    expect(request.content.format, MessageContentFormat.markdown);

    for (final status in ['applied', 'replayed']) {
      final wire = sendMessageResultFixture(status);
      final result = SendMessageResult.fromJson(_roundTrip(wire));

      expect(result.toJson(), wire);
      expect(result.reconciliationStatus.toJson(), status);
      expect(result.clientMessageId, request.clientMessageId);
      expect(result.message, isA<ActiveMessage>());
      expect(result.canonicalRevision, 1);
    }
  });

  test('reply references preserve values and the selected conversation', () {
    for (final notifyAuthor in [true, false]) {
      for (final messageId in [
        'source-1',
        'x' * 255,
        '${'é' * 127}a',
        'source with space'
      ]) {
        final reference = <String, Object?>{
          'messageId': messageId,
          'notifyAuthor': notifyAuthor,
        };
        final wire = <String, Object?>{
          ...sendMessageRequestFixture,
          'replyTo': reference
        };
        final request = SendMessageRequest.fromJson(_roundTrip(wire));
        expect(request.toJson(), wire);
        expect(request.replyTo!.messageId, MessageId(messageId));
        expect(request.replyTo!.notifyAuthor, notifyAuthor);
        expect(request.conversationId.toJson(), wire['conversationId']);
        final constructed = SendMessageRequest(
          conversationId: request.conversationId,
          content: request.content,
          clientMessageId: request.clientMessageId,
          idempotencyKey: request.idempotencyKey,
          replyTo: MessageReplyReference(
              messageId: MessageId(messageId), notifyAuthor: notifyAuthor),
        );
        expect(constructed.toJson(), wire);
        for (final status in ['applied', 'replayed']) {
          final resultWire = sendMessageResultFixture(status);
          (resultWire['message']! as Map<String, Object?>)['replyTo'] =
              reference;
          final result = SendMessageResult.fromJson(_roundTrip(resultWire));
          expect(result.toJson(), resultWire);
          expect(result.message.replyTo!.notifyAuthor, notifyAuthor);
        }
      }
    }
  });

  test(
      'malformed and enriched reply references fail request and result parsing',
      () {
    final valid = <String, Object?>{
      'messageId': 'source-1',
      'notifyAuthor': false
    };
    final invalid = <Object?>[
      null,
      [],
      'source-1',
      42,
      true,
      <String, Object?>{},
      <String, Object?>{'messageId': 'source-1'},
      <String, Object?>{'notifyAuthor': true},
      for (final notifyAuthor in <Object?>[null, 'true', 0, 1, {}, []])
        <String, Object?>{...valid, 'notifyAuthor': notifyAuthor},
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
        'source\u00a0',
        'source\nline',
        'source\tline',
        'source\x00',
        'source\x7f',
        'source\u0085',
        'source\u2028line',
        'source\u2029line',
        'x' * 256,
        'é' * 128,
      ])
        <String, Object?>{...valid, 'messageId': messageId},
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
        'unknown'
      ])
        <String, Object?>{...valid, field: 'injected'},
    ];
    for (final replyTo in invalid) {
      expect(
        () => SendMessageRequest.fromJson(<String, Object?>{
          ...sendMessageRequestFixture,
          'replyTo': replyTo
        }),
        throwsA(isA<SendMessageFormatException>().having((error) => error.code,
            'code', SendMessageParseErrorCode.malformedInput)),
      );
      for (final status in ['applied', 'replayed']) {
        final result = sendMessageResultFixture(status);
        (result['message']! as Map<String, Object?>)['replyTo'] = replyTo;
        expect(
            () => SendMessageResult.fromJson(result),
            throwsA(isA<SendMessageFormatException>().having(
                (error) => error.code,
                'code',
                SendMessageParseErrorCode.malformedResult)));
      }
    }
    final misplaced = <String, Object?>{
      ...sendMessageRequestFixture,
      'content': <String, Object?>{
        'format': 'plain',
        'text': 'Hello',
        'replyTo': valid
      },
    };
    expect(
        () => SendMessageRequest.fromJson(misplaced),
        throwsA(isA<SendMessageFormatException>().having((error) => error.code,
            'code', SendMessageParseErrorCode.malformedContent)));
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
    ]) {
      expect(
        () => SendMessageRequest.fromJson(<String, Object?>{
          ...sendMessageRequestFixture,
          alias: 'spoofed',
        }),
        throwsA(
          isA<SendMessageFormatException>().having(
            (error) => error.code,
            'code',
            SendMessageParseErrorCode.trustedIdentityField,
          ),
        ),
        reason: alias,
      );
    }
  });

  test('request rejects malformed message content and inexact fields', () {
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
        () => SendMessageRequest.fromJson(<String, Object?>{
          ...sendMessageRequestFixture,
          'content': content,
        }),
        throwsA(
          isA<SendMessageFormatException>().having(
            (error) => error.code,
            'code',
            SendMessageParseErrorCode.malformedContent,
          ),
        ),
      );
    }

    expect(
      () => SendMessageRequest.fromJson(<String, Object?>{
        ...sendMessageRequestFixture,
        'messageId': 'caller-owned-message',
      }),
      throwsA(
        isA<SendMessageFormatException>().having(
          (error) => error.code,
          'code',
          SendMessageParseErrorCode.malformedInput,
        ),
      ),
    );
  });

  test('result rejects malformed canonical messages and revision drift', () {
    final invalidMessage = sendMessageResultFixture('applied');
    invalidMessage['message'] = <String, Object?>{
      ...(invalidMessage['message']! as Map<String, Object?>),
      'content': <String, Object?>{'format': 'plain'},
    };

    expect(
      () => SendMessageResult.fromJson(invalidMessage),
      throwsA(
        isA<SendMessageFormatException>().having(
          (error) => error.code,
          'code',
          SendMessageParseErrorCode.malformedResult,
        ),
      ),
    );

    final wrongRevision = sendMessageResultFixture('replayed');
    wrongRevision['canonicalRevision'] = 2;
    expect(
      () => SendMessageResult.fromJson(wrongRevision),
      throwsA(
        isA<SendMessageFormatException>().having(
          (error) => error.code,
          'code',
          SendMessageParseErrorCode.revisionMismatch,
        ),
      ),
    );
  });
}

Object? _roundTrip(Object? value) => jsonDecode(jsonEncode(value));
