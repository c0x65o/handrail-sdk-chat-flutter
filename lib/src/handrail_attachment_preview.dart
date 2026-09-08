import 'dart:async';
import 'dart:collection';

import 'package:flutter/material.dart';

import '../core.dart';
import 'chat_application_delegates.dart';
import 'chat_widget_builders.dart';
import 'handrail_chat_theme.dart';

/// The upload-handle surface consumed by [HandrailAttachmentPreview.active].
///
/// The production [HandrailAttachmentPreview.upload] constructor adapts a
/// [ChatAttachmentUploadHandle]. This interface also lets a host retain the
/// same public, descriptor-free state contract when it wraps an upload.
abstract interface class HandrailAttachmentPreviewUploadHandle {
  String get uploadId;
  ChatAttachmentUploadState get state;
  Future<ChatAttachmentUploadResult> get completion;
  void cancel();
}

/// Resolves a fresh, validated descriptor for one attachment activation.
///
/// The preview never retains or renders the returned descriptor. The
/// cancellation signal is cancelled when the widget is replaced or disposed.
typedef ChatAttachmentDownloadResolver
    = Future<ChatSnapshotQueryResult<GetAttachmentDownloadResult>> Function(
  GetAttachmentDownloadInput input,
  ChatCommandCancellationSignal cancellationSignal,
);

/// An optional attachment card for canonical timeline metadata or an upload.
///
/// Remote image URLs are intentionally not loaded. Hosts remain responsible
/// for opening or downloading an attachment through [delegates]. A temporary
/// resource is revoked only when [ownsTemporaryPreviewResource] is true; upload
/// managers and hosts must not transfer an already-owned resource to the
/// widget.
final class HandrailAttachmentPreview extends StatefulWidget {
  const HandrailAttachmentPreview.timeline({
    required this.attachment,
    required this.messageId,
    this.client,
    this.downloadResolver,
    this.delegates = const ChatApplicationDelegates(),
    this.builders = const ChatWidgetBuilders(),
    this.onRetry,
    this.temporaryPreviewResource,
    this.ownsTemporaryPreviewResource = false,
    this.uploadPollInterval = const Duration(milliseconds: 100),
    super.key,
  }) : upload = null;

  /// Displays a production upload handle using only its public state/actions.
  factory HandrailAttachmentPreview.upload({
    required ChatAttachmentUploadHandle upload,
    HandrailChatClient? client,
    ChatAttachmentDownloadResolver? downloadResolver,
    ChatApplicationDelegates delegates = const ChatApplicationDelegates(),
    ChatWidgetBuilders builders = const ChatWidgetBuilders(),
    FutureOr<void> Function()? onRetry,
    ChatAttachmentTemporaryResource? temporaryPreviewResource,
    bool ownsTemporaryPreviewResource = false,
    Duration uploadPollInterval = const Duration(milliseconds: 100),
    Key? key,
  }) {
    return HandrailAttachmentPreview.active(
      upload: _CoreAttachmentPreviewUploadHandle(upload),
      client: client,
      downloadResolver: downloadResolver,
      delegates: delegates,
      builders: builders,
      onRetry: onRetry,
      temporaryPreviewResource: temporaryPreviewResource,
      ownsTemporaryPreviewResource: ownsTemporaryPreviewResource,
      uploadPollInterval: uploadPollInterval,
      key: key,
    );
  }

  /// Displays a descriptor-free public upload-handle-compatible contract.
  const HandrailAttachmentPreview.active({
    required HandrailAttachmentPreviewUploadHandle this.upload,
    this.client,
    this.downloadResolver,
    this.delegates = const ChatApplicationDelegates(),
    this.builders = const ChatWidgetBuilders(),
    this.onRetry,
    this.temporaryPreviewResource,
    this.ownsTemporaryPreviewResource = false,
    this.uploadPollInterval = const Duration(milliseconds: 100),
    super.key,
  })  : assert(uploadPollInterval > Duration.zero),
        attachment = null,
        messageId = null;

