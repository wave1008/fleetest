# home, back, appSwitcher, tapAppIcon, rotateTo, setAppearance, setTextSize, fold, unfold, hinge

[in Japanese(日本語)](navigation_ja.md)

OS-level navigation: home screen, back, app switcher, home screen icon, screen rotation, the device's appearance and text size, and folding a foldable device.

## Functions

| function | description |
|---|---|
| `home()` | Goes to the home screen. |
| `back(settle:)` | Goes back to the previous screen (Android = back key / iOS = the navigation bar's back button, falling back to a left-edge swipe when there is none). |
| `appSwitcher()` | Opens the app switcher. On a home-button iPhone (e.g. iPhone SE) the switcher is a hardware double-press that cannot be sent, so the scenario is recorded as skipped (not applicable) from that step on instead of failing. |
| `tapAppIcon(name?)` | Finds and taps the app icon on the home screen. `name` is matched **exactly** against the name shown under the icon on the home screen. When omitted it is the app profile's `appName` for that OS (`ios.appName` / `android.appName`). |
| `rotateTo(.portrait, settle:)` / `rotateTo(.landscape, settle:)` | Rotates the app UI to that orientation. Only these two values exist. To run every scenario in landscape without writing this, set `orientation` in the [run profile](../project/run_profile.md). |
| `setAppearance(.light)` / `setAppearance(.dark)` | Switches the **device's** appearance and reads it back; the step fails if the value read back differs from the one requested (it succeeds if the device already had it). The device returns to light at the end of the scenario. |
| `setTextSize(.small / .default / .large / .extraLarge / .accessibility)` | Switches the **device's** text size and reads it back; the step fails if the value read back differs from the one requested (it succeeds if the device already had it). The device returns to `.default` at the end of the scenario. |
| `fold(waitSeconds:)` | Folds a foldable device to the outer screen and waits until the device reports it switched (up to `waitSeconds`, default = the run's default timeout). Fails if it does not switch. |
| `unfold(waitSeconds:)` | Unfolds to the inner (large) screen. Same rules as `fold`. |
| `hinge(_ degrees)` | Sets the hinge angle, 0 (folded) to 180 (unfolded); about 130 is the half-open book posture. Does not check which screen shows. |

## Example

```swift
launchApp()
tap("#settings")
back()                  // return to the previous screen
home()
tapAppIcon()             // find and tap the app icon by the app profile's name
appSwitcher()
rotateTo(.landscape)
rotateTo(.portrait)
setAppearance(.dark)    // dark mode (back to light after the scenario)
setTextSize(.extraLarge)
fold()                  // foldable devices only
unfold()
hinge(130)              // half-open book posture
```

## Notes

- **On iOS in inapp-boost mode (the default) and on Android, after `home()`, `appSwitcher()`, `tapAppIcon()`, `openURL()`, `launchApp(url:)` or `back()`, bring the app back before acting on it.** On iOS, while the app under test is not in front (the home screen, another app, or the app switcher is showing),
  a step that reads or touches the app (including `back()`) waits up to its usual wait for the app to come back, then fails instead of
  acting on an app nobody can see.
  On Android the tree is the screen in front, so only steps that would pass on absence — `notExist`, `countIs(0)`, `select` and
  conditions (`ifCanSelect` and the like) — and scroll sends that would reach another app are treated this way (other reads and
  actions apply to the screen in front; you can still read and tap the home screen's icons). When a step is refused:
  `failureKind` is `app-in-background`, or `system-ui-covered` while the app switcher is open.
  Return with `tapAppIcon()` or `launchApp()`.
  `home()` itself finishes only once the app has left the foreground (it presses home again if the app is still
  in front, and fails if it is still in front after three presses).
- **`back(settle:)` reliability depends on the screen.** On iOS, a screen with a system navigation bar
  back button is deterministic; a screen with a framework's own navigation (e.g. a
  custom-drawn nav bar) falls back to an edge swipe, which only works if the screen supports
  interactive pop — do not call `back(settle:)` on a screen that cannot go back that way (use
  `tap()` on the app's own back button instead). On Android, if the soft keyboard is open,
  the first `back(settle:)` closes the keyboard instead of navigating (OS behavior) — call it twice
  when a field may still have focus.
- When the screen is unchanged before and after `back()`, the step gets a note (`the tree is identical to the one before back …`) — the shape of
  an app whose own navigation ignores the system back. The step does not fail; only the note is
  added. To deal with it, `tap` the app's own back button, or call `back()` once more.
- **More notes on `back()`.** On iOS, when there was no back button and `back()` fell back to the left-edge swipe, and the screen afterwards has the same element ids as before, the step gets the note `back-stayed-on-screen` (the swipe may have reached the screen's own content; check which screen it landed on). It does not fail, and it is not given for a screen with fewer than three element ids, since such a screen cannot be told apart from another one. On Android, when the app in front after `back()` is no longer the app under test (the back key on the app's first screen leaves for the launcher), the step gets the note `back-left-app`. It does not fail either, but the steps after it run against whatever is in front; bring the app back with `launchApp()` or `tapAppIcon()`. If a later step then fails with the warning that another window is in front of the app, the log adds that the preceding `back()` left the app. Also on Android, when the soft keyboard was up and `back()` only closed it (the screen stayed the same), the step gets the note `back-closed-keyboard`; call `back()` again to go back.
- **`tapAppIcon` search order**: current screen first; if not found, Android opens the app
  drawer and scrolls (`flickCenterToTop`, up to 8 times), iOS pages through the home screens
  (`flickRightToLeft`, up to 5 times, stopping after two unchanged pages). On iOS, an app that is not
  on any home screen page (only in the App Library) is opened from the alphabetical list that
  appears when the App Library search field (where the paging ends) is tapped, scrolling the list until
  the row is visible. If that list shows rows without a name (iOS sometimes draws an app's row
  without its name), the visible category folders of the App Library are opened one by one as well. Fails with
  `"App icon not found.(name)"` if never found. The icon is tapped only after its position is
  the same in two consecutive screen reads (a moving drawer or page swallows the tap). When the
  icon is your app's, the step then waits for the app to come to the foreground and fails (without
  tapping again) if it does not.
- **On iOS, `tapAppIcon` names a system alert that is in front of the home screen.** While the alert is up, the tree holds only the alert's elements, so the icon is never found. When the icon is not in the tree and an alert is in front, the step fails naming the alert (`App icon not found.(name) — … is in front of the home screen, so the icons are not in the element list and the search was not run`) instead of paging on. Answer the alert in the scenario, or register [`iosAlertHandler`](./ios_alert_handler.md) before the step that triggers it.
- **`tapAppIcon` never taps when the home-screen tree does not match the shown display.** Seen on the iPhone Duo Simulator with Xcode 27.2 RC, where the inner display's layout leaks into the tree. On a Simulator with two built-in displays it compares the tree's screen size with the shown display and fails with `the home screen tree reports a … screen but the shown display is …`; an icon whose centre is reported outside the screen is re-read for the screen wait timeout and then fails with `the home screen reports the icon outside the screen …` instead of tapping a point that cannot land.
- **iOS after `terminateApp()`, `removeApp()` or `clearAppData()` (the app is not running)** (on a Simulator the tool checks whether the app is running; on a physical device it cannot, so the same handling applies only while no step that could start the app has run since it was stopped — starting it with `launchApp()` is the reliable way): `back()` fails without being sent (`back()` would start the app, and a person cannot go back into an app that is not running). Start it with `launchApp()` or `tapAppIcon()`. In inapp-boost mode, `tapAppIcon()` finds the icon and then launches the app instead of tapping it, with a step note (`the app was not running, so after finding its icon this launched the app …`) — an app started from its icon does not carry what inapp-boost mode drives it through, so every later step would fail. When the app is only in the background, the icon is tapped as before. In inapp-boost mode other steps (`rotateTo` and the like) also fail with `The app under test (…) is not running — this scenario stopped it — so this step was not sent` instead of starting the app.
- **`rotateTo` contracts on the app's UI orientation**, not on how the physical device is
  tilted — the frames a scenario reads are in app-space and behave the same across iOS,
  Android, and every supported UI framework. Only `.portrait` and `.landscape` exist (no
  left/right distinction).
- `rotateTo` waits until the orientation has actually changed before returning.
- **A scenario that rotates reverts to the original orientation automatically at the end**
  (Android also restores the auto-rotate setting).
- **The app must allow that orientation, or it will not rotate** (iOS
  `UISupportedInterfaceOrientations`, Android `screenOrientation`).
  On Android, when the app in front forbids that orientation, `rotateTo` fails right away and
  names the app's declaration.
- Android disables auto-rotate while rotating through this command, since the angle would not
  otherwise hold.
- **`settle: false`** skips this command's post-action wait for the screen to settle (the next step may see a moving screen). See [tap](./tap.md) for details.
- **`setAppearance` / `setTextSize` change the whole device and are undone at the end of every scenario.** At the end of every scenario the tool returns the device to light and the default text size (`.default`), and logs a warning in the run log if it cannot. To run every scenario in dark mode or at a larger text size, set `appearance` / `textSize` in the [run profile](../project/run_profile.md) instead.
- **They cannot be used in `beforeRun()` / `afterRun()` / `setUpDevice()` / `tearDownDevice()` / `beforeAll()` / `afterAll()`.** The device is returned to the baseline (light, default text size) after each scenario, so a change made there would only affect the first test; the step fails with a message saying so. Use the run profile's `appearance` / `textSize` for the whole run. A dry run does not change the device.
- **They can be used in `beforeEach()` / `afterEach()`.** Those run for every test, so the change applies to every test of the class.
- **On Android the screen may be recreated.** Unless the app declares `uiMode` (for `setAppearance`) or `fontScale` (for `setTextSize`) in its `configChanges`, the activity on screen is destroyed and created again, so state kept only in memory is lost. The same applies when the device is returned at the end of the scenario. An app that does not save its screen state then returns to its first screen, so change the display condition at the very start of the scenario (before moving to the target screen), or relaunch the app after changing it and reopen the target screen.
- **The step checks the device's setting, not how the app looks.** An app whose colours do not follow the appearance can become unreadable in dark mode (only the background goes dark), and the text visibility check then fails the step. That is a correct failure: check the app's colours.
- **On iOS in `inapp-boost` mode the step also checks that the app received the setting.** Right after `launchApp()` / `restartApp()` and after `setAppearance` / `setTextSize`, the tool asks the in-app bridge which appearance and text size the app is getting and waits up to 5 seconds for it to match. If it never does, the step fails with `failureKind=display-not-applied`, and before the next scenario the tool restarts that Simulator's SpringBoard (the running app and the XCUITest bridge are restarted with it) and says so in the run log; the failed scenario is not run again. A physical iPhone is not restarted (the step just fails). In `xcuitest` mode and on Android only the device's setting is checked.
- **Text size names map to each OS's own steps.** iOS: `.small` = `small`, `.default` = `large` (the iOS standard), `.large` = `extra-large`, `.extraLarge` = `extra-extra-extra-large`, `.accessibility` = `accessibility-large` (it also turns on "Larger Accessibility Sizes", which goes back to its earlier value at the end of the scenario). Android: `font_scale` 0.85 / 1.0 / 1.15 / 1.3 / 2.0; since Android 14 the OS scales text non-linearly, so the on-screen size ratio is not exactly the scale. Confirmed on a physical iPhone (iOS 26.6.2), the iOS 27.2 Simulator and Android Emulator/physical devices.
- **`fold` / `unfold` / `hinge` need a foldable device.**
  - iOS: the iPhone Duo **Simulator** (Xcode 27.2+), sent through the XCUITest bridge, which both iOS modes support.
  - Android: a foldable **Emulator** (an AVD with a hinge sensor, e.g. Pixel 9 Pro Fold).
  - A physical iPhone can neither be folded nor have its fold state read, so the scenario is recorded as skipped (not applicable), with the reason `fold / unfold / hinge cannot drive a physical iPhone (fold it by hand); they run on the iPhone Duo simulator`.
  - On a physical Android device, a non-foldable model gets the not-applicable treatment below; a foldable model is not supported (fold by hand) and the step fails with that message.
- **On a non-foldable device the scenario is recorded as skipped (not applicable), not failed**, from that step on (same treatment as `appSwitcher()` on a home-button iPhone). The reason reads: `fold / unfold / hinge need a foldable device (the iPhone Duo simulator or a foldable Android Emulator)`. When this happens inside `setUpDevice()`, the remaining tests of the same class on that device are recorded as skipped (not applicable) with the same reason.
- **A not-applicable scenario is handed to a device that has not tried it yet, within the same run.** When a scenario declares itself not applicable (`fold()` on a non-foldable device, `appSwitcher()` on a home-button iPhone), the result is not finalized: the scenario goes to another device of the same OS in the run (another device on the same machine or a device on another machine) that has not tried it. It is recorded as skipped (not applicable) only when every device of that OS in the run has tried it, or when no other device of that OS existed in the run. If a device that had not tried it dropped out of the run (it could not join, or left), the scenario is recorded as **failed** (`not run: …`) instead of passing with nothing executed. Scenarios of a class bound to one device (`@RunInOrder` / `@RunOnSingleDevice`) are not moved to another device, and `@RunOnSingleMachine` stays within its machine. The discarded attempt is listed in the run's retries.
- **Inside `beforeAll()`, it fails instead of becoming not applicable.** `beforeAll()` runs once per run, on the device that takes the class's first scenario, and is not run again on another device. Put preparation whose outcome depends on the device, such as `fold()` / `unfold()` / `appSwitcher()`, in `setUpDevice()` (it runs on each device; a not-applicable result there makes that device's scenarios of the class not applicable).
- **The fold state is restored automatically at the end of the scenario** (like `rotateTo`'s orientation).
- **A foldable Android device shows a lock screen ("swipe up to continue") over the app when it is folded.** `fold()` dismisses it so the app is on the outer screen before the next step (the same unlock fleetest does before each scenario; a PIN or pattern lock cannot be dismissed).
- **`hinge` does not verify which screen shows.** On the iPhone Duo Simulator the switch depends on the previous state (measured: opening switches between 120 and 150 degrees, closing between 20 and 10 degrees). On a foldable Android Emulator the posture follows angle ranges (Pixel 9 Pro Fold AVD: 0-30 closed, 30-150 half-opened, 150-180 opened). Use `fold()` / `unfold()` when the scenario needs a specific screen.
- **iOS mechanism**: Apple provides no public API to fold the Simulator, so fleetest sends the same undocumented hinge event as Xcode's DeviceHub. A future Xcode may stop accepting it; `fold` / `unfold` verify the switch, so they would then fail loudly, never pass silently.
- **The iPhone Duo Simulator may keep crashing once unfolded**: after `unfold()`, the Simulator's home screen (SpringBoard) and keyboard process may crash and restart every dozen seconds or so (a bug in the iOS 27.2 Simulator). While they restart the app goes to the background and the keyboard disappears, so a step that runs then works on that incomplete screen — for example `hideKeyboard()` passes without doing anything because no keyboard is shown. The report of a scenario during which they crashed lists how many times, when, and the crash report file. When you verify on the unfolded screen, check the result after an action, for example with `keyboardIsNotShown()`. If the Simulator stops responding because of these crashes, the run shuts that Simulator down and finishes on the remaining devices without it (the next run boots it again).

### Link
- [index](../../index.md)
