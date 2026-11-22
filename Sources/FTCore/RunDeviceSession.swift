// RunDeviceSession.swift
// 1回の run(または1回の呼び出し)で共有する状態の親側の持ち主。受け渡しの契約は DeviceSessionHandoff.swift。
// ScenarioHost.run が子の runMemoWrite / runMemoClear / deviceSetUp / beforeAll を横取りしてここへ反映し、
// 次のシナリオの起動時に handoff を stdin へ書く。
// 共有の範囲(ユーザー決定):
//   - run メモ = **run 全体**(DR-208。`RunSharedSession` の `RunMemoStore`。マシンをまたぐ run では発行元の通し番号の順に
//     全マシンでそろう = RunMemoStore.swift / RunMemoHub.swift)
//   - beforeAll の済み印・afterAll の申告 = **1つの fleetest プロセスが束ねるデバイスの範囲**(`RunSharedSession`。
//     機械ごとに分かれる run はマシンごと)
//   - setUpDevice の済み印・tearDownDevice の申告 = **1デバイス**(`RunDeviceSession`)

import Foundation

/// run 全体で1つ。全デバイスの `RunDeviceSession` が同じものを持つ
public final class RunSharedSession: @unchecked Sendable {
    // 不変条件: 状態はすべて lock の内側で読み書きする。waiters は beforeAll の状態が変わるたびに全部起こす
    private enum BeforeAllState {
        /// 親がこのクラスの beforeAll を1つのシナリオに受け持たせた(子はまだ始めたと言っていない)
        case reserved
        /// 子が beforeAll を始めた(ここから先は撃ち直さない = at-most-once)
        case began
        case passed
        case failed
    }

    private let lock = NSLock()
    private let runMemo: RunMemoStore
    /// run 全体のロック(RR-8.5)。親とつながった子(`ParentLink.isLinked`)は「呼んだら失敗」で始まる
    public let locks: RunLockHost
    private var beforeAll: [String: BeforeAllState] = [:]
    private var waiters: [CheckedContinuation<Void, Never>] = []
    /// afterAll を持つと子が申告したクラス(申告順 = 片付けの順)と、申告したシナリオが走った OS
    private var afterAllDeclared: [String] = []
    private var afterAllPlatforms: [String: Set<String>] = [:]
    private var afterAllTaken: Set<String> = []

    /// `runMemo` を省くと、マシンをまたぐ run の子(`ParentLink` が開いている)ならその通り道に載った1つ、そうでなければ新しい1つ
    /// `lockMode` の既定は「呼んだら失敗」(設定を忘れた経路が黙って割れない・黙って競合しない)。run の入口は `locks.configure`
    /// (走査の結果と上限・ここで `.ownServer` へ切り替わる)を呼ぶ。親とつながった子は常に「呼んだら失敗」。
    /// `lockHost`: プロセスで共有するホスト(MCP)を使うとき
    public init(runMemo: RunMemoStore? = nil, lockMode: RunLockHost.Mode = .refuse(RunLockHost.notConfiguredRefusal),
                lockHost: RunLockHost? = nil) {
        let store = runMemo ?? ParentLink.memoStore() ?? RunMemoStore()
        self.runMemo = store
        self.locks = lockHost ?? RunLockHost(mode: ParentLink.isLinked ? .refuse(RunLockHost.linkedChildRefusal) : lockMode)
    }

    /// 子へ渡すロックの扱い(`DeviceSessionHandoff` の3欄)。起動ごとの印を作り、この起動の run メモを登録する
    /// `override` を渡すと、その値をそのまま使いサーバーを起こさない(dry-run = 取らずに通す・debug 実行 = その場で渡す。
    /// 起こしてから上書きすると、使わないソケットを作る)
    func lockHandoff(override: RunLockAccess? = nil) -> (access: RunLockAccess, capSeconds: Int, token: String) {
        let token = UUID().uuidString
        locks.register(token: token, memo: runMemo)
        return (override ?? locks.access(), locks.currentWaitCapSeconds, token)
    }

