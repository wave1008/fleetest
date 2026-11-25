import XCTest
@testable import FTCore

/// 「画面を変えなかった前のタップ」の名指しは、失敗側の木がそのタップの時点の木と同じときだけ。
/// 遅れて効いた(その後に木が変わった)タップは、別 scene の失敗にまで挙げ続けない
final class OI393UnchangedTapEvidenceTests: XCTestCase {

    private func el(_ id: String, ref: Int) -> ElementInfo {
        ElementInfo(ref: ref, type: "button", identifier: id, label: id, value: nil, placeholder: nil,
                    enabled: true, frame: FTRect(x: 10, y: Double(ref) * 50, width: 100, height: 40), depth: 0)
    }

    private func snapshot(_ elements: [ElementInfo]) -> SnapshotResponse {
        SnapshotResponse(sessionBundleID: nil, screen: FTRect(x: 0, y: 0, width: 400, height: 800),
                         elements: elements, truncatedCount: 0)
    }

    /// tap A(無変化)→ tap B が A の時点と同じ木で解決 = A は無変化と確定済みの状態を作る
    private func executorWithUnchangedTapA() -> (StepExecutor, [ElementInfo]) {
        let executor = StepExecutor(driver: FakeAppDriver(name: "p", log: CallLog()), isAndroid: false, tunables: RunTunables())
        let tree = [el("btn_a", ref: 1), el("btn_b", ref: 2)]
        let stepA = FlowStep(action: "tap", locator: FlowLocator(id: "btn_a"))
        let stepB = FlowStep(action: "tap", locator: FlowLocator(id: "btn_b"))
        executor.recordInteraction(step: stepA, element: tree[0], in: snapshot(tree))
        executor.tapAwaitingNextTree = executor.lastInteraction   // executeAction の入口が行う持ち越し
        executor.recordInteraction(step: stepB, element: tree[1], in: snapshot(tree))
        XCTAssertEqual(executor.unchangedEarlierTaps.count, 1, "前提: A が無変化と確定している")
        return (executor, tree)
    }

    func testEarlierTapIsNamedWhileTheFailureTreeIsStillTheSame() {
        let (executor, tree) = executorWithUnchangedTapA()
        let hint = executor.tapDiagnosisHint(tree)
        XCTAssertTrue(hint.contains("earlier, the screen was also unchanged"), hint)
        XCTAssertTrue(executor.noteCodesThisStep.contains(.unchangedTapBeforeFailure))
    }

    /// 後で画面が変わっていた(モーダルが湧いた)なら、その tap は外す
    func testEarlierTapIsDroppedOnceALaterTreeHasChanged() {
        let (executor, tree) = executorWithUnchangedTapA()
        let later = tree + [el("modal_title", ref: 3)]
        let hint = executor.tapDiagnosisHint(later)
        XCTAssertFalse(hint.contains("earlier, the screen"), hint)
        XCTAssertFalse(executor.noteCodesThisStep.contains(.unchangedTapBeforeFailure), "\(executor.noteCodesThisStep)")
    }

    /// 木が渡されなければ比べられない = 外さない(材料の無い所で消さない)
    func testEarlierTapIsKeptWhenThereIsNoTreeToCompare() {
        let (executor, _) = executorWithUnchangedTapA()
        XCTAssertTrue(executor.tapDiagnosisHint(nil).contains("earlier, the screen was also unchanged"))
    }

    /// 解決できなかった失敗側(unresolvedActionTapHint)も同じ規則
    func testUnresolvedActionHintAppliesTheSameRule() {
        let (executor, tree) = executorWithUnchangedTapA()
        executor.tapEvidenceAtEntry = (pending: nil, earlier: executor.unchangedEarlierTaps)
        XCTAssertFalse(executor.unresolvedActionTapHint(tree + [el("modal_title", ref: 3)]).contains("unchanged between"))
        XCTAssertTrue(executor.unresolvedActionTapHint(tree).contains("unchanged between"))
    }

    /// 同じ呼び名の tap が2回無変化になっても、署名は1件ずつ持つ(呼び名の辞書だと後の1件が前を上書きして、前の署名が消える)
    func testSameDescriptionTwiceKeepsEachSignature() {
        let executor = StepExecutor(driver: FakeAppDriver(name: "p", log: CallLog()), isAndroid: false, tunables: RunTunables())
        let treeA = [el("btn_a", ref: 1), el("btn_b", ref: 2)]
        let treeB = treeA + [el("other", ref: 3)]
        let step = FlowStep(action: "tap", locator: FlowLocator(id: "btn_a"))
        for tree in [treeA, treeB] {
            executor.recordInteraction(step: step, element: tree[0], in: snapshot(tree))
            executor.tapAwaitingNextTree = executor.lastInteraction
            executor.recordInteraction(step: step, element: tree[0], in: snapshot(tree))
        }
        XCTAssertEqual(executor.unchangedEarlierTaps.count, 2)
        XCTAssertEqual(executor.unchangedEarlierTaps[0].description, executor.unchangedEarlierTaps[1].description)
        XCTAssertNotEqual(executor.unchangedEarlierTaps[0].signature, executor.unchangedEarlierTaps[1].signature)
        XCTAssertEqual(executor.stillUnchangedEarlierTaps(executor.unchangedEarlierTaps, at: treeB).count, 1,
                       "treeB の署名の1件だけが今の木と同じ")
    }
}
