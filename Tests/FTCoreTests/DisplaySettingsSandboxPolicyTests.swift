// 表示条件(外観・文字サイズ)の端末コマンドが、サンドボックスの代行の許可表を通ること(DR-220〜222)。
// 組み立て(`DisplaySettingsCommands`)と許可表(`DevicectlPolicy` / `AdbPolicy`)の片方だけの変更を落とす。
// 子は枠の中なので、表から外れるとデバイス実行のサンドボックスの中でだけ断られる(枠の外の単体テストは緑のまま)。

import XCTest
@testable import FTCore

final class DisplaySettingsSandboxPolicyTests: XCTestCase {

    private let ios = SimctlPolicy.Context(udid: "LANE-UDID", deviceName: nil, toolRoots: [], childWritableRoots: [])
    private let android = SimctlPolicy.Context(udid: nil, deviceName: nil, toolRoots: [], childWritableRoots: [],
                                               serial: "emulator-5554", adbPath: "/parent/adb")

    private func iosRefusal(_ argv: [String]) -> String? { BrokerPolicy.check(argv, context: ios)?.reason }
    private func androidRefusal(_ argv: [String]) -> String? { BrokerPolicy.check(argv, context: android)?.reason }

    // MARK: iOS

    func testIOSBuildersPassThePolicy() {
        XCTAssertNil(iosRefusal(DisplaySettingsCommands.iosRead(udid: "LANE-UDID", timeoutSeconds: 10)))
        XCTAssertNil(iosRefusal(DisplaySettingsCommands.iosRead(udid: "LANE-UDID", timeoutSeconds: 3)))
        for appearance in FTAppearance.allCases {
            let change = DisplayChange(appearance: appearance)
            XCTAssertNil(iosRefusal(DisplaySettingsCommands.iosSet(udid: "LANE-UDID", change: change, timeoutSeconds: 10)))
        }
        for size in FTTextSize.allCases {
            for larger in [nil, true, false] as [Bool?] {
                let change = DisplayChange(appearance: .dark, textSize: size, largerAccessibilitySizes: larger)
                let argv = DisplaySettingsCommands.iosSet(udid: "LANE-UDID", change: change, timeoutSeconds: 10)
                XCTAssertNil(iosRefusal(argv), argv.joined(separator: " "))
            }
        }
        // 「より大きな文字」だけ(終わりの処理が開始時の値へ戻す形)
        XCTAssertNil(iosRefusal(DisplaySettingsCommands.iosSet(
            udid: "LANE-UDID", change: DisplayChange(largerAccessibilitySizes: false), timeoutSeconds: 3)))
    }

    func testIOSRefusesAnotherDeviceAndOffTableShapes() {
        let base = ["xcrun", "devicectl", "device", "settings", "appearance", "--device", "LANE-UDID",
                    "--timeout", "10", "-q"]
        XCTAssertNil(iosRefusal(base + ["--mode", "dark"]))
        XCTAssertNotNil(iosRefusal(DisplaySettingsCommands.iosRead(udid: "OTHER", timeoutSeconds: 10)), "別の端末の読み取り")
        XCTAssertNotNil(iosRefusal(["xcrun", "devicectl", "device", "settings", "appearance", "--device", "OTHER",
                                    "--timeout", "10", "-q", "--mode", "dark"]), "別の端末への設定")
        XCTAssertNotNil(iosRefusal(base), "設定する内容が無い")
        XCTAssertNotNil(iosRefusal(base + ["--mode", "auto"]), "語彙に無い外観")
        XCTAssertNotNil(iosRefusal(base + ["--text-size", "huge"]), "語彙に無い段階名")
        XCTAssertNotNil(iosRefusal(base + ["--mode", "dark", "--mode", "light"]), "同じ引数の重複")
        XCTAssertNotNil(iosRefusal(base + ["--mode"]), "値の無い引数")
        XCTAssertNotNil(iosRefusal(base + ["--mode", "dark", "--evil", "x"]), "知らない引数")
        XCTAssertNotNil(iosRefusal(base + ["--larger-accessibility-sizes", "maybe"]))
        XCTAssertNotNil(iosRefusal(["xcrun", "devicectl", "device", "settings", "appearance", "--device", "LANE-UDID",
                                    "--timeout", "10;rm", "-q", "--mode", "dark"]), "整数でない --timeout")
        XCTAssertNotNil(iosRefusal(["xcrun", "devicectl", "device", "info", "appearance", "--device", "LANE-UDID",
                                    "--timeout", "10", "--json-output", "/tmp/x.json", "-q"]), "読み取りの出力先は標準出力だけ")
        XCTAssertNotNil(iosRefusal(["xcrun", "devicectl", "device", "settings", "location", "--device", "LANE-UDID"]),
                        "ほかの settings は断る")
    }

    func testIOSRefusesWhenTheLanesUDIDIsUnknown() {
        var unknown = ios
        unknown.udid = nil
        XCTAssertNotNil(BrokerPolicy.check(DisplaySettingsCommands.iosRead(udid: "LANE-UDID", timeoutSeconds: 10), context: unknown))
    }

    // MARK: Android

    func testAndroidBuildersPassThePolicy() {
        let adb = "/sdk/platform-tools/adb"
        XCTAssertNil(androidRefusal(DisplaySettingsCommands.androidNightRead(adb: adb, serial: "emulator-5554")))
        XCTAssertNil(androidRefusal(DisplaySettingsCommands.androidFontScaleRead(adb: adb, serial: "emulator-5554")))
        for appearance in FTAppearance.allCases {
            XCTAssertNil(androidRefusal(
                DisplaySettingsCommands.androidNightSet(adb: adb, serial: "emulator-5554", appearance: appearance)))
        }
        for size in FTTextSize.allCases {
            XCTAssertNil(androidRefusal(
                DisplaySettingsCommands.androidFontScaleSet(adb: adb, serial: "emulator-5554", textSize: size)))
        }
    }

    func testAndroidRefusesOtherKeysValuesAndDevices() {
        let adb = "/sdk/platform-tools/adb"
        func args(_ rest: [String], serial: String = "emulator-5554") -> [String] { [adb, "-s", serial] + rest }
        XCTAssertNotNil(androidRefusal(args(["shell", "settings", "put", "system", "screen_off_timeout", "1000"])),
                        "任意のキーは断る")
        XCTAssertNotNil(androidRefusal(args(["shell", "settings", "put", "system", "font_scale", "9.9"])), "5つの倍率以外")
        XCTAssertNotNil(androidRefusal(args(["shell", "settings", "put", "secure", "font_scale", "1.0"])), "別のテーブル")
        XCTAssertNotNil(androidRefusal(args(["shell", "settings", "get", "system", "screen_off_timeout"])))
        XCTAssertNotNil(androidRefusal(args(["shell", "cmd", "uimode", "night", "auto"])), "yes / no 以外")
        XCTAssertNotNil(androidRefusal(args(["shell", "cmd", "uimode", "night", "yes", "extra"])))
        XCTAssertNotNil(androidRefusal(args(["shell", "cmd", "uimode", "car", "yes"])))
        XCTAssertNotNil(androidRefusal(args(["shell", "cmd", "uimode", "night", "no"], serial: "emulator-5556")), "別の端末")
        XCTAssertNotNil(androidRefusal([adb, "shell", "cmd", "uimode", "night", "no"]), "-s の無い形")
    }
}
