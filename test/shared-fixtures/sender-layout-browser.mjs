// Real public components and normalized cache; synthetic directory/query edges only.
import React from 'react';
import { createRoot } from 'react-dom/client';
import { CHAT_PROTOCOL_VERSION } from '@handrail/chat';
import { CHAT_CLIENT_PACKAGE_VERSION, createNormalizedChatCache } from '@handrail/chat/client';
import { ChatContext } from '@handrail/chat/react';
import { MessageTimeline, ThreadPanel } from '@handrail/chat/ui';

const tenantId = 'sender-layout';
const userId = 'viewer';
const now = '2026-10-06T06:29:00.000Z';
const metadata = {
  packageVersion: CHAT_CLIENT_PACKAGE_VERSION, protocolVersion: CHAT_PROTOCOL_VERSION,
  schemaVersion: 1, enabledFeatures: {}, feature: { name: 'conversation_snapshots', version: 1 },
  supportedProtocolRange: { minimumVersion: CHAT_PROTOCOL_VERSION, maximumVersion: CHAT_PROTOCOL_VERSION },
};
const names = [
  'alexandra.montgomery@design.example.test',
  'Alexandra Montgomery Customer Support Engineering',
  'SyntheticSenderIdentifierABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZ',
];
const cache = createNormalizedChatCache({ tenantId, userId, sessionId: 'layout-only' });
const conversation = (id, type) => ({
  id, tenantId, type, name: 'Sender layout', visibility: 'public',
  createdAt: now, updatedAt: now, activityAt: now, latestSequence: names.length,
  ...(type === 'thread' ? { parentConversationId: 'channel', rootMessageId: 'channel-0' } : {}),
  currentMember: { tenantId, conversationId: id, userId, role: 'member', state: 'active', joinedAt: now, updatedAt: now },
  currentReadState: { conversationId: id, userId, lastReadSequence: names.length, updatedAt: now },
  currentPreference: { conversationId: id, userId, notificationPreference: 'all', mute: { muted: false }, updatedAt: now },
});
for (const [id, type] of [['channel', 'channel'], ['thread', 'thread']]) {
  cache.hydrateConversationDetail({ kind: 'conversation_detail', conversation: { ...conversation(id, type), memberUserIds: [userId, 'sender-0', 'sender-1', 'sender-2'] }, _meta: metadata });
  cache.hydrateMessageTimeline({
    conversationId: id,
    messages: names.map((_, index) => ({
      id: `${id}-${index}`, tenantId, conversationId: id, author: { type: 'user', userId: `sender-${index}` },
      sequence: index + 1, createdAt: now, updatedAt: now, revision: { revision: 1 },
      content: { format: 'plain', text: `Readable ${type} message ${index + 1}.` },
      isThreadRoot: id === 'channel' && index === 0,
      reactions: [], attachmentMetadata: [],
      ...(id === 'channel' && index === 0 ? { threadSummary: { threadId: 'thread', replyCount: 3, participantIds: ['sender-0'], unreadCount: 0, lastReplyAt: now } } : {}),
    })),
    pagination: { older: { available: false }, newer: { available: false } },
    replay: { resumeFrom: { eventId: `${id}-event` } },
  });
}
const opening = { state: 'ready', rootMessageId: 'channel-0', parentConversationId: 'channel', threadConversationId: 'thread', reconciliationStatus: 'existing_for_root' };
const draft = { conversationId: 'thread', status: 'ready', authoritativeRevision: 0, dirty: false };
const success = async () => ({ status: 'success' });
const client = {
  endpoint: '/unused-layout-fixture', cache, state: { state: 'ready', enabledFeatures: {} },
  selectDirectoryUser: id => ({ kind: 'active', userId: id, displayName: names[Number(id.split('-')[1])] ?? 'Viewer', avatar: { kind: 'initials', initials: 'SS' } }),
  hydrateDirectoryUsers: success,
  getConversation: success, getMessageTimeline: success, markRead: success,
  getThreadOpeningState: () => opening, subscribeThreadOpening: () => () => {}, openThread: async () => opening,
  selectConversationDraft: () => draft, subscribeConversationDraft: () => () => {},
  openConversationDraft: async () => draft, closeConversationDraft: success,
  startTyping: () => true, stopTyping() {},
};
const context = { client, state: client.state, readiness: 'ready', isReady: true, refreshRequired: null, error: null };
const mode = window.senderLayoutMode ?? 'timeline';
createRoot(document.getElementById('fixture')).render(React.createElement(ChatContext.Provider, { value: context },
  mode === 'thread'
    ? React.createElement(ThreadPanel, { rootMessageId: 'channel-0', currentUserId: userId })
    : React.createElement(MessageTimeline, { conversationId: 'channel', currentUserId: userId }),
));
window.senderLayoutNames = names;
