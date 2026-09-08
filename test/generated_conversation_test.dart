import 'dart:convert';

import 'package:handrail_chat/core.dart';
import 'package:test/test.dart';

void main() {
  test(
      'lifecycle states and legacy absence round-trip independently of archive',
      () {
    final states = <ThreadLifecycle?>[
      null,
      ThreadLifecycle(revision: 1, locked: false),
      ThreadLifecycle(
          revision: 2,
          locked: false,
          closedAt: const IsoTimestamp('2026-09-06T12:00:00.000Z'),
          closedByUserId: const UserId('user-closer')),
      ThreadLifecycle(
          revision: 9007199254740991,
          locked: true,
          closedAt: const IsoTimestamp('2026-09-06T12:00:00.000Z'),
          closedByUserId: const UserId('user-closer')),
    ];
    for (final state in states) {
      for (final archive in <Map<String, Object?>>[
        {},
        {
          'archivedAt': '2026-09-06T13:00:00.000Z',
          'archivedByUserId': 'user-archiver'
        },
      ]) {
        final wire = {
          ..._thread(name: 'Launch 🚀', threadLifecycle: state).toJson(),
          ...archive
        };
        final parsed =
            ThreadConversation.fromJson(jsonDecode(jsonEncode(wire)));
        expect(parsed.threadLifecycle?.toJson(), state?.toJson());
        expect(parsed.toJson(), wire);
        expect(parsed.toJson().containsKey('threadLifecycle'), state != null);
      }
    }
  });

  test('lifecycle JSON rejects malformed values and incoherent state', () {
    const closure = {
      'closedAt': '2026-09-06T12:00:00.000Z',
      'closedByUserId': 'user-closer'
    };
    final invalid = <Object?>[
      null,
      false,
      1,
      'open',
      [],
      {},
      {'locked': false},
      {'revision': 1},
      for (final revision in [
        null,
        '1',
        true,
        0,
        -1,
        1.5,
        double.nan,
        double.infinity,
        double.negativeInfinity,
        9007199254740992
      ])
        {'revision': revision, 'locked': false},
      for (final locked in [null, 0, 1, 'false', [], {}])
        {'revision': 1, 'locked': locked},
      {'revision': 1, 'locked': true},
      {'revision': 1, 'locked': false, 'closedAt': closure['closedAt']},
      {
        'revision': 1,
        'locked': false,
        'closedByUserId': closure['closedByUserId']
      },
      for (final value in [null, false, 42, [], {}]) ...[
        {'revision': 1, 'locked': false, ...closure, 'closedAt': value},
        {'revision': 1, 'locked': true, ...closure, 'closedByUserId': value},
        {
          'revision': 1,
          'locked': false,
          'closedAt': value,
          'closedByUserId': value
        },
      ],
      {'revision': 1, 'locked': false, 'hidden': true},
      {'revision': 1, 'locked': false, 'archivedAt': closure['closedAt']},
    ];
    for (final value in invalid) {
      expect(() => ThreadLifecycle.fromJson(value), throwsFormatException);
      expect(
          () => Conversation.fromJson(
              {..._thread().toJson(), 'threadLifecycle': value}),
          throwsFormatException);
    }
    for (final type in ['channel', 'direct', 'group_direct']) {
      for (final value in [
        null,
        {'revision': 1, 'locked': false}
      ]) {
        expect(
            () => Conversation.fromJson({
                  ..._baseJson(type),
                  'visibility': 'private',
                  if (type == 'channel') 'name': 'Support',
                  'threadLifecycle': value,
                }),
            throwsFormatException);
      }
    }
  });

  test(
      'lifecycle constructors enforce revision, closure pairs, and locked state',
      () {
    for (final revision in [0, -1, 9007199254740992]) {
      expect(() => ThreadLifecycle(revision: revision, locked: false),
          throwsFormatException);
    }
    expect(
        () => ThreadLifecycle(revision: 1, locked: true), throwsArgumentError);
    expect(
        () => ThreadLifecycle(
            revision: 1,
            locked: false,
            closedAt: const IsoTimestamp('2026-09-06T12:00:00.000Z')),
        throwsArgumentError);
    expect(
        () => ThreadLifecycle(
            revision: 1,
            locked: false,
            closedByUserId: const UserId('user-closer')),
        throwsArgumentError);
  });

  test('all four conversation variants round-trip active and archived JSON',
      () {
    final conversations = <Map<String, Object?>>[
      {
        ..._baseJson('channel'),
        'name': 'Support',
        'visibility': 'public',
        'entity': <String, Object?>{'type': 'case', 'id': 'case-1'},
      },
      {..._baseJson('direct'), 'visibility': 'private'},
      {
        ..._baseJson('group_direct'),
        'visibility': 'private',
        'archivedAt': '2026-08-26T12:00:00.000Z',
        'archivedByUserId': 'user-archiver',
      },
      {
        ..._baseJson('thread'),
        'visibility': 'private',
        'parentConversationId': 'conversation-parent',
        'rootMessageId': 'message-root',
        'archivedAt': '2026-08-26T12:00:00.000Z',
        'archivedByUserId': 'user-archiver',
      },
      {
        ..._thread(name: 'Archived discussion 🚀').toJson(),
        'archivedAt': '2026-08-26T12:00:00.000Z',
        'archivedByUserId': 'user-archiver',
      },
    ];

    final decoded = conversations
        .map(
          (wire) => Conversation.fromJson(
            jsonDecode(jsonEncode(wire)),
          ),
        )
        .toList();

    expect(decoded[0], isA<ChannelConversation>());
    expect(decoded[1], isA<DirectConversation>());
    expect(decoded[2], isA<GroupDirectConversation>());
    expect(decoded[3], isA<ThreadConversation>());
    for (var index = 0; index < decoded.length; index += 1) {
      expect(decoded[index].toJson(), conversations[index]);
    }

    final channel = decoded[0] as ChannelConversation;
    expect(channel.id, const ConversationId('conversation-1'));
    expect(channel.tenantId, const TenantId('tenant-1'));
    expect(channel.entity?.type, 'case');
    expect(channel.entity?.id, 'case-1');
    expect(channel.archivedAt, isNull);

    final group = decoded[2] as GroupDirectConversation;
    expect(
      group.archivedAt,
      const IsoTimestamp('2026-08-26T12:00:00.000Z'),
    );
    expect(group.archivedByUserId, const UserId('user-archiver'));

    final thread = decoded[3] as ThreadConversation;
    expect(
      thread.parentConversationId,
      const ConversationId('conversation-parent'),
    );
    expect(thread.rootMessageId, const MessageId('message-root'));
  });

  test('named and unnamed thread constructors and JSON preserve identity', () {
    for (final name in <String?>[
      null,
      'Launch 🚀',
      '🚀',
      '🚀' * 100,
      'a' * 100,
      'e\u0301' * 50,
      'a b',
      'a\u0085b',
      '\u200b',
      '\u180e'
    ]) {
      final thread = _thread(name: name);
      final wire = thread.toJson();
      expect(wire.containsKey('name'), name != null);
      final parsed = ThreadConversation.fromJson(jsonDecode(jsonEncode(wire)));
      expect(parsed.name, name);
      expect(parsed.toJson(), wire);
      expect(parsed.id, thread.id);
      expect(parsed.parentConversationId, thread.parentConversationId);
      expect(parsed.rootMessageId, thread.rootMessageId);
    }
  });

  test('thread names reject malformed, blank, untrimmed and oversized values',
      () {
    final invalid = <Object?>[
      null,
      42,
      true,
      <Object?>[],
      <String, Object?>{},
      '',
      ' ',
      '  \t\n',
      'a' * 101,
      '🚀' * 101,
      'e\u0301' * 51,
      '\ud800',
      '\udfff',
      'x\ud800y',
      ' leading',
      'trailing '
    ];
    for (final value in invalid) {
      expect(
          () => validateThreadConversationName(value), throwsFormatException);
      expect(
          () => ThreadConversation.fromJson(
              {..._thread().toJson(), 'name': value}),
          throwsFormatException);
      if (value is String) {
        expect(() => _thread(name: value), throwsFormatException);
      }
    }
    const whitespace = [
      9,
      10,
      11,
      12,
      13,
      32,
      133,
      160,
      5760,
      8192,
      8193,
      8194,
      8195,
      8196,
      8197,
      8198,
      8199,
      8200,
      8201,
      8202,
      8232,
      8233,
      8239,
      8287,
      12288,
      65279
    ];
    for (final point in whitespace) {
      final space = String.fromCharCode(point);
      for (final name in [space, '${space}Launch', 'Launch$space']) {
        expect(() => _thread(name: name), throwsFormatException);
        expect(
            () => ThreadConversation.fromJson(
                {..._thread().toJson(), 'name': name}),
            throwsFormatException);
      }
      expect(_thread(name: 'a${space}b').name, 'a${space}b');
    }
  });

  test('required channel name and thread fields and forbidden DM names remain',
      () {
    expect(
        () => Conversation.fromJson(
            {..._baseJson('channel'), 'visibility': 'public'}),
        throwsFormatException);
    for (final type in ['direct', 'group_direct']) {
      expect(
          () => Conversation.fromJson(
              {..._baseJson(type), 'visibility': 'private', 'name': 'Name'}),
          throwsFormatException);
    }
    for (final key in [
      'id',
      'tenantId',
      'createdAt',
      'updatedAt',
      'visibility',
      'parentConversationId',
      'rootMessageId'
    ]) {
      final wire = _thread(name: 'Named').toJson()..remove(key);
      expect(() => Conversation.fromJson(wire), throwsFormatException);
    }
    for (final archive in [
      {'archivedAt': '2026-08-26T12:00:00.000Z'},
      {'archivedByUserId': 'user-archiver'},
    ]) {
      expect(
          () => Conversation.fromJson(
              {..._thread(name: 'Named').toJson(), ...archive}),
          throwsFormatException);
    }
  });

  test('variant-specific factories enforce their discriminant', () {
    expect(
      ChannelConversation.fromJson({
        ..._baseJson('channel'),
        'name': 'Support',
        'visibility': 'private',
      }),
      isA<ChannelConversation>(),
    );
    expect(
      () => ChannelConversation.fromJson({
        ..._baseJson('direct'),
        'visibility': 'private',
      }),
      throwsFormatException,
    );
  });

  test('parsing rejects every variant family illegal field', () {
    final illegal = <Map<String, Object?>>[
      {
        ..._baseJson('channel'),
        'name': 'Support',
        'visibility': 'public',
        'rootMessageId': 'message-root',
      },
      {
        ..._baseJson('direct'),
        'visibility': 'private',
        'name': 'Not allowed',
      },
      {
        ..._baseJson('group_direct'),
        'visibility': 'private',
        'entity': <String, Object?>{'type': 'case', 'id': 'case-1'},
      },
      {
        ..._baseJson('thread'),
        'visibility': 'private',
        'parentConversationId': 'conversation-parent',
        'rootMessageId': 'message-root',
        'entity': <String, Object?>{'type': 'case', 'id': 'case-1'},
      },
    ];

    for (final wire in illegal) {
      expect(() => Conversation.fromJson(wire), throwsFormatException);
    }
  });

  test('parsing enforces private direct visibility and paired archive fields',
      () {
    expect(
      () => Conversation.fromJson({
        ..._baseJson('direct'),
        'visibility': 'public',
      }),
      throwsFormatException,
    );
    expect(
      () => Conversation.fromJson({
        ..._baseJson('direct'),
        'visibility': 'private',
        'archivedAt': '2026-08-26T12:00:00.000Z',
      }),
      throwsFormatException,
    );
    expect(
      () => Conversation.fromJson({
        ..._baseJson('direct'),
        'visibility': 'private',
        'archivedAt': null,
        'archivedByUserId': null,
      }),
      throwsFormatException,
    );
    expect(
      () => DirectConversation(
        id: const ConversationId('conversation-1'),
        tenantId: const TenantId('tenant-1'),
        createdAt: const IsoTimestamp('2026-08-26T10:00:00.000Z'),
        updatedAt: const IsoTimestamp('2026-08-26T11:00:00.000Z'),
        archivedAt: const IsoTimestamp('2026-08-26T12:00:00.000Z'),
      ),
      throwsArgumentError,
    );
  });

  test('parsing rejects malformed objects, scalars, and discriminants', () {
    expect(() => Conversation.fromJson('channel'), throwsFormatException);
    expect(
      () => Conversation.fromJson({..._baseJson('unknown')}),
      throwsFormatException,
    );
    expect(
      () => Conversation.fromJson({
        ..._baseJson('direct'),
        'id': 1,
        'visibility': 'private',
      }),
      throwsFormatException,
    );
    expect(
      () => Conversation.fromJson({
        ..._baseJson('channel'),
        'name': 'Support',
        'visibility': 'public',
        'entity': 'case-1',
      }),
      throwsFormatException,
    );
    expect(
      () => HostEntityReference.fromJson({'type': 'case', 'id': 1}),
      throwsFormatException,
    );
  });
}

Map<String, Object?> _baseJson(String type) => {
      'id': 'conversation-1',
      'tenantId': 'tenant-1',
      'createdAt': '2026-08-26T10:00:00.000Z',
      'updatedAt': '2026-08-26T11:00:00.000Z',
      'type': type,
    };

ThreadConversation _thread({String? name, ThreadLifecycle? threadLifecycle}) =>
    ThreadConversation(
      id: const ConversationId('conversation-thread'),
      tenantId: const TenantId('tenant-1'),
      createdAt: const IsoTimestamp('2026-08-26T10:00:00.000Z'),
      updatedAt: const IsoTimestamp('2026-08-26T11:00:00.000Z'),
      visibility: ConversationVisibility.private,
      parentConversationId: const ConversationId('conversation-parent'),
      rootMessageId: const MessageId('message-root'),
      name: name,
      threadLifecycle: threadLifecycle,
    );
