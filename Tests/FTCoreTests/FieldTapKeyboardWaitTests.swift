// Android で入力欄を叩く tap の後は、次のロケータ操作の解決の前にキーボードの出現を待つ(OI-114)。
// 叩いた直後の木は上がる途中のキーボードを持たず、続く type が押し出される前の位置の欄を掴んで 500 で落ちていた。

import XCTest
@testable import FTCore

final class FieldTapKeyboardWaitTests: XCTestCase {

    private func field() -> ElementInfo {
        ElementInfo(ref: 1, type: "textField", identifier: "f", label: nil, value: nil, placeholder: nil,
                    enabled: true, frame: FTRect(x: 20, y: 300, width: 200, height: 40), depth: 1)
    }

    private func button() -> ElementInfo {
        ElementInfo(ref: 2, type: "button", identifier: "b", label: "送信", value: nil, placeholder: nil,
                    enabled: true, frame: FTRect(x: 20, y: 400, width: 100, height: 40), depth: 1)
    }

    private func executor(isAndroid: Bool, knownAbsent: Bool = false) -> (StepExecutor, FakeAppDriver) {
        let driver = FakeAppDriver(name: "primary", log: CallLog(),
                                   snapshotElements: Array(repeating: [field(), button()], count: 12))
        driver.keyboardFrames = [nil]
        let executor = StepExecutor(driver: driver, isAndroid: isAndroid, tunables: RunTunables())
        executor.keyboardKnownAbsent = knownAbsent
        return (executor, driver)
    }

    func testAndroidTapOnTextFieldArmsTheKeyboardWait() async {
        let (executor, _) = executor(isAndroid: true)
        _ = await executor.execute(FlowStep(action: "tap", locator: FlowLocator(id: "f")))
        XCTAssertTrue(executor.pendingTypeKeyboardCheck)
        XCTAssertFalse(executor.pendingTypeEndedWithNewline)
    }

    func testTapOnAButtonDoesNotArm() async {
        let (executor, _) = executor(isAndroid: true)
        _ = await executor.execute(FlowStep(action: "tap", locator: FlowLocator(id: "b")))
        XCTAssertFalse(executor.pendingTypeKeyboardCheck)
    }

    func testIOSTapOnTextFieldDoesNotArm() async {
        let (executor, _) = executor(isAndroid: false)
        _ = await executor.execute(FlowStep(action: "tap", locator: FlowLocator(id: "f")))
        XCTAssertFalse(executor.pendingTypeKeyboardCheck)
    }

    /// 出なかったと観測済みの端末では毎回の上限待ちを払わない
    func testKnownAbsentKeyboardDoesNotArm() async {
        let (executor, _) = executor(isAndroid: true, knownAbsent: true)
        _ = await executor.execute(FlowStep(action: "tap", locator: FlowLocator(id: "f")))
        XCTAssertFalse(executor.pendingTypeKeyboardCheck)
    }
}
