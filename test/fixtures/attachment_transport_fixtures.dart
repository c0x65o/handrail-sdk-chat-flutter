const fixtureNow = '2026-08-26T12:00:00.000Z';
const fixtureChecksum = 'sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';

const attachmentMetadataFixture = <String, Object?>{
  'fileName': 'Quarterly report.pdf',
  'contentType': 'application/pdf',
  'sizeBytes': 42000,
};

const prepareAttachmentInputFixture = <String, Object?>{
  'operation': 'prepare_attachment',
  'metadata': attachmentMetadataFixture,
  'idempotencyKey': 'prepare-attachment-1',
};
const finalizeAttachmentInputFixture = <String, Object?>{
  'operation': 'finalize_attachment',
  'attachmentId': 'attachment-1',
  'idempotencyKey': 'finalize-attachment-1',
};
const abortAttachmentInputFixture = <String, Object?>{
  'operation': 'abort_attachment',
  'attachmentId': 'attachment-2',
  'idempotencyKey': 'abort-attachment-2',
};
const downloadAttachmentInputFixture = <String, Object?>{
  'operation': 'get_attachment_download',
  'attachmentId': 'attachment-1',
  'messageId': 'message-1',
};

const pendingAttachmentFixture = <String, Object?>{
  'status': 'pending',
  'attachmentId': 'attachment-1',
  'metadata': attachmentMetadataFixture,
  'createdAt': '2026-08-26T12:00:30.000Z',
  'expiresAt': '2026-08-26T13:00:30.000Z',
};
final pendingAbortAttachmentFixture = <String, Object?>{
  ...pendingAttachmentFixture,
  'attachmentId': 'attachment-2',
};
final finalizedAttachmentFixture = <String, Object?>{
  ...pendingAttachmentFixture,
  'status': 'finalized',
  'checksum': fixtureChecksum,
  'finalizedAt': '2026-08-26T12:05:00.000Z',
};
final rejectedAttachmentFixture = <String, Object?>{
  ...pendingAttachmentFixture,
  'status': 'rejected',
  'rejectionReason': 'checksum_mismatch',
  'rejectedAt': '2026-08-26T12:05:00.000Z',
};
final attachedAttachmentFixture = <String, Object?>{
  ...pendingAttachmentFixture,
  'status': 'attached',
  'messageId': 'message-1',
  'checksum': fixtureChecksum,
  'attachedAt': '2026-08-26T12:05:00.000Z',
};
final abandonedAttachmentFixture = <String, Object?>{
  ...pendingAbortAttachmentFixture,
  'status': 'abandoned',
  'abandonedAt': '2026-08-26T12:20:00.000Z',
};

const uploadDescriptorFixture = <String, Object?>{
  'kind': 'opaque_attachment_upload',
  'descriptor': 'opaque-public-upload-instructions',
  'expiresAt': '2026-08-26T12:10:00.000Z',
};
const downloadDescriptorFixture = <String, Object?>{
  'kind': 'opaque_attachment_download',
  'descriptor': 'opaque-public-download-instructions',
  'expiresAt': '2026-08-26T12:04:00.000Z',
};

final prepareAttachmentResultFixture = <String, Object?>{
  'operation': 'prepare_attachment',
  'reconciliationStatus': 'applied',
  'idempotencyKey': 'prepare-attachment-1',
  'attachment': pendingAttachmentFixture,
  'upload': uploadDescriptorFixture,
};
final finalizeAttachmentResultFixture = <String, Object?>{
  'operation': 'finalize_attachment',
  'reconciliationStatus': 'applied',
  'idempotencyKey': 'finalize-attachment-1',
  'attachmentId': 'attachment-1',
  'outcome': 'finalized',
  'attachment': finalizedAttachmentFixture,
};
final rejectedFinalizeAttachmentResultFixture = <String, Object?>{
  ...finalizeAttachmentResultFixture,
  'outcome': 'rejected',
  'attachment': rejectedAttachmentFixture,
};
final abortAttachmentResultFixture = <String, Object?>{
  'operation': 'abort_attachment',
  'reconciliationStatus': 'applied',
  'idempotencyKey': 'abort-attachment-2',
  'attachmentId': 'attachment-2',
  'attachment': abandonedAttachmentFixture,
};
final downloadAttachmentResultFixture = <String, Object?>{
  'operation': 'get_attachment_download',
  'attachmentId': 'attachment-1',
  'messageId': 'message-1',
  'attachment': attachedAttachmentFixture,
  'download': downloadDescriptorFixture,
};
