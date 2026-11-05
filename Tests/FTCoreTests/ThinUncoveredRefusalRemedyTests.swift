// 塗り順のある木で、覆いの外に残る部分が薄すぎて撃たずに断るとき、直し方(覆いを閉じる・畳む / 送って外す)を言うこと。
// 実測(E2EY-RN の iOS の半分のシートの裏の行): 断りの文が覆いと残りの量だけを言い、書き手が次に何をすればよいかを言わなかった

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
        XCTAssertTrue(message.contains("Close or collapse #queue_row_02 first, or scroll the target clear of it"), message)
        XCTAssertFalse(log.entries.contains { $0.contains(".tap(") }, "断ったのに撃った: \(log.entries)")
    }
}
