import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:handrail_chat/testing.dart';

import 'package:flutter_erp/erp_chat_production.dart';
import 'package:flutter_erp/main.dart';

final Uri _testApiBase = Uri.parse('https://chat.example.test/api/chat');

void main() {
  testWidgets('one initialized client survives ordinary application rebuilds', (
    tester,
  ) async {
    final fixture = _ErpFixture()..enqueueReadyWorkspace();
    addTearDown(fixture.dispose);
    const bootstrapKey = ValueKey<String>('erp-bootstrap');

    await tester.pumpWidget(fixture.build(key: bootstrapKey));
    expect(
      find.byKey(const ValueKey<String>('erp-chat-loading')),
      findsOneWidget,
    );
    await _pumpUntil(
      tester,
      () => find.byType(HandrailChatWorkspace).evaluate().isNotEmpty,
    );
    final originalClient = fixture.client;

    await tester.pumpWidget(fixture.build(key: bootstrapKey));
    await tester.pump();

    expect(fixture.clientCreationCount, 1);
    expect(fixture.client, same(originalClient));
    expect(
      fixture.http.requests.where(
        (request) => request.uri.path.endsWith('/_meta'),
      ),
      hasLength(1),
    );
    expect(fixture.http.requests.first.uri.host, 'chat.example.test');
    expect(fixture.http.requests.first.uri.path, '/api/chat/_meta');
  });

  testWidgets('renders sanitized error and refresh-required states', (
    tester,
  ) async {
    final errorFixture = _ErpFixture();
    errorFixture.tokens.enqueueError(
      StateError('sensitive-session-detail-must-not-render'),
    );
    addTearDown(errorFixture.dispose);

    await tester.pumpWidget(
      errorFixture.build(key: const ValueKey<String>('error-bootstrap')),
    );
    await _pumpUntil(
      tester,
      () => find
          .byKey(const ValueKey<String>('erp-chat-error'))
          .evaluate()
          .isNotEmpty,
    );
    expect(find.text('Chat is unavailable'), findsOneWidget);
    expect(
      find.text('Chat credentials could not be obtained.'),
      findsOneWidget,
    );
    expect(find.textContaining('sensitive-session-detail'), findsNothing);
    expect(errorFixture.http.requests, isEmpty);

    final refreshFixture = _ErpFixture();
    refreshFixture.http.enqueueJson(
      _metadata(
        minimumProtocol: handrailChatProtocolVersion + 1,
        maximumProtocol: handrailChatProtocolVersion + 2,
      ),
    );
    addTearDown(refreshFixture.dispose);
    await tester.pumpWidget(
      refreshFixture.build(key: const ValueKey<String>('refresh-bootstrap')),
    );
    await _pumpUntil(
      tester,
      () => find
          .byKey(const ValueKey<String>('erp-chat-refresh-required'))
          .evaluate()
          .isNotEmpty,
    );
    expect(find.text('Chat update required'), findsOneWidget);
    expect(find.text(handrailChatRefreshRequiredMessage), findsOneWidget);
  });

  testWidgets('renders workspace and invokes every host-owned delegate', (
    tester,
  ) async {
    final picker = _RecordingAttachmentPicker();
    final fixture = _ErpFixture()..enqueueReadyWorkspace();
    addTearDown(fixture.dispose);

    await tester.pumpWidget(fixture.build(attachmentPicker: picker));
    await _pumpUntil(
      tester,
      () => find.byType(HandrailChatWorkspace).evaluate().isNotEmpty,
    );
    final workspace = tester.widget<HandrailChatWorkspace>(
      find.byType(HandrailChatWorkspace),
    );

    final userNavigation = workspace.delegates.openUser(
      const UserId('employee-7'),
    );
    await _pumpUntil(
      tester,
      () => find.text('Employee employee-7').evaluate().isNotEmpty,
    );
    expect(find.text('Employee employee-7'), findsOneWidget);
    Navigator.of(tester.element(find.text('Employee employee-7'))).pop();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(await userNavigation, ChatApplicationDelegateResult.handled);

    final entityNavigation = workspace.delegates.openEntity(
      const HostEntityReference(type: 'projects', id: 'project-42'),
    );
    await _pumpUntil(
      tester,
      () => find.text('projects project-42').evaluate().isNotEmpty,
    );
    expect(find.text('projects project-42'), findsOneWidget);
    Navigator.of(tester.element(find.text('projects project-42'))).pop();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(await entityNavigation, ChatApplicationDelegateResult.handled);

    expect(
      await workspace.delegates.pickAttachment(),
      isA<ChatAttachmentPickerCancelled>(),
    );
    expect(picker.callCount, 1);

    final notificationNavigation = workspace.delegates
        .showNotificationSettings();
    await _pumpUntil(
      tester,
      () => find.text('ERP notification settings').evaluate().isNotEmpty,
    );
    expect(find.text('ERP notification settings'), findsOneWidget);
    Navigator.of(tester.element(find.text('ERP notification settings'))).pop();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(await notificationNavigation, ChatApplicationDelegateResult.handled);
  });

  testWidgets('custom route renders from public timeline controller state', (
    tester,
  ) async {
    final fixture = _ErpFixture()
      ..enqueueReadyWorkspace()
      ..enqueueEmptyTimeline();
    addTearDown(fixture.dispose);

    await tester.pumpWidget(fixture.build());
    await _pumpUntil(
      tester,
      () => find.byType(HandrailChatWorkspace).evaluate().isNotEmpty,
    );
    await tester.tap(
      find.byKey(const ValueKey<String>('erp-open-custom-timeline')),
    );
    await _pumpUntil(
      tester,
      () => find.text('No messages yet').evaluate().isNotEmpty,
    );

    expect(
      find.byKey(const ValueKey<String>('erp-custom-timeline')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey<String>('erp-custom-composer')),
      findsOneWidget,
    );
    expect(
      fixture.http.requests.any(
        (request) => request.uri.path.contains(erpExampleConversationId.value),
      ),
      isTrue,
    );

    final source = File('lib/custom_timeline.dart').readAsStringSync();
    expect(source, contains("package:handrail_chat/flutter.dart"));
    expect(source, isNot(contains('package:handrail_chat/src/')));
    expect(source, isNot(contains('provider')));
    expect(source, isNot(contains('riverpod')));
    expect(source, isNot(contains('bloc')));
  });

  testWidgets('ChatScope suspends and reconnects realtime across lifecycle', (
    tester,
  ) async {
    await _setApplicationForeground(tester, true);
    final fixture = _ErpFixture(connectivity: ChatConnectivityStatus.online)
      ..enqueueReadyWorkspace();
    final sockets = FakeChatRealtimeSocketFactory();
    final firstSocket = FakeChatRealtimeSocket();
    final resumedSocket = FakeChatRealtimeSocket();
    sockets
      ..enqueueSocket(firstSocket)
      ..enqueueSocket(resumedSocket);
    final sessions = <ChatRealtimeSessionTransport>[];
    addTearDown(() async {
      await fixture.dispose();
      sockets.reset();
      await _setApplicationForeground(tester, true);
    });

    await tester.pumpWidget(
      fixture.build(
        withApplicationBindings: true,
        realtimeSessionFactory: (config) {
          final session = ChatRealtimeSessionTransport(
            endpoint: config.client.apiBaseUri,
            clientPackageVersion: 'flutter-erp-test',
            protocolVersion: handrailChatProtocolVersion,
            tokenProvider: () async => 'fixture-realtime-token',
            socketFactory: sockets.call,
            network: config.network,
          );
          sessions.add(session);
          return session;
        },
      ),
    );
    await _pumpUntil(tester, () => sockets.uris.length == 1);
    firstSocket.emitJson(_acceptedFrame(sessionId: 'initial-session'));
    await _pumpUntil(
      tester,
      () => sessions.single.state is ChatRealtimeConnectedState,
    );

    await _setApplicationForeground(tester, false);
    await _pumpUntil(tester, () => firstSocket.closeCount == 1);
    await _setApplicationForeground(tester, true);
    await _pumpUntil(tester, () => sockets.uris.length == 2);
    resumedSocket.emitJson(_acceptedFrame(sessionId: 'resumed-session'));
    await _pumpUntil(
      tester,
      () => sessions.single.state is ChatRealtimeConnectedState,
    );

    expect(sockets.uris, everyElement(hasHost('chat.example.test')));
    expect(firstSocket.closeCount, 1);
    expect(fixture.http.requests, isNotEmpty);
  });

  testWidgets(
    'production realtime factory scopes cursor storage from ChatScope',
    (tester) async {
      await _setApplicationForeground(tester, true);
      final fixture = _ErpFixture(connectivity: ChatConnectivityStatus.online)
        ..enqueueReadyWorkspace();
      final socket = FakeChatRealtimeSocket();
      final sockets = FakeChatRealtimeSocketFactory()..enqueueSocket(socket);
      final storage = _ErpCursorStorage();
      addTearDown(() async {
        await fixture.dispose();
        sockets.reset();
      });

      await tester.pumpWidget(
        fixture.build(
          withApplicationBindings: true,
          realtimeSessionFactory: createErpChatRealtimeSessionFactory(
            cursorStorage: storage,
            socketFactory: sockets.call,
          ),
        ),
      );
      await _pumpUntil(tester, () => sockets.uris.length == 1);

      expect(storage.readScopes, <String>['fixture-session']);
      expect(socket.sent, hasLength(1));
    },
  );

  test(
    'keeps credentials absent and defaults to a non-production endpoint',
    () {
      final sources = <String>[
        for (final file in Directory('lib').listSync().whereType<File>().where(
          (file) => file.path.endsWith('.dart'),
        ))
          file.readAsStringSync(),
      ].join('\n');

      expect(erpChatApiBaseUri.host, 'chat.example.invalid');
      expect(erpChatApiBaseUri.host.endsWith('.invalid'), isTrue);
      expect(sources, contains('ErpSessionTokenProvider'));
      expect(sources, isNot(contains('devtesting@hitcents.com')));
      expect(sources, isNot(contains('fixture-access-token')));
      expect(sources, isNot(contains('fixture-realtime-token')));
    },
  );
}

