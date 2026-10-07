# Toolbar typing qualification — 2026-10-07 UTC

**Not fixed; do not publish this as a toolbar repair.** The reported ordinary-input defect reproduces with the exact published Flutter **0.1.32 / `2d095ba5a0f86e4aa0b12ba8432500e3edfb576f`** and a matched plain Flutter `TextField`/`IconButton`. None of the explored public-API focus variants qualified pointer input. In accordance with the requested fallback, **all runtime code remains byte-for-byte unchanged**. The workspace adds six platform-channel compatibility tests and this reproducible evidence bundle. There is no passing after-fix runtime candidate.

Work request `4439aaa1-fec6-4490-afde-a75d30a8cb10`; worker `a513dfca-7c7e-4792-a352-4079ce95a3e1`. Current-context confirmed scope and requirements. KB searches, attached guidance, README, release instructions, and both prior qualification bundles were read. No applicable AGENTS.md was found in mounted ancestor/repository paths. There were no saved owner decisions or new owner questions.

## Owning failure and rejected approaches

The SDK's inline/block formatting functions update rich metadata and synchronously request editor focus at `lib/src/handrail_message_composer.dart:1033`. A pointer click transfers browser/Flutter focus to the button, then the callback requests the editor. The quick false/true Flutter focus round trip can be coalesced before the editor's semantics update. The browser textarea has already blurred, which deactivates the engine's semantics editing strategy. Flutter reports editor focus, yet ordinary `X` and ` next` remain directed to the button and neither the controller nor draft accepts them. Correct formatting alone does not establish continued editing.

The plain synchronous control reproduces the same failure, without the SDK, draft acknowledgements, rich controller, or any host remount. The SDK update order contributes to this trigger; the evidence does not treat synchronous `requestFocus()` as universally broken or assert that every toolbar problem is exclusively upstream.

Deferring restoration exposes a second, directly traced engine race. `SemanticsTextEditingStrategy.disable()` schedules `FlutterViewManager.safeBlur()` on the old textarea. A subsequent semantics update can activate and focus that same element before the queued blur runs. The queued operation then transfers focus to `flutter-view`, whose textarea blur deactivates editing again. In `stack-browser.json` (plain `end`, pointer), textarea focus returns at 1656 ms, then is removed at 1755 ms. The actual release-bundle stack is `QD.Hx -> QD.alo -> adH.$0`. `engine-source-correlation.json` maps those exact bundle lines to `_transferFocusToViewRoot` / `safeBlur` and retains source hashes and excerpts. `qualification-main.dart.js.gz` retains the exact compiled bundle for independent correlation.

These disposable **plain-control experiments are rejected**, not shipping workarounds:

- synchronous `FocusNode.requestFocus()`;
- post-frame callback and `WidgetsBinding.endOfFrame` restoration;
- two frame boundaries (can accept continued text while losing the immediate first character);
- public `FocusManager.applyFocusChangesIfNeeded()` with end-of-frame restoration;
- public `EditableTextState.requestKeyboard()`, synchronously and after a frame;
- `TextFieldTapRegion` around the button.

The messenger diagnostic uses public `WidgetsFlutterBinding.createBinaryMessenger` delegation to record text-input messages unchanged. It shows clear/hide followed by setClient/style/editingState/show. No private engine field is read or changed; the browser focus stack is a passive event listener. Initial uninstrumented and instrumented fixtures both reproduce the pointer defect. No timing delay, repeated focus polling, DOM/engine patch, focus-stealing fallback, or new editor architecture was added to the SDK. The fixture's existing 50 ms **read-only telemetry** timer never requests focus or supplies input.

**Remaining owning gate:** qualify a supported Flutter focus/editing path that survives semantic activation and the queued blur, including immediate first input, or obtain a separately scoped upstream engine correction and repeat the exact SDK qualification. A frame-delay-only SDK change is not justified by these results. No global Flutter update was made or recommended as an untested fix.

## Checks and actual input evidence

