// 契約: `LocalConfig` を load → 変更 → save する書き手は `loadForUpdate`(壊れた設定で投げる)で読む。
// `load` は壊れていると空設定を返すので、そのまま保存すると全設定が消える。
// 「`LocalConfig.load(` と `.save(` を同じファイルで使う」ファイルを Sources 全体から導出し、許可リスト(読むだけの load と
// 更新の loadForUpdate が同居するファイル)と等号で固定する。新しい書き手は loadForUpdate を使ってから許可リストへ足す。

import Foundation
import XCTest

final class LocalConfigWriterScanTests: XCTestCase {
    private static let allowedWriters: Set<String> = [
        "fleetest/ApiDeviceSettingsCommand.swift",
        "fleetest/ApiRemoteHostsCommand.swift",
        "fleetest/ApiRetentionCommand.swift",
        "fleetest/ProjectCommands.swift",
        "fleetest/RemoteCommands.swift",
    ]

    private func sourcesRoot() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources")
    }

    private func codeOnly(_ text: String) -> String {
        text.split(separator: "\n", omittingEmptySubsequences: false)
            .map { line -> Substring in
                if line.drop(while: { $0 == " " || $0 == "\t" }).hasPrefix("//") { return "" }
                if let range = line.range(of: " //") { return line[..<range.lowerBound] }
                return line
            }
            .joined(separator: "\n")
    }

    func testLoadAndSaveInOneFileIsLimitedToTheAllowList() throws {
        let root = sourcesRoot()
        let enumerator = try XCTUnwrap(FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]))
        var found = Set<String>()
        var withoutUpdateLoad: [String] = []
        for case let url as URL in enumerator where url.pathExtension == "swift" {
            let code = codeOnly(try String(contentsOf: url, encoding: .utf8))
            guard code.contains("LocalConfig.load("), code.contains("config.save(") || code.contains(".save()") else { continue }
            let relative = String(url.path.dropFirst(root.path.count + 1))
            found.insert(relative)
            if !code.contains("LocalConfig.loadForUpdate(") { withoutUpdateLoad.append(relative) }
        }
        XCTAssertEqual(found, Self.allowedWriters,
                       "a file that loads and saves LocalConfig must read with loadForUpdate, then be listed here")
        XCTAssertEqual(withoutUpdateLoad, [], "writers that never call LocalConfig.loadForUpdate")
    }
}
