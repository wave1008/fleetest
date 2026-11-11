// 断りの文に「今の ref」を載せる(アラートのボタンの ref・同じ素性の相手の ref とセレクタ)。

import XCTest
import FTCore
@testable import fleetest_mcp

final class RefusalRichnessTests: XCTestCase {
    private func el(_ ref: Int, _ type: String, _ label: String?, id: String? = nil,
                    x: Double = 0, y: Double = 0, w: Double = 100, h: Double = 40, depth: Int = 1) -> ElementInfo {
        ElementInfo(ref: ref, type: type, identifier: id, label: label, value: nil, placeholder: nil, enabled: true,
                    frame: FTRect(x: x, y: y, width: w, height: h), depth: depth)
    }

    private func tree(_ elements: [ElementInfo]) -> SnapshotResponse {
        SnapshotResponse(sessionBundleID: "app", screen: FTRect(x: 0, y: 0, width: 400, height: 800),
                         elements: elements, truncatedCount: 0)
    }

    /// アラートのボタンは ref つき("[12] \"OK\"")。ref を外すと落ちる
    func testAlertButtonsCarryTheirCurrentRefs() {
        let target = el(5, "button", "Go", id: "go", y: 100)
        let screen = tree([el(10, "alert", "Title", x: 10, y: 300, w: 360, h: 200),
                           el(12, "button", "OK", x: 20, y: 440, depth: 2)])
        let message = RefGuard.goneMessage(ref: 5, target: target,
                                           inAppAlert: MCPServer.frontInAppAlertWithButtons(screen))
        XCTAssertTrue(message.contains("[12] \"OK\""), message)
    }

    /// 同じ id が今の木に1つだけ → その ref とセレクタを名指し。撃ち直しは勧めない
    func testUniqueCounterpartIsNamedWithRefAndSelector() {
        let target = el(5, "button", "Save", id: "save")
        let screen = tree([el(40, "button", "Save", id: "save", y: 200)])
        let message = RefGuard.goneMessage(ref: 5, target: target, inAppAlert: nil,
                                           currentCounterpart: MCPServer.counterpartClause(for: target, in: screen))
        XCTAssertTrue(message.contains("[40]"), message)
        XCTAssertTrue(message.contains("selector:"), message)
        XCTAssertFalse(message.lowercased().contains("retry"), message)
    }

    /// 2件以上・0件なら名指ししない(当てずっぽうを渡さない)
    func testAmbiguousOrMissingCounterpartStaysSilent() {
        let target = el(5, "button", "Save", id: "save")
        let two = tree([el(40, "button", "Save", id: "save"), el(41, "button", "Save", id: "save", y: 100)])
        XCTAssertEqual(MCPServer.counterpartClause(for: target, in: two), "")
        XCTAssertEqual(MCPServer.counterpartClause(for: target, in: tree([])), "")
    }

    /// id が無ければ label+type で照合する
    func testLabelAndTypeIsTheFallbackIdentity() {
        let target = el(5, "button", "Save")
        let hit = tree([el(7, "button", "Save"), el(8, "staticText", "Save")])
        XCTAssertTrue(MCPServer.counterpartClause(for: target, in: hit).contains("[7]"))
    }

    /// 付け替えの断り(retargetOutcome)の本線も同じ節を足す: 3つの呼び手が通る口に配線されている
    func testRetargetRefusalsGoThroughTheCounterpartClause() throws {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Sources/fleetest-mcp/RefGuard.swift")
        let text = try String(contentsOf: url, encoding: .utf8)
        XCTAssertTrue(text.contains("refusal + currentCounterpartClause("))
    }
}