final class _ErpFixture {
  _ErpFixture({
    ChatConnectivityStatus connectivity = ChatConnectivityStatus.offline,
  }) : connectivity = FakeChatConnectivityDelegate(current: connectivity),
       tokens = ScriptedAccessTokenProvider(
         fallbackToken: 'fixture-access-token',
       );

  final ScriptedHandrailChatHttpTransport http =
      ScriptedHandrailChatHttpTransport();
  final ScriptedAccessTokenProvider tokens;
  final FakeChatConnectivityDelegate connectivity;
  final FakeChatDeviceIdentityDelegate deviceIdentity =
      FakeChatDeviceIdentityDelegate(fallbackDeviceId: 'fixture-device');
  late final ErpSessionTokenProvider session = _SessionTokenProvider(tokens);
  HandrailChatClient? _client;
  int clientCreationCount = 0;

  HandrailChatClient get client => _client!;

  void enqueueReadyWorkspace() {
    http
      ..enqueueJson(_metadata())
      ..enqueueJson(_emptyConversationList());
  }

  void enqueueEmptyTimeline() {
    http.enqueueJson(<String, Object?>{
      'conversationId': erpExampleConversationId.value,
      'messages': <Object?>[],
      'pagination': <String, Object?>{
        'older': <String, Object?>{'available': false},
        'newer': <String, Object?>{'available': false},
      },
      'replay': <String, Object?>{
        'resumeFrom': <String, Object?>{'eventId': 'timeline-event'},
      },
    });
  }

