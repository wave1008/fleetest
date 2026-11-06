import XCTest
@testable import FTCore

/// ブリッジ不達で振り直した item は、落としたレーン以外が生きている間そのレーンへ戻さない(OI-163 ⑪)
final class ScenarioQueueAvoidLaneTests: XCTestCase {
    private func makeItem(_ id: String) -> ScenarioRunItem {
        ScenarioRunItem(info: ScenarioInfo(id: id, title: id, platform: "android"))
    }
    /// 待ちが解けない退行でテストが止まらず落ちるための上限(期待どおりなら 0.1〜0.3 秒で返る)
    private static func deadline(_ seconds: Double = 5) -> @Sendable () async -> Bool {
        let end = Date().addingTimeInterval(seconds)
        return { Date() > end }
    }

    func testAvoidedItemGoesToAnotherLaneNotTheOneThatDroppedIt() async {
        let queue = ScenarioQueue([])
        await queue.laneJoined("A")
        await queue.laneJoined("B")
        _ = await queue.requeue(makeItem("S1"), avoiding: "A")
        // A が先に聞いても渡さない(B が取るまで待つ)。B が取った時点で A の待ちは解ける
        async let forA = queue.next(lane: "A")
        try? await Task.sleep(for: .milliseconds(100))
        let forB = await queue.next(lane: "B")
        XCTAssertEqual(forB?.info.id, "S1")
        await queue.laneEnded("B")
        let a = await forA
        XCTAssertNil(a, "B が取った後に残りは無い")
    }

    func testAvoidedLaneStillGetsOtherItemsFirst() async {
        let queue = ScenarioQueue([makeItem("S2")])
        await queue.laneJoined("A")
        await queue.laneJoined("B")
        _ = await queue.requeue(makeItem("S1"), avoiding: "A")
        let first = await queue.next(lane: "A")
        XCTAssertEqual(first?.info.id, "S2")
    }

    func testOnlyLaneStillGetsItBack() async {
        let queue = ScenarioQueue([])
        await queue.laneJoined("A")
        _ = await queue.requeue(makeItem("S1"), avoiding: "A")
        let got = await queue.next(lane: "A", shouldStop: Self.deadline())
        XCTAssertEqual(got?.info.id, "S1", "他のレーンが無ければ従来どおり戻す")
    }

    func testReturnsToAvoidedLaneOnceOthersEnded() async {
        let queue = ScenarioQueue([])
        await queue.laneJoined("A")
        await queue.laneJoined("B")
        _ = await queue.requeue(makeItem("S1"), avoiding: "A")
        async let forA = queue.next(lane: "A", shouldStop: Self.deadline())
        try? await Task.sleep(for: .milliseconds(100))
        await queue.laneEnded("B")
        let a = await forA
        XCTAssertEqual(a?.info.id, "S1")
    }

    func testShouldStopEndsTheWaitWithoutTakingTheItem() async {
        let queue = ScenarioQueue([])
        await queue.laneJoined("A")
        await queue.laneJoined("B")
        _ = await queue.requeue(makeItem("S1"), avoiding: "A")
        let got = await queue.next(lane: "A", shouldStop: { true })
        XCTAssertNil(got)
        let left = await queue.nextLocal()
        XCTAssertEqual(left?.info.id, "S1")
    }

    func testRequeueWithoutAvoidingKeepsFifoForAnyLane() async {
        let queue = ScenarioQueue([])
        await queue.laneJoined("A")
        await queue.laneJoined("B")
        _ = await queue.requeue(makeItem("S1"))
        let got = await queue.next(lane: "A")
        XCTAssertEqual(got?.info.id, "S1")
    }
}
