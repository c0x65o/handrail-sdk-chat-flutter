import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:handrail_chat/flutter.dart';

/// Compile-time API setting owned by the host application.
///
/// The deliberately unroutable default prevents an unconfigured example from
/// contacting a production service. Override it with:
/// `--dart-define=HANDRAIL_CHAT_API_BASE=https://chat.dev.example.test/api/chat`.
const String erpChatApiBaseSetting = String.fromEnvironment(
  'HANDRAIL_CHAT_API_BASE',
  defaultValue: 'https://chat.example.invalid/api/chat',
);

Uri get erpChatApiBaseUri {
  final uri = Uri.parse(erpChatApiBaseSetting);
  if (!uri.hasScheme || !uri.hasAuthority) {
    throw StateError('HANDRAIL_CHAT_API_BASE must be an absolute URI.');
  }
  if (uri.scheme != 'https' && uri.host != 'localhost') {
    throw StateError(
      'HANDRAIL_CHAT_API_BASE must use HTTPS except for localhost.',
    );
  }
  return uri;
}

/// Host-owned bridge to the authenticated ERP session.
///
/// Implementations fetch a short-lived token at call time. Tokens must not be
/// stored in this example, compile-time defines, or application source.
abstract interface class ErpSessionTokenProvider {
  Future<String> getHandrailChatAccessToken();
}

/// Safe placeholder used until an ERP host supplies its session bridge.
final class UnconfiguredErpSessionTokenProvider
    implements ErpSessionTokenProvider {
  const UnconfiguredErpSessionTokenProvider();

  @override
  Future<String> getHandrailChatAccessToken() => Future<String>.error(
    StateError('The ERP session token provider is not configured.'),
  );
}

/// Minimal `dart:io` HTTP adapter owned by this mobile host example.
final class ErpChatHttpTransport implements HandrailChatHttpTransport {
  ErpChatHttpTransport({HttpClient? client}) : _client = client ?? HttpClient();

  final HttpClient _client;
  bool _closed = false;

  @override
  Future<HandrailChatHttpResponse> send(HandrailChatHttpRequest request) async {
    if (_closed) throw StateError('The ERP chat HTTP transport is closed.');

    final ioRequest = await _client.openUrl(request.method, request.uri);
    request.headers.forEach(ioRequest.headers.set);
    if (request.body case final body?) {
      ioRequest.add(utf8.encode(body));
    }
    final response = await ioRequest.close();
    return HandrailChatHttpResponse(
      statusCode: response.statusCode,
      body: await utf8.decoder.bind(response).join(),
    );
  }

  void close() {
    if (_closed) return;
    _closed = true;
    _client.close(force: true);
  }
}

/// Dependencies given to an injectable client factory in widget tests.
final class ErpChatClientDependencies {
  const ErpChatClientDependencies({
    required this.apiBaseUri,
    required this.tokenProvider,
    required this.transport,
  });

  final Uri apiBaseUri;
  final HandrailChatAccessTokenProvider tokenProvider;
  final HandrailChatHttpTransport transport;
}

typedef ErpChatClientFactory =
    HandrailChatClient Function(ErpChatClientDependencies dependencies);

/// Owns exactly one client for the lifetime of the mounted ERP application.
///
/// Ordinary parent rebuilds do not replace or reinitialize the client. A host
/// must intentionally supply a new key when changing authenticated sessions.
final class ErpChatBootstrap extends StatefulWidget {
  const ErpChatBootstrap({
    required this.sessionTokenProvider,
    required this.child,
    this.apiBaseUri,
    this.transport,
    this.clientFactory,
    this.connectivityDelegate,
    this.deviceIdentityDelegate,
    this.identityScopeKey,
    this.realtimeSessionFactory,
    super.key,
  });

  final ErpSessionTokenProvider sessionTokenProvider;
  final Widget child;
  final Uri? apiBaseUri;
  final HandrailChatHttpTransport? transport;
  final ErpChatClientFactory? clientFactory;
  final ChatConnectivityDelegate? connectivityDelegate;
  final ChatDeviceIdentityDelegate? deviceIdentityDelegate;
  final Object? identityScopeKey;
  final ChatScopeRealtimeSessionFactory? realtimeSessionFactory;

  @override
  State<ErpChatBootstrap> createState() => ErpChatBootstrapState();
}

final class ErpChatBootstrapState extends State<ErpChatBootstrap> {
  late final HandrailChatHttpTransport _transport;
  late final bool _ownsTransport;
  late final HandrailChatClient _client;

  @visibleForTesting
  HandrailChatClient get client => _client;

  @override
  void initState() {
    super.initState();
    _ownsTransport = widget.transport == null;
    _transport = widget.transport ?? ErpChatHttpTransport();
    final dependencies = ErpChatClientDependencies(
      apiBaseUri: widget.apiBaseUri ?? erpChatApiBaseUri,
      tokenProvider: widget.sessionTokenProvider.getHandrailChatAccessToken,
      transport: _transport,
    );
    _client =
        widget.clientFactory?.call(dependencies) ??
        HandrailChatClient(
          apiBaseUri: dependencies.apiBaseUri,
          tokenProvider: dependencies.tokenProvider,
          transport: dependencies.transport,
          requestedCapabilities: const <String, bool>{
            'realtime': true,
            'attachments': true,
          },
        );
    unawaited(_initializeClient());
  }

  Future<void> _initializeClient() async {
    try {
      await _client.initialize();
    } catch (_) {
      // HandrailChatClient publishes only its sanitized lifecycle diagnostic.
    }
  }

  @override
  Widget build(BuildContext context) => ChatScope(
    client: _client,
    connectivityDelegate: widget.connectivityDelegate,
    deviceIdentityDelegate: widget.deviceIdentityDelegate,
    identityScopeKey: widget.identityScopeKey,
    realtimeSessionFactory: widget.realtimeSessionFactory,
    child: widget.child,
  );

  @override
  void dispose() {
    unawaited(_disposeOwnedResources());
    super.dispose();
  }

  Future<void> _disposeOwnedResources() async {
    await _client.dispose();
    if (_ownsTransport) (_transport as ErpChatHttpTransport).close();
  }
}
