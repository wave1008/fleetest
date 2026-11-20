// RunLockHost.swift
// run 全体のロック(RR-8.5)を run の親のプロセスで受け持つ入口。`RunSharedSession` が1つ持ち、受け渡しの行(`DeviceSessionHandoff.lockAccess`)の値を決める。
//
// 方針:
//  - サーバーは**プロジェクトのソースがロックのコマンドを使うときだけ**、最初のシナリオを起こす時に起こす(使わない run に待ち受けを増やさない)。
//    ソースの走査(`RunLockUsage`)が見落とした呼び方で呼ばれても、ソケットを渡されない子は**待たずに英語で失敗する**(黙って割れない・止まらない)
//  - 親とつながった子(マシンをまたぐ run の子)は、発行元から `--lock-socket` を受けたときだけ発行元のサーバーへつなぐ。受けていなければ
//    「呼んだら失敗」(自前のサーバーを起こすとマシンごとに別のロックになって誤った緑)

import Foundation

/// ロックのコマンドをプロジェクトのソースが使っているかの走査(ビルドせずに見る)
public enum RunLockUsage {
    public static let commandNames = ["withRunLock"]

    /// コメントと文字列リテラルの外に、ロックのコマンドの呼び出しがあるか(名前の前後が識別子の文字でないものだけ)
    public static func sourceUsesLocks(_ source: String) -> Bool {
        let code = RunWideHookPlan.strippingCommentsAndStrings(source)
        for name in commandNames {
            var searchFrom = code.startIndex
            while let range = code.range(of: name, range: searchFrom..<code.endIndex) {
                let before = range.lowerBound > code.startIndex ? code[code.index(before: range.lowerBound)] : nil
                let after = code[range.upperBound...].first
                func isIdentifier(_ c: Character?) -> Bool { c.map { $0.isLetter || $0.isNumber || $0 == "_" } ?? false }
                if !isIdentifier(before), !isIdentifier(after) { return true }
                searchFrom = range.upperBound
            }
        }
        return false
    }

    /// `_disabled/` はビルドされない(Package.swift の exclude)ので見ない
    public static func projectUsesLocks(_ project: TestProject) -> Bool {
        RunWideHookPlan.anyScenarioSource(in: project, where: sourceUsesLocks)
    }

    /// 同じプロジェクトの別の run がこのマシンで進行中のときの警告(英語。無ければ nil)。数え方は `RunWideHookPlan.overlappingRunsLine` と同じ
    public static func overlapLine(project: String, ownPid: Int32, records: [RunProgressRecord]) -> String? {
        let others = RunWideHookPlan.otherRunPids(project: project, ownPid: ownPid, records: records)
        guard !others.isEmpty else { return nil }
        return "⚠️ \(others.count) other run(s) of project \(project) are in progress on this machine"
            + " (pid \(others.map(String.init).joined(separator: ", "))):"
            + " run-wide locks only work inside one run, so they do not exclude the scenarios of those runs"
    }

    static func currentOverlapLine(project: String) -> String? {
        overlapLine(project: project, ownPid: ProcessInfo.processInfo.processIdentifier,
                    records: RunProgressLedger.readAll(directory: RunProgressLedger.directory(), startTime: ProcessLiveness.startTime))
    }

    /// 呼び出し1回の待ちの絶対の上限(秒): この run のこのプロジェクトの対象の中で**最も長い実効の `scenarioTimeout`**
    /// (`@Test(scenarioTimeout:)` を含む。プロファイルの既定だけではない)。対象が無ければ既定
    public static func waitCapSeconds(scenarioTimeouts: [Int?], settingsTimeout: Int?) -> Int {
        let resolved = scenarioTimeouts.map { ScenarioTimeoutResolution.seconds(scenario: $0, settings: settingsTimeout) }
        return resolved.max() ?? ScenarioTimeoutResolution.seconds(scenario: nil, settings: settingsTimeout)
    }
}

