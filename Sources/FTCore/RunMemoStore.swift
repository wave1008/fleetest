// RunMemoStore.swift
// run メモ(DR-208 の writeRunMemo / readRunMemo / clearRunMemo)の親側の持ち主。
// マシンをまたぐ run では、各マシンの親が自分の書き込みをすぐ反映し(`pending`)、発行元(`RunMemoHub`)が届いた順に
// 振った通し番号つきで全マシンへ配り返した分(`confirmed`)で並べ直す。**排他は持たない**:
// 保証するのは「書き込みは消えない・同じマシンでは自分の書き込みが次のシナリオから見える・最後は全マシンで同じ順にそろう」まで。
// 読んでから書く間の割り込みと同じキーへの同時書き込みの勝ち負けは保証しない。

import Foundation

public enum RunMemoOp: Equatable, Sendable {
    case write(key: String, value: String)
    /// その時点までの確定分と、自分の未確定分を消す
    case clear
}

/// 並べ方だけの純粋なロジック。見える履歴 = 確定分を通し番号の順に畳み、その後ろに自分の未確定分を書いた順に畳んだもの
/// (`clear` も同じ畳み込みの1件)。確定が全部届けば未確定は空になり、全マシンの畳み込みが同じ列になる
public struct RunMemoLedger: Sendable {
    private var confirmed: [Int: RunMemoOp] = [:]
    private var pending: [(lid: Int, op: RunMemoOp)] = []
    private var nextLid = 1

    public init() {}

    /// 自分の書き込みを未確定として積み、発行元へ上げるときの番号(lid)を返す。
    /// `clear` は手前の未確定を全部消すので残さない(確定すれば発行元の順で同じ効果になる)
    public mutating func addLocal(_ op: RunMemoOp) -> Int {
        let lid = nextLid
        nextLid += 1
        if op == .clear { pending.removeAll() }
        pending.append((lid: lid, op: op))
        return lid
    }

    /// 発行元から戻った確定。`ownLid` = 自分が上げた書き込みの戻り(未確定から外す)。
    /// 通し番号が既に確定済み(再送・履歴の再送)なら何も足さず false
    @discardableResult
    public mutating func confirm(seq: Int, op: RunMemoOp, ownLid: Int?) -> Bool {
        if let ownLid { pending.removeAll { $0.lid == ownLid } }
        guard confirmed[seq] == nil else { return false }
        confirmed[seq] = op
        return true
    }

    public var pendingCount: Int { pending.count }
    public var confirmedCount: Int { confirmed.count }

    public func view() -> [String: [String]] {
        var memo: [String: [String]] = [:]
        func apply(_ op: RunMemoOp) {
            switch op {
            case .write(let key, let value): memo[key, default: []].append(value)
            case .clear: memo.removeAll()
            }
        }
        for seq in confirmed.keys.sorted() { if let op = confirmed[seq] { apply(op) } }
        for entry in pending { apply(entry.op) }
        return memo
    }
}

public final class RunMemoStore: Sendable {
    private let ledger = LockedValue(RunMemoLedger())
    private let link: RunMemoLink?

    /// `link` = マシンをまたぐ run の子で発行元とつながっている通り道(nil = このプロセスだけで完結)
    public init(link: RunMemoLink? = nil) {
        self.link = link
        link?.setReceiver { [weak self] confirmed in self?.confirm(confirmed) }
    }

    public func snapshot() -> [String: [String]] { ledger.withLock { $0.view() } }

    public func write(key: String, value: String) { record(.write(key: key, value: value)) }

    public func clear() { record(.clear) }

    private func record(_ op: RunMemoOp) {
        let lid = ledger.withLock { $0.addLocal(op) }
        link?.publish(lid: lid, op: op)
    }

    private func confirm(_ confirmed: RunMemoLink.Confirmed) {
        let own = confirmed.src == link?.source ? confirmed.lid : nil
        _ = ledger.withLock { $0.confirm(seq: confirmed.seq, op: confirmed.op, ownLid: own) }
    }
}

/// 発行元との行の符号化(`{"ftWork":{...}}` の1行。ssh -tt を通る)。
/// **親 → 子の stdin は端末の行規律に載り、1行が約 1024 バイトを超えると切れる**ので、値は JSON を base64 にして
/// 短い断片に割り、断片ごとに1行にする(子 → 親は端末を通らないが、同じ符号化で揃える)
public enum RunMemoWire {
    /// 1行の断片の base64 文字数。根拠: 行全体(印・src・lid・seq・i・n を含めて約 100 バイト)を 1024 バイトの半分ほどに収める
    public static let pieceCharacters = 480
    /// 1件の上限(約 1.4 MB)。超えた値はマシンをまたいで共有できない(`RunMemoLink.publish` が1行言って自分のマシンだけに残す)
    public static let maxPieces = 4096

