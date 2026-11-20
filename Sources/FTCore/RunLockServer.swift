// RunLockServer.swift
// run 全体のロック(RR-8.5)のサーバー。run の親(1台のマシンの run ならその run のプロセス)が unix ソケットで待ち受け、
// 判定は `RunLockTable`(純粋)に任せて、返事を書くだけ。接続ごとに読むスレッドを1つ持つ。
//
// - 持ち主の接続が「外す」なしで閉じたら、**相手のプロセスの終わりを kqueue の NOTE_EXIT で待ってから外す**
//   (閉じた接続の相手がまだ臨界区間を走っているかもしれない。既に居なければその場で外す)
// - run メモはロックの中の読み・書きだけここを通る。書きは `RunLockMemoBackend` へ入れてから確定を返す
//   (1台の run の実体は `RunMemoStore` = 次に起こすシナリオの写しにすぐ入る)
// - `stop()` した後は何にも答えず、クライアントは EOF になる。ソケットのファイルは stop / プロセスの終了で消す

import Foundation

public protocol RunLockMemoBackend: Sendable {
    func snapshot() -> [String: [String]]
    func apply(_ op: RunMemoOp)
}

extension RunMemoStore: RunLockMemoBackend {
    public func apply(_ op: RunMemoOp) {
        switch op {
        case .write(let key, let value): write(key: key, value: value)
        case .clear: clear()
        }
    }
}

// 不変条件: `state` は lock の内側でだけ読み書きする。返事の書き込みは lock の外(接続ごとの writeLock が直列化)
public final class RunLockServer: @unchecked Sendable {
    /// 接続の相手のプロセスの pid(分からなければ 0)を読む口。本番は `getsockopt(LOCAL_PEERPID)`。テストは 0 を返す偽を渡す
    public typealias PeerPidReader = @Sendable (Int32) -> pid_t

    /// プロセス `pid` の終了を待って `onExit` を1回呼ぶ(`cancelled` が true になったら呼ばずにやめる)。
    /// **待てなくなったとき(kqueue の失敗)は `onExit` ではなく `onError`(英語の理由)を呼ぶ** —— 終わりを確かめられないまま
    /// 外すと二重に持つ(誤った緑)ので、呼び手はロックを持たせたままにする。本番は kqueue。テストは偽(待たない・手で発火)を渡す
    public typealias PidExitWaiter = @Sendable (_ pid: pid_t, _ cancelled: @escaping @Sendable () -> Bool,
                                                _ onExit: @escaping @Sendable () -> Void,
                                                _ onError: @escaping @Sendable (String) -> Void) -> Void

    /// 「待っているキーと持ち主」を run ログへ出す間隔。根拠: 競合の多くは数秒で解けるので、毎秒出すと run ログが埋まる。
    /// 待ちの上限は最長の `scenarioTimeout`(既定 600 秒)なので、1分以内に原因(持ち主)が1行は見える長さにする
    public static let defaultReportInterval: Duration = .seconds(30)

    public let socketPath: String

    private final class Conn: @unchecked Sendable {
        let id: Int
        let descriptor: Int32
        let pid: pid_t
        // 不変条件: scenario / machine / device / token は server.lock の内側。
        // `closed` は stateLock の内側で、**fd を閉じる(= closed を立てる)のは writeLock と stateLock の両方を持つとき**だけ。
        // 書き込み(writeLock の内側)は closed を見てから書くので、閉じた後の番号(再利用されうる)へは書かない。
        // `wake()` は stateLock だけを取る = 相手が読まずに書き込みが詰まっていても(writeLock を握ったまま write で止まる)
        // shutdown で書き込みを起こせる(stop が詰まらない)
        var token = ""
        var scenario = "?"
        var machine = "?"
        var device = "?"
        private let writeLock = NSLock()
        private let stateLock = NSLock()
        private var closed = false

        init(id: Int, descriptor: Int32, pid: pid_t) {
            self.id = id
            self.descriptor = descriptor
            self.pid = pid
        }

        func send(_ message: RunLockMessage) {
            writeLock.withLock {
                guard !stateLock.withLock({ closed }) else { return }
                _ = RunLockLineChannel.writeAll(descriptor, message.encodedLine())
            }
        }

