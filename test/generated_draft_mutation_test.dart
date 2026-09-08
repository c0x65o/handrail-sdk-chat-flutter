import 'dart:convert';

import 'package:handrail_chat/core.dart';
import 'package:test/test.dart';

import 'fixtures/draft_mutation_fixtures.dart';

void main() {
  test(
      'reply construction and replacement/replay/conflict events retain explicit ping',
      () {
    for (final notifyAuthor in [false, true]) {
      final content = DraftContent(
        format: DraftTextFormat.plain,
        text: 'Friday',
        attachments: [],
        replyTo: MessageReplyReference(
            messageId: MessageId('${'é' * 127}x'), notifyAuthor: notifyAuthor),
      );
      expect(DraftContent.fromJson(_roundTrip(content.toJson())).toJson(),
          content.toJson());
      expect(content.toJson().containsKey('mentions'), isFalse);
      final wire = {...replaceDraftInputFixture, 'content': content.toJson()};
      final input = SynchronizeDraftInput.fromJson(wire);
      expect(input.toJson(), wire);
      for (final status in ['applied', 'replayed']) {
        final result =
            settledDraftResultFixture(wire, reconciliationStatus: status);
        expect(
            SynchronizeDraftResult.fromJson(_roundTrip(result),
                    expectedInput: input)
                .toJson(),
            result);
        _expectDraftEvent(wire, result);
      }
      final otherContent = {
        ...content.toJson(),
        'replyTo': {'messageId': 'other', 'notifyAuthor': !notifyAuthor}
      };
      final conflict = {
        ...staleDraftResultFixture(wire),
        'draft': {'kind': 'replaced', 'content': otherContent}
      };
      expect(
          SynchronizeDraftResult.fromJson(_roundTrip(conflict),
                  expectedInput: input)
              .toJson(),
          conflict);
      _expectDraftEvent(wire, conflict);
      _expectDraftEvent(clearDraftInputFixture, {
        ...staleDraftResultFixture(clearDraftInputFixture),
        'draft': conflict['draft'],
      });
      _expectDraftEvent(wire, {
        ...staleDraftResultFixture(wire),
        'draft': {'kind': 'clear_tombstone', 'content': null}
      });
    }
  });

  test('settled reply equality includes presence, target and ping', () {
    final legacy =
        Map<String, Object?>.from(replaceDraftInputFixture['content']! as Map);
    final content = {
      ...legacy,
      'replyTo': {'messageId': 'source', 'notifyAuthor': false}
    };
    final wire = {...replaceDraftInputFixture, 'content': content};
    final input = SynchronizeDraftInput.fromJson(wire);
    for (final status in ['applied', 'replayed']) {
      for (final changed in [
        legacy,
        {
          ...content,
          'replyTo': {'messageId': 'other', 'notifyAuthor': false}
        },
        {
          ...content,
          'replyTo': {'messageId': 'source', 'notifyAuthor': true}
        },
      ]) {
        final result = {
          ...settledDraftResultFixture(wire, reconciliationStatus: status),
          'draft': {'kind': 'replaced', 'content': changed}
        };
        expect(
            () => SynchronizeDraftResult.fromJson(result, expectedInput: input),
            _draftError(DraftMutationParseErrorCode.incoherentResult));
        _expectInvalidDraftEvent(wire, result);
      }
      expect(
          () => SynchronizeDraftResult.fromJson(
              settledDraftResultFixture(wire, reconciliationStatus: status),
              expectedInput:
                  SynchronizeDraftInput.fromJson(replaceDraftInputFixture)),
          _draftError(DraftMutationParseErrorCode.incoherentResult));
    }
  });

  test(
      'reply shapes and identifiers use draft error semantics in inputs/results/events',
      () {
    final legacy =
        Map<String, Object?>.from(replaceDraftInputFixture['content']! as Map);
    final cases = <(Object?, DraftMutationParseErrorCode)>[
      for (final reference in [
        null,
        [],
        'source',
        {},
        {'messageId': 'source'},
        {'notifyAuthor': false},
        for (final ping in [null, 0, 'false'])
          {'messageId': 'source', 'notifyAuthor': ping},
        for (final key in [
          'sourceMessageId',
          'originalAuthor',
          'originalCreatedAt',
          'displayName',
          'sourceDisplay',
          'source',
          'content',
          'extra'
        ])
          {'messageId': 'source', 'notifyAuthor': false, key: 'forbidden'},
      ])
        (reference, DraftMutationParseErrorCode.malformedContent),
      for (final id in [
        '',
        ' source',
        'source ',
        'e\u0301',
        'a\nb',
        'a\tb',
        'a\u0000b',
        'a\u007fb',
        'a\u2028b',
        'a\u2029b',
        '\ud800',
        '\udc00',
        'x' * 256,
        'é' * 128,
        1,
        null
      ])
        (
          {'messageId': id, 'notifyAuthor': false},
          DraftMutationParseErrorCode.malformedIdentifier
        ),
    ];
    for (final (reference, code) in cases) {
      final content = {...legacy, 'replyTo': reference};
      final wire = {...replaceDraftInputFixture, 'content': content};
      expect(() => SynchronizeDraftInput.fromJson(wire), _draftError(code));
      final result = {
        ...settledDraftResultFixture(replaceDraftInputFixture),
        'draft': {'kind': 'replaced', 'content': content}
      };
      expect(
          () => SynchronizeDraftResult.fromJson(result,
              expectedInput:
                  SynchronizeDraftInput.fromJson(replaceDraftInputFixture)),
          _draftError(code == DraftMutationParseErrorCode.malformedContent
              ? DraftMutationParseErrorCode.malformedResult
              : code));
      _expectInvalidDraftEvent(wire, settledDraftResultFixture(wire));
      _expectInvalidDraftEvent(replaceDraftInputFixture, result);
      _expectInvalidDraftEvent(replaceDraftInputFixture,
          {...result, 'reconciliationStatus': 'stale_base'});
    }
    expect(
        () => DraftContent(
            format: DraftTextFormat.plain,
            text: '',
            attachments: [],
            replyTo: MessageReplyReference(
                messageId: const MessageId('e\u0301'), notifyAuthor: false)),
        _draftError(DraftMutationParseErrorCode.malformedIdentifier));
  });

  test('replace and clear inputs round-trip with immutable typed content', () {
    final replace = SynchronizeDraftInput.fromJson(
      _roundTrip(replaceDraftInputFixture),
    );
    final clear = SynchronizeDraftInput.fromJson(
      _roundTrip(clearDraftInputFixture),
    );
    expect(replace, isA<ReplaceDraftInput>());
    expect(clear, isA<ClearDraftInput>());
    expect(replace.toJson(), replaceDraftInputFixture);
    expect(clear.toJson(), clearDraftInputFixture);
    final replaceContent = (replace as ReplaceDraftInput).content;
    expect(replaceContent.mentions, hasLength(3));
    expect(replaceContent.mentions![0], isA<UserMention>());
    expect(replaceContent.mentions![1], isA<ConversationMention>());
    expect(replaceContent.mentions![2], isA<EntityMention>());
    expect(
      () => replaceContent.mentions!.add(
        const UserMention(userId: UserId('user-other')),
      ),
      throwsUnsupportedError,
    );
    expect(
      () => replaceContent.attachments.add(
        DraftAttachmentReference(
          attachmentId: const AttachmentId('attachment-3'),
        ),
      ),
      throwsUnsupportedError,
    );
  });

  test('legacy content without mentions remains valid and omits the key', () {
    final content = Map<String, Object?>.from(
      replaceDraftInputFixture['content']! as Map<String, Object?>,
    )..remove('mentions');
    final fixture = <String, Object?>{
      ...replaceDraftInputFixture,
      'content': content,
    };
    final parsed = SynchronizeDraftInput.fromJson(_roundTrip(fixture));
    expect(parsed.toJson(), fixture);
    expect(
      ((parsed as ReplaceDraftInput).content.toJson()).containsKey('mentions'),
      isFalse,
    );
  });

  test('applied, replayed, and stale-base results round-trip', () {
    final replace = SynchronizeDraftInput.fromJson(replaceDraftInputFixture);
    final clear = SynchronizeDraftInput.fromJson(clearDraftInputFixture);
    final applied = SynchronizeDraftResult.fromJson(
      settledDraftResultFixture(replaceDraftInputFixture),
      expectedInput: replace,
    );
    final replayed = SynchronizeDraftResult.fromJson(
      settledDraftResultFixture(
        clearDraftInputFixture,
        reconciliationStatus: 'replayed',
      ),
      expectedInput: clear,
    );
    final stale = SynchronizeDraftResult.fromJson(
      staleDraftResultFixture(clearDraftInputFixture),
      expectedInput: clear,
    );

    expect(applied.reconciliationStatus,
        DraftMutationReconciliationStatus.applied);
    expect(replayed.reconciliationStatus,
        DraftMutationReconciliationStatus.replayed);
    expect(stale.reconciliationStatus,
        DraftMutationReconciliationStatus.staleBase);
    expect(applied.draft, isA<CanonicalReplacedDraft>());
    expect(replayed.draft, isA<CanonicalClearDraftTombstone>());
    expect(stale.toJson(), staleDraftResultFixture(clearDraftInputFixture));

    final changedResult = settledDraftResultFixture(replaceDraftInputFixture);
    final changedDraft = Map<String, Object?>.from(
      changedResult['draft']! as Map<String, Object?>,
    );
    final changedContent = Map<String, Object?>.from(
      changedDraft['content']! as Map<String, Object?>,
    )..['mentions'] = <Object?>[];
    changedResult['draft'] = {...changedDraft, 'content': changedContent};
    expect(
      () => SynchronizeDraftResult.fromJson(
        changedResult,
        expectedInput: replace,
      ),
      throwsA(
        isA<DraftMutationFormatException>().having(
          (error) => error.code,
          'code',
          DraftMutationParseErrorCode.incoherentResult,
        ),
      ),
    );
  });

  test('private conversation.draft.updated envelopes round-trip', () {
    final result = settledDraftResultFixture(replaceDraftInputFixture);
    final fixture = draftUpdatedEventFixture(replaceDraftInputFixture, result);
    final event = ConversationDraftUpdatedEvent.fromJson(
      _roundTrip(fixture),
      expectedTenantId: const TenantId('tenant-1'),
    );
    expect(event.type, draftUpdatedEventType);
    expect(event.streamId, 'user:user-1');
    expect(event.payload.input, isA<ReplaceDraftInput>());
    expect(event.toJson(), fixture);
  });

  test('rejects unsafe formats, bounds, duplicate attachments, and extras', () {
    final content = Map<String, Object?>.from(
      replaceDraftInputFixture['content']! as Map<String, Object?>,
    );
    final invalidInputs = <Map<String, Object?>>[
      {
        ...replaceDraftInputFixture,
        'content': {...content, 'format': 'html'},
      },
      {
        ...replaceDraftInputFixture,
        'content': {...content, 'text': 'unsafe\u0000text'},
      },
      {
        ...replaceDraftInputFixture,
        'content': {
          ...content,
          'attachments': const <Object?>[
            <String, Object?>{'attachmentId': 'attachment-1'},
            <String, Object?>{'attachmentId': 'attachment-1'},
          ],
        },
      },
      {
        ...replaceDraftInputFixture,
        'content': {...content, 'text': 'x' * (maxDraftTextUtf8Bytes + 1)},
      },
      {
        ...replaceDraftInputFixture,
        'conversationId': 'x' * (maxDraftIdentifierUtf8Bytes + 1),
      },
      {...replaceDraftInputFixture, 'deviceMutationId': 'e\u0301'},
      {
        ...replaceDraftInputFixture,
        'idempotencyKey': 'x' * (maxDraftIdempotencyKeyUtf8Bytes + 1),
      },
      {
        ...replaceDraftInputFixture,
        'content': {
          ...content,
          'attachments': List<Object?>.generate(
            maxDraftAttachmentReferences + 1,
            (index) => <String, Object?>{'attachmentId': 'attachment-$index'},
          ),
        },
      },
      {...replaceDraftInputFixture, 'baseRevision': -1},
      {
        ...replaceDraftInputFixture,
        'content': {...content, 'html': '<b>x</b>'}
      },
      {...clearDraftInputFixture, 'content': content},
    ];
    for (final input in invalidInputs) {
      expect(
        () => SynchronizeDraftInput.fromJson(input),
        throwsA(isA<DraftMutationFormatException>()),
      );
    }
  });

  test('rejects malformed, non-normalized, over-limit, and duplicate mentions',
      () {
    final content = Map<String, Object?>.from(
      replaceDraftInputFixture['content']! as Map<String, Object?>,
    );
    final cases = <(Object?, DraftMutationParseErrorCode)>[
      ('not-an-array', DraftMutationParseErrorCode.malformedContent),
      (
        const <Object?>[
          <String, Object?>{'type': 'user'}
        ],
        DraftMutationParseErrorCode.malformedContent,
      ),
      (
        const <Object?>[
          <String, Object?>{
            'type': 'user',
            'userId': 'user-1',
            'label': 'User One',
          },
        ],
        DraftMutationParseErrorCode.malformedContent,
      ),
      (
        const <Object?>[
          <String, Object?>{
            'type': 'conversation',
            'conversationId': 'e\u0301',
          },
        ],
        DraftMutationParseErrorCode.malformedIdentifier,
      ),
      (
        const <Object?>[
          <String, Object?>{
            'type': 'entity',
            'entity': <String, Object?>{
              'type': ' invoice',
              'id': 'invoice-1',
            },
          },
        ],
        DraftMutationParseErrorCode.malformedIdentifier,
      ),
      (
        List<Object?>.generate(
          maxDraftMentionReferences + 1,
          (index) => <String, Object?>{
            'type': 'user',
            'userId': 'user-$index',
          },
        ),
        DraftMutationParseErrorCode.malformedContent,
      ),
      (
        const <Object?>[
          <String, Object?>{'type': 'user', 'userId': 'user-duplicate'},
          <String, Object?>{'type': 'user', 'userId': 'user-duplicate'},
        ],
        DraftMutationParseErrorCode.duplicateMentionReference,
      ),
      (
        const <Object?>[
          <String, Object?>{
            'type': 'entity',
            'entity': <String, Object?>{
              'type': 'invoice',
              'id': 'invoice-1',
            },
          },
          <String, Object?>{
            'type': 'entity',
            'entity': <String, Object?>{
              'type': 'invoice',
              'id': 'invoice-1',
            },
          },
        ],
        DraftMutationParseErrorCode.duplicateMentionReference,
      ),
    ];
    for (final (mentions, code) in cases) {
      expect(
        () => SynchronizeDraftInput.fromJson({
          ...replaceDraftInputFixture,
          'content': {...content, 'mentions': mentions},
        }),
        throwsA(
          isA<DraftMutationFormatException>().having(
            (error) => error.code,
            'code',
            code,
          ),
        ),
      );
    }
  });

  test('rejects normalized trusted identity aliases at any input depth', () {
    for (final field in <String>[
      'tenant-id',
      'Actor_User_ID',
      'current user',
      'session-id',
      'authorization',
      'roles',
      'capabilities',
      'permissions',
    ]) {
      expect(
        () => SynchronizeDraftInput.fromJson({
          ...replaceDraftInputFixture,
          field: field == 'roles' ? <String>['admin'] : 'spoofed',
        }),
        throwsA(
          isA<DraftMutationFormatException>().having(
            (error) => error.code,
            'code',
            DraftMutationParseErrorCode.trustedIdentityField,
          ),
        ),
      );
    }
    final content = Map<String, Object?>.from(
      replaceDraftInputFixture['content']! as Map<String, Object?>,
    );
    expect(
      () => SynchronizeDraftInput.fromJson({
        ...replaceDraftInputFixture,
        'content': {...content, 'actorUserId': 'spoofed'},
      }),
      throwsA(isA<DraftMutationFormatException>()),
    );
  });

  test('rejects malformed private streams and incoherent event results', () {
    final result = settledDraftResultFixture(replaceDraftInputFixture);
    final event = draftUpdatedEventFixture(replaceDraftInputFixture, result);
    final invalidEvents = <Map<String, Object?>>[
      {...event, 'streamId': 'conversation:conversation-1'},
      {...event, 'tenantId': 'tenant-other'},
      {...event, 'type': 'message.updated'},
      {...event, 'sessionId': 'session-spoof'},
      {
        ...event,
        'payload': {
          ...(event['payload']! as Map<String, Object?>),
          'actorUserId': 'user-other',
        },
      },
      {
        ...event,
        'payload': {
          ...(event['payload']! as Map<String, Object?>),
          'result': {...result, 'idempotencyKey': 'different'},
        },
      },
    ];
    for (final invalid in invalidEvents) {
      expect(
        () => ConversationDraftUpdatedEvent.fromJson(
          invalid,
          expectedTenantId: const TenantId('tenant-1'),
        ),
        throwsA(isA<DraftMutationFormatException>()),
      );
    }
  });
}

