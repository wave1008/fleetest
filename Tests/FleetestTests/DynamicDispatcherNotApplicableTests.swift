// 対象外で終わったシナリオの回し直し(DR-214)の親の配り手の規律。デバイス不要。
// 破ると: 折りたためる端末の居るマシンが落ちた run が 0 本実行の緑で終わる / 試したマシンへ同じシナリオを戻す /
// 回し直した分が子の結果の照合(assigned)に残って「結果が無い」になる / 尽きたマシンが戻ってくる分を待たずに終わる。

import XCTest
import FTCore
@testable import fleetest

final class DynamicDispatcherNotApplicableTests: XCTestCase {
    private typealias Scenario = DynamicSplit.Scenario

    private func makeDispatcher(_ scenarios: [Scenario], entries: Int,
                                sent: LockedValue<[String]> = LockedValue([]),
                                kinds: @escaping @Sendable (String) -> [Int: Set<String>] = { _ in [:] }) -> DynamicDispatcher {
        DynamicDispatcher(
            scenarios: scenarios,
            estimateMs: { _, _ in 1000 },
            lpt: true,
            entryPlatforms: Dictionary(uniqueKeysWithValues: (0..<entries).map { ($0, Set(["ios"])) }),
            entryCandidate: { _, _ in true },
            entryKinds: kinds,
            send: { entry, reply in sent.withLock { $0.append("\(entry):\(WorkQueueProtocol.encode(reply))") } })
    }

    private func want(_ req: Int, lane: String) -> WorkQueueProtocol.Want {
        WorkQueueProtocol.Want(req: req, lane: lane, platform: "ios")
    }

