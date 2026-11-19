// 枠が画面の原点に貼り付いた小さな要素へは撃たずに断る(DR-203。撃つとステータスバーに当たり、前のアプリへ移りうる)
import XCTest
@testable import FTCore

final class OriginPinnedRefusalTests: XCTestCase {

    private func checkbox(_ x: Double) -> ElementInfo {
        ElementInfo(ref: 1, type: "button", identifier: "check", label: "未実行", value: nil, placeholder: nil, enabled: true,
                    frame: FTRect(x: x, y: x, width: 25, height: 25), depth: 1)
    }

    private func tap(_ element: ElementInfo) async -> (StepOutcome, [String]) {
        let log = CallLog()
        let driver = FakeAppDriver(name: "d", log: log, snapshotElements: [[element]])
        let outcome = await StepExecutor(driver: driver, isAndroid: false, tunables: RunTunables())
            .execute(FlowStep(action: "tap", locator: FlowLocator(id: "check"), occlusionGuard: false))
        return (outcome, log.entries + driver.coordinateTaps.map { "tap(x:\($0.x),y:\($0.y))" })
    }

    func testElementPinnedToTheScreenOriginIsNotTouched() async {
        let (outcome, log) = await tap(checkbox(0))
        guard case .failed(let message) = outcome.status else { return XCTFail("\(outcome.status)") }
        XCTAssertTrue(message.description.contains("top-left corner"), message.description)
        XCTAssertFalse(log.contains { $0.contains("tap(") }, "\(log)")
    }

    func testTheSameElementAwayFromTheOriginIsTouched() async {
        let (outcome, log) = await tap(checkbox(40))
        if case .failed(let message) = outcome.status { return XCTFail(message.description) }
        XCTAssertTrue(log.contains { $0.contains("tap(") }, "\(log)")
    }
}