  final MessageAttachmentMetadata? attachment;
  final MessageId? messageId;
  final HandrailAttachmentPreviewUploadHandle? upload;
  final HandrailChatClient? client;
  final ChatAttachmentDownloadResolver? downloadResolver;
  final ChatApplicationDelegates delegates;
  final ChatWidgetBuilders builders;

  /// Shown for an unsuccessful settled upload only when supplied.
  final FutureOr<void> Function()? onRetry;

  final ChatAttachmentTemporaryResource? temporaryPreviewResource;

  /// Whether this widget alone owns [temporaryPreviewResource].
  final bool ownsTemporaryPreviewResource;
  final Duration uploadPollInterval;

  @override
  State<HandrailAttachmentPreview> createState() =>
      HandrailAttachmentPreviewState();
}

/// Public state type for focused activation and lifecycle tests.
final class HandrailAttachmentPreviewState
    extends State<HandrailAttachmentPreview> {
  final Set<ChatAttachmentTemporaryResource> _revokedResources =
      HashSet<ChatAttachmentTemporaryResource>.identity();
  ChatAttachmentUploadState? _uploadState;
  Timer? _pollTimer;
  ChatCommandCancellationController? _downloadCancellation;
  String? _actionMessage;
  var _uploadGeneration = 0;
  var _downloadGeneration = 0;
  var _activating = false;
  var _disposed = false;

  @override
  void initState() {
    super.initState();
    _bindUpload();
  }

  @override
  void didUpdateWidget(covariant HandrailAttachmentPreview oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(
      oldWidget.temporaryPreviewResource,
      widget.temporaryPreviewResource,
    )) {
      _revokeOwnedResource(oldWidget);
    }
    if (!identical(oldWidget.upload, widget.upload)) {
      _bindUpload();
    }
    if (oldWidget.attachment != widget.attachment ||
        oldWidget.messageId != widget.messageId ||
        !identical(oldWidget.client, widget.client) ||
        !identical(oldWidget.downloadResolver, widget.downloadResolver)) {
      _cancelDownload();
      _actionMessage = null;
      _activating = false;
    }
  }

  void _bindUpload() {
    _uploadGeneration += 1;
    _pollTimer?.cancel();
    _pollTimer = null;
    _uploadState = _readUploadState();
    final upload = widget.upload;
    if (upload == null) return;
    final generation = _uploadGeneration;
    _pollTimer = Timer.periodic(widget.uploadPollInterval, (_) {
      if (_disposed || generation != _uploadGeneration) return;
      final next = _readUploadState();
      if (next == null) return;
      if (mounted) setState(() => _uploadState = next);
      if (!_isActive(next.status)) {
        _pollTimer?.cancel();
        _pollTimer = null;
      }
    });
    unawaited(_observeCompletion(upload, generation));
  }

  ChatAttachmentUploadState? _readUploadState() {
    try {
      return widget.upload?.state;
    } catch (_) {
      return _uploadState;
    }
  }

  Future<void> _observeCompletion(
    HandrailAttachmentPreviewUploadHandle upload,
    int generation,
  ) async {
    ChatAttachmentUploadResult result;
    try {
      result = await upload.completion;
    } catch (_) {
      if (!_canApply(generation)) return;
      setState(() => _actionMessage = 'Attachment upload failed.');
      return;
    }
    if (!_canApply(generation)) return;
    final current = _readUploadState();
    setState(() {
      _uploadState = current ?? _settledState(result, _uploadState);
      _pollTimer?.cancel();
      _pollTimer = null;
    });
  }

  bool _canApply(int generation) =>
      !_disposed && mounted && generation == _uploadGeneration;

  bool _canApplyDownload(int generation) =>
      !_disposed && mounted && generation == _downloadGeneration;

  ChatAttachmentUploadState? _settledState(
    ChatAttachmentUploadResult result,
    ChatAttachmentUploadState? previous,
  ) {
    if (previous == null) return null;
    return switch (result) {
      ChatAttachmentUploadFinalized(:final attachment) =>
        ChatAttachmentUploadState(
          uploadId: previous.uploadId,
          conversationId: previous.conversationId,
          metadata: previous.metadata,
          status: ChatAttachmentUploadStatus.finalized,
          uploadedBytes: previous.metadata.sizeBytes,
          attachment: attachment,
        ),
      ChatAttachmentUploadRejected(:final attachment) =>
        ChatAttachmentUploadState(
          uploadId: previous.uploadId,
          conversationId: previous.conversationId,
          metadata: previous.metadata,
          status: ChatAttachmentUploadStatus.rejected,
          uploadedBytes: previous.uploadedBytes,
          attachment: attachment,
        ),
      ChatAttachmentUploadCancelled() => ChatAttachmentUploadState(
          uploadId: previous.uploadId,
          conversationId: previous.conversationId,
          metadata: previous.metadata,
          status: ChatAttachmentUploadStatus.cancelled,
          uploadedBytes: previous.uploadedBytes,
        ),
      ChatAttachmentUploadFailed() => ChatAttachmentUploadState(
          uploadId: previous.uploadId,
          conversationId: previous.conversationId,
          metadata: previous.metadata,
          status: ChatAttachmentUploadStatus.failed,
          uploadedBytes: previous.uploadedBytes,
        ),
    };
  }

  Future<void> _activate() async {
    if (_activating) return;
    final attachment = _messageAttachment;
    final messageId = _resolvedMessageId;
    if (attachment == null || messageId == null) return;
    final generation = ++_downloadGeneration;
    _cancelDownload(incrementGeneration: false);
    final cancellation = ChatCommandCancellationController();
    _downloadCancellation = cancellation;
    setState(() {
      _activating = true;
      _actionMessage = null;
    });

    ChatSnapshotQueryResult<GetAttachmentDownloadResult> resolution;
    try {
      final resolver = widget.downloadResolver;
      final client = widget.client;
      if (resolver != null) {
        resolution = await resolver(
          GetAttachmentDownloadInput(
            attachmentId: attachment.attachmentId,
            messageId: messageId,
          ),
          cancellation.signal,
        );
      } else if (client != null) {
        resolution = await client.getAttachmentDownload(
          GetAttachmentDownloadInput(
            attachmentId: attachment.attachmentId,
            messageId: messageId,
          ),
          options: ChatSnapshotQueryOptions(
            cancellationSignal: cancellation.signal,
          ),
        );
      } else {
        if (_canApplyDownload(generation)) {
          setState(() {
            _activating = false;
            _actionMessage = 'Attachment opening is unavailable.';
          });
        }
        return;
      }
    } catch (_) {
      if (_canApplyDownload(generation)) {
        setState(() {
          _activating = false;
          _actionMessage = 'Attachment could not be opened.';
        });
      }
      return;
    }
    if (!_canApplyDownload(generation)) return;
    if (resolution case ChatSnapshotQuerySuccess(:final value)
        when value.attachmentId == attachment.attachmentId &&
            value.messageId == messageId) {
      try {
        final delegateResult =
            await widget.delegates.openAttachment(attachment);
        if (!_canApplyDownload(generation)) return;
        setState(() {
          _activating = false;
          _actionMessage = switch (delegateResult) {
            ChatApplicationDelegateResult.handled => null,
            ChatApplicationDelegateResult.cancelled =>
              'Attachment opening was cancelled.',
            ChatApplicationDelegateResult.unavailable =>
              'Attachment opening is unavailable.',
          };
        });
      } catch (_) {
        if (_canApplyDownload(generation)) {
          setState(() {
            _activating = false;
            _actionMessage = 'Attachment could not be opened.';
          });
        }
      }
    } else {
      setState(() {
        _activating = false;
        _actionMessage = 'Attachment could not be opened.';
      });
    }
  }

  Future<void> _retry() async {
    final retry = widget.onRetry;
    if (retry == null) return;
    setState(() => _actionMessage = null);
    try {
      await retry();
    } catch (_) {
      if (!_disposed && mounted) {
        setState(() => _actionMessage = 'Attachment retry failed.');
      }
    }
  }

  void _cancelUpload() {
    try {
      widget.upload?.cancel();
    } catch (_) {
      setState(() => _actionMessage = 'Attachment cancellation failed.');
    }
  }

  MessageAttachmentMetadata? get _messageAttachment =>
      widget.attachment ?? _uploadState?.messageAttachment;

  MessageId? get _resolvedMessageId {
    final explicit = widget.messageId;
    if (explicit != null) return explicit;
    final lifecycle = _uploadState?.attachment;
    return lifecycle is AttachedAttachmentState ? lifecycle.messageId : null;
  }

  AttachmentMetadata? get _uploadMetadata => _uploadState?.metadata;

  bool get _canOpen => _messageAttachment != null && _resolvedMessageId != null;

  @override
  Widget build(BuildContext context) {
    final attachment = _messageAttachment;
    final metadata = _uploadMetadata;
    if (attachment == null && metadata == null) {
      return const SizedBox.shrink();
    }
    final fileName = _safeFileName(
      attachment?.fileName ?? metadata!.fileName,
    );
    final contentType = _normalizedContentType(
      attachment?.contentType ?? metadata!.contentType,
    );
    final sizeBytes = attachment?.sizeBytes ?? metadata!.sizeBytes;
    final image = contentType.startsWith('image/');
    final state = _uploadState;
    final status = state?.status;
    final statusText = status == null ? 'Attached' : _statusText(state!);
    final progress =
        state == null || !_isActive(state.status) ? null : _progress(state);
    final dimensions = _dimensions(attachment);
    final safeAlt = image ? _safeAltText(attachment?.altText) : null;
    final semanticsLabel = [
      image ? (safeAlt ?? 'Image attachment') : 'Attachment',
      fileName,
      contentType,
      _formatSize(sizeBytes),
      if (dimensions != null) dimensions,
    ].join(', ');
    final semanticsValue = [
      statusText,
      if (state != null && _isActive(state.status))
        state.metadata.sizeBytes == 0
            ? 'Progress indeterminate'
            : '${(progress! * 100).round()} percent',
    ].join(', ');

    Widget contents;
    if (attachment != null &&
        widget.builders.attachmentPreview !=
            defaultChatAttachmentPreviewBuilder) {
      contents = widget.builders.attachmentPreview(
        context,
        ChatAttachmentPreviewBuilderInput(attachment: attachment),
      );
    } else {
      contents = _buildDefaultContents(
        context,
        fileName: fileName,
        contentType: contentType,
        sizeBytes: sizeBytes,
        image: image,
        dimensions: dimensions,
        statusText: statusText,
        state: state,
        progress: progress,
      );
    }

    final card = Semantics(
      container: true,
      button: _canOpen,
      enabled: !_activating,
      label: semanticsLabel,
      value: semanticsValue,
      onTap: _canOpen ? _activate : null,
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          key: const ValueKey('handrail-attachment-preview-activation'),
          onTap: _canOpen && !_activating ? _activate : null,
          child: contents,
        ),
      ),
    );
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        card,
        if (_activating)
          const LinearProgressIndicator(
            key: ValueKey('handrail-attachment-opening-progress'),
          ),
        if (_actionMessage case final message?)
          Text(
            message,
            key: const ValueKey('handrail-attachment-action-message'),
          ),
      ],
    );
  }

  Widget _buildDefaultContents(
    BuildContext context, {
    required String fileName,
    required String contentType,
    required int sizeBytes,
    required bool image,
    required String? dimensions,
    required String statusText,
    required ChatAttachmentUploadState? state,
    required double? progress,
  }) {
    final tokens = HandrailChatTheme.of(context);
    final colors = Theme.of(context).colorScheme;
    final status = state?.status;
    final cancellable = status != null && _isActive(status);
    final retryable =
        status != null && _isUnsuccessful(status) && widget.onRetry != null;
    return Container(
      key: const ValueKey('handrail-attachment-preview-default'),
      padding: EdgeInsets.all(tokens.spacing.small),
      decoration: BoxDecoration(
        color: colors.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(tokens.radii.medium),
        border: Border.all(
          color: tokens.messageBubbleStyle.borderColor,
          width: tokens.messageBubbleStyle.borderWidth,
        ),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(image ? Icons.image_outlined : Icons.attach_file),
          SizedBox(width: tokens.spacing.small),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(fileName, style: tokens.typography.message),
                Text(
                  [
                    contentType,
                    _formatSize(sizeBytes),
                    if (dimensions != null) dimensions,
                  ].join(' • '),
                  style: tokens.typography.metadata,
                ),
                Text(statusText, style: tokens.typography.metadata),
                if (state != null && _isActive(state.status))
                  Padding(
                    padding: EdgeInsets.only(top: tokens.spacing.extraSmall),
                    child: LinearProgressIndicator(
                      key: const ValueKey('handrail-attachment-progress'),
                      value: progress,
                    ),
                  ),
              ],
            ),
          ),
          if (cancellable)
            IconButton(
              key: const ValueKey('handrail-attachment-cancel'),
              tooltip: 'Cancel attachment upload',
              onPressed: _cancelUpload,
              icon: const Icon(Icons.close),
            ),
          if (retryable)
            TextButton(
              key: const ValueKey('handrail-attachment-retry'),
              onPressed: _retry,
              child: const Text('Retry'),
            ),
          if (_canOpen)
            IconButton(
              key: const ValueKey('handrail-attachment-open'),
              tooltip: 'Open attachment',
              onPressed: _activating ? null : _activate,
              icon: const Icon(Icons.open_in_new),
            ),
        ],
      ),
    );
  }

  void _cancelDownload({bool incrementGeneration = true}) {
    if (incrementGeneration) _downloadGeneration += 1;
    _downloadCancellation?.cancel();
    _downloadCancellation = null;
  }

  void _revokeOwnedResource(HandrailAttachmentPreview owner) {
    final resource = owner.temporaryPreviewResource;
    if (!owner.ownsTemporaryPreviewResource || resource == null) return;
    if (_revokedResources.add(resource)) resource.revoke();
  }

  @override
  void dispose() {
    _disposed = true;
    _uploadGeneration += 1;
    _downloadGeneration += 1;
    _pollTimer?.cancel();
    _pollTimer = null;
    _cancelDownload(incrementGeneration: false);
    _revokeOwnedResource(widget);
    super.dispose();
  }
}

