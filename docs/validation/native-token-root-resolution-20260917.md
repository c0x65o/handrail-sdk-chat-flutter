# Flutter root-package clean source verification

WR `fbfcb483-a3a5-4757-bb79-a7eac5f1c7a3`, run
`4d980d05-9ef1-447a-b67e-14f771c70b97`, September 17, 2026 UTC.

The requested root-package checks now pass on compliant resolutions for both
Flutter 3.41.7 / Dart 3.11.5 and Flutter 3.19.0 / Dart 3.3.0. Each resolution was
reproduced from its generated lock in a second source copy with a separate empty
pub cache. No product source, manifest, checked-in lock, version mirror, SDK
floor or package version changed. This report is the only repository addition.
Independent review and runtime acceptance remain pending.

## Candidate and preparation

Flutter HEAD: `fa2572fb27aa5eb742c197e0766a7c602d2b3ff6` (initially clean).
JS HEAD: `b8f9e3ab5e27cf3d29649eb29e066ad92d99d21d`.
Preview HEAD: `e40655c780776ab933043609d8d2a410e9677d26`.
The package manifest, exported constant and native mirror declaration agree on
`0.1.26`; they were checked before resolution, without generation. The advertised
Flutter >=3.19.0 / Dart >=3.3.0 <4.0.0 floor remains intact.

Root CI pins Flutter 3.41.7 and runs `flutter pub get --no-example`. The initial
source copies contained tracked and nonignored files, including `.handrail`, but
no installed `.dart_tool`, build output or pub cache. The current toolchain used
a task-owned copy of its launcher, Flutter packages and mutable cache metadata,
with immutable installed SDK/engine directories linked read-only. Its identity
is framework `cc0734ac716fbb8b90f3f9db8020958b1553afa7`, engine
`59aa584fdf100e6c78c785d8a5b565d1de4b48ab`, Dart 3.11.5.

The minimum SDK was downloaded from the official Flutter archive, checked
against the official release manifest, and extracted in task scratch. Archive
SHA-256: `4cc1706fbd6e2a5c0ee34a6f8de875aae20904c9f47e18c88d2fcb25d9ea1a79`.
Its framework is `bae5e49bc2a867403c43b2aae2de8f8c33b037e4`, engine
`04817c99c9fd4956f27505204f7e344335810aed`, Dart 3.3.0.

On 3.19, the first full source copy's `pub get --no-example` returned exit 1
after resolving root dependencies: Flutter attempted to update the absent
`example/.dart_tool/package_config.json`. Its tool implementation updates the
example package config when an example exists even after this pub invocation
skips example resolution. No tests used that failed preparation. New root-only
copies omitted `example/` and `examples/`, as allowed by `docs/releasing.md`'s
scoped snapshot procedure. All root source, tests, contracts, manifest, original
lock and `.handrail` bytes were retained. The same resolution command then
succeeded. This establishes root-package compatibility, not minimum-toolchain
preparation of the entire checkout or either example.

## Fresh compatibility matrix

| Check | Flutter 3.41.7 / Dart 3.11.5 | Flutter 3.19.0 / Dart 3.3.0 |
| --- | --- | --- |
| Pre-generation manifest/constant/mirror guard | Pass | Pass |
| Clean root `pub get --no-example` | Pass; 24 dependency changes from old lock | Pass in root-only copies; initial full-copy failure retained |
| Second empty-cache `pub get --no-example --enforce-lockfile` | Pass | Pass |
| Generated lock bytes and resolved dependency library hashes reproduce | Pass | Pass |
| Actual versioned dependency pubspecs match generated lock | Pass; zero mismatches | Pass; zero mismatches |
| `core_import_boundary_test.dart` | 3 pass in each copy | 3 pass in each copy |
| `realtime_session_transport_test.dart` | 18 pass in each copy | 18 pass in each copy |
| `durable_resource_event_reducer_test.dart` | 44 pass in each copy | 44 pass in each copy |
| Scoped Flutter analyze, 7 items | No issues in each copy | No issues in each copy |
| Extra pure-Dart core boundary | Default runner fails; supported `--compiler=source` passes 3 | Default runner passes 3 |

These are 65 distinct focused cases per execution, repeated across two copies
and two toolchains. The direct Dart cases overlap the Flutter cases. This is
not a full root suite or full `lib test` analysis claim.

Both resolved graphs contain 61 package-config entries including the root.
`flutter_lints` is 4.0.0 and `unorm_dart` is 0.3.2 in both. Current resolution uses
test 1.30.0 / analyzer 10.0.1; minimum uses test 1.24.9 / analyzer 6.4.1.

| Lock | SHA-256 |
| --- | --- |
| Current generated A and enforced B | `9cc9a01c8d02359a78e4aae7ecf457fdad366bb80abee4b5cc8281395a8bb3dd` |
| Minimum generated A and enforced B | `eea72d79596aa8f25711079ebe30b6f8b9de269bcb9d92a4bb4576c9aee4e392` |

