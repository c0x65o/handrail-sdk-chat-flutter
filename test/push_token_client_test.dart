import 'dart:async';
import 'dart:convert';

import 'package:handrail_chat/core.dart';
import 'package:handrail_chat/testing.dart' show InMemoryApplicationChatStorage;
import 'package:test/test.dart';

const _deviceId = DeviceId('device-mobile-1');
const _otherDeviceId = DeviceId('device-mobile-2');
const _rawToken = 'RAW_PUSH_TOKEN_DO_NOT_RETAIN';

void main() {
  test('two runtimes merge different targets after compare-exchange contention',
      () async {
    final storage = _AtomicStorage();
    await _seed(storage, _identity(), revision: 1);
    final first = _localFixture(storage);
    final second = _localFixture(storage);
    final gate = _StorageGate();
    storage.beforeWrite = (_, replacement) async {
      if (replacement?.contains('"revision":2') == true) await gate.hold();
    };

    final delayed = first.client.refreshPushToken(_refresh(2));
    await gate.entered.future;
    expect(
      await second.client.registerPushToken(_register(
        10,
        environment: DevicePushProviderEnvironment.production,
      )),
      isA<ChatCommandSuccess<DevicePushTokenResult>>(),
    );
    gate.release.complete();
    expect(await delayed, isA<ChatCommandSuccess<DevicePushTokenResult>>());
    expect(await _revisions(storage), {'sandbox': 2, 'production': 10});
    expect(storage.conflicts, 1);
    _expectSecretFreeWrites(storage);
  });

  for (final delayTransport in [false, true]) {
    test('lower revision keeps newer cache; delayed transport=$delayTransport',
        () async {
      final storage = _AtomicStorage();
      await _seed(storage, _identity(), revision: 1);
      final gate = _StorageGate();
      final first = _fixture(
        storage: storage,
        handler: (request) async {
          if (delayTransport) await gate.hold();
          return _canonicalResponse(request);
        },
      );
      addTearDown(first.client.dispose);
      final second = _localFixture(storage);
      if (!delayTransport) {
        storage.beforeWrite = (_, replacement) async {
          if (replacement?.contains('"revision":2') == true) await gate.hold();
        };
      }

      final delayed = first.client.refreshPushToken(_refresh(2));
      await gate.entered.future;
      expect(await second.client.refreshPushToken(_refresh(3)),
          isA<ChatCommandSuccess<DevicePushTokenResult>>());
      gate.release.complete();
      expect(await delayed, isA<ChatCommandSuccess<DevicePushTokenResult>>());
      expect(await _revisions(storage), {'sandbox': 3});
      expect(storage.conflicts, delayTransport ? 0 : 1);
      expect(await first.client.refreshPushToken(_refresh(3)),
          isA<ChatCommandValidationFailure<DevicePushTokenResult>>());
      expect(first.transport.requests, hasLength(1));
    });
  }

  for (final newerReplacement in [false, true]) {
    test(
        'logout preserves concurrent targets; newer replacement=$newerReplacement',
        () async {
      final storage = _AtomicStorage();
      await _seed(storage, _identity(), revision: 1);
      final first = _localFixture(storage);
      final second = _localFixture(storage);
      final gate = _StorageGate();
      storage.beforeWrite = (_, replacement) async {
        if (replacement == null) await gate.hold();
      };

      final removal = first.client.unregisterPushTokenForLogout(_unregister(2));
      await gate.entered.future;
      expect(first.transport.requests, hasLength(1));
      expect(_body(first.transport.requests.single)['operation'], 'unregister');
      expect(
        await second.client.registerPushToken(_register(
          10,
          environment: DevicePushProviderEnvironment.production,
        )),
        isA<ChatCommandSuccess<DevicePushTokenResult>>(),
      );
      if (newerReplacement) {
        expect(await second.client.refreshPushToken(_refresh(3)),
            isA<ChatCommandSuccess<DevicePushTokenResult>>());
      }
      gate.release.complete();
      expect(await removal, isA<ChatCommandSuccess<DevicePushTokenResult>>());
      expect(await _revisions(storage), {
        'production': 10,
        if (newerReplacement) 'sandbox': 3,
      });
      expect(storage.conflicts, 1);
      if (newerReplacement) {
        expect(await first.client.refreshPushToken(_refresh(3)),
            isA<ChatCommandValidationFailure<DevicePushTokenResult>>());
      }
    });
  }

  test('quarantine cannot delete a valid replacement of a malformed read',
      () async {
    final storage = _AtomicStorage();
    storage._backing.putRawRecordForTesting(
        _identity(),
        ApplicationChatStorageRecordKind.pushTokenRevisions,
        {'token': _rawToken});
    final gate = _StorageGate();
    storage.afterRead = (encoded) async {
      if (encoded?.contains(_rawToken) == true) await gate.hold();
    };
    final first = _localFixture(storage);
    final second = _localFixture(storage);
    final malformedLoad = first.client.registerPushToken(_register(1));
    await gate.entered.future;
    // The second runtime quarantines the same corrupt value, then retries.
    expect(await second.client.registerPushToken(_register(1)),
        isA<ChatCommandTransportFailure<DevicePushTokenResult>>());
    expect(await second.client.registerPushToken(_register(1)),
        isA<ChatCommandSuccess<DevicePushTokenResult>>());
    gate.release.complete();
    expect(await malformedLoad,
        isA<ChatCommandTransportFailure<DevicePushTokenResult>>());
    expect(await _revisions(storage), {'sandbox': 1});
    expect(first.transport.requests, isEmpty);
    expect(await first.client.refreshPushToken(_refresh(2)),
        isA<ChatCommandSuccess<DevicePushTokenResult>>());
    _expectSecretFreeWrites(storage);
  });

  for (final failWithError in [false, true]) {
    test(
        'uncommitted registration stays invisible; adapter error=$failWithError',
        () async {
      final storage = _AtomicStorage();
      final fixture = _localFixture(storage);
      final gate = _StorageGate();
      storage.beforeWrite = (_, replacement) async {
        if (replacement != null) {
          await gate.hold();
          if (failWithError) throw StateError('$_rawToken access-token');
        }
      };
      final registration = fixture.client.registerPushToken(_register(1));
      await gate.entered.future;
      expect(await _revisions(storage), isEmpty);
      // Rotation consults the cache before entering the target's command lane.
      expect(
        await fixture.client.rotatePushToken(
          unregister: _unregister(2),
          replacement: _register(3),
        ),
        isA<ChatCommandValidationFailure<ChatPushTokenRotationResult>>(),
      );
      storage.rejectExchanges = !failWithError;
      gate.release.complete();
      final result = await registration;
      expect(result, isA<ChatCommandTransportFailure<DevicePushTokenResult>>());
      expect(result.toString(), isNot(contains(_rawToken)));
      expect(result.toString(), isNot(contains('access-token')));
      expect(await _revisions(storage), isEmpty);
      if (!failWithError) {
        expect(storage.conflicts, maxApplicationChatStorageMutationAttempts);
      }
      storage.beforeWrite = null;
      storage.rejectExchanges = false;
      expect(await fixture.client.registerPushToken(_register(1)),
          isA<ChatCommandSuccess<DevicePushTokenResult>>());
      expect(await _revisions(storage), {'sandbox': 1});
      _expectSecretFreeWrites(storage);
    });
  }

  test('register sends exact retry-stable PUT and persists token-free revision',
      () async {
    var attempts = 0;
    final diagnostics = <ChatCommandDiagnostic>[];
    final fixture = _fixture(
      handler: (request) async {
        attempts += 1;
        if (attempts == 1) {
          return const HandrailChatHttpResponse(statusCode: 503, body: '{}');
        }
        return _canonicalResponse(request);
      },
      retryOptions: ChatCommandRetryOptions(
        maxAttempts: 2,
        backoff: (_) => Duration.zero,
        wait: (_, __) async {},
      ),
      diagnostics: diagnostics,
    );

    final result = await fixture.client.registerPushToken(_register(1));

    expect(result, isA<ChatCommandSuccess<DevicePushTokenResult>>());
    expect(fixture.transport.requests, hasLength(2));
    final request = fixture.transport.requests.first;
    expect(request.method, 'PUT');
    expect(
      request.uri.toString(),
      'https://chat.example.test/api/chat/devices/device-mobile-1/push-token',
    );
    expect(request.headers, {
      'Accept': 'application/json',
      'Authorization': 'Bearer access-token',
      'Idempotency-Key': 'register-1',
      'Content-Type': 'application/json',
    });
    expect(jsonDecode(request.body!), {
      'operation': 'register',
      'deviceId': _deviceId.value,
      'platform': 'ios',
      'provider': 'apns',
      'environment': 'sandbox',
      'token': _rawToken,
      'tokenRevision': 1,
      'idempotencyKey': 'register-1',
    });
    expect(fixture.transport.requests[1].body, request.body);
    expect(
      fixture.transport.requests[1].headers['Idempotency-Key'],
      'register-1',
    );

    final rawStorage = _rawStorage(
      fixture.storage,
      fixture.identity,
      ApplicationChatStorageRecordKind.pushTokenRevisions,
    );
    final encodedStorage = jsonEncode(rawStorage);
    expect(encodedStorage, contains('"revision":1'));
    expect(encodedStorage, isNot(contains(_rawToken)));
    expect(encodedStorage.toLowerCase(), isNot(contains('"token"')));
    expect(request.toString(), isNot(contains(_rawToken)));
    expect(request.toString(), isNot(contains('access-token')));
    expect(diagnostics.join('\n'), isNot(contains(_rawToken)));
    await fixture.client.dispose();
  });

  test('refresh rehydrates revision and accepts replayed canonical state',
      () async {
    final storage = InMemoryApplicationChatStorage();
    final identity = _identity();
    await _seed(storage, identity, revision: 1);
    final fixture = _fixture(
      storage: storage,
      handler: (request) async =>
          _canonicalResponse(request, reconciliationStatus: 'replayed'),
    );

    final result = await fixture.client.refreshPushToken(_refresh(2));

    expect(result, isA<ChatCommandSuccess<DevicePushTokenResult>>());
    final value = (result as ChatCommandSuccess<DevicePushTokenResult>).value;
    expect(value.reconciliationStatus,
        DevicePushTokenReconciliationStatus.replayed);
    final request = fixture.transport.requests.single;
    expect(request.method, 'PUT');
    expect(jsonDecode(request.body!), {
      'operation': 'refresh',
      'deviceId': _deviceId.value,
      'platform': 'ios',
      'provider': 'apns',
      'environment': 'sandbox',
      'token': _rawToken,
      'tokenRevision': 2,
      'idempotencyKey': 'refresh-2',
    });
    final stored = await storage.read(
      identity,
      ApplicationChatStorageRecordKind.pushTokenRevisions,
    ) as ApplicationChatPushTokenRevisionsRecord;
    expect(stored.revisions.single.revision, 2);
    await fixture.client.dispose();
  });

  test('unregister sends exact token-free body and retains canonical revision',
      () async {
    final storage = InMemoryApplicationChatStorage();
    final identity = _identity();
    await _seed(storage, identity, revision: 2);
    final fixture = _fixture(
      storage: storage,
      handler: (request) async => _canonicalResponse(request),
    );

    final result = await fixture.client.unregisterPushToken(_unregister(3));

    expect(result, isA<ChatCommandSuccess<DevicePushTokenResult>>());
    expect(jsonDecode(fixture.transport.requests.single.body!), {
      'operation': 'unregister',
      'intent': 'unregister',
      'deviceId': _deviceId.value,
      'tokenRevision': 3,
      'idempotencyKey': 'unregister-3',
    });
    final stored = await storage.read(
      identity,
      ApplicationChatStorageRecordKind.pushTokenRevisions,
    ) as ApplicationChatPushTokenRevisionsRecord;
    expect(stored.revisions.single.status, DevicePushTokenStatus.unregistered);
    expect(stored.revisions.single.revision, 3);
    await fixture.client.dispose();
  });

  test('serializes one target while unrelated targets dispatch independently',
      () async {
    final storage = InMemoryApplicationChatStorage();
    final identity = _identity();
    await storage.replace(
      ApplicationChatPushTokenRevisionsRecord(
        identity: identity,
        revisions: [
          _storedRevision(revision: 1),
          _storedRevision(
            revision: 10,
            environment: DevicePushProviderEnvironment.production,
          ),
        ],
      ),
    );
    final firstSandbox = Completer<HandrailChatHttpResponse>();
    final fixture = _fixture(
      storage: storage,
      handler: (request) {
        final body = _body(request);
        if (body['environment'] == 'sandbox' && body['tokenRevision'] == 2) {
          return firstSandbox.future;
        }
        return Future.value(_canonicalResponse(request));
      },
    );

    final first = fixture.client.refreshPushToken(_refresh(2));
    final queued = fixture.client.refreshPushToken(_refresh(3));
    final unrelated = fixture.client.refreshPushToken(
      _refresh(
        11,
        environment: DevicePushProviderEnvironment.production,
      ),
    );
    await Future<void>.delayed(Duration.zero);

    expect(fixture.transport.requests, hasLength(2));
    expect(
      fixture.transport.requests
          .map((request) => _body(request)['tokenRevision']),
      containsAll(<int>[2, 11]),
    );
    expect(await unrelated, isA<ChatCommandSuccess<DevicePushTokenResult>>());
    firstSandbox.complete(_canonicalResponse(fixture.transport.requests.first));
    expect(await first, isA<ChatCommandSuccess<DevicePushTokenResult>>());
    expect(await queued, isA<ChatCommandSuccess<DevicePushTokenResult>>());
    expect(
      fixture.transport.requests
          .map((request) => _body(request)['tokenRevision']),
      containsAllInOrder(<int>[2, 11, 3]),
    );
    await fixture.client.dispose();
  });

  test('rotation unregisters prior revision before registering replacement',
      () async {
    final storage = InMemoryApplicationChatStorage();
    final identity = _identity();
    await _seed(storage, identity, revision: 1);
    final fixture = _fixture(
      storage: storage,
      handler: (request) async => _canonicalResponse(request),
    );

    final result = await fixture.client.rotatePushToken(
      unregister: _unregister(2, key: 'rotation-unregister'),
      replacement: _register(3, key: 'rotation-register'),
    );

    expect(result, isA<ChatCommandSuccess<ChatPushTokenRotationResult>>());
    expect(
      fixture.transport.requests.map((request) => _body(request)['operation']),
      <String>['unregister', 'register'],
    );
    expect(
      fixture.transport.requests
          .map((request) => request.headers['Idempotency-Key']),
      <String>['rotation-unregister', 'rotation-register'],
    );
    final stored = await storage.read(
      identity,
      ApplicationChatStorageRecordKind.pushTokenRevisions,
    ) as ApplicationChatPushTokenRevisionsRecord;
    expect(stored.revisions.single.status, DevicePushTokenStatus.active);
    expect(stored.revisions.single.revision, 3);
    await fixture.client.dispose();
  });

  test('logout unregisters before removing the local revision', () async {
    final storage = _ObservingStorage();
    final identity = _identity();
    await _seed(storage, identity, revision: 1);
    storage.events.clear();
    final fixture = _fixture(
      storage: storage,
      handler: (request) async {
        storage.events.add('transport:${_body(request)['operation']}');
        return _canonicalResponse(request);
      },
    );

    final result = await fixture.client.unregisterPushTokenForLogout(
      _unregister(2, key: 'logout-unregister'),
    );

    expect(result, isA<ChatCommandSuccess<DevicePushTokenResult>>());
    expect(storage.events,
        <String>['read', 'transport:unregister', 'read', 'remove']);
    expect(
      await storage.read(
        identity,
        ApplicationChatStorageRecordKind.pushTokenRevisions,
      ),
      isNull,
    );
    await fixture.client.dispose();
  });

  test('queued and active cancellation settle without extra transport access',
      () async {
    final storage = InMemoryApplicationChatStorage();
    final identity = _identity();
    await _seed(storage, identity, revision: 1);
    final held = Completer<HandrailChatHttpResponse>();
    final fixture = _fixture(
      storage: storage,
      handler: (_) => held.future,
    );
    final activeCancellation = ChatCommandCancellationController();
    final queuedCancellation = ChatCommandCancellationController();

    final active = fixture.client.refreshPushToken(
      _refresh(2),
      cancellationSignal: activeCancellation.signal,
    );
    final queued = fixture.client.refreshPushToken(
      _refresh(3),
      cancellationSignal: queuedCancellation.signal,
    );
    await Future<void>.delayed(Duration.zero);
    expect(fixture.transport.requests, hasLength(1));
    queuedCancellation.cancel();
    expect(await queued, isA<ChatCommandAborted<DevicePushTokenResult>>());
    activeCancellation.cancel();
    expect(await active, isA<ChatCommandAborted<DevicePushTokenResult>>());
    expect(fixture.transport.requests, hasLength(1));
    await fixture.client.dispose();
  });

  test('dispose closes active and queued push-token lanes', () async {
    final storage = InMemoryApplicationChatStorage();
    final identity = _identity();
    await _seed(storage, identity, revision: 1);
    final fixture = _fixture(
        storage: storage,
        handler: (_) => Completer<HandrailChatHttpResponse>().future);
    final active = fixture.client.refreshPushToken(_refresh(2));
    final queued = fixture.client.refreshPushToken(_refresh(3));
    await Future<void>.delayed(Duration.zero);

    final disposing = fixture.client.dispose();
    expect(await active, isA<ChatCommandClosed<DevicePushTokenResult>>());
    expect(await queued, isA<ChatCommandClosed<DevicePushTokenResult>>());
    await disposing;
  });

  test(
      'device mismatch rejects before authentication, transport, or storage write',
      () async {
    var tokenCalls = 0;
    final fixture = _fixture(
      tokenProvider: () async {
        tokenCalls += 1;
        return 'access-token';
      },
      handler: (_) async => throw StateError('must not send'),
    );

    final result = await fixture.client.registerPushToken(
      _register(1, deviceId: _otherDeviceId),
    );

    expect(result, isA<ChatCommandValidationFailure<DevicePushTokenResult>>());
    expect(tokenCalls, 0);
    expect(fixture.transport.requests, isEmpty);
    expect(
      _rawStorage(
        fixture.storage,
        fixture.identity,
        ApplicationChatStorageRecordKind.pushTokenRevisions,
      ),
      isNull,
    );
    expect(result.toString(), isNot(contains(_rawToken)));
    await fixture.client.dispose();
  });

  test(
      'malformed or mismatched canonical results are token-safe and unpersisted',
      () async {
    final diagnostics = <ChatCommandDiagnostic>[];
    final fixture = _fixture(
      diagnostics: diagnostics,
      handler: (request) async {
        final body = _body(request);
        return HandrailChatHttpResponse(
          statusCode: 200,
          body: jsonEncode({
            'operation': body['operation'],
            'reconciliationStatus': 'applied',
            'idempotencyKey': body['idempotencyKey'],
            'devicePushToken': {
              'deviceId': body['deviceId'],
              'status': 'active',
              'platform': 'ios',
              'provider': 'apns',
              'environment': 'production',
              'tokenRevision': body['tokenRevision'],
              'updatedAt': '2026-08-26T20:00:00.000Z',
            },
          }),
        );
      },
    );

    final result = await fixture.client.registerPushToken(_register(1));

    expect(result, isA<ChatCommandMalformedResponse<DevicePushTokenResult>>());
    expect(result.toString(), isNot(contains(_rawToken)));
    expect(diagnostics.join('\n'), isNot(contains(_rawToken)));
    expect(
      _rawStorage(
        fixture.storage,
        fixture.identity,
        ApplicationChatStorageRecordKind.pushTokenRevisions,
      ),
      isNull,
    );
    await fixture.client.dispose();
  });

  test('push revision storage round-trips and cannot represent raw tokens',
      () async {
    final identity = _identity();
    final record = ApplicationChatPushTokenRevisionsRecord(
      identity: identity,
      revisions: [_storedRevision(revision: 7)],
    );

    final encoded = record.encode();
    final decoded = ApplicationChatStorageRecord.decode(encoded)
        as ApplicationChatPushTokenRevisionsRecord;

    expect(decoded.revisions.single.revision, 7);
    expect(decoded.revisions.single.pushService, DevicePushProvider.apns);
    expect(encoded, isNot(contains(_rawToken)));
    expect(encoded.toLowerCase(), isNot(contains('"token"')));
    expect(
      () => ApplicationChatStorageRecord.fromJson({
        'schemaVersion': applicationChatStorageSchemaVersion,
        'kind': 'push_token_revisions',
        'identity': identity.toJson(),
        'payload': {
          'revisions': [
            {..._storedRevision(revision: 7).toJson(), 'token': _rawToken},
          ],
        },
      }),
      throwsFormatException,
    );
  });
}

