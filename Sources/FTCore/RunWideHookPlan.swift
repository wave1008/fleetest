// RunWideHookPlan.swift
// `@RunHooks` の beforeRun() / afterRun()(RR-8.4・DR-209)を走らせるかどうかの判断と、run ログの文言。
// 判断は**この1箇所だけ**(1台の run・マシンをまたぐ発行元・複数対象の親・MCP は結果を写すだけ。別々に書くと経路ごとに条件がずれる)。

import Foundation

public enum RunWideHookPlan {
    /// フックを走らせるクラス名(nil = 走らせない)。
    /// - シナリオが0本の run では走らせない(何も流れない run の準備をしない)
    /// - dry-run では走らせない(フックは副作用を持つ。dry-run はデバイスにも外部にも触れない)
    /// - 親とつながった子(`linkedToParent`)では走らせない(走らせるのは発行元。子が走らせると全マシンで重複する)
    /// - `--fleet` のエントリ(`fleetEntry`)では走らせない(各エントリは別々の run で、マシンごとにばらばらの時刻に走ってしまう。
    ///   入口の検査 `fleetRefusal` に加えた2つ目の門 = 入口の検査をすり抜けた形でも走らせない)
    public static func hooksClassToRun(hooksClass: String?, scenarioCount: Int, dryRun: Bool,
                                       linkedToParent: Bool, fleetEntry: Bool = RunLockHost.isFleetEntry) -> String? {
        guard let hooksClass, scenarioCount > 0, !dryRun, !linkedToParent, !fleetEntry else { return nil }
        return hooksClass
    }

    /// プロジェクトのシナリオのソース(`scenarios/` の `.swift`。`_disabled/` はビルドされない = Package.swift の exclude なので見ない)を
    /// 1つずつ読み、`predicate` が真になるものがあるか。**ソースを走査する検査(`@RunHooks` の宣言・ロックの使用)の唯一の歩き方**
    public static func anyScenarioSource(in project: TestProject, where predicate: (String) -> Bool) -> Bool {
        guard let files = FileManager.default.enumerator(at: project.scenariosDir, includingPropertiesForKeys: nil) else { return false }
        let disabled = project.disabledDir.standardizedFileURL.path + "/"
        for case let url as URL in files where url.pathExtension == "swift" {
            if url.standardizedFileURL.path.hasPrefix(disabled) { continue }
            if let text = try? String(contentsOf: url, encoding: .utf8), predicate(text) { return true }
        }
        return false
    }

    /// 同じプロジェクトの別の run が進行中の pid(自分の pid は数えない。昇順・重複なし)。**重なり警告の唯一の数え方**
    /// (`overlappingRunsLine` と `RunLockUsage.overlapLine` が文言だけ変えて使う)
    public static func otherRunPids(project: String, ownPid: Int32, records: [RunProgressRecord]) -> [Int32] {
        Set(records.filter { $0.project == project && $0.pid != ownPid }.map(\.pid)).sorted()
    }

    public enum AfterVerdict: Equatable, Sendable {
        case run
        /// 走らせない。`reason` は「afterRun did not run: <reason>」の後半
        case skip(reason: String)
    }

    /// afterRun を走らせるか。**全マシンの子が正常に(終了コード 0 / 1 で)終わり、run が中断されていないときだけ**走らせる
    /// (子が異常に終わった = 向こうの run の終わりを確かめられない。まだ動いているテストの下で片付けを撃たない側に倒す。
    /// 取りこぼしの回収は作らない = DR-209)。1台の run は子が無いので `childExitCodes` は空
    public static func afterRunVerdict(childExitCodes: [Int32], interrupted: Bool) -> AfterVerdict {
        if interrupted { return .skip(reason: "the run was interrupted") }
        if let abnormal = childExitCodes.first(where: { $0 != 0 && $0 != 1 }) {
            return .skip(reason: "a machine's sub-run ended abnormally (exit \(abnormal)),"
                + " so the tests on it may still be running")
        }
        return .run
    }

