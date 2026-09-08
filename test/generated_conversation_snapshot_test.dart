import 'dart:convert';
import 'dart:io';

import 'package:handrail_chat/src/generated/conversation.dart';
import 'package:handrail_chat/src/generated/conversation_snapshot.dart';
import 'package:handrail_chat/src/generated/identifiers.dart';
import 'package:test/test.dart';

const _now = '2026-08-26T15:00:00.000Z';
const _tenantId = 'tenant-1';
const _userId = 'user-current';

void main() {
  test('preference revisions preserve legacy absence and validate stored authority', () {
    final base = <String, Object?>{
      'conversationId': 'thread', 'userId': _userId, 'isStarred': false,
      'notificationPreference': 'all', 'mute': {'muted': false}, 'updatedAt': _now,
    };
    expect(ConversationSnapshotPreference.fromJson(base).toJson(), base);
    for (final revision in [0, 1, 7, 9007199254740991]) {
      final wire = {...base, 'preferenceRevision': revision};
      expect(ConversationSnapshotPreference.fromJson(wire).toJson(), wire);
    }
    for (final revision in [-1, 0.5, '1', null, 9007199254740992]) {
      expect(() => ConversationSnapshotPreference.fromJson({...base, 'preferenceRevision': revision}), throwsFormatException);
    }
  });

  final lifecycle = jsonDecode(
      File('conformance-tests/thread-lifecycle.json')
          .readAsStringSync()) as Map<String, dynamic>;

  List<Map<String, Object?>> lifecycleSnapshots(Map<String, Object?> summary) =>
      [
        _listFixture(scope: const {'type': 'organization'}, items: [summary]),
        {
          ..._detailFixture('thread', 'thread-1'),
          'conversation': {
            ...summary,
            'memberUserIds': [_userId]
          }
        },
      ];
  Map<String, Object?> parseLifecycleSnapshot(Map<String, Object?> wire) =>
      wire['kind'] == 'conversation_list'
          ? ConversationListSnapshot.fromJson(wire).toJson()
          : ConversationDetailSnapshot.fromJson(wire).toJson();

  test(
      'lifecycle list/detail round trips preserve legacy, names, archive and private state',
      () {
    for (final state in [null, ...lifecycle['valid'] as List]) {
      for (final name in [null, 'Launch 🚀']) {
        for (final archived in [false, true]) {
          final summary = {
            ..._summaryFixture('thread', 'thread-1'),
            if (name != null) 'name': name,
            if (state != null) 'threadLifecycle': state,
            if (archived) 'archivedAt': _now,
            if (archived) 'archivedByUserId': 'user-archiver',
          };
          for (final wire in lifecycleSnapshots(summary)) {
            final parsed = parseLifecycleSnapshot(wire);
            expect(parsed, wire);
            expect(
                parseLifecycleSnapshot(
                    Map<String, Object?>.from(_jsonRoundTrip(parsed) as Map)),
                wire);
          }
        }
      }
    }
  });

  test(
      'lifecycle snapshots reject malformed metadata and every non-thread lifecycle',
      () {
    for (final type in ['thread', 'channel', 'direct', 'group_direct']) {
      final invalid = type == 'thread'
          ? lifecycle['invalid'] as List
          : [null, ...lifecycle['valid'] as List];
      for (final state in invalid) {
        final summary = {
          ..._summaryFixture(type, 'thread-1'),
          'threadLifecycle': state
        };
        for (final wire in lifecycleSnapshots(summary)) {
          expect(() => parseLifecycleSnapshot(wire), throwsFormatException);
        }
      }
    }
  });

  final names = jsonDecode(
          File('conformance-tests/thread-names.json').readAsStringSync())
      as Map<String, dynamic>;

  test(
      'named and unnamed thread snapshots retain names through construction and JSON',
      () {
    for (final visibility in ConversationVisibility.values) {
      for (final name in <String?>[
        null,
        ...List<String>.from(names['valid'] as List)
      ]) {
        final base = ConversationSnapshotSummary.fromJson(
            _summaryFixture('thread', 'thread-1'));
        final conversation = ThreadConversation(
          id: base.conversation.id,
          tenantId: base.conversation.tenantId,
          createdAt: base.conversation.createdAt,
          updatedAt: base.conversation.updatedAt,
          visibility: visibility,
          parentConversationId: const ConversationId('conversation-parent'),
          rootMessageId: const MessageId('message-root'),
          name: name,
        );
        final summary = ConversationSnapshotSummary(
          conversation: conversation,
          latestSequence: base.latestSequence,
          activityAt: base.activityAt,
          unreadMentionCount: base.unreadMentionCount,
          currentMember: base.currentMember,
          currentReadState: base.currentReadState,
          currentPreference: base.currentPreference,
          activeMemberUserIds: base.activeMemberUserIds,
        );
        final wire = summary.toJson();
        expect(wire.containsKey('name'), name != null);
        expect(wire['name'], name);
        final listWire =
            _listFixture(scope: const {'type': 'organization'}, items: [wire]);
        final list =
            ConversationListSnapshot.fromJson(_jsonRoundTrip(listWire));
        expect(list.toJson(), listWire);
        expect(
            (list.items.single.conversation as ThreadConversation).name, name);
        final detailWire = {
          ..._detailFixture('thread', 'thread-1'),
          'conversation': {
            ...wire,
            'memberUserIds': [_userId, 'user-other']
          },
        };
        final detail =
            ConversationDetailSnapshot.fromJson(_jsonRoundTrip(detailWire));
        expect(detail.toJson(), detailWire);
        expect(
            ConversationDetailSnapshot.fromJson(_jsonRoundTrip(detail.toJson()))
                .toJson(),
            detailWire);
      }
    }
  });

  test('thread snapshot parsing rejects all invalid supplied names', () {
    for (final name in names['invalid'] as List) {
      final summary = {..._summaryFixture('thread', 'thread-1'), 'name': name};
      expect(() => ConversationSnapshotSummary.fromJson(summary),
          throwsFormatException);
      expect(
          () => ConversationListSnapshot.fromJson(_listFixture(
              scope: const {'type': 'organization'}, items: [summary])),
          throwsFormatException);
      expect(
          () => ConversationDetailSnapshot.fromJson({
                ..._detailFixture('thread', 'thread-1'),
                'conversation': {
                  ...summary,
                  'memberUserIds': [_userId]
                },
              }),
          throwsFormatException);
      if (name is String) {
        expect(
            () => ThreadConversation(
                  id: const ConversationId('thread-1'),
                  tenantId: const TenantId(_tenantId),
                  createdAt: const IsoTimestamp(_now),
                  updatedAt: const IsoTimestamp(_now),
                  visibility: ConversationVisibility.public,
                  parentConversationId:
                      const ConversationId('conversation-parent'),
                  rootMessageId: const MessageId('message-root'),
                  name: name,
                ),
            throwsFormatException);
      }
    }
  });

  test('named thread snapshots retain metadata and current-state invariants',
      () {
    final thread = {
      ..._summaryFixture('thread', 'thread-1'),
      'name': 'Launch 🚀'
    };
    final patches = <Map<String, Object?>>[
      for (final field in ['parentConversationId', 'rootMessageId'])
        for (final value in <Object?>[null, '', 7]) {field: value},
      {'visibility': 'invited'},
      {'visibility': null},
      {
        'entity': {'type': 'project', 'id': 'project-1'}
      },
      {'archivedAt': 'invalid'},
      {'archivedByUserId': 'user-other'},
      {
        'currentMember': {
          ...thread['currentMember']! as Map<String, Object?>,
          'tenantId': 'other'
        }
      },
      {
        'currentReadState': {
          ...thread['currentReadState']! as Map<String, Object?>,
          'userId': 'other'
        }
      },
      {
        'currentPreference': {
          ...thread['currentPreference']! as Map<String, Object?>,
          'conversationId': 'other'
        }
      },
    ];
    final invalid = [
      for (final patch in patches) {...thread, ...patch},
      for (final field in ['parentConversationId', 'rootMessageId'])
        Map<String, Object?>.from(thread)..remove(field),
    ];
    for (final summary in invalid) {
      expect(
          () => ConversationListSnapshot.fromJson(_listFixture(
              scope: const {'type': 'organization'}, items: [summary])),
          throwsFormatException);
      expect(
          () => ConversationDetailSnapshot.fromJson({
                ..._detailFixture('thread', 'thread-1'),
                'conversation': {
                  ...summary,
                  'memberUserIds': [_userId]
                },
              }),
          throwsFormatException);
    }
  });

  test('backend list huddle metadata round-trips outside the conversation', () {
    for (final active in [false, true]) {
      final fixture = _listFixture(
        scope: const {'type': 'organization'},
        items: [
          {..._summaryFixture('direct', 'direct-1'), 'hasActiveHuddle': active},
        ],
      );
      final snapshot = ConversationListSnapshot.fromJson(fixture);
      expect(snapshot.items.single.hasActiveHuddle, active);
      expect(snapshot.items.single.conversation.toJson(),
          isNot(contains('hasActiveHuddle')));
      expect(snapshot.toJson(), fixture);
    }
    for (final invalid in <Object?>[null, 'true', 1, {}, []]) {
      expect(
        () => ConversationSnapshotSummary.fromJson({
          ..._summaryFixture('direct', 'direct-1'),
          'hasActiveHuddle': invalid,
        }),
        throwsFormatException,
      );
    }
    expect(
        ConversationSnapshotSummary.fromJson(
          _summaryFixture('direct', 'direct-1'),
        ).hasActiveHuddle,
        isNull);
  });

  test('organization and entity list pages round-trip with optional cursors',
      () {
    final organization = _listFixture(
      scope: const {'type': 'organization'},
      items: [_summaryFixture('channel', 'conversation-channel')],
    );
    final organizationSnapshot = ConversationListSnapshot.fromJson(
      _jsonRoundTrip(organization),
    );
    expect(
      organizationSnapshot.scope,
      isA<OrganizationConversationSnapshotScope>(),
    );
    expect(organizationSnapshot.page.nextCursor, isNull);
    expect(organizationSnapshot.items.single.activeMemberUserIds, const [
      UserId(_userId),
    ]);
    expect(organizationSnapshot.toJson(), organization);
    expect(
      () => organizationSnapshot.items.single.activeMemberUserIds.add(
        const UserId('user-other'),
      ),
      throwsUnsupportedError,
    );

    final cursor = _cursor('conversation-direct');
    final entity = _listFixture(
      scope: const {
        'type': 'entity',
        'entity': {'type': 'erp.invoice', 'id': 'opaque/invoice/42'},
      },
      items: [_summaryFixture('direct', 'conversation-direct')],
      nextCursor: cursor,
    );
    final entitySnapshot =
        parseConversationListSnapshot(_jsonRoundTrip(entity));
    expect(entitySnapshot.scope, isA<EntityConversationSnapshotScope>());
    expect(entitySnapshot.page.nextCursor?.toJson(), cursor);
    expect(entitySnapshot.toJson(), entity);
    expect(
      () => entitySnapshot.items.add(entitySnapshot.items.single),
      throwsUnsupportedError,
    );
  });

  test('v3 ranks and structurally distinct v2/v1 cursor fixtures round-trip',
      () {
    expect(
      const [
        conversationNavigationRankDirect,
        conversationNavigationRankPublicChannel,
        conversationNavigationRankPrivateChannel,
        conversationNavigationRankGroupDirect,
      ],
      const [0, 1, 2, 3],
    );

    for (final navigationRank in const [0, 1, 2, 3]) {
      final fixture = _cursor(
        'conversation-rank-$navigationRank',
        navigationRank: navigationRank,
        isStarred: navigationRank.isEven,
      );
      expect(ConversationSnapshotCursor.fromJson(fixture).toJson(), fixture);
    }

    final v2Fixture = _cursorFixture(2, [true, _now, 'conversation-v2']);
    final v1Fixture = _cursorFixture(1, [_now, 'conversation-v1']);
    expect(ConversationSnapshotCursor.fromJson(v2Fixture).toJson(), v2Fixture);
    expect(ConversationSnapshotCursor.fromJson(v1Fixture).toJson(), v1Fixture);
  });

  test('v3 cursor decoding rejects missing and malformed navigation ranks', () {
    final malformed = <String>[
      _cursorFixture(3, [false, _now, 'conversation-missing-rank']),
      for (final rank in <Object?>[null, 1.5, -1, 4, '1', true, {}, []])
        _cursorFixture(3, [false, rank, _now, 'conversation-bad-rank']),
    ];

    for (final fixture in malformed) {
      expect(
        () => ConversationSnapshotCursor.fromJson(fixture),
        throwsFormatException,
        reason: fixture,
      );
    }
  });

  test('detail snapshots cover channel, direct, group_direct, and thread', () {
    for (final type in const [
      'channel',
      'direct',
      'group_direct',
      'thread',
    ]) {
      final wire = _detailFixture(type, 'conversation-$type');
      final snapshot =
          ConversationDetailSnapshot.fromJson(_jsonRoundTrip(wire));
      expect(snapshot.conversation.summary.conversation.type.wireValue, type);
      expect(snapshot.conversation.memberUserIds, const [
        UserId(_userId),
        UserId('user-other'),
      ]);
      expect(snapshot.conversation.currentPreference.isStarred, isFalse);
      expect(snapshot.conversation.currentPreference.notificationPreference,
          'mentions');
      expect(snapshot.toJson(), wire);
      expect(
        () =>
            snapshot.conversation.memberUserIds.add(const UserId('user-third')),
        throwsUnsupportedError,
      );
    }
  });

  test('input parsers accept only untrusted organization/entity query data',
      () {
    final organization = parseConversationListSnapshotInput({
      'scope': {'type': 'organization'},
      'limit': 25,
    });
    expect(organization.limit, 25);
    expect(organization.cursor, isNull);

    final cursor = _cursor('conversation-1');
    final entity = ConversationListSnapshotInput.fromJson({
      'scope': {
        'type': 'entity',
        'entity': {'type': 'order', 'id': 'order-42'},
      },
      'cursor': cursor,
    });
    expect(entity.cursor?.toJson(), cursor);
    final legacyCursor =
        'handrail-conversations.v1.${Uri.encodeComponent(jsonEncode([
          _now,
          'conversation-legacy'
        ]))}';
    expect(
      ConversationListSnapshotInput.fromJson({
        'scope': {'type': 'organization'},
        'cursor': legacyCursor,
      }).cursor?.toJson(),
      legacyCursor,
    );
    expect(
      parseConversationDetailSnapshotInput({
        'conversationId': 'conversation-1',
      }).conversationId,
      const ConversationId('conversation-1'),
    );
  });

  test('input parsers reject trusted identity and authorization fields', () {
    const trustedFields = [
      'tenant',
      'tenantId',
      'organizationId',
      'actor',
      'actorId',
      'actorContext',
      'user',
      'userId',
      'currentUserId',
      'principal',
      'principalId',
      'subject',
      'subjectId',
      'authenticatedUser',
      'authenticatedUserId',
      'identity',
      'session',
      'auth',
      'role',
      'roles',
    ];

    for (final field in trustedFields) {
      expect(
        () => ConversationDetailSnapshotInput.fromJson({
          'conversationId': 'conversation-1',
          field: 'spoofed',
        }),
        throwsFormatException,
        reason: field,
      );
      expect(
        () => ConversationListSnapshotInput.fromJson({
          'scope': {
            'type': 'entity',
            'entity': {
              'type': 'order',
              'id': 'order-42',
              field: 'spoofed',
            },
          },
        }),
        throwsFormatException,
        reason: 'nested $field',
      );
    }
  });

  test('rejects malformed list, cursor, state, and metadata payloads', () {
    final list = _listFixture(
      scope: const {'type': 'organization'},
      items: [_summaryFixture('channel', 'conversation-channel')],
    );
    final malformed = <Object?>[
      {...list, 'kind': 'conversation_detail'},
      {...list, 'items': 'not-an-array'},
      {
        ...list,
        'page': {'nextCursor': 'not-a-cursor'}
      },
      {
        ...list,
        'page': {
          'nextCursor':
              'handrail-conversations.v2.${Uri.encodeComponent(jsonEncode([
                _now,
                'conversation-1'
              ]))}',
        },
      },
      {
        ...list,
        'page': {
          'nextCursor':
              'handrail-conversations.v3.${Uri.encodeComponent(jsonEncode([
                false,
                _now,
                'conversation-1'
              ]))}',
        },
      },
      {
        ...list,
        'page': {
          'nextCursor':
              'handrail-conversations.v4.${Uri.encodeComponent(jsonEncode([
                false,
                0,
                _now,
                'conversation-1'
              ]))}',
        },
      },
      {
        ...list,
        '_meta': {
          ..._metadata(),
          'feature': {
            'name': conversationSnapshotFeature,
            'version': conversationSnapshotVersion + 1,
          },
        },
      },
      {
        ...list,
        'items': [
          {
            ..._summaryFixture('direct', 'conversation-direct'),
            'visibility': 'public',
          },
        ],
      },
      {
        ...list,
        'items': [
          {
            ..._summaryFixture('channel', 'conversation-channel'),
            'activeMemberUserIds': [_userId, _userId],
          },
        ],
      },
      {
        ...list,
        'items': [
          {
            ..._summaryFixture('channel', 'conversation-channel'),
            'activeMemberUserIds': List.generate(
              maxConversationListActiveMemberUserIds + 1,
              (index) => 'user-$index',
            ),
          },
        ],
      },
      {
        ...list,
        'items': [
          {
            ..._summaryFixture('channel', 'conversation-channel'),
            'currentReadState': {
              ..._readState('conversation-channel'),
              'userId': 'user-spoofed',
            },
          },
        ],
      },
    ];

    for (final wire in malformed) {
      expect(
        () => ConversationListSnapshot.fromJson(_jsonRoundTrip(wire)),
        throwsFormatException,
      );
    }
  });

  test('rejects malformed detail membership and current preference', () {
    final detail = _detailFixture('channel', 'conversation-channel');
    final conversation = detail['conversation']! as Map<String, Object?>;
    expect(
      () => ConversationDetailSnapshot.fromJson({
        ...detail,
        'conversation': {
          ...conversation,
          'memberUserIds': [_userId, _userId],
        },
      }),
      throwsFormatException,
    );
    expect(
      () => ConversationDetailSnapshot.fromJson({
        ...detail,
        'conversation': {
          ...conversation,
          'currentPreference': {
            ...conversation['currentPreference']! as Map<String, Object?>,
            'userId': 'user-spoofed',
          },
        },
      }),
      throwsFormatException,
    );
    for (final isStarred in <Object?>[
      null,
      'true',
      1,
      <String, Object?>{},
      <Object?>[]
    ]) {
      expect(
        () => ConversationDetailSnapshot.fromJson({
          ...detail,
          'conversation': {
            ...conversation,
            'currentPreference': {
              ...conversation['currentPreference']! as Map<String, Object?>,
              'isStarred': isStarred,
            },
          },
        }),
        throwsFormatException,
      );
    }
  });

  test('starred preference state round-trips both boolean values', () {
    for (final isStarred in const [false, true]) {
      final detail = _detailFixture('channel', 'conversation-channel');
      final conversation = detail['conversation']! as Map<String, Object?>;
      final wire = {
        ...detail,
        'conversation': {
          ...conversation,
          'currentPreference': {
            ...conversation['currentPreference']! as Map<String, Object?>,
            'isStarred': isStarred,
          },
        },
      };
      final snapshot =
          ConversationDetailSnapshot.fromJson(_jsonRoundTrip(wire));
      expect(snapshot.conversation.currentPreference.isStarred, isStarred);
      expect(snapshot.toJson(), wire);
    }
  });
}

