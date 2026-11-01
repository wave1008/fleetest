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

    /// 通常の run の入口(ビルドと buildNeeded)が掃除を通ること
    func testHostBuildEntriesSweep() throws {
        let path = #filePath.replacingOccurrences(
            of: "Tests/FTCoreTests/StagedScenarioSweepTests.swift", with: "Sources/FTCore/ScenarioHost.swift")
        let host = try String(contentsOfFile: path, encoding: .utf8)
        XCTAssertEqual(host.components(separatedBy: "StagedScenarioSweep.sweepIfAbandoned").count - 1, 2)
    }
}
