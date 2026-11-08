import XCTest
@testable import FTCore

/// clearInput が消え残りと読んだ値が欄に描かれているかの判定(純粋関数)と、StepExecutor への配線
final class ClearResidualDrawnTests: XCTestCase {
    private let residual = "検索候補は次のとおりです"

    // MARK: - 判定

    func testPlaceholderLineIsNotTheResidual() {
        // プレースホルダ "検索" は残りの先頭と一致する。木が言う文字として除かないと drawn になる
        XCTAssertEqual(ClearResidualDrawn.judge(residual: residual, ocrLines: ["検索"], treeTexts: ["検索, 検索", "検索"]),
                       .notDrawn)
    }

    func testNothingDrawnIsNotDrawn() {
        XCTAssertEqual(ClearResidualDrawn.judge(residual: residual, ocrLines: [], treeTexts: ["検索"]), .notDrawn)
    }

    func testUnrelatedLineIsNotDrawn() {
        XCTAssertEqual(ClearResidualDrawn.judge(residual: residual, ocrLines: ["候補A"], treeTexts: []), .notDrawn)
    }

    func testWholeResidualReadIsDrawn() {
        XCTAssertEqual(ClearResidualDrawn.judge(residual: residual, ocrLines: ["検索候補は次のとおりです"], treeTexts: ["検索"]),
                       .drawn)
    }

    /// 残りの値の前に別の文字(虫眼鏡のアイコンの誤読など)が同じ行に読まれても描かれている
    func testResidualInsideALongerLineIsDrawn() {
        XCTAssertEqual(ClearResidualDrawn.judge(residual: residual, ocrLines: ["Q 検索候補は次のとおりです"], treeTexts: ["検索"]), .drawn)
    }

    func testPartlyDrawnLongValueIsDrawn() {
        // 欄の幅で切れて先頭だけ描かれている本物の消え残り
        let long = "the quick brown fox jumps over the lazy dog"
        XCTAssertEqual(ClearResidualDrawn.judge(residual: long, ocrLines: ["the quick brown"], treeTexts: []), .drawn)
    }

    func testWhitespaceIsIgnoredWhenMatchingTreeTexts() {
        XCTAssertEqual(ClearResidualDrawn.judge(residual: residual, ocrLines: [" 検 索 "], treeTexts: ["検索"]), .notDrawn)
    }

    func testTreeTextsCollectLabelPartsPlaceholderAndInnerStaticText() {
        let field = ElementInfo(ref: 1, type: "textView", identifier: "field_search", label: "検索, 検索候補",
                                value: residual, placeholder: "ph", enabled: true,
                                frame: FTRect(x: 0, y: 0, width: 300, height: 40), depth: 0)
        let inner = ElementInfo(ref: 2, type: "staticText", identifier: nil, label: "inner", value: nil, placeholder: nil,
                                enabled: true, frame: FTRect(x: 10, y: 10, width: 50, height: 20), depth: 1)
        let outer = ElementInfo(ref: 3, type: "staticText", identifier: nil, label: "outer", value: nil, placeholder: nil,
                                enabled: true, frame: FTRect(x: 10, y: 200, width: 50, height: 20), depth: 1)
        let texts = ClearResidualDrawn.treeTexts(field: field, in: [field, inner, outer])
        XCTAssertEqual(Set(texts), ["検索, 検索候補", "検索", "検索候補", "ph", "inner"])
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
        StepExecutor.clearResidualDrawnOverrideForTesting = { _ in (drawn, drawn == nil ? "OCR was unavailable" : nil) }
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
        XCTAssertEqual(message, "clearInput reported success but the value remained: \"\(residual)\"")
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
    }
}
