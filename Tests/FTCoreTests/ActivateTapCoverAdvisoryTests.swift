// in-app が activate で押した tap(ref:) には、木の幾何だけで言う「中心の覆いに当たったかも」を付けない(座標を撃っていない)。
// 合成タッチ・言えないときは従来どおり付ける

import XCTest
@testable import FTCore

final class ActivateTapCoverAdvisoryTests: XCTestCase {
    private func run(_ delivery: TapDelivery?) async -> (StepOutcome, [ElementInfo]) {
        let target = ElementInfo(ref: 1, type: "button", identifier: "btn_under_footer", label: "下端のボタン", value: nil,
                                 placeholder: nil, enabled: true, frame: FTRect(x: 0, y: 300, width: 400, height: 60), depth: 1)
        let cover = ElementInfo(ref: 2, type: "button", identifier: "tab_controls", label: "コントロール", value: nil,
                                placeholder: nil, enabled: true, frame: FTRect(x: 0, y: 320, width: 400, height: 60), depth: 1)
        let elements = [target, cover]
        let driver = FakeAppDriver(name: "d", log: CallLog(), snapshotElements: [elements])
        driver.tapDeliveryAnswer = delivery
        let outcome = await StepExecutor(driver: driver, isAndroid: false, tunables: RunTunables())
            .execute(FlowStep(action: "tap", locator: FlowLocator(id: "btn_under_footer"), timeout: 0))
        return (outcome, elements)
    }

    func testActivateDropsTheCentreCoverAdvisory() async {
        let (outcome, elements) = await run(.activate)
        guard case .overlayCovering? = TapTargetGeometry.advisoryKind(for: elements[0], in: elements,
                                                                     screen: FTRect(x: 0, y: 0, width: 400, height: 800)) else {
            return XCTFail("前提: 木の幾何は中心の覆いと読む")
        }
        XCTAssertTrue(StepExecutor.isSuccess(outcome.status), "\(outcome.status)")
        XCTAssertFalse((outcome.driverFallback ?? "").contains("may have hit"), outcome.driverFallback ?? "")
    }

    func testSyntheticTouchKeepsTheAdvisory() async {
        let (outcome, _) = await run(.syntheticTouch)
        XCTAssertTrue((outcome.driverFallback ?? "").contains("may have hit #tab_controls"), outcome.driverFallback ?? "")
    }

    func testUnknownDeliveryKeepsTheAdvisory() async {
        let (outcome, _) = await run(nil)
        XCTAssertTrue((outcome.driverFallback ?? "").contains("may have hit #tab_controls"), outcome.driverFallback ?? "")
    }
}