    func declareAfterAll(className: String, platform: String?) {
        lock.lock()
        if !afterAllDeclared.contains(className) { afterAllDeclared.append(className) }
        if let platform { afterAllPlatforms[className, default: []].insert(platform) }
        lock.unlock()
    }

    /// まだ走らせていない申告済みの afterAll(申告順)を返し、**返した時点で済み印を付ける** = run で最大1回
    /// (結果が不明でも撃ち直さない)。platforms = そのクラスのシナリオが走った OS(走らせるデバイスを選ぶ材料)
    public func takePendingAfterAlls() -> [(className: String, platforms: Set<String>)] {
        lock.lock()
        defer { lock.unlock() }
        let pending = afterAllDeclared.filter { !afterAllTaken.contains($0) }
        afterAllTaken.formUnion(pending)
        return pending.map { ($0, afterAllPlatforms[$0] ?? []) }
    }

    public func runMemoSnapshot() -> [String: [String]] { runMemo.snapshot() }

    /// beforeRun の書き込みを run メモへ入れる(1台のマシンだけの run。レーンを起こす前に呼ぶ)
    public func seedRunMemo(_ ops: [RunMemoOp]) {
        for op in ops {
            switch op {
            case .write(let key, let value): runMemo.write(key: key, value: value)
            case .clear: runMemo.clear()
            }
        }
    }

    /// 子のイベントで届いた「ロックの外」の書き込み。ストアへ入れた後に数える(ロックのサーバーはこの数に届くまで run メモに答えない)
    func appendRunMemo(key: String, value: String, token: String) {
        let locks = self.locks
        runMemo.write(key: key, value: value) { locks.noteOutsideApplied(token: token) }
    }

    func confirmCommittedRunMemo(seq: Int, op: RunMemoOp) { runMemo.confirmCommitted(seq: seq, op: op) }

    func clearRunMemo(token: String) {
        let locks = self.locks
        runMemo.clear { locks.noteOutsideApplied(token: token) }
    }

    enum BeforeAllTicket: Equatable, Sendable { case run, skip, failed }

    /// このクラスの beforeAll をこのシナリオに受け持たせるか。**別のデバイスが受け持っていて終わっていなければ待つ**
    /// (そのクラスのどのシナリオも beforeAll より先に走らせない)。受け持った側が子を起こせずに終わったら
    /// `release` が未試行へ戻すので、待っていた側の1つが受け持ち直す
    func takeBeforeAll(className: String) async -> BeforeAllTicket {
        while true {
            let decision: BeforeAllTicket? = {
                lock.lock()
                defer { lock.unlock() }
                switch beforeAll[className] {
                case nil:
                    beforeAll[className] = .reserved
                    return .run
                case .reserved, .began: return nil
                case .passed: return .skip
                case .failed: return .failed
                }
            }()
            if let decision { return decision }
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                lock.lock()
                // 待ちに入る前に変わっていたら即座に起き直す(lock の外で変わった分を取りこぼさない)
                switch beforeAll[className] {
                case .reserved?, .began?:
                    waiters.append(continuation)
                    lock.unlock()
                default:
                    lock.unlock()
                    continuation.resume()
                }
            }
        }
    }

    func beforeAllEvent(className: String, status: String?) {
        let next: BeforeAllState?
        switch status {
        case "began": next = .began
        case "passed": next = .passed
        case "failed": next = .failed
        default: next = nil
        }
        guard let next else { return }
        setBeforeAll(className, next)
    }

    /// 受け持ったシナリオの子が終わったあと。始めたまま終わった(途中で死んだ・kill された)なら失敗にする
    /// (途中まで走った beforeAll を撃ち直すと二重実行になる)。始めてもいない(子を起こせなかった・子が
    /// beforeAll の前で落ちた)なら未試行へ戻し、待っている側が受け持ち直す
    func releaseBeforeAll(className: String) {
        lock.lock()
        let state = beforeAll[className]
        lock.unlock()
        switch state {
        case .began?: setBeforeAll(className, .failed)
        case .reserved?: setBeforeAll(className, nil)
        default: break
        }
    }

    private func setBeforeAll(_ className: String, _ state: BeforeAllState?) {
        lock.lock()
        beforeAll[className] = state
        let woken = waiters
        waiters.removeAll()
        lock.unlock()
        for waiter in woken { waiter.resume() }
    }
}

