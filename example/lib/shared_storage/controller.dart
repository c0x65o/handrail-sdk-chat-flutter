import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'dart:js_interop';

import 'package:handrail_chat/testing.dart';
import 'fixture.dart';
import 'indexed_db_storage.dart';

final storageLabIdentity = ApplicationChatStorageIdentity(
  tenantId: const TenantId('tenant-1'),
  userId: const UserId('user-1'),
  deviceId: const DeviceId('device-1'),
);

/// One controller per Flutter engine. Only the IndexedDB database is shared.
final class StorageLabController {
  StorageLabController(this.storage) {
    session = ChatRealtimeSessionTransport(
      endpoint: Uri.parse('https://storage-lab.invalid/api/chat'),
      clientPackageVersion: '0.1.3',
      protocolVersion: handrailChatProtocolVersion,
      tokenProvider: () => 'fixture-only',
      network: network,
      socketFactory: (_, __) async {
        final socket = FakeChatRealtimeSocket();
        Timer(const Duration(milliseconds: 50), () {
          if (!socket.isClosed) {
            socket.emitJson({
              'type': 'chat.session.accepted',
              'metadata': storageLabMetadata,
              'tenantId': 'tenant-1',
              'actorStreamId': 'user:user-1',
              'deviceId': 'device-1',
              'sessionId': uniqueId(),
            });
          }
        });
        return socket;
      },
    );
    client = HandrailChatClient(
      apiBaseUri: Uri.parse('https://storage-lab.invalid/api/chat'),
      tokenProvider: () async => 'fixture-only',
      transport: _LedgerTransport(storage, network),
      realtimeSession: session,
      localStorage: storage,
      storageIdentity: storageLabIdentity,
      normalizedSnapshotStore: store,
      generateClientMessageId: uniqueId,
      generateIdempotencyKey: uniqueId,
      commandRetryOptions: const ChatCommandRetryOptions(maxAttempts: 1),
    );
  }
  final IndexedDbChatStorage storage;
  final network = FakeChatRealtimeNetwork(isOnline: false);
  final store = seedStorageLabConversation();
  late final ChatRealtimeSessionTransport session;
  late final HandrailChatClient client;
  final _random = Random.secure();
  String uniqueId() => List.generate(
      16, (_) => _random.nextInt(256).toRadixString(16).padLeft(2, '0')).join();

  Future<void> start() async {
    await client.activateStorageIdentity(storageLabIdentity);
    final state = await client.initialize();
    if (state is! ChatClientReadyState) {
      throw StateError('Metadata not ready: $state');
    }
    await session.start();
  }

  Future<Map<String, Object?>> command(Map<String, dynamic> input) async {
    final operation = input['operation'];
    Object? result;
    switch (operation) {
      case 'send':
        result = (await client.sendMessage(ChatSendMessageInput(
          conversationId: const ConversationId('conversation-1'),
          content: MessageContent(
              format: MessageContentFormat.plain,
              text:
                  input['text'] as String? ?? 'Durable shared-storage message'),
        )))
            .category
            .name;
      case 'read':
        // The read API settles at canonical acknowledgement, which may be
        // after reconnect. Keep the lab usable while that future is pending.
        final completion = client.markRead(ChatMarkReadInput(
          conversationId: const ConversationId('conversation-1'),
          throughSequence: MessageSequence(input['sequence'] as int? ?? 4),
          idempotencyKey: uniqueId(),
        ));
        unawaited(completion.then((outcome) => storage.note({
              'operation': 'read-settled',
              'result': outcome.category.name,
            })));
        result = 'pending';
      case 'cancel':
        result = await client.cancelQueuedSendMessage(input['id'] as String);
      case 'online':
        network.setOnline(input['value'] == true);
      case 'gate':
        storage.pauseKind = input['kind'] as String;
        storage.pausePhase = input['phase'] as String;
      case 'release':
        storage.release();
      case 'push':
        final request = DevicePushTokenInput.fromJson({
          'operation': input['refresh'] == true ? 'refresh' : 'register',
          'deviceId': storageLabIdentity.deviceId.value,
          'platform': 'ios',
          'provider': 'apns',
          'environment': 'sandbox',
          'token': 'fixture-token-never-export',
          'tokenRevision': input['revision'],
          'idempotencyKey': uniqueId(),
        });
        final outcome = await switch (request) {
          RegisterDevicePushTokenInput() => client.registerPushToken(request),
          RefreshDevicePushTokenInput() => client.refreshPushToken(request),
          _ => throw StateError('Unexpected push fixture operation'),
        };
        result = outcome.category.name;
      case 'corrupt-push':
        await storage.writeFixture(storageLabIdentity,
            ApplicationChatStorageRecordKind.pushTokenRevisions, '{malformed');
      case 'quarantine-push':
        try {
          await ApplicationChatStorageMutator(storage)
              .mutate<ApplicationChatPushTokenRevisionsRecord>(
                  storageLabIdentity,
                  ApplicationChatStorageRecordKind.pushTokenRevisions,
                  (current) => current);
          result = 'valid';
        } on FormatException {
          result = 'malformed-read-rejected';
        }
      case 'snapshot':
        // Probe exact-value CAS using a valid SDK normalized snapshot record.
        final fresh = seedStorageLabConversation();
        final snapshot = ApplicationChatNormalizedSnapshotRecord(
            identity: storageLabIdentity, snapshot: fresh.state);
        final kind = snapshot.kind;
        final expected = input.containsKey('expected')
            ? input['expected'] as String?
            : await storage.readEncoded(storageLabIdentity, kind);
        result = await storage.compareExchange(storageLabIdentity, kind,
            expected, '${snapshot.encode()}${input['suffix'] ?? ''}');
        await fresh.close();
      case 'status':
      case 'export':
        break;
      default:
        throw ArgumentError('Unknown lab operation: $operation');
    }
    if (operation != 'status' && operation != 'export') {
      await storage.note({
        'operation': 'command-result',
        'command': operation,
        'result': result,
        'publishedSendIds': client.queuedSendMessages
            .map((item) => item.clientMessageId)
            .toList()
      });
    }
    return {
      'result': result,
      ...await status(includeTrace: operation == 'export')
    };
  }

