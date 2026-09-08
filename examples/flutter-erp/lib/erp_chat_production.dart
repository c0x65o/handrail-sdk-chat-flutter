import 'dart:async';
import 'dart:io';

import 'package:handrail_chat/flutter.dart';

/// Adapts the host's connectivity plugin without making one plugin part of the
/// Handrail SDK contract.
final class ErpChatConnectivityDelegate implements ChatConnectivityDelegate {
  const ErpChatConnectivityDelegate({
    required this.current,
    required this.changes,
  });

  final FutureOr<ChatConnectivityStatus> Function() current;
  final Stream<ChatConnectivityStatus> changes;

  @override
  Stream<ChatConnectivityStatus> get connectivityChanges => changes;

  @override
  FutureOr<ChatConnectivityStatus> getCurrentConnectivity() => current();
}

/// Adapts the ERP's durable/secure preference store. The host must return the
/// same non-empty identifier for one signed-in account across app restarts.
final class ErpChatDeviceIdentityDelegate
    implements ChatDeviceIdentityDelegate {
  const ErpChatDeviceIdentityDelegate(this.loadOrCreate);

  final FutureOr<String> Function(Object? identityScopeKey) loadOrCreate;

  @override
  FutureOr<String> getOrCreateDeviceId({required Object? identityScopeKey}) =>
      loadOrCreate(identityScopeKey);
}

/// Production `dart:io` socket adapter. Authentication stays in the protocol
/// handshake; tokens are never placed in the URL.
final class ErpChatRealtimeSocket implements ChatRealtimeSocket {
  ErpChatRealtimeSocket._(this._socket);

  final WebSocket _socket;

  static Future<ErpChatRealtimeSocket> connect(
    Uri uri,
    List<String> protocols,
  ) async => ErpChatRealtimeSocket._(
    await WebSocket.connect(uri.toString(), protocols: protocols),
  );

  @override
  Stream<Object?> get frames => _socket;

  @override
  void send(String data) => _socket.add(data);

  @override
  Future<void> close() => _socket.close();
}

/// Builds the concrete realtime session supplied to [ErpChatBootstrap].
/// Cursor persistence is optional but recommended for production replay.
/// When enabled, [ChatScopeRealtimeSessionConfig.identityScopeKey] must be a
/// bounded nonblank string that is stable for the signed-in host identity. It
/// must never contain a token, credential, or another secret.
ChatScopeRealtimeSessionFactory createErpChatRealtimeSessionFactory({
  ChatRealtimeCursorStorage? cursorStorage,
  ChatRealtimeSocketFactory socketFactory = ErpChatRealtimeSocket.connect,
  ChatRealtimeDiagnosticListener? onDiagnostic,
}) => (config) {
  final cursorStorageScope = cursorStorage == null
      ? null
      : _cursorStorageScope(config.identityScopeKey);
  final session = ChatRealtimeSessionTransport(
    endpoint: config.client.apiBaseUri,
    clientPackageVersion: handrailChatPackageVersion,
    protocolVersion: handrailChatProtocolVersion,
    tokenProvider: config.client.tokenProvider,
    socketFactory: socketFactory,
    network: config.network,
    cursorStorage: cursorStorage,
    cursorStorageScope: cursorStorageScope,
    onDiagnostic: onDiagnostic,
  );
  session.bindDurableState(
    reduceDurableEvent: config.client.reduceDurableEvent,
    hydrateSnapshot: config.client.hydrateRealtimeSnapshots,
  );
  return session;
};

String _cursorStorageScope(Object? identityScopeKey) {
  if (identityScopeKey is! String) {
    throw ArgumentError(
      'identityScopeKey must be a string when persistent realtime cursors '
      'are configured.',
    );
  }
  return identityScopeKey;
}
