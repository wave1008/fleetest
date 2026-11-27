import Foundation

/// `||` 分岐 + `*`(セレクタと同じ4形)の値パターン。SystemAlertDismissal と DeviceCondition(model/os)が共有する。
public enum ValuePattern {
    /// セレクタの `||` 記法を候補の列に割る(`"許可||Allow"` → `["許可", "Allow"]`)。
    /// 空の分岐(`"a||"` の末尾など)は落とす —— 空文字は `*` の解釈で「常に一致」に
    /// 化け得るので、書き間違いを黙って通さない
    public static func alternatives(_ pattern: String) -> [String] {
        pattern.components(separatedBy: "||")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    /// 宣言の検査(DSL の `iosAlertHandler`)。空の分岐と、見えない文字を外すと空になる分岐(`"\u{200B}*"` は前方一致の空 =
    /// 題名が読める全アラートに当たり、最初の有効なボタンを押した)を断る。`alternatives` の「空の分岐は捨てる」とは別
    /// (そちらは照合側の防御。宣言は書き損じを黙って通さない)
    public static func patternError(_ pattern: String, argument: String) -> String? {
        let branches = pattern.components(separatedBy: "||")
        for (offset, raw) in branches.enumerated() {
            let branch = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if TextNormalization.isBlank(branch) {
                return "\(argument): alternative \(offset + 1) of \(branches.count) is empty (blank, or only invisible characters) in \"\(pattern)\""
            }
            if TextNormalization.selector.apply(FTSelector.partialMatch(branch).text).isEmpty {
                return "\(argument): alternative \"\(branch)\" has no text besides `*` and invisible characters — it would match any \(argument)"
            }
        }
        return nil
    }

    /// 分岐1つが値に当たるか。**`*` の解釈はセレクタと同一**(`FTSelector.partialMatch` の
    /// 4形: bare = 完全一致 / `x*` = 前方 / `*x` = 後方 / `*x*` = 部分)。
    /// 判定も `FlowMatchMode.matches` を使う = セレクタと同じ正規化で比較する。
    /// `"*"` 単体が全一致に化けないのは partialMatch の性質(リテラル `*` の完全一致になる)
    public static func branchMatches(_ branch: String, value: String?) -> Bool {
        let parsed = FTSelector.partialMatch(branch)
        return parsed.mode.matches(value, parsed.text)
    }

    /// パターン(`||` 分岐 + `*`)が値に当たるか
    public static func patternMatches(_ pattern: String, value: String?) -> Bool {
        alternatives(pattern).contains { branchMatches($0, value: value) }
    }
}
