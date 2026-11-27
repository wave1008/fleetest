// 対象外の回し直し(DR-214)で「同じ種類の台」を見分ける、iOS シミュレータの種類の観測。
// 種類 = simctl の deviceTypeIdentifier + runtime(`SimulatorCatalog.kind(of:)`)。**プロファイルの `model` は表示専用で使わない**
// (読むと折りたたみ機を取りこぼして誤った緑になる)。実機・解決できない台が1台でもあるエントリは不明 = 載せない(部分的な知識で覆わない)。

import FTBridgeClient
import FTCore
import FTRemote
import Foundation

enum IOSDeviceKindResolver {
    /// 秒。ssh 越しの1回の上限 = 接続の上限(`SSHOptions.connectTimeoutSeconds`)+ 向こうの simctl の上限(`SimulatorCatalog.simctlTimeoutSeconds`)。
    /// 尽きたらその機械は不明 = 台ごとの回し直しに戻り、配り手が1行言う(遅くなるだけで誤らない)
    static let remoteTimeoutSeconds = Double(SSHOptions.connectTimeoutSeconds) + SimulatorCatalog.simctlTimeoutSeconds

    /// 純粋部。nil = 不明(iOS の指定が無い・実機を含む・simctl の出力が読めない・1台でも解決できない)。
    /// 解決は `BridgeProvisioner` と同じ `SimulatorCatalog.resolve`
    static func kinds(simctlOutput: String?, specs: [DeviceSpec]) -> Set<String>? {
        guard !specs.isEmpty, !specs.contains(where: \.isPhysical),
              let data = simctlOutput?.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let devices = SimulatorCatalog.devices(simctlJSON: json) else { return nil }
        let blueprints = SimulatorCatalog.blueprints(simctlJSON: json)
        var result: Set<String> = []
        for spec in specs {
            guard let info = try? SimulatorCatalog.resolve(spec: spec, in: devices),
                  let blueprint = blueprints[info.udid] else { return nil }
            result.insert(SimulatorCatalog.kind(of: blueprint))
        }
        return result
    }

    /// `DynamicDispatcher.entryKinds` の本番の実体。エントリ番号 → 観測した種類。機械ごとに1回の simctl を並行に撃つ
    static func entryKinds(project: TestProject, profileName: String, groups: [DeviceMachineRunner.Group],
                           overrides: [String: RunProfileSetValue]) -> [Int: Set<String>] {
        let entries = ProfileResolver.runDeviceEntries(
            project: project, runProfileName: profileName, overrides: overrides)
        let jobs: [(entry: Int, machine: String?, specs: [DeviceSpec])] = groups.enumerated().compactMap { index, group in
            let specs = entries.filter {
                $0.platform == "ios" && MachineDispatch.normalize($0.machine) == MachineDispatch.normalize(group.machine)
                    && group.deviceNames.contains($0.name)
            }.map(\.spec)
            return specs.isEmpty ? nil : (index, group.machine, specs)
        }
        let results = LockedValue<[Int: Set<String>]>([:])
        DispatchQueue.concurrentPerform(iterations: jobs.count) { i in
            let job = jobs[i]
            if let kinds = kinds(simctlOutput: simctlOutput(machine: job.machine), specs: job.specs) {
                results.withLock { $0[job.entry] = kinds }
            }
        }
        return results.value
    }

    /// その機械の `simctl list -j devices`。**終了コードを見る**(失敗 = 不明。空として読まない)
    static func simctlOutput(machine: String?) -> String? {
        let words = ["xcrun", "simctl", "list", "-j", "devices"]
        if MachineDispatch.isExplicitLocal(machine) || machine == nil {
            return (try? Shell.run(words, timeout: SimulatorCatalog.simctlTimeoutSeconds))?.outputIfSucceeded
        }
        guard let machine, let resolved = try? RemoteHostResolver.resolve(rawHost: machine, remoteDirOverride: nil) else {
            return nil
        }
        return (try? Shell.run(
            ["ssh"] + SSHOptions.batchConnectArgs + SSHOptions.keepAliveArgs
                + [resolved.hostSpec.sshTarget, words.joined(separator: " ")],
            timeout: remoteTimeoutSeconds))?.outputIfSucceeded
    }
}
