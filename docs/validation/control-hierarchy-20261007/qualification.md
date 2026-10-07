# Flutter control hierarchy qualification — 2026-10-07 UTC

The two scoped SDK UI defects are corrected in the workspace: Workspace composes its navigation/settings into one ThreadView header, and each formatting control exports one native actionable semantic node. **Toolbar typing with CanvasKit semantics remains broken. This is not Preview, staging, native-device, or whole finish-line acceptance.** Parent owns independent review and any scoped publication.

Work request `40c0737a-59dd-419e-a2c8-b430df27ce83`; worker `0b2d46f1-607c-47c4-aca0-5c42b74eb46a`. The Handrail current-context read confirmed scope and requirement snapshot `08346f8bc724`. Attached KB, repository release guidance, and the retained toolbar qualification/fixtures were inspected. No applicable AGENTS.md was present in the mounted ancestor/repository paths. No owner question was necessary.

## Changes and evidence

`HandrailThreadView.headerActions` is the reusable composition seam. The view still owns its useful header, subscription/preferences controller, lifecycle menu and permission checks. Workspace supplies its existing settings and dismissal widgets there and omits its duplicate surrounding heading. The same `_backPanel` callback, tooltip, icon and workspace dismissal key remain: discovery returns **Back to threads**, ordinary thread dismissal closes the panel. Neither invokes archive/delete/shared-thread lifecycle operations. Standalone `onClose` remains available by default. At widths below 400 logical pixels, the two-line title sits above wrapping actions; wider views share a row. Only the title owns heading semantics.

The formatting change merges the selected state with the native IconButton semantics; it removes the wrapper's duplicate button role and label. Material 2 retains the explicit selection state. Native labels, enabled/disabled state, actions, keyboard traversal, touch and the existing synchronous focus/draft code remain intact. No focus timing variant, runtime cache patch, editor replacement or host workaround was introduced. Nearby composer wrappers were inspected; none was changed without the same demonstrated defect.

[Before/after rendered gallery](gallery.md) contains unmodified Flutter raster captures at 320/390 and desktop widths, including long titles, denied controls, keyboard toolbar scrolling and actual CanvasKit captures. The thread renders are real Flutter widget renders with installed fonts and deterministic HTTP fixtures, not screenshots of Preview. Browser toolbar screenshots use release CanvasKit. The code-block widget raster has the test renderer's fallback monospace glyphs; use the browser toolbar images for browser typography.

New interaction tests exercise all seven formatting controls under Material 2 and 3, checking one exported node, its label, disabled action absence, selected state, actual accessibility activation, touch toggling and canonical draft writes. Existing keyboard/platform editing tests remain. Thread tests exercise settings, subscription follow, lifecycle menu permissions, dismissal callbacks without lifecycle writes, Back/Escape/reopen, retained draft and a real fixture HTTP 403. Existing tests continue to cover lifecycle transitions, preferences, authority revocation, system Back and focus restoration. Five existing named-thread tests now address Workspace's retained dismissal key instead of the removed duplicate ThreadView button.

The same 23 new cases on unchanged runtime produced **19 failures / 4 passes**: 14 duplicated-format semantics failures, three duplicated-dismissal failures, and two narrow title/action layout failures. The candidate passes **23/23**, with paired captures. Chromium's native accessibility tree independently fails the one-Bold-button assertion before and passes afterward: two buttons become one named actionable button. Flutter's selected flag appears as `aria-current=false/true` in this renderer; it is not reported as `aria-pressed`. See `before-ax.json`, `candidate-ax.json`, `ax-checks.json` and `semantic_state_check.mjs`.

## Verification

| Check | Result |
| --- | --- |
| Flutter 3.41.7 / Dart 3.11.5 focused suite | **360 passed**, `current-focused-final.txt` |
| Minimum Flutter 3.19.0 / Dart 3.3.0 same suite | **360 passed**, `minimum-focused.txt` |
| Changed runtime and parent test analysis, both | **Passed**, no issues |
| Full `lib test` analysis, both | **Failed with the same 13 baseline informational findings**, no new findings; `analysis-comparison.json` |
| Current candidate and minimum release CanvasKit builds | **Passed**, `candidate-build.txt`, `minimum-build.txt`; `ui_probe.dart` retains Workspace/ThreadView in compilation as well as the composer |
| Current unchanged SDK/plain release build | **Passed**, `current-runtime-build.txt` |
| Current unchanged SDK/plain Bold browser, 1050/390 | Semantics: **1 passed / 7 failed**. Ordinary: **8 passed** |
| Candidate Bold browser, 1050/390/320 | Semantics: **0 passed / 6 failed**. Ordinary: **6 passed** |
| Native browser formatting node count | Before: 14 nodes for seven controls. After: seven nodes, one per control |
| `git diff --check` | **Passed** |
| Historical full SDK suite | **Not rerun**; retained **2,471 passed / 7 failures**, not relabelled as passing |

