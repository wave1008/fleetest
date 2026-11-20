import XCTest
@testable import FTCore
import FTRemote

final class RunWideHookPlanTests: XCTestCase {
    func testRunsOnlyWhenAClassExistsScenariosExistAndItIsNotADryRunOrALinkedChild() {
        XCTAssertEqual(RunWideHookPlan.hooksClassToRun(hooksClass: "Hooks", scenarioCount: 1, dryRun: false, linkedToParent: false), "Hooks")
        XCTAssertNil(RunWideHookPlan.hooksClassToRun(hooksClass: nil, scenarioCount: 1, dryRun: false, linkedToParent: false))
        XCTAssertNil(RunWideHookPlan.hooksClassToRun(hooksClass: "Hooks", scenarioCount: 0, dryRun: false, linkedToParent: false))
        XCTAssertNil(RunWideHookPlan.hooksClassToRun(hooksClass: "Hooks", scenarioCount: 1, dryRun: true, linkedToParent: false))
        XCTAssertNil(RunWideHookPlan.hooksClassToRun(hooksClass: "Hooks", scenarioCount: 1, dryRun: false, linkedToParent: true))
    }

    func testAfterRunRunsOnlyWhenEveryChildEndedNormallyAndTheRunWasNotInterrupted() {
        XCTAssertEqual(RunWideHookPlan.afterRunVerdict(childExitCodes: [], interrupted: false), .run)
        XCTAssertEqual(RunWideHookPlan.afterRunVerdict(childExitCodes: [0, 1, 1], interrupted: false), .run)
        guard case .skip(let abnormal) = RunWideHookPlan.afterRunVerdict(childExitCodes: [0, 255], interrupted: false) else {
            return XCTFail("an abnormal child must skip afterRun")
        }
        XCTAssertTrue(abnormal.contains("255"), abnormal)
        guard case .skip(let reason) = RunWideHookPlan.afterRunVerdict(childExitCodes: [0, 0], interrupted: true) else {
            return XCTFail("an interrupted run must skip afterRun")
        }
        XCTAssertTrue(reason.contains("interrupted"), reason)
        XCTAssertEqual(RunWideHookPlan.afterSkippedLine(reason: "r"), "afterRun did not run: r")
    }

    /// 中継役(`run --runner M`)が打ち切りで向こうの run の終わりを確かめられないときの専用の終了コードは、0 / 1 のどちらでもない
    /// (1 と取り違えると発行元が、まだ動いているテストの下で afterRun を撃つ)
    func testRelayTimeoutExitCodeIsDedicatedAndSkipsAfterRun() {
        XCTAssertEqual(RemoteDispatchExit.runUnconfirmed, 124)
        guard case .skip(let reason) = RunWideHookPlan.afterRunVerdict(
            childExitCodes: [0, RemoteDispatchExit.runUnconfirmed], interrupted: false) else {
            return XCTFail("a relay that ended on a timeout must skip afterRun")
        }
        XCTAssertTrue(reason.contains("124"), reason)
    }

    func testClassifyPutsInterruptionBeforeFailureAndPassIsPass() {
        let ok = RunHookOutcome(passed: true)
        let killed = RunHookOutcome(passed: false, failureReason: "exited with status 15")
        XCTAssertEqual(RunWideHookPlan.classify(outcome: ok, interrupted: false), .passed)
        XCTAssertEqual(RunWideHookPlan.classify(outcome: killed, interrupted: false), .failed(reason: "beforeRun() failed: exited with status 15"))
        XCTAssertEqual(RunWideHookPlan.classify(outcome: killed, interrupted: true), .interrupted, "中断で殺された beforeRun を失敗として記録している")
        XCTAssertEqual(RunWideHookPlan.classify(outcome: ok, interrupted: true), .interrupted)
        XCTAssertEqual(RunWideHookPlan.gateSignal(for: .interrupted), .cancel(reason: "interrupted before the run started"))
        XCTAssertEqual(RunWideHookPlan.gateSignal(for: .passed), .start)
    }

    func testOverlappingRunsLineCountsOtherPidsOfTheSameProjectOnly() {
        func record(_ pid: Int32, _ project: String) -> RunProgressRecord {
            RunProgressRecord(pid: pid, runID: nil, runGroup: nil, issuer: nil, project: project, profile: nil,
                              startedAt: "2026-11-20T00:00:00Z", total: 1, done: 0, failed: 0, actions: 0, requeued: 0,
                              laneDropouts: 0, etaSeconds: nil, lanes: [], phase: "running", supply: [], videoClips: nil,
                              owner: nil, jobID: nil)
        }
        XCTAssertNil(RunWideHookPlan.overlappingRunsLine(project: "P", ownPid: 1, records: [record(1, "P"), record(2, "Q")]))
        let line = RunWideHookPlan.overlappingRunsLine(project: "P", ownPid: 1, records: [record(1, "P"), record(2, "P"), record(3, "P")])
        XCTAssertTrue(line?.contains("2 other run(s)") == true && line?.contains("pid 2, 3") == true, line ?? "nil")
    }

    func testLocalHostNameDoesNotNeedADNSLookup() {
        XCTAssertFalse(RunWideHookPlan.localHostName().isEmpty)
    }

