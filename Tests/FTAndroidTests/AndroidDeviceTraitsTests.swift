// Android の台の性質(config.ini / getprop / avdmanager の読み)。破ると: 折りたたまない AVD を折りたたみ機と読む(`hw.sensor.hinge.*` の部分一致)/
// 読めない性質が値に化ける/avdmanager の失敗が OS や折りたたみまで巻き込む。

import FTCore
import XCTest
@testable import FTAndroid

final class AndroidDeviceTraitsTests: XCTestCase {
    /// 折りたたまない AVD(Pixel 10 Pro)の config.ini の該当行。`hw.sensor.hinge.*` は並ぶが本体は no
    private let flat = """
        hw.device.name=pixel_10_pro
        hw.sensor.hinge=no
        hw.sensor.hinge.count=0
        hw.sensor.hinge.type=0
        image.sysdir.1=system-images/android-37.1/google_apis_ps16k/arm64-v8a/
        """
    /// 折りたたみ AVD(Pixel 9 Pro Fold)
    private let fold = """
        hw.device.name=pixel_9_pro_fold
        hw.sensor.hinge=yes
        hw.sensor.hinge.count=1
        image.sysdir.1=system-images/android-36/google_apis/arm64-v8a/
        """
    private let defs = ["pixel_10_pro": "Pixel 10 Pro", "pixel_9_pro_fold": "Pixel 9 Pro Fold"]

    func testFoldableIsExactHingeKeyOnly() {
        XCTAssertEqual(AndroidDeviceTraits.emulatorTraits(configText: fold, deviceDefinitions: defs).foldable, true)
        XCTAssertEqual(AndroidDeviceTraits.emulatorTraits(configText: flat, deviceDefinitions: defs).foldable, false)
        // `hinge=` の行が無く `hinge.count=1` だけ → 部分一致で true にしない
        XCTAssertEqual(AndroidDeviceTraits.emulatorTraits(configText: "hw.sensor.hinge.count=1\n", deviceDefinitions: defs).foldable, false)
        XCTAssertNil(AndroidDeviceTraits.configValue("hw.sensor.hinge", in: "hw.sensor.hinge.count=1\n"))
    }

    func testOSFromSysdirOnly() {
        XCTAssertEqual(AndroidDeviceTraits.emulatorTraits(configText: flat, deviceDefinitions: defs).osVersion, "Android 17")
        XCTAssertEqual(AndroidDeviceTraits.emulatorTraits(configText: fold, deviceDefinitions: defs).osVersion, "Android 16")
        XCTAssertEqual(AndroidDeviceTraits.osVersion(sysdir: "system-images/android-32/google_apis/arm64-v8a/"), "Android 12L")
        XCTAssertNil(AndroidDeviceTraits.osVersion(sysdir: "system-images/android-19/default/x86/"), "`API 19` 形は Android で始まらない")
        XCTAssertNil(AndroidDeviceTraits.osVersion(sysdir: "garbage"))
        XCTAssertNil(AndroidDeviceTraits.emulatorTraits(configText: "hw.device.name=x\n", deviceDefinitions: defs).osVersion)
    }

    func testModelFromAvdmanagerDefinitions() {
        XCTAssertEqual(AndroidDeviceTraits.emulatorTraits(configText: fold, deviceDefinitions: defs).model, "Pixel 9 Pro Fold")
        XCTAssertNil(AndroidDeviceTraits.emulatorTraits(configText: fold, deviceDefinitions: ["other": "X"]).model)
    }

    /// avdmanager が失敗(定義が nil)したら機種名だけ nil。折りたたみ・OS は config.ini から読める
    func testAvdmanagerFailureOnlyNilsModel() {
        let t = AndroidDeviceTraits.emulatorTraits(configText: fold, deviceDefinitions: nil)
        XCTAssertNil(t.model)
        XCTAssertEqual(t.foldable, true)
        XCTAssertEqual(t.osVersion, "Android 16")
        XCTAssertEqual(t.homeButton, false)
    }

