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
}
