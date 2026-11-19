import Foundation

extension StepExecutor {
    /// 入力欄の型(type の対象として複数一致を数えるもの)
    static let inputFieldTypes: Set<String> = ["textField", "secureTextField", "searchField", "textView"]

    /// 既に値のある欄へ追記する注記に添える一文: セレクタが同じ画面の入力欄に複数当たり、先頭へ打った。
    /// 標準アプリのリマインダーは行ごとに題名の欄 `textField "タイトル"` を持ち、`.textField&&タイトル` が残っていた行の欄に追記し続けた。
    /// 添字・相対の指定があるとき・1つしか当たらないときは空(注記を増やさない)
    static func severalFieldsMatchedNote(_ step: FlowStep, in elements: [ElementInfo]) -> String {
        guard let locator = step.locator, locator.index == nil, locator.relative?.isEmpty ?? true,
              let matched = LocatorResolver.resolvedCandidates(locator, elements: elements) else { return "" }
        let fields = matched.filter { inputFieldTypes.contains($0.type) }.count
        guard fields > 1 else { return "" }
        return " — the selector matches \(fields) input fields on this screen and this typed into the first one;"
            + " if you meant a new or other field, narrow the selector (an id, or [n])"
    }
}
