// 素の scrollUp / scrollDown が画面を1つも動かさなかったら、✅ のまま注記 scroll-moved-nothing を立てる(原因は名指さない)

import XCTest
@testable import FTCore

final class ScrollMovedNothingNoteTests: XCTestCase {
    private func row(_ ref: Int, _ id: String, y: Double) -> ElementInfo {
        ElementInfo(ref: ref, type: "staticText", identifier: id, label: id, value: nil, placeholder: nil, enabled: true,
                    frame: FTRect(x: 0, y: y, width: 400, height: 60), depth: 2)
    }

    func testNoteWhenNothingMoved() async {
        let tree = [row(1, "row_01", y: 300), row(2, "row_02", y: 360)]
        let driver = FakeAppDriver(name: "d", log: CallLog(), snapshotElements: [tree])
        let outcome = await StepExecutor(driver: driver, isAndroid: true, tunables: RunTunables())
            .execute(FlowStep(action: "scroll", direction: "down"))
        XCTAssertTrue(StepExecutor.isSuccess(outcome.status), "\(outcome.status)")
        XCTAssertTrue(outcome.notes.contains(.scrollMovedNothing), "\(outcome.notes)")
    }

    func testNoNoteWhenTheListMoved() async {
        let before = [row(1, "row_01", y: 300), row(2, "row_02", y: 360)]
        let after = [row(1, "row_05", y: 300), row(2, "row_06", y: 360)]
        let driver = FakeAppDriver(name: "d", log: CallLog(),
                                   snapshotElements: [before, before, before, after, after, after, after, after])
        let outcome = await StepExecutor(driver: driver, isAndroid: true, tunables: RunTunables())
            .execute(FlowStep(action: "scroll", direction: "down"))
        XCTAssertFalse(outcome.notes.contains(.scrollMovedNothing), "\(outcome.notes)")
    }
}
