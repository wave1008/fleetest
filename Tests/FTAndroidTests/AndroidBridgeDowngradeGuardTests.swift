// installBridgeIfNeeded が adb install を試みる前の fail-fast 判定(AndroidDriver.downgradeRefusal)。
// Android は versionCode の引き下げインストールを拒否するため、より新しいブリッジが載ったデバイスに
// 古い fleetest が古い APK を当てると INSTALL_FAILED_VERSION_DOWNGRADE か無応答になる
// (2026-08-14 にフリート8台が全滅した実害。RR-18.5)。

import XCTest
@testable import FTAndroid

final class AndroidBridgeDowngradeGuardTests: XCTestCase {

    func testInstalledNewerThanExpectedReturnsRefusalWithBothVersionsAndPackageAndAdvice() {
        let text = AndroidDriver.downgradeRefusal(installed: 62, expected: 61)
        guard let text else { return XCTFail("installed > expected で nil が返った") }
        XCTAssertTrue(text.contains("62"), text)
        XCTAssertTrue(text.contains("61"), text)
        XCTAssertTrue(text.contains(AndroidDriver.bridgePackage), text)
        XCTAssertTrue(text.contains("uninstall"), text)
        XCTAssertTrue(text.contains("update"), text)
    }

    /// 最新リリースの利用者には「fleetest を更新」が効かないので、必ず効く「端末から消す」を先に置く
    func testRemovingTheBridgeIsOfferedBeforeUpdatingFleetest() throws {
        let text = try XCTUnwrap(AndroidDriver.downgradeRefusal(installed: 62, expected: 61, serial: "emulator-5554"))
        let remove = try XCTUnwrap(text.range(of: "(1) removing the newer bridge"), text)
        let update = try XCTUnwrap(text.range(of: "(2) if a newer fleetest release exists"), text)
        XCTAssertLessThan(remove.lowerBound, update.lowerBound, text)
        XCTAssertTrue(text.contains("reinstalled automatically"), text)
    }

    func testAddendumIsAppendedOnlyWhenGiven() throws {
        let plain = try XCTUnwrap(AndroidDriver.downgradeRefusal(installed: 62, expected: 61))
        let with = try XCTUnwrap(AndroidDriver.downgradeRefusal(installed: 62, expected: 61, addendum: "ADDENDUM-X"))
        XCTAssertFalse(plain.contains("ADDENDUM-X"), plain)
        XCTAssertTrue(with.hasSuffix("ADDENDUM-X"), with)
    }

    // MARK: - installDecision(adb 無しで判定を固定する)

    func testDecisionNewerInstalledIsUsedAsIsOnlyWhenAccepted() {
        XCTAssertEqual(AndroidDriver.installDecision(installed: 62, expected: 61, acceptsNewer: true), .useAsIs)
        guard case .refuse(let text) = AndroidDriver.installDecision(installed: 62, expected: 61, acceptsNewer: false,
                                                                      serial: "s", addendum: "ADD") else {
            return XCTFail("許可が無いのに新しいブリッジを拒否しなかった")
        }
        XCTAssertTrue(text.contains("v62"), text)
        XCTAssertTrue(text.hasSuffix("ADD"), text)
    }

    func testDecisionOlderOrMissingInstallsRegardlessOfPermission() {
        for accepts in [false, true] {
            XCTAssertEqual(AndroidDriver.installDecision(installed: 60, expected: 61, acceptsNewer: accepts), .install)
            XCTAssertEqual(AndroidDriver.installDecision(installed: nil, expected: 61, acceptsNewer: accepts), .install)
        }
    }

    func testDecisionEqualIsUsedAsIs() {
        XCTAssertEqual(AndroidDriver.installDecision(installed: 61, expected: 61, acceptsNewer: false), .useAsIs)
    }

    /// 許可は呼び手の明示だけ: 既定の init は false(DSL・CLI は拒否のまま)
    func testNewerBridgeIsNotAcceptedByDefault() {
        XCTAssertFalse(AndroidDriver(serial: "s", adbPath: "/usr/bin/true").acceptsNewerInstalledBridge)
        XCTAssertFalse(AndroidDriver(serial: "s", adbPath: "/usr/bin/true").isAcceptableRunningVersion(
            AndroidDriver.expectedBridgeVersionCode + 1))
        XCTAssertTrue(AndroidDriver(serial: "s", adbPath: "/usr/bin/true").isAcceptableRunningVersion(
            AndroidDriver.expectedBridgeVersionCode))
    }

    func testInstalledEqualToExpectedReturnsNil() {
        XCTAssertNil(AndroidDriver.downgradeRefusal(installed: 61, expected: 61))
    }

    func testInstalledOlderThanExpectedReturnsNilSoTheNormalUpgradePathStaysOpen() {
        XCTAssertNil(AndroidDriver.downgradeRefusal(installed: 60, expected: 61))
    }

    func testNotInstalledReturnsNilSoTheNormalInstallPathStaysOpen() {
        XCTAssertNil(AndroidDriver.downgradeRefusal(installed: nil, expected: 61))
    }

    func testUninstallCommandIncludesSerialWhenGiven() {
        let text = AndroidDriver.downgradeRefusal(installed: 62, expected: 61, serial: "emulator-5554")
        guard let text else { return XCTFail("installed > expected で nil が返った") }
        XCTAssertTrue(text.contains("adb -s emulator-5554 uninstall \(AndroidDriver.bridgePackage)"), text)
    }

    func testUninstallCommandOmitsSerialFlagWhenNil() {
        let text = AndroidDriver.downgradeRefusal(installed: 62, expected: 61, serial: nil)
        guard let text else { return XCTFail("installed > expected で nil が返った") }
        XCTAssertTrue(text.contains("adb uninstall \(AndroidDriver.bridgePackage)"), text)
        XCTAssertFalse(text.contains("-s "), text)
    }
}
