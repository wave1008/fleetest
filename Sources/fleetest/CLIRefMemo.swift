import Foundation
import FTBridgeClient
import FTCore

/// CLI の `--ref` が、利用者が最後に見た木の ref → 目印(identifier・型)を呼び出しをまたいで控える場所
/// (`.fleetest/cli-ref-memo-<鍵>.json`。判定は `FTCore.RefTableMemo`)。
/// 書くのは `fleetest snapshot` と `RefFireGate`(断らなかった回だけ)。読めない・書けないときは守りなし(黙って撃つ)
enum CLIRefMemo {
    private struct Entry: Codable { var ref: Int; var type: String; var identifier: String? }

    private static func url(key: String) -> URL? {
        (try? RepoRoot.find())?.appendingPathComponent(".fleetest/cli-ref-memo-\(key).json")
    }

    static func load(key: String) -> RefTableMemo.Table? {
        guard let url = url(key: key), let data = try? Data(contentsOf: url),
              let entries = try? JSONDecoder().decode([Entry].self, from: data) else { return nil }
        return Dictionary(entries.map { ($0.ref, RefExpectation(identifier: $0.identifier, type: $0.type)) },
                          uniquingKeysWith: { first, _ in first })
    }

    static func store(key: String, elements: [ElementInfo]) {
        guard let url = url(key: key) else { return }
        let entries = elements.map { Entry(ref: $0.ref, type: $0.type, identifier: $0.identifier) }
        guard let data = try? JSONEncoder().encode(entries) else { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: url, options: .atomic)
    }
}

extension DriverOptions {
    /// 控えの鍵(宛先ごと。--port / --serial を省いた形は "auto")
    var refMemoKey: String {
        resolvedPlatform == "android" ? "android-\(serial ?? "auto")" : "ios-\(port.map(String.init) ?? "auto")"
    }
}
