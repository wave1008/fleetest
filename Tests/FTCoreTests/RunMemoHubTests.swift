// run メモ(DR-208)の発行元(RunMemoHub)と、子の側(RunMemoLink + RunMemoStore)をつないだ配りのテスト。
// 配線は行の文字列だけ(子 → 発行元 = 子の stdout の行、発行元 → 子 = 子の stdin の行)で、プロセスもパイプも使わない。

import XCTest
@testable import FTCore

final class RunMemoHubTests: XCTestCase {

    /// 発行元と複数の「マシン」(子の側の store + link)を行の受け渡しだけでつなぐ
    private final class Cluster: @unchecked Sendable {
        // @unchecked の根拠: links は構築時だけ書き、hub の送りは hub の直列キューの上で読む。deliver は LockedValue
        let hub: RunMemoHub
        private(set) var stores: [RunMemoStore] = []
        private(set) var links: [RunMemoLink] = []
        /// false の間、発行元 → 子の行を止めて溜める(確定が届く前の見え方を確かめる)
        private let held = LockedValue<[(entry: Int, lines: [String])]>([])
        private let holding = LockedValue(false)
        let sentLines = LockedValue<[(entry: Int, lines: [String])]>([])

        init(machines: Int, mode: RunMemoHub.GateMode = .startOnHello) {
            let box = Box()
            hub = RunMemoHub(mode: mode, send: { child, lines in box.send(child.entry, lines) })
            for entry in 0..<machines {
                let link = RunMemoLink(
                    source: "m\(entry)",
                    send: { [hub] text in
                        for line in text.split(separator: "\n") { hub.receive(line: String(line), from: RunMemoHub.Child(target: "", entry: entry)) }
                    },
                    warn: { _ in })
                links.append(link)
                stores.append(RunMemoStore(link: link))
            }
            box.cluster = self
        }

        private final class Box: @unchecked Sendable {
            // @unchecked の根拠: cluster は init の最後に1回だけ書き、以後は読むだけ
            weak var cluster: Cluster?
            func send(_ entry: Int, _ lines: [String]) { cluster?.deliver(entry, lines) }
        }

        private func deliver(_ entry: Int, _ lines: [String]) {
            sentLines.withLock { $0.append((entry: entry, lines: lines)) }
            if holding.value {
                held.withLock { $0.append((entry: entry, lines: lines)) }
                return
            }
            for line in lines { links[entry].receive(line: line) }
        }

        func hold(_ on: Bool) { holding.value = on }

        func releaseHeld() {
            let pending = held.withLock { value -> [(entry: Int, lines: [String])] in
                defer { value = [] }
                return value
            }
            for item in pending { for line in item.lines { links[item.entry].receive(line: line) } }
        }

        func hello(_ entry: Int) { links[entry].hello() }
        func settle() {}
    }

    /// 起動を知らせた全マシンへ(書いたマシンにも)通し番号の順で配り返され、全マシンの履歴が同じ順にそろう
    func testEveryMachineEndsWithTheIssuersOrder() {
        let cluster = Cluster(machines: 3)
        for entry in 0..<3 { cluster.hello(entry) }
        cluster.stores[1].write(key: "k", value: "first")
        cluster.stores[0].write(key: "k", value: "second")
        cluster.stores[2].write(key: "k", value: "third")
        cluster.settle()
        let expected = ["k": ["first", "second", "third"]]
        for store in cluster.stores { XCTAssertEqual(store.snapshot(), expected) }
        XCTAssertEqual(cluster.hub.confirmedCount, 3)
    }

    /// 確定が戻る前でも、書いたマシンは自分の書き込みをすぐ見る。他のマシンはまだ見えない
    func testWriterSeesItsOwnWriteBeforeTheConfirmationReturns() {
        let cluster = Cluster(machines: 2)
        for entry in 0..<2 { cluster.hello(entry) }
        cluster.hold(true)
        cluster.stores[0].write(key: "token", value: "abc")
        cluster.settle()
        XCTAssertEqual(cluster.stores[0].snapshot(), ["token": ["abc"]])
        XCTAssertEqual(cluster.stores[1].snapshot(), [:])
        cluster.hold(false)
        cluster.releaseHeld()
        XCTAssertEqual(cluster.stores[1].snapshot(), ["token": ["abc"]])
        XCTAssertEqual(cluster.stores[0].snapshot(), ["token": ["abc"]], "戻った確定が自分の書き込みと二重に見える")
    }

