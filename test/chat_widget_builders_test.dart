import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:handrail_chat/ui.dart';

const _conversationId = ConversationId('conversation-builders');
const _now = '2026-08-26T22:00:00.000Z';

void main() {
  group('ChatWidgetBuilders', () {
    testWidgets('instantiates and invokes every typed builder', (tester) async {
      final transport = _RecordingTransport();
      final client = _client(transport);
      client.normalizedState.hydrateMessageTimeline(_timelinePage());
      final timeline = client.timeline(_conversationId);
      final message = _message();
      final conversation = _conversation();
      final member = _member();
      const attachment = MessageAttachmentMetadata(
        attachmentId: AttachmentId('attachment/builders'),
        fileName: 'design.pdf',
        contentType: 'application/pdf',
        sizeBytes: 42,
        downloadUrl: 'https://files.example.test/design.pdf',
      );
      const entity = HostEntityReference(type: 'project', id: 'project/42');
      const conversationError = ChatConversationControllerError(
        code: ChatConversationControllerErrorCode.transport,
        message: 'conversation failed',
      );

      final invoked = <String>[];
      final builders = ChatWidgetBuilders(
        message: (context, input) {
          invoked.add('message:${input.message.id.value}');
          expect(input.actions.messageId, input.message.id);
          return const Text('custom message');
        },
        avatar: (context, input) {
          invoked.add('avatar:${input.member.userId.value}');
          return const Text('custom avatar');
        },
        entityReference: (context, input) {
          invoked.add('entity:${input.reference.id}');
          return const Text('custom entity');
        },
        attachmentPreview: (context, input) {
          invoked.add('attachment:${input.attachment.attachmentId.value}');
          return const Text('custom attachment');
        },
        emptyConversation: (context, input) {
          invoked.add('empty:${input.conversation.id.value}');
          return const Text('custom empty');
        },
        loading: (context, input) {
          invoked.add('loading:${input.target.name}');
          return const Text('custom loading');
        },
        error: (context, input) {
          invoked.add('error:${input.message}');
          return const Text('custom error');
        },
      );
      final messageActions = ChatMessageActions.forMessage(
        controller: timeline,
        message: message,
      );

      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) => ListView(
              children: [
                builders.message(
                  context,
                  ChatMessageBuilderInput(
                    message: message,
                    actions: messageActions,
                  ),
                ),
                builders.avatar(
                  context,
                  ChatAvatarBuilderInput(member: member),
                ),
                builders.entityReference(
                  context,
                  const ChatEntityReferenceBuilderInput(reference: entity),
                ),
                builders.attachmentPreview(
                  context,
                  const ChatAttachmentPreviewBuilderInput(
                    attachment: attachment,
                  ),
                ),
                builders.emptyConversation(
                  context,
                  ChatEmptyConversationBuilderInput(
                    conversation: conversation,
                    actions: ChatTimelineActions(timeline),
                  ),
                ),
                builders.loading(
                  context,
                  const ChatLoadingBuilderInput(
                    target: ChatLoadingTarget.timeline,
                    conversationId: _conversationId,
                  ),
                ),
                builders.error(
                  context,
                  const ChatErrorBuilderInput.conversation(
                    error: conversationError,
                  ),
                ),
              ],
            ),
          ),
        ),
      );

      expect(
        invoked,
        [
          'message:message-builders',
          'avatar:user/builders',
          'entity:project/42',
          'attachment:attachment/builders',
          'empty:conversation-builders',
          'loading:timeline',
          'error:conversation failed',
        ],
      );
      expect(find.textContaining('custom '), findsNWidgets(7));

      await timeline.dispose();
      await client.dispose();
    });

    testWidgets('public default callbacks render without a product widget',
        (tester) async {
      final transport = _RecordingTransport();
      final client = _client(transport);
      final timeline = client.timeline(_conversationId);
      final message = _message();
      final builders = const ChatWidgetBuilders();

      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) => ListView(
              children: [
                builders.message(
                  context,
                  ChatMessageBuilderInput(
                    message: message,
                    actions: ChatMessageActions.forMessage(
                      controller: timeline,
                      message: message,
                    ),
                  ),
                ),
                builders.avatar(
                  context,
                  ChatAvatarBuilderInput(member: _member()),
                ),
                builders.entityReference(
                  context,
                  const ChatEntityReferenceBuilderInput(
                    reference: HostEntityReference(
                      type: 'case',
                      id: 'case/7',
                    ),
                  ),
                ),
                builders.attachmentPreview(
                  context,
                  const ChatAttachmentPreviewBuilderInput(
                    attachment: MessageAttachmentMetadata(
                      attachmentId: AttachmentId('attachment/default'),
                      fileName: 'default.txt',
                      contentType: 'text/plain',
                      sizeBytes: 7,
                      downloadUrl: 'https://files.example.test/default.txt',
                    ),
                  ),
                ),
                builders.emptyConversation(
                  context,
                  ChatEmptyConversationBuilderInput(
                    conversation: _conversation(),
                    actions: ChatTimelineActions(timeline),
                  ),
                ),
                builders.loading(
                  context,
                  const ChatLoadingBuilderInput(
                    target: ChatLoadingTarget.conversation,
                  ),
                ),
                builders.error(
                  context,
                  const ChatErrorBuilderInput.timeline(
                    error: ChatTimelineControllerError(
                      code: ChatTimelineControllerErrorCode.transport,
                      message: 'timeline failed',
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      );

      expect(find.text('builder message'), findsOneWidget);
      expect(find.text('U'), findsOneWidget);
      expect(find.text('case: case/7'), findsOneWidget);
      expect(find.text('default.txt'), findsOneWidget);
      expect(find.text('No messages yet'), findsOneWidget);
      expect(find.byType(CircularProgressIndicator), findsOneWidget);
      expect(find.text('timeline failed'), findsOneWidget);

      await timeline.dispose();
      await client.dispose();
    });

    test('merges partial and nested overrides without changing defaults', () {
      Widget baseAvatar(BuildContext context, ChatAvatarBuilderInput input) =>
          const Text('base avatar');
      Widget baseLoading(BuildContext context, ChatLoadingBuilderInput input) =>
          const Text('base loading');
      Widget overrideMessage(
        BuildContext context,
        ChatMessageBuilderInput input,
      ) =>
          const Text('override message');
      Widget overrideError(BuildContext context, ChatErrorBuilderInput input) =>
          const Text('override error');

      final base = ChatWidgetBuilders.fromStates(
        avatar: baseAvatar,
        states: ChatStateWidgetBuilders(loading: baseLoading),
      );
      final merged = base.merge(
        ChatWidgetBuilderOverrides(
          message: overrideMessage,
          states: ChatStateWidgetBuilderOverrides(error: overrideError),
        ),
      );

      expect(merged.message, same(overrideMessage));
      expect(merged.avatar, same(baseAvatar));
      expect(merged.entityReference, same(base.entityReference));
      expect(merged.attachmentPreview, same(base.attachmentPreview));
      expect(merged.loading, same(baseLoading));
      expect(merged.error, same(overrideError));
      expect(merged.emptyConversation, same(base.emptyConversation));
      expect(base.message, same(defaultChatMessageBuilder));
      expect(base.error, same(defaultChatErrorBuilder));
    });

    test('configuration and rendering inputs are immutable values', () {
      const first = ChatWidgetBuilders();
      const second = ChatWidgetBuilders();
      const member = ConversationSnapshotMember(
        tenantId: TenantId('tenant/builders'),
        conversationId: _conversationId,
        userId: UserId('user/builders'),
        role: 'member',
        state: 'active',
        joinedAt: IsoTimestamp(_now),
        updatedAt: IsoTimestamp(_now),
      );

      expect(identical(first, second), isTrue);
      expect(
        identical(
          const ChatAvatarBuilderInput(member: member),
          const ChatAvatarBuilderInput(member: member),
        ),
        isTrue,
      );
      expect(
        identical(
          const ChatLoadingBuilderInput(target: ChatLoadingTarget.timeline),
          const ChatLoadingBuilderInput(target: ChatLoadingTarget.timeline),
        ),
        isTrue,
      );
    });

    test('actions delegate typed values, results, and failures', () async {
      final transport = _RecordingTransport();
      final client = _client(transport);
      client.normalizedState.hydrateMessageTimeline(_timelinePage());
      final timeline = client.timeline(_conversationId);
      final conversation =
          client.conversations.forConversation(_conversationId);
      final messageActions = ChatMessageActions.forMessage(
        controller: timeline,
        message: _message(),
      );
      final timelineActions = ChatTimelineActions(timeline);
      final conversationActions = ChatConversationActions(conversation);
      final content = MessageContent(
        format: MessageContentFormat.markdown,
        text: 'edited through builder actions',
      );

      final ChatCommandResult<EditMessageResult> edit =
          await messageActions.edit(
        content,
        expectedRevision: 7,
        idempotencyKey: 'edit-from-builder',
      );
      final ChatCommandResult<SoftDeleteMessageResult> delete =
          await messageActions.delete(
        expectedRevision: 7,
        idempotencyKey: 'delete-from-builder',
      );
      final ChatCommandResult<ReactionMutationResult> reaction =
          await messageActions.setReaction(
        reactionKey: 'party_parrot',
        reactedByCurrentUser: true,
        idempotencyKey: 'reaction-from-builder',
      );
      final ChatThreadOpenResult thread = await messageActions.openThread();
      final ChatCommandResult<SendMessageResult> send =
          await timelineActions.send(content);
      final ChatCommandResult<ReadCursorMutationResult> read =
          await conversationActions.markRead(const MessageSequence(11));
      final ChatCommandResult<ReadCursorMutationResult> unread =
          await conversationActions.markUnread(const MessageSequence(9));
      final ChatTimelineControllerState timelineState =
          await timelineActions.refresh();
      final ChatConversationControllerState conversationState =
          await conversationActions.refresh();

      expect(edit, isA<ChatCommandFailure<EditMessageResult>>());
      expect(delete, isA<ChatCommandFailure<SoftDeleteMessageResult>>());
      expect(reaction, isA<ChatCommandFailure<ReactionMutationResult>>());
      expect(thread, isA<ChatThreadOpenFailure>());
      expect(send, isA<ChatCommandFailure<SendMessageResult>>());
      expect(read, isA<ChatCommandFailure<ReadCursorMutationResult>>());
      expect(unread, isA<ChatCommandFailure<ReadCursorMutationResult>>());
      expect(timelineState.status, ChatTimelineControllerStatus.error);
      expect(conversationState.status, ChatConversationControllerStatus.error);

      final requests = transport.requests;
      expect(requests, hasLength(7));
      expect(requests[0].method, 'PATCH');
      expect(requests[0].uri.path, '/api/chat/messages/message-builders');
      expect(jsonDecode(requests[0].body!)['expectedRevision'], 7);
      expect(requests[1].method, 'DELETE');
      expect(jsonDecode(requests[1].body!)['expectedRevision'], 7);
      expect(
        requests[2].uri.path,
        '/api/chat/messages/message-builders/reactions/party_parrot',
      );
      expect(
        requests.map((request) => request.uri.path),
        containsAll([
          '/api/chat/messages/message-builders/thread',
          '/api/chat/conversations/conversation-builders/messages',
          '/api/chat/conversations/conversation-builders',
        ]),
      );

      await timeline.dispose();
      await conversation.dispose();
      await client.dispose();
    });

    test('public declaration imports only Flutter and the public core surface',
        () async {
      final source =
          await File('lib/src/chat_widget_builders.dart').readAsString();
      final imports = RegExp("^import '([^']+)';", multiLine: true)
          .allMatches(source)
          .map((match) => match.group(1))
          .toList(growable: false);

      expect(imports, ['package:flutter/material.dart', '../core.dart']);
      expect(source, isNot(contains("import 'core/")));
      expect(source, isNot(contains("import 'generated/")));
      expect(source, isNot(contains('realtime_session_transport.dart')));
      expect(source, isNot(contains('application_chat_storage.dart')));
      expect(source, isNot(contains('attachment_upload_manager.dart')));
    });
  });
}

