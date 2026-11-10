import XCTest
@testable import FTCore

/// XCTest の木が value を 512 UTF-16 単位で切る形(TypeReadback.valueCutAtXCTestLimit)。追送すると二重入力になる
final class TypeReadbackXCTestValueLimitTests: XCTestCase {

    func testValueCutAtTheLimitIsRecognisedForAsciiAndForSurrogatePairs() {
        let ascii = String(repeating: "k", count: 600)
        XCTAssertTrue(TypeReadback.valueCutAtXCTestLimit(expected: ascii, actual: String(ascii.prefix(512))))
        let emoji = String(repeating: "🙂", count: 300)
        XCTAssertTrue(TypeReadback.valueCutAtXCTestLimit(expected: emoji, actual: String(emoji.prefix(256))))
    }

    func testRealDropsAreNotTakenForTheCut() {
        let ascii = String(repeating: "k", count: 600)
        // 上限より短い欠け = 本物の取りこぼし
        XCTAssertFalse(TypeReadback.valueCutAtXCTestLimit(expected: ascii, actual: String(ascii.prefix(511))))
        // 目標が上限以下なら切れは起きない
        let short = String(repeating: "k", count: 512)
        XCTAssertFalse(TypeReadback.valueCutAtXCTestLimit(expected: short + "", actual: short))
        // 先頭が一致しない
        XCTAssertFalse(TypeReadback.valueCutAtXCTestLimit(expected: ascii, actual: String(repeating: "j", count: 512)))
        // 上限で割れたサロゲート(255 個 + 1 単位)は一致しない
        let emoji = String(repeating: "🙂", count: 300)
        XCTAssertFalse(TypeReadback.valueCutAtXCTestLimit(expected: emoji, actual: String(emoji.prefix(255)) + "a"))
    }

    func testLimitIsPinned() {
        XCTAssertEqual(TypeReadback.xctestValueUTF16Limit, 512)
    }
}