RegisterDevicePushTokenInput _register(
  int revision, {
  String? key,
  DeviceId deviceId = _deviceId,
  DevicePushProviderEnvironment environment =
      DevicePushProviderEnvironment.sandbox,
}) =>
    RegisterDevicePushTokenInput(
      deviceId: deviceId,
      platform: DevicePlatform.ios,
      provider: DevicePushProvider.apns,
      environment: environment,
      token: OpaquePushToken(_rawToken),
      tokenRevision: revision,
      idempotencyKey: key ?? 'register-$revision',
    );

RefreshDevicePushTokenInput _refresh(
  int revision, {
  String? key,
  DevicePushProviderEnvironment environment =
      DevicePushProviderEnvironment.sandbox,
}) =>
    RefreshDevicePushTokenInput(
      deviceId: _deviceId,
      platform: DevicePlatform.ios,
      provider: DevicePushProvider.apns,
      environment: environment,
      token: OpaquePushToken(_rawToken),
      tokenRevision: revision,
      idempotencyKey: key ?? 'refresh-$revision',
    );

UnregisterDevicePushTokenInput _unregister(int revision, {String? key}) =>
    UnregisterDevicePushTokenInput(
      deviceId: _deviceId,
      tokenRevision: revision,
      idempotencyKey: key ?? 'unregister-$revision',
    );

