part of '../handrail_chat_client.dart';

/// Authored fields accepted by [HandrailChatClient.deleteMessage].
final class ChatDeleteMessageInput {
  const ChatDeleteMessageInput({
    required this.messageId,
    required this.expectedRevision,
    this.idempotencyKey,
  });

  final MessageId messageId;
  final int expectedRevision;

  /// Optional caller-owned key. When omitted, the client generates one once
  /// for the complete logical delete and reuses it across safe retries.
  final String? idempotencyKey;
}

final ChatCommandDescriptor<SoftDeleteMessageRequest, SoftDeleteMessageRequest,
        SoftDeleteMessageResult> _deleteMessageDescriptor =
    ChatCommandDescriptor.withPathBuilder(
  name: 'message.delete',
  method: ChatCommandMethod.delete,
  pathBuilder: (request) =>
      '/messages/${Uri.encodeComponent(request.messageId.toJson())}',
  retrySafety: ChatCommandRetrySafety.safe,
  validateInput: (request) =>
      SoftDeleteMessageRequest.fromJson(request.toJson()),
  parseResult: SoftDeleteMessageResult.fromJson,
  parseErrorResult: (value, httpStatus) {
    if (httpStatus != 409) return null;
    final result = SoftDeleteMessageResult.fromJson(value);
    return result.reconciliationStatus ==
            SoftDeleteMessageReconciliationStatus.revisionConflict
        ? result
        : null;
  },
);
