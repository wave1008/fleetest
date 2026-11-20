// RunLockScenarioState.swift
// シナリオのプロセスの側のロックの状態(RR-8.5)。**DSL スレッド専有**(`FTDriveCore` が1つ持つ)。
// 持っているキーの積み(規則②③。I/O なし = `RunLockHoldings`)と、サーバーとの接続(`RunLockClient`)をまとめる。
// DSL のコマンド(FTDSL/CommandsLock.swift)はここを呼んで、ステップの記録と本体の実行だけを行う。

import Foundation

/// 今持っているキーの積み。キーの同一性は UTF-8 のバイト列(`String` の等価は Unicode の正規化に依るので使わない)
public struct RunLockHoldings: Sendable {
    private struct Entry {
        var mode: RunLockTable.Mode
        var count: Int
    }

    /// 1回の呼び出し。`keys` は検査済み(名前の順・重複なし)。`newKeys` はまだ持っていないキー = サーバーへ頼むもの
    public struct Plan: Equatable, Sendable {
        public let keys: [String]
        public let newKeys: [String]
        public let mode: RunLockTable.Mode
    }

    private var entries: [[UInt8]: Entry] = [:]

    public init() {}

    public var isEmpty: Bool { entries.isEmpty }
    public var holdsExclusive: Bool { entries.values.contains { $0.mode == .exclusive } }

    /// 取ろうとした時点の判定。違反は競合の有無に関わらずエラー(規則②③)
    public func plan(keys: [String], mode: RunLockTable.Mode) -> Result<Plan, RunLockError> {
        var newKeys: [String] = []
        for key in keys {
            if let held = entries[Array(key.utf8)] {
                if held.mode == .shared, mode == .exclusive {
                    return .failure(RunLockError(
                        "cannot take \"\(key)\" exclusively inside a shared lock on it (a shared lock cannot be upgraded);"
                        + " take the exclusive lock in the outer call"))
                }
            } else {
                newKeys.append(key)
            }
        }
        if let highest = entries.keys.max(by: { $0.lexicographicallyPrecedes($1) }) {
            for key in newKeys where Array(key.utf8).lexicographicallyPrecedes(highest) {
                let heldName = String(decoding: highest, as: UTF8.self)
                return .failure(RunLockError(
                    "taking \"\(key)\" inside the lock on \"\(heldName)\" can deadlock: keys are ordered by name (UTF-8 bytes),"
                    + " and a key that sorts before one you already hold cannot be taken inside it."
                    + " Take all the keys in one call instead, e.g. withExclusiveLock(\"\(key)\", \"\(heldName)\") { ... }"))
            }
        }
        return .success(Plan(keys: keys, newKeys: newKeys, mode: mode))
    }

    /// 取れた(または再入で何もしない)
    public mutating func commit(_ plan: Plan) {
        for key in plan.keys {
            let id = Array(key.utf8)
            if entries[id] != nil {
                entries[id]?.count += 1
            } else {
                entries[id] = Entry(mode: plan.mode, count: 1)
            }
        }
    }

    /// ブロックを抜けた。持つ回数が 0 になったキーを外す
    public mutating func leave(_ plan: Plan) {
        for key in plan.keys {
            let id = Array(key.utf8)
            guard var entry = entries[id] else { continue }
            entry.count -= 1
            if entry.count <= 0 { entries.removeValue(forKey: id) } else { entries[id] = entry }
        }
    }
}

public final class RunLockScenarioState {
    /// 受け渡しの行の値。**行を受けていないプロセス(テスト・MCP の直接操作)はその場で渡す**
    public var access: RunLockAccess = .immediate
    /// 1回の呼び出しの待ちの絶対の上限(秒)。受け渡しの行の値
    public var waitCapSeconds = 0
    /// サーバーへの名乗り(持ち主の名指しに使う)
    public var scenarioID = ""
    public var machine = ""
    public var device = ""
    /// 受け渡しの行の `lockOwnerToken`
    public var ownerToken = ""
    /// このシナリオがロックの外で出した run メモの操作(runMemoWrite + runMemoClear のイベント)の数。
    /// ロックの中の読み書きに載せ、サーバーは親が同じ数を適用し終えてから答える
    public private(set) var outsideMemoOps = 0

    public func noteOutsideMemoOp() { outsideMemoOps += 1 }

    private(set) var holdings = RunLockHoldings()
    private var client: RunLockClient?
    /// つなげなかった理由。以後の呼び出しは待たずに全部失敗にする
    private var unavailable: String?

    public init() {}

