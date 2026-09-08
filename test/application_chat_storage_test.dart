import 'dart:convert';

import 'package:handrail_chat/core.dart';
import 'package:handrail_chat/src/testing/in_memory_application_chat_storage.dart';
import 'package:test/test.dart';

void main() {
  group('snapshot version compatibility', () {
    test(
      'literal version 1 preserves numeric facts and upgrades to version 2',
      () {
        final decoded =
            ApplicationChatStorageRecord.decode(_legacySnapshotJson)
                as ApplicationChatNormalizedSnapshotRecord;
        expect(decoded.identity.tenantId, const TenantId('tenant-1'));
        expect(decoded.identity.userId, const UserId('user-1'));
        expect(decoded.identity.deviceId, const DeviceId('device-1'));
        const conversationId = ConversationId('conversation-1');
        expect(
          decoded.snapshot.conversations[conversationId]?.tenantId,
          const TenantId('tenant-1'),
        );
        expect(
          decoded.snapshot.conversationMetadata[conversationId]?.latestSequence,
          const MessageSequence(12),
        );
        expect(
          decoded
              .snapshot
              .currentUserReadStates[conversationId]
              ?.lastReadSequence,
          const MessageSequence(7),
        );
        expect(
          decoded.snapshot.currentUserReadStates[conversationId]?.userId,
          const UserId('user-1'),
        );
        expect(decoded.snapshot.lifecycleRevisions[conversationId], 3);
        expect(decoded.snapshot.memberListRevisions[conversationId], 4);
        expect(decoded.snapshot.latestReplayCursor?.eventId, 'legacy-event-12');

        final upgraded = jsonDecode(decoded.encode()) as Map<String, Object?>;
        expect(upgraded['schemaVersion'], 2);
        final legacy = jsonDecode(_legacySnapshotJson) as Map<String, Object?>;
        expect(upgraded['identity'], legacy['identity']);
        expect(upgraded['payload'], legacy['payload']);
        expect(
          ApplicationChatStorageRecord.decode(decoded.encode()).toJson(),
          upgraded,
        );
      },
    );

    test('version 2 snapshot round-trips through JSON and storage', () async {
      final storage = InMemoryApplicationChatStorage();
      final record = _snapshotRecord(_identity());
      final encoded = record.encode();
      expect((jsonDecode(encoded) as Map<String, Object?>)['schemaVersion'], 2);
      expect(
        ApplicationChatStorageRecord.decode(encoded).toJson(),
        record.toJson(),
      );
      await storage.replace(record);
      expect(await storage.readEncoded(record.identity, record.kind), encoded);
      final restored = await storage.read(record.identity, record.kind);
      expect(restored!.identity, record.identity);
      expect(restored.toJson(), record.toJson());
    });
  });

  group('unsupported snapshot versions', () {
    for (final version in [-1, 0, 3, 999]) {
      test(
        'version $version rejects and exact removal preserves other records',
        () async {
          final storage = InMemoryApplicationChatStorage();
          final identity = _identity();
          const kind = ApplicationChatStorageRecordKind.normalizedSnapshot;
          final retained = <ApplicationChatStorageRecord>[
            ApplicationChatRealtimeCursorRecord(
              identity: identity,
              cursor: const EventCursor(eventId: 'retained-cursor'),
            ),
            _snapshotRecord(_identity(tenant: 'other-tenant')),
            _snapshotRecord(_identity(user: 'other-user')),
            _snapshotRecord(_identity(device: 'other-device')),
          ];
          for (final record in retained) {
            await storage.replace(record);
          }
          final unsupported = _deepJsonCopy(
            jsonDecode(_legacySnapshotJson) as Map<String, Object?>,
          )..['schemaVersion'] = version;
          expect(
            () => ApplicationChatStorageRecord.decode(jsonEncode(unsupported)),
            throwsFormatException,
          );
          storage.putRawRecordForTesting(identity, kind, unsupported);
          await expectLater(
            storage.read(identity, kind),
            throwsFormatException,
          );
          expect(storage.rawRecordForTesting(identity, kind), unsupported);
          await storage.remove(identity, kind);
          expect(await storage.read(identity, kind), isNull);
          expect(await storage.readEncoded(identity, kind), isNull);
          for (final record in retained) {
            expect(
              await storage.readEncoded(record.identity, record.kind),
              record.encode(),
            );
            expect(
              (await storage.read(record.identity, record.kind))!.toJson(),
              record.toJson(),
            );
          }
        },
      );
    }
  });

  group('snapshot retained-intent isolation', () {
    test(
      'snapshot migration, replacement, rejection and quarantine retain FIFO intents',
      () async {
        final storage = InMemoryApplicationChatStorage();
        final identity = _identity();
        const snapshotKind =
            ApplicationChatStorageRecordKind.normalizedSnapshot;
        final records = <ApplicationChatStorageRecord>[
          ApplicationChatQueuedSendMessageIntentsRecord(
            identity: identity,
            intents: [
              for (final order in [1, 2])
                ApplicationChatQueuedSendMessageIntent.fromJson(
                  _queuedSendIntent(order).toJson()
                    ..['enqueuedAt'] = '2026-08-26T16:0$order:00.000Z',
                ),
            ],
          ),
          ApplicationChatQueuedReadCursorIntentsRecord(
            identity: identity,
            intents: [
              for (final order in [1, 2])
                ApplicationChatQueuedReadCursorIntent.fromJson(
                  _readIntent(
                    order,
                    throughSequence: order + 7,
                    conversation: 'conversation-$order',
                  ).toJson()
                    ..['enqueuedAt'] = '2026-08-26T16:0$order:00.000Z',
                ),
            ],
          ),
        ];
        final originalJson = {
          for (final record in records)
            record.kind: _deepJsonCopy(record.toJson()),
        };
        final originalEncoded = {
          for (final record in records) record.kind: record.encode(),
        };
        for (final record in records) {
          await storage.replace(record);
        }

        Future<void> expectRetainedIntents(String phase) async {
          for (final record in records) {
            expect(
              await storage.readEncoded(identity, record.kind),
              originalEncoded[record.kind],
              reason: phase,
            );
            expect(
              storage.rawRecordForTesting(identity, record.kind),
              originalJson[record.kind],
              reason: phase,
            );
            final restored = (await storage.read(identity, record.kind))!;
            final json = restored.toJson();
            expect(json, originalJson[record.kind], reason: phase);
            expect(json['schemaVersion'], 1, reason: phase);
            expect(restored.identity, identity, reason: phase);
            final intents =
                ((json['payload'] as Map<String, Object?>)['intents']
                        as List<Object?>)
                    .cast<Map<String, Object?>>();
            expect(intents.map((intent) => intent['enqueueOrder']), [
              1,
              2,
            ], reason: phase);
            expect(intents.map((intent) => intent['enqueuedAt']), [
              '2026-08-26T16:01:00.000Z',
              '2026-08-26T16:02:00.000Z',
            ], reason: phase);
            final isSend =
                record.kind ==
                ApplicationChatStorageRecordKind.queuedSendMessageIntents;
            expect(
              intents.map((intent) => intent['idempotencyKey']),
              isSend
                  ? ['send-key-1', 'send-key-2']
                  : ['read-key-1', 'read-key-2'],
              reason: phase,
            );
            if (isSend) {
              expect(intents.map((intent) => intent['clientMessageId']), [
                'client-message-1',
                'client-message-2',
              ], reason: phase);
            }
          }
        }

        final legacy = jsonDecode(_legacySnapshotJson) as Map<String, Object?>;
        storage.putRawRecordForTesting(identity, snapshotKind, legacy);
        await expectRetainedIntents('legacy snapshot persisted');
        final migrated = (await storage.read(identity, snapshotKind))!;
        expect(migrated.toJson()['schemaVersion'], 2);
        expect(storage.rawRecordForTesting(identity, snapshotKind), legacy);
        await expectRetainedIntents('legacy snapshot read');

        await storage.replace(migrated);
        expect(
          (storage.rawRecordForTesting(identity, snapshotKind)
              as Map<String, Object?>)['schemaVersion'],
          2,
        );
        await expectRetainedIntents('migrated snapshot written');
        expect(
          (await storage.read(identity, snapshotKind))!.toJson(),
          migrated.toJson(),
        );
        await expectRetainedIntents('migrated snapshot read');

        final replacement = _snapshotRecord(identity);
        await storage.replace(replacement);
        await expectRetainedIntents('version 2 snapshot replaced');
        expect(
          (await storage.read(identity, snapshotKind))!.toJson(),
          replacement.toJson(),
        );
        await expectRetainedIntents('version 2 snapshot read');

        final unsupported = _deepJsonCopy(legacy)..['schemaVersion'] = 3;
        storage.putRawRecordForTesting(identity, snapshotKind, unsupported);
        await expectLater(
          storage.read(identity, snapshotKind),
          throwsFormatException,
        );
        await expectRetainedIntents('unsupported snapshot rejected');
        await storage.remove(identity, snapshotKind);
        expect(await storage.read(identity, snapshotKind), isNull);
        await expectRetainedIntents('snapshot quarantined by exact removal');
      },
    );

    for (final record in <ApplicationChatStorageRecord>[
      ApplicationChatQueuedSendMessageIntentsRecord(
        identity: _identity(),
        intents: [_queuedSendIntent(1), _queuedSendIntent(2)],
      ),
      ApplicationChatQueuedReadCursorIntentsRecord(
        identity: _identity(),
        intents: [
          _readIntent(1, throughSequence: 8),
          _readIntent(2, throughSequence: 9, conversation: 'conversation-2'),
        ],
      ),
    ]) {
      test('version 2 rejects for ${record.kind.wireValue}', () async {
        final storage = InMemoryApplicationChatStorage();
        final unsupported = _deepJsonCopy(record.toJson())
          ..['schemaVersion'] = 2;
        expect(
          () => ApplicationChatStorageRecord.decode(jsonEncode(unsupported)),
          throwsFormatException,
        );
        storage.putRawRecordForTesting(
          record.identity,
          record.kind,
          unsupported,
        );
        await expectLater(
          storage.read(record.identity, record.kind),
          throwsFormatException,
        );
      });
    }
  });

  group('ApplicationChatStorage records', () {
    test('all closed record kinds round-trip through JSON and storage',
        () async {
      final storage = InMemoryApplicationChatStorage();
      final identity = _identity();
      final records = <ApplicationChatStorageRecord>[
        ApplicationChatRealtimeCursorRecord(
          identity: identity,
          cursor: const EventCursor(eventId: 'event-12'),
        ),
        _snapshotRecord(identity),
        ApplicationChatQueuedCommandMetadataRecord(
          identity: identity,
          commands: [
            ApplicationChatQueuedCommandMetadata(
              commandId: 'queued-1',
              commandKind: ApplicationChatQueuedCommandKind.sendMessage,
              enqueuedAt: const IsoTimestamp('2026-08-26T16:00:00.000Z'),
              attemptCount: 2,
            ),
          ],
        ),
        ApplicationChatQueuedSendMessageIntentsRecord(
          identity: identity,
          intents: [
            ApplicationChatQueuedSendMessageIntent(
              request: SendMessageRequest.fromJson({
                'operation': 'send',
                'conversationId': 'conversation-1',
                'content': {'format': 'markdown', 'text': 'Queued'},
                'clientMessageId': 'client-message-1',
                'idempotencyKey': 'send-key-1',
              }),
              enqueueOrder: 1,
              enqueuedAt: const IsoTimestamp('2026-08-26T16:01:00.000Z'),
            ),
          ],
        ),
        ApplicationChatQueuedReadCursorIntentsRecord(
          identity: identity,
          intents: [_readIntent(1, throughSequence: 2)],
        ),
        ApplicationChatQueuedMessageMutationIntentsRecord(
          identity: identity,
          intents: [_mutationIntent(1, 'forward_message.v1')],
        ),
        ApplicationChatQueuedConversationMembershipIntentsRecord(
          identity: identity,
          intents: [_membershipIntent(1, 'join')],
        ),
        ApplicationChatQueuedConversationCreationIntentsRecord(
          identity: identity,
          intents: [_creationIntent(1, 'channel')],
        ),
        ApplicationChatQueuedConversationPreferenceIntentsRecord(
          identity: identity,
          intents: [_preferenceIntent(1)],
        ),
        ApplicationChatQueuedThreadFollowIntentsRecord(
          identity: identity,
          intents: [_threadFollowIntent(1)],
        ),
        ApplicationChatQueuedMessageReminderIntentsRecord(
          identity: identity,
          intents: [_messageReminderIntent(1)],
        ),
        ApplicationChatQueuedConversationArchiveIntentsRecord(
          identity: identity,
          intents: [_conversationArchiveIntent(1)],
        ),
        ApplicationChatQueuedHuddleCommandIntentsRecord(
          identity: identity,
          intents: [
            ApplicationChatQueuedHuddleCommandIntent(
              request: const StartHuddleInput(
                conversationId: ConversationId('conversation-1'),
                idempotencyKey: 'huddle-key-1',
              ),
              conversationId: const ConversationId('conversation-1'),
              enqueueOrder: 1,
              enqueuedAt: const IsoTimestamp('2026-08-26T16:01:00.000Z'),
            ),
          ],
        ),
        ApplicationChatQueuedDraftIntentsRecord(
          identity: identity,
          intents: [_draftIntent(1)],
        ),
        ApplicationChatPushTokenRevisionsRecord(
          identity: identity,
          revisions: [
            ApplicationChatPushTokenRevision(
              platform: DevicePlatform.ios,
              pushService: DevicePushProvider.apns,
              environment: DevicePushProviderEnvironment.sandbox,
              status: DevicePushTokenStatus.active,
              revision: 1,
              updatedAt: const IsoTimestamp('2026-08-26T16:01:00.000Z'),
            ),
          ],
        ),
      ];
      expect(
        records.map((record) => record.kind).toSet(),
        ApplicationChatStorageRecordKind.values.toSet(),
      );

      for (final record in records) {
        final decoded = ApplicationChatStorageRecord.decode(record.encode());
        expect(decoded.kind, record.kind);
        expect(decoded.identity, identity);
        expect(decoded.toJson(), record.toJson());

        await storage.replace(record);
        final stored = await storage.read(identity, record.kind);
        expect(stored, isNotNull);
        expect(stored!.toJson(), record.toJson());
      }

      final restored = await storage.read(
        identity,
        ApplicationChatStorageRecordKind.normalizedSnapshot,
      ) as ApplicationChatNormalizedSnapshotRecord;
      expect(
          restored.snapshot.canonicalMessages.keys, [const MessageId('m-1')]);
      expect(
        restored.snapshot.timelines[const ConversationId('conversation-1')]
            ?.messageIds,
        [const MessageId('m-1')],
      );
    });

    test('tenant, user, and device scopes cannot observe or remove each other',
        () async {
      final storage = InMemoryApplicationChatStorage();
      final identities = [
        _identity(),
        _identity(tenant: 'tenant-2'),
        _identity(user: 'user-2'),
        _identity(device: 'device-2'),
      ];
      for (var index = 0; index < identities.length; index += 1) {
        await storage.replace(
          ApplicationChatRealtimeCursorRecord(
            identity: identities[index],
            cursor: EventCursor(eventId: 'event-$index'),
          ),
        );
      }

      for (var index = 0; index < identities.length; index += 1) {
        final record = await storage.read(
          identities[index],
          ApplicationChatStorageRecordKind.realtimeCursor,
        ) as ApplicationChatRealtimeCursorRecord;
        expect(record.cursor.eventId, 'event-$index');
      }

      await storage.remove(
        identities.first,
        ApplicationChatStorageRecordKind.realtimeCursor,
      );
      expect(
        await storage.read(
          identities.first,
          ApplicationChatStorageRecordKind.realtimeCursor,
        ),
        isNull,
      );
      for (final identity in identities.skip(1)) {
        expect(
          await storage.read(
            identity,
            ApplicationChatStorageRecordKind.realtimeCursor,
          ),
          isNotNull,
        );
      }
    });

    test('replace and remove expose only complete record states', () async {
      final storage = InMemoryApplicationChatStorage();
      final identity = _identity();
      await storage.replace(
        ApplicationChatRealtimeCursorRecord(
          identity: identity,
          cursor: const EventCursor(eventId: 'before'),
        ),
      );
      await storage.replace(
        ApplicationChatRealtimeCursorRecord(
          identity: identity,
          cursor: const EventCursor(eventId: 'after'),
        ),
      );

      final replaced = await storage.read(
        identity,
        ApplicationChatStorageRecordKind.realtimeCursor,
      ) as ApplicationChatRealtimeCursorRecord;
      expect(replaced.cursor.eventId, 'after');
      expect(jsonEncode(replaced.toJson()), isNot(contains('before')));

      await storage.remove(
        identity,
        ApplicationChatStorageRecordKind.realtimeCursor,
      );
      expect(
        await storage.read(
          identity,
          ApplicationChatStorageRecordKind.realtimeCursor,
        ),
        isNull,
      );
    });

    test('bounded mutation creates, updates, and removes atomically', () async {
      final storage = InMemoryApplicationChatStorage();
      final mutator = ApplicationChatStorageMutator(storage);
      final identity = _identity();
      const kind = ApplicationChatStorageRecordKind.queuedSendMessageIntents;

      final created =
          await mutator.mutate<ApplicationChatQueuedSendMessageIntentsRecord>(
        identity,
        kind,
        (current) {
          expect(current, isNull);
          return ApplicationChatQueuedSendMessageIntentsRecord(
            identity: identity,
            intents: [_queuedSendIntent(1)],
          );
        },
      );
      expect(created?.intents.map((intent) => intent.enqueueOrder), [1]);

      final updated =
          await mutator.mutate<ApplicationChatQueuedSendMessageIntentsRecord>(
        identity,
        kind,
        (current) => ApplicationChatQueuedSendMessageIntentsRecord(
          identity: identity,
          intents: [...current!.intents, _queuedSendIntent(2)],
        ),
      );
      expect(updated?.intents.map((intent) => intent.enqueueOrder), [1, 2]);

      expect(
        await mutator.mutate<ApplicationChatQueuedSendMessageIntentsRecord>(
          identity,
          kind,
          (_) => null,
        ),
        isNull,
      );
      expect(await storage.read(identity, kind), isNull);
    });

    test('two mutation facades append distinct intents without loss', () async {
      final storage = InMemoryApplicationChatStorage();
      final identity = _identity();
      const kind = ApplicationChatStorageRecordKind.queuedSendMessageIntents;
      await storage.replace(
        ApplicationChatQueuedSendMessageIntentsRecord(
          identity: identity,
          intents: [_queuedSendIntent(1)],
        ),
      );
      final facadeA = ApplicationChatStorageMutator(storage);
      final facadeB = ApplicationChatStorageMutator(storage);

      ApplicationChatStorageUpdater<
          ApplicationChatQueuedSendMessageIntentsRecord> append(
              ApplicationChatQueuedSendMessageIntent intent) =>
          (current) => ApplicationChatQueuedSendMessageIntentsRecord(
                identity: identity,
                intents: [...current!.intents, intent]..sort(
                    (left, right) =>
                        left.enqueueOrder.compareTo(right.enqueueOrder),
                  ),
              );

      await Future.wait([
        facadeA.mutate<ApplicationChatQueuedSendMessageIntentsRecord>(
          identity,
          kind,
          append(_queuedSendIntent(2)),
        ),
        facadeB.mutate<ApplicationChatQueuedSendMessageIntentsRecord>(
          identity,
          kind,
          append(_queuedSendIntent(3)),
        ),
      ]);

      final restored = await storage.read(identity, kind)
          as ApplicationChatQueuedSendMessageIntentsRecord;
      expect(
        restored.intents.map((intent) => intent.enqueueOrder),
        [1, 2, 3],
      );
    });

    test('conditional mutation removal preserves a concurrent replacement',
        () async {
      final identity = _identity();
      const kind = ApplicationChatStorageRecordKind.realtimeCursor;
      final original = ApplicationChatRealtimeCursorRecord(
        identity: identity,
        cursor: const EventCursor(eventId: 'original'),
      );
      final replacement = ApplicationChatRealtimeCursorRecord(
        identity: identity,
        cursor: const EventCursor(eventId: 'concurrent'),
      );
      final storage = _AtomicMutationStorage(
        encoded: original.encode(),
        replaceBeforeFirstCompare: replacement.encode(),
      );

      final result = await ApplicationChatStorageMutator(storage)
          .mutate<ApplicationChatRealtimeCursorRecord>(
        identity,
        kind,
        (current) => current?.cursor.eventId == 'original' ? null : current,
      );

      expect(result?.cursor.eventId, 'concurrent');
      expect(storage.compareExchangeCount, 2);
      expect(storage.removeCount, 0);
      expect(storage.encoded, replacement.encode());
    });

    test('corrupt quarantine cannot erase a concurrent valid replacement',
        () async {
      const secret = 'private-malformed-record-content';
      final identity = _identity();
      const kind = ApplicationChatStorageRecordKind.realtimeCursor;
      final replacement = ApplicationChatRealtimeCursorRecord(
        identity: identity,
        cursor: const EventCursor(eventId: 'valid-concurrent'),
      );
      final storage = _AtomicMutationStorage(
        encoded: '{"private":"$secret"',
        replaceBeforeFirstCompare: replacement.encode(),
      );

      Object? failure;
      try {
        await ApplicationChatStorageMutator(storage)
            .mutate<ApplicationChatRealtimeCursorRecord>(
          identity,
          kind,
          (current) => current,
        );
      } on Object catch (error) {
        failure = error;
      }

      expect(failure, isA<FormatException>());
      expect(
        (failure! as FormatException).message,
        'Application chat storage record failed validation.',
      );
      expect(
        (failure as FormatException).message.toString(),
        isNot(contains(secret)),
      );
      expect(storage.compareExchangeCount, 1);
      expect(storage.removeCount, 0);
      expect(storage.encoded, replacement.encode());
    });

    test('mutation validates every proposal before a write attempt', () async {
      final identity = _identity();
      const kind = ApplicationChatStorageRecordKind.realtimeCursor;
      final storage = _AtomicMutationStorage();
      final mutator = ApplicationChatStorageMutator(storage);
      final oversizedChunk = List.filled(1024, 'x').join();
      final oversizedEventId = List.filled(
        (maxApplicationChatStorageRecordBytes ~/ oversizedChunk.length) + 1,
        oversizedChunk,
      ).join();
      final invalidUpdaters =
          <ApplicationChatStorageUpdater<ApplicationChatStorageRecord>>[
        (_) => ApplicationChatRealtimeCursorRecord(
              identity: _identity(user: 'other-user'),
              cursor: const EventCursor(eventId: 'wrong-identity'),
            ),
        (_) => ApplicationChatQueuedCommandMetadataRecord(
              identity: identity,
              commands: const [],
            ),
        (_) => ApplicationChatRealtimeCursorRecord(
              identity: identity,
              cursor: const EventCursor(eventId: ''),
            ),
        (_) => ApplicationChatRealtimeCursorRecord(
              identity: identity,
              cursor: EventCursor(eventId: oversizedEventId),
            ),
      ];

      for (final updater in invalidUpdaters) {
        await expectLater(
          mutator.mutate<ApplicationChatStorageRecord>(
            identity,
            kind,
            updater,
          ),
          throwsA(anything),
        );
      }
      expect(storage.compareExchangeCount, 0);
      expect(storage.replaceCount, 0);
      expect(storage.removeCount, 0);
    });

    test('committed mutation result is detached from the updater instance',
        () async {
      final storage = InMemoryApplicationChatStorage();
      final identity = _identity();
      late ApplicationChatQueuedSendMessageIntentsRecord proposal;

      final committed = await ApplicationChatStorageMutator(storage)
          .mutate<ApplicationChatQueuedSendMessageIntentsRecord>(
        identity,
        ApplicationChatStorageRecordKind.queuedSendMessageIntents,
        (_) {
          proposal = ApplicationChatQueuedSendMessageIntentsRecord(
            identity: identity,
            intents: [_queuedSendIntent(1)],
          );
          return proposal;
        },
      );

      expect(identical(committed, proposal), isFalse);
      expect(committed?.toJson(), proposal.toJson());
    });

    test('mutation exhaustion has a fixed sanitized typed error', () async {
      const secret = 'private-proposal-content';
      final identity = _identity();
      final storage = _AtomicMutationStorage(alwaysContended: true);
      var updaterCount = 0;

      Object? failure;
      try {
        await ApplicationChatStorageMutator(storage)
            .mutate<ApplicationChatRealtimeCursorRecord>(
          identity,
          ApplicationChatStorageRecordKind.realtimeCursor,
          (_) {
            updaterCount += 1;
            return ApplicationChatRealtimeCursorRecord(
              identity: identity,
              cursor: const EventCursor(eventId: secret),
            );
          },
        );
      } on Object catch (error) {
        failure = error;
      }

      expect(failure, isA<ApplicationChatStorageUnavailableException>());
      final unavailable =
          failure! as ApplicationChatStorageUnavailableException;
      expect(unavailable.code, applicationChatStorageContentionErrorCode);
      expect(unavailable.message, applicationChatStorageContentionErrorMessage);
      expect(unavailable.message, isNot(contains(secret)));
      expect(
        storage.readEncodedCount,
        maxApplicationChatStorageMutationAttempts,
      );
      expect(
        storage.compareExchangeCount,
        maxApplicationChatStorageMutationAttempts,
      );
      expect(updaterCount, maxApplicationChatStorageMutationAttempts);
    });

    test('legacy mutation fallback remains functional for one runtime',
        () async {
      final storage = _LegacyMutationStorage();
      final identity = _identity();
      final mutator = ApplicationChatStorageMutator(storage);
      const kind = ApplicationChatStorageRecordKind.realtimeCursor;

      final created = await mutator.mutate<ApplicationChatRealtimeCursorRecord>(
        identity,
        kind,
        (_) => ApplicationChatRealtimeCursorRecord(
          identity: identity,
          cursor: const EventCursor(eventId: 'created'),
        ),
      );
      final updated = await mutator.mutate<ApplicationChatRealtimeCursorRecord>(
        identity,
        kind,
        (current) => ApplicationChatRealtimeCursorRecord(
          identity: identity,
          cursor: EventCursor(eventId: '${current!.cursor.eventId}-updated'),
        ),
      );
      final removed = await mutator.mutate<ApplicationChatRealtimeCursorRecord>(
        identity,
        kind,
        (_) => null,
      );

      expect(created?.cursor.eventId, 'created');
      expect(updated?.cursor.eventId, 'created-updated');
      expect(removed, isNull);
      expect(storage.replaceCount, 2);
      expect(storage.removeCount, 1);
    });

    test('legacy missing-record hydration does not remove an absent key',
        () async {
      final storage = _LegacyMutationStorage();
      final result = await ApplicationChatStorageMutator(storage)
          .mutate<ApplicationChatRealtimeCursorRecord>(
        _identity(),
        ApplicationChatStorageRecordKind.realtimeCursor,
        (current) => current,
      );

      expect(result, isNull);
      expect(storage.replaceCount, 0);
      expect(storage.removeCount, 0);
    });

    test('legacy unchanged records hydrate without replacement', () async {
      final identity = _identity();
      final original = ApplicationChatRealtimeCursorRecord(
        identity: identity,
        cursor: const EventCursor(eventId: 'persisted'),
      );
      final storage = _LegacyMutationStorage()..encoded = original.encode();
      final mutator = ApplicationChatStorageMutator(storage);
      const kind = ApplicationChatStorageRecordKind.realtimeCursor;
      final hydrated =
          await mutator.mutate<ApplicationChatRealtimeCursorRecord>(
        identity,
        kind,
        (current) => current,
      );
      // An equivalent new instance is also a no-op, but remains detached.
      final equivalent =
          await mutator.mutate<ApplicationChatRealtimeCursorRecord>(
        identity,
        kind,
        (_) => original,
      );

      expect(hydrated?.encode(), original.encode());
      expect(equivalent?.encode(), original.encode());
      expect(identical(equivalent, original), isFalse);
      expect(storage.encoded, original.encode());
      expect(storage.replaceCount, 0);
      expect(storage.removeCount, 0);
    });

    for (final initiallyAbsent in [true, false]) {
      test('atomic hydration retries an unchanged '
          '${initiallyAbsent ? 'absent' : 'present'} value after contention',
          () async {
        final identity = _identity();
        final original = ApplicationChatRealtimeCursorRecord(
          identity: identity,
          cursor: const EventCursor(eventId: 'original'),
        );
        final concurrent = ApplicationChatRealtimeCursorRecord(
          identity: identity,
          cursor: const EventCursor(eventId: 'concurrent'),
        );
        final storage = _AtomicMutationStorage(
          encoded: initiallyAbsent ? null : original.encode(),
          replaceBeforeFirstCompare: concurrent.encode(),
        );
        final result = await ApplicationChatStorageMutator(storage)
            .mutate<ApplicationChatRealtimeCursorRecord>(
          identity,
          ApplicationChatStorageRecordKind.realtimeCursor,
          (current) => current,
        );

        expect(result?.cursor.eventId, 'concurrent');
        expect(storage.encoded, concurrent.encode());
        expect(storage.compareExchangeCount, 2);
        expect(storage.replaceCount, 0);
        expect(storage.removeCount, 0);
      });
    }

    test('competing exchanges based on one value produce one winner', () async {
      final storage = InMemoryApplicationChatStorage();
      final identity = _identity();
      final before = ApplicationChatRealtimeCursorRecord(
        identity: identity,
        cursor: const EventCursor(eventId: 'before'),
      );
      final replacements = [
        ApplicationChatRealtimeCursorRecord(
          identity: identity,
          cursor: const EventCursor(eventId: 'winner-1'),
        ),
        ApplicationChatRealtimeCursorRecord(
          identity: identity,
          cursor: const EventCursor(eventId: 'winner-2'),
        ),
      ];
      await storage.replace(before);

      final results = await Future.wait(
        replacements.map(
          (replacement) => storage.compareExchange(
            identity,
            ApplicationChatStorageRecordKind.realtimeCursor,
            before.encode(),
            replacement.encode(),
          ),
        ),
      );

      expect(results.where((result) => result), hasLength(1));
      final winner = replacements[results.indexOf(true)];
      expect(
        (await storage.read(
          identity,
          ApplicationChatStorageRecordKind.realtimeCursor,
        ))
            ?.encode(),
        winner.encode(),
      );
    });

    test('stale removal fails and preserves the newer replacement', () async {
      final storage = InMemoryApplicationChatStorage();
      final identity = _identity();
      final before = ApplicationChatRealtimeCursorRecord(
        identity: identity,
        cursor: const EventCursor(eventId: 'before'),
      );
      final newer = ApplicationChatRealtimeCursorRecord(
        identity: identity,
        cursor: const EventCursor(eventId: 'newer'),
      );
      await storage.replace(before);
      expect(
        await storage.compareExchange(
          identity,
          ApplicationChatStorageRecordKind.realtimeCursor,
          before.encode(),
          newer.encode(),
        ),
        isTrue,
      );

      expect(
        await storage.compareExchange(
          identity,
          ApplicationChatStorageRecordKind.realtimeCursor,
          before.encode(),
          null,
        ),
        isFalse,
      );
      expect(
        (await storage.read(
          identity,
          ApplicationChatStorageRecordKind.realtimeCursor,
        ))
            ?.encode(),
        newer.encode(),
      );
    });

    test('creation from null succeeds only while the key is absent', () async {
      final storage = InMemoryApplicationChatStorage();
      final identity = _identity();
      final first = ApplicationChatRealtimeCursorRecord(
        identity: identity,
        cursor: const EventCursor(eventId: 'first'),
      );
      final second = ApplicationChatRealtimeCursorRecord(
        identity: identity,
        cursor: const EventCursor(eventId: 'second'),
      );

      expect(
        await storage.compareExchange(
          identity,
          ApplicationChatStorageRecordKind.realtimeCursor,
          null,
          first.encode(),
        ),
        isTrue,
      );
      expect(
        await storage.compareExchange(
          identity,
          ApplicationChatStorageRecordKind.realtimeCursor,
          null,
          second.encode(),
        ),
        isFalse,
      );
      expect(
        (await storage.read(
          identity,
          ApplicationChatStorageRecordKind.realtimeCursor,
        ))
            ?.encode(),
        first.encode(),
      );
    });

    test('exchange leaves identity and record-kind siblings untouched',
        () async {
      final storage = InMemoryApplicationChatStorage();
      final identity = _identity();
      final siblingIdentities = [
        _identity(tenant: 'tenant-2'),
        _identity(user: 'user-2'),
        _identity(device: 'device-2'),
      ];
      final before = ApplicationChatRealtimeCursorRecord(
        identity: identity,
        cursor: const EventCursor(eventId: 'before'),
      );
      final replacement = ApplicationChatRealtimeCursorRecord(
        identity: identity,
        cursor: const EventCursor(eventId: 'replacement'),
      );
      final kindSibling = ApplicationChatQueuedCommandMetadataRecord(
        identity: identity,
        commands: const [],
      );
      await storage.replace(before);
      await storage.replace(kindSibling);
      for (var index = 0; index < siblingIdentities.length; index += 1) {
        await storage.replace(
          ApplicationChatRealtimeCursorRecord(
            identity: siblingIdentities[index],
            cursor: EventCursor(eventId: 'sibling-$index'),
          ),
        );
      }

      expect(
        await storage.compareExchange(
          identity,
          ApplicationChatStorageRecordKind.realtimeCursor,
          before.encode(),
          replacement.encode(),
        ),
        isTrue,
      );

      for (var index = 0; index < siblingIdentities.length; index += 1) {
        final sibling = await storage.read(
          siblingIdentities[index],
          ApplicationChatStorageRecordKind.realtimeCursor,
        ) as ApplicationChatRealtimeCursorRecord;
        expect(sibling.cursor.eventId, 'sibling-$index');
      }
      expect(
        (await storage.read(identity, kindSibling.kind))?.encode(),
        kindSibling.encode(),
      );
    });

    test('exchange rejects encoded records from a different key', () async {
      final storage = InMemoryApplicationChatStorage();
      final identity = _identity();
      final siblingIdentityRecord = ApplicationChatRealtimeCursorRecord(
        identity: _identity(user: 'user-2'),
        cursor: const EventCursor(eventId: 'sibling'),
      );
      final siblingKindRecord = ApplicationChatQueuedCommandMetadataRecord(
        identity: identity,
        commands: const [],
      );

      await expectLater(
        storage.compareExchange(
          identity,
          ApplicationChatStorageRecordKind.realtimeCursor,
          siblingIdentityRecord.encode(),
          null,
        ),
        throwsFormatException,
      );
      await expectLater(
        storage.compareExchange(
          identity,
          ApplicationChatStorageRecordKind.realtimeCursor,
          null,
          siblingKindRecord.encode(),
        ),
        throwsFormatException,
      );
    });

    test('logout and identity change clear only the prior identity', () async {
      final storage = InMemoryApplicationChatStorage();
      final previous = _identity();
      final next = _identity(user: 'user-next');
      await _putAllKinds(storage, previous);
      await _putAllKinds(storage, next);

      await storage.clearForIdentityChange(
        previousIdentity: previous,
        nextIdentity: previous,
      );
      expect(
        await _recordCount(storage, previous),
        ApplicationChatStorageRecordKind.values.length,
      );

      await storage.clearForIdentityChange(
        previousIdentity: previous,
        nextIdentity: next,
      );
      expect(await _recordCount(storage, previous), 0);
      expect(
        await _recordCount(storage, next),
        ApplicationChatStorageRecordKind.values.length,
      );

      await storage.clearForLogout(next);
      expect(await _recordCount(storage, next), 0);
    });

    test('malformed, unsupported, and future records yield no partial state',
        () async {
      final storage = InMemoryApplicationChatStorage();
      final identity = _identity();
      await storage.replace(_snapshotRecord(identity));

      final malformed = ApplicationChatRealtimeCursorRecord(
        identity: identity,
        cursor: const EventCursor(eventId: 'valid'),
      ).toJson()
        ..['unexpected'] = true;
      storage.putRawRecordForTesting(
        identity,
        ApplicationChatStorageRecordKind.realtimeCursor,
        malformed,
      );
      await expectLater(
        storage.read(
          identity,
          ApplicationChatStorageRecordKind.realtimeCursor,
        ),
        throwsFormatException,
      );

      final future = Map<String, Object?>.from(malformed)
        ..remove('unexpected')
        ..['schemaVersion'] = applicationChatStorageSchemaVersion + 1;
      storage.putRawRecordForTesting(
        identity,
        ApplicationChatStorageRecordKind.realtimeCursor,
        future,
      );
      await expectLater(
        storage.read(
          identity,
          ApplicationChatStorageRecordKind.realtimeCursor,
        ),
        throwsFormatException,
      );

      final unsupported = Map<String, Object?>.from(future)
        ..['schemaVersion'] = applicationChatStorageSchemaVersion
        ..['kind'] = 'provider_session';
      storage.putRawRecordForTesting(
        identity,
        ApplicationChatStorageRecordKind.realtimeCursor,
        unsupported,
      );
      await expectLater(
        storage.read(
          identity,
          ApplicationChatStorageRecordKind.realtimeCursor,
        ),
        throwsFormatException,
      );

      final snapshot = await storage.read(
        identity,
        ApplicationChatStorageRecordKind.normalizedSnapshot,
      ) as ApplicationChatNormalizedSnapshotRecord;
      expect(snapshot.snapshot.canonicalMessages, hasLength(1));
    });

    test('serialized schemas are closed and structurally secret-free', () {
      final identity = _identity();
      final records = <ApplicationChatStorageRecord>[
        ApplicationChatRealtimeCursorRecord(
          identity: identity,
          cursor: const EventCursor(eventId: 'event-1'),
        ),
        _snapshotRecord(identity),
        ApplicationChatQueuedCommandMetadataRecord(
          identity: identity,
          commands: [
            ApplicationChatQueuedCommandMetadata(
              commandId: 'command-1',
              commandKind: ApplicationChatQueuedCommandKind.sendMessage,
              enqueuedAt: const IsoTimestamp('2026-08-26T16:00:00.000Z'),
              attemptCount: 0,
            ),
          ],
        ),
        ApplicationChatQueuedSendMessageIntentsRecord(
          identity: identity,
          intents: [
            ApplicationChatQueuedSendMessageIntent(
              request: SendMessageRequest.fromJson({
                'operation': 'send',
                'conversationId': 'conversation-1',
                'content': {'format': 'plain', 'text': 'Safe queued body'},
                'clientMessageId': 'client-message-1',
                'idempotencyKey': 'send-key-1',
              }),
              enqueueOrder: 1,
              enqueuedAt: const IsoTimestamp('2026-08-26T16:01:00.000Z'),
            ),
          ],
        ),
        ApplicationChatQueuedReadCursorIntentsRecord(
          identity: identity,
          intents: [_readIntent(1, throughSequence: 2)],
        ),
        ApplicationChatQueuedMessageMutationIntentsRecord(
          identity: identity,
          intents: [_mutationIntent(1, 'edit')],
        ),
        ApplicationChatQueuedConversationMembershipIntentsRecord(
          identity: identity,
          intents: [_membershipIntent(1, 'add_member')],
        ),
        ApplicationChatQueuedConversationCreationIntentsRecord(
          identity: identity,
          intents: [_creationIntent(1, 'direct')],
        ),
        ApplicationChatQueuedConversationPreferenceIntentsRecord(
          identity: identity,
          intents: [_preferenceIntent(1)],
        ),
        ApplicationChatQueuedThreadFollowIntentsRecord(
          identity: identity,
          intents: [_threadFollowIntent(1)],
        ),
        ApplicationChatQueuedMessageReminderIntentsRecord(
          identity: identity,
          intents: [_messageReminderIntent(1)],
        ),
        ApplicationChatQueuedDraftIntentsRecord(
          identity: identity,
          intents: [_draftIntent(1)],
        ),
        ApplicationChatPushTokenRevisionsRecord(
          identity: identity,
          revisions: const [],
        ),
      ];
      const forbidden = {
        'accessToken',
        'authorization',
        'credentials',
        'provider',
        'providerDescriptor',
        'providerConfiguration',
        'commandBody',
        'requestBody',
        'exception',
        'thrownValue',
      };

      for (final record in records) {
        final keys = _allKeys(record.toJson()).toSet();
        expect(keys.intersection(forbidden), isEmpty);
        expect(record.toJson().keys, {
          'schemaVersion',
          'kind',
          'identity',
          'payload',
        });
      }

      final withCommandBody = records
          .whereType<ApplicationChatQueuedCommandMetadataRecord>()
          .single
          .toJson();
      final payload = withCommandBody['payload']! as Map<String, Object?>;
      final command = (payload['commands']! as List<Object?>).single!
          as Map<String, Object?>;
      command['requestBody'] = {'text': 'must not persist'};
      expect(
        () => ApplicationChatStorageRecord.fromJson(withCommandBody),
        throwsFormatException,
      );
    });

    test('read-cursor record rejects identity, version, kind, and shape drift',
        () async {
      final identity = _identity();
      final record = _readRecord(identity).toJson();

      final futureSchema = _deepJsonCopy(record)
        ..['schemaVersion'] = applicationChatStorageSchemaVersion + 1;
      expect(
        () => ApplicationChatStorageRecord.fromJson(futureSchema),
        throwsFormatException,
      );

      final futureContract = _deepJsonCopy(record);
      final futureContractIntent = (((futureContract['payload']!
              as Map<String, Object?>)['intents']! as List<Object?>)
          .single)! as Map<String, Object?>;
      futureContractIntent['contractVersion'] =
          applicationChatReadCursorContractVersion + 1;
      expect(
        () => ApplicationChatStorageRecord.fromJson(futureContract),
        throwsFormatException,
      );

      final wrongKind = _deepJsonCopy(record)
        ..['kind'] = 'queued_send_message_intents';
      expect(
        () => ApplicationChatStorageRecord.fromJson(wrongKind),
        throwsFormatException,
      );

      final baselineShape = _deepJsonCopy(record);
      final baselineIntent = (((baselineShape['payload']!
              as Map<String, Object?>)['intents']! as List<Object?>)
          .single)! as Map<String, Object?>;
      (baselineIntent['acknowledgedReadState']!
          as Map<String, Object?>)['unexpected'] = true;
      expect(
        () => ApplicationChatStorageRecord.fromJson(baselineShape),
        throwsFormatException,
      );

      for (final malformed in <Map<String, Object?>>[
        _deepJsonCopy(record)..['unexpected'] = true,
        _deepJsonCopy(record)
          ..['payload'] = <String, Object?>{
            ...record['payload']! as Map<String, Object?>,
            'unexpected': true,
          },
        _deepJsonCopy(record)
          ..['payload'] = <String, Object?>{
            'intents': <Object?>[
              ...((record['payload']! as Map<String, Object?>)['intents']!
                  as List<Object?>),
            ]..first = <String, Object?>{
                ...((((record['payload']! as Map<String, Object?>)['intents']!
                        as List<Object?>)
                    .first)! as Map<String, Object?>),
                'httpStatus': 503,
              },
          },
      ]) {
        expect(
          () => ApplicationChatStorageRecord.fromJson(malformed),
          throwsFormatException,
        );
      }

      final storage = InMemoryApplicationChatStorage();
      final wrongIdentity = _deepJsonCopy(record)
        ..['identity'] = _identity(user: 'other-user').toJson();
      storage.putRawRecordForTesting(
        identity,
        ApplicationChatStorageRecordKind.queuedReadCursorIntents,
        wrongIdentity,
      );
      await expectLater(
        storage.read(
          identity,
          ApplicationChatStorageRecordKind.queuedReadCursorIntents,
        ),
        throwsFormatException,
      );
      storage.putRawRecordForTesting(
        identity,
        ApplicationChatStorageRecordKind.queuedReadCursorIntents,
        ApplicationChatRealtimeCursorRecord(
          identity: identity,
          cursor: const EventCursor(eventId: 'wrong-kind'),
        ).toJson(),
      );
      await expectLater(
        storage.read(
          identity,
          ApplicationChatStorageRecordKind.queuedReadCursorIntents,
        ),
        throwsFormatException,
      );
    });

    test('read-cursor intents coalesce by conversation without crossing unread',
        () {
      final record = ApplicationChatQueuedReadCursorIntentsRecord(
        identity: _identity(),
        intents: [
          _readIntent(1, throughSequence: 2, idempotencyKey: 'stable-first'),
          _readIntent(2, throughSequence: 5),
          _unreadIntent(3, fromSequence: 4),
          _readIntent(4, throughSequence: 5),
          _readIntent(5, throughSequence: 7),
          _readIntent(6, conversation: 'conversation-2', throughSequence: 3),
          _readIntent(7, throughSequence: 8),
        ],
      );

      expect(record.intents, hasLength(5));
      final first = record.intents[0];
      expect(first.enqueueOrder, 1);
      expect(first.request.idempotencyKey, 'stable-first');
      expect((first.request as MarkReadInput).throughSequence.value, 5);
      expect(record.intents[1].request, isA<MarkUnreadInput>());
      expect(record.intents[1].enqueueOrder, 3);
      expect(
        (record.intents[2].request as MarkReadInput).throughSequence.value,
        7,
      );
      expect(record.intents[2].enqueueOrder, 4);
      expect(
        record.intents[3].request.conversationId.value,
        'conversation-2',
      );
      expect(
        (record.intents[4].request as MarkReadInput).throughSequence.value,
        8,
        reason: 'another conversation is an ordering barrier',
      );
      expect(record.intents[4].enqueueOrder, 7);
      final decoded = ApplicationChatStorageRecord.decode(record.encode())
          as ApplicationChatQueuedReadCursorIntentsRecord;
      expect(decoded.toJson(), record.toJson());
      expect(decoded.intents[1].request, isA<MarkUnreadInput>());
    });

    test(
        'read-cursor queue rejects duplicates, invalid order, and baseline drift',
        () {
      expect(
        () => ApplicationChatQueuedReadCursorIntentsRecord(
          identity: _identity(),
          intents: [
            _readIntent(1, throughSequence: 2),
            _readIntent(1, throughSequence: 3),
          ],
        ),
        throwsArgumentError,
      );
      expect(
        () => ApplicationChatQueuedReadCursorIntentsRecord(
          identity: _identity(),
          intents: [
            _readIntent(1, throughSequence: 2, idempotencyKey: 'same'),
            _readIntent(2, throughSequence: 3, idempotencyKey: 'same'),
          ],
        ),
        throwsArgumentError,
      );
      expect(
        () => ApplicationChatQueuedReadCursorIntentsRecord(
          identity: _identity(),
          intents: [
            _readIntent(2, throughSequence: 2),
            _readIntent(1, throughSequence: 3),
          ],
        ),
        throwsArgumentError,
      );
      expect(
        () => ApplicationChatQueuedReadCursorIntentsRecord(
          identity: _identity(user: 'other-user'),
          intents: [_readIntent(1, throughSequence: 2)],
        ),
        throwsArgumentError,
      );
      expect(
        () => ApplicationChatQueuedReadCursorIntent(
          request: MarkUnreadInput(
            conversationId: const ConversationId('conversation-1'),
            fromSequence: const MessageSequence(6),
            idempotencyKey: 'invalid-unread',
          ),
          acknowledgedReadState: _readState(lastReadSequence: 5),
          enqueueOrder: 1,
          enqueuedAt: const IsoTimestamp('2026-08-26T16:01:00.000Z'),
        ),
        throwsArgumentError,
      );
      expect(
        () => ApplicationChatQueuedReadCursorIntent(
          request: MarkReadInput(
            conversationId: const ConversationId('conversation-1'),
            throughSequence: const MessageSequence(2),
            idempotencyKey: 'unsafe-order',
          ),
          acknowledgedReadState: _readState(),
          enqueueOrder: 9007199254740992,
          enqueuedAt: const IsoTimestamp('2026-08-26T16:01:00.000Z'),
        ),
        throwsArgumentError,
      );
      expect(
        () => ApplicationChatQueuedReadCursorIntent(
          request: MarkReadInput(
            conversationId: ConversationId('c' * 513),
            throughSequence: const MessageSequence(2),
            idempotencyKey: 'bounded-id',
          ),
          acknowledgedReadState: _readState(conversation: 'c' * 513),
          enqueueOrder: 1,
          enqueuedAt: const IsoTimestamp('2026-08-26T16:01:00.000Z'),
        ),
        throwsArgumentError,
      );
      expect(
        () => ApplicationChatQueuedReadCursorIntent(
          request: MarkReadInput(
            conversationId: const ConversationId('conversation-1'),
            throughSequence: const MessageSequence(2),
            idempotencyKey: 'bad-time',
          ),
          acknowledgedReadState: _readState(),
          enqueueOrder: 1,
          enqueuedAt: const IsoTimestamp('2026-08-26'),
        ),
        throwsArgumentError,
      );
    });

    test('read-cursor queue enforces count before coalescing and decoding', () {
      final intents = List.generate(
        maxApplicationChatQueuedReadCursorIntents,
        (index) => _readIntent(index + 1, throughSequence: index + 1),
      );
      expect(
        ApplicationChatQueuedReadCursorIntentsRecord(
          identity: _identity(),
          intents: intents,
        ).intents,
        hasLength(1),
      );
      expect(
        () => ApplicationChatQueuedReadCursorIntentsRecord(
          identity: _identity(),
          intents: [
            ...intents,
            _readIntent(
              maxApplicationChatQueuedReadCursorIntents + 1,
              throughSequence: maxApplicationChatQueuedReadCursorIntents + 1,
            ),
          ],
        ),
        throwsArgumentError,
      );

      final json = _readRecord(_identity()).toJson();
      final payload = json['payload']! as Map<String, Object?>;
      payload['intents'] = List<Object?>.filled(
        maxApplicationChatQueuedReadCursorIntents + 1,
        _readIntentJson(1),
      );
      expect(
        () => ApplicationChatStorageRecord.fromJson(json),
        throwsFormatException,
      );
    });

    test('read-cursor per-entry bounds count UTF-8 bytes', () {
      final ascii = _readIntentJson(1)
        ..['conversationId'] =
            'a' * maxApplicationChatQueuedReadCursorIntentBytes;
      expect(
        () => ApplicationChatQueuedReadCursorIntent.fromJson(ascii),
        throwsA(
          isA<FormatException>().having(
            (error) => error.message,
            'message',
            contains('exceeds 16384 encoded bytes'),
          ),
        ),
      );

      final emoji = _readIntentJson(1)..['conversationId'] = '\u{1f642}' * 5000;
      final encoded = jsonEncode(emoji);
      expect(encoded.length,
          lessThan(maxApplicationChatQueuedReadCursorIntentBytes));
      expect(
        utf8.encode(encoded).length,
        greaterThan(maxApplicationChatQueuedReadCursorIntentBytes),
      );
      expect(
        () => ApplicationChatQueuedReadCursorIntent.fromJson(emoji),
        throwsFormatException,
      );
    });

    test('read-cursor records obey the whole-record UTF-8 ceiling', () {
      final json = _readRecord(_identity()).toJson();
      final payload = json['payload']! as Map<String, Object?>;
      final oversizedIntent = _readIntentJson(1)
        ..['conversationId'] =
            'a' * maxApplicationChatQueuedReadCursorIntentBytes;
      payload['intents'] = List<Object?>.filled(330, oversizedIntent);
      final encoded = jsonEncode(json);
      expect(
        utf8.encode(encoded).length,
        greaterThan(maxApplicationChatStorageRecordBytes),
      );
      expect(
        () => ApplicationChatStorageRecord.decode(encoded),
        throwsA(
          isA<FormatException>().having(
            (error) => error.message,
            'message',
            contains('exceeds 5242880 encoded bytes'),
          ),
        ),
      );
    });

    test('read-cursor values and storage reads are detached and immutable',
        () async {
      final source = [_readIntent(1, throughSequence: 2)];
      final record = ApplicationChatQueuedReadCursorIntentsRecord(
        identity: _identity(),
        intents: source,
      );
      source.add(_readIntent(2, throughSequence: 3));
      expect(record.intents, hasLength(1));
      expect(() => record.intents.add(source.last), throwsUnsupportedError);

      final serialized = record.toJson();
      final intent = ((serialized['payload']!
              as Map<String, Object?>)['intents']! as List<Object?>)
          .single! as Map<String, Object?>;
      intent['throughSequence'] = 99;
      expect(
          (record.intents.single.request as MarkReadInput)
              .throughSequence
              .value,
          2);

      final storage = InMemoryApplicationChatStorage();
      await storage.replace(record);
      final first = await storage.read(
        _identity(),
        ApplicationChatStorageRecordKind.queuedReadCursorIntents,
      ) as ApplicationChatQueuedReadCursorIntentsRecord;
      first.toJson()['kind'] = 'tampered';
      final second = await storage.read(
        _identity(),
        ApplicationChatStorageRecordKind.queuedReadCursorIntents,
      ) as ApplicationChatQueuedReadCursorIntentsRecord;
      expect(second.toJson(), record.toJson());
    });

    test('corrupt read-cursor record can be quarantined by exact removal',
        () async {
      final storage = InMemoryApplicationChatStorage();
      final identity = _identity();
      final others = [
        _identity(tenant: 'other-tenant'),
        _identity(user: 'other-user'),
        _identity(device: 'other-device'),
      ];
      await _putAllKinds(storage, identity);
      for (final other in others) {
        await _putAllKinds(storage, other);
      }
      final corrupt = _readRecord(identity).toJson();
      final payload = corrupt['payload']! as Map<String, Object?>;
      final intent = (payload['intents']! as List<Object?>).single!
          as Map<String, Object?>;
      intent['idempotencyKey'] = ' ';
      storage.putRawRecordForTesting(
        identity,
        ApplicationChatStorageRecordKind.queuedReadCursorIntents,
        corrupt,
      );

      await expectLater(
        storage.read(
          identity,
          ApplicationChatStorageRecordKind.queuedReadCursorIntents,
        ),
        throwsFormatException,
      );
      await storage.remove(
        identity,
        ApplicationChatStorageRecordKind.queuedReadCursorIntents,
      );
      expect(
        await storage.read(
          identity,
          ApplicationChatStorageRecordKind.queuedReadCursorIntents,
        ),
        isNull,
      );
      expect(
        await _recordCount(storage, identity),
        ApplicationChatStorageRecordKind.values.length - 1,
      );
      for (final other in others) {
        expect(
          await _recordCount(storage, other),
          ApplicationChatStorageRecordKind.values.length,
        );
      }
      expect(
        await storage.read(
          identity,
          ApplicationChatStorageRecordKind.normalizedSnapshot,
        ),
        isNotNull,
      );
      expect(
        await storage.read(
          identity,
          ApplicationChatStorageRecordKind.queuedSendMessageIntents,
        ),
        isNotNull,
      );
    });

    test('read-cursor intent rejects forbidden transport and content fields',
        () {
      for (final field in const {
        'accessToken',
        'authorization',
        'providerConfiguration',
        'httpStatus',
        'errorDetails',
        'messageContent',
      }) {
        final json = _readIntentJson(1)..[field] = 'forbidden';
        expect(
          () => ApplicationChatQueuedReadCursorIntent.fromJson(json),
          throwsFormatException,
          reason: field,
        );
      }
    });

    test('all five membership variants round-trip exact retry requests',
        () async {
      final identity = _identity();
      final record = ApplicationChatQueuedConversationMembershipIntentsRecord(
        identity: identity,
        intents: [
          _membershipIntent(1, 'join', idempotencyKey: 'join-key'),
          _membershipIntent(
            2,
            'leave',
            conversation: 'conversation-2',
            idempotencyKey: 'leave-key',
          ),
          _membershipIntent(
            3,
            'add_member',
            targetUser: 'target-add',
            role: 'member',
            idempotencyKey: 'add-key',
          ),
          _membershipIntent(
            4,
            'remove_member',
            targetUser: 'target-remove',
            idempotencyKey: 'remove-key',
          ),
          _membershipIntent(
            5,
            'change_member_role',
            targetUser: 'target-role',
            role: 'moderator',
            idempotencyKey: 'role-key',
          ),
        ],
      );

      final decoded = ApplicationChatStorageRecord.decode(record.encode())
          as ApplicationChatQueuedConversationMembershipIntentsRecord;
      expect(decoded.toJson(), record.toJson());
      expect(
        decoded.intents.map((intent) => intent.request.intent),
        ConversationMembershipMutationIntent.values,
      );
      expect(
        decoded.intents.map((intent) => intent.request.idempotencyKey),
        ['join-key', 'leave-key', 'add-key', 'remove-key', 'role-key'],
      );
      expect(decoded.intents[2].request.targetUserId?.value, 'target-add');
      expect(
        decoded.intents[4].request.requestedRole,
        ConversationMembershipMemberRole.moderator,
      );

      final storage = InMemoryApplicationChatStorage();
      await storage.replace(record);
      for (final mismatch in [
        _identity(tenant: 'other-tenant'),
        _identity(user: 'other-user'),
        _identity(device: 'other-device'),
      ]) {
        expect(
          await storage.read(
            mismatch,
            ApplicationChatStorageRecordKind
                .queuedConversationMembershipIntents,
          ),
          isNull,
        );
      }
      for (final mismatch in [
        _identity(tenant: 'other-tenant'),
        _identity(user: 'other-user'),
        _identity(device: 'other-device'),
      ]) {
        final wrongIdentity = _deepJsonCopy(record.toJson())
          ..['identity'] = mismatch.toJson();
        storage.putRawRecordForTesting(
          identity,
          ApplicationChatStorageRecordKind.queuedConversationMembershipIntents,
          wrongIdentity,
        );
        await expectLater(
          storage.read(
            identity,
            ApplicationChatStorageRecordKind
                .queuedConversationMembershipIntents,
          ),
          throwsFormatException,
        );
      }
    });

    test('membership intents detach and coalesce only adjacent exact semantics',
        () {
      final request = _membershipRequest(
        'add_member',
        conversation: 'detached-conversation',
        targetUser: 'detached-user',
        role: 'owner',
        expectedRevision: 8,
        idempotencyKey: 'detached-key',
      );
      final intent = ApplicationChatQueuedConversationMembershipIntent(
        request: request,
        enqueueOrder: 1,
        enqueuedAt: const IsoTimestamp('2026-09-03T14:01:00.000Z'),
      );
      final source = [
        intent,
        _membershipIntent(
          2,
          'add_member',
          conversation: 'detached-conversation',
          targetUser: 'detached-user',
          role: 'owner',
          expectedRevision: 8,
          idempotencyKey: 'coalesced-key',
        ),
        _membershipIntent(
          3,
          'leave',
          conversation: 'unrelated-conversation',
        ),
        _membershipIntent(
          4,
          'add_member',
          conversation: 'detached-conversation',
          targetUser: 'detached-user',
          role: 'owner',
          expectedRevision: 8,
        ),
        _membershipIntent(
          5,
          'change_member_role',
          conversation: 'detached-conversation',
          targetUser: 'detached-user',
          role: 'moderator',
          expectedRevision: 8,
        ),
      ];
      final record = ApplicationChatQueuedConversationMembershipIntentsRecord(
        identity: _identity(),
        intents: source,
      );
      source.add(_membershipIntent(6, 'join'));

      expect(identical(intent.request, request), isFalse);
      expect(identical(record.intents.first, intent), isFalse);
      expect(identical(record.intents.first.request, intent.request), isFalse);
      expect(() => record.intents.add(source.last), throwsUnsupportedError);
      expect(
        record.intents
            .map(
              (item) => (
                item.enqueueOrder,
                item.enqueuedAt.value,
                item.request.intent.wireValue,
                item.request.idempotencyKey,
              ),
            )
            .toList(),
        [
          (1, '2026-09-03T14:01:00.000Z', 'add_member', 'detached-key'),
          (3, '2026-09-03T14:03:00.000Z', 'leave', 'membership-key-3'),
          (4, '2026-09-03T14:04:00.000Z', 'add_member', 'membership-key-4'),
          (
            5,
            '2026-09-03T14:05:00.000Z',
            'change_member_role',
            'membership-key-5',
          ),
        ],
      );

      final wire = intent.toJson();
      final reparsed =
          ApplicationChatQueuedConversationMembershipIntent.fromJson(wire);
      wire['conversationId'] = 'tampered';
      expect(reparsed.request.conversationId.value, 'detached-conversation');
    });

    test('membership queues reject duplicate correlations and FIFO drift', () {
      for (final intents
          in <List<ApplicationChatQueuedConversationMembershipIntent>>[
        [_membershipIntent(2, 'join'), _membershipIntent(1, 'leave')],
        [
          _membershipIntent(1, 'join', idempotencyKey: 'duplicate-key'),
          _membershipIntent(
            2,
            'leave',
            idempotencyKey: 'duplicate-key',
          ),
        ],
        [_membershipIntent(1, 'join'), _membershipIntent(1, 'leave')],
      ]) {
        expect(
          () => ApplicationChatQueuedConversationMembershipIntentsRecord(
            identity: _identity(),
            intents: intents,
          ),
          throwsArgumentError,
        );
      }
      expect(() => _membershipIntent(0, 'join'), throwsArgumentError);
      expect(
        () => _membershipIntent(9007199254740992, 'join'),
        throwsArgumentError,
      );
      expect(
        () => _membershipIntent(
          1,
          'join',
          enqueuedAt: const IsoTimestamp('2026-09-03'),
        ),
        throwsArgumentError,
      );

      final duplicateKey = _membershipRecord(_identity()).toJson();
      _membershipWireIntents(duplicateKey).add(
        _membershipIntent(
          2,
          'leave',
          idempotencyKey: 'membership-key-1',
        ).toJson(),
      );
      expect(
        () => ApplicationChatStorageRecord.fromJson(duplicateKey),
        throwsFormatException,
      );

      final duplicateOrder = _membershipRecord(_identity()).toJson();
      _membershipWireIntents(duplicateOrder).add(
        _membershipIntent(1, 'leave').toJson(),
      );
      expect(
        () => ApplicationChatStorageRecord.fromJson(duplicateOrder),
        throwsFormatException,
      );
    });

    test(
        'membership parsing rejects operation, shape, role, and revision drift',
        () {
      final variants = <Map<String, Object?>>[
        _membershipIntent(1, 'join').toJson()..['operation'] = 'join',
        _membershipIntent(1, 'join').toJson()..['intent'] = 'invite',
        _membershipIntent(1, 'join').toJson()
          ..['targetUserId'] = 'unexpected-target',
        _membershipIntent(1, 'add_member').toJson()..remove('requestedRole'),
        _membershipIntent(1, 'add_member').toJson()
          ..['requestedRole'] = 'administrator',
        _membershipIntent(1, 'remove_member').toJson()
          ..['requestedRole'] = 'member',
        _membershipIntent(1, 'leave').toJson()
          ..['expectedMemberListRevision'] = 0,
        _membershipIntent(1, 'leave').toJson()
          ..['expectedMemberListRevision'] = 9007199254740992,
        _membershipIntent(1, 'leave').toJson()
          ..['expectedMemberListRevision'] = 1.0,
        _membershipIntent(1, 'join').toJson()..['unexpected'] = true,
      ];
      for (final malformed in variants) {
        expect(
          () => ApplicationChatQueuedConversationMembershipIntent.fromJson(
            malformed,
          ),
          throwsFormatException,
        );
      }

      final future = _membershipRecord(_identity()).toJson();
      _membershipWireIntents(future).single['contractVersion'] =
          applicationChatConversationMembershipContractVersion + 1;
      expect(
        () => ApplicationChatStorageRecord.fromJson(future),
        throwsFormatException,
      );
    });

    test('membership parsing rejects secret and server-derived fields', () {
      for (final field in const {
        'accessToken',
        'authorization',
        'credentials',
        'providerConfiguration',
        'requestBody',
        'tenantId',
        'userId',
        'actorRole',
      }) {
        final json = _membershipIntent(1, 'add_member').toJson()
          ..[field] = 'forbidden';
        expect(
          () => ApplicationChatQueuedConversationMembershipIntent.fromJson(
            json,
          ),
          throwsFormatException,
          reason: field,
        );
      }
    });

    test('membership count and multibyte UTF-8 ceilings are enforced', () {
      final exactCount = List.generate(
        maxApplicationChatQueuedConversationMembershipIntents,
        (index) => _membershipIntent(
          index + 1,
          'join',
          conversation: 'count-$index',
        ),
      );
      expect(
        ApplicationChatQueuedConversationMembershipIntentsRecord(
          identity: _identity(),
          intents: exactCount,
        ).intents,
        hasLength(maxApplicationChatQueuedConversationMembershipIntents),
      );
      expect(
        () => ApplicationChatQueuedConversationMembershipIntentsRecord(
          identity: _identity(),
          intents: [
            ...exactCount,
            _membershipIntent(
              maxApplicationChatQueuedConversationMembershipIntents + 1,
              'join',
              conversation: 'one-too-many',
            ),
          ],
        ),
        throwsArgumentError,
      );

      final exactKey = '${'\u{1f642}' * 63}abc';
      expect(utf8.encode(exactKey), hasLength(255));
      expect(
        _membershipIntent(1, 'join', idempotencyKey: exactKey)
            .request
            .idempotencyKey,
        exactKey,
      );
      expect(
        () => _membershipIntent(
          1,
          'join',
          idempotencyKey: '\u{1f642}' * 64,
        ),
        throwsA(isA<ConversationMembershipFormatException>()),
      );
      expect(
        () => _membershipIntent(
          1,
          'join',
          conversation: '\u{1f642}' * 129,
        ),
        throwsArgumentError,
      );

      final oversizedIntent = _membershipIntent(1, 'join').toJson()
        ..['operation'] = '\u{1f642}' * 4097;
      expect(
        () => ApplicationChatQueuedConversationMembershipIntent.fromJson(
          oversizedIntent,
        ),
        throwsA(
          isA<FormatException>().having(
            (error) => error.message,
            'message',
            contains('exceeds 16384 encoded bytes'),
          ),
        ),
      );

      final oversizedRecord = _membershipRecord(_identity()).toJson();
      final payload = oversizedRecord['payload']! as Map<String, Object?>;
      payload['intents'] = List.generate(
        400,
        (index) => <String, Object?>{
          ..._membershipIntent(index + 1, 'join').toJson(),
          'padding': '\u{1f642}' * 3500,
        },
      );
      final encoded = jsonEncode(oversizedRecord);
      expect(utf8.encode(encoded).length,
          greaterThan(maxApplicationChatStorageRecordBytes));
      expect(
        () => ApplicationChatStorageRecord.decode(encoded),
        throwsFormatException,
      );
    });

    test('corrupt membership removal preserves every other scope and kind',
        () async {
      final storage = InMemoryApplicationChatStorage();
      final identity = _identity();
      final siblings = [
        _identity(tenant: 'other-tenant'),
        _identity(user: 'other-user'),
        _identity(device: 'other-device'),
      ];
      await _putAllKinds(storage, identity);
      for (final sibling in siblings) {
        await _putAllKinds(storage, sibling);
      }
      final corrupt = _membershipRecord(identity).toJson();
      _membershipWireIntents(corrupt).single['accessToken'] =
          'must-not-persist';
      storage.putRawRecordForTesting(
        identity,
        ApplicationChatStorageRecordKind.queuedConversationMembershipIntents,
        corrupt,
      );
      await expectLater(
        storage.read(
          identity,
          ApplicationChatStorageRecordKind.queuedConversationMembershipIntents,
        ),
        throwsFormatException,
      );

      await storage.remove(
        identity,
        ApplicationChatStorageRecordKind.queuedConversationMembershipIntents,
      );
      expect(
        await _recordCount(storage, identity),
        ApplicationChatStorageRecordKind.values.length - 1,
      );
      expect(
        await storage.read(
          identity,
          ApplicationChatStorageRecordKind.queuedMessageMutationIntents,
        ),
        isNotNull,
      );
      for (final sibling in siblings) {
        expect(
          await _recordCount(storage, sibling),
          ApplicationChatStorageRecordKind.values.length,
        );
      }
    });

    test('creation variants round-trip exact retry requests and identity scope',
        () async {
      final identity = _identity();
      final record = ApplicationChatQueuedConversationCreationIntentsRecord(
        identity: identity,
        intents: [
          _creationIntent(
            1,
            'channel',
            name: 'Public channel',
            idempotencyKey: 'channel-public-key',
            clientRequestId: 'channel-public-request',
          ),
          _creationIntent(
            2,
            'channel',
            name: 'Entity channel',
            visibility: 'private',
            entityType: 'project',
            entityId: 'project-42',
            idempotencyKey: 'channel-entity-key',
            clientRequestId: 'channel-entity-request',
          ),
          _creationIntent(
            3,
            'direct',
            members: ['user-z'],
            idempotencyKey: 'direct-key',
            clientRequestId: 'direct-request',
          ),
          _creationIntent(
            4,
            'group_direct',
            members: ['user-z', 'user-a', 'user-m'],
            idempotencyKey: 'group-key',
            clientRequestId: 'group-request',
          ),
        ],
      );

      final decoded = ApplicationChatStorageRecord.decode(record.encode())
          as ApplicationChatQueuedConversationCreationIntentsRecord;
      expect(decoded.toJson(), record.toJson());
      expect(
        decoded.intents.map((intent) => intent.request.type),
        [
          ConversationCreationType.channel,
          ConversationCreationType.channel,
          ConversationCreationType.direct,
          ConversationCreationType.groupDirect,
        ],
      );
      expect(
        (decoded.intents.first.request as CreateChannelConversationInput)
            .entity,
        isNull,
      );
      expect(
        (decoded.intents[1].request as CreateChannelConversationInput)
            .entity
            ?.toJson(),
        {'type': 'project', 'id': 'project-42'},
      );
      expect(
        (decoded.intents[3].request as ParticipantConversationCreationInput)
            .intendedMemberUserIds
            .map((member) => member.value),
        ['user-a', 'user-m', 'user-z'],
      );
      expect(
        decoded.intents.map((intent) => intent.request.idempotencyKey),
        [
          'channel-public-key',
          'channel-entity-key',
          'direct-key',
          'group-key',
        ],
      );
      expect(
        decoded.intents.map((intent) => intent.request.clientRequestId),
        [
          'channel-public-request',
          'channel-entity-request',
          'direct-request',
          'group-request',
        ],
      );
      expect(
          decoded.intents.map((intent) => intent.enqueueOrder), [1, 2, 3, 4]);
      expect(
        decoded.intents.map((intent) => intent.enqueuedAt.value),
        [
          '2026-09-04T14:01:00.000Z',
          '2026-09-04T14:02:00.000Z',
          '2026-09-04T14:03:00.000Z',
          '2026-09-04T14:04:00.000Z',
        ],
      );

      final storage = InMemoryApplicationChatStorage();
      await storage.replace(record);
      for (final mismatch in [
        _identity(tenant: 'other-tenant'),
        _identity(user: 'other-user'),
        _identity(device: 'other-device'),
      ]) {
        expect(
          await storage.read(
            mismatch,
            ApplicationChatStorageRecordKind.queuedConversationCreationIntents,
          ),
          isNull,
        );
        final wrongIdentity = _deepJsonCopy(record.toJson())
          ..['identity'] = mismatch.toJson();
        storage.putRawRecordForTesting(
          identity,
          ApplicationChatStorageRecordKind.queuedConversationCreationIntents,
          wrongIdentity,
        );
        await expectLater(
          storage.read(
            identity,
            ApplicationChatStorageRecordKind.queuedConversationCreationIntents,
          ),
          throwsFormatException,
        );
      }
    });

    test('creation intents canonicalize, detach, and safely coalesce', () {
      final members = ['user-z', 'user-a', 'user-m'];
      final requestJson = <String, Object?>{
        'operation': 'create_conversation',
        'type': 'group_direct',
        'visibility': 'private',
        'intendedMemberUserIds': members,
        'idempotencyKey': 'surviving-key',
        'clientRequestId': 'surviving-request',
      };
      final request = ConversationCreationInput.fromJson(requestJson);
      final first = ApplicationChatQueuedConversationCreationIntent(
        request: request,
        enqueueOrder: 1,
        enqueuedAt: const IsoTimestamp('2026-09-04T14:01:00.000Z'),
      );
      final source = [
        first,
        _creationIntent(2, 'direct', members: ['user-a']),
        _creationIntent(
          3,
          'group_direct',
          members: ['user-m', 'user-z', 'user-a'],
        ),
        _creationIntent(4, 'channel', name: 'same-name'),
        _creationIntent(
          5,
          'channel',
          name: 'same-name',
          visibility: 'private',
        ),
      ];
      final record = ApplicationChatQueuedConversationCreationIntentsRecord(
        identity: _identity(),
        intents: source,
      );
      members[0] = 'tampered-member';
      requestJson['clientRequestId'] = 'tampered-request';
      source.add(_creationIntent(6, 'channel'));

      expect(record.intents, hasLength(4));
      expect(identical(first.request, request), isFalse);
      expect(identical(record.intents.first, first), isFalse);
      expect(
        (record.intents.first.request as ParticipantConversationCreationInput)
            .intendedMemberUserIds
            .map((member) => member.value),
        ['user-a', 'user-m', 'user-z'],
      );
      expect(record.intents.first.request.idempotencyKey, 'surviving-key');
      expect(record.intents.first.request.clientRequestId, 'surviving-request');
      expect(record.intents.first.enqueueOrder, 1);
      expect(record.intents.first.enqueuedAt.value, '2026-09-04T14:01:00.000Z');
      expect(() => record.intents.add(source.last), throwsUnsupportedError);
      expect(
        () => (record.intents.first.request
                as ParticipantConversationCreationInput)
            .intendedMemberUserIds
            .add(const UserId('user-new')),
        throwsUnsupportedError,
      );

      final entityIntent = _creationIntent(
        1,
        'channel',
        entityType: 'project',
        entityId: 'project-1',
      );
      final wire = entityIntent.toJson();
      final reparsed =
          ApplicationChatQueuedConversationCreationIntent.fromJson(wire);
      (wire['entity']! as Map<String, Object?>)['id'] = 'tampered-entity';
      expect(
        (reparsed.request as CreateChannelConversationInput).entity?.id,
        'project-1',
      );
    });

    test('creation queues reject duplicate correlations and FIFO drift', () {
      for (final intents
          in <List<ApplicationChatQueuedConversationCreationIntent>>[
        [_creationIntent(2, 'channel'), _creationIntent(1, 'direct')],
        [_creationIntent(1, 'channel'), _creationIntent(1, 'direct')],
        [
          _creationIntent(1, 'channel', idempotencyKey: 'duplicate-key'),
          _creationIntent(
            2,
            'direct',
            idempotencyKey: 'duplicate-key',
          ),
        ],
        [
          _creationIntent(1, 'channel', clientRequestId: 'duplicate-request'),
          _creationIntent(
            2,
            'direct',
            clientRequestId: 'duplicate-request',
          ),
        ],
      ]) {
        expect(
          () => ApplicationChatQueuedConversationCreationIntentsRecord(
            identity: _identity(),
            intents: intents,
          ),
          throwsArgumentError,
        );
      }
      expect(() => _creationIntent(0, 'channel'), throwsArgumentError);
      expect(
        () => _creationIntent(9007199254740992, 'channel'),
        throwsArgumentError,
      );
      for (final timestamp in const [
        '2026-09-04',
        '2026-02-30T14:00:00.000Z',
        '2026-09-04T24:00:00.000Z',
      ]) {
        expect(
          () => _creationIntent(
            1,
            'channel',
            enqueuedAt: IsoTimestamp(timestamp),
          ),
          throwsArgumentError,
          reason: timestamp,
        );
      }
    });

    test('creation parsing rejects generated-contract and version drift', () {
      final malformed = <Map<String, Object?>>[
        _creationIntent(1, 'channel').toJson()
          ..['operation'] = 'create_channel',
        _creationIntent(1, 'channel').toJson()..['type'] = 'thread',
        _creationIntent(1, 'channel').toJson()..['visibility'] = 'members',
        _creationIntent(1, 'channel').toJson()..remove('name'),
        _creationIntent(1, 'channel').toJson()..['unexpected'] = true,
        _creationIntent(1, 'direct').toJson()
          ..['intendedMemberUserIds'] = <Object?>[],
        _creationIntent(1, 'direct').toJson()
          ..['intendedMemberUserIds'] = ['one', 'two'],
        _creationIntent(1, 'group_direct').toJson()
          ..['intendedMemberUserIds'] = ['duplicate', 'duplicate'],
        _creationIntent(1, 'group_direct').toJson()
          ..['intendedMemberUserIds'] = ['valid', 2],
        _creationIntent(1, 'direct').toJson()..['name'] = 'not-allowed',
        _creationIntent(1, 'channel', entityType: 'project').toJson()
          ..['entity'] = {'type': 'project'},
      ];
      for (final json in malformed) {
        expect(
          () => ApplicationChatQueuedConversationCreationIntent.fromJson(json),
          throwsFormatException,
        );
      }

      final future = _creationRecord(_identity()).toJson();
      _creationWireIntents(future).single['contractVersion'] =
          applicationChatConversationCreationContractVersion + 1;
      expect(
        () => ApplicationChatStorageRecord.fromJson(future),
        throwsFormatException,
      );
    });

    test('creation parsing recursively rejects secrets and trusted fields', () {
      for (final field in const {
        'accessToken',
        'authorization',
        'credentials',
        'providerConfiguration',
        'requestBody',
        'tenantId',
        'userId',
        'actorRole',
        'initialChannelMembership',
      }) {
        final json = _creationIntent(1, 'channel').toJson()
          ..[field] = 'forbidden';
        expect(
          () => ApplicationChatQueuedConversationCreationIntent.fromJson(json),
          throwsFormatException,
          reason: field,
        );
      }
      final nestedSecret = _creationIntent(
        1,
        'channel',
        entityType: 'project',
        entityId: 'project-1',
      ).toJson();
      (nestedSecret['entity']! as Map<String, Object?>)['accessToken'] = 'bad';
      expect(
        () => ApplicationChatQueuedConversationCreationIntent.fromJson(
          nestedSecret,
        ),
        throwsFormatException,
      );
      final nestedTrusted = _deepJsonCopy(nestedSecret);
      final nestedEntity = nestedTrusted['entity']! as Map<String, Object?>
        ..remove('accessToken')
        ..['actorContext'] = 'bad';
      expect(nestedEntity, contains('actorContext'));
      expect(
        () => ApplicationChatQueuedConversationCreationIntent.fromJson(
          nestedTrusted,
        ),
        throwsFormatException,
      );
    });

    test('creation count, participant, and UTF-8 ceilings are enforced', () {
      final exactMembers = List.generate(
        maxApplicationChatConversationCreationMembers,
        (index) => 'member-$index',
      );
      expect(
        (_creationIntent(
          1,
          'group_direct',
          members: exactMembers,
        ).request as ParticipantConversationCreationInput)
            .intendedMemberUserIds,
        hasLength(maxApplicationChatConversationCreationMembers),
      );
      expect(
        () => _creationIntent(
          1,
          'group_direct',
          members: [...exactMembers, 'member-over-limit'],
        ),
        throwsArgumentError,
      );

      final exactAuthored = '\u{1f642}' * 1024;
      expect(utf8.encode(exactAuthored), hasLength(4096));
      expect(
        (_creationIntent(1, 'channel', name: exactAuthored).request
                as CreateChannelConversationInput)
            .name,
        exactAuthored,
      );
      expect(
        () => _creationIntent(1, 'channel', name: '$exactAuthored!'),
        throwsArgumentError,
      );
      final exactIdentifier = '\u{1f642}' * 128;
      expect(utf8.encode(exactIdentifier), hasLength(512));
      expect(
        _creationIntent(
          1,
          'direct',
          members: [exactIdentifier],
          idempotencyKey: exactIdentifier,
          clientRequestId: 'bounded-client-request',
        ),
        isNotNull,
      );
      expect(
        () => _creationIntent(
          1,
          'direct',
          members: ['$exactIdentifier!'],
        ),
        throwsArgumentError,
      );
      expect(
        () => _creationIntent(
          1,
          'channel',
          clientRequestId: '$exactIdentifier!',
        ),
        throwsArgumentError,
      );

      final tooMany = List.generate(
        maxApplicationChatQueuedConversationCreationIntents + 1,
        (index) => _creationIntent(
          index + 1,
          'channel',
          name: 'channel-$index',
        ),
      );
      expect(
        () => ApplicationChatQueuedConversationCreationIntentsRecord(
          identity: _identity(),
          intents: tooMany,
        ),
        throwsArgumentError,
      );

      final oversizedIntent = _creationIntent(1, 'channel').toJson()
        ..['name'] = '\u{1f642}' * 16385;
      expect(
        () => ApplicationChatQueuedConversationCreationIntent.fromJson(
          oversizedIntent,
        ),
        throwsA(
          isA<FormatException>().having(
            (error) => error.message,
            'message',
            contains('exceeds 65536 encoded bytes'),
          ),
        ),
      );

      final oversizedRecord = _creationRecord(_identity()).toJson();
      (oversizedRecord['payload']! as Map<String, Object?>)['intents'] =
          List.generate(
        100,
        (index) => <String, Object?>{
          ..._creationIntent(index + 1, 'channel').toJson(),
          'padding': '\u{1f642}' * 14000,
        },
      );
      final encoded = jsonEncode(oversizedRecord);
      expect(
        utf8.encode(encoded).length,
        greaterThan(maxApplicationChatStorageRecordBytes),
      );
      expect(
        () => ApplicationChatStorageRecord.decode(encoded),
        throwsFormatException,
      );
    });

    test('corrupt creation removal preserves every other scope and kind',
        () async {
      final storage = InMemoryApplicationChatStorage();
      final identity = _identity();
      final siblings = [
        _identity(tenant: 'other-tenant'),
        _identity(user: 'other-user'),
        _identity(device: 'other-device'),
      ];
      await _putAllKinds(storage, identity);
      for (final sibling in siblings) {
        await _putAllKinds(storage, sibling);
      }
      final corrupt = _creationRecord(identity).toJson();
      _creationWireIntents(corrupt).single['accessToken'] = 'must-not-persist';
      storage.putRawRecordForTesting(
        identity,
        ApplicationChatStorageRecordKind.queuedConversationCreationIntents,
        corrupt,
      );
      await expectLater(
        storage.read(
          identity,
          ApplicationChatStorageRecordKind.queuedConversationCreationIntents,
        ),
        throwsFormatException,
      );

      await storage.remove(
        identity,
        ApplicationChatStorageRecordKind.queuedConversationCreationIntents,
      );
      expect(
        await _recordCount(storage, identity),
        ApplicationChatStorageRecordKind.values.length - 1,
      );
      expect(
        await storage.read(
          identity,
          ApplicationChatStorageRecordKind.queuedConversationMembershipIntents,
        ),
        isNotNull,
      );
      for (final sibling in siblings) {
        expect(
          await _recordCount(storage, sibling),
          ApplicationChatStorageRecordKind.values.length,
        );
      }
    });

    test('preference variants round-trip exact requests and isolate identity',
        () async {
      final identity = _identity();
      final record = ApplicationChatQueuedConversationPreferenceIntentsRecord(
        identity: identity,
        intents: [
          _preferenceIntent(
            1,
            conversation: 'conversation-all',
            notification: 'all',
            starred: false,
            mute: const {'muted': false},
            expectedRevision: 0,
            idempotencyKey: 'preference-all-key',
          ),
          _preferenceIntent(
            2,
            conversation: 'conversation-mentions',
            notification: 'mentions',
            starred: true,
            mute: const {'muted': true},
            expectedRevision: 12,
            idempotencyKey: 'preference-mentions-key',
          ),
          _preferenceIntent(
            3,
            conversation: 'conversation-none',
            notification: 'none',
            starred: true,
            mute: const {
              'muted': true,
              'mutedUntil': '2030-02-03T04:05:06.000Z',
            },
            expectedRevision: 99,
            idempotencyKey: 'preference-none-key',
          ),
        ],
      );

      final decoded = ApplicationChatStorageRecord.decode(record.encode())
          as ApplicationChatQueuedConversationPreferenceIntentsRecord;
      expect(decoded.toJson(), record.toJson());
      expect(
        decoded.intents.map((intent) => intent.request.notificationPreference),
        ConversationNotificationPreference.values,
      );
      expect(decoded.intents[0].request.mute,
          isA<UnmutedConversationPreference>());
      expect(decoded.intents[1].request.mute,
          isA<IndefinitelyMutedConversationPreference>());
      expect(decoded.intents[2].request.mute,
          isA<MutedUntilConversationPreference>());
      expect(
        decoded.intents.map((intent) => intent.request.idempotencyKey),
        [
          'preference-all-key',
          'preference-mentions-key',
          'preference-none-key',
        ],
      );
      expect(
        decoded.intents
            .map((intent) => intent.request.expectedPreferenceRevision),
        [0, 12, 99],
      );
      expect(
        decoded.intents[2].request.mute.mutedUntil?.value,
        '2030-02-03T04:05:06.000Z',
      );

      final storage = InMemoryApplicationChatStorage();
      await storage.replace(record);
      for (final mismatch in [
        _identity(tenant: 'other-tenant'),
        _identity(user: 'other-user'),
        _identity(device: 'other-device'),
      ]) {
        expect(
          await storage.read(
            mismatch,
            ApplicationChatStorageRecordKind
                .queuedConversationPreferenceIntents,
          ),
          isNull,
        );
        final wrongIdentity = _deepJsonCopy(record.toJson())
          ..['identity'] = mismatch.toJson();
        storage.putRawRecordForTesting(
          identity,
          ApplicationChatStorageRecordKind.queuedConversationPreferenceIntents,
          wrongIdentity,
        );
        await expectLater(
          storage.read(
            identity,
            ApplicationChatStorageRecordKind
                .queuedConversationPreferenceIntents,
          ),
          throwsFormatException,
        );
      }
    });

    test('preference intents detach and coalesce by conversation lane', () {
      final requestJson = <String, Object?>{
        'operation': 'update_conversation_preference',
        'conversationId': 'conversation-a',
        'expectedPreferenceRevision': 1,
        'idempotencyKey': 'preference-original',
        'notificationPreference': 'all',
        'isStarred': false,
        'mute': <String, Object?>{'muted': false},
      };
      final request = UpdateConversationPreferenceInput.fromJson(requestJson);
      final first = ApplicationChatQueuedConversationPreferenceIntent(
        request: request,
        enqueueOrder: 1,
        enqueuedAt: const IsoTimestamp('2026-09-04T15:01:00.000Z'),
      );
      final source = [
        first,
        _preferenceIntent(
          2,
          conversation: 'conversation-b',
          notification: 'mentions',
          idempotencyKey: 'preference-b-original',
        ),
        _preferenceIntent(
          3,
          conversation: 'conversation-a',
          notification: 'none',
          starred: true,
          mute: const {'muted': true},
          expectedRevision: 7,
          idempotencyKey: 'preference-a-latest',
        ),
        _preferenceIntent(
          4,
          conversation: 'conversation-c',
          idempotencyKey: 'preference-c',
        ),
        _preferenceIntent(
          5,
          conversation: 'conversation-b',
          notification: 'all',
          starred: true,
          mute: const {
            'muted': true,
            'mutedUntil': '2031-01-02T03:04:05.000Z',
          },
          expectedRevision: 8,
          idempotencyKey: 'preference-b-latest',
        ),
      ];
      final record = ApplicationChatQueuedConversationPreferenceIntentsRecord(
        identity: _identity(),
        intents: source,
      );
      requestJson['conversationId'] = 'tampered';
      (requestJson['mute']! as Map<String, Object?>)['muted'] = true;
      source.add(_preferenceIntent(6, conversation: 'conversation-d'));

      expect(identical(first.request, request), isFalse);
      expect(identical(record.intents.first, first), isFalse);
      expect(identical(record.intents.first.request, first.request), isFalse);
      expect(() => record.intents.add(source.last), throwsUnsupportedError);
      expect(
        record.intents
            .map(
              (intent) => (
                intent.request.conversationId.value,
                intent.enqueueOrder,
                intent.enqueuedAt.value,
                intent.request.idempotencyKey,
                intent.request.expectedPreferenceRevision,
              ),
            )
            .toList(),
        [
          (
            'conversation-a',
            1,
            '2026-09-04T15:01:00.000Z',
            'preference-a-latest',
            7,
          ),
          (
            'conversation-b',
            2,
            '2026-09-04T15:02:00.000Z',
            'preference-b-latest',
            8,
          ),
          (
            'conversation-c',
            4,
            '2026-09-04T15:04:00.000Z',
            'preference-c',
            1,
          ),
        ],
      );
      expect(record.intents.first.request.notificationPreference,
          ConversationNotificationPreference.none);
      expect(record.intents.first.request.isStarred, isTrue);
      expect(record.intents.first.request.mute,
          isA<IndefinitelyMutedConversationPreference>());

      final wire = record.intents[1].toJson();
      final reparsed =
          ApplicationChatQueuedConversationPreferenceIntent.fromJson(wire);
      (wire['mute']! as Map<String, Object?>)['mutedUntil'] =
          '2040-01-01T00:00:00.000Z';
      expect(
        reparsed.request.mute.mutedUntil?.value,
        '2031-01-02T03:04:05.000Z',
      );
    });

    test('preference queues reject duplicate correlations and FIFO drift', () {
      for (final intents
          in <List<ApplicationChatQueuedConversationPreferenceIntent>>[
        [_preferenceIntent(2), _preferenceIntent(1)],
        [_preferenceIntent(1), _preferenceIntent(1, conversation: 'other')],
        [
          _preferenceIntent(1, idempotencyKey: 'duplicate-key'),
          _preferenceIntent(
            2,
            conversation: 'other',
            idempotencyKey: 'duplicate-key',
          ),
        ],
      ]) {
        expect(
          () => ApplicationChatQueuedConversationPreferenceIntentsRecord(
            identity: _identity(),
            intents: intents,
          ),
          throwsArgumentError,
        );
      }
      expect(() => _preferenceIntent(0), throwsArgumentError);
      expect(
        () => _preferenceIntent(9007199254740992),
        throwsArgumentError,
      );
      for (final timestamp in const [
        '2026-09-04',
        '2026-02-30T15:00:00.000Z',
        '2026-09-04T24:00:00.000Z',
      ]) {
        expect(
          () => _preferenceIntent(
            1,
            enqueuedAt: IsoTimestamp(timestamp),
          ),
          throwsArgumentError,
          reason: timestamp,
        );
      }
    });

    test('preference parsing rejects malformed shapes, revisions, and times',
        () {
      final malformed = <Map<String, Object?>>[
        _preferenceIntent(1).toJson()
          ..['operation'] = 'toggle_conversation_preference',
        _preferenceIntent(1).toJson()..['notificationPreference'] = 'urgent',
        _preferenceIntent(1).toJson()..['isStarred'] = 1,
        _preferenceIntent(1).toJson()
          ..['mute'] = <String, Object?>{'muted': false, 'mutedUntil': null},
        _preferenceIntent(1).toJson()
          ..['mute'] = <String, Object?>{'muted': true, 'mutedUntil': null},
        _preferenceIntent(1).toJson()..['expectedPreferenceRevision'] = -1,
        _preferenceIntent(1).toJson()
          ..['expectedPreferenceRevision'] = 9007199254740991,
        _preferenceIntent(1).toJson()..remove('idempotencyKey'),
        _preferenceIntent(1).toJson()..['unexpected'] = true,
        _preferenceIntent(1).toJson()
          ..['enqueuedAt'] = '2026-02-30T15:00:00.000Z',
      ];
      for (final json in malformed) {
        expect(
          () => ApplicationChatQueuedConversationPreferenceIntent.fromJson(
            json,
          ),
          throwsFormatException,
        );
      }

      final longTimestamp = '2030-01-02T03:04:05.${'1' * 70}Z';
      final longMute = _preferenceIntent(1).toJson()
        ..['mute'] = <String, Object?>{
          'muted': true,
          'mutedUntil': longTimestamp,
        };
      expect(
        () => ApplicationChatQueuedConversationPreferenceIntent.fromJson(
          longMute,
        ),
        throwsFormatException,
      );

      final future = _preferenceRecord(_identity()).toJson();
      _preferenceWireIntents(future).single['contractVersion'] =
          applicationChatConversationPreferenceContractVersion + 1;
      expect(
        () => ApplicationChatStorageRecord.fromJson(future),
        throwsFormatException,
      );
    });

    test('preference parsing rejects secret, provider, and trusted fields', () {
      for (final field in const {
        'accessToken',
        'authorization',
        'credentials',
        'providerConfiguration',
        'requestBody',
        'tenantId',
        'userId',
        'actorRole',
      }) {
        final json = _preferenceIntent(1).toJson()..[field] = 'forbidden';
        expect(
          () => ApplicationChatQueuedConversationPreferenceIntent.fromJson(
            json,
          ),
          throwsFormatException,
          reason: field,
        );
      }
      final nested = _deepJsonCopy(_preferenceIntent(1).toJson());
      (nested['mute']! as Map<String, Object?>)['providerDescriptor'] = 'bad';
      expect(
        () => ApplicationChatQueuedConversationPreferenceIntent.fromJson(
          nested,
        ),
        throwsFormatException,
      );
    });

    test('preference count and multibyte UTF-8 ceilings are enforced', () {
      final exactIdentifier = '${'\u{1f642}' * 63}abc';
      expect(utf8.encode(exactIdentifier), hasLength(255));
      expect(
        _preferenceIntent(
          1,
          conversation: exactIdentifier,
          idempotencyKey: exactIdentifier,
        ),
        isNotNull,
      );
      final oversizedIdentifier = '$exactIdentifier!';
      expect(utf8.encode(oversizedIdentifier), hasLength(256));
      expect(
        () => _preferenceIntent(1, conversation: oversizedIdentifier),
        throwsA(isA<ConversationPreferenceFormatException>()),
      );
      expect(
        () => _preferenceIntent(1, idempotencyKey: oversizedIdentifier),
        throwsA(isA<ConversationPreferenceFormatException>()),
      );

      final tooMany = List.generate(
        maxApplicationChatQueuedConversationPreferenceIntents + 1,
        (index) => _preferenceIntent(
          index + 1,
          conversation: 'conversation-$index',
        ),
      );
      expect(
        () => ApplicationChatQueuedConversationPreferenceIntentsRecord(
          identity: _identity(),
          intents: tooMany,
        ),
        throwsArgumentError,
      );

      final oversizedIntent = _preferenceIntent(1).toJson()
        ..['padding'] = '\u{1f642}' * 4097;
      expect(
        utf8.encode(jsonEncode(oversizedIntent)).length,
        greaterThan(maxApplicationChatQueuedConversationPreferenceIntentBytes),
      );
      expect(
        () => ApplicationChatQueuedConversationPreferenceIntent.fromJson(
          oversizedIntent,
        ),
        throwsA(
          isA<FormatException>().having(
            (error) => error.message,
            'message',
            contains('exceeds 16384 encoded bytes'),
          ),
        ),
      );
    });

    test('corrupt preference removal preserves every other scope and kind',
        () async {
      final storage = InMemoryApplicationChatStorage();
      final identity = _identity();
      final siblings = [
        _identity(tenant: 'other-tenant'),
        _identity(user: 'other-user'),
        _identity(device: 'other-device'),
      ];
      await _putAllKinds(storage, identity);
      for (final sibling in siblings) {
        await _putAllKinds(storage, sibling);
      }
      final corrupt = _preferenceRecord(identity).toJson();
      _preferenceWireIntents(corrupt).single['providerConfiguration'] =
          'must-not-persist';
      storage.putRawRecordForTesting(
        identity,
        ApplicationChatStorageRecordKind.queuedConversationPreferenceIntents,
        corrupt,
      );
      await expectLater(
        storage.read(
          identity,
          ApplicationChatStorageRecordKind.queuedConversationPreferenceIntents,
        ),
        throwsFormatException,
      );

      await storage.remove(
        identity,
        ApplicationChatStorageRecordKind.queuedConversationPreferenceIntents,
      );
      expect(
        await _recordCount(storage, identity),
        ApplicationChatStorageRecordKind.values.length - 1,
      );
      expect(
        await storage.read(
          identity,
          ApplicationChatStorageRecordKind.queuedConversationCreationIntents,
        ),
        isNotNull,
      );
      for (final sibling in siblings) {
        expect(
          await _recordCount(storage, sibling),
          ApplicationChatStorageRecordKind.values.length,
        );
      }
    });

    test('thread-follow follow and unfollow requests round-trip exactly',
        () async {
      final identity = _identity();
      final record = ApplicationChatQueuedThreadFollowIntentsRecord(
        identity: identity,
        intents: [
          _threadFollowIntent(
            1,
            thread: 'thread-followed',
            intent: 'follow',
            expectedRevision: 12,
            idempotencyKey: 'thread-follow-exact-key',
          ),
          _threadFollowIntent(
            2,
            thread: 'thread-unfollowed',
            intent: 'unfollow',
            expectedRevision: 900,
            idempotencyKey: 'thread-unfollow-exact-key',
            enqueuedAt: const IsoTimestamp('2026-09-04T16:02:03.456-05:00'),
          ),
        ],
      );

      expect(record.toJson(), <String, Object?>{
        'schemaVersion': applicationChatStorageSchemaVersion,
        'kind': 'queued_thread_follow_intents',
        'identity': identity.toJson(),
        'payload': <String, Object?>{
          'intents': <Object?>[
            <String, Object?>{
              'contractVersion': applicationChatThreadFollowContractVersion,
              'enqueueOrder': 1,
              'enqueuedAt': '2026-09-04T16:01:00.000Z',
              'operation': 'set_thread_follow',
              'intent': 'follow',
              'target': <String, Object?>{
                'type': 'thread',
                'id': 'thread-followed',
              },
              'expectedFollowRevision': 12,
              'idempotencyKey': 'thread-follow-exact-key',
            },
            <String, Object?>{
              'contractVersion': applicationChatThreadFollowContractVersion,
              'enqueueOrder': 2,
              'enqueuedAt': '2026-09-04T16:02:03.456-05:00',
              'operation': 'set_thread_follow',
              'intent': 'unfollow',
              'target': <String, Object?>{
                'type': 'thread',
                'id': 'thread-unfollowed',
              },
              'expectedFollowRevision': 900,
              'idempotencyKey': 'thread-unfollow-exact-key',
            },
          ],
        },
      });
      final decoded = ApplicationChatStorageRecord.decode(record.encode())
          as ApplicationChatQueuedThreadFollowIntentsRecord;
      expect(decoded.toJson(), record.toJson());
      expect(decoded.intents.first.request, isA<FollowThreadInput>());
      expect(decoded.intents.last.request, isA<UnfollowThreadInput>());
      expect(
        decoded.intents.map((value) => value.request.expectedFollowRevision),
        [12, 900],
      );
      expect(
        decoded.intents.map((value) => value.request.idempotencyKey),
        ['thread-follow-exact-key', 'thread-unfollow-exact-key'],
      );

      final storage = InMemoryApplicationChatStorage();
      await storage.replace(record);
      expect(
        (await storage.read(
          identity,
          ApplicationChatStorageRecordKind.queuedThreadFollowIntents,
        ))
            ?.toJson(),
        record.toJson(),
      );
      for (final mismatch in [
        _identity(tenant: 'other-tenant'),
        _identity(user: 'other-user'),
        _identity(device: 'other-device'),
      ]) {
        expect(
          await storage.read(
            mismatch,
            ApplicationChatStorageRecordKind.queuedThreadFollowIntents,
          ),
          isNull,
        );
        final wrongIdentity = _deepJsonCopy(record.toJson())
          ..['identity'] = mismatch.toJson();
        storage.putRawRecordForTesting(
          identity,
          ApplicationChatStorageRecordKind.queuedThreadFollowIntents,
          wrongIdentity,
        );
        await expectLater(
          storage.read(
            identity,
            ApplicationChatStorageRecordKind.queuedThreadFollowIntents,
          ),
          throwsFormatException,
        );
      }
    });

    test('thread-follow construction detaches and coalesces by thread lane',
        () {
      final requestJson = <String, Object?>{
        'operation': 'set_thread_follow',
        'intent': 'follow',
        'target': <String, Object?>{'type': 'thread', 'id': 'thread-a'},
        'expectedFollowRevision': 1,
        'idempotencyKey': 'thread-a-first',
      };
      final request = SetThreadFollowInput.fromJson(requestJson);
      final first = ApplicationChatQueuedThreadFollowIntent(
        request: request,
        enqueueOrder: 1,
        enqueuedAt: const IsoTimestamp('2026-09-04T16:01:00.000Z'),
      );
      final source = [
        first,
        _threadFollowIntent(
          2,
          thread: 'thread-b',
          intent: 'unfollow',
          idempotencyKey: 'thread-b-only',
        ),
        _threadFollowIntent(
          3,
          thread: 'thread-a',
          intent: 'unfollow',
          expectedRevision: 7,
          idempotencyKey: 'thread-a-latest',
          enqueuedAt: const IsoTimestamp('2026-09-04T16:03:00.999Z'),
        ),
        _threadFollowIntent(4, thread: 'thread-c'),
      ];
      final record = ApplicationChatQueuedThreadFollowIntentsRecord(
        identity: _identity(),
        intents: source,
      );
      (requestJson['target']! as Map<String, Object?>)['id'] = 'tampered';
      requestJson['idempotencyKey'] = 'tampered';
      source.add(_threadFollowIntent(5, thread: 'thread-d'));

      expect(identical(first.request, request), isFalse);
      expect(identical(record.intents.first, first), isFalse);
      expect(identical(record.intents.first.request, first.request), isFalse);
      expect(() => record.intents.add(source.last), throwsUnsupportedError);
      expect(
        record.intents
            .map(
              (value) => (
                value.enqueueOrder,
                value.enqueuedAt.value,
                value.request.target.id.value,
                value.request.intent,
                value.request.expectedFollowRevision,
                value.request.idempotencyKey,
              ),
            )
            .toList(),
        [
          (
            1,
            '2026-09-04T16:01:00.000Z',
            'thread-a',
            ThreadFollowMutationIntent.unfollow,
            7,
            'thread-a-latest',
          ),
          (
            2,
            '2026-09-04T16:02:00.000Z',
            'thread-b',
            ThreadFollowMutationIntent.unfollow,
            1,
            'thread-b-only',
          ),
          (
            4,
            '2026-09-04T16:04:00.000Z',
            'thread-c',
            ThreadFollowMutationIntent.follow,
            1,
            'thread-follow-key-4',
          ),
        ],
      );

      final wire = record.intents.first.toJson();
      final reparsed = ApplicationChatQueuedThreadFollowIntent.fromJson(wire);
      (wire['target']! as Map<String, Object?>)['id'] = 'wire-tampered';
      expect(reparsed.request.target.id.value, 'thread-a');
    });

    test('thread-follow queues reject duplicate correlations and FIFO drift',
        () {
      for (final intents in <List<ApplicationChatQueuedThreadFollowIntent>>[
        [_threadFollowIntent(2), _threadFollowIntent(1, thread: 'thread-2')],
        [_threadFollowIntent(1), _threadFollowIntent(1, thread: 'thread-2')],
        [
          _threadFollowIntent(1, idempotencyKey: 'duplicate-key'),
          _threadFollowIntent(
            2,
            thread: 'thread-2',
            idempotencyKey: 'duplicate-key',
          ),
        ],
      ]) {
        expect(
          () => ApplicationChatQueuedThreadFollowIntentsRecord(
            identity: _identity(),
            intents: intents,
          ),
          throwsArgumentError,
        );
      }
      expect(() => _threadFollowIntent(0), throwsArgumentError);
      expect(
        () => _threadFollowIntent(9007199254740992),
        throwsArgumentError,
      );
      for (final timestamp in const [
        '2026-09-04',
        '2026-02-30T16:00:00.000Z',
        '2026-09-04T24:00:00.000Z',
      ]) {
        expect(
          () => _threadFollowIntent(
            1,
            enqueuedAt: IsoTimestamp(timestamp),
          ),
          throwsArgumentError,
          reason: timestamp,
        );
      }
    });

    test('thread-follow parsing rejects malformed contracts and unsafe data',
        () {
      final valid = _threadFollowIntent(1).toJson();
      final malformed = <Map<String, Object?>>[
        _deepJsonCopy(valid)..['operation'] = 'toggle_thread_follow',
        _deepJsonCopy(valid)..['intent'] = 'toggle',
        _deepJsonCopy(valid)
          ..['target'] = <String, Object?>{
            'type': 'channel',
            'id': 'channel-1',
          },
        _deepJsonCopy(valid)
          ..['target'] = <String, Object?>{
            'type': 'thread',
            'id': 'thread-1',
            'unexpected': true,
          },
        _deepJsonCopy(valid)..['expectedFollowRevision'] = -1,
        _deepJsonCopy(valid)..['expectedFollowRevision'] = 1.5,
        _deepJsonCopy(valid)..['expectedFollowRevision'] = 9007199254740991,
        _deepJsonCopy(valid)..['enqueueOrder'] = 0,
        _deepJsonCopy(valid)..['enqueueOrder'] = 1.5,
        _deepJsonCopy(valid)..['enqueuedAt'] = '2026-02-30T16:00:00.000Z',
        _deepJsonCopy(valid)
          ..['contractVersion'] =
              applicationChatThreadFollowContractVersion + 1,
        _deepJsonCopy(valid)..remove('idempotencyKey'),
        _deepJsonCopy(valid)..['unexpected'] = true,
        _deepJsonCopy(valid)..['accessToken'] = 'must-not-persist',
        _deepJsonCopy(valid)
          ..['providerConfiguration'] = <String, Object?>{'opaque': true},
        _deepJsonCopy(valid)
          ..['diagnostics'] = <String, Object?>{'stack': 'raw'},
        _deepJsonCopy(valid)..['tenantId'] = 'tenant-injected',
        _deepJsonCopy(valid)..['currentUserId'] = 'user-injected',
        _deepJsonCopy(valid)..['payload'] = <int>[0, 1, 2, 255],
      ];
      for (final json in malformed) {
        expect(
          () => ApplicationChatQueuedThreadFollowIntent.fromJson(json),
          throwsFormatException,
        );
      }

      final longTimestamp = '2030-01-02T03:04:05.${'1' * 70}Z';
      expect(
        () => ApplicationChatQueuedThreadFollowIntent.fromJson(
          _deepJsonCopy(valid)..['enqueuedAt'] = longTimestamp,
        ),
        throwsFormatException,
      );
      final openEnvelope = _threadFollowRecord(_identity()).toJson();
      (openEnvelope['payload']! as Map<String, Object?>)['unexpected'] = true;
      expect(
        () => ApplicationChatStorageRecord.fromJson(openEnvelope),
        throwsFormatException,
      );
    });

    test('thread-follow count and multibyte UTF-8 ceilings are enforced', () {
      final exactIdentifier = '${'\u{1f642}' * 63}abc';
      expect(utf8.encode(exactIdentifier), hasLength(255));
      expect(
        _threadFollowIntent(
          1,
          thread: exactIdentifier,
          idempotencyKey: exactIdentifier,
        ),
        isNotNull,
      );
      final oversizedIdentifier = '$exactIdentifier!';
      expect(utf8.encode(oversizedIdentifier), hasLength(256));
      expect(
        () => _threadFollowIntent(1, thread: oversizedIdentifier),
        throwsA(isA<ThreadFollowMutationFormatException>()),
      );
      expect(
        () => _threadFollowIntent(1, idempotencyKey: oversizedIdentifier),
        throwsA(isA<ThreadFollowMutationFormatException>()),
      );

      final tooMany = List.generate(
        maxApplicationChatQueuedThreadFollowIntents + 1,
        (index) => _threadFollowIntent(
          index + 1,
          thread: 'thread-$index',
        ),
      );
      expect(
        () => ApplicationChatQueuedThreadFollowIntentsRecord(
          identity: _identity(),
          intents: tooMany,
        ),
        throwsArgumentError,
      );

      final oversizedIntent = _threadFollowIntent(1).toJson()
        ..['padding'] = '\u{1f642}' * 4097;
      expect(
        utf8.encode(jsonEncode(oversizedIntent)).length,
        greaterThan(maxApplicationChatQueuedThreadFollowIntentBytes),
      );
      expect(
        () => ApplicationChatQueuedThreadFollowIntent.fromJson(
          oversizedIntent,
        ),
        throwsA(
          isA<FormatException>().having(
            (error) => error.message,
            'message',
            contains('exceeds 16384 encoded bytes'),
          ),
        ),
      );
      expect(
        utf8.encode(_threadFollowRecord(_identity()).encode()).length,
        lessThanOrEqualTo(maxApplicationChatStorageRecordBytes),
      );
    });

    test('corrupt thread-follow removal preserves every other scope and kind',
        () async {
      final storage = InMemoryApplicationChatStorage();
      final identity = _identity();
      final siblings = [
        _identity(tenant: 'other-tenant'),
        _identity(user: 'other-user'),
        _identity(device: 'other-device'),
      ];
      await _putAllKinds(storage, identity);
      for (final sibling in siblings) {
        await _putAllKinds(storage, sibling);
      }
      final corrupt = _threadFollowRecord(identity).toJson();
      _threadFollowWireIntents(corrupt).single['providerConfiguration'] =
          'must-not-persist';
      storage.putRawRecordForTesting(
        identity,
        ApplicationChatStorageRecordKind.queuedThreadFollowIntents,
        corrupt,
      );
      await expectLater(
        storage.read(
          identity,
          ApplicationChatStorageRecordKind.queuedThreadFollowIntents,
        ),
        throwsFormatException,
      );

      await storage.remove(
        identity,
        ApplicationChatStorageRecordKind.queuedThreadFollowIntents,
      );
      expect(
        await _recordCount(storage, identity),
        ApplicationChatStorageRecordKind.values.length - 1,
      );
      for (final kind in ApplicationChatStorageRecordKind.values) {
        expect(
          await storage.read(identity, kind),
          kind == ApplicationChatStorageRecordKind.queuedThreadFollowIntents
              ? isNull
              : isNotNull,
        );
      }
      for (final sibling in siblings) {
        expect(
          await _recordCount(storage, sibling),
          ApplicationChatStorageRecordKind.values.length,
        );
        for (final kind in ApplicationChatStorageRecordKind.values) {
          expect(await storage.read(sibling, kind), isNotNull);
        }
      }
    });

    test('message-reminder set, reschedule, and cancel round-trip exactly',
        () async {
      final identity = _identity();
      final record = ApplicationChatQueuedMessageReminderIntentsRecord(
        identity: identity,
        intents: [
          _messageReminderIntent(
            1,
            message: 'message-set',
            expectedRevision: 12,
            idempotencyKey: 'reminder-set-exact-key',
            dueAt: '2035-01-02T03:04:05.678Z',
          ),
          _messageReminderIntent(
            2,
            message: 'message-rescheduled',
            expectedRevision: 900,
            idempotencyKey: 'reminder-reschedule-exact-key',
            dueAt: '2036-02-03T04:05:06.789-05:00',
          ),
          _messageReminderIntent(
            3,
            message: 'message-cancelled',
            intent: 'cancel',
            expectedRevision: 4,
            idempotencyKey: 'reminder-cancel-exact-key',
          ),
        ],
      );

      expect(record.kind.wireValue, 'queued_message_reminder_intents');
      final decoded = ApplicationChatStorageRecord.decode(record.encode())
          as ApplicationChatQueuedMessageReminderIntentsRecord;
      expect(decoded.toJson(), record.toJson());
      expect(decoded.intents[0].request, isA<SetMessageReminderRequest>());
      expect(decoded.intents[1].request, isA<SetMessageReminderRequest>());
      expect(decoded.intents[2].request, isA<CancelMessageReminderRequest>());
      expect(
        decoded.intents.map((value) => value.request.expectedReminderRevision),
        [12, 900, 4],
      );
      expect(
        decoded.intents.map((value) => value.request.idempotencyKey),
        [
          'reminder-set-exact-key',
          'reminder-reschedule-exact-key',
          'reminder-cancel-exact-key',
        ],
      );
      expect(
        (decoded.intents[1].request as SetMessageReminderRequest).dueAt.value,
        '2036-02-03T04:05:06.789-05:00',
      );
      expect(decoded.intents[2].toJson(), isNot(contains('dueAt')));

      final storage = InMemoryApplicationChatStorage();
      await storage.replace(record);
      for (final mismatch in [
        _identity(tenant: 'other-tenant'),
        _identity(user: 'other-user'),
        _identity(device: 'other-device'),
      ]) {
        expect(
          await storage.read(
            mismatch,
            ApplicationChatStorageRecordKind.queuedMessageReminderIntents,
          ),
          isNull,
        );
        final wrongIdentity = _deepJsonCopy(record.toJson())
          ..['identity'] = mismatch.toJson();
        storage.putRawRecordForTesting(
          identity,
          ApplicationChatStorageRecordKind.queuedMessageReminderIntents,
          wrongIdentity,
        );
        await expectLater(
          storage.read(
            identity,
            ApplicationChatStorageRecordKind.queuedMessageReminderIntents,
          ),
          throwsFormatException,
        );
      }
    });

    test('message-reminder construction detaches and coalesces by message', () {
      final requestJson = <String, Object?>{
        'operation': 'message_reminder.v1',
        'intent': 'set',
        'conversationId': 'conversation-a',
        'messageId': 'message-a',
        'expectedReminderRevision': 1,
        'idempotencyKey': 'reminder-a-first',
        'dueAt': '2035-01-02T03:04:05.000Z',
      };
      final request = MessageReminderRequest.fromJson(
        requestJson,
        referenceTime: DateTime.fromMillisecondsSinceEpoch(0, isUtc: true),
      );
      final first = ApplicationChatQueuedMessageReminderIntent(
        request: request,
        enqueueOrder: 1,
        enqueuedAt: const IsoTimestamp('2026-09-04T17:01:00.000Z'),
      );
      final source = [
        first,
        _messageReminderIntent(
          2,
          message: 'message-b',
          intent: 'cancel',
          idempotencyKey: 'reminder-b-only',
        ),
        _messageReminderIntent(
          3,
          message: 'message-a',
          expectedRevision: 7,
          idempotencyKey: 'reminder-a-latest',
          dueAt: '2037-07-08T09:10:11.999Z',
          enqueuedAt: const IsoTimestamp('2026-09-04T17:03:00.999Z'),
        ),
        _messageReminderIntent(4, message: 'message-c'),
      ];
      final record = ApplicationChatQueuedMessageReminderIntentsRecord(
        identity: _identity(),
        intents: source,
      );
      requestJson['messageId'] = 'tampered';
      requestJson['idempotencyKey'] = 'tampered';
      source.add(_messageReminderIntent(5, message: 'message-d'));

      expect(identical(first.request, request), isFalse);
      expect(identical(record.intents.first, first), isFalse);
      expect(identical(record.intents.first.request, first.request), isFalse);
      expect(() => record.intents.add(source.last), throwsUnsupportedError);
      expect(
        record.intents
            .map(
              (value) => (
                value.enqueueOrder,
                value.enqueuedAt.value,
                value.request.messageId.value,
                value.request.intent,
                value.request.expectedReminderRevision,
                value.request.idempotencyKey,
                value.request is SetMessageReminderRequest
                    ? (value.request as SetMessageReminderRequest).dueAt.value
                    : null,
              ),
            )
            .toList(),
        [
          (
            1,
            '2026-09-04T17:01:00.000Z',
            'message-a',
            MessageReminderIntent.set,
            7,
            'reminder-a-latest',
            '2037-07-08T09:10:11.999Z',
          ),
          (
            2,
            '2026-09-04T17:02:00.000Z',
            'message-b',
            MessageReminderIntent.cancel,
            1,
            'reminder-b-only',
            null,
          ),
          (
            4,
            '2026-09-04T17:04:00.000Z',
            'message-c',
            MessageReminderIntent.set,
            1,
            'message-reminder-key-4',
            '2035-01-02T03:04:05.000Z',
          ),
        ],
      );

      final wire = record.intents.first.toJson();
      final reparsed =
          ApplicationChatQueuedMessageReminderIntent.fromJson(wire);
      wire['messageId'] = 'wire-tampered';
      expect(reparsed.request.messageId.value, 'message-a');
    });

    test('message-reminder queues reject duplicate correlations and FIFO drift',
        () {
      for (final intents in <List<ApplicationChatQueuedMessageReminderIntent>>[
        [
          _messageReminderIntent(2),
          _messageReminderIntent(1, message: 'message-2'),
        ],
        [
          _messageReminderIntent(1),
          _messageReminderIntent(1, message: 'message-2'),
        ],
        [
          _messageReminderIntent(1, idempotencyKey: 'duplicate-key'),
          _messageReminderIntent(
            2,
            message: 'message-2',
            idempotencyKey: 'duplicate-key',
          ),
        ],
      ]) {
        expect(
          () => ApplicationChatQueuedMessageReminderIntentsRecord(
            identity: _identity(),
            intents: intents,
          ),
          throwsArgumentError,
        );
      }
      expect(() => _messageReminderIntent(0), throwsArgumentError);
      expect(
        () => _messageReminderIntent(9007199254740992),
        throwsArgumentError,
      );
      for (final timestamp in const [
        '2026-09-04',
        '2026-02-30T17:00:00.000Z',
        '2026-09-04T24:00:00.000Z',
      ]) {
        expect(
          () => _messageReminderIntent(
            1,
            enqueuedAt: IsoTimestamp(timestamp),
          ),
          throwsArgumentError,
          reason: timestamp,
        );
      }
    });

    test('message-reminder parsing rejects malformed and unsafe data', () {
      final validSet = _messageReminderIntent(1).toJson();
      final validCancel = _messageReminderIntent(1, intent: 'cancel').toJson();
      final malformed = <Map<String, Object?>>[
        _deepJsonCopy(validSet)..['operation'] = 'toggle_message_reminder',
        _deepJsonCopy(validSet)..['intent'] = 'toggle',
        _deepJsonCopy(validSet)..remove('dueAt'),
        _deepJsonCopy(validCancel)..['dueAt'] = '2035-01-02T03:04:05.000Z',
        _deepJsonCopy(validSet)..['expectedReminderRevision'] = -1,
        _deepJsonCopy(validSet)..['expectedReminderRevision'] = 1.5,
        _deepJsonCopy(validSet)
          ..['expectedReminderRevision'] = 9007199254740991,
        _deepJsonCopy(validSet)..['enqueueOrder'] = 0,
        _deepJsonCopy(validSet)..['enqueueOrder'] = 1.5,
        _deepJsonCopy(validSet)..['enqueuedAt'] = '2026-02-30T17:00:00.000Z',
        _deepJsonCopy(validSet)..['dueAt'] = '1969-12-31T23:59:59.000Z',
        _deepJsonCopy(validSet)..['dueAt'] = '2035-02-30T03:04:05.000Z',
        _deepJsonCopy(validSet)
          ..['contractVersion'] =
              applicationChatMessageReminderContractVersion + 1,
        _deepJsonCopy(validSet)..remove('idempotencyKey'),
        _deepJsonCopy(validSet)..['unexpected'] = true,
        _deepJsonCopy(validSet)..['accessToken'] = 'must-not-persist',
        _deepJsonCopy(validSet)
          ..['providerConfiguration'] = <String, Object?>{'opaque': true},
        _deepJsonCopy(validSet)
          ..['diagnostics'] = <String, Object?>{'stack': 'raw'},
        _deepJsonCopy(validSet)..['tenantId'] = 'tenant-injected',
        _deepJsonCopy(validSet)..['currentUserId'] = 'user-injected',
        _deepJsonCopy(validSet)..['payload'] = <int>[0, 1, 2, 255],
      ];
      for (final json in malformed) {
        expect(
          () => ApplicationChatQueuedMessageReminderIntent.fromJson(json),
          throwsFormatException,
        );
      }

      final longDueAt = '2035-01-02T03:04:05.${'1' * 70}Z';
      expect(
        () => ApplicationChatQueuedMessageReminderIntent.fromJson(
          _deepJsonCopy(validSet)..['dueAt'] = longDueAt,
        ),
        throwsFormatException,
      );
      final openEnvelope = _messageReminderRecord(_identity()).toJson();
      (openEnvelope['payload']! as Map<String, Object?>)['unexpected'] = true;
      expect(
        () => ApplicationChatStorageRecord.fromJson(openEnvelope),
        throwsFormatException,
      );
    });

    test('message-reminder count and UTF-8 ceilings are enforced', () {
      final exactIdentifier = '${'\u{1f642}' * 63}abc';
      expect(utf8.encode(exactIdentifier), hasLength(255));
      expect(
        _messageReminderIntent(
          1,
          conversation: exactIdentifier,
          message: exactIdentifier,
          idempotencyKey: exactIdentifier,
        ),
        isNotNull,
      );
      final oversizedIdentifier = '$exactIdentifier!';
      expect(utf8.encode(oversizedIdentifier), hasLength(256));
      for (final request in [
        () => _messageReminderIntent(1, conversation: oversizedIdentifier),
        () => _messageReminderIntent(1, message: oversizedIdentifier),
        () => _messageReminderIntent(1, idempotencyKey: oversizedIdentifier),
      ]) {
        expect(request, throwsA(isA<MessageReminderFormatException>()));
      }

      final tooMany = List.generate(
        maxApplicationChatQueuedMessageReminderIntents + 1,
        (index) => _messageReminderIntent(
          index + 1,
          message: 'message-$index',
        ),
      );
      expect(
        () => ApplicationChatQueuedMessageReminderIntentsRecord(
          identity: _identity(),
          intents: tooMany,
        ),
        throwsArgumentError,
      );

      final oversizedIntent = _messageReminderIntent(1).toJson()
        ..['padding'] = '\u{1f642}' * 4097;
      expect(
        utf8.encode(jsonEncode(oversizedIntent)).length,
        greaterThan(maxApplicationChatQueuedMessageReminderIntentBytes),
      );
      expect(
        () => ApplicationChatQueuedMessageReminderIntent.fromJson(
          oversizedIntent,
        ),
        throwsA(
          isA<FormatException>().having(
            (error) => error.message,
            'message',
            contains('exceeds 16384 encoded bytes'),
          ),
        ),
      );

      final encoded = _messageReminderRecord(_identity()).encode();
      expect(
        () => ApplicationChatStorageRecord.decode(
          '$encoded${' ' * maxApplicationChatStorageRecordBytes}',
        ),
        throwsA(
          isA<FormatException>().having(
            (error) => error.message,
            'message',
            contains('exceeds 5242880 encoded bytes'),
          ),
        ),
      );
    });

    test('corrupt reminder removal preserves every other scope and kind',
        () async {
      final storage = InMemoryApplicationChatStorage();
      final identity = _identity();
      final siblings = [
        _identity(tenant: 'other-tenant'),
        _identity(user: 'other-user'),
        _identity(device: 'other-device'),
      ];
      await _putAllKinds(storage, identity);
      for (final sibling in siblings) {
        await _putAllKinds(storage, sibling);
      }
      final corrupt = _messageReminderRecord(identity).toJson();
      _messageReminderWireIntents(corrupt).single['providerConfiguration'] =
          'must-not-persist';
      storage.putRawRecordForTesting(
        identity,
        ApplicationChatStorageRecordKind.queuedMessageReminderIntents,
        corrupt,
      );
      await expectLater(
        storage.read(
          identity,
          ApplicationChatStorageRecordKind.queuedMessageReminderIntents,
        ),
        throwsFormatException,
      );

      await storage.remove(
        identity,
        ApplicationChatStorageRecordKind.queuedMessageReminderIntents,
      );
      expect(
        await _recordCount(storage, identity),
        ApplicationChatStorageRecordKind.values.length - 1,
      );
      for (final kind in ApplicationChatStorageRecordKind.values) {
        expect(
          await storage.read(identity, kind),
          kind == ApplicationChatStorageRecordKind.queuedMessageReminderIntents
              ? isNull
              : isNotNull,
        );
      }
      for (final sibling in siblings) {
        expect(
          await _recordCount(storage, sibling),
          ApplicationChatStorageRecordKind.values.length,
        );
        for (final kind in ApplicationChatStorageRecordKind.values) {
          expect(await storage.read(sibling, kind), isNotNull);
        }
      }
    });

    test('conversation archive and restore requests round-trip exactly',
        () async {
      final identity = _identity();
      final record = ApplicationChatQueuedConversationArchiveIntentsRecord(
        identity: identity,
        intents: [
          _conversationArchiveIntent(
            1,
            conversation: 'conversation-archived',
            expectedRevision: 12,
            idempotencyKey: 'archive-exact-key',
          ),
          _conversationArchiveIntent(
            2,
            conversation: 'conversation-restored',
            intent: 'restore',
            expectedRevision: 900,
            idempotencyKey: 'restore-exact-key',
            enqueuedAt: const IsoTimestamp('2026-09-04T18:02:03.456-05:00'),
          ),
        ],
      );

      expect(record.toJson(), <String, Object?>{
        'schemaVersion': applicationChatStorageSchemaVersion,
        'kind': 'queued_conversation_archive_intents',
        'identity': identity.toJson(),
        'payload': <String, Object?>{
          'intents': <Object?>[
            <String, Object?>{
              'contractVersion':
                  applicationChatConversationArchiveContractVersion,
              'enqueueOrder': 1,
              'enqueuedAt': '2026-09-04T18:01:00.000Z',
              'operation': 'set_conversation_archive',
              'intent': 'archive',
              'conversationId': 'conversation-archived',
              'expectedLifecycleRevision': 12,
              'idempotencyKey': 'archive-exact-key',
            },
            <String, Object?>{
              'contractVersion':
                  applicationChatConversationArchiveContractVersion,
              'enqueueOrder': 2,
              'enqueuedAt': '2026-09-04T18:02:03.456-05:00',
              'operation': 'set_conversation_archive',
              'intent': 'restore',
              'conversationId': 'conversation-restored',
              'expectedLifecycleRevision': 900,
              'idempotencyKey': 'restore-exact-key',
            },
          ],
        },
      });
      final decoded = ApplicationChatStorageRecord.decode(record.encode())
          as ApplicationChatQueuedConversationArchiveIntentsRecord;
      expect(decoded.toJson(), record.toJson());
      expect(
        decoded.intents.map((value) => value.request.intent),
        [ConversationArchiveIntent.archive, ConversationArchiveIntent.restore],
      );
      expect(
        decoded.intents.map((value) => value.request.expectedLifecycleRevision),
        [12, 900],
      );
      expect(
        decoded.intents.map((value) => value.request.idempotencyKey),
        ['archive-exact-key', 'restore-exact-key'],
      );

      final storage = InMemoryApplicationChatStorage();
      await storage.replace(record);
      expect(
        (await storage.read(
          identity,
          ApplicationChatStorageRecordKind.queuedConversationArchiveIntents,
        ))
            ?.toJson(),
        record.toJson(),
      );
      for (final mismatch in [
        _identity(tenant: 'other-tenant'),
        _identity(user: 'other-user'),
        _identity(device: 'other-device'),
      ]) {
        expect(
          await storage.read(
            mismatch,
            ApplicationChatStorageRecordKind.queuedConversationArchiveIntents,
          ),
          isNull,
        );
        final wrongIdentity = _deepJsonCopy(record.toJson())
          ..['identity'] = mismatch.toJson();
        storage.putRawRecordForTesting(
          identity,
          ApplicationChatStorageRecordKind.queuedConversationArchiveIntents,
          wrongIdentity,
        );
        await expectLater(
          storage.read(
            identity,
            ApplicationChatStorageRecordKind.queuedConversationArchiveIntents,
          ),
          throwsFormatException,
        );
      }
    });

    test('conversation archive data detaches and coalesces per conversation',
        () {
      final requestJson = <String, Object?>{
        'operation': 'set_conversation_archive',
        'intent': 'archive',
        'conversationId': 'conversation-a',
        'expectedLifecycleRevision': 1,
        'idempotencyKey': 'conversation-a-first',
      };
      final request = ConversationArchiveInput.fromJson(requestJson);
      final first = ApplicationChatQueuedConversationArchiveIntent(
        request: request,
        enqueueOrder: 1,
        enqueuedAt: const IsoTimestamp('2026-09-04T18:01:00.000Z'),
      );
      final source = [
        first,
        _conversationArchiveIntent(
          2,
          conversation: 'conversation-b',
          idempotencyKey: 'conversation-b-only',
        ),
        _conversationArchiveIntent(
          3,
          conversation: 'conversation-a',
          intent: 'restore',
          expectedRevision: 7,
          idempotencyKey: 'conversation-a-latest',
          enqueuedAt: const IsoTimestamp('2026-09-04T18:03:00.999Z'),
        ),
        _conversationArchiveIntent(4, conversation: 'conversation-c'),
      ];
      final record = ApplicationChatQueuedConversationArchiveIntentsRecord(
        identity: _identity(),
        intents: source,
      );
      requestJson['conversationId'] = 'tampered';
      requestJson['idempotencyKey'] = 'tampered';
      source.add(
        _conversationArchiveIntent(5, conversation: 'conversation-d'),
      );

      expect(identical(first.request, request), isFalse);
      expect(identical(record.intents.first, first), isFalse);
      expect(identical(record.intents.first.request, first.request), isFalse);
      expect(() => record.intents.add(source.last), throwsUnsupportedError);
      expect(
        record.intents
            .map(
              (value) => (
                value.enqueueOrder,
                value.enqueuedAt.value,
                value.request.conversationId.value,
                value.request.intent,
                value.request.expectedLifecycleRevision,
                value.request.idempotencyKey,
              ),
            )
            .toList(),
        [
          (
            1,
            '2026-09-04T18:01:00.000Z',
            'conversation-a',
            ConversationArchiveIntent.restore,
            7,
            'conversation-a-latest',
          ),
          (
            2,
            '2026-09-04T18:02:00.000Z',
            'conversation-b',
            ConversationArchiveIntent.archive,
            1,
            'conversation-b-only',
          ),
          (
            4,
            '2026-09-04T18:04:00.000Z',
            'conversation-c',
            ConversationArchiveIntent.archive,
            1,
            'conversation-archive-key-4',
          ),
        ],
      );

      final wire = record.intents.first.toJson();
      final reparsed =
          ApplicationChatQueuedConversationArchiveIntent.fromJson(wire);
      wire['conversationId'] = 'wire-tampered';
      expect(reparsed.request.conversationId.value, 'conversation-a');
    });

    test('conversation archive queues reject duplicate keys and FIFO drift',
        () {
      for (final intents
          in <List<ApplicationChatQueuedConversationArchiveIntent>>[
        [
          _conversationArchiveIntent(2),
          _conversationArchiveIntent(1, conversation: 'conversation-2'),
        ],
        [
          _conversationArchiveIntent(1),
          _conversationArchiveIntent(1, conversation: 'conversation-2'),
        ],
        [
          _conversationArchiveIntent(1, idempotencyKey: 'duplicate-key'),
          _conversationArchiveIntent(
            2,
            conversation: 'conversation-2',
            idempotencyKey: 'duplicate-key',
          ),
        ],
      ]) {
        expect(
          () => ApplicationChatQueuedConversationArchiveIntentsRecord(
            identity: _identity(),
            intents: intents,
          ),
          throwsArgumentError,
        );
      }
      final duplicateWire = _conversationArchiveRecord(_identity()).toJson();
      (duplicateWire['payload']! as Map<String, Object?>)['intents'] =
          <Object?>[
        _conversationArchiveIntent(
          1,
          idempotencyKey: 'duplicate-wire-key',
        ).toJson(),
        _conversationArchiveIntent(
          2,
          conversation: 'conversation-2',
          idempotencyKey: 'duplicate-wire-key',
        ).toJson(),
      ];
      expect(
        () => ApplicationChatStorageRecord.fromJson(duplicateWire),
        throwsFormatException,
      );
      expect(() => _conversationArchiveIntent(0), throwsArgumentError);
      expect(
        () => _conversationArchiveIntent(9007199254740992),
        throwsArgumentError,
      );
      expect(
        () => _conversationArchiveIntent(
          1,
          expectedRevision: 9007199254740991,
        ),
        throwsArgumentError,
      );
      for (final timestamp in const [
        '2026-09-04',
        '2026-02-30T18:00:00.000Z',
        '2026-09-04T24:00:00.000Z',
      ]) {
        expect(
          () => _conversationArchiveIntent(
            1,
            enqueuedAt: IsoTimestamp(timestamp),
          ),
          throwsArgumentError,
          reason: timestamp,
        );
      }
    });

    test('conversation archive parsing fails closed for malformed records', () {
      final valid = _conversationArchiveIntent(1).toJson();
      final malformed = <Map<String, Object?>>[
        _deepJsonCopy(valid)..['operation'] = 'toggle_conversation_archive',
        _deepJsonCopy(valid)..['intent'] = 'toggle',
        _deepJsonCopy(valid)..['expectedLifecycleRevision'] = 0,
        _deepJsonCopy(valid)..['expectedLifecycleRevision'] = -1,
        _deepJsonCopy(valid)..['expectedLifecycleRevision'] = 1.5,
        _deepJsonCopy(valid)..['expectedLifecycleRevision'] = 9007199254740991,
        _deepJsonCopy(valid)..['enqueueOrder'] = 0,
        _deepJsonCopy(valid)..['enqueueOrder'] = 1.5,
        _deepJsonCopy(valid)..['enqueuedAt'] = '2026-02-30T18:00:00.000Z',
        _deepJsonCopy(valid)
          ..['contractVersion'] =
              applicationChatConversationArchiveContractVersion + 1,
        _deepJsonCopy(valid)..remove('idempotencyKey'),
        _deepJsonCopy(valid)..['unexpected'] = true,
        _deepJsonCopy(valid)..['accessToken'] = 'must-not-persist',
        _deepJsonCopy(valid)
          ..['metadata'] = <String, Object?>{
            'nested': <String, Object?>{'credential': 'must-not-persist'},
          },
        _deepJsonCopy(valid)
          ..['providerConfiguration'] = <String, Object?>{'opaque': true},
        _deepJsonCopy(valid)..['tenantId'] = 'tenant-injected',
        _deepJsonCopy(valid)..['currentUserId'] = 'user-injected',
        _deepJsonCopy(valid)..['payload'] = <int>[0, 1, 2, 255],
      ];
      for (final json in malformed) {
        expect(
          () => ApplicationChatQueuedConversationArchiveIntent.fromJson(json),
          throwsFormatException,
        );
      }

      final longTimestamp = '2030-01-02T03:04:05.${'1' * 70}Z';
      expect(
        () => ApplicationChatQueuedConversationArchiveIntent.fromJson(
          _deepJsonCopy(valid)..['enqueuedAt'] = longTimestamp,
        ),
        throwsFormatException,
      );
      final openPayload = _conversationArchiveRecord(_identity()).toJson();
      (openPayload['payload']! as Map<String, Object?>)['unexpected'] = true;
      expect(
        () => ApplicationChatStorageRecord.fromJson(openPayload),
        throwsFormatException,
      );
      final futureSchema = _conversationArchiveRecord(_identity()).toJson()
        ..['schemaVersion'] = applicationChatStorageSchemaVersion + 1;
      expect(
        () => ApplicationChatStorageRecord.fromJson(futureSchema),
        throwsFormatException,
      );
    });

    test('conversation archive count and UTF-8 ceilings are enforced', () {
      final exactIdentifier = '${'🙂' * 127}abcd';
      expect(utf8.encode(exactIdentifier), hasLength(512));
      expect(
        _conversationArchiveIntent(
          1,
          conversation: exactIdentifier,
          idempotencyKey: exactIdentifier,
        ),
        isNotNull,
      );
      final oversizedIdentifier = '$exactIdentifier!';
      expect(utf8.encode(oversizedIdentifier), hasLength(513));
      expect(
        () => _conversationArchiveIntent(
          1,
          conversation: oversizedIdentifier,
        ),
        throwsArgumentError,
      );
      expect(
        () => _conversationArchiveIntent(
          1,
          idempotencyKey: oversizedIdentifier,
        ),
        throwsArgumentError,
      );

      final tooMany = List.generate(
        maxApplicationChatQueuedConversationArchiveIntents + 1,
        (index) => _conversationArchiveIntent(
          index + 1,
          conversation: 'conversation-$index',
        ),
      );
      expect(
        ApplicationChatQueuedConversationArchiveIntentsRecord(
          identity: _identity(),
          intents: tooMany
              .take(
                maxApplicationChatQueuedConversationArchiveIntents,
              )
              .toList(growable: false),
        ).intents,
        hasLength(maxApplicationChatQueuedConversationArchiveIntents),
      );
      expect(
        () => ApplicationChatQueuedConversationArchiveIntentsRecord(
          identity: _identity(),
          intents: tooMany,
        ),
        throwsArgumentError,
      );

      final oversizedIntent = _conversationArchiveIntent(1).toJson()
        ..['padding'] = '🙂' * 4097;
      expect(
        utf8.encode(jsonEncode(oversizedIntent)).length,
        greaterThan(maxApplicationChatQueuedConversationArchiveIntentBytes),
      );
      expect(
        () => ApplicationChatQueuedConversationArchiveIntent.fromJson(
          oversizedIntent,
        ),
        throwsA(
          isA<FormatException>().having(
            (error) => error.message,
            'message',
            contains('exceeds 16384 encoded bytes'),
          ),
        ),
      );

      final encoded = _conversationArchiveRecord(_identity()).encode();
      expect(
        () => ApplicationChatStorageRecord.decode(
          '$encoded${' ' * maxApplicationChatStorageRecordBytes}',
        ),
        throwsA(
          isA<FormatException>().having(
            (error) => error.message,
            'message',
            contains('exceeds 5242880 encoded bytes'),
          ),
        ),
      );
    });

    test('corrupt archive removal preserves every other scope and kind',
        () async {
      final storage = InMemoryApplicationChatStorage();
      final identity = _identity();
      final siblings = [
        _identity(tenant: 'other-tenant'),
        _identity(user: 'other-user'),
        _identity(device: 'other-device'),
      ];
      await _putAllKinds(storage, identity);
      for (final sibling in siblings) {
        await _putAllKinds(storage, sibling);
      }
      final corrupt = _conversationArchiveRecord(identity).toJson();
      _conversationArchiveWireIntents(corrupt).single['providerConfiguration'] =
          'must-not-persist';
      storage.putRawRecordForTesting(
        identity,
        ApplicationChatStorageRecordKind.queuedConversationArchiveIntents,
        corrupt,
      );
      await expectLater(
        storage.read(
          identity,
          ApplicationChatStorageRecordKind.queuedConversationArchiveIntents,
        ),
        throwsFormatException,
      );

      await storage.remove(
        identity,
        ApplicationChatStorageRecordKind.queuedConversationArchiveIntents,
      );
      expect(
        await _recordCount(storage, identity),
        ApplicationChatStorageRecordKind.values.length - 1,
      );
      for (final kind in ApplicationChatStorageRecordKind.values) {
        expect(
          await storage.read(identity, kind),
          kind ==
                  ApplicationChatStorageRecordKind
                      .queuedConversationArchiveIntents
              ? isNull
              : isNotNull,
        );
      }
      for (final sibling in siblings) {
        expect(
          await _recordCount(storage, sibling),
          ApplicationChatStorageRecordKind.values.length,
        );
        for (final kind in ApplicationChatStorageRecordKind.values) {
          expect(await storage.read(sibling, kind), isNotNull);
        }
      }
    });

    test('all five message-mutation variants round-trip exact correlations',
        () async {
      final identity = _identity();
      final record = ApplicationChatQueuedMessageMutationIntentsRecord(
        identity: identity,
        intents: [
          _mutationIntent(
            1,
            'forward_message.v1',
            correlation: 'forward-correlation',
            idempotencyKey: 'forward-idempotency',
          ),
          _mutationIntent(2, 'edit', idempotencyKey: 'edit-idempotency'),
          _mutationIntent(
            3,
            'soft_delete',
            idempotencyKey: 'delete-idempotency',
          ),
          _mutationIntent(
            4,
            'add_reaction',
            idempotencyKey: 'add-idempotency',
          ),
          _mutationIntent(
            5,
            'remove_reaction',
            idempotencyKey: 'remove-idempotency',
          ),
        ],
      );

      final decoded = ApplicationChatStorageRecord.decode(record.encode())
          as ApplicationChatQueuedMessageMutationIntentsRecord;
      expect(decoded.toJson(), record.toJson());
      expect(
        decoded.intents.map((intent) => intent.operation),
        [
          'forward_message.v1',
          'edit',
          'soft_delete',
          'add_reaction',
          'remove_reaction',
        ],
      );
      expect(decoded.intents[0].request, isA<ForwardMessageRequest>());
      expect(decoded.intents[1].request, isA<EditMessageRequest>());
      expect(decoded.intents[2].request, isA<SoftDeleteMessageRequest>());
      expect(decoded.intents[3].request, isA<AddReactionInput>());
      expect(decoded.intents[4].request, isA<RemoveReactionInput>());
      final forward = decoded.intents.first.request as ForwardMessageRequest;
      expect(forward.clientCorrelationId, 'forward-correlation');
      expect(forward.idempotencyKey, 'forward-idempotency');
      expect(
        decoded.intents.map((intent) => intent.idempotencyKey),
        [
          'forward-idempotency',
          'edit-idempotency',
          'delete-idempotency',
          'add-idempotency',
          'remove-idempotency',
        ],
      );

      final storage = InMemoryApplicationChatStorage();
      await storage.replace(record);
      for (final mismatch in [
        _identity(tenant: 'other-tenant'),
        _identity(user: 'other-user'),
        _identity(device: 'other-device'),
      ]) {
        expect(
          await storage.read(
            mismatch,
            ApplicationChatStorageRecordKind.queuedMessageMutationIntents,
          ),
          isNull,
        );
        final wrongIdentity = _deepJsonCopy(record.toJson())
          ..['identity'] = mismatch.toJson();
        storage.putRawRecordForTesting(
          identity,
          ApplicationChatStorageRecordKind.queuedMessageMutationIntents,
          wrongIdentity,
        );
        await expectLater(
          storage.read(
            identity,
            ApplicationChatStorageRecordKind.queuedMessageMutationIntents,
          ),
          throwsFormatException,
        );
      }
    });

    test('message-mutation lanes coalesce safely without reordering FIFO', () {
      final record = ApplicationChatQueuedMessageMutationIntentsRecord(
        identity: _identity(),
        intents: [
          _mutationIntent(
            1,
            'edit',
            lane: 'shared-message',
            idempotencyKey: 'edit-original',
          ),
          _mutationIntent(
            2,
            'forward_message.v1',
            lane: 'shared-forward',
            correlation: 'forward-correlation-1',
            idempotencyKey: 'forward-original',
          ),
          _mutationIntent(
            3,
            'add_reaction',
            lane: 'shared-reaction',
            idempotencyKey: 'reaction-original',
          ),
          _mutationIntent(
            4,
            'soft_delete',
            lane: 'shared-message',
            expectedRevision: 2,
            idempotencyKey: 'delete-replacement',
          ),
          _mutationIntent(
            5,
            'forward_message.v1',
            lane: 'shared-forward',
            correlation: 'forward-correlation-2',
            idempotencyKey: 'forward-replacement',
          ),
          _mutationIntent(
            6,
            'remove_reaction',
            lane: 'shared-reaction',
            idempotencyKey: 'reaction-after-intervening-work',
          ),
          _mutationIntent(
            7,
            'add_reaction',
            lane: 'shared-reaction',
            idempotencyKey: 'adjacent-reaction-replacement',
          ),
          _mutationIntent(8, 'edit', lane: 'other-message'),
        ],
      );

      expect(
        record.intents
            .map(
              (intent) => (
                intent.enqueueOrder,
                intent.enqueuedAt.value,
                intent.operation,
                intent.idempotencyKey,
              ),
            )
            .toList(),
        [
          (
            1,
            '2026-09-03T13:01:00.000Z',
            'soft_delete',
            'delete-replacement',
          ),
          (
            2,
            '2026-09-03T13:02:00.000Z',
            'forward_message.v1',
            'forward-replacement',
          ),
          (
            3,
            '2026-09-03T13:03:00.000Z',
            'add_reaction',
            'reaction-original',
          ),
          (
            6,
            '2026-09-03T13:06:00.000Z',
            'add_reaction',
            'adjacent-reaction-replacement',
          ),
          (
            8,
            '2026-09-03T13:08:00.000Z',
            'edit',
            'mutation-key-8',
          ),
        ],
      );
      expect(
        (record.intents[1].request as ForwardMessageRequest)
            .clientCorrelationId,
        'forward-correlation-2',
      );
    });

    test('message-mutation queues reject duplicate correlations and FIFO drift',
        () {
      for (final intents in <List<ApplicationChatQueuedMessageMutationIntent>>[
        [
          _mutationIntent(2, 'edit'),
          _mutationIntent(1, 'soft_delete'),
        ],
        [
          _mutationIntent(
            1,
            'forward_message.v1',
            correlation: 'duplicate-correlation',
          ),
          _mutationIntent(
            2,
            'forward_message.v1',
            correlation: 'duplicate-correlation',
          ),
        ],
        [
          _mutationIntent(1, 'edit', idempotencyKey: 'duplicate-key'),
          _mutationIntent(
            2,
            'add_reaction',
            idempotencyKey: 'duplicate-key',
          ),
        ],
      ]) {
        expect(
          () => ApplicationChatQueuedMessageMutationIntentsRecord(
            identity: _identity(),
            intents: intents,
          ),
          throwsArgumentError,
        );
      }
      expect(() => _mutationIntent(0, 'edit'), throwsArgumentError);
      expect(
        () => _mutationIntent(9007199254740992, 'edit'),
        throwsArgumentError,
      );
      expect(
        () => _mutationIntent(
          1,
          'edit',
          enqueuedAt: const IsoTimestamp('2026-09-03'),
        ),
        throwsArgumentError,
      );
      expect(
        () => _mutationIntent(
          1,
          'forward_message.v1',
          lane: 'x' * 513,
        ),
        throwsArgumentError,
      );
      expect(
        () => _mutationIntent(
          1,
          'edit',
          idempotencyKey: 'x' * 513,
        ),
        throwsArgumentError,
      );
      expect(
        () => _mutationIntent(1, 'edit', text: 'x' * 100001),
        throwsArgumentError,
      );
    });

    test('message-mutation parsing rejects shape, version, and unsafe drift',
        () {
      final record = _mutationRecord(_identity()).toJson();
      for (final malformed in <Map<String, Object?>>[
        _deepJsonCopy(record)..['unexpected'] = true,
        _deepJsonCopy(record)
          ..['schemaVersion'] = applicationChatStorageSchemaVersion + 1,
        _deepJsonCopy(record)..['kind'] = 'queued_message_mutations',
        _deepJsonCopy(record)
          ..['payload'] = <String, Object?>{
            ...record['payload']! as Map<String, Object?>,
            'diagnostics': <String, Object?>{'status': 503},
          },
      ]) {
        expect(
          () => ApplicationChatStorageRecord.fromJson(malformed),
          throwsFormatException,
        );
      }

      final futureContract = _deepJsonCopy(record);
      _mutationWireIntent(futureContract)['contractVersion'] =
          applicationChatMessageMutationContractVersion + 1;
      expect(
        () => ApplicationChatStorageRecord.fromJson(futureContract),
        throwsFormatException,
      );

      for (final field in const {
        'accessToken',
        'credentials',
        'userId',
        'canonicalRevision',
        'providerData',
        'mediaDescriptor',
        'diagnostics',
        'unexpected',
      }) {
        final malformed = _deepJsonCopy(record);
        _mutationWireIntent(malformed)[field] = 'must-not-survive';
        expect(
          () => ApplicationChatStorageRecord.fromJson(malformed),
          throwsFormatException,
          reason: field,
        );
      }

      final nestedUnsafe = _mutationIntent(1, 'edit').toJson();
      final content = nestedUnsafe['content']! as Map<String, Object?>;
      content['blocks'] = <Object?>[
        <String, Object?>{
          'type': 'unsafe',
          'data': <String, Object?>{
            'attachmentBytes': <int>[0, 1, 2],
          },
        },
      ];
      expect(
        () => ApplicationChatQueuedMessageMutationIntent.fromJson(
          nestedUnsafe,
        ),
        throwsFormatException,
      );

      final nestedUnknown = _mutationIntent(1, 'edit').toJson();
      (nestedUnknown['content']! as Map<String, Object?>)['attachments'] = [
        <String, Object?>{
          'attachmentId': 'attachment-1',
          'unknown': true,
        },
      ];
      expect(
        () => ApplicationChatQueuedMessageMutationIntent.fromJson(
          nestedUnknown,
        ),
        throwsFormatException,
      );
      expect(
        () => ApplicationChatQueuedMessageMutationIntent.fromJson({
          ..._mutationIntent(1, 'edit').toJson(),
          'operation': 'toggle_reaction',
        }),
        throwsFormatException,
      );
      expect(
        () => ApplicationChatQueuedMessageMutationIntent(
          request: SendMessageRequest.fromJson({
            'operation': 'send',
            'conversationId': 'conversation-1',
            'content': {'format': 'plain', 'text': 'not a mutation'},
            'clientMessageId': 'client-1',
            'idempotencyKey': 'send-1',
          }),
          enqueueOrder: 1,
          enqueuedAt: const IsoTimestamp('2026-09-03T13:01:00.000Z'),
        ),
        throwsArgumentError,
      );
    });

    test('message-mutation count and UTF-8 byte ceilings are enforced', () {
      final exactCount = List.generate(
        maxApplicationChatQueuedMessageMutationIntents,
        (index) => _mutationIntent(
          index + 1,
          'edit',
          lane: 'count-$index',
        ),
      );
      expect(
        ApplicationChatQueuedMessageMutationIntentsRecord(
          identity: _identity(),
          intents: exactCount,
        ).intents,
        hasLength(maxApplicationChatQueuedMessageMutationIntents),
      );
      expect(
        () => ApplicationChatQueuedMessageMutationIntentsRecord(
          identity: _identity(),
          intents: [
            ...exactCount,
            _mutationIntent(
              maxApplicationChatQueuedMessageMutationIntents + 1,
              'edit',
              lane: 'one-too-many',
            ),
          ],
        ),
        throwsArgumentError,
      );

      final oversizedIntent = _mutationIntent(1, 'edit').toJson();
      (oversizedIntent['content']! as Map<String, Object?>)['text'] =
          '\u{1f642}' * 65536;
      expect(
        () => ApplicationChatQueuedMessageMutationIntent.fromJson(
          oversizedIntent,
        ),
        throwsA(
          isA<FormatException>().having(
            (error) => error.message,
            'message',
            contains('exceeds 262144 encoded bytes'),
          ),
        ),
      );

      final aggregate = List.generate(
        60,
        (index) => _mutationIntent(
          index + 1,
          'edit',
          lane: 'aggregate-$index',
          text: 'x' * 90000,
        ),
      );
      expect(
        () => ApplicationChatQueuedMessageMutationIntentsRecord(
          identity: _identity(),
          intents: aggregate,
        ),
        throwsArgumentError,
      );
    });

    test('message-mutation values and storage reads are deeply detached',
        () async {
      final request = EditMessageRequest.fromJson({
        'operation': 'edit',
        'messageId': 'message-detached',
        'expectedRevision': 1,
        'content': {
          'format': 'plain',
          'text': 'before',
          'blocks': [
            {
              'type': 'safe',
              'data': {'label': 'before'},
            },
          ],
        },
        'idempotencyKey': 'detached-key',
      });
      final intent = ApplicationChatQueuedMessageMutationIntent(
        request: request,
        enqueueOrder: 1,
        enqueuedAt: const IsoTimestamp('2026-09-03T13:01:00.000Z'),
      );
      final source = [intent];
      final record = ApplicationChatQueuedMessageMutationIntentsRecord(
        identity: _identity(),
        intents: source,
      );
      source.add(_mutationIntent(2, 'soft_delete'));
      expect(record.intents, hasLength(1));
      expect(identical(intent.request, request), isFalse);
      expect(identical(record.intents.single, intent), isFalse);
      expect(identical(record.intents.single.request, intent.request), isFalse);
      expect(() => record.intents.add(source.last), throwsUnsupportedError);
      final storedRequest = record.intents.single.request as EditMessageRequest;
      final data =
          storedRequest.content.blocks!.single.data as Map<String, Object?>;
      expect(() => data['label'] = 'tampered', throwsUnsupportedError);

      final serialized = record.toJson();
      final serializedContent =
          _mutationWireIntent(serialized)['content']! as Map<String, Object?>;
      serializedContent['text'] = 'tampered';
      expect(storedRequest.content.text, 'before');

      final storage = InMemoryApplicationChatStorage();
      await storage.replace(record);
      final first = await storage.read(
        _identity(),
        ApplicationChatStorageRecordKind.queuedMessageMutationIntents,
      ) as ApplicationChatQueuedMessageMutationIntentsRecord;
      first.toJson()['kind'] = 'tampered';
      final second = await storage.read(
        _identity(),
        ApplicationChatStorageRecordKind.queuedMessageMutationIntents,
      ) as ApplicationChatQueuedMessageMutationIntentsRecord;
      expect(second.toJson(), record.toJson());
      expect(identical(second, record), isFalse);
    });

    test('corrupt message-mutation removal preserves identities and kinds',
        () async {
      final storage = InMemoryApplicationChatStorage();
      final identity = _identity();
      final siblings = [
        _identity(tenant: 'other-tenant'),
        _identity(user: 'other-user'),
        _identity(device: 'other-device'),
      ];
      await _putAllKinds(storage, identity);
      for (final sibling in siblings) {
        await _putAllKinds(storage, sibling);
      }
      final corrupt = _mutationRecord(identity).toJson();
      _mutationWireIntent(corrupt)['idempotencyKey'] = ' ';
      storage.putRawRecordForTesting(
        identity,
        ApplicationChatStorageRecordKind.queuedMessageMutationIntents,
        corrupt,
      );
      await expectLater(
        storage.read(
          identity,
          ApplicationChatStorageRecordKind.queuedMessageMutationIntents,
        ),
        throwsFormatException,
      );

      await storage.remove(
        identity,
        ApplicationChatStorageRecordKind.queuedMessageMutationIntents,
      );
      expect(
        await _recordCount(storage, identity),
        ApplicationChatStorageRecordKind.values.length - 1,
      );
      expect(
        await storage.read(
          identity,
          ApplicationChatStorageRecordKind.queuedDraftIntents,
        ),
        isNotNull,
      );
      expect(
        await storage.read(
          identity,
          ApplicationChatStorageRecordKind.queuedSendMessageIntents,
        ),
        isNotNull,
      );
      for (final sibling in siblings) {
        expect(
          await _recordCount(storage, sibling),
          ApplicationChatStorageRecordKind.values.length,
        );
      }
    });

    test('replace and clear draft intents round-trip and coalesce by lane', () {
      final record = ApplicationChatQueuedDraftIntentsRecord(
        identity: _identity(),
        intents: [
          _draftIntent(1, conversation: 'conversation-a'),
          _draftIntent(2, conversation: 'conversation-b'),
          _draftIntent(
            3,
            conversation: 'conversation-a',
            clear: true,
            baseRevision: 7,
          ),
        ],
      );

      expect(record.intents, hasLength(2));
      expect(
        record.intents.map((intent) => intent.request.conversationId.value),
        ['conversation-b', 'conversation-a'],
      );
      expect(record.intents.map((intent) => intent.enqueueOrder), [2, 3]);
      expect(record.intents.first.request, isA<ReplaceDraftInput>());
      expect(record.intents.last.request, isA<ClearDraftInput>());
      expect(record.intents.last.request.baseRevision, 7);
      expect(record.intents.last.request.deviceMutationId, 'draft-mutation-3');
      expect(record.intents.last.request.idempotencyKey, 'draft-key-3');

      final decoded = ApplicationChatStorageRecord.decode(record.encode())
          as ApplicationChatQueuedDraftIntentsRecord;
      expect(decoded.toJson(), record.toJson());
      expect(decoded.intents.first.request, isA<ReplaceDraftInput>());
      expect(decoded.intents.last.request, isA<ClearDraftInput>());
    });

    test('draft reply edits round-trip exactly and coalesce without content loss',
        () async {
      final storage = InMemoryApplicationChatStorage();
      final original = _draftRequest(1).toJson();
      final originalContent = original['content']! as Map<String, Object?>;
      final replies = <Map<String, Object?>?>[
        {'messageId': 'source-a', 'notifyAuthor': true},
        {'messageId': 'source-b', 'notifyAuthor': true},
        {'messageId': 'source-b', 'notifyAuthor': false},
        null,
      ];
      ApplicationChatQueuedDraftIntent? previous;
      for (var index = 0; index < replies.length; index += 1) {
        final expected = {
          ...original,
          'deviceMutationId': 'reply-mutation-$index',
          'idempotencyKey': 'reply-key-$index',
          'content': {
            ...originalContent,
            if (replies[index] != null) 'replyTo': replies[index],
          },
        };
        final intent = ApplicationChatQueuedDraftIntent(
          request: SynchronizeDraftInput.fromJson(expected),
          enqueueOrder: index + 1,
          enqueuedAt: const IsoTimestamp('2026-09-03T12:01:00.000Z'),
        );
        final record = ApplicationChatQueuedDraftIntentsRecord(
          identity: _identity(),
          intents: [if (previous != null) previous, intent],
        );
        expect(record.intents, hasLength(1));
        expect(record.intents.single.request.toJson(), expected);
        final decoded = ApplicationChatStorageRecord.decode(record.encode())
            as ApplicationChatQueuedDraftIntentsRecord;
        expect(decoded.toJson(), record.toJson());
        expect(decoded.intents.single.request.toJson(), expected);
        await storage.replace(decoded);
        final read = await storage.read(_identity(),
            ApplicationChatStorageRecordKind.queuedDraftIntents)
            as ApplicationChatQueuedDraftIntentsRecord;
        expect(read.toJson(), record.toJson());
        expect(read.intents.single.request.toJson(), expected);
        previous = intent;
      }
    });

    for (final notifyAuthor in [true, false]) {
      test('draft reply metadata is detached with notifyAuthor=$notifyAuthor',
          () async {
        final input = _draftRequest(1).toJson();
        final inputContent = input['content']! as Map<String, Object?>;
        inputContent['replyTo'] = {
          'messageId': 'source-detached',
          'notifyAuthor': notifyAuthor,
        };
        final expected = _deepJsonCopy(input);
        final request = SynchronizeDraftInput.fromJson(input) as ReplaceDraftInput;
        final intent = ApplicationChatQueuedDraftIntent(
          request: request,
          enqueueOrder: 1,
          enqueuedAt: const IsoTimestamp('2026-09-03T12:01:00.000Z'),
        );
        final cloned = intent.request as ReplaceDraftInput;
        expect(identical(cloned.content, request.content), isFalse);
        expect(identical(cloned.content.replyTo, request.content.replyTo), isFalse);
        final record = ApplicationChatQueuedDraftIntentsRecord(
            identity: _identity(), intents: [intent]);
        final encoded = record.encode();
        final decoded = ApplicationChatStorageRecord.decode(encoded)
            as ApplicationChatQueuedDraftIntentsRecord;
        final serialized = _draftWireIntent(decoded.toJson());
        for (final content in [inputContent,
          serialized['content']! as Map<String, Object?>]) {
          final reply = content['replyTo']! as Map<String, Object?>;
          reply['messageId'] = 'tampered';
          reply['notifyAuthor'] = !notifyAuthor;
          content.remove('replyTo');
        }
        expect(request.toJson(), expected);
        expect(intent.request.toJson(), expected);
        expect(decoded.intents.single.request.toJson(), expected);
        expect(record.encode(), encoded);
        final storage = InMemoryApplicationChatStorage();
        await storage.replace(decoded);
        final first = await storage.read(_identity(),
            ApplicationChatStorageRecordKind.queuedDraftIntents)
            as ApplicationChatQueuedDraftIntentsRecord;
        final firstContent = _draftWireIntent(first.toJson())['content']!
            as Map<String, Object?>;
        (firstContent['replyTo']! as Map<String, Object?>)['notifyAuthor'] =
            !notifyAuthor;
        final second = await storage.read(_identity(),
            ApplicationChatStorageRecordKind.queuedDraftIntents)
            as ApplicationChatQueuedDraftIntentsRecord;
        expect(second.intents.single.request.toJson(), expected);
        expect(identical(
            (first.intents.single.request as ReplaceDraftInput).content.replyTo,
            (second.intents.single.request as ReplaceDraftInput).content.replyTo),
            isFalse);
      });
    }

    test('draft queue rejects duplicate correlations and unsafe FIFO metadata',
        () {
      for (final intents in <List<ApplicationChatQueuedDraftIntent>>[
        [
          _draftIntent(1),
          _draftIntent(2, deviceMutationId: 'draft-mutation-1'),
        ],
        [
          _draftIntent(1),
          _draftIntent(2, idempotencyKey: 'draft-key-1'),
        ],
        [_draftIntent(2), _draftIntent(1)],
        [_draftIntent(1), _draftIntent(1, conversation: 'conversation-2')],
      ]) {
        expect(
          () => ApplicationChatQueuedDraftIntentsRecord(
            identity: _identity(),
            intents: intents,
          ),
          throwsArgumentError,
        );
      }
      expect(
        () => _draftIntent(0),
        throwsArgumentError,
      );
      expect(
        () => _draftIntent(9007199254740992),
        throwsArgumentError,
      );
      expect(
        () => _draftIntent(
          1,
          enqueuedAt: const IsoTimestamp('2026-09-03'),
        ),
        throwsArgumentError,
      );
    });

    test('draft records reject identity, kind, version, and shape drift',
        () async {
      final identity = _identity();
      final record = _draftRecord(identity).toJson();

      for (final malformed in <Map<String, Object?>>[
        _deepJsonCopy(record)..['unexpected'] = true,
        _deepJsonCopy(record)
          ..['schemaVersion'] = applicationChatStorageSchemaVersion + 1,
        _deepJsonCopy(record)..['kind'] = 'queued_drafts',
        _deepJsonCopy(record)
          ..['payload'] = <String, Object?>{
            ...record['payload']! as Map<String, Object?>,
            'diagnostics': <String, Object?>{'status': 503},
          },
      ]) {
        expect(
          () => ApplicationChatStorageRecord.fromJson(malformed),
          throwsFormatException,
        );
      }

      final futureContract = _deepJsonCopy(record);
      _draftWireIntent(futureContract)['contractVersion'] =
          applicationChatDraftMutationContractVersion + 1;
      expect(
        () => ApplicationChatStorageRecord.fromJson(futureContract),
        throwsFormatException,
      );

      for (final field in const {
        'accessToken',
        'providerMetadata',
        'diagnostics',
        'unexpected',
      }) {
        final malformed = _deepJsonCopy(record);
        _draftWireIntent(malformed)[field] = 'must-not-survive';
        expect(
          () => ApplicationChatStorageRecord.fromJson(malformed),
          throwsFormatException,
          reason: field,
        );
      }

      final storage = InMemoryApplicationChatStorage();
      for (final mismatch in [
        _identity(tenant: 'other-tenant'),
        _identity(user: 'other-user'),
        _identity(device: 'other-device'),
      ]) {
        final wrongIdentity = _deepJsonCopy(record)
          ..['identity'] = mismatch.toJson();
        storage.putRawRecordForTesting(
          identity,
          ApplicationChatStorageRecordKind.queuedDraftIntents,
          wrongIdentity,
        );
        await expectLater(
          storage.read(
            identity,
            ApplicationChatStorageRecordKind.queuedDraftIntents,
          ),
          throwsFormatException,
        );
      }
      storage.putRawRecordForTesting(
        identity,
        ApplicationChatStorageRecordKind.queuedDraftIntents,
        ApplicationChatQueuedSendMessageIntentsRecord(
          identity: identity,
          intents: const [],
        ).toJson(),
      );
      await expectLater(
        storage.read(
          identity,
          ApplicationChatStorageRecordKind.queuedDraftIntents,
        ),
        throwsFormatException,
      );
    });

    test('draft queue enforces conversation and UTF-8 intent boundaries', () {
      final exact = List.generate(
        maxApplicationChatQueuedDraftConversations,
        (index) => _draftIntent(index + 1, conversation: 'conversation-$index'),
      );
      expect(
        ApplicationChatQueuedDraftIntentsRecord(
          identity: _identity(),
          intents: exact,
        ).intents,
        hasLength(maxApplicationChatQueuedDraftConversations),
      );
      expect(
        () => ApplicationChatQueuedDraftIntentsRecord(
          identity: _identity(),
          intents: [
            ...exact,
            _draftIntent(
              maxApplicationChatQueuedDraftConversations + 1,
              conversation: 'one-too-many',
            ),
          ],
        ),
        throwsArgumentError,
      );

      final exactBytes = _draftIntent(1).toJson()..['padding'] = '';
      final framingBytes = utf8.encode(jsonEncode(exactBytes)).length;
      exactBytes['padding'] =
          'a' * (maxApplicationChatQueuedDraftIntentBytes - framingBytes);
      expect(
        utf8.encode(jsonEncode(exactBytes)),
        hasLength(maxApplicationChatQueuedDraftIntentBytes),
      );
      expect(
        () => ApplicationChatQueuedDraftIntent.fromJson(exactBytes),
        throwsA(
          isA<FormatException>().having(
            (error) => error.message,
            'message',
            contains('padding is not supported'),
          ),
        ),
        reason: 'the exact byte boundary reaches strict shape validation',
      );
      exactBytes['padding'] = '${exactBytes['padding'] as String}\u{1f642}';
      expect(
        utf8.encode(jsonEncode(exactBytes)).length,
        maxApplicationChatQueuedDraftIntentBytes + 4,
      );
      expect(
        () => ApplicationChatQueuedDraftIntent.fromJson(exactBytes),
        throwsA(
          isA<FormatException>().having(
            (error) => error.message,
            'message',
            contains('exceeds 131072 encoded bytes'),
          ),
        ),
      );
    });

    test('draft records enforce the exact five-MiB UTF-8 boundary', () {
      final encoded = _draftRecord(_identity()).encode();
      final atBoundary =
          '$encoded${' ' * (maxApplicationChatStorageRecordBytes - utf8.encode(encoded).length)}';
      expect(
        utf8.encode(atBoundary),
        hasLength(maxApplicationChatStorageRecordBytes),
      );
      expect(
        ApplicationChatStorageRecord.decode(atBoundary),
        isA<ApplicationChatQueuedDraftIntentsRecord>(),
      );
      expect(
        () => ApplicationChatStorageRecord.decode('$atBoundary '),
        throwsFormatException,
      );
    });

    test('draft values, serialized maps, and storage reads are detached',
        () async {
      final request = _draftRequest(1);
      final intent = ApplicationChatQueuedDraftIntent(
        request: request,
        enqueueOrder: 1,
        enqueuedAt: const IsoTimestamp('2026-09-03T12:01:00.000Z'),
      );
      final source = [intent];
      final record = ApplicationChatQueuedDraftIntentsRecord(
        identity: _identity(),
        intents: source,
      );
      source.add(_draftIntent(2));
      expect(record.intents, hasLength(1));
      expect(identical(intent.request, request), isFalse);
      expect(() => record.intents.add(source.last), throwsUnsupportedError);
      final replacement = intent.request as ReplaceDraftInput;
      expect(
        () => replacement.content.attachments.add(
          DraftAttachmentReference(
            attachmentId: const AttachmentId('other-attachment'),
          ),
        ),
        throwsUnsupportedError,
      );

      final serialized = record.toJson();
      final serializedIntent = _draftWireIntent(serialized);
      (serializedIntent['content']! as Map<String, Object?>)['text'] =
          'tampered';
      expect(
        (record.intents.single.request as ReplaceDraftInput).content.text,
        'draft 1',
      );

      final storage = InMemoryApplicationChatStorage();
      await storage.replace(record);
      final first = await storage.read(
        _identity(),
        ApplicationChatStorageRecordKind.queuedDraftIntents,
      ) as ApplicationChatQueuedDraftIntentsRecord;
      first.toJson()['kind'] = 'tampered';
      final second = await storage.read(
        _identity(),
        ApplicationChatStorageRecordKind.queuedDraftIntents,
      ) as ApplicationChatQueuedDraftIntentsRecord;
      expect(second.toJson(), record.toJson());
      expect(identical(second, record), isFalse);
      expect(identical(second.intents.single.request, request), isFalse);
    });

    test('corrupt draft removal preserves sibling identities and kinds',
        () async {
      final storage = InMemoryApplicationChatStorage();
      final identity = _identity();
      final siblings = [
        _identity(tenant: 'other-tenant'),
        _identity(user: 'other-user'),
        _identity(device: 'other-device'),
      ];
      await _putAllKinds(storage, identity);
      for (final sibling in siblings) {
        await _putAllKinds(storage, sibling);
      }
      final corrupt = _draftRecord(identity).toJson();
      _draftWireIntent(corrupt)['idempotencyKey'] = ' ';
      storage.putRawRecordForTesting(
        identity,
        ApplicationChatStorageRecordKind.queuedDraftIntents,
        corrupt,
      );
      await expectLater(
        storage.read(
          identity,
          ApplicationChatStorageRecordKind.queuedDraftIntents,
        ),
        throwsFormatException,
      );

      await storage.remove(
        identity,
        ApplicationChatStorageRecordKind.queuedDraftIntents,
      );
      expect(
        await _recordCount(storage, identity),
        ApplicationChatStorageRecordKind.values.length - 1,
      );
      expect(
        await storage.read(
          identity,
          ApplicationChatStorageRecordKind.queuedSendMessageIntents,
        ),
        isNotNull,
      );
      for (final sibling in siblings) {
        expect(
          await _recordCount(storage, sibling),
          ApplicationChatStorageRecordKind.values.length,
        );
      }
    });

    test('queued send intent capacity accepts exactly 1000 intents', () {
      final intents = _queuedSendIntents(
        maxApplicationChatQueuedSendIntents,
      );

      final record = ApplicationChatQueuedSendMessageIntentsRecord(
        identity: _identity(),
        intents: intents,
      );

      expect(record.intents, hasLength(maxApplicationChatQueuedSendIntents));
      expect(
        () => ApplicationChatQueuedSendMessageIntentsRecord(
          identity: _identity(),
          intents: _queuedSendIntents(
            maxApplicationChatQueuedSendIntents + 1,
          ),
        ),
        throwsArgumentError,
      );
    });

    test('queued send intent capacity rejects 1001 intents during decode', () {
      final record = ApplicationChatQueuedSendMessageIntentsRecord(
        identity: _identity(),
        intents: _queuedSendIntents(maxApplicationChatQueuedSendIntents),
      ).toJson();
      final payload = record['payload']! as Map<String, Object?>;
      final intents = payload['intents']! as List<Object?>;
      intents.add(
          _queuedSendIntent(maxApplicationChatQueuedSendIntents + 1).toJson());

      expect(
        () => ApplicationChatStorageRecord.decode(jsonEncode(record)),
        throwsFormatException,
      );
    });

    test('encoded record size accepts the boundary and rejects one byte over',
        () {
      final identity = _identity();
      final framingBytes = utf8
          .encode(jsonEncode(
            ApplicationChatRealtimeCursorRecord(
              identity: identity,
              cursor: const EventCursor(eventId: ''),
            ).toJson(),
          ))
          .length;
      final boundaryEventId =
          '$_persistedPayloadSentinel${'a' * (maxApplicationChatStorageRecordBytes - framingBytes - _persistedPayloadSentinel.length)}';
      final boundaryRecord = ApplicationChatRealtimeCursorRecord(
        identity: identity,
        cursor: EventCursor(eventId: boundaryEventId),
      );

      final encoded = boundaryRecord.encode();
      expect(utf8.encode(encoded),
          hasLength(maxApplicationChatStorageRecordBytes));
      expect(
        ApplicationChatStorageRecord.decode(encoded),
        isA<ApplicationChatRealtimeCursorRecord>(),
      );

      final oversizedRecord = ApplicationChatRealtimeCursorRecord(
        identity: identity,
        cursor: EventCursor(eventId: '${boundaryEventId}a'),
      );
      expect(
        oversizedRecord.encode,
        throwsA(
          isA<ArgumentError>().having(
            (error) => error.toString(),
            'message',
            allOf(
              contains('exceeds 5242880 encoded bytes'),
              isNot(contains(_persistedPayloadSentinel)),
            ),
          ),
        ),
      );
    });

    test('oversized persisted record is rejected before JSON parsing', () {
      final encoded =
          '$_persistedPayloadSentinel${'a' * (maxApplicationChatStorageRecordBytes + 1 - _persistedPayloadSentinel.length)}';
      expect(
        utf8.encode(encoded),
        hasLength(maxApplicationChatStorageRecordBytes + 1),
      );

      expect(
        () => ApplicationChatStorageRecord.decode(encoded),
        throwsA(
          isA<FormatException>().having(
            (error) => error.message.toString(),
            'message',
            allOf(
              equals(
                'Application chat storage record exceeds 5242880 encoded bytes.',
              ),
              isNot(contains(_persistedPayloadSentinel)),
            ),
          ),
        ),
      );
    });

    test('individual oversized send intent is rejected during construction',
        () {
      final framingBytes =
          utf8.encode(jsonEncode(_queuedSendIntentJson(''))).length;
      final text =
          '$_persistedPayloadSentinel${'a' * (maxApplicationChatQueuedSendIntentBytes + 1 - framingBytes - _persistedPayloadSentinel.length)}';

      expect(
        () => _queuedSendIntentWithText(text),
        throwsA(
          isA<ArgumentError>().having(
            (error) => error.toString(),
            'message',
            allOf(
              contains('exceeds 262144 encoded bytes'),
              isNot(contains(_persistedPayloadSentinel)),
            ),
          ),
        ),
      );
    });

    test('persisted send intent size counts multibyte UTF-8 bytes', () {
      final framingBytes =
          utf8.encode(jsonEncode(_queuedSendIntentJson(''))).length;
      final availableBytes = maxApplicationChatQueuedSendIntentBytes -
          framingBytes -
          _persistedPayloadSentinel.length;
      final text =
          '$_persistedPayloadSentinel${'\u{1f642}' * (availableBytes ~/ 4 + 1)}';
      final intent = _queuedSendIntentJson(text);
      final encodedIntent = jsonEncode(intent);
      expect(
        encodedIntent.length,
        lessThanOrEqualTo(maxApplicationChatQueuedSendIntentBytes),
      );
      expect(
        utf8.encode(encodedIntent).length,
        greaterThan(maxApplicationChatQueuedSendIntentBytes),
      );
      final record = <String, Object?>{
        'schemaVersion': applicationChatStorageSchemaVersion,
        'kind': 'queued_send_message_intents',
        'identity': _identity().toJson(),
        'payload': <String, Object?>{
          'intents': <Object?>[intent],
        },
      };

      expect(
        () => ApplicationChatStorageRecord.decode(jsonEncode(record)),
        throwsA(
          isA<FormatException>().having(
            (error) => error.message.toString(),
            'message',
            allOf(
              equals(
                'Stored queued send intent exceeds 262144 encoded bytes.',
              ),
              isNot(contains(_persistedPayloadSentinel)),
            ),
          ),
        ),
      );
    });
  });
}

