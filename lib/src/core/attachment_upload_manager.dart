import 'dart:async';
import 'dart:typed_data';

import '../generated/attachment_transport.dart';
import '../generated/identifiers.dart';
import 'command_dispatcher.dart';
import 'normalized_snapshot_state.dart';

/// The transfer boundary receives only opaque upload instructions and bytes.
/// It never receives chat bearer credentials or authenticated HTTP headers.
abstract interface class ChatAttachmentByteTransferTransport {
  Future<ChatAttachmentByteTransferResult> transfer(
    ChatAttachmentByteTransferRequest request,
  );
}

/// One provider-neutral byte transfer request.
final class ChatAttachmentByteTransferRequest {
  const ChatAttachmentByteTransferRequest({
    required this.upload,
    required this.source,
    required this.metadata,
    required this.cancellationSignal,
    required this.onProgress,
  });

  final AttachmentUploadDescriptor upload;
  final Stream<List<int>> source;
  final AttachmentMetadata metadata;
  final ChatCommandCancellationSignal cancellationSignal;

  /// Reports cumulative uploaded bytes. The manager clamps this callback.
  final void Function(int uploadedBytes) onProgress;

  @override
  String toString() => 'ChatAttachmentByteTransferRequest('
      'sizeBytes: ${metadata.sizeBytes})';
}

enum ChatAttachmentTransferRetrySafety { safe, never }

sealed class ChatAttachmentByteTransferResult {
  const ChatAttachmentByteTransferResult();
}

final class ChatAttachmentBytesUploaded
    extends ChatAttachmentByteTransferResult {
  const ChatAttachmentBytesUploaded();
}

final class ChatAttachmentByteTransferFailed
    extends ChatAttachmentByteTransferResult {
  const ChatAttachmentByteTransferFailed({
    this.retrySafety = ChatAttachmentTransferRetrySafety.never,
  });

  final ChatAttachmentTransferRetrySafety retrySafety;
}

abstract interface class ChatAttachmentTemporaryResource {
  void revoke();
}

final class ChatAttachmentUploadInput {
  const ChatAttachmentUploadInput({
    required this.conversationId,
    required this.metadata,
    required this.source,
    this.cancellationSignal,
    this.temporaryResource,
  });

  final ConversationId conversationId;
  final AttachmentMetadata metadata;

  /// One finite byte stream. It is buffered and size-validated before prepare,
  /// allowing an explicitly safe transfer attempt to receive a fresh replay.
  final Stream<List<int>> source;
  final ChatCommandCancellationSignal? cancellationSignal;
  final ChatAttachmentTemporaryResource? temporaryResource;
}

enum ChatAttachmentUploadFailurePhase { prepare, transfer, finalize, abort }

sealed class ChatAttachmentUploadResult {
  const ChatAttachmentUploadResult();
  String get status;
}

final class ChatAttachmentUploadFinalized extends ChatAttachmentUploadResult {
  const ChatAttachmentUploadFinalized(this.attachment);
  final FinalizedAttachmentState attachment;
  @override
  String get status => 'finalized';
}

final class ChatAttachmentUploadRejected extends ChatAttachmentUploadResult {
  const ChatAttachmentUploadRejected(this.attachment);
  final RejectedAttachmentState attachment;
  @override
  String get status => 'rejected';
}

final class ChatAttachmentUploadCancelled extends ChatAttachmentUploadResult {
  const ChatAttachmentUploadCancelled();
  @override
  String get status => 'cancelled';
}

final class ChatAttachmentUploadFailed extends ChatAttachmentUploadResult {
  const ChatAttachmentUploadFailed(this.phase);
  final ChatAttachmentUploadFailurePhase phase;
  @override
  String get status => 'failed';
}

final class ChatAttachmentUploadHandle {
  const ChatAttachmentUploadHandle._({
    required this.uploadId,
    required this.completion,
    required ChatAttachmentUploadState Function() state,
    required void Function() cancel,
  })  : _state = state,
        _cancel = cancel;

  final String uploadId;
  final Future<ChatAttachmentUploadResult> completion;
  final ChatAttachmentUploadState Function() _state;
  final void Function() _cancel;

  ChatAttachmentUploadState get state => _state();
  void cancel() => _cancel();
}

