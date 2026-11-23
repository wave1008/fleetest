// 入っているアプリが appPath と違うときの注記の文言決定。デバイスは使わない。

import XCTest
@testable import fleetest_mcp

final class StaleInstalledAppNoteTests: XCTestCase {
    private func note(_ f: InstalledAppFreshness, again: Bool = false) -> String? {
        MCPServer.staleInstalledAppNote(freshness: f, bundleID: "com.example.app",
                                        appPath: "/p/app.apk", alreadyChecked: again)
    }

    func testSameGivesNoNote() { XCTAssertNil(note(.same)) }

    func testDiffersNamesPathAndInstallTool() throws {
        let text = try XCTUnwrap(note(.differs))
        XCTAssertTrue(text.contains("/p/app.apk"))
        XCTAssertTrue(text.contains("com.example.app"))
        XCTAssertTrue(text.contains("ft_install packagePath: /p/app.apk"))
    }

    func testNotComparableGivesNoNote() { XCTAssertNil(note(.notComparable)) }

    func testSecondCheckInTheSameSessionGivesNoNote() { XCTAssertNil(note(.differs, again: true)) }
}