public final class RunDeviceSession: @unchecked Sendable {
    /// notApplicable = setUpDevice が対象外の宣言で終わった(fold を折りたためない台で撃った等)。失敗ではないので、
    /// 同じデバイスの同じクラスの後続は同じ理由の対象外にする(failed と同じに扱うと後続が赤になる)
    private enum SetUpState: Equatable { case began, passed, failed, notApplicable(String) }

    public let shared: RunSharedSession
    /// 端末の表示条件の「基準へ合わせられない」印(DR-221。デバイスごと・この run の間で、設定が1回成功するまで)
    public let displaySettings = DisplaySettingsLaneState()
    private let lock = NSLock()
    /// 試行済みのクラスだけを持つ(キー無し = 未試行)
    private var setUpStates: [String: SetUpState] = [:]
    /// tearDownDevice を持つと子が申告したクラス(申告順 = 片付けの順。決定的にするため配列)
    private var tearDownDeclared: [String] = []
    private var tornDown: Set<String> = []
    /// このデバイスで beforeAll を受け持たせたクラス(子の終了時に release する)
    private var beforeAllOwned: Set<String> = []

    /// `shared` = run 全体の状態。1デバイスだけの呼び出し(MCP の ft_run_scenario 等)は既定の新しい1つでよい
    public init(shared: RunSharedSession = RunSharedSession()) {
        self.shared = shared
    }

    /// シナリオ ID(`Class.method`)のクラス部。Swift の識別子は "." を含められないので最初の "." で切る。
    /// "." が無い ID(クラスだけの指定)は丸ごと返す
    public static func className(ofScenarioID id: String) -> String {
        guard let dot = id.firstIndex(of: ".") else { return id }
        return String(id[id.startIndex..<dot])
    }

    public enum HandoffDecision: Equatable, Sendable {
        case launch(DeviceSessionHandoff)
        /// このクラスの setUpDevice がこのデバイスで失敗済み
        case setUpDeviceFailed
        /// このクラスの setUpDevice がこのデバイスで対象外の宣言で終わった(理由は子の宣言のまま)
        case setUpDeviceNotApplicable(reason: String)
        /// このクラスの beforeAll がこの run で失敗済み
        case beforeAllFailed
    }

    /// 起動の可否と子へ渡す写し。`classHasBeforeAll`(`ScenarioInfo.beforeAll`)のクラスは、別のデバイスが
    /// beforeAll を受け持っている間ここで待つ。setUpDevice を持たないクラスは deviceSetUp を出さず未試行のままなので、
    /// 毎回 runSetUpDevice = true になる(子が無視する。クラスごとの有無は追跡しない)
    public func handoff(className: String, classHasBeforeAll: Bool,
                        lockOverride: RunLockAccess? = nil) async -> HandoffDecision {
        var runBeforeAll = false
        if classHasBeforeAll {
            switch await shared.takeBeforeAll(className: className) {
            case .run:
                runBeforeAll = true
                _ = lock.withLock { beforeAllOwned.insert(className) }
            case .skip: break
            case .failed: return .beforeAllFailed
            }
        }
        let state = lock.withLock { setUpStates[className] }
        if state == .failed {
            if runBeforeAll { releaseBeforeAll(className: className) }
            return .setUpDeviceFailed
        }
        if case .notApplicable(let reason)? = state {
            if runBeforeAll { releaseBeforeAll(className: className) }
            return .setUpDeviceNotApplicable(reason: reason)
        }
        let lock = shared.lockHandoff(override: lockOverride)
        return .launch(DeviceSessionHandoff(runMemo: shared.runMemoSnapshot(), runSetUpDevice: state == nil,
                                            runBeforeAll: runBeforeAll,
                                            lockAccess: lock.access, lockWaitCapSeconds: lock.capSeconds,
                                            lockOwnerToken: lock.token))
    }

