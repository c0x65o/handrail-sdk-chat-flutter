# SDK repository split

Status: extraction in progress; the old repository is not ready for deletion.

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
Its revision is deliberately unset until an actual extracted SDK commit exists.
The gate fails explicitly for an unset revision rather than testing an empty
scaffold or an arbitrary branch.

## Consumer cutover still required

The new repositories currently have only scaffold commits remotely. Their
uncommitted extracted SDK source cannot be installed using the required public
HTTPS Git dependency pinned to a full committed SHA. No SDK revision is invented.

After the owner authorizes the needed commits and pushes:

1. Resolve the committed SDK revisions and fill `sdk-compatibility.json`.
2. Replace inherited local SDK dependencies in the JS examples, Flutter lab,
   native example, and Mobile Preview host with the new public HTTPS Git URLs
   and full SHAs. Generate and verify matching npm/pub lockfiles. Retain SDK
   compilation in normal install/build commands.
3. Validate consumer builds and tests against those exact revisions.
4. Move the Handrail chat-lab service to the JS repo. The existing Flutter
   check and three Flutter tasks have already moved to the Flutter repo, and
   the PostgreSQL acceptance task now targets the JS repo. The Mobile Preview service stays on the
   existing preview host repo. Validate its authorized proxied browser route.
5. Confirm no active check, task, service, or consumer still needs the old repo
   before the owner deletes it. Keep the original repo attached until then.

Do not commit, push, delete/detach the original, rewrite Git history, or open a
PR without explicit owner authorization.

## Flutter lab source selection

The JS conformance and browser workflows use the same frozen Flutter peer revision.
Set `HANDRAIL_CHAT_FLUTTER_ROOT` to select a non-sibling checkout, including CI's
`.sdk-peers/flutter` path. The lab build, serving path, and storage browser test
use that same selection.

The lab build resolves its existing lockfile before compilation and builds with
`--no-pub`. Its source fingerprint reads the `handrail_chat` package selected by
Dart's package configuration, not an adjacent uncompiled SDK checkout. Diagnostics
include the lab revision and resolved SDK revision. A missing resolved SDK is an
error; there is no fallback to the old monorepo.
