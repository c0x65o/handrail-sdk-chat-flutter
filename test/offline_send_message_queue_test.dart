import 'dart:async';
import 'dart:convert';

import 'package:handrail_chat/core.dart';
import 'package:handrail_chat/testing.dart' show InMemoryApplicationChatStorage;
import 'package:test/test.dart';

void main() {
  group('offline send-message persistence', () {
    for (final destination in ['channel-1', 'thread-1']) {
      for (final notifyAuthor in [true, false]) {
        test('reply round trip: $destination, notifyAuthor=$notifyAuthor',
            () async {
          final storage = InMemoryApplicationChatStorage();
          final first = _fixture(storage: storage);
          final reply = MessageReplyReference(
            messageId: const MessageId('source-message'),
            notifyAuthor: notifyAuthor,
          );
          expect(
            await first.client.sendMessage(ChatSendMessageInput(
              conversationId: ConversationId(destination),
              content: _input('Friday').content,
              replyTo: reply,
            )),
            isA<ChatCommandQueued<SendMessageResult>>(),
          );
          final original = first.client.queuedSendMessages.single.request;
          expect(original.replyTo?.toJson(), reply.toJson());
          final encoded = (await storage.readEncoded(
            _identity(),
            ApplicationChatStorageRecordKind.queuedSendMessageIntents,
          ))!;
          final decoded = ApplicationChatStorageRecord.decode(encoded)
              as ApplicationChatQueuedSendMessageIntentsRecord;
          expect(decoded.intents.single.request.toJson(), original.toJson());
          expect(decoded.encode(), encoded);
          await first.dispose();

          // Reconstruct both the adapter and client from encoded bytes.
          final restoredStorage = InMemoryApplicationChatStorage();
          restoredStorage.putRawRecordForTesting(
            _identity(),
            ApplicationChatStorageRecordKind.queuedSendMessageIntents,
            jsonDecode(encoded),
          );
          final restarted = _fixture(storage: restoredStorage);
          await restarted.client.activateStorageIdentity(_identity());
          await restarted.client.activateStorageIdentity(_identity());
          expect(restarted.client.queuedSendMessages, hasLength(1));
          expect(restarted.client.queuedSendMessages.single.request.toJson(),
              original.toJson());
          expect(restarted.http.requests, isEmpty);
          await restarted.dispose();

          for (final other in [
            _identity(user: 'other-user'),
            _identity(device: 'other-device'),
            _identity(tenant: 'other-tenant'),
          ]) {
            final isolated =
                _fixture(storage: restoredStorage, identity: other);
            await isolated.client.activateStorageIdentity(other);
            expect(isolated.client.queuedSendMessages, isEmpty);
            await isolated.dispose();
          }
          expect(
              await restoredStorage.readEncoded(_identity(),
                  ApplicationChatStorageRecordKind.queuedSendMessageIntents),
              encoded);
        });
      }
    }

    for (final malformed in <Object?>[
      null,
      'source-message',
      {'messageId': '', 'notifyAuthor': false},
      {'messageId': 'source-message'},
      {'messageId': 'source-message', 'notifyAuthor': 'false'},
      {
        'messageId': 'source-message',
        'notifyAuthor': false,
        'accessToken': 'hidden'
      },
    ]) {
      test('malformed reply is quarantined: ${jsonEncode(malformed)}',
          () async {
        final storage = InMemoryApplicationChatStorage();
        final raw = _queuedSendRecord(_identity(),
                clientMessageId: 'bad-client',
                idempotencyKey: 'bad-key',
                text: 'bad')
            .toJson();
        final intent =
            ((raw['payload'] as Map)['intents'] as List).single as Map;
        intent['replyTo'] = malformed;
        expect(() => ApplicationChatStorageRecord.decode(jsonEncode(raw)),
            throwsFormatException);
        storage.putRawRecordForTesting(_identity(),
            ApplicationChatStorageRecordKind.queuedSendMessageIntents, raw);
        final fixture = _fixture(storage: storage);
        await fixture.client.activateStorageIdentity(_identity());
        expect(fixture.client.queuedSendMessages, isEmpty);
        expect(
            await storage.readEncoded(_identity(),
                ApplicationChatStorageRecordKind.queuedSendMessageIntents),
            isNull);
        expect(fixture.http.requests, isEmpty);
        await fixture.dispose();
      });
    }

    test('reply metadata counts toward the intent byte limit', () {
      final ordinary = _queuedSendRecord(_identity(),
              clientMessageId: 'client', idempotencyKey: 'key', text: '')
          .intents
          .single
          .toJson();
      final remaining = maxApplicationChatQueuedSendIntentBytes -
          utf8.encode(jsonEncode(ordinary)).length;
      (ordinary['content'] as Map)['text'] = 'x' * remaining;
      expect(
          ApplicationChatQueuedSendMessageIntent.fromJson(ordinary)
              .request
              .replyTo,
          isNull);
      final withReply = {
        ...ordinary,
        'replyTo': {
          'messageId': 'source-message',
          'notifyAuthor': false,
        }
      };
      expect(() => ApplicationChatQueuedSendMessageIntent.fromJson(withReply),
          throwsFormatException);
      final request =
          ApplicationChatQueuedSendMessageIntent.fromJson(ordinary).request;
      expect(
          () => ApplicationChatQueuedSendMessageIntent(
                request: SendMessageRequest(
                  conversationId: request.conversationId,
                  content: request.content,
                  clientMessageId: request.clientMessageId,
                  idempotencyKey: request.idempotencyKey,
                  replyTo: MessageReplyReference(
                      messageId: const MessageId('source-message'),
                      notifyAuthor: false),
                ),
                enqueueOrder: 1,
                enqueuedAt: const IsoTimestamp('2026-08-26T16:01:00.000Z'),
              ),
          throwsArgumentError);
    });

    test('validates generated identities before storage access', () async {
      final storage = _CountingStorage(InMemoryApplicationChatStorage());
      final fixture = _fixture(
        storage: storage,
        clientMessageIds: const ['   '],
      );
      await fixture.client.activateStorageIdentity(_identity());
      storage.resetCounts();

      expect(
        await fixture.client.sendMessage(_input('invalid identity')),
        isA<ChatCommandValidationFailure<SendMessageResult>>(),
      );
      expect(storage.readCount, 0);
      expect(storage.replaceCount, 0);
      expect(fixture.tokenCalls, 0);
      await fixture.dispose();
    });

    test('persists before publishing or returning queued state', () async {
      final backing = InMemoryApplicationChatStorage();
      final storage = _BlockingStorage(backing);
      final fixture = _fixture(storage: storage);
      var completed = false;

      final pending = fixture.client.sendMessage(_input('first'))
        ..then((_) => completed = true);
      await storage.replaceStarted.future;

      expect(completed, isFalse);
      expect(fixture.client.queuedSendMessages, isEmpty);
      expect(fixture.http.requests, isEmpty);
      expect(fixture.tokenCalls, 0);

      storage.releaseReplace.complete();
      final result = await pending;
      expect(result, isA<ChatCommandQueued<SendMessageResult>>());
      expect(result.category, ChatCommandResultCategory.queued);
      expect(fixture.client.queuedSendMessages, hasLength(1));
      expect(
        backing.rawRecordForTesting(
          _identity(),
          ApplicationChatStorageRecordKind.queuedSendMessageIntents,
        ),
        isNotNull,
      );
      await fixture.dispose();
    });

    test('two queue instances preserve concurrent distinct sends', () async {
      final storage = InMemoryApplicationChatStorage();
      final first = _fixture(
        storage: storage,
        clientMessageIds: const ['client-a'],
        idempotencyKeys: const ['key-a'],
      );
      final second = _fixture(
        storage: storage,
        clientMessageIds: const ['client-b'],
        idempotencyKeys: const ['key-b'],
      );
      await first.client.activateStorageIdentity(_identity());
      await second.client.activateStorageIdentity(_identity());

      final results = await Future.wait([
        first.client.sendMessage(_input('a')),
        second.client.sendMessage(_input('b')),
      ]);

      expect(
          results, everyElement(isA<ChatCommandQueued<SendMessageResult>>()));
      final record = await storage.read(
        _identity(),
        ApplicationChatStorageRecordKind.queuedSendMessageIntents,
      ) as ApplicationChatQueuedSendMessageIntentsRecord;
      expect(
        record.intents.map((intent) => intent.request.clientMessageId).toSet(),
        {'client-a', 'client-b'},
      );
      expect(record.intents.map((intent) => intent.enqueueOrder), [1, 2]);

      await first.dispose();
      await second.dispose();
    });

    test('concurrent duplicate correlations yield one durable winner',
        () async {
      Future<void> expectOneWinner({
        required List<String> clientMessageIds,
        required List<String> idempotencyKeys,
      }) async {
        final storage = InMemoryApplicationChatStorage();
        final first = _fixture(
          storage: storage,
          clientMessageIds: [clientMessageIds[0]],
          idempotencyKeys: [idempotencyKeys[0]],
        );
        final second = _fixture(
          storage: storage,
          clientMessageIds: [clientMessageIds[1]],
          idempotencyKeys: [idempotencyKeys[1]],
        );
        await first.client.activateStorageIdentity(_identity());
        await second.client.activateStorageIdentity(_identity());

        final results = await Future.wait([
          first.client.sendMessage(_input('a')),
          second.client.sendMessage(_input('b')),
        ]);

        expect(
          results.whereType<ChatCommandQueued<SendMessageResult>>(),
          hasLength(1),
        );
        final record = await storage.read(
          _identity(),
          ApplicationChatStorageRecordKind.queuedSendMessageIntents,
        ) as ApplicationChatQueuedSendMessageIntentsRecord;
        expect(record.intents, hasLength(1));
        await first.dispose();
        await second.dispose();
      }

      await expectOneWinner(
        clientMessageIds: const ['same-client', 'same-client'],
        idempotencyKeys: const ['key-a', 'key-b'],
      );
      await expectOneWinner(
        clientMessageIds: const ['client-a', 'client-b'],
        idempotencyKeys: const ['same-key', 'same-key'],
      );
    });

    test('concurrent sends re-check durable capacity after contention',
        () async {
      final storage = InMemoryApplicationChatStorage();
      await storage.replace(
        ApplicationChatQueuedSendMessageIntentsRecord(
          identity: _identity(),
          intents: _queuedSendIntents(
            maxApplicationChatQueuedSendIntents - 1,
          ),
        ),
      );
      final first = _fixture(
        storage: storage,
        clientMessageIds: const ['client-capacity-a'],
        idempotencyKeys: const ['key-capacity-a'],
      );
      final second = _fixture(
        storage: storage,
        clientMessageIds: const ['client-capacity-b'],
        idempotencyKeys: const ['key-capacity-b'],
      );
      await first.client.activateStorageIdentity(_identity());
      await second.client.activateStorageIdentity(_identity());

      final results = await Future.wait([
        first.client.sendMessage(_input('a')),
        second.client.sendMessage(_input('b')),
      ]);

      expect(
        results.whereType<ChatCommandQueued<SendMessageResult>>(),
        hasLength(1),
      );
      expect(
        results.whereType<ChatCommandValidationFailure<SendMessageResult>>(),
        hasLength(1),
      );
      final record = await storage.read(
        _identity(),
        ApplicationChatStorageRecordKind.queuedSendMessageIntents,
      ) as ApplicationChatQueuedSendMessageIntentsRecord;
      expect(record.intents, hasLength(maxApplicationChatQueuedSendIntents));
      expect(record.intents.last.enqueueOrder,
          maxApplicationChatQueuedSendIntents);
      await first.dispose();
      await second.dispose();
    });

    test('cancellation preserves a concurrent append', () async {
      final storage = _InterleavingAtomicStorage();
      final first = _fixture(
        storage: storage,
        clientMessageIds: const ['client-a'],
        idempotencyKeys: const ['key-a'],
      );
      final second = _fixture(
        storage: storage,
        clientMessageIds: const ['client-b'],
        idempotencyKeys: const ['key-b'],
      );
      await first.client.activateStorageIdentity(_identity());
      await second.client.activateStorageIdentity(_identity());
      await first.client.sendMessage(_input('a'));
      storage.beforeNextCompareExchange = () async {
        expect(
          await second.client.sendMessage(_input('b')),
          isA<ChatCommandQueued<SendMessageResult>>(),
        );
      };

      expect(await first.client.cancelQueuedSendMessage('client-a'), isTrue);

      final record = await storage.backing.read(
        _identity(),
        ApplicationChatStorageRecordKind.queuedSendMessageIntents,
      ) as ApplicationChatQueuedSendMessageIntentsRecord;
      expect(record.intents.single.request.clientMessageId, 'client-b');
      expect(
        first.client.queuedSendMessages.single.clientMessageId,
        'client-b',
      );
      await first.dispose();
      await second.dispose();
    });

    test('cancellation preserves a concurrent replacement', () async {
      final storage = _InterleavingAtomicStorage();
      final fixture = _fixture(
        storage: storage,
        clientMessageIds: const ['client-original'],
        idempotencyKeys: const ['key-original'],
      );
      await fixture.client.sendMessage(_input('original'));
      final replacement = _queuedSendRecord(
        _identity(),
        clientMessageId: 'client-replacement',
        idempotencyKey: 'key-replacement',
        text: 'replacement',
      );
      storage.beforeNextCompareExchange = () => storage.backing.replace(
            replacement,
          );

      expect(
        await fixture.client.cancelQueuedSendMessage('client-original'),
        isFalse,
      );

      final record = await storage.backing.read(
        _identity(),
        ApplicationChatStorageRecordKind.queuedSendMessageIntents,
      ) as ApplicationChatQueuedSendMessageIntentsRecord;
      expect(
          record.intents.single.request.clientMessageId, 'client-replacement');
      expect(fixture.client.queuedSendMessages.single.clientMessageId,
          'client-replacement');
      await fixture.dispose();
    });

    test('malformed quarantine preserves and hydrates a valid replacement',
        () async {
      final storage = _InterleavingAtomicStorage();
      final identity = _identity();
      final malformed = _queuedSendRecord(identity,
              clientMessageId: 'bad-client',
              idempotencyKey: 'bad-key',
              text: 'bad')
          .toJson();
      final intent =
          ((malformed['payload'] as Map)['intents'] as List).single as Map;
      intent['replyTo'] = {
        'messageId': 'source-message',
        'notifyAuthor': 'false',
      };
      storage.backing.putRawRecordForTesting(
        identity,
        ApplicationChatStorageRecordKind.queuedSendMessageIntents,
        malformed,
      );
      final replacement = _queuedSendRecord(
        identity,
        clientMessageId: 'client-valid',
        idempotencyKey: 'key-valid',
        text: 'valid',
        replyTo: MessageReplyReference(
            messageId: const MessageId('source-valid'), notifyAuthor: false),
      );
      storage.beforeNextCompareExchange = () => storage.backing.replace(
            replacement,
          );
      final fixture = _fixture(storage: storage, identity: identity);

      await fixture.client.activateStorageIdentity(identity);

      expect(storage.removeCount, 0);
      expect(fixture.client.queuedSendMessages.single.clientMessageId,
          'client-valid');
      final durable = await storage.backing.read(
        identity,
        ApplicationChatStorageRecordKind.queuedSendMessageIntents,
      ) as ApplicationChatQueuedSendMessageIntentsRecord;
      expect(durable.intents.single.request.toJson(),
          replacement.intents.single.request.toJson());
      expect(fixture.client.queuedSendMessages.single.request.toJson(),
          replacement.intents.single.request.toJson());
      await fixture.dispose();
    });

    test('restart rehydrates once with stable identities and FIFO order',
        () async {
      final storage = InMemoryApplicationChatStorage();
      final first = _fixture(
        storage: storage,
        clientMessageIds: ['client-a', 'client-b', 'client-c'],
        idempotencyKeys: ['key-a', 'key-b', 'key-c'],
      );

      for (final text in ['a', 'b', 'c']) {
        expect(
          await first.client.sendMessage(_input(text)),
          isA<ChatCommandQueued<SendMessageResult>>(),
        );
      }
      expect(
        first.client.queuedSendMessages.map((intent) => intent.enqueueOrder),
        [1, 2, 3],
      );
      await first.dispose();

      final restarted = _fixture(
        storage: storage,
        clientMessageIds: ['unused-client'],
        idempotencyKeys: ['unused-key'],
      );
      var nonEmptyProjectionCount = 0;
      final subscription = restarted.client.queuedSendMessageStates.listen(
        (state) {
          if (state.intents.isNotEmpty) nonEmptyProjectionCount += 1;
        },
      );
      await restarted.client.activateStorageIdentity(_identity());
      await restarted.client.activateStorageIdentity(_identity());

      final restored = restarted.client.queuedSendMessages;
      expect(nonEmptyProjectionCount, 1);
      expect(restored.map((intent) => intent.clientMessageId),
          ['client-a', 'client-b', 'client-c']);
      expect(restored.map((intent) => intent.idempotencyKey),
          ['key-a', 'key-b', 'key-c']);
      expect(restored.map((intent) => intent.enqueueOrder), [1, 2, 3]);
      expect(restored.map((intent) => intent.content.text), ['a', 'b', 'c']);
      for (final intent in restored) {
        expect(intent.request.replyTo, isNull);
        expect(intent.request.toJson().containsKey('replyTo'), isFalse);
      }

      await subscription.cancel();
      await restarted.dispose();
    });

    test('isolates identity scopes and narrowly removes invalid records',
        () async {
      final storage = InMemoryApplicationChatStorage();
      final validIdentity = _identity(device: 'device-valid');
      final valid = _fixture(
        storage: storage,
        identity: validIdentity,
        clientMessageIds: ['valid-client'],
        idempotencyKeys: ['valid-key'],
      );
      await valid.client.sendMessage(_input('valid'));
      await valid.dispose();

      final validRaw = storage.rawRecordForTesting(
        validIdentity,
        ApplicationChatStorageRecordKind.queuedSendMessageIntents,
      )! as Map<String, Object?>;
      final futureIdentity = _identity(tenant: 'tenant-future');
      storage.putRawRecordForTesting(
        futureIdentity,
        ApplicationChatStorageRecordKind.queuedSendMessageIntents,
        <String, Object?>{
          ...validRaw,
          'schemaVersion': applicationChatStorageSchemaVersion + 1,
          'identity': futureIdentity.toJson(),
        },
      );
      final futureContractIdentity = _identity(user: 'user-future-contract');
      final futureContractRaw =
          jsonDecode(jsonEncode(validRaw)) as Map<String, Object?>;
      futureContractRaw['identity'] = futureContractIdentity.toJson();
      final futureContractPayload =
          futureContractRaw['payload']! as Map<String, Object?>;
      final futureContractIntent =
          (futureContractPayload['intents']! as List<Object?>).single!
              as Map<String, Object?>;
      futureContractIntent['contractVersion'] =
          applicationChatSendMessageContractVersion + 1;
      storage.putRawRecordForTesting(
        futureContractIdentity,
        ApplicationChatStorageRecordKind.queuedSendMessageIntents,
        futureContractRaw,
      );
      final corruptIdentity = _identity(user: 'user-corrupt');
      storage.putRawRecordForTesting(
        corruptIdentity,
        ApplicationChatStorageRecordKind.queuedSendMessageIntents,
        {'not': 'a record'},
      );
      final mismatchedIdentity = _identity(device: 'device-mismatch');
      storage.putRawRecordForTesting(
        mismatchedIdentity,
        ApplicationChatStorageRecordKind.queuedSendMessageIntents,
        validRaw,
      );

      for (final identity in [
        futureIdentity,
        futureContractIdentity,
        corruptIdentity,
      ]) {
        final fixture = _fixture(storage: storage, identity: identity);
        await fixture.client.activateStorageIdentity(identity);
        expect(fixture.client.queuedSendMessages, isEmpty);
        expect(
          storage.rawRecordForTesting(
            identity,
            ApplicationChatStorageRecordKind.queuedSendMessageIntents,
          ),
          isNull,
        );
        await fixture.dispose();
      }

      final mismatched = _fixture(
        storage: storage,
        identity: mismatchedIdentity,
      );
      await mismatched.client.activateStorageIdentity(mismatchedIdentity);
      expect(mismatched.client.queuedSendMessages, isEmpty);
      expect(
        storage.rawRecordForTesting(
          mismatchedIdentity,
          ApplicationChatStorageRecordKind.queuedSendMessageIntents,
        ),
        validRaw,
      );
      await mismatched.dispose();

      final validRestart = _fixture(storage: storage, identity: validIdentity);
      await validRestart.client.activateStorageIdentity(validIdentity);
      expect(
          validRestart.client.queuedSendMessages.single.content.text, 'valid');
      expect(validRestart.client.queuedSendMessages.single.identity,
          validIdentity);
      await validRestart.dispose();
    });

    test('explicit cancellation removes only its record and projection',
        () async {
      final storage = InMemoryApplicationChatStorage();
      final fixture = _fixture(
        storage: storage,
        clientMessageIds: ['client-a', 'client-b'],
        idempotencyKeys: ['key-a', 'key-b'],
      );
      await fixture.client.sendMessage(_input('a'));
      await fixture.client.sendMessage(_input('b'));

      expect(await fixture.client.cancelQueuedSendMessage('client-a'), isTrue);
      expect(
        fixture.client.queuedSendMessages
            .map((intent) => intent.clientMessageId),
        ['client-b'],
      );
      final record = await storage.read(
        _identity(),
        ApplicationChatStorageRecordKind.queuedSendMessageIntents,
      ) as ApplicationChatQueuedSendMessageIntentsRecord;
      expect(record.intents.single.request.clientMessageId, 'client-b');
      expect(await fixture.client.cancelQueuedSendMessage('missing'), isFalse);
      expect(await fixture.client.cancelQueuedSendMessage('client-b'), isTrue);
      expect(
        await storage.read(
          _identity(),
          ApplicationChatStorageRecordKind.queuedSendMessageIntents,
        ),
        isNull,
      );
      await fixture.dispose();
    });

    test('serialized queue excludes credentials, providers, and bytes',
        () async {
      final storage = InMemoryApplicationChatStorage();
      final fixture = _fixture(
        storage: storage,
        clientMessageIds: ['safe-client', 'unsafe-client', 'raw-byte-client'],
        idempotencyKeys: ['safe-key', 'unsafe-key', 'raw-byte-key'],
      );
      final safe = ChatSendMessageInput(
        conversationId: const ConversationId('conversation-1'),
        content: MessageContent(
          format: MessageContentFormat.markdown,
          text: 'safe attachment',
          attachments: const [
            MessageAttachmentReference(
              attachmentId: AttachmentId('attachment-finalized'),
            ),
          ],
        ),
      );
      await fixture.client.sendMessage(safe);
      final encoded = jsonEncode(storage.rawRecordForTesting(
        _identity(),
        ApplicationChatStorageRecordKind.queuedSendMessageIntents,
      ));
      for (final forbidden in [
        'access-token-value',
        'authorization',
        'secret',
        'providerConfiguration',
        'attachmentBytes',
      ]) {
        expect(encoded, isNot(contains(forbidden)));
      }

      final unsafe = ChatSendMessageInput(
        conversationId: const ConversationId('conversation-1'),
        content: MessageContent(
          format: MessageContentFormat.markdown,
          text: 'unsafe block',
          blocks: [
            MessageBlock(
              type: 'host-data',
              data: {
                'accessToken': 'access-token-value',
                'authorization': 'Bearer hidden',
                'secret': 'hidden',
                'providerConfiguration': {'credential': 'hidden'},
                'attachmentBytes': [1, 2, 3],
              },
            ),
          ],
        ),
      );
      expect(
        await fixture.client.sendMessage(unsafe),
        isA<ChatCommandValidationFailure<SendMessageResult>>(),
      );
      final rawBytes = ChatSendMessageInput(
        conversationId: const ConversationId('conversation-1'),
        content: MessageContent(
          format: MessageContentFormat.markdown,
          text: 'raw bytes',
          blocks: [
            MessageBlock(type: 'host-data', data: [1, 2, 3]),
          ],
        ),
      );
      expect(
        await fixture.client.sendMessage(rawBytes),
        isA<ChatCommandValidationFailure<SendMessageResult>>(),
      );
      expect(fixture.client.queuedSendMessages, hasLength(1));
      expect(fixture.tokenCalls, 0);
      await fixture.dispose();
    });

    test(
        'queued send intent capacity rejects enqueue without replacing or publishing',
        () async {
      final identity = _identity();
      final backing = InMemoryApplicationChatStorage();
      await backing.replace(
        ApplicationChatQueuedSendMessageIntentsRecord(
          identity: identity,
          intents: _queuedSendIntents(maxApplicationChatQueuedSendIntents),
        ),
      );
      final storage = _CountingStorage(backing);
      final fixture = _fixture(
        storage: storage,
        identity: identity,
        clientMessageIds: const ['client-over-capacity'],
        idempotencyKeys: const ['key-over-capacity'],
      );
      await fixture.client.activateStorageIdentity(identity);
      final publishedLengths = <int>[];
      final subscription = fixture.client.queuedSendMessageStates.listen(
        (state) => publishedLengths.add(state.intents.length),
      );
      final publishedBefore = fixture.client.queuedSendMessages
          .map((intent) => intent.clientMessageId)
          .toList(growable: false);

      final result = await fixture.client.sendMessage(_input('overflow'));

      expect(result, isA<ChatCommandValidationFailure<SendMessageResult>>());
      expect(storage.replaceCount, 0);
      expect(publishedLengths, [maxApplicationChatQueuedSendIntents]);
      expect(
        fixture.client.queuedSendMessages,
        hasLength(maxApplicationChatQueuedSendIntents),
      );
      expect(
        fixture.client.queuedSendMessages
            .map((intent) => intent.clientMessageId),
        publishedBefore,
      );
      final stored = await backing.read(
        identity,
        ApplicationChatStorageRecordKind.queuedSendMessageIntents,
      ) as ApplicationChatQueuedSendMessageIntentsRecord;
      expect(stored.intents, hasLength(maxApplicationChatQueuedSendIntents));
      expect(
        stored.intents.map((intent) => intent.request.clientMessageId),
        publishedBefore,
      );
      expect(fixture.tokenCalls, 0);
      await subscription.cancel();
      await fixture.dispose();
    });
  });
}