  Widget build({
    Key? key,
    ErpAttachmentPicker attachmentPicker =
        const UnconfiguredErpAttachmentPicker(),
    bool withApplicationBindings = false,
    ChatScopeRealtimeSessionFactory? realtimeSessionFactory,
  }) => ErpChatBootstrap(
    key: key,
    sessionTokenProvider: session,
    apiBaseUri: _testApiBase,
    transport: http,
    clientFactory: (dependencies) {
      clientCreationCount += 1;
      return _client = HandrailChatClient(
        apiBaseUri: dependencies.apiBaseUri,
        tokenProvider: dependencies.tokenProvider,
        transport: dependencies.transport,
        requestedCapabilities: const <String, bool>{'realtime': true},
      );
    },
    connectivityDelegate: withApplicationBindings ? connectivity : null,
    deviceIdentityDelegate: withApplicationBindings ? deviceIdentity : null,
    identityScopeKey: withApplicationBindings ? 'fixture-session' : null,
    realtimeSessionFactory: withApplicationBindings
        ? realtimeSessionFactory
        : null,
    child: ErpExampleApp(attachmentPicker: attachmentPicker),
  );

  Future<void> dispose() async {
    await connectivity.dispose();
    http.dispose();
  }
}

final class _SessionTokenProvider implements ErpSessionTokenProvider {
  const _SessionTokenProvider(this.provider);

