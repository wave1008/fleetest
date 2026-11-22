# Run profile settings

[in Japanese(日本語)](run_profile_ja.md)

`profiles/runs/<name>.json` combines an app, a device list and run-time settings. This page
lists every recognized key. See [profiles.md](./profiles.md) for the app profile it references
and how a device entry names its machine, and [running_scenarios.md](../running/running_scenarios.md)
for how `--profile` selects one.

```json
{ "app": "myapp",
  "devices": [
    { "platform": "ios", "machine": "local", "name": "iPhone 17 Pro(iOS 27.0)-01", "osVersion": "iOS 27.0", "model": "iPhone 17 Pro" },
    { "platform": "android", "machine": "local", "name": "Pixel 9(Android 16, API 36, APIs)-01", "avd": "Pixel_9_Android_16_API_36_APIs_-01" }
  ],
  "heal": true, "reportDir": "reports", "defaultTimeout": 5,
  "wipeDataOnBloat": true, "wipeDataThresholdGB": 8 }
```

## Keys

| Key | Type | Default | Meaning |
|---|---|---|---|
| `app` | string | — | Name of the `apps/<name>.json` profile to use. The run profile inherits that app profile's `platform` (target OS); `devices` of other OSes are ignored at run time ([profiles.md](./profiles.md)) |
| `devices` | array | — | Device entities to run (iOS/Android can mix in the same list). Each entry: `platform` (`"ios"`/`"android"`, required), `machine` (the machine it lives on — `"local"` for this Mac, or a name registered with `fleetest remote machines add`), `name` (required; unique together with `machine`; for an iOS Simulator this is the Simulator's own name), `enabled` (`false` keeps it listed but does not run it; default = run it. When "Use physical devices for tests" is off in the monitor's Settings tab on the Mac that starts the run, physical devices are not run regardless of `enabled`, including those on runner machines), plus the device's own body keys (`osVersion`/`udid`/`avd`/`serial`/`kind`/`port`/`mode`/`model` — see [profiles.md](./profiles.md)) |
| `heal` | bool | `true` for `--profile` runs, `false` for a plain `fleetest run` | Allow selector self-healing (fingerprint matching; see [self_healing.md](../running/self_healing.md)). Independent of the FM- and OCR-based toggles below — self-healing does not use FM |
| `fmTextVisibilityCheck` | bool | `true` | Use FM (Foundation Models, experimental — see [environments.md](../../overview/environments.md)) for text visibility check. See [Text visibility check](../testclass/text_visibility_check.md). FM is called only when this or `screenLooksLike` is `true` |
| `screenLooksLike` | bool | `true` | Enable `screenLooksLike` (FM visual verification, experimental — see [environments.md](../../overview/environments.md)). When `false`, those steps are skipped rather than failing |
| `ocrTextVisibilityCheck` | bool | `true` | Use on-device OCR (Vision) for text visibility check. Independent of `fmTextVisibilityCheck`; the verification runs when either is `true` (and not at all when both are `false`). When FM gives no verdict, this reading alone decides. See [Text visibility check](../testclass/text_visibility_check.md) |
| `preferCheckStateClassifier` | bool | `true` | For `checkIsON` / `checkIsOFF`, prefer CheckStateClassifier (an image classifier trained from the sample images in the project's `vision/classifiers/CheckStateClassifier/[ON]` and `[OFF]`) over accessibility. When `false`, it is used only for elements whose accessibility reports no check state. It has no effect without sample images |
| `reportDir` | string | `"reports"` | Where to write Markdown reports (relative to the project root) |
| `defaultTimeout` | number (seconds) | `5` | Default timeout for DSL commands that take `waitSeconds:` |
| `scenarioTimeout` | int (seconds) | `600` | Host-side wall-clock timeout per scenario (watchdog). Distinct from `defaultTimeout`, which only bounds individual command waits. `@Test(scenarioTimeout:)` on a scenario overrides it for that scenario (even when shorter). Separately, a scenario whose output stops for 240 seconds (twice the 120-second per-step limit) is stopped there (a slow scenario that keeps making progress is not). Also editable as "Scenario time limit (seconds)" under "Test execution" in the run profile on the monitor's Profiles tab |
| `iosMode` | string | `"inapp-boost"` | `"inapp-boost"` → iOS devices run in inapp-boost mode (the XCUITest bridge plus the in-app bridge: operations the in-app bridge can perform go through it, faster; the rest go through the XCUITest bridge); `"xcuitest"` → XCUITest bridge only. Any other value is an error. A `responseMeasurement` run defaults to `"xcuitest"` instead (the measurement lives in the XCUITest bridge). A device's own `mode` in its `devices[]` entry takes precedence if set. No effect on Android |
| `wipeDataOnBloat` | bool | `true` | At run start, wipe an Android AVD's data if the wipe-affected files (userdata/cache/snapshots) exceed `wipeDataThresholdGB`. When installing the app fails because the device is out of storage, that device also gets a Wipe Data and the install is tried once more (with `false` the device is not wiped and drops out of the run) |
| `wipeDataThresholdGB` | number (GB) | `8` | Threshold for `wipeDataOnBloat` |
| `updateWebView` | bool | `true` | Reconcile the on-device WebView version at the start of a run, so the same scenario does not behave differently across devices with different WebView builds |
| `recoverCpuFallbackToGpu` | bool | `false` | At run start, restart any Android Emulator that has fallen back to CPU rendering (swiftshader) in GPU mode instead |
| `locale` | string | `"ja_JP"` | Locale applied to an Android Emulator on boot. No effect on iOS |
| `iosPreActionPing` | bool | `true` | On interop WebView screens (WebViews embedded by Compose/Flutter etc.), query the runner once right before each tap/type. An attached XCUITest session that has sat idle can report success while failing to deliver the coordinate event. Costs ~0.4s per event on those screens only (reads and other screens are unaffected). Only takes effect in inapp-boost mode |
| `containerInference` | bool | `true` | Enable geometry-based corrections that infer scroll containers (edge clamping, off-screen tap correction, etc.). Unrelated to FM |
| `enableAnimations` | bool | `false` | Keep the app's animations instead of disabling them for the run |
| `responseMeasurement` | bool | `false` | Response measurement mode for **one Android or iOS physical device**. The run must use exactly one enabled device (after narrowing with `--device`), and it must be `kind: physical`, otherwise the run is refused. The run keeps the app's animations (`enableAnimations` is forced on), runs iOS in xcuitest mode, turns off `fmTextVisibilityCheck`, `ocrTextVisibilityCheck`, `screenLooksLike`, `record` and host-load pacing, and holds the Device Monitor until the run ends. Setting `enableAnimations: false`, `iosMode` (or a device's `mode`) to `inapp-boost`, or any of the FM/OCR/`record` keys to `true`, together with it is an error. Cannot be combined with `--broadcast`, `--fleet` or `--split`. See [Response measurement](../running/response_measurement.md) |
| `responseRepeat` | int | `5` | Only with `responseMeasurement: true` (specifying it without is an error). How many times each scenario runs back to back on the device, `1` to `50`. Every iteration is measured; the result files are named `<id>`, `<id>~2`, `<id>~3`, … |
| `orientation` | string | unset (leave the orientation alone) | `portrait` or `landscape` (the same values as `rotateTo`). Rotates right after every `launchApp` / `restartApp` (a relaunch can drop the orientation); the original orientation from before the first rotation is restored when the scenario ends. Works with `--set orientation=landscape`, with or without `--profile`. Any other value (including capitalized ones) is an error and the run is refused. The rotation is an ordinary [`rotateTo`](../commands/navigation.md) step, so the report shows it; if the app does not allow that orientation, that step fails. A scenario that never calls `launchApp` / `restartApp` is not rotated |
| `appearance` | string | unset (light) | `light` or `dark`. The appearance every scenario starts with. When unset, every scenario starts in light, so a device left in dark is put back before the scenario runs. Works with `--set appearance=dark`, with or without `--profile`. Any other value is an error and the run is refused. iOS uses Xcode's `devicectl` on both Simulators and physical devices; Android uses `cmd uimode night`. See [Notes](#notes) |
| `textSize` | string | unset (`default`) | `small` / `default` / `large` / `extraLarge` / `accessibility`. The text size every scenario starts with. The names are matched by body-text size across the OSes (iOS step as named by `devicectl` / Android scale): `small` is `small` / 0.85, `default` is iOS's standard (large) / 1.0, `large` is extra-large / 1.15, `extraLarge` is extra-extra-extra-large / 1.3, `accessibility` is accessibility-large / 2.0. On Android 14 and later, larger text grows less than the scale suggests, so the on-screen size is not guaranteed to match across the OSes. On iOS, `accessibility` turns on "Larger Accessibility Sizes" for the scenario and puts it back to its earlier value afterwards. Works with `--set textSize=extraLarge`. Any other value is an error and the run is refused. See [Notes](#notes) |
| `variants` | array | unset (no variants) | Named display conditions to run every scenario under (see [Variants](#variants)). Each entry is `{ "name", "appearance"?, "textSize"?, "orientation"? }`; the unit of a run becomes scenario × variant |
| `homeOnStart` | bool | `true` for `--profile` runs, `false` for a plain `fleetest run` | Press Home once on every device at run start (works around devices staying black after a mass launch) |
| `playProtectBypass` | bool | `true` | Skips the Play Protect prompt ("Send app for a security check?") on Android `adb install` by turning "Verify apps over USB" off for the install and restoring it afterwards (the app is never sent to Google). `false` is the kill switch: the tool leaves the device setting alone, and a release-signed APK stays blocked on the device's own dialog (the tool never answers it) |
| `record` | bool | `true` | Record each worker's screen for the whole run and cut it into a per-scenario clip. A physical iPhone has no way to capture video, so its clip is a slideshow of the screen captured just before the first action and right after each action step and each failed step, shown at the time each was taken (each capture costs about 50 ms). Physical Android devices record normally. A Simulator, Emulator or physical Android device whose screen recording cannot start also switches to this slideshow, with a warning |
| `recordFailuresOnly` | bool | `false` | With `record: true`, keep only clips for failed (including frozen) scenarios |
| `recordBitrateKbps` | int | `1000` | Re-encoding bitrate for saved clips |
| `recordFullResolution` | bool | `false` | With `record: true`, skip the half-resolution re-encode. Test time does not change, but clip size and the wait for cutting clips after all tests finish go up, more so on screens with more motion |
| `remoteControl` | object | — | Workspace declaration (`{ "workspace": "<path>" }`). The workspace is always enabled and defaults to `TestProjects/<project>/workspace`. Even a local run stages the original `appPath` package here and reads `scripts/run-setup.sh` / `run-teardown.sh` and `scripts/compose.yaml` from it; see [Remote runs](../../fleet/remote_runners.md) |

## Variants

`variants` runs the same scenarios under several display conditions (appearance, text size, orientation) in one run. Write the names and the values that differ; the tool runs every selected scenario once per variant, in the order you declared them.

```json
{
  "variants": [
    { "name": "default" },
    { "name": "dark", "appearance": "dark" },
    { "name": "large-text", "textSize": "extraLarge" },
    { "name": "dark-landscape", "appearance": "dark", "orientation": "landscape" }
  ]
}
```

- A name is required, unique, and written as lowercase letters, digits and hyphens starting with a letter (`[a-z][a-z0-9-]*`). Unknown keys, duplicate names, an empty list and invalid values are errors before the run starts. There is no way to write "every combination": list the combinations you want.
- A key a variant does not write takes the same key at the top of the profile, and then the base value (`light` / `default`). **The resolved values count as written**, so a variant that cannot be applied fails its scenario (a variant named `default` is not allowed to stay green on a device stuck in dark mode).
- When any variant writes `orientation`, every variant must write it (or the profile must have a top-level `orientation`); otherwise the run is refused. Every scenario rotates to its own orientation right after its first launch, so an orientation left by the previous scenario is always overwritten.
- With `variants`, `--set appearance=` / `textSize=` / `orientation=` / `variants=` are refused (the name would no longer match what ran). Add a variant instead.
- The results, reports and recordings of a variant are named `<scenario ID>@<variant>` (for example `S0010@dark`); a JUnit test case is `S0010[dark]`. A run without `variants` is unchanged.
- Pick variants with `--variant <name>` (repeatable) and units with `--scenario S0010@dark` (see [Running scenarios](../running/running_scenarios.md)). `--failed` re-runs the units (scenario × variant) that failed.
- A scenario that needs different values per variant reads `currentVariant` ([Memo](../commands/memo.md)).

## Notes

- Every scenario starts in light appearance and the default text size on every device, even when the profile does not say so: the tool reads the device before and after each scenario and sets whatever differs. At the end of each scenario the device goes back to light and the default text size whatever the profile says, so after the run the device stays in light / default; it is not put back to what it was before the run. If you ran a device in dark mode or with large text, write `appearance` / `textSize` in the profile. Template images captured in dark mode no longer match unless you do. The MCP `ft_run_scenario` does the same, so exploring with the other `ft_*` tools keeps the device as you left it only until the first `ft_run_scenario`.
- If a value you wrote (`appearance` / `textSize`) cannot be set or cannot be confirmed by reading it back, that scenario fails before it starts. If the device cannot be put back to light / default when you wrote nothing, the run continues with a warning in the log, and the tool does not try that again on that device until some setting succeeds. On iOS in `inapp-boost` mode, a Simulator that does not deliver the change to the app (the setting reads back correctly but the app still has the old one) fails the scenario with `failureKind=display-not-applied` after 5 seconds, and the tool restarts that Simulator's SpringBoard before the next scenario; `xcuitest` mode and Android check only the device's setting. Verified only on an iOS 26.6.2 physical device, an iOS 27.2 Simulator and Android Emulators/physical devices; older iOS versions and Simulator runtimes are unverified.
- Hooks and the run memo are shared across variants: `beforeAll` / `afterAll` run once per class per run (`beforeAll` under the display condition of the first unit that runs, `afterAll` in the base state), `setUpDevice` runs once per device and class, and the run memo is one memo for the whole run. To keep values apart per variant, put `currentVariant` in the memo key.
- A class with `@RunInOrder` / `@RunOnSingleDevice` / `@RunOnSingleMachine` stays on one device (machine) across all variants and runs variant by variant (v1: t1, t2, t3, then v2: t1, t2, t3). A failure in the middle of `@RunInOrder` stops only the rest of the same variant.
- On iOS, a text size set from Control Center for "this app only" is not visible to the tool. The result of each scenario records what was expected, what was read and the keys set before the scenario started (not a `setAppearance` / `setTextSize` in the middle of the scenario) in `displaySettings`.

## FM usage

FM (Foundation Models) is called only when `fmTextVisibilityCheck` or `screenLooksLike` is `true`;
both default to `true`. When both are
`false`, FM is never called for that run — set both to `false` to keep a run from calling FM at
all. With `fmTextVisibilityCheck` set to `false`, the verification still runs on OCR alone while
`ocrTextVisibilityCheck` is `true` (FM is not called). `heal` does not use FM, so it is governed only by its own key.
Whether self-healing is on by default depends on how you invoke the run: **a `--profile` run
defaults `heal` to ON**, while a plain `fleetest run` (no profile) defaults it to OFF.
`fleetest run --profile <name> --set <key>=<value>` overrides almost any key on this table for one
run without editing the profile file — e.g. `--set heal=false`, `--set fmTextVisibilityCheck=false`,
`--set reportDir=/tmp/out`, `--set defaultTimeout=8` (the value must match the
key's type shown above; repeatable). It works with or without `--profile` — except the keys that need a run
profile's device list or supply pipeline (`iosMode`, `updateWebView`, `wipeDataOnBloat`,
`recoverCpuFallbackToGpu`, `app`, `locale`, `wipeDataThresholdGB`, `responseMeasurement`, `responseRepeat`), which require
`--profile`. `devices` and `remoteControl` are a list and an object and cannot be expressed as
`<key>=<value>`; edit the profile JSON for those. `record` needs either `--profile` or `--port` given more than once (a single connection has no recording session to attach to). `reportDir` cannot be combined with `--report-dir` (same field, two ways to set it). The run profile key `app` names an app **profile**, unrelated to `fleetest run`'s `--app-id` flag. An unknown key or a value of the wrong type passed to `--set` is an error
(an unknown key inside the profile JSON only prints a warning and is ignored).

## iOS mode

The effective iOS mode is `inapp-boost` (the XCUITest bridge plus the in-app bridge: operations the in-app bridge can perform go through it, faster; the rest go through the XCUITest bridge) by default —
`iosMode: "xcuitest"` switches a run to the XCUITest bridge only. A physical iOS device uses inapp-boost mode
**when the app is development-signed** (get-task-allow; the tool signs the injected bridge
with the app's own team). An app that is not development-signed (TestFlight / App Store) falls back
to xcuitest mode automatically. When you dispatch to a runner machine, the Mac you dispatch from signs the bridge
with the app's certificate and sends it along, so the runner does not need the signing key.

Normally keep the default, inapp-boost. In xcuitest mode the following change: "hidden" cannot be confirmed for the keyboard ([Keyboard](../commands/keyboard_assertion.md)), the HTML `id` of WebView content cannot be used as `#id` ([WebView](../selector/webview.md)), and double tap does not work on iOS Compose apps ([Gestures](../commands/gestures.md)).

### Link
- [index](../../index.md)
