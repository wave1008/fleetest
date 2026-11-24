# launchApp, restartApp, terminateApp, openURL

[in Japanese(日本語)](launch_app_ja.md)

Starts, restarts, stops the app under test, or delivers a deep link URL to it.

## Functions

| function | description |
|---|---|
| `launchApp(appID?, url:)` | Terminates the app if running, then launches it fresh, starting at the entry screen. With `url:`, delivers that URL right after launch (see `openURL` below for delivery details). Delivery waits for the first screen to render (until a tappable element appears, up to the default wait), because frameworks such as React Native discard a URL that arrives before the screen is up; if none appears, the URL is delivered anyway with the note `launch-url-before-interactive-ui` — the step does not fail. `appID` defaults to the default app (see Notes). |
| `openURL(url)` | Delivers a URL (deep link) to the already-running app without restarting it (warm delivery) — the transition is pushed on top of the current screen. Requires a custom URL scheme; Universal Links / App Links (`https://`) depend on AASA/assetlinks.json resolution and can fall through to Safari on a Simulator. On iOS in inapp-boost mode, a URL that opens another app waits (up to 2 seconds) for the app to leave the foreground before the next step runs (on a physical device it waits for the app's own URLs too). |
| `restartApp(appID?)` | Terminates and launches again, resetting in-process state. `appID` defaults the same way as `launchApp()`. |
| `terminateApp()` | Terminates the app. |

## Example

```swift
launchApp()                                  // default app for this run
launchApp("com.example.myapp")
launchApp(url: "myapp://product/42")         // fresh process, then deliver the URL
openURL("myapp://cart")                      // deliver to the already-running app
restartApp()
terminateApp()
```

## Notes

- **`launchApp` always terminates first, even if the app is already running** — it never just
  brings the app to the foreground. Every call starts at the entry screen — except for **apps that restore their previous screen on launch** (OS stock apps such as Contacts and Notes): a search screen in Contacts, the previously opened note in Notes, the previous display state of the Calculator, and a stopwatch that kept running have been observed to be restored.
  For such apps, put steps right after `launchApp()` that return to the list (for example, press the back button with `ifCanSelect`).
- **OS stock apps change their screens with the device's OS version, language and existing data.** A different version changes ids and
  layout, a different language changes labels and display formats (a stopwatch shows `00:00.00` on one and `00` on another), events or
  alarms already on the device change the order of lists, and an app opened for the first time on a device starts with its first-run screens (welcome, sign-in prompts). Run the scenario on devices with the same OS version and language as the one you
  wrote it on, do not depend on existing data (target the data you created, by its unique name), and close first-run screens with `ifCanSelect`.
- **`launchApp` does not erase the app's data** (saved content, login state, and so on). Only the
  process and the screen state are lost. To erase data, use `clearAppData()`.
- **On iOS in the default mode (inapp-boost), `launchApp` / `restartApp` of an app other than the scenario's own app
  fails in the middle of a scenario.** The in-app bridge runs inside the app under test and cannot drive another app.
  Put the steps on another app (such as Settings) in a separate scenario under a run profile whose app profile names that app; that scenario is driven through the XCUITest bridge automatically.
- **fleetest's own bridge cannot be the target.** Passing the bridge's ID (Android `com.example.ftbridge`, or the iOS runner whose ID ends in `.ftrunner`, `.ftrunner.uitests` or `.ftrunner.uitests.xctrunner`) to `launchApp` / `restartApp`
  fails without sending anything — launching it would stop the bridge the run drives the device through.
- **Default app** (when `appID` is omitted, for `launchApp` / `restartApp` / `terminateApp` /
  `removeApp` / `clearAppData` / `appIs`): resolved from the run profile's `app`, then the app profile, then the current platform's `ios.app` /
  `android.app`. `@TestClass` has no `app:` argument (writing one is a compile error), so the same
  scenario targets each platform's own app when run with `--profile ios-run` and
  `--profile android-run`, without duplicating the class. Without a profile (`--port` / `--serial`),
  pass the app with `--app-id <bundleID>`.

  A project that tests several apps keeps each app's scenarios under a run profile for that app, or
  passes the bundle ID explicitly — `launchApp("<id>")` (also `restartApp("<id>")`,
  `clearAppData("<id>")`) — in the steps that switch to another app.
- **`openURL` does not restart the process** — that is the difference from `launchApp(url:)`,
  which restarts first and then delivers. Use `openURL` to test deep links arriving while the
  app is already open.
- **In a browser, a page opened with `openURL` may not be added to the history.** In iOS Safari, moving to another page with `openURL`
  left the Back button disabled. To check back and forward, follow a link on the page or type into the address bar.
- On an iOS Simulator, the first `openURL` delivery for an app can trigger a one-time system
  confirmation alert ("Open in \"App Name\"?"); both iOS modes dismiss it
  automatically. After that, consent for that device+app combination persists. If, after checking for
  that alert, the session could not be pointed back at the app under test (it may still be pointed at the home screen,
  so the next steps through XCUITest may not reach the app), the step still passes and gets the note
  `open-url-session-not-restored`. The note appears only on a delivery where that check ran.
- `openURL` against an app that is not running lets the OS launch it, but that is not what the
  command is for. To verify opening from a URL when the app is not running, use `launchApp(url:)`.

### Link
- [index](../../index.md)
