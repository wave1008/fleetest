// 対象外の回し直しの Android Emulator の種類の観測(DR-214)の純粋部。デバイス不要。
// 破ると: 実機・種類不明の台を含むエントリを覆う(誤った緑)/ 種類が割れて Emulator を毎回別の台として回し直す。

import XCTest
import FTCore
@testable import fleetest

final class AndroidDeviceKindResolverTests: XCTestCase {
    private func emu(_ name: String, avd: String?) -> DeviceSpec {
        var s = DeviceSpec(name: name)
        s.avd = avd
        return s
    }

    func testKindsAreTheSetOfTheEntrysEmulatorKinds() {
        let kinds = AndroidDeviceKindResolver.kinds(specs: [emu("a", avd: "A"), emu("b", avd: "B")], avdKinds: ["A": "k1", "B": "k1"])
        XCTAssertEqual(kinds, ["k1"])
        XCTAssertEqual(AndroidDeviceKindResolver.kinds(specs: [emu("a", avd: "A"), emu("b", avd: "B")], avdKinds: ["A": "k1", "B": "k2"]), ["k1", "k2"])
    }

    /// 1台でも読めなければ不明(部分的な知識で覆わない)・指定なし・機械ごと読めない・AVD 名なしも不明
    func testUnreadableIsUnknown() {
        XCTAssertNil(AndroidDeviceKindResolver.kinds(specs: [emu("a", avd: "A"), emu("b", avd: "B")], avdKinds: ["A": "k1"]))
        XCTAssertNil(AndroidDeviceKindResolver.kinds(specs: [], avdKinds: [:]))
        XCTAssertNil(AndroidDeviceKindResolver.kinds(specs: [emu("a", avd: "A")], avdKinds: nil))
        XCTAssertNil(AndroidDeviceKindResolver.kinds(specs: [emu("a", avd: nil)], avdKinds: ["A": "k1"]))
    }

    /// 実機を含むエントリは観測の対象外 = 空集合(不明と同じく覆わない。読みの失敗でも変わらない)
    func testPhysicalIsOutOfScope() {
        var phys = DeviceSpec(name: "real")
        phys.kind = .physical
        XCTAssertEqual(AndroidDeviceKindResolver.kinds(specs: [emu("a", avd: "A"), phys], avdKinds: ["A": "k1"]), [])
        XCTAssertEqual(AndroidDeviceKindResolver.kinds(specs: [phys], avdKinds: nil), [])
    }

    func testParseTakesTheLastJSONLine() {
        XCTAssertEqual(AndroidDeviceKindResolver.parse(stdout: "noise\n{\"A\":\"k1\"}\n"), ["A": "k1"])
        XCTAssertNil(AndroidDeviceKindResolver.parse(stdout: "no json"))
        XCTAssertEqual(AndroidDeviceKindResolver.parse(stdout: "{}\n"), [:])
    }
}
