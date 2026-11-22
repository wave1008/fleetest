// 実行の単位の鍵(ScenarioUnitKey = シナリオ ID × バリアント)の走査。並べ替え・引き直し・割り振り・欠落の照合の箇所で、
// ID だけの文字列を鍵にした辞書・集合・並びが戻ってきたら落ちる(バリアントを展開した run で、同じ ID の別バリアントの単位が
// 1つに潰れる・取り違えられる = 欠落の照合が黙って緑になる、を防ぐ)。
// 許す箇所は `allowed` に理由付きで置く(表示用の文字列・単位の外の概念。表を増やして通さない)。

import XCTest

final class ScenarioUnitKeyScanTests: XCTestCase {

    /// 走査する箇所(付録 A の「並べ替え・引き直し / 割り振り / 欠落の照合」)
    private static let files = [
        "Sources/FTCore/ScenarioQueue.swift",
        "Sources/FTCore/ClassPlacementRules.swift",
        "Sources/FTCore/WorkQueueProtocol.swift",
        "Sources/FTCore/StdioPullSource.swift",
        "Sources/FTCore/FleetSplit.swift",
        "Sources/FTCore/DynamicSplit.swift",
        "Sources/FTCore/BroadcastPlan.swift",
        "Sources/FTCore/ResponseMeasurementRepeat.swift",
        "Sources/FTCore/JUnitReportWriter.swift",
        "Sources/fleetest/RunPlacementPreflight.swift",
        "Sources/fleetest/DynamicDispatcher.swift",
        "Sources/fleetest/DeviceMachineRunner.swift",
        "Sources/fleetest/ApiRunMachineFanout.swift",
        "Sources/fleetest/MultiTargetRunner.swift",
    ]

