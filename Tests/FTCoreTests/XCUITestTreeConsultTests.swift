// inapp-boost の存在のアサーションが in-app の木で見つからずに締め切りへ来たとき、アプリの XCUITest の木を1回照会する(DR-199)。
// 採るのは「見つかって・可視性検証で文字を読めた」回だけ(XCUITest の木はモーダルの裏の要素も残す)
import XCTest
@testable import FTCore

final class XCUITestTreeConsultTests: XCTestCase {

    private static let emptyState = ElementInfo(ref: 1, type: "staticText", identifier: nil, label: "検索結果なし", value: nil,
                                                placeholder: nil, enabled: true,
                                                frame: FTRect(x: 0, y: 300, width: 200, height: 30), depth: 0)

    private func run(fmVisible: Bool, guardOn: Bool = true, fmEnabled: Bool = true, foreground: Bool = true, xcuitestTree: [ElementInfo] = [emptyState]) async -> StepOutcome {
        let shot = StepExecutorTests.blankPNG
        let inApp = FakeAppDriver(name: "primary", log: CallLog(), snapshotElements: [[]], screenshots: [shot])
        let xcuitest = FakeAppDriver(name: "xcuitest", log: CallLog(), snapshotElements: [xcuitestTree], screenshots: [shot])
        xcuitest.appForeground = foreground
        let executor = StepExecutor(driver: inApp, typeDriver: xcuitest, delegate: FakeVisibilityDelegate(visible: fmVisible),
                                    occlusionOCRMode: .off, fmVisibilityCheckEnabled: fmEnabled, isAndroid: false, tunables: RunTunables(), uiFramework: .uikit)
        executor.launchedBundleID = "com.example.contacts"
        return await executor.execute(FlowStep(assert: "exists", locator: FlowLocator(label: "検索結果なし"),
                                               timeout: 0.2, occlusionGuard: guardOn))
    }

    func testFoundInTheXCUITestTreeAndReadOnScreenPasses() async {
        let outcome = await run(fmVisible: true)
        XCTAssertEqual("\(outcome.status)", "\(StepResult.Status.passed)")
        XCTAssertTrue(outcome.notes.contains(.foundInXCUITestTree), "\(outcome.notes)")
    }

    /// 木に在っても画面で読めない(モーダルの裏など)なら採らない
    func testFoundButNotReadOnScreenStaysRed() async {
        let outcome = await run(fmVisible: false)
        guard case .failed = outcome.status else { return XCTFail("\(outcome.status)") }
        XCTAssertFalse(outcome.notes.contains(.foundInXCUITestTree))
        XCTAssertTrue(outcome.notes.contains(.xcuitestTreeUnverified), "照会の結果(見つかったが確かめられない)を記録に残す: \(outcome.notes)")
    }

    /// 可視性検証が無効なら照会しない(見つかっただけでは採らない)
    func testVisibilityCheckOffDoesNotConsult() async {
        let outcome = await run(fmVisible: true, guardOn: false)
        guard case .failed = outcome.status else { return XCTFail("\(outcome.status)") }
        XCTAssertFalse(outcome.notes.contains(.foundInXCUITestTree))
        XCTAssertTrue(outcome.notes.contains(.xcuitestTreeNotConsulted), "\(outcome.notes)")
    }

    /// 段が1つも設定されていない(FM も OCR も切った)回は文字を読まずに素通りするので採らない
    func testPassThroughWithoutReadingTextDoesNotCount() async {
        let outcome = await run(fmVisible: true, fmEnabled: false)
        guard case .failed = outcome.status else { return XCTFail("\(outcome.status)") }
        XCTAssertFalse(outcome.notes.contains(.foundInXCUITestTree))
    }

    /// 前面を離れたアプリは照会しない(XCUITest の木の読みは activate して引き戻す)
    func testAppNotInFrontIsNotConsulted() async {
        let outcome = await run(fmVisible: true, foreground: false)
        guard case .failed = outcome.status else { return XCTFail("\(outcome.status)") }
        XCTAssertFalse(outcome.notes.contains(.foundInXCUITestTree))
    }

    func testAbsentFromBothTreesStaysRed() async {
        let outcome = await run(fmVisible: true, xcuitestTree: [])
        guard case .failed = outcome.status else { return XCTFail("\(outcome.status)") }
        XCTAssertTrue(outcome.notes.contains(.xcuitestTreeNoMatch), "\(outcome.notes)")
    }
}

