// ProfileError.swift
// プロファイルの読み込み・解決のエラー。プロファイルのモデル全体の説明は RunProfile.swift の冒頭

import Foundation

// MARK: - エラー

/// 重複デバイス名エラーの文言の共有部分(ProfileError.duplicateDeviceName と
/// ProfileResolver.validate の2箇所で同じ言い回しにする)。判定は無効化された行
/// (`"enabled": false`)も重複に数える(DeviceMachineGrouping.entries(enabledOnly: false))ので、
/// 文言もそれを言う —— 編集画面には見えない無効行がエラーの原因になりうるため
let duplicateDeviceNameRule =
    "names must be unique per machine, across ios and android — entries with \"enabled\": false count too"

public enum ProfileError: Error, LocalizedError {
    case runProfileNotFound(name: String, available: [String])
    case appProfileNotFound(name: String, available: [String])
    case decodeFailed(URL, detail: String)
    case missingAppReference(run: String)
    case missingDevices(run: String)
    /// devices はあるが全台が enabled: false
    case noEnabledDevices(run: String)
    /// 有効なデバイスが実機だけで、設定タブ「実機をテストで使用する」が OFF(PhysicalDeviceUse)
    case physicalDevicesNotUsed(run: String, devices: [String])
    /// 同じ (platform 横断で machine, name) が2つある。**別マシンの同名は重複ではない**(DeviceMachineGrouping)
    case duplicateDeviceName(name: String, deviceMachine: String?, run: String)
    case missingBundleID(platform: String, appProfile: String)
    case invalidWipeDataThreshold(run: String)
    /// 空(空白のみ含む)の `reportDir`。resolvePath が "" をプロジェクトルートそのものに解くので、レポートがルート直下へ散らばる
    case emptyReportDir(run: String)
    case invalidLocale(run: String)
    case invalidOrientation(run: String, value: String)
    case invalidAppearance(run: String, value: String)
    case invalidTextSize(run: String, value: String)
    /// iosMode / devices[].mode が `IOSMode.all` のどれでもない(device = nil は iosMode)
    case invalidIOSMode(run: String, device: String?, value: String)
    /// kind=physical なのに同定に必要な識別子(iOS=udid / Android=serial)が無い
    case physicalDeviceMissingIdentifier(name: String, platform: String, run: String)
    /// kind=physical に inapp-boost モードが指定された(実機は注入不可)
    /// アプリプロファイルの platform が対象外にした結果、走らせるデバイスが 0 台
    case noDevicesForAppPlatform(run: String, app: String, scope: AppPlatformScope, ignored: Int)
    /// responseMeasurement なのに有効なデバイスが 1 台でない
    case responseMeasurementDeviceCount(run: String, count: Int)
    /// responseMeasurement なのにデバイスが kind=physical でない
    case responseMeasurementNotPhysical(run: String, device: String)
    /// responseMeasurement のデバイスが Android でない
    case responseMeasurementUnsupportedPlatform(run: String, device: String, platform: String)
    /// responseMeasurement が強制する値と、明示された値が食い違う
    case responseMeasurementConflict(run: String, key: String, required: String)
    /// responseRepeat が responseMeasurement 無しで指定された
    case responseRepeatWithoutMeasurement(run: String)
    /// responseRepeat が範囲外
    case responseRepeatOutOfRange(run: String, value: Int, min: Int, max: Int)