        /// 他のスレッドから読み・書きを起こす(fd は閉じない = 閉じるのは読むスレッドだけ)。writeLock を取らない
        func wake() {
            stateLock.withLock { if !closed { shutdown(descriptor, SHUT_RDWR) } }
        }

        /// 読むスレッドが接続の終わりに呼ぶ。先に shutdown して詰まった書き込みを起こしてから、writeLock を取って閉じる
        func closeDescriptor() {
            wake()
            writeLock.withLock {
                stateLock.withLock {
                    guard !closed else { return }
                    closed = true
                    close(descriptor)
                }
            }
        }
    }

    private struct Waiting {
        let keys: [String]
        let mode: RunLockTable.Mode
        let since: SuspendingClock.Instant
    }

    private struct State {
        var table = RunLockTable()
        var conns: [Int: Conn] = [:]
        var nextConnection = 1
        var waiting: [RunLockTable.Owner: Waiting] = [:]
        var stopped = false
    }

    private let lock = NSLock()
    private var state = State()
    private let memoFor: @Sendable (String) -> RunLockMemoBackend?
    private let applied: RunLockAppliedOps
    private let waitCapSeconds: @Sendable () -> Int
    private let peerPidReader: PeerPidReader
    private let maxReplyBytes: Int
    private let log: @Sendable (String) -> Void
    private let pidExitWaiter: PidExitWaiter
    private let reportInterval: Duration
    private var acceptLoop: AcceptLoop?
    private let readers = DispatchGroup()
    private let reporterWake = DispatchSemaphore(value: 0)
    private let stopOnce = LockedValue(false)

    /// 接続の listen の待ち行列の長さ。根拠: 1台のマシンのシナリオのプロセスは同時にデバイス数(多くて十数台)だけ、
    /// それぞれ1本ずつつなぐ。既定の 16 は同時に起動した全員の接続で溢れうる(溢れると ECONNREFUSED)ので、余裕を見て 128
    public static let listenBacklog: Int32 = 128

    /// - memoFor: 受け渡しの行の `lockOwnerToken` → その起動の run メモ(無ければ nil = 読み書きを断る)
    /// - applied: 親が適用した「ロックの外の run メモ操作」の数(`memoRead` / `memoWrite` はクライアントが出した数に届くまで待つ)
    /// - waitCapSeconds: その待ちの上限(ロックの待ちの絶対上限と同じ値)
    /// - log: run ログへ出す英語の1行(待っているキーと持ち主・取り消しの持ち主の名指し)。**サーバーの lock の外で呼ぶ**。呼ばれるスレッドは決まらない
    public init(memoFor: @escaping @Sendable (String) -> RunLockMemoBackend?,
                applied: RunLockAppliedOps = RunLockAppliedOps(),
                waitCapSeconds: @escaping @Sendable () -> Int = { ScenarioHost.defaultScenarioTimeout },
                log: @escaping @Sendable (String) -> Void,
                directory: String = TemporaryDirectory.url.path,
                reportInterval: Duration = RunLockServer.defaultReportInterval,
                pidExitWaiter: @escaping PidExitWaiter = RunLockServer.kqueueExitWaiter,
                peerPidReader: @escaping PeerPidReader = RunLockServer.peerPid,
                maxReplyBytes: Int = RunLockLimits.maxLineBytes) throws {
        self.maxReplyBytes = maxReplyBytes
        applied.reopen()
        self.memoFor = memoFor
        self.applied = applied
        self.waitCapSeconds = waitCapSeconds
        self.peerPidReader = peerPidReader
        self.log = log
        self.reportInterval = reportInterval
        self.pidExitWaiter = pidExitWaiter
        // sun_path は 104 バイト: 一時フォルダ(約 50 文字)+ 短い一意の名前に収める
        let name = "ftlock-" + String(UUID().uuidString.prefix(8)).lowercased() + ".sock"
        let path = (directory as NSString).appendingPathComponent(name)
        self.socketPath = path
        let listener = try UnixSocket.listen(path: path, backlog: Self.listenBacklog)
        Self.registerForExitCleanup(path)
        do {
            acceptLoop = try AcceptLoop(listener: listener, name: "fleetest-run-lock-accept") { [weak self] descriptor in
                guard let self else {
                    close(descriptor)
                    return false
                }
                self.accept(descriptor)
                return true
            }
        } catch {
            close(listener)
            Self.removeSocketFile(path)
            throw error
        }
        startReporter()
    }

