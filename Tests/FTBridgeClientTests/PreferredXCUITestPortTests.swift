// 回復(SpringBoard の起こし直し)で XCUITest ブリッジを元のポートへ戻す口(`preferredXCUITestPorts`)の固定。
// 緑の run では回復が起きないので、計画の単体と配線のソース走査で持つ。

import XCTest
import FTCore
@testable import FTBridgeClient

final class PreferredXCUITestPortTests: XCTestCase {
    private var repoRoot: URL!

    override func setUpWithError() throws {
        repoRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("ftpreferredxcui-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: repoRoot.appendingPathComponent(".fleetest"), withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: repoRoot)
    }

    private func launchPort(preferred: UInt16?) throws -> UInt16 {
        let sim = SimDeviceInfo(udid: "UDID-A", name: "iPhone 17 Pro", os: "iOS 27.0", booted: true)
        let provisioner = BridgeProvisioner(repoRoot: repoRoot, portRange: 8123...8130,
                                            portHeldByAnotherDevice: { _, _ in false })
        var claimed: Set<UInt16> = []
        var used: Set<UInt16> = []
        let plan = try provisioner.planBridge(
            bridge: "xcuitest", preferred: preferred, name: sim.name, sim: sim, bundleID: nil,
            appIsCurrent: [:], preinstallAppPath: nil, running: [:], starting: [:],
            claimed: &claimed, usedPorts: &used)
        guard case .launch(let port, _, _, _) = plan else {
            XCTFail("expected a launch plan, got \(plan)")
            return 0
        }
        return port
    }

    /// 空いていれば希望のポート・渡さなければ空きの一番若いポート(今まで通り)
    func testPreferredPortIsHonoredWhenFreeAndOtherwiseTheYoungestFreePort() throws {
        XCTAssertEqual(try launchPort(preferred: 8126), 8126)
        XCTAssertEqual(try launchPort(preferred: nil), 8123)
    }

    /// 止めた直後に pid ファイルが残っていれば honor されない(stopRunnersMatching が消すことに依存する)
    func testPreferredPortWithAPidFileIsNotHonored() throws {
        try "12345".write(to: repoRoot.appendingPathComponent(".fleetest/bridge-8126.pid"),
                          atomically: true, encoding: .utf8)
        XCTAssertNotEqual(try launchPort(preferred: 8126), 8126)
    }

    private func source(_ path: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return try String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)
    }

    /// 回復は元の XCUITest ブリッジのポートを希望として渡す(渡し忘れると inapp-boost モードは別のポートで戻って回復を諦める)
    func testRespringAndRebuildPassesTheOriginalXCUITestPort() throws {
        let text = try source("Sources/FTAndroid/ProfileWorkerFactory.swift")
        let start = try XCTUnwrap(text.range(of: "static func respringAndRebuild("))
        let body = String(text[start.lowerBound...].prefix(4000))
        XCTAssertTrue(body.contains("let expectedPort = worker.connection.xcuiPort ?? worker.connection.port"))
        XCTAssertTrue(body.contains("preferredXCUITestPorts: expectedPort.map { [device.name: $0] } ?? [:]"))
    }

    /// 希望があるとき XCUITest を in-app より先に採番する(in-app が先だと、止めた直後で空いている希望ポートを自動採番で採る)
    func testProvisionPlansXCUITestBeforeInAppWhenAPortIsPreferred() throws {
        let text = try source("Sources/FTBridgeClient/BridgeProvisioner.swift")
        let gate = try XCTUnwrap(text.range(of: "if preferredXCUITestPorts[target.name] != nil {"))
        let rest = String(text[gate.upperBound...].prefix(400))
        let xcui = try XCTUnwrap(rest.range(of: "planXCUITest()"))
        let inApp = try XCTUnwrap(rest.range(of: "planInApp()"))
        XCTAssertLessThan(xcui.lowerBound, inApp.lowerBound)
        XCTAssertEqual(text.components(separatedBy: "preferred: preferredXCUITestPorts[target.name]").count - 1, 2,
                       "the inapp-boost XCUITest bridge and the xcuitest-mode bridge both take the preferred port")
    }
}
