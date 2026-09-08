# Handrail Chat Flutter ERP example

This mobile host demonstrates both supported Flutter integration styles:

- `HandrailChatWorkspace` as a complete drop-in screen with ERP-owned
  navigation, attachment, and notification delegates.
- A fully custom timeline built from `ChatScope`,
  `ChatTimelineController`, immutable state, and Flutter SDK primitives only.

`ErpChatBootstrap` creates and initializes one `HandrailChatClient` for the
mounted application and places `ChatScope` above the ERP `MaterialApp`.

## API configuration and authentication

The API base is a compile-time setting. Its checked-in default is the
non-production, unroutable `https://chat.example.invalid/api/chat` endpoint, so
an unconfigured checkout cannot accidentally contact a live Handrail service.

Run against a development service with an explicit define:

```sh
flutter run \
  --dart-define=HANDRAIL_CHAT_API_BASE=https://chat.dev.example.test/api/chat
```

The API base must be HTTPS, except that `http://localhost/...` is allowed for
local development. Do not put an access token in `--dart-define`, source code,
or checked-in environment files.

Authentication remains owned by the ERP host. Replace
`UnconfiguredErpSessionTokenProvider` with an implementation of
`ErpSessionTokenProvider` that reads a current, short-lived access token from
the already authenticated application session each time Handrail requests one.
The example intentionally contains no credential or fallback token.

The same host boundary applies to attachment selection. Implement
`ErpAttachmentPicker` with the ERP's existing file picker and upload policy.
For realtime lifecycle recovery, provide the host connectivity, device
identity, and realtime session factory together to `ErpChatBootstrap`;
`ChatScope` then suspends in the background and resumes from the last cursor.
[`erp_chat_production.dart`](lib/erp_chat_production.dart) is the concrete
composition: it adapts the host connectivity stream and durable device-ID
store, opens a `dart:io` WebSocket with the SDK subprotocols, requests a fresh
token for every connection, hydrates snapshots, reduces canonical events, and
supports host-owned cursor persistence. A production application can wire it
like this:

```dart
ErpChatBootstrap(
  sessionTokenProvider: erpSession,
  connectivityDelegate: ErpChatConnectivityDelegate(
    current: connectivity.currentStatus,
    changes: connectivity.statusChanges,
  ),
  deviceIdentityDelegate: ErpChatDeviceIdentityDelegate(
    securePreferences.loadOrCreateChatDeviceId,
  ),
  // A stable, non-secret host identity string; never an access token.
  identityScopeKey: signedInAccount.chatPersistenceScope,
  realtimeSessionFactory: createErpChatRealtimeSessionFactory(
    cursorStorage: secureCursorStorage,
  ),
  child: const ErpApplication(),
)
```

The connectivity plugin, secure preference implementation, push provider,
attachment picker/uploader, and operating-system notification setup stay
host-owned. Re-key `ErpChatBootstrap` and change `identityScopeKey` when the
signed-in account changes; disposal closes the client, realtime session, and
owned HTTP transport. When cursor persistence is enabled, the ERP realtime
factory validates and forwards this value as the cursor-storage scope. Keep it
stable across restarts for one login identity, include any account and device
boundary your storage model requires, and keep it within 256 UTF-8 bytes. It
must never contain access tokens, credentials, or other secrets.

## Application storage and shared writers

Stable identity scoping isolates records but does not serialize separate Flutter
engines or processes. Storage shared by concurrent writers must implement
`AtomicApplicationChatStorage` with a genuinely atomic `compareExchange` for the
exact identity-and-record-kind key. Each key includes the trusted tenant, user,
and device identity plus the record kind.

A legacy `ApplicationChatStorage` adapter is safe only when the host guarantees
one writer for that identity. `ApplicationChatStorageMutator` provides a
single-runtime legacy fallback, not coordination across runtimes. Individually
atomic `replace`/`remove` operations do not make an unconditional read-plus-replace
sequence safe across writers.

The atomic capability has these exact-value semantics:

- `readEncoded` returns the exact stored representation, not a re-encoding.
- A null `expectedEncodedRecord` means absence: the key must not exist.
- A null `replacementEncodedRecord` conditionally removes the matching value.
  A non-null replacement must encode a valid record for the supplied identity
  and record kind.
- A comparison mismatch must return `false` and leave storage unchanged.
- Quarantine malformed data only by comparing against the exact encoded value
  observed with `compareExchange(identity, kind, observedEncoded, null)`,
  preserving any newer replacement. Do not use an unconditional removal for
  shared-writer quarantine.

Derive storage scope and `ApplicationChatStorageIdentity` from the trusted host
login boundary before realtime starts. Never derive scope or identity from
access-token contents or an identity reported by an unaccepted socket. Keep
scope, persisted records, and diagnostics free of access tokens, refresh tokens,
push tokens, credentials, and other secrets. Use sanitized diagnostics; never
log raw encoded records or adapter errors that may contain secrets.

The `ChatRealtimeCursorStorage` cursor-scope contract is separate from the
`AtomicApplicationChatStorage` application storage capability. The ERP cursor
adapter does not implement that atomic capability; forwarding a cursor scope
does not provide shared-writer coordination. The `identityScopeKey` example
above configures cursor scoping only. Hosts adding application record storage
must choose an adapter that meets their writer model.

## SDK installation

The SDK lives at the root of `handrail-sdk-chat-flutter`. Consume it from
`https://github.com/c0x65o/handrail-sdk-chat-flutter.git`, pinned to a full SDK
commit SHA with a matching `pubspec.lock`. The inherited example manifest is
awaiting the first committed extracted SDK revision; follow
[migration status](../../docs/sdk-repository-split.md) before installing.

`handrail-chat-preview-flutter` is the executable Mobile Preview host. This
repository owns the SDK and its examples.

## Verification

The focused widget suite uses `package:handrail_chat/testing.dart` scripted
HTTP, connectivity, identity, and realtime fakes. It never opens a live HTTP or
WebSocket connection.

```sh
flutter analyze lib test/widget_test.dart
flutter test test/widget_test.dart
```

## Native platform policy

The iOS Runner supports iOS 15.0 and newer in its Debug, Release, and Profile
build configurations. If the iOS scaffold is regenerated, preserve that minimum
in `ios/Runner.xcodeproj/project.pbxproj`; do not add `MinimumOSVersion` to
`ios/Runner/Info.plist`.
