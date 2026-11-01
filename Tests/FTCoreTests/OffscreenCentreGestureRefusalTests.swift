// OI-123: 中心が画面の外の対象への長押し・doubleTap・要素から要素へのドラッグ・Android のピンチは、撃たずに失敗にする。
// 判定は TapTargetGeometry.offscreenScrollGateCentre(画面より大きい軸は免除)。

import XCTest
@testable import FTCore

final class OffscreenCentreGestureRefusalTests: XCTestCase {

    private func el(_ ref: Int, _ id: String, y: Double, height: Double = 40, width: Double = 100) -> ElementInfo {
        ElementInfo(ref: ref, type: "button", identifier: id, label: nil, value: nil, placeholder: nil, enabled: true,
                    frame: FTRect(x: 10, y: y, width: width, height: height), depth: 0)
    }

    private func run(_ step: FlowStep, _ elements: [ElementInfo], android: Bool = false)
        async -> (StepOutcome, CallLog) {
        let log = CallLog()
        let driver = FakeAppDriver(name: "primary", log: log, snapshotElements: [elements])
        let executor = StepExecutor(driver: driver, isAndroid: android, tunables: RunTunables())
        return (await executor.execute(step), log)
    }

    private func assertRefused(_ outcome: StepOutcome, _ log: CallLog, _ fired: String,
                               file: StaticString = #filePath, line: UInt = #line) {
        guard case .failed(let message) = outcome.status else {
            return XCTFail("failed を期待: \(outcome.status)", file: file, line: line)
        }
        XCTAssertTrue(message.contains("outside the visible screen"), message, file: file, line: line)
        XCTAssertFalse(log.entries.contains { $0.contains(fired) }, "撃たないこと: \(log.entries)", file: file, line: line)
    }

    func testDoubleTapOnOffscreenCentreIsRefused() async {
        let (outcome, log) = await run(FlowStep(action: "doubleTap", locator: FlowLocator(id: "below")),
                                       [el(1, "below", y: 900)])
        assertRefused(outcome, log, "doubleTap")
    }

    func testLongPressOnOffscreenCentreIsRefused() async {
        let (outcome, log) = await run(FlowStep(action: "tap", locator: FlowLocator(id: "below"), duration: 1.0),
                                       [el(1, "below", y: 900)])
        assertRefused(outcome, log, "press")
    }

    func testSwipeElementToElementRefusesOffscreenStartAndEnd() async {
        let step = FlowStep(action: "swipeElementToElement", locator: FlowLocator(id: "a"),
                            endLocator: FlowLocator(id: "b"), timeout: 0, occlusionGuard: false)
        let (startOut, startLog) = await run(step, [el(1, "a", y: 900), el(2, "b", y: 100)])
        assertRefused(startOut, startLog, "drag")
        let (endOut, endLog) = await run(step, [el(1, "a", y: 100), el(2, "b", y: 900)])
        assertRefused(endOut, endLog, "drag")
    }

    func testPinchOnAndroidIsRefusedButIOSIsNot() async {
        let step = FlowStep(action: "pinchOut", locator: FlowLocator(id: "below"), scale: 2.0)
        let (android, androidLog) = await run(step, [el(1, "below", y: 900)], android: true)
        assertRefused(android, androidLog, "pinch")
        let (ios, _) = await run(step, [el(1, "below", y: 900)], android: false)
        guard case .passed = ios.status else { return XCTFail("iOS のピンチは対象外: \(ios.status)") }
    }

    /// 中心が画面の中なら通る(画面 400x800)。画面より大きい要素は中心が外でも免除
    func testOnscreenAndOversizedTargetsStillFire() async {
        let (onscreen, _) = await run(FlowStep(action: "doubleTap", locator: FlowLocator(id: "in")),
                                      [el(1, "in", y: 760)])
        guard case .passed = onscreen.status else { return XCTFail("\(onscreen.status)") }
        let tall = ElementInfo(ref: 1, type: "button", identifier: "tall", label: nil, value: nil, placeholder: nil,
                               enabled: true, frame: FTRect(x: 0, y: 300, width: 500, height: 2000), depth: 0)
        let (oversized, _) = await run(FlowStep(action: "doubleTap", locator: FlowLocator(id: "tall")), [tall])
        guard case .passed = oversized.status else { return XCTFail("\(oversized.status)") }
    }

    /// 押すだけの tap は対象外(見えている部分へ寄せる経路があり、助言に止める)
    func testPlainTapIsNotRefusedByThisGate() {
        XCTAssertNil(StepExecutor.offscreenCentreRefusal(
            action: "tap", step: FlowStep(action: "tap", locator: FlowLocator(id: "x")),
            element: el(1, "x", y: 900), screen: FTRect(x: 0, y: 0, width: 400, height: 800), isAndroid: false))
    }
}
