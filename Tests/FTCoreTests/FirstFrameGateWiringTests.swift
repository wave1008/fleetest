// launch 直後の launch storyboard(一様色)を occlusion-guard の誤った赤にしない一度きりの門
// (StepExecutor.firstFrameGatePending)の配線ゲート。判定そのものは
// StepExecutorTests の testFirstFrameGate* が見るが、「arm する呼び出しが launch 系サイトから
// 消えている」変異はコンパイラでは止まらないので、ソースを読んで固定する
// (OverlayWindowOcclusionWiringTests と同型)。

import XCTest

final class FirstFrameGateWiringTests: XCTestCase {

    private static let repoRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()   // Tests/FTCoreTests
        .deletingLastPathComponent()   // Tests
        .deletingLastPathComponent()   // リポジトリ直下

    private func source(_ relativePath: String) throws -> String {
        try String(contentsOf: Self.repoRoot.appendingPathComponent("Sources/" + relativePath),
                    encoding: .utf8)
    }

    private func compact(_ text: String) -> String {
        text.components(separatedBy: .whitespacesAndNewlines).joined()
    }

    /// noteAppLaunched() 自身が門を arm すること。**armUnregisteredSystemAlertProbe() 単体では
    /// arm しない**(CAE の各フェーズ先頭で毎回呼ばれるので、そちらに乗せると launch 系以外の
    /// フェーズ境界でも猶予が発生してしまう)
    func testNoteAppLaunchedArmsTheGate() throws {
        let text = compact(try source("FTCore/StepExecutor.swift"))
        // 本文の一字一句ではなく「その関数の本文に arm の文があるか」で見る(本文に別の後始末が足されても落ちない)
        let launched = try XCTUnwrap(body(of: "funcnoteAppLaunched(", in: text), "noteAppLaunched が見つからない")
        XCTAssertTrue(launched.contains("firstFrameGatePending=true"),
                      "noteAppLaunched() が firstFrameGatePending を arm していない")
        let probe = try XCTUnwrap(body(of: "funcarmUnregisteredSystemAlertProbe(", in: text),
                                  "armUnregisteredSystemAlertProbe が見つからない")
        XCTAssertFalse(probe.contains("firstFrameGatePending=true"),
                       "armUnregisteredSystemAlertProbe() 単体で arm すると、CAE の毎フェーズで門が開いてしまう")
    }

    /// 空白を詰めた本文から、`signature` で始まる関数の最初の `{` から対応する `}` までを返す
    private func body(of signature: String, in text: String) -> String? {
        guard let start = text.range(of: signature),
              let open = text[start.upperBound...].firstIndex(of: "{") else { return nil }
        var depth = 0
        var index = open
        while index < text.endIndex {
            if text[index] == "{" { depth += 1 }
            if text[index] == "}" {
                depth -= 1
                if depth == 0 { return String(text[open...index]) }
            }
            index = text.index(after: index)
        }
        return nil
    }

    /// launch 系コマンド("launchApp"/"restartApp"/"clearAppData"/"installApp")の直後で
    /// noteAppLaunched() を呼ぶ箇所が FTRuntime に実在すること(systemAlertProbePending と
    /// 同じ launch サイト。片方だけ変えると門が二度と開かなくなる)
    func testFTRuntimeCallsNoteAppLaunchedAtLaunchSites() throws {
        let text = compact(try source("FTDSL/FTRuntime.swift"))
        XCTAssertTrue(text.contains(compact(
            "[\"launchApp\", \"restartApp\", \"clearAppData\", \"installApp\"].contains(command)")),
            "launch 系コマンドの一覧が変わっている(systemAlertProbePending と同じ一覧のはず)")
        XCTAssertTrue(text.contains(compact("""
            if let command, ["launchApp", "restartApp", "clearAppData", "installApp"].contains(command) {
                executor.noteAppLaunched(bundleID: launchedBundleID)
            }
            """)),
            "launch 系コマンドの直後で executor.noteAppLaunched() を呼んでいない")
    }
}
