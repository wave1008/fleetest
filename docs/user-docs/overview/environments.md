# Environment

[in Japanese(日本語)](environments_ja.md)

## Supported environment

### What you prepare and install

| Target | Requirement |
|---|---|
| Machine and OS | A Mac with Apple silicon, macOS 26+ |
| Xcode | Xcode 27.2+ (<https://apps.apple.com/app/xcode/id497799835>) |
| Homebrew | Homebrew (<https://brew.sh/>) |
| VSCode | VSCode (<https://code.visualstudio.com/docs/setup/mac>) |
| Android SDK | Android SDK (adb, Command-line Tools) (if you test Android) (<https://developer.android.com/studio/install>). Creating an Emulator needs Java (the one bundled with Android Studio, or a JDK; without either, `--auto-device` fails) |
| Devices under test | iOS 18 or later (Simulator, physical), Android 8.0 (API 26) or later (Emulator, physical) |
| iOS physical devices (if used) | An Apple Developer Program team (a free Personal Team's signing expires in about 7 days). See [Adding physical devices](../fleet/adding_physical_devices.md) |
| AI assistant | One that supports MCP. Claude Code and Codex are verified. For others (Cline, Cursor, Copilot, etc.) see [AI assistants other than Claude Code](../reference/tools/other_agents.md) |

Administrator rights are needed only to accept the Xcode license and to install Homebrew (the AI assistant does not do these for you).

### What is installed automatically

- Node.js
- VSCode extension (fleetest)
- iOS Simulator runtime and Simulator
- Android system image and Emulator

### Optional: Foundation Models (FM)

FM works on macOS 26+ (System Settings → Apple Intelligence & Siri). **Only the features that pass an image (`screenLooksLike` and the FM stage of the text visibility check) need macOS 27+** (System Settings → Siri). **On-device OCR (Vision text recognition) is also macOS 27+ only**: on macOS 26, `tap(linkText:)` fails with that requirement, the screen readback of typed text is skipped, and the OCR stage of the text visibility check is off. Everything else works.

On a Mac without FM, `screenLooksLike` passes without being judged (a ⚠️ line is printed at start), and the text visibility check uses OCR only.

Features that use FM are experimental (their behavior may change with OS updates).

## Supported UI frameworks

| Framework | Platforms |
|---|---|
| SwiftUI / UIKit | iOS |
| Compose Multiplatform | iOS, Android |
| Flutter | iOS, Android |
| React Native | iOS, Android |
| View/XML, Jetpack Compose | Android |

<br>

Next: [Quick start](../quick-start.md)

### Link
- [index](../index.md)
