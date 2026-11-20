// RunHookHost.swift
// `@RunHooks` の beforeRun() / afterRun()(RR-8.4・DR-209)を、**発行元のマシンから**シナリオ実行バイナリの専用の口
// (`run --run-hook before|after`)で1回起こす部品と、一覧の段での `@RunHooks` の数の検査。
// 起こし方は afterAll の専用の子(`--after-all-only`)と同じ形(サンドボックスの入口・中断のリレー・子の stdout の NDJSON)だが、
// **ドライバを持たない**(--port / --serial を渡さない)・compose のテスト用サーバーへの通り道(gateway)も渡さない(RR-8.4 絞った規則)。
// 呼び手(run の各経路)への配線はここに無い。

import Foundation

public enum RunHookPhase: String, Sendable {
    case before, after

    /// DSL のメソッド名
    public var hookName: String { self == .before ? "beforeRun" : "afterRun" }
}

public struct RunHookOutcome: Sendable {
    public let passed: Bool
    /// 英語。失敗の理由(passed == false のとき。言えないときは nil)
    public let failureReason: String?
    /// フックが出した run メモの書き込みを出た順に(`RunMemoOp` は RunMemoStore.swift)
    public let runMemoOps: [RunMemoOp]
    /// 子が書いたレポートのパス(書けなかった・子が起きなかったときは nil)
    public let reportPath: String?

    /// クラスがその段のフックを宣言しているか(false = 子は何もしなかった。親は「走った」と言わない)
    public let declared: Bool
    /// 子が「この段のフックは宣言されていない」と知らせるイベントの kind(FTScenarioRunner/RunHookRun.swift と対)
    public static let notDeclaredEventKind = "runHookNotDeclared"

    public init(passed: Bool, failureReason: String? = nil, runMemoOps: [RunMemoOp] = [], reportPath: String? = nil,
                declared: Bool = true) {
        self.declared = declared
        self.passed = passed
        self.failureReason = failureReason
        self.runMemoOps = runMemoOps
        self.reportPath = reportPath
    }
}

/// 一覧の段(`list --json` の `runHooks`)で数える。子(`--run-hook`)の入口も同じ文言を使う
public enum RunHookCount {
    public static func multipleMessage(classNames: [String]) -> String {
        "more than one @RunHooks class in this project (\(classNames.sorted().joined(separator: ", "))):"
            + " keep exactly one class with @RunHooks and put beforeRun() / afterRun() in it"
    }

    /// 0個 = nil・1個 = そのクラス名・2個以上は throw
    public static func single(_ classNames: [String]) throws -> String? {
        if classNames.count > 1 { throw ScenarioHostError.multipleRunHooks(classNames) }
        return classNames.first
    }
}

/// `ScenarioHost.listing` の結果
public struct ScenarioListing: Sendable {
    public let scenarios: [ScenarioInfo]
    /// `@RunHooks` のクラス名(無ければ nil。2個以上は listing が throw する)
    public let runHooksClass: String?

    public init(scenarios: [ScenarioInfo], runHooksClass: String?) {
        self.scenarios = scenarios
        self.runHooksClass = runHooksClass
    }
}

/// フックの子の NDJSON イベントの畳み込み(純粋なロジック。`ScenarioHost.runRunHook` が使う)
struct RunHookEventFold {
    private(set) var ops: [RunMemoOp] = []
    private(set) var finishedPassed: Bool?
    private(set) var reportPath: String?
    private(set) var firstFailure: String?
    private(set) var notDeclared = false

    /// イベントを1件取り込み、呼び手の log へ流す行を返す(run メモの書き込み・内部のイベントは流さない)
    mutating func consume(_ event: ScenarioEvent) -> [String] {
        switch event.kind {
        case "runMemoWrite":
            if let key = event.memoKey, let value = event.memoValue { ops.append(.write(key: key, value: value)) }
            return []
        case "runMemoClear":
            ops.append(.clear)
            return []
        case "idleAllowance", "deadlineExclusion", "installRequest":
            return []
        case RunHookOutcome.notDeclaredEventKind:
            notDeclared = true
            return []
        case "scenarioFinished":
            finishedPassed = event.passed
            reportPath = event.reportPath
        case "step":
            if firstFailure == nil, event.status == "failed" {
                // detail が説明を含む(アサーションの「<説明> did not hold」)ときは detail だけ。重ねると同じ文が2回並ぶ
                if let detail = event.detail, let description = event.description, detail.contains(description) {
                    firstFailure = detail
                } else {
                    firstFailure = [event.description, event.detail].compactMap { $0 }.joined(separator: ": ")
                }
            }
        default:
            break
        }
        return ScenarioLogFormatter.lines(for: event)
    }

