// 台の絞り込み(`ResolvedProfile.limitingDevices`)と、一覧の前に外した台の検算が使う、台の条件(DR-237)の判定の入口。
// 合う・合わないの判定そのものは `DeviceRequirementMatch` の1箇所(ここは ResolvedDevice への写しだけ)。

import Foundation

public enum DeviceRequirementTrim {
    /// 台の性質。観測(`traits`。鍵 = プロファイルの台の名前 = 1機械の中で一意)は**この機械の台にだけ**効かせる
    /// (別の機械の同名の台に手元の観測を当てない)。無ければ platform と physical だけ確定・残りは読めなかった。
    /// 別の機械の台の観測を足すのは、ここ1箇所を直す
    public static func traits(of device: ResolvedDevice, observed: [String: DeviceTraits]) -> DeviceTraits {
        if MachineDispatch.normalize(device.spec.machine) == nil, let known = observed[device.name] { return known }
        return DeviceTraits(platform: device.platform, physical: device.spec.isPhysical)
    }

    /// 識別子(機械 + 名前。同着の決め方 = 辞書順の最小に使う)
    static func id(of device: ResolvedDevice) -> String {
        "\(MachineDispatch.normalize(device.spec.machine) ?? "local")/\(device.name)"
    }

    private static func lanes(_ devices: [ResolvedDevice], observed: [String: DeviceTraits]) -> [DeviceRequirementMatch.Device] {
        devices.map { (id: id(of: $0), traits: traits(of: $0, observed: observed)) }
    }

    /// 条件の組ごとに合う台を1台(`DeviceRequirementMatch.mustKeep`)。宣言が無ければ空。
    /// **合う台が無い組は、読めなかった台を1台残す** —— この run で使う台に読めない台があれば赤(DR-237)。本数で絞る段で
    /// 落とすと、残った読めた台だけで「合う台が無い」の緑に化けた(陽性対照 11/27: Duo の foldable を読めなくした run が緑)
    public static func mustKeep(devices: [ResolvedDevice], requirements: [DeviceRequirementSet],
                                traits observed: [String: DeviceTraits]) -> Set<ResolvedDevice> {
        let sets = requirements.filter { !$0.isEmpty }
        guard !sets.isEmpty else { return [] }
        let all = lanes(devices, observed: observed)
        var ids = DeviceRequirementMatch.mustKeep(sets: sets, devices: all)
        for set in Set(sets) {
            let split = DeviceRequirementMatch.partition(set, devices: all)
            if split.fits.isEmpty, let unreadable = split.unreadable.min() { ids.insert(unreadable) }
        }
        return Set(devices.filter { ids.contains(id(of: $0)) })
    }

    /// 一覧の前に外した台が条件に要ったか(`full` には合う台があるのに `kept` には無い組)の事実。空 = 要らなかった。
    /// 英語(利用者が読む失敗の本文)
    public static func shortfall(requirements: [DeviceRequirementSet], full: [ResolvedDevice], kept: [ResolvedDevice],
                                 traits observed: [String: DeviceTraits]) -> [String] {
        var seen = Set<DeviceRequirementSet>()
        var facts: [String] = []
        for set in requirements where !set.isEmpty && seen.insert(set).inserted {
            let inKept = DeviceRequirementMatch.partition(set, devices: lanes(kept, observed: observed)).fits
            guard inKept.isEmpty else { continue }
            let inFull = DeviceRequirementMatch.partition(set, devices: lanes(full, observed: observed))
            if let needed = inFull.fits.min() {
                facts.append("\(DeviceRequirementGate.describe(set)) needs \(needed), which was left out before the scenario list was known")
                continue
            }
            // 合う台が無く、読めなかった台を外していた = 赤の根拠を落としている(残っていれば読めない事実で赤になる)
            let unreadableKept = DeviceRequirementMatch.partition(set, devices: lanes(kept, observed: observed)).unreadable
            if unreadableKept.isEmpty, let unread = inFull.unreadable.min() {
                facts.append("\(DeviceRequirementGate.describe(set)) could not be checked on \(unread), which was left out before"
                    + " the scenario list was known")
            }
        }
        return facts
    }
}
