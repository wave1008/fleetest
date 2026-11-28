import XCTest
@testable import fleetest

/// CLI の `results slow` は `--since` の窓をそのまま集計する(summary / flaky と同じ)。
final class ResultsCommandWindowTests: XCTestCase {

    func testSlowCommandPassesTheWholeSinceWindow() throws {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Sources/fleetest/ResultsCommand.swift")
        let code = try String(contentsOf: url, encoding: .utf8).components(separatedBy: "\n")
            .map { $0.components(separatedBy: "//")[0] }.joined(separator: "\n")
        XCTAssertTrue(code.contains("slowTests(records, limit: limit, recentRuns: .max)"),
                      "slowTests に recentRuns を渡し忘れると既定の直近10回に落ちて --since が効かない")
    }
}
