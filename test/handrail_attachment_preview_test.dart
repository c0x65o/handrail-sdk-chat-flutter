import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:handrail_chat/ui.dart';

const _conversationId = ConversationId('conversation-attachment-preview');
const _messageId = MessageId('message-attachment-preview');
const _attachmentId = AttachmentId('attachment-preview');
const _createdAt = IsoTimestamp('2026-08-26T20:00:00.000Z');
const _expiresAt = IsoTimestamp('2026-08-27T20:00:00.000Z');
const _settledAt = IsoTimestamp('2026-08-26T20:01:00.000Z');

void main() {
  testWidgets('presents every upload lifecycle and rejection reason',
      (tester) async {
    final handle = _UploadHandle(_state(ChatAttachmentUploadStatus.preparing));
    await tester.pumpWidget(_host(HandrailAttachmentPreview.active(
      upload: handle,
      uploadPollInterval: const Duration(milliseconds: 10),
    )));

    const labels = <ChatAttachmentUploadStatus, String>{
      ChatAttachmentUploadStatus.preparing: 'Preparing',
      ChatAttachmentUploadStatus.pending: 'Pending',
      ChatAttachmentUploadStatus.uploading: 'Uploading',
      ChatAttachmentUploadStatus.finalizing: 'Finalizing',
      ChatAttachmentUploadStatus.finalized: 'Finalized',
      ChatAttachmentUploadStatus.attached: 'Attached',
      ChatAttachmentUploadStatus.rejected: 'Rejected',
      ChatAttachmentUploadStatus.abandoned: 'Abandoned',
      ChatAttachmentUploadStatus.failed: 'Failed',
      ChatAttachmentUploadStatus.cancelled: 'Cancelled',
    };
    for (final entry in labels.entries) {
      handle.state = _state(entry.key);
      await tester.pumpWidget(_host(HandrailAttachmentPreview.active(
        key: ValueKey(entry.key),
        upload: handle,
        uploadPollInterval: const Duration(milliseconds: 10),
      )));
      expect(find.textContaining(entry.value), findsWidgets);
    }

    const reasons = <AttachmentRejectionReason, String>{
      AttachmentRejectionReason.missingObject: 'File was not received',
      AttachmentRejectionReason.sizeMismatch: 'File size did not match',
      AttachmentRejectionReason.checksumMismatch: 'File integrity check failed',
      AttachmentRejectionReason.contentTypeMismatch: 'File type did not match',
      AttachmentRejectionReason.unsafe: 'File was unsafe',
      AttachmentRejectionReason.scanFailed: 'File scan failed',
      AttachmentRejectionReason.invalidMetadata: 'File details were invalid',
    };
    for (final entry in reasons.entries) {
      handle.state = _state(
        ChatAttachmentUploadStatus.rejected,
        rejectionReason: entry.key,
      );
      await tester.pumpWidget(_host(HandrailAttachmentPreview.active(
        key: ValueKey(entry.key),
        upload: handle,
        uploadPollInterval: const Duration(milliseconds: 10),
      )));
      expect(find.textContaining(entry.value), findsOneWidget);
    }
  });

  testWidgets('shows indeterminate, partial, and complete bounded progress',
      (tester) async {
    final zero = _UploadHandle(_state(
      ChatAttachmentUploadStatus.uploading,
      sizeBytes: 0,
    ));
    await tester.pumpWidget(_host(HandrailAttachmentPreview.active(
      upload: zero,
      uploadPollInterval: const Duration(milliseconds: 10),
    )));
    expect(
      tester
          .widget<LinearProgressIndicator>(
            find.byKey(const ValueKey('handrail-attachment-progress')),
          )
          .value,
      isNull,
    );

    final partial = _UploadHandle(_state(
      ChatAttachmentUploadStatus.uploading,
      uploadedBytes: 25,
    ));
    await tester.pumpWidget(_host(HandrailAttachmentPreview.active(
      upload: partial,
      uploadPollInterval: const Duration(milliseconds: 10),
    )));
    expect(
      tester
          .widget<LinearProgressIndicator>(
            find.byKey(const ValueKey('handrail-attachment-progress')),
          )
          .value,
      .25,
    );
    partial.state = _state(
      ChatAttachmentUploadStatus.uploading,
      uploadedBytes: 100,
    );
    await tester.pump(const Duration(milliseconds: 10));
    expect(
      tester
          .widget<LinearProgressIndicator>(
            find.byKey(const ValueKey('handrail-attachment-progress')),
          )
          .value,
      1,
    );
    expect(
      find.byWidgetPredicate(
        (widget) =>
            widget is Semantics &&
            widget.properties.value == 'Uploading, 100 percent',
      ),
      findsOneWidget,
    );
  });

  testWidgets('offers cancel and supported retry actions only', (tester) async {
    final active = _UploadHandle(_state(ChatAttachmentUploadStatus.uploading));
    await tester.pumpWidget(_host(HandrailAttachmentPreview.active(
      upload: active,
      uploadPollInterval: const Duration(milliseconds: 10),
    )));
    await tester.tap(
      find.byKey(const ValueKey('handrail-attachment-cancel')),
    );
    expect(active.cancelCount, 1);
    expect(
        find.byKey(const ValueKey('handrail-attachment-retry')), findsNothing);

    var retries = 0;
    final failed = _UploadHandle(_state(ChatAttachmentUploadStatus.failed));
    await tester.pumpWidget(_host(HandrailAttachmentPreview.active(
      upload: failed,
      onRetry: () => retries += 1,
    )));
    expect(
        find.byKey(const ValueKey('handrail-attachment-cancel')), findsNothing);
    await tester.tap(find.byKey(const ValueKey('handrail-attachment-retry')));
    await tester.pump();
    expect(retries, 1);
  });

  testWidgets('resolves a fresh descriptor before each open delegate action',
      (tester) async {
    var resolutions = 0;
    var opens = 0;
    final delegates = ChatApplicationDelegates(
      openAttachment: (attachment) async {
        opens += 1;
        expect(attachment.attachmentId, _attachmentId);
        return ChatApplicationDelegateResult.handled;
      },
    );
    await tester.pumpWidget(_host(HandrailAttachmentPreview.timeline(
      attachment: _messageAttachment(),
      messageId: _messageId,
      delegates: delegates,
      downloadResolver: (input, cancellationSignal) async {
        resolutions += 1;
        expect(input.attachmentId, _attachmentId);
        expect(input.messageId, _messageId);
        expect(cancellationSignal.isCancelled, isFalse);
        return ChatSnapshotQuerySuccess(_downloadResult(
          descriptor: 'opaque-download-$resolutions',
        ));
      },
    )));

    await tester.tap(find.byKey(const ValueKey('handrail-attachment-open')));
    await tester.pump();
    expect((resolutions, opens), (1, 1));
    await tester.tap(find.byKey(const ValueKey('handrail-attachment-open')));
    await tester.pump();
    expect((resolutions, opens), (2, 2));
    expect(find.textContaining('opaque-download'), findsNothing);
  });

  testWidgets(
      're-resolves after expiry and reports unavailable or failed actions',
      (tester) async {
    var resolutions = 0;
    final delegates = ChatApplicationDelegates(
      openAttachment: (_) async => ChatApplicationDelegateResult.unavailable,
    );
    await tester.pumpWidget(_host(HandrailAttachmentPreview.timeline(
      attachment: _messageAttachment(),
      messageId: _messageId,
      delegates: delegates,
      downloadResolver: (_, __) async {
        resolutions += 1;
        if (resolutions == 1) {
          // The client represents an expired descriptor as a validated query
          // failure; the widget must not retain that failed resolution.
          return const ChatSnapshotQueryMalformedResponse<
              GetAttachmentDownloadResult>();
        }
        return ChatSnapshotQuerySuccess(_downloadResult(
          descriptor: 'fresh-descriptor',
        ));
      },
    )));
    await tester.tap(find.byKey(const ValueKey('handrail-attachment-open')));
    await tester.pump();
    expect(find.text('Attachment could not be opened.'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('handrail-attachment-open')));
    await tester.pump();
    expect(resolutions, 2);
    expect(find.text('Attachment opening is unavailable.'), findsOneWidget);

    await tester.pumpWidget(_host(HandrailAttachmentPreview.timeline(
      attachment: _messageAttachment(),
      messageId: _messageId,
      delegates: ChatApplicationDelegates(
        openAttachment: (_) => Future<ChatApplicationDelegateResult>.error(
          StateError('https://provider.example/private'),
        ),
      ),
      downloadResolver: (_, __) async =>
          ChatSnapshotQuerySuccess(_downloadResult()),
    )));
    await tester.tap(find.byKey(const ValueKey('handrail-attachment-open')));
    await tester.pump();
    expect(find.text('Attachment could not be opened.'), findsOneWidget);
    expect(find.textContaining('provider.example'), findsNothing);
  });

  testWidgets('uses theme tokens and honors the attachment builder override',
      (tester) async {
    const spacing = HandrailChatSpacing(small: 19);
    const radii = HandrailChatRadii(medium: 23);
    final theme = ThemeData(
      extensions: const [
        HandrailChatTheme(spacing: spacing, radii: radii),
      ],
    );
    await tester.pumpWidget(_host(
      HandrailAttachmentPreview.timeline(
        attachment: _messageAttachment(),
        messageId: _messageId,
      ),
      theme: theme,
    ));
    final container = tester.widget<Container>(
      find.byKey(const ValueKey('handrail-attachment-preview-default')),
    );
    expect(container.padding, const EdgeInsets.all(19));
    final decoration = container.decoration! as BoxDecoration;
    expect(decoration.borderRadius, BorderRadius.circular(23));

    MessageAttachmentMetadata? built;
    await tester.pumpWidget(_host(HandrailAttachmentPreview.timeline(
      attachment: _messageAttachment(),
      messageId: _messageId,
      builders: ChatWidgetBuilders(
        attachmentPreview: (context, input) {
          built = input.attachment;
          return const Text('Company attachment');
        },
      ),
    )));
    expect(find.text('Company attachment'), findsOneWidget);
    expect(built?.attachmentId, _attachmentId);
    expect(
      find.byKey(const ValueKey('handrail-attachment-preview-default')),
      findsNothing,
    );
  });

  testWidgets('supports tap and keyboard activation with safe image semantics',
      (tester) async {
    final semantics = tester.ensureSemantics();
    var opens = 0;
    await tester.pumpWidget(_host(HandrailAttachmentPreview.timeline(
      attachment: _messageAttachment(
        contentType: 'IMAGE/PNG; charset=binary',
        altText: 'Quarterly chart',
        width: 640,
        height: 480,
      ),
      messageId: _messageId,
      delegates: ChatApplicationDelegates(
        openAttachment: (_) async {
          opens += 1;
          return ChatApplicationDelegateResult.handled;
        },
      ),
      downloadResolver: (_, __) async =>
          ChatSnapshotQuerySuccess(_downloadResult()),
    )));
    expect(
      find.bySemanticsLabel(RegExp(
        r'Quarterly chart, report\.png, image/png, 2 KB, 640 × 480 pixels',
      )),
      findsOneWidget,
    );
    expect(find.byType(Image), findsNothing);

    await tester.tap(
      find.byKey(const ValueKey('handrail-attachment-preview-activation')),
    );
    await tester.pump();
    expect(opens, 1);
    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pump();
    expect(opens, 2);
    semantics.dispose();
  });

  testWidgets('redacts descriptors URLs checksums and unsafe alt text',
      (tester) async {
    final semantics = tester.ensureSemantics();
    const secrets = [
      'https://provider.example/download?signature=secret',
      'https://provider.example/preview',
      'opaque-download-secret',
      'checksum-secret',
    ];
    await tester.pumpWidget(_host(HandrailAttachmentPreview.timeline(
      attachment: _messageAttachment(
        downloadUrl: secrets[0],
        previewUrl: secrets[1],
        altText: '${secrets[2]} ${secrets[3]}',
      ),
      messageId: _messageId,
      downloadResolver: (_, __) async =>
          ChatSnapshotQuerySuccess(_downloadResult(
        descriptor: secrets[2],
        checksum: secrets[3],
      )),
    )));
    final visibleText = tester
        .widgetList<Text>(find.byType(Text))
        .map((widget) => widget.data ?? '')
        .join(' ');
    for (final secret in secrets) {
      expect(visibleText, isNot(contains(secret)));
      expect(
        find.byWidgetPredicate((widget) {
          if (widget is! Semantics) return false;
          final properties = widget.properties;
          return [properties.label, properties.value, properties.hint]
              .whereType<String>()
              .any((value) => value.contains(secret));
        }),
        findsNothing,
      );
    }
    expect(find.bySemanticsLabel(RegExp(r'Image attachment, report.png')),
        findsOneWidget);
    expect(find.byType(Image), findsNothing);
    semantics.dispose();
  });

  testWidgets('cancels queries and revokes only widget-owned resources once',
      (tester) async {
    final first = _TemporaryResource();
    final second = _TemporaryResource();
    final hostOwned = _TemporaryResource();
    final query =
        Completer<ChatSnapshotQueryResult<GetAttachmentDownloadResult>>();
    ChatCommandCancellationSignal? signal;
    await tester.pumpWidget(_host(HandrailAttachmentPreview.timeline(
      attachment: _messageAttachment(),
      messageId: _messageId,
      temporaryPreviewResource: first,
      ownsTemporaryPreviewResource: true,
      downloadResolver: (_, cancellationSignal) {
        signal = cancellationSignal;
        return query.future;
      },
    )));
    await tester.tap(find.byKey(const ValueKey('handrail-attachment-open')));
    await tester.pump();
    expect(signal?.isCancelled, isFalse);

    await tester.pumpWidget(_host(HandrailAttachmentPreview.timeline(
      attachment: _messageAttachment(),
      messageId: _messageId,
      temporaryPreviewResource: second,
      ownsTemporaryPreviewResource: true,
    )));
    expect(first.revokeCount, 1);
    expect(signal?.isCancelled, isTrue);
    await tester.pumpWidget(_host(HandrailAttachmentPreview.timeline(
      attachment: _messageAttachment(),
      messageId: _messageId,
      temporaryPreviewResource: hostOwned,
    )));
    expect(second.revokeCount, 1);
    expect(hostOwned.revokeCount, 0);
    await tester.pumpWidget(const SizedBox.shrink());
    expect(first.revokeCount, 1);
    expect(second.revokeCount, 1);
    expect(hostOwned.revokeCount, 0);
  });
}

