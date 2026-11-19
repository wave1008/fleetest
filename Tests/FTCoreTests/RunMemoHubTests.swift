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

        init(machines: Int) {
            let box = Box()
            hub = RunMemoHub(send: { entry, lines in box.send(entry, lines) })
            for entry in 0..<machines {
                let link = RunMemoLink(
                    source: "m\(entry)",
                    send: { [hub] text in
                        for line in text.split(separator: "\n") { hub.receive(line: String(line), fromEntry: entry) }
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
        func settle() { hub.flush() }
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
        cluster.hub.entryExited(1)
        cluster.stores[0].write(key: "k", value: "v")
        cluster.settle()
        XCTAssertFalse(cluster.sentLines.withLock { $0.contains { $0.entry == 1 } })
    }

    /// memo 以外の行は消費しない(呼び手が配り手へ回す)。端末のエコーで戻ってきた seq 付きの行は消費だけして読まない
    func testHubOnlyConsumesMemoLinesAndIgnoresEchoedOnes() {
        let hub = RunMemoHub(send: { _, _ in })
        XCTAssertFalse(hub.receive(
            line: WorkQueueProtocol.encode(WorkQueueProtocol.Want(req: 1, lane: "a", platform: "ios")), fromEntry: 0))
        XCTAssertFalse(hub.receive(line: "some log line", fromEntry: 0))
        let echoed = WorkQueueProtocol.encode(WorkQueueProtocol.MemoPiece(src: "x", lid: 1, seq: 5, i: 0, n: 1, d: "e30="))
        XCTAssertTrue(hub.receive(line: echoed + "\r", fromEntry: 0))
        hub.flush()
        XCTAssertEqual(hub.confirmedCount, 0)
        // 壊れた断片(n が 0 など)も消費して捨てる
        let broken = WorkQueueProtocol.encode(WorkQueueProtocol.MemoPiece(src: "x", lid: 1, seq: nil, i: 0, n: 0, d: ""))
        XCTAssertTrue(hub.receive(line: broken, fromEntry: 0))
        XCTAssertEqual(hub.confirmedCount, 0)
    }

    /// 断片が全部そろうまでは確定しない(途中の断片だけでは通し番号を振らない)
    func testPartialPiecesDoNotConfirm() {
        let hub = RunMemoHub(send: { _, _ in })
        let first = WorkQueueProtocol.encode(WorkQueueProtocol.MemoPiece(src: "x", lid: 1, seq: nil, i: 0, n: 2, d: "AAAA"))
        XCTAssertTrue(hub.receive(line: first, fromEntry: 0))
        XCTAssertEqual(hub.confirmedCount, 0)
        let second = WorkQueueProtocol.encode(WorkQueueProtocol.MemoPiece(src: "x", lid: 1, seq: nil, i: 1, n: 2, d: "BBBB"))
        XCTAssertTrue(hub.receive(line: second, fromEntry: 0))
        XCTAssertEqual(hub.confirmedCount, 1)
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