// Literal legacy wire fixture: independent of the current storage serializer.
const _legacySnapshotJson = '''
{
  "schemaVersion": 1,
  "kind": "normalized_snapshot",
  "identity": {"tenantId": "tenant-1", "userId": "user-1", "deviceId": "device-1"},
  "payload": {
    "snapshot": {
      "conversations": [{
        "id": "conversation-1", "tenantId": "tenant-1", "type": "channel",
        "name": "Legacy channel", "visibility": "private",
        "createdAt": "2026-08-26T16:00:00.000Z",
        "updatedAt": "2026-08-26T16:00:00.000Z"
      }],
      "canonicalMessages": [],
      "messages": [],
      "membersByConversation": [],
      "memberUserIdsByConversation": [],
      "lifecycleRevisions": [{"conversationId": "conversation-1", "revision": 3}],
      "lifecycleArchivedStates": [{"conversationId": "conversation-1", "archived": false}],
      "memberListRevisions": [{"conversationId": "conversation-1", "revision": 4}],
      "currentUserReadStates": [{
        "conversationId": "conversation-1", "userId": "user-1",
        "lastReadSequence": 7, "updatedAt": "2026-08-26T16:00:00.000Z"
      }],
      "currentUserPreferences": [],
      "preferenceRevisions": [],
      "threadFollows": [],
      "threadFollowRevisions": [],
      "savedMessages": [],
      "messageReminders": [],
      "drafts": [],
      "conversationMetadata": [{
        "conversationId": "conversation-1", "latestSequence": 12,
        "activityAt": "2026-08-26T16:00:00.000Z"
      }],
      "durableStreams": [],
      "conversationLists": [],
      "conversationDetails": [],
      "timelines": [],
      "attachments": [],
      "attachmentUploads": [],
      "huddles": [],
      "latestReplayCursor": {"eventId": "legacy-event-12"}
    }
  }
}
''';

