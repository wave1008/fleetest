// MultiTargetRunner.swift
// 複数の対象(プロジェクト × 実行プロファイル)を1回の `fleetest run` で回す親(RR-8.2)。
// 空いたマシンが次の対象を取り(`TargetSchedule.decide`)、終わり際はシナリオ単位で同じ対象に加わる。
// 子はマシン × 対象ごとに `--work-queue` で起こし、対象ごとの `DynamicDispatcher` がシナリオを1本ずつ配る(RR-8.1)。
//
// - 対象(unit)の ID は "<project>/<profile>"、マシンは全対象のグループから作る一覧の添字(Int)
// - マシンは同時に1つの子だけ。dispatch.lock は使う全マシンを最初に `DispatchPrelock` で取り、最後まで手放さない
// - 同じ (対象, マシン) の子は1回だけ起こす(DynamicDispatcher は終わったエントリの要求を無視するので、起こし直すと返事が来ない)

import ArgumentParser
import FTCore
import FTRemote
import Foundation

enum MultiTargetRunner {

    // MARK: - 対象の指定

    struct Target: Equatable {
        /// nil = 既定のプロジェクト
        let project: String?
        let profile: String
    }

    /// `--project`/`--profile`(繰り返し)/`--target A:p` から対象を作る。**単一(0 または 1 個の --profile)は空を返す =
    /// 既存の経路**。`--target` は1個でも返す(run() が通常の経路へ読み替える)
    static func targets(project: String?, profiles: [String], targetSpecs: [String]) throws -> [Target] {
        if !targetSpecs.isEmpty {
            if project != nil || !profiles.isEmpty {
                throw ValidationError("--target cannot be combined with --project/--profile")
            }
            let parsed = try targetSpecs.map(parse)
            try rejectDuplicates(parsed)
            return parsed
        }
        guard profiles.count >= 2 else { return [] }
        let parsed = profiles.map { Target(project: project, profile: $0) }
        try rejectDuplicates(parsed)
        return parsed
    }

    /// `<project>:<profile>`(最初の `:` で割る)
    static func parse(_ spec: String) throws -> Target {
        guard let colon = spec.firstIndex(of: ":") else {
            throw ValidationError("--target must be <project>:<profile> (got \"\(spec)\")")
        }
        let project = String(spec[spec.startIndex..<colon])
        let profile = String(spec[spec.index(after: colon)...])
        guard !project.isEmpty, !profile.isEmpty else {
            throw ValidationError("--target must be <project>:<profile> (got \"\(spec)\")")
        }
        return Target(project: project, profile: profile)
    }

    private static func rejectDuplicates(_ targets: [Target]) throws {
        var seen: Set<String> = []
        for target in targets where !seen.insert("\(target.project ?? "")\u{1}\(target.profile)").inserted {
            throw ValidationError("duplicate target: \(target.project.map { "\($0):" } ?? "")\(target.profile)")
        }
    }

    /// 残った対象が使うマシンのラベルだけ(添字の順のまま)。飛ばした対象だけが使うマシンのロックを取らない
    /// (取ると `--wait-lock` ぶん待ったうえ、使わないマシンを最後まで占有する)。machineLabels 自体は添字の基準なので削らない
    static func labelsInUse(_ machineLabels: [String], entryMaps: [Set<Int>]) -> [String] {
        let used = entryMaps.reduce(into: Set<Int>()) { $0.formUnion($1) }
        return machineLabels.indices.filter { used.contains($0) }.map { machineLabels[$0] }
    }

    /// 2つ以上の対象と併用できないフラグの最初の1つ(純粋関数。順序は利用者に見せたい順)
    static func firstRejection(flags: [(name: String, isSet: Bool)]) -> String? {
        flags.first(where: { $0.isSet }).map {
            "\($0.name) cannot be combined with several targets (repeated --profile or --target)"
        }
    }

    // MARK: - 実行

    /// 1つの対象(対象)の実行時の束
    private struct TargetUnit {
        let id: String
        let project: TestProject
        let profile: String
        let groups: [DeviceMachineRunner.Group]
        /// 全マシン一覧の添字 → groups の添字
        let entryByMachine: [Int: Int]
        let resolved: [DynamicSplit.Scenario]
        let dispatcher: DynamicDispatcher
        /// この対象のプロジェクトの run メモの正本(同じプロジェクトの対象で1つ。子の鍵は (対象, エントリ番号)。DR-208・RR-8.4)
        let memoHub: RunMemoHub
        let estimate: @Sendable (DynamicSplit.Scenario, Int) -> Double
        let healCollection: HealSourceWriteBack.Collection
        let infos: [ScenarioInfo]
    }

    private static func writerKey(_ unit: String, _ entry: Int) -> String { "\(unit)\u{1}\(entry)" }

    /// 1つのプロジェクトの beforeRun / afterRun(RR-8.4)。beforeRun はそのプロジェクトの最初の対象の子を起こすときに1回
    private final class ProjectHook: @unchecked Sendable {
        let parent: RunHookParent
        let hub: RunMemoHub
        // @unchecked の根拠: beforeRunTask は lock の下でしか触らない
        private let lock = NSLock()
        private var beforeRunTask: Task<RunHookOutcome, Never>?

        init(parent: RunHookParent, hub: RunMemoHub) {
            self.parent = parent
            self.hub = hub
        }

        func startBeforeRunIfNeeded() {
            lock.lock()
            defer { lock.unlock() }
            if beforeRunTask == nil { beforeRunTask = parent.start(hub: hub) }
        }

        var beforeRun: Task<RunHookOutcome, Never>? {
            lock.lock()
            defer { lock.unlock() }
            return beforeRunTask
        }
    }

    private struct ChildOutcome {
        let unit: String
        let machine: Int
        let exitCode: Int32
        let duration: TimeInterval
    }