The focused suite includes the version/import guard, composer, Workspace, ThreadView, durable reducer, realtime transport, draft runtime, offline send queue and pump. Post-send, matching-echo, identity and cancellation guards remain. The original six platform toolbar compatibility cases and **all 87 inherited test lines** are preserved byte-for-byte as one block, verified in `source-hashes.json`. Passing widget/platform-channel tests are not browser typing or OS IME proof.

The browser cases use real pointer/Tab/Enter and keyboard text, require the immediate first `X` and continued ` next`, inspect accepted controller/caret, draft and serialized localStorage, and retain delayed acknowledgement/repeated-input checks on accepted cases. There is no post-action refocus or input assignment. Current before/after SDK typing both fail the matched 1050/390 semantics cases; the historical intermittent keyboard passes remain historical evidence, not a guarantee or an erased failure. Browser pointer tests at phone widths are viewport tests, not physical phone qualification.

## One newer official stable runtime

Resolved via the official [Flutter SDK archive](https://docs.flutter.dev/install/archive) and [Linux release manifest](https://storage.googleapis.com/flutter_infra_release/releases/releases_linux.json), retained locally as `releases_linux.json`. No newer supported cached copy was found. An isolated vendor archive was downloaded, checksum-verified and extracted; global Flutter and Preview settings were not changed.

- Version **3.47.6**, Dart **3.13.5**, official stable release dated 2026-10-01.
- Framework commit **`5fc346839b5d0eef006ed8404392afb4dfae428d`**; extracted Git HEAD and `flutter.version.json` agree.
- Archive **`stable/linux/flutter_linux_3.47.6-stable.tar.xz`**, 1,577,721,284 bytes.
- SHA-256 **`f1631b9c2c8b3529323db412b0d1beacf4a748f8783b0d7cf599a8fd5f461675`**; downloaded digest matches the official manifest.

The newer and current comparisons use **identical unchanged `.32` SDK library bytes and identical SDK/plain-control probe source**, verified in `runtime-comparison.json`. The fixture only adds a semantics on/off switch and read-only rendered geometry/focus telemetry for ordinary-mode automation. The plain control remains the original synchronous focus control. Already-rejected timing variants remain in the old fixture archive but were not retested or shipped. Flutter-owned dependency versions resolve separately and both exact locks are retained.

On 3.47.6, desktop/phone-width pointer + keyboard Bold cases yield:

- Semantics enabled: **3 passed / 5 failed**; all four SDK/plain pointer cases fail. SDK phone keyboard also loses the first character.
- Ordinary mode: **8 passed**, including controller/durable-draft checks for accepted SDK cases.

**The comparison stopped at this failure. No expanded newer-runtime lifecycle matrix, nightly investigation or automatic adoption followed. There is no qualified supported-runtime upgrade path from this result.** Ordinary-mode success does not waive accessibility failure. All raw failures, screenshots, source archive, exact compiled JS and build hashes remain here.

## Source custody

Flutter remains **0.1.32 / `2d095ba5a0f86e4aa0b12ba8432500e3edfb576f`**, with workspace edits only. Manifest, package version mirror, native writer declaration, SDK minimum, lock and full-CI/autoskip configuration are unchanged. JS remains **1.0.54 / `248fb8890b8e7e1ba15799aff06ef48156cca451`**; companion remains **0.1.21 / `9dabb1c666443ed913d0400698beabfe6a7509a1`**.

[Exact run-only source diff](source.diff) SHA-256: **`16378ba34a226a2c53e7769a6d45531f2a6fa3f12d67129197ee62ff0836ac88`**. It compares against the retained previous qualification source, so it excludes the inherited 87-line addition; `inherited.diff` preserves that addition separately.

| Runtime source | Candidate SHA-256 |
| --- | --- |
| `handrail_message_composer.dart` | `9afd36dadd0284e986bfe50d52d0e0df5110a4212bf17d374d21f438fb65c964` |
| `handrail_thread_view.dart` | `40215ed47a9f6fffdc74e3b5b7184825d1ac704d0be2df3cbcef6dce64cfdf94` |
| `handrail_chat_workspace.dart` | `3105d2ec80f4b62bf59a7380a301fe0e3bda084f8180ac40f6a813c8adee085f` |

The before composer hash is the requested **`0ce967b86b4b1914c2eb3da4e8be3bc7be6f16819cacf91cdc7c6b0982cf36c6`**. Current/minimum compiled candidate library bytes match the workspace. `custody-after.json` checks all 2,009 tracked JS files, 30 companion files and 1,068 Flutter/prior-evidence paths against initial custody. Only the seven intentionally edited tracked Flutter source/test files differ; three new test parts and this new evidence directory are added. Every prior evidence/archive file is unchanged. No commit, push, PR, publication, deployment, queue/database write, provider/credential work or external report/message was performed. The active Preview consumer elsewhere was not changed or qualified.

## Remaining gates and retained unsuccessful attempts

The semantics-enabled toolbar input defect, system/browser IME and native iOS/Android device behavior remain unresolved/unverified. Link, attachment/mention and lifecycle qualification after a successful accessible pointer toolbar action remains blocked by that prerequisite. Parent must independently review these two UI fixes and decide any separately scoped publication; Git-installed consumer verification, Preview and live staging acceptance are not established here.

The new semantic-action test also exposed the **unchanged Link dialog Cancel controller-lifetime defect**. `baseline-link-cancel.txt` reproduces it on the original runtime with `link_cancel_reproduction.dart`: a disposed TextEditingController is still read during route dismissal. The scoped Link regression checks accessible opening and disabled state; it does not claim cancellation is fixed. The failing reproduction is retained in the baseline source fixture for follow-up, without broadening this runtime diff.

Early qualification attempts are retained with distinct names: an incorrect test settings class; counting merged internal semantics children instead of exported nodes; late test semantics-handle disposal; premature `pumpAndSettle` with pending fixture work; old tests targeting the intentionally removed button; and an incorrect permission test assumption (host send authority is not the same as an HTTP 403). An initial broad run enabled screenshot boundaries globally, affecting a fixture replacement test; the final broad run uses normal widget trees and the separate 23-case render run enables evidence. Initial analysis setup omitted the private Flutter copy's `dev/` directory; copying the complete installed tool sources resolved it. One new test deprecation diagnostic was corrected without changing compatibility; final analysis matches the baseline 13 findings. These setup failures are not represented as shipping runtime regressions or silently erased.

All expensive checks ran sequentially with two test workers and 300-second per-command limits. Resource coordination and the five-minute full-CI autoskip contract remain unchanged.

## Reproduction

Use empty private writable directories, never overwrite a shared checkout. Extract `candidate-sources.tar.gz` with current Flutter 3.41.7, or `minimum-sources.tar.gz` with official 3.19.0 (archive checksum in `minimum-release.json`). Set `FLUTTER_ROOT`, private `PUB_CACHE`, and `FLUTTER_SUPPRESS_ANALYTICS=true`. Run `flutter pub get --no-example`, then `python run_checks.py SOURCE FLUTTER_ROOT PUB_CACHE OUTPUT PREFIX`. Full analysis intentionally exits nonzero on the 13 retained infos; the focused suite expects 360 passes. Build with `flutter build web --release --no-pub --no-web-resources-cdn --target tool/ui_probe.dart`; add `--web-renderer canvaskit` on 3.19.

For paired images extract `baseline-sources.tar.gz` and `candidate-sources.tar.gz` separately. After resolving each, set `HANDRAIL_WIDGET_EVIDENCE_DIR` to separate output directories and run:

```sh
flutter test --no-pub --concurrency=2 --reporter=expanded \
  test/handrail_message_composer_test.dart \
  test/handrail_chat_workspace_test.dart test/handrail_thread_view_test.dart \
  --name 'single format action|one thread dismissal hierarchy|standalone thread title|format toolbar render'
```

Before expects 19 failures / 4 passes; after expects 23 passes. Fonts come from `$FLUTTER_ROOT/bin/cache/artifacts/material_fonts`; outputs have real 1:1 pixel dimensions. The evidence-only baseline Link reproduction runs with `--name 'retained baseline link Cancel'` and is expected to fail.

For the unchanged runtime comparison, extract `runtime-sources.tar.gz` under current Flutter or `newer-runtime-sources.tar.gz` under the exact newer archive. Resolve their retained lock and build `tool/toolbar_probe.dart` with the same release flags. `newer_browser_check.mjs` is the exact original newer-run automation; `runtime_browser_check.mjs` adds passive semantic-node counts for current/candidate inspection, with identical input operations. Install the retained browser package/lock into a private tooling directory. Set `BROWSER_TOOLS_DIR`, a short writable `BROWSER_TMPDIR`, `MODES=sdk,sync`, `WIDTHS=1050,390`, `REQUIRE_INPUT=1`, and separately `SEMANTICS=on` / `off`; invoke `node SCRIPT BUILD_WEB OUTPUT PHASE`. The script uses Chromium 151.0.7922.34 from the installed vendor cache (adjust its executable path for an equivalent local copy). It serves fixtures on a private loopback port and blocks live service traffic. Candidate commands use `MODES=sdk WIDTHS=1050,390,320`. Semantic input runs must retain exit 1.

`semantic_state_check.mjs BUILD_WEB OUTPUT PHASE` checks native Chromium accessibility and selection state; it expects failure against the unchanged runtime and success against the candidate. Source archives, per-source/build hashes, compiled JS gzip files and `evidence-sha256.json` allow independent verification without publishing a package or touching Preview.
