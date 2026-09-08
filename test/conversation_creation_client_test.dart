import 'dart:async';
import 'dart:convert';

import 'package:handrail_chat/core.dart';
import 'package:test/test.dart';

import 'fixtures/conversation_creation_fixtures.dart';

void main() {
  group('HandrailChatClient conversation creation', () {
    test('sends exact generated bodies and headers for all three variants',
        () async {
      final cases = <({
        String type,
        Object input,
        Map<String, Object?> expected,
      })>[
        (
          type: 'channel',
          input: const ChatCreateChannelInput(
            name: 'Order coordination',
            visibility: ConversationVisibility.private,
            entity: HostEntityReference(type: 'erp.order', id: 'order/42'),
          ),
          expected: {
            'operation': 'create_conversation',
            'type': 'channel',
            'name': 'Order coordination',
            'visibility': 'private',
            'entity': {'type': 'erp.order', 'id': 'order/42'},
            'idempotencyKey': 'creation-idempotency',
            'clientRequestId': 'creation-request',
          },
        ),
        (
          type: 'direct',
          input: ChatCreateDirectInput(
            intendedMemberUserIds: const [UserId('user-b')],
          ),
          expected: {
            'operation': 'create_conversation',
            'type': 'direct',
            'visibility': 'private',
            'intendedMemberUserIds': ['user-b'],
            'idempotencyKey': 'creation-idempotency',
            'clientRequestId': 'creation-request',
          },
        ),
        (
          type: 'group_direct',
          input: ChatCreateGroupDirectInput(
            intendedMemberUserIds: const [
              UserId('user-c'),
              UserId('user-b'),
            ],
          ),
          expected: {
            'operation': 'create_conversation',
            'type': 'group_direct',
            'visibility': 'private',
            'intendedMemberUserIds': ['user-b', 'user-c'],
            'idempotencyKey': 'creation-idempotency',
            'clientRequestId': 'creation-request',
          },
        ),
      ];

      for (final testCase in cases) {
        final transport = _RecordingTransport((request) {
          final body = _body(request);
          return Future.value(_jsonResponse(_creationResult(body)));
        });
        final client = _client(
          transport,
          idempotencyKey: () => 'creation-idempotency',
          clientRequestId: () => 'creation-request',
        );

        final result = switch (testCase.input) {
          ChatCreateChannelInput input => client.createChannel(input),
          ChatCreateDirectInput input => client.createDirect(input),
          ChatCreateGroupDirectInput input => client.createGroupDirect(input),
          _ => throw StateError('unsupported test input'),
        };

        expect((await result).category, ChatCommandResultCategory.success);
        expect(transport.requests, hasLength(1));
        final request = transport.requests.single;
        expect(request.method, 'POST');
        expect(request.uri.toString(), 'https://chat.test/api/conversations');
        expect(_body(request), testCase.expected);
        expect(request.headers, {
          'Accept': 'application/json',
          'Authorization': 'Bearer access-token-secret',
          'Idempotency-Key': 'creation-idempotency',
          'Content-Type': 'application/json',
        });
        expect(
          request.headers['Idempotency-Key'],
          _body(request)['idempotencyKey'],
        );
        await client.dispose();
      }
    });

    test('safe retry retains idempotency and client-request identity',
        () async {
      var attempts = 0;
      final transport = _RecordingTransport((request) {
        attempts += 1;
        if (attempts == 1) throw StateError('retry body secret-user-b');
        return Future.value(_jsonResponse(_creationResult(_body(request))));
      });
      final client = _client(
        transport,
        idempotencyKey: () => 'stable-idempotency',
        clientRequestId: () => 'stable-client-request',
        retryOptions: ChatCommandRetryOptions(
          maxAttempts: 2,
          wait: (_, __) async {},
        ),
      );

      final result = await client.createChannel(
        const ChatCreateChannelInput(
          name: 'Retry channel',
          visibility: ConversationVisibility.public,
        ),
      );

      expect(result.category, ChatCommandResultCategory.success);
      expect(transport.requests, hasLength(2));
      expect(transport.requests[0].body, transport.requests[1].body);
      expect(
        transport.requests[0].headers['Idempotency-Key'],
        transport.requests[1].headers['Idempotency-Key'],
      );
      expect(
        _body(transport.requests[0])['clientRequestId'],
        _body(transport.requests[1])['clientRequestId'],
      );
      await client.dispose();
    });

    test('equivalent active calls serialize and reordered participants dedupe',
        () async {
      final response = Completer<HandrailChatHttpResponse>();
      final transport = _RecordingTransport((_) => response.future);
      var idempotencyCount = 0;
      var requestCount = 0;
      final client = _client(
        transport,
        idempotencyKey: () => 'logical-idempotency-${++idempotencyCount}',
        clientRequestId: () => 'logical-request-${++requestCount}',
      );
      final forward = client.createGroupDirect(
        ChatCreateGroupDirectInput(
          intendedMemberUserIds: const [
            UserId('user-c'),
            UserId('user-b'),
          ],
        ),
      );
      await _waitFor(() => transport.requests.isNotEmpty);
      final reversed = client.createGroupDirect(
        ChatCreateGroupDirectInput(
          intendedMemberUserIds: const [
            UserId('user-b'),
            UserId('user-c'),
          ],
        ),
      );

      expect(identical(forward, reversed), isTrue);
      expect(transport.requests, hasLength(1));
      expect(idempotencyCount, 1);
      expect(requestCount, 1);
      final body = _body(transport.requests.single);
      expect(body['intendedMemberUserIds'], ['user-b', 'user-c']);
      response.complete(_jsonResponse(_creationResult(body)));
      expect((await forward).category, ChatCommandResultCategory.success);
      expect((await reversed).category, ChatCommandResultCategory.success);

      final directResponse = Completer<HandrailChatHttpResponse>();
      transport.handler = (_) => directResponse.future;
      final directOne = client.createDirect(
        ChatCreateDirectInput(
          intendedMemberUserIds: const [UserId('user-b')],
        ),
      );
      await _waitFor(() => transport.requests.length == 2);
      final directTwo = client.createDirect(
        ChatCreateDirectInput(
          intendedMemberUserIds: const [UserId('user-b')],
        ),
      );
      expect(identical(directOne, directTwo), isTrue);
      expect(transport.requests, hasLength(2));
      directResponse.complete(
        _jsonResponse(
          _creationResult(
            _body(transport.requests.last),
            conversationId: 'direct-result',
          ),
        ),
      );
      expect((await directOne).category, ChatCommandResultCategory.success);
      await client.dispose();
    });

    test('created, existing-equivalent, and replayed reuse one canonical row',
        () async {
      final statuses = <String>[
        'created',
        'existing_equivalent',
        'replayed',
      ];
      var responseIndex = 0;
      var identity = 0;
      final transport = _RecordingTransport((request) {
        final body = _body(request);
        return Future.value(
          _jsonResponse(
            _creationResult(
              body,
              status: statuses[responseIndex++],
              conversationId: 'canonical-direct',
            ),
          ),
        );
      });
      final store = NormalizedSnapshotStore();
      store.hydrateConversationList(_emptyList(
        const OrganizationConversationSnapshotScope(),
      ));
      final client = _client(
        transport,
        store: store,
        idempotencyKey: () => 'status-idempotency-${++identity}',
        clientRequestId: () => 'status-request-$identity',
      );

      for (final expectedStatus in statuses) {
        final result = await client.createDirect(
          ChatCreateDirectInput(
            intendedMemberUserIds: const [UserId('user-b')],
          ),
        );
        expect(result,
            isA<ChatCommandSuccess<DirectConversationCreationResult>>());
        final value =
            (result as ChatCommandSuccess<DirectConversationCreationResult>)
                .value;
        expect(value.reconciliationStatus.toJson(), expectedStatus);
        expect(store.state.conversations.keys, const [
          ConversationId('canonical-direct'),
        ]);
        expect(store.state.conversationDetails, hasLength(1));
        expect(
          store
              .conversationList(const OrganizationConversationSnapshotScope())
              .conversationIds,
          const [ConversationId('canonical-direct')],
        );
      }
      await client.dispose();
      await store.close();
    });

    test('creation atomically hydrates only applicable existing list scopes',
        () async {
      const entity = HostEntityReference(type: 'erp.order', id: 'order/42');
      const otherEntity =
          HostEntityReference(type: 'erp.order', id: 'order/99');
      final store = NormalizedSnapshotStore();
      store.hydrateConversationList(_emptyList(
        const OrganizationConversationSnapshotScope(),
      ));
      store.hydrateConversationList(_emptyList(
        const EntityConversationSnapshotScope(entity: entity),
      ));
      store.hydrateConversationList(_emptyList(
        const EntityConversationSnapshotScope(entity: otherEntity),
      ));
      final transport = _RecordingTransport((request) => Future.value(
            _jsonResponse(
              _creationResult(
                _body(request),
                conversationId: 'entity-channel',
              ),
            ),
          ));
      final client = _client(
        transport,
        store: store,
        idempotencyKey: () => 'entity-idempotency',
        clientRequestId: () => 'entity-request',
      );

      final result = await client.createChannel(
        const ChatCreateChannelInput(
          name: 'Order coordination',
          visibility: ConversationVisibility.private,
          entity: entity,
        ),
      );

      expect(result.category, ChatCommandResultCategory.success);
      expect(store.state.conversations, hasLength(1));
      expect(
        store
            .conversationList(const OrganizationConversationSnapshotScope())
            .conversationIds,
        const [ConversationId('entity-channel')],
      );
      expect(
        store
            .conversationList(
              const EntityConversationSnapshotScope(entity: entity),
            )
            .conversationIds,
        const [ConversationId('entity-channel')],
      );
      expect(
        store
            .conversationList(
              const EntityConversationSnapshotScope(entity: otherEntity),
            )
            .conversationIds,
        isEmpty,
      );
      expect(
        store.conversation(const ConversationId('entity-channel')).conversation,
        isA<ChannelConversation>(),
      );
      await client.dispose();
      await store.close();
    });

    test('supports cancellation before and during transport and disposal',
        () async {
      var tokenCalls = 0;
      final transport = _RecordingTransport(
          (_) => Completer<HandrailChatHttpResponse>().future);
      final client = _client(
        transport,
        tokenProvider: () async {
          tokenCalls += 1;
          return 'access-token-secret';
        },
      );
      final cancelled = ChatCommandCancellationController()..cancel();
      final before = await client.createChannel(
        const ChatCreateChannelInput(
          name: 'Before cancellation',
          visibility: ConversationVisibility.public,
        ),
        cancellationSignal: cancelled.signal,
      );
      expect(before.category, ChatCommandResultCategory.aborted);
      expect(tokenCalls, 0);
      expect(transport.requests, isEmpty);

      final duringCancellation = ChatCommandCancellationController();
      final during = client.createChannel(
        const ChatCreateChannelInput(
          name: 'During cancellation',
          visibility: ConversationVisibility.public,
        ),
        cancellationSignal: duringCancellation.signal,
      );
      await _waitFor(() => transport.requests.length == 1);
      duringCancellation.cancel();
      expect((await during).category, ChatCommandResultCategory.aborted);

      final closing = client.createChannel(
        const ChatCreateChannelInput(
          name: 'During disposal',
          visibility: ConversationVisibility.public,
        ),
      );
      await _waitFor(() => transport.requests.length == 2);
      final dispose = client.dispose();
      expect((await closing).category, ChatCommandResultCategory.closed);
      await dispose;
      expect(
        (await client.createChannel(
          const ChatCreateChannelInput(
            name: 'After disposal',
            visibility: ConversationVisibility.public,
          ),
        ))
            .category,
        ChatCommandResultCategory.closed,
      );
    });

    test('validates authored and generated identities before auth or transport',
        () async {
      var tokenCalls = 0;
      final transport = _RecordingTransport((_) => throw StateError('unused'));
      final client = _client(
        transport,
        tokenProvider: () async {
          tokenCalls += 1;
          return 'access-token-secret';
        },
      );
      final invalidAuthored = <Future<ChatCommandResult<Object>>>[
        client
            .createChannel(const ChatCreateChannelInput(
              name: ' ',
              visibility: ConversationVisibility.public,
            ))
            .then((value) => value),
        client
            .createDirect(ChatCreateDirectInput(
              intendedMemberUserIds: const [],
            ))
            .then((value) => value),
        client
            .createGroupDirect(ChatCreateGroupDirectInput(
              intendedMemberUserIds: const [
                UserId('user-b'),
                UserId('user-b'),
              ],
            ))
            .then((value) => value),
      ];
      for (final pending in invalidAuthored) {
        expect((await pending).category, ChatCommandResultCategory.validation);
      }
      expect(tokenCalls, 0);
      expect(transport.requests, isEmpty);
      await client.dispose();

      final invalidGenerated = _client(
        transport,
        tokenProvider: () async {
          tokenCalls += 1;
          return 'access-token-secret';
        },
        idempotencyKey: () => 'invalid key with spaces',
        clientRequestId: () => ' ',
      );
      final result = await invalidGenerated.createChannel(
        const ChatCreateChannelInput(
          name: 'Valid authored channel',
          visibility: ConversationVisibility.public,
        ),
      );
      expect(result.category, ChatCommandResultCategory.validation);
      expect(tokenCalls, 0);
      expect(transport.requests, isEmpty);
      await invalidGenerated.dispose();

      final invalidIdempotency = _client(
        transport,
        tokenProvider: () async {
          tokenCalls += 1;
          return 'access-token-secret';
        },
        idempotencyKey: () => 'invalid key with spaces',
        clientRequestId: () => 'valid-generated-request',
      );
      final invalidIdempotencyResult = await invalidIdempotency.createChannel(
        const ChatCreateChannelInput(
          name: 'Valid authored channel',
          visibility: ConversationVisibility.public,
        ),
      );
      expect(
        invalidIdempotencyResult.category,
        ChatCommandResultCategory.validation,
      );
      expect(tokenCalls, 0);
      expect(transport.requests, isEmpty);
      await invalidIdempotency.dispose();
    });

    test('rejects malformed and incoherent responses without cache writes',
        () async {
      final mutators = <void Function(Map<String, Object?>)>[
        (result) => result['clientRequestId'] = 'wrong-request',
        (result) => result['type'] = 'group_direct',
        (result) {
          final identity =
              result['participantIdentity']! as Map<String, Object?>;
          identity['key'] = 'wrong-participant-key';
        },
      ];

      for (final mutate in mutators) {
        final store = NormalizedSnapshotStore();
        final transport = _RecordingTransport((request) {
          final result = _creationResult(_body(request));
          mutate(result);
          return Future.value(_jsonResponse(result));
        });
        final client = _client(transport, store: store);
        final result = await client.createDirect(
          ChatCreateDirectInput(
            intendedMemberUserIds: const [UserId('user-b')],
          ),
        );
        expect(result.category, ChatCommandResultCategory.malformedResponse);
        expect(store.state.conversations, isEmpty);
        await client.dispose();
        await store.close();
      }

      final malformedTransport = _RecordingTransport((_) => Future.value(
            const HandrailChatHttpResponse(
              statusCode: 200,
              body: '{not-json participant-secret user-b',
            ),
          ));
      final client = _client(malformedTransport);
      expect(
        (await client.createDirect(ChatCreateDirectInput(
          intendedMemberUserIds: const [UserId('user-b')],
        )))
            .category,
        ChatCommandResultCategory.malformedResponse,
      );
      await client.dispose();
    });

    test('failure results and diagnostics redact all sensitive material',
        () async {
      const secrets = <String>[
        'access-token-secret',
        'participant-sensitive',
        'entity-sensitive',
        'generated-idempotency-sensitive',
        'generated-request-sensitive',
        'raw-server-sensitive',
      ];
      final diagnostics = <ChatCommandDiagnostic>[];
      final transport = _RecordingTransport((_) {
        throw StateError('raw-server-sensitive participant-sensitive');
      });
      final client = _client(
        transport,
        idempotencyKey: () => 'generated-idempotency-sensitive',
        clientRequestId: () => 'generated-request-sensitive',
        onDiagnostic: diagnostics.add,
        retryOptions: const ChatCommandRetryOptions(maxAttempts: 1),
      );
      final input = ChatCreateChannelInput(
        name: 'participant-sensitive',
        visibility: ConversationVisibility.private,
        entity: const HostEntityReference(
          type: 'entity-sensitive',
          id: 'participant-sensitive',
        ),
      );
      final result = await client.createChannel(input);
      expect(result.category, ChatCommandResultCategory.transport);
      final text = <String>[
        result.toString(),
        (result as ChatCommandFailure).message,
        input.toString(),
        ...diagnostics.map((diagnostic) => diagnostic.toString()),
      ].join('\n');
      for (final secret in secrets) {
        expect(text, isNot(contains(secret)), reason: secret);
      }
      await client.dispose();
    });
  });
}