    static func run(
        targets: [Target], setOverrides: [String: RunProfileSetValue], noLPT: Bool, lptHistoryRuns: Int?,
        performanceMode: Bool, forceLock: Bool, waitLock: Int?, remoteDir: String?, remoteTimeout: Int?,
        quiet: Bool, junit: String?, skipBuild: Bool, reportDir: String?
    ) async throws -> Int32 {
        let junitTempDir = try FleetRunner.makeJUnitTempDir(requested: junit)
        defer { if let junitTempDir { try? FileManager.default.removeItem(at: junitTempDir) } }

        // 1. 対象の解決(プロジェクト・グループ)。読むだけで、デバイスにもビルドにも触らない
        let disabled = MachineEnablement.disabledMachines(config: LocalConfig.load())
        struct Resolved {
            let project: TestProject
            let profile: String
            let groups: [DeviceMachineRunner.Group]
        }
        var resolvedTargets: [Resolved] = []
        var seenIDs: Set<String> = []
        for target in targets {
            let project = try ScenarioHost.project(named: target.project)
            let id = "\(project.name)/\(target.profile)"
            guard seenIDs.insert(id).inserted else { throw ValidationError("duplicate target: \(id)") }
            let (groups, _) = try DeviceMachineRunner.resolveGroups(
                project: project, profileName: target.profile, deviceFilter: [],
                disabledMachines: disabled, overrides: setOverrides)
            guard !groups.isEmpty else {
                throw ValidationError("run profile \"\(target.profile)\" of \(project.name) has no devices")
            }
            // 計測の反復(responseRepeat)は子だけが展開し、親は同じ ID を1回しか配らない = 指定の回数を回さずに成功する
            if ProfileResolver.declaresResponseMeasurement(project: project, runName: target.profile, overrides: setOverrides) {
                throw ValidationError("run profile \"\(target.profile)\" of \(project.name) measures response times;"
                    + " run it on its own (not together with other targets)")
            }
            resolvedTargets.append(Resolved(project: project, profile: target.profile, groups: groups))
        }
        // マシン一覧(全対象のグループのラベル。初出の順)
        var machineLabels: [String] = []
        for target in resolvedTargets {
            for group in target.groups where !machineLabels.contains(group.machineLabel) {
                machineLabels.append(group.machineLabel)
            }
        }

        // ジョブの行(見える化の台帳。DS-18.11)。どの出口でも closeOut が閉じる = 自分で作ったジョブなら消す・外側のジョブなら
        // 自分が running にしたまま閉じていない行だけを canceled にする(外側の他の予定には触らない)
        let job = MultiTargetJobTracker.begin(targets: resolvedTargets.map { ($0.project.name, $0.profile) })
        defer { job?.closeOut() }

        FleetRunner.log("==> \(resolvedTargets.count) target(s) on \(machineLabels.count) machine(s)"
            + " — each free machine takes the next target; the last targets are shared scenario by scenario")

        let clock = DynamicDispatcher.monotonicClock()
        let writers = LockedValue<[String: ChildStdinWriter]>([:])
        // プロジェクトごとの beforeRun / afterRun と run メモの正本(`@RunHooks` が無いプロジェクトは hub だけ。鍵 = プロジェクト名)
        let projectHooks = LockedValue<[String: ProjectHook]>([:])
        defer { for hook in projectHooks.withLock({ Array($0.values) }) { hook.parent.close() } }
        // 前段(入口の印・チケット・手元のロックの先取り・ビルド・使用中の待ち・全マシンの Prelock)は
        // MachineFanoutFrontHalf の1箇所。ここが持つのは差分 = プロジェクトごとのビルドと対象ごとの配り手
        guard let (held, built) = try MachineFanoutFrontHalf.run(
            settings: .init(
                mode: .cliRun, remoteDir: remoteDir, forceLock: forceLock, waitLock: waitLock,
                setOverrides: setOverrides, log: { FleetRunner.log($0) }, emitLocalLockWaiting: nil, emitLocalDevicesWaiting: nil),
            build: { parentInterrupt -> (built: ([TargetUnit], [String: HealSourceWriteBack.Collection]), plan: MachineFanoutFrontHalf.Plan)? in
                // 2. 手元で1回ずつビルドして一覧を出す(プロジェクトごと)。中断はプロジェクトの境目で拾う
                var builtProjects: Set<String> = []
                var listed: [String: [ScenarioInfo]] = [:]
                var hooksClassByProject: [String: String] = [:]
                var healByProject: [String: HealSourceWriteBack.Collection] = [:]
                // 先に1回の swift build でまとめて作る(1本ずつ起こすと起動の固定費を本数ぶん払う。下の build は指紋の一致で抜ける)
                if !skipBuild {
                    var seen: Set<String> = []
                    let projects = resolvedTargets.map(\.project).filter { seen.insert($0.name).inserted }
                    try parentInterrupt.stage("the scenario build", log: { FleetRunner.log($0) }) {
                        ScenarioHost.prebuildTogether(projects: projects, log: { FleetRunner.log($0) })
                    }
                }
                for target in resolvedTargets where builtProjects.insert(target.project.name).inserted {
                    let found = try parentInterrupt.stage("the scenario build", log: { FleetRunner.log($0) }) {
                        if !skipBuild { try ScenarioHost.build(project: target.project, log: { FleetRunner.log($0) }) }
                        return try ScenarioHost.listForRun(project: target.project, dryRun: false, compilesOCR: false)
                    }
                    guard !found.scenarios.isEmpty else {
                        throw ValidationError(
                            "no scenarios (add a @TestClass under TestProjects/\(target.project.name)/scenarios/)")
                    }
                    if let hooksClass = found.runHooksClass { hooksClassByProject[target.project.name] = hooksClass }
                    // 通常の入口と同じ選択(`@Draft` / `@Deleted` を外す)。子へは完全一致の ID で渡すので、子の側では外れない。
                    // 外して空になった対象は飛ばす(通常の入口も外して空なら成功で終わる)= 下の「当てはまるシナリオが無い」で抜ける
                    listed[target.project.name] = try ScenarioSelection.resolve([], from: found.scenarios)
                    healByProject[target.project.name] = HealSourceWriteBack.Collection()
                }

                // プロジェクトごとの run メモの正本。`@RunHooks` があれば開始の行を beforeRun の結果が出るまで保留する。
                // 対象がある(= シナリオが1本以上ある)プロジェクトの分だけ、最初の対象を作るときに作る
                var hubs: [String: RunMemoHub] = [:]
                func projectHub(for project: TestProject) -> RunMemoHub {
                    if let hub = hubs[project.name] { return hub }
                    let className = RunWideHookPlan.hooksClassToRun(
                        hooksClass: hooksClassByProject[project.name], scenarioCount: 1, dryRun: false,
                        linkedToParent: ParentLink.isLinked)
                    let hub = RunMemoHub(mode: className == nil ? .startOnHello : .awaitDecision, send: { child, lines in
                        writers.withLock { $0[MultiTargetRunner.writerKey(child.target, child.entry)] }?
                            .write(line: lines.joined(separator: "\n"))
                    })
                    hubs[project.name] = hub
                    if let className {
                        let parent = RunHookParent(
                            context: RunHookSetup.context(
                                project: project, className: className,
                                profiles: resolvedTargets.filter { $0.project.name == project.name }.map(\.profile),
                                setOverrides: setOverrides, reportDirOverride: reportDir,
                                log: { FleetRunner.log("[\(project.name)] " + $0) }),
                            log: { FleetRunner.log("[\(project.name)] " + $0) })
                        projectHooks.withLock { $0[project.name] = ProjectHook(parent: parent, hub: hub) }
                    }
                    return hub
                }

                // 3. 対象ごとの配り手
                var units: [TargetUnit] = []
                for target in resolvedTargets {
                    let id = "\(target.project.name)/\(target.profile)"
                    let all = listed[target.project.name] ?? []
                    let (runnable, notApplicable) = DeviceMachineRunner.splitApplicable(selected: all, groups: target.groups)
                    if !notApplicable.isEmpty { FleetRunner.log("==> \(id)") }
                    for line in DeviceMachineRunner.notApplicableLines(notApplicable, groups: target.groups) {
                        FleetRunner.log(line)
                    }
                    if ProfileResolver.declaresResponseMeasurement(
                        project: target.project, runName: target.profile, overrides: setOverrides),
                       let message = ClassPlacementRules.measurementError(runnable) {
                        throw ValidationError("[\(id)] " + message)
                    }
                    if let message = DynamicDispatcher.coverageError(selected: runnable, groups: target.groups) {
                        throw ValidationError("[\(id)] " + message)
                    }
                    let resolved = DynamicDispatcher.resolve(
                        runnable,
                        defaultPlatform: DynamicDispatcher.undeclaredPlatform(groups: target.groups))
                    guard !resolved.isEmpty else {
                        FleetRunner.log("==> \(id): no scenario applies to this profile's devices; skipping")
                        job?.mark(project: target.project.name, profile: target.profile, state: .skipped)
                        continue
                    }
                    var entryByMachine: [Int: Int] = [:]
                    for (index, group) in target.groups.enumerated() {
                        if let machine = machineLabels.firstIndex(of: group.machineLabel) { entryByMachine[machine] = index }
                    }
                    let inputs = DeviceMachineRunner.estimationInputs(
                        project: target.project, groups: target.groups, lptHistoryRuns: lptHistoryRuns)
                    let estimate = DeviceMachineRunner.dynamicEstimator(inputs: inputs, groups: target.groups)
                    let targetID = id
                    let targetGroups = target.groups
                    let dispatcher = DynamicDispatcher(
                        scenarios: resolved, estimateMs: estimate, nowMs: clock, lpt: !noLPT,
                        entryPlatforms: DynamicDispatcher.entryPlatforms(groups: targetGroups),
                        entryLabel: { targetGroups[$0].machineLabel },
                        log: { FleetRunner.log("[\(targetID)] " + $0) },
                        send: { entry, reply in
                            writers.withLock { $0[MultiTargetRunner.writerKey(targetID, entry)] }?.write(line: WorkQueueProtocol.encode(reply))
                        })
                    let memoHub = projectHub(for: target.project)
                    units.append(TargetUnit(
                        id: id, project: target.project, profile: target.profile, groups: target.groups,
                        entryByMachine: entryByMachine, resolved: resolved, dispatcher: dispatcher, memoHub: memoHub,
                        estimate: estimate,
                        healCollection: healByProject[target.project.name] ?? HealSourceWriteBack.Collection(),
                        infos: runnable))
                }
                guard !units.isEmpty else {
                    FleetRunner.log("==> no target has a scenario to run; nothing to run")
                    return nil
                }

                var leaseChecks: [MachineFanoutFrontHalf.LeaseCheck] = []
                for unit in units {
                    guard let local = unit.groups.first(where: { $0.machine == nil }) else { continue }
                    let ids = Set(DynamicDispatcher.candidateIDs(for: local, in: unit.resolved))
                    leaseChecks.append(.init(
                        project: unit.project, profileName: unit.profile, localDeviceNames: local.deviceNames,
                        localScenarios: unit.infos.filter { ids.contains($0.id) }, broadcast: false))
                }
                return ((units, healByProject), .init(
                    leaseChecks: leaseChecks,
                    machines: labelsInUse(machineLabels, entryMaps: units.map { Set($0.entryByMachine.keys) }),
                    prelockProject: units[0].project))
            }) else { return 0 }
        defer { held.close() }
        let (units, healByProject) = built
        let runGroup = held.runGroup
        let ticket = held.ticket
        let prelock = held.prelock
        let parentInterrupt = held.parentInterrupt

        let binary = FleetRunner.selfBinaryPath()
        let lockMarkers = held.lockMarkers
        let dispatchStart = Date()

        // run 全体のロック(RR-8.5)のサーバー: **プロジェクトごとに1つ**(ロックの範囲は run × プロジェクト。キーは別のプロジェクトと混ざらない)。
        // ソースがロックを使うプロジェクトだけ。待ちの上限はそのプロジェクトの全対象のシナリオの最長の実効 scenarioTimeout。
        // 子が全員終わるまで持ち、中断は全部へ伝える
        var lockIssuers: [String: RunLockIssuer] = [:]
        for unit in units where lockIssuers[unit.project.name] == nil {
            let name = unit.project.name
            let sameProject = units.filter { $0.project.name == name }
            lockIssuers[name] = RunLockIssuerSetup.start(
                project: unit.project, profiles: sameProject.map(\.profile), setOverrides: setOverrides,
                scenarioTimeouts: sameProject.flatMap { $0.infos.map(\.scenarioTimeout) }, hub: unit.memoHub,
                log: { FleetRunner.log("[\(name)] " + $0) })
        }
        let lockIssuersByProject = lockIssuers
        defer { lockIssuersByProject.values.forEach { $0.stop() } }
        let lockInterruptRelays = lockIssuersByProject.values.map { issuer in
            InterruptRelay.observing(catchUp: true) { issuer.interrupt() }
        }
        defer { lockInterruptRelays.forEach { $0.stop() } }

        // 5. 配り手
        let overheadByMachine = overheadsMs(project: units[0].project, labels: machineLabels)
        var specs: [MultiTargetCoordinator.TargetUnit] = []
        for unit in units {
            var lanes: [Int: MultiTargetCoordinator.Lane] = [:]
            for (machine, entry) in unit.entryByMachine {
                let group = unit.groups[entry]
                lanes[machine] = .init(entry: entry, devices: group.deviceNames.count, platforms: group.platforms)
            }
            let dispatcher = unit.dispatcher
            specs.append(.init(
                id: unit.id, lanes: lanes, pending: { dispatcher.handablePendingScenarios }, estimateMs: unit.estimate,
                childExited: { dispatcher.childExited(entry: $0) }, interrupt: { dispatcher.interrupt() }))
        }
        let targetByID = Dictionary(uniqueKeysWithValues: units.map { ($0.id, $0) })
        let childCounter = LockedValue(0)
        let childHosts = LockedValue<[(host: String, index: Int)]>([])
        let outcomes = LockedValue<[ChildOutcome]>([])
        // ジョブの行: 走っている子の数(対象ごと)と、終端にした対象。最後の子が終わり配り切れていたらその場で終端にする
        let isInterrupted = parentInterrupt.isSet
        let runningChildren = LockedValue<[String: Int]>([:])
        let finalizedTargets = LockedValue<Set<String>>([])
        let finalizeRow: @Sendable (TargetUnit, Bool) -> Void = { unit, interrupted in
            guard let job, finalizedTargets.withLock({ $0.insert(unit.id).inserted }) else { return }
            let codes = outcomes.withLock { $0.filter { $0.unit == unit.id }.map(\.exitCode) }
            job.mark(project: unit.project.name, profile: unit.profile,
                     state: MultiTargetJobTracker.finalState(
                        codes: codes, started: true, hasUnhanded: !unit.dispatcher.unhandedIDs.isEmpty,
                        interrupted: interrupted))
        }
        let launch: MultiTargetCoordinator.Launch = { targetID, machine, finished in
            guard let unit = targetByID[targetID], let entry = unit.entryByMachine[machine] else { finished(127); return }
            let group = unit.groups[entry]
            // beforeRun(RR-8.4): プロジェクトの最初の対象の子を起こすときに1回。失敗したプロジェクトの対象は以後起こさない
            // (別のプロジェクトは続ける。起こさない対象は「失敗(exit 1)」として表に残し、配れなかった分は失敗と数えない)
            let hook = projectHooks.withLock { $0[unit.project.name] }
            if let hook {
                if hook.parent.beforeRunFailed {
                    FleetRunner.log("[\(unit.id)] not started on \(group.machineLabel): beforeRun() failed for \(unit.project.name)")
                    outcomes.withLock { $0.append(ChildOutcome(unit: targetID, machine: machine, exitCode: 1, duration: 0)) }
                    finished(1)
                    return
                }
                hook.startBeforeRunIfNeeded()
            }
            let label = "\(group.machineLabel):\(unit.id)"
            let writer = ChildStdinWriter()
            writers.withLock { $0[MultiTargetRunner.writerKey(targetID, entry)] = writer }
            let index = childCounter.withLock { value -> Int in value += 1; return value }
            runningChildren.withLock { $0[targetID, default: 0] += 1 }
            job?.running(project: unit.project.name, profile: unit.profile, machine: group.machineLabel)
            childHosts.withLock { $0.append((host: label, index: index)) }
            let args = DeviceMachineRunner.childArgs(
                project: unit.project.name, host: group.machineLabel, profile: unit.profile,
                deviceNames: group.deviceNames, deviceMachine: group.machineLabel,
                scenarios: DynamicDispatcher.candidateIDs(for: group, in: unit.resolved), folders: [],
                setOverrides: setOverrides, noLPT: noLPT, lptHistoryRuns: lptHistoryRuns,
                performanceMode: performanceMode, forceLock: forceLock,
                remoteDir: remoteDir, remoteTimeout: remoteTimeout, quiet: quiet,
                junitPath: FleetRunner.entryJUnitPath(tempDir: junitTempDir, index: index),
                runGroup: runGroup, reportDir: reportDir, workQueue: true, runMemoLink: true,
                lockSocket: lockIssuersByProject[unit.project.name]?.socketPath)
            let dispatcher = unit.dispatcher
            let memoHub = unit.memoHub
            let marker = lockMarkers[group.machineLabel]
            let heal = unit.healCollection
            Task {
                let started = Date()
                let code = await FleetRunner.runEntry(
                    binary: binary, args: args, hostLabel: label, ticket: ticket, lockMarker: marker,
                    healCollection: heal, stdin: writer,
                    lineInterceptor: { line in
                        RunMemoRelay.intercept(line: line, hub: memoHub, child: .init(target: targetID, entry: entry),
                                               dispatcher: dispatcher, writer: writer)
                    })
                memoHub.entryExited(.init(target: targetID, entry: entry))
                outcomes.withLock {
                    $0.append(ChildOutcome(unit: targetID, machine: machine, exitCode: code,
                                           duration: Date().timeIntervalSince(started)))
                }
                let left = runningChildren.withLock { counts -> Int in
                    counts[targetID, default: 1] -= 1
                    return counts[targetID] ?? 0
                }
                // 配り切って最後の子が終わった対象はその場で終端(まだ配るものが残るなら別マシンが引き継ぐので待つ)
                if left == 0, dispatcher.handablePendingScenarios.isEmpty {
                    finalizeRow(unit, isInterrupted())
                }
                finished(code)
            }
        }
        let coordinator = MultiTargetCoordinator(
            units: specs, machineCount: machineLabels.count, overheadMs: overheadByMachine,
            nowMs: clock, lpt: !noLPT, launch: launch, log: { FleetRunner.log($0) })
        // catchUp: ロックの取得中(DispatchPrelock の購読が受けた)の中断も、ここで配り手へ伝える
        let relay = InterruptRelay.observing(catchUp: true) { coordinator.interrupt() }
        defer { relay.stop() }
        // 購読の登録より前の中断は子を起こす前に抜ける(DeviceMachineRunner.run の同じ箇所)
        try held.exitIfInterruptedBeforeLaunch(log: { FleetRunner.log($0) })
        let wallStart = clock()
        coordinator.start()
        await coordinator.waitUntilFinished()
        let wallMs = clock() - wallStart
        // 子が全員終わった時点の値で仕分ける(後の対象ごとの走査の間に来た中断で、ほかの対象の本物の欠落を中断に読み替えない。
        // DeviceMachineRunner.run と同じ)。配り手・coordinator の印を立てるのも中断の購読だけ
        let interrupted = parentInterrupt.isSet()

        // 6. 後始末と集計
        let results = outcomes.withLock { $0 }
        var lastExit: [String: Int32] = [:]
        for outcome in results { lastExit[machineLabels[outcome.machine]] = outcome.exitCode }
        // afterRun(プロジェクトごとに1回。そのプロジェクトの全対象の全マシンの子が正常に終わったときだけ。条件は RunWideHookPlan)。
        // **ロックを持ったまま**走らせる(1台の run と同じ。解放は下の releaseAll)。
        // beforeRun が失敗したプロジェクトは1本も流れていないので、配れなかった分・結果の無い分を失敗として数えない
        var hookFailedProjects: Set<String> = []
        var hookInterrupted = false
        let unitProject = Dictionary(uniqueKeysWithValues: units.map { ($0.id, $0.project.name) })
        for (name, hook) in projectHooks.withLock({ $0 }).sorted(by: { $0.key < $1.key }) {
            guard let beforeRun = hook.beforeRun else { continue }
            _ = await beforeRun.value
            if hook.parent.beforeRunFailed { hookFailedProjects.insert(name) }
            if hook.parent.beforeRunInterrupted { hookInterrupted = true }
            await hook.parent.finish(
                hub: hook.hub, beforeRun: beforeRun,
                childExitCodes: results.filter { unitProject[$0.unit] == name }.map(\.exitCode), interrupted: interrupted)
        }

        prelock.releaseAll(exitCodes: lastExit)
        var neverHandedFailure = false
        // 中断で止められた beforeRun(子は取りやめで終わった)は、既存の中断の終わり方 = 130
        var interruptedWithWorkLeft = hookInterrupted
        for unit in units {
            let ids = unit.dispatcher.unhandedIDs
            guard !ids.isEmpty, !hookFailedProjects.contains(unit.project.name) else { continue }
            FleetRunner.log("[\(unit.id)] " + DeviceMachineRunner.neverHandedLine(ids: ids, interrupted: interrupted))
            if let line = DynamicDispatcher.keptUnhandedLine(unit.dispatcher.keptUnhanded) {
                FleetRunner.log("[\(unit.id)] " + line)
            }
            if interrupted { interruptedWithWorkLeft = true }
            if !interrupted {
                neverHandedFailure = true
                for id in ids {
                    LastResultsStore.record(project: unit.project, scenarioID: id, passed: false, profile: unit.profile)
                }
            }
        }
        let neverStarted = coordinator.unstartedTargets.filter { id in !hookFailedProjects.contains(unitProject[id] ?? "") }
        // 走り終えて終端になっていない対象(配り切れなかった・中断)と、一度も起こさなかった対象
        for unit in units {
            if neverStarted.contains(unit.id) {
                if finalizedTargets.withLock({ $0.insert(unit.id).inserted }) {
                    job?.mark(project: unit.project.name, profile: unit.profile,
                              state: MultiTargetJobTracker.finalState(
                                codes: [], started: false, hasUnhanded: false, interrupted: interrupted))
                }
            } else {
                finalizeRow(unit, interrupted)
            }
        }
        for id in neverStarted {
            FleetRunner.log("⚠️ \(interrupted ? "interrupted: " : "")\(id) was never started on any machine")
            if !interrupted { neverHandedFailure = true } else { interruptedWithWorkLeft = true }
        }

        printSummary(units: units, machineLabels: machineLabels, outcomes: results, wallSeconds: wallMs / 1000)
        for (name, collection) in healByProject.sorted(by: { $0.key < $1.key }) {
            if let project = units.first(where: { $0.project.name == name })?.project {
                collection.finish(project: project) { FleetRunner.log($0) }
            }
        }
        for unit in units where !hookFailedProjects.contains(unit.project.name) {
            let assigned: [(Int, DeviceMachineRunner.Group, [String])] = unit.entryByMachine
                .sorted(by: { $0.key < $1.key })
                .map { ($0.value, unit.groups[$0.value], unit.dispatcher.assignedIDs(entry: $0.value)) }
            let missing = reportMissingResults(unit: unit, runGroup: runGroup, since: dispatchStart, assigned: assigned,
                                               outcomes: results, machineLabels: machineLabels)
            // 渡したのに結果が無い分(子が受け取る前の中断など)。中断なら 130・それ以外は 1
            if missing > 0 {
                if interrupted { interruptedWithWorkLeft = true } else { neverHandedFailure = true }
            }
        }
        if let junit, let junitTempDir {
            let names = Array(Set(units.map(\.project.name))).sorted().joined(separator: "+")
            FleetRunner.mergeAndWriteJUnit(
                junit: junit, project: names, tempDir: junitTempDir, entries: childHosts.withLock { $0 },
                beforeRunFailures: projectHooks.withLock { $0 }.sorted { $0.key < $1.key }.compactMap { name, hook in
                    hook.parent.beforeRunFailureReason.map { (project: name, reason: $0) }
                })
        }
        return DeviceMachineRunner.parentExitCode(
            childCodes: results.map(\.exitCode), neverHandedFailure: neverHandedFailure,
            interruptedWithWorkLeft: interruptedWithWorkLeft)
    }

