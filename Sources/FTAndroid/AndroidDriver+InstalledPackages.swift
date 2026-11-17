// AndroidDriver+InstalledPackages.swift
// インストール済みパッケージの照会(差分インストールの判定・パッケージ名の一覧)。

import CryptoKit
import Foundation
import FTBridgeClient
import FTCore

extension AndroidDriver {
    /// インストール済み APK が apkPath と同一内容か(adb install は base.apk をそのままコピーする
    /// ため md5 一致で判定できる。autoInstall の差分スキップ用)。未インストール・判定不能は
    /// false(=要インストール)。
    public func installedPackageIsCurrent(packageID: String, apkPath: String) -> Bool {
        guard AndroidPackageName.isShellSafe(packageID) else { return false }
        if ApksBundle.isApks(path: apkPath) {
            return installedSplitsAreCurrent(packageID: packageID, apksPath: apkPath)
        }
        // md5sum は APK の大きさで所要が変わる = 入口で1回だけ応答を確かめる(答えなければ「要インストール」= install の門が名指しで断る)
        guard (try? requireDeviceAnswers()) != nil,
              let pathResult = try? adb(["shell", "pm", "path", packageID]),
              pathResult.status == 0 else { return false }
        guard let remote = pathResult.output.split(separator: "\n")
            .first(where: { $0.hasPrefix("package:") })
            .map({ String($0.dropFirst("package:".count)).trimmingCharacters(in: .whitespaces) }),
            !remote.isEmpty else { return false }
        guard let md5Result = try? adb(["shell", "md5sum", remote]), md5Result.status == 0,
              let remoteHash = md5Result.output.split(separator: " ").first.map(String.init) else {
            return false
        }
        guard let localData = try? Data(contentsOf: URL(fileURLWithPath: apkPath)) else { return false }
        let localHash = Insecure.MD5.hash(data: localData).map { String(format: "%02x", $0) }.joined()
        return remoteHash.lowercased() == localHash
    }

    /// .apks 版の差分判定: 端末に入っている base/split の全ファイルがこの .apks のエントリ由来か
    /// (規則と限界は ApksBundle.installedIsFromBundle)
    private func installedSplitsAreCurrent(packageID: String, apksPath: String) -> Bool {
        let entries = ApksBundle.listEntries(apksPath: apksPath)
        guard !entries.isEmpty else { return false }
        guard let script = ApksBundle.installedFilesScript(packageID: packageID),
              (try? requireDeviceAnswers()) != nil,
              let probe = try? adb(["shell", script]),
              probe.status == 0,
              let installed = ApksBundle.parseInstalledFiles(probe.output) else { return false }
        return ApksBundle.installedIsFromBundle(installed: installed, entries: entries) {
            ApksBundle.entryMD5(apksPath: apksPath, entry: $0)
        }
    }

    /// インストール済みのユーザーアプリ(third-party)のパッケージ名一覧。
    public func listInstalledPackages() throws -> [String] {
        try packageIDs(scope: "-3")
    }

    public struct InstalledPackage: Sendable, Equatable {
        public let id: String
        public let isUser: Bool

        public init(id: String, isUser: Bool) {
            self.id = id
            self.isUser = isUser
        }
    }

    /// **system も引けるようにする**: 端末に載っている地図・ブラウザ等は
    /// system 扱いで `-3` には1つも出ず、MCP から探しようが無かった(実測: Pixel の AVD で
    /// `com.google.android.apps.maps` が出ず adb へ落ちた)。`pm` は `-3` か `-s` の
    /// どちらかしか出せないので2回撃つ。**system アプリに更新が当たると `-s` 側にだけ出る**ので、
    /// 同じ id が両方に出たときは user を採る(利用者から見て「自分で入れた物」に近い)
    public func listPackages(includeSystem: Bool) throws -> [InstalledPackage] {
        let user = try packageIDs(scope: "-3").map { InstalledPackage(id: $0, isUser: true) }
        guard includeSystem else { return user }
        let userIDs = Set(user.map(\.id))
        let system = try packageIDs(scope: "-s")
            .filter { !userIDs.contains($0) }
            .map { InstalledPackage(id: $0, isUser: false) }
        return (user + system).sorted { $0.id < $1.id }
    }

    /// **終了コードを見る**(失敗の出力から「入っているアプリは 0 個」を作らない)
    private func packageIDs(scope: String) throws -> [String] {
        // 期限つき(凍結した端末は答えない。尽きたら ShellError.timedOut = 何を何秒で切ったかを言う)
        let result = try adbProbe(["shell", "pm", "list", "packages", scope],
                                  timeout: Self.deviceAnswerTimeoutSeconds)
        guard result.status == 0 else {
            throw DriverError.badResponse(status: Int(result.status),
                body: "failed to list installed packages: \(result.tail)")
        }
        return result.output.split(separator: "\n")
            .compactMap { line in
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                return trimmed.hasPrefix("package:") ? String(trimmed.dropFirst("package:".count)) : nil
            }
            .sorted()
    }
}
