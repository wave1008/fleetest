// RunLockClient.swift
// シナリオのプロセス(FTDSL の DSL スレッド)の側のロックの接続。**1プロセスに1本・ブロッキングの送受信**。
// 再接続しない: 切れたら以後のロックの呼び出しは全部失敗(DR-136。書き込み・外すを送った後に切れたら届いたかもしれないので撃ち直さない)。
// fd は `O_CLOEXEC`(シナリオが起こした長生きの子が継ぐと、持ち主が死んでもサーバー側の接続が閉じない)。
// 待ちの時計は `SuspendingClock`(スリープ明けに全員が一斉に時間切れにならない。watchdog と同じ)。

import Foundation

public final class RunLockClient: @unchecked Sendable {
    public enum Outcome: Equatable, Sendable {
        case granted
        /// 時間切れ(呼び手が `cancel` を送る)
        case timedOut
        case failed(String)
    }

    private let descriptor: Int32
    private let channel: RunLockLineChannel
    // 不変条件: 書き込みと下の3つの状態は lock の内側。読み(channel)は DSL スレッドだけ
    private let lock = NSLock()
    private var nextID = 1
    private var brokenReason: String?
    /// 取り消しを送った要求。後から渡しが届いたら外す(すれ違い)
    private var cancelled = Set<Int>()
    /// 直近の渡しが印つき(持ち主不明から外したキー)だったときのキー
    private var lostKeys: [String] = []

    private init(descriptor: Int32) {
        self.descriptor = descriptor
        self.channel = RunLockLineChannel(descriptor: descriptor)
    }

    deinit { close(descriptor) }

    /// つなげなければ投げる(呼び手は待たずに失敗にする)。最初の1通に名乗りを載せる
    /// 1回だけつなぐ(一時的な失敗の再試行は呼び手 = `RunLockScenarioState`。つなぐ操作は届いたか分からない操作ではないので撃ち直してよい)
    public static func connect(path: String, scenario: String, machine: String, device: String,
                               token: String = "") throws -> RunLockClient {
        let descriptor = try UnixSocket.connect(path: path, closeOnExec: true)
        let client = RunLockClient(descriptor: descriptor)
        guard client.send(.hello(scenario: scenario, machine: machine, device: device, token: token)) else {
            throw RunLockError("the run lock server closed the connection")
        }
        return client
    }

    /// 直近の渡しの注記: 前の持ち主が接続を失ったキー(読んだら空に戻す)
    public func takeLostKeys() -> [String] {
        lock.withLock { () -> [String] in
            defer { lostKeys = [] }
            return lostKeys
        }
    }

    /// テスト用: `FD_CLOEXEC` を確かめる
    var descriptorForTesting: Int32 { descriptor }

    public var isBroken: Bool { lock.withLock { brokenReason != nil } }

    /// 要求を送る。番号を返す(切れていれば失敗)
    public func request(keys: [String], mode: RunLockTable.Mode) -> Result<Int, RunLockError> {
        if let reason = lock.withLock({ brokenReason }) { return .failure(RunLockError(reason)) }
        let id = lock.withLock { () -> Int in
            defer { nextID += 1 }
            return nextID
        }
        guard send(.acquire(id: id, keys: keys, mode: mode)) else {
            return .failure(RunLockError(lock.withLock { brokenReason } ?? "the run lock connection is broken"))
        }
        return .success(id)
    }