    /// 全マシンの送りの固定費[ms]。リモートは facts の dispatchOverheadSeconds(DeviceMachineRunner.assign と同じ出どころ)、手元は 0
    private static func overheadsMs(project: TestProject, labels: [String]) -> [Double] {
        let factsDir = RemoteHostFactsStore.dir(project: project)
        let registry = LocalConfig.load().remoteHosts ?? []
        let localHost = RunRecorder.currentMachine()
        return labels.map { label in
            guard label != DeviceMachineGrouping.localDisplayName else { return 0 }
            let facts = RemoteHostFactsStore.load(
                dir: factsDir,
                host: RemoteHostFactsStore.hostKey(machine: label, entries: registry, localHost: localHost))
            return (facts?.dispatchOverheadSeconds ?? 0) * 1000
        }
    }

    /// 対象ごとの「結果の無いシナリオ」。DeviceMachineRunner.reportMissingResults と同じ文言・同じ記録で、
    /// 走査を **profile でも絞る**(同じプロジェクトの別プロファイルが同じシナリオ ID を記録して欠落を隠さない)
    /// 戻り値 = 結果の無いシナリオの数(親の終了コードに載せる)
    @discardableResult
    private static func reportMissingResults(
        unit: TargetUnit, runGroup: String, since: Date, assigned: [(Int, DeviceMachineRunner.Group, [String])],
        outcomes: [ChildOutcome], machineLabels: [String]
    ) -> Int {
        guard assigned.contains(where: { !$0.2.isEmpty }) else { return 0 }
        var missingTotal = 0
        let recorded = DeviceMachineRunner.scanRecordedScenarios(
            project: unit.project, runGroup: runGroup, since: since, profile: unit.profile,
            expected: assigned.flatMap { $0.2 })
        for (_, group, ids) in assigned {
            let machine = machineLabels.firstIndex(of: group.machineLabel)
            let exitCode = outcomes.last(where: { $0.unit == unit.id && $0.machine == machine })?.exitCode ?? -1
            let label = "\(group.machineLabel):\(unit.id)"
            let missing = DeviceMachineRunner.unrecordedScenarioIDs(assigned: ids, recorded: recorded.all)
            missingTotal += missing.count
            if !missing.isEmpty {
                FleetRunner.log(DeviceMachineRunner.missingResultsLine(machineLabel: label, exitCode: exitCode, ids: missing))
                for id in missing {
                    LastResultsStore.record(project: unit.project, scenarioID: id, passed: false, profile: unit.profile)
                }
            }
            guard exitCode != 0 else { continue }
            let interruptedIDs = ids.filter { recorded.interrupted.contains($0) }
            if !interruptedIDs.isEmpty {
                FleetRunner.log(DeviceMachineRunner.interruptedResultsLine(
                    machineLabel: label, exitCode: exitCode, ids: interruptedIDs))
            }
        }
        return missingTotal
    }

