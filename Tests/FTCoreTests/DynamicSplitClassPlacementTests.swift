// DynamicSplit.decide のクラスの寄せ方(RR-8.3 の束ね方・束ねる前の見込み)。期待値は手計算で固定する。

import XCTest
@testable import FTCore

final class DynamicSplitClassPlacementTests: XCTestCase {

    private typealias S = DynamicSplit.Scenario
    private typealias L = DynamicSplit.Lane
    private typealias State = DynamicSplit.LaneState
    private typealias G = DynamicSplit.Group

    private func plain(_ id: String, _ platform: String = "ios") -> S { S(id: id, variant: nil, platform: platform) }
    private func member(_ id: String, _ placement: ClassPlacement, order: Int? = nil,
                        platform: String = "ios") -> S {
        let name = String(id.prefix { $0 != "." })
        return S(id: id, variant: nil, platform: platform, group: G(name: name, placement: placement, order: order))
    }
    private func lane(_ entry: Int, _ name: String, _ platform: String = "ios") -> L {
        L(entry: entry, lane: name, platform: platform)
    }
    /// id → [entry ごとの見込み]。表に無い id は全エントリ 10s
    private func table(_ values: [String: [Double]]) -> (S, Int) -> Double {
        { scenario, entry in values[scenario.id]?[entry] ?? 10_000 }
    }

    // MARK: - 規則1: 束ねたレーンは次を必ず取る

    func testBoundLaneAlwaysGetsNextOfItsClassInOrderEvenWhenOthersAreLonger() {
        let a = lane(0, "a"), b = lane(1, "b")
        var bindings = DynamicSplit.Bindings()
        bindings.record(member("O.t1", .inOrder, order: 1), to: a)
        let decision = DynamicSplit.decide(
            for: a, now: 0,
            pending: [plain("Long"), member("O.t3", .inOrder, order: 3), member("O.t2", .inOrder, order: 2)],
            lanes: [State(lane: a, busy: nil), State(lane: b, busy: nil)],
            estimateMs: table(["Long": [90_000, 90_000]]), bindings: bindings)
        XCTAssertEqual(decision, .assign(ScenarioUnitKey(id: "O.t2", variant: nil)))
    }

    /// 束ねたクラスの次は「バリアントの宣言順 → order 順」。v1 の残りが先で、v2 の t1 が割り込まない
    func testBoundLaneTakesTheClassVariantByVariant() {
        func unit(_ id: String, _ variant: String, rank: Int, order: Int) -> S {
            S(id: id, variant: variant, platform: "ios",
              group: G(name: "O", placement: .inOrder, order: order), variantRank: rank)
        }
        let a = lane(0, "a")
        var bindings = DynamicSplit.Bindings()
        bindings.record(unit("O.t1", "v1", rank: 0, order: 1), to: a)
        let pending = [unit("O.t1", "v2", rank: 1, order: 1), unit("O.t2", "v2", rank: 1, order: 2),
                       unit("O.t2", "v1", rank: 0, order: 2)]
        let decision = DynamicSplit.decide(
            for: a, now: 0, pending: pending, lanes: [State(lane: a, busy: nil)],
            estimateMs: table([:]), bindings: bindings)
        XCTAssertEqual(decision, .assign(ScenarioUnitKey(id: "O.t2", variant: "v1")))
    }

    func testBoundLaneSingleDeviceNextFollowsID() {
        let a = lane(0, "a")
        var bindings = DynamicSplit.Bindings()
        bindings.record(member("D.x", .singleDevice), to: a)
        XCTAssertEqual(
            DynamicSplit.decide(for: a, now: 0, pending: [member("D.z", .singleDevice), member("D.y", .singleDevice)],
                                lanes: [State(lane: a, busy: nil)], estimateMs: table([:]), bindings: bindings),
            .assign(ScenarioUnitKey(id: "D.y", variant: nil)))
    }

