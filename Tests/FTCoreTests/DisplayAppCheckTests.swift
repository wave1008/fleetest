// 表示条件がアプリへ届いたかの確かめ(DisplayAppCheck.swift)の純粋な部分と、その配線の走査。
// 配線は緑の run では1度も通らない(届かない端末が無い)ので、呼び口の消失はソース走査で落とす。

import XCTest
@testable import FTCore

final class DisplayAppCheckTests: XCTestCase {

    private func source(_ path: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return try String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)
    }

    /// 既定値はリテラルで固定する(他のテストが差し替えても production の既定を1度は通す)
    func testLimitsArePinned() {
        XCTAssertEqual(DisplaySettingsLimits.appPropagationSeconds, 5)
        XCTAssertEqual(DisplaySettingsLimits.appPropagationPollSeconds, 0.25)
    }

    func testContentSizeCategoryTable() {
        XCTAssertEqual(FTTextSize.small.uiContentSizeCategory, "UICTContentSizeCategoryS")
        XCTAssertEqual(FTTextSize.default.uiContentSizeCategory, "UICTContentSizeCategoryL")
        XCTAssertEqual(FTTextSize.large.uiContentSizeCategory, "UICTContentSizeCategoryXL")
        XCTAssertEqual(FTTextSize.extraLarge.uiContentSizeCategory, "UICTContentSizeCategoryXXXL")
        XCTAssertEqual(FTTextSize.accessibility.uiContentSizeCategory, "UICTContentSizeCategoryAccessibilityL")
    }

    func testMatchingReportHasNoMismatch() {
        let expected = DisplayAppExpectation(appearance: .dark, textSize: .large)
        let report = InAppDisplayReport(screenAppearance: "dark", contentSizeCategory: "UICTContentSizeCategoryXL")
        XCTAssertEqual(DisplayAppCheck.mismatches(expected: expected, report: report), [])
    }

    /// 出さなくする変異と常に出す変異の両方を落とすため、不一致の側と一致の側を両方置く
    func testMismatchIsNamedPerKey() {
        let expected = DisplayAppExpectation(appearance: .dark, textSize: .default)
        let stuck = InAppDisplayReport(screenAppearance: "light", contentSizeCategory: "UICTContentSizeCategoryL")
        let result = DisplayAppCheck.mismatches(expected: expected, report: stuck)
        XCTAssertEqual(result.count, 1)
        XCTAssertTrue(result[0].contains("appearance: expected dark, the app reports light"), result[0])
        let both = InAppDisplayReport(screenAppearance: "light", contentSizeCategory: "UICTContentSizeCategoryXXL")
        XCTAssertEqual(DisplayAppCheck.mismatches(expected: expected, report: both).count, 2)
    }

    /// 申告が無い欄・期待が無いキーは判定しない(旧ブリッジ・XCUITest・読めなかった)
    func testNoReportOrNoExpectationIsNotJudged() {
        let expected = DisplayAppExpectation(appearance: .dark, textSize: .large)
        XCTAssertEqual(DisplayAppCheck.mismatches(
            expected: expected, report: InAppDisplayReport(screenAppearance: nil, contentSizeCategory: nil)), [])
        XCTAssertEqual(DisplayAppCheck.mismatches(
            expected: DisplayAppExpectation(),
            report: InAppDisplayReport(screenAppearance: "light", contentSizeCategory: "x")), [])
    }

    func testArgumentRoundTripAndHandledKeys() {
        let expected = DisplayExpectation(appearance: .dark, textSize: nil)
        let both = DisplayAppExpectation(expected: expected, handled: [.appearance, .textSize])
        XCTAssertEqual(both.argument, "appearance=dark,textSize=default")
        XCTAssertEqual(DisplayAppExpectation.parse(both.argument ?? ""), both)
        // 合わせられなかった指定の無いキーは渡さない
        let onlyAppearance = DisplayAppExpectation(expected: expected, handled: [.appearance])
        XCTAssertEqual(onlyAppearance.argument, "appearance=dark")
        XCTAssertNil(DisplayAppExpectation(expected: expected, handled: []).argument)
        XCTAssertNil(DisplayAppExpectation.parse("appearance=blue"))
        XCTAssertNil(DisplayAppExpectation.parse("nonsense"))
    }

    func testInjectionOverridesOnlyTheNamedKeysAndGatesRecovery() {
        let report = InAppDisplayReport(screenAppearance: "dark", contentSizeCategory: "UICTContentSizeCategoryXL")
        let env = [DisplayAppInjection.environmentKey: "appearance=light"]
        let faked = DisplayAppInjection.apply(to: report, environment: env)
        XCTAssertEqual(faked.screenAppearance, "light")
        XCTAssertEqual(faked.contentSizeCategory, "UICTContentSizeCategoryXL")
        XCTAssertEqual(DisplayAppInjection.apply(to: report, environment: [:]), report)
        XCTAssertFalse(DisplayAppInjection.recoveryAllowed(environment: env))
        XCTAssertTrue(DisplayAppInjection.recoveryAllowed(
            environment: env.merging([DisplayAppInjection.recoveryEnvironmentKey: "on"]) { $1 }))
        XCTAssertTrue(DisplayAppInjection.recoveryAllowed(environment: [:]))
    }

    func testRecoveryRequestIsTakenOnce() {
        let requests = DisplayRecoveryRequests()
        XCTAssertFalse(requests.take(label: "iPhone-1"))
        requests.request(label: "iPhone-1")
        XCTAssertFalse(requests.take(label: "iPhone-2"))
        XCTAssertTrue(requests.take(label: "iPhone-1"))
        XCTAssertFalse(requests.take(label: "iPhone-1"))
    }

    /// 失敗の種類は DriverError の case で決まる(文言の一致ではない)
    func testFailureKindComesFromTheDriverErrorCase() {
        let error = DriverError.displayNotApplied(detail: "anything at all")
        XCTAssertEqual(StepExecutor.failureKind(thrown: error), .displayNotApplied)
        XCTAssertEqual(StepFailureKind.displayNotApplied.rawValue, "display-not-applied")
        XCTAssertFalse(error.deliveryIsUnknown)
    }

    // MARK: 配線(ソース走査)

    func testDSLChecksAfterLaunchRestartAndTheSetters() throws {
        let app = try source("Sources/FTDSL/CommandsAppControl.swift")
        XCTAssertEqual(app.components(separatedBy: "try await core.awaitDisplayReachedApp()").count - 1, 2,
                       "launchApp と restartApp の直後")
        let display = try source("Sources/FTDSL/CommandsDisplay.swift")
        XCTAssertEqual(display.components(separatedBy: "try await core.awaitDisplayReachedApp()").count - 1, 2,
                       "setAppearance と setTextSize の後")
        XCTAssertTrue(display.contains("core.updateDisplayExpectation(appearance: appearance)"))
        XCTAssertTrue(display.contains("core.updateDisplayExpectation(textSize: size)"))
    }

    func testParentPassesTheExpectationAfterTheStartResult() throws {
        let host = try source("Sources/FTCore/ScenarioHost.swift")
        let start = try XCTUnwrap(host.range(of: "DisplaySettingsEngine.start("))
        let pass = try XCTUnwrap(host.range(of: "\"--display-expected\"", range: start.upperBound..<host.endIndex))
        let run = try XCTUnwrap(host.range(of: "try process.run()", range: start.upperBound..<host.endIndex))
        XCTAssertLessThan(pass.lowerBound, run.lowerBound)
    }

    func testOrchestratorRequestsRecoveryOnlyForSimulatorsAndProviderTakesIt() throws {
        let orchestrator = try source("Sources/FTCore/RunOrchestrator.swift")
        let request = try XCTUnwrap(orchestrator.range(of: "DisplayRecoveryRequests.shared.request(label: worker.label)"))
        let before = String(orchestrator[orchestrator.index(request.lowerBound, offsetBy: -260)..<request.lowerBound])
        XCTAssertTrue(before.contains("Self.requeuesForDisplayNotApplied("), "回復の要求と振り直しは同じ判定で決める")
        let factory = try source("Sources/FTAndroid/ProfileWorkerFactory.swift")
        let take = try XCTUnwrap(factory.range(of: "DisplayRecoveryRequests.shared.take(label: worker.label)"))
        let respring = try XCTUnwrap(factory.range(of: "purpose: .displayNotApplied", range: take.upperBound..<factory.endIndex))
        let gate = try XCTUnwrap(factory.range(of: "DisplayAppInjection.recoveryAllowed(", range: take.upperBound..<factory.endIndex))
        XCTAssertLessThan(gate.lowerBound, respring.lowerBound, "注入の回は許可が無ければ撃たない")
    }

    /// 回復の要求と振り直しの対象は iOS Simulator の `display-not-applied` だけ(実機は起こし直せない・Android は検出しない)
    func testRequeueAndRecoveryOnlyForSimulatorDisplayNotApplied() {
        let kind = StepFailureKind.displayNotApplied.rawValue
        XCTAssertTrue(RunOrchestrator.requeuesForDisplayNotApplied(platform: "ios", physical: false, failedStepKinds: [nil, kind]))
        XCTAssertFalse(RunOrchestrator.requeuesForDisplayNotApplied(platform: "ios", physical: true, failedStepKinds: [kind]))
        XCTAssertFalse(RunOrchestrator.requeuesForDisplayNotApplied(platform: "android", physical: false, failedStepKinds: [kind]))
        XCTAssertFalse(RunOrchestrator.requeuesForDisplayNotApplied(platform: "ios", physical: false, failedStepKinds: [nil, "assertion"]))
        XCTAssertFalse(RunOrchestrator.requeuesForDisplayNotApplied(platform: "ios", physical: false, failedStepKinds: []))
    }

    /// 振り直しは失敗の回だけ・離脱させない(回復は次のシナリオの前)・原因は型で立てる。凍結・環境異常の分岐より前に置く必要は無いが、
    /// 環境異常より前に置いて「届かなかった」の失敗をブレーカの連続失敗に数えない
    func testOrchestratorRequeuesDisplayNotAppliedWithoutRetiring() throws {
        let orchestrator = try source("Sources/FTCore/RunOrchestrator.swift")
        let branch = try XCTUnwrap(orchestrator.range(of: "if outcome == .failed, Self.requeuesForDisplayNotApplied("))
        let tail = String(orchestrator[branch.lowerBound..<orchestrator.index(branch.lowerBound, offsetBy: 900)])
        XCTAssertTrue(tail.contains("cause: .displayNotApplied"))
        XCTAssertFalse(tail.contains("avoidingThisLane: true"), "同じレーンへ戻ってよい(回復の後に走る)")
        XCTAssertFalse(tail.contains("retireUnusable"), "レーンは離脱させない")
        XCTAssertTrue(tail.contains("continue"))
        let breaker = try XCTUnwrap(orchestrator.range(of: "WorkerCircuitBreaker.countsAsLaneFailure("))
        XCTAssertLessThan(branch.lowerBound, breaker.lowerBound, "ブレーカの数えより前で抜ける")
    }
}
