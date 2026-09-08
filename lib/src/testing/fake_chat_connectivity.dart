import 'dart:async';
import 'dart:collection';

import '../chat_application_connectivity.dart';

/// Controllable host connectivity for [ChatRealtimeNetworkAdapter] tests.
final class FakeChatConnectivityDelegate implements ChatConnectivityDelegate {
  FakeChatConnectivityDelegate({
    ChatConnectivityStatus current = ChatConnectivityStatus.unknown,
  }) : _current = current;

  final StreamController<ChatConnectivityStatus> _changes =
      StreamController<ChatConnectivityStatus>.broadcast(sync: true);
  final Queue<_ConnectivityFailure> _queryFailures =
      Queue<_ConnectivityFailure>();
  ChatConnectivityStatus _current;
  var _queryCount = 0;
  var _disposed = false;

  ChatConnectivityStatus get current => _current;
  int get queryCount => _queryCount;

  @override
  Stream<ChatConnectivityStatus> get connectivityChanges => _changes.stream;

  @override
  Future<ChatConnectivityStatus> getCurrentConnectivity() async {
    _ensureActive();
    _queryCount += 1;
    if (_queryFailures.isNotEmpty) _queryFailures.removeFirst().throwError();
    return _current;
  }

  void queueQueryError(Object error, [StackTrace? stackTrace]) {
    _ensureActive();
    _queryFailures.add(
      _ConnectivityFailure(error, stackTrace ?? StackTrace.current),
    );
  }

  void emit(ChatConnectivityStatus status) {
    _ensureActive();
    _current = status;
    _changes.add(status);
  }

  void emitError(Object error, [StackTrace? stackTrace]) {
    _ensureActive();
    _changes.addError(error, stackTrace ?? StackTrace.current);
  }

  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    await _changes.close();
  }

  void _ensureActive() {
    if (_disposed) throw StateError('The fake connectivity is disposed.');
  }
}

/// A FIFO device-identity delegate with recorded identity scopes.
final class FakeChatDeviceIdentityDelegate
    implements ChatDeviceIdentityDelegate {
  FakeChatDeviceIdentityDelegate({String? fallbackDeviceId})
      : _fallbackDeviceId = fallbackDeviceId;

  final Queue<Object> _scripts = Queue<Object>();
  final List<Object?> _identityScopeKeys = <Object?>[];
  String? _fallbackDeviceId;

  List<Object?> get identityScopeKeys =>
      List<Object?>.unmodifiable(_identityScopeKeys);

  set fallbackDeviceId(String? value) => _fallbackDeviceId = value;

  void enqueueDeviceId(String deviceId) => _scripts.add(deviceId);

  void enqueueError(Object error, [StackTrace? stackTrace]) => _scripts.add(
        _ConnectivityFailure(error, stackTrace ?? StackTrace.current),
      );

  @override
  Future<String> getOrCreateDeviceId(
      {required Object? identityScopeKey}) async {
    _identityScopeKeys.add(identityScopeKey);
    if (_scripts.isNotEmpty) {
      final script = _scripts.removeFirst();
      if (script case final _ConnectivityFailure failure) failure.throwError();
      return script as String;
    }
    final fallback = _fallbackDeviceId;
    if (fallback != null) return fallback;
    throw StateError('No scripted device identity remains.');
  }

  void reset({String? fallbackDeviceId}) {
    _scripts.clear();
    _identityScopeKeys.clear();
    _fallbackDeviceId = fallbackDeviceId;
  }

  @override
  String toString() => 'FakeChatDeviceIdentityDelegate('
      'requestCount: ${_identityScopeKeys.length}, '
      'remainingScriptCount: ${_scripts.length}, '
      'hasFallback: ${_fallbackDeviceId != null})';
}

final class _ConnectivityFailure {
  const _ConnectivityFailure(this.error, this.stackTrace);

  final Object error;
  final StackTrace stackTrace;

  Never throwError() => Error.throwWithStackTrace(error, stackTrace);
}
