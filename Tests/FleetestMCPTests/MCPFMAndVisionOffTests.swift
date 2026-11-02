// MCP は既定で FM と Vision を使わない(ユーザー決定 2026-10-12)。ft_run_scenario の設定と ft_start_run の
// `--set` が同じ集合を切っていること・ft_doctor が既定で撃たないことを固定する

import XCTest
import FTCore
@testable import fleetest_mcp

final class MCPFMAndVisionOffTests: XCTestCase {

    func testRunSettingsTurnOffEveryFMAndVisionSwitch() {
        var on = ScenarioExecutionSettings()
        on.fm.enabled = true
        on.fm.fmTextVisibilityCheck = true
        on.fm.screenLooksLike = true
        on.occlusionOCR = true
        on.preferCheckStateClassifier = true
        let off = MCPServer.withoutFMAndVision(on)
        XCTAssertFalse(off.fm.enabled)
        XCTAssertFalse(off.fm.fmTextVisibilityCheck)
        XCTAssertFalse(off.fm.screenLooksLike)
        XCTAssertFalse(off.occlusionOCR)
        XCTAssertFalse(off.preferCheckStateClassifier)
        XCTAssertFalse(off.findImagePrewarm)
        XCTAssertEqual(off.heal, on.heal, "FM と Vision 以外は触らない")
    }

    /// `--set` のキーは実行プロファイルの欄と1文字も同じ(違うと run が「未知のキー」で断る)
    func testStartRunKeysAreRunProfileFields() {
        let fields = Set(Mirror(reflecting: RunProfileDocument()).children.compactMap(\.label))
        for key in MCPServer.fmAndVisionProfileKeys {
            XCTAssertTrue(fields.contains(key), "\(key) is not a run profile field")
        }
        XCTAssertEqual(MCPServer.fmAndVisionProfileKeys.count, 4)
    }

    func testDoctorDoesNotTouchFMOrVisionByDefault() async throws {
        let server = MCPServer(write: { _ in }, makeDriver: { _ in FakeDriver() }, recordSnapshot: { _, _, _ in })
        let text = try await server.call(tool: "ft_doctor", args: [:]).compactMap { $0["text"] as? String }.joined()
        XCTAssertTrue(text.contains("Not checked"), text)
        XCTAssertTrue(text.contains("fmAndVision: true"), text)
    }

    /// MCP が作る StepExecutor は OCR の段を切る(既定の `.on` だと type の描画確認 `TypedEchoOCRCheck` が Vision を動かす)。
    /// MCP の操作の道具は `fmAndVision` を持たないので常に `.off`
    func testEveryMCPStepExecutorTurnsTheOCRStageOff() throws {
        let dir = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Sources/fleetest-mcp")
        var constructions = 0
        for file in try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
        where file.pathExtension == "swift" {
            let lines = try String(contentsOf: file, encoding: .utf8).components(separatedBy: "\n")
            for (i, line) in lines.enumerated() where line.contains("StepExecutor(driver:")
                && !line.trimmingCharacters(in: .whitespaces).hasPrefix("//") {
                constructions += 1
                let call = lines[i...min(i + 2, lines.count - 1)].joined(separator: " ")
                XCTAssertTrue(call.contains("occlusionOCRMode: .off"), "\(file.lastPathComponent):\(i + 1)")
            }
        }
        XCTAssertEqual(constructions, 6, "StepExecutor を作る経路が増減した: 新しい経路も OCR の段を切ること")
    }
}
