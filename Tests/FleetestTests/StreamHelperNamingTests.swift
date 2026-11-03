import FTCore
import FTRemote
import XCTest

@testable import fleetest

/// 配信ヘルパーの名前を `api device-stream` が**リテラルで持たない**ことを固定する。
///
/// 持たせると、新しいヘルパーを足したときに `RemoteSetupPlan.alignRevisionCommand`(= リモート機で
/// ビルドするもの)へ追随しなくても全部緑のまま通り、**そのランナーのタイルだけが黙って「映像なし」**
/// になる(2026-08-28 の実害。既存3本が丸ごとこれだった)。`StreamHelpers` を通していれば
/// 追加はそこに現れ、align のリテラル等号テストが落ちる。
final class StreamHelperNamingTests: XCTestCase {

    func testDeviceStreamNamesHelpersOnlyThroughStreamHelpers() throws {
        let source = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/fleetest/ApiDeviceStreamCommand.swift")
        let text = try String(contentsOf: source, encoding: .utf8)
        let code = text.split(separator: "\n", omittingEmptySubsequences: false)
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
            .joined(separator: "\n")
        XCTAssertFalse(code.contains("\"fleetest-"),
                       "配信ヘルパーは StreamHelpers 経由で名指しする"
                       + "(リテラルで書くと alignRevisionCommand がビルドし忘れても誰も落ちない)")
    }

    /// 名前が実際の実行ファイル名と食い違えば、リモートでは exec が失敗し手元では
    /// resolveSimStream(config.ts)が外れる。3本とも `fleetest-` 接頭辞の実在プロダクト名
    func testHelperNamesAreTheBuiltProductNames() {
        XCTAssertEqual(StreamHelpers.all,
                       ["fleetest-simstream", "fleetest-androidstream", "fleetest-devicepoll"])
    }

    /// align がランナー機でビルドする製品は fleetest・配信ヘルパー・中継 `fleetest-services`・`fleetest-mcp` の全部で、
    /// 全部 `buildScript`(dispatch.lock の下)に載る。
    /// 中継が抜けると、ランナーで動く run-setup.sh から `fleetest-services: command not found` になる(M1Ultra の実測)。
    /// 狙い: `buildOrder` から1製品を外す変異・`swift build --product fleetest` を外す変異で落ちる
    func testAlignBuildsEveryProductTheRunnerNeeds() {
        let layout = RemoteLayout(base: "/Users/ci/fleetest-runner", issuer: "alice", home: "/Users/ci")
        let script = RemoteAlignPlan.buildScript(layout: layout, revision: "abc123", digest: "d1", developerDir: nil)
        XCTAssertTrue(script.contains("swift build --product fleetest && "), "fleetest is always built")
        let products = StreamHelpers.all + [ServiceGatewayWire.relayProductName, "fleetest-mcp"]
        for product in products {
            XCTAssertTrue(script.contains("ft_build '\(product)' '"), "\(product) must be built (or skipped when unchanged) by buildScript")
        }
        XCTAssertFalse(script.contains("nohup"), "no product is built in the background")
    }
}
