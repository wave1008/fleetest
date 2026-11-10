// ft_dsl_commands が名指しのコマンドに添える注意事項(docs/user-docs/reference/writing/known_caveats.md = 英語の一覧)。
// 一覧の項目は「- [要点](../commands/<page>.md#notes) — 説明」。コマンド → ページは、各コマンドページの「## Functions」/
// 「## Properties」の表の1列目のバッククォートから引く(連鎖 `select(sel).textIs(..)` は最後の呼び出しの名前)。
// 一覧と元の文書の件数の一致は vscode-fleetest/test/knownCaveatsIndex.test.mjs が固定する = ここは読むだけ。
// 実行時にクローンの docs を読む(受け手のクローンにも docs はある)。読めなければ nil = 注意事項を添えないだけ

import Foundation

public struct CommandCaveats: Sendable {
    /// コマンド名 → 注意事項の行(「要点 — 説明」)。同じページの全コマンドに同じ行が付く
    public let byCommand: [String: [String]]
    /// クローンの根からの一覧の位置(案内の文言にも使う)
    public static let indexPath = "docs/user-docs/reference/writing/known_caveats.md"

    public static func load(toolRoot: URL) -> CommandCaveats? {
        guard let index = try? String(contentsOf: toolRoot.appendingPathComponent(indexPath), encoding: .utf8) else {
            return nil
        }
        let commandsDir = toolRoot.appendingPathComponent("docs/user-docs/reference/commands")
        guard let files = try? FileManager.default.contentsOfDirectory(atPath: commandsDir.path) else { return nil }
        var pages: [String: String] = [:]
        for file in files where file.hasSuffix(".md") && !file.hasSuffix("_ja.md") {
            if let source = try? String(contentsOf: commandsDir.appendingPathComponent(file), encoding: .utf8) {
                pages[file] = source
            }
        }
        return CommandCaveats(index: index, commandPages: pages)
    }

    /// commandPages: コマンドページのファイル名(`tap.md`)→ 本文
    public init(index: String, commandPages: [String: String]) {
        let caveats = Self.caveatLines(index: index)
        var byCommand: [String: [String]] = [:]
        for (page, source) in commandPages {
            guard let lines = caveats[page], !lines.isEmpty else { continue }
            for name in Self.functionNames(in: source) { byCommand[name, default: []] += lines }
        }
        self.byCommand = byCommand
    }

    /// 一覧の項目をコマンドページごとに(出現順)。コマンドページを指さない項目(UI 部品・セレクタ)は含めない
    static func caveatLines(index: String) -> [String: [String]] {
        var out: [String: [String]] = [:]
        for raw in index.split(separator: "\n", omittingEmptySubsequences: false) {
            guard let match = String(raw).firstMatch(
                of: /^- \[([^\]]+)\]\(\.\.\/commands\/([^)#\s]+\.md)#[^)]*\)\s*(?:—\s*)?(.*)$/) else { continue }
            let rest = String(match.3).trimmingCharacters(in: .whitespaces)
            out[String(match.2), default: []].append(rest.isEmpty ? String(match.1) : "\(match.1) — \(rest)")
        }
        return out
    }

    /// コマンドページの関数表(「## Functions」/「## Properties」)の1列目に書かれたコマンド名
    static func functionNames(in source: String) -> Set<String> {
        var names = Set<String>()
        var inTable = false
        for raw in source.split(separator: "\n") {
            let line = String(raw)
            if line.hasPrefix("## ") {
                inTable = line.hasPrefix("## Functions") || line.hasPrefix("## Properties")
                continue
            }
            guard inTable, line.hasPrefix("|"), let firstCell = line.split(separator: "|").first else { continue }
            for span in firstCell.matches(of: /`([^`]+)`/) {
                let calls = String(span.1).matches(of: /(?:^|\.)([A-Za-z_][A-Za-z0-9_]*)(?=\(|\/|$)/)
                if let last = calls.last { names.insert(String(last.1)) }
            }
        }
        return names
    }
}