ApplicationChatStorageIdentity _identity() => ApplicationChatStorageIdentity(
      tenantId: const TenantId('tenant-1'),
      userId: const UserId('user-1'),
      deviceId: _deviceId,
    );

ApplicationChatPushTokenRevision _storedRevision({
  required int revision,
  DevicePushProviderEnvironment environment =
      DevicePushProviderEnvironment.sandbox,
}) =>
    ApplicationChatPushTokenRevision(
      platform: DevicePlatform.ios,
      pushService: DevicePushProvider.apns,
      environment: environment,
      status: DevicePushTokenStatus.active,
      revision: revision,
      updatedAt: const IsoTimestamp('2026-08-26T19:00:00.000Z'),
    );

Future<void> _seed(
  ApplicationChatStorage storage,
  ApplicationChatStorageIdentity identity, {
  required int revision,
}) =>
    storage.replace(
      ApplicationChatPushTokenRevisionsRecord(
        identity: identity,
        revisions: [_storedRevision(revision: revision)],
      ),
    );

Map<String, Object?> _body(HandrailChatHttpRequest request) =>
    jsonDecode(request.body!) as Map<String, Object?>;

HandrailChatHttpResponse _canonicalResponse(
  HandrailChatHttpRequest request, {
  String reconciliationStatus = 'applied',
}) {
  final body = _body(request);
  final unregister = body['operation'] == 'unregister';
  return HandrailChatHttpResponse(
    statusCode: 200,
    body: jsonEncode({
      'operation': body['operation'],
      'reconciliationStatus': reconciliationStatus,
      'idempotencyKey': body['idempotencyKey'],
      'devicePushToken': {
        'deviceId': body['deviceId'],
        'status': unregister ? 'unregistered' : 'active',
        'platform': body['platform'] ?? 'ios',
        'provider': body['provider'] ?? 'apns',
        'environment': body['environment'] ?? 'sandbox',
        'tokenRevision': body['tokenRevision'],
        'updatedAt': '2026-08-26T20:00:00.000Z',
      },
    }),
  );
}

