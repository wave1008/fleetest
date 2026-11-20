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

    /// 手元(このプロセスと、この機械で起こした子・中継役)用の待ち受けのパス。**接続の出どころはどの待ち受けで受けたかだけで決める**
    /// (相手の名乗りや `LOCAL_PEERPID` には頼らない: 転送越しの接続の pid は手元の ssh のものになり、リモートの run は自分を local と名乗る)
    public let socketPath: String

    /// 接続の出どころ = 受けた待ち受け。**リモートはディスパッチ(中継役の子)ごとに別の待ち受け**で、`scope` = その待ち受けのパス
    /// (持ち主不明を外せるのは同じ scope の知らせだけ。同じ機械の別のディスパッチの不明を巻き込まない)
    enum Origin: Equatable, Sendable {
        case local
        case remote(machine: String, scope: String)
    }

    /// 閉じた後も持ち分が残っている接続(`scenarioEnded` と、不明を外すときの掃除が引く)
    fileprivate struct ClosedHolder {
        let token: String
        /// リモートの待ち受けで受けた接続のときだけ(持ち主不明の範囲)
        let scope: String?
    }

    fileprivate final class Conn: @unchecked Sendable {
        let id: Int
        let descriptor: Int32
        let pid: pid_t
        let origin: Origin
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

        init(id: Int, descriptor: Int32, pid: pid_t, origin: Origin) {
            self.id = id
            self.descriptor = descriptor
            self.pid = pid
            self.origin = origin
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

    fileprivate struct Waiting {
        let keys: [String]
        let mode: RunLockTable.Mode
        let since: SuspendingClock.Instant
        /// リモートのディスパッチの待ち(その待ち受けの識別子)。手元は nil(数えない)
        let scope: String?
    }

    /// 待ちの時刻(ミリ秒)の起点。`RunLockWaitUnion` へ渡す値はこの起点からの経過
    private static let clockOrigin = SuspendingClock().now
    private static func nowMs() -> Int { DurationConversion.milliseconds(SuspendingClock().now - clockOrigin) }

    fileprivate struct State {
        var table = RunLockTable()
        var conns: [Int: Conn] = [:]
        var nextConnection = 1
        var waiting: [RunLockTable.Owner: Waiting] = [:]
        /// リモートのディスパッチ(待ち受けの識別子)ごとの待ちの和集合
        var waitUnion: [String: RunLockWaitUnion] = [:]
        /// 待ち受けを閉じた範囲。待ちが尽きたら `waitUnion` から外す
        var closedScopes: Set<String> = []
        var stopped = false
        var closedHolders: [Int: ClosedHolder] = [:]
        /// 親が見届けた(reap した)シナリオの起動の印。**持ち分を外すのはその接続が閉じたとき**(接続の EOF は、その接続の
        /// それまでの全メッセージ(`release` を含む)の後に処理される。別の接続の `scenarioEnded` が先に着いても、放した分に印を付けない)
        var endedTokens: Set<String> = []
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
    // 不変条件: acceptLoops / allPaths / remoteLoops は listenersLock の内側(動的に待ち受けを足す・閉じるため)
    private let listenersLock = NSLock()
    private var acceptLoops: [AcceptLoop] = []
    private var allPaths: [String] = []
    private var remoteLoops: [String: AcceptLoop] = [:]
    private let directory: String
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
        self.directory = directory
        self.maxReplyBytes = maxReplyBytes
        applied.reopen()
        self.memoFor = memoFor
        self.applied = applied
        self.waitCapSeconds = waitCapSeconds
        self.peerPidReader = peerPidReader
        self.log = log
        self.reportInterval = reportInterval
        self.pidExitWaiter = pidExitWaiter
        let localPath = Self.uniquePath(directory: directory)
        self.socketPath = localPath
        do {
            try addListener(path: localPath, origin: .local)
        } catch {
            for loop in acceptLoops { loop.stop() }
            for path in allPaths { Self.removeSocketFile(path) }
            throw error
        }
        startReporter()
    }

    /// sun_path は 104 バイト: 一時フォルダ(約 50 文字)+ 短い一意の名前に収める。待ち受けごとに別のパス
    private static func uniquePath(directory: String) -> String {
        (directory as NSString).appendingPathComponent("ftlock-" + String(UUID().uuidString.prefix(8)).lowercased() + ".sock")
    }

    private func addListener(path: String, origin: Origin) throws {
        let listener = try UnixSocket.listen(path: path, backlog: Self.listenBacklog)
        Self.registerForExitCleanup(path)
        do {
            let loop = try AcceptLoop(listener: listener, name: "fleetest-run-lock-accept") { [weak self] descriptor in
                guard let self else {
                    close(descriptor)
                    return false
                }
                self.accept(descriptor, origin: origin)
                return true
            }
            listenersLock.withLock {
                acceptLoops.append(loop)
                allPaths.append(path)
                if case .remote = origin { remoteLoops[path] = loop }
            }
        } catch {
            close(listener)
            Self.removeSocketFile(path)
            throw error
        }
    }

    /// リモートの機械へのディスパッチ1回ぶんの待ち受けを開く(中継役の子を起こす直前)。戻り値 = そのパス = ディスパッチの識別子
    /// (中継役の ssh の `-R` の転送先。`sshEnded` / `remoteRunEnded` もこのパスで呼ぶ)。**ディスパッチごとに別の待ち受け** =
    /// 同じ機械の別のディスパッチ(前の対象)の持ち主不明と混ざらない
    public func openRemoteListener(machine: String) throws -> String {
        let path = Self.uniquePath(directory: directory)
        try addListener(path: path, origin: .remote(machine: machine, scope: path))
        return path
    }

    /// そのディスパッチの待ち受けを閉じる(中継役の子が終わった後)。**既に受けた接続と持ち主不明は残る**(外すのは `remoteRunEnded` だけ)
    public func closeRemoteListener(path: String) {
        let loop = listenersLock.withLock { () -> AcceptLoop? in
            allPaths.removeAll { $0 == path }
            return remoteLoops.removeValue(forKey: path)
        }
        loop?.stop()
        Self.removeSocketFile(path)
        lock.withLock {
            state.closedScopes.insert(path)
            state.pruneWaitUnion(path)
        }
    }

    deinit {
        for loop in acceptLoops { loop.requestStop() }
        reporterWake.signal()
        for path in allPaths { Self.removeSocketFile(path) }
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
        let (loops, paths) = listenersLock.withLock { (acceptLoops, allPaths) }
        if isOnOwnThread {
            for loop in loops { loop.requestStop() }
            for path in paths { Self.removeSocketFile(path) }
            return
        }
        for loop in loops { loop.stop() }
        readers.wait()
        for path in listenersLock.withLock({ allPaths }) { Self.removeSocketFile(path) }
    }

    private static let ownThreadKey = "fleetest.runLockServer"
    private var isOnOwnThread: Bool {
        (Thread.current.threadDictionary[Self.ownThreadKey] as? ObjectIdentifier) == ObjectIdentifier(self)
    }
    private func markOwnThread() { Thread.current.threadDictionary[Self.ownThreadKey] = ObjectIdentifier(self) }

    /// テスト用: 閉じた後も持ち分が残っている接続の数(外したら掃除されること)
    var closedHolderCountForTesting: Int { lock.withLock { state.closedHolders.count } }

    public var isStopped: Bool { lock.withLock { state.stopped } }

    // MARK: 接続

    private func accept(_ descriptor: Int32, origin: Origin) {
        let conn: Conn? = lock.withLock {
            guard !state.stopped else { return nil }
            let conn = Conn(id: state.nextConnection, descriptor: descriptor,
                            pid: origin == .local ? peerPidReader(descriptor) : 0, origin: origin)
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
                    // 表が**この要求を新しく**行列に入れたときだけ待ちに数える(重複で断られた要求は、元の待ちが数えられているので重ねない)
                    if state.waiting[owner] == nil, !effects.failures.contains(where: { $0.owner == owner }),
                       !state.table.isGranted(owner), state.table.waitingKey(of: owner) != nil {
                        let scope: String? = { if case .remote(_, let scope) = conn.origin { return scope } else { return nil } }()
                        state.beginWaiting(owner, Waiting(keys: keys, mode: mode, since: SuspendingClock().now, scope: scope), nowMs: Self.nowMs())
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
                state.endWaiting(owner, nowMs: Self.nowMs())
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
        case .scenarioEnded(let token):
            scenarioEnded(token: token)
        case .sshEnded(let listener):
            guard conn.origin == .local else { return }  // 中継役は手元のプロセス(手元の待ち受け以外の主張は読まない)
            var count = 0
            perform { state, lines in
                var effects = RunLockTable.Effects.none
                var machine = listener
                for open in state.conns.values {
                    guard case .remote(let name, let scope) = open.origin, scope == listener else { continue }
                    machine = name
                    let more = state.table.markUnknown(connection: open.id, scope: scope, machine: name)
                    effects.grants += more.grants
                    effects.failures += more.failures
                    effects.lossMarked.merge(more.lossMarked) { $1 }
                }
                count = state.table.unknownKeyCount(scope: listener)
                if count > 0 {
                    lines.append("run lock: ssh to \(machine) ended while its scenarios held \(count) key(s);"
                        + " they are unavailable until that dispatch's run is confirmed to have ended")
                }
                return effects
            }
            conn.send(.unknownKeys(listener: listener, count: count, capSeconds: max(1, waitCapSeconds())))
        case .remoteRunEnded(let listener):
            guard conn.origin == .local else { return }
            perform { state, lines in
                let released = state.table.releaseUnknown(scope: listener)
                for (id, closed) in state.closedHolders where closed.scope == listener { state.closedHolders.removeValue(forKey: id) }
                if released.keys > 0 {
                    lines.append("run lock: the remote run has ended; released \(released.keys) key(s) of its lost owners"
                        + " (the next holder is told their writes may be missing)")
                }
                return released.effects
            }
            conn.send(.unknownKeys(listener: listener, count: 0, capSeconds: max(1, waitCapSeconds())))
        case .waitedQuery(let listener):
            guard conn.origin == .local else { return }
            let ms = lock.withLock { state.waitUnion[listener]?.totalMs(nowMs: Self.nowMs()) ?? 0 }
            conn.send(.waited(listener: listener, ms: ms))
        case .queued, .pending, .granted, .grantedAfterLoss, .failed, .memo, .committed, .unknownKeys, .waited:
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

    /// その印のシナリオのプロセスを親が見届けた(reap した)。**その印の接続がまだ開いていれば何もしない**: 持ち分を外すのは接続が閉じたとき
    /// (EOF は、その接続のそれまでの全メッセージ = `release` の後に処理されるので、放した分に印を付けない)。
    /// 既に閉じていて持ち分(持ち主不明・pid 待ち)が残っていれば、ここで外す(閉じたまま持っていた = 印が付く)
    public func scenarioEnded(token: String) {
        guard !token.isEmpty else { return }
        perform { state, _ in
            state.endedTokens.insert(token)
            var effects = RunLockTable.Effects.none
            for (id, closed) in state.closedHolders.sorted(by: { $0.key < $1.key }) where closed.token == token {
                let released = state.table.releaseAll(connection: id)
                effects.grants += released.grants
                effects.failures += released.failures
                effects.lossMarked.merge(released.lossMarked) { $1 }
                state.closedHolders.removeValue(forKey: id)
            }
            return effects
        }
    }

    /// 接続が閉じた。**1回の操作で**(別のスレッドの `scenarioEnded` / `sshEnded` が間に入って取りこぼされない)
    /// 表から外し・持ち主を決める:
    /// - 持ち分が無ければ何もしない
    /// - その印のシナリオを親が見届けていれば(`scenarioEnded` が先に着いていた)、閉じたまま持っていたので外して印を付ける
    /// - リモートの待ち受けで受けた接続は**持ち主不明**(ssh の切断でも閉じ、切れた先でまだ臨界区間を走っていることがある)
    /// - 手元の待ち受けで受けた接続は、相手のプロセスの終わりを待って外す
    private func connectionDidClose(_ conn: Conn) {
        var localHeld: [RunLockTable.Owner] = []
        var stopped = false
        perform { state, lines in
            stopped = state.stopped
            state.conns.removeValue(forKey: conn.id)
            let closed = state.table.connectionClosed(conn.id)
            var effects = closed.effects
            for owner in state.waiting.keys where owner.connection == conn.id && !closed.held.contains(owner) {
                state.endWaiting(owner, nowMs: Self.nowMs())
            }
            guard !closed.held.isEmpty, !state.stopped else { return effects }
            func merge(_ more: RunLockTable.Effects) {
                effects.grants += more.grants
                effects.failures += more.failures
                effects.lossMarked.merge(more.lossMarked) { $1 }
            }
            if !conn.token.isEmpty, state.endedTokens.contains(conn.token) {
                merge(state.table.releaseAll(connection: conn.id))
                return effects
            }
            switch conn.origin {
            case .remote(let machine, let scope):
                state.closedHolders[conn.id] = ClosedHolder(token: conn.token, scope: scope)
                lines.append("run lock: \(describe(conn)) lost its connection while holding locks, so the keys it held are unknown-owner"
                    + " until the run on \(machine) is confirmed to have ended")
                merge(state.table.markUnknown(connection: conn.id, scope: scope, machine: machine))
            case .local:
                state.closedHolders[conn.id] = ClosedHolder(token: conn.token, scope: nil)
                localHeld = closed.held
            }
            return effects
        }
        guard !localHeld.isEmpty, !stopped else { return }
        let heldOwners = localHeld
        let releaseHeld: @Sendable () -> Void = { [self] in
            perform { state, _ in
                var effects = RunLockTable.Effects.none
                for owner in heldOwners {
                    let released = state.table.release(connection: owner.connection, requestID: owner.requestID)
                    effects.grants += released.grants
                    effects.failures += released.failures
                }
                state.closedHolders.removeValue(forKey: conn.id)
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
                state.endWaiting(owner, nowMs: Self.nowMs())
                if let conn = state.conns[owner.connection] {
                    if let lost = effects.lossMarked[owner] {
                        sends.append((conn, .grantedAfterLoss(id: owner.requestID, keys: lost)))
                    } else {
                        sends.append((conn, .granted(id: owner.requestID)))
                    }
                }
            }
            for failure in effects.failures {
                state.endWaiting(failure.owner, nowMs: Self.nowMs())
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

extension RunLockServer.State {
    /// 待ちに入った(リモートのディスパッチなら和集合に数える)
    fileprivate mutating func beginWaiting(_ owner: RunLockTable.Owner, _ waiting: RunLockServer.Waiting, nowMs: Int) {
        self.waiting[owner] = waiting
        if let scope = waiting.scope { waitUnion[scope, default: RunLockWaitUnion()].begin(nowMs: nowMs) }
    }

    /// 待ちが終わった(渡し・失敗・取り消し・接続の終わり)。待っていなければ何もしない
    fileprivate mutating func endWaiting(_ owner: RunLockTable.Owner, nowMs: Int) {
        guard let waiting = self.waiting.removeValue(forKey: owner) else { return }
        if let scope = waiting.scope {
            waitUnion[scope]?.end(nowMs: nowMs)
            pruneWaitUnion(scope)
        }
    }

    /// 待ち受けを閉じた範囲の和集合は、待ちが尽きたら捨てる(ディスパッチごとに増え続けない)
    fileprivate mutating func pruneWaitUnion(_ scope: String) {
        if closedScopes.contains(scope), waitUnion[scope]?.isActive != true {
            waitUnion.removeValue(forKey: scope)
            closedScopes.remove(scope)
        }
    }
}
