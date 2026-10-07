# Rendered control hierarchy evidence

All PNGs are unmodified captures. Thread images use real Flutter widget rendering with deterministic transport fixtures and installed fonts. Browser images use release CanvasKit. None is a Preview or live staging capture.

## Workspace thread

| Viewport | Before | After |
| --- | --- | --- |
| 320px | ![Before thread 320](before-renders/thread-320.png) | ![After thread 320](after-renders/thread-320.png) |
| 390px | ![Before thread 390](before-renders/thread-390.png) | ![After thread 390](after-renders/thread-390.png) |
| 1400px | ![Before thread 1400](before-renders/thread-1400.png) | ![After thread 1400](after-renders/thread-1400.png) |

## Standalone title and permission denial

| Width | Before title | After title | After HTTP 403 |
| --- | --- | --- | --- |
| 320px | ![Before standalone 320](before-renders/standalone-320.png) | ![After standalone 320](after-renders/standalone-320.png) | ![Denied standalone 320](after-renders/standalone-denied-320.png) |
| 390px | ![Before standalone 390](before-renders/standalone-390.png) | ![After standalone 390](after-renders/standalone-390.png) | ![Denied standalone 390](after-renders/standalone-denied-390.png) |
| 900px | ![Before standalone 900](before-renders/standalone-900.png) | ![After standalone 900](after-renders/standalone-900.png) | ![Denied standalone 900](after-renders/standalone-denied-900.png) |

## Actual browser toolbar

Visual layout is intentionally retained; native accessibility changes from two buttons to one per format. The after-action images below retain failed semantics-enabled typing, not a claimed typing fix.

| Width | Before action, original SDK | After action, UI candidate |
| --- | --- | --- |
| 320px | ![Original toolbar 320](../composer-toolbar-20261007/matched-sdk-bold-pointer-320-before.png) | ![Candidate toolbar 320](candidate-semantics-sdk-bold-pointer-320-continued.png) |
| 390px | ![Original toolbar 390](current-semantics-sdk-bold-pointer-390-before.png) | ![Candidate toolbar 390](candidate-semantics-sdk-bold-pointer-390-continued.png) |
| 1050px | ![Original toolbar 1050](current-semantics-sdk-bold-pointer-1050-before.png) | ![Candidate toolbar 1050](candidate-semantics-sdk-bold-pointer-1050-continued.png) |

The 320px original browser image is explicitly from the retained prior qualification of the same published composer. Current-run paired widget toolbar renders are also available under `before-renders/toolbar-*.png` and `after-renders/toolbar-*.png`; `toolbar-scrolled-*.png` records keyboard reachability at the right edge. The code-block widget image uses the test renderer's fallback monospace glyphs, so browser captures are the typography reference.

See [qualification and reproduction](qualification.md) for exact sources, locks, fonts, commands and failures.
