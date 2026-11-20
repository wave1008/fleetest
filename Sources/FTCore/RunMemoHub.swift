// RunMemoHub.swift
// run メモ(DR-208)の発行元の側: マシンをまたぐ run の親(DeviceMachineRunner / ApiRunMachineFanout / MultiTargetRunner)が持つ正本。
// 子(各マシンの `fleetest run` / `api run`)の stdout に出た書き込みを届いた順に通し番号を振り、
// 起動を知らせた全部の子へ(書いた子にも)stdin で配り返す。履歴は run の間ずっと持つ(後から起動を知らせた子へ再送する)。
// - 配りは臨界区間の中で `send` を直接呼ぶ(通し番号を振る区間の中なので、どの子へも通し番号の順に積まれる。別のキューを挟まない =
//   子ごとの書き手の列だけで順序が決まる)。`send` は**呼び手をブロックしない・hub へ再入しない**こと
//   (本番は子ごとの `ChildStdinWriter` の非同期のキューへ積むだけ)
// - 子は通し番号で並べ直すので、再送・順序の入れ替わりは害にならない(RunMemoLedger)
// - 開始の行(RR-8.4): 子は開始の行を受けるまでシナリオを流し始めない。各子について「起動の知らせ(memoHello)を受けた」と
//   「開始の決定が出た」の**遅いほう**で、その子の列へ「履歴 → 開始(または取りやめ)」の順に積む(臨界区間の中。join と同じ)

import Foundation

public final class RunMemoHub: Sendable {
    /// 子の鍵 = (対象, エントリ番号)。複数の対象を1つの正本にまとめるとき、エントリ番号だけだと別の対象の同じ番号の子と混ざる。
    /// 対象が1つの呼び手は `target` に "" を使う
    public struct Child: Hashable, Comparable, Sendable {
        public let target: String
        public let entry: Int

        public init(target: String, entry: Int) {
            self.target = target
            self.entry = entry
        }

        public static func < (lhs: Child, rhs: Child) -> Bool {
            (lhs.target, lhs.entry) < (rhs.target, rhs.entry)
        }
    }

    /// 開始の決め方。`startOnHello` = 起動の知らせを受けたらすぐ開始(開始を決める呼び出しを配線していない呼び手の既定。
    /// 子が開始を待って止まらないための形)・`awaitDecision` = `decideGate` が呼ばれるまで保留する
    public enum GateMode: Sendable { case startOnHello, awaitDecision }

    /// 子(鍵)の stdin へ書く行。1回の呼び出し = 1件ぶんの断片(まとめて1回の write にする)
    public typealias Send = @Sendable (_ child: Child, _ lines: [String]) -> Void

    private struct Entry: Sendable {
        let seq: Int
        let src: String
        let lid: Int
        let pieces: [String]
    }

    private struct State {
        var seq = 0
        var history: [Entry] = []
        /// (子, 書いたプロセス, 書き込み番号) → 断片の番号 → 断片(全部そろうまで)
        var assembling: [String: [Int: String]] = [:]
        /// 開始の行を送った子(終わった子は外す)。確定した書き込みの配り先
        var joined: Set<Child> = []
        /// 起動を知らせたが、開始の決定をまだ受けていない子
        var waiting: Set<Child> = []
        /// 決定済みの開始・取りやめ(最初の1回だけ有効)
        var decided: WorkQueueProtocol.StartSignal?
        var seeded = 0
    }

    /// `beforeRun` の書き込み(`seedConfirmed`)の発信元の印。子の印(8桁の16進)と衝突しない
    static let seedSource = "run-hook"

    private let state = LockedValue(State())
    private let send: Send
    private let mode: GateMode

    public init(mode: GateMode, send: @escaping Send) {
        self.mode = mode
        self.send = send
    }

    /// 確定した書き込みの数(テスト・診断用)
    public var confirmedCount: Int { state.withLock { $0.history.count } }

