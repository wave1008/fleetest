// 対象外の回し直し(DR-214)で「同じ種類の台」を見分ける、Android Emulator の種類の観測(iOS は `IOSDeviceKindResolver`)。
// 種類の文字列は `AndroidDeviceTraits.emulatorKind` の1か所(子の `RunWorker.deviceKind` と同じ関数)。**プロファイルの `model` は使わない**。
// 実機・AVD 名の無い台・config.ini が読めない台が1台でもあるエントリは不明 = 覆わない(部分的な知識で覆わない)。

import ArgumentParser
import FTAndroid
import FTCore
import FTRemote
import Foundation

enum AndroidDeviceKindResolver {
    /// 秒。ssh 越しの1回の上限 = `remote exec` の ssh(`$HOME` の問い合わせと本体で接続 ×2)+ 余裕 30 秒(向こうは config.ini を読むだけ)。
    /// 尽きたらその機械は不明 = 台ごとの回し直しに戻り、配り手が1行言う(遅くなるだけで誤らない)
    static let remoteTimeoutSeconds = Double(SSHOptions.connectTimeoutSeconds) * 2 + 30

    /// 純粋部。nil = 観測できなかった(Android の指定が無い・AVD 名が無い・種類が読めなかった)。
    /// 空集合 = 観測の対象外(実機を含む。覆わない点は nil と同じだが失敗ではないので配り手は言わない)。
    /// `avdKinds` = AVD 名 → 種類(読めなかった AVD は載せない。nil = 機械ごと読めなかった)
    static func kinds(specs: [DeviceSpec], avdKinds: [String: String]?) -> Set<String>? {
        guard !specs.isEmpty else { return nil }
        if specs.contains(where: \.isPhysical) { return [] }
        guard let avdKinds else { return nil }
        var result = Set<String>()
        for spec in specs {
            guard let avd = spec.avd, let kind = avdKinds[avd] else { return nil }
            result.insert(kind)
        }
        return result
    }

    /// `DynamicDispatcher.entryKinds` の Android の実体。エントリ番号 → 観測した種類。機械ごとに1回(並行)
    static func entryKinds(project: TestProject, profileName: String, groups: [DeviceMachineRunner.Group],
                           overrides: [String: RunProfileSetValue]) -> [Int: Set<String>] {
        let entries = ProfileResolver.runDeviceEntries(
            project: project, runProfileName: profileName, overrides: overrides)
        let jobs: [(entry: Int, machine: String?, specs: [DeviceSpec])] = groups.enumerated().compactMap { index, group in
            let specs = entries.filter {
                $0.platform == "android" && MachineDispatch.normalize($0.machine) == MachineDispatch.normalize(group.machine)
                    && group.deviceNames.contains($0.name)
            }.map(\.spec)
            return specs.isEmpty ? nil : (index, group.machine, specs)
        }
        let results = LockedValue<[Int: Set<String>]>([:])
        DispatchQueue.concurrentPerform(iterations: jobs.count) { i in
            let job = jobs[i]
            let avds = Set(job.specs.filter { !$0.isPhysical }.compactMap(\.avd))
            let avdKinds = avds.isEmpty ? [:] : cachedAVDKinds(machine: job.machine, avds: avds)
            if let kinds = kinds(specs: job.specs, avdKinds: avdKinds) {
                results.withLock { $0[job.entry] = kinds }
            }
        }
        return results.value
    }

    /// (機械, AVD 名の集合) → 種類。複数対象の run は対象ごとに配り手を作るので、引くたびに ssh を撃たない(プロセスで1回)
    private static let outputs = LockedValue<[String: [String: String]]>([:])
    private static let fetchLocks = LockedValue<[String: NSLock]>([:])

