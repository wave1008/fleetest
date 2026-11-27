import XCTest
@testable import FTCore

/// クラスの寄せ方(RR-8.3)のマシンの中のキュー: 束ね・続けて取る・振り直し・離脱の残り・@RunInOrder の失敗の後
final class ScenarioQueueClassPlacementTests: XCTestCase {
    private func item(_ id: String, _ placement: ClassPlacement? = nil, order: Int? = nil) -> ScenarioRunItem {
        ScenarioRunItem(info: ScenarioInfo(id: id, title: id, platform: "ios", placement: placement, order: order), variant: nil)
    }

    private func ids(_ items: [ScenarioRunItem]) -> [String] { items.map(\.info.id) }

    func testBoundClassIsNotTakenByOtherLaneAndBoundLaneContinuesIt() async {
        let queue = ScenarioQueue([item("A.s1", .singleDevice), item("A.s2", .singleDevice), item("B.s1"), item("A.s3", .singleDevice)])
        await queue.laneJoined("L1")
        await queue.laneJoined("L2")
        let first = await queue.next(lane: "L1")
        XCTAssertEqual(first?.info.id, "A.s1")
        // L2 は A を取らず B を取る
        let other = await queue.next(lane: "L2")
        XCTAssertEqual(other?.info.id, "B.s1")
        // L1 は他を挟まず A の残りを続ける
        let second = await queue.next(lane: "L1")
        let third = await queue.next(lane: "L1")
        XCTAssertEqual([second?.info.id, third?.info.id], ["A.s2", "A.s3"])
    }

    func testRemainingOnlyOtherLanesClassEndsWithoutWaiting() async {
        let queue = ScenarioQueue([item("A.s1", .singleDevice), item("A.s2", .singleDevice)])
        await queue.laneJoined("L1")
        await queue.laneJoined("L2")
        _ = await queue.next(lane: "L1")
        let none = await queue.next(lane: "L2", shouldStop: { false })
        XCTAssertNil(none, "A は L1 に束ねたので、L2 は待たずに終わる")
        let hasForL2 = await queue.hasItems(lane: "L2")
        let hasForL1 = await queue.hasItems(lane: "L1")
        XCTAssertFalse(hasForL2)
        XCTAssertTrue(hasForL1)
    }

    func testRequeuedBoundItemReturnsToClassFrontAndSameLaneTakesIt() async {
        let queue = ScenarioQueue([item("A.s1", .singleDevice), item("A.s2", .singleDevice)])
        await queue.laneJoined("L1")
        await queue.laneJoined("L2")
        let first = await queue.next(lane: "L1")!
        // avoiding を掛けても束ねたクラスは別レーン優先にしない
        let attempt = await queue.requeue(first, avoiding: "L1")
        XCTAssertEqual(attempt, 1)
        let again = await queue.next(lane: "L1")
        XCTAssertEqual(again?.info.id, "A.s1")
        let next = await queue.next(lane: "L1")
        XCTAssertEqual(next?.info.id, "A.s2")
    }

    func testLaneEndedReturnsRemainingOfItsBoundClassOnly() async {
        let queue = ScenarioQueue([item("A.s1", .singleDevice), item("A.s2", .singleDevice), item("B.s1")])
        await queue.laneJoined("L1")
        await queue.laneJoined("L2")
        _ = await queue.next(lane: "L1")
        let orphans = await queue.laneEnded("L1")
        XCTAssertEqual(ids(orphans), ["A.s2"])
        let rest = await queue.nextLocal()
        XCTAssertEqual(rest?.info.id, "B.s1")
        let end = await queue.nextLocal()
        XCTAssertNil(end)
    }

    func testLaneEndedWithoutOrphaningKeepsItems() async {
        let queue = ScenarioQueue([item("A.s1", .singleDevice), item("A.s2", .singleDevice)])
        await queue.laneJoined("L1")
        _ = await queue.next(lane: "L1")
        let orphans = await queue.laneEnded("L1", orphaning: false)
        XCTAssertTrue(orphans.isEmpty)
        let rest = await queue.nextLocal()
        XCTAssertEqual(rest?.info.id, "A.s2")
    }

