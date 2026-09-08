export const saveMessageInput = Object.freeze({
  operation: "set_saved_message",
  intent: "save",
  messageId: "message-alpha",
  expectedSavedMessageRevision: 2,
  idempotencyKey: "saved-message:alpha:3",
  privateNote: "Follow up with the customer",
});

export const unsaveMessageInput = Object.freeze({
  operation: "set_saved_message",
  intent: "unsave",
  messageId: "message-beta",
  expectedSavedMessageRevision: 7,
  idempotencyKey: "saved-message:beta:8",
});

export const savedMessageInputs = Object.freeze([
  saveMessageInput,
  unsaveMessageInput,
]);

export function settledSavedMessageResult(
  input,
  reconciliationStatus = "applied",
) {
  return {
    operation: "set_saved_message",
    intent: input.intent,
    reconciliationStatus,
    messageId: input.messageId,
    expectedSavedMessageRevision: input.expectedSavedMessageRevision,
    idempotencyKey: input.idempotencyKey,
    savedMessageRevision:
      reconciliationStatus === "already_requested_state"
        ? input.expectedSavedMessageRevision
        : input.expectedSavedMessageRevision + 1,
    savedMessage: {
      messageId: input.messageId,
      isSaved: input.intent === "save",
      ...(input.privateNote === undefined
        ? {}
        : { privateNote: input.privateNote }),
    },
  };
}

export function conflictingSavedMessageResult(
  input,
  savedMessageRevision,
) {
  return {
    operation: "set_saved_message",
    intent: input.intent,
    reconciliationStatus: "saved_message_revision_conflict",
    messageId: input.messageId,
    expectedSavedMessageRevision: input.expectedSavedMessageRevision,
    idempotencyKey: input.idempotencyKey,
    savedMessageRevision,
    savedMessage: {
      messageId: input.messageId,
      isSaved: input.intent !== "save",
      ...(input.intent === "unsave"
        ? { privateNote: "Existing private note" }
        : {}),
    },
  };
}
