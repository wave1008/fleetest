// ライブ操作の drag(座標)は CoordinateGuards.dragDoesNotMove で撃つ前に断る(MCP の ft_drag と同じ判定。ソース走査)

import XCTest
@testable import fleetest

final class LiveDragGuardWiringTests: XCTestCase {
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
}
