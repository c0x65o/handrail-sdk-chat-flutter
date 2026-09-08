import 'dart:convert';

import 'package:handrail_chat/core.dart';
import 'package:test/test.dart';

import 'fixtures/attachment_transport_fixtures.dart';

void main() {
  final now = DateTime.parse(fixtureNow);

  test('every lifecycle state round-trips as its immutable Dart subtype', () {
    final fixtures = [
      pendingAttachmentFixture,
      finalizedAttachmentFixture,
      rejectedAttachmentFixture,
      attachedAttachmentFixture,
      abandonedAttachmentFixture,
    ];
    final types = [
      isA<PendingAttachmentState>(),
      isA<FinalizedAttachmentState>(),
      isA<RejectedAttachmentState>(),
      isA<AttachedAttachmentState>(),
      isA<AbandonedAttachmentState>(),
    ];
    for (var index = 0; index < fixtures.length; index++) {
      final parsed = AttachmentLifecycleState.fromJson(_roundTrip(fixtures[index]));
      expect(parsed, types[index]);
      expect(parsed.toJson(), fixtures[index]);
      final exposed = parsed.toJson();
      (exposed['metadata']! as Map<String, Object?>)['fileName'] = 'changed.pdf';
      expect(parsed.toJson(), fixtures[index]);
    }
  });

  test('prepare, finalize, abort, and download results are strictly coherent', () {
    final cases = <(Map<String, Object?>, Map<String, Object?>, Matcher)>[
      (prepareAttachmentInputFixture, prepareAttachmentResultFixture, isA<PrepareAttachmentResult>()),
      (finalizeAttachmentInputFixture, finalizeAttachmentResultFixture, isA<FinalizeAttachmentResult>()),
      (finalizeAttachmentInputFixture, rejectedFinalizeAttachmentResultFixture, isA<FinalizeAttachmentResult>()),
      (abortAttachmentInputFixture, abortAttachmentResultFixture, isA<AbortAttachmentResult>()),
      (downloadAttachmentInputFixture, downloadAttachmentResultFixture, isA<GetAttachmentDownloadResult>()),
    ];
    for (final (inputJson, resultJson, matcher) in cases) {
      final input = AttachmentTransportInput.fromJson(_roundTrip(inputJson));
      final result = parseAttachmentTransportResult(_roundTrip(resultJson), input, now: now);
      expect(result, matcher);
      expect(result.toJson(), resultJson);
    }

    final finalizeInput = AttachmentTransportInput.fromJson(finalizeAttachmentInputFixture);
    for (final invalid in <Map<String, Object?>>[
      {...finalizeAttachmentResultFixture, 'idempotencyKey': 'wrong'},
      {...finalizeAttachmentResultFixture, 'attachmentId': 'wrong'},
      {...finalizeAttachmentResultFixture, 'outcome': 'rejected'},
      {...finalizeAttachmentResultFixture, 'unexpected': true},
    ]) {
      expect(() => parseAttachmentTransportResult(invalid, finalizeInput, now: now), throwsA(isA<AttachmentTransportFormatException>()));
    }
  });

  test('allowed lifecycle transitions and operation-specific transitions are enforced', () {
    final statuses = <AttachmentLifecycleStatus?>[null, ...AttachmentLifecycleStatus.values];
    final allowed = {
      'null:pending',
      'pending:finalized',
      'pending:rejected',
      'pending:abandoned',
      'finalized:attached',
    };
    for (final from in statuses) {
      for (final to in AttachmentLifecycleStatus.values) {
        expect(
          isAllowedAttachmentLifecycleTransition(from, to),
          allowed.contains('${from?.name}:$to'.replaceFirst('AttachmentLifecycleStatus.', '')),
          reason: '${from?.name} -> ${to.name}',
        );
      }
    }

    final pending = AttachmentLifecycleState.fromJson(pendingAttachmentFixture);
    final finalized = AttachmentLifecycleState.fromJson(finalizedAttachmentFixture);
    final rejected = AttachmentLifecycleState.fromJson(rejectedAttachmentFixture);
    final abandoned = AttachmentLifecycleState.fromJson(abandonedAttachmentFixture);
    final prepare = AttachmentTransportInput.fromJson(prepareAttachmentInputFixture);
    final finalize = AttachmentTransportInput.fromJson(finalizeAttachmentInputFixture);
    final abort = AttachmentTransportInput.fromJson(abortAttachmentInputFixture);
    expect(validateAttachmentLifecycleTransition(null, pending, prepare), same(pending));
    expect(validateAttachmentLifecycleTransition(pending, finalized, finalize), same(finalized));
    expect(validateAttachmentLifecycleTransition(pending, rejected, finalize), same(rejected));
    final pendingAbort = AttachmentLifecycleState.fromJson(pendingAbortAttachmentFixture);
    expect(validateAttachmentLifecycleTransition(pendingAbort, abandoned, abort), same(abandoned));
    expect(() => validateAttachmentLifecycleTransition(finalized, abandoned, abort), throwsA(_code(AttachmentTransportParseErrorCode.invalidTransition)));
    expect(() => validateAttachmentLifecycleTransition(pending, abandoned, finalize), throwsA(_code(AttachmentTransportParseErrorCode.invalidTransition)));
  });

  test('descriptor kinds, expiry, TTL, opacity, and serialized secrets are enforced', () {
    expect(AttachmentUploadDescriptor.fromJson(uploadDescriptorFixture, now: now).toJson(), uploadDescriptorFixture);
    expect(AttachmentDownloadDescriptor.fromJson(downloadDescriptorFixture, now: now).toJson(), downloadDescriptorFixture);
    for (final invalid in <Map<String, Object?>>[
      {...downloadDescriptorFixture, 'expiresAt': fixtureNow},
      {...downloadDescriptorFixture, 'expiresAt': '2026-08-26T12:05:00.001Z'},
      {...downloadDescriptorFixture, 'kind': 'opaque_attachment_upload'},
      {...downloadDescriptorFixture, 'descriptor': jsonEncode({'accessToken': 'secret'})},
      {...downloadDescriptorFixture, 'descriptor': jsonEncode({'providerResponse': {'requestId': 'internal'}})},
    ]) {
      expect(() => AttachmentDownloadDescriptor.fromJson(invalid, now: now), throwsA(isA<AttachmentTransportFormatException>()));
    }
  });

  test('filename, size, content-type, checksum, and pending TTL bounds are enforced', () {
    for (final metadata in <Map<String, Object?>>[
      {...attachmentMetadataFixture, 'fileName': '../report.pdf'},
      {...attachmentMetadataFixture, 'fileName': '.hidden.pdf'},
      {...attachmentMetadataFixture, 'fileName': 'report.pdf.exe'},
      {...attachmentMetadataFixture, 'fileName': '${'é' * 255}.pdf'},
      {...attachmentMetadataFixture, 'contentType': 'application/octet-stream'},
      {...attachmentMetadataFixture, 'contentType': 'application/pdf; charset=binary'},
      {...attachmentMetadataFixture, 'sizeBytes': -1},
      {...attachmentMetadataFixture, 'sizeBytes': maxAttachmentSizeBytes + 1},
    ]) {
      expect(() => AttachmentMetadata.fromJson(metadata), throwsA(isA<AttachmentTransportFormatException>()));
    }
    expect(() => AttachmentLifecycleState.fromJson({...finalizedAttachmentFixture, 'checksum': 'sha256:ABC'}), throwsA(isA<AttachmentTransportFormatException>()));
    expect(
      () => AttachmentLifecycleState.fromJson({...pendingAttachmentFixture, 'expiresAt': '2026-08-27T12:00:30.001Z'}),
      throwsA(_code(AttachmentTransportParseErrorCode.incoherentState)),
    );
  });

  test('trusted identity, credentials, provider fields, and unknown fields are rejected recursively', () {
    for (final entry in <(String, Object?)>[
      ('tenantId', 'tenant-spoof'),
      ('actorUserId', 'actor-spoof'),
      ('authorization', 'Bearer secret'),
      ('credentials', {'password': 'secret'}),
      ('providerConfiguration', {'provider': 's3'}),
      ('objectKey', 'private/key'),
      ('headers', {'Authorization': 'secret'}),
      ('signedUrl', 'https://storage.invalid/signed'),
      ('rawProviderResponse', {'ok': true}),
    ]) {
      expect(
        () => AttachmentTransportInput.fromJson({
          ...prepareAttachmentInputFixture,
          'metadata': {...attachmentMetadataFixture, 'nested': {entry.$1: entry.$2}},
        }),
        throwsA(isA<AttachmentTransportFormatException>()),
        reason: entry.$1,
      );
    }
    expect(() => AttachmentTransportInput.fromJson({...prepareAttachmentInputFixture, 'checksum': fixtureChecksum}), throwsA(_code(AttachmentTransportParseErrorCode.malformedInput)));
  });
}

Object? _roundTrip(Object? value) => jsonDecode(jsonEncode(value));

Matcher _code(AttachmentTransportParseErrorCode code) => isA<AttachmentTransportFormatException>().having((error) => error.code, 'code', code);
