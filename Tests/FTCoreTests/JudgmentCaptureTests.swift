// 画像判定の絵の撮り分け(FTCore.JudgmentCapture と StepExecutor.judgmentScreenshot)。
// inapp-boost モードの in-app ブリッジの絵にはキーボードもシステムアラートも写らないので、覆いがあると分かっているときだけ
// 画面全体の絵(fallbackDriver = XCUITest)で撮る。

@testable import FTCore
import XCTest

final class JudgmentCaptureTests: XCTestCase {

    private func source(omits: Bool = true, whole: Bool = true, always: Bool = false,
                        keyboard: Bool = false, alert: Bool?) -> JudgmentCapture.Source {
        JudgmentCapture.source(primaryOmitsSystemUI: omits, hasWholeScreen: whole, alwaysWholeScreen: always,
                               keyboardShown: keyboard, alertCovering: alert)
    }

    func testDecisionTable() {
        // xcuitest 単独・Android・MCP(主ドライバの絵が画面全体)は今までどおり
        XCTAssertEqual(source(omits: false, keyboard: true, alert: true), .primary)
        // inapp 単独は撮り直す先が無い
        XCTAssertEqual(source(whole: false, keyboard: true, alert: true), .primary)
        XCTAssertEqual(source(keyboard: true, alert: nil), .wholeScreen, "キーボードは木だけで分かる = 聞かない")
        XCTAssertEqual(source(always: true, alert: nil), .wholeScreen)
        XCTAssertEqual(source(alert: nil), .probeSystemAlert)
        XCTAssertEqual(source(alert: true), .wholeScreen)
        XCTAssertEqual(source(alert: false), .primary)
    }

    private let alert = SystemAlertProbeResponse(present: true, title: "Allow?", buttons: ["Allow", "Don't Allow"])
    private let pngPrimary = Data([1])
    private let pngWhole = Data([2])

    private func makeExecutor(omits: Bool = true, alertFrames: [SystemAlertProbeResponse]? = nil)
        -> (StepExecutor, FakeAppDriver, FakeAppDriver) {
        let log = CallLog()
        let primary = FakeAppDriver(name: "inapp", log: log, screenshots: [pngPrimary])
        let whole = FakeAppDriver(name: "xcuitest", log: log, screenshots: [pngWhole])
        whole.systemAlertFrames = alertFrames ?? [SystemAlertProbeResponse(present: false)]
        let executor = StepExecutor(driver: primary, fallbackDriver: whole, primaryCaptureOmitsSystemUI: omits,
                                    isAndroid: false, tunables: RunTunables())
        return (executor, primary, whole)
    }

    func testNoCoverUsesThePrimaryAndAsksOncePerPhase() async throws {
        let (executor, _, whole) = makeExecutor()
        var phase = StepExecutor.PhaseAccumulator()
        let first = try await executor.judgmentScreenshot(keyboardShown: false, phase: &phase)
        let second = try await executor.judgmentScreenshot(keyboardShown: false, phase: &phase)
        XCTAssertEqual([first, second], [pngPrimary, pngPrimary])
        XCTAssertEqual(whole.systemAlertCallCount, 1, "同じフェーズでは聞き直さない")
        executor.armUnregisteredSystemAlertProbe()
        _ = try await executor.judgmentScreenshot(keyboardShown: false, phase: &phase)
        XCTAssertEqual(whole.systemAlertCallCount, 2, "フェーズの先頭で聞き直す")
    }

    func testKeyboardShownUsesTheWholeScreenWithoutAsking() async throws {
        let (executor, _, whole) = makeExecutor()
        var phase = StepExecutor.PhaseAccumulator()
        let shot = try await executor.judgmentScreenshot(keyboardShown: true, phase: &phase)
        XCTAssertEqual(shot, pngWhole)
        XCTAssertEqual(whole.systemAlertCallCount, 0)
    }

    func testAlertInFrontUsesTheWholeScreenAndNotesIt() async throws {
        let (executor, primary, _) = makeExecutor(alertFrames: [alert])
        var phase = StepExecutor.PhaseAccumulator()
        let shot = try await executor.judgmentScreenshot(keyboardShown: false, phase: &phase)
        XCTAssertEqual(shot, pngWhole)
        XCTAssertEqual(primary.screenshotCallCount, 0)
        XCTAssertTrue(executor.noteCodesThisStep.contains(.systemAlertPresent))
    }

    func testWithoutTheFlagNothingChanges() async throws {
        let (executor, _, whole) = makeExecutor(omits: false, alertFrames: [alert])
        var phase = StepExecutor.PhaseAccumulator()
        let shot = try await executor.judgmentScreenshot(keyboardShown: true, alwaysWholeScreen: true, phase: &phase)
        XCTAssertEqual(shot, pngPrimary)
        XCTAssertEqual(whole.systemAlertCallCount, 0, "xcuitest 単独・MCP に往復を足さない")
    }

    /// 触る操作の照会(launch 直後・フェーズ先頭)の答えを、同じフェーズの画像判定が使う
    func testTheTouchProbeAnswerIsReused() async throws {
        let (executor, _, whole) = makeExecutor(alertFrames: [alert])
        var phase = StepExecutor.PhaseAccumulator()
        _ = await executor.unregisteredSystemAlert(phase: &phase)
        let shot = try await executor.judgmentScreenshot(keyboardShown: false, phase: &phase)
        XCTAssertEqual(shot, pngWhole)
        XCTAssertEqual(whole.systemAlertCallCount, 1)
    }

