# 環境

[in English](environments.md)

## 対応環境

### 利用者が用意してインストールするもの

| 対象 | 要件 |
|---|---|
| マシンと OS | Apple silicon の Mac、macOS 26+ |
| Xcode | Xcode 27.2以降(<https://apps.apple.com/jp/app/xcode/id497799835>) |
| Homebrew | Homebrew(<https://brew.sh/ja/>) |
| VSCode | VSCode(<https://code.visualstudio.com/docs/setup/mac>) |
| Android SDK | Android SDK(adb・Command-line Tools)(Android をテストする場合)(<https://developer.android.com/studio/install?hl=ja>)。Emulator を作るには Java が要ります(Android Studio 同梱の Java か JDK) |
| 実機(使う場合) | iOS 18 以降、Android 8.0(API 26)以降。iOS は Apple Developer Program のチームが必要 |
| AIアシスタント | MCP に対応したもの。動作確認済みは Claude Code・Codex |

### 自動でインストールされるもの

- Node.js
- VSCode 拡張(fleetest)
- iOS Simulator のランタイムと Simulator
- Android のシステムイメージと Emulator

### オプション：Foundation Models (FM)

システム設定で Apple Intelligence をオンにしてください。

## サポートする UI フレームワーク

| フレームワーク | 対象 OS | 確認済みの版 |
|---|---|---|
| SwiftUI / UIKit | iOS | (OS に付属) |
| Compose Multiplatform | iOS, Android | 1.12.1(Kotlin 2.4.21) |
| Flutter | iOS, Android | 3.47.7 |
| React Native | iOS, Android | 0.87.1 |
| View/XML・Jetpack Compose | Android | (OS・AndroidX に付属) |

この版で動作を確認しています。古い版は確かめていません。

<br>

次へ: [クイックスタート](../quick-start_ja.md)

### Link
- [index](../index_ja.md)
