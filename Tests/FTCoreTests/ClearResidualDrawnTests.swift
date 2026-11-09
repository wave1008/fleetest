import XCTest
@testable import FTCore

/// clearInput が消え残りと読んだ値が欄に描かれているかの判定(純粋関数)と、StepExecutor への配線
final class ClearResidualDrawnTests: XCTestCase {
    private let residual = "検索候補は次のとおりです"

    // MARK: - 判定

    func testPlaceholderLineIsNotTheResidual() {
        XCTAssertTrue(ClearResidualDrawn.remainingLines(ocrLines: ["検索"], treeTexts: ["検索"]).isEmpty)
    }

    func testNothingDrawnIsNotDrawn() {
        XCTAssertTrue(ClearResidualDrawn.remainingLines(ocrLines: [], treeTexts: ["検索"]).isEmpty)
    }

    /// value(案内文)は描かれず、消し損ねた入力 "bx" が描かれている = 消え残り(value の文字との照合では見逃す形)
    func testLeftoverInputOtherThanTheValueIsDrawn() {
        XCTAssertFalse(ClearResidualDrawn.remainingLines(ocrLines: ["検索", "bx"], treeTexts: ["検索"]).isEmpty)
    }

    /// 書式付きの表示・同形異字の誤読・キーボードの文字など、何であれ飾り以外の行は赤のまま
    func testAnyLineOtherThanDecorationIsDrawn() {
        XCTAssertFalse(ClearResidualDrawn.remainingLines(ocrLines: ["090-1234-5678"], treeTexts: []).isEmpty)
        XCTAssertFalse(ClearResidualDrawn.remainingLines(ocrLines: ["аp"], treeTexts: ["Search"]).isEmpty)
    }

    func testWhitespaceIsIgnoredWhenMatchingTreeTexts() {
        XCTAssertTrue(ClearResidualDrawn.remainingLines(ocrLines: [" 検 索 "], treeTexts: ["検索"]).isEmpty)
        XCTAssertEqual(ClearResidualDrawn.remainingLines(ocrLines: [" 検 索 ", " ", "bx"], treeTexts: ["検索"]), ["bx"])
    }

    /// 欄自身のラベルは飾りに入れない(入力をラベルへ畳む構成 "bx, Search" で消し損ねた入力を除いてしまう)
    func testTreeTextsArePlaceholderAndInnerStaticTextButNotTheFieldLabel() {
        let field = ElementInfo(ref: 1, type: "textView", identifier: "field_search", label: "bx, Search",
                                value: residual, placeholder: "ph", enabled: true,
                                frame: FTRect(x: 0, y: 0, width: 300, height: 40), depth: 0)
        let inner = ElementInfo(ref: 2, type: "staticText", identifier: nil, label: "inner", value: nil, placeholder: nil,
                                enabled: true, frame: FTRect(x: 10, y: 10, width: 50, height: 20), depth: 1)
        let outer = ElementInfo(ref: 3, type: "staticText", identifier: nil, label: "outer", value: nil, placeholder: nil,
                                enabled: true, frame: FTRect(x: 10, y: 100, width: 50, height: 20), depth: 1)
        let texts = ClearResidualDrawn.treeTexts(field: field, in: [field, inner, outer])
        XCTAssertEqual(Set(texts), ["ph", "inner"])
        XCTAssertFalse(ClearResidualDrawn.remainingLines(ocrLines: ["bx"], treeTexts: texts).isEmpty)
    }

    /// 既定値はリテラルで固定する(ランナーの clearBudgetSeconds と揃える値。他のテストは差し替え口で予算を通らない)
    func testClearReadbackBudgetIsPinned() {
        XCTAssertEqual(StepExecutor.clearReadbackBudgetSeconds, 8)
    }

    func testUnreadableReasons() {
        let screen = FTRect(x: 0, y: 0, width: 400, height: 800)
        func field(_ type: String, _ frame: FTRect) -> ElementInfo {
            ElementInfo(ref: 1, type: type, identifier: nil, label: nil, value: "v", placeholder: nil, enabled: true,
                        frame: frame, depth: 0)
        }
        let ok = FTRect(x: 10, y: 100, width: 200, height: 40)
        XCTAssertNil(ClearResidualDrawn.unreadableReason(field: field("textField", ok), screen: screen, keyboard: nil))
        XCTAssertNotNil(ClearResidualDrawn.unreadableReason(field: field("secureTextField", ok), screen: screen, keyboard: nil))
        XCTAssertNotNil(ClearResidualDrawn.unreadableReason(
            field: field("textField", FTRect(x: 300, y: 100, width: 200, height: 40)), screen: screen, keyboard: nil))
        XCTAssertNotNil(ClearResidualDrawn.unreadableReason(
            field: field("textField", ok), screen: screen, keyboard: FTRect(x: 0, y: 120, width: 400, height: 300)))
        XCTAssertNil(ClearResidualDrawn.unreadableReason(
            field: field("textField", ok), screen: screen, keyboard: FTRect(x: 0, y: 500, width: 400, height: 300)))
    }