Map<String, Object?> _listFixture({
  required Map<String, Object?> scope,
  required List<Map<String, Object?>> items,
  String? nextCursor,
}) =>
    {
      'kind': 'conversation_list',
      'scope': scope,
      'items': items,
      'page': {
        if (nextCursor != null) 'nextCursor': nextCursor,
      },
      '_meta': _metadata(),
    };

Map<String, Object?> _detailFixture(String type, String id) {
  final summary = _summaryFixture(type, id);
  return {
    'kind': 'conversation_detail',
    'conversation': {
      ...summary,
      'memberUserIds': [_userId, 'user-other'],
      'currentPreference': {
        'conversationId': id,
        'userId': _userId,
        'isStarred': false,
        'notificationPreference': 'mentions',
        'mute': {'muted': false},
        'updatedAt': _now,
      },
    },
    '_meta': _metadata(),
  };
}

Map<String, Object?> _summaryFixture(String type, String id) => {
      ..._conversationFixture(type, id),
      'latestSequence': 12,
      'activityAt': _now,
      'unreadMentionCount': 1,
      'currentMember': _member(id),
      'currentReadState': _readState(id),
      'currentPreference': {
        'conversationId': id,
        'userId': _userId,
        'isStarred': false,
        'notificationPreference': 'mentions',
        'mute': {'muted': false},
        'updatedAt': _now,
      },
      'activeMemberUserIds': [_userId],
    };

