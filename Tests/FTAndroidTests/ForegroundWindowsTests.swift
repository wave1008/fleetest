import XCTest
@testable import FTAndroid

/// `dumpsys window windows` から「アプリより手前の別 window」を拾う規則。
/// 入力は実機(Pixel 9 / Android 15)の実出力を要点だけ残したもの。
final class ForegroundWindowsTests: XCTestCase {

    private let package = "com.ftester.e2e"

    /// name と可視性だけを持つ最小のブロックを組み立てる(実出力と同じ字面・字下げ)
    private func dump(_ windows: [(String, Bool)]) -> String {
        windows.enumerated().map { index, entry in
            """
              Window #\(index) Window{abc\(index) u0 \(entry.0)}:
                mViewVisibility=0x0 mHaveFrame=true mObscured=false
                isVisible=\(entry.1)
            """
        }.joined(separator: "\n")
    }

    func testShadeCoveringFollowsTheWindowVisibility() {
        XCTAssertTrue(AndroidForegroundWindows.shadeCovering(dumpsys: dump([("NotificationShade", true), ("StatusBar", true)])))
        XCTAssertFalse(AndroidForegroundWindows.shadeCovering(dumpsys: dump([("NotificationShade", false), ("StatusBar", true)])))
    }

    func testReportsNothingWhenOnlyChromeIsInFront() {
        let text = dump([
            ("ScreenDecorOverlay", false), ("Taskbar", true), ("NotificationShade", false),
            ("StatusBar", true), ("InputMethod", false),
            ("\(package)/\(package).MainActivity", true),
        ])
        XCTAssertEqual(AndroidForegroundWindows.overlaying(package: package, dumpsys: text), [])
    }

    func testReportsVisibleForeignWindowAboveTheApp() {
        let text = dump([
            ("Taskbar", true), ("NotificationShade", true), ("StatusBar", true),
            ("\(package)/\(package).MainActivity", true),
        ])
        XCTAssertEqual(AndroidForegroundWindows.overlaying(package: package, dumpsys: text),
                       ["NotificationShade"])
    }

    /// 実害の形: IME(Gboard)の案内シートがアプリの上に出る
    func testReportsImeDialogInZOrder() {
        let ime = "com.google.android.inputmethod.latin/…StylusOnboardingActivity"
        let text = dump([
            ("StatusBar", true), (ime, true), ("InputMethod", true),
            ("\(package)/\(package).MainActivity", true),
        ])
        XCTAssertEqual(AndroidForegroundWindows.overlaying(package: package, dumpsys: text),
                       [ime])
    }

    /// キーボード自身の窓だけが手前にあるときは何も言わない(前後で他の窓が居れば、その窓だけを報告する)
    func testSoftKeyboardWindowIsNotCountedAsAnOverlay() {
        let onlyKeyboard = dump([("StatusBar", true), ("InputMethod", true),
                                 ("\(package)/\(package).MainActivity", true)])
        XCTAssertEqual(AndroidForegroundWindows.overlaying(package: package, dumpsys: onlyKeyboard), [])
        let withShade = dump([("NotificationShade", true), ("InputMethod", true),
                              ("\(package)/\(package).MainActivity", true)])
        XCTAssertEqual(AndroidForegroundWindows.overlaying(package: package, dumpsys: withShade), ["NotificationShade"])
    }

    func testIgnoresWindowsBehindTheAppAndOtherAppsThatAreHidden() {
        let text = dump([
            ("StatusBar", true),
            ("\(package)/\(package).MainActivity", true),
            ("com.other.app/com.other.app.MainActivity", true),   // 背面(z 順が下)
            ("com.hidden.app/com.hidden.app.MainActivity", false),
        ])
        XCTAssertEqual(AndroidForegroundWindows.overlaying(package: package, dumpsys: text), [])
    }

    /// アプリの window が見つからない(別アプリが前面・取得失敗)ときは黙る
    func testReturnsEmptyWhenAppWindowIsAbsent() {
        let text = dump([("StatusBar", true), ("com.other.app/com.other.app.MainActivity", true)])
        XCTAssertEqual(AndroidForegroundWindows.overlaying(package: package, dumpsys: text), [])
    }

    /// アプリ自身の別 window(ダイアログ等)は「別プロセス」ではないので報告しない
    func testIgnoresAppsOwnAdditionalWindow() {
        let text = dump([
            ("\(package)/\(package).DialogActivity", true),
            ("\(package)/\(package).MainActivity", true),
        ])
        XCTAssertEqual(AndroidForegroundWindows.overlaying(package: package, dumpsys: text), [])
    }

