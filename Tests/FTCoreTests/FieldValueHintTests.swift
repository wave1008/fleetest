//: text 系の検証が、ラベルを持たず値だけを持つ入力欄に当たったときの失敗文の事実

import XCTest
@testable import FTCore

final class FieldValueHintTests: XCTestCase {
    private func field(type: String = "textField", label: String? = nil, value: String? = "hello123") -> ElementInfo {
        ElementInfo(ref: 1, type: type, identifier: "field_single", label: label, value: value, placeholder: nil,
                    enabled: true, frame: FTRect(x: 0, y: 0, width: 100, height: 40), depth: 1)
    }

    func testNamesTheValueOfALabellessField() {
        let hint = StepExecutor.fieldValueHint(assert: "textIs", element: field())
        XCTAssertTrue(hint.contains("\"hello123\""), hint)
        XCTAssertTrue(hint.contains("valueIs"), hint)
    }

    func testSilentWhenTheFieldHasALabel() {
        XCTAssertEqual(StepExecutor.fieldValueHint(assert: "textIs", element: field(label: "Name")), "")
    }

    func testSilentWithoutValueOrForNonInputsAndOtherAssertions() {
        XCTAssertEqual(StepExecutor.fieldValueHint(assert: "textIs", element: field(value: nil)), "")
        XCTAssertEqual(StepExecutor.fieldValueHint(assert: "textIs", element: field(value: "")), "")
        XCTAssertEqual(StepExecutor.fieldValueHint(assert: "textIs", element: field(type: "staticText")), "")
        XCTAssertEqual(StepExecutor.fieldValueHint(assert: "valueIs", element: field()), "")
        XCTAssertEqual(StepExecutor.fieldValueHint(assert: "idEquals", element: field()), "")
        XCTAssertEqual(StepExecutor.fieldValueHint(assert: "textIs", element: nil), "")
    }

    func testNeverEchoesAMaskedFieldValue() {
        XCTAssertEqual(StepExecutor.fieldValueHint(assert: "textIs",
                                                   element: field(type: "secureTextField", value: "••••")), "")
    }
}