    deinit {
        acceptLoop?.requestStop()
        reporterWake.signal()
        Self.removeSocketFile(socketPath)
    }

    /// 全ての接続が同じ run メモを使う形(テスト・1つの run だけを受け持つ呼び手)
    public convenience init(memo: RunLockMemoBackend, log: @escaping @Sendable (String) -> Void,
                            directory: String = TemporaryDirectory.url.path,
                            reportInterval: Duration = RunLockServer.defaultReportInterval,
                            pidExitWaiter: @escaping PidExitWaiter = RunLockServer.kqueueExitWaiter) throws {
        try self.init(memoFor: { _ in memo }, log: log, directory: directory, reportInterval: reportInterval,
                      pidExitWaiter: pidExitWaiter)
    }

    // MARK: 外から

    /// 中断: 待っている要求を全部失敗にし、以後の新しい要求もすぐ失敗にする(渡し済みはそのまま)
    public func interrupt() {
        perform { state, _ in state.table.interrupt() }
        applied.abort(RunLockTable.interruptedReason)  // run メモの適用待ちも起こして失敗にする
    }

    /// 全部閉じる(何度呼んでもよい)。戻った時点でソケットのファイルは消えていて、クライアントは EOF になる。
    /// **このサーバーの読むスレッド・報告のスレッドの上から呼ばれたら、止める依頼だけして待たない**(自分を待って詰まる。
    /// 最後の参照がそこで外れうる)
    public func stop() {
        guard stopOnce.withLock({ let was = $0; $0 = true; return !was }) else { return }
        let conns = lock.withLock { () -> [Conn] in
            state.stopped = true
            return Array(state.conns.values)
        }
        reporterWake.signal()
        applied.abort("the run lock server stopped")  // 適用待ちで止まっている読むスレッドを起こす(`readers.wait()` が上限まで待たない)
        for conn in conns { conn.wake() }
        if isOnOwnThread {
            acquireLoopRequestStop()
            Self.removeSocketFile(socketPath)
            return
        }
        acceptLoop?.stop()
        readers.wait()
        Self.removeSocketFile(socketPath)
    }

    private func acquireLoopRequestStop() { acceptLoop?.requestStop() }

    private static let ownThreadKey = "fleetest.runLockServer"
    private var isOnOwnThread: Bool {
        (Thread.current.threadDictionary[Self.ownThreadKey] as? ObjectIdentifier) == ObjectIdentifier(self)
    }
    private func markOwnThread() { Thread.current.threadDictionary[Self.ownThreadKey] = ObjectIdentifier(self) }

    public var isStopped: Bool { lock.withLock { state.stopped } }

    // MARK: 接続

    private func accept(_ descriptor: Int32) {
        let conn: Conn? = lock.withLock {
            guard !state.stopped else { return nil }
            let conn = Conn(id: state.nextConnection, descriptor: descriptor, pid: peerPidReader(descriptor))
            state.nextConnection += 1
            state.conns[conn.id] = conn
            return conn
        }
        guard let conn else {
            close(descriptor)
            return
        }
        readers.enter()
        let thread = Thread { [self] in
            defer { readers.leave() }
            markOwnThread()
            serve(conn)
        }
        thread.name = "fleetest-run-lock-conn"
        thread.start()
    }

    private func serve(_ conn: Conn) {
        let channel = RunLockLineChannel(descriptor: conn.descriptor)
        loop: while true {
            switch channel.readLine(timeoutMs: -1) {
            case .timeout: continue
            case .closed: break loop
            case .line(let data):
                // 壊れたメッセージを出す相手は切る(以後の順序を信用できない)
                guard let message = RunLockMessage.decode(line: data) else { break loop }
                if isStopped { break loop }
                handle(message, from: conn)
            }
        }
        connectionDidClose(conn)
        conn.closeDescriptor()
    }

