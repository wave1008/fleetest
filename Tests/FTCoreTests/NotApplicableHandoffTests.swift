import XCTest
@testable import FTCore

/// 対象外のシナリオを同じ run のまだ試していない台へ回し直すかの判定(DR-214)。
/// 破ると: 対象の台が落ちた run が 0 本実行の緑で終わる / 最初から対象の台が居ない run が赤になる / 試した台へ戻して同じ対象外を繰り返す。
final class NotApplicableHandoffTests: XCTestCase {
    private typealias H = NotApplicableHandoff

    func testUntriedLiveDeviceMeansHandOn() {
        XCTAssertEqual(H.decide(tried: ["a"], live: ["a", "b"], departed: [], kinds: [:], evidence: []), .handOn)
        // 落ちた台が別に居ても、生きた未試行の台が先
        XCTAssertEqual(H.decide(tried: ["a"], live: ["a", "b"], departed: ["c"], kinds: [:], evidence: []), .handOn)
    }

    func testEveryDeviceTriedMeansSkipped() {
        XCTAssertEqual(H.decide(tried: ["a", "b"], live: ["a", "b"], departed: [], kinds: [:], evidence: []), .skipped)
        // 試して対象外と宣言した後に落ちた台は「未試行で落ちた」に数えない
        XCTAssertEqual(H.decide(tried: ["a", "b"], live: ["a"], departed: ["b"], kinds: [:], evidence: []), .skipped)
    }

    /// 最初から他の台が居ない(対象の台が無いプロファイル)は従来どおり対象外
    func testNoOtherDeviceMeansSkipped() {
        XCTAssertEqual(H.decide(tried: ["a"], live: ["a"], departed: [], kinds: [:], evidence: []), .skipped)
    }

    /// 試していない台が落ちて回し直す先が残らない = 実行しなかった赤(duo_memo_cmp の形)
    func testUntriedDeviceThatLeftMeansNotRun() {
        XCTAssertEqual(H.decide(tried: ["m1max"], live: ["m1max"], departed: ["duo"], kinds: [:], evidence: []), .notRun)
    }

    /// 試した台で観測した種類(証拠)と同じ種類の台は試した扱い(iOS。DR-214)
    func testSameKindAsEvidenceCountsAsTried() {
        let kinds: [String: Set<String>] = ["b": ["k"]]
        XCTAssertEqual(H.decide(tried: ["a"], live: ["a", "b"], departed: [], kinds: kinds, evidence: ["k"]), .skipped)
        // 落ちた台でも種類が同じなら「未試行で落ちた」に数えない
        XCTAssertEqual(H.decide(tried: ["a"], live: ["a"], departed: ["b"], kinds: kinds, evidence: ["k"]), .skipped)
    }

    /// 種類が違う・不明・空・一部だけ証拠に入る台は覆わない(誤った緑を作らない)
    func testDifferentOrUnknownKindIsNotCovered() {
        XCTAssertEqual(H.decide(tried: ["a"], live: ["a", "b"], departed: [], kinds: ["b": ["f"]], evidence: ["k"]), .handOn)
        XCTAssertEqual(H.decide(tried: ["a"], live: ["a", "b"], departed: [], kinds: [:], evidence: ["k"]), .handOn)
        XCTAssertEqual(H.decide(tried: ["a"], live: ["a", "b"], departed: [], kinds: ["b": []], evidence: ["k"]), .handOn)
        XCTAssertEqual(H.decide(tried: ["a"], live: ["a", "b"], departed: [], kinds: ["b": ["k", "f"]], evidence: ["k"]), .handOn)
        XCTAssertEqual(H.decide(tried: ["a"], live: ["a"], departed: ["b"], kinds: ["b": ["f"]], evidence: ["k"]), .notRun)
    }

    /// 証拠は渡された evidence だけ。試した鍵の種類の見込み(kinds)は証拠にしない
    /// (親のエントリは台の集まりで、子は一部の台しか使わないことがある = 使わなかった種類を試したことにしない)
    func testTriedKeyKindsAreNotEvidence() {
        XCTAssertEqual(H.decide(tried: ["a"], live: ["a", "b"], departed: [], kinds: ["a": ["k", "f"], "b": ["f"]], evidence: ["k"]), .handOn)
        XCTAssertEqual(H.decide(tried: ["a"], live: ["a", "b"], departed: [], kinds: ["a": ["k"], "b": ["k"]], evidence: []), .handOn)
        // 2つの種類を両方試した証拠があれば、両方の種類を持つ鍵は覆われる
        XCTAssertEqual(H.decide(tried: ["a"], live: ["a", "b"], departed: [], kinds: ["b": ["k", "f"]], evidence: ["k", "f"]), .skipped)
    }

    /// 種類を上限まで載せても行は短い(上限を超える数は載せない = 観測していない扱い)
    func testNotApplicableKindsStayShortOrAreDropped() {
        let long = "折りたたみの開閉を跨いで操作できること.S0020"
        let kinds = Set((0..<WorkQueueProtocol.NotApplicable.maxKinds).map { "iPhone-18-Pro-Max-\($0)|iOS-27-2" })
        let na = WorkQueueProtocol.NotApplicable(req: 9999, unit: ScenarioUnitKey(id: long, variant: "dark-large"),
                                                 lane: "iPhone 18 Pro(iOS 27.2)-08", platform: "ios", dep: true, kinds: kinds)
        XCTAssertEqual(na.kinds?.count, WorkQueueProtocol.NotApplicable.maxKinds)
        XCTAssertLessThan(WorkQueueProtocol.encode(na).utf8.count, WorkQueueProtocol.maxStartLineBytes)
        let over = WorkQueueProtocol.NotApplicable(req: 1, unit: ScenarioUnitKey(id: long, variant: nil), lane: "a", platform: "ios",
                                                   dep: false, kinds: kinds.union(["one-more|iOS-27-2"]))
        XCTAssertNil(over.kinds)
        XCTAssertNil(WorkQueueProtocol.NotApplicable(req: 1, unit: ScenarioUnitKey(id: long, variant: nil), lane: "a",
                                                     platform: "ios", dep: false, kinds: []).kinds, "空は載せない(省略 = 観測していない)")
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
        let na = WorkQueueProtocol.NotApplicable(req: 7, unit: ScenarioUnitKey(id: "C.S1", variant: nil), lane: "Duo-01", platform: "ios", dep: true, kinds: ["iPhone-Duo|iOS-27-2"])
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
