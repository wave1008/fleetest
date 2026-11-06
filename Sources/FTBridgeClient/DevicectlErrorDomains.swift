import Foundation

/// devicectl の `--json-output -` が失敗時に出す JSON から、エラーのドメインを構造で取り出す(文言の一致では決めない)。
/// 構造は階層の深さが版で変わりうるので、全ての辞書の `domain` と `errorSignature`(ドメイン列の欄)を再帰で拾う。
/// 読めなければ空 = 呼び手は従来の文(確かめられないので断定しない)
enum DevicectlErrorDomains {
    /// アプリのデータコンテナが無い = そのアプリがこのデバイスに入っていない(`copy to --domain-type appDataContainer` の失敗)
    static let containerLookup = "ContainerLookupErrorDomain"

    static func domains(in output: String) -> Set<String> {
        guard let start = output.firstIndex(of: "{"), let end = output.lastIndex(of: "}"), start < end,
              let data = String(output[start...end]).data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data) else { return [] }
        var found = Set<String>()
        collect(root, into: &found)
        return found
    }

    static func indicatesNotInstalled(_ output: String) -> Bool { domains(in: output).contains(containerLookup) }

    private static func collect(_ node: Any, into found: inout Set<String>) {
        if let dict = node as? [String: Any] {
            if let d = dict["domain"] as? String { found.insert(d) }
            if let sig = dict["errorSignature"] as? String, sig.contains(containerLookup) { found.insert(containerLookup) }
            for v in dict.values { collect(v, into: &found) }
        } else if let arr = node as? [Any] {
            for v in arr { collect(v, into: &found) }
        }
    }
}