    /// ID だけを鍵にした形。`info.id` / `scenarioID` / `.id` を辞書の鍵・集合の要素・添字に使う形と、ID の並び・集合の宣言
    private static let forbidden: [(name: String, pattern: String)] = [
        ("subscript by info.id / scenarioID", #"\[(\w+\.)?(info\.id|scenarioID)[\],]"#),
        ("collection built from ids", #"(Set|Dictionary)\(.*(\.map\(\\\.(id|scenarioID)\)|\.map \{ \$0\.(id|scenarioID) \}|info\.id|\.scenarioID)"#),
        ("grouping by id", #"Dictionary\(grouping:.*\.(id|scenarioID)"#),
        ("ID-named String collection", #"(var|let|func)\s+\w*(IDs|[bB]yID|Ids)\b.*(Set<String>|\[String:|\[String\])"#),
    ]

    /// 許す行(ファイル → 行に含まれる断片 → 理由)。ここに載せるのは、単位の鍵ではない ID の使い方だけ
    private static let allowed: [(file: String, fragment: String, reason: String)] = [
        // 選び方の検査(`selectionError`)・--failed の展開の「クラスの全メンバー」: 選択はバリアントに依らない(ID の集合 = どの単位かではなく
        // どのシナリオか)。展開後の鍵は ScenarioUnitKey(`expandingFailed` の戻り値)
        ("Sources/FTCore/ClassPlacementRules.swift", "let selectedIDs = Set(selected.map(\\.id))", "選び方の検査はシナリオ単位"),
        ("Sources/FTCore/ClassPlacementRules.swift", "universe[info.id] = info", "選び方の検査はシナリオ単位(クラスのメンバーの並び)"),
        ("Sources/FTCore/ClassPlacementRules.swift", "let inOrderIDs = Set(all.filter", "全メンバー(ScenarioInfo)に @RunInOrder があるかの判定"),
        // 複数対象の `--target` の重複検査(対象 = プロファイルの id。シナリオの単位ではない)
        ("Sources/fleetest/MultiTargetRunner.swift", "var seenIDs: Set<String>", "target id の重複検査"),
        // JUnit のクラス別のまとまり(表示の分け方。単位の鍵ではない)
        ("Sources/FTCore/JUnitReportWriter.swift", "Dictionary(grouping: sorted)", "classname ごとの testsuite"),
        // 実績(LPT / 見積り)の索引は ID + platform の鍵。結果に variant を足す段で「そのバリアントの履歴が無ければ無しの履歴」を足す(仕様 6.6)
        ("Sources/FTCore/FleetSplit.swift", "duration.scenarioID", "実績の索引(結果の記録に variant が無い間は ID + platform)"),
    ]

    private static func lines(_ path: String) throws -> [String] {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent(path)
        return try String(contentsOf: url, encoding: .utf8).split(separator: "\n", omittingEmptySubsequences: false)
            .map(String.init)
    }

    /// 走査の本体(変異・単体テストから同じ関数を通す)
    static func violations(in lines: [String], file: String) -> [String] {
        var found: [String] = []
        for (index, line) in lines.enumerated() {
            if line.trimmingCharacters(in: .whitespaces).hasPrefix("//") { continue }
            for rule in forbidden where line.range(of: rule.pattern, options: .regularExpression) != nil {
                if allowed.contains(where: { $0.file == file && line.contains($0.fragment) }) { continue }
                found.append("\(file):\(index + 1): \(rule.name): \(line.trimmingCharacters(in: .whitespaces))")
            }
        }
        return found
    }

    func testNoIDOnlyKeysInUnitKeyedPlaces() throws {
        var all: [String] = []
        for file in Self.files { all += Self.violations(in: try Self.lines(file), file: file) }
        XCTAssertTrue(all.isEmpty, "ID だけの文字列を鍵にしている(ScenarioUnitKey を使う):\n" + all.joined(separator: "\n"))
    }

    /// 走査自体が効いている確認: 禁止の形を実際に検出する(常に空を返す走査と区別する)
    func testScanDetectsTheForbiddenForms() {
        let samples = [
            "        var byID: [String: [ScenarioRunItem]] = [:]",
            "        for item in items { byID[item.info.id, default: []].append(item) }",
            "        let ids = Set(selected.map(\\.id))",
            "    private let scenariosByID: [String: DynamicSplit.Scenario]",
            "    func assignedIDs(entry: Int) -> [String] {",
            "        let g = Dictionary(grouping: infos) { $0.id }",
        ]
        for sample in samples {
            XCTAssertFalse(Self.violations(in: [sample], file: "x.swift").isEmpty, "検出できない: \(sample)")
        }
        XCTAssertTrue(Self.violations(in: ["// byID: [String: Int]", "    var byUnit: [ScenarioUnitKey: Int] = [:]"], file: "x.swift").isEmpty)
    }

    /// 走査の対象に載せたファイルが実在する(改名・分割で黙って外れない)
    func testScannedFilesExist() throws {
        for file in Self.files { XCTAssertFalse(try Self.lines(file).isEmpty, file) }
    }
}

/// ScenarioRunItem の作り直しは `with(lane:)` / `with(repeatIndex:)` を通す(init に info を渡し直すと variant を落としうる)
final class ScenarioRunItemRebuildScanTests: XCTestCase {
    func testNoRebuildThroughInit() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let sources = root.appendingPathComponent("Sources")
        var offenders: [String] = []
        let enumerator = FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil)
        while let url = enumerator?.nextObject() as? URL {
            guard url.pathExtension == "swift" else { continue }
            if url.lastPathComponent == "RunTypes.swift" { continue }
            let text = try String(contentsOf: url, encoding: .utf8)
            for (index, line) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated()
            where line.contains("ScenarioRunItem(info: item") || line.contains("ScenarioRunItem(info: $0.info")
                || line.contains("ScenarioRunItem(info: queued") {
                offenders.append("\(url.lastPathComponent):\(index + 1)")
            }
        }
        XCTAssertTrue(offenders.isEmpty, "既存の item から作り直すときは with(lane:) / with(repeatIndex:) を使う: \(offenders)")
    }
}
