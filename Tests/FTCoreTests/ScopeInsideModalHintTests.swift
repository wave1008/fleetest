// 61周目 im4 F1: スコープが手前のモーダル自身(`.alert >> …`)のとき、「モーダルを閉じてから」「裏に居るだけかも」と言わない
// (従うと容器ごと消えて必ず赤)。モーダルの外のスコープ・モーダルの申告が無い木は従来どおり。

import XCTest
@testable import FTCore

final class ScopeInsideModalHintTests: XCTestCase {
    private func el(_ ref: Int, _ type: String, _ id: String?, _ frame: FTRect, depth: Int) -> ElementInfo {
        ElementInfo(ref: ref, type: type, identifier: id, label: nil, value: nil, placeholder: nil,
                    enabled: true, frame: frame, depth: depth)
    }

    private func snapshot(modal: Bool = true) -> SnapshotResponse {
        let alertFrame = FTRect(x: 41, y: 388, width: 320, height: 126)
        let elements = [
            el(1, "alert", "dlg", alertFrame, depth: 0),
            el(2, "button", "btn_ok", FTRect(x: 60, y: 460, width: 100, height: 40), depth: 1),
            el(3, "list", "bg_list", FTRect(x: 0, y: 0, width: 402, height: 300), depth: 0),
        ]
        return SnapshotResponse(sessionBundleID: "app", screen: FTRect(x: 0, y: 0, width: 402, height: 874),
                                elements: elements, truncatedCount: 0,
                                modalScope: modal ? ModalScopeCover(droppedCount: 4, frames: [alertFrame]) : nil)
    }

    private func step(_ selector: String) -> FlowStep {
        FlowStep(assert: "exists", locator: FTSelector.parse(selector).primary)
    }

    func testScopeInsideModalIsDetectedWithoutNamingTypes() {
        XCTAssertTrue(StepExecutor.scopeContainerIsInModal(step("#dlg >> #btn_behind"), snapshot()))
        XCTAssertTrue(StepExecutor.scopeContainerIsInModal(step(".alert >> #btn_behind"), snapshot()))
    }

    func testScopeOutsideModalOrWithoutReportIsNotInModal() {
        XCTAssertFalse(StepExecutor.scopeContainerIsInModal(step("#bg_list >> #x"), snapshot()))
        XCTAssertFalse(StepExecutor.scopeContainerIsInModal(step("#dlg >> #x"), snapshot(modal: false)))
        XCTAssertFalse(StepExecutor.scopeContainerIsInModal(step("#btn_behind"), snapshot()))
        XCTAssertFalse(StepExecutor.scopeContainerIsInModal(step("#missing >> #x"), snapshot()))
    }

    func testHintDoesNotTellToCloseTheModal() throws {
        let hint = try XCTUnwrap(StepExecutor.scopeIsTheModalHint(step("#dlg >> #btn_behind"), snapshot()))
        XCTAssertTrue(hint.contains("the modal in front of the screen itself"))
        XCTAssertFalse(hint.contains("close the modal (dismiss"))
        XCTAssertNil(StepExecutor.scopeIsTheModalHint(step("#bg_list >> #x"), snapshot()))
    }
}