    /// 子が終わった後の結果。`timeoutSeconds` は打ち切ったときだけ(打ち切りが先に勝つ)
    func outcome(exitStatus: Int32, timedOutAfter timeoutSeconds: Int?, phase: RunHookPhase,
                 stderrTail: String?) -> RunHookOutcome {
        if let timeoutSeconds {
            return RunHookOutcome(
                passed: false,
                failureReason: "\(phase.hookName)() exceeded \(timeoutSeconds)s (scenarioTimeout) and was killed",
                runMemoOps: ops, reportPath: reportPath)
        }
        let passed = finishedPassed ?? (exitStatus == 0)
        if passed { return RunHookOutcome(passed: true, runMemoOps: ops, reportPath: reportPath, declared: !notDeclared) }
        let reason = firstFailure ?? stderrTail ?? "\(phase.hookName)() exited with status \(exitStatus)"
        return RunHookOutcome(passed: false, failureReason: reason, runMemoOps: ops, reportPath: reportPath)
    }
}

extension ScenarioHost {
    /// 子の引数。ドライバ接続の引数(--port / --serial / --udid 等)は**持たない**
    static func runHookArguments(className: String, phase: RunHookPhase, reportDir: String, projectRoot: String,
                                 tunables: String, config: LocalConfig) -> [String] {
        ["run", "--scenario", className, "--run-hook", phase.rawValue,
         "--report-dir", reportDir, "--json",
         "--project-dir", projectRoot,
         "--run-started-at", TestLogSessionLabel.processStart,
         "--device-session-stdin", "--tunables", tunables]
            + accountRedactionArguments(config)
    }

