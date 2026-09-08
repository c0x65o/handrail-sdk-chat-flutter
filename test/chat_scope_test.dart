import 'dart:async';
import 'dart:convert';

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:handrail_chat/flutter.dart';

void main() {
  group('ChatScope construction and lookup', () {
    test('requires exactly one client source', () {
      final client = _client(_ImmediateTransport(_readyResponse));
      final config = _config(_ImmediateTransport(_readyResponse));

      expect(
        () => ChatScope(child: const SizedBox.shrink()),
        throwsA(
          isA<ArgumentError>().having(
            (error) => error.message,
            'message',
            contains('requires either client or config'),
          ),
        ),
      );
      expect(
        () => ChatScope(
          client: client,
          config: config,
          child: const SizedBox.shrink(),
        ),
        throwsA(
          isA<ArgumentError>().having(
            (error) => error.message,
            'message',
            contains('either client or config, not both'),
          ),
        ),
      );
    });

    testWidgets('supports missing and nearest nested lookup', (tester) async {
      ChatScopeBinding? missing;
      Object? requiredLookupError;
      await tester.pumpWidget(
        _host(
          Builder(
            builder: (context) {
              missing = ChatScope.maybeOf(context);
              try {
                ChatScope.of(context);
              } catch (error) {
                requiredLookupError = error;
              }
              return const SizedBox.shrink();
            },
          ),
        ),
      );

      expect(missing, isNull);
      expect(requiredLookupError, isA<FlutterError>());

      final outer = _client(_ImmediateTransport(_readyResponse));
      final inner = _client(_ImmediateTransport(_readyResponse));
      late HandrailChatClient outerFound;
      late HandrailChatClient innerFound;

      await tester.pumpWidget(
        _host(
          ChatScope(
            client: outer,
            child: Column(
              children: <Widget>[
                Builder(
                  builder: (context) {
                    outerFound = ChatScope.of(context).client;
                    return const SizedBox.shrink();
                  },
                ),
                ChatScope(
                  client: inner,
                  child: Builder(
                    builder: (context) {
                      innerFound = ChatScope.of(context).client;
                      return const SizedBox.shrink();
                    },
                  ),
                ),
              ],
            ),
          ),
        ),
      );

      expect(outerFound, same(outer));
      expect(innerFound, same(inner));
      await outer.dispose();
      await inner.dispose();
    });
  });

  group('external client ownership', () {
    testWidgets('observes emissions without initializing or disposing', (
      tester,
    ) async {
      final token = Completer<String>();
      final transport = _ImmediateTransport(_readyResponse);
      final client = HandrailChatClient(
        apiBaseUri: Uri.parse('https://chat.example.test/api/chat'),
        tokenProvider: () => token.future,
        transport: transport,
      );
      final observed = <String>[];
      var builds = 0;

      await tester.pumpWidget(
        _host(
          ChatScope(
            client: client,
            child: Builder(
              builder: (context) {
                builds += 1;
                final binding = ChatScope.of(context);
                observed.add(binding.state.state);
                return Text(binding.state.state);
              },
            ),
          ),
        ),
      );

      expect(transport.requests, isEmpty);
      expect(observed, <String>['idle']);
      expect(ChatScopeReadiness.notReady.name, 'notReady');

      await tester.pump();
      final initialization = client.initialize();
      token.complete('external-token');
      await initialization;
      await tester.pump();
      expect(find.text('ready'), findsOneWidget);
      expect(observed.first, 'idle');
      expect(observed.last, 'ready');
      expect(builds, greaterThan(1));

      await tester.pumpWidget(_host(const SizedBox.shrink()));
      expect(() => client.initialize(), returnsNormally);
      expect(transport.requests, hasLength(1));
      await client.dispose();
    });
  });

  group('owned client lifecycle', () {
    testWidgets('creates once and projects idle, initializing, and ready', (
      tester,
    ) async {
      final token = Completer<String>();
      final transport = _ImmediateTransport(_readyResponse);
      final states = <String>[];
      final readiness = <ChatScopeReadiness>[];
      final clients = <HandrailChatClient>[];

      await tester.pumpWidget(
        _host(
          ChatScope(
            config: _config(transport, tokenProvider: () => token.future),
            child: Builder(
              builder: (context) {
                final binding = ChatScope.of(context);
                clients.add(binding.client);
                states.add(binding.state.state);
                readiness.add(binding.readiness);
                return Text('${binding.state.state}:${binding.isReady}');
              },
            ),
          ),
        ),
      );

      expect(states, <String>['idle']);
      await tester.pump();
      expect(find.text('initializing:false'), findsOneWidget);

      token.complete('owned-token');
      await tester.pumpAndSettle();
      expect(find.text('ready:true'), findsOneWidget);
      expect(states, <String>['idle', 'initializing', 'ready']);
      expect(
        readiness,
        <ChatScopeReadiness>[
          ChatScopeReadiness.notReady,
          ChatScopeReadiness.notReady,
          ChatScopeReadiness.ready,
        ],
      );
      expect(clients.toSet(), hasLength(1));
      expect(transport.requests, hasLength(1));
    });

    testWidgets('projects refresh-required and sanitized error states', (
      tester,
    ) async {
      late ChatScopeBinding binding;
      final refreshTransport = _ImmediateTransport(
        HandrailChatHttpResponse(
          statusCode: 200,
          body: jsonEncode(
            _metadata(
              protocolVersion: 6,
              minimumProtocolVersion: 5,
              maximumProtocolVersion: 6,
            ),
          ),
        ),
      );

      await tester.pumpWidget(
        _host(
          ChatScope(
            config: _config(refreshTransport),
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

      expect(binding.readiness, ChatScopeReadiness.refreshRequired);
      expect(binding.refreshRequired, isA<ChatClientRefreshRequiredState>());
      expect(binding.error, isNull);
      expect(binding.isReady, isFalse);

      await tester.pumpWidget(_host(const SizedBox.shrink()));
      await tester.pump();

      const secret = 'private-provider-exception';
      await tester.pumpWidget(
        _host(
          ChatScope(
            config: _config(
              _ImmediateTransport(_readyResponse),
              tokenProvider: () => Future<String>.error(
                StateError(secret),
              ),
            ),
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

      expect(binding.readiness, ChatScopeReadiness.error);
      expect(binding.state, isA<ChatClientErrorState>());
      expect(binding.refreshRequired, isNull);
      expect(binding.error, isA<ChatClientDiagnostic>());
      expect(binding.error!.code, ChatClientDiagnosticCode.accessTokenFailed);
      expect(binding.error.toString(), isNot(contains(secret)));
    });

    testWidgets('keeps its binding stable across parent rebuilds', (
      tester,
    ) async {
      final transport = _ImmediateTransport(_readyResponse);
      final clients = <HandrailChatClient>[];
      late StateSetter rebuildParent;

      await tester.pumpWidget(
        _host(
          StatefulBuilder(
            builder: (context, setState) {
              rebuildParent = setState;
              return ChatScope(
                config: _config(transport),
                child: Builder(
                  builder: (context) {
                    clients.add(ChatScope.of(context).client);
                    return const SizedBox.shrink();
                  },
                ),
              );
            },
          ),
        ),
      );
      await tester.pumpAndSettle();
      final original = clients.last;

      rebuildParent(() {});
      await tester.pump();

      expect(clients.last, same(original));
      expect(transport.requests, hasLength(1));
    });

    testWidgets('disposes once and ignores late startup completion safely', (
      tester,
    ) async {
      final response = Completer<HandrailChatHttpResponse>();
      final transport = _CompletingTransport(response);
      late HandrailChatClient ownedClient;

      await tester.pumpWidget(
        _host(
          ChatScope(
            config: _config(transport),
            child: Builder(
              builder: (context) {
                ownedClient = ChatScope.of(context).client;
                return const SizedBox.shrink();
              },
            ),
          ),
        ),
      );
      await tester.pump();
      expect(ownedClient.state, isA<ChatClientInitializingState>());

      await tester.pumpWidget(_host(const SizedBox.shrink()));
      expect(() => ownedClient.initialize(), throwsStateError);

      response.complete(_readyResponse);
      await tester.pump();
      await tester.pump();
      expect(tester.takeException(), isNull);
      expect(() => ownedClient.initialize(), throwsStateError);
    });
  });
}

Widget _host(Widget child) => Directionality(
      textDirection: TextDirection.ltr,
      child: child,
    );

ChatScopeClientConfig _config(
  HandrailChatHttpTransport transport, {
  HandrailChatAccessTokenProvider? tokenProvider,
}) =>
    ChatScopeClientConfig(
      apiBaseUri: Uri.parse('https://chat.example.test/api/chat'),
      tokenProvider: tokenProvider ?? () async => 'scope-token',
      transport: transport,
    );

HandrailChatClient _client(HandrailChatHttpTransport transport) =>
    HandrailChatClient(
      apiBaseUri: Uri.parse('https://chat.example.test/api/chat'),
      tokenProvider: () async => 'external-token',
      transport: transport,
    );

Map<String, Object?> _metadata({
  int protocolVersion = handrailChatProtocolVersion,
  int minimumProtocolVersion = 3,
  int maximumProtocolVersion = handrailChatProtocolVersion,
}) =>
    <String, Object?>{
      'packageVersion': '0.1.3',
      'protocolVersion': protocolVersion,
      'schemaVersion': 7,
      'enabledFeatures': <String, bool>{'realtime': true},
      'supportedProtocolRange': <String, int>{
        'minimumVersion': minimumProtocolVersion,
        'maximumVersion': maximumProtocolVersion,
      },
    };

final HandrailChatHttpResponse _readyResponse = HandrailChatHttpResponse(
  statusCode: 200,
  body: jsonEncode(_metadata()),
);

final class _ImmediateTransport implements HandrailChatHttpTransport {
  _ImmediateTransport(this.response);

  final HandrailChatHttpResponse response;
  final List<HandrailChatHttpRequest> requests = <HandrailChatHttpRequest>[];

  @override
  Future<HandrailChatHttpResponse> send(HandrailChatHttpRequest request) async {
    requests.add(request);
    return response;
  }
}

final class _CompletingTransport implements HandrailChatHttpTransport {
  _CompletingTransport(this.response);

  final Completer<HandrailChatHttpResponse> response;

  @override
  Future<HandrailChatHttpResponse> send(HandrailChatHttpRequest request) =>
      response.future;
}