final class _CoreAttachmentPreviewUploadHandle
    implements HandrailAttachmentPreviewUploadHandle {
  const _CoreAttachmentPreviewUploadHandle(this._handle);

  final ChatAttachmentUploadHandle _handle;

  @override
  Future<ChatAttachmentUploadResult> get completion => _handle.completion;

  @override
  ChatAttachmentUploadState get state => _handle.state;

  @override
  String get uploadId => _handle.uploadId;

  @override
  void cancel() => _handle.cancel();
}

bool _isActive(ChatAttachmentUploadStatus status) => switch (status) {
      ChatAttachmentUploadStatus.preparing ||
      ChatAttachmentUploadStatus.pending ||
      ChatAttachmentUploadStatus.uploading ||
      ChatAttachmentUploadStatus.finalizing =>
        true,
      _ => false,
    };

bool _isUnsuccessful(ChatAttachmentUploadStatus status) => switch (status) {
      ChatAttachmentUploadStatus.rejected ||
      ChatAttachmentUploadStatus.abandoned ||
      ChatAttachmentUploadStatus.failed ||
      ChatAttachmentUploadStatus.cancelled =>
        true,
      _ => false,
    };

double? _progress(ChatAttachmentUploadState state) {
  final total = state.metadata.sizeBytes;
  if (total <= 0) return null;
  return (state.uploadedBytes / total).clamp(0.0, 1.0).toDouble();
}

