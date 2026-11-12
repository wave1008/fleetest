// ピッカーのホイールの値の照合(`PickerValueMatch`)。境界: ゼロ埋め・単位つき・英語の言い回し・数字で始まらない値・空。

import XCTest
@testable import FTCore

final class PickerValueMatchTests: XCTestCase {

    func testMatchesExactTextAndLeadingInteger() {
        XCTAssertTrue(PickerValueMatch.matches(current: "09", wanted: "09"))
        XCTAssertTrue(PickerValueMatch.matches(current: "07", wanted: "7"))
        XCTAssertTrue(PickerValueMatch.matches(current: "7", wanted: "07"), "数字だけの指定は数値で比べる")
        XCTAssertTrue(PickerValueMatch.matches(current: "14時", wanted: "14"))
        XCTAssertTrue(PickerValueMatch.matches(current: "9 o’clock", wanted: "9"))
        XCTAssertTrue(PickerValueMatch.matches(current: "30 minutes", wanted: "30"))
        XCTAssertTrue(PickerValueMatch.matches(current: "30 minutes", wanted: "30 minutes"))
    }

    func testDoesNotMatchPartialOrRoundedValues() {
        XCTAssertFalse(PickerValueMatch.matches(current: "19時", wanted: "1"), "部分一致はしない")
        XCTAssertFalse(PickerValueMatch.matches(current: "19時", wanted: "9"))
        XCTAssertFalse(PickerValueMatch.matches(current: "30 minutes", wanted: "3"))
        XCTAssertFalse(PickerValueMatch.matches(current: "January", wanted: "Jan"), "数字でない指定は完全一致だけ")
        XCTAssertFalse(PickerValueMatch.matches(current: "AM", wanted: "9"), "数字で始まらない値は数値照合に乗らない")
        XCTAssertFalse(PickerValueMatch.matches(current: "9", wanted: "AM"))
    }

    func testEmptyNeverMatches() {
        XCTAssertFalse(PickerValueMatch.matches(current: "", wanted: ""))
        XCTAssertFalse(PickerValueMatch.matches(current: "09", wanted: ""))
        XCTAssertFalse(PickerValueMatch.matches(current: "", wanted: "9"))
    }

    func testInvisibleCharactersAndWhitespaceAreIgnored() {
        XCTAssertTrue(PickerValueMatch.matches(current: "\u{200B}09\u{200B}", wanted: "09"))
        XCTAssertTrue(PickerValueMatch.matches(current: " 30  minutes ", wanted: "30 minutes"))
    }

    func testLeadingInteger() {
        XCTAssertEqual(PickerValueMatch.leadingInteger("14時"), 14)
        XCTAssertEqual(PickerValueMatch.leadingInteger("09"), 9)
        XCTAssertEqual(PickerValueMatch.leadingInteger("30 minutes"), 30)
        XCTAssertNil(PickerValueMatch.leadingInteger("AM"))
        XCTAssertNil(PickerValueMatch.leadingInteger(""))
        XCTAssertNil(PickerValueMatch.leadingInteger("x9"))
    }

    func testIOSCandidatesReplaceTheLeadingDigitsKeepingTheRowWording() {
        XCTAssertEqual(PickerValueMatch.iosCandidates(current: "14時", wanted: "19"), ["19", "19時"])
        XCTAssertEqual(PickerValueMatch.iosCandidates(current: "9 o’clock", wanted: "19"), ["19", "19 o’clock"])
        XCTAssertEqual(PickerValueMatch.iosCandidates(current: "09時", wanted: "7"), ["07", "7", "07時"], "ゼロ埋めの桁は current に合わせる")
        // 分の行は "00"〜"59"(実測: "5" も "05 minutes" も行が無く、"05" で通る)。今の値の先頭が0で始まらなくても桁はそろえる
        XCTAssertEqual(PickerValueMatch.iosCandidates(current: "30 minutes", wanted: "5"), ["05", "5", "05 minutes"], "桁をそろえた数字を先に(外れの候補で待ちを使い切らない)")
        XCTAssertEqual(PickerValueMatch.iosCandidates(current: "30 minutes", wanted: "45"), ["45", "45 minutes"])
        XCTAssertEqual(PickerValueMatch.iosCandidates(current: "09", wanted: "09"), ["09"], "重複は除く")
    }

    func testIOSCandidatesFallBackToTheWantedTextOnly() {
        XCTAssertEqual(PickerValueMatch.iosCandidates(current: "AM", wanted: "PM"), ["PM"])
        XCTAssertEqual(PickerValueMatch.iosCandidates(current: "AM", wanted: "9"), ["9"], "current が数字で始まらない")
        XCTAssertEqual(PickerValueMatch.iosCandidates(current: "14時", wanted: "PM"), ["PM"], "wanted が数字だけでない")
        XCTAssertEqual(PickerValueMatch.iosCandidates(current: "", wanted: "9"), ["9"])
    }

    func testAndroidDirection() {
        XCTAssertEqual(PickerValueMatch.androidDirection(current: "14", wanted: "19"), .forward)
        XCTAssertEqual(PickerValueMatch.androidDirection(current: "14", wanted: "3"), .backward)
        XCTAssertNil(PickerValueMatch.androidDirection(current: "14", wanted: "14"))
        XCTAssertNil(PickerValueMatch.androidDirection(current: "January", wanted: "3"), "現在値が数値でない")
        XCTAssertNil(PickerValueMatch.androidDirection(current: "3", wanted: "March"), "目標が数字だけでない")
    }
}
