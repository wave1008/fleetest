// DR-199: スコープ(`>>`)の容器が in-app の木で子を持たない形(CMP の ScrollableTabRow・PullToRefreshBox)で、
// countIs / select / 検証 / 送りの探索の解決が居る要素を「無い」と見て誤って赤になる誤りを、XCUITest の木の照会で塞ぐ(肯定形)
import XCTest
@testable import FTCore

final class OI390ScopedPositiveConsultTests: XCTestCase {

    private static func element(_ ref: Int, id: String?, type: String, depth: Int, kept: Int? = nil) -> ElementInfo {
        ElementInfo(ref: ref, type: type, identifier: id, label: id.map { "L-" + $0 }, value: nil, placeholder: nil, enabled: true,
                    frame: FTRect(x: 0, y: Double(ref) * 40, width: 200, height: 30), depth: depth, keptDepth: kept)
    }

    /// in-app の木: 容器の直後に同じ枠の other が兄弟で並び、子は容器と同じ keptDepth → `scopeDescendants` が空になる
    private static let childlessInApp: [ElementInfo] = [
        element(1, id: "stab_row", type: "other", depth: 9, kept: 2),
        element(2, id: nil, type: "other", depth: 9, kept: 2),
        element(3, id: "stab_02", type: "button", depth: 10, kept: 2),
        element(4, id: "stab_03", type: "button", depth: 10, kept: 2),
    ]
    private static let healthyInApp: [ElementInfo] = [
        element(1, id: "stab_row", type: "other", depth: 0, kept: 0),
        element(2, id: "stab_02", type: "button", depth: 1, kept: 1),
        element(3, id: "stab_03", type: "button", depth: 1, kept: 1),
    ]
    private static let xcuitestTree: [ElementInfo] = [
        element(1, id: "stab_row", type: "other", depth: 0),
        element(2, id: "stab_02", type: "button", depth: 1),
        element(3, id: "stab_03", type: "button", depth: 1),
        element(4, id: "stab_04", type: "button", depth: 1),
    ]

    private let scoped = FlowLocator(id: "stab_02", scope: [FlowLocator(id: "stab_row")])

    private func run(_ step: FlowStep, inApp: [ElementInfo], foreground: Bool = true)
        async -> (outcome: StepOutcome, xcuitestSnapshots: Int) {
        let inAppDriver = FakeAppDriver(name: "primary", log: CallLog(), snapshotElements: [inApp])
        let xcuitestDriver = FakeAppDriver(name: "xcuitest", log: CallLog(), snapshotElements: [Self.xcuitestTree])
        xcuitestDriver.appForeground = foreground
        let executor = StepExecutor(driver: inAppDriver, typeDriver: xcuitestDriver, delegate: FakeVisibilityDelegate(visible: true),
                                    occlusionOCRMode: .off, fmVisibilityCheckEnabled: false, isAndroid: false,
                                    tunables: RunTunables(), uiFramework: .uikit)
        executor.launchedBundleID = "com.example.cmp"
        let outcome = await executor.execute(step)
        return (outcome, xcuitestDriver.snapshotCallCount)
    }

    private func countStep(_ expected: Int) -> FlowStep {
        FlowStep(assert: "count", locator: FlowLocator(type: "button", scope: [FlowLocator(id: "stab_row")]),
                 timeout: 0.2, expectedCount: expected, occlusionGuard: false)
    }

    func testCountIsReadFromTheXCUITestTreeWhenTheScopeIsEmpty() async {
        let (outcome, snapshots) = await run(countStep(3), inApp: Self.childlessInApp)
        XCTAssertEqual("\(outcome.status)", "\(StepResult.Status.passed)")
        XCTAssertTrue(outcome.notes.contains(.scopeResolvedViaXCUITestTree), "\(outcome.notes)")
        XCTAssertGreaterThan(snapshots, 0)
    }

    func testCountMismatchStillFailsWithTheXCUITestCount() async {
        let (outcome, _) = await run(countStep(4), inApp: Self.childlessInApp)
        guard case .failed(let message) = outcome.status else { return XCTFail("\(outcome.status)") }
        XCTAssertTrue(message.description.contains("actual 3"), message.description)
    }

    func testCountDoesNotConsultWhenTheScopeHasChildren() async {
        let (outcome, snapshots) = await run(countStep(2), inApp: Self.healthyInApp)
        XCTAssertEqual("\(outcome.status)", "\(StepResult.Status.passed)")
        XCTAssertEqual(snapshots, 0)
        XCTAssertFalse(outcome.notes.contains(.scopeResolvedViaXCUITestTree))
    }

