import XCTest
@testable import FTCore

/// SIGKILL された run-file の置き場は、持ち主が死んでいるときだけ通常の run の開始で消える
final class StagedScenarioSweepTests: XCTestCase {
    private var scenarios: URL!

    override func setUpWithError() throws {
        scenarios = FileManager.default.temporaryDirectory.appendingPathComponent("sweep-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: scenarios, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: scenarios) }

    private func stage(owner: pid_t?) throws -> URL {
        let dir = StagedScenarioSweep.stageDirectory(scenariosDir: scenarios)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try "x".write(to: dir.appendingPathComponent("P5.swift"), atomically: true, encoding: .utf8)
        if let owner { try StagedScenarioSweep.claim(stageDir: dir, pid: owner) }
        return dir
    }

    func testDeadOwnerLeftoverIsRemoved() throws {
        let dir = try stage(owner: 4242)
        XCTAssertTrue(StagedScenarioSweep.sweepIfAbandoned(scenariosDir: scenarios, isAlive: { _ in false }))
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.path))
    }

    func testLiveOwnerStageIsKept() throws {
        let dir = try stage(owner: 4242)
        XCTAssertFalse(StagedScenarioSweep.sweepIfAbandoned(scenariosDir: scenarios, isAlive: { $0 == 4242 }))
        XCTAssertTrue(FileManager.default.fileExists(atPath: dir.path))
    }

    func testStageWithoutOwnerIsRemoved() throws {
        let dir = try stage(owner: nil)
        XCTAssertTrue(StagedScenarioSweep.sweepIfAbandoned(scenariosDir: scenarios, isAlive: { _ in true }))
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.path))
    }

    func testNothingStagedIsANoOp() {
        XCTAssertFalse(StagedScenarioSweep.sweepIfAbandoned(scenariosDir: scenarios))
    }

    /// 通常の run の入口(ビルドと buildNeeded)と `--skip-build` の入口(warnIfSkipBuildStale)が掃除を通ること
    func testHostBuildEntriesSweep() throws {
        let path = #filePath.replacingOccurrences(
            of: "Tests/FTCoreTests/StagedScenarioSweepTests.swift", with: "Sources/FTCore/ScenarioHost.swift")
        let host = try String(contentsOfFile: path, encoding: .utf8)
        XCTAssertEqual(host.components(separatedBy: "StagedScenarioSweep.sweepIfAbandoned").count - 1, 3)
    }

    // MARK: - --wait-lock の置き場の待ち

    func testWaitUntilFreeTimesOutWhileALiveOwnerHoldsTheStage() throws {
        _ = try stage(owner: 4242)
        var clock = Date(timeIntervalSince1970: 0)
        var polls = 0
        let free = StagedScenarioSweep.waitUntilFree(
            scenariosDir: scenarios, waitSeconds: 3, pollSeconds: 1,
            isAlive: { _ in true }, sleep: { clock.addTimeInterval($0); polls += 1 }, now: { clock })
        XCTAssertFalse(free)
        XCTAssertEqual(polls, 3, "秒数ぶん待ってから諦める")
    }

    func testWaitUntilFreeReturnsOnceTheOwnerDies() throws {
        let dir = try stage(owner: 4242)
        var clock = Date(timeIntervalSince1970: 0)
        var alive = true
        let free = StagedScenarioSweep.waitUntilFree(
            scenariosDir: scenarios, waitSeconds: 60, pollSeconds: 1,
            isAlive: { _ in alive }, sleep: { clock.addTimeInterval($0); alive = false }, now: { clock })
        XCTAssertTrue(free)
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.path))
    }

    func testWaitUntilFreeWithZeroSecondsDoesNotWait() throws {
        _ = try stage(owner: 4242)
        var slept = false
        XCTAssertFalse(StagedScenarioSweep.waitUntilFree(
            scenariosDir: scenarios, waitSeconds: 0, isAlive: { _ in true }, sleep: { _ in slept = true }))
        XCTAssertFalse(slept)
    }

    /// run-file の `--wait-lock` が置き場の待ちへ渡ること(渡し忘れると別の run-file が動いているだけで 0.1 秒で断る)
    func testRunFileStageReceivesTheWaitLock() throws {
        let path = #filePath.replacingOccurrences(
            of: "Tests/FTCoreTests/StagedScenarioSweepTests.swift", with: "Sources/fleetest/RunFileCommand.swift")
        let source = try String(contentsOfFile: path, encoding: .utf8)
        XCTAssertTrue(source.contains("waitSeconds: waitLock ?? 0"))
        XCTAssertTrue(source.contains("StagedScenarioSweep.waitUntilFree"))
    }
}
