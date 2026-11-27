// monitorRuns.jobs(DS-18)の変換・中継・配線の検証。
// 守るもの: ①死んだ pid の running は canceled として出す(生きていれば running のまま・pid 無しは触らない)
// ②並びは startedAt → jobID で固定 ③mine は issuer 一致のときだけ(nil は false)
// ④中継は machines の "local" だけをその機械名へ書き換える ⑤run / api run の両経路が RunExitGuard の jobRun を渡す
// ⑥複数対象の run はジョブの行を受け持つ ⑦リモートの run は FT_JOB_ID と FT_JOB_MARKED=1 を一緒に運ぶ

import XCTest
import FTCore
import FTRemote
@testable import fleetest

final class ApiMonitorJobsTests: XCTestCase {
    private let now = ISO8601DateFormatter().date(from: "2026-11-18T10:10:00Z")!

    private func record(_ id: String, startedAt: String = "2026-11-18T10:00:00Z", issuer: String? = "me",
                        runs: [JobRunEntry]) -> JobProgressRecord {
        JobProgressRecord(jobID: id, title: "t", issuer: issuer, ownerPid: 1, startedAt: startedAt, runs: runs)
    }

    func testRunningRunWithDeadPidIsShownCanceled() {
        let runs = [JobRunEntry(project: "A", profile: "p", state: .running, pid: 10),
                    JobRunEntry(project: "B", profile: "p", state: .running, pid: 11),
                    JobRunEntry(project: "C", profile: "p", state: .running, machines: ["local"]),
                    JobRunEntry(project: "D", profile: "p", state: .passed)]
        let out = ApiMonitorCommand.monitorJobs(records: [record("j", runs: runs)], now: now, myIssuer: "me",
                                                isAlive: { $0 == 11 })
        XCTAssertEqual(out[0].runs.map(\.state), ["canceled", "running", "running", "passed"])
        XCTAssertEqual(out[0].elapsedSeconds, 600)
    }

    /// 変化の判定に使う「死んだ実行中の行の pid」。台帳が変わらないまま run が死んでも1行出し直すため
    func testOrphanedJobPidsAreOnlyDeadRunningRows() {
        let runs = [JobRunEntry(project: "A", profile: "p", state: .running, pid: 10),
                    JobRunEntry(project: "B", profile: "p", state: .running, pid: 11),
                    JobRunEntry(project: "C", profile: "p", state: .running),
                    JobRunEntry(project: "D", profile: "p", state: .passed, pid: 12)]
        XCTAssertEqual(ApiMonitorCommand.orphanedJobPids(records: [record("j", runs: runs)], isAlive: { $0 == 11 }), [10])
    }

