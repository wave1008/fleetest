// id を載せた非マージの包み(Flutter の Semantics)と、その中の唯一の入力欄: value* の読みは欄の値・覆いの注記は自分の欄を名指ししない
import XCTest
@testable import FTCore

final class EnclosedInputValueTests: XCTestCase {
    private let frame = FTRect(x: 16, y: 539, width: 370, height: 40)
    private let screen = FTRect(x: 0, y: 0, width: 402, height: 874)

    private func wrapper(value: String? = nil) -> ElementInfo {
        ElementInfo(ref: 1, type: "other", identifier: "field_first", label: nil, value: value, placeholder: nil,
                    enabled: true, frame: frame, depth: 1)
    }

    private func input(ref: Int, depth: Int) -> ElementInfo {
        ElementInfo(ref: ref, type: "textField", identifier: nil, label: "姓", value: "F", placeholder: nil,
                    enabled: true, frame: frame, depth: depth)
    }

    func testValueIsReadsTheSoleInputInsideTheWrapper() {
        for tree in [[wrapper(), input(ref: 2, depth: 2)], [wrapper(), input(ref: 2, depth: 1)]] {
            XCTAssertEqual(TypeReadback.assertedValue(of: tree[0], in: tree), "F")
        }
    }

    func testWrapperWithTwoInputsOrOwnValueIsNotRedirected() {
        let two = [wrapper(), input(ref: 2, depth: 2), input(ref: 3, depth: 2)]
        XCTAssertNil(TypeReadback.assertedValue(of: two[0], in: two))
        let own = wrapper(value: "mine")
        XCTAssertEqual(TypeReadback.assertedValue(of: own, in: [own, input(ref: 2, depth: 2)]), "mine")
    }

    func testCoveringHintNeverNamesItsOwnDescendantOrEnclosedInput() {
        for tree in [[wrapper(), input(ref: 2, depth: 2)], [wrapper(), input(ref: 2, depth: 1)]] {
            XCTAssertEqual(StepExecutor.coveringHint(element: tree[0], elements: tree, screen: screen), "")
        }
    }

    func testCoveringHintStillNamesARealCover() {
        let cover = ElementInfo(ref: 3, type: "other", identifier: "sheet", label: nil, value: nil, placeholder: nil,
                                enabled: true, frame: frame, depth: 0)
        let tree = [wrapper(), input(ref: 2, depth: 2), cover]
        XCTAssertTrue(StepExecutor.coveringHint(element: tree[0], elements: tree, screen: screen).contains("#sheet"))
    }
}
