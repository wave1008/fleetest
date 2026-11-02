// CLI とライブ操作が「座標を撃つ手」を撃つ前に通す守りの経路表(操作 × 経路 × 守り)。
// 撃つ手を足すと、この表の件数が合わず落ちる(表へ足すか、守りを通す)。
//   CLI   tap / press の座標                    → CoordinateFireGate.check。表は ManualDriveWiringTests
//   live  tap/doubleTap/drag/press の座標      → requireOnScreen(drag は CoordinateGuards.dragDoesNotMove も)

import XCTest

final class FireEntryPathTableTests: XCTestCase {
    private func code(_ path: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return try String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)
            .components(separatedBy: "\n").filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }.joined(separator: "\n")
    }

    private func caseBody(_ name: String, in source: String) throws -> String {
        let start = try XCTUnwrap(source.range(of: "        case \"\(name)\":"), "case \"\(name)\"")
        let rest = source[start.upperBound...]
        return String(rest[..<(rest.range(of: "\n        case \"")?.lowerBound ?? rest.endIndex)])
    }

    func testLiveCoordinateFiringCasesPassRequireOnScreen() throws {
        let live = try code("Sources/fleetest/ApiLiveCommand.swift")
        for name in ["tap", "doubleTap", "drag", "press"] {
            XCTAssertTrue(try caseBody(name, in: live).contains("requireOnScreen("), "live \(name) の座標形")
        }
        XCTAssertTrue(try caseBody("drag", in: live).contains("CoordinateGuards.dragDoesNotMove("))
        // 座標で撃つドライバ呼び出しの総数(増えたら守りの有無を決めて表へ)
        let fires = live.components(separatedBy: "\n").filter {
            $0.range(of: #"driver\.(tap|doubleTap|press)\(x:|driver\.drag\(from"#, options: .regularExpression) != nil
        }
        XCTAssertEqual(fires.count, 4, fires.joined(separator: "\n"))
    }

    func testMCPDragUsesTheSharedNoMoveJudgement() throws {
        XCTAssertTrue(try code("Sources/fleetest-mcp/MCPServer+GesturesTools.swift").contains("CoordinateGuards.dragDoesNotMove("))
    }
}
