// results-compare の hostLoad の配線: 各 runID を月のフォルダから引き、前回/今回の側と指定順を保つ。
// RunHostLoadTests は集計だけを見るので、側の取り違え・runDir の解決違いはここでしか落ちない。

import XCTest
import Foundation
import FTCore
@testable import fleetest

final class ResultsCompareHostLoadTests: XCTestCase {

    private func writeRun(_ resultsDir: URL, _ runID: String, cpu: Double) throws {
        let dir = RunResultsStore.runDir(resultsDir: resultsDir, runID: runID)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let line = "{\"kind\":\"hostMetrics\",\"ts\":1,\"cpu\":\(cpu)}\n"
        try line.write(to: dir.appendingPathComponent("host-metrics.ndjson"), atomically: true, encoding: .utf8)
    }

    func testEachSideKeepsItsRunsInTheGivenOrder() throws {
        let resultsDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("compare-hostload-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: resultsDir) }
        try writeRun(resultsDir, "20261101-000000Z-aaaaaaaa", cpu: 0.1)
        try writeRun(resultsDir, "20261102-000000Z-bbbbbbbb", cpu: 0.2)
        try writeRun(resultsDir, "20261128-000000Z-cccccccc", cpu: 0.9)

        let load = ApiResultsCompareCommand.hostLoad(
            resultsDir: resultsDir,
            previous: ["20261102-000000Z-bbbbbbbb", "20261101-000000Z-aaaaaaaa"],
            latest: ["20261128-000000Z-cccccccc", "20261128-000000Z-dddddddd"])

        XCTAssertEqual(load.previous.map(\.runID), ["20261102-000000Z-bbbbbbbb", "20261101-000000Z-aaaaaaaa"])
        XCTAssertEqual(load.previous.map(\.cpu.median), [0.2, 0.1])
        XCTAssertEqual(load.latest.map(\.cpu.median), [0.9, nil])
        XCTAssertEqual(load.latest.map(\.samples), [1, 0], "記録の無い run は samples 0(エラーにしない)")
    }
}
