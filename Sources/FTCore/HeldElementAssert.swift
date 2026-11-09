// 掴んだ時点の要素だけで判定できるアサーション(FTDSL のチェーンの初回判定に使う)。
// `exist("#x").textIs("y")` は掴んだ値で先に判定し、満たしていなければ
// StepExecutor が取り直しながらポーリングする(満たしていればデバイス往復が 0 回になる)。
//
// **判定規則は StepExecutor と同じ関数を使う**(matchedText / negativeAssertSatisfied)。
// ここで独自に比較すると、同じアサートがチェーン経路と実機経路で違う答えを出す。

import Foundation

public enum HeldElementAssert {

    /// 掴んだ値だけで判定した結果。**nil = このアサートは保持値で判定しない**(必ず実機を見る)。
    /// 判定しないもの:
    /// - `exists` / `notExists` / `count`: 今の画面に在るか(個数)は過去の値から言えない
    /// - `checked` / `notChecked`: 「checked を実際に観測したか」の追跡が実機経路にあり、
    ///   飛ばすと `checkIsOFF` の誤用警告(状態を持たない要素を指している)が出なくなる
    /// - `screenMatches` / `keyboardShown` / `keyboardNotShown`: 要素の値ではなく画面全体を見る
    ///
    /// **空の期待値の断り(`StepExecutor.emptyExpectationRefusal`)は executor にしか無い**ので、断る入力はここで nil を返して
    /// executor へ落とす(緑を先に返さない)。`normalization` は executor の `textNormalization(for:)` と同じ値を呼び手が渡す(`strict:`)
    public static func satisfied(assert: String, expected: String?,
                                 element: ElementInfo,
                                 normalization: TextNormalization = .text) -> Bool? {
        if StepExecutor.emptyExpectationRefusal(assert, expected: expected) != nil { return nil }
        switch assert {
        case "idEquals":
            guard let expected, let identifier = element.identifier else { return nil }
            return normalization.apply(identifier) == normalization.apply(expected)
        case "valueEquals", "textEquals", "textContains", "textMatches",
             "textStartsWith", "textEndsWith", "textMatchesDateFormat",
             "valueContains", "valueMatches", "valueStartsWith", "valueEndsWith",
             "valueMatchesDateFormat":
            // 値の無い要素はここで決めない(端末の経路は囲んだ入力欄の値も読む = `TypeReadback.assertedValue`。
            // nil を "" と読んで決めると、値を持つ欄を包んだ要素で valueIs("") が通る)
            guard let expected, let actual = actualText(assert, element) else { return nil }
            return LocatorResolver.matchedText(actual, expected: expected, assert: assert,
                                              normalization: normalization) != nil
        case "textNotEquals", "textIsEmpty", "textIsNotEmpty",
             "textStartsWithNot", "textContainsNot", "textEndsWithNot", "textMatchesNot",
             "valueNotEquals", "valueIsEmpty", "valueIsNotEmpty",
             "valueStartsWithNot", "valueContainsNot", "valueEndsWithNot", "valueMatchesNot":
            guard let actual = actualText(assert, element) else { return nil }   // 理由は肯定形と同じ
            return LocatorResolver.negativeAssertSatisfied(assert, actual: actual, expected: expected,
                                                           normalization: normalization)
        case "enabled":
            return element.enabled
        case "disabled":
            return !element.enabled
        default:
            return nil
        }
    }

    /// text 系は label・value 系は value(実機経路の executeAssertTextComparison と同じ振り分け)
    private static func actualText(_ assert: String, _ element: ElementInfo) -> String? {
        assert.hasPrefix("value") ? element.value : element.label
    }
}
