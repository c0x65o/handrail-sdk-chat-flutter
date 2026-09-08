# Flutter named-thread opening and controls

Work request: `110805a9-8ff0-40a5-a2d3-f28bbac3f83a`.
Finding: `fabc23fb-fd79-474e-ab7a-e675b62c3aab`.
Campaign: `298e20b4-4faf-4283-949d-3801cf437aa8`, dev.
Source work request: `8ff41fa4-8f28-4ee9-b884-7e87614c7db5`.
Source run: `fee77ab0-0d2f-42ba-825f-82575519ddf8`.

## Failure boundary

The HTTP detail contract already declares actor-private `currentThreadFollow`.
The server emits it and TypeScript validates it. Flutter's snapshot generator
omitted it, passing the enrichment into the strict canonical conversation parser.
This rejected HTTP 200 responses, preventing opening, conversation preference
loading, composer initialization and managed snapshot recovery. Named thread and
lifecycle fields themselves were already supported.

The Flutter lifecycle controller checked the reserved contract label
`thread_lifecycle_v1` instead of the deployed handshake flag `threadLifecycle`.
Its fixtures used the same wrong label, masking the mismatch. The shared-backend
Flutter host also omitted the lifecycle capability request and host authority. The reply-styles backend explicitly grants Alice and Bob
`message.send` and `thread.manage`; the deterministic Flutter fixture configured
those permissions but the shared-backend host did not. No env variable, provider
credential, resource injection, database migration or deploy configuration change
is needed. Server authorization remains authoritative.

Before editing, Handrail current context confirmed the project and work request.
Dev-service status confirmed the healthy shared `chat-lab` on port 4167, instance
`09cc43d02b2911e0ff91788be8ae55ae`. The separately configured Mobile Preview was
stopped and is not this campaign's `/__flutter-chat-lab/` route. Same-environment
logs showed socket EPIPE/ECONNRESET errors, with no matching credential or
permission failures. Source inspection and the captured HTTP body independently
identified the parser mismatch. The earlier served-build repair is preserved.

## Changes

- Generate and validate optional detail follow authority, including canonical
  target, safe revision, explicit absence and legacy omission. Preserve it during
  round trips, outside the canonical conversation model.
- Hydrate private follow state with the existing monotonic reconciliation rules,
  atomically with the detail. Preserve pending intents and newer revisions.
- Handle watchers registered synchronously during a normalized-state commit.
  Previously publication dereferenced a missing baseline, leaving partially
  published thread/composer state despite successful HTTP reads.
- Use the canonical runtime lifecycle flag in the controller, host and fixtures;
  keep the reserved contract label unchanged.
- Bind reply-styles host lifecycle permissions once per accepted identity/device
  for hydrated existing or newly created threads, and request lifecycle support.
  Unrelated commits do not restore revoked authority or interrupt pending writes.

The live replay also exposed two related client failures after detail parsing
was repaired. The durable-event registry required `reconciliationStatus` on
read-cursor events, while `contracts/http/read-cursor.json` and the actual server
emit no such field. The registry now accepts its omission (retaining compatibility
with older fixtures that include it). The captured event is preserved in
[read-cursor-frames.json](read-cursor-frames.json). Its private-actor checks remain.

An HTTP send acknowledgement can reach Flutter before `message.created`.
Command reconciliation stores the canonical message; the durable reducer used to
return early for that message and never create its visible timeline projection.
It now installs the missing projection without replaying an existing projection,
regressing newer revisions, or lowering the latest sequence. A thread reply's root
summary is advanced only for a new sequence. This is covered for both channel
messages and thread replies, including event redelivery.

`thread.created` also carries an unrevisioned `memberUserIds` enrichment from
`src/server/create-thread-command.ts`. Flutter now validates and removes that
enrichment before decoding the canonical conversation. It does not overwrite
newer membership authority with the creation event's initial list. This prevents
creation-triggered recovery from aborting composer/preference requests.

The creation response includes `currentPreference.preferenceRevision`, while
subsequent detail reads omit it. At the same timestamp, comparing the revision's
presence as preference content raised `NormalizedSnapshotConflict`, disabling all
three post-creation controllers. Legacy preference comparison now excludes that
transport metadata, retains the known revision, and still rejects conflicting
preference values. [created-detail-sequence.json](created-detail-sequence.json)
preserves the actual creation response, detail response and `thread.created`
frame used by the regression.

## Original evidence

All three attached screenshots were reviewed. The JSON attachment paths were
absent in this worker; the five JSON artifacts were recovered through the scoped
read-only `get_goal_completed_work_result` tool, reviewed and preserved byte for
byte in [campaign/](campaign/). Local SHA-256 checks match the supplied hashes.
The snapshots show HTTP 200 alongside `conversation.detail:response_malformed`,
`snapshot_hydration_failed`, and disabled composer/subscription controls. The
canonical data confirms the existing React-created thread's retained messages
and the persisted Flutter-created thread. This was not an intentional denied-role
scenario.

Artifact references under `campaigns/298e20b4-4faf-4283-949d-3801cf437aa8/`:

