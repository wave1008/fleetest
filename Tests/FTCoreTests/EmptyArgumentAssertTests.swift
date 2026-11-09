import XCTest
@testable import FTCore

/// 空の文字列の引数が黙って緑にならないこと(41周目 iultra F1・F3)
final class EmptyArgumentAssertTests: XCTestCase {
    /// 空の期待値は「含む」(StartsWith / EndsWith と同じ向き)= textContainsNot("") は赤になる
    func testEmptyExpectationIsContained() {
        for assert in ["textContains", "valueContains", "textStartsWith", "textEndsWith"] {
            XCTAssertNotNil(LocatorResolver.matchedText("abc", expected: "", assert: assert), assert)
        }
        XCTAssertNil(LocatorResolver.matchedText("abc", expected: "x", assert: "textContains"))
    }

    /// 空のセレクタは text="" に解かれて notExist("") が緑になる = 実行前に断る(`#` 単独と同じ)
    func testEmptySelectorIsRefused() {
        XCTAssertNotNil(FTSelector.validationError(""))
        XCTAssertNotNil(FTSelector.validationError("   "))
        XCTAssertNil(FTSelector.validationError("OK"))
        XCTAssertNil(FTSelector.validationError("#btn_ok"))
    }

    /// `=` の後が空のラベルも断る(43周目 im4 F2・iultra F1: notExist("=") が緑)。`=` で始まる中身のあるラベルは通す
    func testEmptyEscapedLabelIsRefused() {
        XCTAssertNotNil(FTSelector.validationError("="))
        XCTAssertNotNil(FTSelector.validationError("= "))
        XCTAssertNotNil(FTSelector.validationError("#nope||="))
        XCTAssertNil(FTSelector.validationError("=smile :)"))
    }

    /// 空白だけの部分一致・スコープの後ろの空のラベルも断る(44周目)
    func testWhitespaceOnlyPartialAndScopedEmptyLabelAreRefused() {
        XCTAssertNotNil(FTSelector.validationError("* *"))
        XCTAssertNotNil(FTSelector.validationError("*  *"))
        XCTAssertNotNil(FTSelector.validationError("#field_single>>="))
        XCTAssertNil(FTSelector.validationError("*a b*"))
        XCTAssertNil(FTSelector.validationError("#field_single>>=OK"))
    }

    /// 改行だけの値・ラベル・節も空(44周目 im4 F2: `#\n`・`text=\n`・`#a>>\n` が緑)
    func testNewlineOnlyValuesAreEmpty() {
        for bad in ["#\n", "text=\n", "value=\r\n", "#a>>\n", "#nope||#\n", "=\n", "*\u{200B}*", "#\u{3000}", "text=\u{00A0}",
                    "=\u{FEFF}", "(a|\u{200B})"] {
            XCTAssertNotNil(FTSelector.validationError(bad), bad.debugDescription)
        }
    }

    func testEmptyExpectationNegatedFormIsRed() {
        for assert in ["textContainsNot", "valueContainsNot"] {
            XCTAssertFalse(LocatorResolver.negativeAssertSatisfied(assert, actual: "abc", expected: ""), assert)
            XCTAssertFalse(LocatorResolver.negativeAssertSatisfied(assert, actual: "", expected: ""), assert)
            XCTAssertTrue(LocatorResolver.negativeAssertSatisfied(assert, actual: "abc", expected: "x"), assert)
        }
    }

    func testNewlineOnlySelectorAndEmptyAlternativesAreRefused() {
        for text in ["\n", "\r\n", "||", " || ", "#nav_input||", "||#a"] {
            XCTAssertNotNil(FTSelector.validationError(text), text)
        }
        // 改行・空白だけは「選択肢が空」ではなく「セレクタが空」と言う
        XCTAssertEqual(FTSelector.validationError(" \t\n "), "the selector is empty")
        XCTAssertTrue(FTSelector.validationError("#a||")?.contains("alternative 2 of 2") ?? false)
        XCTAssertNil(FTSelector.validationError("#a||OK"))
        XCTAssertNil(FTSelector.validationError("=||"))
    }

    func testOrdinalWithoutTypeIsRefused() {
        XCTAssertTrue(FTSelector.validationError(".[1]")?.contains("type name is missing") ?? false)
        XCTAssertNil(FTSelector.validationError(".button[1]"))
    }
}