typedef ChatAttachmentUploadIdGenerator = String Function();
typedef ChatAttachmentUploadIdempotencyKeyGenerator = String Function(
  ChatAttachmentUploadFailurePhase phase,
  String uploadId,
);

final class ChatAttachmentUploadOptions {
  const ChatAttachmentUploadOptions({
    this.maxSafeTransferAttempts = 2,
    this.cleanupTimeout = const Duration(seconds: 1),
  });

  final int maxSafeTransferAttempts;
  final Duration cleanupTimeout;
}

/// Pure-Dart prepare-transfer-finalize attachment runtime.
final class ChatAttachmentUploadManager {
  ChatAttachmentUploadManager({
    required ChatCommandDispatcher commandDispatcher,
    required NormalizedSnapshotStore normalizedState,
    required ChatAttachmentByteTransferTransport transferTransport,
    required ChatAttachmentUploadIdGenerator generateUploadId,
    required ChatAttachmentUploadIdempotencyKeyGenerator generateIdempotencyKey,
    ChatAttachmentUploadOptions options = const ChatAttachmentUploadOptions(),
  })  : _commandDispatcher = commandDispatcher,
        _normalizedState = normalizedState,
        _transferTransport = transferTransport,
        _generateUploadId = generateUploadId,
        _generateIdempotencyKey = generateIdempotencyKey,
        _options = options {
    if (options.maxSafeTransferAttempts < 1 ||
        options.maxSafeTransferAttempts > 5) {
      throw ArgumentError.value(
        options.maxSafeTransferAttempts,
        'options.maxSafeTransferAttempts',
        'must be from 1 to 5',
      );
    }
    if (options.cleanupTimeout <= Duration.zero ||
        options.cleanupTimeout > const Duration(seconds: 10)) {
      throw ArgumentError.value(
        options.cleanupTimeout,
        'options.cleanupTimeout',
        'must be greater than zero and at most ten seconds',
      );
    }
  }

  final ChatCommandDispatcher _commandDispatcher;
  final NormalizedSnapshotStore _normalizedState;
  final ChatAttachmentByteTransferTransport _transferTransport;
  final ChatAttachmentUploadIdGenerator _generateUploadId;
  final ChatAttachmentUploadIdempotencyKeyGenerator _generateIdempotencyKey;
  final ChatAttachmentUploadOptions _options;
  final Map<String, _ActiveAttachmentUpload> _active = {};
  bool _closed = false;

  ChatAttachmentUploadHandle upload(ChatAttachmentUploadInput input) {
    if (_closed) throw StateError('The attachment upload manager is closed.');
    final metadata = AttachmentMetadata.fromJson(input.metadata.toJson());
    final uploadId = _generateUploadId();
    if (uploadId.trim().isEmpty || _active.containsKey(uploadId)) {
      throw StateError('The attachment upload identity is invalid.');
    }
    late final String prepareKey;
    late final String finalizeKey;
    late final String abortKey;
    try {
      prepareKey = _generateIdempotencyKey(
        ChatAttachmentUploadFailurePhase.prepare,
        uploadId,
      );
      finalizeKey = _generateIdempotencyKey(
        ChatAttachmentUploadFailurePhase.finalize,
        uploadId,
      );
      abortKey = _generateIdempotencyKey(
        ChatAttachmentUploadFailurePhase.abort,
        uploadId,
      );
      // Reuse command validation's closed idempotency-key grammar before any
      // transport or source access.
      for (final key in [prepareKey, finalizeKey, abortKey]) {
        if (!RegExp(r'^[A-Za-z0-9][A-Za-z0-9._:-]{0,199}$').hasMatch(key)) {
          throw const FormatException();
        }
      }
    } catch (_) {
      throw StateError('Attachment upload identity generation failed.');
    }

    final record = _ActiveAttachmentUpload(
      uploadId: uploadId,
      input: input,
      metadata: metadata,
      prepareKey: prepareKey,
      finalizeKey: finalizeKey,
      abortKey: abortKey,
    );
    _active[uploadId] = record;
    _setState(record, ChatAttachmentUploadStatus.preparing);
    final callerSignal = input.cancellationSignal;
    if (callerSignal != null) {
      record.callerCancellation = callerSignal.onCancelled.listen((_) {
        record.controller.cancel();
      });
      if (callerSignal.isCancelled) record.controller.cancel();
    }
    final completion = _run(record).whenComplete(() async {
      await record.callerCancellation?.cancel();
      record.transferSettled = true;
      record.bytes = null;
      _revokeResource(record);
      _active.remove(uploadId);
    });
    record.completion = completion;
    return ChatAttachmentUploadHandle._(
      uploadId: uploadId,
      completion: completion,
      state: () => _normalizedState.state.attachmentUploads[uploadId]!,
      cancel: record.controller.cancel,
    );
  }