_Fixture _fixture({
  required Future<HandrailChatHttpResponse> Function(
    HandrailChatHttpRequest request,
  ) handler,
  ApplicationChatStorage? storage,
  Future<String> Function()? tokenProvider,
  ChatCommandRetryOptions retryOptions = const ChatCommandRetryOptions(),
  List<ChatCommandDiagnostic>? diagnostics,
}) {
  final actualStorage = storage ?? InMemoryApplicationChatStorage();
  final transport = _Transport(handler);
  final identity = _identity();
  return _Fixture(
    client: HandrailChatClient(
      apiBaseUri: Uri.parse('https://chat.example.test/api/chat'),
      tokenProvider: tokenProvider ?? () async => 'access-token',
      transport: transport,
      commandRetryOptions: retryOptions,
      onCommandDiagnostic: diagnostics?.add,
      localStorage: actualStorage,
      storageIdentity: identity,
    ),
    transport: transport,
    storage: actualStorage,
    identity: identity,
  );
}

final class _Fixture {
  const _Fixture({
    required this.client,
    required this.transport,
    required this.storage,
    required this.identity,
  });

  final HandrailChatClient client;
  final _Transport transport;
  final ApplicationChatStorage storage;
  final ApplicationChatStorageIdentity identity;
}

final class _Transport implements HandrailChatHttpTransport {
  _Transport(this.handler);

