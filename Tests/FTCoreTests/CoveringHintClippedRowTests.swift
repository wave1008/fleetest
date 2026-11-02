// OI-151①: 容器の外へはみ出して描かれていない行に「覆われている」と言わない

import XCTest
@testable import FTCore

final class CoveringHintClippedRowTests: XCTestCase {
    private func el(_ ref: Int, _ type: String, id: String, y: Double, h: Double,
                    scrollable: Bool? = nil, depth: Int = 1) -> ElementInfo {
        ElementInfo(ref: ref, type: type, identifier: id, label: id, value: nil, placeholder: nil, enabled: true,
                    frame: FTRect(x: 0, y: y, width: 400, height: h), depth: depth, scrollable: scrollable)
    }

    private func tree(rowY: Double) -> [ElementInfo] {
        [el(1, "scrollView", id: "list", y: 100, h: 300, scrollable: true),
         el(2, "staticText", id: "row_9", y: rowY, h: 40, depth: 2),
         el(3, "button", id: "echo_bar", y: 340, h: 160)]
    }

    private let screen = FTRect(x: 0, y: 0, width: 400, height: 800)

    func testNoCoveredClaimForARowPushedOutOfItsContainer() {
        let elements = tree(rowY: 420)   // 容器は 100..400。行は丸ごと外
        let hint = StepExecutor.coveringHint(element: elements[1], elements: elements, screen: screen)
        XCTAssertEqual(hint, "")
    }

    func testStillCoveredClaimForARowInsideItsContainer() {
        let elements = tree(rowY: 350)   // 容器の内側
        let hint = StepExecutor.coveringHint(element: elements[1], elements: elements, screen: screen)
        XCTAssertTrue(hint.contains("covered by"), hint)
    }
}
