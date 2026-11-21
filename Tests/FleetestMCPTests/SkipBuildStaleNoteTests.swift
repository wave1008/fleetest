import XCTest
@testable import fleetest_mcp

/// skipBuild で古いバイナリを回したときの注記(判定は ScenarioHost.skipBuildStaleWarning が CLI と共有)
final class SkipBuildStaleNoteTests: XCTestCase {
    func testNoteWhenSkippingBuildWithStaleSource() throws {
        let note = try XCTUnwrap(MCPServer.skipBuildStaleNote(skipBuild: true, stale: true))
        XCTAssertTrue(note.contains("OLD binary"), note)
        XCTAssertTrue(note.contains("without skipBuild"), note)
    }

    func testSilentWhenSourceIsNotStaleOrBuildWasNotSkipped() {
        XCTAssertNil(MCPServer.skipBuildStaleNote(skipBuild: true, stale: false))
        XCTAssertNil(MCPServer.skipBuildStaleNote(skipBuild: false, stale: true))
    }

    /// skipBuild を受ける3つのツール(一覧・dry-run・実行)の実装は、どれも古いバイナリの注記を通す。
    /// 一覧だけ通していなかった = 古いバイナリから消したシナリオを「ある」と返した(シナリオ作成の評価 7回目)
    func testEveryToolTakingSkipBuildAttachesTheStaleNote() throws {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Sources/fleetest-mcp/MCPServer+ScenarioTools.swift")
        let source = try String(contentsOf: url, encoding: .utf8)
        for function in ["func listScenarios(", "func dryRun(", "func runScenario("] {
            let start = try XCTUnwrap(source.range(of: function), function)
            let rest = source[start.upperBound...]
            let end = rest.range(of: "\n    func ")?.lowerBound ?? rest.endIndex
            XCTAssertTrue(rest[..<end].contains("skipBuildStaleNote(args, project: project)"),
                          "\(function) が古いバイナリの注記を通していない")
        }
    }
}
