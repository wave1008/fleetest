import XCTest

/// 台の条件(DR-237)つきの絞り込みの配線。**実害**: 台を絞る呼び出しが条件を知らずに `prefix` で絞ると、条件に合う台(Duo)が
/// 供給されず対象外(緑)で終わった。次を固定する ——
/// ①台を絞る呼び出し(`limitingDevices(` / `limitingDevicesAvoidingMCP(`)は全部 `requirements:` と `traits:` を渡す
/// ②空の条件(`requirements: []` / `traits: [:]`)を渡す呼び出しは、理由付きの許可表にあるものだけ
/// ③`fleetest run` と `api run` の一覧の前の供給は、同じ1つの入口(`preListingSupplyStart`)で待つかを決める
final class LimitingDevicesWiringTests: XCTestCase {
    private static let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

    private static func swiftFiles(under dir: String) -> [URL] {
        let base = root.appendingPathComponent(dir)
        let walker = FileManager.default.enumerator(at: base, includingPropertiesForKeys: nil)
        return (walker?.compactMap { $0 as? URL } ?? []).filter { $0.pathExtension == "swift" }
    }

    private static func code(_ url: URL) -> String {
        ((try? String(contentsOf: url, encoding: .utf8)) ?? "")
            .components(separatedBy: "\n")
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
            .joined(separator: "\n")
    }

    private static func source(_ path: String) -> String {
        code(root.appendingPathComponent(path))
    }

    /// 呼び出し(`name(` から対応する `)` まで)。宣言(`func name(`)は除く
    static func calls(of name: String, in text: String) -> [String] {
        var out: [String] = []
        var search = text.startIndex
        while let hit = text.range(of: name + "(", range: search..<text.endIndex) {
            search = hit.upperBound
            let before = text[..<hit.lowerBound]
            // 別の名前の末尾を取り違えない(`limitingDevicesAvoidingMCP(` は `limitingDevices(` に当たらない)・宣言を除く
            if let last = before.last, last.isLetter || last.isNumber || last == "_" { continue }
            if before.hasSuffix("func ") { continue }
            var depth = 1
            var end = hit.upperBound
            while end < text.endIndex, depth > 0 {
                if text[end] == "(" { depth += 1 } else if text[end] == ")" { depth -= 1 }
                end = text.index(after: end)
            }
            out.append(String(text[hit.lowerBound..<end]))
        }
        return out
    }

    /// 空の条件を渡してよい呼び出し(ファイル → 件数と理由)。**理由が書けないものは足さない** —— 書けないなら条件を渡す
    private static let emptyConditionCalls: [String: (count: Int, reason: String)] = [
        "ProfileRunner.swift": (1, "機械分担の親の前段の確認(lease)。機械をまたぐ run の台の観測は別の段で、ここは従来の絞り込み"),
        "ProfileRunner+Supply.swift": (1, "`preListingSupplyStart` の試算(一覧の前 = 宣言を知らない。台が減るかだけを見る)"),
        "ApiRunCommand.swift": (1, "一覧の前の仮の絞り込み(lease・開始スクリプトの台の一覧用。待たない回はこの結果で供給する = 宣言の文字列が無いか台を外さない)"),
    ]

    func testEveryTrimCallPassesRequirementsAndTraits() {
        var emptyByFile: [String: Int] = [:]
        var seen = 0
        for url in Self.swiftFiles(under: "Sources") {
            let text = Self.code(url)
            for name in ["limitingDevices", "limitingDevicesAvoidingMCP"] {
                for call in Self.calls(of: name, in: text) {
                    seen += 1
                    XCTAssertTrue(call.contains("requirements:") && call.contains("traits:"),
                                  "\(url.lastPathComponent): \(name)( が requirements: / traits: を渡していない\n\(call)")
                    if call.contains("requirements: []") || call.contains("traits: [:]") {
                        emptyByFile[url.lastPathComponent, default: 0] += 1
                    }
                }
            }
        }
        XCTAssertGreaterThanOrEqual(seen, 4, "呼び出しの抽出に失敗している(書式が変わった?)")
        XCTAssertEqual(emptyByFile, Self.emptyConditionCalls.mapValues(\.count),
                       "空の条件を渡す呼び出しが許可表と食い違っている。条件を渡せないなら理由を emptyConditionCalls に書く")
        for (file, entry) in Self.emptyConditionCalls {
            XCTAssertFalse(entry.reason.trimmingCharacters(in: .whitespaces).isEmpty, "\(file): 理由が空")
        }
    }