    /// 受け渡しの行から。名乗りの machine はこのマシンの名前
    public func configure(handoff: DeviceSessionHandoff, scenarioID: String, device: String) {
        access = handoff.lockAccess
        waitCapSeconds = handoff.lockWaitCapSeconds
        self.scenarioID = scenarioID
        machine = RunWideHookPlan.localHostName()
        ownerToken = handoff.lockOwnerToken
        self.device = device
    }

    public struct Entry {
        let plan: RunLockHoldings.Plan
        let requestID: Int?
        /// 待った秒(ステップの記述に出す)
        public let waited: Double
        public var keys: [String] { plan.keys }
        public var mode: RunLockTable.Mode { plan.mode }
    }

    public var isHolding: Bool { !holdings.isEmpty }

    /// 待ちの上限の下限(秒)。根拠: 上限は `scenarioTimeout`(プロファイルの検査が 1 秒未満を断る = `RunProfile`)から決まるので
    /// 実際は 1 以上。0 になるのは受け渡しの行の値が無い・未設定の起動だけで、その場合に即時の時間切れにしないための床
    static let minimumCapSeconds = 1

    /// ロックのブロックに入る。取れなければ理由(英語)を返す = 本体を実行しない
    public func enter(keys rawKeys: [String], mode: RunLockTable.Mode, waitSeconds: Double?) -> Result<Entry, RunLockError> {
        if let waitSeconds, !(waitSeconds > 0 && waitSeconds.isFinite) {
            return .failure(RunLockError("waitSeconds must be a positive number of seconds (got \(waitSeconds))"))
        }
        let keys: [String]
        switch RunLockKeys.normalize(rawKeys) {
        case .success(let value): keys = value
        case .failure(let error): return .failure(error)
        }
        let plan: RunLockHoldings.Plan
        switch holdings.plan(keys: keys, mode: mode) {
        case .success(let value): plan = value
        case .failure(let error): return .failure(error)
        }
        switch access {
        case .passThrough, .immediate:
            holdings.commit(plan)
            return .success(Entry(plan: plan, requestID: nil, waited: 0))
        case .refuse(let reason):
            return .failure(RunLockError("run-wide locks are not available: \(reason)"))
        case .socket(let path):
            return enterViaServer(path: path, plan: plan, waitSeconds: waitSeconds)
        }
    }

    /// ブロックを抜ける(本体が失敗で止まっていても呼ぶ)
    public func leave(_ entry: Entry) {
        holdings.leave(entry.plan)
        if let id = entry.requestID { client?.release(id: id) }
    }

    // MARK: run メモ(ロックの中)

    /// ロックの中でサーバーへ聞く・書くか。ロックの外は今のまま(手元の写しと親への片道通知)
    public var usesServerMemo: Bool { client != nil && isHolding }

    /// ロックの中の run メモの書き込みを断る理由。断らないなら nil。**全ての構成で同じ規則**(1台の run で通って複数台で赤にならない):
    /// 排他を1つも持っていない(共有だけ)・1件が `RunMemoWire.maxPieces` を超える
    public func memoWriteRejection(command: String, op: RunMemoOp) -> String? {
        guard isHolding else { return nil }
        if !holdings.holdsExclusive {
            return "\(command) needs an exclusive lock: inside withSharedLock only, a read-modify-write would lose updates."
                + " Use withSharedLock only to read, or hold an exclusive lock on some key"
        }
        if RunMemoWire.pieces(for: op).count > RunMemoWire.maxPieces {
            return "\(command): the value is too large to share across the run"
                + " (over \(RunMemoWire.maxPieces) pieces of \(RunMemoWire.pieceCharacters) characters when encoded)"
        }
        return nil
    }

    /// サーバーが「親の適用待ち」に入った間は締め切り(scenarioTimeout・出力の無さの打ち切り)から外す。窓の上限は絶対上限
    private func withMemoWindow<T>(_ body: (Duration, () -> Void) -> T) -> T {
        let cap = Duration.seconds(Double(max(Self.minimumCapSeconds, waitCapSeconds)))
        var window: DeadlineExclusion.Token?
        let result = body(cap, { window = DeadlineExclusion.begin(cap: cap) })
        if let window { DeadlineExclusion.end(window) }
        return result
    }

    public func serverMemoRead() -> Result<[String: [String]], RunLockError> {
        guard let client else { return .failure(RunLockError("the run lock connection is not open")) }
        let ops = outsideMemoOps
        return withMemoWindow { cap, onPending in client.memoRead(outsideOps: ops, cap: cap, onPending: onPending) }
    }

