// 対象外で終わったシナリオの回し直し(DR-214)の親の配り手の規律。デバイス不要。
// 破ると: 折りたためる端末の居るマシンが落ちた run が 0 本実行の緑で終わる / 試したマシンへ同じシナリオを戻す /
// 回し直した分が子の結果の照合(assigned)に残って「結果が無い」になる / 尽きたマシンが戻ってくる分を待たずに終わる。

import XCTest
import FTCore
@testable import fleetest

final class DynamicDispatcherNotApplicableTests: XCTestCase {
    private typealias Scenario = DynamicSplit.Scenario

    private func makeDispatcher(_ scenarios: [Scenario], entries: Int,
                                sent: LockedValue<[String]> = LockedValue([])) -> DynamicDispatcher {
        DynamicDispatcher(
            scenarios: scenarios,
            estimateMs: { _, _ in 1000 },
            lpt: true,
            entryPlatforms: Dictionary(uniqueKeysWithValues: (0..<entries).map { ($0, Set(["ios"])) }),
            send: { entry, reply in sent.withLock { $0.append("\(entry):\(WorkQueueProtocol.encode(reply))") } })
    }

    private func want(_ req: Int, lane: String) -> WorkQueueProtocol.Want {
        WorkQueueProtocol.Want(req: req, lane: lane, platform: "ios")
    }

    private func na(_ req: Int, id: String, lane: String, dep: Bool = false) -> WorkQueueProtocol.NotApplicable {
        WorkQueueProtocol.NotApplicable(req: req, id: id, lane: lane, platform: "ios", dep: dep)
    }

    private let fold = Scenario(id: "Fold.S1", platform: "ios")

    /// 他のエントリが未試行で生きている: 回し直す。pending へ戻り、試したエントリへは渡さず、未試行のエントリが取る
    func testHandsOnToTheUntriedEntryAndNeverBackToTheOneThatTried() {
        let sent = LockedValue<[String]>([])
        let d = makeDispatcher([fold], entries: 2, sent: sent)
        XCTAssertEqual(d.handle(want(1, lane: "pro"), fromEntry: 1), .init(req: 1, id: "Fold.S1"))
        // 未試行のエントリ 0 の要求は、エントリ 1 が走らせている間は終わらせず保留する(対象外で戻ってくるかもしれない)
        XCTAssertNil(d.handle(want(1, lane: "duo"), fromEntry: 0))
        let reply = d.handleNotApplicable(na(2, id: "Fold.S1", lane: "pro"), fromEntry: 1)
        XCTAssertEqual(reply, .init(req: 2, verdict: .handOn))
        XCTAssertEqual(sent.value, ["0:" + WorkQueueProtocol.encode(.init(req: 1, id: "Fold.S1"))],
                       "保留していたエントリ 0 の要求に戻ってきたシナリオが渡る")
        XCTAssertEqual(d.assignedIDs(entry: 1), [], "子は結果を捨てるので、結果の照合に残さない")
        XCTAssertEqual(d.assignedIDs(entry: 0), ["Fold.S1"])
        // 試したエントリ 1 の次の要求には戻さない
        XCTAssertEqual(d.handle(want(3, lane: "pro"), fromEntry: 1), .init(req: 3, none: true),
                       "試したエントリ 1 には戻さず、エントリ 0 が走らせているぶんを待つ理由も無い")
    }

    /// 全エントリが試して対象外: 対象外(緑)で確定
    func testFinalizesSkippedWhenEveryEntryTried() {
        let d = makeDispatcher([fold], entries: 2)
        _ = d.handle(want(1, lane: "pro"), fromEntry: 1)
        XCTAssertEqual(d.handleNotApplicable(na(2, id: "Fold.S1", lane: "pro"), fromEntry: 1), .init(req: 2, verdict: .handOn))
        XCTAssertEqual(d.handle(want(1, lane: "duo"), fromEntry: 0), .init(req: 1, id: "Fold.S1"))
        XCTAssertEqual(d.handleNotApplicable(na(2, id: "Fold.S1", lane: "duo"), fromEntry: 0), .init(req: 2, verdict: .skipped))
    }

    /// 最初から他のエントリが居ない(対象の台が無いプロファイル)は対象外のまま
    func testFinalizesSkippedWhenNoOtherEntryExists() {
        let d = makeDispatcher([fold], entries: 1)
        _ = d.handle(want(1, lane: "pro"), fromEntry: 0)
        XCTAssertEqual(d.handleNotApplicable(na(2, id: "Fold.S1", lane: "pro"), fromEntry: 0), .init(req: 2, verdict: .skipped))
    }

