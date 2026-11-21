import XCTest
@testable import fleetest_mcp

/// ft_status の session がプロファイルのアプリと違うときの注記
final class StatusProfileAppNoteTests: XCTestCase {
    func testDifferentAppIsNamed() {
        let note = MCPServer.profileAppMismatchNote(session: "com.ftester.e2ey.rn", profileApp: "com.ftester.e2e.rn")
        XCTAssertTrue(note.contains("com.ftester.e2e.rn"), note)
    }

    func testSameAppOrUnknownSaysNothing() {
        XCTAssertEqual(MCPServer.profileAppMismatchNote(session: "com.ftester.e2e.rn", profileApp: "com.ftester.e2e.rn"), "")
        XCTAssertEqual(MCPServer.profileAppMismatchNote(session: "com.ftester.e2e.rn", profileApp: nil), "")
        XCTAssertEqual(MCPServer.profileAppMismatchNote(session: nil, profileApp: "com.ftester.e2e.rn"), "")
    }

    func testSpringboardSaysNothing() {
        XCTAssertEqual(MCPServer.profileAppMismatchNote(session: "com.apple.springboard", profileApp: "com.ftester.e2e"), "")
    }
}
