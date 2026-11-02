// CLI の ref を撃つ手(tap / press / type)は全部 RefFireGate(= FTCore.RefFireCheck)を撃つ前に通す。
// 経路の表: 操作 × 経路 × 守り(キーボードの下・せり上がったバーの覆い = 断る / 別の物に当たりうる形 = ⚠️)。
//   tap --ref   → RefFireGate.check → driver.tap(ref:)(Android の下端の帯の中なら check が返す帯より上の座標)
//   press --ref → RefFireGate.check → driver.press(ref:)(同上)
//   type --ref  → RefFireGate.check(allowFocused) → driver.type(ref:)
// 止めた直後に待受が残る bridge down の事実の文も固める

import XCTest
@testable import fleetest

final class RefFireGateWiringTests: XCTestCase {
    /// 届いたか分からない操作の4コマンド7経路は全部 `DeliveryAdvice.relaying` を通す(CLI の時間切れが「ブリッジを確かめよ」とだけ言っていた)
    func testEveryDrivingCommandRelaysTheDeliveryAdvice() throws {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Sources/fleetest/ManualDriveCommands.swift")
        let code = try String(contentsOf: url, encoding: .utf8)
        XCTAssertEqual(code.components(separatedBy: "DeliveryAdvice.relaying {").count - 1, 7)
    }

    /// **ref の tap と press は Android の下端のジェスチャ帯を避ける**(DSL・MCP・ライブ操作と同じ `BottomGestureBandTap`)。
    /// 帯の座標は照合を済ませた要素から check が求め、撃つ側はそれがあれば座標で撃つ
    func testRefTapAndPressClearTheBottomGestureBand() throws {
        let text = try source().joined(separator: "\n")
        XCTAssertTrue(text.contains("BottomGestureBandTap.tapY(for: element.frame, screen: snapshot.screen"))
        XCTAssertTrue(text.contains("checked.bandPoint = (element.frame.centerX, y)"), "判定の結果を撃つ側へ渡すこと")
        XCTAssertTrue(text.contains("if let point = gate.bandPoint {\ntry await DeliveryAdvice.relaying { try await driver.tap(x: point.x, y: point.y) }"))
        XCTAssertTrue(text.contains("if let point = gate.bandPoint {\ntry await DeliveryAdvice.relaying { try await driver.press(x: point.x, y: point.y, duration: holdSeconds) }"))
    }

    private func source() throws -> [String] {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let text = try String(contentsOf: root.appendingPathComponent("Sources/fleetest/ManualDriveCommands.swift"), encoding: .utf8)
        return text.components(separatedBy: "\n")
            .map { $0.components(separatedBy: "//")[0].trimmingCharacters(in: .whitespaces) }
    }

    func testEveryRefFiringCommandPassesTheGateBeforeFiring() throws {
        let lines = try source()
        let fires = ["try await driver.tap(ref: ref)", "try await driver.press(ref: ref", "try await driver.type(ref: ref"]
        for fire in fires {
            let fireIndex = try XCTUnwrap(lines.firstIndex { $0.contains(fire) }, "\(fire) が無い(走査の前提が崩れた)")
            let gateIndex = try XCTUnwrap(lines[..<fireIndex].lastIndex { $0.contains("RefFireGate.check(") },
                                          "\(fire) の前に RefFireGate.check が無い")
            XCTAssertLessThan(fireIndex - gateIndex, 8, "\(fire): ゲートが撃つ手から離れている")
        }
        XCTAssertEqual(lines.filter { $0.contains("RefFireGate.check(") && !$0.contains("static func") }.count, fires.count)
        // ref を撃つ手が増えたらここも増やす(ゲートを通さない ref の呼び出しが無い)
        let refCalls = lines.filter { $0.range(of: #"driver\.(tap|press|type|doubleTap|longPress)\(ref:"#, options: .regularExpression) != nil }
        XCTAssertEqual(refCalls.count, fires.count)
    }

    /// ref の古さの控え: 3つの手は全部 memoKey を渡し、snapshot は控えを書き、type だけが typing: true
    func testEveryGateCallCarriesTheMemoKeyAndSnapshotWritesTheMemo() throws {
        let text = try source().joined(separator: "\n")
        XCTAssertEqual(text.components(separatedBy: "memoKey: driverOptions.refMemoKey").count - 1, 3)
        XCTAssertEqual(text.components(separatedBy: "typing: true").count - 1, 1)
        XCTAssertTrue(text.contains("CLIRefMemo.store(key: driverOptions.refMemoKey"))
    }

    func testBridgeDownDoesNotClaimStoppedWhileTheRunnerStillListens() {
        XCTAssertNil(BridgeDownRefusal.survivorMessage(port: 8135, holder: nil))
        let message = BridgeDownRefusal.survivorMessage(port: 8135, holder: "pid 17680: FleetestRunner-Runner")
        XCTAssertTrue(message?.contains("still being listened on (pid 17680") == true, message ?? "nil")
        XCTAssertFalse(message?.contains("Stopped") == true)
    }
}