    func testTimeoutIsTheLongestScenarioTimeoutAndFallsBackToTheDefault() {
        XCTAssertEqual(RunWideHookPlan.timeoutSeconds(profileScenarioTimeouts: [120, 900, nil]), 900)
        XCTAssertEqual(RunWideHookPlan.timeoutSeconds(profileScenarioTimeouts: [120]), 120)
        XCTAssertEqual(RunWideHookPlan.timeoutSeconds(profileScenarioTimeouts: [nil]), ScenarioHost.defaultScenarioTimeout)
        XCTAssertEqual(RunWideHookPlan.timeoutSeconds(profileScenarioTimeouts: []), ScenarioHost.defaultScenarioTimeout)
    }

    func testFleetEntriesNeverRunTheHooks() {
        XCTAssertEqual(RunWideHookPlan.hooksClassToRun(hooksClass: "Hooks", scenarioCount: 3, dryRun: false, linkedToParent: false, fleetEntry: false), "Hooks")
        XCTAssertNil(RunWideHookPlan.hooksClassToRun(hooksClass: "Hooks", scenarioCount: 3, dryRun: false, linkedToParent: false, fleetEntry: true),
                     "--fleet のエントリは入口の検査をすり抜けても走らせない")
    }

    func testGateSignalCancelsOnFailureOrInterruptAndStartsOtherwise() {
        let ok = RunHookOutcome(passed: true)
        let bad = RunHookOutcome(passed: false, failureReason: "boom")
        XCTAssertEqual(RunWideHookPlan.gateSignal(for: RunWideHookPlan.classify(outcome: ok, interrupted: false)), .start)
        XCTAssertEqual(RunWideHookPlan.gateSignal(for: RunWideHookPlan.classify(outcome: bad, interrupted: false)), .cancel(reason: "beforeRun() failed: boom"))
        XCTAssertEqual(RunWideHookPlan.gateSignal(for: RunWideHookPlan.classify(outcome: ok, interrupted: true)), .cancel(reason: "interrupted before the run started"))
        XCTAssertEqual(RunWideHookPlan.ranLine(.before, machine: "m1"), "beforeRun ran on m1")
    }

    func testHubFinalValuesFoldsSeededAndChildWritesInOrder() {
        let hub = RunMemoHub(mode: .awaitDecision, send: { _, _ in })
        XCTAssertEqual(hub.seedConfirmed([.write(key: "a", value: "1"), .write(key: "a", value: "2"), .write(key: "b", value: "x")]), 3)
        XCTAssertEqual(hub.finalValues(), ["a": ["1", "2"], "b": ["x"]])
        _ = hub.seedConfirmed([.clear, .write(key: "c", value: "z")])
        XCTAssertEqual(hub.finalValues(), ["c": ["z"]])
    }
}

final class RunHookSourceScanTests: XCTestCase {
    func testDetectsTheAttributeAtTheStartOfALineButNotCommentsOrLongerNames() {
        XCTAssertTrue(RunWideHookPlan.sourceDeclaresRunHooks("import FTDSL\n@RunHooks\nfinal class H {}\n"))
        XCTAssertTrue(RunWideHookPlan.sourceDeclaresRunHooks("  @RunHooks final class H {}"))
        XCTAssertFalse(RunWideHookPlan.sourceDeclaresRunHooks("// @RunHooks goes here\nfinal class H {}"))
        XCTAssertFalse(RunWideHookPlan.sourceDeclaresRunHooks("@RunHooksOther\nfinal class H {}"))
        XCTAssertFalse(RunWideHookPlan.sourceDeclaresRunHooks("@TestClass\nfinal class H {}"))
    }

    func testDetectsTheAttributeAnywhereOutsideCommentsAndStrings() {
        XCTAssertTrue(RunWideHookPlan.sourceDeclaresRunHooks("@MainActor @RunHooks final class X {}"))
        XCTAssertTrue(RunWideHookPlan.sourceDeclaresRunHooks("@MainActor\n@RunHooks(\n) final class X {}"))
        XCTAssertTrue(RunWideHookPlan.sourceDeclaresRunHooks("@FTDSL.RunHooks final class X {}"))
        XCTAssertTrue(RunWideHookPlan.sourceDeclaresRunHooks("// note\n/* c */ @RunHooks final class X {}"))
        XCTAssertFalse(RunWideHookPlan.sourceDeclaresRunHooks("final class X { /* @RunHooks */ }"))
        XCTAssertFalse(RunWideHookPlan.sourceDeclaresRunHooks("/* a /* @RunHooks */ @RunHooks */ final class X {}"))
        XCTAssertFalse(RunWideHookPlan.sourceDeclaresRunHooks("let s = \"@RunHooks\"\nfinal class X {}"))
        XCTAssertFalse(RunWideHookPlan.sourceDeclaresRunHooks("@FTDSL.RunHooksOther final class X {}"))
    }
}

final class RunHookMemoValuesTests: XCTestCase {
    func testFoldsOpsInOrderAndClearDropsEarlierValues() {
        XCTAssertEqual(RunWideHookPlan.memoValues(afterOps: [.write(key: "k", value: "1"), .write(key: "k", value: "2")]), ["k": ["1", "2"]])
        XCTAssertEqual(RunWideHookPlan.memoValues(afterOps: [.write(key: "k", value: "1"), .clear, .write(key: "j", value: "z")]), ["j": ["z"]])
    }
}