String _statusText(ChatAttachmentUploadState state) => switch (state.status) {
      ChatAttachmentUploadStatus.preparing => 'Preparing',
      ChatAttachmentUploadStatus.pending => 'Pending',
      ChatAttachmentUploadStatus.uploading => 'Uploading',
      ChatAttachmentUploadStatus.finalizing => 'Finalizing',
      ChatAttachmentUploadStatus.finalized => 'Finalized',
      ChatAttachmentUploadStatus.attached => 'Attached',
      ChatAttachmentUploadStatus.rejected =>
        'Rejected: ${_rejectionText(state.attachment)}',
      ChatAttachmentUploadStatus.abandoned => 'Abandoned',
      ChatAttachmentUploadStatus.failed => 'Failed',
      ChatAttachmentUploadStatus.cancelled => 'Cancelled',
    };

String _rejectionText(AttachmentLifecycleState? lifecycle) {
  final reason =
      lifecycle is RejectedAttachmentState ? lifecycle.rejectionReason : null;
  return switch (reason) {
    AttachmentRejectionReason.missingObject => 'File was not received',
    AttachmentRejectionReason.sizeMismatch => 'File size did not match',
    AttachmentRejectionReason.checksumMismatch => 'File integrity check failed',
    AttachmentRejectionReason.contentTypeMismatch => 'File type did not match',
    AttachmentRejectionReason.unsafe => 'File was unsafe',
    AttachmentRejectionReason.scanFailed => 'File scan failed',
    AttachmentRejectionReason.invalidMetadata => 'File details were invalid',
    null => 'File was not accepted',
  };
}

