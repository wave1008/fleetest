// ブリッジ自身(BridgeSelfApps)の断りは MCP・DSL だけでなく、CLI の `fleetest launch` にも掛かる
// (撃つとブリッジが自滅する。判定は共有・文言は呼び手ごと)

import XCTest
@testable import fleetest

final class BridgeSelfRefusalCLITests: XCTestCase {
    /// 走査: CLI の launch は撃つ前に断る
    func testCLILaunchRefusesTheBridgeBeforeFiring() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Sources/fleetest")
        let cli = try String(contentsOf: root.appendingPathComponent("ManualDriveCommands.swift"), encoding: .utf8)
        let launch = try XCTUnwrap(cli.range(of: "struct Launch: AsyncParsableCommand"))
        XCTAssertTrue(cli[launch.upperBound...].prefix(900).contains("BridgeSelfApps.isBridgeItself(bundleID)"))
    }
}