const _persistedPayloadSentinel = 'PERSISTED_PAYLOAD_SENTINEL';

ApplicationChatQueuedReadCursorIntentsRecord _readRecord(
  ApplicationChatStorageIdentity identity,
) =>
    ApplicationChatQueuedReadCursorIntentsRecord(
      identity: identity,
      intents: [
        _readIntent(1, throughSequence: 2, user: identity.userId.value)
      ],
    );

ApplicationChatQueuedReadCursorIntent _readIntent(
  int order, {
  required int throughSequence,
  String conversation = 'conversation-1',
  String user = 'user-1',
  String? idempotencyKey,
}) =>
    ApplicationChatQueuedReadCursorIntent(
      request: MarkReadInput(
        conversationId: ConversationId(conversation),
        throughSequence: MessageSequence(throughSequence),
        idempotencyKey: idempotencyKey ?? 'read-key-$order',
      ),
      acknowledgedReadState: _readState(
        conversation: conversation,
        user: user,
      ),
      enqueueOrder: order,
      enqueuedAt: const IsoTimestamp('2026-08-26T16:01:00.000Z'),
    );

ApplicationChatQueuedReadCursorIntent _unreadIntent(
  int order, {
  required int fromSequence,
  String conversation = 'conversation-1',
  String user = 'user-1',
}) =>
    ApplicationChatQueuedReadCursorIntent(
      request: MarkUnreadInput(
        conversationId: ConversationId(conversation),
        fromSequence: MessageSequence(fromSequence),
        idempotencyKey: 'unread-key-$order',
      ),
      acknowledgedReadState: _readState(
        conversation: conversation,
        user: user,
        lastReadSequence: 8,
      ),
      enqueueOrder: order,
      enqueuedAt: const IsoTimestamp('2026-08-26T16:02:00.000Z'),
    );

