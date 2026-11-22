// ScenarioHost+DisplaySettings.swift
// `ScenarioHost.run` が端末の表示条件(DR-221)を撃つ宛先の決定。処理の本体は DisplaySettingsDevice.swift
import Foundation

extension ScenarioHost {
    /// 親が表示条件を読む・設定する宛先。**nil = 何もしない**: dry-run(宛先の無い adb は繋がっている別の端末の設定を変える)・
    /// 片付けだけの子(tearDownDevice / afterAll)・udid / serial の無い接続
    static func displaySettingsTransport(connection: DriverConnection, dryRun: Bool,
                                         lifecycleOnly: Bool) -> DisplaySettingsTransport? {
        guard !dryRun, !lifecycleOnly else { return nil }
        switch connection.platform {
        case "ios":
            guard let udid = connection.udid, !udid.isEmpty else { return nil }
            return IOSDisplaySettingsTransport(udid: udid)
        case "android":
            guard let serial = connection.serial, !serial.isEmpty else { return nil }
            return AndroidDisplaySettingsTransport(serial: serial)
        default:
            return nil
        }
    }
}
