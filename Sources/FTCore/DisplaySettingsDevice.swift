// DisplaySettingsDevice.swift
// 端末の表示条件(外観・文字サイズ)を読む・設定する側(DR-221・DR-222)。判定は DisplaySettings.swift の純粋関数、
// シナリオへの組み込みは ScenarioHost+DisplaySettings.swift。**撃つのは親(`ScenarioHost.run` の側)だけ** —— シナリオの子はサンドボックスの中。
import Foundation

/// 定数の根拠はすべて DR-222 / PT-13。尽きたときの扱いは各行
public enum DisplaySettingsLimits {
    /// `devicectl --timeout` に渡す1回の上限[秒](整数だけ)。根拠: 8台同時・負荷の高い状態(load average 約 500)の最大 2.08 秒の約5倍。
    /// 尽きたら1回だけ撃ち直し、2回とも完了しなければ失敗(DR-221 の扱い)にして `backoffSeconds` の遮断に入る
    public static let commandTimeoutSeconds = 10
    /// 上限を超えたときの撃ち直しの回数。同じ値の設定は何度撃っても結果が同じなので DR-136 の対象外
    public static let retryCount = 1
    /// 時間切れの後に、このプロセスの中で `devicectl` の表示設定を呼ばない秒数(プロセス全体で共有。別の run・シナリオの子(DSL)のプロセスとは共有しない)。
    /// ライブ操作の `DevicectlBackoff` と同じ 30 秒。尽きたら次の呼び出しから通常どおり撃つ
    public static let backoffSeconds: TimeInterval = 30
    /// `devicectl --timeout` が受け付ける下限[秒]。下回ると devicectl は撃たずに exit 64(「Please specify a 'timeout' value between 5 and …」
    /// = 回帰の中断で観測。中断の戻しが毎回失敗していた)。上の上限はどれもこれ以上にする(テストが固定)
    public static let devicectlMinimumTimeoutSeconds = 5
    /// 中断(SIGINT/SIGTERM)の最中の終わりの処理の1回の上限[秒]。中断の応答を遅らせない短さで、負荷の高い状態の最大 2.08 秒を
    /// 超え、`devicectlMinimumTimeoutSeconds` を下回らない。撃ち直さない。尽きたら実行ログに戻せなかったと出す(次の開始時の読み取りが直す)
    public static let interruptedTimeoutSeconds = 5
    /// `devicectl` 自身の `--timeout` が効かずに居座ったときの外側の打ち切りの上乗せ[秒]。尽きたら時間切れとして数える
    public static let outerGraceSeconds: TimeInterval = 5
}

/// 1回の呼び出しの上限と撃ち直し
public struct DisplayCommandBudget: Sendable, Equatable {
    public let timeoutSeconds: Int
    public let retries: Int
    public init(timeoutSeconds: Int, retries: Int) {
        self.timeoutSeconds = timeoutSeconds
        self.retries = retries
    }
    public static let normal = DisplayCommandBudget(
        timeoutSeconds: DisplaySettingsLimits.commandTimeoutSeconds, retries: DisplaySettingsLimits.retryCount)
    public static let interrupted = DisplayCommandBudget(
        timeoutSeconds: DisplaySettingsLimits.interruptedTimeoutSeconds, retries: 0)
}

/// 時間切れの後の遮断(DR-222)。**プロセス全体で共有するので並行から触る**(`shared`。別のプロセスとは共有しない)。数えるのは時間切れだけ —— 速く失敗した
/// 1台(切断・非対応)で他の台の設定まで止めない
public final class DisplaySettingsBackoff: Sendable {
    public static let shared = DisplaySettingsBackoff()

    private let lastTimeout = LockedValue<ContinuousClock.Instant?>(nil)
    private let now: @Sendable () -> ContinuousClock.Instant
    private let seconds: TimeInterval

    public init(seconds: TimeInterval = DisplaySettingsLimits.backoffSeconds,
                now: @escaping @Sendable () -> ContinuousClock.Instant = { ContinuousClock.now }) {
        self.seconds = seconds
        self.now = now
    }

    public var isActive: Bool {
        guard let last = lastTimeout.value else { return false }
        return Self.isActive(lastTimeoutAt: last, now: now(), seconds: seconds)
    }

    public func noteTimeout() { lastTimeout.value = now() }

    public func reset() { lastTimeout.value = nil }

