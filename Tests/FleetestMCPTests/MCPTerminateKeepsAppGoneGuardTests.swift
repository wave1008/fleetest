// 34周目 alocal F3: Android で ft_terminate がセッションのアプリを止めた後、前面に出た同じ #id の別のアプリへ ft_batch が撃って ok だった
// (ft_terminate が起動の記憶を消す → `wireAppGoneGuard` が門を付けない)。止めた後も記憶を残して止めた印を立て、門を通す。
// Android の止め方は本物の AndroidDriver(adb)を通るので、判定(`terminateKeepsLaunchRecord`)と、それが残す状態での門を分けて見る。
// デバイスでの形は Scripts/replay-cases/r-oi192-terminate-sibling.json

import XCTest
@testable import FTCore
@testable import fleetest_mcp

final class MCPTerminateKeepsAppGoneGuardTests: XCTestCase {
    private let android: [String: Any] = ["platform": "android"]

    func testAndroidTerminateOfTheSessionAppKeepsTheLaunchRecord() {
        XCTAssertTrue(MCPServer.terminateKeepsLaunchRecord(stopsByName: true, launched: "com.example.app",
                                                           terminated: "com.example.app"))
        XCTAssertFalse(MCPServer.terminateKeepsLaunchRecord(stopsByName: true, launched: "com.example.app",
                                                            terminated: "com.example.other"),
                       "別のアプリを名指しで止めたのに、セッションのアプリを止めた扱いにした")
        XCTAssertFalse(MCPServer.terminateKeepsLaunchRecord(stopsByName: true, launched: nil, terminated: "com.example.app"),
                       "起動していないアプリを起動の記憶に入れた")
        XCTAssertFalse(MCPServer.terminateKeepsLaunchRecord(stopsByName: false, launched: "com.example.app",
                                                            terminated: "com.example.app"),
                       "iOS の記憶の扱いを変えた")
    }

    /// ft_terminate が残す状態(起動の記憶 + 止めた印)で、別のアプリの木への batch の tap を撃たずに断る
    func testBatchAfterTerminateIsRefusedOnASiblingAppsTree() async throws {
        let driver = FakeDriver()
        driver.answers = .android
        driver.foregroundBundleID = "com.example.sibling"
        driver.snapshotResponse = SnapshotResponse(
            sessionBundleID: "com.example.sibling", screen: FTRect(x: 0, y: 0, width: 1280, height: 2856),
            elements: [ElementInfo(ref: 1, type: "button", identifier: "btn_send", label: "送信", value: nil, placeholder: nil,
                                   enabled: true, frame: FTRect(x: 1000, y: 2600, width: 200, height: 150), depth: 1)],
            truncatedCount: 0)
        let server = MCPServer(write: { _ in }, makeDriver: { _ in driver }, recordSnapshot: { _, _, _ in })
        let key = MCPServer.sessionKey(android)
        server.bridges[key] = "android"
        server.androidPackageRunning = { _, _ in false }
        server.launchedBundleIDs[key] = "com.example.app"
        server.toolStoppedBundleIDs[key] = "ft_terminate"
        do {
            _ = try await server.call(tool: "ft_batch", args: android.merging(["steps": "tap '#btn_send'"]) { $1 })
            XCTFail("止めたアプリの代わりに別のアプリへ撃った: \(driver.calls)")
        } catch {
            let message = error.localizedDescription
            XCTAssertTrue(message.contains("com.example.app) is not running"), message)
            XCTAssertTrue(message.contains("ft_terminate stopped it"), message)
        }
        XCTAssertFalse(driver.calls.contains { $0.hasPrefix("tap(") }, "\(driver.calls)")
    }
}