    func testInOrderClassIsOrderedByOrderAndAbandonReturnsRest() async {
        let queue = ScenarioQueue([item("O.s3", .inOrder, order: 3), item("X.s1"), item("O.s1", .inOrder, order: 1),
                                   item("O.s2", .inOrder, order: 2)])
        await queue.laneJoined("L1")
        let first = await queue.next(lane: "L1")!
        XCTAssertEqual(first.info.id, "O.s1")
        let rest = await queue.abandonInOrderClass(after: first, lane: "L1")
        XCTAssertEqual(ids(rest), ["O.s2", "O.s3"])
        let left = await queue.nextLocal()
        XCTAssertEqual(left?.info.id, "X.s1")
    }

    func testAbandonIgnoresNonInOrderAndGateStopsLaterOnes() async {
        let queue = ScenarioQueue([item("D.s1", .singleDevice), item("D.s2", .singleDevice)])
        let first = await queue.next(lane: "L1")!
        let none = await queue.abandonInOrderClass(after: first, lane: "L1")
        XCTAssertTrue(none.isEmpty, "@RunOnSingleDevice は失敗の後も続ける")
        let skip = await queue.inOrderSkipReason(for: item("D.s2", .singleDevice), lane: "L1")
        XCTAssertNil(skip)

        let ordered = ScenarioQueue([])
        let failed = item("O.s1", .inOrder, order: 1)
        _ = await ordered.abandonInOrderClass(after: failed, lane: "L1")
        let reason = await ordered.inOrderSkipReason(for: item("O.s2", .inOrder, order: 2), lane: "L1")
        XCTAssertNotNil(reason)
        let otherLane = await ordered.inOrderSkipReason(for: item("O.s2", .inOrder, order: 2), lane: "L2")
        XCTAssertNil(otherLane, "失敗の記帳はレーンごと")
    }

    func testSingleMachineAndPlainItemsKeepOriginalBehavior() async {
        let queue = ScenarioQueue([item("M.s1", .singleMachine), item("P.s1"), item("M.s2", .singleMachine)])
        await queue.laneJoined("L1")
        await queue.laneJoined("L2")
        let a = await queue.next(lane: "L1")
        let b = await queue.next(lane: "L2")
        let c = await queue.next(lane: "L2")
        XCTAssertEqual([a, b, c].map { $0?.info.id }, ["M.s1", "P.s1", "M.s2"])
        let requeued = await queue.requeue(a!, avoiding: "L1")
        XCTAssertEqual(requeued, 1)
        let back = await queue.next(lane: "L2")
        XCTAssertEqual(back?.info.id, "M.s1", "寄せない item は従来どおり末尾へ・別レーン優先")
    }

    func testPositionNoticeOnlyForInOrder() async {
        let queue = ScenarioQueue([item("O.s1", .inOrder, order: 1), item("O.s2", .inOrder, order: 2), item("P.s1")])
        let notice = await queue.positionNotice(for: item("O.s2", .inOrder, order: 2))
        XCTAssertNotNil(notice)
        let none = await queue.positionNotice(for: item("P.s1"))
        XCTAssertNil(none)
    }

    /// broadcast は各レーンが自分のキューを持つ。どのレーンでも順番が守られ、他のレーンの束ねに影響されない
    func testBroadcastLanesEachKeepOrderIndependently() async {
        let plan = BroadcastPlan.make(
            items: [item("O.s2", .inOrder, order: 2), item("O.s1", .inOrder, order: 1)],
            lanes: [BroadcastLane(key: "L1", platform: "ios"), BroadcastLane(key: "L2", platform: "ios")])
        for lane in ["L1", "L2"] {
            let queue = ScenarioQueue(plan.queues[lane] ?? [])
            let a = await queue.next(lane: lane)
            let b = await queue.next(lane: lane)
            XCTAssertEqual([a, b].map { $0?.info.id }, ["O.s1", "O.s2"], lane)
        }
    }