ConversationReadState _readState({
  String conversation = 'conversation-1',
  String user = 'user-1',
  int lastReadSequence = 1,
}) =>
    ConversationReadState(
      conversationId: ConversationId(conversation),
      userId: UserId(user),
      lastReadSequence: MessageSequence(lastReadSequence),
      updatedAt: const IsoTimestamp('2026-08-26T16:00:00.000Z'),
    );

Map<String, Object?> _readIntentJson(int order) =>
    _readIntent(order, throughSequence: 2).toJson();

ApplicationChatQueuedConversationMembershipIntentsRecord _membershipRecord(
  ApplicationChatStorageIdentity identity,
) =>
    ApplicationChatQueuedConversationMembershipIntentsRecord(
      identity: identity,
      intents: [_membershipIntent(1, 'add_member')],
    );

ApplicationChatQueuedConversationMembershipIntent _membershipIntent(
  int order,
  String intent, {
  String conversation = 'conversation-1',
  String? targetUser,
  String? role,
  int expectedRevision = 1,
  String? idempotencyKey,
  IsoTimestamp? enqueuedAt,
}) =>
    ApplicationChatQueuedConversationMembershipIntent(
      request: _membershipRequest(
        intent,
        conversation: conversation,
        targetUser: targetUser,
        role: role,
        expectedRevision: expectedRevision,
        idempotencyKey: idempotencyKey ?? 'membership-key-$order',
      ),
      enqueueOrder: order,
      enqueuedAt: enqueuedAt ??
          IsoTimestamp(
            '2026-09-03T14:${(order % 60).toString().padLeft(2, '0')}:00.000Z',
          ),
    );

