import XCTest
@testable import FTCore

/// 対象外のシナリオを同じ run のまだ試していない台へ回し直すかの判定(DR-214)。
/// 破ると: 対象の台が落ちた run が 0 本実行の緑で終わる / 最初から対象の台が居ない run が赤になる / 試した台へ戻して同じ対象外を繰り返す。
final class NotApplicableHandoffTests: XCTestCase {
    private typealias H = NotApplicableHandoff

    func testUntriedLiveDeviceMeansHandOn() {
        XCTAssertEqual(H.decide(tried: ["a"], live: ["a", "b"], departed: []), .handOn)
        // 落ちた台が別に居ても、生きた未試行の台が先
        XCTAssertEqual(H.decide(tried: ["a"], live: ["a", "b"], departed: ["c"]), .handOn)
    }

    func testEveryDeviceTriedMeansSkipped() {
        XCTAssertEqual(H.decide(tried: ["a", "b"], live: ["a", "b"], departed: []), .skipped)
        // 試して対象外と宣言した後に落ちた台は「未試行で落ちた」に数えない
        XCTAssertEqual(H.decide(tried: ["a", "b"], live: ["a"], departed: ["b"]), .skipped)
    }

    /// 最初から他の台が居ない(対象の台が無いプロファイル)は従来どおり対象外
    func testNoOtherDeviceMeansSkipped() {
        XCTAssertEqual(H.decide(tried: ["a"], live: ["a"], departed: []), .skipped)
    }

    /// 試していない台が落ちて回し直す先が残らない = 実行しなかった赤(duo_memo_cmp の形)
    func testUntriedDeviceThatLeftMeansNotRun() {
        XCTAssertEqual(H.decide(tried: ["m1max"], live: ["m1max"], departed: ["duo"]), .notRun)
    }

    func testWireRoundTrip() {
        for verdict in [H.Verdict.handOn, .skipped, .notRun] {
            XCTAssertEqual(H.Verdict(wire: verdict.wire), verdict)
        }
        XCTAssertNil(H.Verdict(wire: "x"))
    }

    func testNotRunReasonNamesTheDeclaration() {
        let text = H.notRunReason(declared: "fold() needs a foldable device")
        XCTAssertTrue(text.hasPrefix("not run:"))
        XCTAssertTrue(text.contains("fold() needs a foldable device"))
    }

    /// 親子のワイヤ: 問い合わせ(`na`)と返事(`verdict`)が往復し、`want` / 通常の返事と取り違えない
    func testWireLinesRoundTrip() {
        let na = WorkQueueProtocol.NotApplicable(req: 7, id: "C.S1", lane: "Duo-01", platform: "ios", dep: true)
        let line = WorkQueueProtocol.encode(na)
        XCTAssertEqual(WorkQueueProtocol.decodeNotApplicable(line), na)
        XCTAssertNil(WorkQueueProtocol.decodeWant(line), "na を want と読まない")
        XCTAssertLessThan(line.utf8.count, 300, "ssh -tt の行規律に載る短さ")

        let reply = WorkQueueProtocol.Reply(req: 7, verdict: .notRun)
        let replyLine = WorkQueueProtocol.encode(reply)
        XCTAssertEqual(WorkQueueProtocol.decodeReply(replyLine)?.verdict, "fail")
        XCTAssertNil(WorkQueueProtocol.decodeReply(replyLine)?.scenarioID)
        XCTAssertNil(WorkQueueProtocol.decodeNotApplicable(WorkQueueProtocol.encode(
            WorkQueueProtocol.Want(req: 1, lane: "a", platform: "ios"))))
    }
}