    public func serverMemoWrite(_ op: RunMemoOp) -> RunLockError? {
        guard let client else { return RunLockError("the run lock connection is not open") }
        let ops = outsideMemoOps
        return withMemoWindow { cap, onPending in client.memoWrite(op, outsideOps: ops, cap: cap, onPending: onPending) }
    }

    // MARK: サーバー

    /// つなぐのを再試行する間隔(ミリ秒)の始まりと上限。根拠: 同時に起動したシナリオの接続が listen の待ち行列(128)を
    /// 溢れさせたときの ECONNREFUSED / EAGAIN は、サーバーが accept するまでの数十ミリ秒で解ける
    private static let connectRetryStartMs = 20
    private static let connectRetryMaxMs = 200

    /// つなぐ。**ECONNREFUSED / EAGAIN だけ**、待ちの絶対上限の中で再試行する(listen の待ち行列が一時的に埋まったときの失敗。
    /// つなぐ操作は届いたか分からない操作ではないので撃ち直してよい = DR-136)。サーバーが居ない(ENOENT 等)は待たずに失敗。
    /// 再試行に入ったら待ちの窓(締め切りの差し引き)を開く
    private func connectWithRetry(path: String, cap: Double) throws -> RunLockClient {
        func attempt() throws -> RunLockClient {
            try RunLockClient.connect(path: path, scenario: scenarioID, machine: machine, device: device, token: ownerToken)
        }
        func isTransient(_ error: Error) -> Bool {
            guard let posix = error as? POSIXError else { return false }
            return posix.code == .ECONNREFUSED || posix.code == .EAGAIN
        }
        do { return try attempt() } catch where isTransient(error) {}
        let token = DeadlineExclusion.begin(cap: .seconds(cap))
        defer { DeadlineExclusion.end(token) }
        let clock = SuspendingClock()
        let deadline = clock.now.advanced(by: .seconds(cap))
        var delay = Self.connectRetryStartMs
        while true {
            usleep(UInt32(delay) * 1000)
            delay = min(delay * 2, Self.connectRetryMaxMs)
            do { return try attempt() } catch where isTransient(error) {
                if clock.now >= deadline { throw error }
            }
        }
    }

    private func enterViaServer(path: String, plan: RunLockHoldings.Plan, waitSeconds: Double?) -> Result<Entry, RunLockError> {
        if let unavailable { return .failure(RunLockError(unavailable)) }
        let cap = Double(max(Self.minimumCapSeconds, waitCapSeconds))
        if client == nil {
            do {
                client = try connectWithRetry(path: path, cap: cap)
            } catch {
                let reason = "cannot reach the run lock server (\(error.localizedDescription)); every lock call in this scenario fails"
                unavailable = reason
                return .failure(RunLockError(reason))
            }
        }
        guard let client else { return .failure(RunLockError("the run lock connection is not open")) }
        if client.isBroken {
            return .failure(RunLockError("the run lock connection is broken; every lock call in this scenario fails"))
        }
        if plan.newKeys.isEmpty {
            holdings.commit(plan)
            return .success(Entry(plan: plan, requestID: nil, waited: 0))
        }
        let limit = min(cap, waitSeconds ?? cap)
        let clock = SuspendingClock()
        let started = clock.now
        let id: Int
        switch client.request(keys: plan.newKeys, mode: plan.mode) {
        case .success(let value): id = value
        case .failure(let error): return .failure(error)
        }
        // 待ちの窓(締め切りの差し引き)は、サーバーが「行列に入った」と返したときだけ開く。窓の上限は
        // **呼び出しの絶対の上限**(`waitSeconds:` で短くしても窓は短くしない = こちらが先に閉じて watchdog に切られない)
        var window: DeadlineExclusion.Token?
        let outcome = client.wait(id: id, timeout: .seconds(limit), onQueued: { window = DeadlineExclusion.begin(cap: .seconds(cap)) })
        if let window { DeadlineExclusion.end(window) }
        let waited = Double(DurationConversion.milliseconds(clock.now - started)) / 1000
        switch outcome {
        case .granted:
            holdings.commit(plan)
            return .success(Entry(plan: plan, requestID: id, waited: waited))
        case .timedOut:
            client.cancel(id: id)
            let names = plan.newKeys.map { "\"\($0)\"" }.joined(separator: ", ")
            return .failure(RunLockError(
                "timed out waiting for run lock \(names) after \(String(format: "%.1f", waited))s"
                + " (limit \(String(format: "%.0f", limit))s)"))
        case .failed(let reason):
            return .failure(RunLockError("could not take run lock: \(reason)"))
        }
    }
}