| Check | Result |
| --- | --- |
| Current Flutter 3.41.7 / Dart 3.11.5 focused suite | **218 passed**: existing 212 plus six new platform controls |
| Minimum Flutter 3.19.0 / Dart 3.3.0 focused suite | **218 passed** |
| Scoped composer source/test analysis, both | **Passed, no issues** |
| Full `lib test` analysis, both | **Failed: exactly the same 13 baseline informational findings**, verified in `analysis-comparison.json` |
| Current release CanvasKit baseline and diagnostic builds | **Passed** |
| Minimum release CanvasKit build | **Passed** |
| Minimum matched Bold SDK/plain browser controls, desktop | **Failed**: both pointer cases reject input; both keyboard cases pass (`minimum-browser.json`) |
| Current matched Bold SDK/plain controls, 1050/390/320 | **Failed**: all six pointer cases reject input; SDK keyboard cases lose first `X` at 1050/320 in the final run; SDK 390 and all three plain keyboard cases pass |
| Current SDK Italic/Inline code/Code block/Bulleted list/Numbered list, both activations, all three widths | **Failed**: all 15 pointer cases reject input; 14 keyboard cases pass, wide Italic loses first `X` |
| Published `.32` delayed-send browser controls | **Passed**: wide success/failure, narrow success, repeated sends, canonical-message counts, controller and real localStorage draft agreement |
| Published `.32` browser focus boundaries | **Passed**: another control, hide/return, channel, thread, account change, logout |
| Existing full SDK suite | **Not rerun without cause**; retained truthful baseline **2,471 passed / 7 failures** in `../composer-editing-20261006/` |
| Browser/system IME, native devices, Preview/staging | **Unverified**; no supported system IME session was available in this headless environment |

The current browser acceptance gate has **24 failed / 18 passed** cases across `matched-browser.json` and `formats-browser.json`. Failed input assertions return process exit 1; they have not been relabeled as passing reproductions. The browser is Chromium **151.0.7922.34**. These fixtures explicitly enable Flutter semantics, matching the prior review path; the result is bounded to this semantics-enabled CanvasKit setup, not every browser or non-semantics editing path. Each case proves CanvasKit resource loading and records controller text, selection/composing, Flutter focus ownership, DOM focus/value, local SDK draft, serialized pending-draft storage, and transport requests. No live service traffic is allowed. Actual text uses Playwright keyboard events; no host-controller assignment, `fill`, DOM-value assertion alone, Tab back to the editor, blur/refocus, or click assistance follows activation. Tab is used only to reach a toolbar button in keyboard-activation cases. Narrow pointer cases use horizontal wheel scrolling to reach clipped toolbar controls.

For accepted SDK cases, the immediate `X` replaces the selected `Original`; continued input becomes `X next`, with the expected canonical formatting (`**X** next` for Bold). The SDK draft and serialized record in real browser localStorage must agree. Releasing the held same-content acknowledgement preserves text and caret `[6,6]`, and subsequent ordinary ` again` also persists. No send operation occurs in these editing tests. Some failed keyboard cases later accept ` next` after losing `X`; that is still a failed immediate-input gate. Pointer failures retain formatted `Original` and do not persist the attempted text.

The six new widget tests cover Bold/Italic/Inline code through native touch and keyboard traversal. They use the existing platform text-input connection after activation, assert controller/selection and persisted SDK record, preserve the `EditableTextState`, and check that native touch does not issue `TextInput.hide`. These tests **pass on unchanged `.32`** and are compatibility controls, not widget reproduction of the browser bug or proof of OS keyboard/IME operation. Existing focused tests cover same-content echoes, newer remote text/format, attachments/uploads, mentions, format-toolbar visibility, main/thread/channel changes, hidden return, identity/logout/client/controller replacement, intentional focus movement, and successful/failed send paths. Their uncertain command identity, durability, and cancellation semantics are unchanged.

The rendered matrix covers six direct format actions, horizontal toolbar reachability, accepted editing where possible, and widths 320, 390, and 1050. Link-dialog, attachment/mention, and all lifecycle transitions **after a successful pointer toolbar action remain unqualified in the browser**, since that prerequisite fails. They retain existing widget coverage. No claim of full toolbar, native-device, Preview, or staging readiness is made. Composing ranges from platform tests are not system IME proof; no Unicode/CDP imitation was used to claim it. Screenshots are unmodified rendered captures; see `gallery.md` for curated before/after-action images, not a fabricated after-fix comparison.

The additional minimum-version browser comparison also reproduces the shared synchronous pointer failure: **2 failed / 2 passed** at 1050 px. Its older renderer intercepts clicks on the semantic textarea; the final run uses actual mouse coordinates at the rendered field/button centers (`CANVAS_POINTER=1`), without post-action refocus. Initial editor setup settles before entering the precondition; no wait/focus assistance follows toolbar activation. The initial modern-bootstrap and semantic-hit-test harness failures are retained under `attempts/`. This older-engine result does not claim the current engine's later `safeBlur` implementation exists unchanged in 3.19.

## Source custody and safe publication recommendation