    /// 子の runMemoWrite / runMemoClear / deviceSetUp / beforeAll / afterAll / deviceTearDown を反映する。
    /// 戻り値 true = 横取りした(emit しない)。`platform` = そのシナリオを走らせた OS(afterAll の申告に添える。
    /// ScenarioHost は接続の OS を必ず渡す)
    @discardableResult
    public func apply(_ event: ScenarioEvent, className: String, platform: String? = nil, lockOwnerToken: String = "") -> Bool {
        switch event.kind {
        case "afterAll":
            // status "declared" だけ(子がシナリオの開始時に、クラスが afterAll を持つときに出す)
            if event.status == "declared" { shared.declareAfterAll(className: className, platform: platform) }
            return true
        case "runMemoWrite":
            if let key = event.memoKey, let value = event.memoValue {
                shared.appendRunMemo(key: key, value: value, token: lockOwnerToken)
            }
            return true
        case "runMemoCommitted":
            // ロックの中の書き込み(発行元の正本が確定した通し番号つき)。ロックの外の書き込みの数(`outsideApplied`)には数えない
            if let seq = event.memoSeq {
                if let key = event.memoKey, let value = event.memoValue {
                    shared.confirmCommittedRunMemo(seq: seq, op: .write(key: key, value: value))
                } else {
                    shared.confirmCommittedRunMemo(seq: seq, op: .clear)
                }
            }
            return true
        case "runMemoClear":
            shared.clearRunMemo(token: lockOwnerToken)
            return true
        case "beforeAll":
            shared.beforeAllEvent(className: className, status: event.status)
            return true
        case "deviceTearDown":
            // status "declared" だけ(子がシナリオの開始時に、クラスが tearDownDevice を持つときに出す)
            if event.status == "declared" {
                lock.lock()
                if !tearDownDeclared.contains(className) { tearDownDeclared.append(className) }
                lock.unlock()
            }
            return true
        case "deviceSetUp":
            let next: SetUpState?
            switch event.status {
            case "began": next = .began
            case "passed": next = .passed
            case "failed": next = .failed
            // 理由は子が notApplicableReason で運ぶ。欠けていたら対象外と言えないので失敗に倒す
            case "notApplicable": next = event.notApplicableReason.map { .notApplicable($0) } ?? .failed
            default: next = nil
            }
            if let next {
                lock.lock()
                setUpStates[className] = next
                lock.unlock()
            }
            return true
        default:
            return false
        }
    }

    /// tearDownDevice 専用の子へ渡す写し(setUpDevice も beforeAll も走らせない・失敗済みでも片付けは走らせる)
    public func tearDownHandoff(lockOverride: RunLockAccess? = nil) -> DeviceSessionHandoff {
        let lock = shared.lockHandoff(override: lockOverride)
        return DeviceSessionHandoff(runMemo: shared.runMemoSnapshot(), runSetUpDevice: false, runBeforeAll: false,
                                    lockAccess: lock.access, lockWaitCapSeconds: lock.capSeconds,
                                    lockOwnerToken: lock.token)
    }

    /// まだ片付けていない申告済みクラス(申告順)を返し、**返した時点で済み印を付ける** = 1デバイスで最大1回
    /// (結果が不明でも撃ち直さない。setUpDevice と同じ at-most-once)
    public func takePendingTearDowns() -> [String] {
        lock.lock()
        defer { lock.unlock() }
        let pending = tearDownDeclared.filter { !tornDown.contains($0) }
        tornDown.formUnion(pending)
        return pending
    }

    /// 受け持った beforeAll を、子を起こさずに手放す(handoff の後で起動前に断った経路)
    public func releaseBeforeAll(className: String) {
        lock.lock()
        let owned = beforeAllOwned.remove(className) != nil
        lock.unlock()
        if owned { shared.releaseBeforeAll(className: className) }
    }