  final Future<HandrailChatHttpResponse> Function(
    HandrailChatHttpRequest request,
  ) handler;
  final List<HandrailChatHttpRequest> requests = [];

  @override
  Future<HandrailChatHttpResponse> send(HandrailChatHttpRequest request) {
    requests.add(request);
    return handler(request);
  }
}

final class _ObservingStorage implements ApplicationChatStorage {
  final InMemoryApplicationChatStorage _backing =
      InMemoryApplicationChatStorage();
  final List<String> events = [];

  @override
  Future<ApplicationChatStorageRecord?> read(
    ApplicationChatStorageIdentity identity,
    ApplicationChatStorageRecordKind kind,
  ) async {
    if (kind == ApplicationChatStorageRecordKind.pushTokenRevisions) {
      events.add('read');
    }
    return _backing.read(identity, kind);
  }

  @override
  Future<void> replace(ApplicationChatStorageRecord record) =>
      _backing.replace(record);

  @override
  Future<void> clearForLogout(
    ApplicationChatStorageIdentity previousIdentity,
  ) =>
      _backing.clearForLogout(previousIdentity);

  @override
  Future<void> clearForIdentityChange({
    required ApplicationChatStorageIdentity previousIdentity,
    required ApplicationChatStorageIdentity nextIdentity,
  }) =>
      _backing.clearForIdentityChange(
        previousIdentity: previousIdentity,
        nextIdentity: nextIdentity,
      );

