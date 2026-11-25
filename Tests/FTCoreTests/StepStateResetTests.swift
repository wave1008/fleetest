// StepExecutor のステップごとの状態(名前が `…ThisStep` の型の欄)は、ステップの入口(`executeStep`)で戻すか、
// 別の入口で必ず代入することを固定する。戻し忘れると前のステップの値が次のステップの結果(StepOutcome)に載る
// (例: `resolvedElementThisStep` が残ると別の要素の指紋が記録され、自己修復が誤った要素へ寄る)

import XCTest

final class StepStateResetTests: XCTestCase {
    /// 入口(`executeStep`)以外で戻す欄と、その場所(ファイル名 → そこに `<欄> =` がある)。理由は値に書く
    private static let resetElsewhere: [String: (file: String, reason: String)] = [
        "resolvedViaSystemUIThisStep": ("StepExecutor+Assert.swift", "検証の入口(executeAssert)で戻し、検証の中でだけ読む"),
        "tapTargetBeforeThisStep": ("StepExecutor+Actions.swift", "操作の入口(executeAction)で毎回代入し、操作の中でだけ読む"),
        "tapStepTargetBeforeThisStep": ("StepExecutor+Actions.swift", "操作の入口(executeAction)で毎回代入し、操作の中でだけ読む"),
        "typedFieldBeforeThisStep": ("StepExecutor+Actions.swift", "操作の入口(executeAction)で毎回代入し、type の焦点の確かめでだけ読む"),
    ]

    private static var coreDir: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Sources/FTCore")
    }

    func testEveryPerStepFieldIsResetAtAnEntry() throws {
        let files = try FileManager.default.contentsOfDirectory(at: Self.coreDir, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.hasPrefix("StepExecutor") && $0.pathExtension == "swift" }
        // 型の欄 = 字下げ 4 の `var`(関数の中の局所変数は字下げが深い)
        let declaration = try NSRegularExpression(pattern: #"(?m)^    (?:(?:private|fileprivate|public|internal) )?var ([A-Za-z]+ThisStep)\b"#)
        var fields: Set<String> = []
        var sources: [String: String] = [:]
        for file in files {
            let text = try String(contentsOf: file, encoding: .utf8)
            sources[file.lastPathComponent] = text
            for match in declaration.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
                if let range = Range(match.range(at: 1), in: text) { fields.insert(String(text[range])) }
            }
        }
        XCTAssertGreaterThanOrEqual(fields.count, 20, "走査が …ThisStep の欄に届いていない")

        let executor = try XCTUnwrap(sources["StepExecutor.swift"])
        let entry = try XCTUnwrap(executor.range(of: "private func executeStep("), "executeStep が見つからない")
        // 入口の戻しはステップの実行(`executeActionRetryingUndelivered` / 検証の振り分け)より前に並ぶ
        let entryBlock = executor[entry.lowerBound...].prefix(6000)
        for field in fields.sorted() {
            if let elsewhere = Self.resetElsewhere[field] {
                let text = try XCTUnwrap(sources[elsewhere.file], elsewhere.file)
                XCTAssertTrue(text.contains("\(field) = "), "\(field): 例外の表の \(elsewhere.file) で戻していない(\(elsewhere.reason))")
                continue
            }
            XCTAssertTrue(entryBlock.contains("\(field) = "),
                          "\(field) をステップの入口(executeStep)で戻していない —— 前のステップの値が次の結果に載る。"
                          + "入口で戻すか、別の入口で必ず代入するなら resetElsewhere に理由と場所を書く")
        }
        XCTAssertEqual(Set(Self.resetElsewhere.keys).subtracting(fields), [], "例外の表に、もう無い欄が残っている")
    }
}