    /// 要求 `id` の渡しを待つ。`timeout` が尽きたら `.timedOut`(0 は今届いているものだけ)。
    /// `onQueued`: サーバーが「すぐには渡せず行列に入った」と返したとき(渡しの前に1回だけ)呼ぶ = 待ちの窓を開く合図
    public func wait(id: Int, timeout: Duration, onQueued: () -> Void = {}) -> Outcome {
        let clock = SuspendingClock()
        let deadline = clock.now.advanced(by: timeout)
        while true {
            let remaining = deadline - clock.now
            let ms = remaining <= .zero ? Int32(0) : Int32(min(1_000, DurationConversion.milliseconds(remaining) + 1))
            switch channel.readLine(timeoutMs: ms) {
            case .timeout:
                if clock.now >= deadline { return .timedOut }
            case .closed:
                return .failed(markBroken("the run lock server closed the connection"))
            case .line(let data):
                guard let message = RunLockMessage.decode(line: data) else {
                    return .failed(markBroken("the run lock server sent an unreadable message"))
                }
                switch message {
                case .queued(let queued) where queued == id: onQueued()
                case .grantedAfterLoss(let granted, let keys) where granted == id:
                    lock.withLock { lostKeys = keys }
                    return .granted
                case .granted(let granted) where granted == id: return .granted
                case .failed(let failed, let reason) where failed == id: return .failed(reason)
                case .granted(let late): releaseIfCancelled(late)
                case .grantedAfterLoss(let late, _): releaseIfCancelled(late)
                default: continue
                }
            }
        }
    }

    /// 待ちを諦める。返事は待たない(渡しとすれ違ったらサーバーが「外す」として扱う)
    public func cancel(id: Int) {
        lock.withLock { _ = cancelled.insert(id) }
        _ = send(.cancel(id: id))
    }

    /// 子のプロセスが、`token` のシナリオの「ロックの外の操作1件」が正本に確定したと伝える(返事は無い。切れていれば false)
    public func sendOutsideApplied(token: String) -> Bool { send(.outsideApplied(token: token)) }

    /// 子のプロセスからサーバーへの片道の知らせ(`outsideApplied` / `scenarioEnded`)
    public func sendNote(_ message: RunLockMessage) -> Bool { send(message) }

    /// 渡し済みの要求を外す(切れていれば何もしない)
    public func release(id: Int) {
        _ = send(.release(id: id))
    }

    /// 返事を待つ上限に足す余裕。根拠: サーバーの適用待ちは `cap` で必ず失敗の返事になる(同じ値)ので、返事は cap のすぐ後までに届く。
    /// 負荷の高いマシンで読むスレッドの起床が数秒遅れても、返事の失敗を「返事が来ない」と取り違えないための幅
    static let replyMargin: Duration = .seconds(10)

    /// サーバーの最新の run メモ。`outsideOps` = このシナリオがロックの外で出した run メモ操作の数(サーバーは親が適用し終えるまで待つ)。
    /// `cap` = サーバーの適用待ちの上限(ロックの待ちの絶対上限と同じ値)。`onPending` = サーバーが「適用待ちに入った」と返したとき
    /// (結果の前に1回)呼ぶ = 待ちの窓を開く合図。返事は `cap + replyMargin` までに来なければ接続を壊れた扱いにして失敗にする
    public func memoRead(outsideOps: Int, cap: Duration = .seconds(ScenarioHost.defaultScenarioTimeout),
                         onPending: () -> Void = {}) -> Result<[String: [String]], RunLockError> {
        if let reason = lock.withLock({ brokenReason }) { return .failure(RunLockError(reason)) }
        let id = lock.withLock { () -> Int in
            defer { nextID += 1 }
            return nextID
        }
        guard send(.memoRead(id: id, outsideOps: outsideOps)) else {
            return .failure(RunLockError(lock.withLock { brokenReason } ?? "the run lock connection is broken"))
        }
        switch awaitReply(id: id, cap: cap, onPending: onPending, isReply: { if case .memo = $0 { return true } else { return false } }) {
        case .reply(.memo(let values)): return .success(values)
        case .reply: return .failure(RunLockError("the run lock server sent an unexpected reply"))
        case .failed(let reason): return .failure(RunLockError(reason))
        case .broken(let reason): return .failure(RunLockError(reason))
        }
    }

