import React, { useState } from 'react';
import { createRoot } from 'react-dom/client';
import { flushSync } from 'react-dom';
import { DefaultMessageComposerRenderer } from '../../dist/ui/message-composer.js';

const root = createRoot(document.getElementById('fixture'));
function Composer({ options }) {
  const [text, setText] = useState(options.draft === 'empty' ? '' : 'A short draft');
  const [format, setFormat] = useState('plain');
  const controls = {
    setText, setFormat, insertMention() {}, async send() {}, async retrySend() {}, async retryDraft() {},
    addAttachments() {}, cancelAttachment() {}, removeAttachment() {}, blur() {}, clearReply() {},
    setReplyNotifyAuthor() {}, async retryReplySource() {}, selectReply() {},
  };
  return React.createElement(DefaultMessageComposerRenderer, {
    conversation: { id: 'fixture-channel', type: 'channel', name: 'Composer qualification', visibility: 'private' },
    hostProps: { className: 'handrail-chat__composer', onSubmit: event => event.preventDefault() },
    controls,
    state: {
      inputLabel: 'Message', placeholder: 'Write a message', text, format,
      attachments: [], mentions: [], mentionParticipants: [], disabled: false, readOnly: false,
      attachmentDisabledReason: options.attachments === 'enabled' ? undefined : options.attachments,
      isSending: options.feedback === 'sending', canSubmit: text.length > 0 && options.feedback !== 'sending',
      status: options.feedback === 'sending' ? { kind: 'sending', message: 'Sending message…' } : { kind: 'draft', message: '' },
      ...(options.feedback === 'error' ? { sendError: 'Message could not be sent. Please try again.', failedClientMessageId: 'fixture-failed' } : {}),
    },
  });
}
window.renderComposer = options => flushSync(() => root.render(React.createElement(Composer, { key: JSON.stringify(options), options })));
