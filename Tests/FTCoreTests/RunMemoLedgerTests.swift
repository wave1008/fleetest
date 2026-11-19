// run メモ(DR-208)の並べ方(RunMemoLedger)と行の符号化(RunMemoWire / WorkQueueProtocol の memo 行)の単体テスト。
// 並べ方の規則: 見える履歴 = 確定分を通し番号の順に畳み、その後ろに自分の未確定分を書いた順に畳む(clear も畳み込みの1件)。

import XCTest
@testable import FTCore

final class RunMemoLedgerTests: XCTestCase {

    private func write(_ key: String, _ value: String) -> RunMemoOp { .write(key: key, value: value) }

    /// 確定の前でも自分の書き込みはすぐ見える(同じマシンの次のシナリオから見える)。書いた順
    func testLocalWritesAreVisibleImmediatelyInWriteOrder() {
        var ledger = RunMemoLedger()
        _ = ledger.addLocal(write("k", "a"))
        _ = ledger.addLocal(write("k", "b"))
        _ = ledger.addLocal(write("other", "z"))
        XCTAssertEqual(ledger.view(), ["k": ["a", "b"], "other": ["z"]])
    }

    /// 確定分は到着順でなく通し番号の順に並ぶ
    func testConfirmedWritesAreOrderedBySequenceNotArrival() {
        var ledger = RunMemoLedger()
        ledger.confirm(seq: 2, op: write("k", "second"), ownLid: nil)
        ledger.confirm(seq: 1, op: write("k", "first"), ownLid: nil)
        ledger.confirm(seq: 3, op: write("k", "third"), ownLid: nil)
        XCTAssertEqual(ledger.view(), ["k": ["first", "second", "third"]])
    }

    /// 未確定は確定の後ろ。自分の書き込みが戻ったら未確定から外れる(二重に見えない)
    func testPendingComesAfterConfirmedAndOwnConfirmationReplacesIt() {
        var ledger = RunMemoLedger()
        let lid = ledger.addLocal(write("k", "mine"))
        ledger.confirm(seq: 1, op: write("k", "theirs"), ownLid: nil)
        XCTAssertEqual(ledger.view(), ["k": ["theirs", "mine"]], "未確定は確定の後ろ")
        ledger.confirm(seq: 2, op: write("k", "mine"), ownLid: lid)
        XCTAssertEqual(ledger.view(), ["k": ["theirs", "mine"]])
        XCTAssertEqual(ledger.pendingCount, 0, "戻った書き込みが未確定に残っている")
    }

    /// 自分の書き込みの確定が相手の書き込みより先の番号なら、確定後は番号の順へ入れ替わる(最後は全マシンで同じ順)
    func testOwnWriteMovesToItsSequencePositionOnceConfirmed() {
        var ledger = RunMemoLedger()
        let lid = ledger.addLocal(write("k", "mine"))
        ledger.confirm(seq: 2, op: write("k", "theirs"), ownLid: nil)
        XCTAssertEqual(ledger.view(), ["k": ["theirs", "mine"]])
        ledger.confirm(seq: 1, op: write("k", "mine"), ownLid: lid)
        XCTAssertEqual(ledger.view(), ["k": ["mine", "theirs"]])
    }

    /// 同じ通し番号の再送(履歴の再送)は足さない
    func testDuplicateSequenceIsIgnored() {
        var ledger = RunMemoLedger()
        XCTAssertTrue(ledger.confirm(seq: 1, op: write("k", "a"), ownLid: nil))
        XCTAssertFalse(ledger.confirm(seq: 1, op: write("k", "a"), ownLid: nil))
        XCTAssertEqual(ledger.view(), ["k": ["a"]])
        XCTAssertEqual(ledger.confirmedCount, 1)
    }

    /// clear は、その時点までの確定分と自分の未確定分を消す。後の書き込みは残る
    func testClearErasesEarlierConfirmedAndOwnPendingButNotLaterWrites() {
        var ledger = RunMemoLedger()
        ledger.confirm(seq: 1, op: write("k", "old"), ownLid: nil)
        _ = ledger.addLocal(write("k", "pendingBefore"))
        _ = ledger.addLocal(.clear)
        XCTAssertEqual(ledger.view(), [:])
        _ = ledger.addLocal(write("k", "after"))
        XCTAssertEqual(ledger.view(), ["k": ["after"]])
        XCTAssertEqual(ledger.pendingCount, 2, "clear の手前の未確定は残さない")
    }

    /// 確定した clear は、番号が手前の確定分だけを消す(後の番号の書き込みは残る)
    func testConfirmedClearErasesOnlyLowerSequences() {
        var ledger = RunMemoLedger()
        ledger.confirm(seq: 1, op: write("k", "a"), ownLid: nil)
        ledger.confirm(seq: 3, op: write("k", "c"), ownLid: nil)
        ledger.confirm(seq: 2, op: .clear, ownLid: nil)
        XCTAssertEqual(ledger.view(), ["k": ["c"]])
    }

