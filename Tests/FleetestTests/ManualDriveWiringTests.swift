// CLI の手動操作で撃つ手の配線。座標で撃つ手(tap / press)は全部 CoordinateFireGate を撃つ前に通す
// (画面の外 = 断る / キーボードの中 = ⚠️)。ref では撃たない(ref はその時点の木だけに通じる番号で、呼び出しごとに
// 独立した CLI では人が見た番号と撃つ時の番号が食い違う。ref で撃つのは MCP とライブ操作だけ)。
// 止めた直後に待受が残る bridge down の事実の文も固める

import ArgumentParser
import XCTest
@testable import fleetest

final class ManualDriveWiringTests: XCTestCase {
    private func source() throws -> [String] {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let text = try String(contentsOf: root.appendingPathComponent("Sources/fleetest/ManualDriveCommands.swift"), encoding: .utf8)
        return text.components(separatedBy: "\n")
            .map { $0.components(separatedBy: "//")[0].trimmingCharacters(in: .whitespaces) }
    }

    /// 届いたか分からない操作の4コマンド(tap / type / swipe / press)は全部 `DeliveryAdvice.relaying` を通す
    /// (CLI の時間切れが「ブリッジを確かめよ」とだけ言っていた)
    func testEveryDrivingCommandRelaysTheDeliveryAdvice() throws {
        let text = try source().joined(separator: "\n")
        XCTAssertEqual(text.components(separatedBy: "DeliveryAdvice.relaying {").count - 1, 4)
    }

    func testEveryCoordinateFiringCommandPassesTheGateBeforeFiring() throws {
        let lines = try source()
        let fires = ["try await driver.tap(x: x, y: y)", "try await driver.press(x: x, y: y"]
        for fire in fires {
            let fireIndex = try XCTUnwrap(lines.firstIndex { $0.contains(fire) }, "\(fire) が無い(走査の前提が崩れた)")
            let gateIndex = try XCTUnwrap(lines[..<fireIndex].lastIndex { $0.contains("CoordinateFireGate.check(") },
                                          "\(fire) の前に CoordinateFireGate.check が無い")
            XCTAssertLessThan(fireIndex - gateIndex, 3, "\(fire): ゲートが撃つ手から離れている")
        }
        XCTAssertEqual(lines.filter { $0.contains("CoordinateFireGate.check(") && !$0.contains("static func") }.count, fires.count)
        let coordinateCalls = lines.filter { $0.range(of: #"driver\.(tap|press|doubleTap|drag)\(x:"#, options: .regularExpression) != nil }
        XCTAssertEqual(coordinateCalls.count, fires.count, "座標で撃つ手が増えたら守りを通してここも増やす")
    }

    /// CLI は ref で撃たない(撃つ手にも、引数にも ref が無い)
    func testNoCommandFiresByRef() throws {
        let lines = try source()
        XCTAssertEqual(lines.filter { $0.range(of: #"driver\.(tap|press|type|doubleTap|longPress)\(ref: [^n]"#, options: .regularExpression) != nil }, [])
        for command in [Tap.self as ParsableCommand.Type, Press.self, TypeCommand.self] {
            XCTAssertFalse(command.helpMessage().contains("--ref"), "\(command) のヘルプに --ref がある")
        }
    }

    func testBridgeDownDoesNotClaimStoppedWhileTheRunnerStillListens() {
        XCTAssertNil(BridgeDownRefusal.survivorMessage(port: 8135, holder: nil))
        let message = BridgeDownRefusal.survivorMessage(port: 8135, holder: "pid 17680: FleetestRunner-Runner")
        XCTAssertTrue(message?.contains("still being listened on (pid 17680") == true, message ?? "nil")
        XCTAssertFalse(message?.contains("Stopped") == true)
    }
}
