// RunHostLoad(results-compare の hostLoad)の集計。run 間の CPU を並べる唯一の口なので、
// 集計が静かに間違うと性能判断を誤らせる。

import XCTest
import Foundation
@testable import FTCore

final class RunHostLoadTests: XCTestCase {

    private func line(ts: Double?, cpu: Double? = nil, gpu: Double? = nil,
                      memUsed: Int? = nil, memTotal: Int? = nil, kind: String = "hostMetrics") -> String {
        var obj: [String: Any] = ["kind": kind]
        if let ts { obj["ts"] = ts }
        if let cpu { obj["cpu"] = cpu }
        if let gpu { obj["gpu"] = gpu }
        if let memUsed { obj["memUsedBytes"] = memUsed }
        if let memTotal { obj["memTotalBytes"] = memTotal }
        let data = try! JSONSerialization.data(withJSONObject: obj)
        return String(decoding: data, as: UTF8.self)
    }

    func testMedianOfOddCountAndPeak() {
        let r = RunHostLoad.summarize(lines: [10, 90, 30].enumerated().map { line(ts: Double($0.offset), cpu: $0.element) },
                                      runID: "r", machine: "m")
        XCTAssertEqual(r.samples, 3)
        XCTAssertEqual(r.cpu.median, 30)
        XCTAssertEqual(r.cpu.peak, 90)
        XCTAssertEqual(r.machine, "m")
    }

    func testMedianOfEvenCountIsMeanOfMiddleTwo() {
        let r = RunHostLoad.summarize(lines: [10, 20, 40, 100].enumerated().map { line(ts: Double($0.offset), cpu: $0.element) },
                                      runID: "r", machine: nil)
        XCTAssertEqual(r.cpu.median, 30)
    }

    func testNullOnlyValuesStayNilButSamplesCount() {
        let r = RunHostLoad.summarize(lines: [line(ts: 1), line(ts: 2)], runID: "r", machine: nil)
        XCTAssertEqual(r.samples, 2)
        XCTAssertNil(r.gpu.median)
        XCTAssertNil(r.gpu.peak)
        XCTAssertNil(r.memPeakUsedBytes)
        XCTAssertNil(r.memTotalBytes)
    }

    func testIgnoresOtherKindsMissingTsAndGarbage() {
        let r = RunHostLoad.summarize(
            lines: [line(ts: 1, cpu: 10), line(ts: 2, cpu: 999, kind: "other"), line(ts: nil, cpu: 999), "not json"],
            runID: "r", machine: nil)
        XCTAssertEqual(r.samples, 1)
        XCTAssertEqual(r.cpu.peak, 10)
    }

    func testMemoryPeakAndLastSeenTotal() {
        let r = RunHostLoad.summarize(
            lines: [line(ts: 1, memUsed: 1000, memTotal: 8000), line(ts: 2, memUsed: 3000, memTotal: 16000),
                    line(ts: 3, memUsed: 2000)],
            runID: "r", machine: nil)
        XCTAssertEqual(r.memPeakUsedBytes, 3000)
        XCTAssertEqual(r.memTotalBytes, 16000)
    }

    func testLoadReadsRotatedGenerationAndCurrentFile() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("runhostload-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try (line(ts: 1, cpu: 10) + "\n").write(to: dir.appendingPathComponent("host-metrics.ndjson.1"), atomically: true, encoding: .utf8)
        try (line(ts: 2, cpu: 50) + "\n").write(to: dir.appendingPathComponent("host-metrics.ndjson"), atomically: true, encoding: .utf8)
        let r = RunHostLoad.load(runDir: dir, runID: "r")
        XCTAssertEqual(r.samples, 2)
        XCTAssertEqual(r.cpu.median, 30)
        XCTAssertNil(r.machine)
    }

    func testMissingFilesMeanZeroSamplesAndNulls() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("runhostload-none-\(UUID().uuidString)")
        let r = RunHostLoad.load(runDir: dir, runID: "r")
        XCTAssertEqual(r.samples, 0)
        XCTAssertNil(r.cpu.median)
        let json = String(decoding: try JSONEncoder().encode(r), as: UTF8.self)
        XCTAssertTrue(json.contains("\"memTotalBytes\":null"), json)
        XCTAssertTrue(json.contains("\"machine\":null"), json)
    }
}
