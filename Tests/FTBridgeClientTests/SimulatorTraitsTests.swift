// iOS Simulator の台の解決と性質(折りたたみ・ホームボタン・OS・機種名)。実機の simctl / capabilities.plist の形を写した fixture。
// 破ると: 折りたたみ機を取りこぼす/iPhone Duo の OS が化ける/ホームボタン機を Face ID と読む(@RequiresDevice が誤って外す・通す)。

import FTCore
import XCTest
@testable import FTBridgeClient

final class SimulatorTraitsTests: XCTestCase {
    private let duoRuntime = "com.apple.CoreSimulator.SimRuntime.iOS-27-2-iPhone19-4"
    private let ios27 = "com.apple.CoreSimulator.SimRuntime.iOS-27-2"
    private let typePrefix = "com.apple.CoreSimulator.SimDeviceType."

    /// `simctl list -j devicetypes devices` の抜粋(実機の出力と同じキー)
    private func simctlJSON() -> [String: Any] {
        func type(_ id: String, _ name: String, _ family: String) -> [String: Any] {
            ["identifier": typePrefix + id, "name": name, "productFamily": family,
             "bundlePath": "/nonexistent/\(id).simdevicetype"]
        }
        func dev(_ udid: String, _ name: String, _ typeID: String, _ state: String = "Shutdown") -> [String: Any] {
            ["udid": udid, "name": name, "state": state, "isAvailable": true,
             "deviceTypeIdentifier": typePrefix + typeID]
        }
        return [
            "devicetypes": [type("iPhone-Duo", "iPhone Duo", "iPhone"),
                            type("iPhone-SE-3rd-generation", "iPhone SE (3rd generation)", "iPhone"),
                            type("iPhone-17", "iPhone 17", "iPhone"),
                            type("iPad-Pro-13-inch-M5-12GB", "iPad Pro 13-inch (M5)", "iPad")],
            "devices": [
                duoRuntime: [dev("DUO", "iPhone Duo", "iPhone-Duo")],
                ios27: [dev("SE3", "iPhone SE3", "iPhone-SE-3rd-generation"), dev("P17", "iPhone 17", "iPhone-17"),
                        dev("PAD", "iPad Pro", "iPad-Pro-13-inch-M5-12GB")],
            ],
        ]
    }

    private typealias Display = (w: Int, h: Int, scale: Int, type: String)

    private func caps(_ displays: [Display]) -> Data {
        let list = displays.map { ["displayType": $0.type, "width": $0.w, "height": $0.h, "scale": $0.scale] as [String: Any] }
        return try! PropertyListSerialization.data(fromPropertyList: ["capabilities": ["displays": list]], format: .xml, options: 0)
    }

    private let se3Caps: [Display] = [(750, 1334, 2, "integrated"), (720, 480, 1, "tvOut")]
    private let p17Caps: [Display] = [(1206, 2622, 3, "integrated")]
    private let duoCaps: [Display] = [(1398, 2034, 3, "integrated"), (2007, 2853, 3, "integrated"), (720, 480, 1, "tvOut")]
    private let padCaps: [Display] = [(2064, 2752, 2, "integrated")]

    private func resolve(_ name: String) throws -> SimulatorCatalog.ResolvedSimulator {
        let json = simctlJSON()
        let devices = try XCTUnwrap(SimulatorCatalog.devices(simctlJSON: json))
        return try XCTUnwrap(SimulatorCatalog.resolveSimulators(specs: [DeviceSpec(name: name)], devices: devices, simctlJSON: json)[0])
    }

    /// iPhone Duo(runtime `iOS-27-2-iPhone19-4`)は OS が `iOS 27.2` で折りたたみ機・ホームボタン無し
    func testDuoIsFoldableWithCleanOS() throws {
        let t = SimulatorCatalog.traits(of: try resolve("iPhone Duo"), capabilitiesPlist: caps(duoCaps))
        XCTAssertEqual(t, DeviceTraits(platform: "ios", physical: false, foldable: true, homeButton: false,
                                       osVersion: "iOS 27.2", model: "iPhone Duo"))
    }

    func testSE3HasHomeButtonThroughRuntimeScreenTable() throws {
        let t = SimulatorCatalog.traits(of: try resolve("iPhone SE3"), capabilitiesPlist: caps(se3Caps))
        XCTAssertEqual(t.homeButton, true, "750x1334 @2x = 375x667pt = 実行時の isHomeButtonPhoneScreen の表")
        XCTAssertEqual(t.foldable, false)
        XCTAssertEqual(t.model, "iPhone SE (3rd generation)")
    }

    func testFaceIDPhoneAndIPad() throws {
        let p = SimulatorCatalog.traits(of: try resolve("iPhone 17"), capabilitiesPlist: caps(p17Caps))
        XCTAssertEqual(p.homeButton, false)
        XCTAssertEqual(p.foldable, false)
        let pad = SimulatorCatalog.traits(of: try resolve("iPad Pro"), capabilitiesPlist: caps(padCaps))
        XCTAssertEqual(pad.homeButton, false, "iPad は false(確定値。nil にしない)")
    }

    /// capabilities.plist が読めなければ foldable / homeButton は nil(OS・機種は simctl から読める)。iPad の homeButton は plist 不要で false
    func testUnreadableCapabilitiesGivesNilTraitsOnly() throws {
        let t = SimulatorCatalog.traits(of: try resolve("iPhone Duo"), capabilitiesPlist: nil)
        XCTAssertNil(t.foldable)
        XCTAssertNil(t.homeButton)
        XCTAssertEqual(t.osVersion, "iOS 27.2")
        XCTAssertEqual(t.model, "iPhone Duo")
        XCTAssertEqual(SimulatorCatalog.traits(of: try resolve("iPad Pro"), capabilitiesPlist: nil).homeButton, false)
        XCTAssertNil(SimulatorCatalog.traits(of: try resolve("iPhone 17"), capabilitiesPlist: Data("x".utf8)).homeButton)
    }

    func testResolveIsIndexAlignedAndNilForUnresolvedOrPhysical() throws {
        let json = simctlJSON()
        let devices = try XCTUnwrap(SimulatorCatalog.devices(simctlJSON: json))
        var physical = DeviceSpec(name: "iPhone 17")
        physical.kind = .physical
        let out = SimulatorCatalog.resolveSimulators(
            specs: [DeviceSpec(name: "iPhone 17"), DeviceSpec(name: "Missing"), physical], devices: devices, simctlJSON: json)
        XCTAssertEqual(out.map { $0?.udid }, ["P17", nil, nil])
    }
}