    /// フックの打ち切り秒。**対象のうち最も長い `scenarioTimeout`**(プロファイルに無い対象は既定。新しい数字を置かない)。
    /// 1つの対象ならそのプロファイルの値
    public static func timeoutSeconds(profileScenarioTimeouts: [Int?]) -> Int {
        let resolved = profileScenarioTimeouts.map { ScenarioTimeoutResolution.seconds(scenario: nil, settings: $0) }
        return resolved.max() ?? ScenarioHost.defaultScenarioTimeout
    }

    public enum BeforeVerdict: Equatable, Sendable {
        case passed
        /// beforeRun の失敗(`reason` は abortReason の文言)
        case failed(reason: String)
        /// 中断(失敗ではない。**中断で子を殺された beforeRun を失敗として記録しない**)
        case interrupted
    }

    /// beforeRun の結果の仕分け。**中断が先**(中断で止められた子は passed == false で返るので、失敗と取り違えない)
    public static func classify(outcome: RunHookOutcome, interrupted: Bool) -> BeforeVerdict {
        if interrupted { return .interrupted }
        return outcome.passed ? .passed : .failed(reason: abortReason(outcome))
    }

    /// 開始の行(発行元 → 子)。beforeRun が通れば開始・失敗か中断なら取りやめ
    public static func gateSignal(for verdict: BeforeVerdict) -> WorkQueueProtocol.StartSignal {
        switch verdict {
        case .passed: return .start
        case .failed(let reason): return .cancel(reason: reason)
        case .interrupted: return .cancel(reason: "interrupted before the run started")
        }
    }

    /// run.json の abortReason と取りやめの理由(英語)
    public static func abortReason(_ outcome: RunHookOutcome) -> String {
        "beforeRun() failed" + (outcome.failureReason.map { ": \($0)" } ?? "")
    }

    /// `--fleet` を断る文(英語)。各エントリが自分で一覧を作り、親とつながらないので、マシンごとにばらばらの時刻に走ってしまう
    public static let fleetRefusal = "--fleet cannot be used with a project that declares @RunHooks:"
        + " each entry runs on its own, so beforeRun() / afterRun() would run on each machine at a different time"
        + " (a shared server could be initialised in the middle of another machine's run)."
        + " Put the machines in one run profile's devices and use --profile instead"

    /// ソース1ファイルが `@RunHooks` / `@FTDSL.RunHooks` を宣言しているか(ビルドせずに見る = `--fleet` は親が一覧を作らない)。
    /// コメント(`//` と `/* */`)と文字列リテラルの外のどこにあっても数える(`@MainActor @RunHooks final class` も拾う)
    public static func sourceDeclaresRunHooks(_ source: String) -> Bool {
        let code = strippingCommentsAndStrings(source)
        for token in ["@RunHooks", "@FTDSL.RunHooks"] {
            var searchFrom = code.startIndex
            while let range = code.range(of: token, range: searchFrom..<code.endIndex) {
                let next = code[range.upperBound...].first
                if next.map({ !($0.isLetter || $0.isNumber || $0 == "_") }) ?? true { return true }
                searchFrom = range.upperBound
            }
        }
        return false
    }

    /// コメントと文字列リテラルを空白に置き換える(入れ子の `/* */`・`"""` 複数行にも対応する程度の簡易な走査)
    static func strippingCommentsAndStrings(_ source: String) -> String {
        let chars = Array(source)
        var out = ""
        var i = 0
        var blockDepth = 0
        while i < chars.count {
            let c = chars[i]
            let next: Character? = i + 1 < chars.count ? chars[i + 1] : nil
            if blockDepth > 0 {
                if c == "/", next == "*" { blockDepth += 1; i += 2 }
                else if c == "*", next == "/" { blockDepth -= 1; i += 2 }
                else { i += 1 }
                continue
            }
            if c == "/", next == "/" {
                while i < chars.count, chars[i] != "\n" { i += 1 }
                continue
            }
            if c == "/", next == "*" { blockDepth = 1; i += 2; continue }
            if c == "\"" {
                let multiline = i + 2 < chars.count && chars[i + 1] == "\"" && chars[i + 2] == "\""
                i += multiline ? 3 : 1
                while i < chars.count {
                    if chars[i] == "\\" { i += 2; continue }
                    if multiline {
                        if chars[i] == "\"", i + 2 < chars.count, chars[i + 1] == "\"", chars[i + 2] == "\"" { i += 3; break }
                    } else if chars[i] == "\"" || chars[i] == "\n" { i += 1; break }
                    i += 1
                }
                out.append(" ")
                continue
            }
            out.append(c)
            i += 1
        }
        return out
    }

