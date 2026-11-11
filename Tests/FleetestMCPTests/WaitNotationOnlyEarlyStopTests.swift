// 表記違いだけの外れ(`*円*` を待つ画面が `¥715`)は待たずに返す。判定の純粋関数・ループの配線・見出し・畳まれた群の注意書き。

import XCTest
import FTCore
@testable import fleetest_mcp

private func notationElement(_ ref: Int, _ label: String) -> ElementInfo {
    ElementInfo(ref: ref, type: "staticText", identifier: nil, label: label, value: nil, placeholder: nil,
                enabled: true, frame: FTRect(x: 10, y: Double(20 * ref), width: 100, height: 20), depth: 1)
}

private func notationScreen(_ labels: [String]) -> SnapshotResponse {
    SnapshotResponse(sessionBundleID: "com.example.app", screen: FTRect(x: 0, y: 0, width: 390, height: 844),
                     elements: labels.enumerated().map { notationElement($0.offset + 1, $0.element) }, truncatedCount: 0)
}

final class WaitNotationOnlyEarlyStopTests: XCTestCase {
    func testYenSignOnScreenForAnEnSelectorIsANotationOnlyNearMiss() {
        XCTAssertTrue(MCPServer.isNotationOnlyNearMiss("*\u{5186}*", in: notationScreen(["¥715 IC"])))
    }

    /// 本物の部分一致(別の助言が出る形)があれば false = 待ち続ける
    func testARealPartialMatchIsNotANotationOnlyNearMiss() {
        let screen = notationScreen(["¥715", "総武線直通武蔵野線"])
        XCTAssertFalse(MCPServer.isNotationOnlyNearMiss("武蔵野線", in: screen))
        XCTAssertFalse(MCPServer.isNotationOnlyNearMiss("*武蔵野線", in: screen))
    }

    func testNoNearMissIsNotNotationOnly() {
        XCTAssertFalse(MCPServer.isNotationOnlyNearMiss("*\u{5186}*", in: notationScreen(["経路"])))
        XCTAssertFalse(MCPServer.isNotationOnlyNearMiss("*\u{5186}*", in: notationScreen([])))
    }

    /// ループは1回も撃ち直さず・上限も静止の切り上げも待たずに返る(first の木で判定)
    func testWaitForReturnsAtOnceOnANotationOnlyMiss() async throws {
        let start = Date()
        let result = try await MCPServer.waitFor("*\u{5186}*", driver: FakeDriver(),
                                                  first: notationScreen(["¥715"]), seconds: 30)
        XCTAssertFalse(result.found)
        XCTAssertEqual(result.quietStopAfter, 0)
        XCTAssertFalse(result.refetched)
        XCTAssertLessThan(Date().timeIntervalSince(start), 2)
    }

    /// 撃ち直しで表記違いだけの木になったときも、その周回で返る
    func testWaitForStopsOnTheFirstPollThatShowsOnlyTheOtherNotation() async throws {
        let driver = FakeDriver()
        driver.scriptedSnapshots = [notationScreen(["¥715"])]
        let start = Date()
        let result = try await MCPServer.waitFor("*\u{5186}*", driver: driver,
                                                  first: notationScreen([]), seconds: 30)
        XCTAssertFalse(result.found)
        XCTAssertNotNil(result.quietStopAfter)
        XCTAssertTrue(result.refetched)
        XCTAssertLessThan(Date().timeIntervalSince(start), 2)
    }

    /// 実際に出た(別の表記でなく同じ表記)なら従来どおり found
    func testAMatchStillWins() async throws {
        let result = try await MCPServer.waitFor("*\u{5186}*", driver: FakeDriver(),
                                                  first: notationScreen(["715円"]), seconds: 5)
        XCTAssertTrue(result.found)
    }

    func testHeadlineNamesTheNotationStopNotTheQuietCutoff() {
        let notation = MCPServer.waitMissHeadline("*\u{5186}*", seconds: 5, quietStopAfter: 0, canWaitForChange: true,
                                                  notationStop: true)
        XCTAssertTrue(notation.contains("different notation"), notation)
        XCTAssertFalse(notation.contains("had not changed"), notation)
        let quiet = MCPServer.waitMissHeadline("x", seconds: 5, quietStopAfter: 3, canWaitForChange: true)
        XCTAssertTrue(quiet.contains("had not changed"), quiet)
    }

    /// 畳まれた群の中の一致は、待った中身でない可能性を言う
    func testFoldedGroupMatchIsCautionary() {
        let pins = (0..<25).map { i in
            ElementInfo(ref: 100 + i, type: "other", identifier: "VKPointFeature", label: i == 7 ? "高円寺駅" : "店 \(i)",
                        value: nil, placeholder: nil, enabled: true,
                        frame: FTRect(x: 10, y: Double(20 * i), width: 100, height: 20), depth: 1)
        }
        let note = MCPServer.waitForAppearedNote("*\u{5186}*", in: SnapshotResponse(
            sessionBundleID: "a", screen: FTRect(x: 0, y: 0, width: 390, height: 844), elements: pins, truncatedCount: 0),
            collapsingBulk: true)
        XCTAssertTrue(note.contains("may not be the content you waited for"), note)
    }
}