    /// 子の終了後に呼ぶ。began のまま終わった(setUpDevice の途中で死んだ・kill された)クラスは failed にする。
    /// 途中まで走った setUpDevice(アカウント作成等)を再実行すると二重実行になるので、at-most-once。
    /// beforeAll を受け持っていたら手放す(`RunSharedSession.releaseBeforeAll`)
    public func scenarioEnded(className: String) {
        lock.lock()
        if setUpStates[className] == .began { setUpStates[className] = .failed }
        lock.unlock()
        releaseBeforeAll(className: className)
    }
}

/// レーン鍵(`BroadcastPlan.laneKey(of:)`)→ RunDeviceSession。初回に作る。全部が同じ `RunSharedSession` を持つ
public final class RunDeviceSessionBook: @unchecked Sendable {
    private let lock = NSLock()
    private var sessions: [String: RunDeviceSession] = [:]
    public let shared = RunSharedSession()

    public init() {}

    public func session(for laneKey: String) -> RunDeviceSession {
        lock.lock()
        defer { lock.unlock() }
        if let existing = sessions[laneKey] { return existing }
        let created = RunDeviceSession(shared: shared)
        sessions[laneKey] = created
        return created
    }
}

/// tearDownDevice / afterAll 1本の結果(呼び手が自分の文脈の行へ写す)
public struct DeviceTearDownOutcome: Sendable {
    /// "tearDownDevice" / "afterAll"
    public let hook: String
    public let className: String
    /// false = 走らせなかった(走らせるデバイスが無かった。理由は failure)
    public var ran = true
    public let passed: Bool
    public var reportPath: String?
    /// 最初に落ちたステップの説明と理由(passed なら nil)
    public let failure: String?

    /// レポートのパスを落とした写し(dry-run が一時フォルダへ捨てたレポート = 処理の終わりに消えるパスを行に載せない)
    public func droppingReportPath(_ drop: Bool) -> DeviceTearDownOutcome {
        guard drop else { return self }
        var out = self
        out.reportPath = nil
        return out
    }
}

extension ScenarioHost {
    /// **デバイスの仕事が終わった時点で**、そのデバイスで tearDownDevice を申告したクラスを1本ずつ片付ける。
    /// 共有キューでは「このデバイスでのクラス最後のシナリオ」が取り出し時点で決まらない(残りを別デバイスが取りうる)
    /// ので、シナリオの子の中では走らせず、ここで専用の子を起こす。中断時・離脱したデバイスでは呼ばない(呼び手の責務)。
    /// 結果は results に載せない(シナリオではない)。レポート(.md)は子が書く
    public static func runDeviceTearDowns(project: TestProject, connection: DriverConnection,
                                          deviceSession: RunDeviceSession,
                                          settings: ScenarioExecutionSettings, reportDir: String,
                                          dryRun: Bool,
                                          appPath: String?, appName: String?, appBundleID: String?,
                                          registerChildProcess: (@Sendable (Process) -> @Sendable () -> Void)?)
        async -> [DeviceTearDownOutcome] {
        var outcomes: [DeviceTearDownOutcome] = []
        for className in deviceSession.takePendingTearDowns() {
            var reportPath: String?
            var failure: String?
            let passed = await run(project: project, scenarioID: "\(className).tearDownDevice", variant: nil,
                                   connection: connection, deviceSession: deviceSession,
                                   classHasBeforeAll: false,
                                   scenarioTimeoutOverride: nil,
                                   settings: settings, reportDir: reportDir, dryRun: dryRun,
                                   appPath: appPath, appName: appName, appBundleID: appBundleID,
                                   registerChildProcess: registerChildProcess,
                                   deviceTearDownOnly: true) { event in
                if event.kind == "scenarioFinished" { reportPath = event.reportPath }
                if failure == nil, event.kind == "step", event.status == "failed" {
                    failure = [event.description, event.detail].compactMap { $0 }.joined(separator: ": ")
                }
            }
            outcomes.append(DeviceTearDownOutcome(hook: "tearDownDevice", className: className, passed: passed,
                                                  reportPath: reportPath, failure: failure))
        }
        return outcomes
    }