| Artifact | Artifact ID | SHA-256 |
| --- | --- | --- |
| `12-flutter-thread-open.png` | `b3a5b961-75c5-48ba-ba5e-85c8cf72dd48` | `b191a7371889a497d26c35dd6bc3520098c72db3407c2c78a25205c040c7974a` |
| `30-flutter-discovery-open-error.png` | `a4e0bb9c-6422-4bd4-a0f9-0017baea7754` | `f1a9bae74a210b3549d8e6093be7f64036285e0a24b174124d66a1cc2c3e693e` |
| `42-flutter-created-thread-retry.png` | `e159e506-4301-45f2-a8eb-f20c1b145505` | `7f40fc4de6f32dc0e113310c4768485af1f36b17f0ffa5a85dae5fc60bdbe9eb` |
| `canonical-final.json` | `5d0390d1-c414-4afb-a981-0e37faef9d72` | `fa6e7a2dd32213fc53302379c999898b0a9a8ca76c66db9d05c148a21e279831` |
| `flutter-created-thread-ready.json` | `b30406f2-3038-4182-be46-ebe840ef1132` | `e98f9950ed6a3316e81ba7936617510a7bc1b04da4c0105038b7c5ce38f1b184` |
| `flutter-mobile-discovery.json` | `1378f844-dd34-41e2-996b-521a0a43d1df` | `0ca6efac00d1fe89be68f976f893df363159341fd65a604c096f821168088270` |
| `flutter-subscription-retry-outcome.json` | `7c9457a7-0b8d-4d06-89fe-ddaddf83df4a` | `22e43840a39eabd911376d4aaa5790a449667f7aff695e34c4cc876d98e09eda` |
| `flutter-thread-retry.json` | `6b5a8039-37da-46d6-b79e-5be282e8b1d9` | `8810c7446907f6a8dbbe4fcb6357993d833fe3530d3126ec3f1db4ed36ac4ff1` |

Each original artifact is available at
`/api/pm/qa-campaign-artifacts/<artifact-ID>/content`.

## Verification

- `flutter test --no-pub --concurrency=1` on snapshot parsing/querying, named
  thread regressions, host lifecycle integration, the suggested durable resource
  reducer, thread view, lifecycle controller and normalized store: 136 passed.
  [flutter-tests.log](flutter-tests.log).
- After correcting the runtime capability flag and keeping missing follow
  revisions implicit, the named-thread/host, thread-view, lifecycle, follow
  command/recovery and thread-opening suites: 113 passed.
  [thread-regressions.log](thread-regressions.log).
- Final scoped Dart analysis: no errors or warnings; 27 pre-existing generated
  durable-parser brace-style hints. [dart-analysis.log](dart-analysis.log).
- Final snapshot/event, preference and durable-reducer suites: 291 passed,
  including the suggested durable resource reducer and live read-cursor fixture.
  [final-flutter-tests.log](final-flutter-tests.log).
- Snapshot and durable contract generation/parsing: 123 passed. Both generators'
  `--check` commands passed. [contracts-tests.log](contracts-tests.log).
- Creation/detail preference compatibility and preference command/recovery
  suites: 33 passed. [creation-preference-tests.log](creation-preference-tests.log).
- TypeScript SDK compilation (`npm run build`) passed.
  [typescript-build.log](typescript-build.log).
- Flutter release web build passed. [flutter-build.log](flutter-build.log).
  The SDK is read-only in this worker; the established cached Flutter tool
  invocation from the sibling `flutter-served-provenance/README.md` was used.
  Nonfatal native-tool stamp and existing missing Cupertino font warnings remain.
- Final TypeScript `tsc --project tsconfig.json --noEmit` passed.
- Live Chromium regression: **3 passed**, against the existing dev backend.
  [browser-tests.log](browser-tests.log). Alice (desktop) and Bob (390×844) opened
  `e35ac80a-52f1-472a-b8f0-f35aa7eb9ef6` from its root and discovery, retained its
  history, and reconnected with composer/subscriptions available. Both reported
  zero browser page errors. Bob created
  `f6fc402a-2373-4346-a807-c4d38b83efbf`, posted `Friday`, left/rejoined, and performed
  close → reopen → lock/close → unlock → reopen. Creation/post returned 201;
  follow and all five lifecycle writes returned 200. Final diagnostics contain
  no malformed detail or snapshot recovery failure. The executing source digest
  matched the local build: `a39f4b842673ecba7b8250a7c6b5433688dd39e24344099e478ba2ee048387c8`.
- `git diff --check` passed.

Successful browser evidence and screenshots:
[Alice](browser/alice.json), [Alice screenshot](browser/alice.png),
[Bob](browser/bob.json), [Bob screenshot](browser/bob.png),
[creation and controls](browser/created.json),
[creation screenshot](browser/created.png).

Run the browser regression from `examples/drop-in-react` with
`FLUTTER_CHAT_LAB_ORIGIN=http://127.0.0.1:4167 npx playwright test e2e/flutter-named-threads.spec.mjs --project=chromium --retries=0`.
It targets the retained campaign data; it is skipped without the explicit origin.
The harness scrolls the virtual timeline to the campaign root and types through
Flutter's focused input before sending.

The shared parent channel returned one existing draft-revision conflict (409)
while the QA root was authored; this did not block sending. The newly created
thread's draft saves returned 200. The test records that response and excludes
parent draft synchronization from its thread-action status assertions.

The regression tests use narrow HTTP/socket boundaries and captured real HTTP
responses. The browser uses the existing PostgreSQL-backed dev Chat Lab. No
persistence queries, migrations, database resets, external providers, dependency
pins or managed environment settings changed. Browser mutation checks add clearly
labelled QA content through the application API and retain the campaign's original
roots/history. The static Flutter assets are rebuilt through the repository's
existing provenance-aware build script; the running backend instance is preserved.

[before-publication-fix.log](before-publication-fix.log) records the independently
reproduced client-side null assertion after the parser was repaired, including its
compiled `_commit` stack. Temporary debug instrumentation was removed. The
corresponding synchronous-watcher regression is in `named_thread_snapshot_test.dart`.
