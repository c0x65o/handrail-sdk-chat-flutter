import 'dart:async';
import 'dart:convert';

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:handrail_chat/flutter.dart';
import 'package:handrail_chat/testing.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('initialized fixture completes a push command', () async {
    final transport = _Transport();
    final client = _client(transport, 'device-direct');
    await client.initialize();
    final cancellation = ChatCommandCancellationController();
    final result = await client.registerPushToken(
      RegisterDevicePushTokenInput(
        deviceId: const DeviceId('device-direct'),
        platform: DevicePlatform.ios,
        provider: DevicePushProvider.apns,
        environment: DevicePushProviderEnvironment.sandbox,
        token: OpaquePushToken('direct-token'),
        tokenRevision: 1,
        idempotencyKey: 'direct-register',
      ),
      cancellationSignal: cancellation.signal,
    );
    expect(result, isA<ChatCommandSuccess<DevicePushTokenResult>>());
    await client.dispose();
  });

  tearDown(() {
    _resumeApplication(TestWidgetsFlutterBinding.instance);
  });

  testWidgets('waits for client readiness and identity before registering', (
    tester,
  ) async {
    final identity = Completer<String>();
    final connectivity = _Connectivity(ChatConnectivityStatus.online);
    final tokens = _Tokens(initial: _token('initial-secret'));
    final transport = _Transport();
    final client = _client(transport, 'device-a');

    await tester.pumpWidget(
      _scope(
        client: client,
        connectivity: connectivity,
        identity: _Identity((_) => identity.future),
        tokens: tokens,
      ),
    );
    await _flush(tester);
    expect(tokens.listenCount, 0);
    expect(transport.pushRequests, isEmpty);

    identity.complete('device-a');
    await _flush(tester);
    expect(tokens.listenCount, 0);

    await client.initialize();
    await _flush(tester);
    expect(tokens.listenCount, 1);
    expect(tokens.initialScopes, <Object?>['account-a']);
    expect(transport.pushRequests, hasLength(1));
    expect(_body(transport.pushRequests.single)['operation'], 'register');
    expect(_body(transport.pushRequests.single)['token'], 'initial-secret');

    await tester.pumpWidget(const SizedBox.shrink());
    await _flush(tester);
    // The external client remains host-owned; scope teardown is asserted above.
  });

  testWidgets(
    'gates foreground/connectivity and suppresses duplicate token values',
    (tester) async {
      final binding = TestWidgetsFlutterBinding.instance;
      _pauseApplication(binding);
      final connectivity = _Connectivity(ChatConnectivityStatus.offline);
      final tokens = _Tokens(initial: _token('token-a'));
      final transport = _Transport();
      final client = _client(transport, 'device-a');
      final diagnostics = <ChatScopeIntegrationDiagnostic>[];
      await client.initialize();

      await tester.pumpWidget(
        _scope(
          client: client,
          connectivity: connectivity,
          identity: _Identity((_) => 'device-a'),
          tokens: tokens,
          diagnostics: diagnostics,
        ),
      );
      await _flush(tester);
      expect(transport.pushRequests, isEmpty);

      connectivity.emit(ChatConnectivityStatus.online);
      await _flush(tester);
      expect(transport.pushRequests, isEmpty);

      _resumeApplication(binding);
      await _flush(tester);
      expect(transport.pushRequests, hasLength(1));

      tokens.emit(_token('token-a'));
      tokens.emit(_token('token-a'));
      await _flush(tester);
      expect(transport.pushRequests, hasLength(1));

      _pauseApplication(binding);
      tokens.emit(_token('token-b'));
      await _flush(tester);
      expect(transport.pushRequests, hasLength(1));

      _resumeApplication(binding);
      await _flush(tester);
      expect(
        transport.pushRequests.map((request) => _body(request)['operation']),
        <Object?>['register', 'unregister', 'register'],
        reason: diagnostics.join('\n'),
      );

      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets('serializes distinct rotations', (tester) async {
    final transport = _Transport(blockPush: true);
    final client = _client(transport, 'device-a');
    await client.initialize();
    final tokens = _Tokens(initial: _token('token-a'));

    await tester.pumpWidget(
      _scope(
        client: client,
        connectivity: _Connectivity(ChatConnectivityStatus.online),
        identity: _Identity((_) => 'device-a'),
        tokens: tokens,
      ),
    );
    await _flush(tester);
    expect(transport.pushRequests, hasLength(1));

    tokens.emit(_token('token-b'));
    tokens.emit(_token('token-c'));
    await _flush(tester);
    expect(transport.pushRequests, hasLength(1));

    transport.completeNext();
    await _waitForPushRequestCount(tester, transport, 2);
    expect(_operations(transport), <Object?>['register', 'unregister']);
    transport.completeNext();
    await _waitForPushRequestCount(tester, transport, 3);
    expect(_operations(transport),
        <Object?>['register', 'unregister', 'register']);
    transport.completeNext();
    await _waitForPushRequestCount(tester, transport, 4);
    expect(
      _operations(transport),
      <Object?>['register', 'unregister', 'register', 'unregister'],
    );
    transport.completeNext();
    await _waitForPushRequestCount(tester, transport, 5);
    transport.completeNext();
    await _flush(tester);
    expect(transport.maximumConcurrentPushRequests, 1);
    expect(
      transport.pushRequests
          .where((request) => _body(request)['operation'] == 'register')
          .map((request) => _body(request)['token']),
      <Object?>['token-a', 'token-b', 'token-c'],
    );

    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('retries failed work only after connectivity returns', (
    tester,
  ) async {
    final connectivity = _Connectivity(ChatConnectivityStatus.online);
    final transport = _Transport(failFirstPush: true);
    final diagnostics = <ChatScopeIntegrationDiagnostic>[];
    final client = _client(transport, 'device-a');
    await client.initialize();

    await tester.pumpWidget(
      _scope(
        client: client,
        connectivity: connectivity,
        identity: _Identity((_) => 'device-a'),
        tokens: _Tokens(initial: _token('credential-that-must-not-leak')),
        diagnostics: diagnostics,
      ),
    );
    await _flush(tester);
    expect(transport.pushRequests, hasLength(1));
    expect(
      diagnostics.last.code,
      ChatScopeIntegrationDiagnosticCode.pushTokenRegistrationFailed,
    );
    expect(
      diagnostics.join(),
      isNot(contains('credential-that-must-not-leak')),
    );

    connectivity.emit(ChatConnectivityStatus.online);
    await _flush(tester);
    expect(transport.pushRequests, hasLength(1));
    connectivity.emit(ChatConnectivityStatus.offline);
    connectivity.emit(ChatConnectivityStatus.online);
    await _flush(tester);
    expect(transport.pushRequests, hasLength(2));

    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets(
      'sanitizes delegate errors and retries initial lookup on reconnect', (
    tester,
  ) async {
    const providerError = 'provider-exception-with-credential';
    final connectivity = _Connectivity(ChatConnectivityStatus.online);
    final tokens = _Tokens(
      initialProvider: (call, _) {
        if (call == 1) throw StateError(providerError);
        return _token('recovered-token');
      },
    );
    final diagnostics = <ChatScopeIntegrationDiagnostic>[];
    final transport = _Transport();
    final client = _client(transport, 'device-a');
    await client.initialize();

    await tester.pumpWidget(
      _scope(
        client: client,
        connectivity: connectivity,
        identity: _Identity((_) => 'device-a'),
        tokens: tokens,
        diagnostics: diagnostics,
      ),
    );
    await _flush(tester);
    expect(tokens.initialCalls, 1);
    expect(diagnostics.single.code,
        ChatScopeIntegrationDiagnosticCode.pushTokenInitialFailed);
    expect(diagnostics.join(), isNot(contains(providerError)));

    connectivity.emit(ChatConnectivityStatus.online);
    await _flush(tester);
    expect(tokens.initialCalls, 1);
    connectivity.emit(ChatConnectivityStatus.offline);
    connectivity.emit(ChatConnectivityStatus.online);
    await _flush(tester);
    expect(tokens.initialCalls, 2);
    expect(transport.pushRequests, hasLength(1));

    tokens.emitError(StateError(providerError));
    await _flush(tester);
    expect(diagnostics.last.code,
        ChatScopeIntegrationDiagnosticCode.pushTokenStreamFailed);
    expect(diagnostics.join(), isNot(contains(providerError)));

    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('only explicit logout unregisters and disposal cancels streams', (
    tester,
  ) async {
    final tokens = _Tokens(initial: _token('token-a'));
    final transport = _Transport();
    final client = _client(transport, 'device-a');
    await client.initialize();
    final connectivity = _Connectivity(ChatConnectivityStatus.online);
    final identity = _Identity((_) => 'device-a');
    late ChatScopeBinding scopeBinding;
    late StateSetter rebuild;

    await tester.pumpWidget(
      _host(
        StatefulBuilder(
          builder: (context, setState) {
            rebuild = setState;
            return _scopeBody(
              client: client,
              connectivity: connectivity,
              identity: identity,
              tokens: tokens,
              child: Builder(
                builder: (context) {
                  scopeBinding = ChatScope.of(context);
                  return const SizedBox.shrink();
                },
              ),
            );
          },
        ),
      ),
    );
    await _flush(tester);
    expect(_operations(transport), <Object?>['register']);

    rebuild(() {});
    await _flush(tester);
    expect(_operations(transport), <Object?>['register']);

    final logoutFuture = scopeBinding.unregisterPushTokenForLogout();
    await _flush(tester);
    final logout = await logoutFuture;
    expect(logout, isA<ChatCommandSuccess<DevicePushTokenResult>>());
    expect(_operations(transport), <Object?>['register', 'unregister']);

    await tester.pumpWidget(const SizedBox.shrink());
    await _flush(tester);
    expect(tokens.cancelCount, 1);
    expect(_operations(transport), <Object?>['register', 'unregister']);
  });

  testWidgets('account replacement fences stale token completion and events', (
    tester,
  ) async {
    final delayedInitial = Completer<ChatPushToken?>();
    final oldTokens = _Tokens(initialFuture: delayedInitial.future);
    final newTokens = _Tokens(initial: _token('new-token'));
    final oldTransport = _Transport();
    final newTransport = _Transport();
    final oldClient = _client(oldTransport, 'device-a');
    final newClient = _client(newTransport, 'device-b');
    await oldClient.initialize();
    await newClient.initialize();

    await tester.pumpWidget(
      _scope(
        key: const ValueKey<String>('account-a'),
        client: oldClient,
        connectivity: _Connectivity(ChatConnectivityStatus.online),
        identity: _Identity((_) => 'device-a'),
        tokens: oldTokens,
      ),
    );
    await _flush(tester);
    expect(oldTokens.listenCount, 1);

    await tester.pumpWidget(
      _scope(
        key: const ValueKey<String>('account-b'),
        client: newClient,
        connectivity: _Connectivity(ChatConnectivityStatus.online),
        identity: _Identity((_) => 'device-b'),
        tokens: newTokens,
        identityScopeKey: 'account-b',
      ),
    );
    await _flush(tester);
    expect(newTransport.pushRequests, hasLength(1));
    expect(oldTokens.cancelCount, 1);

    delayedInitial.complete(_token('old-secret-token'));
    oldTokens.emit(_token('stale-rotation'));
    await _flush(tester);
    expect(oldTransport.pushRequests, isEmpty);
    expect(newTransport.pushRequests, hasLength(1));

    await tester.pumpWidget(const SizedBox.shrink());
  });
}

Widget _scope({
  Key? key,
  required HandrailChatClient client,
  required _Connectivity connectivity,
  required _Identity identity,
  required _Tokens tokens,
  List<ChatScopeIntegrationDiagnostic>? diagnostics,
  Object? identityScopeKey = 'account-a',
}) =>
    _host(
      _scopeBody(
        key: key,
        client: client,
        connectivity: connectivity,
        identity: identity,
        tokens: tokens,
        diagnostics: diagnostics,
        identityScopeKey: identityScopeKey,
      ),
    );

Widget _scopeBody({
  Key? key,
  required HandrailChatClient client,
  required _Connectivity connectivity,
  required _Identity identity,
  required _Tokens tokens,
  List<ChatScopeIntegrationDiagnostic>? diagnostics,
  Object? identityScopeKey = 'account-a',
  Widget child = const SizedBox.shrink(),
}) =>
    ChatScope(
      key: key,
      client: client,
      connectivityDelegate: connectivity,
      deviceIdentityDelegate: identity,
      identityScopeKey: identityScopeKey,
      realtimeSessionFactory: _session,
      pushTokenDelegate: tokens,
      onIntegrationDiagnostic: diagnostics?.add,
      child: child,
    );

Widget _host(Widget child) => Directionality(
      textDirection: TextDirection.ltr,
      child: child,
    );

HandrailChatClient _client(_Transport transport, String deviceId) =>
    HandrailChatClient(
      apiBaseUri: Uri.parse('https://chat.example.test/api/chat'),
      tokenProvider: () async => 'access-token',
      transport: transport,
      localStorage: InMemoryApplicationChatStorage(),
      storageIdentity: ApplicationChatStorageIdentity(
        tenantId: const TenantId('tenant-1'),
        userId: const UserId('user-1'),
        deviceId: DeviceId(deviceId),
      ),
    );

ChatRealtimeSessionTransport _session(ChatScopeRealtimeSessionConfig config) =>
    ChatRealtimeSessionTransport(
      endpoint: config.client.apiBaseUri,
      clientPackageVersion: '0.1.3',
      protocolVersion: handrailChatProtocolVersion,
      tokenProvider: () => 'realtime-token',
      socketFactory: (_, __) => _Socket(),
      network: config.network,
    );

ChatPushToken _token(String value) => ChatPushToken(
      token: value,
      platform: DevicePlatform.ios,
      provider: DevicePushProvider.apns,
      environment: DevicePushProviderEnvironment.sandbox,
    );

Future<void> _flush(WidgetTester tester) async {
  await tester.pump();
  await tester.runAsync(() async {
    for (var index = 0; index < 8; index += 1) {
      await Future<void>.delayed(Duration.zero);
    }
  });
  await tester.pump();
}

Future<void> _waitForPushRequestCount(
  WidgetTester tester,
  _Transport transport,
  int count,
) async {
  for (var attempt = 0; attempt < 50; attempt += 1) {
    await _flush(tester);
    if (transport.pushRequests.length >= count) return;
  }
}

Map<String, Object?> _body(HandrailChatHttpRequest request) =>
    jsonDecode(request.body!) as Map<String, Object?>;

List<Object?> _operations(_Transport transport) => transport.pushRequests
    .map((request) => _body(request)['operation'])
    .toList(growable: false);

final class _Connectivity implements ChatConnectivityDelegate {
  _Connectivity(this.current);

  ChatConnectivityStatus current;
  final StreamController<ChatConnectivityStatus> _changes =
      StreamController<ChatConnectivityStatus>.broadcast(sync: true);

  @override
  Stream<ChatConnectivityStatus> get connectivityChanges => _changes.stream;

  @override
  ChatConnectivityStatus getCurrentConnectivity() => current;

  void emit(ChatConnectivityStatus status) {
    current = status;
    _changes.add(status);
  }
}

final class _Identity implements ChatDeviceIdentityDelegate {
  const _Identity(this.resolve);

  final FutureOr<String> Function(Object? scope) resolve;

  @override
  FutureOr<String> getOrCreateDeviceId({required Object? identityScopeKey}) =>
      resolve(identityScopeKey);
}

final class _Tokens implements ChatPushTokenDelegate {
  _Tokens({
    this.initial,
    this.initialFuture,
    this.initialProvider,
  }) {
    _rotations = StreamController<ChatPushToken>.broadcast(
      sync: true,
      onListen: () => listenCount += 1,
      onCancel: () => cancelCount += 1,
    );
  }

  final ChatPushToken? initial;
  final Future<ChatPushToken?>? initialFuture;
  final ChatPushToken? Function(int call, Object? scope)? initialProvider;
  late final StreamController<ChatPushToken> _rotations;
  final List<Object?> initialScopes = <Object?>[];
  int initialCalls = 0;
  int listenCount = 0;
  int cancelCount = 0;

  @override
  FutureOr<ChatPushToken?> getInitialPushToken({
    required Object? identityScopeKey,
  }) {
    initialCalls += 1;
    initialScopes.add(identityScopeKey);
    final provider = initialProvider;
    if (provider != null) return provider(initialCalls, identityScopeKey);
    final future = initialFuture;
    if (future != null) return future;
    return initial;
  }

  @override
  Stream<ChatPushToken> get pushTokenRotations => _rotations.stream;

  void emit(ChatPushToken token) => _rotations.add(token);

  void emitError(Object error) => _rotations.addError(error);
}

final class _Transport implements HandrailChatHttpTransport {
  _Transport({this.blockPush = false, this.failFirstPush = false});

  final bool blockPush;
  final bool failFirstPush;
  final List<HandrailChatHttpRequest> requests = <HandrailChatHttpRequest>[];
  final List<Completer<HandrailChatHttpResponse>> _blocked =
      <Completer<HandrailChatHttpResponse>>[];
  int _activePushRequests = 0;
  int maximumConcurrentPushRequests = 0;

  List<HandrailChatHttpRequest> get pushRequests => requests
      .where((request) => request.uri.path.endsWith('/push-token'))
      .toList(growable: false);

  @override
  Future<HandrailChatHttpResponse> send(HandrailChatHttpRequest request) async {
    requests.add(request);
    if (!request.uri.path.endsWith('/push-token')) return _metadataResponse;
    _activePushRequests += 1;
    if (_activePushRequests > maximumConcurrentPushRequests) {
      maximumConcurrentPushRequests = _activePushRequests;
    }
    try {
      if (failFirstPush && pushRequests.length == 1) {
        return const HandrailChatHttpResponse(
          statusCode: 400,
          body: '{"error":{"code":"rejected"}}',
        );
      }
      if (blockPush) {
        final completer = Completer<HandrailChatHttpResponse>();
        _blocked.add(completer);
        return await completer.future;
      }
      return _pushResponse(request);
    } finally {
      _activePushRequests -= 1;
    }
  }

  void completeNext() {
    final completer = _blocked.removeAt(0);
    final request = pushRequests[_completedPushCount];
    _completedPushCount += 1;
    completer.complete(_pushResponse(request));
  }

  int _completedPushCount = 0;
}

HandrailChatHttpResponse _pushResponse(HandrailChatHttpRequest request) {
  final body = _body(request);
  final unregister = body['operation'] == 'unregister';
  return HandrailChatHttpResponse(
    statusCode: 200,
    body: jsonEncode(<String, Object?>{
      'operation': body['operation'],
      'reconciliationStatus': 'applied',
      'idempotencyKey': body['idempotencyKey'],
      'devicePushToken': <String, Object?>{
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

final HandrailChatHttpResponse _metadataResponse = HandrailChatHttpResponse(
  statusCode: 200,
  body: jsonEncode(<String, Object?>{
    'packageVersion': '0.1.3',
    'protocolVersion': handrailChatProtocolVersion,
    'schemaVersion': 7,
    'enabledFeatures': <String, bool>{'realtime': true},
    'supportedProtocolRange': <String, int>{
      'minimumVersion': handrailChatProtocolVersion - 1,
      'maximumVersion': handrailChatProtocolVersion,
    },
  }),
);

void _pauseApplication(TestWidgetsFlutterBinding binding) {
  switch (binding.lifecycleState) {
    case null:
      binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      return;
    case AppLifecycleState.resumed:
      binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
      binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      return;
    case AppLifecycleState.inactive:
      binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
      binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      return;
    case AppLifecycleState.hidden:
      binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      return;
    case AppLifecycleState.paused:
      return;
    case AppLifecycleState.detached:
      binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      _pauseApplication(binding);
      return;
  }
}

void _resumeApplication(TestWidgetsFlutterBinding binding) {
  switch (binding.lifecycleState) {
    case null:
      binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      return;
    case AppLifecycleState.resumed:
      return;
    case AppLifecycleState.inactive:
      binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      return;
    case AppLifecycleState.hidden:
      binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      return;
    case AppLifecycleState.paused:
      binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
      binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      return;
    case AppLifecycleState.detached:
      binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      return;
  }
}

final class _Socket implements ChatRealtimeSocket {
  final StreamController<Object?> _frames =
      StreamController<Object?>.broadcast(sync: true);

  @override
  Stream<Object?> get frames => _frames.stream;

  @override
  void send(String data) {}

  @override
  void close() {}
}