HandrailChatClient _client(
  _RecordingTransport transport, {
  NormalizedSnapshotStore? store,
  Future<String> Function()? tokenProvider,
  String Function()? idempotencyKey,
  String Function()? clientRequestId,
  ChatCommandRetryOptions retryOptions =
      const ChatCommandRetryOptions(maxAttempts: 1),
  ChatCommandDiagnosticCallback? onDiagnostic,
}) =>
    HandrailChatClient(
      apiBaseUri: Uri.parse('https://chat.test/api'),
      tokenProvider: tokenProvider ?? () async => 'access-token-secret',
      transport: transport,
      normalizedSnapshotStore: store,
      commandRetryOptions: retryOptions,
      onCommandDiagnostic: onDiagnostic,
      generateIdempotencyKey: idempotencyKey ?? () => 'creation-idempotency',
      generateConversationClientRequestId:
          clientRequestId ?? () => 'creation-request',
    );

final class _RecordingTransport implements HandrailChatHttpTransport {
  _RecordingTransport(this.handler);

  Future<HandrailChatHttpResponse> Function(HandrailChatHttpRequest) handler;
  final List<HandrailChatHttpRequest> requests = [];

  @override
  Future<HandrailChatHttpResponse> send(HandrailChatHttpRequest request) {
    requests.add(request);
    return handler(request);
  }
}