    /// run メモへ書いて、**確定の返事を待つ**(`cap` / `onPending` は `memoRead` と同じ)。送った後に切れたら撃ち直さず、
    /// 届いたかもしれない旨を返す(DR-136)
    public func memoWrite(_ op: RunMemoOp, outsideOps: Int, cap: Duration = .seconds(ScenarioHost.defaultScenarioTimeout),
                          onPending: () -> Void = {}) -> RunLockError? {
        if case .failure(let error) = memoWriteCommitted(op, outsideOps: outsideOps, cap: cap, onPending: onPending) { return error }
        return nil
    }

    /// `memoWrite` と同じで、成功したら確定の通し番号(正本が無い構成は nil)を返す
    public func memoWriteCommitted(_ op: RunMemoOp, outsideOps: Int, cap: Duration = .seconds(ScenarioHost.defaultScenarioTimeout),
                                   onPending: () -> Void = {}) -> Result<Int?, RunLockError> {
        if let reason = lock.withLock({ brokenReason }) { return .failure(RunLockError(reason)) }
        let id = lock.withLock { () -> Int in
            defer { nextID += 1 }
            return nextID
        }
        guard send(.memoWrite(id: id, op: RunLockMemoOp(op), outsideOps: outsideOps)) else {
            return .failure(RunLockError("the run memo write could not be sent to the run lock server (it was not written)"))
        }
        switch awaitReply(id: id, cap: cap, onPending: onPending, isReply: { if case .committed(let done, _) = $0 { return done == id } else { return false } }) {
        case .reply(.committed(_, let seq)): return .success(seq)
        case .reply: return .success(nil)
        case .failed(let reason): return .failure(RunLockError(reason))
        case .broken:
            return .failure(RunLockError("the connection to the run lock server broke after the run memo write was sent:"
                + " the value may or may not have been written (it is not sent again)"))
        }
    }

    private enum Reply {
        case reply(RunLockMessage)
        case failed(String)
        case broken(String)
    }

    /// `id` の返事を待つ。`pending` を受けたら `onPending`・取り消し済みの要求の渡しは外す・上限を過ぎたら壊れた扱い
    private func awaitReply(id: Int, cap: Duration, onPending: () -> Void, isReply: (RunLockMessage) -> Bool) -> Reply {
        let clock = SuspendingClock()
        let deadline = clock.now.advanced(by: cap + Self.replyMargin)
        while true {
            let remaining = deadline - clock.now
            let ms = remaining <= .zero ? Int32(0) : Int32(min(1_000, DurationConversion.milliseconds(remaining) + 1))
            switch channel.readLine(timeoutMs: ms) {
            case .timeout:
                if clock.now >= deadline {
                    return .broken(markBroken("the run lock server did not reply within \(DurationConversion.milliseconds(cap) / 1000)s"
                        + " plus a margin; every lock call in this scenario fails"))
                }
            case .closed:
                return .broken(markBroken("the run lock server closed the connection"))
            case .line(let data):
                guard let message = RunLockMessage.decode(line: data) else {
                    return .broken(markBroken("the run lock server sent an unreadable message"))
                }
                if isReply(message) { return .reply(message) }
                switch message {
                case .pending(let pending) where pending == id: onPending()
                case .failed(let failed, let reason) where failed == id: return .failed(reason)
                case .granted(let late): releaseIfCancelled(late)
                default: continue
                }
            }
        }
    }

    // MARK: 内部

    func releaseIfCancelled(_ id: Int) {
        let wasCancelled = lock.withLock { cancelled.remove(id) != nil }
        if wasCancelled { _ = send(.release(id: id)) }
    }

    /// 書く。失敗したら接続を壊れた扱いにして false
    private func send(_ message: RunLockMessage) -> Bool {
        lock.withLock {
            if brokenReason != nil { return false }
            guard RunLockLineChannel.writeAll(descriptor, message.encodedLine()) else {
                brokenReason = "the run lock server closed the connection"
                return false
            }
            return true
        }
    }

    private func markBroken(_ reason: String) -> String {
        lock.withLock {
            if brokenReason == nil { brokenReason = reason }
            return brokenReason ?? reason
        }
    }
}