  Future<Map<String, Object?>> status({bool includeTrace = false}) async => {
        'adapter': IndexedDbChatStorage.adapterId,
        'database': storage.database.name,
        'writer': storage.writer,
        'identity': storageLabIdentity.toJson(),
        'online': network.isOnline,
        'recovery': session.state.state,
        'paused': storage.paused,
        'readSequence': store
            .state
            .currentUserReadStates[const ConversationId('conversation-1')]
            ?.lastReadSequence
            .value,
        'queuedSendIds': client.queuedSendMessages
            .map((item) => item.clientMessageId)
            .toList(),
        'records': await storage.entries('records'),
        'ledger': await storage.entries('ledger'),
        if (includeTrace) 'trace': await storage.entries('trace'),
      };

  Future<void> dispose() async {
    storage.release();
    await client.dispose();
    await session.dispose();
    await network.dispose();
    await store.close();
    storage.database.close();
  }
}

/// Credential-free canonical endpoint fixture. The durable idempotency ledger
/// commits once across engines/restarts; repeated HTTP attempts return its
/// original result. It is explicitly not a production server integration.
final class _LedgerTransport implements HandrailChatHttpTransport {
  _LedgerTransport(this.storage, this.network);
  final IndexedDbChatStorage storage;
  final FakeChatRealtimeNetwork network;

  @override
  Future<HandrailChatHttpResponse> send(HandrailChatHttpRequest request) async {
    if (request.method == 'GET') {
      return HandrailChatHttpResponse(
          statusCode: 200, body: jsonEncode(storageLabMetadata));
    }
    if (!network.isOnline) throw StateError('Fixture network is offline');
    final body = jsonDecode(request.body!) as Map<String, dynamic>;
    final key = body['idempotencyKey'] as String;
    final tx = storage.transaction(['ledger', 'trace']);
    final committed = transactionComplete(tx);
    final ledger = tx.objectStore('ledger');
    final existing =
        (await requestValue(ledger.get(key.toJS)))?.dartify() as String?;
    late Map<String, dynamic> response;
    if (existing != null) {
      response = (jsonDecode(existing) as Map<String, dynamic>)['response']
          as Map<String, dynamic>;
    } else {
      final sequence =
          ((await requestValue(ledger.count())) as JSNumber).toDartInt + 9;
      final time =
          DateTime.utc(2030).add(Duration(seconds: sequence)).toIso8601String();
      if (body.containsKey('clientMessageId')) {
        response = {
          'operation': 'send',
          'reconciliationStatus': 'applied',
          'clientMessageId': body['clientMessageId'],
          'canonicalRevision': 1,
          'message': {
            'id': 'message-$sequence',
            'tenantId': 'tenant-1',
            'conversationId': body['conversationId'],
            'author': {'type': 'user', 'userId': 'user-1'},
            'sequence': sequence,
            'createdAt': time,
            'updatedAt': time,
            'revision': {'revision': 1},
            'content': body['content']
          }
        };
      } else if (body.containsKey('tokenRevision')) {
        response = {
          'operation': body['operation'],
          'reconciliationStatus': 'applied',
          'idempotencyKey': key,
          'devicePushToken': {
            'deviceId': body['deviceId'],
            'status': 'active',
            'platform': body['platform'],
            'provider': body['provider'],
            'environment': body['environment'],
            'tokenRevision': body['tokenRevision'],
            'updatedAt': time
          }
        };
      } else {
        final through = body['throughSequence'] as int;
        response = {
          'operation': 'mark_read',
          'reconciliationStatus': 'applied',
          'idempotencyKey': key,
          'conversationId': body['conversationId'],
          'readState': {
            'conversationId': body['conversationId'],
            'userId': 'user-1',
            'lastReadSequence': through,
            'updatedAt': time
          },
          'latestSequence': 8,
          'unreadCount': 8 - through
        };
      }
      ledger.put(jsonEncode({'key': key, 'response': response}).toJS, key.toJS);
    }
    storage.trace(tx, {
      'operation': 'transport',
      'key': key,
      'applied': existing == null,
      'response': response
    });
    await committed;
    return HandrailChatHttpResponse(
        statusCode: 200, body: jsonEncode(response));
  }
}
