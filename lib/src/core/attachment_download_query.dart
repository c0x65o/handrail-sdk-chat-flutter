part of '../handrail_chat_client.dart';

/// Supplies the current time used to validate download descriptor expiry.
typedef ChatAttachmentDownloadClock = DateTime Function();

extension _AttachmentDownloadQueryReader on _ConversationSnapshotQueryReader {
  Future<ChatSnapshotQueryResult<GetAttachmentDownloadResult>>
      getAttachmentDownload(
    GetAttachmentDownloadInput input, {
    required ChatSnapshotQueryOptions options,
    required ChatAttachmentDownloadClock clock,
  }) {
    late final GetAttachmentDownloadInput validated;
    try {
      validated = GetAttachmentDownloadInput.fromJson(input.toJson());
    } catch (_) {
      _diagnose(
        const ChatSnapshotQueryDiagnostic(
          event: ChatSnapshotQueryDiagnosticEvent.validationFailed,
          query: ChatSnapshotQueryName.attachmentDownload,
          attempt: 0,
        ),
      );
      return Future.value(
        const ChatSnapshotQueryValidationFailure<GetAttachmentDownloadResult>(),
      );
    }

    return _run<GetAttachmentDownloadResult>(
      query: ChatSnapshotQueryName.attachmentDownload,
      uri: _attachmentDownloadUri(apiBaseUri, validated),
      options: options,
      parse: (value) {
        final result = parseAttachmentTransportResult(
          value,
          validated,
          now: clock().toUtc(),
        );
        if (result is! GetAttachmentDownloadResult) {
          throw const FormatException();
        }
        return result;
      },
    );
  }
}

Uri _attachmentDownloadUri(
  Uri baseUri,
  GetAttachmentDownloadInput input,
) =>
    _snapshotEndpointUri(
      baseUri,
      <String>[
        'attachments',
        input.attachmentId.toJson(),
        'download',
      ],
      queryParameters: <String, String>{
        'messageId': input.messageId.toJson(),
      },
    );

DateTime _currentAttachmentDownloadTime() => DateTime.now().toUtc();