    /// 子の stdout の1行。run メモの行(`memoHello` / `memo`)なら消費して true、それ以外は false(呼び手が続きを判断する)。
    /// 親 → 子の行が端末のエコーで戻ってきた分(seq 付きの断片・開始・取りやめ)は消費だけして読まない
    @discardableResult
    public func receive(line: String, from child: Child) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        if WorkQueueProtocol.decodeMemoHello(trimmed) != nil {
            join(child)
            return true
        }
        if WorkQueueProtocol.decodeStartSignal(trimmed) != nil { return true }
        guard let piece = WorkQueueProtocol.decodeMemoPiece(trimmed) else { return false }
        guard piece.seq == nil, piece.n >= 1, piece.n <= RunMemoWire.maxPieces,
              (0..<piece.n).contains(piece.i) else { return true }
        admit(piece, from: child)
        return true
    }

    /// `beforeRun` が出した書き込みを確定分として先に入れる(通し番号の先頭)。**中身が読めるものだけ**番号を振る
    /// (読めない断片の組に番号を振ると、受け手が捨てて番号が抜ける)。値が大きすぎて共有できないものも入れない。
    /// 開始の決定の前に呼ぶ(後に呼んでも起動済みの子へ配る)。入れた件数を返す
    @discardableResult
    public func seedConfirmed(_ ops: [RunMemoOp]) -> Int {
        ops.reduce(0) { $0 + (commit($1) == nil ? 0 : 1) }
    }

    /// 1件を確定分として入れ、**振った通し番号**を返す(読めない・大きすぎて共有できないものは入れずに nil)。
    /// ロックの中の書き込み(`RunMemoHubLockBackend`)が、書いたマシンの次のシナリオへ配りの戻りを待たずに見せるために使う
    @discardableResult
    public func commit(_ op: RunMemoOp) -> Int? {
        let send = self.send
        return state.withLock { s -> Int? in
            let pieces = RunMemoWire.pieces(for: op)
            guard pieces.count <= RunMemoWire.maxPieces, RunMemoWire.op(fromPieces: pieces) == op else { return nil }
            s.seeded += 1
            s.seq += 1
            let confirmed = Entry(seq: s.seq, src: Self.seedSource, lid: s.seeded, pieces: pieces)
            s.history.append(confirmed)
            let lines = Self.lines(confirmed)
            for target in s.joined.sorted() { send(target, lines) }
            return s.seq
        }
    }

    /// 開始(または取りやめ)を全部の子へ決める。保留していた子へ「履歴 → 開始(取りやめ)」を積み、以後に起動を知らせた子へは
    /// 知らせを受けた時点ですぐ流す。**最初の1回だけ有効**(2回目以降は無視する)
    public func decideGate(_ signal: WorkQueueProtocol.StartSignal) {
        state.withLock { s in
            guard s.decided == nil else { return }
            s.decided = signal
            for child in s.waiting.sorted() { openGate(child, signal, &s) }
            s.waiting.removeAll()
        }
    }

    /// 確定済みの履歴を通し番号の順に畳んだ最終の値(afterRun が読む。全マシンの書き込みがそろった後に呼ぶ)
    public func finalValues() -> [String: [String]] {
        state.withLock { s in
            var ledger = RunMemoLedger()
            for entry in s.history {
                if let op = RunMemoWire.op(fromPieces: entry.pieces) { ledger.confirm(seq: entry.seq, op: op, ownLid: nil) }
            }
            return ledger.view()
        }
    }

    /// 子が終わった。以後は配らない
    public func entryExited(_ child: Child) {
        state.withLock { s in
            s.joined.remove(child)
            s.waiting.remove(child)
        }
    }

    private func admit(_ piece: WorkQueueProtocol.MemoPiece, from child: Child) {
        let key = "\(child.target)#\(child.entry)#\(piece.src)#\(piece.lid)"
        let send = self.send
        state.withLock { s in
            var got = s.assembling[key] ?? [:]
            got[piece.i] = piece.d
            guard got.count == piece.n else {
                s.assembling[key] = got
                return
            }
            s.assembling.removeValue(forKey: key)
            let assembled = (0..<piece.n).map { got[$0] ?? "" }
            guard RunMemoWire.op(fromPieces: assembled) != nil else { return }
            s.seq += 1
            let confirmed = Entry(seq: s.seq, src: piece.src, lid: piece.lid, pieces: assembled)
            s.history.append(confirmed)
            let lines = Self.lines(confirmed)
            for target in s.joined.sorted() { send(target, lines) }
        }
    }

    private func join(_ child: Child) {
        state.withLock { s in
            if let decided = s.decided {
                openGate(child, decided, &s)
            } else if mode == .startOnHello {
                s.decided = .start
                // 決定は全部の子に効く(この子が最初の知らせ = 保留中の子は居ない)
                openGate(child, .start, &s)
            } else {
                s.waiting.insert(child)
            }
        }
    }

    /// 臨界区間の中で、その子の列へ「履歴 → 開始(取りやめ)」を積む。取りやめの子には履歴を送らない(1本も流さず終わる)
    private func openGate(_ child: Child, _ signal: WorkQueueProtocol.StartSignal, _ s: inout State) {
        let send = self.send
        var lines: [String] = []
        if case .start = signal {
            s.joined.insert(child)
            lines = s.history.flatMap { Self.lines($0) }
        }
        lines.append(WorkQueueProtocol.encode(signal))
        send(child, lines)
    }

    private static func lines(_ entry: Entry) -> [String] {
        entry.pieces.enumerated().map { piece in
            WorkQueueProtocol.encode(WorkQueueProtocol.MemoPiece(
                src: entry.src, lid: entry.lid, seq: entry.seq, i: piece.offset, n: entry.pieces.count, d: piece.element))
        }
    }
}