/// 親が適用した「ロックの外の run メモ操作」(runMemoWrite / runMemoClear のイベント)の数を、起動の印(`lockOwnerToken`)ごとに数える。
/// ロックのサーバーはクライアントが出した数に届くまで run メモの読み書きに答えない(RunLockMessage.memoRead の doc)
public final class RunLockAppliedOps: @unchecked Sendable {
    // 不変条件: counts は condition の内側
    private let condition = NSCondition()
    private var counts: [String: Int] = [:]
    private var abortReason: String?

    public init() {}

    /// 1件適用した(ストアへ入れた後に呼ぶ)
    public func note(token: String) {
        condition.lock()
        counts[token, default: 0] += 1
        condition.broadcast()
        condition.unlock()
    }

    public func forget(token: String) {
        condition.lock()
        counts.removeValue(forKey: token)
        condition.unlock()
    }

    public enum WaitResult: Equatable, Sendable {
        case reached
        /// 上限まで届かなかった(その時点の数)
        case timedOut(arrived: Int)
        /// `abort` で起こされた(理由)
        case aborted(String)
    }

    public func count(token: String) -> Int {
        condition.lock()
        defer { condition.unlock() }
        return counts[token] ?? 0
    }

    /// 待っている全部を起こして失敗にする(サーバーの stop・interrupt)。以後の待ちもすぐ失敗にする(`reopen` まで)
    public func abort(_ reason: String) {
        condition.lock()
        if abortReason == nil { abortReason = reason }
        condition.broadcast()
        condition.unlock()
    }

    /// 新しいサーバーが使い始めるときに、前のサーバーの `abort` を忘れる
    public func reopen() {
        condition.lock()
        abortReason = nil
        condition.unlock()
    }

    /// `atLeast` 件に届くまで待つ。上限まで届かなければ `timedOut`・`abort` で起こされたら `aborted`
    public func waitResult(token: String, atLeast: Int, timeout: Duration) -> WaitResult {
        let deadline = Date().addingTimeInterval(Double(DurationConversion.milliseconds(timeout)) / 1000)
        condition.lock()
        defer { condition.unlock() }
        while (counts[token] ?? 0) < atLeast {
            if let abortReason { return .aborted(abortReason) }
            if !condition.wait(until: deadline) {
                if let abortReason { return .aborted(abortReason) }
                return (counts[token] ?? 0) >= atLeast ? .reached : .timedOut(arrived: counts[token] ?? 0)
            }
        }
        return .reached
    }
}

public final class RunLockHost: @unchecked Sendable {
    public enum Mode: Sendable, Equatable {
        case immediate
        case refuse(String)
        /// プロジェクトのソースがロックを使うなら、最初の `access()` でサーバーを起こす
        case ownServer
        /// 発行元(マシンをまたぐ run の親)のサーバーへつなぐ(親とつながったローカルの子。`--lock-socket`)。
        /// run メモは発行元の正本を通り、ロックの外の書き込みの確定は `noteOutsideApplied` がそのサーバーへ知らせる
        case issuer(String)
    }

    /// 発行元から `--lock-socket` を受けた印(隠しフラグ)。手元の子は発行元の手元の待ち受けを、リモートの機械の run は中継役が ssh の転送で
    /// 張った向こうのパスを受ける。受けていない親とつながった子は「呼んだら失敗」
    private static let issuerSocket = LockedValue<String?>(nil)
    public static func markIssuerSocket(_ path: String) { issuerSocket.value = path }
    /// `configure` の `issuerSocket` の既定(プロセスで受けた `--lock-socket`)
    public static var markedIssuerSocket: String? { issuerSocket.value }

    /// MCP サーバーのプロセスが**プロジェクトごとに1つ**持つ(別々の `ft_run_scenario` が別のデバイスで同時に走りうるので、
    /// その場で渡さない。ロックの範囲は run × プロジェクトなので、別のプロジェクトのキーが同じ表に載らない)。
    /// 設定は同じプロジェクトの呼び出しごとに足し込む(`configure(merge: true)`)
    public static func mcpShared(project: String) -> RunLockHost {
        mcpHosts.withLock { hosts in
            if let host = hosts[project] { return host }
            let host = RunLockHost(mode: .ownServer)
            hosts[project] = host
            return host
        }
    }
    private static let mcpHosts = LockedValue<[String: RunLockHost]>([:])

