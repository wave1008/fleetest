// 設定タブ「実機をテストで使用する」OFF で実行から実機を外す規則(PhysicalDeviceUse)。
// resolve はマシン設定を読むので、ここでは読んだ後の純粋な変換と文言だけを固定する。

import FTCore
import XCTest

final class PhysicalDeviceUseTests: XCTestCase {
    private func doc() -> RunProfileDocument {
        var document = RunProfileDocument()
        document.devices = [
            RunDeviceEntry(platform: "ios", spec: DeviceSpec(name: "sim", kind: .virtual)),
            RunDeviceEntry(platform: "ios", spec: DeviceSpec(name: "phone", kind: .physical, udid: "U1")),
            RunDeviceEntry(platform: "android", spec: DeviceSpec(name: "pixel", kind: .physical, serial: "S1"),
                           enabled: false),
        ]
        return document
    }

    func testOffDisablesPhysicalDevicesAndReportsOnlyThoseThatWereEnabled() {
        let (result, excluded) = PhysicalDeviceUse.applying(to: doc(), off: true)
        XCTAssertEqual(result.devices?.map(\.isEnabled), [true, false, false])
        XCTAssertEqual(excluded, ["phone"], "元から無効の実機は「外した」に数えない")
    }

    func testOnLeavesTheProfileAsIs() {
        let (result, excluded) = PhysicalDeviceUse.applying(to: doc(), off: false)
        XCTAssertEqual(result, doc())
        XCTAssertTrue(excluded.isEmpty)
    }

    func testJSONFormDisablesPhysicalDevicesAndKeepsUnknownKeys() {
        let object: [String: Any] = [
            "app": "a", "custom": 1,
            "devices": [["platform": "ios", "name": "sim"],
                        ["platform": "ios", "name": "phone", "kind": "physical", "udid": "U1"]],
        ]
        let result = PhysicalDeviceUse.applying(toJSON: object, off: true)
        let devices = result["devices"] as? [[String: Any]]
        XCTAssertNil(devices?[0]["enabled"])
        XCTAssertEqual(devices?[1]["enabled"] as? Bool, false)
        XCTAssertEqual(result["custom"] as? Int, 1)
        XCTAssertNil((PhysicalDeviceUse.applying(toJSON: object, off: false)["devices"] as? [[String: Any]])?[1]["enabled"])
    }

    func testIsOffOnlyWhenExplicitlyFalse() {
        XCTAssertFalse(PhysicalDeviceUse.isOff(config: LocalConfig()))
        XCTAssertFalse(PhysicalDeviceUse.isOff(config: LocalConfig(usePhysicalDevices: true)))
        XCTAssertTrue(PhysicalDeviceUse.isOff(config: LocalConfig(usePhysicalDevices: false)))
    }

    func testAllPhysicalErrorNamesTheSetting() {
        let message = ProfileError.physicalDevicesNotUsed(run: "ios-device", devices: ["phone"]).errorDescription ?? ""
        XCTAssertTrue(message.contains("Use physical devices for tests"), message)
        XCTAssertTrue(message.contains("phone"), message)
    }
}
