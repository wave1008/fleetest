// ClassPlacementRules / InOrderGate(RR-8.3)。期待値は手計算で固定する。

import XCTest
@testable import FTCore

final class ClassPlacementRulesTests: XCTestCase {

    private func info(_ id: String, _ placement: ClassPlacement? = nil, order: Int? = nil,
                      platform: String? = nil, deleted: Bool = false, draft: Bool = false) -> ScenarioInfo {
        ScenarioInfo(id: id, title: id, platform: platform, deleted: deleted, draft: draft,
                     placement: placement, order: order)
    }

    private func ids(_ items: [ScenarioInfo]) -> [String] { items.map(\.id) }

    // MARK: - className

    func testClassNameIsBeforeFirstDot() {
        XCTAssertEqual(ClassPlacementRules.className(of: "OrderTests.test.one"), "OrderTests")
        XCTAssertEqual(ClassPlacementRules.className(of: "Plain"), "Plain")
    }

    // MARK: - ordered

    func testOrderedGathersDeviceClassAtFirstMemberPositionSortedByOrder() {
        let items = [
            info("A.s1"), info("O.b", .inOrder, order: 2), info("B.s1"),
            info("O.a", .inOrder, order: 1), info("C.s1"), info("O.c", .inOrder, order: 3),
        ]
        XCTAssertEqual(ids(ClassPlacementRules.ordered(items)), ["A.s1", "O.a", "O.b", "O.c", "B.s1", "C.s1"])
    }

    func testOrderedKeepsSingleDeviceRelativeOrderAndLeavesOthersAlone() {
        let items = [
            info("D.z", .singleDevice), info("M.x", .singleMachine), info("D.a", .singleDevice),
            info("P.q"), info("M.a", .singleMachine),
        ]
        XCTAssertEqual(ids(ClassPlacementRules.ordered(items)), ["D.z", "D.a", "M.x", "P.q", "M.a"])
    }

    func testOrderedTiesAndNilOrderFollowIDAndNilIsLast() {
        let items = [
            info("O.z", .inOrder, order: 1), info("O.b", .inOrder, order: 1),
            info("O.n", .inOrder, order: nil), info("O.m", .inOrder, order: 0),
        ]
        XCTAssertEqual(ids(ClassPlacementRules.ordered(items)), ["O.m", "O.b", "O.z", "O.n"])
    }

    func testOrderedWithoutAttributesIsIdentity() {
        let items = [info("Z.a"), info("A.b"), info("M.c", .singleMachine)]
        XCTAssertEqual(ClassPlacementRules.ordered(items), items)
    }

    // MARK: - selectionError

    private var orderClass: [ScenarioInfo] {
        [info("O.t1", .inOrder, order: 1), info("O.t2", .inOrder, order: 2),
         info("O.t3", .inOrder, order: 3), info("O.t4", .inOrder, order: 4)]
    }

    func testSelectionWholeClassAndPrefixAreAccepted() {
        let all = orderClass + [info("P.x")]
        XCTAssertNil(ClassPlacementRules.selectionError(selected: all, all: all))
        XCTAssertNil(ClassPlacementRules.selectionError(selected: Array(orderClass.prefix(2)), all: all))
        XCTAssertNil(ClassPlacementRules.selectionError(selected: [orderClass[0]], all: all))
    }

    func testSelectionMiddleOnlyAndGapsAreRejectedWithClassName() {
        let all = orderClass
        let middle = ClassPlacementRules.selectionError(selected: [orderClass[1]], all: all)
        XCTAssertNotNil(middle)
        XCTAssertTrue(middle!.contains("O is a @RunInOrder class"))
        XCTAssertTrue(middle!.contains("O.t1"))
        XCTAssertNotNil(ClassPlacementRules.selectionError(selected: [orderClass[0], orderClass[2]], all: all))
        XCTAssertNotNil(ClassPlacementRules.selectionError(selected: Array(orderClass.suffix(2)), all: all))
    }