    /// `--port` 直指定のワーカーは論理名を持たない。レーン名が空のままだと全員が束ねたレーン本人と見なされ、
    /// デバイスに束ねたクラスが複数のデバイスで同時に走る(レーン名はラベルで区別する)
    func testWorkersWithoutLogicalNameAreDistinctLanes() async {
        let a = RunWorker(label: "ios:8100", platform: "ios", driver: LaneTestDriver(),
                          connection: DriverConnection(platform: "ios"), deviceKind: nil)
        let b = RunWorker(label: "ios:8101", platform: "ios", driver: LaneTestDriver(),
                          connection: DriverConnection(platform: "ios"), deviceKind: nil)
        XCTAssertNotEqual(ScenarioQueue.lane(of: a), ScenarioQueue.lane(of: b))
        let queue = ScenarioQueue([item("D.s1", .singleDevice), item("D.s2", .singleDevice), item("P.s1")])
        let first = await queue.next(lane: ScenarioQueue.lane(of: a))
        let second = await queue.next(lane: ScenarioQueue.lane(of: b))
        XCTAssertEqual(first?.info.id, "D.s1")
        XCTAssertEqual(second?.info.id, "P.s1", "束ねたクラスは論理名の無い別のワーカーへ渡らない")
    }

    // MARK: - バリアント(実行の単位 = シナリオ × バリアント)

    private func unit(_ id: String, _ variant: String?, _ placement: ClassPlacement? = nil, order: Int? = nil) -> ScenarioRunItem {
        ScenarioRunItem(info: ScenarioInfo(id: id, title: id, platform: "ios", placement: placement, order: order), variant: variant)
    }

    private func drain(_ queue: ScenarioQueue, lane: String) async -> [String] {
        var keys: [String] = []
        while let next = await queue.next(lane: lane, shouldStop: { true }) { keys.append(next.unitKey.description) }
        return keys
    }

    /// 寄せるクラスは同じ台のまま「バリアントごとに続けて(宣言順)→ その中は order 順」に並ぶ
    func testInOrderClassRunsVariantByVariantOnOneLane() async {
        let queue = ScenarioQueue([
            unit("O.t2", "v1", .inOrder, order: 2), unit("P.x", "v1"), unit("O.t1", "v2", .inOrder, order: 1),
            unit("O.t1", "v1", .inOrder, order: 1), unit("O.t2", "v2", .inOrder, order: 2),
        ])
        await queue.laneJoined("L1")
        await queue.laneJoined("L2")
        let first = await queue.next(lane: "L1")
        XCTAssertEqual(first?.unitKey.description, "O.t1@v1")
        let rest = await drain(queue, lane: "L1")
        XCTAssertEqual(rest, ["O.t2@v1", "O.t1@v2", "O.t2@v2", "P.x@v1"], "束ねたレーンが他を挟まずクラスの全バリアントを続けて取る")
    }

    /// 順番の途中の失敗で止めるのは同じバリアントのまとまりの中だけ。母数もまとまりの中で数える
    func testInOrderFailureStopsOnlyTheSameVariantGroup() async {
        let queue = ScenarioQueue([
            unit("O.t1", "v1", .inOrder, order: 1), unit("O.t2", "v1", .inOrder, order: 2),
            unit("O.t1", "v2", .inOrder, order: 1), unit("O.t2", "v2", .inOrder, order: 2),
        ])
        await queue.laneJoined("L1")
        let first = await queue.next(lane: "L1")!
        XCTAssertEqual(first.unitKey.description, "O.t1@v1")
        let notice = await queue.positionNotice(for: first)
        XCTAssertEqual(notice, "@RunInOrder: test 1 of 2 in O", "母数はバリアントのまとまりの中(4本ではなく2本)")
        let abandoned = await queue.abandonInOrderClass(after: first, lane: "L1")
        XCTAssertEqual(abandoned.map { $0.unitKey.description }, ["O.t2@v1"])
        let rest = await drain(queue, lane: "L1")
        XCTAssertEqual(rest, ["O.t1@v2", "O.t2@v2"], "v1 の失敗が v2 を止めない")
        let v1 = await queue.inOrderSkipReason(for: unit("O.t2", "v1", .inOrder, order: 2), lane: "L1")
        let v2 = await queue.inOrderSkipReason(for: unit("O.t2", "v2", .inOrder, order: 2), lane: "L1")
        XCTAssertNotNil(v1)
        XCTAssertNil(v2)
    }