    /// 試していないエントリが落ちた(子が終わった = duo_memo_cmp の形): 実行しなかった赤
    func testFinalizesNotRunWhenTheUntriedEntryLeft() {
        let d = makeDispatcher([fold], entries: 2)
        _ = d.handle(want(1, lane: "pro"), fromEntry: 1)
        d.childExited(entry: 0)
        XCTAssertEqual(d.handleNotApplicable(na(2, id: "Fold.S1", lane: "pro"), fromEntry: 1), .init(req: 2, verdict: .notRun))
    }

    /// 子の中で試していない台が落ちている申告(dep)も「落ちた台」に数える
    func testChildReportedDepartedLaneCountsAsLeft() {
        let d = makeDispatcher([fold], entries: 1)
        _ = d.handle(want(1, lane: "pro"), fromEntry: 0)
        XCTAssertEqual(d.handleNotApplicable(na(2, id: "Fold.S1", lane: "pro", dep: true), fromEntry: 0), .init(req: 2, verdict: .notRun))
    }

    /// デバイスに束ねたクラスのシナリオは機械の外へ回さない(従来どおり対象外)
    func testBoundClassIsNotHandedOn() {
        let bound = Scenario(id: "C.S1", platform: "ios",
                             group: .init(name: "C", placement: .singleDevice, order: 0))
        let d = makeDispatcher([bound], entries: 2)
        _ = d.handle(want(1, lane: "pro"), fromEntry: 1)
        XCTAssertEqual(d.handleNotApplicable(na(2, id: "C.S1", lane: "pro"), fromEntry: 1), .init(req: 2, verdict: .skipped))
    }

    /// 割り当てていないシナリオの問い合わせは回し直さない(偽の問い合わせで pending を増やさない)
    func testUnknownScenarioIsNotHandedOn() {
        let d = makeDispatcher([fold], entries: 2)
        _ = d.handle(want(1, lane: "pro"), fromEntry: 1)
        XCTAssertEqual(d.handleNotApplicable(na(2, id: "Other.S9", lane: "pro"), fromEntry: 1), .init(req: 2, verdict: .skipped))
        XCTAssertEqual(d.unhandedIDs, [])
    }

    /// 戻ってくる見込みが無ければ従来どおり none で終わる(保留しない)
    func testIdleEntryIsAnsweredNoneWhenNothingCanComeBack() {
        let d = makeDispatcher([], entries: 2)
        XCTAssertEqual(d.handle(want(1, lane: "duo"), fromEntry: 0), .init(req: 1, none: true))
    }
    /// 回し直したシナリオは、試したエントリが先に聞き直しても渡さず pending に残る(未試行のエントリがまだ要求を出していないとき)
    func testTriedEntryIsNotHandedTheScenarioBackWhileTheUntriedOneHasNotAsked() {
        let d = makeDispatcher([fold], entries: 2)
        _ = d.handle(want(1, lane: "pro"), fromEntry: 1)
        XCTAssertEqual(d.handleNotApplicable(na(2, id: "Fold.S1", lane: "pro"), fromEntry: 1), .init(req: 2, verdict: .handOn))
        XCTAssertEqual(d.handle(want(3, lane: "pro"), fromEntry: 1), .init(req: 3, none: true))
        XCTAssertEqual(d.unhandedIDs, ["Fold.S1"], "試していないエントリへ渡る機会を残す")
    }

    /// 子の中で別のレーンへ回った分: 宣言するレーンは親が割り当てたレーンと限らない(親はエントリで見る)
    func testDeclaringLaneMayDifferFromTheLaneTheParentAssigned() {
        let d = makeDispatcher([fold], entries: 2)
        XCTAssertEqual(d.handle(want(1, lane: "a"), fromEntry: 1), .init(req: 1, id: "Fold.S1"))
        XCTAssertEqual(d.handleNotApplicable(na(2, id: "Fold.S1", lane: "b"), fromEntry: 1), .init(req: 2, verdict: .handOn))
        XCTAssertEqual(d.assignedIDs(entry: 1), [])
        XCTAssertEqual(d.handle(want(1, lane: "duo"), fromEntry: 0), .init(req: 1, id: "Fold.S1"))
    }
}
