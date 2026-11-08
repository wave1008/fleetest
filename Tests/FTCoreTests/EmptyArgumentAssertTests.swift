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
}