  Future<void> closeActive() async {
    if (_closed && _active.isEmpty) return;
    _closed = true;
    final completions = <Future<ChatAttachmentUploadResult>>[];
    for (final record in _active.values.toList(growable: false)) {
      record.controller.cancel();
      if (record.completion case final completion?) {
        completions.add(completion);
      }
    }
    if (completions.isNotEmpty) {
      await Future.wait(completions);
    }
  }

  Future<ChatAttachmentUploadResult> _run(
    _ActiveAttachmentUpload record,
  ) async {
    try {
      if (record.controller.signal.isCancelled) {
        _setState(record, ChatAttachmentUploadStatus.cancelled);
        return const ChatAttachmentUploadCancelled();
      }

      try {
        record.bytes = await _readAndValidateSource(record);
      } catch (_) {
        final cancelled = record.controller.signal.isCancelled;
        _setState(
          record,
          cancelled
              ? ChatAttachmentUploadStatus.cancelled
              : ChatAttachmentUploadStatus.failed,
        );
        return cancelled
            ? const ChatAttachmentUploadCancelled()
            : const ChatAttachmentUploadFailed(
                ChatAttachmentUploadFailurePhase.prepare,
              );
      }

      final prepareInput = PrepareAttachmentInput.fromJson({
        'operation': 'prepare_attachment',
        'metadata': record.metadata.toJson(),
        'idempotencyKey': record.prepareKey,
      });
      final prepared = await _commandDispatcher.dispatch(
        _prepareDescriptor(record.input.conversationId, prepareInput),
        prepareInput,
        options: ChatCommandDispatchOptions(
          idempotencyKey: record.prepareKey,
          cancellationSignal: record.controller.signal,
        ),
      );
      if (prepared is! ChatCommandSuccess<PrepareAttachmentResult>) {
        final cancelled = record.controller.signal.isCancelled;
        _setState(
          record,
          cancelled
              ? ChatAttachmentUploadStatus.cancelled
              : ChatAttachmentUploadStatus.failed,
        );
        return cancelled
            ? const ChatAttachmentUploadCancelled()
            : const ChatAttachmentUploadFailed(
                ChatAttachmentUploadFailurePhase.prepare,
              );
      }
      record.pending = prepared.value.attachment;
      record.upload = prepared.value.upload;
      _setState(
        record,
        ChatAttachmentUploadStatus.pending,
        attachment: record.pending,
      );
      if (record.controller.signal.isCancelled) {
        await _abortPrepared(record);
        return const ChatAttachmentUploadCancelled();
      }

      _setState(
        record,
        ChatAttachmentUploadStatus.uploading,
        attachment: record.pending,
      );
      var transferred = false;
      for (var attempt = 1;
          attempt <= _options.maxSafeTransferAttempts;
          attempt += 1) {
        ChatAttachmentByteTransferResult outcome;
        try {
          outcome = await _raceWithCancellation(
            _transferTransport.transfer(
              ChatAttachmentByteTransferRequest(
                upload: record.upload!,
                source: Stream<List<int>>.value(record.bytes!),
                metadata: record.metadata,
                cancellationSignal: record.controller.signal,
                onProgress: (uploadedBytes) {
                  if (record.transferSettled ||
                      record.controller.signal.isCancelled) {
                    return;
                  }
                  final clamped =
                      uploadedBytes.clamp(0, record.metadata.sizeBytes).toInt();
                  if (clamped <= record.uploadedBytes) return;
                  record.uploadedBytes = clamped;
                  _setState(
                    record,
                    ChatAttachmentUploadStatus.uploading,
                    attachment: record.pending,
                  );
                },
              ),
            ),
            record.controller.signal,
          );
        } catch (_) {
          outcome = const ChatAttachmentByteTransferFailed();
        }
        if (outcome is ChatAttachmentBytesUploaded) {
          transferred = true;
          break;
        }
        if (outcome is! ChatAttachmentByteTransferFailed ||
            outcome.retrySafety != ChatAttachmentTransferRetrySafety.safe ||
            attempt == _options.maxSafeTransferAttempts) {
          break;
        }
      }
      record.transferSettled = true;
      if (!transferred || record.controller.signal.isCancelled) {
        final cancelled = record.controller.signal.isCancelled;
        final cleaned = await _abortPrepared(record);
        if (!cleaned) {
          _setState(
            record,
            cancelled
                ? ChatAttachmentUploadStatus.cancelled
                : ChatAttachmentUploadStatus.failed,
            attachment: record.pending,
          );
        }
        return cancelled
            ? const ChatAttachmentUploadCancelled()
            : const ChatAttachmentUploadFailed(
                ChatAttachmentUploadFailurePhase.transfer,
              );
      }

      record.uploadedBytes = record.metadata.sizeBytes;
      _setState(
        record,
        ChatAttachmentUploadStatus.finalizing,
        attachment: record.pending,
      );
      final finalizeInput = FinalizeAttachmentInput.fromJson({
        'operation': 'finalize_attachment',
        'attachmentId': record.pending!.attachmentId.toJson(),
        'idempotencyKey': record.finalizeKey,
      });
      final finalized = await _commandDispatcher.dispatch(
        _finalizeDescriptor(finalizeInput, record.pending!),
        finalizeInput,
        options: ChatCommandDispatchOptions(
          idempotencyKey: record.finalizeKey,
          cancellationSignal: record.controller.signal,
        ),
      );
      if (finalized is! ChatCommandSuccess<FinalizeAttachmentResult>) {
        final cancelled = record.controller.signal.isCancelled;
        final cleaned = await _abortPrepared(record);
        if (!cleaned) {
          _setState(
            record,
            cancelled
                ? ChatAttachmentUploadStatus.cancelled
                : ChatAttachmentUploadStatus.failed,
            attachment: record.pending,
          );
        }
        return cancelled
            ? const ChatAttachmentUploadCancelled()
            : const ChatAttachmentUploadFailed(
                ChatAttachmentUploadFailurePhase.finalize,
              );
      }
      final attachment = finalized.value.attachment;
      if (attachment is FinalizedAttachmentState) {
        _setState(
          record,
          ChatAttachmentUploadStatus.finalized,
          attachment: attachment,
        );
        return ChatAttachmentUploadFinalized(attachment);
      }
      if (attachment is RejectedAttachmentState) {
        _setState(
          record,
          ChatAttachmentUploadStatus.rejected,
          attachment: attachment,
        );
        return ChatAttachmentUploadRejected(attachment);
      }
      _setState(
        record,
        ChatAttachmentUploadStatus.failed,
        attachment: record.pending,
      );
      return const ChatAttachmentUploadFailed(
        ChatAttachmentUploadFailurePhase.finalize,
      );
    } catch (_) {
      final cancelled = record.controller.signal.isCancelled;
      if (record.pending != null) await _abortPrepared(record);
      final current = _normalizedState.state.attachmentUploads[record.uploadId];
      if (current?.status != ChatAttachmentUploadStatus.abandoned) {
        _setState(
          record,
          cancelled
              ? ChatAttachmentUploadStatus.cancelled
              : ChatAttachmentUploadStatus.failed,
          attachment: record.pending,
        );
      }
      return cancelled
          ? const ChatAttachmentUploadCancelled()
          : const ChatAttachmentUploadFailed(
              ChatAttachmentUploadFailurePhase.transfer,
            );
    }
  }