ConversationMembershipMutationInput _membershipRequest(
  String intent, {
  String conversation = 'conversation-1',
  String? targetUser,
  String? role,
  int expectedRevision = 1,
  String idempotencyKey = 'membership-key',
}) {
  final targeted = intent == 'add_member' ||
      intent == 'remove_member' ||
      intent == 'change_member_role';
  final roleBearing = intent == 'add_member' || intent == 'change_member_role';
  return ConversationMembershipMutationInput.fromJson(<String, Object?>{
    'operation': 'mutate_conversation_membership',
    'intent': intent,
    'conversationId': conversation,
    if (targeted) 'targetUserId': targetUser ?? 'target-user',
    if (roleBearing) 'requestedRole': role ?? 'member',
    'expectedMemberListRevision': expectedRevision,
    'idempotencyKey': idempotencyKey,
  });
}

List<Map<String, Object?>> _membershipWireIntents(
  Map<String, Object?> record,
) =>
    ((record['payload']! as Map<String, Object?>)['intents']! as List<Object?>)
        .cast<Map<String, Object?>>();

ApplicationChatQueuedConversationCreationIntentsRecord _creationRecord(
  ApplicationChatStorageIdentity identity,
) =>
    ApplicationChatQueuedConversationCreationIntentsRecord(
      identity: identity,
      intents: [_creationIntent(1, 'channel')],
    );

