import 'dart:async';
import 'dart:collection';
import 'dart:convert';

import '../../core.dart';

/// A controllable text-frame socket with recorded outbound sends.
final class FakeChatRealtimeSocket implements ChatRealtimeSocket {
  final StreamController<Object?> _frames =
      StreamController<Object?>.broadcast(sync: true);
  final Queue<_SocketFailure> _sendFailures = Queue<_SocketFailure>();
  final List<String> _sent = <String>[];
  var _closeCount = 0;
  var _closed = false;

  @override
  Stream<Object?> get frames => _frames.stream;

  List<String> get sent => List<String>.unmodifiable(_sent);
  int get closeCount => _closeCount;
  bool get isClosed => _closed;

  @override
  Future<void> send(String data) async {
    if (_closed) throw StateError('The fake realtime socket is closed.');
    _sent.add(data);
    if (_sendFailures.isNotEmpty) _sendFailures.removeFirst().throwError();
  }

  void queueSendError(Object error, [StackTrace? stackTrace]) {
    _sendFailures.add(
      _SocketFailure(error, stackTrace ?? StackTrace.current),
    );
  }

  void emitFrame(Object? frame) {
    _ensureOpen();
    _frames.add(frame);
  }

  void emitJson(Object? value) => emitFrame(jsonEncode(value));

  void emitError(Object error, [StackTrace? stackTrace]) {
    _ensureOpen();
    _frames.addError(error, stackTrace ?? StackTrace.current);
  }

  /// Simulates the remote endpoint completing the frame stream.
  Future<void> finish() async {
    if (_closed) return;
    _closed = true;
    await _frames.close();
  }

  @override
  Future<void> close() async {
    if (_closed) return;
    _closeCount += 1;
    _closed = true;
    await _frames.close();
  }

  void resetSends() {
    _sent.clear();
    _sendFailures.clear();
  }

  void _ensureOpen() {
    if (_closed) throw StateError('The fake realtime socket is closed.');
  }

  @override
  String toString() => 'FakeChatRealtimeSocket('
      'sentCount: ${_sent.length}, closeCount: $_closeCount, closed: $_closed)';
}

/// A FIFO socket factory that records connection arguments.
final class FakeChatRealtimeSocketFactory {
  final Queue<Object> _scripts = Queue<Object>();
  final List<Uri> _uris = <Uri>[];
  final List<List<String>> _protocols = <List<String>>[];

  List<Uri> get uris => List<Uri>.unmodifiable(_uris);
  List<List<String>> get protocols => List<List<String>>.unmodifiable(
        _protocols.map(List<String>.unmodifiable),
      );
  int get remainingScriptCount => _scripts.length;

  void enqueueSocket(FakeChatRealtimeSocket socket) => _scripts.add(socket);

  void enqueueError(Object error, [StackTrace? stackTrace]) => _scripts.add(
        _SocketFailure(error, stackTrace ?? StackTrace.current),
      );

  Future<ChatRealtimeSocket> call(Uri uri, List<String> protocols) async {
    _uris.add(uri);
    _protocols.add(List<String>.unmodifiable(protocols));
    if (_scripts.isEmpty) {
      throw StateError('No scripted realtime socket remains.');
    }
    final script = _scripts.removeFirst();
    if (script case final _SocketFailure failure) failure.throwError();
    return script as FakeChatRealtimeSocket;
  }

  void reset() {
    _scripts.clear();
    _uris.clear();
    _protocols.clear();
  }

  @override
  String toString() => 'FakeChatRealtimeSocketFactory('
      'connectionCount: ${_uris.length}, '
      'remainingScriptCount: ${_scripts.length})';
}

/// A synchronous, controllable online/offline boundary.
final class FakeChatRealtimeNetwork implements ChatRealtimeNetwork {
  FakeChatRealtimeNetwork({bool isOnline = true}) : _isOnline = isOnline;

  final StreamController<bool> _changes =
      StreamController<bool>.broadcast(sync: true);
  bool _isOnline;
  var _disposed = false;

  @override
  bool get isOnline => _isOnline;

  @override
  Stream<bool> get changes => _changes.stream;

  void setOnline(bool value) {
    if (_disposed) throw StateError('The fake realtime network is disposed.');
    if (value == _isOnline) return;
    _isOnline = value;
    _changes.add(value);
  }

  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    await _changes.close();
  }
}

final class _SocketFailure {
  const _SocketFailure(this.error, this.stackTrace);

  final Object error;
  final StackTrace stackTrace;

  Never throwError() => Error.throwWithStackTrace(error, stackTrace);
}