    /// 収束: 2つのマシンがそれぞれ自分の書き込みを先に見ていても、発行元の順が全部届けば同じ履歴になる
    func testTwoMachinesConvergeToTheSameHistoryOnceEverythingIsConfirmed() {
        var a = RunMemoLedger()
        var b = RunMemoLedger()
        let lidA = a.addLocal(write("k", "fromA"))
        let lidB = b.addLocal(write("k", "fromB"))
        XCTAssertNotEqual(a.view(), b.view(), "確定前は各自の書き込みが後ろに付くので食い違ってよい")
        // 発行元の順: B が先、A が後
        let confirmed: [(Int, RunMemoOp, Bool)] = [(1, write("k", "fromB"), false), (2, write("k", "fromA"), true)]
        for (seq, op, isA) in confirmed {
            a.confirm(seq: seq, op: op, ownLid: isA ? lidA : nil)
            b.confirm(seq: seq, op: op, ownLid: isA ? nil : lidB)
        }
        XCTAssertEqual(a.view(), ["k": ["fromB", "fromA"]])
        XCTAssertEqual(a.view(), b.view())
    }

    /// 収束(clear を含む): 片方が clear を書いても、確定が全部届けば同じ履歴
    func testTwoMachinesConvergeWithAClearInTheMiddle() {
        var a = RunMemoLedger()
        var b = RunMemoLedger()
        let lidA1 = a.addLocal(write("k", "a1"))
        let lidA2 = a.addLocal(.clear)
        let lidB = b.addLocal(write("k", "b1"))
        let order: [(RunMemoOp, Int?, Int?)] = [   // (op, A の lid, B の lid)
            (write("k", "a1"), lidA1, nil), (write("k", "b1"), nil, lidB), (.clear, lidA2, nil),
        ]
        for (index, entry) in order.enumerated() {
            a.confirm(seq: index + 1, op: entry.0, ownLid: entry.1)
            b.confirm(seq: index + 1, op: entry.0, ownLid: entry.2)
        }
        XCTAssertEqual(a.view(), [:])
        XCTAssertEqual(a.view(), b.view())
    }
}

final class RunMemoWireTests: XCTestCase {

    func testWriteAndClearRoundTripThroughPieces() {
        let ops: [RunMemoOp] = [
            .write(key: "token", value: "abc"), .write(key: "", value: ""), .clear,
            .write(key: "日本語のキー", value: "改行\nと\"引用\"と\\と絵文字😀"),
        ]
        for op in ops {
            XCTAssertEqual(RunMemoWire.op(fromPieces: RunMemoWire.pieces(for: op)), op, "\(op)")
        }
    }

    /// 長い値は複数の断片に割れ、どの行も ssh -tt の行の限度(約 1024 バイト)に十分収まる
    func testLongValueSplitsIntoShortLines() {
        let value = String(repeating: "あいう\"\n", count: 3000)
        let pieces = RunMemoWire.pieces(for: .write(key: "k", value: value))
        XCTAssertGreaterThan(pieces.count, 1)
        XCTAssertEqual(RunMemoWire.op(fromPieces: pieces), .write(key: "k", value: value))
        for (index, piece) in pieces.enumerated() {
            let line = WorkQueueProtocol.encode(WorkQueueProtocol.MemoPiece(
                src: "abcd1234", lid: 12345, seq: 98765, i: index, n: pieces.count, d: piece))
            XCTAssertLessThan(line.utf8.count, 700, "断片 \(index) の行が長すぎる")
            XCTAssertFalse(line.contains("\n"))
        }
    }

    func testBrokenPiecesAreNil() {
        XCTAssertNil(RunMemoWire.op(fromPieces: ["!!!not-base64!!!"]))
        XCTAssertNil(RunMemoWire.op(fromPieces: [Data(#"{"x":1}"#.utf8).base64EncodedString()]))
        XCTAssertNil(RunMemoWire.op(fromPieces: [""]))
    }

    func testMemoLinesRoundTripAndAreNotMistakenForWorkQueueLines() throws {
        let piece = WorkQueueProtocol.MemoPiece(src: "a1", lid: 3, seq: nil, i: 0, n: 2, d: "QUJD")
        let line = WorkQueueProtocol.encode(piece)
        XCTAssertEqual(line, #"{"ftWork":{"d":"QUJD","i":0,"lid":3,"n":2,"op":"memo","src":"a1"}}"#)
        XCTAssertEqual(WorkQueueProtocol.decodeMemoPiece(line), piece)
        let down = WorkQueueProtocol.MemoPiece(src: "a1", lid: 3, seq: 9, i: 1, n: 2, d: "REU=")
        XCTAssertEqual(WorkQueueProtocol.decodeMemoPiece(WorkQueueProtocol.encode(down)), down)
        XCTAssertNil(WorkQueueProtocol.decodeWant(line))
        XCTAssertNil(WorkQueueProtocol.decodeReply(line))

        let hello = WorkQueueProtocol.MemoHello(src: "a1")
        let helloLine = WorkQueueProtocol.encode(hello)
        XCTAssertEqual(helloLine, #"{"ftWork":{"op":"memoHello","src":"a1"}}"#)
        XCTAssertEqual(WorkQueueProtocol.decodeMemoHello(helloLine), hello)
        XCTAssertNil(WorkQueueProtocol.decodeMemoPiece(helloLine))
        XCTAssertNil(WorkQueueProtocol.decodeWant(helloLine))
        XCTAssertNil(WorkQueueProtocol.decodeReply(helloLine))
        // 逆: 要求・返事の行は memo としては読めない
        XCTAssertNil(WorkQueueProtocol.decodeMemoPiece(WorkQueueProtocol.encode(
            WorkQueueProtocol.Want(req: 1, lane: "a", platform: "ios"))))
        XCTAssertNil(WorkQueueProtocol.decodeMemoHello(WorkQueueProtocol.encode(
            WorkQueueProtocol.Reply(req: 1, none: true))))
    }
}