    /// 起動を知らせる前に流れた書き込みは、知らせた時点で履歴として再送される。知らせていない子へは配らない
    func testLateJoinerGetsTheWholeHistoryAndUnjoinedEntriesGetNothing() {
        let cluster = Cluster(machines: 2)
        cluster.hello(0)
        cluster.stores[0].write(key: "a", value: "1")
        cluster.stores[0].write(key: "a", value: "2")
        cluster.settle()
        XCTAssertTrue(cluster.sentLines.withLock { $0.allSatisfy { $0.entry == 0 } }, "知らせていない子へ配っている")
        XCTAssertEqual(cluster.stores[1].snapshot(), [:])
        cluster.hello(1)
        cluster.settle()
        XCTAssertEqual(cluster.stores[1].snapshot(), ["a": ["1", "2"]])
        // 続きの書き込みは両方へ
        cluster.stores[1].write(key: "a", value: "3")
        cluster.settle()
        XCTAssertEqual(cluster.stores[0].snapshot(), ["a": ["1", "2", "3"]])
        XCTAssertEqual(cluster.stores[1].snapshot(), ["a": ["1", "2", "3"]])
    }

    /// clear も同じ経路の1件。その時点までを消し、後の書き込みは残る(全マシン)
    func testClearTravelsTheSamePathAndErasesEverythingBeforeIt() {
        let cluster = Cluster(machines: 2)
        for entry in 0..<2 { cluster.hello(entry) }
        cluster.stores[0].write(key: "k", value: "old")
        cluster.stores[1].write(key: "j", value: "old")
        cluster.settle()
        cluster.stores[1].clear()
        cluster.settle()
        cluster.stores[0].write(key: "k", value: "new")
        cluster.settle()
        for store in cluster.stores { XCTAssertEqual(store.snapshot(), ["k": ["new"]]) }
    }

    /// 値が長くて複数の断片になっても、1件として届く(通し番号も1つ)
    func testLongValueIsOneConfirmedWrite() {
        let cluster = Cluster(machines: 2)
        for entry in 0..<2 { cluster.hello(entry) }
        let value = String(repeating: "長い値", count: 2000)
        cluster.stores[0].write(key: "big", value: value)
        cluster.settle()
        XCTAssertEqual(cluster.hub.confirmedCount, 1)
        XCTAssertEqual(cluster.stores[1].snapshot(), ["big": [value]])
        let lines = cluster.sentLines.withLock { $0.flatMap(\.lines) }
        XCTAssertTrue(lines.allSatisfy { $0.utf8.count < 700 }, "親 → 子の行が端末の行規律の限度に近い")
    }

    /// 終わった子へは以後配らない
    func testExitedEntryIsNoLongerSentTo() {
        let cluster = Cluster(machines: 2)
        for entry in 0..<2 { cluster.hello(entry) }
        cluster.settle()
        cluster.sentLines.withLock { $0.removeAll() }  // hello への開始の行は数えない(見るのは終わった後の配り)
        cluster.hub.entryExited(RunMemoHub.Child(target: "", entry: 1))
        cluster.stores[0].write(key: "k", value: "v")
        cluster.settle()
        XCTAssertFalse(cluster.sentLines.withLock { $0.contains { $0.entry == 1 } })
    }

    /// memo 以外の行は消費しない(呼び手が配り手へ回す)。端末のエコーで戻ってきた seq 付きの行は消費だけして読まない
    func testHubOnlyConsumesMemoLinesAndIgnoresEchoedOnes() {
        let hub = RunMemoHub(mode: .startOnHello, send: { _, _ in })
        let zero = RunMemoHub.Child(target: "", entry: 0)
        XCTAssertFalse(hub.receive(
            line: WorkQueueProtocol.encode(WorkQueueProtocol.Want(req: 1, lane: "a", platform: "ios")), from: zero))
        XCTAssertFalse(hub.receive(line: "some log line", from: zero))
        // 開始・取りやめの行の戻り(端末のエコー)も消費だけする
        XCTAssertTrue(hub.receive(line: WorkQueueProtocol.encode(WorkQueueProtocol.StartSignal.start) + "\r", from: zero))
        XCTAssertTrue(hub.receive(line: WorkQueueProtocol.encode(WorkQueueProtocol.StartSignal.cancel(reason: "x")), from: zero))
        let echoed = WorkQueueProtocol.encode(WorkQueueProtocol.MemoPiece(src: "x", lid: 1, seq: 5, i: 0, n: 1, d: "e30="))
        XCTAssertTrue(hub.receive(line: echoed + "\r", from: zero))
        XCTAssertEqual(hub.confirmedCount, 0)
        // 壊れた断片(n が 0 など)も消費して捨てる
        let broken = WorkQueueProtocol.encode(WorkQueueProtocol.MemoPiece(src: "x", lid: 1, seq: nil, i: 0, n: 0, d: ""))
        XCTAssertTrue(hub.receive(line: broken, from: zero))
        XCTAssertEqual(hub.confirmedCount, 0)
    }

