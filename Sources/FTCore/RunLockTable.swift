// RunLockTable.swift
// run 全体のロック(`withExclusiveLock` / `withSharedLock`。RR-8.5・DR-210)の判定。**I/O を持たない純粋な型**:
// サーバー(`RunLockServer`)とテストが同じ型を使う。操作はどれも「送るべき渡し・失敗」を返すだけで、書くのは呼び手。
//
// 規則:
//  - キーごとに先着順の待ち行列。共有は共有どうしで重ねて持てるが、**排他を待つ人が行列にいる間は新しい共有を渡さない**
//    (行列の先頭だけが渡される = 共有の後ろの排他が飢えない)
//  - 1回の要求のキーは呼び手が**名前の順に並べて重複を除いて**渡す。**1つずつ順に取り、取った分は持ったまま次を待つ**
//    (全員が同じ順でしか待たないので待ちの輪ができない)。全部持った時点で「渡し」
//  - 持ち主不明(リモート越しの接続切れ)は第2b段 = ここには置かない

import Foundation

public struct RunLockTable: Sendable {
    public enum Mode: String, Codable, Sendable { case shared, exclusive }

    /// 要求の持ち主 = (接続, 接続の中の要求番号)
    public struct Owner: Hashable, Sendable {
        public let connection: Int
        public let requestID: Int
        public init(connection: Int, requestID: Int) {
            self.connection = connection
            self.requestID = requestID
        }
    }

    public struct Failure: Equatable, Sendable {
        public let owner: Owner
        public let reason: String
    }

    /// 1回の操作で呼び手が送るべきもの
    public struct Effects: Equatable, Sendable {
        public var grants: [Owner] = []
        public var failures: [Failure] = []
        public static let none = Effects()
    }

    private struct Request {
        let keys: [String]
        let mode: Mode
        /// 持ち終えたキーの数(keys[0..<held] を持つ。held == keys.count で渡し済み)
        var held = 0
        var isGranted: Bool { held == keys.count }
    }

    private struct KeyState {
        var holders: [Owner] = []
        var holderMode: Mode = .shared
        var queue: [Owner] = []
    }

    private var requests: [Owner: Request] = [:]
    /// キーの同一性は UTF-8 のバイト列(`String` の等価は Unicode の正規化に依る = 合成済みと分解形が同じキーになってしまう。
    /// 並べ方と同じ規則 = `RunLockKeys`)
    private var keyStates: [[UInt8]: KeyState] = [:]
    private var interrupted = false

    public init() {}

    // MARK: 操作

    /// `keys` は名前の順(UTF-8 のバイト列)に並べて重複を除いたもの。**同じ (接続, 番号) の二重の要求は失敗にする**
    public mutating func acquire(connection: Int, requestID: Int, keys: [String], mode: Mode) -> Effects {
        let owner = Owner(connection: connection, requestID: requestID)
        if interrupted { return Effects(failures: [Failure(owner: owner, reason: Self.interruptedReason)]) }
        if requests[owner] != nil {
            return Effects(failures: [Failure(owner: owner, reason: "duplicate lock request \(requestID)")])
        }
        requests[owner] = Request(keys: keys, mode: mode)
        if keys.isEmpty { return Effects(grants: [owner]) }
        keyStates[Array(keys[0].utf8), default: KeyState()].queue.append(owner)
        return pump()
    }

    /// 待っている要求は行列から外し、取っていた分を放す。**渡し済みの取り消しとのすれ違いは「外す」として扱う**
    /// (クライアントは失敗として抜けたので、渡した分を持ち続けない)。知らない要求は何もしない
    public mutating func cancel(connection: Int, requestID: Int) -> Effects {
        remove(Owner(connection: connection, requestID: requestID))
    }

    /// 渡し済みの要求を放す。待っている途中の「外す」は取り消しと同じ
    public mutating func release(connection: Int, requestID: Int) -> Effects {
        remove(Owner(connection: connection, requestID: requestID))
    }

    public struct Closed: Equatable, Sendable {
        /// 呼び手が接続の相手のプロセスの終わりを待ってから `release` する要求(渡し済み)
        public var held: [Owner] = []
        public var effects = Effects.none
    }

