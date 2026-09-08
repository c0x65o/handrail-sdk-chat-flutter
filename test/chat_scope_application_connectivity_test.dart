import 'dart:async';
import 'dart:convert';

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:handrail_chat/flutter.dart';

void main() {
  group('ChatScope application delegates', () {
    testWidgets('resolves device identity before client and handshake', (
      tester,
    ) async {
      final events = <String>[];
      final device = Completer<String>();
      final connectivity = _FakeConnectivity(ChatConnectivityStatus.online);
      final identity = _FakeIdentity((scope) async {
        events.add('identity:start:$scope');
        final value = await device.future;
        events.add('identity:done:$value');
        return value;
      });
      final http = _ImmediateTransport();
      final sockets = <_FakeSocket>[];
      late ChatScopeBinding binding;

      await tester.pumpWidget(
        _host(
          ChatScope(
            config: _clientConfig(http),
            connectivityDelegate: connectivity,
            deviceIdentityDelegate: identity,
            identityScopeKey: 'login-a',
            realtimeSessionFactory: (config) {
              events.add('session:${config.deviceId.value}');
              return _session(config, sockets, events: events);
            },
            child: Builder(
              builder: (context) {
                binding = ChatScope.of(context);
                return const SizedBox.shrink();
              },
            ),
          ),
        ),
      );
      await tester.pump();
      await tester.pump();

      expect(http.requests, isEmpty);
      expect(sockets, isEmpty);
      expect(binding.integrationReadiness,
          ChatScopeIntegrationReadiness.resolving);

      device.complete('device-a');
      await tester.pumpAndSettle();

      expect(http.requests, hasLength(1));
      expect(sockets, hasLength(1));
      expect(binding.deviceId, const DeviceId('device-a'));
      expect(binding.integrationReadiness, ChatScopeIntegrationReadiness.ready);
      expect(
        events,
        containsAllInOrder(<String>[
          'identity:done:device-a',
          'session:device-a',
          'socket:open',
          'socket:handshake',
        ]),
      );
    });

    testWidgets('offline and unknown startup open no socket', (tester) async {
      for (final status in <ChatConnectivityStatus>[
        ChatConnectivityStatus.offline,
        ChatConnectivityStatus.unknown,
      ]) {
        final connectivity = _FakeConnectivity(status);
        final sockets = <_FakeSocket>[];
        late ChatScopeBinding binding;

        await tester.pumpWidget(
          _host(
            ChatScope(
              key: ValueKey<ChatConnectivityStatus>(status),
              config: _clientConfig(_ImmediateTransport()),
              connectivityDelegate: connectivity,
              deviceIdentityDelegate:
                  _FakeIdentity((_) async => 'device-$status'),
              identityScopeKey: status,
              realtimeSessionFactory: (config) => _session(config, sockets),
              child: Builder(
                builder: (context) {
                  binding = ChatScope.of(context);
                  return const SizedBox.shrink();
                },
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();

        expect(binding.connectivity, status);
        expect(binding.realtimeState, isA<ChatRealtimeOfflineState>());
        expect(sockets, isEmpty, reason: '$status must be conservative');
        await tester.pumpWidget(_host(const SizedBox.shrink()));
        await tester.pump();
      }
    });

    testWidgets('offline to online connects once and suppresses duplicates', (
      tester,
    ) async {
      final connectivity = _FakeConnectivity(ChatConnectivityStatus.offline);
      final sockets = <_FakeSocket>[];

      await tester.pumpWidget(
        _host(
          ChatScope(
            config: _clientConfig(_ImmediateTransport()),
            connectivityDelegate: connectivity,
            deviceIdentityDelegate: _FakeIdentity((_) async => 'device-a'),
            identityScopeKey: 'login-a',
            realtimeSessionFactory: (config) => _session(config, sockets),
            child: const SizedBox.shrink(),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(sockets, isEmpty);

      connectivity.emit(ChatConnectivityStatus.offline);
      connectivity.emit(ChatConnectivityStatus.online);
      connectivity.emit(ChatConnectivityStatus.online);
      await tester.pump();
      await tester.pump();
      expect(sockets, hasLength(1));

      connectivity.emit(ChatConnectivityStatus.offline);
      connectivity.emit(ChatConnectivityStatus.offline);
      await _flushAsync(tester);
      expect(sockets.single.closeCalls, 1);

      connectivity.emit(ChatConnectivityStatus.online);
      connectivity.emit(ChatConnectivityStatus.online);
      await tester.pump();
      await tester.pump();
      expect(sockets, hasLength(2));
    });

    testWidgets('scope changes discard stale identity work', (tester) async {
      final deviceA = Completer<String>();
      final deviceB = Completer<String>();
      final identity = _FakeIdentity(
        (scope) => scope == 'login-a' ? deviceA.future : deviceB.future,
      );
      final firstConnectivity =
          _FakeConnectivity(ChatConnectivityStatus.online);
      final secondConnectivity =
          _FakeConnectivity(ChatConnectivityStatus.online);
      final sockets = <_FakeSocket>[];
      final sessionDevices = <String>[];
      late StateSetter rebuild;
      var scopeKey = 'login-a';

      ChatRealtimeSessionTransport factory(
        ChatScopeRealtimeSessionConfig config,
      ) {
        sessionDevices.add(config.deviceId.value);
        return _session(config, sockets);
      }

      await tester.pumpWidget(
        _host(
          StatefulBuilder(
            builder: (context, setState) {
              rebuild = setState;
              return ChatScope(
                config: _clientConfig(_ImmediateTransport()),
                connectivityDelegate: scopeKey == 'login-a'
                    ? firstConnectivity
                    : secondConnectivity,
                deviceIdentityDelegate: identity,
                identityScopeKey: scopeKey,
                realtimeSessionFactory: factory,
                child: const SizedBox.shrink(),
              );
            },
          ),
        ),
      );
      await tester.pump();
      await tester.pump();

      rebuild(() => scopeKey = 'login-b');
      await tester.pump();
      deviceB.complete('device-b');
      await tester.pumpAndSettle();
      await _flushAsync(tester);
      expect(sessionDevices, <String>['device-b']);
      expect(sockets, hasLength(1));
      expect(firstConnectivity.cancelCount, 1);

      deviceA.complete('device-a');
      await tester.pump();
      await tester.pump();
      expect(sessionDevices, <String>['device-b']);
      expect(sockets, hasLength(1));
    });

    testWidgets('identity errors are sanitized and a new scope recovers', (
      tester,
    ) async {
      const secret = 'private-identity-provider-value';
      final identity = _FakeIdentity((scope) {
        if (scope == 'bad') throw StateError(secret);
        return 'device-good';
      });
      final connectivity = _FakeConnectivity(ChatConnectivityStatus.online);
      final sockets = <_FakeSocket>[];
      final diagnostics = <ChatScopeIntegrationDiagnostic>[];
      late ChatScopeBinding binding;
      late StateSetter rebuild;
      var scopeKey = 'bad';
      ChatRealtimeSessionTransport factory(
        ChatScopeRealtimeSessionConfig config,
      ) =>
          _session(config, sockets);

      await tester.pumpWidget(
        _host(
          StatefulBuilder(
            builder: (context, setState) {
              rebuild = setState;
              return ChatScope(
                config: _clientConfig(_ImmediateTransport()),
                connectivityDelegate: connectivity,
                deviceIdentityDelegate: identity,
                identityScopeKey: scopeKey,
                realtimeSessionFactory: factory,
                onIntegrationDiagnostic: diagnostics.add,
                child: Builder(
                  builder: (context) {
                    binding = ChatScope.of(context);
                    return const SizedBox.shrink();
                  },
                ),
              );
            },
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(binding.integrationReadiness, ChatScopeIntegrationReadiness.error);
      expect(binding.integrationDiagnostic!.code,
          ChatScopeIntegrationDiagnosticCode.deviceIdentityFailed);
      expect(binding.integrationDiagnostic.toString(), isNot(contains(secret)));
      expect(diagnostics.single.toString(), isNot(contains(secret)));
      expect(sockets, isEmpty);

      rebuild(() => scopeKey = 'good');
      await tester.pumpAndSettle();
      await _flushAsync(tester);
      expect(binding.integrationReadiness, ChatScopeIntegrationReadiness.ready);
      expect(binding.deviceId, const DeviceId('device-good'));
      expect(binding.integrationDiagnostic, isNull);
      expect(sockets, hasLength(1));
    });

    testWidgets('invalid identity never starts the client or session', (
      tester,
    ) async {
      final http = _ImmediateTransport();
      final sockets = <_FakeSocket>[];
      late ChatScopeBinding binding;

      await tester.pumpWidget(
        _host(
          ChatScope(
            config: _clientConfig(http),
            connectivityDelegate:
                _FakeConnectivity(ChatConnectivityStatus.online),
            deviceIdentityDelegate: _FakeIdentity((_) async => '  '),
            identityScopeKey: 'login-a',
            realtimeSessionFactory: (config) => _session(config, sockets),
            child: Builder(
              builder: (context) {
                binding = ChatScope.of(context);
                return const SizedBox.shrink();
              },
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(http.requests, isEmpty);
      expect(sockets, isEmpty);
      expect(binding.integrationDiagnostic!.code,
          ChatScopeIntegrationDiagnosticCode.invalidDeviceIdentity);
    });

    testWidgets('connectivity errors are sanitized and stream data recovers', (
      tester,
    ) async {
      const secret = 'private-connectivity-provider-value';
      final connectivity = _FakeConnectivity(
        ChatConnectivityStatus.unknown,
        currentError: StateError(secret),
      );
      final sockets = <_FakeSocket>[];
      final diagnostics = <ChatScopeIntegrationDiagnostic>[];
      late ChatScopeBinding binding;

      await tester.pumpWidget(
        _host(
          ChatScope(
            config: _clientConfig(_ImmediateTransport()),
            connectivityDelegate: connectivity,
            deviceIdentityDelegate: _FakeIdentity((_) async => 'device-a'),
            identityScopeKey: 'login-a',
            realtimeSessionFactory: (config) => _session(config, sockets),
            onIntegrationDiagnostic: diagnostics.add,
            child: Builder(
              builder: (context) {
                binding = ChatScope.of(context);
                return const SizedBox.shrink();
              },
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(binding.connectivity, ChatConnectivityStatus.unknown);
      expect(binding.integrationDiagnostic!.code,
          ChatScopeIntegrationDiagnosticCode.connectivityQueryFailed);
      expect(binding.integrationDiagnostic.toString(), isNot(contains(secret)));
      expect(sockets, isEmpty);

      connectivity.emitError(StateError(secret));
      await tester.pump();
      expect(binding.integrationDiagnostic!.code,
          ChatScopeIntegrationDiagnosticCode.connectivityStreamFailed);
      expect(diagnostics.last.toString(), isNot(contains(secret)));

      connectivity.emit(ChatConnectivityStatus.online);
      await tester.pump();
      await tester.pump();
      expect(binding.integrationDiagnostic, isNull);
      expect(binding.connectivity, ChatConnectivityStatus.online);
      expect(sockets, hasLength(1));
      expect(tester.takeException(), isNull);
    });

    testWidgets(
      'identity replacement isolates delayed cursor work in one adapter',
      (tester) async {
        final storage = _ScopedCursorStorage()
          ..values['login-a'] =
              jsonEncode(<String, Object?>{'eventId': 'cursor-a'});
        final connectivity = _FakeConnectivity(ChatConnectivityStatus.online);
        final identity = _FakeIdentity((scope) => 'device-$scope');
        final http = _ImmediateTransport();
        final sockets = <_FakeSocket>[];
        final sessions = <ChatRealtimeSessionTransport>[];
        late StateSetter rebuild;
        var scopeKey = 'login-a';

        ChatRealtimeSessionTransport factory(
          ChatScopeRealtimeSessionConfig config,
        ) {
          final scope = config.identityScopeKey! as String;
          final session = ChatRealtimeSessionTransport(
            endpoint: config.client.apiBaseUri,
            clientPackageVersion: '0.1.3',
            protocolVersion: handrailChatProtocolVersion,
            tokenProvider: () async => 'realtime-token',
            socketFactory: (_, __) {
              final socket = _FakeSocket(null);
              sockets.add(socket);
              return socket;
            },
            network: config.network,
            cursorStorage: storage,
            cursorStorageScope: scope,
          );
          sessions.add(session);
          return session;
        }

        await tester.pumpWidget(
          _host(
            StatefulBuilder(
              builder: (context, setState) {
                rebuild = setState;
                return ChatScope(
                  config: _clientConfig(http),
                  connectivityDelegate: connectivity,
                  deviceIdentityDelegate: identity,
                  identityScopeKey: scopeKey,
                  realtimeSessionFactory: factory,
                  child: const SizedBox.shrink(),
                );
              },
            ),
          ),
        );
        await _flushAsync(tester);
        expect(sockets, hasLength(1));
        expect(
          jsonDecode(sockets.first.sent.single),
          containsPair(
            'resumeFrom',
            <String, Object?>{'eventId': 'cursor-a'},
          ),
        );

        sockets.first._frames.add(jsonEncode(_acceptedFrame(
          sessionId: 'session-a',
          resumeFrom: 'cursor-a-late',
        )));
        await storage.delayedWriteStarted.future;

        rebuild(() => scopeKey = 'login-b');
        await tester.pump();
        await _flushAsync(tester);
        expect(sockets, hasLength(2));
        expect(
          jsonDecode(sockets.last.sent.single),
          isNot(contains('resumeFrom')),
        );

        sockets.last._frames.add(jsonEncode(_acceptedFrame(
          sessionId: 'session-b',
          resumeFrom: 'cursor-b-active',
        )));
        await _flushAsync(tester);
        expect(
          storage.values['login-b'],
          jsonEncode(<String, Object?>{'eventId': 'cursor-b-active'}),
        );

        storage.releaseDelayedWrite.complete();
        await _flushAsync(tester);
        expect(storage.values['login-a'], isNull);
        expect(
          storage.values['login-b'],
          jsonEncode(<String, Object?>{'eventId': 'cursor-b-active'}),
        );
        expect(storage.clearedScopes, <String>['login-a']);
        expect(sessions.first.isDisposed, isTrue);

        await tester.pumpWidget(_host(const SizedBox.shrink()));
        await _flushAsync(tester);
      },
    );

    testWidgets('teardown cancels and disposes owned resources once', (
      tester,
    ) async {
      final connectivity = _FakeConnectivity(ChatConnectivityStatus.online);
      final sockets = <_FakeSocket>[];
      late HandrailChatClient client;
      late ChatRealtimeSessionTransport session;

      await tester.pumpWidget(
        _host(
          ChatScope(
            config: _clientConfig(_ImmediateTransport()),
            connectivityDelegate: connectivity,
            deviceIdentityDelegate: _FakeIdentity((_) async => 'device-a'),
            identityScopeKey: 'login-a',
            realtimeSessionFactory: (config) {
              session = _session(config, sockets);
              return session;
            },
            child: Builder(
              builder: (context) {
                client = ChatScope.of(context).client;
                return const SizedBox.shrink();
              },
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(connectivity.listenCount, 1);
      expect(sockets, hasLength(1));

      await tester.pumpWidget(_host(const SizedBox.shrink()));
      await _flushAsync(tester);

      expect(connectivity.cancelCount, 1);
      expect(session.isStarted, isFalse);
      expect(sockets.single.closeCalls, 1);
      expect(() => client.initialize(), throwsStateError);

      await tester.pumpWidget(_host(const SizedBox.shrink()));
      await tester.pump();
      expect(connectivity.cancelCount, 1);
      expect(sockets.single.closeCalls, 1);
    });
  });
}

Widget _host(Widget child) => Directionality(
      textDirection: TextDirection.ltr,
      child: child,
    );

Future<void> _flushAsync(WidgetTester tester) async {
  await tester.runAsync(() async {
    for (var index = 0; index < 10; index += 1) {
      await Future<void>.delayed(Duration.zero);
    }
  });
  await tester.pump();
}

ChatScopeClientConfig _clientConfig(HandrailChatHttpTransport transport) =>
    ChatScopeClientConfig(
      apiBaseUri: Uri.parse('https://chat.example.test/api/chat'),
      tokenProvider: () async => 'client-token',
      transport: transport,
    );

ChatRealtimeSessionTransport _session(
  ChatScopeRealtimeSessionConfig config,
  List<_FakeSocket> sockets, {
  List<String>? events,
}) =>
    ChatRealtimeSessionTransport(
      endpoint: config.client.apiBaseUri,
      clientPackageVersion: '0.1.3',
      protocolVersion: handrailChatProtocolVersion,
      tokenProvider: () async => 'realtime-token',
      socketFactory: (uri, protocols) {
        events?.add('socket:open');
        final socket = _FakeSocket(events);
        sockets.add(socket);
        return socket;
      },
      network: config.network,
    );

final class _FakeConnectivity implements ChatConnectivityDelegate {
  _FakeConnectivity(
    this.current, {
    this.currentError,
  }) {
    _controller = StreamController<ChatConnectivityStatus>.broadcast(
      sync: true,
      onListen: () => listenCount += 1,
      onCancel: () => cancelCount += 1,
    );
  }

  final ChatConnectivityStatus current;
  final Object? currentError;
  late final StreamController<ChatConnectivityStatus> _controller;
  int listenCount = 0;
  int cancelCount = 0;

  @override
  Stream<ChatConnectivityStatus> get connectivityChanges => _controller.stream;

  @override
  FutureOr<ChatConnectivityStatus> getCurrentConnectivity() {
    final error = currentError;
    if (error != null) throw error;
    return current;
  }

  void emit(ChatConnectivityStatus status) => _controller.add(status);

  void emitError(Object error) => _controller.addError(error);
}

final class _FakeIdentity implements ChatDeviceIdentityDelegate {
  _FakeIdentity(this.resolve);

  final FutureOr<String> Function(Object? scope) resolve;

  @override
  FutureOr<String> getOrCreateDeviceId({required Object? identityScopeKey}) =>
      resolve(identityScopeKey);
}

final class _FakeSocket implements ChatRealtimeSocket {
  _FakeSocket(this.events);

  final List<String>? events;
  final StreamController<Object?> _frames =
      StreamController<Object?>.broadcast(sync: true);
  final List<String> sent = <String>[];
  int closeCalls = 0;

  @override
  Stream<Object?> get frames => _frames.stream;

  @override
  void send(String data) {
    events?.add('socket:handshake');
    sent.add(data);
  }

  @override
  void close() {
    closeCalls += 1;
  }
}

final class _ScopedCursorStorage implements ChatRealtimeCursorStorage {
  final Map<String, String> values = <String, String>{};
  final List<String> clearedScopes = <String>[];
  final Completer<void> delayedWriteStarted = Completer<void>();
  final Completer<void> releaseDelayedWrite = Completer<void>();

  @override
  String? read({required String scope}) => values[scope];

  @override
  Future<void> write({
    required String scope,
    required String value,
  }) async {
    if (scope == 'login-a') {
      if (!delayedWriteStarted.isCompleted) delayedWriteStarted.complete();
      await releaseDelayedWrite.future;
    }
    values[scope] = value;
  }

  @override
  void clear({required String scope}) {
    clearedScopes.add(scope);
    values.remove(scope);
  }
}

Map<String, Object?> _acceptedFrame({
  required String sessionId,
  String? resumeFrom,
}) =>
    <String, Object?>{
      'type': 'chat.session.accepted',
      'metadata': <String, Object?>{
        'packageVersion': '0.1.3',
        'protocolVersion': handrailChatProtocolVersion,
        'schemaVersion': 7,
        'enabledFeatures': <String, Object?>{},
        'supportedProtocolRange': <String, Object?>{
          'minimumVersion': handrailChatProtocolVersion - 1,
          'maximumVersion': handrailChatProtocolVersion,
        },
      },
      'tenantId': 'tenant-1',
      'actorStreamId': 'user:user-1',
      'deviceId': 'device-1',
      'sessionId': sessionId,
      if (resumeFrom != null)
        'resumeFrom': <String, Object?>{
          'eventId': resumeFrom,
        },
    };

final class _ImmediateTransport implements HandrailChatHttpTransport {
  final List<HandrailChatHttpRequest> requests = <HandrailChatHttpRequest>[];

  @override
  Future<HandrailChatHttpResponse> send(HandrailChatHttpRequest request) async {
    requests.add(request);
    return HandrailChatHttpResponse(
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
  }
}
