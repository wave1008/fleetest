import XCTest
@testable import FTCore

/// 実行機が知らない検証・操作の名前はスキップでなく失敗にする(分岐の足し忘れが「何もしないまま緑」になる)。
/// 知らない否定形を「!=」として満たさない
final class UnknownStepNameFailsTests: XCTestCase {
    private func run(_ step: FlowStep) async -> StepOutcome {
        let button = ElementInfo(ref: 1, type: "button", identifier: "btn", label: "OK", value: nil, placeholder: nil,
                                 enabled: true, frame: FTRect(x: 0, y: 100, width: 200, height: 60), depth: 1, z: nil)
        let driver = FakeAppDriver(name: "primary", log: CallLog(), snapshotElements: [[button]])
        let executor = StepExecutor(driver: driver, occlusionOCRMode: .off, isAndroid: false, tunables: RunTunables())
        return await executor.execute(step)
    }

    func testUnknownAssertionFails() async {
        let outcome = await run(FlowStep(assert: "noSuchAssertion", locator: FlowLocator(id: "btn"), timeout: 0))
        guard case .failed(let message) = outcome.status else { return XCTFail("\(outcome.status)") }
        XCTAssertTrue(message.contains("unknown assertion: noSuchAssertion"), message)
    }

    func testUnknownActionFails() async {
        let outcome = await run(FlowStep(action: "noSuchAction", locator: FlowLocator(id: "btn")))
        guard case .failed(let message) = outcome.status else { return XCTFail("\(outcome.status)") }
        XCTAssertTrue(message.contains("unknown action: noSuchAction"), message)
    }

    func testUnknownNegativeAssertionIsNotSatisfied() {
        XCTAssertFalse(LocatorResolver.negativeAssertSatisfied("noSuchNot", actual: "a", expected: "b"))
        XCTAssertTrue(LocatorResolver.negativeAssertSatisfied("textNotEquals", actual: "a", expected: "b"))
        XCTAssertTrue(LocatorResolver.negativeAssertSatisfied("valueNotEquals", actual: "a", expected: "b"))
    }
}
