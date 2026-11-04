# tap, tapAppIcon

[in Japanese(日本語)](tap_ja.md)

Taps an element, or raw coordinates, on the screen.

## Functions

| function | description |
|---|---|
| `tap(sel, holdSeconds: 0, maxGestureSeconds:containerInference:linkText:settle:waitSeconds:scroll:maxSwipes:)` | Taps the first element matching the selector. `holdSeconds` greater than 0 makes it a long press (default 0 = normal tap, capped at 10 seconds by default — pass `maxGestureSeconds:` to allow up to 60 for this one call). Waits for the target to become enabled before tapping (see Notes). Returns the tapped element, so assertions chain directly: `tap("#btn_ok").textIs("OK")`. |
| `tap(sel, linkText: "text")` | Taps the place where `linkText` is drawn **inside** the element the selector resolves to — for an inline link in a paragraph, which the accessibility tree does not expose as a node on Compose Multiplatform, Android Views (`ClickableSpan`) and SwiftUI (`AttributedString` links). Located first from the tree (a descendant whose label or value equals `linkText`, as Flutter and React Native expose links), then by OCR on the element's pixels. If neither finds it the step fails and lists what OCR read — it never falls back to the element's centre. The step note records which way located it (`tree` / `ocr`). A link wrapped across two lines is not found by OCR. Without `linkText:` it taps the centre of the element. |
| `tap(x: Double, y: Double, holdSeconds: 0, maxGestureSeconds:, settle:)` | Taps raw coordinates. Coordinates use the same system as the `screen` frame in a snapshot — iOS = pt, Android = px (not dp). Prefer a selector whenever one is available. A point outside the screen fails without sending anything (a negative coordinate always; the screen size is checked when the element list is read anyway). On iOS in inapp-boost mode, a point off the screen fails; a point on the software keyboard is tapped through the XCUITest bridge, so the key is pressed — to reach what is under the keyboard, close it first with `pressEnter` or `hideKeyboard`; and an element clipped out of its scroll container is not activated even if its frame contains the point — the touch is sent to whatever is actually visible at that point (the step gets the note `<element> contains this point but is clipped by its scroll container here (not drawn), so it was not activated; sent a touch to what is on screen at that point`). |
| `tap(sel, scroll: .noScroll)` | Taps without scrolling, even inside a `withScrollDown { }` block. |
| `tapAppIcon(name?)` | Taps the app icon on the home screen. For name matching and search order, see [navigation](./navigation.md). |

## Example

```swift
tap("#login_btn||Log In")
tap("Settings", scroll: .down)         // searches while scrolling down
tap("#row_03", holdSeconds: 1)         // long press
tap("#txt_terms", linkText: "Terms of Service")   // a link inside a paragraph
tap(x: 120, y: 640)                    // only when no selector is available
```

## Notes

- **When several elements match the selector**: if the first one is covered by another element in front and an uncovered
  match exists, that one is tapped (with a note). If every match is covered and there is nowhere to press, nothing is tapped
  and the step fails.
- **When the target's centre is under a tab bar, fixed footer or other element in front**: the list is scrolled once to clear
  it. If that does not clear it, the centre is not pressed (it would hit the tab in front and open another screen); the uncovered,
  visible part of the target is pressed instead (with a note). If that visible part is too thin (under 8pt; 8dp on Android), nothing is tapped
  and the step fails. Long press and `doubleTap` behave the same.
- **When a target outside the list (such as a button on a top bar that hid on scroll) is under a navigation bar or similar**:
  one scroll of the list does not bring it out, so without `scroll:` nothing is tapped, the step fails and the message suggests
  a direction (`scroll: .up` etc.). With `scroll:`, the list is scrolled until the target comes out from under it, then it is tapped.
- **When the app has crashed and another app is in front**: if the launched app's process is gone and the screen's tree belongs
  to another app, the step fails without touching or checking anything in that tree (so an element with the same `#id` in
  another app is never operated by mistake).