  Future<Uint8List> _readAndValidateSource(
    _ActiveAttachmentUpload record,
  ) {
    final builder = BytesBuilder(copy: false);
    final completer = Completer<Uint8List>();
    late final StreamSubscription<List<int>> sourceSubscription;
    late final StreamSubscription<void> cancellationSubscription;

    void fail() {
      if (!completer.isCompleted) {
        completer.completeError(const _AttachmentSourceFailed());
      }
    }

    try {
      sourceSubscription = record.input.source.listen(
        (chunk) {
          if (completer.isCompleted) return;
          try {
            builder.add(chunk);
            if (builder.length > record.metadata.sizeBytes) fail();
          } catch (_) {
            fail();
          }
        },
        onError: (Object _, StackTrace __) => fail(),
        onDone: () {
          if (completer.isCompleted) return;
          if (builder.length != record.metadata.sizeBytes) {
            fail();
            return;
          }
          completer.complete(builder.takeBytes());
        },
        cancelOnError: true,
      );
    } catch (_) {
      return Future<Uint8List>.error(const _AttachmentSourceFailed());
    }
    cancellationSubscription = record.controller.signal.onCancelled.listen((_) {
      unawaited(sourceSubscription.cancel());
      if (!completer.isCompleted) {
        completer.completeError(const _AttachmentUploadInterrupted());
      }
    });
    if (record.controller.signal.isCancelled) {
      unawaited(sourceSubscription.cancel());
      completer.completeError(const _AttachmentUploadInterrupted());
    }
    return completer.future.whenComplete(() async {
      await cancellationSubscription.cancel();
      await sourceSubscription.cancel();
    });
  }