Map<String, Object?> _conversationFixture(String type, String id) {
  final base = <String, Object?>{
    'id': id,
    'tenantId': _tenantId,
    'type': type,
    'createdAt': _now,
    'updatedAt': _now,
  };
  return switch (type) {
    'channel' => {
        ...base,
        'name': 'Orders',
        'visibility': 'public',
        'entity': {'type': 'order', 'id': 'order-42'},
      },
    'direct' || 'group_direct' => {...base, 'visibility': 'private'},
    'thread' => {
        ...base,
        'visibility': 'public',
        'parentConversationId': 'conversation-parent',
        'rootMessageId': 'message-root',
      },
    _ => throw ArgumentError.value(type),
  };
}

Map<String, Object?> _member(String conversationId) => {
      'tenantId': _tenantId,
      'conversationId': conversationId,
      'userId': _userId,
      'role': 'member',
      'state': 'active',
      'joinedAt': _now,
      'updatedAt': _now,
    };

Map<String, Object?> _readState(String conversationId) => {
      'conversationId': conversationId,
      'userId': _userId,
      'lastReadSequence': 11,
      'updatedAt': _now,
    };

Map<String, Object?> _metadata() => {
      'packageVersion': '0.1.3',
      'protocolVersion': 4,
      'schemaVersion': 9,
      'enabledFeatures': {'threads': true, conversationSnapshotFeature: true},
      'supportedProtocolRange': {
        'minimumVersion': 1,
        'maximumVersion': 4,
      },
      'feature': {
        'name': conversationSnapshotFeature,
        'version': conversationSnapshotVersion,
      },
    };

String _cursor(
  String conversationId, {
  int navigationRank = conversationNavigationRankDirect,
  bool isStarred = false,
}) =>
    _cursorFixture(conversationSnapshotCursorVersion, [
      isStarred,
      navigationRank,
      _now,
      conversationId,
    ]);

String _cursorFixture(int version, List<Object?> position) =>
    'handrail-conversations.v$version.${Uri.encodeComponent(jsonEncode(position))}';

Object? _jsonRoundTrip(Object? value) => jsonDecode(jsonEncode(value));
