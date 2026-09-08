import 'dart:async';
import 'dart:convert';

import 'package:handrail_chat/core.dart';
import 'package:handrail_chat/src/testing/fake_chat_realtime.dart'
    show FakeChatRealtimeNetwork;
import 'package:handrail_chat/src/testing/in_memory_application_chat_storage.dart';
import 'package:test/test.dart';
import 'fixtures/existing_thread_opening_fixtures.dart';
import 'reply_style_runtime_test.dart' as f;

class Socket implements ChatRealtimeSocket {
  final framesController = StreamController<Object?>.broadcast(sync: true);
  final sent = <Map<String, dynamic>>[];
  @override
  Stream<Object?> get frames => framesController.stream;
  @override
  void close() {}
  @override
  void send(String data) {
    final json = jsonDecode(data) as Map<String, dynamic>;
    sent.add(json);
    if (json['type'] == 'chat.subscribe') {
      scheduleMicrotask(() => emit({
            'type': 'chat.subscription.accepted',
            'streamId': json['streamId'],
            'requestId': json['requestId'],
          }));
    }
  }

  void emit(Object? json) => framesController.add(jsonEncode(json));
  void accept(
          {bool? supported = true,
          ChatReplyStyleIdentity identity = f.actor,
          String device = 'device-1'}) =>
      emit({
        'type': 'chat.session.accepted',
        'metadata': f.metadata(supported),
        'tenantId': identity.tenantId.value,
        'actorStreamId': 'user:${identity.userId.value}',
        'deviceId': device,
        'sessionId': 'session-1',
      });
}

ChatRealtimeSessionTransport sessionFor(Socket socket,
    {FakeChatRealtimeNetwork? network}) {
  final session = ChatRealtimeSessionTransport(
    endpoint: Uri.parse('https://chat.test/api/chat'),
    clientPackageVersion: '0.1.19',
    protocolVersion: 4,
    tokenProvider: () => 'token',
    socketFactory: (_, __) => socket,
    network: network,
  );
  addTearDown(() async {
    await session.dispose();
    await socket.framesController.close();
  });
  return session;
}

Future<void> reconnect(ChatRealtimeSessionTransport session, Socket socket,
    {bool? supported = true,
    ChatReplyStyleIdentity identity = f.actor,
    String device = 'device-1'}) async {
  await session.suspend();
  await session.start();
  socket.accept(supported: supported, identity: identity, device: device);
  await f.pump();
}

