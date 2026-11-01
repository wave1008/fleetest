// ライブ操作の守りの配線(ソース走査)。経路の表:
//   drag(座標)        → CoordinateGuards.dragDoesNotMove で撃つ前に断る(MCP の ft_drag と同じ判定)
//   tap/type/clear ref → RefExpectationScope 経由(利用者が見ていた要素を期待として撃つ = 別プロセスが表を入れ替えていれば断る)
//   doubleTap/pinch ref → refuseIfNotWhatWasSeen(座標へ畳む前に照合)

import XCTest
@testable import fleetest

final class LiveRefAndDragGuardWiringTests: XCTestCase {
    private func performBody() throws -> String {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let text = try String(contentsOf: root.appendingPathComponent("Sources/fleetest/ApiLiveCommand.swift"), encoding: .utf8)
        let start = try XCTUnwrap(text.range(of: "private func perform(command: ApiLiveServeCommand"))
        return text.components(separatedBy: "\n")
            .map { $0.components(separatedBy: "//")[0] }
            .joined(separator: "\n")
            .components(separatedBy: "private func perform(command: ApiLiveServeCommand").last
            ?? String(text[start.lowerBound...])
    }

    func testDragRefusesAZeroMove() throws {
        XCTAssertTrue(try performBody().contains("CoordinateGuards.dragDoesNotMove("))
    }

    func testRefOperationsCheckWhatTheUserSaw() throws {
        let body = try performBody()
        XCTAssertEqual(body.components(separatedBy: "Self.firing(await Self.seen(").count - 1, 3, "tap / type / clear")
        XCTAssertEqual(body.components(separatedBy: "Self.refuseIfNotWhatWasSeen(").count - 1, 2, "doubleTap / pinch")
    }
}
