// 親の配り手(DynamicDispatcher)のクラスの寄せ方(RR-8.3)。デバイス不要(偽の時計・見積り)。
// 破ると: 束ねたクラスのメンバーが別のエントリ/レーンへ渡って同時に走る / 束ねた先が落ちた後に残りが他へ移って二重に走る /
// 終わったエントリに束ねた分が「まだ配れる残り」に数えられて複数対象の仕事が終わらない。

import XCTest
import FTCore
@testable import fleetest

final class DynamicDispatcherClassPlacementTests: XCTestCase {

    private typealias Scenario = DynamicSplit.Scenario
    private typealias Group = DynamicSplit.Group

    private struct Harness {
        let dispatcher: DynamicDispatcher
        let logs: LockedValue<[String]>
    }

    private func harness(_ scenarios: [Scenario], platforms: [Int: Set<String>] = [:]) -> Harness {
        let logs = LockedValue<[String]>([])
        let dispatcher = DynamicDispatcher(
            scenarios: scenarios, estimateMs: { _, _ in 1000 }, nowMs: { 0 },
            timer: { _, _ in {} }, lpt: true, entryPlatforms: platforms,
            entryLabel: { "M\($0)" }, log: { line in logs.withLock { $0.append(line) } },
            send: { _, _ in })
        return Harness(dispatcher: dispatcher, logs: logs)
    }

    private func want(_ req: Int, lane: String) -> WorkQueueProtocol.Want {
        WorkQueueProtocol.Want(req: req, lane: lane, platform: "ios")
    }

    private func member(_ id: String, _ placement: ClassPlacement, order: Int? = nil) -> Scenario {
        Scenario(id: id, variant: nil, platform: "ios",
                 group: Group(name: ClassPlacementRules.className(of: id), placement: placement, order: order))
    }

    func testSingleMachineClassStaysOnTheFirstEntryAndLogsOnce() {
        let h = harness([member("C.a", .singleMachine), member("C.b", .singleMachine),
                         Scenario(id: "P.x", variant: nil, platform: "ios")])
        XCTAssertEqual(h.dispatcher.handle(want(1, lane: "a"), fromEntry: 0), .init(req: 1, unit: ScenarioUnitKey(id: "C.a", variant: nil)))
        XCTAssertEqual(h.dispatcher.handle(want(1, lane: "b"), fromEntry: 1), .init(req: 1, unit: ScenarioUnitKey(id: "P.x", variant: nil)))
        XCTAssertEqual(h.dispatcher.handle(want(2, lane: "b"), fromEntry: 1), .init(req: 2, none: true),
                       "束ねたクラスの残りは別のエントリへ渡さない")
        XCTAssertEqual(h.dispatcher.handle(want(2, lane: "a"), fromEntry: 0), .init(req: 2, unit: ScenarioUnitKey(id: "C.b", variant: nil)))
        XCTAssertEqual(h.logs.value, ["C: kept on M0 (@RunOnSingleMachine)"])
    }

    func testInOrderClassGoesToOneLaneInOrderAndLogsTheLane() {
        let h = harness([member("C.x", .inOrder, order: 2), member("C.y", .inOrder, order: 1),
                         Scenario(id: "P.x", variant: nil, platform: "ios")])
        XCTAssertEqual(h.dispatcher.handle(want(1, lane: "a"), fromEntry: 0), .init(req: 1, unit: ScenarioUnitKey(id: "C.y", variant: nil)))
        XCTAssertEqual(h.dispatcher.handle(want(1, lane: "b"), fromEntry: 0), .init(req: 1, unit: ScenarioUnitKey(id: "P.x", variant: nil)))
        XCTAssertEqual(h.dispatcher.handle(want(2, lane: "b"), fromEntry: 0), .init(req: 2, none: true))
        XCTAssertEqual(h.dispatcher.handle(want(2, lane: "a"), fromEntry: 0), .init(req: 2, unit: ScenarioUnitKey(id: "C.x", variant: nil)))
        XCTAssertEqual(h.logs.value, ["C: kept on M0 / a (@RunInOrder)"])
    }

    func testRemainderOfAKeptClassIsNotMovedAfterTheEntryExited() {
        let h = harness([member("C.a", .singleMachine), member("C.b", .singleMachine)])
        XCTAssertEqual(h.dispatcher.handle(want(1, lane: "a"), fromEntry: 0), .init(req: 1, unit: ScenarioUnitKey(id: "C.a", variant: nil)))
        h.dispatcher.childExited(entry: 0)
        XCTAssertEqual(h.dispatcher.handle(want(1, lane: "b"), fromEntry: 1), .init(req: 1, none: true))
        XCTAssertEqual(h.dispatcher.unhandedUnits, [ScenarioUnitKey(id: "C.b", variant: nil)])
        XCTAssertEqual(h.dispatcher.keptUnhanded.map(\.unit.id), ["C.b"])
        XCTAssertTrue(h.dispatcher.handablePendingScenarios.isEmpty, "束ねた先が終わった分は配れる残りに数えない")
        XCTAssertEqual(h.dispatcher.pendingScenarios.map(\.id), ["C.b"])
        let line = DynamicDispatcher.keptUnhandedLine(h.dispatcher.keptUnhanded)
        XCTAssertTrue(line?.contains("@RunOnSingleMachine") == true && line?.contains("C.b") == true, line ?? "nil")
    }

    func testUnboundPendingIsStillHandableAndNoKeptLineWithoutKept() {
        let h = harness([member("C.a", .singleMachine), Scenario(id: "P.x", variant: nil, platform: "ios")])
        XCTAssertTrue(h.dispatcher.keptUnhanded.isEmpty)
        XCTAssertEqual(h.dispatcher.handablePendingScenarios.count, 2)
        XCTAssertNil(DynamicDispatcher.keptUnhandedLine([]))
    }

    func testSingleMachineClassIsNotGivenToAnEntryMissingItsPlatform() {
        let both = Scenario(id: "C.a", variant: nil, platform: "ios",
                            group: Group(name: "C", placement: .singleMachine))
        let android = Scenario(id: "C.b", variant: nil, platform: "android",
                               group: Group(name: "C", placement: .singleMachine))
        let h = harness([both, android], platforms: [0: ["ios"], 1: ["ios", "android"]])
        XCTAssertEqual(h.dispatcher.handle(want(1, lane: "a"), fromEntry: 0), .init(req: 1, none: true))
        XCTAssertEqual(h.dispatcher.handle(want(1, lane: "b"), fromEntry: 1), .init(req: 1, unit: ScenarioUnitKey(id: "C.a", variant: nil)))
    }

    func testResolveCarriesTheGroupOfAPlacedClass() {
        let info = ScenarioInfo(id: "C.a", title: "t", placement: .inOrder, order: 3)
        let plain = ScenarioInfo(id: "P.a", title: "t")
        let resolved = DynamicDispatcher.resolve([info, plain], variant: nil, defaultPlatform: "ios")
        XCTAssertEqual(resolved[0].group, Group(name: "C", placement: .inOrder, order: 3))
        XCTAssertNil(resolved[1].group)
        XCTAssertEqual(DynamicDispatcher.groups(of: [info, plain], variant: nil), [ScenarioUnitKey(id: "C.a", variant: nil): Group(name: "C", placement: .inOrder, order: 3)])
    }
}
