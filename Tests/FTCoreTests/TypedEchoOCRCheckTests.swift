// OI-40: 読み返しの後の OCR 確認の対象を絞る門(費用が通常の入力に広がらない・OCR オフでは何もしない)

import XCTest
@testable import FTCore

final class TypedEchoOCRCheckTests: XCTestCase {
    private func field(_ id: String, type: String = "textField") -> ElementInfo {
        ElementInfo(ref: 1, type: type, identifier: id, label: nil, value: "xyz", placeholder: nil,
                    enabled: true, frame: FTRect(x: 0, y: 0, width: 300, height: 56), depth: 1)
    }

    private func check(framework: AppUIFramework? = .flutter, ocr: RegionTextGateMode = .on, replace: Bool = true,
                       text: String = "xyz", element: ElementInfo? = nil) -> Bool {
        TypedEchoOCRCheck.shouldCheck(framework: framework, ocrMode: ocr, replace: replace, text: text,
                                      element: element ?? field("field_number"), locator: nil)
    }

    func testChecksFlutterNumericNamedFieldWithOCROn() {
        XCTAssertTrue(check())
    }

    func testNameIsMatchedByWordNotSubstring() {
        for name in ["phoneNumber", "field_number", "Zip code", "user-age", "PIN"] {
            XCTAssertTrue(TypedEchoOCRCheck.hasNumericName(name), name)
        }
        for name in ["message", "homepage", "shipping_address", "hotel", "typingField"] {
            XCTAssertFalse(TypedEchoOCRCheck.hasNumericName(name), name)
        }
        XCTAssertTrue(TypedEchoOCRCheck.hasNumericName("電話番号"))
    }

    func testScopeIdOfTheWrittenSelectorCountsAsTheName() {
        let inner = ElementInfo(ref: 1, type: "textField", identifier: nil, label: nil, value: "xyz", placeholder: nil,
                                enabled: true, frame: FTRect(x: 0, y: 0, width: 300, height: 56), depth: 2)
        let scoped = FlowLocator(type: "textField", scope: [FlowLocator(id: "field_number")])
        XCTAssertTrue(TypedEchoOCRCheck.shouldCheck(framework: .flutter, ocrMode: .on, replace: true, text: "xyz",
                                                    element: inner, locator: scoped))
        XCTAssertFalse(TypedEchoOCRCheck.shouldCheck(framework: .flutter, ocrMode: .on, replace: true, text: "xyz",
                                                     element: inner, locator: nil))
    }

    func testTheTypePathCallsTheCheck() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let source = try String(contentsOf: root.appendingPathComponent("Sources/FTCore/StepExecutor+Actions.swift"), encoding: .utf8)
        // 打鍵の成功経路は2つ(typeDriver 経由と主経路)。どちらからも確認を呼ぶ
        XCTAssertEqual(source.components(separatedBy: "TypedEchoOCRCheck.shouldCheck(").count - 1, 2)
        XCTAssertEqual(source.components(separatedBy: "noteIfTypedTextNotDrawn(element:").count - 1, 2)
    }

    func testNeverRunsWhenOCRIsOffOrMeasure() {
        XCTAssertFalse(check(ocr: .off))
        XCTAssertFalse(check(ocr: .measure))
    }

    func testSkipsOtherFrameworksUnknownAndNonReplace() {
        XCTAssertFalse(check(framework: .compose))
        XCTAssertFalse(check(framework: nil))
        XCTAssertFalse(check(replace: false))
    }

    func testSkipsOrdinaryFieldsAndDigitOnlyText() {
        XCTAssertFalse(check(element: field("field_first")), "名前が数字系でない通常の入力に OCR を広げない")
        XCTAssertFalse(check(text: "12345"))
        XCTAssertFalse(check(element: field("field_number", type: "secureTextField")))
        XCTAssertFalse(check(element: field("field_number", type: "button")))
    }
}