  @override
  Future<void> remove(
    ApplicationChatStorageIdentity identity,
    ApplicationChatStorageRecordKind kind,
  ) async {
    if (kind == ApplicationChatStorageRecordKind.pushTokenRevisions) {
      events.add('remove');
    }
    await _backing.remove(identity, kind);
  }
}

Object? _rawStorage(
  ApplicationChatStorage storage,
  ApplicationChatStorageIdentity identity,
  ApplicationChatStorageRecordKind kind,
) {
  if (storage is InMemoryApplicationChatStorage) {
    return storage.rawRecordForTesting(identity, kind);
  }
  if (storage is _ObservingStorage) {
    return storage._backing.rawRecordForTesting(identity, kind);
  }
  throw StateError('The test storage does not expose raw records.');
}

_Fixture _localFixture(ApplicationChatStorage storage) {
  final fixture = _fixture(
    storage: storage,
    handler: (request) async => _canonicalResponse(request),
  );
  addTearDown(fixture.client.dispose);
  return fixture;
}

Future<Map<String, int>> _revisions(ApplicationChatStorage storage) async {
  final record = await storage.read(
    _identity(),
    ApplicationChatStorageRecordKind.pushTokenRevisions,
  ) as ApplicationChatPushTokenRevisionsRecord?;
  return {
    for (final revision
        in record?.revisions ?? const <ApplicationChatPushTokenRevision>[])
      revision.environment.wireValue: revision.revision,
  };
}