void main() {
  test(
      'accepted identity hydrates without storage; same actor and new device reconnect reload',
      () async {
    final http = f.Http();
    final socket = Socket();
    final session = sessionFor(socket);
    final client = f.clientFor(http, realtime: session);
    await client.initialize();
    expect(http.reads, isEmpty);
    await session.start();
    socket.accept();
    await f.pump();
    expect(
        client.replyStyles.state.confirmed, isA<AbsentReplyStylePreference>());
    http.preference = f.saved(1);
    await reconnect(session, socket);
    expect(client.replyStyles.state.confirmed!.toJson(), f.saved(1));
    http.preference = f.saved(2, 'current');
    await reconnect(session, socket, device: 'new-device');
    expect(http.reads, hasLength(3));
    expect(client.replyStyles.state.confirmed!.toJson(), f.saved(2, 'current'));
    // Deliver through the real transport's authenticated private event boundary.
    socket.emit(f.event(3).toJson());
    await f.pump();
    expect(client.replyStyles.state.confirmed!.toJson(), f.saved(3));
    expect(session.state, isA<ChatRealtimeConnectedState>());
    expect(() => client.replyStyles.activateIdentity(null), throwsStateError);
  });

  test(
      'capability absence, regain and loss are rechecked on every accepted session',
      () async {
    final http = f.Http();
    final socket = Socket();
    final session = sessionFor(socket);
    final client = f.clientFor(http,
        realtime: session,
        configuration: const ChatReplyStyleConfiguration(
            defaultStyle: ReplyStyle.discord));
    await session.start();
    socket.accept(supported: null);
    await f.pump();
    expect(client.replyStyles.state.isAvailable, isFalse);
    expect(http.reads, isEmpty);
    await reconnect(session, socket);
    expect(client.replyStyles.state.isAvailable, isTrue);
    await client.replyStyles.select(ReplyStyle.current);
    expect(client.replyStyles.state.effectiveStyle, ReplyStyle.current);
    await reconnect(session, socket, supported: false);
    expect(client.replyStyles.state.isAvailable, isFalse);
    expect(client.replyStyles.state.canEdit, isFalse);
    expect(client.replyStyles.state.confirmed!.toJson(), f.saved(1, 'current'));
    expect(http.reads, hasLength(1));
    http.preference = f.saved(2);
    await reconnect(session, socket);
    expect(client.replyStyles.state.confirmed!.toJson(), f.saved(2));
  });

  test(
      'disconnect cancels save; reconnect hydrates but explicit retry alone replays',
      () async {
    final http = f.Http();
    final socket = Socket();
    final session = sessionFor(socket);
    final client = f.clientFor(http, realtime: session);
    await session.start();
    socket.accept();
    await f.pump();
    final pending = Completer<HandrailChatHttpResponse>();
    http.write = (_) => pending.future;
    final saving = client.replyStyles.select(ReplyStyle.discord);
    await f.pump();
    final input = http.writes.single;
    await session.suspend();
    await f.pump();
    await saving;
    expect(client.replyStyles.state.requestedStyle, ReplyStyle.discord);
    expect(client.replyStyles.state.isAvailable, isFalse);
    expect(client.replyStyles.state.effectiveStyle, ReplyStyle.current);
    pending.complete(f.response(f.result(input)));
    await f.pump();
    expect(client.replyStyles.state.confirmed!.revision, 0);
    http.preference = f.saved(2, 'current');
    await session.start();
    socket.accept();
    await f.pump();
    expect(http.writes, hasLength(1));
    expect(client.replyStyles.state.requestedStyle, ReplyStyle.discord);
    http.write = (_) async => f.response(f.result(input, status: 'replayed'));
    await client.replyStyles.retry();
    expect(http.writes, [input, input]);
    expect(client.replyStyles.state.confirmed!.toJson(), f.saved(2, 'current'));
    expect(client.replyStyles.state.requestedStyle, isNull);
  });

  test(
      'offline requested selection is retained without a write or optimistic style change',
      () async {
    final http = f.Http();
    final socket = Socket();
    final session = sessionFor(socket);
    final client = f.clientFor(http, realtime: session);
    await session.start();
    socket.accept();
    await f.pump();
    await session.suspend();
    await f.pump();
    await client.replyStyles.select(ReplyStyle.discord);
    expect(client.replyStyles.state.requestedStyle, ReplyStyle.discord);
    expect(client.replyStyles.state.effectiveStyle, ReplyStyle.current);
    expect(client.replyStyles.state.error, ChatReplyStyleError.unavailable);
    expect(http.writes, isEmpty);
    await session.start();
    socket.accept();
    await f.pump();
    expect(http.writes, isEmpty);
    await client.replyStyles.retry();
    expect(http.writes, hasLength(1));
    expect(client.replyStyles.state.confirmed!.toJson(), f.saved(1));
  });

  test('new accepted account cancels old read and never retries its selection',
      () async {
    final http = f.Http()..write = (_) => Future.error(StateError('lost'));
    final socket = Socket();
    final session = sessionFor(socket);
    final client = f.clientFor(http, realtime: session);
    await session.start();
    socket.accept();
    await f.pump();
    await client.replyStyles.select(ReplyStyle.discord);
    final pending = Completer<HandrailChatHttpResponse>();
    http.read = (_) => pending.future;
    final retry = client.replyStyles.retry();
    await f.pump();
    http.read = null;
    const other = ChatReplyStyleIdentity(
        tenantId: TenantId('tenant-2'), userId: UserId('user-2'));
    await reconnect(session, socket, identity: other);
    pending.complete(f.response(f.saved(99)));
    await retry;
    expect(client.replyStyles.state.identity!.userId, other.userId);
    expect(client.replyStyles.state.confirmed!.revision, 0);
    expect(client.replyStyles.state.requestedStyle, isNull);
    await client.replyStyles.retry();
    expect(http.writes, hasLength(1));
  });

  test('disposal cancels in-flight save and never accepts the late success',
      () async {
    final http = f.Http();
    final client = f.clientFor(http);
    await client.initialize();
    final pending = Completer<HandrailChatHttpResponse>();
    http.write = (_) => pending.future;
    final save = client.replyStyles.select(ReplyStyle.discord);
    await f.pump();
    await client.dispose();
    pending.complete(f.response(f.result(http.writes.single)));
    await save;
    expect(client.replyStyles.state.isDisposed, isTrue);
    expect(client.replyStyles.state.confirmed, isNull);
    expect(client.replyStyles.state.requestedStyle, isNull);
  });

  test(
      'style changes preserve retained draft, queued reply destination and open thread',
      () async {
    const identity = ChatReplyStyleIdentity(
        tenantId: TenantId('tenant-from-session'),
        userId: UserId('user-current'));
    final storageIdentity = ApplicationChatStorageIdentity(
        tenantId: identity.tenantId,
        userId: identity.userId,
        deviceId: const DeviceId('device-1'));
    final storage = InMemoryApplicationChatStorage();
    final network = FakeChatRealtimeNetwork(isOnline: false);
    addTearDown(network.dispose);
    final socket = Socket();
    final session = sessionFor(socket, network: network);
    final http = ThreadHttp();
    var key = 0;
    final client = HandrailChatClient(
      apiBaseUri: Uri.parse('https://chat.test/api/chat'),
      tokenProvider: () async => 'token',
      transport: http,
      localStorage: storage,
      storageIdentity: storageIdentity,
      realtimeSession: session,
      generateIdempotencyKey: () => 'intent-${++key}',
    );
    addTearDown(client.dispose);
    client.setApplicationForeground(
        false); // Keep the existing message pumps paused.
    await client.activateStorageIdentity(storageIdentity);
    const thread = ConversationId('conversation-thread');
    final content = DraftContent.fromJson({
      'format': 'markdown',
      'text': 'Friday **works**',
      'attachments': [
        {'attachmentId': 'draft-attachment'}
      ],
      'replyTo': {'messageId': 'message-reply', 'notifyAuthor': false},
    });
    unawaited(client.synchronizeDraft(ChatReplaceDraftInput(
      conversationId: thread,
      baseRevision: 0,
      content: content,
      deviceMutationId: 'draft-device',
      idempotencyKey: 'draft-key',
    )));
    await f.pump();
    final queued = await client.sendMessage(ChatSendMessageInput(
      conversationId: thread,
      content: MessageContent.fromJson({'format': 'plain', 'text': 'Friday'}),
      replyTo: MessageReplyReference(
          messageId: const MessageId('message-reply'), notifyAuthor: false),
    ));
    expect(queued, isA<ChatCommandQueued<SendMessageResult>>());
    await client.initialize();
    network.setOnline(true);
    await session.start();
    socket.accept(identity: identity);
    await f.pump();
    final opened = await client.openExistingThread(thread);
    expect(opened, isA<ChatExistingThreadOpenSuccess>());
    final handle = (opened as ChatExistingThreadOpenSuccess).handle;
    final threadState = handle.state;
    final draft = client.draftFor(thread)!.draft.toJson();
    final request = client.queuedSendMessages.single.request.toJson();
    final normalized = client.normalizedState.state;
    final queuedBytes = await storage.readEncoded(storageIdentity,
        ApplicationChatStorageRecordKind.queuedSendMessageIntents);
    await client.replyStyles.select(ReplyStyle.discord);
    expect(client.replyStyles.state.effectiveStyle, ReplyStyle.discord);
    client.reduceDurableEvent(f.event(2, style: 'current', identity: identity));
    expect(client.replyStyles.state.effectiveStyle, ReplyStyle.current);
    client.replyStyles.configure(
        const ChatReplyStyleConfiguration(override: ReplyStyle.discord));
    expect(client.draftFor(thread)!.draft.toJson(), draft);
    expect(client.queuedSendMessages.single.request.toJson(), request);
    expect(
        await storage.readEncoded(storageIdentity,
            ApplicationChatStorageRecordKind.queuedSendMessageIntents),
        queuedBytes);
    expect(client.normalizedState.state, same(normalized));
    expect(handle.state, same(threadState));
    expect(handle.state.parentConversationId,
        const ConversationId('conversation-parent'));
    expect(handle.conversationId, thread);
    expect(http.requests.where((r) => r.method != 'GET').length, 1);
    handle.release();
  });
}

class ThreadHttp extends f.Http {
  @override
  Future<HandrailChatHttpResponse> send(HandrailChatHttpRequest request) async {
    if (request.uri.path.contains('/conversations/')) {
      requests.add(request);
      if (request.uri.path.endsWith('/messages')) {
        return f.response(existingThreadTimelineFixture(
            parent: request.uri.path.contains('conversation-parent'),
            deletedRoot: false));
      }
      return f.response(existingThreadDetailFixture());
    }
    return super.send(request);
  }
}