    private func handle(_ message: RunLockMessage, from conn: Conn) {
        switch message {
        case .hello(let scenario, let machine, let device, let token):
            lock.withLock {
                conn.scenario = scenario
                conn.machine = machine
                conn.device = device
                conn.token = token
            }
        case .acquire(let id, let rawKeys, let mode):
            let owner = RunLockTable.Owner(connection: conn.id, requestID: id)
            switch RunLockKeys.normalize(rawKeys) {
            case .failure(let error):
                conn.send(.failed(id: id, reason: error.message))
            case .success(let keys):
                perform { state, _ in
                    let effects = state.table.acquire(connection: conn.id, requestID: id, keys: keys, mode: mode)
                    if !state.table.isGranted(owner), state.table.waitingKey(of: owner) != nil {
                        state.waiting[owner] = Waiting(keys: keys, mode: mode, since: SuspendingClock().now)
                        // 順序の根拠: 渡しを書くのも同じ lock の内側なので、`queued` は必ず `granted` より前に届く
                        conn.send(.queued(id: id))
                    }
                    return effects
                }
            }
        case .cancel(let id):
            let owner = RunLockTable.Owner(connection: conn.id, requestID: id)
            perform { state, lines in
                if let key = state.table.waitingKey(of: owner), let waited = state.waiting[owner] {
                    let seconds = Self.seconds(SuspendingClock().now - waited.since)
                    lines.append("run lock: \(describe(conn)) gave up waiting for \"\(key)\" after \(seconds)s;"
                        + " held by \(holdersText(of: key, in: state))")
                }
                state.waiting.removeValue(forKey: owner)
                return state.table.cancel(connection: conn.id, requestID: id)
            }
        case .release(let id):
            perform { state, _ in state.table.release(connection: conn.id, requestID: id) }
        case .memoRead(let id, let outsideOps):
            if let reason = memoPreconditionFailure(conn, id: id, outsideOps: outsideOps) {
                conn.send(.failed(id: id, reason: reason))
                return
            }
            let reply = RunLockMessage.memo(values: memoBackend(conn)?.snapshot() ?? [:])
            // 返事が大きすぎる行は読み手が壊れた接続として切るので、送らずに理由つきの失敗にする
            if reply.encodedLine().count > maxReplyBytes {
                conn.send(.failed(id: id, reason: "the run memo is too large to read through the run lock connection"
                    + " (over \(maxReplyBytes) bytes)"))
            } else {
                conn.send(reply)
            }
        case .memoWrite(let id, let op, let outsideOps):
            if let reason = memoPreconditionFailure(conn, id: id, outsideOps: outsideOps) {
                conn.send(.failed(id: id, reason: reason))
                return
            }
            memoBackend(conn)?.apply(op.runMemoOp)
            conn.send(.committed(id: id))
        case .outsideApplied(let token):
            applied.note(token: token)
        case .queued, .pending, .granted, .failed, .memo, .committed:
            break
        }
    }

    private func memoBackend(_ conn: Conn) -> RunLockMemoBackend? {
        memoFor(lock.withLock { conn.token })
    }

    /// run メモの読み書きの前に: 持ち主が分かること・親がこのシナリオの「ロックの外の操作」を出された数だけ適用し終えていること。
    /// 足りなければクライアントへ `pending` を返してから待つ(クライアントは待ちの窓を開く)。待ちは絶対上限まで・
    /// stop / interrupt で起こされる。断る理由(英語)を返す
    private func memoPreconditionFailure(_ conn: Conn, id: Int, outsideOps: Int) -> String? {
        let token = lock.withLock { conn.token }
        guard memoFor(token) != nil else { return "the run memo of this scenario is unknown to the run lock server" }
        if applied.count(token: token) < outsideOps { conn.send(.pending(id: id)) }
        let cap = max(1, waitCapSeconds())
        switch applied.waitResult(token: token, atLeast: outsideOps, timeout: .seconds(cap)) {
        case .reached: return nil
        case .timedOut(let arrived):
            return "timed out after \(cap)s waiting for \(outsideOps) run memo write(s) made outside the lock to reach the issuer"
                + " (\(arrived) of \(outsideOps) arrived)"
        case .aborted(let reason):
            return "stopped waiting for \(outsideOps) run memo write(s) made outside the lock to reach the issuer (\(reason))"
        }
    }