    /// `--fleet` の各エントリが立てる印(隠しフラグ `--fleet-entry`)。エントリは別々の run なので、マシンをまたいで同じロックを共有できない
    /// 直し方まで言う(利用者向けの docs には書かない。踏んだ AI・利用者はこの文言で知る)
    public static let fleetEntryRefusal = "--fleet starts a separate run on each machine, so the machines do not share locks"
        + " — to exclude across machines, name the machines on the devices of one run profile instead"
    private static let fleetEntry = LockedValue(false)
    public static func markFleetEntry() { fleetEntry.value = true }
    /// この run が `--fleet` のエントリか(`RunWideHookPlan.hooksClassToRun` の2つ目の門が見る)
    public static var isFleetEntry: Bool { fleetEntry.value }

    /// 発行元から `--lock-socket` を受けていない親とつながった子(ソースがロックを使うと見えなかった・ssh の転送を張れなかった)
    public static let linkedChildRefusal = "the parent of this multi-machine run did not hand over a run lock socket"
        + " (no withRunLock call was found under the project's scenarios/ folder, or the ssh forward for this machine could not be set up)"
    public static let notConfiguredRefusal = "this way of running does not set up run-wide locks"
    /// 探した場所と直し方を言う: 共通のヘルパーを別のパッケージにまとめて、そこでだけ呼ぶと「呼んでいるのに使えない」になる
    public static let notDetectedRefusal = "no withRunLock call was found under the project's scenarios/ folder"
        + " (comments, strings and _disabled/ are skipped; a call that exists only in another target or package is not seen"
        + " — write at least one withRunLock call in a scenario file)"

    /// 親が適用したロックの外のメモ操作の数(`RunDeviceSession.apply` が数える)
    public let appliedOps = RunLockAppliedOps()

    // 不変条件: 下の状態はすべて lock の内側。他のオブジェクトの呼び出し(サーバーの interrupt / stop・log)は lock の外
    private let lock = NSLock()
    private var mode: Mode
    private var waitCapSeconds = ScenarioHost.defaultScenarioTimeout
    private var log: @Sendable (String) -> Void = { ConsoleOut.err($0) }
    private var overlapWarning: (@Sendable () -> String?)?
    private var server: RunLockServer?
    private var startFailure: String?
    private var interrupted = false
    private var configured = false
    // 発行元のサーバーへの1本の接続(子のプロセスで1つ)。forwardLock の内側
    private let forwardLock = NSLock()
    private let forwardQueue = DispatchQueue(label: "fleetest.run-lock.forward")
    private var forwarder: RunLockClient?
    private var pendingNotes: [RunLockMessage] = []
    private var retrying = false
    /// 起動の印 → その起動の run メモ(`RunSharedSession.lockHandoff` が登録し、シナリオの終わりに外す)
    private var memos: [String: RunLockMemoBackend] = [:]

    public init(mode: Mode) { self.mode = mode }

    deinit { server?.stop() }

    public func register(token: String, memo: RunLockMemoBackend) {
        lock.withLock { memos[token] = memo }
    }

    public func unregister(token: String) {
        lock.withLock { _ = memos.removeValue(forKey: token) }
        appliedOps.forget(token: token)
    }

