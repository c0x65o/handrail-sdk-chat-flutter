import 'dart:async';
import 'dart:convert';

import 'package:handrail_chat/core.dart';
import 'package:test/test.dart';

void main() {
  group('attachment upload phases', () {
    test(
        'prepares, transfers without auth leakage, clamps progress, and finalizes',
        () async {
      const token = 'sentinel-chat-bearer';
      final phases = <String>[];
      final progress = <int>[];
      late ChatAttachmentByteTransferRequest transferRequest;
      late HandrailChatClient client;
      final http = _AttachmentHttpTransport(
        onPhase: phases.add,
      );
      final bytes = _FakeByteTransport((request, _) async {
        phases.add('transfer');
        transferRequest = request;
        expect(await _collect(request.source), <int>[1, 2, 3]);
        for (final rawProgress in <int>[2, 1, -50, 9, 3]) {
          request.onProgress(rawProgress);
          final upload =
              client.normalizedState.state.attachmentUploads.values.single;
          progress.add(upload.uploadedBytes);
        }
        return const ChatAttachmentBytesUploaded();
      });
      final resource = _TemporaryResource();
      client = _client(
        http: http,
        bytes: bytes,
        token: token,
      );

      final handle = client.uploadAttachment(
        ChatAttachmentUploadInput(
          conversationId: ConversationId('conversation-1'),
          metadata: _metadata(),
          source: Stream<List<int>>.fromIterable(const [
            [1],
            [2, 3],
          ]),
          temporaryResource: resource,
        ),
      );
      final result = await handle.completion;
      progress.add(handle.state.uploadedBytes);

      expect(result, isA<ChatAttachmentUploadFinalized>());
      expect(phases, <String>['prepare', 'transfer', 'finalize']);
      expect(http.requests, hasLength(2));
      expect(
        http.requests,
        everyElement(
          isA<HandrailChatHttpRequest>().having(
            (request) => request.headers['Authorization'],
            'authorization',
            'Bearer $token',
          ),
        ),
      );
      expect(transferRequest.upload.descriptor, 'opaque-upload-instructions');
      expect(transferRequest.toString(), isNot(contains(token)));
      expect(transferRequest.metadata.toJson(), _metadata().toJson());
      expect(progress, orderedEquals([...progress]..sort()));
      expect(progress, everyElement(inInclusiveRange(0, 3)));
      expect(handle.state.status, ChatAttachmentUploadStatus.finalized);
      expect(handle.state.attachment, isA<FinalizedAttachmentState>());
      expect(
        client.normalizedState.state.attachmentUploads[handle.uploadId],
        same(handle.state),
      );
      final encoded = NormalizedSnapshotStateStorageCodec.encode(
        client.normalizedState.state,
      );
      final serialized = jsonEncode(encoded);
      expect(serialized, isNot(contains(token)));
      expect(serialized, isNot(contains('opaque-upload-instructions')));
      final restored = NormalizedSnapshotStateStorageCodec.decode(encoded);
      expect(
        restored.attachmentUploads[handle.uploadId]!.toJson(),
        handle.state.toJson(),
      );
      expect(resource.revokeCalls, 1);
      await client.dispose();
      expect(resource.revokeCalls, 1);
    });

    test('rejects a declared-size mismatch before authenticated prepare',
        () async {
      final http = _AttachmentHttpTransport();
      final resource = _TemporaryResource();
      final client = _client(
        http: http,
        bytes: _FakeByteTransport((_, __) async {
          fail('byte transfer must not run');
        }),
      );

      final result = await client
          .uploadAttachment(
            ChatAttachmentUploadInput(
              conversationId: ConversationId('conversation-1'),
              metadata: _metadata(),
              source: Stream<List<int>>.value(const [1, 2]),
              temporaryResource: resource,
            ),
          )
          .completion;

      expect(
        result,
        isA<ChatAttachmentUploadFailed>().having(
          (value) => value.phase,
          'phase',
          ChatAttachmentUploadFailurePhase.prepare,
        ),
      );
      expect(http.requests, isEmpty);
      expect(resource.revokeCalls, 1);
      await client.dispose();
    });

    test('parses rejected finalize outcomes into canonical normalized state',
        () async {
      final client = _client(
        http: _AttachmentHttpTransport(finalizeRejected: true),
        bytes: _FakeByteTransport(
          (_, __) async => const ChatAttachmentBytesUploaded(),
        ),
      );

      final handle = client.uploadAttachment(_input());
      final result = await handle.completion;

      expect(result, isA<ChatAttachmentUploadRejected>());
      expect(handle.state.status, ChatAttachmentUploadStatus.rejected);
      expect(handle.state.attachment, isA<RejectedAttachmentState>());
      expect(handle.state.uploadedBytes, 3);
      await client.dispose();
    });
  });

  group('attachment upload retries and cleanup', () {
    test('retries transfer only for explicit safe results and stays bounded',
        () async {
      var safeAttempts = 0;
      final safeHttp = _AttachmentHttpTransport();
      final safeClient = _client(
        http: safeHttp,
        bytes: _FakeByteTransport((_, __) async {
          safeAttempts += 1;
          return const ChatAttachmentByteTransferFailed(
            retrySafety: ChatAttachmentTransferRetrySafety.safe,
          );
        }),
        options: const ChatAttachmentUploadOptions(
          maxSafeTransferAttempts: 3,
        ),
      );

      final safeResult = await safeClient.uploadAttachment(_input()).completion;

      expect(safeAttempts, 3);
      expect(safeResult, isA<ChatAttachmentUploadFailed>());
      expect(safeHttp.abortRequests, 1);
      await safeClient.dispose();

      var unsafeAttempts = 0;
      final unsafeHttp = _AttachmentHttpTransport();
      final unsafeClient = _client(
        http: unsafeHttp,
        bytes: _FakeByteTransport((_, __) async {
          unsafeAttempts += 1;
          return const ChatAttachmentByteTransferFailed();
        }),
        options: const ChatAttachmentUploadOptions(
          maxSafeTransferAttempts: 5,
        ),
      );

      await unsafeClient.uploadAttachment(_input()).completion;

      expect(unsafeAttempts, 1);
      expect(unsafeHttp.abortRequests, 1);
      await unsafeClient.dispose();
    });

    test('uses one finalize key across authenticated HTTP retries', () async {
      final http = _AttachmentHttpTransport(transientFinalizeFailures: 1);
      final client = _client(
        http: http,
        bytes: _FakeByteTransport(
          (_, __) async => const ChatAttachmentBytesUploaded(),
        ),
        commandRetryOptions: ChatCommandRetryOptions(
          maxAttempts: 2,
          wait: (_, __) async {},
        ),
      );

      final result = await client.uploadAttachment(_input()).completion;

      expect(result, isA<ChatAttachmentUploadFinalized>());
      expect(http.finalizeRequests, 2);
      expect(
        http.requests
            .where((request) =>
                jsonDecode(request.body!)['operation'] == 'finalize_attachment')
            .map((request) => request.headers['Idempotency-Key'])
            .toSet(),
        hasLength(1),
      );
      await client.dispose();
    });

    test('bounds best-effort abort and suppresses cleanup thrown values',
        () async {
      const secret = 'provider-secret-that-must-not-escape';
      final http = _AttachmentHttpTransport(hangAbort: true);
      final resource = _TemporaryResource(throwValue: StateError(secret));
      final client = _client(
        http: http,
        bytes: _FakeByteTransport((_, __) async => throw StateError(secret)),
        options: const ChatAttachmentUploadOptions(
          cleanupTimeout: Duration(milliseconds: 10),
        ),
      );

      final result = await client
          .uploadAttachment(_input(temporaryResource: resource))
          .completion
          .timeout(const Duration(seconds: 1));

      expect(result, isA<ChatAttachmentUploadFailed>());
      expect(result.toString(), isNot(contains(secret)));
      expect(http.abortRequests, 1);
      expect(resource.revokeCalls, 1);
      await client.dispose();
    });
  });

  group('attachment upload cancellation', () {
    test('cancels before and during prepare without starting byte transfer',
        () async {
      final before = ChatCommandCancellationController()..cancel();
      final beforeHttp = _AttachmentHttpTransport();
      final bytes = _FakeByteTransport((_, __) async {
        fail('byte transfer must not run');
      });
      final beforeClient = _client(http: beforeHttp, bytes: bytes);
      final beforeResult = await beforeClient
          .uploadAttachment(_input(cancellationSignal: before.signal))
          .completion;
      expect(beforeResult, isA<ChatAttachmentUploadCancelled>());
      expect(beforeHttp.requests, isEmpty);
      await beforeClient.dispose();

      final prepareStarted = Completer<void>();
      final duringHttp = _AttachmentHttpTransport(
        hangPrepare: true,
        onPrepareStarted: prepareStarted.complete,
      );
      final duringClient = _client(http: duringHttp, bytes: bytes);
      final handle = duringClient.uploadAttachment(_input());
      await prepareStarted.future;
      handle.cancel();
      expect(await handle.completion, isA<ChatAttachmentUploadCancelled>());
      expect(duringHttp.abortRequests, 0);
      await duringClient.dispose();
    });

    test('cancels transfer, aborts prepared state, and revokes once', () async {
      final transferStarted = Completer<void>();
      final resource = _TemporaryResource();
      final http = _AttachmentHttpTransport();
      final client = _client(
        http: http,
        bytes: _FakeByteTransport((request, _) {
          transferStarted.complete();
          return Completer<ChatAttachmentByteTransferResult>().future;
        }),
      );
      final handle = client.uploadAttachment(
        _input(temporaryResource: resource),
      );
      await transferStarted.future;

      handle.cancel();
      final result = await handle.completion;

      expect(result, isA<ChatAttachmentUploadCancelled>());
      expect(http.abortRequests, 1);
      expect(handle.state.status, ChatAttachmentUploadStatus.abandoned);
      expect(resource.revokeCalls, 1);
      await client.dispose();
      expect(resource.revokeCalls, 1);
    });

    test('cancels finalize and reconciles successful abort cleanup', () async {
      final finalizeStarted = Completer<void>();
      final http = _AttachmentHttpTransport(
        hangFinalize: true,
        onFinalizeStarted: finalizeStarted.complete,
      );
      final client = _client(
        http: http,
        bytes: _FakeByteTransport(
          (_, __) async => const ChatAttachmentBytesUploaded(),
        ),
      );
      final handle = client.uploadAttachment(_input());
      await finalizeStarted.future;

      handle.cancel();
      final result = await handle.completion;

      expect(result, isA<ChatAttachmentUploadCancelled>());
      expect(http.abortRequests, 1);
      expect(handle.state.attachment, isA<AbandonedAttachmentState>());
      await client.dispose();
    });

    test('client dispose cancels active transfer and awaits bounded cleanup',
        () async {
      final transferStarted = Completer<void>();
      final resource = _TemporaryResource();
      final http = _AttachmentHttpTransport(hangAbort: true);
      final client = _client(
        http: http,
        bytes: _FakeByteTransport((_, __) {
          transferStarted.complete();
          return Completer<ChatAttachmentByteTransferResult>().future;
        }),
        options: const ChatAttachmentUploadOptions(
          cleanupTimeout: Duration(milliseconds: 10),
        ),
      );
      final handle = client.uploadAttachment(
        _input(temporaryResource: resource),
      );
      await transferStarted.future;

      await client.dispose().timeout(const Duration(seconds: 1));

      expect(await handle.completion, isA<ChatAttachmentUploadCancelled>());
      expect(http.abortRequests, 1);
      expect(resource.revokeCalls, 1);
    });
  });
}