    /// 抽出の陽性対照: 空の条件・条件の渡し忘れを実際に拾う
    func testCallExtractionSeesEmptyAndMissingArguments() {
        let sample = """
        let a = p.limitingDevices(iosScenarios: 1, androidScenarios: 0, requirements: [], traits: [:], avoiding: { _ in false })
        let b = p.limitingDevices(iosScenarios: 1, androidScenarios: 0, avoiding: { _ in false })
        static func limitingDevices(iosScenarios: Int?) {}
        let c = X.limitingDevicesAvoidingMCP(full, requirements: sets, traits: t)
        """
        let calls = Self.calls(of: "limitingDevices", in: sample)
        XCTAssertEqual(calls.count, 2)
        XCTAssertTrue(calls[0].contains("requirements: []"))
        XCTAssertFalse(calls[1].contains("requirements:"))
        XCTAssertEqual(Self.calls(of: "limitingDevicesAvoidingMCP", in: sample).count, 1)
    }

    /// 一覧の前に供給を始める2経路は、同じ1つの入口で待つかを決める(判定を2か所に置かない)。待つなら一覧の後に条件つきで絞る
    func testBothEntryPathsDecideWithTheSingleWaitFunction() {
        let run = Self.source("Sources/fleetest/Fleetest.swift")
        let api = Self.source("Sources/fleetest/ApiRunCommand.swift")
        XCTAssertEqual(Self.calls(of: "ProfileRunner.preListingSupplyStart", in: run).count, 1, "fleetest run が待つ判定を通っていない")
        XCTAssertEqual(Self.calls(of: "ProfileRunner.preListingSupplyStart", in: api).count, 1, "api run が待つ判定を通っていない")
        // 判定の本体(supplyStart)を呼ぶのは入口の1箇所だけ(経路ごとに写さない)
        var supplyStartCalls = 0
        for url in Self.swiftFiles(under: "Sources") {
            supplyStartCalls += Self.calls(of: "DeviceRequirementEntry.supplyStart", in: Self.code(url)).count
        }
        XCTAssertEqual(supplyStartCalls, 1)
        // 待った回は一覧の後に条件つきで絞る(api run)・一覧の前に台を外した回は検算する(両経路)
        XCTAssertTrue(api.contains("requirements: requirementSets, traits: traits"), "api run が一覧の後に条件つきで絞っていない")
        XCTAssertTrue(api.contains("requireDevicesForDeclarations("))
        let runner = Self.source("Sources/fleetest/ProfileRunner.swift")
        XCTAssertTrue(runner.contains("requireDevicesForDeclarations("))
        XCTAssertTrue(runner.contains("requirements: requirementSets, deviceTraits: traits"), "ProfileRunner.run が一覧の後に条件を渡していない")
    }

    /// 親の観測は子へ運ぶ: 内部フラグの値を ProfileRunner.run / 供給へ渡す(渡し忘れると子が観測し直す)
    func testInjectedTraitsReachTheSupplyFromBothEntries() {
        XCTAssertTrue(Self.source("Sources/fleetest/Fleetest.swift").contains("injectedDeviceTraits: injectedDeviceTraits"))
        XCTAssertTrue(Self.source("Sources/fleetest/ApiRunCommand.swift").contains("injected: injectedDeviceTraits"))
    }
}