Widget _host(Widget child, {ThemeData? theme}) => MaterialApp(
      theme: theme,
      home: Scaffold(body: Center(child: SizedBox(width: 520, child: child))),
    );

final class _UploadHandle implements HandrailAttachmentPreviewUploadHandle {
  _UploadHandle(this.state);

  @override
  ChatAttachmentUploadState state;
  final Completer<ChatAttachmentUploadResult> _completion = Completer();
  var cancelCount = 0;

  @override
  Future<ChatAttachmentUploadResult> get completion => _completion.future;

  @override
  String get uploadId => state.uploadId;

  @override
  void cancel() => cancelCount += 1;
}

final class _TemporaryResource implements ChatAttachmentTemporaryResource {
  var revokeCount = 0;

  @override
  void revoke() => revokeCount += 1;
}

ChatAttachmentUploadState _state(
  ChatAttachmentUploadStatus status, {
  int sizeBytes = 100,
  int uploadedBytes = 0,
  AttachmentRejectionReason rejectionReason = AttachmentRejectionReason.unsafe,
}) {
  final metadata = AttachmentMetadata(
    fileName: 'report.png',
    contentType: 'image/png',
    sizeBytes: sizeBytes,
  );
  AttachmentLifecycleState? lifecycle;
  MessageAttachmentMetadata? messageAttachment;
  switch (status) {
    case ChatAttachmentUploadStatus.pending:
    case ChatAttachmentUploadStatus.uploading:
    case ChatAttachmentUploadStatus.finalizing:
      lifecycle = PendingAttachmentState(
        attachmentId: _attachmentId,
        metadata: metadata,
        createdAt: _createdAt,
        expiresAt: _expiresAt,
      );
    case ChatAttachmentUploadStatus.finalized:
      lifecycle = FinalizedAttachmentState(
        attachmentId: _attachmentId,
        metadata: metadata,
        createdAt: _createdAt,
        expiresAt: _expiresAt,
        checksum: 'sha256:${'a' * 64}',
        finalizedAt: _settledAt,
      );
    case ChatAttachmentUploadStatus.attached:
      lifecycle = AttachedAttachmentState(
        attachmentId: _attachmentId,
        metadata: metadata,
        createdAt: _createdAt,
        expiresAt: _expiresAt,
        messageId: _messageId,
        checksum: 'sha256:${'a' * 64}',
        attachedAt: _settledAt,
      );
      messageAttachment = _messageAttachment(sizeBytes: sizeBytes);
    case ChatAttachmentUploadStatus.rejected:
      lifecycle = RejectedAttachmentState(
        attachmentId: _attachmentId,
        metadata: metadata,
        createdAt: _createdAt,
        expiresAt: _expiresAt,
        rejectionReason: rejectionReason,
        rejectedAt: _settledAt,
      );
    case ChatAttachmentUploadStatus.abandoned:
      lifecycle = AbandonedAttachmentState(
        attachmentId: _attachmentId,
        metadata: metadata,
        createdAt: _createdAt,
        expiresAt: _expiresAt,
        abandonedAt: _settledAt,
      );
    case ChatAttachmentUploadStatus.preparing:
    case ChatAttachmentUploadStatus.failed:
    case ChatAttachmentUploadStatus.cancelled:
      break;
  }
  return ChatAttachmentUploadState(
    uploadId: 'upload-preview',
    conversationId: _conversationId,
    metadata: metadata,
    status: status,
    uploadedBytes: uploadedBytes,
    attachment: lifecycle,
    messageAttachment: messageAttachment,
  );
}

