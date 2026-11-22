import XCTest
@testable import FTCore

/// 親の開始の行(RR-8.4)を `RunOrchestrator.run` の本物で通す。実際のデバイスは加わらないので、シナリオのプロセスは起きない
final class RunStartGateOrchestratorTests: XCTestCase {
    private func makeOrchestrator() throws -> RunOrchestrator {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("RunStartGateOrchestratorTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return RunOrchestrator(
            project: TestProject(name: "StartGate", rootURL: root), workers: [],
            settings: ScenarioExecutionSettings(fm: FMConfig(enabled: false)),
            reportDir: root.appendingPathComponent("reports"), progressHistoryRuns: 1, clearResidualSystemAlert: nil,
            // android を担当する(遅れて加わる)ワーカーがいる形にする。担当のいない OS のシナリオは開始待ちより前に
            // 「no worker available」で失敗に数えられるので、ワーカー0台のままだと取りやめの経路を見られない
            lateWorkers: (platforms: ["android"], provider: { [] }))
    }

    private func item(_ id: String) -> ScenarioRunItem {
        ScenarioRunItem(info: ScenarioInfo(id: id, title: id, platform: "android"), variant: nil)
    }

    private static func events(_ orchestrator: RunOrchestrator) async -> (skipped: [String], logs: [String]) {
        var skipped: [String] = []
        var logs: [String] = []
        for await event in orchestrator.events {
            if case .flowSkipped(let url, _) = event { skipped.append(url.lastPathComponent) }
            if case .workerLog(_, let message) = event { logs.append(message) }
        }
        return (skipped, logs)
    }

    /// 取りやめ: 1本も流さず・未実行を失敗に数えず・afterAll の行も出さず・理由が abortReason と startCancelled に入る。中断ではない
    func testCancelledGateStopsTheRunWithoutRecordingTheUnrunScenarios() async throws {
        let orchestrator = try makeOrchestrator()
        async let observed = Self.events(orchestrator)
        let summary = await orchestrator.run(
            items: [item("A.S0010"), item("A.S0020")], defaultPlatform: "android",
            startGate: { .cancel(reason: "beforeRun() failed: boom") })
        let seen = await observed
        XCTAssertEqual(summary.abortReason, "beforeRun() failed: boom")
        XCTAssertEqual(summary.startCancelled, "beforeRun() failed: boom")
        XCTAssertFalse(summary.interrupted, "親の取りやめを利用者の中断として記録している")
        XCTAssertEqual(summary.failed, 0, "流していないシナリオを失敗に数えている")
        XCTAssertTrue(seen.skipped.isEmpty, "流していないシナリオを flowSkipped にしている: \(seen.skipped)")
        XCTAssertFalse(seen.logs.contains { $0.contains("afterAll") }, "何も始まっていない run が afterAll を撃っている")
    }

    /// 中断が取りやめより先に開始待ちを抜けたら、後から取りやめが来ても取りやめとして残さない
    func testInterruptThatWinsTheWaitIsNotRecordedAsACancel() async throws {
        let orchestrator = try makeOrchestrator()
        async let observed = Self.events(orchestrator)
        Task {
            try? await Task.sleep(for: .milliseconds(200))
            orchestrator.requestInterrupt()
        }
        let summary = await orchestrator.run(
            items: [item("A.S0010")], defaultPlatform: "android",
            startGate: {
                try? await Task.sleep(for: .seconds(2))
                return .cancel(reason: "beforeRun() failed: late")
            })
        _ = await observed
        XCTAssertNil(summary.startCancelled)
        XCTAssertNil(summary.abortReason)
        XCTAssertTrue(summary.interrupted)
    }

    func testStartSignalLeavesNoCancelMark() async throws {
        let orchestrator = try makeOrchestrator()
        async let observed = Self.events(orchestrator)
        let summary = await orchestrator.run(items: [], defaultPlatform: "android", startGate: { .start })
        _ = await observed
        XCTAssertNil(summary.startCancelled)
    }
}
