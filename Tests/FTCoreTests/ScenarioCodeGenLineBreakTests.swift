// 生成する .swift へ CRLF / CR が素通りしない。"\r\n" は Swift では1つの Character なので、
// "\n" だけを見る switch / replacingOccurrences では当たらず、文字列リテラルが壊れコメントの残りがコードになる。

import FTCore
import XCTest

final class ScenarioCodeGenLineBreakTests: XCTestCase {

    func testLiteralEscapesCRLFAndCR() {
        XCTAssertEqual(ScenarioCodeGen.literal("a\r\nb"), "\"a\\r\\nb\"")
        XCTAssertEqual(ScenarioCodeGen.literal("a\rb"), "\"a\\rb\"")
        XCTAssertEqual(ScenarioCodeGen.literal("a\nb"), "\"a\\nb\"")
    }

    func testSingleLineRemovesEveryLineBreakForm() {
        let out = ScenarioCodeGen.singleLine("a\r\nb\nc\rd")
        XCTAssertFalse(out.contains("\r"))
        XCTAssertFalse(out.contains("\n"))
        XCTAssertEqual(out, "a b c d")
    }
}
