// DR-199: スコープ(`>>`)の容器が in-app の木で子を持たない形(CMP の ScrollableTabRow・PullToRefreshBox)で、
// notExist / waitForClose が居る要素を「無い」と結論して緑になる誤りを、XCUITest の木の照会で塞ぐ
import XCTest
@testable import FTCore

final class OI390ScopedNegativeConsultTests: XCTestCase {

    private static func element(_ ref: Int, id: String?, type: String, depth: Int, kept: Int? = nil) -> ElementInfo {
        ElementInfo(ref: ref, type: type, identifier: id, label: nil, value: nil, placeholder: nil, enabled: true,
                    frame: FTRect(x: 0, y: Double(ref) * 40, width: 200, height: 30), depth: depth, keptDepth: kept)
    }

    /// in-app の木: 容器の直後に同じ枠の other が兄弟で並び、子は容器と同じ keptDepth → `scopeDescendants` が空になる
    private static let childlessInApp: [ElementInfo] = [
        element(1, id: "stab_row", type: "other", depth: 9, kept: 2),
        element(2, id: nil, type: "other", depth: 9, kept: 2),
        element(3, id: "stab_02", type: "button", depth: 10, kept: 2),
    ]

    /// 容器が子を持つ木(照会の条件に当たらない)。子は別の id
    private static let healthyInApp: [ElementInfo] = [
        element(1, id: "stab_row", type: "other", depth: 0, kept: 0),
        element(2, id: "stab_01", type: "button", depth: 1, kept: 1),
    ]

    private static let xcuitestWithTarget: [ElementInfo] = [
        element(1, id: "stab_row", type: "other", depth: 0),
        element(2, id: "stab_02", type: "button", depth: 1),
    ]
    private static let xcuitestWithoutTarget: [ElementInfo] = [
        element(1, id: "stab_row", type: "other", depth: 0),
    ]

    private static func snapshot(_ elements: [ElementInfo]) -> SnapshotResponse {
        SnapshotResponse(sessionBundleID: nil, screen: FTRect(x: 0, y: 0, width: 402, height: 874), elements: elements, truncatedCount: 0)
    }

    private var step: FlowStep {
        FlowStep(assert: "notExists",
                 locator: FlowLocator(id: "stab_02", scope: [FlowLocator(id: "stab_row")]),
                 timeout: 0.2, occlusionGuard: false)
    }

    private func run(inApp: [ElementInfo], xcuitest: [ElementInfo], foreground: Bool = true)
        async -> (outcome: StepOutcome, xcuitestSnapshots: Int) {
        let inAppDriver = FakeAppDriver(name: "primary", log: CallLog(), snapshotElements: [inApp])
        let xcuitestDriver = FakeAppDriver(name: "xcuitest", log: CallLog(), snapshotElements: [xcuitest])
        xcuitestDriver.appForeground = foreground
        let executor = StepExecutor(driver: inAppDriver, typeDriver: xcuitestDriver, delegate: FakeVisibilityDelegate(visible: true),
                                    occlusionOCRMode: .off, fmVisibilityCheckEnabled: false, isAndroid: false,
                                    tunables: RunTunables(), uiFramework: .uikit)
        executor.launchedBundleID = "com.example.cmp"
        let outcome = await executor.execute(step)
        return (outcome, xcuitestDriver.snapshotCallCount)
    }

    func testPrecondition_InAppScopeIsEmpty() {
        XCTAssertNil(LocatorResolver.resolve(step: step, in: Self.snapshot(Self.childlessInApp), strictForAssert: true))
        XCTAssertNotNil(LocatorResolver.resolve(step: step, in: Self.snapshot(Self.xcuitestWithTarget), strictForAssert: true))
    }

    /// 空のスコープ + XCUITest の木に居る → 緑にせず赤
    func testEmptyScopeAndPresentInXCUITestTreeFails() async {
        let (outcome, snapshots) = await run(inApp: Self.childlessInApp, xcuitest: Self.xcuitestWithTarget)
        guard case .failed(let message) = outcome.status else { return XCTFail("\(outcome.status)") }
        XCTAssertTrue(message.description.contains("still exists"), message.description)
        XCTAssertTrue(outcome.notes.contains(.absenceContradictedByXCUITestTree), "\(outcome.notes)")
        XCTAssertGreaterThan(snapshots, 0)
    }

    /// 空のスコープ + XCUITest の木にも居ない → 緑(注記で照会の結果を残す)
    func testEmptyScopeAndAbsentInXCUITestTreePasses() async {
        let (outcome, snapshots) = await run(inApp: Self.childlessInApp, xcuitest: Self.xcuitestWithoutTarget)
        XCTAssertEqual("\(outcome.status)", "\(StepResult.Status.passed)")
        XCTAssertTrue(outcome.notes.contains(.xcuitestTreeNoMatch), "\(outcome.notes)")
        XCTAssertFalse(outcome.notes.contains(.absenceContradictedByXCUITestTree))
        XCTAssertEqual(snapshots, 1)
    }

    /// スコープが空でない → 照会を撃たない
    func testNonEmptyScopeDoesNotConsult() async {
        let (outcome, snapshots) = await run(inApp: Self.healthyInApp, xcuitest: Self.xcuitestWithTarget)
        XCTAssertEqual("\(outcome.status)", "\(StepResult.Status.passed)")
        XCTAssertEqual(snapshots, 0)
        XCTAssertFalse(outcome.notes.contains(.xcuitestTreeNoMatch))
    }

    /// 前面に無いなど答えられない照会は従来どおり(緑のまま・居ると言わない)
    func testUnansweredConsultKeepsTheOldVerdict() async {
        let (outcome, snapshots) = await run(inApp: Self.childlessInApp, xcuitest: Self.xcuitestWithTarget, foreground: false)
        XCTAssertEqual("\(outcome.status)", "\(StepResult.Status.passed)")
        XCTAssertEqual(snapshots, 0)
        XCTAssertFalse(outcome.notes.contains(.absenceContradictedByXCUITestTree))
    }
}
