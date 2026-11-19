// Sources の1ファイルの行数の上限(CLAUDE.md §ソース分割の方針「1ファイル約2,000行以下」)を走査で止める。
// 方針だけでは止まらず、超えたファイルが週に100〜200行ずつ伸びていた。
//
// **ラチェット式**: 上限を超えているファイルは `frozen` に今の行数で凍結し、増やすと落ちる。減らした分は
// 表を下げて新しい上限にする(`shrinkSlack` を超えて減ったら表の書き換えを求めて落ちる)。上限を切ったら表から外す。
// 表に無いファイルが上限を超えたら落ちる。**表の数字を上げて通さない** —— 上げるなら `reason` に理由を書く。
//
// 行数は `wc -l` と同じ(改行の数)。対象外は Generated/(protoc の生成物)だけ。

import Foundation
import XCTest

final class SourceFileLineBudgetTests: XCTestCase {

    /// 1ファイルの上限(行)。根拠: Read ツールが1回で読む既定の行数 = 2,000 行。超えると編集のたびに一部しか読めない
    static let limit = 2000

    /// 凍結した行数からこれ以上減ったら表を下げさせる(行)。小さな減りのたびに表の書き換えを求めないための余裕で、
    /// その分だけ再び伸びる余地が残る
    static let shrinkSlack = 50

    /// 上限を超えたまま凍結したファイル。path はリポジトリ相対・lines は凍結した行数・reason は分割を見送っている理由
    static let frozen: [(path: String, lines: Int, reason: String)] = [
        ("Sources/FTCore/StepExecutor+Actions.swift", 2362, "分割未着手"),
        ("Sources/FTCore/RunOrchestrator.swift", 2302, "分割未着手"),
        ("Sources/FTBridgeClient/BridgeProvisioner.swift", 2211, "分割未着手"),
        ("Sources/FTCore/BridgeDTO.swift", 2256, "両 iOS ブリッジの入力(build.sh・project.xcproj・BridgeSourceSet・契約テストの指紋)で、移動でも版上げが要る。次のブリッジの版上げに同梱して分割する(単独で版を上げない)"),
        ("Sources/fleetest-mcp/MCPServer+Snapshot.swift", 2259, "分割未着手"),
        ("Sources/fleetest-mcp/MCPServer+Driver.swift", 2206, "分割未着手"),
        ("Sources/FTDSL/FTRuntime.swift", 2162, "分割未着手"),
        ("Sources/FTCore/RunProfile.swift", 2004, "分割未着手"),
    ]

    private static var repoRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    }

    /// Sources 配下の .swift(Generated/ を除く)の行数。キーはリポジトリ相対パス
    private static func lineCounts() throws -> [String: Int] {
        let root = repoRoot
        let sources = root.appendingPathComponent("Sources")
        let enumerator = try XCTUnwrap(FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil))
        var counts: [String: Int] = [:]
        for case let url as URL in enumerator where url.pathExtension == "swift" {
            let relative = url.path.replacingOccurrences(of: root.path + "/", with: "")
            if relative.contains("/Generated/") { continue }
            let data = try Data(contentsOf: url)
            counts[relative] = data.reduce(0) { $0 + ($1 == 0x0A ? 1 : 0) }
        }
        return counts
    }

    func testNoSourceFileGrowsPastItsBudget() throws {
        let counts = try Self.lineCounts()
        // 走査が Sources に届いていることの確認(0 件だと「常に緑」と区別できない)
        XCTAssertGreaterThanOrEqual(counts.count, 500, "Sources の .swift が見つからない —— 走査の前提が崩れた")

        let frozenByPath = Dictionary(uniqueKeysWithValues: Self.frozen.map { ($0.path, $0) })
        var problems: [String] = []
        for (path, lines) in counts.sorted(by: { $0.key < $1.key }) {
            if let entry = frozenByPath[path] {
                if lines > entry.lines {
                    problems.append("\(path): \(lines) lines > frozen \(entry.lines) (split it, or shrink it back)")
                }
            } else if lines > Self.limit {
                problems.append("\(path): \(lines) lines > limit \(Self.limit) (split it)")
            }
        }
        XCTAssertEqual(problems, [], "\n" + problems.joined(separator: "\n"))
    }

    func testFrozenTableFollowsShrinkingFiles() throws {
        let counts = try Self.lineCounts()
        var stale: [String] = []
        for entry in Self.frozen {
            XCTAssertFalse(entry.reason.isEmpty, "\(entry.path): reason が空")
            guard let lines = counts[entry.path] else {
                stale.append("\(entry.path): file not found (remove it from frozen)")
                continue
            }
            if lines <= Self.limit {
                stale.append("\(entry.path): \(lines) lines <= limit \(Self.limit) (remove it from frozen)")
            } else if lines < entry.lines - Self.shrinkSlack {
                stale.append("\(entry.path): \(lines) lines, frozen \(entry.lines) (lower frozen to \(lines))")
            }
        }
        XCTAssertEqual(stale, [], "\n" + stale.joined(separator: "\n"))
    }

    /// 既定値はリテラルで固定する(CLAUDE.md §判定の規律)
    func testDefaultsArePinned() {
        XCTAssertEqual(Self.limit, 2000)
        XCTAssertEqual(Self.shrinkSlack, 50)
    }
}
