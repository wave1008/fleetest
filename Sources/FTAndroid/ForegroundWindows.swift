// 対象アプリより手前に出ている「別プロセスの window」の検出。
// アプリの a11y ツリーには他プロセスの window が出ないため、システムダイアログや IME の案内が
// アプリを覆っていても**スナップショット上は正常に見え、tap は成功扱いで返る**
// (実害: Gboard のスタイラス案内が送信ボタンを覆い、05_テキスト入力 が間欠失敗した。
// AndroidBridge.disableStylusHandwriting 参照)。失敗時にこれを添えて再調査を不要にする。

import Foundation
import FTCore

public enum AndroidForegroundWindows {

    /// 常に可視で、操作の邪魔をしない画面装飾。報告しても雑音にしかならないので除く
    /// (前方一致で判定。`NavigationBar0` のような連番付きがあるため)
    static let chromePrefixes = [
        "StatusBar", "Taskbar", "NavigationBar", "ScreenDecorOverlay",
        "EdgeBackGestureHandler", "ShellDropTarget", "ImageWallpaper",
    ]

    /// ソフトキーボード自身の窓(名前が `InputMethod`)。「前にある別の窓」には数えない —— キーボードの表示は
    /// 木のキーボード枠(`keyboardFrame`)が別の判定で言う。数えると入力欄の値を確かめる失敗に毎回
    /// 「別の窓が手前」が添う。IME が出す案内などの別名の窓(`…StylusOnboardingActivity`)は従来どおり報告する
    static let softKeyboardWindowName = "InputMethod"

    /// `dumpsys window windows` の出力から、**対象アプリの window より手前**にある
    /// 可視の別 window 名を z 順(手前が先)で返す。アプリの window が見つからなければ空
    /// (判定できないときは黙る = 誤った断定をしない)
    public static func overlaying(package: String, dumpsys: String) -> [String] {
        let blocks = windowBlocks(dumpsys)
        guard let appIndex = blocks.indices.first(where: {
            blocks[$0].visible && blocks[$0].name.hasPrefix("\(package)/")
        }) else { return [] }

        return blocks.indices.prefix(upTo: appIndex).compactMap { index in
            guard blocks[index].visible else { return nil }
            let name = blocks[index].name
            guard !name.hasPrefix("\(package)/") else { return nil }
            // アプリ自身の PopupWindow は ownDialogs が数える(別のプロセスの窓と言わない)
            guard !isOwnSubWindow(blocks[index], package: package) else { return nil }
            guard !chromePrefixes.contains(where: { name.hasPrefix($0) }) else { return nil }
            guard name != softKeyboardWindowName else { return nil }
            return name
        }
    }

    /// **対象アプリ自身のダイアログの窓**(同じ package の可視の窓で `ty=APPLICATION`)。窓の名前がアプリの Activity と同じなので
    /// `overlaying` は自分の package の窓として除く —— ダイアログの裏の要素への操作の失敗が覆いを名指さなかった。
    /// Activity 本体は `ty=BASE_APPLICATION`。型が読めない窓は数えない(判定できないときは黙る)。
    /// **アプリの PopupWindow(メニュー・ドロップダウン・ツールチップ)も数える**: 名前は `PopupWindow:<hash>` で package を持たず、
    /// 持ち主は窓の `package=` の欄・型は `APPLICATION_SUB_PANEL`(Android 17 の Emulator で実測)。数えないと `overlaying` が
    /// 「別のプロセスの窓」と言い、裏の要素の失敗が waitSeconds: を勧めていた。起動中の窓(`APPLICATION_STARTING`)は除く
    public static func ownDialogs(package: String, dumpsys: String) -> [String] {
        windowBlocks(dumpsys).compactMap { block in
            guard block.visible, isOwnSubWindow(block, package: package) else { return nil }
            return "\(block.name) (the app's own dialog window)"
        }
    }

    private static func isOwnSubWindow(_ block: (name: String, visible: Bool, type: String?, owner: String?),
                                       package: String) -> Bool {
        guard let type = block.type else { return false }
        if type == "APPLICATION", block.name.hasPrefix("\(package)/") { return true }
        return block.owner == package && type.hasPrefix("APPLICATION_") && type != "APPLICATION_STARTING"
    }

    /// `dumpsys window windows` にソフトキーボード(IME)の window が**表示中**で存在するか。
    /// AndroidDriver.snapshot() の keyboardShown 判定用(オンデバイスのブリッジは別プロセスの
    /// window を a11y ツリーから見れないため、ホスト側でここを叩いて補う)。
    /// isVisible=false の居残り window(閉じかけ等)は false 扱い(overlaying と同じ可視性規約)
    public static func keyboardVisible(dumpsys: String) -> Bool {
        windowBlocks(dumpsys).contains { $0.visible && $0.name.hasPrefix("InputMethod") }
    }

