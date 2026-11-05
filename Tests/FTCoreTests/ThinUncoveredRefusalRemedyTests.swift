// 塗り順のある木で、覆いの外に残る部分が薄すぎて撃たずに断るとき、直し方(覆いを持つシートを閉じる・畳む / scroll: で外す)を言うこと。
// 何も撃たない(座標でも)

import XCTest
@testable import FTCore

final class ThinUncoveredRefusalRemedyTests: XCTestCase {
    func testRefusalSaysHowToUncoverTheTarget() async {
        var target = ElementInfo(ref: 3, type: "button", identifier: "row_main_10", label: "本文 10", value: nil, placeholder: nil,
                                 enabled: true, frame: FTRect(x: 0, y: 700, width: 402, height: 48), depth: 1)
        var list = ElementInfo(ref: 4, type: "other", identifier: nil, label: nil, value: nil, placeholder: nil,
                               enabled: true, frame: FTRect(x: 0, y: 568, width: 402, height: 306), depth: 1, scrollable: true)
        var queueRow = ElementInfo(ref: 5, type: "button", identifier: "queue_row_02", label: "キュー 02", value: nil, placeholder: nil,
                                   enabled: true, frame: FTRect(x: 0, y: 690, width: 402, height: 70), depth: 2)
        target.z = 10; list.z = 20; queueRow.z = 21
        let log = CallLog()
        let driver = FakeAppDriver(name: "d", log: log, snapshotElements: [[target, list, queueRow]])
        let outcome = await StepExecutor(driver: driver, isAndroid: false, tunables: RunTunables())
            .execute(FlowStep(action: "tap", locator: FlowLocator(id: "row_main_10"), timeout: 0))
        guard case .failed(let message) = outcome.status else { return XCTFail("\(outcome.status)") }
        XCTAssertTrue(message.contains("is left uncovered"), "この経路を通っていない: \(message)")
        XCTAssertTrue(message.contains("If #queue_row_02 is part of a sheet or panel, close or collapse it first;"
            + " otherwise add scroll:"), message)
        XCTAssertFalse(log.entries.contains { $0.contains(".tap(") }, "断ったのに撃った: \(log.entries)")
        XCTAssertTrue(driver.coordinateTaps.isEmpty, "断ったのに座標で撃った: \(driver.coordinateTaps)")
    }

    /// `scroll:` を書いた手には足せと言わない(探索が送っても出せなかった)。`scroll:` を受けないコマンドは先に送る手を言う
    func testRemedyFollowsWhatTheStepCanExpress() {
        let written = StepExecutor.uncoverRemedy(cover: "#bar", step: FlowStep(action: "tap", locator: FlowLocator(id: "x"), direction: "down"))
        XCTAssertTrue(written.contains("scroll the other way"), written)
        XCTAssertFalse(written.contains("add scroll:"), written)
        let noArgument = StepExecutor.uncoverRemedy(cover: "#bar", step: FlowStep(action: "doubleTap", locator: FlowLocator(id: "x")))
        XCTAssertTrue(noArgument.contains("this command has no scroll: argument"), noArgument)
    }
}