/// 操作(tap・type)の対象が in-app の木で解けないとき、キーボードを閉じる前に XCUITest の木を1回照会し、
/// 見つかって XCUITest が押せると答えた要素だけ XCUITest で撃つ(DR-202)
final class XCUITestTreeActionConsultTests: XCTestCase {

    private static let field = ElementInfo(ref: 7, type: "textField", identifier: nil, label: "タイトル", value: nil,
                                           placeholder: nil, enabled: true,
                                           frame: FTRect(x: 20, y: 300, width: 300, height: 40), depth: 0)

    private func run(_ step: FlowStep, hittable: HitTestAnswer, foreground: Bool = true,
                     xcuitestTree: [ElementInfo] = [field]) async -> (StepOutcome, [String]) {
        let log = CallLog()
        let inApp = FakeAppDriver(name: "primary", log: log, snapshotElements: [[]])
        let xcuitest = FakeAppDriver(name: "xcuitest", log: log, snapshotElements: [xcuitestTree])
        xcuitest.appForeground = foreground
        xcuitest.hitTestAnswer = hittable
        let executor = StepExecutor(driver: inApp, typeDriver: xcuitest, delegate: FakeVisibilityDelegate(visible: true),
                                    occlusionOCRMode: .off, fmVisibilityCheckEnabled: false, isAndroid: false,
                                    tunables: RunTunables(), uiFramework: .uikit)
        executor.launchedBundleID = "com.example.reminders"
        let outcome = await executor.execute(step)
        return (outcome, log.entries)
    }

    private var tapStep: FlowStep {
        FlowStep(action: "tap", locator: FlowLocator(label: "タイトル", type: "textField"), occlusionGuard: false)
    }

    func testHittableInTheXCUITestTreeIsTappedThroughXCUITest() async {
        let (outcome, log) = await run(tapStep, hittable: .hittable(true))
        if case .failed(let message) = outcome.status { return XCTFail(message.description) }
        XCTAssertTrue(log.contains("xcuitest.tap(ref:7)"), "\(log)")
        XCTAssertFalse(log.contains { $0.hasPrefix("primary.tap") }, "\(log)")
        XCTAssertTrue(outcome.notes.contains(.actedViaXCUITestTree), "\(outcome.notes)")
    }

    func testTypeIntoTheFieldGoesThroughXCUITest() async {
        let step = FlowStep(action: "type", locator: FlowLocator(label: "タイトル", type: "textField"), text: "牛乳",
                            occlusionGuard: false)
        let (outcome, log) = await run(step, hittable: .hittable(true))
        XCTAssertTrue(log.contains { $0.hasPrefix("xcuitest.type(ref:7)") }, "\(log) \(outcome.status)")
        XCTAssertTrue(outcome.notes.contains(.actedViaXCUITestTree), "\(outcome.notes)")
    }

    /// 木に在っても押せない(モーダルの裏など)と答えたら撃たない
    func testNotHittableIsNotActedOn() async {
        let (outcome, log) = await run(tapStep, hittable: .hittable(false))
        guard case .failed = outcome.status else { return XCTFail("\(outcome.status)") }
        XCTAssertFalse(log.contains { $0.contains(".tap(ref:") }, "\(log)")
        XCTAssertFalse(outcome.notes.contains(.actedViaXCUITestTree))
    }

    /// 押せるかを答えられないなら撃たない(推測で採らない)
    func testUnansweredHitTestIsNotActedOn() async {
        let (outcome, log) = await run(tapStep, hittable: .unavailable)
        guard case .failed = outcome.status else { return XCTFail("\(outcome.status)") }
        XCTAssertFalse(log.contains { $0.contains(".tap(ref:") }, "\(log)")
    }

    /// 前面を離れたアプリは照会しない(XCUITest の木の読みは activate して引き戻す)
    func testAppNotInFrontIsNotConsulted() async {
        let (outcome, log) = await run(tapStep, hittable: .hittable(true), foreground: false)
        guard case .failed = outcome.status else { return XCTFail("\(outcome.status)") }
        XCTAssertFalse(log.contains("xcuitest.tap(ref:7)"), "\(log)")
    }
}