  Future<bool> _abortPrepared(_ActiveAttachmentUpload record) {
    final existing = record.abortCompletion;
    if (existing != null) return existing;
    final pending = record.pending;
    if (pending == null) return Future<bool>.value(true);
    final controller = ChatCommandCancellationController();
    final timer = Timer(_options.cleanupTimeout, controller.cancel);
    final input = AbortAttachmentInput.fromJson({
      'operation': 'abort_attachment',
      'attachmentId': pending.attachmentId.toJson(),
      'idempotencyKey': record.abortKey,
    });
    final completion = _commandDispatcher
        .dispatch(
      _abortDescriptor(input, pending),
      input,
      options: ChatCommandDispatchOptions(
        idempotencyKey: record.abortKey,
        cancellationSignal: controller.signal,
      ),
    )
        .then((result) {
      if (result case ChatCommandSuccess<AbortAttachmentResult>(:final value)) {
        _setState(
          record,
          ChatAttachmentUploadStatus.abandoned,
          attachment: value.attachment,
        );
        return true;
      }
      return false;
    }, onError: (_) => false).whenComplete(timer.cancel);
    record.abortCompletion = completion;
    return completion;
  }

  void _setState(
    _ActiveAttachmentUpload record,
    ChatAttachmentUploadStatus status, {
    AttachmentLifecycleState? attachment,
  }) {
    try {
      _normalizedState.reconcileAttachmentUpload(
        ChatAttachmentUploadState(
          uploadId: record.uploadId,
          conversationId: record.input.conversationId,
          metadata: record.metadata,
          status: status,
          uploadedBytes: record.uploadedBytes,
          attachment: attachment,
        ),
      );
    } on StateError {
      // An application-owned normalized store may close before the client.
    }
  }

  void _revokeResource(_ActiveAttachmentUpload record) {
    if (record.resourceRevoked) return;
    record.resourceRevoked = true;
    try {
      record.input.temporaryResource?.revoke();
    } catch (_) {
      // Resource cleanup is best effort; thrown values may contain secrets.
    }
  }
}

final class _ActiveAttachmentUpload {
  _ActiveAttachmentUpload({
    required this.uploadId,
    required this.input,
    required this.metadata,
    required this.prepareKey,
    required this.finalizeKey,
    required this.abortKey,
  });

  final String uploadId;
  final ChatAttachmentUploadInput input;
  final AttachmentMetadata metadata;
  final String prepareKey;
  final String finalizeKey;
  final String abortKey;
  final ChatCommandCancellationController controller =
      ChatCommandCancellationController();
  StreamSubscription<void>? callerCancellation;
  PendingAttachmentState? pending;
  AttachmentUploadDescriptor? upload;
  Uint8List? bytes;
  int uploadedBytes = 0;
  bool transferSettled = false;
  bool resourceRevoked = false;
  Future<bool>? abortCompletion;
  Future<ChatAttachmentUploadResult>? completion;
}

