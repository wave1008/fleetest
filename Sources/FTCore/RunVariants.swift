// RunVariants.swift
// 実行プロファイルの `variants`(名前付きの表示条件の一覧)の宣言型と解決。
// 解決した値は「指定あり」(合わせられなければそのシナリオを失敗にする = 3.4)。展開(シナリオ × バリアント)は `RunVariantPlan`。

import Foundation

public struct RunVariantEntry: Codable, Sendable, Equatable {
    public var name: String
    public var appearance: String?
    public var textSize: String?
    public var orientation: String?

    public init(name: String, appearance: String? = nil, textSize: String? = nil, orientation: String? = nil) {
        self.name = name
        self.appearance = appearance
        self.textSize = textSize
        self.orientation = orientation
    }

    static let knownKeys: Set<String> = ["name", "appearance", "textSize", "orientation"]

    private struct AnyKey: CodingKey {
        var stringValue: String
        var intValue: Int? { nil }
        init?(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { nil }
    }

    /// 知らないキーはデコードの失敗にする(タイポが黙って無視されるとバリアントが基準のまま緑になる)
    public init(from decoder: Decoder) throws {
        let any = try decoder.container(keyedBy: AnyKey.self)
        let unknown = any.allKeys.map(\.stringValue).filter { !Self.knownKeys.contains($0) }.sorted()
        if let first = unknown.first {
            throw DecodingError.dataCorruptedError(
                forKey: AnyKey(stringValue: first)!, in: any,
                debugDescription: "unknown key \"\(first)\" in a variant (known: name, appearance, textSize, orientation)")
        }
        name = try any.decode(String.self, forKey: AnyKey(stringValue: "name")!)
        appearance = try any.decodeIfPresent(String.self, forKey: AnyKey(stringValue: "appearance")!)
        textSize = try any.decodeIfPresent(String.self, forKey: AnyKey(stringValue: "textSize")!)
        orientation = try any.decodeIfPresent(String.self, forKey: AnyKey(stringValue: "orientation")!)
    }

    public func encode(to encoder: Encoder) throws {
        var any = encoder.container(keyedBy: AnyKey.self)
        try any.encode(name, forKey: AnyKey(stringValue: "name")!)
        try any.encodeIfPresent(appearance, forKey: AnyKey(stringValue: "appearance")!)
        try any.encodeIfPresent(textSize, forKey: AnyKey(stringValue: "textSize")!)
        try any.encodeIfPresent(orientation, forKey: AnyKey(stringValue: "orientation")!)
    }
}

public enum RunVariantResolution {
    /// バリアント名の規則(先頭は英小文字)
    public static let nameRule = "must match [a-z][a-z0-9-]* (lowercase letters, digits and hyphens; starts with a letter)"

    public static func isValidName(_ name: String) -> Bool {
        guard let first = name.unicodeScalars.first, ("a"..."z").contains(first) else { return false }
        return name.unicodeScalars.allSatisfy { ("a"..."z").contains($0) || ("0"..."9").contains($0) || $0 == "-" }
    }

    /// 検査の問題を全部返す(空 = 正常)。実行前の解決と validate-profile が同じ文言を使う
    public static func problems(entries: [RunVariantEntry], topOrientation: String?) -> [String] {
        var problems: [String] = []
        if entries.isEmpty { return ["\"variants\" must not be empty (omit it to run without variants)"] }
        var seen = Set<String>()
        for entry in entries {
            if !isValidName(entry.name) {
                problems.append("variant name \"\(entry.name)\" \(nameRule)")
            } else if !seen.insert(entry.name).inserted {
                problems.append("duplicate variant name \"\(entry.name)\"")
            }
            if let raw = entry.appearance, FTAppearance.parse(raw) == nil {
                problems.append("variant \"\(entry.name)\": appearance \"\(raw)\" \(FTAppearance.rule)")
            }
            if let raw = entry.textSize, FTTextSize.parse(raw) == nil {
                problems.append("variant \"\(entry.name)\": textSize \"\(raw)\" \(FTTextSize.rule)")
            }
            if let raw = entry.orientation, FTOrientation.parse(raw) == nil {
                problems.append("variant \"\(entry.name)\": orientation \"\(raw)\" \(RunProfileDocument.orientationRule)")
            }
        }
        // 向きを書くバリアントがあるなら全バリアントが向きを持つ(各シナリオが起動直後に必ず自分の向きへ回す。前のシナリオの向きを残さない)
        if topOrientation == nil, entries.contains(where: { $0.orientation != nil }) {
            let missing = entries.filter { $0.orientation == nil }.map(\.name)
            if !missing.isEmpty {
                problems.append("some variants set \"orientation\" but \(missing.map { "\"\($0)\"" }.joined(separator: ", ")) do not"
                    + " (when any variant sets it, every variant must, or the profile must set a top-level \"orientation\")")
            }
        }
        return problems
    }

    /// 解決: 書かないキーはプロファイルの最上位の同じキー → 基準の値(light / default)。向きは最上位も無ければ nil(どのバリアントも書かない run だけ)
    public static func resolve(entries: [RunVariantEntry], topAppearance: String?, topTextSize: String?,
                               topOrientation: String?, run: String) throws -> [ResolvedVariant] {
        if let first = problems(entries: entries, topOrientation: topOrientation).first {
            throw ProfileError.invalidVariants(run: run, reason: first)
        }
        return entries.map { entry in
            ResolvedVariant(
                name: entry.name,
                appearance: (entry.appearance ?? topAppearance).flatMap(FTAppearance.parse) ?? .light,
                textSize: (entry.textSize ?? topTextSize).flatMap(FTTextSize.parse) ?? .default,
                orientation: entry.orientation ?? topOrientation)
        }
    }

    /// `variants` のあるプロファイルでは表示条件の `--set` を受けない(名前と中身がずれる)
    public static let rejectedSetKeys = ["appearance", "textSize", "orientation"]

    public static func rejectSetOverrides(_ overrides: [String: RunProfileSetValue], run: String) throws {
        if let key = rejectedSetKeys.first(where: { overrides[$0] != nil }) {
            throw ProfileError.invalidVariants(
                run: run, reason: "--set \(key) cannot be used with a run profile that declares variants (add a variant instead)")
        }
    }
}
