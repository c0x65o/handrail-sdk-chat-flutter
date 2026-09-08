part of '../handrail_chat_client.dart';

extension _MessageTimelineQueryReader on _ConversationSnapshotQueryReader {
  Future<ChatSnapshotQueryResult<MessageTimelinePage>> getMessageTimeline(
    MessageTimelineRequest input, {
    required ChatSnapshotQueryOptions options,
  }) {
    late final MessageTimelineRequest validated;
    try {
      validated = MessageTimelineRequest.fromJson(input.toJson());
    } catch (_) {
      _diagnose(
        const ChatSnapshotQueryDiagnostic(
          event: ChatSnapshotQueryDiagnosticEvent.validationFailed,
          query: ChatSnapshotQueryName.messageTimeline,
          attempt: 0,
        ),
      );
      return Future.value(
        const ChatSnapshotQueryValidationFailure<MessageTimelinePage>(),
      );
    }

    return _run<MessageTimelinePage>(
      query: ChatSnapshotQueryName.messageTimeline,
      uri: _messageTimelineUri(apiBaseUri, validated),
      options: options,
      parse: (value) => MessageTimelinePage.fromJson(
        value,
        request: validated,
      ),
    );
  }
}

Uri _messageTimelineUri(
  Uri baseUri,
  MessageTimelineRequest input,
) {
  final parameters = <String, String>{};
  final cursor = input.cursor;
  if (input.direction == MessageTimelineDirection.forward) {
    parameters['after'] = (cursor?.value ?? 0).toString();
  } else if (cursor != null) {
    parameters['before'] = cursor.value.toString();
  }
  parameters['limit'] = input.limit.toString();

  return _snapshotEndpointUri(
    baseUri,
    <String>[
      'conversations',
      input.conversationId.toJson(),
      'messages',
    ],
    queryParameters: parameters,
  );
}
