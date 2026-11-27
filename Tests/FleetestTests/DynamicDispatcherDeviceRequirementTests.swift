// 機械をまたぐ動的な割り振りの台の条件(DR-237)の親の配り手の規律。デバイス不要。
// 破ると: 合う台の無い機械へ宣言付きのシナリオが渡る / 合う台の無い機械が回し直しの先に数えられて全員が待ち合う /
// 対象外の確定が「未試行の台が居る」で回し直しになって run が終わらない。

import XCTest
import FTCore
@testable import fleetest

final class DynamicDispatcherDeviceRequirementTests: XCTestCase {
    private typealias Scenario = DynamicSplit.Scenario
    private let fold = Scenario(id: "Fold.S1", variant: nil, platform: "ios")
    private let foldUnit = ScenarioUnitKey(id: "Fold.S1", variant: nil)

    private func make(_ scenarios: [Scenario], entries: Int, candidate: @escaping @Sendable (ScenarioUnitKey, Int) -> Bool,
                      sent: LockedValue<[String]> = LockedValue([])) -> DynamicDispatcher {
        DynamicDispatcher(
            scenarios: scenarios, estimateMs: { _, _ in 1000 }, lpt: true,
            entryPlatforms: Dictionary(uniqueKeysWithValues: (0..<entries).map { ($0, Set(["ios"])) }),
            entryCandidate: candidate, entryKinds: { _ in [:] },
            send: { entry, reply in sent.withLock { $0.append("\(entry):\(WorkQueueProtocol.encode(reply))") } })
    }

    private func want(_ req: Int, lane: String) -> WorkQueueProtocol.Want {
        WorkQueueProtocol.Want(req: req, lane: lane, platform: "ios")
    }

    private func na(_ req: Int, lane: String) -> WorkQueueProtocol.NotApplicable {
        WorkQueueProtocol.NotApplicable(req: req, unit: foldUnit, lane: lane, platform: "ios", dep: false, kinds: [])
    }

    func testDeclaredUnitGoesOnlyToCandidateEntryAndNonCandidateEndsWithoutWaiting() {
        let d = make([fold], entries: 2, candidate: { _, entry in entry == 1 })
        XCTAssertEqual(d.handle(want(1, lane: "a"), fromEntry: 0), .init(req: 1, none: true),
                       "合う台の無い機械は受け取らず、他の機械が走らせている間も待たない(戻ってくる先ではない)")
        XCTAssertEqual(d.handle(want(1, lane: "b"), fromEntry: 1), .init(req: 1, unit: foldUnit))
        XCTAssertEqual(d.assignedUnits(entry: 0), [])
    }

    /// 同じ並びでも、全エントリが候補なら従来どおり(試していない台へ回し直す)
    func testAllCandidatesKeepsTheHandOnAndNonCandidateCountsAsTried() {
        let open = make([fold], entries: 2, candidate: { _, _ in true })
        XCTAssertEqual(open.handle(want(1, lane: "b"), fromEntry: 1), .init(req: 1, unit: foldUnit))
        XCTAssertEqual(open.handleNotApplicable(na(2, lane: "b"), fromEntry: 1), .init(req: 2, verdict: .handOn))

        let gated = make([fold], entries: 2, candidate: { _, entry in entry == 1 })
        XCTAssertEqual(gated.handle(want(1, lane: "b"), fromEntry: 1), .init(req: 1, unit: foldUnit))
        XCTAssertEqual(gated.handleNotApplicable(na(2, lane: "b"), fromEntry: 1), .init(req: 2, verdict: .skipped),
                       "合う台の無い機械は試した扱い = 回し直す先が無く、対象外(緑)で確定")
        XCTAssertTrue(gated.unhandedUnits.isEmpty)
    }

    /// 宣言の無い単位(候補が常に true)は、候補の判定が他の単位へ波及しない
    func testUnconstrainedUnitIsStillHandedToEveryEntry() {
        let other = Scenario(id: "Plain.S1", variant: nil, platform: "ios")
        let d = make([fold, other], entries: 2, candidate: { unit, entry in unit.id != "Fold.S1" || entry == 1 })
        XCTAssertEqual(d.handle(want(1, lane: "a"), fromEntry: 0), .init(req: 1, unit: ScenarioUnitKey(id: "Plain.S1", variant: nil)))
    }
}