    /// 接続が「外す」なしで閉じた。待っていただけの要求は消す(取っていた分も放す)。**渡し済みの要求は残す**
    /// —— 相手のプロセスがまだ臨界区間を走っているかもしれないので、終わりを確かめた呼び手が `release` で外す
    public mutating func connectionClosed(_ connection: Int) -> Closed {
        var closed = Closed()
        let mine = requests.filter { $0.key.connection == connection }
        for (owner, request) in mine.sorted(by: { $0.key.requestID < $1.key.requestID }) {
            if request.isGranted {
                closed.held.append(owner)
            } else {
                detach(owner)
            }
        }
        closed.effects = pump()
        return closed
    }

    /// 中断: 待っている要求を全部失敗にし(取っていた分は放す)、**以後の新しい要求もすぐ失敗させる**。渡し済みは残す
    public mutating func interrupt() -> Effects {
        interrupted = true
        // 先に全部外してから失敗にする(途中の放しで別の待ちが渡されて、渡しと失敗が同じ要求に重ならないように)
        var effects = Effects.none
        let waiting = requests.filter { !$0.value.isGranted }.map(\.key)
        for owner in waiting.sorted(by: { ($0.connection, $0.requestID) < ($1.connection, $1.requestID) }) {
            detach(owner)
            effects.failures.append(Failure(owner: owner, reason: Self.interruptedReason))
        }
        return effects
    }

    public static let interruptedReason = "the run was interrupted"

    // MARK: 照会

    /// そのキーを持っている要求(渡し済みでなくても、そのキーまで取れていれば含む)
    public func holders(of key: String) -> [Owner] { keyStates[Array(key.utf8)]?.holders ?? [] }

    public func queue(of key: String) -> [Owner] { keyStates[Array(key.utf8)]?.queue ?? [] }

    /// 待っている要求が今待っているキー(渡し済み・知らない要求は nil)
    public func waitingKey(of owner: Owner) -> String? {
        guard let request = requests[owner], !request.isGranted else { return nil }
        return request.keys[request.held]
    }

    public func isGranted(_ owner: Owner) -> Bool { requests[owner]?.isGranted ?? false }

    public var requestCount: Int { requests.count }

    // MARK: 内部

    private mutating func remove(_ owner: Owner) -> Effects {
        guard detach(owner) else { return .none }
        return pump()
    }

    /// 要求を消して、行列とキーの持ち主から外す(渡しは進めない)。知らない要求は false
    @discardableResult
    private mutating func detach(_ owner: Owner) -> Bool {
        guard let request = requests.removeValue(forKey: owner) else { return false }
        if !request.isGranted {
            let waitingOn = request.keys[request.held]
            keyStates[Array(waitingOn.utf8)]?.queue.removeAll { $0 == owner }
        }
        for key in request.keys.prefix(request.held) {
            keyStates[Array(key.utf8)]?.holders.removeAll { $0 == owner }
        }
        return true
    }

    /// 渡せるものがなくなるまで行列の先頭を進める。キーを名前の順に回して結果を決定的にする
    private mutating func pump() -> Effects {
        var effects = Effects.none
        var progressed = true
        while progressed {
            progressed = false
            for key in keyStates.keys.sorted(by: { $0.lexicographicallyPrecedes($1) }) {
                guard var state = keyStates[key], let head = state.queue.first,
                      let request = requests[head], canGrant(request.mode, state) else { continue }
                state.queue.removeFirst()
                state.holders.append(head)
                state.holderMode = request.mode
                keyStates[key] = state
                var advanced = request
                advanced.held += 1
                requests[head] = advanced
                if advanced.isGranted {
                    effects.grants.append(head)
                } else {
                    keyStates[Array(advanced.keys[advanced.held].utf8), default: KeyState()].queue.append(head)
                }
                progressed = true
            }
            keyStates = keyStates.filter { !($0.value.holders.isEmpty && $0.value.queue.isEmpty) }
        }
        return effects
    }

    private func canGrant(_ mode: Mode, _ state: KeyState) -> Bool {
        if state.holders.isEmpty { return true }
        return mode == .shared && state.holderMode == .shared
    }
}