Map<String, Object?> _body(HandrailChatHttpRequest request) =>
    (jsonDecode(request.body!) as Map<String, Object?>);

HandrailChatHttpResponse _jsonResponse(Object? body) =>
    HandrailChatHttpResponse(statusCode: 201, body: jsonEncode(body));

Map<String, Object?> _creationResult(
  Map<String, Object?> input, {
  String status = 'created',
  String conversationId = 'conversation-result',
}) {
  final type = input['type']! as String;
  final intended =
      (input['intendedMemberUserIds'] as List<Object?>? ?? const [])
          .cast<String>();
  final result = conversationCreationResultFixture(
    type,
    status,
    clientRequestId: input['clientRequestId']! as String,
  );
  final detail = result['conversation']! as Map<String, Object?>;
  final conversation = detail['conversation']! as Map<String, Object?>;
  conversation['id'] = conversationId;
  conversation['visibility'] = input['visibility'];
  if (input['name'] case final String name) conversation['name'] = name;
  if (input['entity'] case final Map<String, Object?> entity) {
    conversation['entity'] = Map<String, Object?>.of(entity);
  }
  for (final field in <String>[
    'currentMember',
    'currentReadState',
    'currentPreference',
  ]) {
    (conversation[field]! as Map<String, Object?>)['conversationId'] =
        conversationId;
  }
  if (type == 'channel') {
    conversation['memberUserIds'] = ['user-actor'];
  } else {
    final identity = deriveCanonicalParticipantIdentity(
      const UserId('user-actor'),
      intended.map(UserId.new).toList(),
    );
    result['participantIdentity'] = identity.toJson();
    conversation['memberUserIds'] =
        identity.participantUserIds.map((id) => id.toJson()).toList();
  }
  return result;
}

ConversationListSnapshot _emptyList(ConversationSnapshotScope scope) =>
    ConversationListSnapshot.fromJson({
      'kind': 'conversation_list',
      'scope': scope.toJson(),
      'items': <Object?>[],
      'page': <String, Object?>{},
      '_meta': _metadata,
    });

const _metadata = <String, Object?>{
  'packageVersion': '0.1.4',
  'protocolVersion': 1,
  'schemaVersion': 1,
  'enabledFeatures': {'conversation_creation': true},
  'supportedProtocolRange': {
    'minimumVersion': 1,
    'maximumVersion': 1,
  },
  'feature': {'name': 'conversation_snapshots', 'version': 1},
};

Future<void> _waitFor(bool Function() predicate) async {
  for (var count = 0; count < 100 && !predicate(); count += 1) {
    await Future<void>.delayed(Duration.zero);
  }
  expect(predicate(), isTrue);
}
