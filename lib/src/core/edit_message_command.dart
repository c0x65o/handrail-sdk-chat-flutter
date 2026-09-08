part of '../handrail_chat_client.dart';

/// Authored fields accepted by [HandrailChatClient.editMessage].
final class ChatEditMessageInput {
  const ChatEditMessageInput({
    required this.messageId,
    required this.expectedRevision,
    required this.content,
    this.idempotencyKey,
  });

  final MessageId messageId;
  final int expectedRevision;
  final MessageContent content;

  /// Optional caller-owned key. When omitted, the client generates one once
  /// for the complete logical edit and reuses it across safe retries.
  final String? idempotencyKey;
}

final ChatCommandDescriptor<EditMessageRequest, EditMessageRequest,
        EditMessageResult> _editMessageDescriptor =
    ChatCommandDescriptor.withPathBuilder(
  name: 'message.edit',
  method: ChatCommandMethod.patch,
  pathBuilder: (request) =>
      '/messages/${Uri.encodeComponent(request.messageId.toJson())}',
  retrySafety: ChatCommandRetrySafety.safe,
  validateInput: (request) => EditMessageRequest.fromJson(request.toJson()),
  parseResult: EditMessageResult.fromJson,
  parseErrorResult: (value, httpStatus) {
    if (httpStatus != 409) return null;
    final result = EditMessageResult.fromJson(value);
    return result.reconciliationStatus ==
            EditMessageReconciliationStatus.revisionConflict
        ? result
        : null;
  },
);
