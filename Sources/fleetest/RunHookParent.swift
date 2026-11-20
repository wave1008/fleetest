// RunHookParent.swift
// マシンをまたぐ発行元(DeviceMachineRunner / ApiRunMachineFanout / MultiTargetRunner の1プロジェクト)の beforeRun / afterRun(RR-8.4)。
// 走らせるかの判断・afterRun の条件・時間の上限は FTCore の `RunHookPlan` の1箇所。ここは起こして hub へ結果を渡すだけ。
// - beforeRun は子の起動と並行に走らせ、書き込みを hub へ確定分として入れてから開始(失敗なら取りやめ)を決める
// - afterRun は全部の子が終わった後。写しは hub の確定済みの最終の値

import FTCore
import Foundation

/// フックの子プロセスを中断(SIGINT / SIGTERM)で止める登録簿。発行元は `RunInterruptState` を持たない(2回目の中断で
/// 即終了する逃げ道を発行元に置かない = DeviceMachineRunner.ParentInterrupt の宣言)ので、止めるだけの別の口にする
final class RunHookInterrupt: @unchecked Sendable {
    // @unchecked の根拠: stopped / processes は lock の下でしか触らない
    private let lock = NSLock()
    private var stopped = false
    private var processes: [ObjectIdentifier: Process] = [:]

    var isStopped: Bool {
        lock.lock(); defer { lock.unlock() }
        return stopped
    }

    func stop() {
        lock.lock()
        stopped = true
        let toKill = Array(processes.values)
        lock.unlock()
        // SIGTERM だけ。時限の SIGKILL へ上げない(シナリオ実行バイナリは SIGTERM で後始末して抜ける契約 = process-lifecycle.md)
        for process in toKill where process.isRunning { process.terminate() }
    }

    /// `ScenarioHost.runRunHook(registerChildProcess:)` へ渡す。登録前に既に中断済みならその場で止める(登録と中断の競合の取りこぼし対策)
    func register(_ process: Process) -> @Sendable () -> Void {
        let id = ObjectIdentifier(process)
        lock.lock()
        let alreadyStopped = stopped
        if !alreadyStopped { processes[id] = process }
        lock.unlock()
        if alreadyStopped, process.isRunning { process.terminate() }
        return { [weak self] in
            guard let self else { return }
            self.lock.lock()
            self.processes.removeValue(forKey: id)
            self.lock.unlock()
        }
    }
}

/// 実行プロファイル(1つ以上)からフックの束を作る。解決できないプロファイルは飛ばして1行言う(子が自分で同じ検査を通して断る。
/// 黙って既定の設定へ落とすと、フックだけが別の上限・報告先で走ったことが見えない)
enum RunHookSetup {
    static func context(project: TestProject, className: String, profiles: [String],
                        setOverrides: [String: RunProfileSetValue], reportDirOverride: String?,
                        log: (String) -> Void) -> RunHookContext {
        var resolved: [ResolvedProfile] = []
        for name in profiles {
            do {
                resolved.append(try ProfileResolver.resolve(project: project, runName: name, workspaceOverride: nil,
                                                            overrides: setOverrides))
            } catch {
                log("⚠️ beforeRun() / afterRun(): could not read run profile \(name) (\(error.localizedDescription));"
                    + " they run without its settings")
            }
        }
        return RunHookContext(
            project: project, className: className,
            settings: resolved.first.map { ScenarioExecutionSettings($0) } ?? ScenarioExecutionSettings(),
            reportDir: reportDirOverride ?? resolved.first?.reportDir.path ?? project.reportsDir.path,
            timeoutSeconds: RunWideHookPlan.timeoutSeconds(profileScenarioTimeouts: resolved.map(\.scenarioTimeout)))
    }
}

final class RunHookParent: @unchecked Sendable {
    // @unchecked の根拠: `relay` は lock の下でしか触らない。他の保持値は不変か LockedValue / RunHookInterrupt(自前で排他)
    let context: RunHookContext
    let interrupt = RunHookInterrupt()
    private let log: @Sendable (String) -> Void
    private let lock = NSLock()
    private var relay: InterruptRelay?
    private let failedFlag = LockedValue(false)
    private let interruptedFlag = LockedValue(false)
    private let failureReason = LockedValue<String?>(nil)

    /// beforeRun が**失敗した**(取りやめの決定より前に立てる)。中断では立てない。取りやめで終わる子の未完了のシナリオを失敗として合成しない判断に使う
    var beforeRunFailed: Bool { failedFlag.value }

    /// beforeRun が失敗した理由(失敗していなければ nil)。マシンをまたぐ親の JUnit に失敗の項目として載せる
    var beforeRunFailureReason: String? { failureReason.value }

    /// beforeRun が中断で止められた(失敗ではない。親は既存の中断の終わり方 = 130 に寄せる)
    var beforeRunInterrupted: Bool { interruptedFlag.value }

    /// 中断の購読を立てる(登録前に受けた中断も拾う)。`close` で外す
    init(context: RunHookContext, log: @escaping @Sendable (String) -> Void) {
        self.context = context
        self.log = log
        let interrupt = interrupt
        let observed = InterruptRelay.observing(catchUp: true) { interrupt.stop() }
        lock.lock()
        relay = observed
        lock.unlock()
    }