    func testSelectionIgnoresNonInOrderClasses() {
        let all = [info("D.b", .singleDevice), info("D.a", .singleDevice), info("P.x")]
        XCTAssertNil(ClassPlacementRules.selectionError(selected: [all[0]], all: all))
    }

    func testSelectionSkipsDeletedAndDraftNotSelected() {
        let all = [info("O.t1", .inOrder, order: 1), info("O.t2", .inOrder, order: 2, draft: true),
                   info("O.t3", .inOrder, order: 3)]
        // t2 は @Draft で選ばれていない = 並びに入らない。t1,t3 は先頭から連続
        XCTAssertNil(ClassPlacementRules.selectionError(selected: [all[0], all[2]], all: all))
    }

    func testSelectionExplicitDraftCountsInSequence() {
        let t1 = info("O.t1", .inOrder, order: 1), t2 = info("O.t2", .inOrder, order: 2, draft: true)
        let t3 = info("O.t3", .inOrder, order: 3)
        let all = [t1, t2, t3]
        XCTAssertNil(ClassPlacementRules.selectionError(selected: [t1, t2], all: all))
        XCTAssertNotNil(ClassPlacementRules.selectionError(selected: [t1, t2, t3].filter { $0.id != "O.t1" }, all: all))
        // t2 を選んでいて t1 を選んでいない = 先頭から連続でない
        XCTAssertNotNil(ClassPlacementRules.selectionError(selected: [t2], all: all))
    }

    // MARK: - expandingFailed

    func testExpandingFailedAddsWholeInOrderClassWithoutDeletedAndDraft() {
        let all = [info("O.t1", .inOrder, order: 1), info("O.t2", .inOrder, order: 2),
                   info("O.t3", .inOrder, order: 3, deleted: true), info("O.t4", .inOrder, order: 4, draft: true),
                   info("D.a", .singleDevice), info("D.b", .singleDevice), info("P.x")]
        XCTAssertEqual(ClassPlacementRules.expandingFailed(["O.t2", "D.a"], all: all),
                       ["O.t1", "O.t2", "D.a"])
        XCTAssertEqual(ClassPlacementRules.expandingFailed(["D.a", "P.x"], all: all), ["D.a", "P.x"])
    }

    // MARK: - measurement / notices

    func testMeasurementErrorOnlyForInOrder() {
        XCTAssertNil(ClassPlacementRules.measurementError([info("D.a", .singleDevice), info("P.x")]))
        let message = ClassPlacementRules.measurementError([info("O.t1", .inOrder, order: 1)])
        XCTAssertNotNil(message)
        XCTAssertTrue(message!.contains("O"))
    }

    func testSharedRunNoticeNamesClassesAndModeOrNil() {
        XCTAssertNil(ClassPlacementRules.sharedRunNotice([info("P.x")], mode: "--broadcast"))
        let line = ClassPlacementRules.sharedRunNotice(
            [info("M.a", .singleMachine), info("M.b", .singleMachine), info("O.t", .inOrder, order: 1)],
            mode: "--broadcast")!
        XCTAssertTrue(line.hasPrefix("--broadcast:"))
        XCTAssertTrue(line.contains("M (@RunOnSingleMachine)"))
        XCTAssertTrue(line.contains("O (@RunInOrder)"))
        XCTAssertFalse(line.contains("\n"))
    }

    // MARK: - singleMachineCoverageError

    func testCoverageErrorWhenNoEntryHasAllOSes() {
        let selected = [info("M.a", .singleMachine, platform: "ios"), info("M.b", .singleMachine, platform: "android")]
        let error = ClassPlacementRules.singleMachineCoverageError(
            selected, defaultPlatform: "ios",
            entries: [(label: "local", platforms: ["ios"]), (label: "M1Ultra", platforms: ["android"])])
        XCTAssertNotNil(error)
        XCTAssertTrue(error!.contains("local: ios"))
        XCTAssertTrue(error!.contains("M1Ultra: android"))
        XCTAssertTrue(error!.contains("@TestClass(platform:)"))
    }

