import XCTest
import FTCore
@testable import fleetest_mcp

/// MCP 側の「利用者の文字列を受け取って比べる・解く経路」の表(DSL 側は `FTDSLTests/TextInputPathTableTests`)。
/// 経路 × 入力の組を等号で固定し、ツール定義の文字列引数(ツール × 引数名)の全数を表 + 許可表(理由つき)と照合する。
/// 期待値は規則から手で導いた。
final class TextInputPathTableMCPTests: XCTestCase {

    enum Outcome: Equatable { case refused, accepted, matched, notMatched }

    static let inputs: [String] = ["", " ", "\u{3000}", "\n", "\u{200B}", "OK\u{200B}", "[\u{200B}]", "☺\u{FE0F}", "a\u{FE0F}", "\\="]

    static func row(blank: Outcome, ok: Outcome, cls: Outcome, smile: Outcome, ascii: Outcome, esc: Outcome) -> [Outcome] {
        Array(repeating: blank, count: 5) + [ok, cls, smile, ascii, esc]
    }

    private static let selectorGate = row(blank: .refused, ok: .accepted, cls: .refused, smile: .accepted, ascii: .accepted, esc: .accepted)
    private static let plainGate = row(blank: .refused, ok: .accepted, cls: .accepted, smile: .accepted, ascii: .accepted, esc: .accepted)
    private static let typeGate: [Outcome] = [.refused] + Array(repeating: .accepted, count: 9)

    /// ツール引数名 → (期待する並び, 実行)。名前はツール定義の引数名
    nonisolated(unsafe) static let argumentPaths: [(argument: String, expected: [Outcome], run: (String) -> Outcome)] = [
        ("selector", selectorGate, { (try? MCPServer.parseSelectorArgument($0, argument: "selector")) == nil ? .refused : .accepted }),
        ("waitFor", selectorGate, { (try? MCPServer.parseSelectorArgument($0, argument: "waitFor")) == nil ? .refused : .accepted }),
        ("to", selectorGate, { (try? MCPServer.parseSelectorArgument($0, argument: "to")) == nil ? .refused : .accepted }),
        ("detect", selectorGate, { (try? MCPServer.parseSelectorArgument($0, argument: "detect")) == nil ? .refused : .accepted }),
        ("dismiss", selectorGate, { (try? MCPServer.parseSelectorArgument($0, argument: "dismiss")) == nil ? .refused : .accepted }),
        // scrollFrame は 1 つの容器だけ(代替は断る)
        ("scrollFrame", selectorGate, { FTSelector.scrollFrameLocator($0).error == nil ? .accepted : .refused }),
        // iosAlertHandler(button:) の完全一致の分岐と同じ照合(DSL と同じ正規化)
        ("alertButton@match", row(blank: .notMatched, ok: .matched, cls: .notMatched, smile: .notMatched, ascii: .notMatched, esc: .notMatched),
         { MCPServer.alertButtonMatches("OK\u{200B}", $0) ? .matched : .notMatched }),
        ("alertButton@bounds", plainGate, { ArgumentBounds.emptyViolation("alertButton", $0) == nil ? .accepted : .refused }),
        ("label@bounds", plainGate, { ArgumentBounds.emptyViolation("label", $0) == nil ? .accepted : .refused }),
        ("id@bounds", plainGate, { ArgumentBounds.emptyViolation("id", $0) == nil ? .accepted : .refused }),
        ("selector@bounds", plainGate, { ArgumentBounds.emptyViolation("selector", $0) == nil ? .accepted : .refused }),
    ]

    /// 引数名のうち、比べる・解く経路ではないもの(理由つき)。**理由が書けない引数は表に載せる**
    static let notInTable: [String: String] = {
        var table: [String: String] = [:]
        func add(_ names: [String], _ reason: String) { for name in names { table[name] = reason } }
        add(["udid", "serial", "device", "platform", "project", "profile", "runner", "target", "scenario", "runId", "since",
             "name", "title", "state", "category", "className", "classifier", "filter", "query", "action", "finger",
             "direction", "orientation"],
            "identifier / enum / free-form filter, not a compared screen text")
        add(["bundleId", "packagePath", "url", "launch"], "app identifier / path / URL")
        add(["text"], "text typed into the app; the read-back compares both sides with TextNormalization.text (ft_type note)")
        add(["value"], "ft_set_picker_value: compared with the wheel's text by PickerValueMatch (its own table: PickerValueMatchTests)")
        add(["steps"], "DSL lines: each line is parsed by BatchLineParser and built by the batch builders (see the batch paths)")
        return table
    }()