Object? _roundTrip(Object? value) => jsonDecode(jsonEncode(value));

Matcher _draftError(DraftMutationParseErrorCode code) =>
    throwsA(isA<DraftMutationFormatException>()
        .having((error) => error.code, 'code', code));

void _expectDraftEvent(
    Map<String, Object?> input, Map<String, Object?> result) {
  final wire = draftUpdatedEventFixture(input, result);
  expect(
      ConversationDraftUpdatedEvent.fromJson(_roundTrip(wire),
              expectedTenantId: const TenantId('tenant-1'))
          .toJson(),
      wire);
  expect(
      KnownDurableEvent.fromJson(_roundTrip(wire),
              trustedIdentity: const DurableEventTrustedIdentity(
                  tenantId: TenantId('tenant-1'), userId: UserId('user-1')))
          .toJson(),
      wire);
}

void _expectInvalidDraftEvent(
    Map<String, Object?> input, Map<String, Object?> result) {
  final wire = draftUpdatedEventFixture(input, result);
  expect(
      () => ConversationDraftUpdatedEvent.fromJson(wire,
          expectedTenantId: const TenantId('tenant-1')),
      throwsA(isA<DraftMutationFormatException>()));
  expect(
      () => KnownDurableEvent.fromJson(wire,
          trustedIdentity: const DurableEventTrustedIdentity(
              tenantId: TenantId('tenant-1'), userId: UserId('user-1'))),
      throwsA(isA<DurableEventFormatException>().having((error) => error.code,
          'code', DurableEventParseErrorCode.incoherentPayload)));
}