    func testCountKeepsTheInAppAnswerWhenTheConsultIsUnanswered() async {
        let (outcome, snapshots) = await run(countStep(3), inApp: Self.childlessInApp, foreground: false)
        XCTAssertEqual(snapshots, 0)
        guard case .failed = outcome.status else { return XCTFail("\(outcome.status)") }
        XCTAssertFalse(outcome.notes.contains(.scopeResolvedViaXCUITestTree))
    }

    func testSelectGrabsTheElementFromTheXCUITestTreeWhenTheScopeIsEmpty() async {
        let (outcome, snapshots) = await run(FlowStep(action: "select", locator: scoped, timeout: 0.2), inApp: Self.childlessInApp)
        XCTAssertEqual("\(outcome.status)", "\(StepResult.Status.passed)")
        XCTAssertEqual(outcome.resolvedElement?.identifier, "stab_02")
        XCTAssertTrue(outcome.notes.contains(.scopeResolvedViaXCUITestTree), "\(outcome.notes)")
        XCTAssertGreaterThan(snapshots, 0)
    }

    /// 送りの探索の各周の解決も XCUITest の木で補う(in-app の木だけだと端まで払って「見つからない」)
    func testScrollSearchFindsTheElementThroughTheXCUITestTree() async {
        let step = FlowStep(action: "select", locator: scoped, direction: "right", timeout: 0.2, maxSwipes: 2)
        let (outcome, snapshots) = await run(step, inApp: Self.childlessInApp)
        XCTAssertEqual("\(outcome.status)", "\(StepResult.Status.passed)")
        XCTAssertEqual(outcome.resolvedElement?.identifier, "stab_02")
        XCTAssertGreaterThan(snapshots, 0)
    }

    func testSelectDoesNotConsultWhenTheScopeHasChildren() async {
        let (outcome, snapshots) = await run(FlowStep(action: "select", locator: scoped, timeout: 0.2), inApp: Self.healthyInApp)
        XCTAssertEqual(outcome.resolvedElement?.identifier, "stab_02")
        XCTAssertEqual(snapshots, 0)
        XCTAssertFalse(outcome.notes.contains(.scopeResolvedViaXCUITestTree))
    }

    func testSelectKeepsTheEmptyAnswerWhenTheConsultIsUnanswered() async {
        let (outcome, _) = await run(FlowStep(action: "select", locator: scoped, timeout: 0.2), inApp: Self.childlessInApp, foreground: false)
        XCTAssertNil(outcome.resolvedElement)
        XCTAssertFalse(outcome.notes.contains(.scopeResolvedViaXCUITestTree))
    }
    /// select の後に連なる検証(textIs・exist 等)は要素を自分で引き直すので、検証の各周も同じ条件で XCUITest の木で解く
    func testTextAssertionReadsTheXCUITestTreeWhenTheScopeIsEmpty() async {
        let step = FlowStep(assert: "textEquals", locator: scoped, expected: "L-stab_02", timeout: 0.2, occlusionGuard: false)
        let (outcome, snapshots) = await run(step, inApp: Self.childlessInApp)
        XCTAssertEqual("\(outcome.status)", "\(StepResult.Status.passed)")
        XCTAssertTrue(outcome.notes.contains(.scopeResolvedViaXCUITestTree), "\(outcome.notes)")
        XCTAssertGreaterThan(snapshots, 0)
    }

    func testExistsReadsTheXCUITestTreeWhenTheScopeIsEmpty() async {
        let step = FlowStep(assert: "exists", locator: scoped, timeout: 0.2, occlusionGuard: false)
        let (outcome, _) = await run(step, inApp: Self.childlessInApp)
        XCTAssertEqual("\(outcome.status)", "\(StepResult.Status.passed)")
        XCTAssertTrue(outcome.notes.contains(.scopeResolvedViaXCUITestTree), "\(outcome.notes)")
    }

    func testTextAssertionDoesNotConsultWhenTheScopeHasChildren() async {
        let step = FlowStep(assert: "textEquals", locator: scoped, expected: "L-stab_02", timeout: 0.2, occlusionGuard: false)
        let (outcome, snapshots) = await run(step, inApp: Self.healthyInApp)
        XCTAssertEqual("\(outcome.status)", "\(StepResult.Status.passed)")
        XCTAssertEqual(snapshots, 0)
    }
}
