// 覆いを外す送りの後に対象を見失ったとき、送った後の木がロック画面・常時表示なら「覆われた」と言わず、
// 画面が落ちた事実を言う。アプリの木なら従来の文のまま。

import XCTest
@testable import FTCore

final class CoverLiftLostMessageLockScreenTests: XCTestCase {
    private let step = FlowStep(action: "tap", locator: FlowLocator(id: "btn"))

    private func tree(session: String, ids: [String]) -> SnapshotResponse {
        let elements = ids.enumerated().map { index, id in
            ElementInfo(ref: index + 1, type: "view", identifier: id, label: nil, value: nil, placeholder: nil,
                        enabled: true, frame: FTRect(x: 0, y: 0, width: 100, height: 100), depth: 0)
        }
        return SnapshotResponse(sessionBundleID: session, screen: FTRect(x: 0, y: 0, width: 400, height: 800),
                                elements: elements, truncatedCount: 0)
    }

    func testLockScreenTreeIsNamedInsteadOfCovered() {
        let message = StepExecutor.coverLiftLostMessage(
            step, verb: "touching",
            after: tree(session: "com.android.systemui", ids: ["keyguard_status_view", "ambient_indication_container"]))
        XCTAssertFalse(message.contains("was covered"), message)
        XCTAssertTrue(message.contains("always-on display"), message)
        XCTAssertTrue(message.contains(step.locatorSummary), message)
    }

    func testAppTreeKeepsTheCoveredWording() {
        let message = StepExecutor.coverLiftLostMessage(
            step, verb: "touching", after: tree(session: "com.example.app", ids: ["other"]))
        XCTAssertTrue(message.hasPrefix("the target was covered"), message)
        XCTAssertEqual(message, StepExecutor.coverLiftLostMessage(step, verb: "touching"))
    }

    /// 通知シェードの木はロック画面ではない(覆いの経路の文のまま)
    func testNotificationShadeIsNotTheLockScreen() {
        let message = StepExecutor.coverLiftLostMessage(
            step, verb: "touching", after: tree(session: "com.android.systemui", ids: ["notification_panel"]))
        XCTAssertTrue(message.hasPrefix("the target was covered"), message)
    }
}