- **`tap` waits for the target to become enabled before tapping.** A screen can render an
  element before it is actually interactive (a form still loading, a button disabled until
  validation passes). `tap` retries resolution until the element is `enabled`, up to the
  step's `waitSeconds:` (5 seconds by default). If it never becomes enabled, `tap` still taps
  it — a scenario that deliberately taps a disabled element to assert "nothing happens" keeps
  working. Waiting is skipped when the selector explicitly pins the state, e.g.
  `#btn&&enabled=false`, or when `waitSeconds: 0` is given.
- **Waiting for the element to appear is short**: without `waitSeconds:`, resolution is retried for only about
  0.7 seconds until the element is found (once found, `tap` waits up to 5 seconds for it to become enabled, as above).
  For an element that appears late after a screen transition, pass `tap("#btn", waitSeconds: 5)` or wait first with
  `waitForDisplay("#btn")`. Other operations such as `type` behave the same.
- **Tapping first, then typing**: `tap("#field")` followed by `type("some text")` also works. On Android,
  when `#id` resolves to the input's wrapping container rather than the field itself, focus can
  fail to land in the field; `type` recovers by locating the single input inside the tapped
  container. See [type](./type.md).
- **Elements at the very bottom of an Android screen**: on a device with gesture navigation, a touch inside the band at the
  bottom edge of the screen (the band that takes the home / app-switch gesture) can be taken by the OS and send the app to
  the background. When an element's centre lies inside this band and part of the element is above it, `tap` (and long press
  and `doubleTap`) touches the centre of the part above the band (the step gets the note
  `touched the part of the element above the Android bottom gesture band`). An element entirely inside the band is touched
  at its centre.
- **iOS in-app bridge: "a real touch would land elsewhere" note.** The in-app bridge operates the element
  directly (its accessibility action, or a touch sent straight to the element's window), so it can reach an
  element that a real finger cannot — for example a button hidden under a keyboard accessory bar. When a real
  touch at the centre of the element's frame would land on another view, the step stays green and gets the
  note `in-app operated the element directly, but a real touch at the centre of its frame lands on another view
  (<view> at (x, y))` (machine-readable: `inapp-tap-outside-hit-area`). The tap is not retried and the step is
  not failed. The same tap can fail on the XCUITest bridge, which presses the centre of the frame. Nothing is
  said when it cannot be determined (for example Flutter, which draws everything in one view). A SwiftUI
  `.plain` button that is tappable only on its text gets a separate note instead: `in-app activated the element at
  its activation point, which is not the centre of its frame that a coordinate tap presses (activation point (x, y),
  centre (x, y))` (machine-readable: `inapp-activation-point-off-centre`; SwiftUI and UIKit apps only).
- Coordinate taps: use them only when the app exposes nothing selectable at that spot.

  | Use case | Guidance |
  |---|---|
  | Writing a scenario (kept long-term) | Prefer a selector. Coordinates are a last resort — they hit whatever is there once the layout moves. |
  | Ad-hoc exploration | A selector is still preferred, but coordinates are fine if they resolve faster. |
- **`settle: false` skips the wait for the screen to settle after this one command.** Normally a command
  waits for the screen to settle before returning (the bridge's settle wait and fleetest's comparison of
  the element tree after the command; each wait has an upper limit), so the next step sees the final positions. With `settle: false`
  those post-action waits are skipped for that call only, so the command returns sooner and the next step may
  see a screen that is still moving (positions can be off). Use it when speed matters more and the next step
  does not depend on final positions. Waits that verify the result (for example the typed text being read back,
  or the orientation actually changing) and waits before the action are kept. Commands that take it: `tap`
  (selector and `x:y:`), `doubleTap`, `hold`, `type`, `clearInput`, `pressEnter`, `hideKeyboard`, `back`,
  `rotateTo`, `swipe*`, `flick*`, `scroll*`, `scrollTo*`, `pinchOut` / `pinchIn`, `gesture`. It goes after the
  command-specific arguments and before `waitSeconds:`. The step slowdown (the wait before an action while the Mac's CPU is high) is not applied to the command either.

### Link
- [index](../../index.md)
