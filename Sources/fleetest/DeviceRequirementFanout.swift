// 機械をまたぐ run(`run` の機械分担・`api run` の機械分担・複数対象・`--fleet --split`)の台の条件(DR-237)。
// 親が機械ごとに台の性質を1回観測し(別の機械は `fleetest api device-traits` を remote exec で引く)、
// ①どの機械へ配ってよいか(候補)②各機械の子へ運ぶ性質、を決める。判定そのものは FTCore(`DeviceRequirementCandidacy`)。
// **宣言が無い run は観測しない**(ssh を1本も足さない = 今までと同一)。

import FTBridgeClient
import FTCore
import FTRemote
import Foundation

enum DeviceRequirementFanout {

    /// 観測の1口。key = `MachineDeviceTraits` の外側の鍵(機械分担は `DeviceRequirementTrim.machineKey`・`--fleet` はエントリ番号)
    struct Job: Sendable {
        let key: String
        /// nil / "local" = この機械
        let machine: String?
        let profile: String
        let entries: [DeviceMachineGrouping.CatalogEntry]
    }

    enum Fetched: Sendable, Equatable {
        case traits([String: DeviceTraits])
        /// 理由は1行(ログへそのまま出す)
        case failed(String)
    }

    typealias RemoteFetch = @Sendable (_ machine: String, _ project: String, _ profile: String) -> Fetched
    typealias LocalObserve = @Sendable (_ entries: [DeviceMachineGrouping.CatalogEntry]) -> [String: DeviceTraits]

    /// 秒。`remote exec` 1本の上限 = ssh の接続 ×2(`$HOME` の問い合わせと本体)+ 向こうの simctl + avdmanager の上限 + 余裕 30 秒
    /// (devicectl・JVM の起動は実測していない)。尽きたらその機械の台は読めなかった扱い(1行言う)= 遅くなるだけで誤らない
    static let remoteTimeoutSeconds: Double =
        Double(SSHOptions.connectTimeoutSeconds) * 2 + SimulatorCatalog.simctlTimeoutSeconds
        + DeviceTraitsObserver.avdManagerTimeoutSeconds + 30

    /// 全口を並行に観測する。**1機械の失敗は他へ波及しない**: 失敗した機械の台は platform / physical だけ確定(残りは読めなかった)にして
    /// 1行ログを出す。観測していない口(entries が空)は結果に載せない
    static func observe(project: String, jobs: [Job], remote: RemoteFetch, local: LocalObserve,
                        log: @Sendable (String) -> Void) -> MachineDeviceTraits {
        let results = LockedValue<MachineDeviceTraits>([:])
        DispatchQueue.concurrentPerform(iterations: jobs.count) { index in
            let job = jobs[index]
            guard !job.entries.isEmpty else { return }
            let observed: [String: DeviceTraits]
            if MachineDispatch.normalize(job.machine) == nil {
                observed = local(job.entries)
            } else {
                switch remote(job.machine!, project, job.profile) {
                case .traits(let traits): observed = traits
                case .failed(let reason):
                    log("→ could not read the device traits on \(job.machine!) (\(reason));"
                        + " its devices count as unreadable for the declared device conditions")
                    observed = [:]
                }
            }
            var perDevice: [String: DeviceTraits] = [:]
            for entry in job.entries {
                perDevice[entry.name] = observed[entry.name]
                    ?? DeviceTraits(platform: entry.platform, physical: entry.spec.isPhysical)
            }
            results.withLock { $0[job.key] = perDevice }
        }
        return results.value
    }

    /// 機械分担のグループ → 観測の口(台の名前で絞る。グループの machine のぶんだけ)
    static func jobs(profileName: String, groups: [DeviceMachineRunner.Group],
                     entries: [DeviceMachineGrouping.CatalogEntry]) -> [Job] {
        groups.map { group in
            let wanted = Set(group.deviceNames)
            return Job(key: DeviceRequirementTrim.machineKey(group.machine), machine: group.machine, profile: profileName,
                       entries: entries.filter {
                           MachineDispatch.normalize($0.machine) == MachineDispatch.normalize(group.machine)
                               && wanted.contains($0.name)
                       })
        }
    }

    static func observe(project: TestProject, profileName: String, groups: [DeviceMachineRunner.Group],
                        overrides: [String: RunProfileSetValue],
                        log: @Sendable (String) -> Void = { FleetRunner.log($0) }) -> MachineDeviceTraits {
        let entries = ProfileResolver.runDeviceEntries(project: project, runProfileName: profileName, overrides: overrides)
        return observe(project: project.name, jobs: jobs(profileName: profileName, groups: groups, entries: entries),
                       remote: liveFetch, local: { DeviceTraitsObserver.observe(entries: $0) }, log: log)
    }

    // MARK: - 宣言の有無・候補

    static func declares(_ selected: [ScenarioInfo]) -> Bool {
        selected.contains { !($0.deviceRequirements?.isEmpty ?? true) }
    }

