// LaunchPreflightDriver.wrapping: preflight は simctl 依存なので、実機・udid 不明では包まない。
// inapp-boost の別アプリ分岐と xcuitest の主経路が同じ関数を通る(片方だけ実機で外し忘れる型の再発止め)。
import XCTest
@testable import FTBridgeClient
import FTCore

final class LaunchPreflightWrappingTests: XCTestCase {
    func testSimulatorWithUDIDIsWrapped() {
        let client = BridgeClient(port: 59990)
        XCTAssertTrue(LaunchPreflightDriver.wrapping(client, udid: "SIM-UDID", physical: false) is LaunchPreflightDriver)
    }

    func testPhysicalDeviceIsNotWrapped() {
        let client = BridgeClient(port: 59990)
        XCTAssertTrue((LaunchPreflightDriver.wrapping(client, udid: "PHYS-UDID", physical: true) as AnyObject) === client)
    }

    func testUnknownUDIDIsNotWrapped() {
        let client = BridgeClient(port: 59990)
        XCTAssertTrue((LaunchPreflightDriver.wrapping(client, udid: nil, physical: false) as AnyObject) === client)
    }
}
