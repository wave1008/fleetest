// クラスの寄せ方(RR-8.3)の入口の検査は `fleetest run` / `fleetest api run` / 複数マシンの3経路 / 静的な割り当てで同じ関数を通す。
// 破ると: 片方の入口だけ @RunInOrder の途中のテストを通して順番の前提が崩れる(どちらも緑のまま)。
// あわせて、RunOrchestrator を通らない逐次の経路の並べ替えと失敗の後の扱い(SequentialPlacementGate)を固定する。

import XCTest
import FTCore
@testable import fleetest

final class RunPlacementParityTests: XCTestCase {

    private func source(_ name: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        return try String(contentsOf: root.appendingPathComponent("Sources/fleetest/\(name)"), encoding: .utf8)
    }

    func testBothEntriesCallTheSamePreflight() throws {
        for file in ["Fleetest.swift", "ApiRunCommand.swift"] {
            XCTAssertTrue(try source(file).contains("RunPlacementPreflight.check("), "\(file) が入口の検査を呼んでいない")
        }
        XCTAssertTrue(try source("DeviceMachineRunner.swift").contains("RunPlacementPreflight.check("))
        for file in ["DeviceMachineRunner.swift", "ApiRunMachineFanout.swift"] {
            XCTAssertTrue(try source(file).contains("placementPreflight("), "\(file)")
        }
        XCTAssertTrue(try source("MultiTargetRunner.swift").contains("DynamicDispatcher.coverageError("))
        XCTAssertTrue(try source("FleetRunner.swift").contains("singleMachineCoverageError("))
    }

    func testFailedRerunExpandsAndSequentialPathsUseTheGate() throws {
        XCTAssertTrue(try source("Fleetest.swift").contains("ClassPlacementRules.expandingFailed("))
        for file in ["Fleetest.swift", "ApiRunCommand.swift"] {
            let text = try source(file)
            XCTAssertTrue(text.contains("SequentialPlacementGate.ordered("), file)
            XCTAssertTrue(text.contains("placementGate.skipReason("), file)
            XCTAssertTrue(text.contains("placementGate.record("), file)
        }
    }

    func testStaticSplitsPassTheGroups() throws {
        XCTAssertTrue(try source("DeviceMachineRunner.swift").contains("groups: DynamicDispatcher.groups(of: runnable, variant: nil)"))
        XCTAssertTrue(try source("FleetRunner.swift").contains("groups: DynamicDispatcher.groups(of: selected, variant: nil)"))
    }

    private func item(_ id: String, _ placement: ClassPlacement? = nil, order: Int? = nil) -> ScenarioRunItem {
        ScenarioRunItem(info: ScenarioInfo(id: id, title: id, placement: placement, order: order), variant: nil)
    }

    func testSequentialOrderGroupsAClassAtItsFirstMemberInOrder() {
        let items = [item("A.1"), item("C.b", .inOrder, order: 2), item("B.1"), item("C.a", .inOrder, order: 1)]
        XCTAssertEqual(SequentialPlacementGate.ordered(items).map(\.info.id), ["A.1", "C.a", "C.b", "B.1"])
    }

    func testGateStopsTheRestOfAFailedInOrderClassOnly() {
        var gate = SequentialPlacementGate()
        let a = ScenarioInfo(id: "C.a", title: "a", placement: .inOrder, order: 1)
        let b = ScenarioInfo(id: "C.b", title: "b", placement: .inOrder, order: 2)
        let other = ScenarioInfo(id: "D.a", title: "a", placement: .inOrder, order: 1)
        let plain = ScenarioInfo(id: "P.a", title: "p")
        XCTAssertNil(gate.skipReason(for: b, variant: nil))
        gate.record(a, variant: nil, passed: false)
        XCTAssertEqual(gate.skipReason(for: b, variant: nil), ClassPlacementRules.notRunReason(failedID: "C.a"))
        XCTAssertNil(gate.skipReason(for: other, variant: nil))
        XCTAssertNil(gate.skipReason(for: plain, variant: nil))
    }

    func testGateIgnoresFailureOfNonInOrderClasses() {
        var gate = SequentialPlacementGate()
        let a = ScenarioInfo(id: "C.a", title: "a", placement: .singleDevice)
        gate.record(a, variant: nil, passed: false)
        XCTAssertNil(gate.skipReason(for: ScenarioInfo(id: "C.b", title: "b", placement: .singleDevice), variant: nil))
    }

    func testPreflightRefusesAMiddleTestAndNoticesBroadcast() {
        let a = ScenarioInfo(id: "C.a", title: "a", placement: .inOrder, order: 1)
        let b = ScenarioInfo(id: "C.b", title: "b", placement: .inOrder, order: 2)
        XCTAssertThrowsError(try RunPlacementPreflight.check(
            selected: [b], all: [a, b], measuresResponse: false, broadcast: false, log: { _ in }))
        XCTAssertNoThrow(try RunPlacementPreflight.check(
            selected: [a], all: [a, b], measuresResponse: false, broadcast: false, log: { _ in }))
        XCTAssertThrowsError(try RunPlacementPreflight.check(
            selected: [a, b], all: [a, b], measuresResponse: true, broadcast: false, log: { _ in }))
        var lines: [String] = []
        XCTAssertNoThrow(try RunPlacementPreflight.check(
            selected: [a, b], all: [a, b], measuresResponse: false, broadcast: true, log: { lines.append($0) }))
        XCTAssertEqual(lines.count, 1)
    }
}