List<ApplicationChatQueuedSendMessageIntent> _queuedSendIntents(int count) =>
    List.generate(count, (index) {
      final order = index + 1;
      return ApplicationChatQueuedSendMessageIntent(
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
    });

ApplicationChatQueuedSendMessageIntentsRecord _queuedSendRecord(
  ApplicationChatStorageIdentity identity, {
  required String clientMessageId,
  required String idempotencyKey,
  required String text,
  MessageReplyReference? replyTo,
}) =>
    ApplicationChatQueuedSendMessageIntentsRecord(
      identity: identity,
      intents: [
        ApplicationChatQueuedSendMessageIntent(
          request: SendMessageRequest.fromJson({
            'operation': 'send',
            'conversationId': 'conversation-1',
            'content': {'format': 'plain', 'text': text},
            if (replyTo != null) 'replyTo': replyTo.toJson(),
            'clientMessageId': clientMessageId,
            'idempotencyKey': idempotencyKey,
          }),
          enqueueOrder: 1,
          enqueuedAt: const IsoTimestamp('2026-08-26T16:01:00.000Z'),
        ),
      ],
    );

ChatSendMessageInput _input(String text) => ChatSendMessageInput(
      conversationId: const ConversationId('conversation-1'),
      content: MessageContent(
        format: MessageContentFormat.markdown,
        text: text,
      ),
    );

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

_ClientFixture _fixture({
  required ApplicationChatStorage storage,
  ApplicationChatStorageIdentity? identity,
  List<String> clientMessageIds = const ['client-default'],
  List<String> idempotencyKeys = const ['key-default'],
}) {
  final network = _OfflineNetwork();
  final realtime = ChatRealtimeSessionTransport(
    endpoint: Uri.parse('https://chat.example.test/api/chat'),
    clientPackageVersion: '0.1.3',
    protocolVersion: handrailChatProtocolVersion,
    tokenProvider: () => 'realtime-token',
    socketFactory: (_, __) => throw StateError('offline socket must not open'),
    network: network,
  );
  final http = _RecordingHttpTransport();
  var tokenCalls = 0;
  var clientIndex = 0;
  var keyIndex = 0;
  final client = HandrailChatClient(
    apiBaseUri: Uri.parse('https://chat.example.test/api/chat'),
    tokenProvider: () async {
      tokenCalls += 1;
      return 'access-token-value';
    },
    transport: http,
    realtimeSession: realtime,
    localStorage: storage,
    storageIdentity: identity ?? _identity(),
    offlineSendClock: () => DateTime.utc(2026, 8, 26, 20, clientIndex),
    generateClientMessageId: () => clientMessageIds[clientIndex++],
    generateIdempotencyKey: () => idempotencyKeys[keyIndex++],
  );
  return _ClientFixture(
    client: client,
    realtime: realtime,
    http: http,
    tokenCallsValue: () => tokenCalls,
  );
}

final class _ClientFixture {
  const _ClientFixture({
    required this.client,
    required this.realtime,
    required this.http,
    required int Function() tokenCallsValue,
  }) : _tokenCallsValue = tokenCallsValue;

  final HandrailChatClient client;
  final ChatRealtimeSessionTransport realtime;
  final _RecordingHttpTransport http;
  final int Function() _tokenCallsValue;

  int get tokenCalls => _tokenCallsValue();

  Future<void> dispose() async {
    await client.dispose();
    await realtime.dispose();
  }
}

final class _OfflineNetwork implements ChatRealtimeNetwork {
  @override
  bool get isOnline => false;

  @override
  Stream<bool> get changes => const Stream<bool>.empty();
}

final class _RecordingHttpTransport implements HandrailChatHttpTransport {
  final List<HandrailChatHttpRequest> requests = [];

  @override
  Future<HandrailChatHttpResponse> send(HandrailChatHttpRequest request) async {
    requests.add(request);
    throw StateError('offline HTTP must not run');
  }
}

final class _BlockingStorage implements AtomicApplicationChatStorage {
  _BlockingStorage(this.backing);

  final InMemoryApplicationChatStorage backing;
  final Completer<void> replaceStarted = Completer<void>();
  final Completer<void> releaseReplace = Completer<void>();

  @override
  Future<ApplicationChatStorageRecord?> read(
    ApplicationChatStorageIdentity identity,
    ApplicationChatStorageRecordKind kind,
  ) =>
      backing.read(identity, kind);

  @override
  Future<String?> readEncoded(
    ApplicationChatStorageIdentity identity,
    ApplicationChatStorageRecordKind kind,
  ) =>
      backing.readEncoded(identity, kind);

  @override
  Future<bool> compareExchange(
    ApplicationChatStorageIdentity identity,
    ApplicationChatStorageRecordKind kind,
    String? expectedEncodedRecord,
    String? replacementEncodedRecord,
  ) async {
    if (kind == ApplicationChatStorageRecordKind.queuedSendMessageIntents &&
        replacementEncodedRecord != null) {
      if (!replaceStarted.isCompleted) replaceStarted.complete();
      await releaseReplace.future;
    }
    return backing.compareExchange(
      identity,
      kind,
      expectedEncodedRecord,
      replacementEncodedRecord,
    );
  }

  @override
  Future<void> replace(ApplicationChatStorageRecord record) async {
    if (record.kind ==
        ApplicationChatStorageRecordKind.queuedSendMessageIntents) {
      if (!replaceStarted.isCompleted) replaceStarted.complete();
      await releaseReplace.future;
    }
    await backing.replace(record);
  }

  @override
  Future<void> remove(
    ApplicationChatStorageIdentity identity,
    ApplicationChatStorageRecordKind kind,
  ) =>
      backing.remove(identity, kind);

  @override
  Future<void> clearForLogout(
    ApplicationChatStorageIdentity previousIdentity,
  ) =>
      backing.clearForLogout(previousIdentity);

  @override
  Future<void> clearForIdentityChange({
    required ApplicationChatStorageIdentity previousIdentity,
    required ApplicationChatStorageIdentity nextIdentity,
  }) =>
      backing.clearForIdentityChange(
        previousIdentity: previousIdentity,
        nextIdentity: nextIdentity,
      );
}

final class _CountingStorage implements AtomicApplicationChatStorage {
  _CountingStorage(this.backing);

  final InMemoryApplicationChatStorage backing;
  var readCount = 0;
  var replaceCount = 0;

  void resetCounts() {
    readCount = 0;
    replaceCount = 0;
  }

  @override
  Future<ApplicationChatStorageRecord?> read(
    ApplicationChatStorageIdentity identity,
    ApplicationChatStorageRecordKind kind,
  ) {
    readCount += 1;
    return backing.read(identity, kind);
  }

  @override
  Future<String?> readEncoded(
    ApplicationChatStorageIdentity identity,
    ApplicationChatStorageRecordKind kind,
  ) {
    readCount += 1;
    return backing.readEncoded(identity, kind);
  }

  @override
  Future<bool> compareExchange(
    ApplicationChatStorageIdentity identity,
    ApplicationChatStorageRecordKind kind,
    String? expectedEncodedRecord,
    String? replacementEncodedRecord,
  ) =>
      backing.compareExchange(
        identity,
        kind,
        expectedEncodedRecord,
        replacementEncodedRecord,
      );

  @override
  Future<void> replace(ApplicationChatStorageRecord record) {
    replaceCount += 1;
    return backing.replace(record);
  }

  @override
  Future<void> remove(
    ApplicationChatStorageIdentity identity,
    ApplicationChatStorageRecordKind kind,
  ) =>
      backing.remove(identity, kind);

  @override
  Future<void> clearForLogout(
    ApplicationChatStorageIdentity previousIdentity,
  ) =>
      backing.clearForLogout(previousIdentity);

  @override
  Future<void> clearForIdentityChange({
    required ApplicationChatStorageIdentity previousIdentity,
    required ApplicationChatStorageIdentity nextIdentity,
  }) =>
      backing.clearForIdentityChange(
        previousIdentity: previousIdentity,
        nextIdentity: nextIdentity,
      );
}

final class _InterleavingAtomicStorage implements AtomicApplicationChatStorage {
  final InMemoryApplicationChatStorage backing =
      InMemoryApplicationChatStorage();
  Future<void> Function()? beforeNextCompareExchange;
  var removeCount = 0;

  @override
  Future<ApplicationChatStorageRecord?> read(
    ApplicationChatStorageIdentity identity,
    ApplicationChatStorageRecordKind kind,
  ) =>
      backing.read(identity, kind);

  @override
  Future<String?> readEncoded(
    ApplicationChatStorageIdentity identity,
    ApplicationChatStorageRecordKind kind,
  ) =>
      backing.readEncoded(identity, kind);

  @override
  Future<bool> compareExchange(
    ApplicationChatStorageIdentity identity,
    ApplicationChatStorageRecordKind kind,
    String? expectedEncodedRecord,
    String? replacementEncodedRecord,
  ) async {
    final interleave = beforeNextCompareExchange;
    beforeNextCompareExchange = null;
    if (interleave != null) await interleave();
    return backing.compareExchange(
      identity,
      kind,
      expectedEncodedRecord,
      replacementEncodedRecord,
    );
  }

  @override
  Future<void> replace(ApplicationChatStorageRecord record) =>
      backing.replace(record);

  @override
  Future<void> remove(
    ApplicationChatStorageIdentity identity,
    ApplicationChatStorageRecordKind kind,
  ) {
    removeCount += 1;
    return backing.remove(identity, kind);
  }

  @override
  Future<void> clearForLogout(
    ApplicationChatStorageIdentity previousIdentity,
  ) =>
      backing.clearForLogout(previousIdentity);

  @override
  Future<void> clearForIdentityChange({
    required ApplicationChatStorageIdentity previousIdentity,
    required ApplicationChatStorageIdentity nextIdentity,
  }) =>
      backing.clearForIdentityChange(
        previousIdentity: previousIdentity,
        nextIdentity: nextIdentity,
      );
}
