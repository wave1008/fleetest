# Known caveats

[日本語](known_caveats_ja.md)

Read this page before you write a scenario. Each line summarizes one thing to watch for when you use that command or component; the link goes to the full explanation and how to write it.
Pay special attention to the ones that go wrong silently (the step stays green while being wrong): check the value or state afterwards, as each line says.

## Commands

### App assertion (appIs)
- [Bundle ID or package name only](../commands/app_assertion.md#notes) — there is no nickname mechanism, so write the bundle ID / package name directly.
- [Foreground name in failures differs by OS](../commands/app_assertion.md#notes) — Android failures include the actual foreground package; iOS cannot read it, so the message lacks it.
- [Unreadable foreground app on Android](../commands/app_assertion.md#notes) — `appIs` keeps waiting and fails as "could not be read" at `waitSeconds`; it is not a mismatch.

### ifCanSelect, ios, android
- [`ifCanSelect` decides immediately](../commands/branch.md#notes) — it checks once; pass `waitSeconds:` to poll before deciding "not found".
- [Use `ifCanSelect` for maybe-present UI](../commands/branch.md#notes) — there is no other "may or may not appear" argument; express dialogs and banners that may not show with it.
- [`ifCanSelect` never scrolls](../commands/branch.md#notes) — even inside `withScroll*` it matches only the current screen, so an off-screen element means the block does not run.
- [Declared interruptions are closed before the answer](../commands/branch.md#notes) — a covered element would otherwise read as "not found" and take the wrong branch; declare `irregularHandler` for such modals.
- [Two forms of branching](../commands/branch.md#notes) — use plain Swift `if` for values already read and `ifCanSelect` for "is this on screen".
- [`ios { }` / `android { }` are for small OS differences](../commands/branch.md#notes) — use them inside shared scenarios for behavior that applies to only one OS.

### clearInput
- [Android: field under a popup window](../commands/clear_input.md#notes) — the focusing tap would pick a suggestion and change another field, so the step fails first; close the popup beforehand.
- [Non-input target fails before clearing](../commands/clear_input.md#notes) — `clearInput` taps first, so a button, switch or link would be pressed; it refuses them, but an element wrapping exactly one input is accepted.
- [Fields whose value does not mirror input](../commands/clear_input.md#notes) — a value that seems to remain may pass via OCR with note `clear-residual-not-drawn`; otherwise it fails.
- [Whitespace cannot be verified](../commands/clear_input.md#notes) — whitespace-only content is invisible to accessibility, so lost spaces go undetected; assert values with `valueIs` where whitespace matters.
- [`type` appends](../commands/clear_input.md#notes) — clear first when replacing, or use `type(sel, "text", replace: true)` to do both in one command.
- [Flutter iOS falls back to XCUITest for this command](../commands/clear_input.md#notes) — the in-app bridge cannot clear it, adding roughly one to two seconds; no change in how you write it.
- [`settle: false` skips the settle wait](../commands/clear_input.md#notes) — the next step may see a moving screen, so use it only when the next step does not depend on final positions.

### group, procedure, beforeEach, afterEach, beforeAll, afterAll, setUpDevice, tearDownDevice
- [`procedure { }` for code to skip after a failure](../commands/descriptors.md#notes) — raw Swift directly in `action { }` / `expectation { }` still runs after an earlier failure; put it in `procedure { }`.
- [`beforeAll()` instance properties are not shared](../commands/descriptors.md#notes) — it runs in the first scenario's process; pass values with `writeMemo` / `readMemo`, and if it fails the class's remaining scenarios fail unrun.
- [`setUpDevice()` instance properties are not shared](../commands/descriptors.md#notes) — pass values with `writeMemo` / `readMemo`; a failure fails the class's remaining scenarios on that device and is never retried.
- [`afterEach()` runs even after a failure](../commands/descriptors.md#notes) — use it for cleanup that must always happen, such as terminating the app.
- [`tearDownDevice()` has its own process](../commands/descriptors.md#notes) — it can read memos and runs even if `setUpDevice()` failed, but not on dropped devices; its result is not counted in the test results.
- [`@Deleted` / `@Draft` are excluded from bulk runs](../commands/descriptors.md#notes) — they can only be run by exact ID, so a scenario marked this way silently does not run in all/folder/class runs.
- [Describe steps in the scene title](../commands/descriptors.md#notes) — write the steps in the scene's title string.

### exist, notExist, countIs
- [`exist` return value chains into checks](../commands/existence_assertion.md#notes) — chain text, value or id assertions onto it.
- [`exist` / `notExist` / `countIs` always take a selector](../commands/existence_assertion.md#notes) — they resolve more than one element, so there is no implicit last-element form.
- [`notExist` ignores visibility](../commands/existence_assertion.md#notes) — an element merely covered by a modal but still in the tree counts as present, and the check fails after the wait.
- [Absence passes behind a dialog (`absence-behind-modal`)](../commands/existence_assertion.md#notes) — a dialog in front can remove elements from the tree, so `notExist` passes (with this note) though the element is behind it; close the dialog first.
- [Absence read on another app (`absence-checked-on-another-app`)](../commands/existence_assertion.md#notes) — on Android, `notExist` passes with this note while another app is in front and says nothing about your app; bring your app back first.
- [Truncated text on the visibility check](../commands/existence_assertion.md#notes) — ellipsis (`text-ellipsized`) or more than half drawn (`text-partially-hidden`) passes with a note, half or less fails; use `requireVisible: false` if hiding is intended.

### Find by image (findImage, findImages, existImage)
- [Distance is recorded](../commands/find_image.md#notes) — read the recorded distance and number of candidates to choose `threshold`.
- [Same-shape parts differing only in text](../commands/find_image.md#notes) — a different row can be grabbed under the default `threshold` (0.15); check distances and tighten it, for example 0.03.
- [Capture samples per OS version and scale](../commands/find_image.md#notes) — the same row looks different across versions; put a sample for each version or state in the label folder.
- [`waitSeconds` defaults to 0](../commands/find_image.md#notes) — it looks once; pass `waitSeconds: 3` or similar right after a screen transition.
- [Failure message and attached screenshot](../commands/find_image.md#notes) — a failed `existImage` reports the nearest distance and `threshold` and attaches the judged screenshot.
- [Inside `withScrollDown { }` it scrolls](../commands/find_image.md#notes) — pass `scroll: .noScroll` to look at the current screen only.
- [Pass `scroll:` to search while scrolling](../commands/find_image.md#notes) — as with `exist` and `select`; function-name aliases such as `findImageWithScrollDown` do not exist.
- [No sample image is a configuration error](../commands/find_image.md#notes) — the step fails when the label folder has no sample at all.
- [Vision anomalies are retried](../commands/find_image.md#notes) — odd feature prints on a busy Mac make the tool wait and search again (`vision-anomaly-retried`); if it persists, rerun or restart the Mac.
- [Single-colour screenshot is retaken](../commands/find_image.md#notes) — an all-black or all-white app area is treated as not captured (`blank-screenshot-retaken`) and fails if it stays so.
- [iOS inapp-boost captures like the text visibility check](../commands/find_image.md#notes) — on iOS in the default mode, a covered element is compared as the picture of whatever covers it.
- [Chain assertions on a found element](../commands/find_image.md#notes) — this works when the element has a writable selector such as an id or unique label.
- [Tap right after finding](../commands/find_image.md#notes) — moving the screen afterwards makes `tap()` hit the old coordinates.
- [Candidates are accessibility element frames](../commands/find_image.md#notes) — parts that do not appear in accessibility cannot be found.

### flick
- [`flick` is content-agnostic](../commands/flick.md#notes) — it sends one fast stroke with shorter default durations than `swipe`, and does not search for an element.
- [Target region via `scrollFrame:`](../commands/flick.md#notes) — pass the region as a `scrollFrame:` selector, the same as `scroll`.
- [`flick` has no notion of the edge](../commands/flick.md#notes) — chained flicks do not tell you whether you arrived; verify the destination yourself afterwards.

### Gestures for maps and canvases (doubleTap, pinchIn, pinchOut, gesture, hold)
- [`settle: false` skips the settle wait](../commands/gestures.md#notes) — the next step may see a moving screen; use it only when the next step does not depend on final positions.

### Image assertion (imageIs)
- [No matching samples fails immediately](../commands/image_assertion.md#notes) — without samples whose label contains `label`, the check fails at once.
- [Failure shows label and confidence](../commands/image_assertion.md#notes) — the message states what the image was classified as and how confident it was.

### installApp, removeApp, clearAppData
- [Call `launchApp()` after `installApp()` on iOS inapp-boost](../commands/install_app.md#notes) — the install ends the in-app bridge, so `tap` and similar do not reach the app until the next `launchApp()`.
- [Reinstalling keeps permissions](../commands/install_app.md#notes) — on an iOS Simulator, permission dialogs do not reappear after reinstall; use `clearAppData()` for first-run state.
- [`clearAppData()` resets permissions](../commands/install_app.md#notes) — permission dialogs appear again, which is the command to use for onboarding and first-run permission flows.
- [Physical iPhone: `clearAppData()` reinstalls](../commands/install_app.md#notes) — it takes install time (`reinstalled-to-clear-data`) and needs `appPathPhysical` plus `--profile`; without a valid source it fails without uninstalling.
- [Keychain / Keystore survive `clearAppData()`](../commands/install_app.md#notes) — a first-run flag stored there is not reset, so first-run cannot be reproduced this way.
- [fleetest's own bridge cannot be the target](../commands/install_app.md#notes) — passing the bridge's ID to `removeApp` / `clearAppData` fails without sending anything.
- [Removing the app under test breaks the run](../commands/install_app.md#notes) — call `removeApp()` on your own target only when you mean to end the scenario there.
- [Android install verification is turned off during install](../commands/install_app.md#notes) — Play Protect's check is disabled temporarily and restored, so the app is never sent to Google; set `playProtectBypass` to false to stop this.

### iosAlertHandler
- [Empty or all-wildcard alternative fails at declaration](../commands/ios_alert_handler.md#notes) — an empty alternative or one of only `*` and invisible characters would match any alert, so declare concrete text.

### irregularHandler
- [Fires during operation and assertion waits](../commands/irregular_handler.md#notes) — assertions poll the current tree, so a modal opening during `exist` / `textIs` is closed too.
- [Up to 10 closes per step](../commands/irregular_handler.md#notes) — change with `maxDismissals:`; if the same thing remains after two closes, the tool gives up and records it was not fully closed.
- [Conditions close interruptions first](../commands/irregular_handler.md#notes) — `ifCanSelect` and `repeatWhileCanSelect` close declared interruptions before judging so a covered target does not read as "not found".
- [OS system dialogs are not touched](../commands/irregular_handler.md#notes) — permission prompts and "Open in …?" belong to `iosAlertHandler`, not this.
- [iOS separate-window modals](../commands/irregular_handler.md#notes) — a fully covered screen drops out of the tree (so it never reads as a false pass), a partial cover leaves the rest, and taps reach the frontmost window.

### Keyboard assertion (keyboardIsShown, keyboardIsNotShown)
- [Unknown keyboard state is never "hidden"](../commands/keyboard_assertion.md#notes) — `keyboardIsNotShown` can fail with "cannot determine the keyboard state" in iOS xcuitest mode; use inapp-boost or Android when you must confirm hiding.

### launchApp, restartApp, terminateApp, openURL
- [`launchApp` always terminates first](../commands/launch_app.md#notes) — it never just foregrounds the app, so every call starts at the entry screen.
- [`launchApp` keeps app data](../commands/launch_app.md#notes) — saved content and login state remain; use `clearAppData()` to erase.
- [iOS inapp-boost: other apps fail mid-scenario](../commands/launch_app.md#notes) — the in-app bridge cannot drive another app; put steps on other apps (such as Settings) in a separate scenario under a profile naming that app.
- [fleetest's own bridge cannot be the target](../commands/launch_app.md#notes) — passing the bridge's ID to `launchApp` / `restartApp` fails without sending anything.
- [Default app resolution](../commands/launch_app.md#notes) — an omitted `appID` resolves from the run profile, app profile, then platform app; `@TestClass` has no `app:`, so running the same scenario under another profile changes the app; with several apps, pass the bundle ID or use a per-app profile.
- [`openURL` does not restart the process](../commands/launch_app.md#notes) — use it for deep links to an open app, and `launchApp(url:)` to restart then deliver.
- [First `openURL` on a Simulator](../commands/launch_app.md#notes) — a one-time "Open in …?" alert is dismissed automatically; if the session could not be re-pointed at the app, the step passes with `open-url-session-not-restored`.
- [`openURL` while the app is not running](../commands/launch_app.md#notes) — the OS launches it, but that is not the command's purpose; use `launchApp(url:)`.

### home, back, appSwitcher, tapAppIcon, rotateTo, fold, unfold, hinge
- [Bring the app back after leaving it](../commands/navigation.md#notes) — on iOS inapp-boost and Android, after `home()`, `appSwitcher()`, `tapAppIcon()`, `openURL()` and similar, steps fail (`app-in-background`) until `launchApp()` or `tapAppIcon()`.
- [`back(settle:)` depends on the screen](../commands/navigation.md#notes) — custom navigation may need an edge swipe, and Android's first `back` closes an open keyboard; tap the app's own back button where it cannot go back.
- [Unchanged screen after `back()` only adds a note](../commands/navigation.md#notes) — the step does not fail when the app ignores system back; tap its own back button or call `back()` again.
- [`back-stayed-on-screen` and similar notes](../commands/navigation.md#notes) — a `back()` that stayed on the same screen (iOS) or left the app for the launcher (Android `back-left-app`) stays green with a note; check where you landed.
- [`tapAppIcon` search order](../commands/navigation.md#notes) — current screen, then the drawer or home pages, and the App Library on iOS; it fails with "App icon not found" if never found.
- [iOS: a system alert hides the icons](../commands/navigation.md#notes) — `tapAppIcon` fails naming the alert; answer it in the scenario or register `iosAlertHandler`.
- [Two-display Simulator tree mismatch](../commands/navigation.md#notes) — `tapAppIcon` never taps when the home-screen tree does not match the shown display, and fails with a message saying so.
- [iOS `back()` after the app was stopped](../commands/navigation.md#notes) — after `terminateApp()`, `removeApp()` or `clearAppData()` it fails unsent, and in inapp-boost `tapAppIcon()` launches instead of tapping; start the app with `launchApp()` first.
- [`rotateTo` follows the app's UI orientation](../commands/navigation.md#notes) — only `.portrait` and `.landscape` exist, with identical frames across OS and frameworks.
- [`rotateTo` waits for the change](../commands/navigation.md#notes) — it returns only once the orientation has actually changed.
- [Orientation reverts automatically](../commands/navigation.md#notes) — a scenario that rotates is restored at the end, with Android's auto-rotate setting too.
- [The app must allow the orientation](../commands/navigation.md#notes) — otherwise it will not rotate; on Android a forbidden orientation fails right away naming the app's declaration.
- [Android auto-rotate is disabled while rotating](../commands/navigation.md#notes) — otherwise the angle would not hold.
- [`settle: false` skips the settle wait](../commands/navigation.md#notes) — the next step may see a moving screen; use it only when the next step does not depend on final positions.
- [`fold` / `unfold` / `hinge` need a foldable device](../commands/navigation.md#notes) — only the iPhone Duo Simulator and foldable Android Emulators work; a physical iPhone is skipped, and a physical foldable Android fails.
- [Non-foldable devices are skipped, not failed](../commands/navigation.md#notes) — the scenario is recorded as not applicable from that step on, so do not read it as a pass.
- [Fold state is restored automatically](../commands/navigation.md#notes) — like `rotateTo`, it reverts at the end of the scenario.
- [Foldable Android lock screen](../commands/navigation.md#notes) — `fold()` dismisses the swipe-up lock screen; a PIN or pattern lock cannot be dismissed.
- [`hinge` does not verify which screen shows](../commands/navigation.md#notes) — the switch angle depends on the previous state; use `fold()` / `unfold()` when you need a specific screen.
- [iOS fold uses an undocumented hinge event](../commands/navigation.md#notes) — a future Xcode may stop accepting it, and `fold` / `unfold` would then fail loudly, never pass silently.

### pressEnter, hideKeyboard
- [`pressEnter` newline vs. commit depends on the field](../commands/press_enter_hide_keyboard.md#notes) — the field decides, not the command; see `type` for the same question about a trailing `\n`.
- [iOS `hideKeyboard()` differs by framework](../commands/press_enter_hide_keyboard.md#notes) — a background tap or the following Enter closes it, and that Enter fires the field's return-key action (search, submit); it fails if neither closes it; React Native inapp-boost sends no Enter.
- [A target under the keyboard](../commands/press_enter_hide_keyboard.md#notes) — `tap` / `type` / `clearInput` scroll first, then close the keyboard without side effects; if that fails, `tap` presses the visible part and `type` / `clearInput` fail untouched.
- [Keyboard state is a separate assertion](../commands/press_enter_hide_keyboard.md#notes) — verify whether it is showing with the keyboard assertions.
- [`settle: false` skips the settle wait](../commands/press_enter_hide_keyboard.md#notes) — the next step may see a moving screen; use it only when the next step does not depend on final positions.

### repeatWhileCanSelect, doUntilTrue
- [`maxLoopCount:` is only a cap](../commands/repeat.md#notes) — it stops a runaway loop and is not an assertion that the loop ran a specific number of times.
- [To wait for appear/disappear, do not loop](../commands/repeat.md#notes) — use `waitForDisplay` / `waitForClose` or `waitSeconds:` instead of `doUntilTrue`; they already poll and record one step.
- [Each attempt is a group](../commands/repeat.md#notes) — attempts are recorded as `"<description> #n"`, and a failing command inside the block stops the scenario.
- [`doUntilTrue` stops only on its own limits](../commands/repeat.md#notes) — `waitSeconds:` and `maxLoopCount:` apply; the 120-second single-command cap does not.
- [A `throw` in the condition fails immediately](../commands/repeat.md#notes) — reserve throwing for a condition that can never become true, not for transient read errors.

### Screen assertion (screenLooksLike)
- [Experimental](../commands/screen_assertion.md#notes) — Japanese descriptions work but their accuracy has not been measured.
- [Requires macOS 27+](../commands/screen_assertion.md#notes) — on macOS 26 the check is skipped automatically; check availability with `fleetest doctor`.
- [Not a strict gate](../commands/screen_assertion.md#notes) — results depend on wording and how the screenshot is taken; use it for rough checks and write tree-based checks where failure is not acceptable.
- [Does not count as an assertion](../commands/screen_assertion.md#notes) — an `expectation` with only `screenLooksLike` is warned about as having no assertions, though a failure still aborts the scenario.
- [Describe the screen in the call](../commands/screen_assertion.md#notes) — you always write what the screen should look like in the call itself.

### screenshot
- [Place it where you want the picture](../commands/screenshot.md#notes) — the screenshot is embedded right after the step that took it.
- [Android WebView may be missing](../commands/screenshot.md#notes) — the capture can drop the WebView layer; it is filled in only when WebView debugging is on, so never assert a screen loaded from a screenshot; use `exist` / `notExist`.

### select, lastElement
- [`select` never fails by itself](../commands/select.md#notes) — a missing element becomes an empty element; only chained commands such as `.textIs(...)` can fail the step.
- [Android: refused while the app is not in front](../commands/select.md#notes) — it waits and fails instead of returning an empty element; bring the app back with `launchApp()` or `tapAppIcon()` first.
- [`lastElement` resets](../commands/select.md#notes) — it is empty at each `scene` start and after a failed grab, and empty with a warning if nothing was grabbed yet.
- [`select` waits the default timeout](../commands/select.md#notes) — without `waitSeconds:` it looks up to `defaultTimeout` (5 s) before returning an empty element; use `waitSeconds: 0` to look once.

### State assertion (enabledIsTrue, enabledIsFalse, checkIsON, checkIsOFF)
- [Checked state comes from accessibility](../commands/state_assertion.md#notes) — iOS implementations report it differently and fleetest reads all of them (selected trait, switch value, React Native checkbox).
- [Some elements never report a checked state](../commands/state_assertion.md#notes) — `checkIsON` fails with "reports no check state"; verify a reflecting text with `textIs` or have the app expose it. `checkIsOFF` passes on such an element (warning at the end of the run).
- [Implementations that report only "on"](../commands/state_assertion.md#notes) — `checkIsOFF` on an element never seen on passes without knowing the state, with only a warning at the end of the run.
- [Indeterminate state fails both](../commands/state_assertion.md#notes) — a partially checked element fails `checkIsON` and `checkIsOFF`.
- [`enabledIsTrue` / `enabledIsFalse` judge the state at select time](../commands/state_assertion.md#notes) — an element drawing no text (a loading skeleton row) returns an empty element, yet the state at select time is used.

### suppressHandler, useHandler, disableHandler, enableHandler
- [Prefer the block form `suppressHandler { }`](../commands/suppress_handler.md#notes) — automatic closing is restored even when a step inside fails.
- [`disableHandler()` / `enableHandler()` span sections](../commands/suppress_handler.md#notes) — they are the only pair that spans `condition` / `action` / `expectation`.
- [`useHandler { }` is nested only](../commands/suppress_handler.md#notes) — it restores closing for the nested block, then the outer suppression resumes.
- [Suppressing does not stop the interruption showing](../commands/suppress_handler.md#notes) — only closing is stopped, so a tap sent while a modal is up can still be swallowed.
- [Failure note while suppressed](../commands/suppress_handler.md#notes) — a failing step gets "a declared interruption was on screen but automatic closing is suppressed here"; nothing is added on success.
- [Forgetting `enableHandler()` leaves suppression on](../commands/suppress_handler.md#notes) — it stays on for the rest of the scenario, including `afterEach()` cleanup; use the block form.
- [OS system dialogs are unaffected](../commands/suppress_handler.md#notes) — permission prompts belong to `iosAlertHandler`, and an alert the scenario resolves directly is never taken either way.

### swipe, swipePointToPoint, swipeElementToElement, swipeBy
- [`swipe` direction is the finger's movement](../commands/swipe.md#notes) — it is the only command not content-based; every `scroll*` command uses content direction, so `.down` moves the finger up.
- [`swipe` does not check that anything moved](../commands/swipe.md#notes) — the step stays green when there is nothing to move; verify afterwards with `exist` or similar.
- [Building blocks for maps and canvases](../commands/swipe.md#notes) — `swipeBy` and `swipeElementToElement` serve maps, image viewers and drawing canvases; see gestures.
- [`settle: false` skips the settle wait](../commands/swipe.md#notes) — the next step may see a moving screen; use it only when the next step does not depend on final positions.

### tap, tapAppIcon
- [Covered-element handling applies only where draw order is known](../commands/tap.md#notes) — the next three notes apply to UIKit/React Native on iOS inapp-boost and Views/React Native on Android.
- [Several matches, first one covered](../commands/tap.md#notes) — an uncovered match is tapped with a note; if every match is covered, nothing is tapped and the step fails.
- [Centre under a tab bar or footer](../commands/tap.md#notes) — the list scrolls once, then the visible part is pressed with a note; a part thinner than 8pt/8dp fails without tapping.
- [Target under a bar outside the list](../commands/tap.md#notes) — without `scroll:` nothing is tapped and the step fails suggesting a direction; add `scroll:` to scroll it out from under.
- [Target hidden behind a window or modal](../commands/tap.md#notes) — on iOS inapp-boost the failure names the window or modal that left the target out of the tree; close it first.
- [Unknown draw order: centre is pressed](../commands/tap.md#notes) — SwiftUI, Compose, Flutter, xcuitest and MCP presses the centre even if covered, so make sure nothing covers the target at that step; a later failing check names the overlapper.
- [App crashed, another app in front](../commands/tap.md#notes) — the step fails without touching that tree, so an element with the same `#id` in another app is never operated.
- [`tap` waits for the target to be enabled](../commands/tap.md#notes) — up to `waitSeconds:` (5 s), then it taps anyway; skipped when the selector pins `enabled=false` or `waitSeconds: 0`.
- [Appearance wait is short](../commands/tap.md#notes) — only about 0.7 s without `waitSeconds:`, so pass `waitSeconds: 5` or `waitForDisplay` for elements that appear late; `type` behaves the same.
- [`tap` then `type` works](../commands/tap.md#notes) — on Android a container may not take focus, and `type` recovers by locating the single input inside; see `type`.
- [Android bottom gesture band](../commands/tap.md#notes) — an element whose centre is in the gesture band is touched above it (note), so the OS cannot send the app to the background; an element wholly in the band is touched at its centre.
- [iOS in-app "real touch would land elsewhere" note](../commands/tap.md#notes) — the step stays green with `inapp-tap-outside-hit-area`, but the same tap can fail on the XCUITest bridge; check that the element is truly reachable.
- [Coordinate taps are a last resort](../commands/tap.md#notes) — prefer a selector in scenarios you keep, because coordinates hit whatever is there after the layout moves.
- [`settle: false` skips the settle wait](../commands/tap.md#notes) — the next step may see a moving screen; use it only when speed matters and the next step does not depend on final positions.

### Text assertion (textIs, textContains, ...)
- [Four rules for comparing text](../commands/text_assertion.md#notes) — compared as it looks on screen, half-width/full-width spaces and line breaks differ, empty expected values cannot be used with contains-style checks, and regexes are used as written.
- [Empty regular expression fails before comparing](../commands/text_assertion.md#notes) — empty, spaces-only or invisible-only patterns would match any text, so `textMatches` and its siblings reject them.
- [Empty expected value fails before comparing](../commands/text_assertion.md#notes) — for contains/starts/ends-with checks an empty or invisible-only string would hold for any text; invisible characters are removed from both sides.
- [Comparison is "same if it looks the same"](../commands/text_assertion.md#notes) — invisible characters are ignored, half-width and full-width spaces differ, NBSP equals a space; `strict: true` disables the normalization.
- [The element is assumed to exist](../commands/text_assertion.md#notes) — these commands wait up to `waitSeconds` for the value to change, so they can wait for a value update.
- [Negative and empty forms ignore visibility](../commands/text_assertion.md#notes) — `textIsNot`, `textIsEmpty` and similar cannot confirm "not visible" from a screen match.
- [No `scroll:` on text assertions](../commands/text_assertion.md#notes) — they verify a static screen, so scroll the target into view first with `select(selector, scroll: .down)`.
- [Chained checks use the grabbed value first](../commands/text_assertion.md#notes) — if it already satisfies the assertion the step records `(from the grabbed value)` with no device round trip; otherwise it polls up to `waitSeconds`.

### type
- [`type("")` fails before typing](../commands/type.md#notes) — it would do nothing; to empty a field use `clearInput()` or `type("", replace: true)`.
- [Android: field under a popup window](../commands/type.md#notes) — the focusing tap would select the suggestion, so the step fails before typing; close the popup first.
- [Non-input target fails before typing](../commands/type.md#notes) — `type` taps first, so a button would be pressed; an element wrapping exactly one input types into it with a warning.
- [Typing into a filled field appends](../commands/type.md#notes) — the step stays green with only a note; use `replace: true` or `clearInput(sel)` first when replacing.
- [Line breaks (`\n`) follow the OS](../commands/type.md#notes) — newline versus commit depends on the field; to commit use `pressEnter()`, and on iOS xcuitest a middle newline is not read back, so split the text.
- [The next action waits for the soft keyboard](../commands/type.md#notes) — up to 1.5 s before resolving its target, with `keyboard-not-shown-after-type` if it never appears; skipped when the text ends with a newline.
- [`tap(field)` then `type("text")` is supported](../commands/type.md#notes) — on Android `type` recovers focus into the single inner field (`type-focus-recovered`); if ambiguous, write `type(sel, "text")` instead.
- [Android: selector-less `type` checks where text went](../commands/type.md#notes) — with no focus reported the step passes with `type-focus-not-reported`, so check the screen or use the selector form.
- [Android: selector-less input with another app in front](../commands/type.md#notes) — the text may go to that app (`ref-less-input-on-other-app`); pass the field's selector.
- [Typed value is read back and repaired](../commands/type.md#notes) — missing or doubled characters are fixed, a mid-string drop clears and retypes once (`type-retyped`), and a field transforming input is accepted (`type-retype-abandoned`), so check with `valueIs`.
- [Android: field may not keep the whole text](../commands/type.md#notes) — a limited field shows "did not keep the last N character(s)" yet the result stays green; check with `textIs` / `valueIs`.
- [Value does not move at all](../commands/type.md#notes) — OCR (macOS 27+) accepts text drawn in the field (`type-readback-unchanged`); otherwise the input is re-sent once and then the step fails.
- [iOS xcuitest: only the first 512 units of a field's value can be read](../commands/type.md#notes) — longer text is accepted when the readable part matches and the rest is not checked; check the whole text with `textIs` on the app's display.
- [`settle: false` skips the settle wait](../commands/type.md#notes) — the next step may see a moving screen; use it only when the next step does not depend on final positions.

### Value assertion (valueIs, valueContains, ...)
- [Use `value*` for text fields](../commands/value_assertion.md#notes) — an empty field is `valueIsEmpty` everywhere, while `text` returns the placeholder in Compose iOS, Flutter iOS and React Native, so do not assert `textIsEmpty` on fields.
- [Negative and empty forms ignore visibility](../commands/value_assertion.md#notes) — none of these commands take `scroll:`, the same rules as text assertions.
- [Chained checks use the grabbed value first](../commands/value_assertion.md#notes) — the device is polled only if that value does not yet satisfy the assertion.

### Anything assertion (verify)
- [A block with zero assertions is `inconclusive`](../commands/verify.md#notes) — it is neither passed nor failed and does not abort the scenario, so make sure the block really asserts something.
- [A failing command still aborts](../commands/verify.md#notes) — if a command inside the block fails, the scenario aborts as usual.

### wait, waitForDisplay, waitForClose, waitForSettle
- [Appearance is already implicit](../commands/wait.md#notes) — operations retry and assertions poll, so `wait()` before `exist()` is redundant; raise `waitSeconds:` instead.
- [`wait()` is a last resort](../commands/wait.md#notes) — use it only for settling with no selector to poll; use `waitForSettle` rather than a fixed `wait()`.
- [`waitForDisplay` judges visibility like `exist`](../commands/wait.md#notes) — it has no `requireVisible: false`; use `exist(sel, requireVisible: false, waitSeconds: 15)` to skip the visibility check.
- [`waitForDisplay` / `waitForClose` never scroll](../commands/wait.md#notes) — scroll first or use `scrollTo` if the element may be off-screen.

## Selectors

### Typed selector (Sel)
- [Misspelled member is a compile error](../selector/typed_selector.md#notes) — unlike the string form, `.buton` fails at compile time instead of silently becoming a literal label.
- [`scrollFrame:` stays string-only](../selector/typed_selector.md#notes) — there is no `Sel` overload for that argument, even on commands with a full `Sel` overload.
- [Generated code uses the string form](../selector/typed_selector.md#notes) — `Sel` is for people who prefer to write selectors by hand.

## UI component quirks (current limitations)

### While a modal is open, the screen behind it drops out of the tree
- [React Native collapses under `accessible` ancestors](ui_component_patterns.md#while-a-modal-is-open-the-screen-behind-it-drops-out-of-the-tree) — on iOS only, inner elements of `Tooltip` and `BottomSheetModal` go missing; the app must pass `accessible={false}`, so a scenario cannot fix it.
- [Flutter iOS overlay shrinks a11y rects](ui_component_patterns.md#while-a-modal-is-open-the-screen-behind-it-drops-out-of-the-tree) — after an overlay, taps land in the wrong spot in xcuitest mode only; move to another screen and back before the next action.

### Bottom sheet
- [RN persistent sheet on iOS does not expand by search](ui_component_patterns.md#bottom-sheet) — swipe up from the sheet's title to open it fully before searching.

### Selection field (read-only dropdown)
- [Suggestion rows have no id](ui_component_patterns.md#selection-field-read-only-dropdown) — in Android View's `MaterialAutoCompleteTextView` and Flutter's `DropdownMenu`, target suggestions by label.

### Pull to refresh
- [Long pull needed on SwiftUI and RN iOS](ui_component_patterns.md#pull-to-refresh) — about 470pt is needed; a roughly 260pt swipe does not start the refresh, so use a raw `gesture` dragging the full screen ratio.
- [xcuitest: `scrollToTop()` can run an extra refresh](ui_component_patterns.md#pull-to-refresh) — in lists whose rows lack `#id` or short lists not flush with the frame, the edge-confirming swipe becomes a pull.
- [Flutter iOS `scrollToTop()` can also refresh](ui_component_patterns.md#pull-to-refresh) — this is under investigation, so do not rely on a refresh count after it.
- [Do not read the refresh count after `scrollToTop()`](ui_component_patterns.md#pull-to-refresh) — verify the count before it in scenarios that check the refresh count.
- [Android is unaffected](ui_component_patterns.md#pull-to-refresh) — `scrollToTop()` / `scrollToBottom()` use accessibility scroll actions and never overscroll into a pull.

### Animation (fade, switch)
- [Flutter `AnimatedOpacity` keeps hidden elements in the tree](ui_component_patterns.md#animation-fade-switch) — do not use "the element is absent" as a visibility check; judge by the app's state echo or `checkIsON` / `checkIsOFF`.

### Navigation
- [Android View: toolbar back may not go back one level](ui_component_patterns.md#navigation) — with stacked detail screens the tap sometimes does nothing; use the OS `back()` in multi-level stack scenarios.

### Collapsing header
- [RN collapsible tabs on iOS: first rows hide behind the header](ui_component_patterns.md#collapsing-header) — fleetest cannot scroll them out from under it; tap a row that is visible below the header.

### Types of input fields
- [Android: non-focused popup content can be missing](ui_component_patterns.md#types-of-input-fields) — autocomplete suggestion lists and tooltips may not appear in the tree; check the confirmed value through the app's echo.
- [Android Flutter autocomplete suggestions are at the wrong position](ui_component_patterns.md#types-of-input-fields) — `tap` on a suggestion hits the field and stays green without selecting it; always verify the selected value afterwards.
- [Android refuses `ACTION_SET_TEXT` on some fields](ui_component_patterns.md#types-of-input-fields) — there is no workaround, but ordinary `type` keystrokes still work.
- [RN iOS suggestion below the field may not be tappable](ui_component_patterns.md#types-of-input-fields) — in inapp-boost the keyboard stays up after `pressEnter()` and hides the suggestion (under investigation); lay out the screen to avoid it or check the value via the app's echo.

### FAB (floating action button)
- [Android View `BottomAppBar` folds items into "More options"](ui_component_patterns.md#fab-floating-action-button) — folded rows cannot carry an id; `tap("More options")` to open the overflow first.

### Infinite scroll
- [RN `FlatList` can load pages without scrolling](ui_component_patterns.md#infinite-scroll) — `onEndReached` may fire when initial data fits one screen; there is no scenario-side workaround, so keep it in mind when asserting an exact initial row count.

### Bars that hide on scroll
- [Flutter `AnimatedSlide` bar stays at its original place](ui_component_patterns.md#bars-that-hide-on-scroll) — the search does not scroll and the tap may land where the button no longer is.

### Link
- [index](../../index.md)
