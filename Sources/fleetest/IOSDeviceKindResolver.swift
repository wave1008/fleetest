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

    /// 純粋部。nil = 観測できなかった(iOS の指定が無い・simctl の出力が読めない・1台でも解決できない)。
    /// 空集合 = 観測の対象外(実機を含む = simctl の種類が無い。覆わない点は nil と同じだが、失敗ではないので配り手は言わない)。
    /// 解決は `BridgeProvisioner` と同じ `SimulatorCatalog.resolve`
    static func kinds(simctlOutput: String?, specs: [DeviceSpec]) -> Set<String>? {
        guard !specs.isEmpty else { return nil }
        if specs.contains(where: \.isPhysical) { return [] }
        guard let data = simctlOutput?.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let devices = SimulatorCatalog.devices(simctlJSON: json) else { return nil }
        // 台の性質の観測(`DeviceTraitsObserver`)と同じ解決(`resolveSimulators`)。1台でも解決できなければ不明
        let resolved = SimulatorCatalog.resolveSimulators(specs: specs, devices: devices, simctlJSON: json)
        guard !resolved.contains(where: { $0 == nil }) else { return nil }
        let result = Set(resolved.compactMap { $0.map { SimulatorCatalog.kind(of: $0.blueprint) } })
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
            if let kinds = kinds(simctlOutput: cachedSimctlOutput(machine: job.machine), specs: job.specs) {
                results.withLock { $0[job.entry] = kinds }
            }
        }
        return results.value
    }

    /// 機械 → `simctl list -j devicetypes devices` の出力(nil = 読めなかった)。**プロセスで機械ごとに1回だけ撃つ** —— 複数対象の run は対象ごとに
    /// 配り手を作るので、引くたびに撃つと同じ機械へ ssh が対象の数だけ重なる。run の開始の時点の一覧 = 子の供給と同じ頃の観測
    private static let outputs = LockedValue<[String: String?]>([:])
    /// 機械ごとの撃つ順番(同じ機械を同時に2回撃たない。待った側は控えを読む)
    private static let fetchLocks = LockedValue<[String: NSLock]>([:])

    static func cachedSimctlOutput(machine: String?) -> String? {
        let key = MachineDispatch.isExplicitLocal(machine) || machine == nil ? "local" : machine!
        let lock = fetchLocks.withLock { locks -> NSLock in
            if let existing = locks[key] { return existing }
            let created = NSLock()
            locks[key] = created
            return created
        }
        lock.lock()
        defer { lock.unlock() }
        if let hit = outputs.withLock({ $0[key] }) { return hit }
        let output = simctlOutput(machine: machine)
        outputs.withLock { $0[key] = .some(output) }
        return output
    }

    /// その機械の `simctl list -j devicetypes devices`。**終了コードを見る**(失敗 = 不明。空として読まない)。
    /// 中断で止まる(`abortable` = `BuildAbort` に載る。ssh は中断のリレーの例外にしない = process-lifecycle.md)
    static func simctlOutput(machine: String?) -> String? {
        // devicetypes も読む = 台の性質の観測(`DeviceTraitsObserver`)が同じ出力を使う(simctl を2経路で読まない)
        let words = ["xcrun", "simctl", "list", "-j", "devicetypes", "devices"]
        if MachineDispatch.isExplicitLocal(machine) || machine == nil {
            return (try? Shell.run(words, timeout: SimulatorCatalog.simctlTimeoutSeconds, abortable: true))?.outputIfSucceeded
        }
        guard let machine, let resolved = try? RemoteHostResolver.resolve(rawHost: machine, remoteDirOverride: nil) else {
            return nil
        }
        return (try? Shell.run(
            ["ssh"] + SSHOptions.batchConnectArgs + SSHOptions.keepAliveArgs
                + [resolved.hostSpec.sshTarget, words.joined(separator: " ")],
            timeout: remoteTimeoutSeconds, abortable: true))?.outputIfSucceeded
    }
}
