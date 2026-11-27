import Foundation

/// **陽性対照の注入口**: 台の性質の観測結果のうち指定した性質を nil(読めなかった)に強制する。
/// 観測と公表の経路だけに効く(デバイスには触らない。`FrozenInjection` と同じ規律)。
/// 書式 `FT_FAKE_UNREADABLE_TRAITS=<key>[:<trait>,...][;<key>...]`。trait を省くと全部(foldable, homeButton, osVersion, model)。
/// key = プロファイルのデバイス名。区切りの `:` は**最後の1つ**で、後ろが全部 trait 名のときだけ trait 指定と読む(名前に `:` があってよい)
public enum TraitsInjection {
    public static let environmentKey = "FT_FAKE_UNREADABLE_TRAITS"
    public static let traitNames = ["foldable", "homeButton", "osVersion", "model"]

    public static func plan(environment: [String: String]) -> [String: Set<String>] {
        guard let raw = environment[environmentKey] else { return [:] }
        var out: [String: Set<String>] = [:]
        for entry in raw.split(separator: ";") {
            let text = entry.trimmingCharacters(in: .whitespaces)
            guard !text.isEmpty else { continue }
            var key = text
            var traits = Set(traitNames)
            if let colon = text.lastIndex(of: ":") {
                let tail = text[text.index(after: colon)...].split(separator: ",")
                    .map { $0.trimmingCharacters(in: .whitespaces) }
                if !tail.isEmpty, tail.allSatisfy({ traitNames.contains($0) }) {
                    key = String(text[..<colon])
                    traits = Set(tail)
                }
            }
            out[key, default: []].formUnion(traits)
        }
        return out
    }

    public static func apply(_ traits: DeviceTraits, key: String, environment: [String: String]) -> DeviceTraits {
        guard let forced = plan(environment: environment)[key] else { return traits }
        var t = traits
        if forced.contains("foldable") { t.foldable = nil }
        if forced.contains("homeButton") { t.homeButton = nil }
        if forced.contains("osVersion") { t.osVersion = nil }
        if forced.contains("model") { t.model = nil }
        return t
    }
}
