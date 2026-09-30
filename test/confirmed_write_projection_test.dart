import 'dart:async';
import 'dart:convert';
import 'package:handrail_chat/core.dart';
import 'package:test/test.dart';
import 'fixtures/conversation_list_fixtures.dart';
import 'fixtures/conversation_creation_fixtures.dart';
import 'fixtures/existing_thread_opening_fixtures.dart';
import 'fixtures/thread_creation_fixtures.dart';

class Transport implements HandrailChatHttpTransport {
  Transport(this.handle);
  final FutureOr<HandrailChatHttpResponse> Function(HandrailChatHttpRequest)
      handle;
  @override
  Future<HandrailChatHttpResponse> send(HandrailChatHttpRequest r) async =>
      handle(r);
}

HandrailChatHttpResponse json(Object value, [int status = 200]) =>
    HandrailChatHttpResponse(statusCode: status, body: jsonEncode(value));
HandrailChatClient clientFor(Transport transport) => HandrailChatClient(
      apiBaseUri: Uri.parse('https://test.invalid/chat'),
      tokenProvider: () async => 'test',
      transport: transport,
    );
void main() {
  test(
      'confirmed channel creation immediately updates a mounted list without another list read',
      () async {
    var reads = 0;
    final client = clientFor(Transport((r) {
      if (r.method == 'GET') {
        reads++;
        return json(conversationListPage());
      }
      final body = jsonDecode(r.body!) as Map;
      return json(
          conversationCreationResultFixture('channel', 'created',
              clientRequestId: body['clientRequestId'] as String),
          201);
    }));
    final list = ChatConversationListController(
        client: client, scope: const OrganizationConversationSnapshotScope());
    addTearDown(() async {
      await list.dispose();
      await client.dispose();
    });
    await list.refresh();
    expect(list.state.items, isEmpty);
    final result = await client.createChannel(const ChatCreateChannelInput(
        name: 'Order coordination',
        visibility: ConversationVisibility.private,
        entity: HostEntityReference(type: 'erp.order', id: 'order/42')));
    expect(
        result, isA<ChatCommandSuccess<ChannelConversationCreationResult>>());
    await Future<void>.delayed(Duration.zero);
    expect(list.state.items.single.displayName, 'Order coordination');
    expect(reads, 1);
  });

  for (final mode in ['replay', 'failed read', 'concurrent']) {
    final lostRead = mode == 'failed read';
    final concurrent = mode == 'concurrent';
    test(
        'confirmed thread reply refreshes root without replaying send; mode=$mode',
        () async {
      var sends = 0, rootReads = 0;
      final refreshed = Completer<void>();
      final releaseFirstRead = Completer<void>();
      final summary = {
        'threadId': 'conversation-thread',
        'replyCount': 0,
        'participantIds': <String>[],
        'unreadCount': 0
      };
      Map<String, Object?> rootPage(int count) {
        final page =
            existingThreadTimelineFixture(parent: true, deletedRoot: false);
        final row = (page['messages'] as List).single as Map<String, Object?>;
        row['threadSummary'] = {...summary, 'replyCount': count};
        row['isThreadRoot'] = true;
        return page;
      }

      final client = clientFor(Transport((r) async {
        if (r.method == 'POST') {
          sends++;
          final body = jsonDecode(r.body!) as Map;
          return json({
            'operation': 'send',
            'reconciliationStatus':
                concurrent || sends == 1 ? 'applied' : 'replayed',
            'clientMessageId': body['clientMessageId'],
            'canonicalRevision': 1,
            'message': {
              'id': concurrent ? 'reply-$sends' : 'reply',
              'tenantId': 'tenant-from-session',
              'conversationId': 'conversation-thread',
              'author': {'type': 'user', 'userId': 'user-current'},
              'sequence': concurrent ? sends + 2 : 3,
              'createdAt': existingThreadFixtureTime,
              'updatedAt': existingThreadFixtureTime,
              'revision': {'revision': 1},
              'content': body['content'],
            }
          }, 201);
        }
        if (r.uri.path.contains('conversation-parent')) {
          rootReads++;
          if (!refreshed.isCompleted) refreshed.complete();
          if (concurrent && rootReads == 1) await releaseFirstRead.future;
          return lostRead
              ? json({'error': 'unavailable'}, 403)
              : json(rootPage(concurrent ? rootReads : 1));
        }
        return json(existingThreadTimelineFixture());
      }));
      addTearDown(client.dispose);
      client.normalizedState.hydrateConversationDetail(
          ConversationDetailSnapshot.fromJson(
              threadCreationResultFixture('created')['conversation']));
      client.normalizedState.hydrateMessageTimeline(
          MessageTimelinePage.fromJson(rootPage(0),
              request: const MessageTimelineRequest(
                  conversationId: ConversationId('conversation-parent'),
                  direction: MessageTimelineDirection.backward,
                  limit: 50)));
      if (concurrent) {
        final sendsTogether = await Future.wait([
          for (var i = 0; i < 2; i++)
            client.sendMessage(ChatSendMessageInput(
              conversationId: const ConversationId('conversation-thread'),
              content: MessageContent(
                  format: MessageContentFormat.plain, text: 'Reply $i'),
            )),
        ]);
        expect(sendsTogether,
            everyElement(isA<ChatCommandSuccess<SendMessageResult>>()));
        await refreshed.future;
        expect(rootReads, 1);
        releaseFirstRead.complete();
        for (var i = 0;
            i < 100 &&
                client
                        .normalizedState
                        .state
                        .messages[const MessageId('message-root')]!
                        .threadSummary!
                        .replyCount !=
                    2;
            i++) {
          await Future<void>.delayed(const Duration(milliseconds: 10));
        }
        expect(
            client
                .normalizedState
                .state
                .messages[const MessageId('message-root')]!
                .threadSummary!
                .replyCount,
            2);
        expect(sends, 2);
        expect(rootReads, 2);
        return;
      }
      for (var i = 0; i < 2; i++) {
        final result = await client.sendMessage(ChatSendMessageInput(
            conversationId: const ConversationId('conversation-thread'),
            content: MessageContent(
                format: MessageContentFormat.plain, text: 'Reply')));
        expect(result, isA<ChatCommandSuccess<SendMessageResult>>());
        await refreshed.future;
        await Future<void>.delayed(Duration.zero);
        expect(
            client
                .normalizedState
                .state
                .messages[const MessageId('message-root')]!
                .threadSummary!
                .replyCount,
            lostRead ? 0 : 1);
      }
      expect(sends, 2);
      expect(rootReads, 2);
    });
  }
}
