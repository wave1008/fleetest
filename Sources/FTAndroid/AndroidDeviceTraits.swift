// Android の台の性質(`DeviceTraits`)の観測(ブリッジ無し)。読めない性質は nil。

import Foundation
import FTCore

public enum AndroidDeviceTraits {

    /// config.ini の1キー(**キー完全一致**: `hw.sensor.hinge` は `hw.sensor.hinge.count=` に当たらない)。値が空なら nil
    public static func configValue(_ key: String, in text: String) -> String? {
        for line in text.split(whereSeparator: \.isNewline) where line.hasPrefix(key + "=") {
            let value = line.dropFirst(key.count + 1).trimmingCharacters(in: .whitespaces)
            return value.isEmpty ? nil : value
        }
        return nil
    }

    /// `image.sysdir.1` → `"Android 17"`。**エミュレータの OS の出どころはこれ1つ**(起動中でも getprop を使わない =
    /// 12L / 12 の表記が揺れる)。API 21 未満(`API 19` 形)は `Android ` で始まらないので nil
    static func osVersion(sysdir: String?) -> String? {
        guard let sysdir, let image = VirtualDeviceNaming.androidImage(fromSysdir: sysdir) else { return nil }
        let name = RunProfileDeviceEditor.androidVersionName(apiLevel: image.apiLevel)
        return name.hasPrefix("Android ") ? name : nil
    }

    /// エミュレータ。`configText` nil = config.ini が読めない(foldable・OS・機種が nil)。
    /// foldable は `hw.sensor.hinge=yes` の完全一致(折りたたまない AVD にも `hw.sensor.hinge.*` は並ぶ)。
    /// `deviceDefinitions` = avdmanager の id → 表示名(nil = 読めなかった → 機種名だけ nil)
    public static func emulatorTraits(configText: String?, deviceDefinitions: [String: String]?) -> DeviceTraits {
        guard let text = configText else { return DeviceTraits(platform: "android", physical: false) }
        let model = configValue("hw.device.name", in: text).flatMap { deviceDefinitions?[$0] }
        return DeviceTraits(platform: "android", physical: false,
                            foldable: configValue("hw.sensor.hinge", in: text) == "yes",
                            homeButton: false,
                            osVersion: osVersion(sysdir: configValue("image.sysdir.1", in: text)),
                            model: model)
    }

    /// 実機(`ro.build.version.release` / `ro.product.model`。取れなければ nil)。折りたたみの実機は foldable false(fold が 501 の赤になる現状)
    public static func physicalTraits(release: String?, model: String?) -> DeviceTraits {
        let version = release.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .flatMap { v in v.first?.isNumber == true ? "Android " + v : nil }
        let name = model.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.flatMap { $0.isEmpty ? nil : $0 }
        return DeviceTraits(platform: "android", physical: true, foldable: false, homeButton: false,
                            osVersion: version, model: name)
    }

    public static func emulatorTraits(avd: String?, deviceDefinitions: [String: String]?) -> DeviceTraits {
        guard let avd, !avd.isEmpty else { return DeviceTraits(platform: "android", physical: false) }
        let config = AndroidDeviceCatalog.avdContentDirectory(id: AndroidDeviceCatalog.canonicalAVDID(avd))
            .appendingPathComponent("config.ini")
        return emulatorTraits(configText: try? String(contentsOf: config, encoding: .utf8),
                              deviceDefinitions: deviceDefinitions)
    }

    /// adb 1台ぶん。失敗(非ゼロ・締切)は nil(失敗の出力を値にしない)
    public static func physicalTraits(serial: String?) -> DeviceTraits {
        guard let serial, !serial.isEmpty, let adb = try? AndroidDriver.findADB() else {
            return DeviceTraits(platform: "android", physical: true, foldable: false, homeButton: false)
        }
        func prop(_ key: String) -> String? {
            (try? Shell.run([adb, "-s", serial, "shell", "getprop", key],
                            timeout: AndroidDeviceCatalog.adbTimeoutSeconds))?.outputIfSucceeded
        }
        return physicalTraits(release: prop("ro.build.version.release"), model: prop("ro.product.model"))
    }
}