    func close() {
        lock.lock()
        let current = relay
        relay = nil
        lock.unlock()
        current?.stop()
    }

    /// 子の起動と並行に beforeRun を走らせ、書き込みを hub へ確定分として入れて開始の決定を出す。
    /// 戻りの Task は全部の子が終わった後に await する(失敗でも afterRun は走る)
    func start(hub: RunMemoHub) -> Task<RunHookOutcome, Never> {
        let context = context, interrupt = interrupt, log = log
        return Task { [self] in
            let before = await RunHookFlow.runBefore(
                context, registerChildProcess: { interrupt.register($0) },
                interrupted: { interrupt.isStopped }, log: { log($0) })
            switch before.verdict {
            case .failed(let reason):
                failureReason.value = reason
                failedFlag.value = true
                log("❌ Run stopped: \(reason)")
            case .interrupted:
                interruptedFlag.value = true
            case .passed:
                break
            }
            let ops = before.outcome.runMemoOps
            let dropped = ops.count - hub.seedConfirmed(ops)
            if dropped > 0 { log(RunWideHookPlan.oversizedSeedLine(dropped: dropped)) }
            hub.decideGate(RunWideHookPlan.gateSignal(for: before.verdict))
            return before.outcome
        }
    }

    /// 全部の子が終わった後の afterRun。走らせない条件は `RunWideHookPlan.afterRunVerdict`
    func finish(hub: RunMemoHub, beforeRun: Task<RunHookOutcome, Never>, childExitCodes: [Int32],
                interrupted: Bool) async {
        _ = await beforeRun.value
        let log = log, interrupt = interrupt
        await RunHookFlow.finish(
            context, runMemo: hub.finalValues(), childExitCodes: childExitCodes,
            interrupted: interrupted || interrupt.isStopped,
            registerChildProcess: { interrupt.register($0) }, log: { log($0) })
    }
}

/// 1台のマシンだけの run(`run` / `api run` の各実行経路。親とつながっていない run)の beforeRun / afterRun。
/// 走らせるかの判断は `RunHookPlan`(0本の run・親とつながった子では走らせない)。run メモの共有の写しへは、呼び手が
/// レーンを起こす前に `seedOps` を入れる
struct SingleMachineRunHooks {
    private let context: RunHookContext?
    /// beforeRun が出した run メモの書き込み(失敗した beforeRun のぶんも入る = afterRun が途中まで作った分を片付けられる)
    let seedOps: [RunMemoOp]
    /// beforeRun が失敗した(1本も流さずに終える)
    let beforeFailure: RunHookOutcome?

    var abortReason: String? { beforeFailure.map(RunWideHookPlan.abortReason) }

    /// 走らせないなら何もしない値を返す。**ビルドと供給より後・どのレーンもシナリオを流し始める前**に呼ぶ(供給は並行で進んでいてよい)
    /// - dryRun: true なら走らせない(dry-run は副作用を持たない。デバッグ実行も同じ扱い = 人が1本ずつ進める実行に準備は要らない)
    static func begin(hooksClass: String?, scenarioCount: Int, dryRun: Bool, project: TestProject,
                      settings: ScenarioExecutionSettings,
                      reportDir: String, profileScenarioTimeout: Int?, interruptState: RunInterruptState,
                      launcher: @escaping RunHookContext.Launcher = RunHookContext.realLauncher,
                      log: @escaping (String) -> Void) async -> SingleMachineRunHooks {
        guard let className = RunWideHookPlan.hooksClassToRun(
            hooksClass: hooksClass, scenarioCount: scenarioCount, dryRun: dryRun, linkedToParent: ParentLink.isLinked)
        else { return SingleMachineRunHooks(context: nil, seedOps: [], beforeFailure: nil) }
        let context = RunHookContext(
            project: project, className: className, settings: settings, reportDir: reportDir,
            timeoutSeconds: RunWideHookPlan.timeoutSeconds(profileScenarioTimeouts: [profileScenarioTimeout]),
            launcher: launcher)
        // 起こす前に中断済みなら起こさない(中断は既存の終わり方 = 呼び手がそのまま中断として流す。afterRun は中断で走らない)
        if interruptState.isStopped { return SingleMachineRunHooks(context: context, seedOps: [], beforeFailure: nil) }
        let before = await RunHookFlow.runBefore(
            context, registerChildProcess: { interruptState.registerChildProcess($0) },
            interrupted: { interruptState.isStopped }, log: log)
        // 中断で止められた beforeRun は失敗として記録しない(1台の run は既存の中断の終わり方へ進む)
        let failure: RunHookOutcome? = { if case .failed = before.verdict { return before.outcome } else { return nil } }()
        return SingleMachineRunHooks(context: context, seedOps: before.outcome.runMemoOps, beforeFailure: failure)
    }

    /// 全部終わって afterAll の後(beforeRun が失敗した run は、流さずに終える前)。中断された run では走らせず1行言う(RunHookPlan)
    func finish(runMemo: [String: [String]], interruptState: RunInterruptState, log: @escaping (String) -> Void) async {
        guard let context else { return }
        await RunHookFlow.finish(
            context, runMemo: runMemo, childExitCodes: [], interrupted: interruptState.isStopped,
            registerChildProcess: { interruptState.registerChildProcess($0) }, log: log)
    }
}
