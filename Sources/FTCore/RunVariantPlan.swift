// RunVariantPlan.swift
// run の入口が選んだシナリオ(ID の集合)をバリアントへ展開する1か所(`fleetest run` / `fleetest api run` / 機械分担 / 複数対象が共有)。
// 実行の単位 = シナリオ × バリアント。並びは「シナリオの順 × バリアントの宣言の順」。
// 絞り込み: `--variant`(名前)・`--scenario ID@variant`(単位の名指し)・`--failed`(失敗した単位)は**積集合**(`--scenario` の複数指定の中は和集合)。

import Foundation

public struct RunVariantPlan: Sendable {
    /// 展開するバリアント(宣言順。`--variant` で絞った後)。空 = バリアントの無い run
    public let variants: [ResolvedVariant]
    /// 宣言したバリアント全部(`--variant` で絞る前。run の記録の `variants` と `--failed` の集約の母集団)
    public let declared: [ResolvedVariant]
    /// `--scenario` の単位の名指し(`ID@variant`)。nil = 名指しなし。ID の部分はクラス名も受ける
    private let named: [(id: String, variant: String?)]?
    /// `--failed` の失敗した単位。nil = 絞らない
    private let failedUnits: Set<ScenarioUnitKey>?

    public static let none = RunVariantPlan(variants: [], declared: [], named: nil, failedUnits: nil)

    private init(variants: [ResolvedVariant], declared: [ResolvedVariant], named: [(id: String, variant: String?)]?, failedUnits: Set<ScenarioUnitKey>?) {
        self.variants = variants
        self.declared = declared
        self.named = named
        self.failedUnits = failedUnits
    }

    public var hasVariants: Bool { !variants.isEmpty }

    /// 展開に使うバリアント名(バリアントの無い run は [nil])
    public var variantNames: [String?] { variants.isEmpty ? [nil] : variants.map(\.name) }

    /// 宣言順の番号(`DynamicSplit.Scenario.variantRank`。寄せるクラスの並び「バリアントごとに続けて」の鍵)
    public func rank(of variant: String?) -> Int {
        variant.flatMap { name in variants.firstIndex { $0.name == name } } ?? 0
    }

    /// `--failed` の記録(失敗した単位)で絞る。呼び手は `LastResultsStore.failedIDs` の結果を渡す
    public func restrictingToFailed(_ units: Set<ScenarioUnitKey>) -> RunVariantPlan {
        RunVariantPlan(variants: variants, declared: declared, named: named, failedUnits: units)
    }

    public func allows(_ unit: ScenarioUnitKey) -> Bool {
        if let failedUnits, !failedUnits.contains(unit) { return false }
        if let named {
            let hit = named.contains { selector in
                ScenarioSelection.selects(selector.id, scenarioID: unit.id)
                    && (selector.variant == nil || selector.variant == unit.variant)
            }
            if !hit { return false }
        }
        return true
    }

    /// 選んだシナリオ × バリアントの単位(シナリオの順 × 宣言の順)。名指し・`--failed` で外れた単位は含まない
    public func units(of infos: [ScenarioInfo]) -> [ScenarioUnitKey] {
        infos.flatMap { info in variantNames.map { info.unitKey(variant: $0) } }.filter(allows)
    }

    /// 単位を持つシナリオだけ(ID 単位の検査・対象外の仕分けへ渡す)
    public func infos(_ infos: [ScenarioInfo]) -> [ScenarioInfo] {
        let ids = Set(units(of: infos).map(\.id))
        return infos.filter { ids.contains($0.id) }
    }

    public func items(of infos: [ScenarioInfo]) -> [ScenarioRunItem] {
        let byID = Dictionary(infos.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        return units(of: infos).compactMap { unit in byID[unit.id].map { ScenarioRunItem(info: $0, variant: unit.variant) } }
    }

    public var declaredNames: [String] { declared.map(\.name) }

    /// 組み立て。`declared` = プロファイルの解決済みバリアント(プロファイル無しは空)・`variantNames` = `--variant`・
    /// `selectors` = `--scenario` の生の指定(`ID` / `Class` / `ID@variant`)
    public static func make(declared: [ResolvedVariant], variantNames: [String], selectors: [String],
                            profile: String?) throws -> RunVariantPlan {
        var chosen = declared
        if !variantNames.isEmpty {
            guard !declared.isEmpty else {
                throw RunVariantPlanError.noVariantsDeclared(option: "--variant", profile: profile)
            }
            let unknown = variantNames.filter { name in !declared.contains { $0.name == name } }
            if let first = unknown.first {
                throw RunVariantPlanError.unknownVariant(name: first, available: declared.map(\.name), profile: profile)
            }
            chosen = declared.filter { variantNames.contains($0.name) }
        }
        var named: [(id: String, variant: String?)]?
        if selectors.contains(where: { $0.contains("@") }) {
            var parsed: [(id: String, variant: String?)] = []
            for selector in selectors {
                guard let key = ScenarioUnitKey.parse(selector) else {
                    throw RunVariantPlanError.malformedSelector(selector)
                }
                if let variant = key.variant {
                    guard !declared.isEmpty else {
                        throw RunVariantPlanError.noVariantsDeclared(option: "--scenario \(selector)", profile: profile)
                    }
                    guard declared.contains(where: { $0.name == variant }) else {
                        throw RunVariantPlanError.unknownVariant(name: variant, available: declared.map(\.name), profile: profile)
                    }
                }
                parsed.append((key.id, key.variant))
            }
            named = parsed
        }
        return RunVariantPlan(variants: chosen, declared: declared, named: named, failedUnits: nil)
    }
}

public enum RunVariantPlanError: Error, LocalizedError {
    case noVariantsDeclared(option: String, profile: String?)
    case unknownVariant(name: String, available: [String], profile: String?)
    case malformedSelector(String)

    public var errorDescription: String? {
        switch self {
        case .noVariantsDeclared(let option, let profile):
            let where_ = profile.map { "run profile \($0) declares no variants" } ?? "there is no run profile (variants come from a run profile's \"variants\")"
            return "\(option): \(where_)"
        case .unknownVariant(let name, let available, let profile):
            return "unknown variant \"\(name)\"" + (profile.map { " in run profile \($0)" } ?? "")
                + " (available: \(available.joined(separator: ", ")))"
        case .malformedSelector(let selector):
            return "\(selector): not a scenario selector (use ID, Class or ID@variant)"
        }
    }
}

extension ScenarioSelection {
    /// `--scenario` の指定から `@variant` を外した ID の並び(初出順・重複は1回。`resolve*` へ渡す)。
    /// 単位の名指しの意味は `RunVariantPlan.make` が持つ(ここは ID の選択だけ)
    public static func idsStrippingVariants(_ selectors: [String]) -> [String] {
        var seen = Set<String>()
        var ids: [String] = []
        for selector in selectors {
            let id = ScenarioUnitKey.parse(selector)?.id ?? selector
            if seen.insert(id).inserted { ids.append(id) }
        }
        return ids
    }
}