  final ScriptedAccessTokenProvider provider;

  @override
  Future<String> getHandrailChatAccessToken() => provider.call();
}

final class _RecordingAttachmentPicker implements ErpAttachmentPicker {
  int callCount = 0;

  @override
  Future<ChatAttachmentPickerResult> pickAttachments() async {
    callCount += 1;
    return const ChatAttachmentPickerCancelled();
  }
}

final class _ErpCursorStorage implements ChatRealtimeCursorStorage {
  final Map<String, String> values = <String, String>{};
  final List<String> readScopes = <String>[];

  @override
  String? read({required String scope}) {
    readScopes.add(scope);
    return values[scope];
  }

  @override
  void write({required String scope, required String value}) {
    values[scope] = value;
  }

  @override
  void clear({required String scope}) {
    values.remove(scope);
  }
}

Map<String, Object?> _metadata({
  int minimumProtocol = handrailChatProtocolVersion - 1,
  int maximumProtocol = handrailChatProtocolVersion,
}) => <String, Object?>{
  'packageVersion': '1.0.0-test',
  'protocolVersion': maximumProtocol,
  'schemaVersion': 1,
  'enabledFeatures': <String, bool>{'realtime': true},
  'supportedProtocolRange': <String, int>{
    'minimumVersion': minimumProtocol,
    'maximumVersion': maximumProtocol,
  },
};

Map<String, Object?> _emptyConversationList() => <String, Object?>{
  'kind': 'conversation_list',
  'scope': <String, Object?>{'type': 'organization'},
  'items': <Object?>[],
  'page': <String, Object?>{},
  '_meta': <String, Object?>{
    ..._metadata(),
    'feature': <String, Object?>{
      'name': conversationSnapshotFeature,
      'version': conversationSnapshotVersion,
    },
  },
};

Map<String, Object?> _acceptedFrame({required String sessionId}) =>
    <String, Object?>{
      'type': 'chat.session.accepted',
      'metadata': _metadata(),
      'tenantId': 'fixture-tenant',
      'actorStreamId': 'user:fixture-user',
      'deviceId': 'fixture-device',
      'sessionId': sessionId,
    };

Matcher hasHost(String host) =>
    predicate<Uri>((uri) => uri.host == host, 'URI has host $host');

Future<void> _setApplicationForeground(
  WidgetTester tester,
  bool foreground,
) async {
  final binding = tester.binding;
  final current = binding.lifecycleState;
  if (foreground) {
    switch (current) {
      case null:
      case AppLifecycleState.detached:
      case AppLifecycleState.inactive:
        binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      case AppLifecycleState.hidden:
        binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
        binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      case AppLifecycleState.paused:
        binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
        binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
        binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      case AppLifecycleState.resumed:
        break;
    }
  } else {
    switch (current) {
      case null:
        binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      case AppLifecycleState.resumed:
        binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
        binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
        binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      case AppLifecycleState.inactive:
        binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
        binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      case AppLifecycleState.hidden:
        binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      case AppLifecycleState.paused:
        break;
      case AppLifecycleState.detached:
        binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
        await _setApplicationForeground(tester, false);
    }
  }
  await _flushAsync(tester);
}

Future<void> _pumpUntil(
  WidgetTester tester,
  bool Function() condition, {
  int attempts = 100,
}) async {
  for (var attempt = 0; attempt < attempts; attempt += 1) {
    if (condition()) return;
    await _flushAsync(tester);
  }
  fail('Condition was not met after $attempts pumps.');
}

Future<void> _flushAsync(WidgetTester tester) async {
  await tester.runAsync(() async {
    for (var index = 0; index < 10; index += 1) {
      await Future<void>.delayed(Duration.zero);
    }
  });
  await tester.pump(const Duration(milliseconds: 10));
}
