// 35周目 iultra F1・11/8 手元 4/16: 速く返った tap の直後の select が、遷移の途中の1枚の可視性検証で「見えない」と出て
// 固定領域のラベルを空の要素にした。「見えない」と出た回だけ木と絵を1回撮り直してから決める(締切までは待たない)

import XCTest
@testable import FTCore

final class SelectNotVisibleRetakeTests: XCTestCase {
    private func select(_ verdicts: [Bool]) async -> (StepOutcome, SequenceVisibilityDelegate) {
        let label = ElementInfo(ref: 1, type: "staticText", identifier: "txt_loading_state", label: "state=loading",
                                value: nil, placeholder: nil, enabled: true,
                                frame: FTRect(x: 16, y: 120, width: 200, height: 24), depth: 0)
        // 撮り直しごとに別の絵(同じ絵は VisibilityVerdictMemo が同じ判定を返す)
        let driver = FakeAppDriver(name: "primary", log: CallLog(), snapshotElements: [[label]],
                                   screenshots: [Data([0x01]), Data([0x02])])
        let delegate = SequenceVisibilityDelegate(verdicts)
        let executor = StepExecutor(driver: driver, delegate: delegate, occlusionOCRMode: .off, isAndroid: false,
                                    tunables: RunTunables())
        let outcome = await executor.execute(FlowStep(action: "select", locator: FlowLocator(id: "txt_loading_state"),
                                                      timeout: 1, occlusionGuard: true))
        return (outcome, delegate)
    }

    func testOneRetakeRescuesATransientNotVisible() async {
        let (outcome, delegate) = await select([false, true])
        guard case .passed = outcome.status else { return XCTFail("\(outcome.status)") }
        XCTAssertNotEqual(outcome.driverFallback, "not visible: returned an empty element", "撮り直しで見えたのに空を返した")
        XCTAssertEqual(outcome.resolvedElement?.identifier, "txt_loading_state")
        XCTAssertEqual(delegate.calls, 2)
    }

    func testStillNotVisibleAfterOneRetakeReturnsEmptyWithoutWaiting() async {
        let (outcome, delegate) = await select([false, false, false, false])
        XCTAssertEqual(outcome.driverFallback, "not visible: returned an empty element")
        XCTAssertEqual(delegate.calls, 2, "撮り直しは1回だけ(本当に見えない要素の select を締切まで待たせない)")
    }

    /// 撮り直した要素の状態が変わっていたら(骨組み → 読み込み済み)、後の状態を掴まない = 最初の時点の「見えない」で返す
    /// (E2EY-Android の 53 S0020: 骨組みの押せない行を、押せる行にすり替えて enabledIsFalse が赤だった)
    func testRetakeDoesNotGrabALaterState() async {
        let skeleton = ElementInfo(ref: 1, type: "staticText", identifier: "row_l_03", label: "Row 3", value: nil, placeholder: nil,
                                   enabled: false, frame: FTRect(x: 16, y: 300, width: 300, height: 48), depth: 0)
        var loaded = skeleton
        loaded.enabled = true
        let driver = FakeAppDriver(name: "primary", log: CallLog(), snapshotElements: [[skeleton], [loaded]],
                                   screenshots: [Data([0x01]), Data([0x02])])
        let delegate = SequenceVisibilityDelegate([false, true])
        let executor = StepExecutor(driver: driver, delegate: delegate, occlusionOCRMode: .off,
                                    isAndroid: false, tunables: RunTunables())
        let outcome = await executor.execute(FlowStep(action: "select", locator: FlowLocator(id: "row_l_03"),
                                                      timeout: 1, occlusionGuard: true))
        XCTAssertEqual(outcome.driverFallback, "not visible: returned an empty element", "撮り直しで後の状態(押せる行)を掴んだ")
        XCTAssertNotEqual(outcome.resolvedElement?.enabled, true)
        XCTAssertEqual(delegate.calls, 1, "状態の変わった撮り直しの絵を確かめに行った")
    }
}
