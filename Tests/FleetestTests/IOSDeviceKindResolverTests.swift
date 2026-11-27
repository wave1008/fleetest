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
        XCTAssertEqual(kinds, ["iPhone-18-Pro|iOS-27-2"], "共通の接頭辞を外した短い形(親子のワイヤに載る)")
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

    /// 1台でも解決できなければ不明(部分的な知識で覆わない)・iOS の指定なし・出力なしも不明
    func testUnresolvableOrUnreadableIsUnknown() {
        let out = json([rt27: [("U1", "Phone", "iPhone-18-Pro")]])
        XCTAssertNil(IOSDeviceKindResolver.kinds(simctlOutput: out, specs: [spec("Phone"), spec("Missing")]))
        XCTAssertNil(IOSDeviceKindResolver.kinds(simctlOutput: out, specs: []))
        XCTAssertNil(IOSDeviceKindResolver.kinds(simctlOutput: nil, specs: [spec("Phone")]))
        XCTAssertNil(IOSDeviceKindResolver.kinds(simctlOutput: "not json", specs: [spec("Phone")]))
    }

    /// 実機を含むエントリは観測の対象外 = 空集合(覆わない点は不明と同じ。失敗ではないので配り手は「観測できなかった」と言わない)。
    /// simctl の出力が無くても同じ(実機の判定は出力を読む前)
    func testPhysicalDeviceIsOutOfScopeNotUnknown() {
        let out = json([rt27: [("U1", "Phone", "iPhone-18-Pro")]])
        XCTAssertEqual(IOSDeviceKindResolver.kinds(simctlOutput: out, specs: [spec("Phone"), spec("Real", udid: "X", physical: true)]), [])
        XCTAssertEqual(IOSDeviceKindResolver.kinds(simctlOutput: nil, specs: [spec("Real", udid: "X", physical: true)]), [])
    }
}