    /// 判定だけの純粋関数(`DevicectlBackoff.isActive` と同じ形)
    static func isActive(lastTimeoutAt: ContinuousClock.Instant, now: ContinuousClock.Instant, seconds: TimeInterval) -> Bool {
        now - lastTimeoutAt < .seconds(seconds)
    }
}

public struct DisplayReadResult: Sendable, Equatable {
    public var observation: DisplayObservation
    /// 読めなかった理由(1つでも読めなければ非 nil)
    public var failure: String?
    /// 遮断中で撃たなかった(この端末の失敗ではない = 「合わせられない」の印を付けない)
    public var paused: Bool
    public init(observation: DisplayObservation, failure: String?, paused: Bool = false) {
        self.observation = observation
        self.failure = failure
        self.paused = paused
    }
}

public struct DisplayApplyResult: Sendable, Equatable {
    /// 設定できなかったキー。iOS は1コマンドなので失敗したら渡したキーの全部(どちらが失敗したか分からない)
    public var failedKeys: Set<DisplayKey>
    public var failure: String?
    /// 遮断中で撃たなかった(`DisplayReadResult.paused` と同じ)
    public var paused: Bool
    public var succeeded: Bool { failure == nil }
    public init(failedKeys: Set<DisplayKey>, failure: String?, paused: Bool = false) {
        self.failedKeys = failedKeys
        self.failure = failure
        self.paused = paused
    }
    public static let ok = DisplayApplyResult(failedKeys: [], failure: nil)
}

public protocol DisplaySettingsTransport: Sendable {
    func read(budget: DisplayCommandBudget) -> DisplayReadResult
    func apply(_ change: DisplayChange, budget: DisplayCommandBudget) -> DisplayApplyResult
}

public typealias DisplayCommandRunner = @Sendable (_ args: [String], _ timeout: TimeInterval) throws -> Shell.Result

enum DisplayCommandExecutor {
    enum Outcome {
        case ok(Shell.Result)
        case failed(String)
        /// 遮断中で撃たなかった。**他の端末の時間切れでも入る**(遮断はプロセス全体)ので、この端末の失敗と分ける
        case paused(String)
    }

    /// devicectl 自身の時間切れ(`--timeout`)の終了コードは観測できていないので、
    /// 「0 以外で終わり、かつ上限に届くまで掛かった」も時間切れに数える(速い失敗は数えない)。
    /// **サンドボックスの代行が完了しなかった(`SandboxBroker.didNotCompleteStatus`)も時間切れ** = DSL のように子から撃つと、
    /// 時間切れは throw ではなくこの終了コードで返る(`BridgeClient.stopOnSimulator` と同じ契約)
    static func isTimeout(status: Int32, elapsed: TimeInterval, limitSeconds: Int) -> Bool {
        status == SandboxBroker.didNotCompleteStatus || (status != 0 && elapsed >= TimeInterval(limitSeconds) - 0.5)
    }

    /// 上限を超えたら `budget.retries` 回だけ撃ち直す。全部時間切れなら遮断へ入る。
    /// `outerGrace` = `--timeout` を持たない adb は 0・devicectl は `outerGraceSeconds`
    static func execute(_ args: [String], budget: DisplayCommandBudget, outerGrace: TimeInterval,
                        backoff: DisplaySettingsBackoff?, run: DisplayCommandRunner) -> Outcome {
        if let backoff, backoff.isActive {
            return .paused("display settings via devicectl are paused for "
                + "\(Int(DisplaySettingsLimits.backoffSeconds))s after a timeout")
        }
        let clock = ContinuousClock()
        var attempts = 0
        while attempts <= budget.retries {
            attempts += 1
            let start = clock.now
            do {
                let result = try run(args, TimeInterval(budget.timeoutSeconds) + outerGrace)
                if result.status == 0 { return .ok(result) }
                let elapsed = Double((clock.now - start).components.seconds)
                    + Double((clock.now - start).components.attoseconds) / 1e18
                if !isTimeout(status: result.status, elapsed: elapsed, limitSeconds: budget.timeoutSeconds) {
                    let tail = result.tail.isEmpty ? "" : ": " + result.tail
                    return .failed("exit code \(result.status)\(tail)")
                }
            } catch ShellError.timedOut {
                // 時間切れ。撃ち直しへ
            } catch {
                return .failed(error.localizedDescription)
            }
        }
        backoff?.noteTimeout()
        return .failed("did not complete within \(budget.timeoutSeconds)s (tried \(attempts) time\(attempts == 1 ? "" : "s"))")
    }
}