Composer SHA-256 remains **`0ce967b86b4b1914c2eb3da4e8be3bc7be6f16819cacf91cdc7c6b0982cf36c6`**. Test SHA-256 is **`3068e28e78e6010dc0b5c29b87f645027705dd286a5fd69d44f598a89d9c5a07`**. `source.diff` contains the entire tracked change: **87 added test lines, zero runtime changes**. Version manifest, lock, Dart version mirror, and native version-writer declaration are unchanged. The previous single-semantic-field, matching-echo, and post-send repairs remain intact.

`custody-after.json` checks all 2,009 tracked JS files, all 30 companion files, and all 738 original Flutter files. Only the intentionally edited composer test changed; all prior evidence is preserved. JS stays at **1.0.54 / `248fb8890b8e7e1ba15799aff06ef48156cca451`**; companion stays at **0.1.21 / `9dabb1c666443ed913d0400698beabfe6a7509a1`**. No Preview, Assistant, Marketing, auth, rate-limit, credential, provider, database/queue, commit, push, PR, deployment, or publication changes occurred.

`baseline-sources.tar.gz` retains original `.32` runtime/tests and the uninstrumented public fixture. `qualification-sources.tar.gz` retains the identical runtime, added tests, and diagnostic/plain-control variants. `source-and-build-hashes.json` binds every source/configuration and build output, and explicitly verifies identical production `lib/` bytes. `minimum-sources.tar.gz` additionally retains the minimum lock and version-compatible web bootstrap. Exact compiled JS bundles, current/minimum locks, toolchain logs, browser tooling lock, scripts, checks, raw failures and screenshots are retained. These are source qualification fixtures, **not Git-installed proof of a new published SDK**. Fixture manifests alone enable Material icons; no repository dependency was changed.

Checks ran sequentially with two test workers and 300-second per-command caps. Private writable copies/extractions and pub caches were used; the global installation stayed read-only. The minimum archive matches the official [Flutter release archive](https://docs.flutter.dev/install/archive), SHA-256 `4cc1706fbd6e2a5c0ee34a6f8de875aae20904c9f47e18c88d2fcb25d9ea1a79`. Full-CI/autoskip configuration is unchanged.

Failed attempts are retained: initial fixture callback-name compilation error; incorrect initial keyboard-selector check; overly broad Markdown continuation expectation; rejected public focus variants; missing imported example files in the first analysis snapshot; incorrect archive URL attempts; and the modern bootstrap entrypoint not existing in a minimum-version build. Corrections to harness setup are separated from runtime input failures.

**Recommendation: hold scoped runtime publication for this defect.** Parent can review/retain the test and evidence changes, but there is no fixed composer to publish. A later repair still needs independent qualification, native Flutter-only finalization by the parent, and exact public-HTTPS-Git-SHA consumers with matching locks. None of those release or final application/device gates is satisfied by this report.

## Reproduction

Extract either source archive into an empty writable directory outside the shared checkout. Use private Flutter 3.41.7 and pub cache paths. Run `flutter pub get --no-example`, then `flutter build web --release --no-pub --no-web-resources-cdn --target tool/toolbar_probe.dart`. `run_checks.py SOURCE FLUTTER_ROOT PRIVATE_PUB_CACHE OUTPUT PREFIX` runs the recorded focused suite and analysis. Original baseline has 212 tests; the qualification fixture has 218.

Install `browser-package.json` / `browser-package-lock.json` as `package.json` / `package-lock.json` in a private browser-tools directory. Set `BROWSER_TOOLS_DIR` to it and `BROWSER_TMPDIR` to a short writable directory. `browser_check.mjs BUILD_WEB OUTPUT PHASE` uses the retained Chromium executable path (adjust that path to an equivalent installed browser if needed). The final current commands set `MODES=sdk,sync WIDTHS=1050,390,320 REQUIRE_INPUT=1` for Bold, then `MODES=sdk FORMATS='Italic,Inline code,Code block,Bulleted list,Numbered list' WIDTHS=1050,390,320 REQUIRE_INPUT=1`. The expected current result is exit 1, with the failed acceptance cases preserved. `postsend_check.mjs BUILD_WEB OUTPUT published` reproduces the passing `.32` completion/boundary checks.

For the minimum, use `minimum-sources.tar.gz`, private Flutter 3.19.0, its own pub cache, and `flutter build web --release --no-pub --no-web-resources-cdn --web-renderer canvaskit --target tool/toolbar_probe.dart`. The final browser command sets `MODES=sdk,sync WIDTHS=1050 CANVAS_POINTER=1 REQUIRE_INPUT=1`. Do not use the newer `flutter_bootstrap.js` entrypoint with this older build.
