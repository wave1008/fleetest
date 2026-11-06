// 台帳 OI-184 ② / OI-163 ⑮ / OI-161 ⑨ / OI-129 の直しの固定。
//  1. 「対象が動いた」注記は、失敗したステップの対象が直前の tap の対象と同じときだけ付く
//  2. Android の pressEnter / clearInput の 409 の失敗文は Android の事実だけを言う
//  3. 欄を叩く tap の後のキーボードの出現待ちが尽きたら keyboard-not-shown-after-tap(type の注記は変えない)
//  4. ロケータなしの type の後に焦点の申告が無ければ(Android)type-focus-not-reported。判定は MCP と共有

import XCTest
@testable import FTCore

final class OperationNoteFixesTests: XCTestCase {

    private func element(_ ref: Int, id: String?, label: String? = nil, type: String = "button",
                         y: Double, focused: Bool? = nil) -> ElementInfo {
        ElementInfo(ref: ref, type: type, identifier: id, label: label, value: nil, placeholder: nil, enabled: true,
                    frame: FTRect(x: 20, y: y, width: 100, height: 40), depth: 1, focused: focused)
    }

    private func executor(isAndroid: Bool = false) -> StepExecutor {
        StepExecutor(driver: FakeAppDriver(name: "primary", log: CallLog()), isAndroid: isAndroid, tunables: RunTunables())
    }

    private func armLastTap(_ executor: StepExecutor, target: ElementInfo, before: [ElementInfo]) {
        executor.lastInteraction = StepExecutor.LastInteraction(
            description: "tap #\(target.identifier ?? "")", before: before, pointTakenBy: nil, target: target)
    }

    // MARK: - 1

    func testMovedNoteStaysWhenNoStepIsGiven() {
        let tapped = element(1, id: "a", y: 100)
        let ex = executor()
        armLastTap(ex, target: tapped, before: [tapped])
        XCTAssertTrue(ex.tapDiagnosisHint([element(1, id: "a", y: 300)]).contains("the target has moved"))
    }

    // MARK: - 2

    func testFocusedFieldRefusalSpeaksForTheConfiguration() {
        let android = StepExecutor.focusedFieldRefusal("press Enter in", isAndroid: true)
        XCTAssertFalse(android.contains("in-app"), android)
        XCTAssertFalse(android.contains("XCUITest"), android)
        XCTAssertTrue(android.contains("Android bridge refused to press Enter in the focused field (HTTP 409)"), android)
        let ios = StepExecutor.focusedFieldRefusal("clear", isAndroid: false)
        XCTAssertTrue(ios.contains("in-app bridge") && ios.contains("no XCUITest bridge"), ios)
    }

    func testAndroidPressEnterRefusalIsAndroidsWhenTheBridgeAnswers409() async {
        let driver = FakeAppDriver(name: "primary", log: CallLog())
        driver.pressEnterError = DriverError.badResponse(status: 409, body: "no focus")
        let outcome = await StepExecutor(driver: driver, isAndroid: true, tunables: RunTunables())
            .execute(FlowStep(action: "pressEnter"))
        guard case .failed(let message) = outcome.status else { return XCTFail("\(outcome.status)") }
        XCTAssertFalse(message.contains("in-app") || message.contains("XCUITest"), message)
    }

    // MARK: - 3

    func testStepNoteForTapKeyboardWaitHasItsOwnRawValue() {
        XCTAssertEqual(StepNote.keyboardNotShownAfterTap.rawValue, "keyboard-not-shown-after-tap")
        XCTAssertEqual(StepNote.keyboardNotShownAfterType.rawValue, "keyboard-not-shown-after-type")
        XCTAssertFalse(StepNote.keyboardNotShownAfterTap.text.contains("after the preceding type"))
    }

    func testFieldTapKeyboardWaitThatRunsOutNotesAfterTapNotAfterType() async throws {
        let field = element(1, id: "f", type: "textField", y: 100)
        let driver = FakeAppDriver(name: "primary", log: CallLog(), snapshotElements: [[field]])
        let ex = StepExecutor(driver: driver, isAndroid: true, tunables: RunTunables())
        let snap = SnapshotResponse(sessionBundleID: nil, screen: FTRect(x: 0, y: 0, width: 400, height: 800),
                                    elements: [field], truncatedCount: 0)
        ex.armKeyboardAppearanceWaitAfterFieldTap(field, in: snap)
        XCTAssertTrue(ex.pendingTypeKeyboardCheck)
        var phase = StepExecutor.PhaseAccumulator()
        _ = try await ex.consumePendingTypeKeyboardCheck(snap, phase: &phase)
        XCTAssertTrue(ex.noteCodesThisStep.contains(.keyboardNotShownAfterTap), "\(ex.noteCodesThisStep)")
        XCTAssertFalse(ex.noteCodesThisStep.contains(.keyboardNotShownAfterType), "\(ex.noteCodesThisStep)")
    }

    // MARK: - 4

    func testVerdictSeparatesReportedUnconfirmableAndNowhere() {
        let screen = FTRect(x: 0, y: 0, width: 400, height: 800)
        func snap(_ elements: [ElementInfo], keyboard: FTRect? = nil) -> SnapshotResponse {
            SnapshotResponse(sessionBundleID: nil, screen: screen, elements: elements, truncatedCount: 0, keyboardFrame: keyboard)
        }
        let plain = element(1, id: "a", y: 100)
        XCTAssertEqual(TypeFocusConfirmation.verdict(snap([element(2, id: "f", type: "textField", y: 10, focused: true)])), .reported)
        XCTAssertEqual(TypeFocusConfirmation.verdict(snap([plain])), .nowhere)
        XCTAssertEqual(TypeFocusConfirmation.verdict(snap([plain], keyboard: FTRect(x: 0, y: 400, width: 400, height: 400))), .unconfirmable)
        XCTAssertEqual(TypeFocusConfirmation.verdict(snap([])), .unconfirmable)
        XCTAssertEqual(TypeFocusConfirmation.verdict(snap([element(3, id: "w", type: "webView", y: 0)])), .unconfirmable)
    }

    func testRefLessTypeOnAndroidNotesWhenNoFocusIsReported() async {
        let plain = element(1, id: "a", y: 100)
        let driver = FakeAppDriver(name: "primary", log: CallLog(), snapshotElements: [[plain]])
        let outcome = await StepExecutor(driver: driver, isAndroid: true, tunables: RunTunables())
            .execute(FlowStep(action: "type", text: "abc"))
        XCTAssertTrue(outcome.notes.contains(.typeFocusNotReported), "\(outcome.notes)")
        let focused = FakeAppDriver(name: "primary", log: CallLog(),
                                    snapshotElements: [[element(2, id: "f", type: "textField", y: 10, focused: true)]])
        let quiet = await StepExecutor(driver: focused, isAndroid: true, tunables: RunTunables())
            .execute(FlowStep(action: "type", text: "abc"))
        XCTAssertFalse(quiet.notes.contains(.typeFocusNotReported), "\(quiet.notes)")
    }
}
