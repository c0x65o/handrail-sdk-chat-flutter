import 'dart:collection';
import 'dart:convert';

import '../../core.dart';

/// A deterministic HTTP edge with FIFO responses and failures.
final class ScriptedHandrailChatHttpTransport
    implements HandrailChatHttpTransport {
  final Queue<_HttpScript> _scripts = Queue<_HttpScript>();
  final List<HandrailChatHttpRequest> _requests = <HandrailChatHttpRequest>[];
  var _disposed = false;

  /// Requests observed in dispatch order.
  List<HandrailChatHttpRequest> get requests =>
      List<HandrailChatHttpRequest>.unmodifiable(_requests);

  int get remainingScriptCount => _scripts.length;
  bool get isDisposed => _disposed;

  void enqueueResponse(HandrailChatHttpResponse response) {
    _ensureActive();
    _scripts.add(_HttpResponseScript(response));
  }

  void enqueueJson(Object? body, {int statusCode = 200}) {
    enqueueResponse(
      HandrailChatHttpResponse(
        statusCode: statusCode,
        body: jsonEncode(body),
      ),
    );
  }

  void enqueueError(Object error, [StackTrace? stackTrace]) {
    _ensureActive();
    _scripts.add(_HttpErrorScript(error, stackTrace ?? StackTrace.current));
  }

  @override
  Future<HandrailChatHttpResponse> send(
    HandrailChatHttpRequest request,
  ) async {
    _ensureActive();
    _requests.add(request);
    if (_scripts.isEmpty) {
      throw StateError('No scripted HTTP result remains.');
    }
    return _scripts.removeFirst().resolve();
  }

  /// Clears recorded requests and unconsumed scripts.
  void reset() {
    _ensureActive();
    _requests.clear();
    _scripts.clear();
  }

  /// Permanently releases this fake. Repeated calls are harmless.
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _requests.clear();
    _scripts.clear();
  }

  void _ensureActive() {
    if (_disposed) throw StateError('The scripted HTTP transport is disposed.');
  }

  @override
  String toString() => 'ScriptedHandrailChatHttpTransport('
      'requestCount: ${_requests.length}, '
      'remainingScriptCount: ${_scripts.length}, disposed: $_disposed)';
}

sealed class _HttpScript {
  const _HttpScript();

  HandrailChatHttpResponse resolve();
}

final class _HttpResponseScript extends _HttpScript {
  const _HttpResponseScript(this.response);

  final HandrailChatHttpResponse response;

  @override
  HandrailChatHttpResponse resolve() => response;
}

final class _HttpErrorScript extends _HttpScript {
  const _HttpErrorScript(this.error, this.stackTrace);

  final Object error;
  final StackTrace stackTrace;

  @override
  HandrailChatHttpResponse resolve() =>
      Error.throwWithStackTrace(error, stackTrace);
}