ApplicationChatQueuedConversationCreationIntent _creationIntent(
  int order,
  String type, {
  String? name,
  String visibility = 'public',
  String? entityType,
  String? entityId,
  List<String>? members,
  String? idempotencyKey,
  String? clientRequestId,
  IsoTimestamp? enqueuedAt,
}) =>
    ApplicationChatQueuedConversationCreationIntent(
      request: _creationRequest(
        type,
        name: name ?? 'channel-$order',
        visibility: visibility,
        entityType: entityType,
        entityId: entityId,
        members: members,
        idempotencyKey: idempotencyKey ?? 'creation-key-$order',
        clientRequestId: clientRequestId ?? 'creation-request-$order',
      ),
      enqueueOrder: order,
      enqueuedAt: enqueuedAt ??
          IsoTimestamp(
            '2026-09-04T14:${(order % 60).toString().padLeft(2, '0')}:00.000Z',
          ),
    );

ConversationCreationInput _creationRequest(
  String type, {
  required String name,
  required String visibility,
  String? entityType,
  String? entityId,
  List<String>? members,
  required String idempotencyKey,
  required String clientRequestId,
}) {
  final json = switch (type) {
    'channel' => <String, Object?>{
        'operation': 'create_conversation',
        'type': type,
        'name': name,
        'visibility': visibility,
        if (entityType != null || entityId != null)
          'entity': <String, Object?>{
            'type': entityType ?? 'entity-type',
            'id': entityId ?? 'entity-$name',
          },
        'idempotencyKey': idempotencyKey,
        'clientRequestId': clientRequestId,
      },
    'direct' || 'group_direct' => <String, Object?>{
        'operation': 'create_conversation',
        'type': type,
        'visibility': 'private',
        'intendedMemberUserIds': members ??
            (type == 'direct' ? ['member-$name'] : ['a-$name', 'b-$name']),
        'idempotencyKey': idempotencyKey,
        'clientRequestId': clientRequestId,
      },
    _ => throw ArgumentError.value(type, 'type', 'is unsupported'),
  };
  return ConversationCreationInput.fromJson(json);
}

