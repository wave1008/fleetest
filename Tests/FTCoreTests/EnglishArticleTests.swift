// 実行時の名詞の不定冠詞。破ると: 「the target is a other」と崩れる(探索 11/27 alocal F1)/ 子音の型に an を付ける
import XCTest
@testable import FTCore

final class EnglishArticleTests: XCTestCase {
    func testVowelInitialNounsTakeAn() {
        XCTAssertEqual(EnglishArticle.indefinite("other"), "an other")
        XCTAssertEqual(EnglishArticle.indefinite("image"), "an image")
        XCTAssertEqual(EnglishArticle.indefinite("Alert"), "an Alert")
    }

    func testConsonantInitialAndEmptyNounsTakeA() {
        XCTAssertEqual(EnglishArticle.indefinite("button"), "a button")
        XCTAssertEqual(EnglishArticle.indefinite("staticText"), "a staticText")
        XCTAssertEqual(EnglishArticle.indefinite(""), "a ")
    }

    /// 呼び手の文が冠詞を通す(容器への type の注記)
    func testNonInputTypeNoteUsesTheArticle() {
        let target = ElementInfo(ref: 1, type: "other", identifier: "field_prompt", label: nil, value: nil, placeholder: nil,
                                 enabled: true, frame: FTRect(x: 0, y: 0, width: 100, height: 40), depth: 1)
        let field = ElementInfo(ref: 2, type: "textField", identifier: nil, label: nil, value: nil, placeholder: nil,
                                enabled: true, frame: FTRect(x: 0, y: 0, width: 100, height: 40), depth: 2)
        let note = TapTargetGeometry.nonInputTypeTargetNote(target, in: [target, field])
        XCTAssertTrue(note?.contains("the target is an other, not a text field") ?? false, note ?? "nil")
    }
}