    /// run の入口が1回呼ぶ。**親とつながった子は、発行元のソケット(`issuerSocket`)を受けていなければ「呼んだら失敗」**。
    /// `usesLocks` が false(走査が見なかった)なら `notDetectedRefusal`。
    /// `merge`: 設定済みなら上書きせず足し込む(使う宣言は OR・上限は大きいほう)= プロセスで1つのホストを複数の呼び出しが共有する形(MCP)
    public func configure(usesLocks: Bool, waitCapSeconds: Int, linkedToParent: Bool, merge: Bool = false,
                          issuerSocket: String? = RunLockHost.markedIssuerSocket,
                          overlapWarning: (@Sendable () -> String?)? = nil,
                          log: @escaping @Sendable (String) -> Void) {
        lock.withLock {
            let alreadyUses = merge && configured && mode == .ownServer
            if Self.fleetEntry.value {
                mode = .refuse(Self.fleetEntryRefusal)
            } else if linkedToParent {
                if let path = issuerSocket {
                    mode = usesLocks ? .issuer(path) : .refuse(Self.notDetectedRefusal)
                } else {
                    mode = .refuse(Self.linkedChildRefusal)
                }
            } else {
                mode = (usesLocks || alreadyUses) ? .ownServer : .refuse(Self.notDetectedRefusal)
            }
            self.waitCapSeconds = merge && configured ? max(self.waitCapSeconds, waitCapSeconds) : waitCapSeconds
            configured = true
            self.overlapWarning = overlapWarning
            self.log = log
        }
    }

    /// run の入口が呼ぶ組み合わせ: ソースの走査・待ちの上限(この run の対象の最長の実効 scenarioTimeout)・別の run との重なりの警告
    public func configure(project: TestProject, scenarioTimeouts: [Int?], settingsTimeout: Int?, merge: Bool = false,
                          log: @escaping @Sendable (String) -> Void) {
        let name = project.name
        configure(usesLocks: RunLockUsage.projectUsesLocks(project),
                  waitCapSeconds: RunLockUsage.waitCapSeconds(scenarioTimeouts: scenarioTimeouts, settingsTimeout: settingsTimeout),
                  linkedToParent: ParentLink.isLinked, merge: merge,
                  overlapWarning: { RunLockUsage.currentOverlapLine(project: name) },
                  log: log)
    }

    /// テスト用: サーバーを起こしたか(dry-run / debug の上書きが、起こしてから上書きする形に戻らないことを確かめる)
    var serverStartedForTesting: Bool { lock.withLock { server != nil } }

    public var currentWaitCapSeconds: Int { lock.withLock { waitCapSeconds } }

    /// 次のシナリオの子へ渡す値(dry-run・debug の上書きは呼び手)
    public func access() -> RunLockAccess {
        struct Started {
            var access: RunLockAccess
            var warn: (@Sendable () -> String?)?
            var log: @Sendable (String) -> Void
            var interruptNow: RunLockServer?
        }
        let started: Started = lock.withLock {
            switch mode {
            case .immediate: return Started(access: .immediate, log: log)
            case .refuse(let reason): return Started(access: .refuse(reason), log: log)
            case .issuer(let path): return Started(access: .socket(path), log: log)
            case .ownServer:
                if let server { return Started(access: .socket(server.socketPath), log: log) }
                if let startFailure { return Started(access: .refuse(startFailure), log: log) }
                do {
                    let created = try RunLockServer(
                        memoFor: { [weak self] token in self?.lock.withLock { self?.memos[token] } },
                        applied: appliedOps,
                        waitCapSeconds: { [weak self] in self?.currentWaitCapSeconds ?? ScenarioHost.defaultScenarioTimeout },
                        log: { [weak self] line in self?.emit(line) })
                    server = created
                    let warn = overlapWarning
                    overlapWarning = nil
                    return Started(access: .socket(created.socketPath), warn: warn, log: log,
                                   interruptNow: interrupted ? created : nil)
                } catch {
                    let reason = "cannot start the run lock server: \(error.localizedDescription)"
                    startFailure = reason
                    return Started(access: .refuse(reason), log: log)
                }
            }
        }
        started.interruptNow?.interrupt()
        // 起こした時に1回だけ(別の run が重なっていれば警告)
        if let line = started.warn?() { started.log(line) }
        return started.access
    }