    private static func printSummary(units: [TargetUnit], machineLabels: [String], outcomes: [ChildOutcome], wallSeconds: Double) {
        FleetRunner.log("")
        FleetRunner.log("=== \(units.count) target(s) across \(machineLabels.count) machine(s) ===")
        for unit in units {
            let mine = outcomes.filter { $0.unit == unit.id }
            let code = FleetProfile.aggregateExitCode(mine.map(\.exitCode))
            let used = Dictionary(grouping: mine, by: \.machine).keys.sorted().map { machine -> String in
                let entry = unit.entryByMachine[machine]
                return "\(machineLabels[machine])(\(entry.map { unit.dispatcher.assignedIDs(entry: $0).count } ?? 0))"
            }.joined(separator: ", ")
            let result = mine.isEmpty ? "not run" : (code == 0 ? "✅ pass" : "❌ fail (exit \(code))")
            FleetRunner.log("\(unit.id): \(result)  machines(scenarios): \(used.isEmpty ? "-" : used)")
        }
        for (machine, label) in machineLabels.enumerated() {
            let busy = outcomes.filter { $0.machine == machine }.reduce(0) { $0 + $1.duration }
            FleetRunner.log(String(format: "machine %@: busy=%.1fs idle=%.1fs", label as NSString, busy,
                                   max(wallSeconds - busy, 0)))
        }
    }
}

