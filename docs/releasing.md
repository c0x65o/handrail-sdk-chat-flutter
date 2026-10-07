# Flutter releases

The root `pubspec.yaml` owns the `handrail_chat` package version. The JavaScript
SDK owns its separate version sequence; the two versions need not match.
`lib/src/package_metadata.dart` is a pure-Dart mirror exported by `core.dart`,
so clients can send the package identity without Flutter or runtime file I/O.

Handrail's native version writer reads `.handrail/version-mirrors.json` and
updates the manifest and Dart constant together. Its `text_templates` entry
must match the previous canonical version exactly once. Invalid declarations,
stale constants, or missing/duplicate matches reject the bump before the
canonical file is written. Keep the declaration in source snapshots and release
review artifacts. Do not pre-increment the version for a repair or manually
maintain a second version sequence in Dart.

1. Resolve dependencies with `flutter pub get --no-example`, then run the
   read-only guard **before any generation, contract sync, or version writer**:

   ```sh
   dart test test/core_import_boundary_test.dart
   ```

   The guard compares the public constant with the checked-in manifest, checks
   the native mirror declaration, and traverses the pure-Dart import graph.
   Do not regenerate source to make an initially failing guard disappear;
   retain the failure and review the correction. Dependency resolution does
   not generate this metadata. The normal Flutter test CI also runs this guard.
2. Run `flutter analyze --no-pub lib test` and relevant tests, including
   `flutter test --no-pub --concurrency=2 test/realtime_session_transport_test.dart`.
   Verify the minimum Flutter 3.19.0 / Dart 3.3.0 and supported Flutter 3.41.7 /
   Dart 3.11.5. Disposable scoped source snapshots may omit example/cache state
   following the existing compatibility procedure, but must include `.handrail`.
3. Obtain independent review of the complete uncommitted candidate. After review
   and resolution of publication holds, Handrail owns the subsequent version
   bump, commit and push through native Work Request finalization with
   `auto_commit_push=true` and `auto_deploy_env=null`. Reconcile concurrent work
   before finalization; the native path stages all dirty files.
4. Inspect manifest, declaration and Dart constant in the actual new published
   SHA before any generation. Reconcile it with the reviewed candidate, allowing
   the expected native version bump. Repeat clean consumer installation,
   analysis, public-import and package-version checks on both toolchains using
   the public HTTPS Git URL pinned to that full SHA and matching `pubspec.lock`.
   An unpublished source fixture cannot establish this later consumer gate.

There is no package-registry publication or deployment step. Full runtime,
threads/settings, UI and huddle/media QA remain separate gates. Hitcents ERP
changes still require the owner's readiness/integration approval.

## Read acknowledgement and decoration release scope (2026-10-07)

The reviewed decoration correction is qualified on Flutter 3.19.0/Dart 3.3.0
and 3.41.7/Dart 3.11.5. Reuse its exact source/lock and layout, lifetime,
compiler and ordinary-browser evidence in
[the independent review](validation/ack-release-review-20261007/review.txt)
when those runtime bytes are unchanged. This does not clear the historical
13 full-analysis infos, seven full-suite failures, semantics-enabled toolbar
typing failure, device/provider/staging checks or Preview 126/120 acceptance.

Published Flutter 0.1.32 already requires the canonical HTTP read outcome,
including `reconciliationStatus` and the request's `idempotencyKey`. Its
parser/read runtime/visibility bytes are unchanged in 0.1.33 and this candidate;
the corrected JS server supplies the missing fields. Do not relax Flutter
parsing or send transport metadata into strict canonical Result/event helpers.

The companion JS `docs/releasing.md` records the actual eight-case public HTTP
matrix: old non-durable JS 1.0.54 readers reject the corrected server, whereas
the candidate non-durable reader also works with the legacy server. Upgrade
those readers first, or coordinate the reader/server rollout. Durable JS and
Flutter need the corrected server; the reader patch alone cannot make the
legacy producer's incomplete outcome valid. Other historical JS pins are not
blanket-qualified. Preview's root server/React upgrade and exact installed
consumer checks remain parent-owned and separate from this Flutter publication.

JS owns the shared snapshot. Use its `scripts/sync-flutter-contracts.mjs` for
the exact vendor fixtures and lock, then verify the intended pair with
`check:flutter-contracts`, `check:capabilities` and bounded `check:conformance`.
Paired CI uses the frozen `sdk-compatibility.json` revision; a passing sibling
workspace pair does not certify that separate frozen pin. Publish only the
reconciled reviewed sources through native finalization, verify the immutable
commit and version mirror, then install public HTTPS full-SHA pins and matching
locks for the combined consumer acceptance.