/// iOS(Simulator も実機も)。`devicectl` だけを使い `simctl ui` へは切り替えない(DR-222)
public struct IOSDisplaySettingsTransport: DisplaySettingsTransport {
    private let udid: String
    private let backoff: DisplaySettingsBackoff
    private let run: DisplayCommandRunner

    public init(udid: String, backoff: DisplaySettingsBackoff = .shared,
                run: @escaping DisplayCommandRunner = { try Shell.run($0, timeout: $1) }) {
        self.udid = udid
        self.backoff = backoff
        self.run = run
    }

    public func read(budget: DisplayCommandBudget) -> DisplayReadResult {
        let args = DisplaySettingsCommands.iosRead(udid: udid, timeoutSeconds: budget.timeoutSeconds)
        switch DisplayCommandExecutor.execute(args, budget: budget, outerGrace: DisplaySettingsLimits.outerGraceSeconds,
                                              backoff: backoff, run: run) {
        case .failed(let detail):
            return DisplayReadResult(observation: DisplayObservation(), failure: "read appearance: \(detail)")
        case .paused(let detail):
            return DisplayReadResult(observation: DisplayObservation(), failure: "read appearance: \(detail)", paused: true)
        case .ok(let result):
            guard let observation = DisplaySettingsParser.ios(json: Data(result.output.utf8)) else {
                return DisplayReadResult(observation: DisplayObservation(),
                                         failure: "read appearance: the devicectl output could not be parsed")
            }
            return DisplayReadResult(observation: observation, failure: nil)
        }
    }

    public func apply(_ change: DisplayChange, budget: DisplayCommandBudget) -> DisplayApplyResult {
        guard !change.isEmpty else { return .ok }
        let args = DisplaySettingsCommands.iosSet(udid: udid, change: change, timeoutSeconds: budget.timeoutSeconds)
        switch DisplayCommandExecutor.execute(args, budget: budget, outerGrace: DisplaySettingsLimits.outerGraceSeconds,
                                              backoff: backoff, run: run) {
        case .ok: return .ok
        case .failed(let detail):
            return DisplayApplyResult(failedKeys: change.keys, failure: "set appearance: \(detail)")
        case .paused(let detail):
            return DisplayApplyResult(failedKeys: change.keys, failure: "set appearance: \(detail)", paused: true)
        }
    }
}

/// Android(Emulator も実機も)。外観と文字サイズは別のコマンド
public struct AndroidDisplaySettingsTransport: DisplaySettingsTransport {
    private let serial: String
    private let adb: String?
    private let run: DisplayCommandRunner

    public init(serial: String, adb: String? = AdbLocator.adbPath(),
                run: @escaping DisplayCommandRunner = { try Shell.run($0, timeout: $1) }) {
        self.serial = serial
        self.adb = adb
        self.run = run
    }

    private func execute(_ args: [String], budget: DisplayCommandBudget) -> DisplayCommandExecutor.Outcome {
        DisplayCommandExecutor.execute(args, budget: budget, outerGrace: 0, backoff: nil, run: run)
    }

    public func read(budget: DisplayCommandBudget) -> DisplayReadResult {
        guard let adb else {
            return DisplayReadResult(observation: DisplayObservation(), failure: "adb was not found")
        }
        var observation = DisplayObservation()
        var failures: [String] = []
        switch execute(DisplaySettingsCommands.androidNightRead(adb: adb, serial: serial), budget: budget) {
        case .ok(let result):
            observation.appearance = DisplaySettingsParser.androidNight(result.output)
            if observation.appearance == nil { failures.append("read night mode: the output could not be parsed") }
        case .failed(let detail), .paused(let detail): failures.append("read night mode: \(detail)")
        }
        switch execute(DisplaySettingsCommands.androidFontScaleRead(adb: adb, serial: serial), budget: budget) {
        case .ok(let result):
            observation.textSize = DisplaySettingsParser.androidFontScale(result.output)
            if observation.textSize == nil { failures.append("read font_scale: the output could not be parsed") }
        case .failed(let detail), .paused(let detail): failures.append("read font_scale: \(detail)")
        }
        return DisplayReadResult(observation: observation, failure: failures.isEmpty ? nil : failures.joined(separator: "; "))
    }

