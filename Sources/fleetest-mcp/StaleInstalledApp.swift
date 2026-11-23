// プロファイルの呼び出しで、端末に入っているアプリが appPath と違うことを注記で知らせる。
// MCP は入れ直さない(探索中の画面を失う)ので、古い版のまま探索させないための知らせだけを出す。
// 差分の判定は run の autoInstall 差分スキップと同じ実装を呼ぶ(`InstalledAppCheck.simulatorAppIsCurrent` /
// `AndroidDriver.installedPackageIsCurrent`)。2つ目の判定を書かない。

import Foundation
import FTAndroid
import FTBridgeClient
import FTCore

enum InstalledAppFreshness: Equatable {
    case same
    case differs
    /// 比べられない(実機の iOS・未インストール・adb/simctl が答えない)
    case notComparable
}

extension MCPServer {
    /// 判定から文言を決める純粋関数。同じ・比べられない・2回目以降は nil
    static func staleInstalledAppNote(freshness: InstalledAppFreshness, bundleID: String,
                                      appPath: String, alreadyChecked: Bool) -> String? {
        guard !alreadyChecked, freshness == .differs else { return nil }
        return "note: the installed \(bundleID) differs from the app profile's appPath (\(appPath))"
            + " — it may be an older build, so what you explore may not match a run (which reinstalls it)."
            + " To explore the current build: ft_install packagePath: \(appPath)"
    }

    /// 入っているアプリと appPath の比較。パッケージが無い・入っていない・確かめられないときは `.notComparable`
    /// (appPath を持たないプロファイルは nil = 何も言わない)。
    /// **Android の `installedPackageIsCurrent` は未インストールと判定不能も false で返す**ので、先に在否(`installedVerdict`)を見る
    func installedAppFreshness(
        target: ResolvedDriverTarget, resolved: ResolvedProfile, driver: AppDriver, args: [String: Any]
    ) async -> (bundleID: String, appPath: String, freshness: InstalledAppFreshness)? {
        // 差し替えドライバ(テスト)ではデバイスを照会しない
        guard makeDriver == nil else { return nil }
        switch target {
        case .ios(let provisioned, let iosApp):
            guard let iosApp, let appPath = iosApp.packagePath(physical: provisioned.physical) else { return nil }
            // 実機のアプリコンテナはホストから読めない(run の差分スキップと同じ制約)
            guard !provisioned.physical else { return (iosApp.bundleID, appPath, .notComparable) }
            guard await installedVerdict(bundleID: iosApp.bundleID, driver: driver, args: args) == .installed
            else { return (iosApp.bundleID, appPath, .notComparable) }
            let current = InstalledAppCheck.simulatorAppIsCurrent(
                udid: provisioned.udid, bundleID: iosApp.bundleID, appPath: appPath)
            return (iosApp.bundleID, appPath, current ? .same : .differs)
        case .android:
            guard let android = driver as? AndroidDriver, let app = resolved.apps["android"] else { return nil }
            let physical = resolved.devices.first { $0.platform == "android" }?.spec.isPhysical ?? false
            guard let appPath = app.packagePath(physical: physical) else { return nil }
            guard await installedVerdict(bundleID: app.bundleID, driver: driver, args: args) == .installed
            else { return (app.bundleID, appPath, .notComparable) }
            let current = android.installedPackageIsCurrent(packageID: app.bundleID, apkPath: appPath)
            return (app.bundleID, appPath, current ? .same : .differs)
        }
    }
}