List<Map<String, Object?>> _creationWireIntents(
  Map<String, Object?> record,
) =>
    ((record['payload']! as Map<String, Object?>)['intents']! as List<Object?>)
        .cast<Map<String, Object?>>();

ApplicationChatQueuedConversationPreferenceIntentsRecord _preferenceRecord(
  ApplicationChatStorageIdentity identity,
) =>
    ApplicationChatQueuedConversationPreferenceIntentsRecord(
      identity: identity,
      intents: [_preferenceIntent(1)],
    );

ApplicationChatQueuedConversationPreferenceIntent _preferenceIntent(
  int order, {
  String conversation = 'conversation-1',
  String notification = 'all',
  bool starred = false,
  Map<String, Object?> mute = const {'muted': false},
  int expectedRevision = 1,
  String? idempotencyKey,
  IsoTimestamp? enqueuedAt,
}) =>
    ApplicationChatQueuedConversationPreferenceIntent(
      request: _preferenceRequest(
        conversation: conversation,
        notification: notification,
        starred: starred,
        mute: mute,
        expectedRevision: expectedRevision,
        idempotencyKey: idempotencyKey ?? 'preference-key-$order',
      ),
      enqueueOrder: order,
      enqueuedAt: enqueuedAt ??
          IsoTimestamp(
            '2026-09-04T15:${(order % 60).toString().padLeft(2, '0')}:00.000Z',
          ),
    );

