// 台帳の親(xcodebuild)が居ない実機のランナーは、/status に答えても再利用しない(止めて起動し直す)。

import XCTest
import FTCore
@testable import FTBridgeClient

final class PlanBridgeOwnerlessRunnerTests: XCTestCase {
    private func plan(sim: SimDeviceInfo, ownerGone: Bool) throws -> BridgeProvisioner.BridgePlan {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ftownerless-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root.appendingPathComponent(".fleetest"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let provisioner = BridgeProvisioner(repoRoot: root, portRange: 8123...8130, portHeldByAnotherDevice: { _, _ in false })
        var claimed: Set<UInt16> = []
        let running: [UInt16: BridgeProvisioner.RunningBridge] = [
            8123: .init(udid: sim.udid, name: sim.name, bridge: "xcuitest",
                        protocolVersion: BridgeAPI.bridgeProtocolVersion, sessionBundleID: nil, ownerGone: ownerGone)]
        var used = Set(running.keys)
        return try provisioner.planBridge(
            bridge: "xcuitest", preferred: nil, name: sim.name, sim: sim, bundleID: nil,
            appIsCurrent: [:], preinstallAppPath: nil, running: running, claimed: &claimed, usedPorts: &used)
    }

    func testPhysicalRunnerWithoutItsOwnerIsRestartedInPlace() throws {
        let phone = SimDeviceInfo(udid: "00008130-0018", name: "iPhone", os: "iOS 26.6", booted: true, physical: true)
        guard case .launch(let port, _, let stale, _) = try plan(sim: phone, ownerGone: true) else {
            return XCTFail("親の居ない実機のランナーは再利用してはいけない")
        }
        XCTAssertEqual(stale, 8123)
        XCTAssertEqual(port, 8123)
    }

    func testPhysicalRunnerWithItsOwnerIsReused() throws {
        let phone = SimDeviceInfo(udid: "00008130-0018", name: "iPhone", os: "iOS 26.6", booted: true, physical: true)
        guard case .reuse(let port) = try plan(sim: phone, ownerGone: false) else { return XCTFail("親が居れば再利用") }
        XCTAssertEqual(port, 8123)
    }

    func testSimulatorRunnerIsNotJudgedByOwner() throws {
        let sim = SimDeviceInfo(udid: "SIM-1", name: "iPhone 17 Pro", os: "iOS 27.0", booted: true)
        guard case .reuse = try plan(sim: sim, ownerGone: true) else { return XCTFail("Simulator は対象外") }
    }
}
