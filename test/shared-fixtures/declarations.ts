import type * as Client from "@handrail/chat/client";
import type * as ReactIntegration from "@handrail/chat/react";
import type * as Server from "@handrail/chat/server";
import type {
  HandrailChatTesting,
  PostgresTestBackend,
  PostgresTestHarness,
} from "@handrail/chat/testing";
import type * as Testing from "@handrail/chat/testing";
import type * as Ui from "@handrail/chat/ui";

export type ClientExports = typeof Client;
export type ReactExports = typeof ReactIntegration;
export type ReactContext = ReactIntegration.ChatContextValue<"typing">;
export type ReactProviderConfiguration = ReactIntegration.ChatProviderProps<"typing">;
export type ReactChatActions = ReturnType<typeof ReactIntegration.useChatActions>;
export type ReactConversationQuery = ReturnType<
  typeof ReactIntegration.useConversation
>;
export type ReactMessagesQuery = ReturnType<typeof ReactIntegration.useMessages>;
export type ReactDirectoryUsersOptions = ReactIntegration.DirectoryUsersQueryOptions;
export type ReactDirectoryUsersQuery = ReturnType<
  typeof ReactIntegration.useDirectoryUsers
>;
export type ReactSavedMessagesQuery = ReturnType<
  typeof ReactIntegration.useSavedMessages
>;
export type ReactMessageRemindersQuery = ReturnType<
  typeof ReactIntegration.useMessageReminders
>;
export const reactProviderConfiguration = {
  config: {
    endpoint: "/api/chat",
    getAccessToken: () => "token",
    features: { typing: true },
  },
} satisfies ReactProviderConfiguration;
declare const externalChatClient: Client.ChatClient<"typing">;
export const reactProviderClient = {
  client: externalChatClient,
} satisfies ReactProviderConfiguration;
export type ServerExports = typeof Server;
export type TestingExports = typeof Testing;
export type TestingBackend = PostgresTestBackend;
export type TestingHarness = PostgresTestHarness;
export type TestingSurface = HandrailChatTesting.Surface;
export type UiExports = typeof Ui;