UpdateConversationPreferenceInput _preferenceRequest({
  required String conversation,
  required String notification,
  required bool starred,
  required Map<String, Object?> mute,
  required int expectedRevision,
  required String idempotencyKey,
}) =>
    UpdateConversationPreferenceInput.fromJson(<String, Object?>{
      'operation': 'update_conversation_preference',
      'conversationId': conversation,
      'expectedPreferenceRevision': expectedRevision,
      'idempotencyKey': idempotencyKey,
      'notificationPreference': notification,
      'isStarred': starred,
      'mute': Map<String, Object?>.from(mute),
    });

List<Map<String, Object?>> _preferenceWireIntents(
  Map<String, Object?> record,
) =>
    ((record['payload']! as Map<String, Object?>)['intents']! as List<Object?>)
        .cast<Map<String, Object?>>();

ApplicationChatQueuedThreadFollowIntentsRecord _threadFollowRecord(
  ApplicationChatStorageIdentity identity,
) =>
    ApplicationChatQueuedThreadFollowIntentsRecord(
      identity: identity,
      intents: [_threadFollowIntent(1)],
    );

ApplicationChatQueuedThreadFollowIntent _threadFollowIntent(
  int order, {
  String thread = 'thread-1',
  String intent = 'follow',
  int expectedRevision = 1,
  String? idempotencyKey,
  IsoTimestamp? enqueuedAt,
}) =>
    ApplicationChatQueuedThreadFollowIntent(
      request: SetThreadFollowInput.fromJson(<String, Object?>{
        'operation': 'set_thread_follow',
        'intent': intent,
        'target': <String, Object?>{'type': 'thread', 'id': thread},
        'expectedFollowRevision': expectedRevision,
        'idempotencyKey': idempotencyKey ?? 'thread-follow-key-$order',
      }),
      enqueueOrder: order,
      enqueuedAt: enqueuedAt ??
          IsoTimestamp(
            '2026-09-04T16:${(order % 60).toString().padLeft(2, '0')}:00.000Z',
          ),
    );

List<Map<String, Object?>> _threadFollowWireIntents(
  Map<String, Object?> record,
) =>
    ((record['payload']! as Map<String, Object?>)['intents']! as List<Object?>)
        .cast<Map<String, Object?>>();

ApplicationChatQueuedMessageReminderIntentsRecord _messageReminderRecord(
  ApplicationChatStorageIdentity identity,
) =>
    ApplicationChatQueuedMessageReminderIntentsRecord(
      identity: identity,
      intents: [_messageReminderIntent(1)],
    );

ApplicationChatQueuedMessageReminderIntent _messageReminderIntent(
  int order, {
  String conversation = 'conversation-1',
  String message = 'message-1',
  String intent = 'set',
  int expectedRevision = 1,
  String? idempotencyKey,
  String dueAt = '2035-01-02T03:04:05.000Z',
  IsoTimestamp? enqueuedAt,
}) =>
    ApplicationChatQueuedMessageReminderIntent(
      request: MessageReminderRequest.fromJson(
        <String, Object?>{
          'operation': 'message_reminder.v1',
          'intent': intent,
          'conversationId': conversation,
          'messageId': message,
          'expectedReminderRevision': expectedRevision,
          'idempotencyKey': idempotencyKey ?? 'message-reminder-key-$order',
          if (intent == 'set') 'dueAt': dueAt,
        },
        referenceTime: DateTime.fromMillisecondsSinceEpoch(0, isUtc: true),
      ),
      enqueueOrder: order,
      enqueuedAt: enqueuedAt ??
          IsoTimestamp(
            '2026-09-04T17:${(order % 60).toString().padLeft(2, '0')}:00.000Z',
          ),
    );

List<Map<String, Object?>> _messageReminderWireIntents(
  Map<String, Object?> record,
) =>
    ((record['payload']! as Map<String, Object?>)['intents']! as List<Object?>)
        .cast<Map<String, Object?>>();

ApplicationChatQueuedConversationArchiveIntentsRecord
    _conversationArchiveRecord(
  ApplicationChatStorageIdentity identity,
) =>
        ApplicationChatQueuedConversationArchiveIntentsRecord(
          identity: identity,
          intents: [_conversationArchiveIntent(1)],
        );

ApplicationChatQueuedConversationArchiveIntent _conversationArchiveIntent(
  int order, {
  String conversation = 'conversation-1',
  String intent = 'archive',
  int expectedRevision = 1,
  String? idempotencyKey,
  IsoTimestamp? enqueuedAt,
}) =>
    ApplicationChatQueuedConversationArchiveIntent(
      request: ConversationArchiveInput.fromJson(<String, Object?>{
        'operation': 'set_conversation_archive',
        'intent': intent,
        'conversationId': conversation,
        'expectedLifecycleRevision': expectedRevision,
        'idempotencyKey': idempotencyKey ?? 'conversation-archive-key-$order',
      }),
      enqueueOrder: order,
      enqueuedAt: enqueuedAt ??
          IsoTimestamp(
            '2026-09-04T18:${(order % 60).toString().padLeft(2, '0')}:00.000Z',
          ),
    );

List<Map<String, Object?>> _conversationArchiveWireIntents(
  Map<String, Object?> record,
) =>
    ((record['payload']! as Map<String, Object?>)['intents']! as List<Object?>)
        .cast<Map<String, Object?>>();

ApplicationChatQueuedMessageMutationIntentsRecord _mutationRecord(
  ApplicationChatStorageIdentity identity,
) =>
    ApplicationChatQueuedMessageMutationIntentsRecord(
      identity: identity,
      intents: [_mutationIntent(1, 'forward_message.v1')],
    );

ApplicationChatQueuedMessageMutationIntent _mutationIntent(
  int order,
  String operation, {
  String? lane,
  String? correlation,
  String? idempotencyKey,
  String? reactionKey,
  int expectedRevision = 1,
  String? text,
  IsoTimestamp? enqueuedAt,
}) {
  final suffix = lane ?? '$order';
  final requestJson = switch (operation) {
    'forward_message.v1' => <String, Object?>{
        'operation': operation,
        'sourceMessageId': 'source-$suffix',
        'destinationConversationId': 'destination-$suffix',
        'clientCorrelationId': correlation ?? 'correlation-$order',
        'idempotencyKey': idempotencyKey ?? 'mutation-key-$order',
      },
    'edit' => <String, Object?>{
        'operation': operation,
        'messageId': 'message-$suffix',
        'expectedRevision': expectedRevision,
        'content': <String, Object?>{
          'format': 'plain',
          'text': text ?? 'edited $order',
        },
        'idempotencyKey': idempotencyKey ?? 'mutation-key-$order',
      },
    'soft_delete' => <String, Object?>{
        'operation': operation,
        'messageId': 'message-$suffix',
        'expectedRevision': expectedRevision,
        'idempotencyKey': idempotencyKey ?? 'mutation-key-$order',
      },
    'add_reaction' || 'remove_reaction' => <String, Object?>{
        'operation': operation,
        'messageId': 'message-$suffix',
        'reactionKey': reactionKey ?? 'reaction-$suffix',
        'idempotencyKey': idempotencyKey ?? 'mutation-key-$order',
      },
    _ => throw ArgumentError.value(operation, 'operation', 'is unsupported'),
  };
  final request = switch (operation) {
    'forward_message.v1' => ForwardMessageRequest.fromJson(requestJson),
    'edit' => EditMessageRequest.fromJson(requestJson),
    'soft_delete' => SoftDeleteMessageRequest.fromJson(requestJson),
    'add_reaction' ||
    'remove_reaction' =>
      ReactionMutationInput.fromJson(requestJson),
    _ => throw ArgumentError.value(operation, 'operation', 'is unsupported'),
  };
  return ApplicationChatQueuedMessageMutationIntent(
    request: request,
    enqueueOrder: order,
    enqueuedAt: enqueuedAt ??
        IsoTimestamp(
          '2026-09-03T13:${(order % 60).toString().padLeft(2, '0')}:00.000Z',
        ),
  );
}

Map<String, Object?> _mutationWireIntent(Map<String, Object?> record) =>
    (((record['payload']! as Map<String, Object?>)['intents']! as List<Object?>)
        .single)! as Map<String, Object?>;

ApplicationChatQueuedDraftIntentsRecord _draftRecord(
  ApplicationChatStorageIdentity identity,
) =>
    ApplicationChatQueuedDraftIntentsRecord(
      identity: identity,
      intents: [_draftIntent(1)],
    );

ApplicationChatQueuedDraftIntent _draftIntent(
  int order, {
  String conversation = 'conversation-1',
  bool clear = false,
  int baseRevision = 1,
  String? deviceMutationId,
  String? idempotencyKey,
  IsoTimestamp? enqueuedAt,
}) =>
    ApplicationChatQueuedDraftIntent(
      request: _draftRequest(
        order,
        conversation: conversation,
        clear: clear,
        baseRevision: baseRevision,
        deviceMutationId: deviceMutationId,
        idempotencyKey: idempotencyKey,
      ),
      enqueueOrder: order,
      enqueuedAt: enqueuedAt ?? const IsoTimestamp('2026-09-03T12:01:00.000Z'),
    );

SynchronizeDraftInput _draftRequest(
  int order, {
  String conversation = 'conversation-1',
  bool clear = false,
  int baseRevision = 1,
  String? deviceMutationId,
  String? idempotencyKey,
}) =>
    SynchronizeDraftInput.fromJson(<String, Object?>{
      'operation': draftMutationOperation,
      'intent': clear ? 'clear' : 'replace',
      'conversationId': conversation,
      'baseRevision': baseRevision,
      'deviceMutationId': deviceMutationId ?? 'draft-mutation-$order',
      'idempotencyKey': idempotencyKey ?? 'draft-key-$order',
      if (!clear)
        'content': <String, Object?>{
          'format': 'markdown',
          'text': 'draft $order',
          'mentions': <Object?>[
            <String, Object?>{'type': 'user', 'userId': 'mentioned-user'},
          ],
          'attachments': <Object?>[
            <String, Object?>{'attachmentId': 'attachment-$order'},
          ],
        },
    });

Map<String, Object?> _draftWireIntent(Map<String, Object?> record) =>
    (((record['payload']! as Map<String, Object?>)['intents']! as List<Object?>)
        .single)! as Map<String, Object?>;

Map<String, Object?> _deepJsonCopy(Map<String, Object?> value) =>
    jsonDecode(jsonEncode(value))! as Map<String, Object?>;

List<ApplicationChatQueuedSendMessageIntent> _queuedSendIntents(int count) =>
    List.generate(count, (index) => _queuedSendIntent(index + 1));

ApplicationChatQueuedSendMessageIntent _queuedSendIntent(int order) =>
    ApplicationChatQueuedSendMessageIntent(
      request: SendMessageRequest.fromJson({
        'operation': 'send',
        'conversationId': 'conversation-1',
        'content': {'format': 'plain', 'text': 'Queued $order'},
        'clientMessageId': 'client-message-$order',
        'idempotencyKey': 'send-key-$order',
      }),
      enqueueOrder: order,
      enqueuedAt: const IsoTimestamp('2026-08-26T16:01:00.000Z'),
    );

ApplicationChatQueuedSendMessageIntent _queuedSendIntentWithText(String text) =>
    ApplicationChatQueuedSendMessageIntent(
      request: SendMessageRequest.fromJson({
        'operation': 'send',
        'conversationId': 'conversation-1',
        'content': {'format': 'plain', 'text': text},
        'clientMessageId': 'client-message-1',
        'idempotencyKey': 'send-key-1',
      }),
      enqueueOrder: 1,
      enqueuedAt: const IsoTimestamp('2026-08-26T16:01:00.000Z'),
    );

Map<String, Object?> _queuedSendIntentJson(String text) => <String, Object?>{
      'contractVersion': applicationChatSendMessageContractVersion,
      'enqueueOrder': 1,
      'enqueuedAt': '2026-08-26T16:01:00.000Z',
      'conversationId': 'conversation-1',
      'content': <String, Object?>{'format': 'plain', 'text': text},
      'clientMessageId': 'client-message-1',
      'idempotencyKey': 'send-key-1',
    };

ApplicationChatStorageIdentity _identity({
  String tenant = 'tenant-1',
  String user = 'user-1',
  String device = 'device-1',
}) =>
    ApplicationChatStorageIdentity(
      tenantId: TenantId(tenant),
      userId: UserId(user),
      deviceId: DeviceId(device),
    );

ApplicationChatNormalizedSnapshotRecord _snapshotRecord(
  ApplicationChatStorageIdentity identity,
) {
  final metadata = <String, Object?>{
    'packageVersion': '0.1.3',
    'protocolVersion': 1,
    'schemaVersion': 1,
    'enabledFeatures': {conversationSnapshotFeature: true},
    'supportedProtocolRange': {
      'minimumVersion': 1,
      'maximumVersion': 1,
    },
    'feature': {
      'name': conversationSnapshotFeature,
      'version': conversationSnapshotVersion,
    },
  };
  final summary = <String, Object?>{
    'id': 'conversation-1',
    'tenantId': identity.tenantId.value,
    'type': 'channel',
    'name': 'Stored channel',
    'visibility': 'private',
    'createdAt': '2026-08-26T16:00:00.000Z',
    'updatedAt': '2026-08-26T16:00:00.000Z',
    'latestSequence': 1,
    'activityAt': '2026-08-26T16:00:00.000Z',
    'unreadMentionCount': 0,
    'currentMember': {
      'tenantId': identity.tenantId.value,
      'conversationId': 'conversation-1',
      'userId': identity.userId.value,
      'role': 'member',
      'state': 'active',
      'joinedAt': '2026-08-26T16:00:00.000Z',
      'updatedAt': '2026-08-26T16:00:00.000Z',
    },
    'currentReadState': {
      'conversationId': 'conversation-1',
      'userId': identity.userId.value,
      'lastReadSequence': 1,
      'updatedAt': '2026-08-26T16:00:00.000Z',
    },
    'currentPreference': {
      'conversationId': 'conversation-1',
      'userId': identity.userId.value,
      'notificationPreference': 'mentions',
      'isStarred': false,
      'mute': {'muted': false},
      'updatedAt': '2026-08-26T16:00:00.000Z',
    },
    'activeMemberUserIds': [identity.userId.value],
  };
  final message = <String, Object?>{
    'id': 'm-1',
    'tenantId': identity.tenantId.value,
    'conversationId': 'conversation-1',
    'author': {'type': 'user', 'userId': identity.userId.value},
    'sequence': 1,
    'createdAt': '2026-08-26T16:00:00.000Z',
    'updatedAt': '2026-08-26T16:00:00.000Z',
    'revision': {'revision': 1},
    'content': {'format': 'markdown', 'text': 'Stored message'},
    'isThreadRoot': false,
    'reactions': <Object?>[],
    'attachmentMetadata': <Object?>[],
  };
  final store = NormalizedSnapshotStore()
    ..hydrateConversationList(
      ConversationListSnapshot.fromJson({
        'kind': 'conversation_list',
        'scope': {'type': 'organization'},
        'items': [summary],
        'page': <String, Object?>{},
        '_meta': metadata,
      }),
    )
    ..hydrateConversationDetail(
      ConversationDetailSnapshot.fromJson({
        'kind': 'conversation_detail',
        'conversation': {
          ...summary,
          'memberUserIds': [identity.userId.value],
          'currentPreference': {
            'conversationId': 'conversation-1',
            'userId': identity.userId.value,
            'notificationPreference': 'mentions',
            'isStarred': false,
            'mute': {'muted': false},
            'updatedAt': '2026-08-26T16:00:00.000Z',
          },
        },
        '_meta': metadata,
      }),
    )
    ..hydrateMessageTimeline(
      MessageTimelinePage.fromJson(
        {
          'conversationId': 'conversation-1',
          'messages': [message],
          'pagination': {
            'older': {'available': false},
            'newer': {'available': false},
          },
          'replay': {
            'resumeFrom': {'eventId': 'event-1'},
          },
        },
        request: MessageTimelineRequest.fromJson({
          'conversationId': 'conversation-1',
          'direction': 'backward',
          'limit': 20,
        }),
      ),
    );
  return ApplicationChatNormalizedSnapshotRecord(
    identity: identity,
    snapshot: store.state,
  );
}

Future<void> _putAllKinds(
  InMemoryApplicationChatStorage storage,
  ApplicationChatStorageIdentity identity,
) async {
  await storage.replace(
    ApplicationChatRealtimeCursorRecord(
      identity: identity,
      cursor: const EventCursor(eventId: 'event-1'),
    ),
  );
  await storage.replace(_snapshotRecord(identity));
  await storage.replace(
    ApplicationChatQueuedCommandMetadataRecord(
      identity: identity,
      commands: const [],
    ),
  );
  await storage.replace(
    ApplicationChatQueuedSendMessageIntentsRecord(
      identity: identity,
      intents: const [],
    ),
  );
  await storage.replace(
    ApplicationChatQueuedReadCursorIntentsRecord(
      identity: identity,
      intents: const [],
    ),
  );
  await storage.replace(
    ApplicationChatQueuedMessageMutationIntentsRecord(
      identity: identity,
      intents: const [],
    ),
  );
  await storage.replace(
    ApplicationChatQueuedConversationMembershipIntentsRecord(
      identity: identity,
      intents: const [],
    ),
  );
  await storage.replace(
    ApplicationChatQueuedConversationCreationIntentsRecord(
      identity: identity,
      intents: const [],
    ),
  );
  await storage.replace(
    ApplicationChatQueuedConversationPreferenceIntentsRecord(
      identity: identity,
      intents: const [],
    ),
  );
  await storage.replace(
    ApplicationChatQueuedThreadFollowIntentsRecord(
      identity: identity,
      intents: const [],
    ),
  );
  await storage.replace(
    ApplicationChatQueuedMessageReminderIntentsRecord(
      identity: identity,
      intents: const [],
    ),
  );
  await storage.replace(
    ApplicationChatQueuedConversationArchiveIntentsRecord(
      identity: identity,
      intents: const [],
    ),
  );
  await storage.replace(
    ApplicationChatQueuedHuddleCommandIntentsRecord(
      identity: identity,
      intents: const [],
    ),
  );
  await storage.replace(
    ApplicationChatQueuedDraftIntentsRecord(
      identity: identity,
      intents: const [],
    ),
  );
  await storage.replace(
    ApplicationChatPushTokenRevisionsRecord(
      identity: identity,
      revisions: const [],
    ),
  );
}

Future<int> _recordCount(
  InMemoryApplicationChatStorage storage,
  ApplicationChatStorageIdentity identity,
) async {
  var count = 0;
  for (final kind in ApplicationChatStorageRecordKind.values) {
    if (await storage.read(identity, kind) != null) count += 1;
  }
  return count;
}

Iterable<String> _allKeys(Object? value) sync* {
  if (value is List<Object?>) {
    for (final item in value) {
      yield* _allKeys(item);
    }
  } else if (value is Map<Object?, Object?>) {
    for (final entry in value.entries) {
      if (entry.key case final String key) yield key;
      yield* _allKeys(entry.value);
    }
  }
}

final class _AtomicMutationStorage implements AtomicApplicationChatStorage {
  _AtomicMutationStorage({
    this.encoded,
    this.alwaysContended = false,
    this.replaceBeforeFirstCompare,
  });

  String? encoded;
  final bool alwaysContended;
  String? replaceBeforeFirstCompare;
  int readEncodedCount = 0;
  int compareExchangeCount = 0;
  int replaceCount = 0;
  int removeCount = 0;

  @override
  Future<ApplicationChatStorageRecord?> read(
    ApplicationChatStorageIdentity identity,
    ApplicationChatStorageRecordKind kind,
  ) async {
    final value = encoded;
    if (value == null) return null;
    return ApplicationChatStorageRecord.decode(value);
  }

  @override
  Future<String?> readEncoded(
    ApplicationChatStorageIdentity identity,
    ApplicationChatStorageRecordKind kind,
  ) async {
    readEncodedCount += 1;
    return encoded;
  }

  @override
  Future<void> replace(ApplicationChatStorageRecord record) async {
    replaceCount += 1;
    encoded = record.encode();
  }

  @override
  Future<void> remove(
    ApplicationChatStorageIdentity identity,
    ApplicationChatStorageRecordKind kind,
  ) async {
    removeCount += 1;
    encoded = null;
  }

  @override
  Future<bool> compareExchange(
    ApplicationChatStorageIdentity identity,
    ApplicationChatStorageRecordKind kind,
    String? expectedEncodedRecord,
    String? replacementEncodedRecord,
  ) async {
    compareExchangeCount += 1;
    final concurrent = replaceBeforeFirstCompare;
    if (concurrent != null) {
      encoded = concurrent;
      replaceBeforeFirstCompare = null;
    }
    if (alwaysContended || encoded != expectedEncodedRecord) return false;
    encoded = replacementEncodedRecord;
    return true;
  }

  @override
  Future<void> clearForLogout(
    ApplicationChatStorageIdentity previousIdentity,
  ) async {}

  @override
  Future<void> clearForIdentityChange({
    required ApplicationChatStorageIdentity previousIdentity,
    required ApplicationChatStorageIdentity nextIdentity,
  }) async {}
}

final class _LegacyMutationStorage implements ApplicationChatStorage {
  String? encoded;
  int replaceCount = 0;
  int removeCount = 0;

  @override
  Future<ApplicationChatStorageRecord?> read(
    ApplicationChatStorageIdentity identity,
    ApplicationChatStorageRecordKind kind,
  ) async {
    final value = encoded;
    if (value == null) return null;
    return ApplicationChatStorageRecord.decode(value);
  }

  @override
  Future<void> replace(ApplicationChatStorageRecord record) async {
    replaceCount += 1;
    encoded = record.encode();
  }

  @override
  Future<void> remove(
    ApplicationChatStorageIdentity identity,
    ApplicationChatStorageRecordKind kind,
  ) async {
    removeCount += 1;
    encoded = null;
  }

  @override
  Future<void> clearForLogout(
    ApplicationChatStorageIdentity previousIdentity,
  ) async {}

  @override
  Future<void> clearForIdentityChange({
    required ApplicationChatStorageIdentity previousIdentity,
    required ApplicationChatStorageIdentity nextIdentity,
  }) async {}
}
