// 対象外の回し直しの種類の観測(DR-214)。simctl の出力から台の種類を引く純粋部。デバイス不要。
// 破ると: 種類が違う台を同じと読んで折りたたみ機を取りこぼす(誤った緑)/ 解決できない台があるのに覆う。

import XCTest
import FTCore
@testable import fleetest

final class IOSDeviceKindResolverTests: XCTestCase {
    private func json(_ runtimes: [String: [(udid: String, name: String, type: String)]]) -> String {
        let devices = runtimes.mapValues { list in
            list.map { ["udid": $0.udid, "name": $0.name, "state": "Shutdown", "isAvailable": true,
                        "deviceTypeIdentifier": "com.apple.CoreSimulator.SimDeviceType." + $0.type] as [String: Any] }
        }
        let data = try! JSONSerialization.data(withJSONObject: ["devices": devices])
        return String(data: data, encoding: .utf8)!
    }

    private let rt27 = "com.apple.CoreSimulator.SimRuntime.iOS-27-2"

    private func spec(_ name: String, udid: String? = nil, physical: Bool = false) -> DeviceSpec {
        var s = DeviceSpec(name: name)
        s.udid = udid
        if physical { s.kind = .physical }
        return s
    }

    func testKindIsObservedDeviceTypeAndRuntime() {
        let out = json([rt27: [("U1", "iPhone 18 Pro-01", "iPhone-18-Pro"), ("U2", "iPhone 18 Pro-02", "iPhone-18-Pro")]])
        let kinds = IOSDeviceKindResolver.kinds(simctlOutput: out, specs: [spec("iPhone 18 Pro-01"), spec("iPhone 18 Pro-02")])
        XCTAssertEqual(kinds, ["com.apple.CoreSimulator.SimDeviceType.iPhone-18-Pro|" + rt27])
    }

    /// 名前が同じでも機種が違えば別の種類(名前・プロファイルの表示用の機種名は使わない)
    func testSameNameDifferentTypeIsDifferentKind() {
        let a = json([rt27: [("U1", "Phone", "iPhone-18-Pro")]])
        let b = json([rt27: [("U1", "Phone", "iPhone-Fold")]])
        XCTAssertNotEqual(IOSDeviceKindResolver.kinds(simctlOutput: a, specs: [spec("Phone")]),
                          IOSDeviceKindResolver.kinds(simctlOutput: b, specs: [spec("Phone")]))
    }

    func testDifferentRuntimeIsDifferentKind() {
        let a = json([rt27: [("U1", "Phone", "iPhone-18-Pro")]])
        let b = json(["com.apple.CoreSimulator.SimRuntime.iOS-27-3": [("U1", "Phone", "iPhone-18-Pro")]])
        XCTAssertNotEqual(IOSDeviceKindResolver.kinds(simctlOutput: a, specs: [spec("Phone")]),
                          IOSDeviceKindResolver.kinds(simctlOutput: b, specs: [spec("Phone")]))
    }

    /// 1台でも解決できなければ不明(部分的な知識で覆わない)・実機・iOS の指定なし・出力なしも不明
    func testUnresolvableOrUnreadableIsUnknown() {
        let out = json([rt27: [("U1", "Phone", "iPhone-18-Pro")]])
        XCTAssertNil(IOSDeviceKindResolver.kinds(simctlOutput: out, specs: [spec("Phone"), spec("Missing")]))
        XCTAssertNil(IOSDeviceKindResolver.kinds(simctlOutput: out, specs: [spec("Phone"), spec("Real", udid: "X", physical: true)]))
        XCTAssertNil(IOSDeviceKindResolver.kinds(simctlOutput: out, specs: []))
        XCTAssertNil(IOSDeviceKindResolver.kinds(simctlOutput: nil, specs: [spec("Phone")]))
        XCTAssertNil(IOSDeviceKindResolver.kinds(simctlOutput: "not json", specs: [spec("Phone")]))
    }
}
