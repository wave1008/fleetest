// OI-53: Android の /launch が返す stoppedForeground を ft_launch の文に添える。

import XCTest
@testable import FTBridgeClient
@testable import fleetest_mcp

final class OI53StoppedForegroundTests: XCTestCase {

    func testClauseNamesTheStoppedPackage() {
        XCTAssertEqual(MCPServer.stoppedForegroundClause("com.stuck.app"),
                       " (force-stopped com.stuck.app that stayed in front)")
    }

    func testClauseIsEmptyWhenNothingWasStopped() {
        XCTAssertEqual(MCPServer.stoppedForegroundClause(nil), "")
        XCTAssertEqual(MCPServer.stoppedForegroundClause(""), "")
    }

    func testReplyDecodesBothShapesOfTheBridge() throws {
        let with = try JSONDecoder().decode(BridgeClient.LaunchReply.self,
                                            from: Data(#"{"ok":true,"stoppedForeground":"com.x"}"#.utf8))
        XCTAssertEqual(with.stoppedForeground, "com.x")
        let without = try JSONDecoder().decode(BridgeClient.LaunchReply.self, from: Data(#"{"ok":true}"#.utf8))
        XCTAssertNil(without.stoppedForeground)
    }

    func testFtLaunchAndAndroidDriverAreWired() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let tools = try String(contentsOf: root.appendingPathComponent("Sources/fleetest-mcp/MCPServer+SessionTools.swift"), encoding: .utf8)
        XCTAssertTrue(tools.contains("stoppedForegroundClause((launchDriver as? AndroidDriver)?.lastLaunchStoppedForeground)"))
        let driver = try String(contentsOf: root.appendingPathComponent("Sources/FTAndroid/AndroidDriver.swift"), encoding: .utf8)
        XCTAssertTrue(driver.contains("lastLaunchStoppedForeground = try await withBridge { try await $0.launchReportingStoppedForeground"))
    }
}