    /// 起動の印 `token` のシナリオの「ロックの外の run メモ操作」1件が確定した(書き込みごとの確定の口が呼ぶ)。
    /// 自前のサーバーなら直接数える。**発行元のサーバーへつなぐ子は、そのサーバーへ送る**(数えるのはサーバーが居る発行元のプロセス)。
    /// 送れなければ控えに積み、`forwardRetryInterval` ごとに再接続・再送する。待ちの上限(`currentWaitCapSeconds`)を過ぎたら諦めて
    /// 1回だけログに出す。サーバー側の待ちも同じ上限で理由つきの失敗になるので、どちらもハングしない
    public func noteOutsideApplied(token: String) {
        let issuerPath = lock.withLock { () -> String? in
            if case .issuer(let path) = mode { return path }
            return nil
        }
        guard let issuerPath else {
            appliedOps.note(token: token)
            return
        }
        forward(.outsideApplied(token: token), path: issuerPath)
    }

    /// 起動の印 `token` のシナリオのプロセスを、親(この host を持つプロセス)が見届けた(reap した)。
    /// サーバーはその印の持ち分を外す(臨界区間の途中で死んだ・kill されたシナリオの持ち分を、接続の切れや pid の終わりを待たずに外す。
    /// リモートのマシンでは「持ち主不明」を作らない)。サーバーへ届かなければ `noteOutsideApplied` と同じ再送
    public func noteScenarioEnded(token: String) {
        let target = lock.withLock { () -> (path: String?, server: RunLockServer?) in
            if case .issuer(let path) = mode { return (path, nil) }
            return (nil, server)
        }
        if let path = target.path {
            forward(.scenarioEnded(token: token), path: path)
        } else {
            target.server?.scenarioEnded(token: token)
        }
    }

    /// 呼び元(親の stdin を読むスレッド・子の出力を読むスレッド)で接続・書き込みをしない: **ホストが持つ直列キュー**で行う
    /// (詰まった転送が、開始の行・配りの返事の処理を止めない)
    private func forward(_ message: RunLockMessage, path issuerPath: String) {
        forwardLock.lock()
        pendingNotes.append(message)
        forwardLock.unlock()
        forwardQueue.async { [self] in
            forwardLock.lock()
            let startRetry = !flushPendingNotesLocked(path: issuerPath) && !retrying
            if startRetry { retrying = true }
            forwardLock.unlock()
            if startRetry { retryForwarding(path: issuerPath) }
        }
    }

    /// 送れる分を送る。全部送れたら true。forwardLock を持って呼ぶ
    private func flushPendingNotesLocked(path: String) -> Bool {
        while let message = pendingNotes.first {
            if forwarder == nil || forwarder?.isBroken == true {
                forwarder = try? RunLockClient.connect(path: path, scenario: "run-lock-forwarder", machine: "child", device: "-")
            }
            guard forwarder?.sendNote(message) == true else { return false }
            pendingNotes.removeFirst()
        }
        return true
    }

    /// 再送の間隔。根拠: 接続の一時的な失敗(listen の待ち行列が埋まった・サーバーの起動直後)は数十ミリ秒で解ける。
    /// 長くしても待っているシナリオの待ちが延びるだけで得が無い
    static let forwardRetryInterval: Duration = .milliseconds(100)

    private func retryForwarding(path: String) {
        let cap = Double(max(1, currentWaitCapSeconds))
        let thread = Thread { [self] in
            let clock = SuspendingClock()
            let deadline = clock.now.advanced(by: .seconds(cap))
            while true {
                Thread.sleep(forTimeInterval: Double(DurationConversion.milliseconds(Self.forwardRetryInterval)) / 1000)
                forwardLock.lock()
                let done = flushPendingNotesLocked(path: path)
                let expired = !done && clock.now >= deadline
                if done || expired {
                    if expired {
                        pendingNotes.removeAll()
                    }
                    retrying = false
                }
                forwardLock.unlock()
                if done { return }
                if expired {
                    let sink = lock.withLock { log }
                    sink("⚠️ cannot tell the run lock server that run memo writes were applied (gave up after \(Int(cap))s);"
                        + " locks waiting on them fail at their wait limit")
                    return
                }
            }
        }
        thread.name = "fleetest-run-lock-forward-retry"
        thread.start()
    }