    /// 断片が全部そろうまでは確定しない(途中の断片だけでは通し番号を振らない)
    func testPartialPiecesDoNotConfirm() {
        let hub = RunMemoHub(mode: .startOnHello, send: { _, _ in })
        let zero = RunMemoHub.Child(target: "", entry: 0)
        let pieces = RunMemoWire.pieces(for: .write(key: "k", value: String(repeating: "v", count: 1000)))
        XCTAssertEqual(pieces.count, 2 + 1, "断片が3つに割れる大きさの値")
        for (index, piece) in pieces.enumerated() {
            let line = WorkQueueProtocol.encode(WorkQueueProtocol.MemoPiece(
                src: "x", lid: 1, seq: nil, i: index, n: pieces.count, d: piece))
            XCTAssertTrue(hub.receive(line: line, from: zero))
            XCTAssertEqual(hub.confirmedCount, index == pieces.count - 1 ? 1 : 0)
        }
    }

    /// 中身が読めない断片の組には通し番号を振らない(受け手が捨てて番号が抜けるのを防ぐ)
    func testUnreadablePieceSetIsNotNumbered() {
        let hub = RunMemoHub(mode: .startOnHello, send: { _, _ in })
        let line = WorkQueueProtocol.encode(WorkQueueProtocol.MemoPiece(src: "x", lid: 1, seq: nil, i: 0, n: 1, d: "AAAA"))
        XCTAssertTrue(hub.receive(line: line, from: RunMemoHub.Child(target: "", entry: 0)))
        XCTAssertEqual(hub.confirmedCount, 0)
    }

    // MARK: - 開始の行(RR-8.4)

    private func decoded(_ lines: [String]) -> [String] {
        lines.map { line in
            if let signal = WorkQueueProtocol.decodeStartSignal(line) {
                switch signal {
                case .start: return "start"
                case .cancel(let reason): return "cancel:\(reason)"
                }
            }
            if let piece = WorkQueueProtocol.decodeMemoPiece(line) { return "memo#\(piece.seq ?? -1)" }
            return "?"
        }
    }

    /// 開始を決める呼び出しが無い形の既定: 起動の知らせを受けたらすぐ「履歴 → 開始」(既存の run が開始を待って止まらない)
    func testDefaultModeStartsAChildAsSoonAsItSaysHello() {
        let cluster = Cluster(machines: 2)
        cluster.hub.seedConfirmed([.write(key: "k", value: "seed")])
        cluster.hello(0)
        cluster.settle()
        let sent = cluster.sentLines.withLock { $0 }
        XCTAssertEqual(sent.map(\.entry), [0])
        XCTAssertEqual(decoded(sent[0].lines), ["memo#1", "start"])
    }

    /// 決定を待つモード: 決定の前に来た知らせは保留(何も送らない)。決定で「履歴 → 開始」の順に全部の子へ
    func testAwaitDecisionHoldsHelloUntilTheDecisionThenSendsHistoryBeforeStart() {
        let cluster = Cluster(machines: 2, mode: .awaitDecision)
        XCTAssertEqual(cluster.hub.seedConfirmed([.write(key: "a", value: "1"), .write(key: "a", value: "2")]), 2)
        cluster.hello(0)
        cluster.hello(1)
        cluster.settle()
        XCTAssertTrue(cluster.sentLines.withLock { $0.isEmpty }, "決定の前に開始や履歴を送っている")
        cluster.hub.decideGate(.start)
        cluster.settle()
        let sent = cluster.sentLines.withLock { $0 }
        XCTAssertEqual(Set(sent.map(\.entry)), [0, 1])
        for item in sent { XCTAssertEqual(decoded(item.lines), ["memo#1", "memo#2", "start"], "履歴が開始より後ろ") }
        for store in cluster.stores { XCTAssertEqual(store.snapshot(), ["a": ["1", "2"]]) }
    }