    /// 通知シェード・クイック設定・ロック画面の窓が**表示中**か(閉じると isVisible=false で残る。Android 15 Emulator で実測)
    public static func shadeCovering(dumpsys: String) -> Bool {
        windowBlocks(dumpsys).contains { $0.visible && $0.name == "NotificationShade" }
    }

    /// 入力フォーカスを持つ窓が通知シェード・クイック設定・ロック画面(解除画面)の窓か(`mCurrentFocus=Window{… NotificationShade}`)。
    /// **渡すのは `dumpsys window displays` の出力**(`windows` には行が無い。Android 12・13・15 で実測)。行が無ければ false。
    /// 通知の到着(ヘッズアップ)でもシェードの窓は可視になりうるが入力フォーカスは持たない(実測: 通知の到着ではアプリのまま・
    /// シェードとクイック設定を開くと NotificationShade)ので、可視かどうかではなくフォーカスで見る
    public static func inputFocusHeldByShade(dumpsys: String) -> Bool {
        guard let line = dumpsys.split(separator: "\n", omittingEmptySubsequences: false)
            .map({ $0.trimmingCharacters(in: .whitespaces) })
            .first(where: { $0.hasPrefix("mCurrentFocus=") }),
              let name = windowName(line) else { return false }
        return name == "NotificationShade"
    }