    /// フックの書き込み(出た順)を畳んだ run メモの値。beforeRun が失敗した 1台の run の afterRun が読む(レーンも hub も無い)
    public static func memoValues(afterOps ops: [RunMemoOp]) -> [String: [String]] {
        var ledger = RunMemoLedger()
        for op in ops { _ = ledger.addLocal(op) }
        return ledger.view()
    }

    /// beforeRun / afterRun を走らせない実行の仕方(プロファイル無しの `run`・デバッグ実行)で、宣言があることだけ言う(黙って飛ばさない)
    public static func unsupportedModeLine(mode: String) -> String {
        "⚠️ This project declares @RunHooks, but beforeRun() / afterRun() do not run in \(mode)"
    }

    public static func ranLine(_ phase: RunHookPhase, machine: String) -> String {
        "\(phase.hookName) ran on \(machine)"
    }

    /// 大きすぎて(`RunMemoWire.maxPieces` を超えて)他のマシンへ配れなかった beforeRun の書き込み。通常のシナリオの書き込みと同じく
    /// 黙って捨てない(`RunMemoLink.publish` の1行と同じ扱い)。発行元の hub に入らないので afterRun にも見えない
    public static func oversizedSeedLine(dropped: Int) -> String {
        "⚠️ \(dropped) run memo write(s) from beforeRun() are too large to share across machines and were dropped"
    }

    public static func afterSkippedLine(reason: String) -> String {
        "afterRun did not run: \(reason)"
    }
}

extension RunWideHookPlan {
    /// 同じプロジェクトの別の run がこのマシンで進行中のときの警告(英語。無ければ nil)。数えるのは run の台帳(`~/.fleetest/runs`。
    /// DS-18.11 のジョブの台帳ではなく、生きた pid の記録)で、**自分の pid は数えない**。
    /// 別のマシン・別の利用者の run は台帳に無いので見えない(範囲外 = RR-8.4「別々の run」)
    public static func overlappingRunsLine(project: String, ownPid: Int32, records: [RunProgressRecord]) -> String? {
        let others = otherRunPids(project: project, ownPid: ownPid, records: records)
        guard !others.isEmpty else { return nil }
        return "⚠️ \(others.count) other run(s) of project \(project) are in progress on this machine"
            + " (pid \(others.map(String.init).joined(separator: ", "))):"
            + " beforeRun() / afterRun() run once per run, so one that resets a shared server can break them"
    }

    /// 台帳を読んで `overlappingRunsLine` を作る
    static func currentOverlappingRunsLine(project: String) -> String? {
        overlappingRunsLine(
            project: project, ownPid: ProcessInfo.processInfo.processIdentifier,
            records: RunProgressLedger.readAll(directory: RunProgressLedger.directory(), startTime: ProcessLiveness.startTime))
    }

    /// このマシンの名前(run ログの「ran on」)。`ProcessInfo.hostName` は逆引きの DNS を引いて待たされうるので `gethostname` を読む
    public static func localHostName() -> String {
        var buffer = [CChar](repeating: 0, count: 256)
        guard gethostname(&buffer, buffer.count - 1) == 0 else { return "this machine" }
        return String(cString: buffer)
    }
}

/// 呼び手が1回のフックを走らせるのに要る束(`RunHookFlow` へ渡す)
public struct RunHookContext: Sendable {
    public let project: TestProject
    public let className: String
    public let settings: ScenarioExecutionSettings
    public let reportDir: String
    public let timeoutSeconds: Int
    /// run ログの「ran on <マシン>」に出す名前
    public let machine: String
    /// 同じプロジェクトの別の run が進行中のときの警告(beforeRun の前に出す。**コンテキストを作った時点の台帳**で決める =
    /// 親は子を起こす前に作るので、自分の子を別の run と数えない)
    public let overlapWarning: String?
    /// フックの子を起こす関数。production は `ScenarioHost.runRunHook`。テストは偽を渡す(本物は実行ファイルを探しに
    /// `swift build --show-bin-path` を撃ちうる = `swift test` が SwiftPM のロックを握っている間は永久に待つ)
    public let launcher: Launcher

