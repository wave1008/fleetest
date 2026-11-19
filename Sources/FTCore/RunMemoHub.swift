// RunMemoHub.swift
// run メモ(DR-208)の発行元の側: マシンをまたぐ run の親(DeviceMachineRunner / ApiRunMachineFanout / MultiTargetRunner の
// 対象ごと)が持つ正本。子(各マシンの `fleetest run` / `api run`)の stdout に出た書き込みを届いた順に通し番号を振り、
// 起動を知らせた全部の子へ(書いた子にも)stdin で配り返す。履歴は run の間ずっと持つ(後から起動を知らせた子へ再送する)。
// - 配りは1本の直列キューへ積む(送り先の書き込みが詰まっても、受け付ける側の読み取りスレッドを止めない)。
//   通し番号を振る臨界区間の中で積むので、どの子へも通し番号の順に書かれる
// - 子は通し番号で並べ直すので、再送・順序の入れ替わりは害にならない(RunMemoLedger)

import Foundation

public final class RunMemoHub: Sendable {
    /// 子(エントリ番号)の stdin へ書く行。1回の呼び出し = 1件ぶんの断片(まとめて1回の write にする)
    public typealias Send = @Sendable (_ entry: Int, _ lines: [String]) -> Void

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
        /// 起動を知らせた子(終わった子は外す)
        var joined: Set<Int> = []
    }

    private let state = LockedValue(State())
    private let send: Send
    private let queue = DispatchQueue(label: "fleetest.run-memo-hub")

    public init(send: @escaping Send) { self.send = send }

    /// 確定した書き込みの数(テスト・診断用)
    public var confirmedCount: Int { state.withLock { $0.history.count } }

    /// 子の stdout の1行。run メモの行(`memoHello` / `memo`)なら消費して true、それ以外は false(呼び手が続きを判断する)。
    /// 親 → 子の行が端末のエコーで戻ってきた分(seq 付き)は消費だけして読まない
    @discardableResult
    public func receive(line: String, fromEntry entry: Int) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        if WorkQueueProtocol.decodeMemoHello(trimmed) != nil {
            join(entry: entry)
            return true
        }
        guard let piece = WorkQueueProtocol.decodeMemoPiece(trimmed) else { return false }
        guard piece.seq == nil, piece.n >= 1, piece.n <= RunMemoWire.maxPieces,
              (0..<piece.n).contains(piece.i) else { return true }
        admit(piece, fromEntry: entry)
        return true
    }

    /// 積んだ配りが全部書き終わるまで待つ(テスト用)
    public func flush() { queue.sync {} }

    /// 子が終わった。以後は配らない
    public func entryExited(_ entry: Int) {
        _ = state.withLock { $0.joined.remove(entry) }
    }

    private func admit(_ piece: WorkQueueProtocol.MemoPiece, fromEntry entry: Int) {
        let key = "\(entry)#\(piece.src)#\(piece.lid)"
        let send = self.send
        state.withLock { s in
            var got = s.assembling[key] ?? [:]
            got[piece.i] = piece.d
            guard got.count == piece.n else {
                s.assembling[key] = got
                return
            }
            s.assembling.removeValue(forKey: key)
            s.seq += 1
            let confirmed = Entry(seq: s.seq, src: piece.src, lid: piece.lid,
                                  pieces: (0..<piece.n).map { got[$0] ?? "" })
            s.history.append(confirmed)
            let lines = Self.lines(confirmed)
            for target in s.joined.sorted() {
                queue.async { send(target, lines) }
            }
        }
    }

    private func join(entry: Int) {
        let send = self.send
        state.withLock { s in
            s.joined.insert(entry)
            guard !s.history.isEmpty else { return }
            let lines = s.history.flatMap { Self.lines($0) }
            queue.async { send(entry, lines) }
        }
    }

    private static func lines(_ entry: Entry) -> [String] {
        entry.pieces.enumerated().map { piece in
            WorkQueueProtocol.encode(WorkQueueProtocol.MemoPiece(
                src: entry.src, lid: entry.lid, seq: entry.seq, i: piece.offset, n: entry.pieces.count, d: piece.element))
        }
    }
}