    func testUnreadableConfigKeepsOnlyKind() {
        XCTAssertEqual(AndroidDeviceTraits.emulatorTraits(configText: nil, deviceDefinitions: defs),
                       DeviceTraits(platform: "android", physical: false))
        XCTAssertEqual(AndroidDeviceTraits.emulatorTraits(avd: nil, deviceDefinitions: defs),
                       DeviceTraits(platform: "android", physical: false))
    }

    func testPhysicalFromGetprop() {
        XCTAssertEqual(AndroidDeviceTraits.physicalTraits(release: "16\n", model: "Pixel 9\n"),
                       DeviceTraits(platform: "android", physical: true, foldable: false, homeButton: false,
                                    osVersion: "Android 16", model: "Pixel 9"))
        let bad = AndroidDeviceTraits.physicalTraits(release: nil, model: "  ")
        XCTAssertNil(bad.osVersion)
        XCTAssertNil(bad.model)
        XCTAssertNil(AndroidDeviceTraits.physicalTraits(release: "error: device offline", model: nil).osVersion)
    }

    // MARK: - 台の種類(DR-214。対象外の回し直しで同じ種類の台を試した扱いにする)

    func testEmulatorKindIsDeviceImageAndHinge() {
        XCTAssertEqual(AndroidDeviceTraits.emulatorKind(configText: flat),
                       "android|pixel_10_pro|system-images/android-37.1/google_apis_ps16k/arm64-v8a|hinge=no")
        XCTAssertEqual(AndroidDeviceTraits.emulatorKind(configText: fold),
                       "android|pixel_9_pro_fold|system-images/android-36/google_apis/arm64-v8a|hinge=yes")
    }

    /// ヒンジだけ違う2台は別の種類(折りたたみ機を取りこぼして誤った緑にしない)・機種やイメージが違っても別
    func testEmulatorKindDiffersByHingeDeviceAndImage() {
        let yes = flat.replacingOccurrences(of: "hw.sensor.hinge=no", with: "hw.sensor.hinge=yes")
        XCTAssertNotEqual(AndroidDeviceTraits.emulatorKind(configText: flat), AndroidDeviceTraits.emulatorKind(configText: yes))
        XCTAssertNotEqual(AndroidDeviceTraits.emulatorKind(configText: flat),
                          AndroidDeviceTraits.emulatorKind(configText: flat.replacingOccurrences(of: "pixel_10_pro", with: "pixel_9")))
        XCTAssertNotEqual(AndroidDeviceTraits.emulatorKind(configText: flat),
                          AndroidDeviceTraits.emulatorKind(configText: flat.replacingOccurrences(of: "android-37.1", with: "android-36")))
    }

    /// 末尾の / の有無で割れない・ヒンジのキーが無い AVD は no・機種かイメージが読めなければ不明
    func testEmulatorKindNormalisationAndUnknown() {
        let a = "hw.device.name=p\nimage.sysdir.1=system-images/android-36/x/arm64-v8a/\n"
        let b = "hw.device.name=p\nimage.sysdir.1=system-images/android-36/x/arm64-v8a\nhw.sensor.hinge=no\n"
        XCTAssertEqual(AndroidDeviceTraits.emulatorKind(configText: a), AndroidDeviceTraits.emulatorKind(configText: b))
        XCTAssertNil(AndroidDeviceTraits.emulatorKind(configText: "hw.device.name=p\n"), "イメージが読めない")
        XCTAssertNil(AndroidDeviceTraits.emulatorKind(configText: "image.sysdir.1=system-images/android-36/x/arm64-v8a/\n"), "機種が読めない")
        XCTAssertNil(AndroidDeviceTraits.emulatorKind(configText: nil))
        XCTAssertNil(AndroidDeviceTraits.emulatorKind(avd: nil))
        XCTAssertNil(AndroidDeviceTraits.emulatorKind(avd: ""))
    }
}
