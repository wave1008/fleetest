import XCTest
@testable import FTCore

/// 対象外のシナリオを同じ run のまだ試していない台へ回し直すかの判定(DR-214)。
/// 破ると: 対象の台が落ちた run が 0 本実行の緑で終わる / 最初から対象の台が居ない run が赤になる / 試した台へ戻して同じ対象外を繰り返す。
final class NotApplicableHandoffTests: XCTestCase {
    private typealias H = NotApplicableHandoff

    func testUntriedLiveDeviceMeansHandOn() {
        XCTAssertEqual(H.decide(tried: ["a"], live: ["a", "b"], departed: [], kinds: [:]), .handOn)
        // 落ちた台が別に居ても、生きた未試行の台が先
        XCTAssertEqual(H.decide(tried: ["a"], live: ["a", "b"], departed: ["c"], kinds: [:]), .handOn)
    }

    func testEveryDeviceTriedMeansSkipped() {
        XCTAssertEqual(H.decide(tried: ["a", "b"], live: ["a", "b"], departed: [], kinds: [:]), .skipped)
        // 試して対象外と宣言した後に落ちた台は「未試行で落ちた」に数えない
        XCTAssertEqual(H.decide(tried: ["a", "b"], live: ["a"], departed: ["b"], kinds: [:]), .skipped)
    }

    /// 最初から他の台が居ない(対象の台が無いプロファイル)は従来どおり対象外
    func testNoOtherDeviceMeansSkipped() {
        XCTAssertEqual(H.decide(tried: ["a"], live: ["a"], departed: [], kinds: [:]), .skipped)
    }

    /// 試していない台が落ちて回し直す先が残らない = 実行しなかった赤(duo_memo_cmp の形)
    func testUntriedDeviceThatLeftMeansNotRun() {
        XCTAssertEqual(H.decide(tried: ["m1max"], live: ["m1max"], departed: ["duo"], kinds: [:]), .notRun)
    }

    /// 試した台と同じ観測の種類の台は試した扱い(iOS。DR-214)
    func testSameKindCountsAsTried() {
        let kinds: [String: Set<String>] = ["a": ["k"], "b": ["k"]]
        XCTAssertEqual(H.decide(tried: ["a"], live: ["a", "b"], departed: [], kinds: kinds), .skipped)
        // 落ちた台でも種類が同じなら「未試行で落ちた」に数えない
        XCTAssertEqual(H.decide(tried: ["a"], live: ["a"], departed: ["b"], kinds: kinds), .skipped)
    }

    /// 種類が違う・不明・空・一部だけ同じ台は覆わない(誤った緑を作らない)
    func testDifferentOrUnknownKindIsNotCovered() {
        XCTAssertEqual(H.decide(tried: ["a"], live: ["a", "b"], departed: [], kinds: ["a": ["k"], "b": ["f"]]), .handOn)
        XCTAssertEqual(H.decide(tried: ["a"], live: ["a", "b"], departed: [], kinds: ["a": ["k"]]), .handOn)
        XCTAssertEqual(H.decide(tried: ["a"], live: ["a", "b"], departed: [], kinds: ["a": ["k"], "b": []]), .handOn)
        // 試した側が不明なら何も覆わない
        XCTAssertEqual(H.decide(tried: ["a"], live: ["a", "b"], departed: [], kinds: ["b": ["k"]]), .handOn)
        // 台が複数の種類を持つとき、全部が試した種類に入らなければ覆わない
        XCTAssertEqual(H.decide(tried: ["a"], live: ["a", "b"], departed: [], kinds: ["a": ["k"], "b": ["k", "f"]]), .handOn)
        XCTAssertEqual(H.decide(tried: ["a"], live: ["a"], departed: ["b"], kinds: ["a": ["k"], "b": ["f"]]), .notRun)
    }

    /// 種類の混ざった鍵(親のエントリ = 台の集まり。子は一部の台しか使わないことがある)の「対象外」は、どちらの種類を試した証拠にもならない
    func testMixedKindTriedKeyCoversNothing() {
        XCTAssertEqual(H.decide(tried: ["a"], live: ["a", "b"], departed: [], kinds: ["a": ["k", "f"], "b": ["f"]]), .handOn)
        XCTAssertEqual(H.decide(tried: ["a"], live: ["a"], departed: ["b"], kinds: ["a": ["k", "f"], "b": ["k"]]), .notRun)
        // 単一の種類の鍵が2つ試していれば、両方の種類を持つ鍵は覆われる
        XCTAssertEqual(H.decide(tried: ["a", "c"], live: ["a", "b", "c"], departed: [],
                                kinds: ["a": ["k"], "c": ["f"], "b": ["k", "f"]]), .skipped)
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
        let na = WorkQueueProtocol.NotApplicable(req: 7, unit: ScenarioUnitKey(id: "C.S1", variant: nil), lane: "Duo-01", platform: "ios", dep: true)
        let line = WorkQueueProtocol.encode(na)
        XCTAssertEqual(WorkQueueProtocol.decodeNotApplicable(line), na)
        XCTAssertNil(WorkQueueProtocol.decodeWant(line), "na を want と読まない")
        XCTAssertLessThan(line.utf8.count, 300, "ssh -tt の行規律に載る短さ")

        let reply = WorkQueueProtocol.Reply(req: 7, verdict: .notRun)
        let replyLine = WorkQueueProtocol.encode(reply)
        XCTAssertEqual(WorkQueueProtocol.decodeReply(replyLine)?.verdict, "fail")
        XCTAssertNil(WorkQueueProtocol.decodeReply(replyLine)?.unit)
        XCTAssertNil(WorkQueueProtocol.decodeNotApplicable(WorkQueueProtocol.encode(
            WorkQueueProtocol.Want(req: 1, lane: "a", platform: "ios"))))
    }
}