    public typealias Launcher = @Sendable (_ context: RunHookContext, _ phase: RunHookPhase, _ runMemo: [String: [String]],
                                           _ registerChildProcess: (@Sendable (Process) -> @Sendable () -> Void)?,
                                           _ log: @escaping (String) -> Void) async -> RunHookOutcome

    public static let realLauncher: Launcher = { context, phase, runMemo, registerChildProcess, log in
        await ScenarioHost.runRunHook(
            project: context.project, phase: phase, className: context.className, runMemo: runMemo,
            settings: context.settings, reportDir: context.reportDir, timeoutSeconds: context.timeoutSeconds,
            registerChildProcess: registerChildProcess, log: log)
    }

    public init(project: TestProject, className: String, settings: ScenarioExecutionSettings,
                reportDir: String, timeoutSeconds: Int, machine: String = RunWideHookPlan.localHostName(),
                launcher: @escaping Launcher = RunHookContext.realLauncher) {
        self.project = project
        self.className = className
        self.settings = settings
        self.reportDir = reportDir
        self.timeoutSeconds = timeoutSeconds
        self.machine = machine
        self.overlapWarning = RunWideHookPlan.currentOverlappingRunsLine(project: project.name)
        self.launcher = launcher
    }
}

/// beforeRun の結果と仕分け(`RunWideHookPlan.classify`)
public struct RunHookBefore: Sendable {
    public let outcome: RunHookOutcome
    public let verdict: RunWideHookPlan.BeforeVerdict
}

/// フックの実行と run ログへの記録。**afterRun の失敗は合否に数えない**(呼び手は結果を変えない)
public enum RunHookFlow {
    /// - interrupted: 走らせ終えた時点で中断を受けていたか(受けていれば失敗として記録・表示しない)
    public static func runBefore(_ context: RunHookContext, runMemo: [String: [String]] = [:],
                                 registerChildProcess: (@Sendable (Process) -> @Sendable () -> Void)?,
                                 interrupted: @Sendable () -> Bool,
                                 log: @escaping (String) -> Void) async -> RunHookBefore {
        if let overlap = context.overlapWarning { log(overlap) }
        let outcome = await context.launcher(context, .before, runMemo, registerChildProcess, log)
        let verdict = RunWideHookPlan.classify(outcome: outcome, interrupted: interrupted())
        switch verdict {
        case .passed:
            log(RunWideHookPlan.ranLine(.before, machine: context.machine))
        case .failed(let reason):
            log("❌ " + reason + " (on \(context.machine))" + (outcome.reportPath.map { " (report: \($0))" } ?? ""))
        case .interrupted:
            log("⏹ beforeRun() was interrupted")
        }
        return RunHookBefore(outcome: outcome, verdict: verdict)
    }

    @discardableResult
    public static func runAfter(_ context: RunHookContext, runMemo: [String: [String]],
                                registerChildProcess: (@Sendable (Process) -> @Sendable () -> Void)?,
                                log: @escaping (String) -> Void) async -> RunHookOutcome {
        let outcome = await context.launcher(context, .after, runMemo, registerChildProcess, log)
        if outcome.passed {
            log(RunWideHookPlan.ranLine(.after, machine: context.machine))
        } else {
            log("⚠️ afterRun() failed on \(context.machine)" + (outcome.failureReason.map { ": \($0)" } ?? "")
                + (outcome.reportPath.map { " (report: \($0))" } ?? "") + " — the run result is unchanged")
        }
        return outcome
    }

    /// 判断(`RunWideHookPlan.afterRunVerdict`)を引いて、走らせるか1行言う
    public static func finish(_ context: RunHookContext, runMemo: [String: [String]],
                              childExitCodes: [Int32], interrupted: Bool,
                              registerChildProcess: (@Sendable (Process) -> @Sendable () -> Void)?,
                              log: @escaping (String) -> Void) async {
        switch RunWideHookPlan.afterRunVerdict(childExitCodes: childExitCodes, interrupted: interrupted) {
        case .run:
            _ = await runAfter(context, runMemo: runMemo, registerChildProcess: registerChildProcess, log: log)
        case .skip(let reason):
            log(RunWideHookPlan.afterSkippedLine(reason: reason))
        }
    }
}