    func testBoundLaneWithNoPendingOfItsClassFallsBackToNormalDecision() {
        let a = lane(0, "a")
        var bindings = DynamicSplit.Bindings()
        bindings.record(member("O.t1", .inOrder, order: 1), to: a)
        XCTAssertEqual(
            DynamicSplit.decide(for: a, now: 0, pending: [plain("X")], lanes: [State(lane: a, busy: nil)],
                                estimateMs: table([:]), bindings: bindings),
            .assign(ScenarioUnitKey(id: "X", variant: nil)))
    }

    // MARK: - 規則2: 束ねたクラスは他へ渡さない

    func testOtherLaneNeverGetsDeviceBoundClass() {
        let a = lane(0, "a"), b = lane(1, "b")
        var bindings = DynamicSplit.Bindings()
        bindings.record(member("O.t1", .inOrder, order: 1), to: a)
        let lanes = [State(lane: a, busy: (plain("run"), 0)), State(lane: b, busy: nil)]
        XCTAssertEqual(
            DynamicSplit.decide(for: b, now: 0, pending: [member("O.t2", .inOrder, order: 2)], lanes: lanes,
                                estimateMs: table([:]), bindings: bindings),
            .none)
        XCTAssertEqual(
            DynamicSplit.decide(for: b, now: 0, pending: [member("O.t2", .inOrder, order: 2), plain("X")],
                                lanes: lanes, estimateMs: table([:]), bindings: bindings),
            .assign(ScenarioUnitKey(id: "X", variant: nil)))
    }

    func testSingleMachineBoundClassIsOnlyForItsEntry() {
        let a0 = lane(0, "a0"), a1 = lane(0, "a1"), b = lane(1, "b")
        var bindings = DynamicSplit.Bindings()
        bindings.record(member("M.s1", .singleMachine), to: a0)
        let lanes = [State(lane: a0, busy: (plain("run"), 0)), State(lane: a1, busy: nil), State(lane: b, busy: nil)]
        let pending = [member("M.s2", .singleMachine)]
        XCTAssertEqual(DynamicSplit.decide(for: b, now: 0, pending: pending, lanes: lanes,
                                           estimateMs: table([:]), bindings: bindings), .none)
        // 同じエントリのレーンは個別のジョブとして取れる(クラスの中は並列)
        XCTAssertEqual(DynamicSplit.decide(for: a1, now: 0, pending: pending, lanes: lanes,
                                           estimateMs: table([:]), bindings: bindings), .assign(ScenarioUnitKey(id: "M.s2", variant: nil)))
    }

    func testUnboundSingleMachineClassNotGivenToEntryMissingItsOS() {
        let ios = lane(0, "i"), android = lane(1, "a", "android")
        let pending = [member("M.s1", .singleMachine), member("M.s2", .singleMachine, platform: "android")]
        let lanes = [State(lane: ios, busy: nil), State(lane: android, busy: nil)]
        let platforms: [Int: Set<String>] = [0: ["ios"], 1: ["android"]]
        XCTAssertEqual(DynamicSplit.decide(for: ios, now: 0, pending: pending, lanes: lanes,
                                           estimateMs: table([:]), entryPlatforms: platforms), .none)
        XCTAssertEqual(DynamicSplit.decide(for: android, now: 0, pending: pending, lanes: lanes,
                                           estimateMs: table([:]), entryPlatforms: platforms), .none)
        // 両 OS を持つエントリなら渡す。entryPlatforms に無いエントリは検査しない
        XCTAssertEqual(DynamicSplit.decide(for: ios, now: 0, pending: pending, lanes: lanes,
                                           estimateMs: table([:]), entryPlatforms: [0: ["ios", "android"]]),
                       .assign(ScenarioUnitKey(id: "M.s1", variant: nil)))
        XCTAssertEqual(DynamicSplit.decide(for: ios, now: 0, pending: pending, lanes: lanes,
                                           estimateMs: table([:])), .assign(ScenarioUnitKey(id: "M.s1", variant: nil)))
    }

