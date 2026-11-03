// キーボードと入力の経路: 閉じた後の覆い・直前の type/clearInput が立てた焦点・RN の「閉じるだけ」の tap・409 の文言

import XCTest
@testable import FTCore

final class KeyboardInputPathsTests: XCTestCase {
    private func el(_ ref: Int, _ type: String, _ id: String, _ f: FTRect, depth: Int = 1, scrollable: Bool? = nil,
                    value: String? = nil) -> ElementInfo {
        var e = ElementInfo(ref: ref, type: type, identifier: id, label: id, value: value, placeholder: nil, enabled: true,
                            frame: f, depth: depth)
        e.scrollable = scrollable
        return e
    }

    /// F2: 閉じた後の木で中心が下のタブ列に潜っていたら、タブを押さずに断る(注記だけで撃たない)
    func testTapAfterClosingKeyboardRefusesWhenTabBarCoversTheTarget() async throws {
        let log = CallLog()
        let target = el(1, "button", "btn_submit", FTRect(x: 20, y: 700, width: 300, height: 60))
        let tab = el(2, "button", "tab_home", FTRect(x: 0, y: 680, width: 400, height: 120))
        let primary = FakeAppDriver(name: "primary", log: log, snapshotElements: [[target]])
        primary.keyboardFrame = FTRect(x: 0, y: 450, width: 400, height: 350)
        primary.afterHideKeyboard = {
            primary.keyboardFrame = nil
            primary.snapshotElements = [[target, tab]]
        }
        let executor = StepExecutor(driver: primary, isAndroid: true, tunables: RunTunables())
        let outcome = await executor.execute(FlowStep(action: "tap", locator: FlowLocator(id: "btn_submit")))
        guard case .failed(let message) = outcome.status else { return XCTFail("\(outcome.status) \(log.entries)") }
        XCTAssertTrue(message.contains("covered by"), message)
        XCTAssertTrue(message.contains("nothing was touched"), message)
        XCTAssertFalse(log.entries.contains { $0.hasPrefix("primary.tap(") }, log.entries.description)
    }

    /// F5: 直前の type が叩いた欄は、焦点の印を木に出さない構成でも clearInput がキーボードの下で閉じずに消す
    func testClearInputRightAfterTypeOnTheSameFieldDoesNotCloseTheKeyboard() async throws {
        let log = CallLog()
        let early = el(1, "textField", "field_single", FTRect(x: 78, y: 100, width: 718, height: 48))
        var covered = early
        covered.frame = FTRect(x: 78, y: 260, width: 718, height: 48)
        let primary = FakeAppDriver(name: "primary", log: log, snapshotElements: [[early]])
        primary.tapProbeAnswer = TapProbeResponse(background: true, receiver: "UIView", reason: nil)
        let executor = StepExecutor(driver: primary, isAndroid: false, tunables: RunTunables(defaultTimeout: 0.2),
                                    uiFramework: .flutter)
        _ = await executor.execute(FlowStep(action: "type", locator: FlowLocator(id: "field_single"), text: "abc"))
        primary.snapshotElements = [[covered]]
        primary.keyboardFrame = FTRect(x: 0, y: 218, width: 874, height: 184)
        log.entries.removeAll()
        primary.coordinateTaps.removeAll()
        let outcome = await executor.execute(FlowStep(action: "clearInput", locator: FlowLocator(id: "field_single")))
        XCTAssertTrue(log.entries.contains { $0.hasPrefix("primary.clearInput(") }, "\(outcome.status) \(log.entries)")
        XCTAssertTrue(primary.coordinateTaps.isEmpty, "閉じるために叩いた: \(primary.coordinateTaps)")
    }

    /// F5: replace の type は、自分の消去が欄を叩いて焦点を立てた後に欄がキーボードの下へ潜っても閉じずに打つ
    func testReplaceTypeDoesNotCloseTheKeyboardItselfRaised() async throws {
        let log = CallLog()
        let early = el(1, "textField", "field_single", FTRect(x: 78, y: 100, width: 718, height: 48), value: "old")
        var covered = early
        covered.frame = FTRect(x: 78, y: 260, width: 718, height: 48)
        let primary = FakeAppDriver(name: "primary", log: log, snapshotElements: [[early]])
        primary.tapProbeAnswer = TapProbeResponse(background: true, receiver: "UIView", reason: nil)
        primary.onMutatingCall = {
            primary.snapshotElements = [[covered]]
            primary.keyboardFrame = FTRect(x: 0, y: 218, width: 874, height: 184)
        }
        let executor = StepExecutor(driver: primary, isAndroid: false, tunables: RunTunables(defaultTimeout: 0.2),
                                    uiFramework: .flutter)
        let outcome = await executor.execute(FlowStep(action: "type", locator: FlowLocator(id: "field_single"),
                                                      text: "abc", replace: true))
        if case .failed(let message) = outcome.status {
            XCTAssertFalse(message.contains("under the soft keyboard"), message)
        }
        XCTAssertTrue(primary.coordinateTaps.isEmpty, "閉じるために叩いた: \(primary.coordinateTaps)")
    }

