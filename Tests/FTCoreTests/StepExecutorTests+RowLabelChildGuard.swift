// occlusion-guard: 文字の型でない要素(行の clickable・ボタン)は、同じ label の文字の子をちょうど1つ持つとき
// その子で可視性を確かめる。親は切れて文字が消えていても枠の位置にインクがあるので足切りを通っていた。
import XCTest
@testable import FTCore

extension StepExecutorTests {

    private func rowTree(children: [(label: String, type: String)], scrollable: Bool = true) -> [ElementInfo] {
        var pane = ElementInfo(ref: 0, type: "scrollView", identifier: "pane", label: nil, value: nil,
                               placeholder: nil, enabled: true,
                               frame: FTRect(x: 0, y: 0, width: 100, height: 40), depth: 0)
        pane.scrollable = scrollable
        let row = ElementInfo(ref: 1, type: "clickable", identifier: "row_01", label: "行 01", value: nil,
                              placeholder: nil, enabled: true,
                              frame: FTRect(x: 0, y: 0, width: 100, height: 20), depth: 1)
        var tree = [pane, row]
        for (i, c) in children.enumerated() {
            tree.append(ElementInfo(ref: 2 + i, type: c.type, identifier: nil, label: c.label, value: nil,
                                    placeholder: nil, enabled: true,
                                    frame: FTRect(x: 0, y: 0, width: 100, height: 20), depth: 2))
        }
        return tree
    }

    /// 行を textEquals で確かめたときの判定と、可視性の段(FM)へ回った回数
    private func rowGuardOutcome(_ tree: [ElementInfo], isAndroid: Bool = false,
                                 rowType: String = "clickable") async -> (StepResult.Status, Int, [StepNote]) {
        var tree = tree
        tree[1].type = rowType
        let primary = FakeAppDriver(name: "primary", log: CallLog(), snapshotElements: [tree],
                                    screenshots: [Self.inkedPNG])
        let delegate = FakeVisibilityDelegate(visible: false)
        let executor = StepExecutor(driver: primary, delegate: delegate, isAndroid: isAndroid, tunables: RunTunables())
        executor.noteAppLaunched()
        let step = FlowStep(assert: "textEquals", locator: FlowLocator(id: "row_01"),
                            expected: "行 01", timeout: 0, occlusionGuard: true)
        let outcome = await executor.execute(step)
        return (outcome.status, delegate.visibleCalls, outcome.notes)
    }

    func testRowWithOneSameLabelTextChildIsVerifiedThroughTheChild() async {
        let (status, calls, _) = await rowGuardOutcome(rowTree(children: [("行 01", "staticText")]))
        XCTAssertGreaterThan(calls, 0, "子の文字を縁の判定つきで読ませるはず")
        guard case .failed = status else { XCTFail("読めない文字は赤のはず: \(status)"); return }
    }

    /// 文字の子の無い iOS の行は枠で読ませるが、見えていないと判定しても赤にせず警告にする
    func testRowWithoutTextChildIsReadButOnlyWarns() async {
        let (status, calls, notes) = await rowGuardOutcome(rowTree(children: []))
        XCTAssertGreaterThan(calls, 0, "行の枠で読ませるはず")
        guard case .passed = status else { XCTFail("警告にとどめるはず: \(status)"); return }
        XCTAssertTrue(notes.contains(.rowLabelNotRead))
    }

    func testRowWithoutTextChildThatIsVisibleHasNoWarning() async {
        let primary = FakeAppDriver(name: "primary", log: CallLog(), snapshotElements: [rowTree(children: [])],
                                    screenshots: [Self.inkedPNG])
        let delegate = FakeVisibilityDelegate(visible: true)
        let executor = StepExecutor(driver: primary, delegate: delegate, isAndroid: false, tunables: RunTunables())
        executor.noteAppLaunched()
        let outcome = await executor.execute(FlowStep(assert: "textEquals", locator: FlowLocator(id: "row_01"),
                                                      expected: "行 01", timeout: 0, occlusionGuard: true))
        XCTAssertGreaterThan(delegate.visibleCalls, 0)
        XCTAssertFalse(outcome.notes.contains(.rowLabelNotRead))
    }