MessageAttachmentMetadata _messageAttachment({
  String contentType = 'image/png',
  int sizeBytes = 2048,
  String downloadUrl = 'https://transport.invalid/download',
  String? previewUrl = 'https://transport.invalid/preview',
  int? width,
  int? height,
  String? altText,
}) =>
    MessageAttachmentMetadata(
      attachmentId: _attachmentId,
      fileName: 'report.png',
      contentType: contentType,
      sizeBytes: sizeBytes,
      downloadUrl: downloadUrl,
      previewUrl: previewUrl,
      width: width,
      height: height,
      altText: altText,
    );

GetAttachmentDownloadResult _downloadResult({
  String descriptor = 'opaque-download',
  String checksum =
      'sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
}) {
  final metadata = AttachmentMetadata(
    fileName: 'report.png',
    contentType: 'image/png',
    sizeBytes: 2048,
  );
  return GetAttachmentDownloadResult(
    attachmentId: _attachmentId,
    messageId: _messageId,
    attachment: AttachedAttachmentState(
      attachmentId: _attachmentId,
      metadata: metadata,
      createdAt: _createdAt,
      expiresAt: _expiresAt,
      messageId: _messageId,
      checksum: checksum,
      attachedAt: _settledAt,
    ),
    download: AttachmentDownloadDescriptor(
      descriptor: descriptor,
      expiresAt: _expiresAt,
    ),
  );
}