    /// afterAll を走らせるデバイス(呼び手が選ぶ。run の経路は仕事を最後まで終えたデバイス、直指定の経路はその1台)
    public struct LifecycleTarget: Sendable {
        public let connection: DriverConnection
        public let appPath: String?
        public let appName: String?
        public let appBundleID: String?

        public init(connection: DriverConnection, appPath: String?, appName: String?, appBundleID: String?) {
            self.connection = connection
            self.appPath = appPath
            self.appName = appName
            self.appBundleID = appBundleID
        }
    }

    /// **run の全デバイスの仕事が終わった後に**、afterAll を申告したクラスを1本ずつ片付ける(run × クラスで最大1回)。
    /// 走らせるデバイスは `target(platforms)` が選ぶ(そのクラスのシナリオが走った OS のどれか)。選べなければ走らせず、
    /// 走らなかったことを結果に残す。中断時は呼ばない(呼び手の責務)。結果は results に載せない(シナリオではない)
    public static func runAfterAlls(project: TestProject, shared: RunSharedSession,
                                    target: (Set<String>) -> LifecycleTarget?,
                                    settings: ScenarioExecutionSettings, reportDir: String, dryRun: Bool,
                                    registerChildProcess: (@Sendable (Process) -> @Sendable () -> Void)?,
                                    /// 走らせる間だけデバイスを押さえる口(run の経路 = run-lease の取り直し。直指定の経路は
                                    /// デバイスを持ったままなので要らない)
                                    acquire: (DriverConnection) async -> Void = { _ in },
                                    release: (DriverConnection) async -> Void = { _ in })
        async -> [DeviceTearDownOutcome] {
        var outcomes: [DeviceTearDownOutcome] = []
        for (className, platforms) in shared.takePendingAfterAlls() {
            guard let chosen = target(platforms) else {
                outcomes.append(DeviceTearDownOutcome(
                    hook: "afterAll", className: className, ran: false, passed: false, reportPath: nil,
                    failure: "no device that ran its \(platforms.sorted().joined(separator: "/")) scenarios"
                        + " finished its work in this run"))
                continue
            }
            var reportPath: String?
            var failure: String?
            await acquire(chosen.connection)
            let passed = await run(project: project, scenarioID: "\(className).afterAll", variant: nil,
                                   connection: chosen.connection,
                                   deviceSession: RunDeviceSession(shared: shared),
                                   classHasBeforeAll: false,
                                   scenarioTimeoutOverride: nil,
                                   settings: settings, reportDir: reportDir, dryRun: dryRun,
                                   appPath: chosen.appPath, appName: chosen.appName, appBundleID: chosen.appBundleID,
                                   registerChildProcess: registerChildProcess,
                                   afterAllOnly: true) { event in
                if event.kind == "scenarioFinished" { reportPath = event.reportPath }
                if failure == nil, event.kind == "step", event.status == "failed" {
                    failure = [event.description, event.detail].compactMap { $0 }.joined(separator: ": ")
                }
            }
            await release(chosen.connection)
            outcomes.append(DeviceTearDownOutcome(hook: "afterAll", className: className, passed: passed,
                                                  reportPath: reportPath, failure: failure))
        }
        return outcomes
    }

    /// 呼び手の log 行(英語。CLI の文言は英語だけ)
    public static func describe(_ outcome: DeviceTearDownOutcome) -> String {
        if outcome.passed { return "\(outcome.hook) of \(outcome.className): passed" }
        if !outcome.ran { return "⚠️ \(outcome.hook) of \(outcome.className) was not run — \(outcome.failure ?? "")" }
        return "⚠️ \(outcome.hook) of \(outcome.className) failed"
            + (outcome.failure.map { " — \($0)" } ?? "")
            + (outcome.reportPath.map { " (report: \($0))" } ?? "")
    }
}
