//: 容器の外へはみ出して描かれていない行に「覆われている」と言わない

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
        let hint = StepExecutor.coveringHint(element: elements[1], elements: elements, screen: screen, isAndroid: false, framework: nil)
        XCTAssertEqual(hint, "")
    }

    func testStillCoveredClaimForARowInsideItsContainer() {
        let elements = tree(rowY: 350)   // 容器の内側
        let hint = StepExecutor.coveringHint(element: elements[1], elements: elements, screen: screen, isAndroid: false, framework: nil)
        XCTAssertTrue(hint.contains("covered by"), hint)
    }

    /// 検証の失敗文は何も撃っていないので「操作が吸われた」と言わない(事実は覆っている要素の名指しだけ)
    func testHintDoesNotClaimAnInteractionWasSwallowed() {
        let elements = tree(rowY: 350)
        let hint = StepExecutor.coveringHint(element: elements[1], elements: elements, screen: screen, isAndroid: false, framework: nil)
        XCTAssertFalse(hint.contains("swallowed"), hint)
    }

    /// Android の Flutter の同じウィンドウでは覆いを名指さない(括弧書き全体を出さない)。疑いの判定は変えず、抑止を報告する
    func testHintOmittedForFlutterButNotForOtherApps() {
        let elements = tree(rowY: 350)
        let flutter = StepExecutor.coveringHintResult(element: elements[1], elements: elements, screen: screen,
                                                      isAndroid: true, framework: .flutter)
        XCTAssertEqual(flutter.hint, "")
        XCTAssertTrue(flutter.namingSuppressed)
        for (isAndroid, fw) in [(true, AppUIFramework.compose), (true, nil), (false, .flutter)] as [(Bool, AppUIFramework?)] {
            let r = StepExecutor.coveringHintResult(element: elements[1], elements: elements, screen: screen,
                                                    isAndroid: isAndroid, framework: fw)
            XCTAssertTrue(r.hint.contains("covered by"), r.hint)
            XCTAssertFalse(r.namingSuppressed)
        }
    }
}