    private func connectionDidClose(_ conn: Conn) {
        var held: [RunLockTable.Owner] = []
        var stopped = false
        perform { state, _ in
            stopped = state.stopped
            state.conns.removeValue(forKey: conn.id)
            let closed = state.table.connectionClosed(conn.id)
            held = closed.held
            for owner in state.waiting.keys where owner.connection == conn.id && !closed.held.contains(owner) {
                state.waiting.removeValue(forKey: owner)
            }
            return closed.effects
        }
        guard !held.isEmpty, !stopped else { return }
        let heldOwners = held
        let releaseHeld: @Sendable () -> Void = { [self] in
            perform { state, _ in
                var effects = RunLockTable.Effects.none
                for owner in heldOwners {
                    let released = state.table.release(connection: owner.connection, requestID: owner.requestID)
                    effects.grants += released.grants
                    effects.failures += released.failures
                }
                return effects
            }
        }
        // 相手のプロセスが分からなければ終わりを確かめられない。**外さない**: 臨界区間がまだ走っているかもしれず、
        // 外すと二重に持つ(誤った緑になる)。待っている側は上限で失敗する
        if conn.pid <= 0 {
            let who = lock.withLock { describe(conn) }
            log("run lock: the process of \(who) could not be identified, so its locks stay held"
                + " until the run ends (waiters fail at their wait limit)")
        } else {
            let who = lock.withLock { describe(conn) }
            let logLine = log
            pidExitWaiter(conn.pid, { [self] in isStopped }, releaseHeld) { reason in
                // 終わりを確かめられない: 外さない(pid が分からないときと同じ規則)
                logLine("run lock: cannot wait for the process of \(who) to exit (\(reason)), so its locks stay held"
                    + " until the run ends (waiters fail at their wait limit)")
            }
        }
    }

    /// 表を操作して、返事を書く。**書く・ログを出すのは lock の外**(ただし `queued` はクライアントへの順序のため body が lock の内側で書く)
    private func perform(_ body: (inout State, inout [String]) -> RunLockTable.Effects) {
        var sends: [(Conn, RunLockMessage)] = []
        var lines: [String] = []
        lock.withLock {
            let effects = body(&state, &lines)
            for owner in effects.grants {
                state.waiting.removeValue(forKey: owner)
                if let conn = state.conns[owner.connection] { sends.append((conn, .granted(id: owner.requestID))) }
            }
            for failure in effects.failures {
                state.waiting.removeValue(forKey: failure.owner)
                if let conn = state.conns[failure.owner.connection] {
                    sends.append((conn, .failed(id: failure.owner.requestID, reason: failure.reason)))
                }
            }
        }
        for (conn, message) in sends { conn.send(message) }
        for line in lines { log(line) }
    }

    // MARK: 待ちの報告

    private func startReporter() {
        let thread = Thread { [weak self] in
            self?.markOwnThread()
            while let self {
                // 起こされた(stop)か、間隔が尽きるまで待つ
                let woken = reporterWake.wait(timeout: .now() + .milliseconds(DurationConversion.milliseconds(reportInterval)))
                if woken == .success || isStopped { return }
                reportWaiters()
            }
        }
        thread.name = "fleetest-run-lock-report"
        thread.start()
    }

    func reportWaiters() {
        let lines: [String] = lock.withLock {
            let now = SuspendingClock().now
            return state.waiting
                .sorted { ($0.key.connection, $0.key.requestID) < ($1.key.connection, $1.key.requestID) }
                .compactMap { owner, waiting in
                    guard let conn = state.conns[owner.connection], let key = state.table.waitingKey(of: owner) else { return nil }
                    return "run lock: \(describe(conn)) has waited \(Self.seconds(now - waiting.since))s for \(waiting.mode.rawValue)"
                        + " lock \"\(key)\" (held by \(holdersText(of: key, in: state)))"
                }
        }
        for line in lines { log(line) }
    }

    // MARK: 文言

    private func describe(_ conn: Conn) -> String { "\(conn.scenario) [\(conn.machine) / \(conn.device)]" }

    /// 呼び手が `lock` を持っている前提
    private func holdersText(of key: String, in state: State) -> String {
        let names = state.table.holders(of: key).compactMap { state.conns[$0.connection].map(describe) }
        let unique = names.reduce(into: [String]()) { if !$0.contains($1) { $0.append($1) } }
        return unique.isEmpty ? "waiters queued ahead" : unique.joined(separator: ", ")
    }

    private static func seconds(_ duration: Duration) -> String {
        String(format: "%.1f", Double(DurationConversion.milliseconds(duration)) / 1000)
    }

    // MARK: 相手のプロセス

