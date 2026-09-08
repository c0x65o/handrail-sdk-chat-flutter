# SDK repository split

Status: source extracted; consumer and runtime cutover validation is in progress.

## Ownership

- `handrail-sdk-chat-js` owns `@handrail/chat`, including browser/client, React,
  UI, Node server, examples, and TypeScript checks. Its public package name and
  subpath exports stay compatible.
- `handrail-sdk-chat-flutter` owns `handrail_chat` at its repository root,
  including widgets, Dart tests, the timeline lab in `example/`, and the native
  integration example in `examples/flutter-erp/`.
- `handrail-chat-preview-flutter` remains the executable Mobile Preview host.

The migration started from source commit
`1f97255bcff4e0aab6c8071783aebdccb886380d`. The original checkout is retained.
Historical validation documents retain their original paths and revisions as
provenance; they are not new validation evidence. Build outputs are reproducible
and are not copied into the new SDK source repositories.

## Shared contracts

The sibling JS repository is authoritative for `contracts/`, generators in `scripts/`,
`conformance-tests/`, and shared `test/fixtures/`. Generators emit TypeScript
contracts plus golden Dart outputs in `contracts/generated/dart/`. The latter
are generator artifacts, not another Flutter SDK.

`npm run sync:flutter-contracts` copies the shared fixtures and generated Dart
contracts to the Flutter repository and writes `shared-contracts.lock.json`
with their SHA-256 hashes. Do not edit those copies independently.
`npm run check:flutter-contracts` verifies the paired snapshots without writes.
Flutter tests read their local copies (shared JSON fixtures live in
`test/shared-fixtures/`; Flutter-owned Dart fixtures stay in `test/fixtures/`), so standalone testing requires neither
this repository nor Node.

For cross-repository development, set `HANDRAIL_CHAT_FLUTTER_ROOT` to the Flutter
SDK checkout. The default is the sibling `../handrail-sdk-chat-flutter` checkout.
This is a test-tool checkout location, not a package dependency override.
`npm run check:conformance` verifies the snapshot, public capability citations
against both SDKs, and matching Dart/TypeScript fixture outcomes.

Paired CI checks out the Flutter revision frozen in `sdk-compatibility.json`.
All consumers use public HTTPS Git dependencies at full committed SHAs with
matching npm/pub lockfiles. The Flutter demo is a Git subdirectory package;
Pub resolves its relative SDK dependency within that same Git revision.

## Consumer revisions

- JS: `90bff33529df06720ff89ccd821360ac65eaf0d0`
- Flutter: `51bc3e1411858ce38980f5beded683dee957d1a3`

The JS examples, Flutter lab, native example, and Mobile Preview have matching
Git pins. Normal npm install/ci runs the SDK prepare build. Do not disable
install scripts. npm may canonicalize a GitHub lock entry to SSH when updating
it; retain the same SHA and use the manifest's public HTTPS URL in `resolved`,
then verify with `npm ci` (which preserves the lockfile).

The original repository stays attached until the owner retires it. Historical
logs and screenshots can contain old paths; those are evidence, not active
checkout dependencies. Two historical hand-written scripts found under the
original `build/` directory are preserved in the JS repository's
`docs/sdk-split-archive/`.

See `sdk-extraction-validation.md` for checks and outstanding retirement steps.

## Chat Lab setup

From the JS repository, run `npm ci --include=dev` followed by
`npm run setup:lab`. This installs the locked JS consumer and compiles the
Flutter lab using its Git-installed SDK. The normal service start command is
`npm run build && npm --prefix examples/drop-in-react run dev:lab`.
Handrail also has a dev task named **Prepare Chat Lab dependencies and Flutter
assets** for this setup. Compile before startup because Handrail requires a
listener within 30 seconds and a clean Flutter build takes longer.