    /// 決定の後に来た知らせは、その場で「履歴 → 開始」。決定は最初の1回だけ有効
    func testHelloAfterTheDecisionIsAnsweredAtOnceAndOnlyTheFirstDecisionCounts() {
        let cluster = Cluster(machines: 2, mode: .awaitDecision)
        cluster.hub.seedConfirmed([.write(key: "k", value: "v")])
        cluster.hub.decideGate(.start)
        cluster.hub.decideGate(.cancel(reason: "late"))
        cluster.hello(1)
        cluster.settle()
        let sent = cluster.sentLines.withLock { $0 }
        XCTAssertEqual(sent.count, 1)
        XCTAssertEqual(decoded(sent[0].lines), ["memo#1", "start"])
    }

    /// 取りやめ: 履歴は送らず取りやめの行だけ・以後その子へ確定を配らない
    func testCancelSendsOnlyTheCancelLineAndNeverJoinsTheChild() {
        let cluster = Cluster(machines: 2, mode: .awaitDecision)
        cluster.hub.seedConfirmed([.write(key: "k", value: "v")])
        cluster.hello(0)
        cluster.hub.decideGate(.cancel(reason: "beforeRun() failed"))
        cluster.hello(1)
        cluster.settle()
        let sent = cluster.sentLines.withLock { $0 }
        XCTAssertEqual(sent.map(\.entry).sorted(), [0, 1])
        for item in sent { XCTAssertEqual(decoded(item.lines), ["cancel:beforeRun() failed"]) }
        cluster.hub.seedConfirmed([.write(key: "j", value: "w")])
        cluster.settle()
        XCTAssertEqual(cluster.sentLines.withLock { $0.count }, 2, "取りやめた子へ確定を配っている")
    }

    /// 鍵は (対象, エントリ番号): 別の対象の同じ番号の子が終わっても、走っている子は配り先から外れない
    func testChildKeyIncludesTheTarget() {
        let sent = LockedValue<[String]>([])
        let hub = RunMemoHub(mode: .startOnHello, send: { child, _ in sent.withLock { $0.append("\(child.target)/\(child.entry)") } })
        let hello = WorkQueueProtocol.encode(WorkQueueProtocol.MemoHello(src: "s"))
        let a = RunMemoHub.Child(target: "A", entry: 0)
        let b = RunMemoHub.Child(target: "B", entry: 0)
        hub.receive(line: hello, from: a)
        hub.receive(line: hello, from: b)
        hub.entryExited(b)
        sent.withLock { $0.removeAll() }
        hub.seedConfirmed([.write(key: "k", value: "v")])
        XCTAssertEqual(sent.withLock { $0 }, ["A/0"])
    }

    /// `beforeRun` の書き込みは通し番号の先頭・読めないものは番号を振らない
    func testSeedConfirmedNumbersFromTheFrontAndSkipsWhatCannotBeShared() {
        let hub = RunMemoHub(mode: .awaitDecision, send: { _, _ in })
        let huge = String(repeating: "x", count: RunMemoWire.pieceCharacters * RunMemoWire.maxPieces)
        XCTAssertEqual(hub.seedConfirmed([.write(key: "a", value: "1"), .write(key: "big", value: huge), .clear]), 2)
        XCTAssertEqual(hub.confirmedCount, 2)
    }
    /// 上限を超える値はマシンをまたがず、そのマシンだけに残る(1行言う)
    func testOversizedValueStaysLocalAndWarns() {
        let warned = LockedValue<[String]>([])
        let sent = LockedValue<[String]>([])
        let link = RunMemoLink(source: "m", send: { text in sent.withLock { $0.append(text) } },
                               warn: { message in warned.withLock { $0.append(message) } })
        let store = RunMemoStore(link: link)
        let huge = String(repeating: "x", count: RunMemoWire.pieceCharacters * RunMemoWire.maxPieces)
        store.write(key: "k", value: huge)
        XCTAssertEqual(store.snapshot()["k"]?.count, 1, "自分のマシンには残る")
        XCTAssertTrue(sent.withLock { $0.isEmpty }, "上限を超えた値を送っている")
        XCTAssertEqual(warned.withLock { $0.count }, 1)
    }
}