    /// 監視の周期が死んだ pid の集合の変化でも出し直すこと(記録の比較だけに戻すと、死んだ run が実行中のまま見え続ける)
    func testMonitorLoopEmitsWhenOrphanedPidsChange() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let source = try String(contentsOf: root.appendingPathComponent("Sources/fleetest/ApiMonitorCommand.swift"), encoding: .utf8)
        XCTAssertTrue(source.contains("|| orphanedJobPids != lastOrphanedJobPids"))
    }

    func testOrderingAndMine() {
        let a = record("b", startedAt: "2026-11-18T10:00:00Z", runs: [])
        let b = record("a", startedAt: "2026-11-18T10:00:00Z", issuer: nil, runs: [])
        let c = record("c", startedAt: "2026-11-18T09:00:00Z", issuer: "other", runs: [])
        let out = ApiMonitorCommand.monitorJobs(records: [a, b, c], now: now, myIssuer: "me", isAlive: { _ in true })
        XCTAssertEqual(out.map(\.jobID), ["c", "a", "b"])
        XCTAssertEqual(out.map(\.mine), [false, false, true])
    }

    func testFanoutRewritesOnlyLocalMachineNames() {
        let job = ApiMonitorJob(jobID: "j", title: "t", issuer: nil, mine: false, elapsedSeconds: 0, runs: [
            ApiMonitorJobRun(project: "A", profile: "p", state: "running", machines: ["local", "M3"])],
            preparing: [ApiMonitorJobPreparing(machine: "local", stage: "checkingRunner", project: "A", profile: "p"),
                        ApiMonitorJobPreparing(machine: "M3", stage: "startingRun", project: "A", profile: "p")])
        let out = RemoteMonitorFanout.machineStamped(jobs: [job], machine: "M1Ultra")
        XCTAssertEqual(out[0].runs[0].machines, ["M1Ultra", "M3"])
        XCTAssertEqual(out[0].preparing.map(\.machine), ["M1Ultra", "M3"], "準備中の機械名の local もその機械名へ書き換える")
    }

    /// 準備中の段階は機械名順で、台帳の値をそのまま運ぶ。無ければ空配列
    func testPreparingIsEmittedSortedByMachine() {
        var r = record("j", runs: [])
        r.preparing = ["M2": JobPreparingActivity(stage: .sendingScenarios, project: "A", profile: "p"),
                       "M1": JobPreparingActivity(stage: .collectingResults, project: "B", profile: "q")]
        let out = ApiMonitorCommand.monitorJobs(records: [r, record("k", runs: [])], now: now, myIssuer: "me",
                                                isAlive: { _ in true })
        XCTAssertEqual(out[0].preparing, [
            ApiMonitorJobPreparing(machine: "M1", stage: "collectingResults", project: "B", profile: "q"),
            ApiMonitorJobPreparing(machine: "M2", stage: "sendingScenarios", project: "A", profile: "p")])
        XCTAssertEqual(out[1].preparing, [])
    }

    func testFanoutIngestStampsJobsInRelayedMonitorRunsLine() throws {
        let relayed = LockedValue<[String]>([])
        let fanout = RemoteMonitorFanout(machines: ["M1Ultra"], project: "P", profile: nil, interval: 2, maxWidth: 960,
                                         log: { _ in }, relayLine: { line in relayed.withLock { $0.append(line) } })
        let event = ApiMonitorRunsEvent(runs: [], services: [], jobs: [
            ApiMonitorJob(jobID: "j", title: "t", issuer: nil, mine: false, elapsedSeconds: 0, runs: [
                ApiMonitorJobRun(project: "A", profile: "p", state: "running", machines: ["local"])],
                preparing: [ApiMonitorJobPreparing(machine: "local", stage: "startingRun", project: "A", profile: "p")])])
        fanout.ingest(line: String(data: try JSONEncoder().encode(event), encoding: .utf8)!, machine: "M1Ultra")
        let out = try XCTUnwrap(relayed.withLock { $0.first })
        let decoded = try JSONDecoder().decode(ApiMonitorRunsEvent.self, from: Data(out.utf8))
        XCTAssertEqual(decoded.jobs[0].runs[0].machines, ["M1Ultra"])
        XCTAssertEqual(decoded.jobs[0].preparing[0].machine, "M1Ultra")
        XCTAssertEqual(decoded.machine, "M1Ultra")
    }

    // MARK: 配線(ソース走査)

    private static func code(_ path: String) throws -> String {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent(path)
        return try String(contentsOf: url, encoding: .utf8)
    }

    func testBothRunPathsPassJobRunToTheExitGuard() throws {
        for path in ["Sources/fleetest/Fleetest.swift", "Sources/fleetest/ApiRunCommand.swift"] {
            let text = try Self.code(path)
            XCTAssertTrue(text.contains("RunExitGuard.run(log:") && text.contains("jobRun: jobRunTarget"),
                          "\(path): RunExitGuard.run に jobRun を渡していない(この経路の run はジョブの行を受け持たない)")
            XCTAssertTrue(text.contains("dryRun ? nil"), "\(path): dry-run は受け持たない")
        }
        let guardText = try Self.code("Sources/fleetest/RunExitGuard.swift")
        XCTAssertTrue(guardText.contains("JobMembership.claim("))
        XCTAssertGreaterThanOrEqual(guardText.components(separatedBy: "JobMembership.finish(exitCode:").count - 1, 2,
                                    "正常終了と例外の両方の出口で finish する")
    }

    func testMultiTargetRunnerOwnsRowsAndDoesNotClaim() throws {
        let text = try Self.code("Sources/fleetest/MultiTargetRunner.swift")
        XCTAssertTrue(text.contains("MultiTargetJobTracker.begin("))
        XCTAssertTrue(text.contains("job?.closeOut()"))
        XCTAssertTrue(text.contains("state: .skipped"))
        XCTAssertFalse(text.contains("JobMembership.claim("), "複数対象の run は MultiTargetRunner が行を受け持つ")
    }

    func testRemoteRunCommandCarriesJobIDWithMarker() {
        let layout = RemoteLayout(base: "/b", issuer: "me", home: "/h")
        let run = RemoteShell.remoteRunCommand(layout: layout, fleetestArgs: ["run"], streamOwner: nil, jobID: "J-1")
        XCTAssertTrue(run.contains("export FT_JOB_ID='J-1'") || run.contains("export FT_JOB_ID=J-1"))
        XCTAssertTrue(run.contains("export FT_JOB_MARKED=1"), "リモートの run は行を受け持たない")
        let none = RemoteShell.remoteRunCommand(layout: layout, fleetestArgs: ["run"], streamOwner: nil, jobID: nil)
        XCTAssertFalse(none.contains("FT_JOB"))
    }
}