    public func apply(_ change: DisplayChange, budget: DisplayCommandBudget) -> DisplayApplyResult {
        guard !change.keys.isEmpty else { return .ok }
        guard let adb else { return DisplayApplyResult(failedKeys: change.keys, failure: "adb was not found") }
        var failed: Set<DisplayKey> = []
        var failures: [String] = []
        if let appearance = change.appearance {
            switch execute(DisplaySettingsCommands.androidNightSet(adb: adb, serial: serial, appearance: appearance), budget: budget) {
            case .ok: break
            case .failed(let detail), .paused(let detail):
                failed.insert(.appearance)
                failures.append("set night mode: \(detail)")
            }
        }
        if let textSize = change.textSize {
            switch execute(DisplaySettingsCommands.androidFontScaleSet(adb: adb, serial: serial, textSize: textSize), budget: budget) {
            case .ok: break
            case .failed(let detail), .paused(let detail):
                failed.insert(.textSize)
                failures.append("set font_scale: \(detail)")
            }
        }
        return DisplayApplyResult(failedKeys: failed, failure: failures.isEmpty ? nil : failures.joined(separator: "; "))
    }
}

/// 端末ごと・run の間だけの状態(`RunDeviceSession` が持つ)。DR-221: 指定の無いキーを基準へ合わせられなかった端末は、
/// 設定のコマンドが1回でも成功するまで基準へ合わせる処理を試みない(毎回の失敗で時間を払わない)
public final class DisplaySettingsLaneState: Sendable {
    private let unreachable = LockedValue<Bool>(false)
    public init() {}
    public var baselineUnreachable: Bool { unreachable.value }
    public func markBaselineUnreachable() { unreachable.value = true }
    public func noteSetSucceeded() { unreachable.value = false }
}

public struct DisplaySettingsStart: Sendable, Equatable {
    /// nil = 何もしなかった(結果の欄を省く)
    public var record: DisplaySettingsRecord?
    /// 実行ログへ1行ずつ
    public var notices: [String]
    /// 非 nil = 指定のあるキーを合わせられなかった(そのシナリオを失敗にする。説明は `failureSummary`)
    public var failureDetail: String?
    public var changed: [DisplayKey]
    /// 開始時の最初の読み取りで読んだ iOS の「より大きな文字」(終わりに戻す)
    public var largerAtStart: Bool?

    public var didNothing: Bool { record == nil }

    /// 失敗のステップの説明(DR-221)
    public static func failureSummary(_ expected: DisplayExpectation) -> String {
        "display settings before the scenario (\(expected.summary))"
    }
}

public enum DisplaySettingsEngine {
    /// DR-221 の開始時: 読む → 違うキーだけ設定 → 読み返す
    public static func start(expected: DisplayExpectation, transport: DisplaySettingsTransport,
                             lane: DisplaySettingsLaneState) -> DisplaySettingsStart {
        let handled = DisplaySettingsPlan.handledKeys(expected: expected, baselineUnreachable: lane.baselineUnreachable)
        guard !handled.isEmpty else {
            return DisplaySettingsStart(record: nil, notices: [], failureDetail: nil, changed: [], largerAtStart: nil)
        }
        let budget = DisplayCommandBudget.normal
        let first = transport.read(budget: budget)
        var observation = first.observation
        var anyRead = observation.appearance != nil || observation.textSize != nil
        let keys = DisplaySettingsPlan.keysToSet(expected: expected, observed: observation, handling: handled)
        var failedKeys: Set<DisplayKey> = []
        var details: [String] = []
        var changed: [DisplayKey] = []
        var parts = ["expected \(expected.summary)", "read \(describe(observation))"]
        if let failure = first.failure { details.append(failure) }
        var paused = first.paused

        if !keys.isEmpty {
            let applied = transport.apply(
                DisplaySettingsPlan.change(keys: keys, target: expected, restoreLarger: nil), budget: budget)
            let done = keys.subtracting(applied.failedKeys)
            changed = DisplayKey.allCases.filter { done.contains($0) }
            if !done.isEmpty { lane.noteSetSucceeded() }
            failedKeys = applied.failedKeys
            paused = paused || applied.paused
            if let failure = applied.failure { details.append(failure) }
            parts.append("set \(changed.map(\.rawValue).joined(separator: ", "))")
            if !done.isEmpty {
                let back = transport.read(budget: budget)
                paused = paused || back.paused
                observation = back.observation
                anyRead = anyRead || observation.appearance != nil || observation.textSize != nil
                parts.append("read back \(describe(observation))")
                let still = DisplaySettingsPlan.keysToSet(expected: expected, observed: observation, handling: done)
                for key in DisplayKey.allCases where still.contains(key) {
                    details.append("\(key.rawValue): expected \(expected.value(key)), read back \(observation.value(key) ?? "nothing")")
                }
                if let failure = back.failure, !still.isEmpty { details.append(failure) }
                failedKeys.formUnion(still)
            }
        }

        let verdict = DisplaySettingsPlan.classifyFailures(failedKeys, expected: expected)
        var notices: [String] = ["display settings: " + parts.joined(separator: "; ")]
        if !verdict.warn.isEmpty {
            let keys = verdict.warn.map(\.rawValue).joined(separator: ", ")
            let because = details.isEmpty ? "" : " (\(details.joined(separator: "; ")))"
            // **遮断中で撃たなかった回は印を付けない** = 遮断はプロセス全体なので、別の端末の時間切れでも入る。印を付けると、
            // 成功する機会の無い端末が run の終わりまで基準へ戻されなくなる(DR-222)
            if paused {
                notices.append("⚠️ display settings: could not return \(keys) to the baseline (light, default text size) while"
                    + " devicectl calls are paused after a timeout; the next scenario tries again" + because)
            } else {
                lane.markBaselineUnreachable()
                notices.append("⚠️ display settings: could not return \(keys) to the baseline"
                    + " (light, default text size); this device is not tried again until a setting succeeds" + because)
            }
        }
        return DisplaySettingsStart(
            record: DisplaySettingsPlan.record(expected: expected, observed: anyRead ? observation : nil, changed: changed),
            notices: notices,
            failureDetail: verdict.mustFail.isEmpty ? nil : details.joined(separator: "; "),
            changed: changed,
            largerAtStart: first.observation.largerAccessibilitySizes)
    }