    // MARK: - 規則3: 塊の重さ

    func testChunkRepresentativeIsFirstByOrderThenID() {
        let a = lane(0, "a")
        XCTAssertEqual(
            DynamicSplit.decide(for: a, now: 0,
                                pending: [member("O.b", .inOrder, order: 2), member("O.a", .inOrder, order: 1)],
                                lanes: [State(lane: a, busy: nil)], estimateMs: table([:])),
            .assign(ScenarioUnitKey(id: "O.a", variant: nil)))
    }

    func testSlowLaneDoesNotTakeBigDeviceClassByItsFirstTestAlone() {
        let fast = lane(0, "fast"), slow = lane(1, "slow")
        let estimate = table(["run": [60_000, 60_000],
                              "O.a": [10_000, 40_000], "O.b": [10_000, 40_000], "O.c": [10_000, 40_000]])
        let pending = [member("O.a", .inOrder, order: 1), member("O.b", .inOrder, order: 2),
                       member("O.c", .inOrder, order: 3)]
        let lanes = [State(lane: fast, busy: (plain("run"), 0)), State(lane: slow, busy: nil)]
        // 塊 = 遅いレーンで 120s、速いレーンは 60s + 30s = 90s で終わる → 待つ(先頭1本だけ 40s なら取っていた)
        XCTAssertEqual(DynamicSplit.decide(for: slow, now: 0, pending: pending, lanes: lanes, estimateMs: estimate),
                       .hold(reconsiderAt: 60_000))
        XCTAssertEqual(DynamicSplit.decide(for: slow, now: 0, pending: [pending[0]], lanes: lanes, estimateMs: estimate),
                       .assign(ScenarioUnitKey(id: "O.a", variant: nil)))
    }

    func testSingleMachineChunkWeightIsDividedByLanesOfThatEntry() {
        let fast = lane(0, "fast"), s1 = lane(1, "s1"), s2 = lane(1, "s2")
        let estimate = table(["run": [60_000, 60_000],
                              "M.a": [10_000, 40_000], "M.b": [10_000, 40_000], "M.c": [10_000, 40_000]])
        let pending = [member("M.a", .singleMachine), member("M.b", .singleMachine), member("M.c", .singleMachine)]
        let lanes = [State(lane: fast, busy: (plain("run"), 0)), State(lane: s1, busy: nil), State(lane: s2, busy: nil)]
        // 遅いエントリは 2 レーン: 120s ÷ 2 = 60s < 速いほうの 60s + 30s = 90s → 取る
        XCTAssertEqual(DynamicSplit.decide(for: s1, now: 0, pending: pending, lanes: lanes, estimateMs: estimate),
                       .assign(ScenarioUnitKey(id: "M.a", variant: nil)))
        // 同じ見込みでも1台だけのエントリなら 120s で待つ
        XCTAssertEqual(DynamicSplit.decide(for: s1, now: 0, pending: pending,
                                           lanes: [lanes[0], lanes[1]], estimateMs: estimate),
                       .hold(reconsiderAt: 60_000))
    }

    // MARK: - 記帳

    func testBindingsRecordKeepsFirstBindingAndIgnoresUngrouped() {
        let a = lane(0, "a"), b = lane(1, "b")
        var bindings = DynamicSplit.Bindings()
        bindings.record(plain("X"), to: a)
        XCTAssertEqual(bindings, DynamicSplit.Bindings())
        bindings.record(member("M.s", .singleMachine), to: a)
        bindings.record(member("M.t", .singleMachine), to: b)
        bindings.record(member("D.s", .singleDevice), to: b)
        bindings.record(member("D.t", .singleDevice), to: a)
        XCTAssertEqual(bindings.machine, ["M": 0])
        XCTAssertEqual(bindings.device, ["D": b])
    }
}
