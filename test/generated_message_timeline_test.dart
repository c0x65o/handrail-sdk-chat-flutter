import 'package:handrail_chat/core.dart';
import 'package:test/test.dart';

void main() {
  group('MessageTimelinePage', () {
    test('round trips replies and legacy active and deleted messages', () {
      for (final conversationId in ['conversation-1', 'thread-1']) {
        final request = MessageTimelineRequest.fromJson({
          'conversationId': conversationId,
          'direction': 'backward',
          'cursor': 3,
          'limit': 2,
        });
        for (final deleted in [false, true]) {
          for (final notifyAuthor in [false, true]) {
            for (final messageId in [
              'source-1',
              'source with spaces',
              'a' * 255,
              '${'é' * 127}a',
              '${'😀' * 63}abc',
            ]) {
              final replyTo = {
                'messageId': messageId,
                'notifyAuthor': notifyAuthor
              };
              final legacy = _message(1, conversationId: conversationId);
              final reply = _message(2, conversationId: conversationId)
                ..['replyTo'] = replyTo;
              if (deleted) {
                for (final message in [legacy, reply]) {
                  message['content'] = null;
                  message['deletedAt'] = '2026-08-25T20:04:00.000Z';
                  message['deletedByUserId'] = 'user-moderator';
                }
              }
              final json = _page([legacy, reply], older: 1)
                ..['conversationId'] = conversationId;
              final page = MessageTimelinePage.fromJson(json, request: request);
              expect(page.toJson(), json);
              expect(page.messages.first.message.replyTo, isNull);
              final parsedReply = page.messages.last;
              expect(parsedReply.message.replyTo?.messageId.value, messageId);
              expect(parsedReply.message.replyTo?.notifyAuthor, notifyAuthor);
              expect(parsedReply.isThreadRoot, isFalse);
              expect(parsedReply.threadSummary, isNull);
              expect(parsedReply.message.content?.forwarded != null, isFalse);
              expect(
                  MessageTimelinePage.fromJson(page.toJson(), request: request)
                      .toJson(),
                  json);
            }
          }
        }
      }
    });

    test('rejects malformed reply references on active and deleted shells', () {
      final valid = {'messageId': 'source-1', 'notifyAuthor': false};
      final malformed = <Object?>[
        null,
        false,
        1,
        'source-1',
        [],
        [valid],
        {},
        {'messageId': 'source-1'},
        {'notifyAuthor': true},
        for (final messageId in <Object?>[
          null,
          false,
          1,
          {},
          [],
          '',
          ' ',
          ' source',
          'source ',
          'source\n',
          'a\u0000b',
          'a\u001fb',
          'a\u007fb',
          'a\u0085b',
          'a\u009fb',
          'a\u2028b',
          'a\u2029b',
          'a' * 256,
          'é' * 128,
          '😀' * 64,
        ])
          {...valid, 'messageId': messageId},
        for (final notifyAuthor in <Object?>[
          null,
          0,
          1,
          'true',
          'false',
          {},
          []
        ])
          {...valid, 'notifyAuthor': notifyAuthor},
        for (final field in [
          'tenantId',
          'conversationId',
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
          'forward',
          'forwarded',
          'snapshot',
          'threadSummary',
          'isThreadRoot',
          'unexpected',
        ])
          {...valid, field: 'injected'},
      ];
      final request = MessageTimelineRequest.fromJson({
        'conversationId': 'conversation-1',
        'direction': 'forward',
        'limit': 1,
      });
      for (final deleted in [false, true]) {
        for (final replyTo in malformed) {
          final message = _message(1)..['replyTo'] = replyTo;
          if (deleted) {
            message['content'] = null;
            message['deletedAt'] = '2026-08-25T20:04:00.000Z';
            message['deletedByUserId'] = 'user-moderator';
          }
          expect(
            () => MessageTimelinePage.fromJson(_page([message]),
                request: request),
            throwsFormatException,
            reason: 'accepted malformed reply: $replyTo',
          );
        }
      }
    });

    test('accepts ascending backward and forward pages', () {
      final backwardRequest = MessageTimelineRequest.fromJson({
        'conversationId': 'conversation-1',
        'direction': 'backward',
        'cursor': 10,
        'limit': 2,
      });
      final backward = MessageTimelinePage.fromJson(
        _page([
          _message(7),
          _message(9),
        ], older: 7, newer: 9),
        request: backwardRequest,
      );
      expect(
          backward.messages.map((message) => message.sequence.value), [7, 9]);

      final forwardRequest = MessageTimelineRequest.fromJson({
        'conversationId': 'conversation-1',
        'direction': 'forward',
        'cursor': 10,
        'limit': 2,
      });
      final forward = MessageTimelinePage.fromJson(
        _page([_message(11), _message(12)]),
        request: forwardRequest,
      );
      expect(
          forward.messages.map((message) => message.sequence.value), [11, 12]);
      expect(() => forward.messages.add(forward.messages.first),
          throwsUnsupportedError);
    });

    test('preserves thread, reaction, attachment, page, and replay enrichment',
        () {
      final request = MessageTimelineRequest.fromJson({
        'conversationId': 'conversation-1',
        'direction': 'backward',
        'limit': 20,
      });
      final root = _message(4, enrichedRoot: true)
        ..['replyTo'] = {'messageId': 'source-1', 'notifyAuthor': false};
      final page = MessageTimelinePage.fromJson(
        _page([root], older: 4),
        request: request,
      );
      final message = page.messages.single;

      expect(message.isThreadRoot, isTrue);
      expect(message.message.replyTo?.notifyAuthor, isFalse);
      expect(message.threadSummary?.threadId.value, 'thread-4');
      expect(message.threadSummary?.replyCount, 2);
      expect(message.reactions.single.reactionKey, 'thumbsup');
      expect(message.reactions.single.reactedByCurrentUser, isTrue);
      expect(message.attachmentMetadata.single.fileName, 'status.png');
      expect(message.attachmentMetadata.single.width, 640);
      expect(page.pagination.older.cursor?.value, 4);
      expect(page.replay.resumeFrom.eventId, 'event-snapshot-42');
      expect(page.toJson(), _page([root], older: 4));
    });

    test('rejects conversation mismatch, duplicates, over-limit, and cursors',
        () {
      final backward = MessageTimelineRequest.fromJson({
        'conversationId': 'conversation-1',
        'direction': 'backward',
        'cursor': 10,
        'limit': 2,
      });

      expect(
        () => MessageTimelinePage.fromJson(
          {
            ..._page([_message(9)]),
            'conversationId': 'conversation-2'
          },
          request: backward,
        ),
        throwsFormatException,
      );
      expect(
        () => MessageTimelinePage.fromJson(
          _page([_message(9), _message(9)]),
          request: backward,
        ),
        throwsFormatException,
      );
      expect(
        () => MessageTimelinePage.fromJson(
          _page([_message(7), _message(8), _message(9)]),
          request: backward,
        ),
        throwsFormatException,
      );
      expect(
        () => MessageTimelinePage.fromJson(
          _page([_message(10)]),
          request: backward,
        ),
        throwsFormatException,
      );
      expect(
        () => MessageTimelinePage.fromJson(
          _page([_message(9, conversationId: 'conversation-2')]),
          request: backward,
        ),
        throwsFormatException,
      );
    });

    test('rejects malformed thread, attachment, and reaction enrichment', () {
      final request = MessageTimelineRequest.fromJson({
        'conversationId': 'conversation-1',
        'direction': 'backward',
        'limit': 20,
      });
      final falseRootWithSummary = _message(4, enrichedRoot: true)
        ..['replyTo'] = {'messageId': 'source-1', 'notifyAuthor': true}
        ..['isThreadRoot'] = false;
      final mismatchedAttachment = _message(4, enrichedRoot: true);
      (mismatchedAttachment['attachmentMetadata'] as List<Object?>).single
          as Map<String, Object?>
        ..['attachmentId'] = 'other-attachment';
      final duplicateReaction = _message(4, enrichedRoot: true);
      (duplicateReaction['reactions'] as List<Object?>).add({
        'reactionKey': 'thumbsup',
        'count': 1,
        'reactedByCurrentUser': false,
      });

      for (final message in [
        falseRootWithSummary,
        mismatchedAttachment,
        duplicateReaction,
      ]) {
        expect(
          () =>
              MessageTimelinePage.fromJson(_page([message]), request: request),
          throwsFormatException,
        );
      }
    });

    test('rejects descending pages and invalid pagination', () {
      final request = MessageTimelineRequest.fromJson({
        'conversationId': 'conversation-1',
        'direction': 'backward',
        'limit': 20,
      });
      expect(
        () => MessageTimelinePage.fromJson(
          _page([_message(2), _message(1)]),
          request: request,
        ),
        throwsFormatException,
      );
      expect(
        () => MessageTimelinePage.fromJson(
          _page([_message(1)], older: 9),
          request: request,
        ),
        throwsFormatException,
      );
      expect(
        () => MessageTimelinePage.fromJson(
          _page(const [], older: 1),
          request: request,
        ),
        throwsFormatException,
      );
      expect(
        () => MessageTimelinePage.fromJson(
          {
            ..._page([_message(1)]),
            'pagination': {
              'older': {'available': false, 'cursor': 1},
              'newer': {'available': false},
            },
          },
          request: request,
        ),
        throwsFormatException,
      );
    });
  });
}

