export const fixtureNow = "2026-08-26T12:00:00.000Z";
export const checksum = `sha256:${"a".repeat(64)}`;

export const attachmentMetadata = {
  fileName: "Quarterly report.pdf",
  contentType: "application/pdf",
  sizeBytes: 42_000,
};

export const prepareInput = {
  operation: "prepare_attachment",
  metadata: attachmentMetadata,
  idempotencyKey: "prepare-attachment-1",
};

export const finalizeInput = {
  operation: "finalize_attachment",
  attachmentId: "attachment-1",
  idempotencyKey: "finalize-attachment-1",
};

export const abortInput = {
  operation: "abort_attachment",
  attachmentId: "attachment-2",
  idempotencyKey: "abort-attachment-2",
};

export const downloadInput = {
  operation: "get_attachment_download",
  attachmentId: "attachment-1",
  messageId: "message-1",
};

export const pendingAttachment = {
  status: "pending",
  attachmentId: "attachment-1",
  metadata: attachmentMetadata,
  createdAt: "2026-08-26T12:00:30.000Z",
  expiresAt: "2026-08-26T13:00:30.000Z",
};

export const pendingAbortAttachment = {
  ...pendingAttachment,
  attachmentId: "attachment-2",
};

export const attachedAttachment = {
  ...pendingAttachment,
  status: "attached",
  messageId: "message-1",
  checksum,
  attachedAt: "2026-08-26T12:05:00.000Z",
};

export const finalizedAttachment = {
  ...pendingAttachment,
  status: "finalized",
  checksum,
  finalizedAt: "2026-08-26T12:05:00.000Z",
};

export const abandonedAttachment = {
  ...pendingAbortAttachment,
  status: "abandoned",
  abandonedAt: "2026-08-26T12:20:00.000Z",
};

export const uploadDescriptor = {
  kind: "opaque_attachment_upload",
  descriptor: "opaque-public-upload-instructions",
  expiresAt: "2026-08-26T12:10:00.000Z",
};

export const downloadDescriptor = {
  kind: "opaque_attachment_download",
  descriptor: "opaque-public-download-instructions",
  expiresAt: "2026-08-26T12:04:00.000Z",
};

export const prepareAppliedResult = {
  operation: "prepare_attachment",
  reconciliationStatus: "applied",
  idempotencyKey: prepareInput.idempotencyKey,
  attachment: pendingAttachment,
  upload: uploadDescriptor,
};

export const prepareReplayedResult = {
  ...prepareAppliedResult,
  reconciliationStatus: "replayed",
};

export const finalizeAppliedResult = {
  operation: "finalize_attachment",
  reconciliationStatus: "applied",
  idempotencyKey: finalizeInput.idempotencyKey,
  attachmentId: finalizeInput.attachmentId,
  outcome: "finalized",
  attachment: finalizedAttachment,
};

export const finalizeReplayedResult = {
  ...finalizeAppliedResult,
  reconciliationStatus: "replayed",
};

export const abortAppliedResult = {
  operation: "abort_attachment",
  reconciliationStatus: "applied",
  idempotencyKey: abortInput.idempotencyKey,
  attachmentId: abortInput.attachmentId,
  attachment: abandonedAttachment,
};

export const abortReplayedResult = {
  ...abortAppliedResult,
  reconciliationStatus: "replayed",
};

export const downloadResult = {
  operation: "get_attachment_download",
  attachmentId: downloadInput.attachmentId,
  messageId: downloadInput.messageId,
  attachment: attachedAttachment,
  download: downloadDescriptor,
};
