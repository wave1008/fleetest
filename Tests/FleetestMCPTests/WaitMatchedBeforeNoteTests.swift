// waitFor が操作の前から同じ文字で在った要素に一致したら、待たずに返ったことを言う(実測: ft_batch の waitFor が開く前の
// `overlay=none` に即一致し、AI がその値を期待値に書いて本番で赤)。新しく現れた一致では言わない

import XCTest
import FTCore
@testable import fleetest_mcp

final class WaitMatchedBeforeNoteTests: XCTestCase {

    private func el(_ ref: Int, _ label: String, y: Double) -> ElementInfo {
        ElementInfo(ref: ref, type: "staticText", identifier: nil, label: label, value: nil, placeholder: nil, enabled: true,
                    frame: FTRect(x: 16, y: y, width: 200, height: 40), depth: 1)
    }

    private func snap(_ elements: [ElementInfo]) -> SnapshotResponse {
        SnapshotResponse(sessionBundleID: "com.example", screen: FTRect(x: 0, y: 0, width: 400, height: 800),
                         elements: elements, truncatedCount: 0)
    }

    func testNoteWhenTheMatchWasAlreadyThereBeforeTheAction() {
        let before = snap([el(1, "overlay=none", y: 100)])
        let now = snap([el(1, "overlay=none", y: 100), el(2, "開く", y: 200)])
        let note = MCPServer.waitMatchedBeforeNote("overlay=none", before: before, now: now, canWaitForChange: false)
        XCTAssertTrue(note.contains("already matched"), note)
        XCTAssertFalse(note.contains("waitForChange"), "ft_batch には無い引数を勧めない: \(note)")
        XCTAssertTrue(MCPServer.waitMatchedBeforeNote("overlay=none", before: before, now: now, canWaitForChange: true)
            .contains("waitForChange: true"))
    }

    func testNoNoteForANewMatchOrWithoutTheTreeBefore() {
        let before = snap([el(1, "overlay=none", y: 100)])
        let now = snap([el(1, "overlay=open", y: 100)])
        XCTAssertEqual(MCPServer.waitMatchedBeforeNote("overlay=open", before: before, now: now, canWaitForChange: true), "")
        XCTAssertEqual(MCPServer.waitMatchedBeforeNote("overlay=open", before: nil, now: now, canWaitForChange: true), "")
    }

    /// 配線: ft_tap の snapshotAfter + waitFor の応答に出る
    func testTapWithWaitForSaysSo() async throws {
        let driver = FakeDriver()
        let screen = snap([el(1, "overlay=none", y: 100), el(2, "開く", y: 200)])
        driver.snapshotResponse = screen
        let server = MCPServer(write: { _ in }, makeDriver: { _ in driver }, recordSnapshot: { _, _, _ in })
        _ = try await server.call(tool: "ft_snapshot", args: [:])
        let content = try await server.call(tool: "ft_tap", args: ["selector": "開く", "snapshotAfter": true,
                                                                    "waitFor": "overlay=none"])
        let text = content.compactMap { $0["text"] as? String }.joined(separator: "\n")
        XCTAssertTrue(text.contains("already matched"), text)
    }

    /// 配線: ft_batch の waitFor(実害が出た経路)。waitForChange を持たないので、新しい値を待つよう言う
    func testBatchWithWaitForSaysSo() async throws {
        let driver = FakeDriver()
        driver.snapshotResponse = snap([el(1, "overlay=none", y: 100), el(2, "開く", y: 200)])
        let server = MCPServer(write: { _ in }, makeDriver: { _ in driver }, recordSnapshot: { _, _, _ in })
        _ = try await server.call(tool: "ft_snapshot", args: [:])
        let content = try await server.call(tool: "ft_batch", args: ["steps": "tap '開く'", "waitFor": "overlay=none"])
        let text = content.compactMap { $0["text"] as? String }.joined(separator: "\n")
        XCTAssertTrue(text.contains("already matched"), text)
        XCTAssertFalse(text.contains("pass waitForChange"), text)
    }
}
