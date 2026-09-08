# SDK cutover validation

The local SDK and consumer cutover is validated. The old checkout is intact and
clean. Retirement is still blocked by the platform metadata and final commit
steps below; this report does not authorize deleting the old repository.

## Source preservation

The inventory maps **1,669** source, tooling, and documentation files from
`1f97255bcff4e0aab6c8071783aebdccb886380d`. Every mapped destination exists and
all original hashes still match. **No implementation files are missing.**
Of 291 SDK runtime source files, only generated JS package-version metadata
changed (the normal build now reports package version 1.0.20).
Two hand-written scripts originally tracked under `build/` were recovered in
`docs/sdk-split-archive/`. The 2,467 excluded paths are generated artifacts,
downloaded browser runtime files, and historical logs. The JS repository's
`sdk-extraction-inventory.json` lists every source/destination hash and excluded
artifact. Adapted files cover paths, manifests, lockfiles, tooling, fixtures,
and documentation; the SDK implementations retain their original code.

## Dependency and runtime cutover

- JS consumers pin public HTTPS Git revision
  `90bff33529df06720ff89ccd821360ac65eaf0d0` with matching npm locks.
- Flutter consumers pin public HTTPS Git revision
  `51bc3e1411858ce38980f5beded683dee957d1a3` with matching pub locks.
  The preview resolves both the demo subdirectory and SDK from that Git revision.
- Installed consumer resolutions and active source/config files have no
  dependency on the original checkout.
- JS owns shared contracts and generators; Flutter has independently testable
  generated contracts and fixture snapshots. The paired revision is frozen in
  `sdk-compatibility.json`.
- `chat-lab` is assigned to the JS repository. Its verified listener's working
  directory is the new JS example, and health/readiness both return HTTP 200.
- Mobile Preview was restarted and passes health/readiness. Its authorized dev
  proxy browser test opened the launcher, entered a workspace, returned to the
  launcher, and closed the browser. Redacted diagnostics showed successful
  requests; no app login was required for deterministic fixtures.
- Eight existing dev environment values were copied server-side to the JS repo.
  The PostgreSQL spec retained its ID and settings while ownership moved to JS.
- Existing checks/tasks target the new SDK repos. A dev setup task now runs
  `npm ci --include=dev && npm run setup:lab` before service startup.

A first lab restart exceeded Handrail's 30-second listener deadline while
compiling Flutter. Startup now runs the short build/start command after normal
setup. The subsequent start succeeded. No database or volume was recreated.

## Validation this cutover

| Check | Result |
| --- | --- |
| JS public Git install, normal prepare build, lock, exports and React runtime | Passed |
| Full JS typecheck including contract typechecks | Passed |
| Cross-client conformance and generated snapshot checks | Four suites passed |
| Drop-in React typecheck/build/browser graph/static boundaries | Passed |
| Drop-in React smoke tests | 37 passed, two workers |
| Headless React typecheck/build/browser graph/static boundaries and smoke | Passed, one test |
| Embedded server typecheck/build/authenticated HTTP and WebSocket smoke/static boundaries | Passed |
| Flutter native example analysis and tests | Passed, 11 tests, two workers |
| Flutter lab analysis, release web build and tests | Passed, 38 tests, two workers |
| Mobile Preview analysis, release web build and tests | Passed, eight tests, two workers |
| Authorized Mobile Preview proxy journey | Passed; browser closed |
| Flutter SDK analysis (lib/test) | 64 existing info diagnostics; zero warnings/errors; strict exit 1 |
| Original checkout preservation and active reference audit | Passed |

Consumer validation exposed stale example fixtures. They now supply required
preference/member fields, demonstrate the LinkPreview override, and test User
slot rendering separately from channel headers. The embedded fixture explicitly
rejects unsupported device push-token operations and supplies current snapshot
fields. Static checks recognize the public Git dependency, host media signaling,
and test transport doubles; chat components retain transport boundary checks.
The theme guide now includes all 74 declared CSS tokens.

Earlier extraction validation also passed 698 focused Flutter tests and 146
Node generator/conformance-runner tests. The earlier broad Node suite had
2,734 passes, 111 failures and seven cancellations. The broad Flutter run stalled
and was interrupted; the same widget-builder case also stalled in the original
checkout. Representative broad Node failures reproduce in the original. These
full-suite results are not claimed green or replaced by the scoped passes here.

## Remaining retirement steps

1. Commit/push the final changes in JS, Flutter, and Preview, including the two
   recovered historical scripts and the source inventory. No commits or pushes
   were made in this turn because the owner has not explicitly authorized them.
2. Once the Flutter manifest/lock follow-up is pushed, pin the JS paired CI
   revision to that actual new commit and verify its frozen checkout. The
   current frozen revision has the extracted SDK but its example manifest still
   has the inherited local path; local consumer manifests are already fixed.
3. Select **handrail-sdk-chat-js** as primary in Config > Repos. There is no
   primary-selection mutation in the available Dev Chat tools.
4. Repair ownership of the existing materialized PostgreSQL resource
   `c699099d-668d-4a0f-a5a0-7f52923f3e32` (`handrail-chat-db`). Its declaration
   `a6d98e4b-d928-4c47-8fbc-611de08667a5` now belongs to JS, but a successful
   `materialize_project_resources(env=dev)` returned action `unchanged` with the
   old repo ID on the materialized row. The available tools can configure the
   spec and inspect/start the resource, but cannot reassign that existing row.
   Preserve the existing database and data while repairing this platform link.
5. Recheck repository/resource ownership after those steps, then the owner can
   retire the old repo. It remains intact and attached.

Detailed local logs, redacted browser evidence, and state are under
`.handrail/sdk-split/` in the project workspace.
