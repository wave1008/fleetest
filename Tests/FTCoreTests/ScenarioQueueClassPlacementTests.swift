import XCTest
@testable import FTCore

/// クラスの寄せ方(RR-8.3)のマシンの中のキュー: 束ね・続けて取る・振り直し・離脱の残り・@RunInOrder の失敗の後
final class ScenarioQueueClassPlacementTests: XCTestCase {
    private func item(_ id: String, _ placement: ClassPlacement? = nil, order: Int? = nil) -> ScenarioRunItem {
        ScenarioRunItem(info: ScenarioInfo(id: id, title: id, platform: "ios", placement: placement, order: order))
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
                          connection: DriverConnection(platform: "ios"))
        let b = RunWorker(label: "ios:8101", platform: "ios", driver: LaneTestDriver(),
                          connection: DriverConnection(platform: "ios"))
        XCTAssertNotEqual(ScenarioQueue.lane(of: a), ScenarioQueue.lane(of: b))
        let queue = ScenarioQueue([item("D.s1", .singleDevice), item("D.s2", .singleDevice), item("P.s1")])
        let first = await queue.next(lane: ScenarioQueue.lane(of: a))
        let second = await queue.next(lane: ScenarioQueue.lane(of: b))
        XCTAssertEqual(first?.info.id, "D.s1")
        XCTAssertEqual(second?.info.id, "P.s1", "束ねたクラスは論理名の無い別のワーカーへ渡らない")
    }

    /// 配り手から受け取る経路: 親は「残りは別のレーンに束ねた分だけ」のレーンに nil を返す。1つのレーンの nil を全レーンの尽きと
    /// 読むと、束ねたレーンが残りを聞きに行かずに終わる(回帰で実測: @RunInOrder の3本目が誰にも渡らなかった)
    func testNoneForOneLaneDoesNotStopAnotherLaneFromAsking() async {
        final class PerLaneSource: ScenarioPullSource {
            let asked = LockedValue<[String]>([])
            func next(platform: String, lane: String) async -> String? {
                asked.withLock { $0.append(lane) }
                return lane == "L1" ? "O.s2" : nil
            }
            func stopWaiting() {}
        }
        let source = PerLaneSource()
        let catalog = ["O.s2": [item("O.s2", .inOrder, order: 2)]]
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
