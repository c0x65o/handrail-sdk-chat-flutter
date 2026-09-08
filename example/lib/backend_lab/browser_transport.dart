import 'dart:async';
import 'dart:js_interop';

import 'package:handrail_chat/core.dart';
import 'package:web/web.dart' as web;

/// Browser boundaries only. Authentication, replay and reduction belong to SDK.
class BrowserChatTransport implements HandrailChatHttpTransport {
  @override
  Future<HandrailChatHttpResponse> send(HandrailChatHttpRequest request) async {
    final headers = web.Headers();
    request.headers.forEach((name, value) => headers.set(name, value));
    final response = await web.window
        .fetch(
          request.uri.toString().toJS,
          web.RequestInit(
            method: request.method,
            headers: headers,
            body: request.body?.toJS,
            credentials: 'same-origin',
          ),
        )
        .toDart;
    return HandrailChatHttpResponse(
      statusCode: response.status,
      body: (await response.text().toDart).toDart,
    );
  }
}

class BrowserChatSocket implements ChatRealtimeSocket {
  BrowserChatSocket._(this._socket) {
    _socket.onmessage = ((web.MessageEvent event) {
      _frames.add(event.data.dartify());
    }).toJS;
    _socket.onclose = ((web.Event _) {
      unawaited(_frames.close());
    }).toJS;
  }

  final web.WebSocket _socket;
  final _frames = StreamController<Object?>();

  static Future<ChatRealtimeSocket> open(
      Uri uri, List<String> protocols) async {
    final socket = web.WebSocket(
        uri.toString(), protocols.map((value) => value.toJS).toList().toJS);
    final adapter = BrowserChatSocket._(socket);
    final opened = Completer<ChatRealtimeSocket>();
    socket.onopen = ((web.Event _) {
      if (!opened.isCompleted) opened.complete(adapter);
    }).toJS;
    socket.onerror = ((web.Event _) {
      if (!opened.isCompleted) {
        opened.completeError(StateError('Chat Lab socket could not connect.'));
      } else if (!adapter._frames.isClosed) {
        adapter._frames.addError(StateError('Chat Lab socket disconnected.'));
      }
    }).toJS;
    try {
      return await opened.future.timeout(const Duration(seconds: 15));
    } catch (_) {
      socket.close();
      rethrow;
    }
  }

  @override
  Stream<Object?> get frames => _frames.stream;

  @override
  void send(String data) => _socket.send(data.toJS);

  @override
  void close() => _socket.close();
}

/// Cursors live as long as this engine's normalized cache. Reload starts both
/// fresh; reconnect retains both. Never resume a cursor with an empty cache.
class LabCursorStorage implements ChatRealtimeCursorStorage {
  String? value;

  @override
  String? read({required String scope}) => value;

  @override
  void write({required String scope, required String value}) =>
      this.value = value;

  @override
  void clear({required String scope}) => value = null;
}
