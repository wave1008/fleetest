// ライブ操作の守りの配線(ソース走査)。経路の表:
//   drag(座標)        → CoordinateGuards.dragDoesNotMove で撃つ前に断る(MCP の ft_drag と同じ判定)
//   tap/type/clear ref → RefExpectationScope 経由(利用者が見ていた要素を期待として撃つ = 別プロセスが表を入れ替えていれば断る)
//   doubleTap/pinch ref・Android の帯へ寄せる tap ref → refuseIfNotWhatWasSeen(座標へ畳む前に照合)

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

    /// Android の ref の tap を下端の帯より上の座標へ畳む経路も、見ていた要素と照合してから座標を返す
    /// (`firing(seen)` を通らない枝。撮り直した木の ref の番号ずれで別の要素を押さない)
    func testBottomBandTapChecksWhatTheUserSawBeforeFoldingToCoordinates() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let text = try String(contentsOf: root.appendingPathComponent("Sources/fleetest/ApiLiveCommand.swift"), encoding: .utf8)
            .components(separatedBy: "\n").map { $0.components(separatedBy: "//")[0] }.joined(separator: "\n")
        let start = try XCTUnwrap(text.range(of: "private static func bottomBandPoint(ref: Int, seen: ElementInfo?"))
        let body = text[start.upperBound...].prefix(600)
        let fold = try XCTUnwrap(body.range(of: "return (element.frame.centerX, y)"))
        XCTAssertNotNil(body[..<fold.lowerBound].range(of: "try refuseIfNotWhatWasSeen(element, seen: seen)"), String(body))
        XCTAssertTrue(try performBody().contains("Self.bottomBandPoint(ref: ref, seen: await Self.seen(ref, screenMemo)"))
    }
}
