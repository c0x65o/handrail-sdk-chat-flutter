import 'dart:convert';

import 'package:handrail_chat/core.dart';
import 'package:test/test.dart';

void main() {
  test('reply references preserve both ping choices on all message variants', () {
    for (final notifyAuthor in [true, false]) {
      final reference = MessageReplyReference(
        messageId: const MessageId('message-source'),
        notifyAuthor: notifyAuthor,
      );
      final referenceWire = <String, Object?>{
        'messageId': 'message-source', 'notifyAuthor': notifyAuthor,
      };
      expect(reference.toJson(), referenceWire);
      final content = MessageContent.fromJson({'format': 'plain', 'text': 'Friday'});
      final composition = MessageComposition(content: content, replyTo: reference);
      expect(composition.toJson(), {'content': content.toJson(), 'replyTo': referenceWire});
      expect(MessageComposition.fromJson(_roundTrip(composition.toJson())).toJson(), composition.toJson());
      for (final deleted in [false, true]) {
        for (final redact in [false, true]) {
          if (!deleted && redact) continue;
          final wire = <String, Object?>{
            ..._baseMessage(),
            'content': redact ? null : content.toJson(),
            'replyTo': referenceWire,
            if (deleted) 'deletedAt': '2026-09-06T00:00:00.000Z',
            if (deleted) 'deletedByUserId': 'user-1',
          };
          final parsed = Message.fromJson(_roundTrip(wire));
          expect(parsed.replyTo!.messageId, reference.messageId);
          expect(parsed.replyTo!.notifyAuthor, notifyAuthor);
          expect(parsed.toJson(), wire);
          final Message constructed = deleted
              ? DeletedMessage(
                  id: parsed.id, tenantId: parsed.tenantId,
                  conversationId: parsed.conversationId, author: parsed.author,
                  sequence: parsed.sequence, createdAt: parsed.createdAt,
                  updatedAt: parsed.updatedAt, revision: parsed.revision,
                  content: parsed.content, replyTo: reference,
                  deletedAt: (parsed as DeletedMessage).deletedAt,
                  deletedByUserId: parsed.deletedByUserId,
                )
              : ActiveMessage(
                  id: parsed.id, tenantId: parsed.tenantId,
                  conversationId: parsed.conversationId, author: parsed.author,
                  sequence: parsed.sequence, createdAt: parsed.createdAt,
                  updatedAt: parsed.updatedAt, revision: parsed.revision,
                  content: parsed.content!, replyTo: reference,
                );
          expect(constructed.toJson(), wire);
        }
      }
    }
  });

  test('legacy messages and compositions omit replyTo on round-trip', () {
    final content = MessageContent.fromJson({'format': 'plain', 'text': 'Legacy'});
    final composition = MessageComposition(content: content);
    expect(composition.toJson().containsKey('replyTo'), isFalse);
    expect(MessageComposition.fromJson(composition.toJson()).toJson(), composition.toJson());
    for (final deleted in [false, true]) {
      final wire = <String, Object?>{
        ..._baseMessage(), 'content': deleted ? null : content.toJson(),
        if (deleted) 'deletedAt': '2026-09-06T00:00:00.000Z',
        if (deleted) 'deletedByUserId': 'user-1',
      };
      final message = Message.fromJson(wire);
      expect(message.replyTo, isNull);
      expect(message.toJson(), wire);
      expect(message.toJson().containsKey('replyTo'), isFalse);
    }
  });

  test('reply references reject malformed objects in every parent parser', () {
    final invalid = <Object?>[
      null, false, 1, 'source', <Object?>[], <String, Object?>{},
      {'messageId': 'source'}, {'notifyAuthor': true},
      for (final id in <Object?>[null, true, 42, {}, [], '', ' source', 'source ', 'a\n', 'a\u007f', 'a\u0085', 'a\u2028', 'a' * 256, 'é' * 128])
        {'messageId': id, 'notifyAuthor': true},
      for (final ping in <Object?>[null, 'true', 'false', 0, 1, {}, []])
        {'messageId': 'source', 'notifyAuthor': ping},
      for (final field in ['tenantId', 'actor', 'actorId', 'userId', 'author', 'authorId', 'sourceMessageId', 'originalAuthor', 'originalCreatedAt', 'displayName', 'sourceDisplay', 'source', 'content', 'unexpected'])
        {'messageId': 'source', 'notifyAuthor': true, field: 'spoofed'},
      <Object?, Object?>{'messageId': 'source', 'notifyAuthor': true, 1: 'invalid key'},
    ];
    for (final reference in invalid) {
      expect(() => MessageReplyReference.fromJson(reference), throwsFormatException, reason: '$reference');
      expect(() => MessageComposition.fromJson({
        'content': {'format': 'plain', 'text': 'Friday'}, 'replyTo': reference,
      }), throwsFormatException, reason: '$reference');
      for (final deleted in [false, true]) {
        final wire = <String, Object?>{
          ..._baseMessage(),
          'content': deleted ? null : {'format': 'plain', 'text': 'Friday'},
          'replyTo': reference,
          if (deleted) 'deletedAt': '2026-09-06T00:00:00.000Z',
          if (deleted) 'deletedByUserId': 'user-1',
        };
        expect(() => Message.fromJson(wire), throwsFormatException, reason: '$reference');
        expect(() => deleted ? DeletedMessage.fromJson(wire) : ActiveMessage.fromJson(wire), throwsFormatException);
      }
    }
    for (final id in ['', ' source', 'a\u0000', 'é' * 128]) {
      expect(() => MessageReplyReference(messageId: MessageId(id), notifyAuthor: false), throwsFormatException);
    }
    for (final id in ['opaque-source:123', 'a' * 255, 'é' * 127 + 'a']) {
      final wire = {'messageId': id, 'notifyAuthor': false};
      expect(MessageReplyReference.fromJson(wire).toJson(), wire);
    }
  });

  test('reply metadata cannot be embedded in content or forwarded attribution', () {
    final reply = {'messageId': 'source', 'notifyAuthor': false};
    expect(() => MessageContent.fromJson({
      'format': 'plain', 'text': 'Friday', 'replyTo': reply,
    }), throwsFormatException);
    expect(() => ForwardedMessageSnapshot.fromJson({
      'sourceMessageId': 'source',
      'originalAuthor': {'userId': 'user-1', 'displayName': 'Alice'},
      'originalCreatedAt': '2026-09-06T00:00:00.000Z',
      'replyTo': reply,
    }), throwsFormatException);
  });

  test('active markdown messages round-trip every nested message shape', () {
    final wire = <String, Object?>{
      ..._baseMessage(),
      'content': <String, Object?>{
        'format': 'markdown',
        'text': 'Hello **team**',
        'mentions': <Object?>[
          <String, Object?>{'type': 'user', 'userId': 'user-2'},
          <String, Object?>{
            'type': 'conversation',
            'conversationId': 'conversation-2',
          },
          <String, Object?>{
            'type': 'entity',
            'entity': <String, Object?>{'type': 'order', 'id': 'order-42'},
          },
        ],
        'attachments': <Object?>[
          <String, Object?>{'attachmentId': 'attachment-1'},
        ],
        'blocks': <Object?>[
          <String, Object?>{
            'type': 'order.preview',
            'data': <String, Object?>{
              'orderId': 'order-42',
              'flags': <Object?>[true, null, 3, 2.5],
              'nested': <String, Object?>{
                'labels': <Object?>['priority', 'open'],
              },
            },
          },
        ],
      },
      'revision': <String, Object?>{
        'revision': 2,
        'editedAt': '2026-08-26T10:05:00.000Z',
        'editedByUserId': 'user-1',
      },
      'threadSummary': <String, Object?>{
        'threadId': 'conversation-thread',
        'replyCount': 3,
        'participantIds': <Object?>['user-1', 'user-2'],
        'unreadCount': 1,
        'lastReplyAt': '2026-08-26T10:04:00.000Z',
      },
    };

    final message = Message.fromJson(jsonDecode(jsonEncode(wire)));

    expect(message, isA<ActiveMessage>());
    expect(message.toJson(), wire);
    final active = message as ActiveMessage;
    expect(active.content.format, MessageContentFormat.markdown);
    expect(active.content.mentions, hasLength(3));
    expect(active.content.mentions![0], isA<UserMention>());
    expect(active.content.mentions![1], isA<ConversationMention>());
    expect(active.content.mentions![2], isA<EntityMention>());
    expect(active.content.attachments!.single.attachmentId,
        const AttachmentId('attachment-1'));
    expect(active.revision.revision, 2);
    expect(active.threadSummary!.participantIds,
        const [UserId('user-1'), UserId('user-2')]);
  });

  test('deleted messages round-trip retained plain and redacted content', () {
    final retained = <String, Object?>{
      ..._baseMessage(),
      'content': <String, Object?>{'format': 'plain', 'text': 'Retained'},
      'deletedAt': '2026-08-26T10:06:00.000Z',
      'deletedByUserId': 'user-1',
    };
    final redacted = <String, Object?>{
      ..._baseMessage(),
      'content': null,
      'deletedAt': '2026-08-26T10:06:00.000Z',
      'deletedByUserId': 'user-1',
    };

    final retainedMessage = Message.fromJson(retained);
    final redactedMessage = Message.fromJson(redacted);

    expect(retainedMessage, isA<DeletedMessage>());
    expect((retainedMessage as DeletedMessage).content!.format,
        MessageContentFormat.plain);
    expect(retainedMessage.toJson(), retained);
    expect(redactedMessage, isA<DeletedMessage>());
    expect((redactedMessage as DeletedMessage).content, isNull);
    expect(redactedMessage.toJson(), redacted);
  });

  test('forwarded attribution round-trips as a closed immutable snapshot', () {
    final wire = <String, Object?>{
      'format': 'plain',
      'text': 'Frozen source text',
      'forwarded': <String, Object?>{
        'sourceMessageId': 'message-source',
        'originalAuthor': <String, Object?>{
          'userId': 'original-user',
          'displayName': 'Original Author',
        },
        'originalCreatedAt': '2026-08-20T12:30:00.000Z',
      },
    };
    final content = MessageContent.fromJson(_roundTrip(wire));
    expect(content.toJson(), wire);
    expect(content.forwarded!.sourceMessageId, const MessageId('message-source'));
    expect(content.forwarded!.originalAuthor.displayName, 'Original Author');
    expect(
      () => ForwardedMessageSnapshot.fromJson({
        ...wire['forwarded']! as Map<String, Object?>,
        'session': 'secret',
      }),
      throwsFormatException,
    );
  });

  test('composition and variant-specific factories round-trip', () {
    final wire = <String, Object?>{
      'content': <String, Object?>{'format': 'plain', 'text': 'Draft'},
    };
    expect(MessageComposition.fromJson(wire).toJson(), wire);
    expect(
      UserMention.fromJson(<String, Object?>{
        'type': 'user',
        'userId': 'user-2',
      }),
      isA<UserMention>(),
    );
    expect(
      () => UserMention.fromJson(<String, Object?>{
        'type': 'conversation',
        'conversationId': 'conversation-2',
      }),
      throwsFormatException,
    );
  });

  test('block JSON and public collections are defensively immutable', () {
    final nested = <String, Object?>{
      'items': <Object?>[
        <String, Object?>{'value': 1},
      ],
    };
    final block = MessageBlock(type: 'custom', data: nested);
    nested['items'] = <Object?>['changed'];

    expect(block.toJson()['data'], {
      'items': [
        {'value': 1},
      ],
    });
    expect(
      () => (block.data as Map<String, Object?>)['new'] = true,
      throwsUnsupportedError,
    );

    final sourceMentions = <MessageMention>[
      const UserMention(userId: UserId('user-1')),
    ];
    final content = MessageContent(
      format: MessageContentFormat.plain,
      text: 'Immutable',
      mentions: sourceMentions,
    );
    sourceMentions.clear();
    expect(content.mentions, hasLength(1));
    expect(() => content.mentions!.clear(), throwsUnsupportedError);
  });

  test('parsing rejects malformed and missing discriminators', () {
    final malformed = <Object?>[
      <String, Object?>{'text': 'Missing format'},
      <String, Object?>{'format': 'html', 'text': 'No HTML'},
      <String, Object?>{'format': 'plain'},
      <String, Object?>{'format': 'plain', 'text': 'x', 'unknown': true},
    ];
    for (final wire in malformed) {
      expect(() => MessageContent.fromJson(wire), throwsFormatException);
    }

    for (final mention in <Object?>[
      <String, Object?>{'userId': 'user-1'},
      <String, Object?>{'type': 'team', 'userId': 'user-1'},
      <String, Object?>{'type': 'user'},
      <String, Object?>{
        'type': 'entity',
        'entity': <String, Object?>{'type': 'order', 'id': '1'},
        'extra': true,
      },
    ]) {
      expect(() => MessageMention.fromJson(mention), throwsFormatException);
    }

    expect(
      () => MessageAuthorIdentity.fromJson(
        <String, Object?>{'type': 'bot', 'userId': 'user-1'},
      ),
      throwsFormatException,
    );
  });

  test('closed generated objects reject unknown fields and invalid JSON data',
      () {
    final parsers = <void Function()>[
      () => MessageAttachmentReference.fromJson(
            <String, Object?>{'attachmentId': 'attachment-1', 'extra': true},
          ),
      () => MessageBlock.fromJson(
            <String, Object?>{'type': 'custom', 'data': null, 'extra': true},
          ),
      () => MessageRevisionMetadata.fromJson(
            <String, Object?>{'revision': 1, 'extra': true},
          ),
      () => ThreadSummary.fromJson(<String, Object?>{
            'threadId': 'conversation-thread',
            'replyCount': 0,
            'participantIds': <Object?>[],
            'unreadCount': 0,
            'extra': true,
          }),
      () => MessageComposition.fromJson(<String, Object?>{
            'content': <String, Object?>{'format': 'plain', 'text': 'x'},
            'author': <String, Object?>{'type': 'user', 'userId': 'spoof'},
          }),
      () => Message.fromJson(<String, Object?>{
            ..._baseMessage(),
            'content': <String, Object?>{'format': 'plain', 'text': 'x'},
            'extra': true,
          }),
      () => MessageBlock(type: 'custom', data: double.nan),
      () => MessageBlock(type: 'custom', data: <Object?, Object?>{1: 'bad'}),
    ];
    for (final parse in parsers) {
      expect(parse, throwsFormatException);
    }
  });

  test('messages reject missing fields and illegal deletion combinations', () {
    final validContent = <String, Object?>{'format': 'plain', 'text': 'x'};
    final invalid = <Map<String, Object?>>[
      {..._baseMessage(), 'content': null},
      {
        ..._baseMessage(),
        'content': validContent,
        'deletedAt': '2026-08-26T10:06:00.000Z',
      },
      {
        ..._baseMessage(),
        'content': validContent,
        'deletedByUserId': 'user-1',
      },
      {
        ..._baseMessage(),
        'content': validContent,
        'deletedAt': null,
        'deletedByUserId': 'user-1',
      },
      {
        ..._baseMessage(),
        'deletedAt': '2026-08-26T10:06:00.000Z',
        'deletedByUserId': 'user-1',
      },
      {
        ..._baseMessage(),
        'content': validContent,
        'author': <String, Object?>{'type': 'user'},
      },
    ];

    final missingId = <String, Object?>{
      ..._baseMessage(),
      'content': validContent,
    }..remove('id');
    invalid.add(missingId);

    for (final wire in invalid) {
      expect(() => Message.fromJson(wire), throwsFormatException);
    }
  });

  test('shared thread summary facts round-trip exact fields', () {
    for (final example in [
      (replyCount: 0, participantIds: <String>[], lastReplyAt: null),
      (
        replyCount: 3,
        participantIds: ['user-1', 'user-2'],
        lastReplyAt: '2026-08-26T10:04:00.000Z',
      ),
    ]) {
      final wire = <String, Object?>{
        'threadId': 'conversation-thread',
        'replyCount': example.replyCount,
        'participantIds': example.participantIds,
        if (example.lastReplyAt != null) 'lastReplyAt': example.lastReplyAt,
      };
      final facts = ThreadSummaryFacts.fromJson(_roundTrip(wire));

      expect(facts.threadId, const ConversationId('conversation-thread'));
      expect(facts.replyCount, example.replyCount);
      expect(facts.participantIds, example.participantIds.map(UserId.new));
      expect(
        facts.lastReplyAt,
        example.lastReplyAt == null ? null : IsoTimestamp(example.lastReplyAt!),
      );
      expect(facts.toJson(), wire);
      expect(facts.toJson().keys.toSet(), {
        'threadId',
        'replyCount',
        'participantIds',
        if (example.lastReplyAt != null) 'lastReplyAt',
      });
      expect(facts.toJson(), isNot(contains('unreadCount')));
    }
  });

  test('shared thread summary facts reject unknown and malformed fields', () {
    final valid = <String, Object?>{
      'threadId': 'conversation-thread',
      'replyCount': 3,
      'participantIds': <Object?>['user-1', 'user-2'],
    };
    for (final field in ['unreadCount', 'extra']) {
      expect(
        () => ThreadSummaryFacts.fromJson(_roundTrip({...valid, field: 0})),
        throwsFormatException,
        reason: 'unknown $field',
      );
    }
    for (final field in ['threadId', 'replyCount', 'participantIds']) {
      final wire = {...valid}..remove(field);
      expect(
        () => ThreadSummaryFacts.fromJson(_roundTrip(wire)),
        throwsFormatException,
        reason: 'missing $field',
      );
    }
    final invalidValues = <String, List<Object?>>{
      'threadId': [null, 42, true, <Object?>[], <String, Object?>{}],
      'replyCount': [
        null,
        -1,
        1.5,
        1.0,
        '3',
        true,
        <Object?>[],
        <String, Object?>{}
      ],
      'participantIds': [
        null,
        'user-1',
        42,
        true,
        <String, Object?>{},
        for (final entry in [null, 42, true, <Object?>[], <String, Object?>{}])
          <Object?>['user-1', entry],
      ],
      'lastReplyAt': [null, 42, true, <Object?>[], <String, Object?>{}],
    };
    for (final field in invalidValues.entries) {
      for (final value in field.value) {
        expect(
          () => ThreadSummaryFacts.fromJson(
            _roundTrip({...valid, field.key: value}),
          ),
          throwsFormatException,
          reason: '${field.key}: ${jsonEncode(value)}',
        );
      }
    }
  });

  test('normalized thread summaries round-trip exact nullable unread fields', () {
    for (final unreadCount in <int?>[null, 0, 2]) {
      for (final example in [
        (replyCount: 0, participantIds: <String>[], lastReplyAt: null),
        (
          replyCount: 3,
          participantIds: ['user-1', 'user-2'],
          lastReplyAt: '2026-08-26T10:04:00.000Z',
        ),
      ]) {
        final wire = <String, Object?>{
          'threadId': 'conversation-thread',
          'replyCount': example.replyCount,
          'participantIds': example.participantIds,
          'unreadCount': unreadCount,
          if (example.lastReplyAt != null) 'lastReplyAt': example.lastReplyAt,
        };
        final summary = NormalizedThreadSummary.fromJson(_roundTrip(wire));

        expect(summary.threadId, const ConversationId('conversation-thread'));
        expect(summary.replyCount, example.replyCount);
        expect(summary.participantIds, example.participantIds.map(UserId.new));
        expect(summary.unreadCount, unreadCount);
        expect(
          summary.lastReplyAt,
          example.lastReplyAt == null ? null : IsoTimestamp(example.lastReplyAt!),
        );
        expect(summary.toJson(), wire);
        expect(summary.toJson().keys.toSet(), {
          'threadId',
          'replyCount',
          'participantIds',
          'unreadCount',
          if (example.lastReplyAt != null) 'lastReplyAt',
        });
        expect(() => summary.participantIds.clear(), throwsUnsupportedError);
      }
    }
  });

  test('normalized thread summary participant lists are copied and immutable',
      () {
    final sourceIds = <UserId>[const UserId('user-1')];
    final sourceJson = <String, Object?>{
      'threadId': 'conversation-thread',
      'replyCount': 1,
      'participantIds': <String>['user-1'],
      'unreadCount': null,
    };
    final summaries = [
      NormalizedThreadSummary(
        threadId: const ConversationId('conversation-thread'),
        replyCount: 1,
        participantIds: sourceIds,
        unreadCount: null,
      ),
      NormalizedThreadSummary.fromJson(sourceJson),
    ];
    sourceIds.clear();
    (sourceJson['participantIds']! as List<String>).clear();

    for (final summary in summaries) {
      expect(summary.participantIds, const [UserId('user-1')]);
      expect(summary.toJson()['participantIds'], ['user-1']);
      expect(() => summary.participantIds.clear(), throwsUnsupportedError);
      expect(
        () => summary.participantIds[0] = const UserId('user-2'),
        throwsUnsupportedError,
      );
    }
  });

  test('normalized thread summaries reject missing unread and invalid fields',
      () {
    final valid = <String, Object?>{
      'threadId': 'conversation-thread',
      'replyCount': 3,
      'participantIds': <String>['user-1', 'user-2'],
      'unreadCount': null,
    };
    final invalid = <String, Map<String, Object?>>{
      'missing unreadCount': {...valid}..remove('unreadCount'),
      'unknown field': {...valid, 'extra': true},
      for (final field in ['unreadCount', 'replyCount'])
        for (final value in [-1, 1.5])
          '$field: $value': {...valid, field: value},
    };
    for (final example in invalid.entries) {
      expect(
        () => NormalizedThreadSummary.fromJson(_roundTrip(example.value)),
        throwsFormatException,
        reason: example.key,
      );
    }
  });

  test('legacy thread summary still requires numeric unreadCount', () {
    final wire = <String, Object?>{
      'threadId': 'conversation-thread',
      'replyCount': 3,
      'participantIds': <Object?>['user-1', 'user-2'],
      'unreadCount': 1,
      'lastReplyAt': '2026-08-26T10:04:00.000Z',
    };
    final summary = ThreadSummary.fromJson(_roundTrip(wire));
    expect(summary.threadId, const ConversationId('conversation-thread'));
    expect(summary.replyCount, 3);
    expect(summary.participantIds, const [UserId('user-1'), UserId('user-2')]);
    expect(summary.unreadCount, 1);
    expect(summary.lastReplyAt, const IsoTimestamp('2026-08-26T10:04:00.000Z'));
    expect(summary.toJson(), wire);
    expect(summary.toJson().keys.toSet(), {
      'threadId',
      'replyCount',
      'participantIds',
      'unreadCount',
      'lastReplyAt',
    });
    for (final invalid in [
      {...wire}..remove('unreadCount'),
      {...wire, 'unreadCount': null},
    ]) {
      expect(
        () => ThreadSummary.fromJson(_roundTrip(invalid)),
        throwsFormatException,
        reason:
            'unreadCount ${invalid.containsKey('unreadCount') ? 'null' : 'missing'}',
      );
    }
  });

  test('revision and thread summary enforce integer bounds and required fields',
      () {
    expect(
      () => MessageRevisionMetadata.fromJson(
        <String, Object?>{'revision': 0},
      ),
      throwsFormatException,
    );
    expect(
      () => ThreadSummary.fromJson(<String, Object?>{
        'threadId': 'conversation-thread',
        'replyCount': -1,
        'participantIds': <Object?>[],
        'unreadCount': 0,
      }),
      throwsFormatException,
    );
    expect(
      () => ThreadSummary.fromJson(<String, Object?>{
        'threadId': 'conversation-thread',
        'replyCount': 0,
        'unreadCount': 0,
      }),
      throwsFormatException,
    );
  });
}

Object? _roundTrip(Object? value) => jsonDecode(jsonEncode(value));

Map<String, Object?> _baseMessage() => <String, Object?>{
      'id': 'message-1',
      'tenantId': 'tenant-1',
      'conversationId': 'conversation-1',
      'author': <String, Object?>{'type': 'user', 'userId': 'user-1'},
      'sequence': 7,
      'createdAt': '2026-08-26T10:00:00.000Z',
      'updatedAt': '2026-08-26T10:05:00.000Z',
      'revision': <String, Object?>{'revision': 1},
    };