The supplemental current `dart test` failure is a test-tool dependency issue:
normal get retained frontend_server_client 3.2.0, which requests the removed
`frontend_server.dart.snapshot`. The installed Dart SDK has the newer AOT
snapshot. Running the same resolved package:test with its supported
`--compiler=source` mode passes without dependency edits. The original default
command remains failed; do not relabel it or silently upgrade the repository
lock. Follow-up is needed if default `dart test` on 3.11 is itself required:
prepare and independently verify a compatible transitive resolution separately.
No repository-source defect was demonstrated by the required Flutter checks.

Checks ran sequentially in the worker's delegated heavy-command cgroup. Maximum
reported child RSS was 799,976 KiB. The cgroup peak was 4,164,771,840 bytes;
inspection after the SDK download/extraction and checks found no live processes,
zero anonymous memory, about 2.98 GB of file cache and 159 MB of reclaimable
kernel slab, with zero OOM events. This distinguishes cached archive/SDK/package
bytes from a continuing test-process memory leak. No worker limit was changed.

## Reproduction and retained evidence

Use the retained `reproduce.md` and `preparation-scripts.txt`. Preserve the
original root lock in the checkout; allow normal resolution to update it only
inside disposable A. Copy that generated lock into fresh B, with its own empty
cache, and enforce it there. Never copy the historical installed package config.
Run sequentially under the worker's delegated heavy-command cgroup and with
Flutter concurrency 2. Scope analysis to:

```sh
flutter test --no-pub --concurrency=2 --reporter=expanded \
  test/core_import_boundary_test.dart \
  test/realtime_session_transport_test.dart \
  test/durable_resource_event_reducer_test.dart
flutter analyze --no-pub lib/core.dart lib/src/package_metadata.dart \
  lib/src/realtime_session_transport.dart \
  lib/src/core/durable_resource_event_reducer.dart \
  test/core_import_boundary_test.dart \
  test/realtime_session_transport_test.dart \
  test/durable_resource_event_reducer_test.dart
```

Use `--no-pub` only after successful compliant resolution. Exact argv, ordering,
paths, environment, exits and full output are in `commands-results.json`.
`resolutions.json` retains exact generated locks, package configurations,
dependency versions, pubspec hashes and library-content hashes, including the
failed minimum preparation's outputs. `source-audit.json` retains the initial
revisions, inventories and preexisting diffs. `verification.json` records final
byte comparisons and cleanup; `toolchains.json` records tool and archive
identities. Selected evidence is read back and hash-checked before disposable
state is removed. Server artifact collection and final independent acceptance
must still be checked by the existing Task lead.

## Preserved history and remaining gates

The four supplied artifacts from WR `36d770d0-08c2-4b3c-b486-c3df7bf4d1a0`
are preserved verbatim with their original saved IDs and SHA-256 values in
`historical-inputs.json`. Its 21 installed-resolution Flutter passes, 46 version
mismatches and read-only cache failure remain historical evidence. They are not
reclassified as clean results. The current clean runs above close that narrow
root-package evidence gap.

Settled React review WR `c7cd9106-8130-433f-867a-9168f60d4886` remains passed
as supplied. Its two runner scripts, regression test and
`docs/validation/source-evidence-gaps-20260917.md` are unchanged. No JavaScript
or browser suite was rerun. Retained JS source/package identities remain
`c4c43f31c86fd830e1cab8b3d1623d3cd8ce7b74af00dbc89fa974ff891c35fc` /
`fd2f6f8575e70977c63c5f15ee225b5b4036abad7a07e3a1b78a824f9ba429e8`.

Preserve failed native operation `822b6d83-d082-4d30-a0a4-e82d502e42b6` and
run `1f411d6e-6a69-480f-add5-186edcd004ad`, operation
`f339e179-8ef9-4fcc-9e11-5e2430026512`, and all earlier planning/platform
repair failures and corrections. The example's enforced-lock preparation
remains a separate dependency; no setup, native lifecycle, deployment or reset
was attempted. Main synchronization remained deferred as
`main_workspace_in_use`; disposable copies avoided any source or Git repair.
No Git mutation command, commit, push, publication, database/queue edit,
production/provider message, ERP edit or Handrail platform edit occurred.

The existing Task lead must independently review these exact evidence bytes,
then continue the existing SDK-example preparation repair through its supported
controls. Native dev delivery and served candidate identity, actual
administrator create/list/revoke UI and external contact-form HTTP proof,
denied channels/revocation/persistence, verified clean-state repetition and the
second build-status payload remain mandatory and unverified. Historical server,
PostgreSQL, component and browser evidence keeps its original applicability;
these root-package tests provide no runtime acceptance credit.