    /// `@RunHooks` のクラスの beforeRun() / afterRun() を、この機械で1回起こす。**発行元(スケジューリングを行う機械)から呼ぶ**。
    /// 失敗(子が起きない・赤・打ち切り)は投げず `passed == false` で返す。
    /// 引数に既定値は置かない = 呼び手の渡し忘れをコンパイルで止める。
    /// - runMemo: 子へ渡す run メモの写し(beforeRun は空か既存の確定分・afterRun は全マシンの書き込みがそろった最終の値)
    /// - settings: 実行プロファイルの設定(使うのは `tunables`)。`timeoutSeconds` は呼び手が解いた上限(nil = 上限なし。
    ///   RR-8.4 はその run のそのプロジェクトの対象のうち最も長い `scenarioTimeout`)
    /// - registerChildProcess: 中断(SIGINT / SIGTERM)で子を止める登録口(`run` の子と同じ)
    /// - log: 子の出力と起こす側の注記を英語の1行ずつ流す先(呼ばれるのはこの関数を呼んだタスクの上)
    public static func runRunHook(project: TestProject, phase: RunHookPhase, className: String,
                                  runMemo: [String: [String]],
                                  settings: ScenarioExecutionSettings,
                                  reportDir: String,
                                  timeoutSeconds: Int?,
                                  registerChildProcess: (@Sendable (Process) -> @Sendable () -> Void)?,
                                  log: @escaping (String) -> Void) async -> RunHookOutcome {
        func failed(_ reason: String) -> RunHookOutcome {
            log("❌ \(reason)")
            return RunHookOutcome(passed: false, failureReason: reason)
        }
        let runner: URL
        do {
            runner = try runnerURL(project: project)
        } catch {
            return failed(error.localizedDescription)
        }
        let tunables: String
        do {
            tunables = try tunablesArgument(settings.tunables)
        } catch {
            return failed("cannot encode the run tunables: \(error.localizedDescription)")
        }
        let args = runHookArguments(className: className, phase: phase, reportDir: reportDir,
                                    projectRoot: project.rootURL.path, tunables: tunables,
                                    config: LocalConfig.load())
        var isDirectory: ObjCBool = false
        if !FileManager.default.fileExists(atPath: runner.path, isDirectory: &isDirectory) || isDirectory.boolValue
            || !FileManager.default.isExecutableFile(atPath: runner.path) {
            return failed("Cannot start the runner: \(runner.path) is not an executable file")
        }

        let process = Process()
        process.executableURL = runner
        process.arguments = args
        process.environment = childEnvironment()
        var sandboxBroker: SandboxBroker?
        defer { sandboxBroker?.stop() }
        do {
            // 一覧取得と同じ枠(ドライバの口は開けない)。宛先の許可(allowedDomains)は枠に含まれる = httpRequest が通る
            if let launch = try sandboxedLaunch(project: project, runner: runner, arguments: args,
                                                reportDir: reportDir, connection: nil, drivesDevice: false) {
                sandboxBroker = launch.broker
                process.executableURL = launch.executable
                process.arguments = launch.arguments
                process.environment = launch.childEnvironment(base: process.environment ?? ProcessInfo.processInfo.environment)
                log(ScenarioSandbox.notice)
            } else {
                log(ScenarioSandbox.disabledNotice)
            }
        } catch {
            return failed("sandbox: " + error.localizedDescription)
        }

        let stdout = Pipe()
        let stderr = Pipe()
        let stdinPipe = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        process.standardInput = stdinPipe
        // 子が先に死んでいると書き込みは SIGPIPE で親ごと落ちる(run の子と同じ。fd 単位で止めて EPIPE を Swift のエラーで受ける)
        _ = fcntl(stdinPipe.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1)

        let processExited = ProcessExitWait.prepare(process)
        do {
            try process.run()
        } catch {
            return failed("Cannot start the runner: \(error.localizedDescription)")
        }
        let unregisterChildProcess = registerChildProcess?(process)
        defer { unregisterChildProcess?() }

        // 打ち切り: 上限を過ぎても子が生きていて、子の正常終了が先に claim していなければ SIGTERM → 猶予 → SIGKILL。
        // 勝者は1つの状態で決める(0 = 未決・1 = 子が先に終わった・2 = 打ち切りが勝った)
        let race = LockedValue(0)
        var killer: Task<Void, Never>?
        if let timeoutSeconds {
            killer = Task {
                try? await Task.sleep(for: watchdogDuration(seconds: timeoutSeconds), clock: SuspendingClock())
                guard !Task.isCancelled, ProcessLiveness.isAlive(process.processIdentifier),
                      race.withLock({ let was = $0; if was == 0 { $0 = 2 }; return was == 0 }) else { return }
                await terminateWithGrace(process)
            }
        }

        // 写しの書き込みは**打ち切りの監視を起こした後**・呼んだスレッドをブロックしない別スレッドで行う
        // (子が stdin を読まないまま止まると、パイプが詰まった書き込みが打ち切りの監視より前でブロックして上限が効かない)。
        // 子が死ねば書き込みは EPIPE で戻る(F_SETNOSIGPIPE 済み)
        // beforeRun / afterRun は run に1つ・他のシナリオと時間が重ならないので、ロックはその場で渡す
        let handoff = DeviceSessionHandoff(runMemo: runMemo, runSetUpDevice: false, runBeforeAll: false,
                                           lockAccess: .immediate, lockWaitCapSeconds: 0, lockOwnerToken: "")
        let handoffData = Data((handoff.encodedLine() + "\n").utf8)
        let stdinWriter = stdinPipe.fileHandleForWriting
        DispatchQueue.global(qos: .utility).async {
            try? stdinWriter.write(contentsOf: handoffData)
            try? stdinWriter.close()
        }

        let stderrTask = Task.detached { () -> [String] in
            var lines: [String] = []
            for await rawLine in lineStream(stderr.fileHandleForReading) {
                lines.append(SecretRedactor.shared.redact(rawLine))
            }
            return lines
        }

        var fold = RunHookEventFold()
        for await rawLine in lineStream(stdout.fileHandleForReading) {
            // 子が伏せる値を知らせてきた行は登録簿へ入れて捨てる(どこにも書き出さない)
            guard let line = SecretRedactor.hostStdoutLine(rawLine) else { continue }
            if let event = ScenarioEvent.decode(line: line) {
                for out in fold.consume(event) { log(out) }
            } else if !line.isEmpty {
                log(line)
            }
        }
        for await _ in processExited {}
        // 打ち切りの発火より先に終わっていたら打ち切りは何もしない(判定は終了経路に任せる)
        let timedOut = race.withLock { let was = $0; if was == 0 { $0 = 1 }; return was == 2 }
        killer?.cancel()
        let errLines = await stderrTask.value
        for line in errLines where !line.isEmpty { log(line.hasPrefix("⚠️") ? line : "⚠️ \(line)") }

        return fold.outcome(exitStatus: process.terminationStatus,
                            timedOutAfter: timedOut ? timeoutSeconds : nil, phase: phase,
                            stderrTail: errLines.last { !$0.isEmpty })
    }
}
