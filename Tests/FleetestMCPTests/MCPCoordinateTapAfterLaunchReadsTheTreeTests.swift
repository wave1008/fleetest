// OI-111: launch の直後に木を読まずに座標を撃つ iOS の手は、撃つ前に木を1回読む(描画前に撃つ窓を閉じる)。
// 読んだ後・木を既に読んでいた回は余計に読まない。

import XCTest
import FTCore
@testable import fleetest_mcp

final class MCPCoordinateTapAfterLaunchReadsTheTreeTests: XCTestCase {

    private var driver: FakeDriver!
    private var server: MCPServer!

    override func setUp() {
        super.setUp()
        driver = FakeDriver()
        let fake = driver!
        server = MCPServer(write: { _ in }, makeDriver: { _ in fake }, recordSnapshot: { _, _, _ in })
    }

    func testCoordinateTapRightAfterLaunchReadsTheTreeBeforeFiring() async throws {
        _ = try await server.call(tool: "ft_launch", args: ["bundleId": "com.example.app"])
        _ = try await server.call(tool: "ft_tap", args: ["x": 100.0, "y": 200.0])
        let read = driver.calls.firstIndex { $0.hasPrefix("snapshot") }
        let tap = driver.calls.firstIndex { $0.hasPrefix("tap(") }
        XCTAssertNotNil(read, "\(driver.calls)")
        XCTAssertNotNil(tap, "\(driver.calls)")
        if let read, let tap { XCTAssertLessThan(read, tap, "\(driver.calls)") }
    }

    func testATreeReadAfterLaunchMeansTheTapAddsNoReadBeforeFiring() async throws {
        _ = try await server.call(tool: "ft_launch", args: ["bundleId": "com.example.app"])
        _ = try await server.call(tool: "ft_snapshot", args: [:])
        let reads = driver.calls.filter { $0.hasPrefix("snapshot") }.count
        _ = try await server.call(tool: "ft_tap", args: ["x": 100.0, "y": 200.0])
        let tapIndex = driver.calls.firstIndex { $0.hasPrefix("tap(") }
        let readsBeforeTap = driver.calls.prefix(tapIndex ?? 0).filter { $0.hasPrefix("snapshot") }.count
        XCTAssertEqual(readsBeforeTap, reads, "\(driver.calls)")
    }
}
