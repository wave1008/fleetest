// beforeRun の失敗と中断の仕分け(RR-8.4)。フックの起動は偽(必ず失敗で返す)に差し替えて、失敗の側の経路を確定的に通す。
// 中断の側は、起こす前に中断を立てて通す(中断で殺された子は passed == false で返るので、仕分けを外すと失敗に化ける)

import FTCore
import XCTest
@testable import fleetest

final class RunHookParentTests: XCTestCase {
    private func makeContext() -> RunHookContext {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("RunHookParentTests-\(UUID().uuidString)")
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return RunHookContext(
            project: TestProject(name: "NoSuchProject", rootURL: root), className: "Hooks", settings: ScenarioExecutionSettings(),
            reportDir: root.appendingPathComponent("reports").path, timeoutSeconds: 5,
            launcher: { _, phase, _, _, _ in
                // 本物の子は起こさない(実行ファイルを探す処理が swift test の SwiftPM のロックを待って止まる)。必ず失敗で返す
                RunHookOutcome(passed: false, failureReason: "\(phase.hookName)() exited with status 1")
            })
    }

    /// 開始の決定を捕まえる(hello を1回送ると、決定済みならその子へ開始か取りやめの行が出る)
    private func decision(of hub: RunMemoHub, sent: LockedValue<[String]>) -> WorkQueueProtocol.StartSignal? {
        hub.receive(line: WorkQueueProtocol.encode(WorkQueueProtocol.MemoHello(src: "s")), from: .init(target: "", entry: 0))
        return sent.withLock { $0 }.compactMap(WorkQueueProtocol.decodeStartSignal).first
    }

    func testAFailedBeforeRunSetsTheFailedFlagAndCancelsTheChildren() async {
        let sent = LockedValue<[String]>([])
        let hub = RunMemoHub(mode: .awaitDecision, send: { _, lines in sent.withLock { $0.append(contentsOf: lines) } })
        let parent = RunHookParent(context: makeContext(), log: { _ in })
        defer { parent.close() }
        let outcome = await parent.start(hub: hub).value
        XCTAssertFalse(outcome.passed)
        XCTAssertTrue(parent.beforeRunFailed)
        XCTAssertEqual(parent.beforeRunFailureReason?.hasPrefix("beforeRun() failed"), true)
        XCTAssertFalse(parent.beforeRunInterrupted)
        guard case .cancel(let reason)? = decision(of: hub, sent: sent) else { return XCTFail("a failure must cancel the children") }
        XCTAssertTrue(reason.hasPrefix("beforeRun() failed"), reason)
    }

    func testAnInterruptedBeforeRunIsNotAFailure() async {
        let sent = LockedValue<[String]>([])
        let hub = RunMemoHub(mode: .awaitDecision, send: { _, lines in sent.withLock { $0.append(contentsOf: lines) } })
        let logged = LockedValue<[String]>([])
        let parent = RunHookParent(context: makeContext(), log: { line in logged.withLock { $0.append(line) } })
        defer { parent.close() }
        parent.interrupt.stop()
        _ = await parent.start(hub: hub).value
        XCTAssertFalse(parent.beforeRunFailed, "中断を beforeRun の失敗として記録している")
        XCTAssertNil(parent.beforeRunFailureReason)
        XCTAssertTrue(parent.beforeRunInterrupted)
        XCTAssertFalse(logged.withLock { $0 }.contains { $0.contains("Run stopped") })
        XCTAssertEqual(decision(of: hub, sent: sent), .cancel(reason: "interrupted before the run started"))
    }

    /// beforeRun が失敗した run の子は1本も流さない(記録の無い JUnit)。結合した JUnit に失敗の項目と理由が載る
    func testMergedJUnitCarriesTheBeforeRunFailure() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("RunHookJUnit-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let empty = JUnitReportWriter.xml(project: "P", records: [])
        try empty.write(to: dir.appendingPathComponent("entry-0.xml"), atomically: true, encoding: .utf8)
        let out = dir.appendingPathComponent("junit.xml")
        FleetRunner.mergeAndWriteJUnit(junit: out.path, project: "P", tempDir: dir, entries: [(host: "local", index: 0)],
                                       beforeRunFailures: [(project: "P", reason: "beforeRun() failed: boom")])
        let xml = try String(contentsOf: out, encoding: .utf8)
        XCTAssertTrue(xml.contains("failures=\"1\""), xml)
        XCTAssertTrue(xml.contains("beforeRun() failed: boom"), xml)
    }

    /// `--fleet` の拒否は、ビルドされない `_disabled/` に退避した `@RunHooks` を数えない
    func testFleetRefusalScanIgnoresTheDisabledFolder() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("RunHookFleetScan-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let project = TestProject(name: "P", rootURL: root)
        try FileManager.default.createDirectory(at: project.disabledDir, withIntermediateDirectories: true)
        let source = "import FTDSL\n@RunHooks\nclass Hooks { func beforeRun() {} }\n"
        try source.write(to: project.disabledDir.appendingPathComponent("Hooks.swift"), atomically: true, encoding: .utf8)
        XCTAssertFalse(FleetRunner.declaresRunHooks(project: project))
        try source.write(to: project.scenariosDir.appendingPathComponent("Hooks.swift"), atomically: true, encoding: .utf8)
        XCTAssertTrue(FleetRunner.declaresRunHooks(project: project))
    }

    /// 他のマシンへ配れない大きさの書き込みは黙って捨てない(通常のシナリオの書き込みの `RunMemoLink.publish` と同じく1行言う)
    func testAnOversizedBeforeRunWriteIsDroppedWithALine() async {
        let base = makeContext()
        let huge = String(repeating: "x", count: RunMemoWire.pieceCharacters * RunMemoWire.maxPieces)
        let context = RunHookContext(
            project: base.project, className: base.className, settings: base.settings, reportDir: base.reportDir,
            timeoutSeconds: 5,
            launcher: { _, _, _, _, _ in
                RunHookOutcome(passed: true, runMemoOps: [.write(key: "big", value: huge), .write(key: "k", value: "v")])
            })
        let hub = RunMemoHub(mode: .awaitDecision, send: { _, _ in })
        let logged = LockedValue<[String]>([])
        let parent = RunHookParent(context: context, log: { line in logged.withLock { $0.append(line) } })
        defer { parent.close() }
        _ = await parent.start(hub: hub).value
        XCTAssertEqual(hub.finalValues(), ["k": ["v"]])
        XCTAssertTrue(logged.withLock { $0 }.contains(RunWideHookPlan.oversizedSeedLine(dropped: 1)), "\(logged.withLock { $0 })")
    }

    func testSingleMachineBeginDoesNotLaunchAfterAnInterruptAndReportsAFailureOtherwise() async {
        let state = RunInterruptState(recorder: nil, forceExit: { _ in })
        let context = makeContext()
        func begin() async -> SingleMachineRunHooks {
            await SingleMachineRunHooks.begin(
                hooksClass: "Hooks", scenarioCount: 1, dryRun: false, project: context.project,
                settings: context.settings, reportDir: context.reportDir, profileScenarioTimeout: 5,
                interruptState: state, launcher: context.launcher, log: { _ in })
        }
        let failed = await begin()
        XCTAssertNotNil(failed.abortReason, "a hook that cannot start is a failure")
        state.requestStop()
        let interrupted = await begin()
        XCTAssertNil(interrupted.abortReason, "中断を beforeRun の失敗として記録している")
        XCTAssertTrue(interrupted.seedOps.isEmpty)
    }
}