ChatCommandDescriptor<PrepareAttachmentInput, PrepareAttachmentInput,
    PrepareAttachmentResult> _prepareDescriptor(
  ConversationId conversationId,
  PrepareAttachmentInput expected,
) =>
    ChatCommandDescriptor(
      name: 'attachment.prepare',
      method: ChatCommandMethod.post,
      path: '/conversations/${Uri.encodeComponent(conversationId.toJson())}'
          '/attachments',
      retrySafety: ChatCommandRetrySafety.safe,
      validateInput: (input) => PrepareAttachmentInput.fromJson(
        input.toJson(),
      ),
      parseResult: (json) => parseAttachmentTransportResult(
        json,
        expected,
      ) as PrepareAttachmentResult,
    );

ChatCommandDescriptor<FinalizeAttachmentInput, FinalizeAttachmentInput,
    FinalizeAttachmentResult> _finalizeDescriptor(
  FinalizeAttachmentInput expected,
  PendingAttachmentState pending,
) =>
    ChatCommandDescriptor(
      name: 'attachment.finalize',
      method: ChatCommandMethod.patch,
      path: '/attachments/'
          '${Uri.encodeComponent(expected.attachmentId.toJson())}'
          '/lifecycle',
      retrySafety: ChatCommandRetrySafety.safe,
      validateInput: (input) => FinalizeAttachmentInput.fromJson(
        input.toJson(),
      ),
      parseResult: (json) {
        final result = parseAttachmentTransportResult(
          json,
          expected,
        ) as FinalizeAttachmentResult;
        _validateSettledIdentity(pending, result.attachment);
        return result;
      },
    );

ChatCommandDescriptor<AbortAttachmentInput, AbortAttachmentInput,
    AbortAttachmentResult> _abortDescriptor(
  AbortAttachmentInput expected,
  PendingAttachmentState pending,
) =>
    ChatCommandDescriptor(
      name: 'attachment.abort',
      method: ChatCommandMethod.patch,
      path: '/attachments/'
          '${Uri.encodeComponent(expected.attachmentId.toJson())}'
          '/lifecycle',
      retrySafety: ChatCommandRetrySafety.safe,
      validateInput: (input) => AbortAttachmentInput.fromJson(
        input.toJson(),
      ),
      parseResult: (json) {
        final result = parseAttachmentTransportResult(
          json,
          expected,
        ) as AbortAttachmentResult;
        _validateSettledIdentity(pending, result.attachment);
        return result;
      },
    );

void _validateSettledIdentity(
  PendingAttachmentState pending,
  AttachmentLifecycleState settled,
) {
  if (pending.attachmentId != settled.attachmentId ||
      pending.createdAt != settled.createdAt ||
      pending.expiresAt != settled.expiresAt ||
      pending.metadata.fileName != settled.metadata.fileName ||
      pending.metadata.contentType != settled.metadata.contentType ||
      pending.metadata.sizeBytes != settled.metadata.sizeBytes) {
    throw const FormatException('Attachment lifecycle identity changed.');
  }
}

Future<T> _raceWithCancellation<T>(
  Future<T> future,
  ChatCommandCancellationSignal signal,
) {
  if (signal.isCancelled) {
    return Future<T>.error(const _AttachmentUploadInterrupted());
  }
  final completer = Completer<T>();
  late final StreamSubscription<void> subscription;
  subscription = signal.onCancelled.listen((_) {
    if (!completer.isCompleted) {
      completer.completeError(const _AttachmentUploadInterrupted());
    }
  });
  future.then(
    (value) {
      if (!completer.isCompleted) completer.complete(value);
    },
    onError: (Object _, StackTrace __) {
      if (!completer.isCompleted) {
        completer.completeError(const _AttachmentTransferFailed());
      }
    },
  ).whenComplete(subscription.cancel);
  return completer.future;
}

final class _AttachmentUploadInterrupted implements Exception {
  const _AttachmentUploadInterrupted();
}

final class _AttachmentTransferFailed implements Exception {
  const _AttachmentTransferFailed();
}

final class _AttachmentSourceFailed implements Exception {
  const _AttachmentSourceFailed();
}
