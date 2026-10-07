# Actual rendered captures

These are **before and after toolbar actions on unchanged published `.32`**, not before/after a successful repair. All images are original browser captures. JSON acceptance assertions use the Flutter controller and SDK/storage record, not the editable DOM alone.

| Case | Before action | After action and ordinary input | Result |
| --- | --- | --- | --- |
| 320 px, pointer Bold | [Before](matched-sdk-bold-pointer-320-before.png) | [After X and continued typing](matched-sdk-bold-pointer-320-continued.png) | Failed: accepted text remains Original; Bold applies but typing is rejected |
| 390 px, pointer Bold | [Before](matched-sdk-bold-pointer-390-before.png) | [After](matched-sdk-bold-pointer-390-continued.png) | Failed |
| Desktop, pointer Bold | [Before](matched-sdk-bold-pointer-1050-before.png) | [After](matched-sdk-bold-pointer-1050-continued.png) | Failed |
| 390 px, keyboard Bold | [Before](matched-sdk-bold-keyboard-390-before.png) | [After](matched-sdk-bold-keyboard-390-continued.png) | Passed in this run: accepted X next, same text persisted and retained after delayed acknowledgement |
| 320 px, keyboard Bold | [Before](matched-sdk-bold-keyboard-320-before.png) | [After](matched-sdk-bold-keyboard-320-continued.png) | Failed: first X lost; continued input later accepted |
| 320 px, pointer Inline code | [Before](formats-sdk-inline-code-pointer-320-before.png) | [After](formats-sdk-inline-code-pointer-320-continued.png) | Failed; horizontally scrolled toolbar is reachable |
| Desktop, plain Flutter pointer control | [Before](matched-sync-bold-pointer-1050-before.png) | [After](matched-sync-bold-pointer-1050-continued.png) | Same failure without SDK |
| Desktop, published .32 send success | [Disabled send frame](published-success-1050-disabled.png) | [First character](published-success-1050-first-character.png) | Passed: prior post-send repair still accepts ordinary X |
| Desktop, published .32 send failure | [Disabled send frame](published-failure-1050-disabled.png) | [First character](published-failure-1050-first-character.png) | Passed: OriginalX accepted |

At 320/390 the format toolbar scrolls horizontally; the send control remains reachable. The title and accepted-state diagnostic wrap at narrow widths. The existing native layout/overflow checks also pass. These screenshots do not qualify system IME, native device keyboards, Link-dialog/attachment/mention browser transitions, or Preview. No missing-glyph screenshot has been repaired or concealed; this run's ordinary-input screenshots use ASCII, and historical Unicode screenshots are untouched.
