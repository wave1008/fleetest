// PhysicalDeviceUse.swift
// 設定タブ「実機をテストで使用する」(マシン設定 `LocalConfig.usePhysicalDevices`)が OFF のとき、
// **実行から実機を外す**。外し方は「その実機を `enabled: false` として読む」だけ(JSON は書き換えない)なので、
// 以降の判定(台数・振り分け・機械の分担・無効の注記)は既存の enabled の規則にそのまま乗る。
//
// 効かせる場所は2つだけ:
//   - `ProfileResolver`(resolve / runDeviceMachines / disabledRunDevices)—— 手元のすべての実行経路の入口
//   - ランナー機へ送る実行プロファイル(RunnerProfileTransfer)—— 向こうの子は**向こうのマシン設定**で解決するので、
//     手元の OFF を `enabled: false` に焼いて運ぶ(焼かないと `--runner <machine>` の丸ごと転送で実機が走る)
// モニターの一覧から外すのは ApiMonitorCommand(同じ設定を読む)。

import Foundation

public enum PhysicalDeviceUse {
    /// OFF(実行から実機を外す)か。未設定・true は ON
    public static func isOff(config: LocalConfig = LocalConfig.load()) -> Bool {
        config.usePhysicalDevices == false
    }

    /// OFF なら実機を `enabled: false` にした文書と、そのために外した(元は有効だった)実機の名前を返す
    public static func applying(to doc: RunProfileDocument, off: Bool) -> (doc: RunProfileDocument, excluded: [String]) {
        guard off, let devices = doc.devices else { return (doc, []) }
        var copy = doc
        var excluded: [String] = []
        copy.devices = devices.map { entry in
            guard entry.spec.isPhysical else { return entry }
            if entry.isEnabled { excluded.append(entry.spec.name) }
            var disabled = entry
            disabled.enabled = false
            return disabled
        }
        return (copy, excluded)
    }

    /// ランナー機へ送る JSON の実行プロファイル版(未知キーは温存する)
    public static func applying(toJSON object: [String: Any], off: Bool) -> [String: Any] {
        guard off, let list = object["devices"] as? [[String: Any]] else { return object }
        var result = object
        result["devices"] = list.map { device -> [String: Any] in
            guard (device["kind"] as? String) == DeviceKind.physical.rawValue else { return device }
            var disabled = device
            disabled["enabled"] = false
            return disabled
        }
        return result
    }

    public static func excludedWarning(_ names: [String], run: String) -> String {
        "run profile \(run): skipping physical device(s) \(names.joined(separator: ", "))"
            + " (\"Use physical devices for tests\" is off in the monitor's Settings tab)"
    }
}
