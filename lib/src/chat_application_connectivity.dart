import 'dart:async';

import '../core.dart';

/// Host-observed reachability without prescribing a connectivity plugin.
enum ChatConnectivityStatus {
  /// Reachability has not been established. Realtime treats this as offline.
  unknown,

  offline,
  online,
}

/// Supplies current and changing reachability from the host application.
abstract interface class ChatConnectivityDelegate {
  FutureOr<ChatConnectivityStatus> getCurrentConnectivity();

  Stream<ChatConnectivityStatus> get connectivityChanges;
}

/// Supplies a stable device identifier within a host-defined identity scope.
abstract interface class ChatDeviceIdentityDelegate {
  FutureOr<String> getOrCreateDeviceId({required Object? identityScopeKey});
}

/// Stable codes for sanitized Flutter application-integration diagnostics.
abstract final class ChatScopeIntegrationDiagnosticCode {
  static const String connectivityQueryFailed = 'connectivity_query_failed';
  static const String connectivityStreamFailed = 'connectivity_stream_failed';
  static const String deviceIdentityFailed = 'device_identity_failed';
  static const String invalidDeviceIdentity = 'invalid_device_identity';
  static const String realtimeSessionFailed = 'realtime_session_failed';
  static const String pushTokenInitialFailed = 'push_token_initial_failed';
  static const String pushTokenStreamFailed = 'push_token_stream_failed';
  static const String pushTokenRegistrationFailed =
      'push_token_registration_failed';
  static const String pushTokenLogoutFailed = 'push_token_logout_failed';
}

/// Credential-safe application-integration diagnostic.
final class ChatScopeIntegrationDiagnostic {
  const ChatScopeIntegrationDiagnostic({
    required this.code,
    required this.message,
  });

  final String code;
  final String message;

  @override
  String toString() =>
      'ChatScopeIntegrationDiagnostic(code: $code, message: $message)';
}

typedef ChatScopeIntegrationDiagnosticListener = void Function(
  ChatScopeIntegrationDiagnostic diagnostic,
);

/// Values supplied after ChatScope has resolved its host-owned device ID.
final class ChatScopeRealtimeSessionConfig {
  const ChatScopeRealtimeSessionConfig({
    required this.client,
    required this.deviceId,
    required this.network,
    required this.identityScopeKey,
  });

  final HandrailChatClient client;
  final DeviceId deviceId;
  final ChatRealtimeNetwork network;

  /// Trusted host login identity available before realtime starts.
  ///
  /// Cursor-persisting factories should validate and use this value as their
  /// storage scope. It must remain stable for one login identity, include any
  /// account/device boundary needed by the host, and never contain tokens,
  /// credentials, or other secrets.
  final Object? identityScopeKey;
}

/// Creates the realtime runtime owned by a delegate-enabled ChatScope.
typedef ChatScopeRealtimeSessionFactory = ChatRealtimeSessionTransport Function(
  ChatScopeRealtimeSessionConfig config,
);

/// Adapts tri-state Flutter reachability to the pure-Dart realtime boundary.
///
/// Unknown reachability is deliberately offline. Equivalent delegate events
/// are suppressed, and [dispose] releases the delegate stream exactly once.
final class ChatRealtimeNetworkAdapter implements ChatRealtimeNetwork {
  ChatRealtimeNetworkAdapter({
    required ChatConnectivityDelegate delegate,
    void Function(ChatConnectivityStatus status)? onStatusChanged,
    ChatScopeIntegrationDiagnosticListener? onDiagnostic,
  })  : _delegate = delegate,
        _onStatusChanged = onStatusChanged,
        _onDiagnostic = onDiagnostic;

  final ChatConnectivityDelegate _delegate;
  final void Function(ChatConnectivityStatus status)? _onStatusChanged;
  final ChatScopeIntegrationDiagnosticListener? _onDiagnostic;
  final StreamController<bool> _changes =
      StreamController<bool>.broadcast(sync: true);

  StreamSubscription<ChatConnectivityStatus>? _subscription;
  ChatConnectivityStatus _status = ChatConnectivityStatus.unknown;
  var _eventSequence = 0;
  var _initialized = false;
  var _disposed = false;

  ChatConnectivityStatus get status => _status;

  @override
  bool get isOnline => _status == ChatConnectivityStatus.online;

  @override
  Stream<bool> get changes => _changes.stream;

  /// Attaches observation before querying the current value to avoid a gap.
  Future<void> initialize() async {
    if (_initialized || _disposed) return;
    _initialized = true;

    try {
      _subscription = _delegate.connectivityChanges.listen(
        _handleStatus,
        onError: (Object _, StackTrace __) => _report(
          const ChatScopeIntegrationDiagnostic(
            code: ChatScopeIntegrationDiagnosticCode.connectivityStreamFailed,
            message: 'Chat connectivity changes could not be observed.',
          ),
        ),
      );
    } catch (_) {
      _report(
        const ChatScopeIntegrationDiagnostic(
          code: ChatScopeIntegrationDiagnosticCode.connectivityStreamFailed,
          message: 'Chat connectivity changes could not be observed.',
        ),
      );
    }

    final sequenceBeforeQuery = _eventSequence;
    late final ChatConnectivityStatus current;
    try {
      current = await _delegate.getCurrentConnectivity();
    } catch (_) {
      _report(
        const ChatScopeIntegrationDiagnostic(
          code: ChatScopeIntegrationDiagnosticCode.connectivityQueryFailed,
          message: 'Current chat connectivity could not be determined.',
        ),
      );
      return;
    }
    if (_disposed || sequenceBeforeQuery != _eventSequence) return;
    _setStatus(current);
  }

  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    final subscription = _subscription;
    _subscription = null;
    try {
      await subscription?.cancel();
    } catch (_) {
      // Cancellation failure cannot retain adapter authority.
    }
    await _changes.close();
  }

  void _handleStatus(ChatConnectivityStatus status) {
    if (_disposed) return;
    _eventSequence += 1;
    _setStatus(status);
  }

  void _setStatus(ChatConnectivityStatus status) {
    if (_disposed || status == _status) return;
    final wasOnline = isOnline;
    _status = status;
    try {
      _onStatusChanged?.call(status);
    } catch (_) {
      // Host observers cannot alter connectivity behavior.
    }
    if (wasOnline != isOnline && !_changes.isClosed) {
      _changes.add(isOnline);
    }
  }

  void _report(ChatScopeIntegrationDiagnostic diagnostic) {
    try {
      _onDiagnostic?.call(diagnostic);
    } catch (_) {
      // Diagnostic observers cannot alter connectivity behavior.
    }
  }
}