// MARK: - 配り手(対象 × マシンの割り当て)

/// 空いたマシンごとに `TargetSchedule.decide` を呼び、子の起動を指示する。状態は全部 LockedValue の中。
/// 子の終了・タイマー・中断のどれが来ても空いているマシンを全部判定し直す(固定周期では回さない)。
/// ロックの順序は 配り手 → 対象のクロージャ(DynamicDispatcher のロック)の一方向。DynamicDispatcher は配り手を呼ばない
final class MultiTargetCoordinator: Sendable {

    struct Lane: Sendable {
        /// 対象のグループ(= DynamicDispatcher のエントリ)の添字
        let entry: Int
        let devices: Int
        let platforms: Set<String>
    }

    struct TargetUnit: Sendable {
        let id: String
        /// 全マシン一覧の添字 → この対象のレーン。載っていないマシンは回せない
        let lanes: [Int: Lane]
        let pending: @Sendable () -> [DynamicSplit.Scenario]
        let estimateMs: @Sendable (DynamicSplit.Scenario, Int) -> Double
        let childExited: @Sendable (Int) -> Void
        let interrupt: @Sendable () -> Void
    }

    /// 子を起こす。起こしたら戻り、子が終わったら `finished(終了コード)` を1回呼ぶ(テストは偽物を渡す)
    typealias Launch = @Sendable (_ unit: String, _ machine: Int, _ finished: @escaping @Sendable (Int32) -> Void) -> Void

