export const hostDirectoryMetadata = {
  packageVersion: "0.1.2",
  protocolVersion: 4,
  schemaVersion: 9,
  enabledFeatures: { directorySearch: true },
  supportedProtocolRange: { minimumVersion: 4, maximumVersion: 4 },
  feature: { name: "host_directory_snapshots", version: 1 },
};

export const activeDirectoryUsers = [
  {
    kind: "active",
    userId: "host-user-image",
    displayName: "Avery Image",
    avatar: {
      kind: "image",
      url: "https://assets.example.test/avatars/avery.png",
      altText: "Avery",
    },
    status: {
      availability: "online",
      text: "Helping customers",
      emoji: "👋",
      expiresAt: "2026-08-25T23:00:00.000Z",
    },
  },
  {
    kind: "active",
    userId: "host-user-initials",
    displayName: "Blake Initials",
    avatar: { kind: "initials", initials: "BI" },
    status: { availability: "away" },
  },
  {
    kind: "active",
    userId: "host-user-none",
    displayName: "Casey No Avatar",
    avatar: { kind: "none" },
  },
  {
    kind: "active",
    userId: "host-user-relative-image",
    displayName: "Devon Relative",
    avatar: { kind: "image", url: "/api/users/devon/avatar" },
    status: { text: "Heads down" },
  },
];

export const redactedDirectoryUser = {
  kind: "redacted",
  userId: "host-user-redacted",
};

export const missingDirectoryUser = {
  kind: "unavailable",
  userId: "host-user-missing",
  reason: "missing",
};

export const temporarilyUnavailableDirectoryUser = {
  kind: "unavailable",
  userId: "host-user-unavailable",
  reason: "temporarily_unavailable",
};

export const directoryUsers = [
  ...activeDirectoryUsers,
  redactedDirectoryUser,
  missingDirectoryUser,
  temporarilyUnavailableDirectoryUser,
];