    /// Android 15 の実出力形: mCurrentFocus 行は無く、可視のアプリ窓は前面の1つだけ
    /// (背面アプリ・ランチャーは isVisible=false)。E2E で appIs が必ずタイムアウトした退行の再発防止
    func testTopmostAppPackageFromZOrderWithoutCurrentFocusLine() {
        let text = dump([
            ("ScreenDecorOverlay", true), ("Taskbar", true), ("StatusBar", true),
            ("InputMethod", false),
            ("com.ftester.e2e.flutter/com.ftester.e2e.flutter.MainActivity", true),
            ("com.ftester.e2e/com.ftester.e2e.MainActivity", false),
            ("com.google.android.apps.nexuslauncher/….NexusLauncherActivity", false),
        ])
        XCTAssertEqual(AndroidForegroundWindows.topmostAppPackage(dumpsys: text),
                       "com.ftester.e2e.flutter")
    }

    /// mCurrentFocus 行がある(旧形式)ときはそちらを優先する
    func testTopmostAppPackagePrefersCurrentFocusLineWhenPresent() {
        let text = dump([
            ("com.zorder.top/com.zorder.top.MainActivity", true),
        ]) + "\n  mCurrentFocus=Window{1755f66 u0 com.focused.app/com.focused.app.MainActivity}"
        XCTAssertEqual(AndroidForegroundWindows.topmostAppPackage(dumpsys: text),
                       "com.focused.app")
    }

    /// 可視のアプリ窓が1つも無い(ホーム画面すら取れない・取得失敗)ときは nil で黙る
    func testTopmostAppPackageReturnsNilWhenNoVisibleAppWindow() {
        let text = dump([("StatusBar", true), ("InputMethod", true),
                         ("com.hidden.app/com.hidden.app.MainActivity", false)])
        XCTAssertNil(AndroidForegroundWindows.topmostAppPackage(dumpsys: text))
    }