    private struct Payload: Codable {
        var k: String?
        var v: String?
        var c: Bool?
    }

    public static func pieces(for op: RunMemoOp) -> [String] {
        let payload: Payload
        switch op {
        case .write(let key, let value): payload = Payload(k: key, v: value, c: nil)
        case .clear: payload = Payload(k: nil, v: nil, c: true)
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let text = ((try? encoder.encode(payload)) ?? Data()).base64EncodedString()
        var pieces: [String] = []
        var index = text.startIndex
        while index < text.endIndex {
            let end = text.index(index, offsetBy: pieceCharacters, limitedBy: text.endIndex) ?? text.endIndex
            pieces.append(String(text[index..<end]))
            index = end
        }
        return pieces.isEmpty ? [""] : pieces
    }

    /// 壊れた断片の組は nil(読み捨てる)
    public static func op(fromPieces pieces: [String]) -> RunMemoOp? {
        guard let data = Data(base64Encoded: pieces.joined()),
              let payload = try? JSONDecoder().decode(Payload.self, from: data) else { return nil }
        if payload.c == true { return .clear }
        if let key = payload.k, let value = payload.v { return .write(key: key, value: value) }
        return nil
    }
}

/// 子(マシンをまたぐ run の各マシンの `fleetest run` / `api run`)の側の通り道: 書き込みを stdout の行で発行元へ上げ、
/// 発行元が stdin へ配った確定を受け取って `RunMemoStore` へ渡す
public final class RunMemoLink: Sendable {
    public struct Confirmed: Sendable {
        public let seq: Int
        public let src: String
        public let lid: Int
        public let op: RunMemoOp
    }

    /// このプロセスの印。発行元が配り返した確定のうち自分の書き込みを見分ける(プロセスごとに1つ)
    public let source: String
    private let send: @Sendable (String) -> Void
    private let warn: @Sendable (String) -> Void
    /// 通し番号 → 断片の番号 → 断片(全部そろうまで)
    private let assembling = LockedValue<[Int: [Int: String]]>([:])
    private let receiver = LockedValue<(@Sendable (Confirmed) -> Void)?>(nil)

    public init(source: String = RunMemoLink.makeSource(),
                send: @escaping @Sendable (String) -> Void,
                warn: @escaping @Sendable (String) -> Void = { ConsoleOut.err($0) }) {
        self.source = source
        self.send = send
        self.warn = warn
    }

    public static func makeSource() -> String { String(UUID().uuidString.prefix(8)).lowercased() }

    func setReceiver(_ handler: @escaping @Sendable (Confirmed) -> Void) {
        receiver.withLock { $0 = handler }
    }

    /// 自分の書き込みを発行元へ上げる(1回の `send` に断片の行をまとめる = 他の出力が間に挟まらない)
    public func publish(lid: Int, op: RunMemoOp) {
        let pieces = RunMemoWire.pieces(for: op)
        guard pieces.count <= RunMemoWire.maxPieces else {
            warn("⚠️ a run memo value is too large to share across machines; it stays on this machine only")
            return
        }
        let lines = pieces.enumerated().map { piece in
            WorkQueueProtocol.encode(WorkQueueProtocol.MemoPiece(
                src: source, lid: lid, seq: nil, i: piece.offset, n: pieces.count, d: piece.element))
        }
        send(lines.joined(separator: "\n"))
    }

    /// 起動を発行元へ知らせる。発行元はそれまでの履歴をこの子へ送る(子の stdin が読める前に流れた分を取りこぼさない)
    public func hello() {
        send(WorkQueueProtocol.encode(WorkQueueProtocol.MemoHello(src: source)))
    }

    /// stdin の1行。確定の断片でなければ読み捨てる。同じ通し番号の再送は `RunMemoLedger.confirm` が弾く
    public func receive(line: String) {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let piece = WorkQueueProtocol.decodeMemoPiece(trimmed), let seq = piece.seq,
              piece.n >= 1, piece.n <= RunMemoWire.maxPieces, (0..<piece.n).contains(piece.i) else { return }
        let complete: [String]? = assembling.withLock { assembling in
            var got = assembling[seq] ?? [:]
            got[piece.i] = piece.d
            guard got.count == piece.n else {
                assembling[seq] = got
                return nil
            }
            assembling.removeValue(forKey: seq)
            return (0..<piece.n).compactMap { got[$0] }
        }
        guard let complete, complete.count == piece.n, let op = RunMemoWire.op(fromPieces: complete) else { return }
        receiver.value?(Confirmed(seq: seq, src: piece.src, lid: piece.lid, op: op))
    }
}
