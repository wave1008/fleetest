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
        WorkQueueProtocol.NotApplicable(req: req, unit: ScenarioUnitKey(id: id, variant: nil), lane: lane, platform: "ios", dep: dep)
    }

    private let fold = Scenario(id: "Fold.S1", variant: nil, platform: "ios")

    /// 他のエントリが未試行で生きている: 回し直す。pending へ戻り、試したエントリへは渡さず、未試行のエントリが取る
    func testHandsOnToTheUntriedEntryAndNeverBackToTheOneThatTried() {
        let sent = LockedValue<[String]>([])
        let d = makeDispatcher([fold], entries: 2, sent: sent)
        XCTAssertEqual(d.handle(want(1, lane: "pro"), fromEntry: 1), .init(req: 1, unit: ScenarioUnitKey(id: "Fold.S1", variant: nil)))
        // 未試行のエントリ 0 の要求は、エントリ 1 が走らせている間は終わらせず保留する(対象外で戻ってくるかもしれない)
        XCTAssertNil(d.handle(want(1, lane: "duo"), fromEntry: 0))
        let reply = d.handleNotApplicable(na(2, id: "Fold.S1", lane: "pro"), fromEntry: 1)
        XCTAssertEqual(reply, .init(req: 2, verdict: .handOn))
        XCTAssertEqual(sent.value, ["0:" + WorkQueueProtocol.encode(.init(req: 1, unit: ScenarioUnitKey(id: "Fold.S1", variant: nil)))],
                       "保留していたエントリ 0 の要求に戻ってきたシナリオが渡る")
        XCTAssertEqual(d.assignedUnits(entry: 1), [], "子は結果を捨てるので、結果の照合に残さない")
        XCTAssertEqual(d.assignedUnits(entry: 0), [ScenarioUnitKey(id: "Fold.S1", variant: nil)])
        // 試したエントリ 1 の次の要求には戻さない
        XCTAssertEqual(d.handle(want(3, lane: "pro"), fromEntry: 1), .init(req: 3, none: true),
                       "試したエントリ 1 には戻さず、エントリ 0 が走らせているぶんを待つ理由も無い")
    }

    /// 全エントリが試して対象外: 対象外(緑)で確定
    func testFinalizesSkippedWhenEveryEntryTried() {
        let d = makeDispatcher([fold], entries: 2)
        _ = d.handle(want(1, lane: "pro"), fromEntry: 1)
        XCTAssertEqual(d.handleNotApplicable(na(2, id: "Fold.S1", lane: "pro"), fromEntry: 1), .init(req: 2, verdict: .handOn))
        XCTAssertEqual(d.handle(want(1, lane: "duo"), fromEntry: 0), .init(req: 1, unit: ScenarioUnitKey(id: "Fold.S1", variant: nil)))
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
        let bound = Scenario(id: "C.S1", variant: nil, platform: "ios",
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
        XCTAssertEqual(d.unhandedUnits, [])
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
        XCTAssertEqual(d.unhandedUnits, [ScenarioUnitKey(id: "Fold.S1", variant: nil)], "試していないエントリへ渡る機会を残す")
    }

    /// 子の中で別のレーンへ回った分: 宣言するレーンは親が割り当てたレーンと限らない(親はエントリで見る)
    func testDeclaringLaneMayDifferFromTheLaneTheParentAssigned() {
        let d = makeDispatcher([fold], entries: 2)
        XCTAssertEqual(d.handle(want(1, lane: "a"), fromEntry: 1), .init(req: 1, unit: ScenarioUnitKey(id: "Fold.S1", variant: nil)))
        XCTAssertEqual(d.handleNotApplicable(na(2, id: "Fold.S1", lane: "b"), fromEntry: 1), .init(req: 2, verdict: .handOn))
        XCTAssertEqual(d.assignedUnits(entry: 1), [])
        XCTAssertEqual(d.handle(want(1, lane: "duo"), fromEntry: 0), .init(req: 1, unit: ScenarioUnitKey(id: "Fold.S1", variant: nil)))
    }

    private func kept(_ id: String, on: Bool) -> WorkQueueProtocol.Kept {
        WorkQueueProtocol.Kept(unit: ScenarioUnitKey(id: id, variant: nil), on: on)
    }

    /// 子が機械の中で回し直している最中(`kept`)は、宣言したレーンが次を求めて親のレーンの印が消えても、未試行の他のエントリを
    /// 終わらせない(回帰の E2E-Android: 手元の6台が順に試す間に M1Max が終わり、最後に「未試行の台が落ちた」赤になった)
    func testKeptUnitHoldsTheUntriedEntryAfterTheAssignedLaneMovesOn() {
        let sent = LockedValue<[String]>([])
        let d = makeDispatcher([fold], entries: 2, sent: sent)
        XCTAssertEqual(d.handle(want(1, lane: "a"), fromEntry: 1), .init(req: 1, unit: ScenarioUnitKey(id: "Fold.S1", variant: nil)))
        d.handleKept(kept("Fold.S1", on: true), fromEntry: 1)
        // 子の中で b へ回した後、a は次を求める(親のレーンの印からは Fold が消える)
        XCTAssertEqual(d.handle(want(2, lane: "a"), fromEntry: 1), .init(req: 2, none: true))
        XCTAssertNil(d.handle(want(1, lane: "duo"), fromEntry: 0), "回し直し中の分が戻ってくるかもしれないので終わらせない")
        // 子の中で尽きて親へ聞いてきた: 未試行のエントリ 0 へ回す
        XCTAssertEqual(d.handleNotApplicable(na(3, id: "Fold.S1", lane: "b"), fromEntry: 1), .init(req: 3, verdict: .handOn))
        XCTAssertEqual(sent.value, ["0:" + WorkQueueProtocol.encode(.init(req: 1, unit: ScenarioUnitKey(id: "Fold.S1", variant: nil)))])
    }

    /// 回し直しが子の中で終わった(`kept off`)ら、保留していた未試行のエントリの要求を見直して終わらせる
    func testKeptOffReleasesTheHeldEntry() {
        let sent = LockedValue<[String]>([])
        let d = makeDispatcher([fold], entries: 2, sent: sent)
        _ = d.handle(want(1, lane: "a"), fromEntry: 1)
        d.handleKept(kept("Fold.S1", on: true), fromEntry: 1)
        _ = d.handle(want(2, lane: "a"), fromEntry: 1)
        XCTAssertNil(d.handle(want(1, lane: "duo"), fromEntry: 0))
        d.handleKept(kept("Fold.S1", on: false), fromEntry: 1)
        XCTAssertEqual(sent.value, ["0:" + WorkQueueProtocol.encode(.init(req: 1, none: true))])
    }

    /// 割り当てていない単位の `kept` は無視する(偽の知らせで他のエントリを待たせない)
    func testKeptForAnUnassignedUnitIsIgnored() {
        let d = makeDispatcher([], entries: 2)
        d.handleKept(kept("Other.S9", on: true), fromEntry: 1)
        XCTAssertEqual(d.handle(want(1, lane: "duo"), fromEntry: 0), .init(req: 1, none: true))
    }

    /// 同じエントリの別のレーンが走らせている未試行のシナリオも待つ理由に数える(1回の見直しで同じ子の1本へ渡し、残りへ none を
    /// 返すと、子が渡した単位を記帳する前に none でレーンを終わらせ、後で「試していない台が落ちた」赤になる)
    func testSiblingLaneOfTheSameEntryRunningAnUntriedScenarioHoldsTheRequester() {
        let d = makeDispatcher([fold], entries: 2)
        XCTAssertEqual(d.handle(want(1, lane: "a"), fromEntry: 1), .init(req: 1, unit: ScenarioUnitKey(id: "Fold.S1", variant: nil)))
        XCTAssertNil(d.handle(want(2, lane: "b"), fromEntry: 1), "同じマシンの a が走らせている Fold が対象外で戻ってくるかもしれない")
        // a が普通に終わって次を求めたら待つ理由は無い
        XCTAssertEqual(d.handle(want(3, lane: "a"), fromEntry: 1), .init(req: 3, none: true))
    }
}