    // MARK: - 配線

    private func searchField(value: String?, focused: Bool? = nil) -> ElementInfo {
        ElementInfo(ref: 7, type: "textView", identifier: "field_search", label: "検索, 検索", value: value,
                    placeholder: nil, enabled: true, frame: FTRect(x: 0, y: 0, width: 100, height: 20), depth: 0,
                    focused: focused)
    }

    private func run(_ step: FlowStep, drawn: Bool?, driver: (FakeAppDriver) -> Void = { _ in }) async -> StepOutcome {
        // drawn のときの fact = 飾りの他に読めた行
        StepExecutor.clearResidualDrawnOverrideForTesting = { _ in (drawn, drawn == nil ? "OCR was unavailable" : (drawn! ? "bx" : nil)) }
        defer { StepExecutor.clearResidualDrawnOverrideForTesting = nil }
        let primary = FakeAppDriver(name: "primary", log: CallLog(),
                                    snapshotElements: [[searchField(value: residual, focused: true)]])
        driver(primary)
        let executor = StepExecutor(driver: primary, isAndroid: false, tunables: RunTunables())
        return await executor.execute(step)
    }

    func testSelectorClearPassesWithNoteWhenResidualIsNotDrawn() async {
        let outcome = await run(FlowStep(action: "clearInput", locator: FlowLocator(id: "field_search")), drawn: false)
        guard case .passed = outcome.status else { XCTFail("\(outcome.status)"); return }
        XCTAssertTrue(outcome.notes.contains(.clearResidualNotDrawn))
        XCTAssertEqual(outcome.driverFallback, StepNote.clearResidualNotDrawn.text)
    }

    func testSelectorClearStaysRedWhenResidualIsDrawn() async {
        let outcome = await run(FlowStep(action: "clearInput", locator: FlowLocator(id: "field_search")), drawn: true)
        guard case .failed(let message) = outcome.status else { XCTFail("\(outcome.status)"); return }
        XCTAssertEqual(message, "clearInput reported success but the value remained: \"\(residual)\""
            + " (the field on screen still shows text (OCR): \"bx\")")
        XCTAssertFalse(outcome.notes.contains(.clearResidualNotDrawn))
    }

    func testSelectorClearStaysRedWithReasonWhenUndetermined() async {
        let outcome = await run(FlowStep(action: "clearInput", locator: FlowLocator(id: "field_search")), drawn: nil)
        guard case .failed(let message) = outcome.status else { XCTFail("\(outcome.status)"); return }
        XCTAssertTrue(message.hasPrefix("clearInput reported success but the value remained: "), message)
        XCTAssertTrue(message.contains("not checked against the screen: OCR was unavailable"), message)
    }

    func testFocusedClearPassesWithNoteWhenResidualIsNotDrawn() async {
        let outcome = await run(FlowStep(action: "clearInput"), drawn: false)
        guard case .passed = outcome.status else { XCTFail("\(outcome.status)"); return }
        XCTAssertTrue(outcome.notes.contains(.clearResidualNotDrawn))
    }

    func testFocusedClearStaysRedWhenResidualIsDrawn() async {
        let outcome = await run(FlowStep(action: "clearInput"), drawn: true)
        guard case .failed(let message) = outcome.status else { XCTFail("\(outcome.status)"); return }
        XCTAssertTrue(message.contains("the value remained"), message)
    }

    func testRunnerEmptyRefusalPassesWhenResidualIsNotDrawn() async {
        let outcome = await run(FlowStep(action: "clearInput", locator: FlowLocator(id: "field_search")), drawn: false) {
            $0.clearInputError = DriverError.badResponse(
                status: 422, body: StepExecutor.runnerEmptyRefusalPrefix + " (12 character(s) still there after 4 round(s))")
        }
        guard case .passed = outcome.status else { XCTFail("\(outcome.status)"); return }
        XCTAssertTrue(outcome.notes.contains(.clearResidualNotDrawn))
    }

