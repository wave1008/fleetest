// occlusion-guard: 文字の型でない要素(行の clickable・ボタン)は、同じ label の文字の子をちょうど1つ持つとき
// その子で可視性を確かめる(OI-156)。親は切れて文字が消えていても枠の位置にインクがあるので足切りを通っていた。
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
    private func rowGuardOutcome(_ tree: [ElementInfo]) async -> (StepResult.Status, Int) {
        let primary = FakeAppDriver(name: "primary", log: CallLog(), snapshotElements: [tree],
                                    screenshots: [Self.inkedPNG])
        let delegate = FakeVisibilityDelegate(visible: false)
        let executor = StepExecutor(driver: primary, delegate: delegate, isAndroid: false, tunables: RunTunables())
        executor.noteAppLaunched()
        let step = FlowStep(assert: "textEquals", locator: FlowLocator(id: "row_01"),
                            expected: "行 01", timeout: 0, occlusionGuard: true)
        let outcome = await executor.execute(step)
        return (outcome.status, delegate.visibleCalls)
    }

    func testRowWithOneSameLabelTextChildIsVerifiedThroughTheChild() async {
        let (status, calls) = await rowGuardOutcome(rowTree(children: [("行 01", "staticText")]))
        XCTAssertGreaterThan(calls, 0, "子の文字を縁の判定つきで読ませるはず")
        guard case .failed = status else { XCTFail("読めない文字は赤のはず: \(status)"); return }
    }

    func testRowWithoutTextChildStaysPassThrough() async {
        let (status, calls) = await rowGuardOutcome(rowTree(children: []))
        XCTAssertEqual(calls, 0)
        guard case .passed = status else { XCTFail("\(status)"); return }
    }

    func testRowWithTwoSameLabelTextChildrenStaysPassThrough() async {
        let (_, calls) = await rowGuardOutcome(rowTree(children: [("行 01", "staticText"), ("行 01", "staticText")]))
        XCTAssertEqual(calls, 0)
    }

    func testRowWithDifferentLabelChildStaysPassThrough() async {
        let (_, calls) = await rowGuardOutcome(rowTree(children: [("別の文字", "staticText")]))
        XCTAssertEqual(calls, 0)
    }

    func testRowWithSameLabelNonTextChildStaysPassThrough() async {
        let (_, calls) = await rowGuardOutcome(rowTree(children: [("行 01", "image")]))
        XCTAssertEqual(calls, 0)
    }

    /// 縁の判定は子に対して効く: スクロール容器でなければ子はインクで素通り
    func testChildAwayFromAScrollEdgeIsStillPassedByInk() async {
        let (status, calls) = await rowGuardOutcome(rowTree(children: [("行 01", "staticText")], scrollable: false))
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