    /// `dumpsys window displays` の `isKeyguardShowing=` 行。ロック画面・解除画面が出ている間 true
    /// (Android 15 Emulator で実測: PIN ロックの消灯→点灯 = true・解除後 = false・解除済みでシェードを開いても false)。
    /// 行が無ければ nil(読めない = 「出ていない」にしない)
    public static func keyguardShowing(displaysDumpsys: String) -> Bool? {
        for raw in displaysDumpsys.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line == "isKeyguardShowing=true" { return true }
            if line == "isKeyguardShowing=false" { return false }
        }
        return nil
    }

    /// `Window #N Window{... 名前}:` ブロックを (名前, isVisible) の並び(z 順)に分解する。
    /// overlaying / keyboardVisible の共通パーサ(可視性判定はここ1箇所)
    private static func windowBlocks(_ dumpsys: String) -> [(name: String, visible: Bool, type: String?, owner: String?)] {
        var names: [String] = []
        var visibility: [Bool] = []
        var types: [String?] = []
        // `mOwnerUid=… package=<pkg> appop=…` の行の package(窓の持ち主。名前に package を持たない PopupWindow を見分ける)
        var owners: [Int: String] = [:]
        var current: String?
        for line in dumpsys.split(separator: "\n", omittingEmptySubsequences: false) {
            let text = line.trimmingCharacters(in: .whitespaces)
            if text.hasPrefix("Window #"), let name = windowName(text) {
                // 直前のブロックが isVisible / ty= を持たなかった場合に列がずれないよう埋める
                if current != nil, names.count > visibility.count { visibility.append(false) }
                if current != nil, names.count > types.count { types.append(nil) }
                names.append(name)
                current = name
            } else if current != nil, text.hasPrefix("isVisible="),
                      names.count > visibility.count {
                visibility.append(text == "isVisible=true")
            } else if current != nil, text.hasPrefix("mOwnerUid="),
                      let field = text.split(separator: " ").first(where: { $0.hasPrefix("package=") }) {
                owners[names.count - 1] = String(field.dropFirst("package=".count))
            } else if current != nil, names.count > types.count, text.hasPrefix("mAttrs="),
                      let type = layoutType(text) {
                types.append(type)
            }
        }
        if names.count > visibility.count { visibility.append(false) }
        if names.count > types.count { types.append(nil) }
        return (0..<names.count).map { (name: names[$0], visible: visibility[$0], type: types[$0], owner: owners[$0]) }
    }

    /// `mAttrs={… ty=APPLICATION …}` の窓の型(`APPLICATION` = ダイアログ・`BASE_APPLICATION` = Activity 本体)。
    /// `priority=` のような語尾の `ty=` を拾わないよう、直前が英字の `ty=` は数えない
    static func layoutType(_ attrsLine: String) -> String? {
        var searchStart = attrsLine.startIndex
        while let found = attrsLine.range(of: "ty=", range: searchStart..<attrsLine.endIndex) {
            searchStart = found.upperBound
            if found.lowerBound > attrsLine.startIndex,
               attrsLine[attrsLine.index(before: found.lowerBound)].isLetter { continue }
            let value = attrsLine[found.upperBound...].prefix { $0.isLetter || $0.isNumber || $0 == "_" }
            if !value.isEmpty { return String(value) }
        }
        return nil
    }

    /// `Window #7 Window{b9b01a8 u0 InputMethod}:` → `InputMethod`
    static func windowName(_ line: String) -> String? {
        guard let braceIndex = line.firstIndex(of: "{"),
              let closeIndex = line.lastIndex(of: "}") , braceIndex < closeIndex else { return nil }
        let inner = line[line.index(after: braceIndex)..<closeIndex]
        // `<hash> u<user> <名前>` の3つ目以降(名前に空白は入らない)
        let parts = inner.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true)
        guard parts.count == 3 else { return nil }
        return String(parts[2])
    }

    /// 最前面のアプリの package 名を返す。DSL の appIs 用。
    /// 本線は z 順の window リスト: **可視(isVisible=true)のアプリ窓は前面の1つだけ**で、
    /// 背面アプリ・ランチャーは isVisible=false、システム装飾・IME は名前に `/` を含まない
    /// (Android 15 エミュレータで実測)。`mCurrentFocus=` 行があれば優先するが、
    /// Android 15 の `dumpsys window windows` にはこの行が出ない(実測。行前提の実装は
    /// 常に nil になり appIs が必ずタイムアウトした)。
    /// どちらでも取れなければ nil(不明。判定できないときは黙る=overlaying と同じ規約)
    public static func topmostAppPackage(dumpsys: String) -> String? {
        if let line = dumpsys.split(separator: "\n", omittingEmptySubsequences: false)
            .map({ $0.trimmingCharacters(in: .whitespaces) })
            .first(where: { $0.hasPrefix("mCurrentFocus=") }),
           let name = windowName(line),
           let slashIndex = name.firstIndex(of: "/") {
            return String(name[..<slashIndex])
        }
        for block in windowBlocks(dumpsys) where block.visible {
            if let slashIndex = block.name.firstIndex(of: "/") {
                return String(block.name[..<slashIndex])
            }
        }
        return nil
    }

    /// 対象アプリの window が1枚も可視でなく、**別のアプリの window が前面に可視**ならその名前(`<package>/<activity>`)。
    /// `overlaying` はアプリの window が見えないと黙るので、ランチャーへ抜けた(帯の中の押下でホームへ)・
    /// 別アプリが開いた形が失敗の記録に何も残らなかった(探索は「スワイプが届いていない」と言った)。
    /// 前面が読めなければ nil(判定できないときは黙る)
    public static func frontAppWhileHidden(package: String, dumpsys: String) -> String? {
        let blocks = windowBlocks(dumpsys)
        guard !blocks.contains(where: { $0.visible && $0.name.hasPrefix("\(package)/") }) else { return nil }
        return blocks.first(where: { $0.visible && $0.name.contains("/") && !$0.name.hasPrefix("\(package)/") })?.name
    }

    /// 失敗の記録に添える「手前の別 window」の判定(純粋関数)。**最後に起こしたアプリ(`alsoAccepted`)が前面なら覆いと言わない**
    /// —— 撃つ前の門(`StepExecutor.backgroundedAppRefusal`)は実行プロファイルのアプリか最後に起こしたアプリのどちらかが前面なら通すので、
    /// 注記も同じ基準で比べる(食い違うと門が通した操作の失敗に「別の window が手前」と添える)
    public static func overlayNotes(package: String, alsoAccepted: String?, dumpsys: String) -> [String] {
        if let other = alsoAccepted, other != package, topmostAppPackage(dumpsys: dumpsys) == other { return [] }
        if let front = frontAppWhileHidden(package: package, dumpsys: dumpsys) {
            return ["\(front) (the app's own window is not visible)"]
        }
        return ownDialogs(package: package, dumpsys: dumpsys) + overlaying(package: package, dumpsys: dumpsys)
    }

    /// 実機/エミュレータへ問い合わせる。adb が無い・失敗した場合は空(失敗診断の付加情報なので非致命)
    public static func query(package: String, alsoAccepted: String? = nil, serial: String) -> [String] {
        guard let adb = try? AndroidDriver.findADB(),
              let output = try? Shell.run([adb, "-s", serial, "shell", "dumpsys", "window", "windows"],
                                          timeout: 10).outputIfSucceeded else { return [] }
        return overlayNotes(package: package, alsoAccepted: alsoAccepted, dumpsys: output)
    }
}