    /// バリアントが全部 nil のキューの並びは、ScenarioInfo だけで並べた従来の並びと同じ
    func testNilVariantsKeepTheExistingOrder() async {
        let items = [item("A.1"), item("C.b", .inOrder, order: 2), item("B.1"), item("C.a", .inOrder, order: 1)]
        let queue = ScenarioQueue(items)
        await queue.laneJoined("L1")
        let got = await drain(queue, lane: "L1")
        XCTAssertEqual(got, ClassPlacementRules.ordered(items.map(\.info)).map(\.id))
    }

    /// 作り直し(lane / repeat)は variant を落とさず、URL にも載る
    func testRebuildingAnItemKeepsTheVariant() {
        let base = unit("A.s", "dark")
        XCTAssertEqual(base.with(lane: "L1").variant, "dark")
        XCTAssertEqual(base.with(repeatIndex: 2).variant, "dark")
        XCTAssertNotEqual(base.url, unit("A.s", nil).url, "同じ ID でもバリアントが違えば別キー")
        XCTAssertTrue(base.url.absoluteString.contains("variant=dark"))
        XCTAssertEqual(base.with(lane: "L1").with(repeatIndex: 3).repeatIndex, 3)
        XCTAssertEqual(base.with(repeatIndex: 3).with(lane: "L1").repeatIndex, 3, "lane の作り直しが repeatIndex を落とさない")
    }

    /// 配り手から受け取る経路: 親は「残りは別のレーンに束ねた分だけ」のレーンに nil を返す。1つのレーンの nil を全レーンの尽きと
    /// 読むと、束ねたレーンが残りを聞きに行かずに終わる(回帰で実測: @RunInOrder の3本目が誰にも渡らなかった)
    func testNoneForOneLaneDoesNotStopAnotherLaneFromAsking() async {
        final class PerLaneSource: ScenarioPullSource {
            let asked = LockedValue<[String]>([])
            func next(platform: String, lane: String) async -> PullAnswer {
                asked.withLock { $0.append(lane) }
                return lane == "L1" ? .unit(ScenarioUnitKey(id: "O.s2", variant: nil)) : .exhausted
            }
            func stopWaiting() {}
            func declareNotApplicable(platform: String, lane: String, unit: ScenarioUnitKey,
                                      departedUntried: Bool, kinds: Set<String>) async -> NotApplicableHandoff.Verdict { .skipped }
            func noteKept(unit: ScenarioUnitKey, on: Bool) {}
        }
        let source = PerLaneSource()
        let catalog = [ScenarioUnitKey(id: "O.s2", variant: nil): [item("O.s2", .inOrder, order: 2)]]
        let queue = ScenarioQueue(pulled: ScenarioQueue.PullState(
            source: source, platform: "ios", catalog: LockedValue(catalog),
            onHandOut: { _ in }, onUnknownID: { _ in }))
        let other = await queue.next(lane: "L2")
        XCTAssertNil(other)
        let bound = await queue.next(lane: "L1")
        XCTAssertEqual(bound?.info.id, "O.s2", "別のレーンが nil を受けても、このレーンは配り手に聞く")
        XCTAssertEqual(source.asked.value, ["L2", "L1"])
        let rest = await queue.hasItems(lane: "L2")
        XCTAssertFalse(rest)
    }
}

private struct LaneTestDriver: AppDriver {
    func status() async throws -> StatusResponse {
        StatusResponse(ready: true, device: "-", osVersion: "-", sessionBundleID: nil)
    }
    func install(packagePath: String) async throws -> String? { nil }
    func uninstall(bundleID: String) async throws {}
    func launch(bundleID: String) async throws {}
    func isAppForeground(bundleID: String) async throws -> Bool { false }
    func snapshot() async throws -> SnapshotResponse {
        SnapshotResponse(sessionBundleID: nil, screen: FTRect(x: 0, y: 0, width: 0, height: 0),
                         elements: [], truncatedCount: 0)
    }
    func tap(ref: Int) async throws {}
    func tap(x: Double, y: Double) async throws {}
    func type(ref: Int?, text: String) async throws {}
    func swipe(_ direction: FTSwipeDirection) async throws {}
    func press(ref: Int, duration: Double) async throws {}
    func screenshot() async throws -> Data { Data() }
    func terminate() async throws {}
}