    func testEveryArgumentPathAgreesWithTheTableForEveryInput() {
        var failures: [String] = []
        for path in Self.argumentPaths {
            XCTAssertEqual(path.expected.count, Self.inputs.count, path.argument)
            for (index, value) in Self.inputs.enumerated() {
                let got = path.run(value)
                if got != path.expected[index] { failures.append("\(path.argument) × input#\(index): expected \(path.expected[index]) got \(got)") }
            }
        }
        XCTAssertTrue(failures.isEmpty, failures.joined(separator: "\n"))
    }

    /// ft_batch: 明示の `''`(空・空白・見えない文字だけ)のセレクタ・scrollFrame・dismiss は「省略」と読まず断る
    func testBatchBuildersRefuseExplicitBlankInsteadOfReadingItAsOmitted() {
        let selectorKeys = ["selector", "to", "detect", "dismiss", "scrollFrame"]
        var failures: [String] = []
        var checked = 0
        for (command, builder) in MCPServer.batchStepBuilders {
            for key in selectorKeys where builder.keys.contains(key) {
                var base: [String: Any] = ["selector": "#a", "to": "#b", "detect": "#a", "text": "x"]
                base = base.filter { builder.keys.contains($0.key) }
                guard (try? builder.build(base)) != nil else { continue }   // 最小の引数で組めない命令は対象外(必須の別引数がある)
                for (index, value) in Self.inputs.enumerated() {
                    var raw = base
                    raw[key] = value
                    let outcome: Outcome = (try? builder.build(raw)) == nil ? .refused : .accepted
                    if outcome != Self.selectorGate[index] {
                        failures.append("batch \(command).\(key) × input#\(index): expected \(Self.selectorGate[index]) got \(outcome)")
                    }
                }
                checked += 1
            }
        }
        XCTAssertGreaterThan(checked, 5, "the batch scan checked too few (command, key) pairs")
        XCTAssertTrue(failures.isEmpty, failures.joined(separator: "\n"))
    }

    /// ft_batch の type: 空文字は replace: true のときだけ通す
    func testBatchTypeRefusesEmptyTextWithoutReplace() throws {
        let builder = try XCTUnwrap(MCPServer.batchStepBuilders["type"])
        XCTAssertNil(try? builder.build(["text": ""]))
        XCTAssertNotNil(try? builder.build(["text": "", "replace": true]))
        XCTAssertNotNil(try? builder.build(["text": " "]))
    }

    /// ツール定義の文字列引数(引数名)の全数 = 表の引数名 + 許可表
    func testEveryStringArgumentOfEveryToolIsInTheTableOrTheAllowList() {
        var names: Set<String> = []
        for tool in MCPServer.toolDefinitions {
            guard let schema = tool["inputSchema"] as? [String: Any],
                  let props = schema["properties"] as? [String: Any] else { continue }
            for (name, raw) in props {
                guard let prop = raw as? [String: Any] else { continue }
                let isString: Bool
                if let type = prop["type"] as? String { isString = type == "string" }
                else if let types = prop["type"] as? [String] { isString = types.contains("string") }
                else { isString = false }
                if isString { names.insert(name) }
            }
        }
        XCTAssertFalse(names.isEmpty)
        let table = Set(Self.argumentPaths.map { String($0.argument.split(separator: "@", maxSplits: 1)[0]) })
        let allowed = Set(Self.notInTable.keys)
        XCTAssertTrue(table.isDisjoint(with: allowed), "in both: \(table.intersection(allowed).sorted())")
        let uncovered = names.subtracting(table).subtracting(allowed)
        XCTAssertTrue(uncovered.isEmpty,
                      "string arguments of ft_* tools are in neither the path table nor the allow list (add a path, or an allow-list entry with a reason): \(uncovered.sorted())")
        // 表の引数名がツール定義から消えていないこと(bounds 用の label / id は ArgumentBounds の鍵なのでツール定義に無くてよい)
        // to / detect / dismiss は ft_batch の DSL 行のキー(ツール定義には無い・batch の走査が別に固定する)
        let stale = table.union(allowed).subtracting(names).subtracting(["label", "id", "to", "detect", "dismiss"])
        XCTAssertTrue(stale.isEmpty, "path table / allow list names an argument that no tool declares: \(stale.sorted())")
    }
}