    /// 中断(待っている要求を失敗にし、以後の新しい要求もすぐ失敗にする)
    public func interrupt() {
        let current = lock.withLock { () -> RunLockServer? in
            interrupted = true
            return server
        }
        current?.interrupt()
    }

    /// run の終わりに呼ぶ(ソケットのファイルを消す)。サーバーの読むスレッドの上から呼ばれても待たない(`RunLockServer.stop`)
    public func stop() {
        let current = lock.withLock { () -> RunLockServer? in
            let was = server
            server = nil
            return was
        }
        current?.stop()
    }

    private func emit(_ line: String) {
        let sink = lock.withLock { log }
        sink(line)
    }
}

/// run メモの正本(`RunMemoHub`)をロックのサーバーの backend にする(マシンをまたぐ run の発行元)。
/// 読み = 確定済みの履歴を畳んだ値・書き = 確定した書き込みとして通し番号を振り、起動を知らせた全部の子へ配り返す
/// (`beforeRun` の書き込みと同じ経路 = `seedConfirmed`。hub の順序づけをそのまま使う)
public struct RunMemoHubLockBackend: RunLockMemoBackend {
    public let hub: RunMemoHub

    public init(hub: RunMemoHub) { self.hub = hub }

    public func snapshot() -> [String: [String]] { hub.finalValues() }

    public func apply(_ op: RunMemoOp) { hub.commit(op) }

    public func applyCommitted(_ op: RunMemoOp) -> Int? { hub.commit(op) }
}

/// 発行元(マシンをまたぐ run の親)が持つロックのサーバー。プロジェクトのソースがロックを使うときだけ起こす。
/// ロックの範囲は run × プロジェクト(複数対象の run ではプロジェクトごとに1つ)
public final class RunLockIssuer: @unchecked Sendable {
    /// 手元の待ち受け(この機械で起こした子・中継役がつなぐ)
    public let socketPath: String
    private let server: RunLockServer

    /// リモートの機械へのディスパッチ1回ぶんの待ち受けを開く(中継役の子を起こす直前)。ssh の `-R` の転送先になり、
    /// 同時に**そのディスパッチの識別子**(`sshEnded` / `remoteRunEnded` に使う)。nil = 開けなかった(子はロックを使えない)
    public func openRemoteListener(machine: String) -> String? { try? server.openRemoteListener(machine: machine) }

    /// 子を起こした / 子が終わった(`unknownKeys` の `othersActive` の材料)。まだ起こしていない仕事が残るかの問い合わせ
    public func childLaunched() { server.childLaunched() }
    public func childExited() { server.childExited() }
    public func setMoreWorkProbe(_ probe: @escaping @Sendable () -> Bool) { server.setMoreWorkProbe(probe) }

    /// 中継役の子が終わった後に閉じる(受けた接続と持ち主不明は残る)
    public func closeRemoteListener(path: String) { server.closeRemoteListener(path: path) }

    private init(server: RunLockServer) {
        self.server = server
        self.socketPath = server.socketPath
    }

    /// ソースが使っていなければ nil(子は `--lock-socket` を受けず「呼んだら失敗」)。起こせなければ1行言って nil
    public static func startIfUsed(project: TestProject, waitCapSeconds: Int, hub: RunMemoHub,
                                   log: @escaping @Sendable (String) -> Void) -> RunLockIssuer? {
        guard RunLockUsage.projectUsesLocks(project) else { return nil }
        let backend = RunMemoHubLockBackend(hub: hub)
        do {
            let server = try RunLockServer(memoFor: { _ in backend }, applied: RunLockAppliedOps(),
                                           waitCapSeconds: { waitCapSeconds }, log: log)
            if let line = RunLockUsage.currentOverlapLine(project: project.name) { log(line) }
            return RunLockIssuer(server: server)
        } catch {
            log("⚠️ cannot start the run lock server (\(error.localizedDescription)); lock calls in this run will fail")
            return nil
        }
    }

    public func interrupt() { server.interrupt() }
    public func stop() { server.stop() }
}
