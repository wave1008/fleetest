// ClassPlacementRules.swift
// クラスの寄せ方(@RunOnSingleMachine / @RunOnSingleDevice / @RunInOrder。RR-8.3・DR-206)の判定。純粋関数。
// 「どの順で渡すか・選び方の検査・失敗の後に何を止めるか」はここ1箇所に置き、呼び手(CLI の1本ずつの実行・MCP・
// マシンの中のキュー・親の配り手)は写すだけにする。文言は呼び手ごとの対処文を持たない(判定の事実だけ)。

import Foundation

public enum ClassPlacementRules {

    /// "Class.method" → "Class"。ID の最初の "." より前(. が無ければ全体)
    public static func className(of scenarioID: String) -> String {
        guard let dot = scenarioID.firstIndex(of: ".") else { return scenarioID }
        return String(scenarioID[..<dot])
    }

    /// @Order の昇順 → 同値・nil は ID 順(nil は最後)。@RunInOrder の並びの唯一の定義
    public static func inOrderPrecedes(_ lhs: ScenarioInfo, _ rhs: ScenarioInfo) -> Bool {
        let l = lhs.order ?? Int.max, r = rhs.order ?? Int.max
        return l != r ? l < r : lhs.id < rhs.id
    }

    /// デバイスに寄せるクラスのメンバーを、そのクラスの最初のメンバーの位置へ連続して集める(`ordered(_:info:variant:)` の
    /// バリアントの無い版)
    public static func ordered(_ items: [ScenarioInfo]) -> [ScenarioInfo] {
        ordered(items, info: { $0 }, variant: { _ in nil })
    }

    /// 単位(シナリオ × バリアント)の並べ替え。デバイスに寄せるクラスの全単位を、そのクラスの最初の単位の位置へ連続して集める。
    /// **並びは「バリアントの出現順 → その中は inOrder なら order 順・singleDevice なら元の相対順」**(RR-8.3 の寄せる属性 =
    /// バリアントごとに続けて並べる)。singleMachine と属性無しは動かさない(安定)。バリアントが全部 nil なら従来と同じ並び。
    /// T を直接並べる(ID を鍵にした引き当てを持たない = 同じ ID の単位が複数あっても取り違えない)
    public static func ordered<T>(_ items: [T], info: (T) -> ScenarioInfo, variant: (T) -> String?) -> [T] {
        func binds(_ item: T) -> Bool { info(item).placement?.bindsDevice == true }
        var members: [String: [T]] = [:]
        for item in items where binds(item) { members[className(of: info(item).id), default: []].append(item) }
        var emitted = Set<String>()
        var result: [T] = []
        for item in items {
            guard binds(item) else { result.append(item); continue }
            let name = className(of: info(item).id)
            guard emitted.insert(name).inserted else { continue }
            let group = members[name] ?? []
            var variantOrder: [String?] = []
            for member in group where !variantOrder.contains(where: { $0 == variant(member) }) {
                variantOrder.append(variant(member))
            }
            for v in variantOrder {
                let sameVariant = group.filter { variant($0) == v }
                result += sameVariant.contains(where: { info($0).placement == .inOrder })
                    ? sameVariant.sorted { inOrderPrecedes(info($0), info($1)) } : sameVariant
            }
        }
        return result
    }

    /// @RunInOrder のクラスの選び方の検査。並び = all のうちそのクラスのメンバー(@Deleted / @Draft は selected に
    /// 入っているものだけ)を order 順に並べたもの。selected のメンバーがその先頭からの同じ長さの部分と一致しなければ文言を返す
    public static func selectionError(selected: [ScenarioInfo], all: [ScenarioInfo]) -> String? {
        let selectedIDs = Set(selected.map(\.id))
        var classes: [String: [ScenarioInfo]] = [:]
        for info in selected where info.placement == .inOrder {
            classes[className(of: info.id), default: []].append(info)
        }
        for name in classes.keys.sorted() {
            var universe: [String: ScenarioInfo] = [:]
            for info in all where info.placement == .inOrder && className(of: info.id) == name
                && ((!info.deleted && !info.draft) || selectedIDs.contains(info.id)) {
                universe[info.id] = info
            }
            for info in classes[name] ?? [] { universe[info.id] = info }
            let sequence = universe.values.sorted(by: inOrderPrecedes).map(\.id)
            let chosen = sequence.filter { selectedIDs.contains($0) }
            if Array(sequence.prefix(chosen.count)) == chosen { continue }
            let missing = sequence.prefix(chosen.count).filter { !selectedIDs.contains($0) }
            return "\(name) is a @RunInOrder class: select the whole class or a run of tests starting from its first test"
                + " (order: \(sequence.joined(separator: ", ")))."
                + " The selection \(chosen.joined(separator: ", ")) leaves out \(missing.joined(separator: ", ")) before it."
                + " To check a test in the middle, run the whole class (mark tests not written yet with @Draft)"
        }
        return nil
    }