HandrailChatClient _client({
  required _AttachmentHttpTransport http,
  required ChatAttachmentByteTransferTransport bytes,
  String token = 'chat-token',
  ChatAttachmentUploadOptions options = const ChatAttachmentUploadOptions(),
  ChatCommandRetryOptions commandRetryOptions =
      const ChatCommandRetryOptions(maxAttempts: 1),
}) =>
    HandrailChatClient(
      apiBaseUri: Uri.parse('https://chat.example.test/api/chat'),
      tokenProvider: () async => token,
      transport: http,
      attachmentTransferTransport: bytes,
      attachmentUploadOptions: options,
      commandRetryOptions: commandRetryOptions,
      generateAttachmentUploadId: () => 'upload-${http.prepareRequests + 1}',
      generateIdempotencyKey: () => 'key-${http.generatedKeys++}',
    );

ChatAttachmentUploadInput _input({
  ChatCommandCancellationSignal? cancellationSignal,
  ChatAttachmentTemporaryResource? temporaryResource,
}) =>
    ChatAttachmentUploadInput(
      conversationId: ConversationId('conversation-1'),
      metadata: _metadata(),
      source: Stream<List<int>>.fromIterable(const [
        [1],
        [2, 3],
      ]),
      cancellationSignal: cancellationSignal,
      temporaryResource: temporaryResource,
    );

