// ft_run_scenario の台選び(DR-237): `@RequiresDevice` / `@ExcludesDevice` の宣言があるときだけ、台の性質を観測して決める。
// 判定は `DeviceRequirementGate`(run と共有)だけ。ここは候補の中から1台を選び、合わないテストを名指しするだけで、条件の照合を持たない。
// 観測は呼び出しごとに読み直す(常駐プロセスに古い観測を残さない)。宣言が1つも無い呼び出しは観測もしない(従来と同一)。

import Foundation
import FTAndroid
import FTBridgeClient
import FTCore

enum ScenarioDeviceSelection {

    /// 候補の台。traits nil = 観測していない(宣言があれば読めなかった扱い)
    struct Candidate {
        let name: String
        let traits: DeviceTraits?
    }

    enum Result {
        /// `chosen` = 候補の添字。`runnable` = その台で走らせるテスト(元の順)・`skipped` = 対象外にして名指しするテスト
        case run(chosen: Int, runnable: [ScenarioInfo], skipped: [(id: String, reason: String)])
        /// どの台でも1本も走らせられない(全台が読めて、どれも合わない)。非エラーで返す
        case nothingApplicable(skipped: [(id: String, reason: String)])
        /// 台の性質が読めず判定できない(事実だけ)。エラーで返す
        case unreadable(message: String)
    }

    static func isDeclared(_ infos: [ScenarioInfo]) -> Bool {
        infos.contains { !($0.deviceRequirements?.isEmpty ?? true) }
    }

    /// nil = 宣言が無い(`candidates` を呼ばない = 観測しない)。台が無いときも nil(後段が自分の言葉で断る)
    static func select(infos: [ScenarioInfo], candidates: () -> [Candidate]) -> Result? {
        guard isDeclared(infos) else { return nil }
        let cands = candidates()
        guard !cands.isEmpty else { return nil }
        let fitting = cands.map { cand in
            infos.map { DeviceRequirementGate.fit($0.deviceRequirements, traits: cand.traits) == .fits }
        }
        let best = fitting.map { $0.filter { $0 }.count }
        if let top = best.max(), top > 0, let chosen = best.firstIndex(of: top) {
            var runnable: [ScenarioInfo] = []
            var skipped: [(id: String, reason: String)] = []
            var unreadable: [String] = []
            for (i, info) in infos.enumerated() {
                if fitting[chosen][i] { runnable.append(info); continue }
                switch conclusion(info, lanes: [cands[chosen]]) {
                case .failed(let reason)?: unreadable.append("\(info.id): \(reason)")
                case .skipped(let reason)?: skipped.append((info.id, reason))
                case nil: runnable.append(info)
                }
            }
            if !unreadable.isEmpty { return .unreadable(message: unreadable.joined(separator: "\n")) }
            return .run(chosen: chosen, runnable: runnable, skipped: skipped)
        }
        var skipped: [(id: String, reason: String)] = []
        var unreadable: [String] = []
        for info in infos {
            switch conclusion(info, lanes: cands) {
            case .failed(let reason)?: unreadable.append("\(info.id): \(reason)")
            case .skipped(let reason)?: skipped.append((info.id, reason))
            case nil: break
            }
        }
        if !unreadable.isEmpty { return .unreadable(message: unreadable.joined(separator: "\n")) }
        return .nothingApplicable(skipped: skipped)
    }

    private static func conclusion(_ info: ScenarioInfo, lanes: [Candidate]) -> DeviceRequirementGate.Conclusion? {
        guard let set = info.deviceRequirements, !set.isEmpty else { return nil }
        // 観測していない台は全性質が読めなかった扱い(`fit` と同じ)
        let devices = lanes.map { (id: $0.name, traits: $0.traits ?? DeviceTraits(platform: "?", physical: false)) }
        if lanes.contains(where: { $0.traits == nil }) {
            return .failed(reason: "could not read the device traits needed for the declared device conditions"
                + " (\(DeviceRequirementGate.describe(set))): "
                + lanes.filter { $0.traits == nil }.map { "\($0.name): unreadable (traits)" }.joined(separator: "; "))
        }
        return DeviceRequirementGate.conclusion(set, lanes: devices)
    }

    // MARK: - 観測(呼び出しごとに読み直す・キャッシュしない)

    /// プロファイルの候補(同じ OS の台。プロファイルの記述順)
    static func profileCandidates(devices: [ResolvedDevice]) -> [Candidate] {
        let entries = devices.map { DeviceMachineGrouping.CatalogEntry(platform: $0.platform, spec: $0.spec) }
        let traits = DeviceTraitsObservation.observe(entries: entries, simctlJSON: { DeviceTraitsObservation.localSimctlJSON() })
        return devices.map { Candidate(name: $0.name, traits: traits[$0.name]) }
    }

    /// udid / serial で直に指した1台
    static func directCandidate(_ connection: DriverConnection) -> Candidate {
        let name = connection.udid ?? connection.serial ?? "device"
        let traits: DeviceTraits
        if connection.platform == "ios" {
            traits = DeviceTraitsObservation.portTraits(
                udid: connection.udid, physical: connection.physical,
                simctlJSON: connection.physical ? nil : DeviceTraitsObservation.localSimctlJSON(),
                physicalDevices: connection.physical ? try? IOSPhysicalDeviceCatalog.devices() : nil)
        } else {
            traits = connection.serial.map(DeviceTraitsObservation.serialTraits(serial:))
                ?? DeviceTraits(platform: "android", physical: false)
        }
        return Candidate(name: name, traits: TraitsInjection.apply(traits, key: name, environment: ProcessInfo.processInfo.environment))
    }

    static func skippedLines(_ skipped: [(id: String, reason: String)]) -> [String] {
        skipped.map { "⏭ \($0.id): \($0.reason)" }
    }
}
