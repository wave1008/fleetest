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
| Android SDK | Android SDK (adb, Command-line Tools) (if you test Android) (<https://developer.android.com/studio/install>). Creating an Emulator needs Java (the one bundled with Android Studio, or a JDK) |
| Physical devices (if used) | iOS 18 or later, Android 8.0 (API 26) or later. iOS needs an Apple Developer Program team |
| AI assistant | One that supports MCP. Claude Code and Codex are verified |

### What is installed automatically

- Node.js
- VSCode extension (fleetest)
- iOS Simulator runtime and Simulator
- Android system image and Emulator

### Optional: Foundation Models (FM)

Turn on Apple Intelligence in System Settings.

## Supported UI frameworks

| Framework | Platforms | Verified version |
|---|---|---|
| SwiftUI / UIKit | iOS | (comes with the OS) |
| Compose Multiplatform | iOS, Android | 1.12.1 (Kotlin 2.4.21) |
| Flutter | iOS, Android | 3.47.7 |
| React Native | iOS, Android | 0.87.1 |
| View/XML, Jetpack Compose | Android | (comes with the OS and AndroidX) |

These are the versions we have verified. Older versions have not been checked.

<br>

Next: [Quick start](../quick-start.md)

### Link
- [index](../index.md)
