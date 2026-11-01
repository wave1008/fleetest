import XCTest
@testable import FTCore

final class DisplayFreezeDetectorTests: XCTestCase {

    func testDigestIsStableAndDistinguishesBytes() {
        let a = Data("frame-a".utf8)
        XCTAssertEqual(DisplayFreezeDetector.digest(a), DisplayFreezeDetector.digest(Data("frame-a".utf8)))
        XCTAssertNotEqual(DisplayFreezeDetector.digest(a), DisplayFreezeDetector.digest(Data("frame-b".utf8)))
        XCTAssertEqual(DisplayFreezeDetector.digest(a).count, 64)
    }

    func testNoPreviousSampleIsNotSuspect() {
        let current = DisplayFreezeDetector.Sample(digest: "x", at: 1000)
        XCTAssertEqual(DisplayFreezeDetector.judge(previous: nil, current: current), .none)
    }

    func testDifferentFrameIsNotSuspectEvenAfterALongSpan() {
        let previous = DisplayFreezeDetector.Sample(digest: "x", at: 0)
        let current = DisplayFreezeDetector.Sample(digest: "y", at: 10_000)
        XCTAssertEqual(DisplayFreezeDetector.judge(previous: previous, current: current), .none)
    }

    func testSameFrameWithinTheMinimumSpanIsNotSuspect() {
        let previous = DisplayFreezeDetector.Sample(digest: "x", at: 100)
        let current = DisplayFreezeDetector.Sample(digest: "x", at: 100 + DisplayFreezeDetector.minSpanSeconds - 0.001)
        XCTAssertEqual(DisplayFreezeDetector.judge(previous: previous, current: current), .none)
    }

    func testSameFrameAtOrBeyondTheMinimumSpanIsSuspect() {
        let previous = DisplayFreezeDetector.Sample(digest: "x", at: 100)
        let atBoundary = DisplayFreezeDetector.Sample(digest: "x", at: 100 + DisplayFreezeDetector.minSpanSeconds)
        XCTAssertEqual(DisplayFreezeDetector.judge(previous: previous, current: atBoundary),
                       .suspect(spanSeconds: DisplayFreezeDetector.minSpanSeconds))
        let later = DisplayFreezeDetector.Sample(digest: "x", at: 100 + 500)
        XCTAssertEqual(DisplayFreezeDetector.judge(previous: previous, current: later), .suspect(spanSeconds: 500))
    }

    /// 既定値をリテラルで固定する(ステータスバーの時計が 1 分に 1 回変わる、が根拠)
    func testMinimumSpanIsPinnedToOneMinute() {
        XCTAssertEqual(DisplayFreezeDetector.minSpanSeconds, 60)
    }

    func testInjectedKeysAreParsedFromTheEnvironment() {
        XCTAssertEqual(DisplayFreezeDetector.injectedKeys(environment: [:]), [])
        XCTAssertEqual(DisplayFreezeDetector.injectedKeys(
            environment: [DisplayFreezeDetector.frozenFrameInjectionKey: "emulator-5554, ABC , ,"]),
            ["emulator-5554", "ABC"])
    }
}

/// 境目の表示の確認の、RunOrchestrator 側の純粋な部品(終了イベントの書き換え・前面へ戻すアプリの解決)
final class LaneDisplayCheckOrchestratorPartsTests: XCTestCase {

    private let url = URL(fileURLWithPath: "/tmp/Foo.swift")

    func testFailedFinishTurnsAPassIntoAFailureAndKeepsTheOtherFields() {
        let passed = RunEvent.flowFinished(worker: "w", flowURL: url, passed: true,
                                           reportURL: URL(fileURLWithPath: "/tmp/r.md"), fm: nil, appCrash: nil,
                                           notApplicableReason: nil)
        guard case .flowFinished(let worker, let flowURL, let ok, let report, _, _, let na, let discarded) =
                RunOrchestrator.failedFinish(passed, discardReason: "a blank screen") else { return XCTFail("not a flowFinished") }
        XCTAssertFalse(ok)
        XCTAssertEqual(worker, "w")
        XCTAssertEqual(flowURL, url)
        XCTAssertEqual(report?.lastPathComponent, "r.md")
        XCTAssertNil(na)
        XCTAssertEqual(discarded, "a blank screen")
    }

    /// 赤で終わった回の結果は子の赤のまま(捨てた理由を出すのは「緑だったのに」の回だけ)
    func testFailedFinishDoesNotCallARedRunDiscarded() {
        let failed = RunEvent.flowFinished(worker: "w", flowURL: url, passed: false, reportURL: nil, fm: nil,
                                           appCrash: nil, notApplicableReason: nil)
        guard case .flowFinished(_, _, _, _, _, _, _, let discarded) =
                RunOrchestrator.failedFinish(failed, discardReason: "a blank screen") else { return XCTFail("not a flowFinished") }
        XCTAssertNil(discarded)
    }

    func testDiscardedNoticeGoesRightAfterTheTimestampAndKeepsTheResultLine() {
        let report = "# Scenario run report\n\n- Result: ✅ passed\n- Timestamp: t\n\n## scene 1\n"
        let lines = ScenarioReportNotice.withDiscardedNotice(report, reason: "a blank screen")
            .components(separatedBy: "\n")
        XCTAssertTrue(lines.contains("- Result: ✅ passed"))
        let timestamp = lines.firstIndex(of: "- Timestamp: t")!
        XCTAssertTrue(lines[timestamp + 2].hasPrefix("> ⚠️ This result was discarded: a blank screen"), "\(lines)")
    }

    func testDiscardedNoticeLeavesAReportWithoutTheHeaderAlone() {
        XCTAssertEqual(ScenarioReportNotice.withDiscardedNotice("no header", reason: "x"), "no header")
    }

    func testFailedFinishLeavesANotApplicableDeclarationAlone() {
        let skipped = RunEvent.flowFinished(worker: "w", flowURL: url, passed: true, reportURL: nil, fm: nil,
                                            appCrash: nil, notApplicableReason: "android only")
        guard case .flowFinished(_, _, let ok, _, _, _, let na, _) = RunOrchestrator.failedFinish(skipped, discardReason: "a blank screen")
        else { return XCTFail("not a flowFinished") }
        XCTAssertTrue(ok)
        XCTAssertEqual(na, "android only")
    }

    /// 前面へ戻すのは実行プロファイルのアプリ。決まらなければ戻さない
    func testRestoreAppFollowsTheRunProfile() {
        XCTAssertEqual(RunOrchestrator.restoreAppID(fromProfile: "com.a", scenarioID: "X.S1"), "com.a")
        XCTAssertNil(RunOrchestrator.restoreAppID(fromProfile: nil, scenarioID: "X.S1"))
    }
}

