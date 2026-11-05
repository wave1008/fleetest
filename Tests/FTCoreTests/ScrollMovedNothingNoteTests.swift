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

    /// 払いが一覧の端に掛かって数 px だけずれた(顔ぶれは同じ)= 動いていない側に数える
    func testNoteWhenRowsOnlyShiftedByAFewPixels() async {
        let before = [row(1, "row_05", y: 521), row(2, "row_06", y: 689)]
        let after = [row(1, "row_05", y: 518), row(2, "row_06", y: 686)]
        let driver = FakeAppDriver(name: "d", log: CallLog(),
                                   snapshotElements: [before, before, before, after, after, after, after, after])
        let outcome = await StepExecutor(driver: driver, isAndroid: true, tunables: RunTunables())
            .execute(FlowStep(action: "scroll", direction: "down"))
        XCTAssertTrue(outcome.notes.contains(.scrollMovedNothing), "\(outcome.notes)")
    }

    /// settle: false の最後の送りの後は撮らないので比べない(立てない)
    func testNoNoteWithoutTheSettleRead() async {
        let tree = [row(1, "row_01", y: 300)]
        let driver = FakeAppDriver(name: "d", log: CallLog(), snapshotElements: [tree])
        var step = FlowStep(action: "scroll", direction: "down")
        step.settle = false
        let outcome = await StepExecutor(driver: driver, isAndroid: true, tunables: RunTunables()).execute(step)
        XCTAssertFalse(outcome.notes.contains(.scrollMovedNothing), "\(outcome.notes)")
    }

    /// scrollFrame: を書いた送りに「scrollFrame: を渡せ」と言わない
    func testWrittenScrollFrameIsNotToldToPassOne() async {
        let list = ElementInfo(ref: 9, type: "other", identifier: "list", label: nil, value: nil, placeholder: nil, enabled: true,
                               frame: FTRect(x: 0, y: 200, width: 400, height: 600), depth: 1, scrollable: true)
        let tree = [list, row(1, "row_01", y: 300)]
        let driver = FakeAppDriver(name: "d", log: CallLog(), snapshotElements: [tree])
        var step = FlowStep(action: "scroll", direction: "down")
        step.scrollFrame = FlowLocator(id: "list")
        let outcome = await StepExecutor(driver: driver, isAndroid: true, tunables: RunTunables()).execute(step)
        XCTAssertTrue(outcome.notes.contains(.scrollMovedNothing), "\(outcome.notes)")
        XCTAssertFalse((outcome.driverFallback ?? "").contains("pass scrollFrame:"), outcome.driverFallback ?? "")
    }
}