    /// replace の type は、最初からキーボードの下にある欄でも閉じずに打つ(消去が欄を叩いて焦点を立てるので、その欄を焦点のある欄とみなす)。
    /// 直前のステップの tap は無い = 直前の tap の免除には頼れない形
    func testReplaceTypeIntoAFieldAlreadyUnderTheKeyboardDoesNotCloseIt() async throws {
        let log = CallLog()
        let covered = el(1, "textField", "field_single", FTRect(x: 78, y: 260, width: 718, height: 48), value: "old")
        let primary = FakeAppDriver(name: "primary", log: log, snapshotElements: [[covered]])
        primary.keyboardFrame = FTRect(x: 0, y: 218, width: 874, height: 184)
        primary.tapProbeAnswer = TapProbeResponse(background: true, receiver: "UIView", reason: nil)
        let executor = StepExecutor(driver: primary, isAndroid: false, tunables: RunTunables(defaultTimeout: 0.2),
                                    uiFramework: .flutter)
        let outcome = await executor.execute(FlowStep(action: "type", locator: FlowLocator(id: "field_single"),
                                                      text: "abc", replace: true))
        if case .failed(let message) = outcome.status {
            XCTAssertFalse(message.contains("under the soft keyboard"), message)
        }
        XCTAssertTrue(primary.coordinateTaps.isEmpty, "閉じるために叩いた: \(primary.coordinateTaps)")
    }

    /// e2ey F5: RN の ScrollView の中の行は、キーボードが出ている間の最初のタップが閉じるだけなので撃つ前に閉じる
    func testTapOnlyDismissesKeyboardJudgement() {
        let list = el(1, "scrollView", "list_chat", FTRect(x: 0, y: 0, width: 400, height: 500), depth: 0, scrollable: true)
        let row = el(2, "button", "msg_30", FTRect(x: 10, y: 100, width: 380, height: 40), depth: 1)
        let outside = el(3, "button", "btn_send", FTRect(x: 300, y: 520, width: 80, height: 40), depth: 0)
        var shown = SnapshotResponse(sessionBundleID: nil, screen: FTRect(x: 0, y: 0, width: 400, height: 800),
                                     elements: [list, row, outside], truncatedCount: 0)
        shown.keyboardFrame = FTRect(x: 0, y: 560, width: 400, height: 240)
        XCTAssertTrue(PreFireGuard.tapOnlyDismissesKeyboard(row, in: shown, framework: .reactNative))
        XCTAssertFalse(PreFireGuard.tapOnlyDismissesKeyboard(outside, in: shown, framework: .reactNative), "ScrollView の外")
        XCTAssertFalse(PreFireGuard.tapOnlyDismissesKeyboard(row, in: shown, framework: .flutter))
        XCTAssertFalse(PreFireGuard.tapOnlyDismissesKeyboard(row, in: shown, framework: nil), "不明は撃つ側")
        var hidden = shown
        hidden.keyboardFrame = nil
        XCTAssertFalse(PreFireGuard.tapOnlyDismissesKeyboard(row, in: hidden, framework: .reactNative))
    }

    /// F6: ブリッジの 409 の文言(ref を渡せ)を DSL の利用者へ出さない。断られた事実だけ言う
    func testClearInput409MessageDoesNotAdviseARef() async throws {
        let log = CallLog()
        let field = el(1, "textField", "field_single", FTRect(x: 78, y: 100, width: 718, height: 48))
        let primary = FakeAppDriver(name: "primary", log: log, snapshotElements: [[field]])
        primary.clearInputError = DriverError.badResponse(status: 409, body: "pass the ref of the input element itself")
        let executor = StepExecutor(driver: primary, isAndroid: false, tunables: RunTunables(), uiFramework: .compose)
        let outcome = await executor.execute(FlowStep(action: "clearInput", locator: FlowLocator(id: "field_single")))
        guard case .failed(let message) = outcome.status else { return XCTFail("\(outcome.status)") }
        XCTAssertFalse(message.contains("pass the ref"), message)
        XCTAssertTrue(message.contains("HTTP 409"), message)
    }

    /// F1: 409 の理由を推測で言わない(焦点が立っていても 409 は返る)
    func testTypeFocusMissMessageStatesOnlyTheFact() {
        let message = StepExecutor.typeFocusMissMessage(FlowStep(action: "type", locator: FlowLocator(id: "f")), tried: true)
        XCTAssertFalse(message.contains("could not give"), message)
        XCTAssertTrue(message.contains("HTTP 409"), message)
    }
}
