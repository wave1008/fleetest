// iOS 実機の台の性質(devicectl の一覧だけから)。破ると: 読めない性質が値に化ける(`"iOS"` だけ・空の機種名)/
// ホームボタン機を Face ID と読む/未知の機種を決め付ける(@RequiresDevice の誤った通過・誤った対象外)。

import FTCore
import XCTest
@testable import FTBridgeClient

final class IOSPhysicalDeviceTraitsTests: XCTestCase {
    /// 実機(iPhone SE3)の devicectl の entry と同じキー(`properties` の形)
    private func entry(productType: String? = "iPhone14,6", marketingName: String? = "iPhone SE (3rd generation)",
                       osVersion: String? = "26.6.2") -> [String: Any] {
        var hardware: [String: Any] = ["platform": "iOS", "udid": "00008110-000260242EEB801E"]
        if let productType { hardware["productType"] = productType }
        if let marketingName { hardware["marketingName"] = marketingName }
        var props: [String: Any] = ["hardware": hardware, "state": ["name": "iPhone SE3"],
                                    "connection": ["state": "connected", "transportType": "wired"]]
        if let osVersion { props["software"] = ["osVersionNumber": ["stringValue": osVersion]] }
        return ["identifier": "370D80E6-B702-535B-9C1B-19BC301DA726", "properties": props]
    }

    private func traits(_ e: [String: Any]) throws -> DeviceTraits {
        IOSPhysicalDeviceTraits.traits(of: try XCTUnwrap(IOSPhysicalDeviceCatalog.parse(e)))
    }

    func testSE3Traits() throws {
        XCTAssertEqual(try traits(entry()),
                       DeviceTraits(platform: "ios", physical: true, foldable: false, homeButton: true,
                                    osVersion: "iOS 26.6.2", model: "iPhone SE (3rd generation)"))
    }

    func testMissingOsVersionAndMarketingNameAreNilNotFallbacks() throws {
        let t = try traits(entry(marketingName: nil, osVersion: nil))
        XCTAssertNil(t.osVersion, "表示用の `iOS` だけを値にしない")
        XCTAssertNil(t.model, "表示用の空文字を値にしない")
        XCTAssertEqual(t.homeButton, true)
        // 表示側(`os` / `model`)の穴埋めは従来のまま
        let device = try XCTUnwrap(IOSPhysicalDeviceCatalog.parse(entry(marketingName: nil, osVersion: nil)))
        XCTAssertEqual(device.os, "iOS")
        XCTAssertEqual(device.model, "")
    }

    func testEmptyStringsAreNil() throws {
        let t = try traits(entry(productType: "", marketingName: "", osVersion: ""))
        XCTAssertNil(t.homeButton)
        XCTAssertNil(t.model)
        XCTAssertNil(t.osVersion)
    }

    func testHomeButtonTable() {
        for home in ["iPhone8,1", "iPhone8,2", "iPhone8,4", "iPhone9,1", "iPhone9,2", "iPhone9,3", "iPhone9,4",
                     "iPhone10,1", "iPhone10,2", "iPhone10,4", "iPhone10,5", "iPhone12,8", "iPhone14,6"] {
            XCTAssertEqual(IOSPhysicalDeviceTraits.homeButton(productType: home), true, home)
        }
        for faceID in ["iPhone10,3", "iPhone10,6", "iPhone11,2", "iPhone14,5", "iPhone16,1", "iPhone19,4"] {
            XCTAssertEqual(IOSPhysicalDeviceTraits.homeButton(productType: faceID), false, faceID)
        }
        XCTAssertEqual(IOSPhysicalDeviceTraits.homeButton(productType: "iPad14,3"), false)
    }

    /// 未知の productType(iPhone / iPad 以外・表に無い古い世代)と productType 無しは nil(決め付けない)
    func testUnknownProductTypeIsNil() {
        XCTAssertNil(IOSPhysicalDeviceTraits.homeButton(productType: nil))
        XCTAssertNil(IOSPhysicalDeviceTraits.homeButton(productType: "Watch7,1"))
        XCTAssertNil(IOSPhysicalDeviceTraits.homeButton(productType: "iPhone7,2"))
        XCTAssertNil(IOSPhysicalDeviceTraits.homeButton(productType: "iPhoneX"))
        XCTAssertNil(IOSPhysicalDeviceTraits.homeButton(productType: "Unknown1,1"))
    }

    func testOsVersionNormalisation() {
        XCTAssertEqual(IOSPhysicalDeviceTraits.osVersion(osVersionNumber: "27.2.1"), "iOS 27.2.1")
        XCTAssertNil(IOSPhysicalDeviceTraits.osVersion(osVersionNumber: nil))
        XCTAssertNil(IOSPhysicalDeviceTraits.osVersion(osVersionNumber: "iOS"))
        XCTAssertNil(IOSPhysicalDeviceTraits.osVersion(osVersionNumber: ""))
    }

    func testNotListedDeviceKeepsOnlyKind() {
        XCTAssertEqual(IOSPhysicalDeviceTraits.unreadable, DeviceTraits(platform: "ios", physical: true))
    }
}