    enum Status: Equatable, Sendable {
        case idle, busy(String), finished
    }

    private struct Pair: Hashable { let unit: String; let machine: Int }

    private struct State {
        var status: [Status]
        var unstarted: [String]
        var running: [String: Set<Int>] = [:]
        var launched: Set<Pair> = []
        /// 対象ごとの「終わる見込みの時刻」の記憶[ms]。始めた・加わったときの見込みの早いほう(expectedFreeAt を見よ)
        var anchor: [String: Double] = [:]
        var dead: Set<Int> = []
        var active = 0
        var interrupted = false
        var cancelTimer: DynamicDispatcher.Cancel?
        var finished = false
        var continuation: CheckedContinuation<Void, Never>?
    }

    private let state: LockedValue<State>
    private let units: [String: TargetUnit]
    private let overheadMs: [Double]
    private let nowMs: @Sendable () -> Double
    private let timer: DynamicDispatcher.Timer
    private let launch: Launch
    private let log: @Sendable (String) -> Void
    /// false = `--no-lpt`(未着手の対象を宣言の順に試す)
    private let lpt: Bool

    init(units: [TargetUnit], machineCount: Int, overheadMs: [Double],
         nowMs: @escaping @Sendable () -> Double = DynamicDispatcher.monotonicClock(),
         timer: @escaping DynamicDispatcher.Timer = DynamicDispatcher.dispatchTimer,
         lpt: Bool = true,
         launch: @escaping Launch, log: @escaping @Sendable (String) -> Void = { _ in }) {
        self.lpt = lpt
        self.units = Dictionary(units.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        self.overheadMs = overheadMs
        self.nowMs = nowMs
        self.timer = timer
        self.launch = launch
        self.log = log
        state = LockedValue(State(status: Array(repeating: .idle, count: machineCount),
                                  unstarted: units.map(\.id)))
    }

    // MARK: - 入口

    func start() { reconsider() }

    /// 中断: 以後は子を起こさず、各対象の配り手が保留中も以後の要求も none で答える。走っている子は待つ
    func interrupt() {
        state.withLock { $0.interrupted = true }
        for unit in units.values { unit.interrupt() }
        reconsider()
    }

    func waitUntilFinished() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            state.withLock { s in
                if s.finished { continuation.resume() } else { s.continuation = continuation }
            }
        }
    }

    // MARK: - 読み出し

    var isInterrupted: Bool { state.withLock { $0.interrupted } }
    /// 一度もどのマシンでも起こさなかった対象(担当が抜けて未着手へ戻った対象は含めない = その残りは対象ごとの「配られなかった」が言う)
    var unstartedTargets: [String] {
        state.withLock { s in s.unstarted.filter { id in !s.launched.contains { $0.unit == id } } }
    }
    var deadMachines: Set<Int> { state.withLock { $0.dead } }
    var statuses: [Status] { state.withLock { $0.status } }

    // MARK: - 判定

    private func childFinished(unit: String, machine: Int, exitCode: Int32) {
        if let spec = units[unit], let lane = spec.lanes[machine] { spec.childExited(lane.entry) }
        let pendingLeft = !(units[unit]?.pending().isEmpty ?? true)
        state.withLock { s in
            s.active -= 1
            s.running[unit]?.remove(machine)
            if s.running[unit]?.isEmpty == true {
                s.running.removeValue(forKey: unit)
                // **担当が0台になっても誰にも渡していない分が残っていれば、未着手へ戻す**(ほかのマシンが始める)。
                // 戻さないと「走っている」でも「未着手」でもなくなり、落ちた1台の残りが誰にも配られず赤で残った。
                // 渡し済みは回し直さない(配り手が持たない)・抜けたマシンは同じ対象を起こし直さない(launched)
                if pendingLeft, !s.unstarted.contains(unit) {
                    s.unstarted.append(unit)
                    s.anchor[unit] = nil   // 始め直す側の見込みで覚え直す(古い時刻のままだと始めた直後から期限切れに見える)
                }
            }
            // 0(全緑)と 1(シナリオの失敗)以外は子が異常終了した印。そのマシンには以後配らない
            if exitCode != 0 && exitCode != 1 {
                s.dead.insert(machine)
                s.status[machine] = .finished
            } else {
                s.status[machine] = .idle
            }
        }
        if exitCode != 0 && exitCode != 1 {
            log("⚠️ machine #\(machine) ended abnormally (exit \(exitCode)) while running \(unit); no further work goes to it")
        }
        reconsider()
    }

    private func reconsider() {
        let starts: [(unit: String, machine: Int)] = state.withLock { s in
            var out: [(unit: String, machine: Int)] = []
            let now = nowMs()
            s.cancelTimer?()
            s.cancelTimer = nil
            if s.interrupted {
                for m in s.status.indices where s.status[m] == .idle { s.status[m] = .finished }
            } else {
                var earliest: Double?
                var progressed = true
                while progressed {
                    progressed = false
                    earliest = nil
                    for m in s.status.indices where s.status[m] == .idle {
                        switch decide(&s, machine: m, now: now) {
                        case .start(let id), .join(let id):
                            guard units[id] != nil, !s.launched.contains(Pair(unit: id, machine: m)) else {
                                s.status[m] = .finished
                                break
                            }
                            if let finish = expectedFinish(unit: id, adding: m, state: s, now: now) {
                                s.anchor[id] = min(s.anchor[id] ?? .infinity, finish)
                            }
                            s.unstarted.removeAll { $0 == id }
                            s.running[id, default: []].insert(m)
                            s.status[m] = .busy(id)
                            s.launched.insert(Pair(unit: id, machine: m))
                            s.active += 1
                            out.append((id, m))
                            progressed = true
                        case .hold(let at):
                            if let at, at < (earliest ?? .infinity) { earliest = at }
                        case .done:
                            s.status[m] = .finished
                        }
                        if progressed { break }
                    }
                }
                if let earliest {
                    s.cancelTimer = timer(max(earliest - now, 0)) { [weak self] in self?.reconsider() }
                }
                // 何も走っておらず、待つ時刻も無いなら、待っていても状況は変わらない(判定が時刻の無い保留を返し続ける)
                if s.active == 0, out.isEmpty, s.cancelTimer == nil {
                    for m in s.status.indices where s.status[m] == .idle { s.status[m] = .finished }
                }
            }
            if s.active == 0, !s.status.contains(.idle), s.cancelTimer == nil || s.interrupted {
                s.cancelTimer?()
                s.cancelTimer = nil
                s.finished = true
                s.continuation?.resume()
                s.continuation = nil
            }
            return out
        }
        for (unit, machine) in starts {
            // **予約したあとに中断が来ていたら起こさない**(予約はロックの中・起動は外なので、その間の中断を見落とすと
            // 中断のあとに子が起きる)。予約を戻して終わりの判定をし直す
            let cancelled = state.withLock { s -> Bool in
                guard s.interrupted else { return false }
                s.active -= 1
                s.running[unit]?.remove(machine)
                if s.running[unit]?.isEmpty == true { s.running.removeValue(forKey: unit) }
                s.status[machine] = .finished
                return true
            }
            if cancelled {
                reconsider()
                continue
            }
            launch(unit, machine) { [self] code in childFinished(unit: unit, machine: machine, exitCode: code) }
        }
    }

    private func decide(_ s: inout State, machine: Int, now: Double) -> TargetSchedule.Decision {
        let states: [TargetSchedule.MachineState] = s.status.indices.map { m in
            if case .busy(let id) = s.status[m] {
                return TargetSchedule.MachineState(machine: m, currentTarget: id,
                                                expectedFreeAt: expectedFreeAt(unit: id, running: s, now: now))
            }
            return TargetSchedule.MachineState(machine: m, currentTarget: nil, expectedFreeAt: nil)
        }
        let snapshot = s
        return TargetSchedule.decide(
            for: machine, now: now, unstarted: s.unstarted, running: s.running,
            hasPending: { id in !(units[id]?.pending().isEmpty ?? true) },
            machines: states,
            aloneMs: { id, m in aloneMs(unit: id, machine: m, state: snapshot) },
            overheadMs: { m in m < overheadMs.count ? overheadMs[m] : 0 },
            joinGainMs: { id, m in joinGain(unit: id, machine: m, state: snapshot, now: now) }, lpt: lpt)
    }

    /// machine が走っている対象に加わると終わりがどれだけ早まるか(`TargetSchedule.joinGain`)。担当のデバイスは今、加わるデバイスは固定費の後に空く
    private func joinGain(unit id: String, machine: Int, state s: State, now: Double) -> Double? {
        guard let unit = units[id], let lane = unit.lanes[machine] else { return nil }
        func joinLane(_ l: Lane, at t: Double) -> TargetSchedule.JoinLane {
            TargetSchedule.JoinLane(entry: l.entry, devices: l.devices, platforms: l.platforms, availableAt: t)
        }
        let members = (s.running[id] ?? []).sorted().compactMap { unit.lanes[$0].map { joinLane($0, at: now) } }
        let overhead = machine < overheadMs.count ? overheadMs[machine] : 0
        return TargetSchedule.joinGain(
            pending: unit.pending(), members: members, joiner: joinLane(lane, at: now + overhead),
            estimateMs: unit.estimateMs)
    }

    /// その対象を、このマシンのこの対象のデバイスだけで、まだ配っていない分を全部回す時間[ms]。
    /// 回せない(レーンが無い・死んだ・一度起こして抜けた・残りにこのマシンで回せるものが無い)なら nil。
    /// **今その対象を回しているマシンは nil にしない** —— 加わる判定(TargetSchedule)は回しているマシンの速さの和で
    /// 「加わらないときの終わり」を出すので、nil だと速さ 0 になり、終わり際に1台も加わらなかった。
    /// 抜けたマシンを外すのは、配り手が終わったエントリの要求を受けない(起こし直せない)ため
    private func aloneMs(unit id: String, machine: Int, state s: State) -> Double? {
        let leftAlready = s.launched.contains(Pair(unit: id, machine: machine))
            && !(s.running[id]?.contains(machine) ?? false)
        guard let unit = units[id], let lane = unit.lanes[machine], !s.dead.contains(machine),
              !leftAlready else { return nil }
        let fitting = unit.pending().filter { lane.platforms.contains($0.platform) }
        guard !fitting.isEmpty else { return nil }
        let total = fitting.reduce(0.0) { $0 + unit.estimateMs($1, lane.entry) }
        return total / Double(max(lane.devices, 1))
    }

    /// 走っている対象が終わる見込みの時刻 = min(記憶した時刻, 今 + 残りの見込み)。
    /// **「今 + 残り」だけにしない** —— 毎回いまから作り直すので、見込みより遅れても期限を過ぎた側へ一度も倒れず、
    /// TargetSchedule の安全弁が効かない(FM が落ちて遅くなった手元を「もうすぐ空く速いマシン」と見続け、空いた2台が
    /// 未着手の対象を取らずに10分以上待った)。記憶した時刻は遅れを覚え、残りの見込みは早く進んだ分を拾う
    private func expectedFreeAt(unit id: String, running s: State, now: Double) -> Double {
        let rest = remainingFinish(unit: id, members: s.running[id] ?? [], now: now)
        return min(s.anchor[id] ?? .infinity, rest ?? now)
    }

    /// その対象を members で回したときの「今 + 残り」。速さはマシンごとの 1/見込み の和。残りが無ければ nil
    private func remainingFinish(unit id: String, members: Set<Int>, now: Double) -> Double? {
        guard let unit = units[id] else { return nil }
        var rate = 0.0
        for m in members {
            guard let lane = unit.lanes[m] else { continue }
            let fitting = unit.pending().filter { lane.platforms.contains($0.platform) }
            let total = fitting.reduce(0.0) { $0 + unit.estimateMs($1, lane.entry) } / Double(max(lane.devices, 1))
            if total > 0 { rate += 1 / total }
        }
        return rate > 0 ? now + 1 / rate : nil
    }

    /// machine が始める・加わるときの終わる見込み(固定費の後から加わった速さで回る近似)
    private func expectedFinish(unit id: String, adding machine: Int, state s: State, now: Double) -> Double? {
        let overhead = machine < overheadMs.count ? overheadMs[machine] : 0
        guard let rest = remainingFinish(unit: id, members: (s.running[id] ?? []).union([machine]), now: now + overhead)
        else { return nil }
        return rest
    }
}