    /// --failed の展開: 失敗した単位を含む @RunInOrder のクラスは、同じバリアントのそのクラスの全メンバー(@Deleted / @Draft を除く)を足す
    public static func expandingFailed(_ failed: Set<ScenarioUnitKey>, all: [ScenarioInfo]) -> Set<ScenarioUnitKey> {
        let inOrderIDs = Set(all.filter { $0.placement == .inOrder }.map(\.id))
        let failedClasses = Set(failed.filter { inOrderIDs.contains($0.id) }
            .map { ClassVariantKey(className: className(of: $0.id), variant: $0.variant) })
        guard !failedClasses.isEmpty else { return failed }
        var result = failed
        for info in all where info.placement == .inOrder && !info.deleted && !info.draft {
            for key in failedClasses where key.className == className(of: info.id) {
                result.insert(ScenarioUnitKey(id: info.id, variant: key.variant))
            }
        }
        return result
    }

    /// レスポンス計測の run に @RunInOrder のクラスがあれば断る文言
    public static func measurementError(_ selected: [ScenarioInfo]) -> String? {
        let names = Set(selected.filter { $0.placement == .inOrder }.map { className(of: $0.id) }).sorted()
        guard !names.isEmpty else { return nil }
        return "response measurement does not support @RunInOrder classes (\(names.joined(separator: ", ")));"
            + " remove them from the selection"
    }

    /// --broadcast / --fleet(split なし)で寄せる属性のクラスがあれば1行
    public static func sharedRunNotice(_ selected: [ScenarioInfo], mode: String) -> String? {
        var attributes: [String: ClassPlacement] = [:]
        for info in selected { if let p = info.placement { attributes[className(of: info.id)] = p } }
        guard !attributes.isEmpty else { return nil }
        let list = attributes.keys.sorted().map { "\($0) (\(attributes[$0]!.attributeName))" }.joined(separator: ", ")
        return "\(mode): these classes run on several devices at the same time, so keeping them on one machine or device does not apply: \(list)"
            + (attributes.values.contains(.inOrder) ? " (@RunInOrder still keeps its order on each device)" : "")
    }

    /// @RunOnSingleMachine のクラスのうち、2つ以上の OS にまたがるものに、全部の OS を持つエントリが1つも無ければ文言
    /// (1つの OS だけのクラスは対象外 = OS を持つデバイスが無い場合は対象外スキップの経路が扱う)
    public static func singleMachineCoverageError(
        _ selected: [ScenarioInfo], defaultPlatform: String,
        entries: [(label: String, platforms: Set<String>)]
    ) -> String? {
        var needs: [String: Set<String>] = [:]
        for info in selected where info.placement == .singleMachine {
            needs[className(of: info.id), default: []].insert(info.platform ?? defaultPlatform)
        }
        for name in needs.keys.sorted() {
            let need = needs[name] ?? []
            guard need.count > 1, !entries.contains(where: { need.isSubset(of: $0.platforms) }) else { continue }
            let perMachine = entries.map { "\($0.label): \($0.platforms.sorted().joined(separator: "+"))" }
                .joined(separator: "; ")
            return "\(name) is a @RunOnSingleMachine class that runs on \(need.sorted().joined(separator: " and ")),"
                + " but no machine in the profile has devices for all of them (\(perMachine))."
                + " Split the class by @TestClass(platform:), or put devices for both OSes on one machine"
        }
        return nil
    }

    public static func notRunReason(failedID: String) -> String {
        "not run: the earlier test \(failedID) in this @RunInOrder class failed"
    }

    public static func orphanReason(placement: ClassPlacement, className: String, lane: String) -> String {
        "not run: \(className) is kept on one device (\(placement.attributeName)) and the device \(lane) could not be revived"
    }

    /// @RunInOrder のテストの実行順の注記。inOrder 以外・classMembers に無ければ nil
    public static func positionNotice(_ info: ScenarioInfo, classMembers: [ScenarioInfo]) -> String? {
        guard info.placement == .inOrder else { return nil }
        let sequence = classMembers.sorted(by: inOrderPrecedes)
        guard let index = sequence.firstIndex(where: { $0.id == info.id }) else { return nil }
        return "@RunInOrder: test \(index + 1) of \(sequence.count) in \(className(of: info.id))"
    }
}

/// @RunInOrder の「失敗したら残りは実行しない」の記帳。レーンごとに、失敗したクラス × バリアント → 失敗した単位
/// (他のバリアントのまとまりは止めない)
public struct InOrderGate: Sendable {
    private var failed: [String: [ClassVariantKey: ScenarioUnitKey]] = [:]

    public init() {}

    private static func key(_ info: ScenarioInfo, _ variant: String?) -> ClassVariantKey {
        ClassVariantKey(className: ClassPlacementRules.className(of: info.id), variant: variant)
    }

    public func skipReason(for info: ScenarioInfo, variant: String?, lane: String) -> String? {
        guard info.placement == .inOrder, let failedUnit = failed[lane]?[Self.key(info, variant)] else { return nil }
        return ClassPlacementRules.notRunReason(failedID: failedUnit.description)
    }

    public mutating func record(_ info: ScenarioInfo, variant: String?, lane: String, passed: Bool) {
        guard !passed, info.placement == .inOrder else { return }
        let key = Self.key(info, variant)
        if failed[lane]?[key] == nil { failed[lane, default: [:]][key] = ScenarioUnitKey(id: info.id, variant: variant) }
    }
}