AttachmentMetadata _metadata() => AttachmentMetadata(
      fileName: 'note.txt',
      contentType: 'text/plain',
      sizeBytes: 3,
    );

typedef _ByteHandler = Future<ChatAttachmentByteTransferResult> Function(
  ChatAttachmentByteTransferRequest request,
  int attempt,
);

final class _FakeByteTransport implements ChatAttachmentByteTransferTransport {
  _FakeByteTransport(this.handler);
  final _ByteHandler handler;
  int attempts = 0;

  @override
  Future<ChatAttachmentByteTransferResult> transfer(
    ChatAttachmentByteTransferRequest request,
  ) =>
      handler(request, ++attempts);
}

final class _AttachmentHttpTransport implements HandrailChatHttpTransport {
  _AttachmentHttpTransport({
    this.finalizeRejected = false,
    this.transientFinalizeFailures = 0,
    this.hangPrepare = false,
    this.hangFinalize = false,
    this.hangAbort = false,
    this.onPhase,
    this.onPrepareStarted,
    this.onFinalizeStarted,
  });

  final bool finalizeRejected;
  final int transientFinalizeFailures;
  final bool hangPrepare;
  final bool hangFinalize;
  final bool hangAbort;
  final void Function(String phase)? onPhase;
  final void Function()? onPrepareStarted;
  final void Function()? onFinalizeStarted;
  final List<HandrailChatHttpRequest> requests = [];
  int prepareRequests = 0;
  int finalizeRequests = 0;
  int abortRequests = 0;
  int generatedKeys = 0;
  Map<String, Object?>? pendingState;

