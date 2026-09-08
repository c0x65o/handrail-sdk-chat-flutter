import 'dart:convert';

import 'package:handrail_chat/core.dart';
import 'package:test/test.dart';

// ignore: avoid_relative_lib_imports
import '../example/lib/backend_lab/thread_lifecycles.dart';
import 'thread_lifecycle_controller_test.dart' as f;
import 'reply_style_client_test.dart' as rt;

f.Http httpFor(String actor) {
  Object? forActor(Object? value) =>
      jsonDecode(jsonEncode(value).replaceAll(f.user.value, actor));
  final http = f.Http();
  http.snapshot = (forActor(http.snapshot) as Map).cast<String, Object?>();
  (http.snapshot['conversation'] as Map)['currentThreadFollow'] = {
    'followRevision': 0,
    'follow': null,
  };
  http.write = (request) async => f.response(forActor(f.result(request)));
  return http;
}

void main() {
  test('host configures created threads, reconnects and preserves revocation',
      () async {
    final http = httpFor('alice');
    final socket = rt.Socket();
    final session = rt.sessionFor(socket);
    final client = await f.clientFor(http, realtime: session);
    final binding = BackendLabThreadLifecycles(client, session);
    addTearDown(binding.dispose);
    final controller = client.threadLifecycles.forThread(f.threadId);
    expect((await controller.load()).error, ChatThreadLifecycleError.denied);
    Future<void> connect(String device) async {
      await session.start();
      socket.emit({
        'type': 'chat.session.accepted',
        'metadata': f.metadata,
        'tenantId': f.tenant.value,
        'actorStreamId': 'user:alice',
        'deviceId': device,
        'sessionId': 'session-$device',
      });
      await f.pump();
    }

    await connect('first');
    // Thread creation/detail hydration happens after connecting.
    client.normalizedState.hydrateConversationDetail(
        ConversationDetailSnapshot.fromJson(http.snapshot));
    await f.pump();
    expect(controller.state.status, ChatThreadLifecycleStatus.ready);
    expect(controller.state.capabilities.canClose, true);
    expect(controller.state.capabilities.canReopen, true);
    expect(controller.state.capabilities.canLock, true);
    expect((await controller.close()).status, ChatThreadLifecycleStatus.ready);
    expect(http.writes, hasLength(1));
    controller.setAuthority(null);
    client.normalizedState.hydrateConversationDetail(
        ConversationDetailSnapshot.fromJson(http.snapshot));
    await f.pump();
    expect(controller.state.error, ChatThreadLifecycleError.denied);
    expect(controller.state.capabilities.canClose, false);
    await session.suspend();
    await connect('second');
    client.normalizedState.hydrateConversationDetail(
        ConversationDetailSnapshot.fromJson(http.snapshot));
    await f.pump();
    expect(controller.state.status, ChatThreadLifecycleStatus.ready);
    expect(controller.state.capabilities.canClose, true);
  });
  for (final actor in ['carol', 'dave']) {
    test('$actor cannot manage threads in the reply-styles seed', () async {
      final http = httpFor(actor);
      final socket = rt.Socket();
      final session = rt.sessionFor(socket);
      final client = await f.clientFor(http, realtime: session);
      final binding = BackendLabThreadLifecycles(client, session);
      addTearDown(binding.dispose);
      await session.start();
      socket.emit({
        'type': 'chat.session.accepted',
        'metadata': f.metadata,
        'tenantId': f.tenant.value,
        'actorStreamId': 'user:$actor',
        'deviceId': 'first',
        'sessionId': 'session-first',
      });
      await f.pump();
      client.normalizedState.hydrateConversationDetail(
          ConversationDetailSnapshot.fromJson(http.snapshot));
      await f.pump();
      final controller = client.threadLifecycles.forThread(f.threadId);
      expect(controller.state.status, ChatThreadLifecycleStatus.ready);
      expect(controller.state.capabilities.canClose, false);
      expect(controller.state.capabilities.canLock, false);
      await controller.close();
      expect(http.writes, isEmpty);
    });
  }
}