    /// **成功だけ控える**(ssh の時間切れ・向こうの失敗の nil を覚えると、同じプロセスの後の配り手が一生やり直せない)。
    /// `fetch` はテストの差し替え口
    static func cachedAVDKinds(machine: String?, avds: Set<String>,
                               fetch: (String?, Set<String>) -> [String: String]? = fetchAVDKinds) -> [String: String]? {
        let key = (MachineDispatch.isExplicitLocal(machine) || machine == nil ? "local" : machine!) + "\u{1}" + avds.sorted().joined(separator: "\u{1}")
        let lock = fetchLocks.withLock { locks -> NSLock in
            if let existing = locks[key] { return existing }
            let created = NSLock()
            locks[key] = created
            return created
        }
        lock.lock()
        defer { lock.unlock() }
        if let hit = outputs.withLock({ $0[key] }) { return hit }
        guard let kinds = fetch(machine, avds) else { return nil }
        outputs.withLock { $0[key] = kinds }
        return kinds
    }

    /// その機械の AVD の種類。ローカルは直に読む。別の機械は `remote exec <machine> -- api avd-kinds <avd>...`
    /// (AVD の実体の場所は向こうの `ANDROID_AVD_HOME` と `<id>.ini` の `path=` が決める = 親の想定で `cat` しない)。
    /// **終了コードを見る**(失敗 = nil)・中断で止まる(`abortable`)・子は `FT_PARENT_PID` で親の死に追随する
    static func fetchAVDKinds(machine: String?, avds: Set<String>) -> [String: String]? {
        if MachineDispatch.isExplicitLocal(machine) || machine == nil { return localKinds(avds: avds) }
        guard let machine else { return nil }
        let command = ["env", "-u", DispatchRefusalReport.environmentKey,
                       "\(ParentDeathWatch.environmentKey)=\(getpid())",
                       RemoteProjectSync.selfBinaryPath(), "remote", "exec", machine, "--",
                       "api", "avd-kinds"] + avds.sorted()
        guard let result = try? Shell.run(command, timeout: remoteTimeoutSeconds, abortable: true),
              let output = result.outputIfSucceeded else { return nil }
        return parse(stdout: output)
    }

    static func localKinds(avds: Set<String>) -> [String: String] {
        avds.reduce(into: [:]) { out, avd in
            if let kind = AndroidDeviceTraits.emulatorKind(avd: avd) { out[avd] = kind }
        }
    }

    static func parse(stdout: String) -> [String: String]? {
        for line in stdout.split(separator: "\n").reversed() {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("{") else { continue }
            return try? JSONDecoder().decode([String: String].self, from: Data(trimmed.utf8))
        }
        return nil
    }
}

/// `fleetest api avd-kinds <avd>...`: この機械の AVD の種類を JSON `{ "<AVD 名>": "<種類>" }` で出す(読めない AVD は載せない)。
/// 親が別の機械の観測を remote exec で引くための内部口(拡張は使わない)。何も起動しない
struct ApiAVDKindsCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "avd-kinds",
        abstract: "Print the observed kind of each given AVD of this machine as JSON on stdout. Starts nothing",
        shouldDisplay: false)

    @Argument(help: "AVD names")
    var avds: [String] = []

    func run() async throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        ConsoleOut.out(String(data: try encoder.encode(AndroidDeviceKindResolver.localKinds(avds: Set(avds))), encoding: .utf8)!)
    }
}

/// `DynamicDispatcher.entryKinds` の本番の実体(platform ごとの観測へ振り分ける。呼び手は3か所 = この1つを通す)
enum DeviceKindResolver {
    static func entryKinds(platform: String, project: TestProject, profileName: String,
                           groups: [DeviceMachineRunner.Group], overrides: [String: RunProfileSetValue]) -> [Int: Set<String>] {
        switch platform {
        case "ios":
            return IOSDeviceKindResolver.entryKinds(project: project, profileName: profileName, groups: groups, overrides: overrides)
        case "android":
            return AndroidDeviceKindResolver.entryKinds(project: project, profileName: profileName, groups: groups, overrides: overrides)
        default:
            return [:]
        }
    }
}