    /// DR-221 の終わり: 読み、基準の状態と違うキーだけ戻して読み返す。**失敗は警告だけ**(次の開始時の読み取りが直す)。
    /// `interrupted` = 中断の最中。短い上限で撃ち直さない
    public static func end(started: DisplaySettingsStart, expected: DisplayExpectation, interrupted: Bool,
                           transport: DisplaySettingsTransport, lane: DisplaySettingsLaneState) -> [String] {
        let handled = DisplaySettingsPlan.handledKeys(expected: expected, baselineUnreachable: lane.baselineUnreachable)
        guard !handled.isEmpty else { return [] }
        if started.failureDetail != nil, started.changed.isEmpty { return [] }
        let budget = interrupted ? DisplayCommandBudget.interrupted : .normal
        let first = transport.read(budget: budget)
        let target = DisplayExpectation.baseline
        let keys = DisplaySettingsPlan.keysToSet(expected: target, observed: first.observation, handling: handled)
        let larger = DisplaySettingsPlan.largerToRestore(
            atStart: started.largerAtStart, now: first.observation.largerAccessibilitySizes)
        let change = DisplaySettingsPlan.change(keys: keys, target: target, restoreLarger: larger)
        let after = interrupted ? "while interrupted" : "after the scenario"
        guard !change.isEmpty else {
            if let failure = first.failure {
                return ["⚠️ display settings \(after): could not read the device (\(failure)); the next scenario reads it again"]
            }
            return []
        }
        let applied = transport.apply(change, budget: budget)
        if applied.succeeded { lane.noteSetSucceeded() }
        var line = "display settings \(after): read \(describe(first.observation)); set \(describeChange(change))"
        var problems: [String] = []
        if let failure = applied.failure { problems.append(failure) }
        if applied.succeeded {
            let back = transport.read(budget: budget)
            line += "; read back \(describe(back.observation))"
            for key in DisplaySettingsPlan.keysToSet(expected: target, observed: back.observation, handling: keys) {
                problems.append("\(key.rawValue): expected \(target.value(key)), read back \(back.observation.value(key) ?? "nothing")")
            }
            if !problems.isEmpty, let failure = back.failure { problems.append(failure) }
        }
        guard problems.isEmpty else {
            return [line, "⚠️ display settings \(after): could not return the device to the baseline (\(problems.joined(separator: "; ")));"
                + " the next scenario reads it again"]
        }
        return [line]
    }

    static func describe(_ observation: DisplayObservation) -> String {
        "appearance=\(observation.appearance ?? "?"), textSize=\(observation.textSize ?? "?")"
    }

    static func describeChange(_ change: DisplayChange) -> String {
        var parts: [String] = []
        if let appearance = change.appearance { parts.append("appearance=\(appearance.rawValue)") }
        if let textSize = change.textSize { parts.append("textSize=\(textSize.rawValue)") }
        if let larger = change.largerAccessibilitySizes { parts.append("largerAccessibilitySizes=\(larger ? "on" : "off")") }
        return parts.joined(separator: ", ")
    }
}