    /// 可視性検証の 200ms の使い回しは、撮り分けが変わったら効かない(in-app の絵をキーボード表示中に使い回さない)
    func testGuardCacheIsNotReusedAcrossSources() async throws {
        let (executor, _, _) = makeExecutor()
        var phase = StepExecutor.PhaseAccumulator()
        let first = try await executor.guardScreenshot(keyboardShown: false, phase: &phase)
        let second = try await executor.guardScreenshot(keyboardShown: true, phase: &phase)
        XCTAssertEqual(first.data, pngPrimary)
        XCTAssertEqual(second.data, pngWhole)
        XCTAssertTrue(second.freshlyCaptured)
        let third = try await executor.guardScreenshot(keyboardShown: true, phase: &phase)
        XCTAssertFalse(third.freshlyCaptured, "同じ撮り分けなら今までどおり使い回す")
    }

    private static var repoRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    }

    /// 主ドライバで絵を直に撮る(`driver.screenshot()` / `treeDriver.screenshot()`)ファイル。画像判定の絵は judgmentScreenshot /
    /// judgmentCapture だけで撮る。**新しい直撮りは、判定の絵でないと言える理由を付けてここへ足す**(判定の絵なら judgmentScreenshot へ)
    private static let directCaptureSites: [String: String] = [
        "FTCore/StepExecutor+JudgmentCapture.swift": "撮り分けの定義元(主ドライバへ落ちる側)",
        "FTCore/StepExecutor.swift": "recordPreLaunchFrame: Android の鮮度の基準の絵(キーボードを省く構成が無い)",
        "FTCore/BlankWorkerTriage.swift": "ワーカーの白紙判定(デバイスの状態の確認で、画像判定ではない)",
        "FTCore/StepExecutor+RenderCollapse.swift": "描画崩壊の判定。キーボードは木の枠でアプリの領域から除く(キーボードの絵は要らない)",
        "FTCore/StepExecutor+TypeClear.swift": "打った文字が欄に描かれたかの OCR。欄の矩形だけを読むのでキーボードの絵は要らない(写らずに欄が見えれば「描かれた」側 = 追送しない側へ倒れる)",
        "FTCore/StepExecutor+ClearResidual.swift": "消した後の残りの OCR。キーボードが欄に重なるときは先に断る(ClearResidualDrawn.unreadableReason)",
        "FTDSL/FTRuntime.swift": "失敗の証跡・動画用の絵(画面全体を先に撮り、撮れなければ主ドライバ)",
    ]

    func testJudgmentFilesDoNotCaptureWithThePrimaryDirectly() throws {
        let judgmentFiles = ["Sources/FTCore/StepExecutor+AssertState.swift", "Sources/FTCore/StepExecutor+FindImage.swift",
                             "Sources/FTCore/StepExecutor+LinkText.swift"]
        for path in judgmentFiles {
            let source = try String(contentsOf: Self.repoRoot.appendingPathComponent(path), encoding: .utf8)
            XCTAssertTrue(source.contains("judgment"), "\(path) の走査が撮影の口に届いていない")
        }
        let pattern = try NSRegularExpression(pattern: #"[dD]river\.screenshot\(\)"#)
        var found: Set<String> = []
        var scanned = 0
        for dir in ["FTCore", "FTDSL"] {
            let root = Self.repoRoot.appendingPathComponent("Sources/" + dir)
            let walker = try XCTUnwrap(FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil))
            for case let url as URL in walker where url.pathExtension == "swift" {
                scanned += 1
                let text = try String(contentsOf: url, encoding: .utf8)
                let code = text.replacingOccurrences(of: #"/\*[\s\S]*?\*/"#, with: "", options: .regularExpression)
                    .split(separator: "\n", omittingEmptySubsequences: false)
                    .map { line in line.range(of: "//").map { String(line[..<$0.lowerBound]) } ?? String(line) }
                    .joined(separator: "\n")
                if pattern.firstMatch(in: code, range: NSRange(code.startIndex..., in: code)) != nil {
                    found.insert(dir + "/" + url.lastPathComponent)
                }
            }
        }
        XCTAssertGreaterThan(scanned, 100, "走査が Sources/FTCore・FTDSL に届いていない")
        XCTAssertEqual(found, Set(Self.directCaptureSites.keys),
                       "主ドライバで絵を直に撮るファイルが表と違う。画像判定の絵なら judgmentScreenshot / judgmentCapture を通す。"
                       + "判定の絵でないなら directCaptureSites へ理由付きで足す")
    }

    /// 印を立てるのは inapp-boost モードの分岐(fallbackDriver = SystemUIDriver を組む所)だけで、FTDriveCore へ渡す
    func testScenarioRunnerSetsTheFlagOnlyForInappMode() throws {
        let source = try String(contentsOf: Self.repoRoot.appendingPathComponent(
            "Sources/FTScenarioRunner/ScenarioRunnerMain.swift"), encoding: .utf8)
        XCTAssertEqual(source.components(separatedBy: "primaryCaptureOmitsSystemUI = true").count - 1, 1)
        guard let inapp = source.range(of: "let inapp = InAppDriver("),
              let set = source.range(of: "primaryCaptureOmitsSystemUI = true") else {
            return XCTFail("inapp-boost モードの分岐か印が見つからない")
        }
        let between = source[inapp.upperBound..<set.lowerBound]
        XCTAssertTrue(between.contains("fallbackDriver = SystemUIDriver("), "印が inapp-boost モードの fallbackDriver と別の所にある")
        XCTAssertFalse(between.contains("} else"), "印が inapp-boost モードの分岐の外にある")
        XCTAssertTrue(source.contains("primaryCaptureOmitsSystemUI: primaryCaptureOmitsSystemUI,"), "FTDriveCore へ渡していない")
    }
}
