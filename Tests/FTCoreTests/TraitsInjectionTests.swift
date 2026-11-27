// 台の性質の注入口(FT_FAKE_UNREADABLE_TRAITS)の解釈。破ると: 陽性対照が効かない/無関係の台まで読めなくなる(全台 unreadable の暴発)。

import XCTest
@testable import FTCore

final class TraitsInjectionTests: XCTestCase {
    private let full = DeviceTraits(platform: "ios", physical: false, foldable: true, homeButton: false,
                                    osVersion: "iOS 27.2", model: "iPhone Duo")

    private func env(_ v: String) -> [String: String] { [TraitsInjection.environmentKey: v] }

    func testKeyOnlyForcesEveryTraitUnreadable() {
        let t = TraitsInjection.apply(full, key: "A", environment: env("A"))
        XCTAssertEqual(t, DeviceTraits(platform: "ios", physical: false))
    }

    func testNamedTraitsOnly() {
        let t = TraitsInjection.apply(full, key: "A", environment: env("A:foldable,model"))
        XCTAssertNil(t.foldable)
        XCTAssertNil(t.model)
        XCTAssertEqual(t.homeButton, false)
        XCTAssertEqual(t.osVersion, "iOS 27.2")
    }

    func testOtherKeysAndUnsetEnvironmentAreUntouched() {
        XCTAssertEqual(TraitsInjection.apply(full, key: "B", environment: env("A")), full)
        XCTAssertEqual(TraitsInjection.apply(full, key: "A", environment: [:]), full)
    }

    /// platform / physical は注入しても消えない(プロファイルの種別から常に分かる)
    func testPlatformAndPhysicalNeverForcedUnreadable() {
        let t = TraitsInjection.apply(full, key: "A", environment: env("A"))
        XCTAssertEqual(t.platform, "ios")
        XCTAssertFalse(t.physical)
    }

    func testMultipleEntriesAndColonInName() {
        let plan = TraitsInjection.plan(environment: env("A:model;Pixel 9(Android 16):foldable; C:x"))
        XCTAssertEqual(plan["A"], ["model"])
        XCTAssertEqual(plan["Pixel 9(Android 16)"], ["foldable"])
        // 末尾が trait 名でなければ全体がキー(名前に ':' がある台)
        XCTAssertEqual(plan["C:x"], Set(TraitsInjection.traitNames))
    }
}
