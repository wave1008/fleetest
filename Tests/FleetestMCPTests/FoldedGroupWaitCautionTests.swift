// waitFor が畳まれた群(地図のピン等)の中で当たったときは、待った中身でない可能性を言う
// (`*円*` が地名「高円寺」のピンに当たり、運賃が出たと読まれた)。照合そのものは DSL と同じまま(外さない = ユーザー決定)

import XCTest
import FTCore
@testable import fleetest_mcp

final class FoldedGroupWaitCautionTests: XCTestCase {
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
