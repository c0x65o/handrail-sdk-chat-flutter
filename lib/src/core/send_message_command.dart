part of '../handrail_chat_client.dart';

/// Deterministic boundary for client-authored message identifiers.
typedef ChatClientMessageIdGenerator = String Function();

/// Authored fields accepted by [HandrailChatClient.sendMessage].
final class ChatSendMessageInput {
  const ChatSendMessageInput({
    required this.conversationId,
    required this.content,
    this.replyTo,
  });

  final ConversationId conversationId;
  final MessageContent content;

  /// References a message in the explicitly supplied conversation.
  final MessageReplyReference? replyTo;
}

final ChatCommandDescriptor<Map<String, Object?>, SendMessageRequest,
        SendMessageResult> _sendMessageDescriptor =
    ChatCommandDescriptor.withPathBuilder(
  name: 'message.send',
  method: ChatCommandMethod.post,
  pathBuilder: (request) =>
      '/conversations/${Uri.encodeComponent(request.conversationId.toJson())}/messages',
  retrySafety: ChatCommandRetrySafety.safe,
  validateInput: SendMessageRequest.fromJson,
  parseResult: SendMessageResult.fromJson,
);