void _expectSecretFreeWrites(_AtomicStorage storage) {
  expect(storage.proposals, isNotEmpty);
  for (final encoded in storage.proposals.whereType<String>()) {
    final record = ApplicationChatStorageRecord.decode(encoded)
        as ApplicationChatPushTokenRevisionsRecord;
    expect(record.identity, _identity());
    expect(encoded, isNot(contains(_rawToken)));
    expect(encoded, isNot(contains('access-token')));
    expect(encoded, isNot(contains('idempotencyKey')));
    expect(encoded.toLowerCase(), isNot(contains('"token"')));
    for (final revision in record.revisions) {
      expect(
          revision.toJson().keys,
          unorderedEquals([
            'platform',
            'pushService',
            'environment',
            'status',
            'revision',
            'updatedAt',
          ]));
    }
  }
}

final class _StorageGate {
  final entered = Completer<void>();
  final release = Completer<void>();

  Future<void> hold() async {
    if (entered.isCompleted) return;
    entered.complete();
    await release.future;
  }
}

/// Boundary hooks preserve the backing adapter's actual encoded-value CAS.
final class _AtomicStorage extends _ObservingStorage
    implements AtomicApplicationChatStorage {
  Future<void> Function(String? encoded)? afterRead;
  Future<void> Function(String? expected, String? replacement)? beforeWrite;
  final List<String?> proposals = [];
  bool rejectExchanges = false;
  int conflicts = 0;

  @override
  Future<String?> readEncoded(ApplicationChatStorageIdentity identity,
      ApplicationChatStorageRecordKind kind) async {
    final encoded = await _backing.readEncoded(identity, kind);
    if (kind == ApplicationChatStorageRecordKind.pushTokenRevisions) {
      await afterRead?.call(encoded);
    }
    return encoded;
  }

  @override
  Future<ApplicationChatStorageRecord?> read(
      ApplicationChatStorageIdentity identity,
      ApplicationChatStorageRecordKind kind) async {
    final encoded = await readEncoded(identity, kind);
    return encoded == null
        ? null
        : ApplicationChatStorageRecord.decode(encoded);
  }

  @override
  Future<void> replace(ApplicationChatStorageRecord record) async {
    if (record.kind == ApplicationChatStorageRecordKind.pushTokenRevisions) {
      proposals.add(record.encode());
      await beforeWrite?.call(null, record.encode());
    }
    await super.replace(record);
  }

  @override
  Future<void> remove(ApplicationChatStorageIdentity identity,
      ApplicationChatStorageRecordKind kind) async {
    if (kind == ApplicationChatStorageRecordKind.pushTokenRevisions) {
      await beforeWrite?.call(null, null);
    }
    await super.remove(identity, kind);
  }

  @override
  Future<bool> compareExchange(
      ApplicationChatStorageIdentity identity,
      ApplicationChatStorageRecordKind kind,
      String? expectedEncodedRecord,
      String? replacementEncodedRecord) async {
    if (kind == ApplicationChatStorageRecordKind.pushTokenRevisions) {
      proposals.add(replacementEncodedRecord);
      await beforeWrite?.call(expectedEncodedRecord, replacementEncodedRecord);
      if (rejectExchanges) {
        conflicts += 1;
        return false;
      }
    }
    final committed = await _backing.compareExchange(
        identity, kind, expectedEncodedRecord, replacementEncodedRecord);
    if (!committed) conflicts += 1;
    return committed;
  }
}
