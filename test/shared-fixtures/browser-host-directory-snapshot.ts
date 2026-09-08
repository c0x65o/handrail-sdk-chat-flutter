import {
  createHostDirectorySnapshotMetadata,
  decodeHostDirectorySearchCursor,
  encodeHostDirectorySearchCursor,
  parseHostDirectoryBatchLookupInput,
  parseHostDirectorySearchResult,
} from "@handrail/chat/client";

const cursor = encodeHostDirectorySearchCursor({
  query: "avery",
  continuation: "host-page-2",
});

export const browserHostDirectoryProof = {
  cursor: decodeHostDirectorySearchCursor(cursor),
  batch: parseHostDirectoryBatchLookupInput({ userIds: ["host-user-1"] }),
  result: parseHostDirectorySearchResult({
    kind: "host_directory_search",
    users: [],
    page: { nextCursor: cursor },
    _meta: createHostDirectorySnapshotMetadata({
      packageVersion: "0.1.2",
      protocolVersion: 1,
      schemaVersion: 0,
      enabledFeatures: { directorySearch: true },
    }),
  }),
};
