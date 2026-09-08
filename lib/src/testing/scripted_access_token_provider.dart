import 'dart:collection';

/// A FIFO access-token provider compatible with HTTP and realtime clients.
///
/// Token values are intentionally absent from [toString].
final class ScriptedAccessTokenProvider {
  ScriptedAccessTokenProvider({String? fallbackToken})
      : _fallbackToken = fallbackToken;

  final Queue<_TokenScript> _scripts = Queue<_TokenScript>();
  String? _fallbackToken;
  var _callCount = 0;

  int get callCount => _callCount;
  int get remainingScriptCount => _scripts.length;

  set fallbackToken(String? value) => _fallbackToken = value;

  void enqueueToken(String token) => _scripts.add(_TokenValue(token));

  void enqueueError(Object error, [StackTrace? stackTrace]) => _scripts.add(
        _TokenError(error, stackTrace ?? StackTrace.current),
      );

  Future<String> call() async {
    _callCount += 1;
    if (_scripts.isNotEmpty) return _scripts.removeFirst().resolve();
    final fallback = _fallbackToken;
    if (fallback != null) return fallback;
    throw StateError('No scripted access-token result remains.');
  }

  void reset({String? fallbackToken}) {
    _scripts.clear();
    _callCount = 0;
    _fallbackToken = fallbackToken;
  }

  @override
  String toString() => 'ScriptedAccessTokenProvider('
      'callCount: $_callCount, remainingScriptCount: ${_scripts.length}, '
      'hasFallback: ${_fallbackToken != null})';
}

sealed class _TokenScript {
  const _TokenScript();

  String resolve();
}

final class _TokenValue extends _TokenScript {
  const _TokenValue(this.value);

  final String value;

  @override
  String resolve() => value;
}

final class _TokenError extends _TokenScript {
  const _TokenError(this.error, this.stackTrace);

  final Object error;
  final StackTrace stackTrace;

  @override
  String resolve() => Error.throwWithStackTrace(error, stackTrace);
}
