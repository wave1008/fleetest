// CLI とライブ操作が「要素・座標を撃つ手」を撃つ前に通す守りの経路表(操作 × 経路 × 守り)。
// 撃つ手を足すと、この表の件数が合わず落ちる(表へ足すか、守りを通す)。
//   CLI   tap --ref / press --ref / type --ref → RefFireGate.check(= RefFireCheck)。表は RefFireGateWiringTests
//   CLI   tap --x --y                          → 画面の外の断り + CoordinateGuards.keyboardFrame
//   live  tap/type/clear/doubleTap/pinch の ref → requireFireable(= RefFireCheck)
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

    func testLiveRefFiringCasesPassRequireFireable() throws {
        let live = try code("Sources/fleetest/ApiLiveCommand.swift")
        let table: [(String, Bool)] = [("tap", false), ("type", true), ("clear", true), ("doubleTap", false), ("pinch", false)]
        for (name, typing) in table {
            let body = try caseBody(name, in: live)
            XCTAssertTrue(body.contains("requireFireable(ref: ref, typing: \(typing)"), "live \(name) の ref 形が入口を通らない")
        }
        XCTAssertEqual(live.components(separatedBy: "Self.requireFireable(").count - 1, table.count)
        XCTAssertTrue(live.contains("RefFireCheck.evaluate("))
    }

    func testLiveCoordinateFiringCasesPassRequireOnScreen() throws {
        let live = try code("Sources/fleetest/ApiLiveCommand.swift")
        for name in ["tap", "doubleTap", "drag", "press"] {
            XCTAssertTrue(try caseBody(name, in: live).contains("requireOnScreen("), "live \(name) の座標形")
        }
        XCTAssertTrue(try caseBody("drag", in: live).contains("CoordinateGuards.dragDoesNotMove("))
        // 座標で撃つドライバ呼び出しの総数(増えたら守りの有無を決めて表へ)。Android 帯の tap(x: point.x) は ref 形の一部
        let fires = live.components(separatedBy: "\n").filter {
            $0.range(of: #"driver\.(tap|doubleTap|press)\(x:|driver\.drag\(from"#, options: .regularExpression) != nil
        }
        XCTAssertEqual(fires.count, 6, fires.joined(separator: "\n"))
    }

    func testMCPDragUsesTheSharedNoMoveJudgement() throws {
        XCTAssertTrue(try code("Sources/fleetest-mcp/MCPServer+GesturesTools.swift").contains("CoordinateGuards.dragDoesNotMove("))
    }
}