    /// 配る単位ごとの候補エントリ(`FleetSplit.plan` の `candidates:`・`DynamicDispatcher.entryCandidate` の材料)と、どこにも配れない単位
    struct Candidacy: Sendable {
        /// 載っていない単位は全エントリが候補
        let entries: [ScenarioUnitKey: Set<Int>]
        /// 候補が1つも無い単位(全台が読めて合う台が無い = 対象外。読めない台があれば候補になるのでここには来ない)
        let unmet: Set<ScenarioUnitKey>

        static let unconstrained = Candidacy(entries: [:], unmet: [])

        func isCandidate(_ unit: ScenarioUnitKey, entry: Int) -> Bool { entries[unit]?.contains(entry) ?? true }

        /// 配れない単位のシナリオ(ID 単位。条件も OS もバリアントに依らない)を外す
        func split(_ infos: [ScenarioInfo]) -> (kept: [ScenarioInfo], unmet: [ScenarioInfo]) {
            let ids = Set(unmet.map(\.id))
            return (infos.filter { !ids.contains($0.id) }, infos.filter { ids.contains($0.id) })
        }
    }

    /// `entryDevices[i]` = エントリ i の台の性質。単位の OS は `platformOf`(解決済み。nil = どちらでも)
    static func candidacy(units: [ScenarioUnitKey], requirements: [String: DeviceRequirementSet],
                          platformOf: (ScenarioUnitKey) -> String?, entryDevices: [[DeviceTraits]]) -> Candidacy {
        var entries: [ScenarioUnitKey: Set<Int>] = [:]
        var unmet = Set<ScenarioUnitKey>()
        for unit in units {
            guard let set = requirements[unit.id], !set.isEmpty else { continue }
            let platform = platformOf(unit)
            let ok = Set(entryDevices.indices.filter {
                DeviceRequirementCandidacy.isCandidate(set, platform: platform, devices: entryDevices[$0])
            })
            entries[unit] = ok
            if ok.isEmpty { unmet.insert(unit) }
        }
        return Candidacy(entries: entries, unmet: unmet)
    }

    /// 機械分担: グループ = エントリ。宣言が無い(観測していない)ときは `.unconstrained`
    static func candidacy(selected: [ScenarioInfo], plan: RunVariantPlan, groups: [DeviceMachineRunner.Group],
                          observed: MachineDeviceTraits, defaultPlatform: String) -> Candidacy {
        guard declares(selected) else { return .unconstrained }
        var requirements: [String: DeviceRequirementSet] = [:]
        var platforms: [String: String] = [:]
        for info in selected {
            if let set = info.deviceRequirements { requirements[info.id] = set }
            platforms[info.id] = info.platform ?? defaultPlatform
        }
        let entryDevices = groups.map { group in
            DeviceRequirementCandidacy.childTraits(observed, machine: group.machine, deviceNames: group.deviceNames)
                .values.map { $0 }
        }
        return candidacy(units: plan.units(of: selected), requirements: requirements,
                         platformOf: { platforms[$0.id] }, entryDevices: entryDevices)
    }

    /// 親が仕分けた「配れない単位」の1行(英語)。件数つき。呼び手が notApplicable として数える
    static func unmetLines(_ unmet: [ScenarioInfo]) -> [String] {
        guard !unmet.isEmpty else { return [] }
        var lines = ["→ Skipped \(unmet.count) scenario(s): no device of this run matches their declared device conditions"]
        for info in unmet {
            let conditions = info.deviceRequirements.map(DeviceRequirementGate.describe) ?? ""
            lines.append("    \(info.id): not applicable — \(conditions)")
        }
        return lines
    }

    // MARK: - リモートの観測

    static func parse(stdout: String) -> [String: DeviceTraits]? {
        for line in stdout.split(separator: "\n").reversed() {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("{") else { continue }
            return try? JSONDecoder().decode([String: DeviceTraits].self, from: Data(trimmed.utf8))
        }
        return nil
    }

    /// `remote exec <machine> -- api device-traits --project <P> --profile <prof>`(`--machine` は付けない: ランナーの転送済みプロファイルは
    /// 「そのランナーから見た姿」= 自分の台の machine が無い)。**先にプロジェクトを送る**(`remote exec` は転送しない = 古い・無い
    /// プロファイルを読む)。終了コードを見る・中断で止まる(`abortable`)・子は `FT_PARENT_PID` で親の死に追随する
    static func liveFetch(machine: String, project: String, profile: String) -> Fetched {
        if let failure = RemoteProjectSync.run(project: project, machine: machine) { return .failed(failure) }
        let command = ["env", "-u", DispatchRefusalReport.environmentKey,
                       "\(ParentDeathWatch.environmentKey)=\(getpid())",
                       RemoteProjectSync.selfBinaryPath(), "remote", "exec", machine, "--",
                       "api", "device-traits", "--project", project, "--profile", profile]
        do {
            let result = try Shell.run(command, timeout: remoteTimeoutSeconds, abortable: true)
            guard let output = result.outputIfSucceeded else { return .failed("exit status \(result.status)") }
            guard let traits = parse(stdout: output) else { return .failed("unreadable output") }
            return .traits(traits)
        } catch {
            return .failed(error.localizedDescription)
        }
    }
}
