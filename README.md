# handrail_chat

The Flutter and Dart SDK for Handrail Chat. One package provides the headless
client, Flutter lifecycle bindings, optional composable UI, native media
contracts, and deterministic testing helpers.

## Installation

The package now lives at the root of `handrail-sdk-chat-flutter`. Install from
`https://github.com/c0x65o/handrail-sdk-chat-flutter.git` at a full committed SDK
SHA with a matching `pubspec.lock`. The extracted source is awaiting its first
committed revision; do not pin the initial empty scaffold or use a path dependency.
See [migration status](docs/sdk-repository-split.md) for the remaining cutover.

Import only the surfaces the host needs. All five are libraries in the same
versioned package:

```dart
import 'package:handrail_chat/core.dart';
import 'package:handrail_chat/flutter.dart';
import 'package:handrail_chat/ui.dart';
import 'package:handrail_chat/media.dart';
import 'package:handrail_chat/testing.dart';
```

## Realtime replay cursor storage

`ChatRealtimeCursorStorage` is optional. When it is configured, construct
`ChatRealtimeSessionTransport` with `cursorStorageScope` and isolate every
adapter read, write, and clear by the scope passed to that operation. The scope
must be a trimmed, nonblank host identity string no larger than 256 UTF-8
bytes. Derive it before realtime starts from the trusted login boundary, keep
it stable across reconnects and process restarts for that identity, and include
any account/device boundary required by the host storage model. Never derive it
from access-token contents or an identity reported by an unaccepted socket, and
never place tokens, credentials, or other secrets in it.

Transports without cursor storage do not require a scope. Storage reads remain
fail-open, while required durable-event writes retain the existing recovery
ordering guarantees.

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
does not provide shared-writer coordination.

## Headless and custom UI

The client exposes public controllers, immutable state, streams, and commands
without requiring a particular state-management package. A custom host can
create one long-lived `HandrailChatClient` and observe a conversation directly:

```dart
final conversation = chatClient.conversations.forConversation(conversationId);

ConversationStateBuilder(
  conversation: conversation,
  builder: (context, state) {
    return Text(state.conversation?.id.value ?? 'Loading conversation');
  },
)
```

## Composable UI

Under a `ChatScope`, hosts can arrange the working Handrail widgets while
retaining ownership of navigation and surrounding application actions:

```dart
Column(
  children: [
    HandrailChannelHeader(
      conversationId: conversationId,
    ),
    Expanded(
      child: HandrailMessageTimeline(
        conversationId: conversationId,
      ),
    ),
    HandrailMessageComposer(
      conversationId: conversationId,
    ),
  ],
)
```

The optional UI consumes the same public `ChatConversationController`,
`ChatTimelineController`, and immutable state available to custom hosts.

## Drop-in workspace

For a complete router-neutral chat surface, mount the workspace under the same
scope:

```dart
HandrailChatWorkspace(
  initialConversationId: conversationId,
)
```

The host can add search, member, huddle, attachment, and navigation behavior
through the workspace's public delegates and configuration.

## Flutter ERP example

The existing [Flutter ERP example](examples/flutter-erp/README.md)
documents application lifecycle and `ChatScope` ownership, host-provided
[authentication](examples/flutter-erp/README.md#api-configuration-and-authentication),
and [native platform setup](examples/flutter-erp/README.md#native-platform-policy).
Its [bootstrap implementation](examples/flutter-erp/lib/erp_chat_host.dart)
shows one long-lived client without embedding credentials or a live endpoint.
The [production composition](examples/flutter-erp/lib/erp_chat_production.dart)
adapts host connectivity and device identity, opens the `dart:io` realtime
socket, and binds cursor recovery and durable event reduction.
