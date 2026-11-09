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

    /// 見えない文字は検査の前に除外する: `#` + ZWJ・単独の異体字セレクタ・CGJ だけの値も空(45周目 im4 F1・F2)
    func testInvisibleOnlySelectorsAreRefused() {
        for bad in ["#\u{200D}", "text=\u{200D}", "#a>>=\u{200D}", ".textField#\u{200D}", "*\u{FE0F}*", "value=\u{FE0F}",
                    "textContains=\u{034F}"] {
            XCTAssertNotNil(FTSelector.validationError(bad), bad.unicodeScalars.map { String($0.value, radix: 16) }.joined(separator: " "))
        }
        XCTAssertNil(FTSelector.validationError("#nav_input"))
        XCTAssertNil(FTSelector.validationError("❤\u{FE0F}"), "見た目の文字に付いた異体字セレクタは残す")
    }

    /// 要素の検証の空の期待値は比べる前に断る(ユーザー決定 11/9)。含む・前方・後方一致とその否定形だけ
    func testEmptyExpectationRefusal() {
        for assert in ["textContains", "textStartsWithNot", "valueEndsWith", "valueContainsNot", "thisContains"] {
            for expected in ["", " ", "\u{200B}", "\n", "\u{FE0F}"] {
                XCTAssertNotNil(StepExecutor.emptyExpectationRefusal(assert, expected: expected), "\(assert) \(expected.debugDescription)")
            }
            XCTAssertNil(StepExecutor.emptyExpectationRefusal(assert, expected: "a"))
        }
        XCTAssertNil(StepExecutor.emptyExpectationRefusal("textIs", expected: ""), "一致の検証は空の期待値を書ける")
        XCTAssertNil(StepExecutor.emptyExpectationRefusal("textContains", expected: nil))
    }

    /// 正規表現のパターンからも見えない文字を除外する(画面の文字と同じ規則)
    func testRegexPatternExcludesInvisibleCharacters() {
        XCTAssertNotNil(LocatorResolver.matchedText("a\u{200B}b", expected: "^a\u{200B}b$", assert: "textMatches"))
        XCTAssertFalse(LocatorResolver.negativeAssertSatisfied("textMatchesNot", actual: "a\u{200B}b", expected: "^a\u{200B}b$"))
    }

    /// 実行機の入口でも断る(要素を探す前・比べる前)。陽性対照: 中身のある期待値は比べに行く
    func testExecutorRefusesEmptyContainmentExpectation() async {
        let element = ElementInfo(ref: 1, type: "staticText", identifier: "txt_result", label: "abc", value: nil, placeholder: nil,
                                  enabled: true, frame: FTRect(x: 0, y: 100, width: 200, height: 40), depth: 1)
        let driver = FakeAppDriver(name: "primary", log: CallLog(), snapshotElements: [[element]])
        let executor = StepExecutor(driver: driver, occlusionOCRMode: .off, isAndroid: false, tunables: RunTunables())
        let refused = await executor.execute(FlowStep(assert: "textContains", locator: FlowLocator(id: "txt_result"),
                                                      expected: "\u{200B}", timeout: 0, occlusionGuard: false))
        guard case .failed(let message) = refused.status else { return XCTFail("空の期待値が通った: \(refused.status)") }
        XCTAssertTrue(message.contains("the expected value is empty"), message)
        let compared = await executor.execute(FlowStep(assert: "textContains", locator: FlowLocator(id: "txt_result"),
                                                       expected: "b", timeout: 0, occlusionGuard: false))
        XCTAssertTrue(StepExecutor.isSuccess(compared.status), "\(compared.status)")
    }

    /// 正規表現はパターンを書き換えず、素の値と正規化した値の両方に当てる(46周目: 書き換えで空・量指定子の移動・`[]` が出た)
    func testRegexKeepsThePatternAndTriesBothValues() {
        XCTAssertNil(TextNormalization.regexMatch("abc", pattern: "\u{200B}", under: .text), "見えない文字だけのパターンが何にでも一致した")
        XCTAssertNil(TextNormalization.regexMatch("aaac", pattern: "^a\u{200B}*c$", under: .text), "量指定子が前の文字へ移った")
        XCTAssertNotNil(TextNormalization.regexMatch("a\u{200B}b", pattern: "^ab$", under: .text), "見えない文字を除いた値に当たらない")
        XCTAssertNotNil(TextNormalization.regexMatch("a\u{200B}b", pattern: "^a\u{200B}b$", under: .text), "素の値に当たらない")
        XCTAssertNotNil(TextNormalization.regexMatch("a\u{00A0}b", pattern: "\\u00A0", under: .text), "エスケープで名指した文字が素の値に当たらない")
        XCTAssertNil(TextNormalization.regexMatch("a\u{200B}b", pattern: "^ab$", under: .strict), "strict は素の値だけ")
    }

    /// セレクタは検査と解析が同じ「見えない文字を外した」文字列を見る。正規表現のフィルタの値は書いたまま
    func testSelectorParseStripsInvisibleButKeepsRegexValues() {
        XCTAssertEqual(FTSelector.parse("#\u{200D}nav_pager").primary.id, "nav_pager", "結合子でラベルに化けた")
        XCTAssertEqual(FTSelector.parse(".button\u{200B}").primary.type, "button")
        XCTAssertNil(FTSelector.validationError("textMatches=^E2E[\u{200B}]*"), "正当な正規表現を除外の後の形で断った")
        XCTAssertNotNil(FTSelector.validationError("textMatches=\u{200B}"), "見えない文字だけのパターンを通した")
        XCTAssertEqual(FTSelector.parse("#a&&textMatches=x[\u{200B}]").primary.label, "x[\u{200B}]", "正規表現の値を書き換えた")
    }

    /// 絵文字でない文字の後ろの異体字セレクタ・CGJ は見えないので除外し、絵文字の後ろの異体字セレクタは残す
    func testVariationSelectorKeptOnlyAfterEmoji() {
        XCTAssertEqual(TextNormalization.text.apply("ム\u{FE0F}"), "ム")
        XCTAssertEqual(TextNormalization.text.apply("a\u{034F}b"), "ab")
        XCTAssertEqual(TextNormalization.text.apply("❤\u{FE0F}"), "❤\u{FE0F}")
    }
}
