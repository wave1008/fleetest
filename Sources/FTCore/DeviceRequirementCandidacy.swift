// 機械をまたぐ run(DR-237)で、台の条件を持つ単位をどの機械(エントリ)へ配ってよいかの判定の1箇所。
// 静的な割り振り(FleetSplit)・動的な割り振り(DynamicDispatcher の試した扱い)・親の対象外の仕分けが同じ関数を通る。

import Foundation

/// 親が観測した台の性質。鍵 = 機械の鍵(`DeviceRequirementTrim.machineKey`)→ 台の名前 → 性質。
/// 台の名前は1機械の中でしか一意でないので、機械をまたぐ観測は必ずこの2段で持つ
public typealias MachineDeviceTraits = [String: [String: DeviceTraits]]

public enum DeviceRequirementCandidacy {
    /// 候補 = その機械に、単位の OS(nil = どちらでも)の台があり、うち1台でも条件に合う(`.fits`)か読めなかった(`.unreadable`)。
    /// 読めなかった台は候補に数える(合わないと決めつけない = 読めない事実で、その機械の子が赤にする)。
    /// 宣言なし・空の条件は台の性質を見ずに常に候補(従来の配り方と同一)
    public static func isCandidate(_ requirements: DeviceRequirementSet?, platform: String?,
                                   devices: [DeviceTraits]) -> Bool {
        guard let requirements, !requirements.isEmpty else { return true }
        return devices.contains { device in
            guard platform == nil || device.platform == platform else { return false }
            switch DeviceRequirementMatch.fit(requirements, device) {
            case .fits, .unreadable: return true
            case .unfit: return false
            }
        }
    }

    /// 親の観測から、ある機械の子へ運ぶ性質(台の名前 → 性質。子は自分の機械の台しか知らない = 鍵は素の名前)
    public static func childTraits(_ observed: MachineDeviceTraits, machine: String?,
                                   deviceNames: [String]) -> [String: DeviceTraits] {
        guard let own = observed[DeviceRequirementTrim.machineKey(machine)] else { return [:] }
        let wanted = Set(deviceNames)
        return own.filter { wanted.contains($0.key) }
    }
}
