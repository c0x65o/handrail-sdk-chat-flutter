import {
  parseSetSavedMessageInput,
  parseSetSavedMessageResult,
  type SetSavedMessageInput,
} from "@handrail/chat/client";

const input: SetSavedMessageInput = {
  operation: "set_saved_message",
  intent: "save",
  messageId: "message-browser" as never,
  expectedSavedMessageRevision: 3,
  idempotencyKey: "browser:saved-message:4",
  privateNote: "Browser-private note",
};

export const browserSavedMessageInputProof =
  parseSetSavedMessageInput(input);

export const browserSavedMessageResultProof = parseSetSavedMessageResult(
  {
    operation: "set_saved_message",
    intent: "save",
    reconciliationStatus: "applied",
    messageId: input.messageId,
    expectedSavedMessageRevision: input.expectedSavedMessageRevision,
    idempotencyKey: input.idempotencyKey,
    savedMessageRevision: 4,
    savedMessage: {
      messageId: input.messageId,
      isSaved: true,
      privateNote: "Browser-private note",
    },
  },
  input,
);
