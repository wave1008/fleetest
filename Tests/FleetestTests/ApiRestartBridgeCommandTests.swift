// `fleetest api restart-bridge`: 純粋に切り出せる部分だけを固定する(Android を断ること・
// 断りの文言・--udid からの spec 合成)。デバイスを触る部分(UDID 解決・BridgeLauncher.stopMatching・BridgeProvisioner)は
// デバイスが要るため対象外。

import FTBridgeClient
import FTCore
import XCTest

@testable import fleetest

final class ApiRestartBridgeCommandTests: XCTestCase {

    func testAndroidIsRejected() {
        XCTAssertThrowsError(try ApiRestartBridgeCommand.requireIOS(platform: "android")) { error in
            XCTAssertEqual(error as? RestartBridgeError, .androidNotSupported)
        }
    }

    func testIOSPassesValidation() {
        XCTAssertNoThrow(try ApiRestartBridgeCommand.requireIOS(platform: "ios"))
    }

    func testAndroidNotSupportedMessageMentionsTheAlternative() {
        let message = RestartBridgeError.androidNotSupported.errorDescription ?? ""
        XCTAssertTrue(message.contains("iOS only"), message)
        XCTAssertTrue(message.contains("bridge down"), message)
    }

    func testInUseMessagePassesThroughVerbatim() {
        XCTAssertEqual(RestartBridgeError.inUse("refusing to stop: X is in use").errorDescription,
                       "refusing to stop: X is in use")
    }

    // MARK: - --udid(名前が選択中のプロジェクトの台帳に無いデバイス)

    private static let se3 = IOSPhysicalDeviceInfo(
        udid: "00008110-000260242EEB801E", name: "iPhone SE3", os: "26.6", connected: true,
        transport: "wired", deviceCtlIdentifier: "D1E2F3A4-0000-0000-0000-000000000001")
    private static let sim = SimDeviceInfo(udid: "2A7FBD43-4A72-44DA-AB95-EED23B1B3B6D",
                                           name: "iPhone 18 Pro", os: "iOS 27.2", booted: true, physical: false)

    func testDirectSpecForAConnectedPhysicalDeviceIsPhysicalXCUITest() throws {
        let spec = try ApiRestartBridgeCommand.directSpec(
            udid: Self.se3.udid, physicalDevices: [Self.se3], simulators: [Self.sim])
        XCTAssertEqual(spec.name, "iPhone SE3")
        XCTAssertEqual(spec.udid, Self.se3.udid)
        XCTAssertTrue(spec.isPhysical)
        XCTAssertEqual(spec.mode, IOSMode.xcuitest)
        XCTAssertNil(spec.port)
    }

    /// devicectl の Identifier(別の UUID)で渡されても同じ端末に当たり、spec は本来の UDID を持つ
    func testDirectSpecMatchesThePhysicalDeviceByDevicectlIdentifier() throws {
        let spec = try ApiRestartBridgeCommand.directSpec(
            udid: Self.se3.deviceCtlIdentifier, physicalDevices: [Self.se3], simulators: [])
        XCTAssertEqual(spec.udid, Self.se3.udid)
        XCTAssertTrue(spec.isPhysical)
    }

    func testDirectSpecForASimulatorIsVirtual() throws {
        let spec = try ApiRestartBridgeCommand.directSpec(
            udid: Self.sim.udid, physicalDevices: [Self.se3], simulators: [Self.sim])
        XCTAssertEqual(spec.name, "iPhone 18 Pro")
        XCTAssertEqual(spec.udid, Self.sim.udid)
        XCTAssertFalse(spec.isPhysical)
        XCTAssertEqual(spec.mode, IOSMode.xcuitest)
    }

    func testDirectSpecRefusesAnUnknownUDID() {
        XCTAssertThrowsError(try ApiRestartBridgeCommand.directSpec(
            udid: "NOPE", physicalDevices: [Self.se3], simulators: [Self.sim])) { error in
            XCTAssertEqual(error as? RestartBridgeError, .udidNotFound("NOPE"))
            XCTAssertEqual((error as? RestartBridgeError)?.errorDescription,
                           "no physical device or simulator with UDID NOPE on this Mac")
        }
    }

    func testNoUDIDMessageNamesTheDevice() {
        XCTAssertEqual(RestartBridgeError.noUDID("iPhone 17").errorDescription,
                       "could not resolve a UDID for iPhone 17")
    }
}