  @override
  Future<HandrailChatHttpResponse> send(HandrailChatHttpRequest request) async {
    requests.add(request);
    final body = jsonDecode(request.body!) as Map<String, Object?>;
    final operation = body['operation'];
    switch (operation) {
      case 'prepare_attachment':
        prepareRequests += 1;
        onPhase?.call('prepare');
        onPrepareStarted?.call();
        if (hangPrepare) {
          return Completer<HandrailChatHttpResponse>().future;
        }
        final result = _prepareResult(body);
        pendingState = Map<String, Object?>.from(
          result['attachment']! as Map<String, Object?>,
        );
        return _response(result);
      case 'finalize_attachment':
        finalizeRequests += 1;
        onPhase?.call('finalize');
        onFinalizeStarted?.call();
        if (hangFinalize) {
          return Completer<HandrailChatHttpResponse>().future;
        }
        if (finalizeRequests <= transientFinalizeFailures) {
          return HandrailChatHttpResponse(
            statusCode: 503,
            body: jsonEncode({
              'error': {'code': 'BUSY', 'message': 'busy'},
            }),
          );
        }
        return _response(
          _finalizeResult(
            body,
            pending: pendingState!,
            rejected: finalizeRejected,
          ),
        );
      case 'abort_attachment':
        abortRequests += 1;
        onPhase?.call('abort');
        if (hangAbort) {
          return Completer<HandrailChatHttpResponse>().future;
        }
        return _response(_abortResult(body, pending: pendingState!));
      default:
        throw StateError('Unexpected attachment operation.');
    }
  }
}

Map<String, Object?> _prepareResult(Map<String, Object?> input) {
  final now = DateTime.now().toUtc();
  return {
    'operation': 'prepare_attachment',
    'reconciliationStatus': 'applied',
    'idempotencyKey': input['idempotencyKey'],
    'attachment': _pending(input['metadata']!, now),
    'upload': {
      'kind': 'opaque_attachment_upload',
      'descriptor': 'opaque-upload-instructions',
      'expiresAt': now.add(const Duration(minutes: 10)).toIso8601String(),
    },
  };
}

Map<String, Object?> _finalizeResult(
  Map<String, Object?> input, {
  required Map<String, Object?> pending,
  required bool rejected,
}) {
  final now = DateTime.now().toUtc();
  return {
    'operation': 'finalize_attachment',
    'reconciliationStatus': 'applied',
    'idempotencyKey': input['idempotencyKey'],
    'attachmentId': input['attachmentId'],
    'outcome': rejected ? 'rejected' : 'finalized',
    'attachment': {
      ...pending,
      'status': rejected ? 'rejected' : 'finalized',
      'attachmentId': input['attachmentId'],
      if (rejected) ...{
        'rejectionReason': 'scan_failed',
        'rejectedAt': now.add(const Duration(minutes: 1)).toIso8601String(),
      } else ...{
        'checksum':
            'sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
        'finalizedAt': now.add(const Duration(minutes: 1)).toIso8601String(),
      },
    },
  };
}

Map<String, Object?> _abortResult(
  Map<String, Object?> input, {
  required Map<String, Object?> pending,
}) {
  final now = DateTime.now().toUtc();
  return {
    'operation': 'abort_attachment',
    'reconciliationStatus': 'applied',
    'idempotencyKey': input['idempotencyKey'],
    'attachmentId': input['attachmentId'],
    'attachment': {
      ...pending,
      'status': 'abandoned',
      'attachmentId': input['attachmentId'],
      'abandonedAt': now.add(const Duration(minutes: 1)).toIso8601String(),
    },
  };
}

Map<String, Object?> _pending(Object metadata, DateTime now) => {
      'status': 'pending',
      'attachmentId': 'attachment-1',
      'metadata': metadata,
      'createdAt': now.toIso8601String(),
      'expiresAt': now.add(const Duration(hours: 1)).toIso8601String(),
    };

HandrailChatHttpResponse _response(Map<String, Object?> body) =>
    HandrailChatHttpResponse(statusCode: 200, body: jsonEncode(body));

Future<List<int>> _collect(Stream<List<int>> source) async =>
    [await for (final chunk in source) ...chunk];

final class _TemporaryResource implements ChatAttachmentTemporaryResource {
  _TemporaryResource({this.throwValue});
  final Object? throwValue;
  int revokeCalls = 0;

  @override
  void revoke() {
    revokeCalls += 1;
    if (throwValue case final value?) throw value;
  }
}