String _safeFileName(String value) {
  final trimmed = value.trim();
  if (trimmed.isEmpty ||
      trimmed.startsWith('.') ||
      trimmed.endsWith('.') ||
      RegExp(r'[\x00-\x1f\x7f<>:"/\\|?*]').hasMatch(trimmed) ||
      _looksSensitive(trimmed)) {
    return 'Attachment';
  }
  return trimmed;
}

String _normalizedContentType(String value) {
  final normalized = value.trim().toLowerCase().split(';').first.trim();
  return RegExp(r'^[a-z0-9][a-z0-9!#$&^_.+-]*/[a-z0-9][a-z0-9!#$&^_.+-]*$')
          .hasMatch(normalized)
      ? normalized
      : 'application/octet-stream';
}

String? _safeAltText(String? value) {
  final trimmed = value?.trim();
  if (trimmed == null || trimmed.isEmpty || _looksSensitive(trimmed)) {
    return null;
  }
  return trimmed;
}

bool _looksSensitive(String value) {
  final lower = value.toLowerCase();
  return lower.contains('://') ||
      lower.contains('www.') ||
      lower.contains('opaque_') ||
      lower.contains('descriptor') ||
      lower.contains('checksum') ||
      lower.contains('signedurl') ||
      lower.contains('signature=');
}

String? _dimensions(MessageAttachmentMetadata? attachment) {
  final width = attachment?.width;
  final height = attachment?.height;
  return width == null || height == null ? null : '$width × $height pixels';
}

String _formatSize(int bytes) {
  if (bytes < 1024) return '$bytes B';
  const units = ['KB', 'MB', 'GB'];
  var value = bytes / 1024;
  var unit = 0;
  while (value >= 1024 && unit < units.length - 1) {
    value /= 1024;
    unit += 1;
  }
  final precision = value >= 10 || value == value.roundToDouble() ? 0 : 1;
  return '${value.toStringAsFixed(precision)} ${units[unit]}';
}