Map<String, Object?> _page(
  List<Map<String, Object?>> messages, {
  int? older,
  int? newer,
}) =>
    {
      'conversationId': 'conversation-1',
      'messages': messages,
      'pagination': {
        'older': older == null
            ? {'available': false}
            : {'available': true, 'cursor': older},
        'newer': newer == null
            ? {'available': false}
            : {'available': true, 'cursor': newer},
      },
      'replay': {
        'resumeFrom': {'eventId': 'event-snapshot-42'},
      },
    };

Map<String, Object?> _message(
  int sequence, {
  String conversationId = 'conversation-1',
  bool enrichedRoot = false,
}) =>
    {
      'id': 'message-$sequence',
      'tenantId': 'tenant-1',
      'conversationId': conversationId,
      'author': {'type': 'user', 'userId': 'user-1'},
      'sequence': sequence,
      'createdAt': '2026-08-25T20:00:00.000Z',
      'updatedAt': '2026-08-25T20:00:00.000Z',
      'revision': {'revision': 1},
      'content': {
        'format': 'markdown',
        'text': 'message $sequence',
        if (enrichedRoot)
          'attachments': [
            {'attachmentId': 'attachment-1'},
          ],
      },
      'isThreadRoot': enrichedRoot,
      if (enrichedRoot)
        'threadSummary': {
          'threadId': 'thread-4',
          'replyCount': 2,
          'participantIds': ['user-1', 'user-2'],
          'unreadCount': 1,
          'lastReplyAt': '2026-08-25T20:05:00.000Z',
        },
      'reactions': enrichedRoot
          ? [
              {
                'reactionKey': 'thumbsup',
                'count': 2,
                'reactedByCurrentUser': true,
              },
            ]
          : <Object?>[],
      'attachmentMetadata': enrichedRoot
          ? [
              {
                'attachmentId': 'attachment-1',
                'fileName': 'status.png',
                'contentType': 'image/png',
                'sizeBytes': 2048,
                'downloadUrl': 'https://cdn.example.test/status.png',
                'previewUrl': 'https://cdn.example.test/status-preview.png',
                'width': 640,
                'height': 480,
                'altText': 'Current order status',
              },
            ]
          : <Object?>[],
    };