    /// cell 型(XCUITest 経由)も行。ボタンは描かれない a11y ラベルを持つので対象外
    func testCellRowIsReadAndButtonIsNot() async {
        let (_, cellCalls, _) = await rowGuardOutcome(rowTree(children: []), rowType: "cell")
        XCTAssertGreaterThan(cellCalls, 0)
        let (status, buttonCalls, notes) = await rowGuardOutcome(rowTree(children: []), rowType: "button")
        XCTAssertEqual(buttonCalls, 0)
        guard case .passed = status else { XCTFail("\(status)"); return }
        XCTAssertFalse(notes.contains(.rowLabelNotRead))
    }

    /// Android は従来どおり(文字の子の無い行へ広げない)
    func testAndroidRowWithoutTextChildStaysPassThrough() async {
        let (_, calls, notes) = await rowGuardOutcome(rowTree(children: []), isAndroid: true)
        XCTAssertEqual(calls, 0)
        XCTAssertFalse(notes.contains(.rowLabelNotRead))
    }

    /// 文字の子があるときは従来どおりその子で確かめて赤(警告にしない)
    func testRowWithTextChildStillFailsRedAndHasNoRowWarning() async {
        let (status, _, notes) = await rowGuardOutcome(rowTree(children: [("行 01", "staticText")]))
        guard case .failed = status else { XCTFail("\(status)"); return }
        XCTAssertFalse(notes.contains(.rowLabelNotRead))
    }

    func testLabelledRowRuleIsPure() {
        let bare = rowTree(children: [])
        XCTAssertTrue(OcclusionEligibility.isLabelledRowWithoutText(bare[1], expectedText: "行 01", in: bare))
        XCTAssertFalse(OcclusionEligibility.isLabelledRowWithoutText(bare[1], expectedText: "別", in: bare))
        let withOtherText = rowTree(children: [("別の文字", "staticText")])
        XCTAssertFalse(OcclusionEligibility.isLabelledRowWithoutText(withOtherText[1], expectedText: "行 01", in: withOtherText))
    }

    func testRowWithTwoSameLabelTextChildrenStaysPassThrough() async {
        let (_, calls, _) = await rowGuardOutcome(rowTree(children: [("行 01", "staticText"), ("行 01", "staticText")]))
        XCTAssertEqual(calls, 0)
    }

    func testRowWithDifferentLabelChildStaysPassThrough() async {
        let (_, calls, _) = await rowGuardOutcome(rowTree(children: [("別の文字", "staticText")]))
        XCTAssertEqual(calls, 0)
    }

    func testRowWithSameLabelNonTextChildStaysPassThrough() async {
        let (_, calls, _) = await rowGuardOutcome(rowTree(children: [("行 01", "image")]))
        XCTAssertEqual(calls, 0)
    }

    /// 縁の判定は子に対して効く: スクロール容器でなければ子はインクで素通り
    func testChildAwayFromAScrollEdgeIsStillPassedByInk() async {
        let (status, calls, _) = await rowGuardOutcome(rowTree(children: [("行 01", "staticText")], scrollable: false))
        XCTAssertEqual(calls, 0)
        guard case .passed = status else { XCTFail("\(status)"); return }
    }

    func testSameLabelTextDescendantIsTheSharedPureRule() {
        let tree = rowTree(children: [("行 01", "staticText")])
        XCTAssertEqual(OcclusionEligibility.sameLabelTextDescendant(
            of: tree[1], expectedText: "行 01", isUserText: true, in: tree)?.ref, 2)
        XCTAssertNil(OcclusionEligibility.sameLabelTextDescendant(
            of: tree[2], expectedText: "行 01", isUserText: true, in: tree), "文字の型自身は対象外")
    }
}
