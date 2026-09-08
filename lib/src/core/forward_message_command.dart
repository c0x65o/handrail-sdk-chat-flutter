part of '../handrail_chat_client.dart';

/// Deterministic boundary for client-authored forwarding correlations.
typedef ChatForwardMessageCorrelationIdGenerator = String Function();

/// Authored fields accepted by [HandrailChatClient.forwardMessage].
final class ChatForwardMessageInput {
  const ChatForwardMessageInput({
    required this.sourceMessageId,
    required this.destinationConversationId,
  });

  final MessageId sourceMessageId;
  final ConversationId destinationConversationId;
}

final class _PendingForwardMessageCorrelation {
  const _PendingForwardMessageCorrelation(this.value);

  final String value;
}

ChatCommandDescriptor<ForwardMessageRequest, ForwardMessageRequest,
    ForwardMessageResult> _forwardMessageDescriptor(
  ForwardMessageRequest request,
) =>
    ChatCommandDescriptor<ForwardMessageRequest, ForwardMessageRequest,
        ForwardMessageResult>(
      name: 'message.forward',
      method: ChatCommandMethod.post,
      path: '/messages/forward',
      retrySafety: ChatCommandRetrySafety.safe,
      validateInput: (input) => ForwardMessageRequest.fromJson(input.toJson()),
      parseResult: (value) =>
          ForwardMessageResult.fromJson(value, request: request),
    );