    private func na(_ req: Int, id: String, lane: String, dep: Bool = false, kinds: Set<String> = []) -> WorkQueueProtocol.NotApplicable {
        WorkQueueProtocol.NotApplicable(req: req, unit: ScenarioUnitKey(id: id, variant: nil), lane: lane, platform: "ios", dep: dep, kinds: kinds)
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

    /// 同じ観測の種類のエントリは試した扱い(DR-214・iOS だけ): 回し直さず対象外で確定し、覆ったエントリへ単位を渡さない
    func testSameKindEntryCountsAsTriedAndIsNeverHandedTheUnit() {
        let sent = LockedValue<[String]>([])
        let resolved = LockedValue<[String]>([])
        let d = makeDispatcher([fold], entries: 2, sent: sent, kinds: { platform in
            resolved.withLock { $0.append(platform) }
            return [0: ["pro|ios27"], 1: ["pro|ios27"]]
        })
        XCTAssertEqual(d.handle(want(1, lane: "pro"), fromEntry: 0), .init(req: 1, unit: ScenarioUnitKey(id: "Fold.S1", variant: nil)))
        XCTAssertEqual(d.handleNotApplicable(na(2, id: "Fold.S1", lane: "pro", kinds: ["pro|ios27"]), fromEntry: 0),
                       .init(req: 2, verdict: .skipped))
        XCTAssertEqual(resolved.value, ["ios"])
        XCTAssertEqual(d.assignedUnits(entry: 1), [])
        XCTAssertTrue(sent.value.isEmpty)
    }

    /// 3つのうち2つが同じ種類: 回し直す先は種類の違うエントリだけ。覆ったエントリの要求には渡さない(子を起こすだけの空振りを作らない)
    func testCoveredEntryIsSkippedWhenHandingOn() {
        let sent = LockedValue<[String]>([])
        let d = makeDispatcher([fold], entries: 3, sent: sent, kinds: { _ in [0: ["pro"], 1: ["pro"], 2: ["fold"]] })
        XCTAssertEqual(d.handle(want(1, lane: "pro"), fromEntry: 0), .init(req: 1, unit: ScenarioUnitKey(id: "Fold.S1", variant: nil)))
        XCTAssertEqual(d.handleNotApplicable(na(2, id: "Fold.S1", lane: "pro", kinds: ["pro"]), fromEntry: 0), .init(req: 2, verdict: .handOn))
        XCTAssertEqual(d.handle(want(1, lane: "pro"), fromEntry: 1), .init(req: 1, none: true),
                       "覆ったエントリ 1 へは渡さず、戻ってくる見込みも無い")
        XCTAssertEqual(d.assignedUnits(entry: 1), [])
        XCTAssertEqual(d.handle(want(1, lane: "fold"), fromEntry: 2), .init(req: 1, unit: ScenarioUnitKey(id: "Fold.S1", variant: nil)))
    }

    /// iOS の対象外で引いた種類で、Android の対象外を覆わない(両 OS の台を持つマシンが2台の run。先に iOS の対象外が来た形)
    func testIOSKindsNeverCoverAnAndroidUnit() {
        let iosFold = Scenario(id: "Fold.S1", variant: nil, platform: "ios")
        let androidFold = Scenario(id: "AFold.S1", variant: nil, platform: "android")
        let d = DynamicDispatcher(
            scenarios: [iosFold, androidFold], estimateMs: { _, _ in 1000 }, lpt: true,
            entryPlatforms: [0: ["ios", "android"], 1: ["ios", "android"]],
            entryCandidate: { _, _ in true },
            entryKinds: { _ in [0: ["pro"], 1: ["pro"]] }, send: { _, _ in })
        XCTAssertEqual(d.handle(want(1, lane: "pro"), fromEntry: 0), .init(req: 1, unit: ScenarioUnitKey(id: "Fold.S1", variant: nil)))
        XCTAssertEqual(d.handleNotApplicable(na(2, id: "Fold.S1", lane: "pro", kinds: ["pro"]), fromEntry: 0), .init(req: 2, verdict: .skipped),
                       "同じ iOS の種類のエントリ 1 は覆われる")
        let androidWant = WorkQueueProtocol.Want(req: 3, lane: "pixel", platform: "android")
        XCTAssertEqual(d.handle(androidWant, fromEntry: 0), .init(req: 3, unit: ScenarioUnitKey(id: "AFold.S1", variant: nil)))
        let androidNA = WorkQueueProtocol.NotApplicable(
            req: 4, unit: ScenarioUnitKey(id: "AFold.S1", variant: nil), lane: "pixel", platform: "android", dep: false, kinds: ["pro"])
        XCTAssertEqual(d.handleNotApplicable(androidNA, fromEntry: 0), .init(req: 4, verdict: .handOn),
                       "Android の台は iOS の種類で覆わない = エントリ 1 の Android の台で試す")
        XCTAssertEqual(d.handle(WorkQueueProtocol.Want(req: 5, lane: "pixel", platform: "android"), fromEntry: 1),
                       .init(req: 5, unit: ScenarioUnitKey(id: "AFold.S1", variant: nil)))
    }

    /// 覆いの証拠は子が送った種類(`na.kinds`)だけ。エントリの種類の見込みが同じでも、子が観測を送らなければ覆わない
    /// (子が実際に使った台は、プロファイルを引き直した台と限らない)
    func testEntryKindsAloneAreNotEvidence() {
        let d = makeDispatcher([fold], entries: 2, kinds: { _ in [0: ["pro"], 1: ["pro"]] })
        _ = d.handle(want(1, lane: "pro"), fromEntry: 0)
        XCTAssertEqual(d.handleNotApplicable(na(2, id: "Fold.S1", lane: "pro"), fromEntry: 0), .init(req: 2, verdict: .handOn))
        XCTAssertEqual(d.handle(want(1, lane: "pro"), fromEntry: 1), .init(req: 1, unit: ScenarioUnitKey(id: "Fold.S1", variant: nil)))
    }

    /// 種類が違う・不明なエントリは覆わない。resolver は platform ごとに1回だけ引く
    func testDifferentOrUnknownKindStillHandsOn() {
        for kinds: [Int: Set<String>] in [[0: ["pro"], 1: ["fold"]], [0: ["pro"]], [:], [0: ["pro"], 1: []]] {
            let calls = LockedValue(0)
            let d = makeDispatcher([fold], entries: 2, kinds: { _ in calls.withLock { $0 += 1 }; return kinds })
            _ = d.handle(want(1, lane: "pro"), fromEntry: 0)
            XCTAssertEqual(d.handleNotApplicable(na(2, id: "Fold.S1", lane: "pro", kinds: ["pro"]), fromEntry: 0),
                           .init(req: 2, verdict: .handOn), "\(kinds)")
            XCTAssertEqual(d.handle(want(1, lane: "duo"), fromEntry: 1), .init(req: 1, unit: ScenarioUnitKey(id: "Fold.S1", variant: nil)))
            _ = d.handleNotApplicable(na(3, id: "Fold.S1", lane: "duo"), fromEntry: 1)
            XCTAssertEqual(calls.value, 1)
        }
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

    /// 仮置き(BacklogPlacement)は、そのシナリオを試したエントリのレーンを置き場に数えない(11/26 のフル E2E で run が止まった)。
    /// 数えると、試したエントリの空いたレーンが「一番早く終わる置き場」に選ばれ、取れるレーンが全部それを待って保留し、
    /// 空いたレーンしか無いので見直しの時刻も作られず run が止まる(フル E2E の E2E-Android: 手元と M4Max が互いに相手の
    /// 試したシナリオを待ち、未試行の M1Max も待った。M4Max を止めた瞬間に手元が S0020 を取った)
    func testPlacementDoesNotParkAHandedBackScenarioOnALaneOfAnEntryThatTriedIt() {
        let a = Scenario(id: "Fold.S1", variant: nil, platform: "ios")
        let b = Scenario(id: "Fold.S2", variant: nil, platform: "ios")
        let keyA = ScenarioUnitKey(id: "Fold.S1", variant: nil)
        let keyB = ScenarioUnitKey(id: "Fold.S2", variant: nil)
        // A はエントリ 0 で速く、B はエントリ 1 で速い。エントリ 2 はどちらも遅い(未試行の遅いマシン = M1Max の役)
        let costs: [String: [Int: Double]] = ["Fold.S1": [0: 1000, 1: 2000, 2: 5000],
                                              "Fold.S2": [0: 2000, 1: 1000, 2: 5000]]
        let sent = LockedValue<[String]>([])
        let d = DynamicDispatcher(
            scenarios: [a, b],
            estimateMs: { scenario, entry in costs[scenario.id]![entry]! },
            nowMs: { 0 },
            timer: { _, _ in {} },
            lpt: false,
            entryPlatforms: [0: ["ios"], 1: ["ios"], 2: ["ios"]],
            entryCandidate: { _, _ in true },
            entryKinds: { _ in [:] },
            send: { entry, reply in sent.withLock { $0.append("\(entry):\(WorkQueueProtocol.encode(reply))") } })
        XCTAssertEqual(d.handle(want(1, lane: "x"), fromEntry: 0), .init(req: 1, unit: keyA))
        XCTAssertEqual(d.handle(want(1, lane: "y"), fromEntry: 1), .init(req: 1, unit: keyB))
        XCTAssertNil(d.handle(want(1, lane: "m"), fromEntry: 2), "A・B が対象外で戻ってくるかもしれないので保留")
        XCTAssertEqual(d.handleNotApplicable(na(2, id: "Fold.S1", lane: "x"), fromEntry: 0), .init(req: 2, verdict: .handOn))
        XCTAssertNil(d.handle(want(3, lane: "x"), fromEntry: 0), "B はエントリ 0 が未試行で、まだエントリ 1 で走っている")
        XCTAssertEqual(d.handleNotApplicable(na(2, id: "Fold.S2", lane: "y"), fromEntry: 1), .init(req: 2, verdict: .handOn))
        let yReply = d.handle(want(3, lane: "y"), fromEntry: 1)
        let handed = sent.value + (yReply.map { ["1:" + WorkQueueProtocol.encode($0)] } ?? [])
        XCTAssertTrue(handed.contains("0:" + WorkQueueProtocol.encode(.init(req: 3, unit: keyB))),
                      "B を試していないエントリ 0 が B を取る(試したエントリ 1 のレーンを置き場に数えない): \(handed)")
        XCTAssertTrue(handed.contains("1:" + WorkQueueProtocol.encode(.init(req: 3, unit: keyA))),
                      "A を試していないエントリ 1 が A を取る: \(handed)")
        XCTAssertEqual(d.unhandedUnits, [])
    }
}