    /// `getsockopt(SOL_LOCAL, LOCAL_PEERPID)`。分からなければ 0
    public static func peerPid(_ descriptor: Int32) -> pid_t {
        var pid: pid_t = 0
        var length = socklen_t(MemoryLayout<pid_t>.size)
        // <sys/un.h>: SOL_LOCAL = 0・LOCAL_PEERPID = 0x002
        guard getsockopt(descriptor, 0, 0x002, &pid, &length) == 0 else { return 0 }
        return pid
    }

    /// 待ちのスレッドが `cancelled`(= サーバーの stop)を見に起きる間隔(秒)。根拠: stop した後に待ちのスレッドが残る最長の時間。
    /// 待ちのスレッドは1接続につき1本・1秒に1回の kevent の起床だけなので、短くしても得が無く、長くすると停止後に残る
    static let cancelPollSeconds = 1

    /// kqueue の `NOTE_EXIT`。既に居なければ(登録が ESRCH)その場で `onExit`。**kqueue の失敗は `onExit` にしない**(`onError`)
    public static let kqueueExitWaiter: PidExitWaiter = { pid, cancelled, onExit, onError in
        let queue = kqueue()
        guard queue >= 0 else {
            onError("kqueue() failed: \(String(cString: strerror(errno)))")
            return
        }
        var change = kevent(ident: UInt(pid), filter: Int16(EVFILT_PROC), flags: UInt16(EV_ADD | EV_ONESHOT),
                            fflags: UInt32(NOTE_EXIT), data: 0, udata: nil)
        var event = kevent()
        // 待たずに登録だけ(timeout 0)。nil だと登録の呼び出し自体が終了まで戻らない
        var immediately = timespec(tv_sec: 0, tv_nsec: 0)
        let registered = kevent(queue, &change, 1, &event, 1, &immediately)
        if registered < 0 {
            let code = errno
            close(queue)
            if code == ESRCH { onExit() } else { onError("kevent registration failed: \(String(cString: strerror(code)))") }
            return
        }
        if registered > 0 {
            close(queue)
            // 登録と同時に終わっていたとき(ESRCH)は EV_ERROR 付きで返る。それ以外の EV_ERROR は登録の失敗
            if (event.flags & UInt16(EV_ERROR)) != 0, event.data != Int(ESRCH) {
                onError("kevent registration failed: \(String(cString: strerror(Int32(event.data))))")
            } else {
                onExit()
            }
            return
        }
        let thread = Thread {
            defer { close(queue) }
            exitWaitLoop(queue: queue, cancelled: cancelled, onExit: onExit, onError: onError)
        }
        thread.name = "fleetest-run-lock-pid-exit"
        thread.start()
    }

    /// 登録済みの kqueue で終わりを待つ。テストが不正な fd を渡して `onError` の経路を確かめる
    static func exitWaitLoop(queue: Int32, cancelled: @Sendable () -> Bool, onExit: @Sendable () -> Void,
                             onError: @Sendable (String) -> Void) {
        while !cancelled() {
            var timeout = timespec(tv_sec: cancelPollSeconds, tv_nsec: 0)
            var out = kevent()
            let count = kevent(queue, nil, 0, &out, 1, &timeout)
            if count > 0 {
                onExit()
                return
            }
            if count < 0, errno != EINTR {
                onError("kevent failed while waiting: \(String(cString: strerror(errno)))")
                return
            }
        }
    }

    // MARK: ソケットのファイルの後始末

    private static let livePaths = LockedValue(Set<String>())
    private static let exitHookInstalled = LockedValue(false)

    /// プロセスが `exit` で終わる経路(2回目の中断など)でもファイルを残さない
    private static func registerForExitCleanup(_ path: String) {
        livePaths.withLock { _ = $0.insert(path) }
        let install = exitHookInstalled.withLock { let was = $0; $0 = true; return !was }
        if install {
            atexit { RunLockServer.removeAllSocketFiles() }
        }
    }

    /// 生きているサーバーのソケットのファイルを全部消す(`atexit` から。テストからも呼べる)
    static func removeAllSocketFiles() {
        for path in livePaths.value { unlink(path) }
    }

    private static func removeSocketFile(_ path: String) {
        unlink(path)
        livePaths.withLock { _ = $0.remove(path) }
    }
}