    func testCoverageOkWhenOneEntryHasBothAndUndeclaredUsesDefault() {
        let selected = [info("M.a", .singleMachine, platform: "android"), info("M.b", .singleMachine)]
        XCTAssertNil(ClassPlacementRules.singleMachineCoverageError(
            selected, defaultPlatform: "ios",
            entries: [(label: "a", platforms: ["ios"]), (label: "b", platforms: ["ios", "android"])]))
        XCTAssertNotNil(ClassPlacementRules.singleMachineCoverageError(
            selected, defaultPlatform: "ios", entries: [(label: "a", platforms: ["ios"])]))
    }

    func testCoverageIgnoresSingleOSClassesAndOtherPlacements() {
        XCTAssertNil(ClassPlacementRules.singleMachineCoverageError(
            [info("M.a", .singleMachine, platform: "android"), info("D.a", .singleDevice, platform: "ios"),
             info("D.b", .singleDevice, platform: "android")],
            defaultPlatform: "ios", entries: [(label: "a", platforms: ["ios"])]))
    }

    // MARK: - reasons / position

    func testReasonsAreEnglishAndNameTheFacts() {
        XCTAssertEqual(ClassPlacementRules.notRunReason(failedID: "X.S0020"),
                       "not run: the earlier test X.S0020 in this @RunInOrder class failed")
        let orphan = ClassPlacementRules.orphanReason(placement: .inOrder, className: "OrderTests", lane: "iPhone 17")
        XCTAssertTrue(orphan.contains("OrderTests") && orphan.contains("@RunInOrder") && orphan.contains("iPhone 17"))
    }

    func testPositionNoticeUsesOrderAndIsNilOtherwise() {
        let members = [info("O.c", .inOrder, order: 3), info("O.a", .inOrder, order: 1), info("O.b", .inOrder, order: 2)]
        XCTAssertEqual(ClassPlacementRules.positionNotice(members[2], classMembers: members),
                       "@RunInOrder: test 2 of 3 in O")
        XCTAssertNil(ClassPlacementRules.positionNotice(info("D.a", .singleDevice), classMembers: members))
        XCTAssertNil(ClassPlacementRules.positionNotice(info("O.zzz", .inOrder, order: 9), classMembers: members))
    }

    // MARK: - InOrderGate

    func testGateStopsRestOfFailedClassOnThatLaneOnly() {
        var gate = InOrderGate()
        let t1 = info("O.t1", .inOrder, order: 1), t2 = info("O.t2", .inOrder, order: 2)
        XCTAssertNil(gate.skipReason(for: t2, lane: "A"))
        gate.record(t1, lane: "A", passed: false)
        XCTAssertEqual(gate.skipReason(for: t2, lane: "A"), ClassPlacementRules.notRunReason(failedID: "O.t1"))
        XCTAssertNil(gate.skipReason(for: t2, lane: "B"))
        XCTAssertNil(gate.skipReason(for: info("P.x"), lane: "A"))
    }

    func testGateIgnoresPassesAndNonInOrderFailuresAndKeepsFirstFailure() {
        var gate = InOrderGate()
        let t1 = info("O.t1", .inOrder, order: 1), t2 = info("O.t2", .inOrder, order: 2)
        gate.record(t1, lane: "A", passed: true)
        gate.record(info("D.a", .singleDevice), lane: "A", passed: false)
        XCTAssertNil(gate.skipReason(for: t2, lane: "A"))
        XCTAssertNil(gate.skipReason(for: info("D.b", .singleDevice), lane: "A"))
        gate.record(t1, lane: "A", passed: false)
        gate.record(t2, lane: "A", passed: false)
        XCTAssertEqual(gate.skipReason(for: info("O.t3", .inOrder, order: 3), lane: "A"),
                       ClassPlacementRules.notRunReason(failedID: "O.t1"))
    }
}
