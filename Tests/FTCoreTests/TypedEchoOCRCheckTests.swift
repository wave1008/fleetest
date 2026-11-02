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

    /// Flutter の欄は id が外側の `other` に付き、入力欄は同じ枠の子にある(`type("#field_number", …)` の形)。
    /// 外側のままだと入力欄の型でないので確認が掛からない = 同じ枠の入力欄で判定する
    func testOuterOtherIsJudgedByTheInputInTheSameFrame() {
        let outer = field("field_number", type: "other")
        let inner = ElementInfo(ref: 2, type: "textField", identifier: nil, label: nil, value: "xyz", placeholder: "数量",
                                enabled: true, frame: outer.frame, depth: 2)
        let judged = TypedEchoOCRCheck.judgedElement(outer, in: [outer, inner])
        XCTAssertEqual(judged.ref, 2)
        XCTAssertTrue(check(element: judged))
        XCTAssertFalse(check(element: outer), "外側の other のままなら確認しない")
        XCTAssertEqual(TypedEchoOCRCheck.judgedElement(outer, in: [outer]).ref, 1, "同じ枠の入力欄が無ければ対象のまま")
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

    private func snapshot(_ elements: [ElementInfo]) -> SnapshotResponse {
        SnapshotResponse(sessionBundleID: nil, screen: FTRect(x: 0, y: 0, width: 400, height: 800),
                         elements: elements, truncatedCount: 0, safeAreaTop: .unknown)
    }

    private func input(value: String, focused: Bool?, y: Double) -> ElementInfo {
        ElementInfo(ref: 1, type: "textField", identifier: "f", label: nil, value: value, placeholder: nil,
                    enabled: true, frame: FTRect(x: 0, y: y, width: 300, height: 56), depth: 1, focused: focused)
    }

    /// 打った後の木の、焦点のある欄で value が打った文字列のものの枠を使う(打つ前の位置ではない)
    func testTheCropFrameComesFromTheFocusedFieldAfterTyping() {
        let moved = input(value: "xyz", focused: true, y: 300)
        let frame = TypedEchoOCRCheck.typedFieldFrame(
            in: snapshot([input(value: "xyz", focused: false, y: 10), moved]), text: "xyz")
        XCTAssertEqual(frame?.y, 300)
    }

    /// 見つからなければ nil(確認をしない)
    func testNoFocusedFieldWithTheTypedValueMeansNoCheck() {
        XCTAssertNil(TypedEchoOCRCheck.typedFieldFrame(in: snapshot([input(value: "xyz", focused: false, y: 10)]), text: "xyz"))
        XCTAssertNil(TypedEchoOCRCheck.typedFieldFrame(in: snapshot([input(value: "abc", focused: true, y: 10)]), text: "xyz"))
        XCTAssertNil(TypedEchoOCRCheck.typedFieldFrame(in: snapshot([input(value: "xyz", focused: nil, y: 10)]), text: "xyz"))
    }

    func testTheTypePathCallsTheCheck() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let source = try String(contentsOf: root.appendingPathComponent("Sources/FTCore/StepExecutor+Actions.swift"), encoding: .utf8)
        // 打鍵の成功経路は2つ(typeDriver 経由と主経路)。どちらからも確認を呼ぶ
        XCTAssertEqual(source.components(separatedBy: "TypedEchoOCRCheck.shouldCheck(").count - 1, 2)
        XCTAssertEqual(source.components(separatedBy: "noteIfTypedTextNotDrawn(driver:").count - 1, 2)
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
