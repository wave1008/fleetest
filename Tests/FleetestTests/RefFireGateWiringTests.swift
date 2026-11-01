// CLI の ref を撃つ手(tap / press / type)は全部 RefFireGate(= FTCore.RefFireCheck)を撃つ前に通す。
// 経路の表: 操作 × 経路 × 守り(キーボードの下・せり上がったバーの覆い = 断る / 別の物に当たりうる形 = ⚠️)。
//   tap --ref   → RefFireGate.check → driver.tap(ref:)
//   press --ref → RefFireGate.check → driver.press(ref:)
//   type --ref  → RefFireGate.check(allowFocused) → driver.type(ref:)
// 止めた直後に待受が残る bridge down の事実の文も固める

import XCTest
@testable import fleetest

final class RefFireGateWiringTests: XCTestCase {
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

    func testBridgeDownDoesNotClaimStoppedWhileTheRunnerStillListens() {
        XCTAssertNil(BridgeDownRefusal.survivorMessage(port: 8135, holder: nil))
        let message = BridgeDownRefusal.survivorMessage(port: 8135, holder: "pid 17680: FleetestRunner-Runner")
        XCTAssertTrue(message?.contains("still being listened on (pid 17680") == true, message ?? "nil")
        XCTAssertFalse(message?.contains("Stopped") == true)
    }
}
