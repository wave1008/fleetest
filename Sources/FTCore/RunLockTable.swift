// RunLockTable.swift
// run 全体のロック(`withExclusiveLock`。RR-8.5・DR-210)の判定。**I/O を持たない純粋な型**:
// サーバー(`RunLockServer`)とテストが同じ型を使う。操作はどれも「送るべき渡し・失敗」を返すだけで、書くのは呼び手。
//
// 規則:
//  - キーごとに先着順の待ち行列(先頭だけが渡される)
//  - 1回の要求のキーは呼び手が**名前の順に並べて重複を除いて**渡す。**1つずつ順に取り、取った分は持ったまま次を待つ**
//    (全員が同じ順でしか待たないので待ちの輪ができない)。全部持った時点で「渡し」
//  - **持ち主不明**(リモートの待ち受けで受けた接続が「外す」なしで閉じた = ssh の切断でも閉じ、切れた先でまだ臨界区間を走っていることがある):
//    **そのキーの待ちも新しい要求もすぐ失敗**にする。向こうの run の終わりを確かめた呼び手が `releaseUnknown` で外し、そのキーは**印**を持つ
//    (以後そのキーを渡すとき `Effects.lossMarked` に載せる = 前の持ち主の書き込みが欠けているかもしれない注記の材料)

import Foundation

public struct RunLockTable: Sendable {
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
        /// 渡しのうち、印のあるキー(持ち主不明から外したキー)を含むもの → そのキー
        public var lossMarked: [Owner: [String]] = [:]
        public static let none = Effects()
    }

    private struct Request {
        let keys: [String]
        /// 持ち終えたキーの数(keys[0..<held] を持つ。held == keys.count で渡し済み)
        var held = 0
        var isGranted: Bool { held == keys.count }
        /// 持ち主不明にした範囲(渡し済みの要求だけが持つ)。`scope` = 1回のディスパッチ(= リモートの待ち受け1つ)の識別子・
        /// `machine` = 文言に出す機械の名前。**外せるのは同じ scope の知らせだけ**: 機械で括ると、同じ機械の別のディスパッチ
        /// (前の対象の ssh が切れて不明のまま残った分)を、後の対象の「run が終わった」で外してしまう(二重に持つ)
        var unknown: (scope: String, machine: String)?
    }

    private struct KeyState {
        var holders: [Owner] = []
        var queue: [Owner] = []
    }

    private var requests: [Owner: Request] = [:]
    /// キーの同一性は UTF-8 のバイト列(`String` の等価は Unicode の正規化に依る = 合成済みと分解形が同じキーになってしまう。
    /// 並べ方と同じ規則 = `RunLockKeys`)
    private var keyStates: [[UInt8]: KeyState] = [:]
    private var interrupted = false
    /// 持ち主不明から外したキー(run の終わりまで持つ。バイト列)
    private var marks: Set<[UInt8]> = []

    public init() {}

    // MARK: 操作

    /// `keys` は名前の順(UTF-8 のバイト列)に並べて重複を除いたもの。**同じ (接続, 番号) の二重の要求は失敗にする**
    public mutating func acquire(connection: Int, requestID: Int, keys: [String]) -> Effects {
        let owner = Owner(connection: connection, requestID: requestID)
        if interrupted { return Effects(failures: [Failure(owner: owner, reason: Self.interruptedReason)]) }
        if requests[owner] != nil {
            return Effects(failures: [Failure(owner: owner, reason: "duplicate lock request \(requestID)")])
        }
        requests[owner] = Request(keys: keys)
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
                if request.unknown == nil { closed.held.append(owner) }
            } else {
                detach(owner)
            }
        }
        closed.effects = pump()
        return closed
    }

    /// その接続の渡し済みの要求を「持ち主不明」にする(接続の相手の機械 = `machine`)。待っているだけの要求は外す。
    /// 呼び手は、リモートの待ちの接続が閉じたとき(または ssh が終わったとき)に呼ぶ。待っている要求のうち、不明の排他に当たるものは失敗で返る
    public mutating func markUnknown(connection: Int, scope: String, machine: String) -> Effects {
        for (owner, request) in requests.filter({ $0.key.connection == connection }) {
            if request.isGranted {
                requests[owner]?.unknown = (scope, machine)
            } else {
                detach(owner)
            }
        }
        return pump()
    }

    /// 持ち主不明のキーの数(その範囲の不明の要求が持つキーの延べ数。0 = 不明は無い)
    public func unknownKeyCount(scope: String) -> Int {
        requests.values.filter { $0.unknown?.scope == scope }.reduce(0) { $0 + $1.keys.count }
    }

    /// 向こうの run の終わりを確かめた: **その範囲(1回のディスパッチ)の**不明の要求を外し、持っていたキーに印を付ける。
    /// 待っていた要求に渡す。戻り値の2つ目 = 印を付けたキーの数
    public mutating func releaseUnknown(scope: String) -> (effects: Effects, keys: Int) {
        var keys = 0
        for (owner, request) in requests.filter({ $0.value.unknown?.scope == scope }) {
            for key in request.keys { marks.insert(Array(key.utf8)) }
            keys += request.keys.count
            detach(owner)
        }
        return (pump(), keys)
    }

    /// その接続の要求を全部外す(シナリオのプロセスの終わりを親が見届けた)。**まだ渡し済み(持っていた)の要求のキーには印を付ける**
    /// (放さずに終わった = 臨界区間の途中で終わった可能性がある。持ち主不明から外す場合も同じ)。待っていた要求は印なしで外す
    public mutating func releaseAll(connection: Int) -> Effects {
        for (owner, request) in requests.filter({ $0.key.connection == connection }) {
            if request.isGranted { for key in request.keys { marks.insert(Array(key.utf8)) } }
            detach(owner)
        }
        return pump()
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
                guard var state = keyStates[key], let head = state.queue.first, let request = requests[head] else { continue }
                if let machine = unknownMachineBlocking(state) {
                    detach(head)
                    effects.failures.append(Failure(owner: head, reason: Self.unknownOwnerReason(
                        key: String(decoding: key, as: UTF8.self), machine: machine)))
                    progressed = true
                    continue
                }
                guard state.holders.isEmpty else { continue }
                state.queue.removeFirst()
                state.holders.append(head)
                keyStates[key] = state
                var advanced = request
                advanced.held += 1
                requests[head] = advanced
                if advanced.isGranted {
                    effects.grants.append(head)
                    let marked = advanced.keys.filter { marks.contains(Array($0.utf8)) }
                    if !marked.isEmpty { effects.lossMarked[head] = marked }
                } else {
                    keyStates[Array(advanced.keys[advanced.held].utf8), default: KeyState()].queue.append(head)
                }
                progressed = true
            }
            keyStates = keyStates.filter { !($0.value.holders.isEmpty && $0.value.queue.isEmpty) }
        }
        return effects
    }

    /// そのキーに持ち主不明の持ち主が居て、この要求を断るか(居る機械の名前を返す)
    private func unknownMachineBlocking(_ state: KeyState) -> String? {
        state.holders.compactMap { requests[$0]?.unknown?.machine }.first
    }

    public static func unknownOwnerReason(key: String, machine: String) -> String {
        "run lock \"\(key)\" cannot be taken: its owner on machine \(machine) lost its connection"
            + " (it may still be running there, so the lock stays unavailable until that machine's run has ended)"
    }
}