    func testRunnerEmptyRefusalStaysErrorWhenResidualIsDrawn() async {
        let outcome = await run(FlowStep(action: "clearInput", locator: FlowLocator(id: "field_search")), drawn: true) {
            $0.clearInputError = DriverError.badResponse(
                status: 422, body: StepExecutor.runnerEmptyRefusalPrefix + " (12 character(s) still there after 4 round(s))")
        }
        guard case .failed(let message) = outcome.status else { XCTFail("\(outcome.status)"); return }
        XCTAssertTrue(message.contains("could not empty the field"), message)
        XCTAssertTrue(message.contains("the field on screen still shows text (OCR): \"bx\""), message)
    }

    /// 判断できなかった 422 も、確かめられなかった理由を本文に足して同じ 422 のまま返す
    func testRunnerEmptyRefusalCarriesTheReasonWhenUndetermined() async {
        let outcome = await run(FlowStep(action: "clearInput", locator: FlowLocator(id: "field_search")), drawn: nil) {
            $0.clearInputError = DriverError.badResponse(
                status: 422, body: StepExecutor.runnerEmptyRefusalPrefix + " (12 character(s) still there after 4 round(s))")
        }
        guard case .failed(let message) = outcome.status else { XCTFail("\(outcome.status)"); return }
        XCTAssertTrue(message.contains("could not empty the field"), message)
        XCTAssertTrue(message.contains("not checked against the screen: OCR was unavailable"), message)
    }

    /// 絵が縦長・木が横長(開いた Duo)= 切り出しが断られる。理由を言う。向きが合えば nil
    func testOrientationReasonNamesTheMismatch() {
        let landscape = FTRect(x: 0, y: 0, width: 951, height: 669)
        let reason = ClearResidualDrawn.orientationReason(imageWidth: 2006, imageHeight: 2852, screen: landscape)
        XCTAssertNotNil(reason)
        XCTAssertTrue(reason?.contains("2006x2852") == true, reason ?? "")
        XCTAssertNil(ClearResidualDrawn.orientationReason(imageWidth: 2852, imageHeight: 2006, screen: landscape))
    }

    /// 消え残り → XCUITest へ回した消去が 422 のとき、確かめは外の catch(1回)と撃ち直しの後(1回)だけ。
    /// 内側でも確かめると同じ欄の OCR を3回払う(1回あたり最大 8 秒)
    func testResidualPathEmptyRefusalChecksTheScreenOncePerClear() async {
        let checks = LockedValue(0)
        StepExecutor.clearResidualDrawnOverrideForTesting = { _ in checks.withLock { $0 += 1 }; return (true, "bx") }
        defer { StepExecutor.clearResidualDrawnOverrideForTesting = nil }
        let primary = FakeAppDriver(name: "primary", log: CallLog(), snapshotElements: [[searchField(value: residual, focused: true)]])
        let typeDriver = FakeAppDriver(name: "typedriver", log: CallLog(), snapshotElements: [[searchField(value: residual, focused: true)]])
        typeDriver.clearInputError = DriverError.badResponse(
            status: 422, body: StepExecutor.runnerEmptyRefusalPrefix + " (12 character(s) still there after 4 round(s))")
        let executor = StepExecutor(driver: primary, typeDriver: typeDriver, isAndroid: false, tunables: RunTunables())
        let outcome = await executor.execute(FlowStep(action: "clearInput", locator: FlowLocator(id: "field_search")))
        guard case .failed(let message) = outcome.status else { return XCTFail("\(outcome.status)") }
        XCTAssertTrue(message.contains("could not empty the field"), message)
        XCTAssertEqual(message.components(separatedBy: "still shows text (OCR)").count - 1, 1, message)
        XCTAssertEqual(checks.withLock { $0 }, 2)
    }

    /// 422 のあと木で欄が空に読めるとき(OCR の材料が無い)も、赤の文に確かめなかった理由を付ける
    func testRunnerEmptyRefusalWithEmptyTreeValueSaysWhyNotChecked() async {
        StepExecutor.clearResidualDrawnOverrideForTesting = { _ in (true, "bx") }
        defer { StepExecutor.clearResidualDrawnOverrideForTesting = nil }
        let primary = FakeAppDriver(name: "primary", log: CallLog(), snapshotElements: [[searchField(value: "", focused: true)]])
        primary.clearInputError = DriverError.badResponse(
            status: 422, body: StepExecutor.runnerEmptyRefusalPrefix + " (12 character(s) still there after 4 round(s))")
        let executor = StepExecutor(driver: primary, isAndroid: false, tunables: RunTunables())
        let outcome = await executor.execute(FlowStep(action: "clearInput", locator: FlowLocator(id: "field_search")))
        guard case .failed(let message) = outcome.status else { return XCTFail("\(outcome.status)") }
        XCTAssertTrue(message.contains("could not empty the field"), message)
        XCTAssertTrue(message.contains("not checked against the screen: the field's value reads as empty"), message)
    }
}
