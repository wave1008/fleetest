// FleetSplit.plan / partition の groups(RR-8.3: クラスは1つの塊として1エントリへ)。

import XCTest
@testable import FTCore

final class FleetSplitClassPlacementTests: XCTestCase {

    private func duration(_ id: String, _ ms: Double, _ platform: String = "ios") -> LPTScheduler.Duration {
        LPTScheduler.Duration(scenarioID: id, platform: platform, medianMs: ms)
    }

    private func groups(_ name: String, _ ids: [String], _ placement: ClassPlacement = .singleMachine)
        -> [ScenarioUnitKey: DynamicSplit.Group] {
        Dictionary(uniqueKeysWithValues: ids.enumerated().map {
            (ScenarioUnitKey(id: $0.element, variant: nil), DynamicSplit.Group(name: name, placement: placement, order: placement == .inOrder ? $0.offset : nil))
        })
    }

    func testClassMembersGoToTheSameBucketAsOneChunk() throws {
        // M.a/M.b/M.c(各 3000 = 塊 9000)と X(5000)・Y(4000)。塊は9000で最も重く先に置く → entry0。
        // X → entry1(0→5000)、Y → entry1(5000→9000)。塊の分割は起きない
        let durations = ["M.a", "M.b", "M.c"].map { duration($0, 3_000) } + [duration("X.x", 5_000), duration("Y.y", 4_000)]
        let scenarios: [(id: String, variant: String?, platform: String?)] = [
            ("M.a", nil, nil), ("M.b", nil, nil), ("M.c", nil, nil), ("X.x", nil, nil), ("Y.y", nil, nil),
        ]
        let buckets = try FleetSplit.partition(
            scenarios: scenarios, durations: durations, entryPlatforms: [["ios"], ["ios"]],
            unknownDurationMs: 1_000, groups: groups("M", ["M.a", "M.b", "M.c"]))
        XCTAssertEqual(buckets, [
            FleetSplit.Bucket(entryIndex: 0, units: unitKeys(["M.a", "M.b", "M.c"]), estimatedMs: 9_000),
            FleetSplit.Bucket(entryIndex: 1, units: unitKeys(["X.x", "Y.y"]), estimatedMs: 9_000),
        ])
    }

    func testInOrderMembersAreListedInOrderWithinBucket() throws {
        let scenarios: [(id: String, variant: String?, platform: String?)] = [("O.c", nil, nil), ("O.a", nil, nil), ("O.b", nil, nil)]
        // order は groups の並びの添字: O.b=0, O.c=1, O.a=2
        let buckets = try FleetSplit.partition(
            scenarios: scenarios, durations: [], entryPlatforms: [["ios"]], unknownDurationMs: 1_000,
            groups: groups("O", ["O.b", "O.c", "O.a"], .inOrder))
        XCTAssertEqual(buckets[0].units, unitKeys(["O.b", "O.c", "O.a"]))
    }

    func testClassIsNotPlacedOnEntryMissingAnyMemberOS() throws {
        // entry0 = ios のみ(空いている)、entry1 = ios + android。両 OS のクラスは entry1 へ
        let scenarios: [(id: String, variant: String?, platform: String?)] = [
            ("M.a", nil, "ios"), ("M.b", nil, "android"), ("X.x", nil, "ios"),
        ]
        let buckets = try FleetSplit.partition(
            scenarios: scenarios, durations: [], entryPlatforms: [["ios"], ["ios", "android"]],
            unknownDurationMs: 1_000, groups: groups("M", ["M.a", "M.b"]))
        XCTAssertEqual(buckets[1].units, unitKeys(["M.a", "M.b"]))
        XCTAssertEqual(buckets[0].units, unitKeys(["X.x"]))
    }

    func testClassWithNoFittingEntryThrows() {
        let scenarios: [(id: String, variant: String?, platform: String?)] = [("M.a", nil, "ios"), ("M.b", nil, "android")]
        XCTAssertThrowsError(try FleetSplit.partition(
            scenarios: scenarios, durations: [], entryPlatforms: [["ios"], ["android"]],
            unknownDurationMs: 1_000, groups: groups("M", ["M.a", "M.b"]))) { error in
            XCTAssertEqual(error as? FleetSplit.FleetSplitError,
                           .noFittingEntry(scenarioID: "M.a", platform: "android+ios"))
        }
    }

    func testEstimateBasisCountsPerMember() throws {
        let durations = [duration("M.a", 3_000)]
        let scenarios: [(id: String, variant: String?, platform: String?)] = [("M.a", nil, nil), ("M.b", nil, nil)]
        let plan = try FleetSplit.plan(
            scenarios: scenarios, durations: durations, entryPlatforms: [["ios"]], unknownDurationMs: 1_000,
            groups: groups("M", ["M.a", "M.b"]))
        // M.a は混合実績 × 係数(scaled)、M.b は実績なし(unknown)。塊でも1本ずつ数える
        XCTAssertEqual(plan.basis[0].scaled, 1)
        XCTAssertEqual(plan.basis[0].unknown, 1)
        XCTAssertEqual(plan.buckets[0].estimatedMs, 4_000)
    }

    func testEmptyGroupsGivesSameResultAsBefore() throws {
        let durations = [duration("A.one", 5_000), duration("B.two", 3_000), duration("C.three", 4_000, "android")]
        let scenarios: [(id: String, variant: String?, platform: String?)] = [
            ("A.one", nil, nil), ("B.two", nil, nil), ("C.three", nil, nil), ("D.four", nil, nil), ("E.five", nil, nil),
        ]
        let entries: [Set<String>] = [["ios", "android"], ["ios", "android"]]
        let without = try FleetSplit.partition(scenarios: scenarios, durations: durations,
                                               entryPlatforms: entries, unknownDurationMs: 1_000)
        let with = try FleetSplit.partition(scenarios: scenarios, durations: durations, entryPlatforms: entries,
                                            unknownDurationMs: 1_000, groups: [:])
        XCTAssertEqual(without, with)
        XCTAssertEqual(with, [
            FleetSplit.Bucket(entryIndex: 0, units: unitKeys(["A.one", "D.four", "E.five"]), estimatedMs: 7_000),
            FleetSplit.Bucket(entryIndex: 1, units: unitKeys(["C.three", "B.two"]), estimatedMs: 7_000),
        ])
    }
}