HandrailChatClient _client(_RecordingTransport transport) {
  var id = 0;
  return HandrailChatClient(
    apiBaseUri: Uri.parse('https://chat.test/api/chat'),
    tokenProvider: () async => 'builder-test-token',
    transport: transport,
    generateClientMessageId: () => 'builder-client-message',
    generateIdempotencyKey: () => 'builder-key-${id += 1}',
  );
}

final class _RecordingTransport implements HandrailChatHttpTransport {
  final List<HandrailChatHttpRequest> requests = [];

  @override
  Future<HandrailChatHttpResponse> send(HandrailChatHttpRequest request) async {
    requests.add(request);
    return HandrailChatHttpResponse(
      statusCode: 400,
      body: jsonEncode({'error': 'expected builder action rejection'}),
    );
  }
}

MessageTimelineMessage _message() => MessageTimelineMessage.fromJson({
      'id': 'message-builders',
      'tenantId': 'tenant/builders',
      'conversationId': _conversationId.value,
      'author': {'type': 'user', 'userId': 'user/builders'},
      'sequence': 11,
      'createdAt': _now,
      'updatedAt': _now,
      'revision': {'revision': 7},
      'content': {'format': 'plain', 'text': 'builder message'},
      'isThreadRoot': false,
      'reactions': <Object?>[],
      'attachmentMetadata': <Object?>[],
    });

MessageTimelinePage _timelinePage() {
  final request = MessageTimelineRequest(
    conversationId: _conversationId,
    direction: MessageTimelineDirection.backward,
    limit: 10,
  );
  return MessageTimelinePage.fromJson(
    {
      'conversationId': _conversationId.value,
      'messages': [_message().toJson()],
      'pagination': {
        'older': {'available': false},
        'newer': {'available': false},
      },
      'replay': {
        'resumeFrom': {'eventId': 'builder-timeline-event'},
      },
    },
    request: request,
  );
}

Conversation _conversation() => Conversation.fromJson({
      'id': _conversationId.value,
      'tenantId': 'tenant/builders',
      'type': 'channel',
      'name': 'Builder conversation',
      'visibility': 'private',
      'createdAt': _now,
      'updatedAt': _now,
    });

ConversationSnapshotMember _member() => ConversationSnapshotMember.fromJson({
      'tenantId': 'tenant/builders',
      'conversationId': _conversationId.value,
      'userId': 'user/builders',
      'role': 'member',
      'state': 'active',
      'joinedAt': _now,
      'updatedAt': _now,
    });
