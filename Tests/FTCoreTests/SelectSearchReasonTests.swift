// 探索付きの select が見つけられなかったとき、skip の理由に探索の理由(端・動かない等)を添える。
// 後続の検証の赤は「見つからない」としか言えないので、書き手が次の手を選べるのはこの行だけ

import XCTest
@testable import FTCore

final class SelectSearchReasonTests: XCTestCase {
    func testSkipCarriesTheScrollSearchReason() async {
        let list = ElementInfo(ref: 1, type: "scrollView", identifier: "list", label: nil, value: nil, placeholder: nil,
                               enabled: true, frame: FTRect(x: 0, y: 100, width: 400, height: 600), depth: 1, scrollable: true)
        let row = ElementInfo(ref: 2, type: "cell", identifier: "row_01", label: "行 01", value: nil, placeholder: nil,
                              enabled: true, frame: FTRect(x: 0, y: 110, width: 400, height: 60), depth: 2)
        let driver = FakeAppDriver(name: "d", log: CallLog(), snapshotElements: [[list, row]])
        let outcome = await StepExecutor(driver: driver, isAndroid: false, tunables: RunTunables())
            .execute(FlowStep(action: "select", locator: FlowLocator(id: "row_99"), direction: "up", maxSwipes: 2))
        guard case .skipped(let reason) = outcome.status else { return XCTFail("\(outcome.status)") }
        XCTAssertTrue(reason.hasPrefix("select returned an empty element: element not found after"), reason)
        XCTAssertTrue(reason.contains("nothing moved at all"), "探索の理由そのものを添える: \(reason)")
    }
}
