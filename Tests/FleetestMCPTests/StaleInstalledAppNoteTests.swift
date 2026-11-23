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

    /// ft_install が最初の呼び出しだと、入れ直す前の比較が入れ直しの応答に載り「入れ直しても古いと言われる」と読まれた。
    /// ft_install では比べず(済みの印も付けない)、次の呼び出しで比べ直す
    func testInstallCallDoesNotCarryTheNoteFromBeforeItInstalled() throws {
        let source = try String(contentsOf: URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/fleetest-mcp/MCPServer+Driver.swift"), encoding: .utf8)
        let skip = try XCTUnwrap(source.range(of: "Self.currentTool != \"ft_install\","))
        let check = try XCTUnwrap(source.range(of: "await installedAppFreshness("))
        XCTAssertLessThan(skip.lowerBound, check.lowerBound)
        XCTAssertLessThan(source.distance(from: skip.lowerBound, to: check.lowerBound), 300, "同じ条件の中で比べる前に断つ")
    }
}