    private func realDump(_ name: String) throws -> String {
        try String(contentsOf: URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Fixtures/AndroidWindowDumps/\(name)"), encoding: .utf8)
    }

    /// 実出力(Pixel 9 / Android 15 の Emulator): 帯の中の押下でランチャーへ抜けた後。アプリの窓は isVisible=false
    func testFrontAppWhileHiddenNamesTheLauncherWhenTheAppWentToTheBackground() throws {
        let text = try realDump("launcher-in-front.txt")
        XCTAssertEqual(AndroidForegroundWindows.frontAppWhileHidden(package: "com.ftester.e2ey.flutter", dumpsys: text),
                       "com.google.android.apps.nexuslauncher/com.google.android.apps.nexuslauncher.NexusLauncherActivity")
        XCTAssertEqual(AndroidForegroundWindows.overlaying(package: "com.ftester.e2ey.flutter", dumpsys: text), [])
    }

    func testFrontAppWhileHiddenIsNilWhileTheAppIsInFront() throws {
        let text = try realDump("app-in-front.txt")
        XCTAssertNil(AndroidForegroundWindows.frontAppWhileHidden(package: "com.ftester.e2ey.flutter", dumpsys: text))
        // 接頭辞が重なる別パッケージ(com.ftester.e2ey)を対象アプリと取り違えない
        XCTAssertEqual(AndroidForegroundWindows.frontAppWhileHidden(package: "com.ftester.e2ey", dumpsys: text),
                       "com.ftester.e2ey.flutter/com.ftester.e2ey.flutter.MainActivity")
    }

    /// アプリが見えている間は、背後に可視の別アプリの窓があっても名指ししない(前面の判定は overlaying の担当)
    func testFrontAppWhileHiddenIsNilWhenTheAppIsVisibleEvenWithAnotherVisibleAppBehind() {
        let text = dump([
            ("StatusBar", true),
            ("\(package)/\(package).MainActivity", true),
            ("com.other.app/com.other.app.MainActivity", true),
        ])
        XCTAssertNil(AndroidForegroundWindows.frontAppWhileHidden(package: package, dumpsys: text))
    }

    /// 可視のアプリ窓が1つも無い(取得失敗の形)ときは黙る
    func testFrontAppWhileHiddenIsNilWithoutAVisibleAppWindow() {
        let text = dump([("StatusBar", true), ("com.hidden.app/com.hidden.app.MainActivity", false)])
        XCTAssertNil(AndroidForegroundWindows.frontAppWhileHidden(package: package, dumpsys: text))
    }

    func testParsesWindowNameFromRealLine() {
        XCTAssertEqual(
            AndroidForegroundWindows.windowName("Window #7 Window{b9b01a8 u0 InputMethod}:"),
            "InputMethod")
        XCTAssertEqual(
            AndroidForegroundWindows.windowName(
                "Window #8 Window{f2f739c u0 com.ftester.e2e/com.ftester.e2e.MainActivity}:"),
            "com.ftester.e2e/com.ftester.e2e.MainActivity")
        XCTAssertNil(AndroidForegroundWindows.windowName("Window #9 なにか別の行"))
    }

    /// 最後に起こしたアプリが前面なら、実行プロファイルのアプリが背面でも覆いと言わない(撃つ前の門と同じ基準)
    func testLastLaunchedAppInFrontIsNotAnOverlay() {
        let other = "com.example.other"
        let text = dump([
            ("StatusBar", true),
            ("\(other)/\(other).Main", true),
            ("\(package)/\(package).MainActivity", false),
        ])
        XCTAssertEqual(AndroidForegroundWindows.overlayNotes(package: package, alsoAccepted: other, dumpsys: text), [])
        XCTAssertEqual(AndroidForegroundWindows.overlayNotes(package: package, alsoAccepted: nil, dumpsys: text),
                       ["\(other)/\(other).Main (the app's own window is not visible)"])
    }

    /// 最後に起こしたアプリが前面でなければ、従来どおり手前の別 window を言う
    func testForeignWindowIsStillReportedWhenLastLaunchedAppIsNotInFront() {
        let text = dump([
            ("Taskbar", true), ("NotificationShade", true),
            ("\(package)/\(package).MainActivity", true),
        ])
        XCTAssertEqual(AndroidForegroundWindows.overlayNotes(package: package, alsoAccepted: "com.example.other", dumpsys: text),
                       ["NotificationShade"])
    }

    /// 窓の型(`ty=`)付きの最小のブロック。`priority=` のような語尾の `ty=` が先に並ぶ実出力の形も混ぜる
    private func dumpTyped(_ windows: [(String, Bool, String?)]) -> String {
        windows.enumerated().map { index, entry in
            let attrs = entry.2.map { "mAttrs={(0,0)(fillxfill) priority=0 ty=\($0) fmt=TRANSLUCENT}" } ?? "mAttrs={(0,0)(fillxfill)}"
            return """
              Window #\(index) Window{abc\(index) u0 \(entry.0)}:
                \(attrs)
                isVisible=\(entry.1)
            """
        }.joined(separator: "\n")
    }

    /// 実害の形: アプリ自身のダイアログの窓は Activity と同じ名前(`ty=APPLICATION`)で、`overlaying` は名指せない
    func testOwnDialogWindowIsNamedAndTheActivityBodyIsNot() {
        let main = "\(package)/\(package).MainActivity"
        let withDialog = dumpTyped([("StatusBar", true, "STATUS_BAR"), (main, true, "APPLICATION"), (main, true, "BASE_APPLICATION")])
        XCTAssertEqual(AndroidForegroundWindows.overlaying(package: package, dumpsys: withDialog), [])
        XCTAssertEqual(AndroidForegroundWindows.ownDialogs(package: package, dumpsys: withDialog),
                       ["\(main) (the app's own dialog window)"])
        XCTAssertEqual(AndroidForegroundWindows.overlayNotes(package: package, alsoAccepted: nil, dumpsys: withDialog),
                       ["\(main) (the app's own dialog window)"])
        let withoutDialog = dumpTyped([("StatusBar", true, "STATUS_BAR"), (main, true, "BASE_APPLICATION")])
        XCTAssertEqual(AndroidForegroundWindows.ownDialogs(package: package, dumpsys: withoutDialog), [])
    }

    /// 閉じかけで残った不可視のダイアログ・型の読めない窓・他アプリの APPLICATION の窓は数えない
    func testOwnDialogIgnoresInvisibleUntypedAndForeignWindows() {
        let main = "\(package)/\(package).MainActivity"
        let other = "com.example.other/com.example.other.Main"
        let text = dumpTyped([(main, false, "APPLICATION"), (main, true, nil), (other, true, "APPLICATION"),
                              (main, true, "BASE_APPLICATION")])
        XCTAssertEqual(AndroidForegroundWindows.ownDialogs(package: package, dumpsys: text), [])
    }

    func testLayoutTypeSkipsSuffixMatches() {
        XCTAssertEqual(AndroidForegroundWindows.layoutType("mAttrs={priority=0 ty=APPLICATION fmt=OPAQUE}"), "APPLICATION")
        XCTAssertEqual(AndroidForegroundWindows.layoutType("mAttrs={ty=BASE_APPLICATION}"), "BASE_APPLICATION")
        XCTAssertNil(AndroidForegroundWindows.layoutType("mAttrs={priority=0}"))
    }
}