    public var errorDescription: String? {
        switch self {
        case .runProfileNotFound(let name, let available):
            return "run profile not found: \(name)"
                + availableHint(available, empty: "profiles/runs/ is empty")
        case .appProfileNotFound(let name, let available):
            return "app profile not found: \(name)"
                + availableHint(available, empty: "profiles/apps/ is empty")
        case .decodeFailed(let url, let detail):
            return "cannot load the profile: \(url.path)\n\(detail)"
        case .missingAppReference(let run):
            return "run profile \(run) has no \"app\" (a reference into apps/)"
        case .missingDevices(let run):
            return "run profile \(run) has no \"devices\""
        case .noEnabledDevices(let run):
            return "run profile \(run) has no enabled devices (every entry in \"devices\" has \"enabled\": false)"
        case .physicalDevicesNotUsed(let run, let devices):
            return "run profile \(run) uses only physical devices (\(devices.joined(separator: ", ")))"
                + " and \"Use physical devices for tests\" is off in the monitor's Settings tab"
                + " (machine setting usePhysicalDevices) — turn it on, or add a simulator/emulator"
        case .duplicateDeviceName(let name, let deviceMachine, let run):
            return "duplicate device name in run profile \(run): \(name)"
                + " on machine \(DeviceMachineGrouping.display(deviceMachine))"
                + " (\(duplicateDeviceNameRule))"
        case .missingBundleID(let platform, let appProfile):
            // 案内は platform セクション限定
            return "app profile \(appProfile) has no \"app\" (bundle ID / package name) for \(platform)"
                + " (add it in the \(platform) section)"
        case .invalidWipeDataThreshold(let run):
            return "wipeDataThresholdGB in run profile \(run) must be a positive number (GB)"
        case .emptyReportDir(let run):
            return "reportDir in run profile \(run) must not be empty (omit it to use reports/)"
        case .invalidLocale(let run):
            return "locale in run profile \(run) must look like ja_JP"
        case .invalidOrientation(let run, let value):
            return "orientation \"\(value)\" in run profile \(run) \(RunProfileDocument.orientationRule)"
        case .invalidAppearance(let run, let value):
            return "appearance \"\(value)\" in run profile \(run) \(FTAppearance.rule)"
        case .invalidTextSize(let run, let value):
            return "textSize \"\(value)\" in run profile \(run) \(FTTextSize.rule)"
        case .invalidIOSMode(let run, let device, let value):
            let key = device.map { "mode of device \"\($0)\"" } ?? "iosMode"
            return "\(key) in run profile \(run) is \"\(value)\" — use \"inapp-boost\" or \"xcuitest\""
        case .physicalDeviceMissingIdentifier(let name, let platform, let run):
            let field = platform == "ios" ? "udid" : "serial"
            let how = platform == "ios"
                ? "the Identifier column of xcrun devicectl list devices, or the UDID"
                : "the left column of adb devices"
            return "device \"\(name)\" in run profile \(run) is kind=physical but has no "
                + "\"\(field)\" (set it to \(how))"
        case .noDevicesForAppPlatform(let run, let app, let scope, let ignored):
            let other = scope == .ios ? "android" : "ios"
            return "run profile \(run) has no enabled \(scope.rawValue) devices"
                + " (app profile \(app) targets \(scope.rawValue) only;"
                + " \(ignored) \(other) device(s) are ignored)"
        case .responseMeasurementDeviceCount(let run, let count):
            return "responseMeasurement in run profile \(run) needs exactly one enabled device (found \(count));"
                + " narrow it with --device <name> (add --runner local for a device on this Mac),"
                + " or set \"enabled\": false on the others"
        case .responseMeasurementNotPhysical(let run, let device):
            return "responseMeasurement in run profile \(run) needs a physical device, but \"\(device)\" is not"
                + " kind=physical (use a physical device, or turn responseMeasurement off)"
        case .responseMeasurementUnsupportedPlatform(let run, let device, let platform):
            return "responseMeasurement in run profile \(run) supports only Android and iOS physical devices,"
                + " but \"\(device)\" is \(platform)"
        case .responseMeasurementConflict(let run, let key, let required):
            return "responseMeasurement in run profile \(run) requires \(key) to be \(required),"
                + " but it is set the other way (remove \(key), or turn responseMeasurement off)"
        case .responseRepeatWithoutMeasurement(let run):
            return "responseRepeat in run profile \(run) needs responseMeasurement"
                + " (set responseMeasurement to true, or remove responseRepeat)"
        case .responseRepeatOutOfRange(let run, let value, let min, let max):
            let why = value < min
                ? "must be at least \(min)"
                : "must be at most \(max) (a larger value is more likely a typo; it would keep one run busy for a very long time)"
            return "responseRepeat in run profile \(run) \(why), but it is \(value)"
        }
    }

    private func availableHint(_ available: [String], empty: String) -> String {
        available.isEmpty ? " (\(empty))" : " (available: \(available.joined(separator: ", ")))"
    }
}

extension ProfileError {
    /// `ProfileResolver.validate`(単体ファイル検査)が同じ原因を別の文言で既に出す解決エラーか。
    /// validate-profile は解決まで通す(段ごとにしか出ない誤りを隠さない)ので、この判定で同じ原因の2行目を除く。
    /// 静的検査に無い誤り(iosMode・noEnabledDevices・アプリプロファイル側の読み込み失敗 等)は false = 必ず出す。
    /// `runFileName` = 検証中の実行プロファイルのファイル名(拡張子なし)。別ファイル(アプリプロファイル)の
    /// decodeFailed は静的検査が見ていないので false
    public func isCoveredByStaticRunValidation(runFileName: String) -> Bool {
        switch self {
        case .emptyReportDir, .duplicateDeviceName, .missingAppReference, .missingDevices,
             .invalidWipeDataThreshold, .invalidLocale, .invalidOrientation, .invalidAppearance, .invalidTextSize,
             .physicalDeviceMissingIdentifier:
            return true
        case .decodeFailed(let url, _):
            return url.deletingPathExtension().lastPathComponent == runFileName
                && url.deletingLastPathComponent().lastPathComponent == ProfileFileKind.run.directoryName
        default:
            return false
        }
    }
}
