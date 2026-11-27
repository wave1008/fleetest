// アプリのコンテナを空にする前に、cfprefsd が抱えた設定(NSUserDefaults)をファイルごと消させる口(clearAppData・AppleSimulatorWipe)。
// **cfprefsd を起こし直さない**(`launchctl kickstart -k system/com.apple.cfprefsd.xpc.daemon`)—— 起こし直すと SpringBoard の
// 外観の部品(UserInterfaceStyleArbiter)が以後の外観の変更を受け取れなくなり、setAppearance がアプリへ届かない
// (外観が届かない件 = docs/verification/resolved.md。起こし直しの直後に3/3で無反応・しない対照は反応したまま)。
// 代わりにドメインをパスで名指しして `defaults delete` させると、cfprefsd のキャッシュも落ちる(消して起動した起動回数が 1 に戻る = 3/3。
// ファイルを消すだけなら 2→3・3→4 と戻ってくる)。ByHost の plist もパスで消せる(実測)。
// **順序は「アプリを止めた後・容器を空にする前」**: 空にした後ではドメインが無く `defaults delete` は 1(not found)で終わり、
// 成否を終了コードで言えない。アプリ自身は止めてあるので書き戻さない(初回起動で作ったドメインも、止めた直後には plist がある = 実測)。
// **group の容器はこの前提が成り立たない**(同じ group のウィジェット・拡張が動いていれば書き戻しうる)

import FTCore
import Foundation

public enum SimulatorPreferencesFlush {
    /// 秒。1回の `simctl spawn … defaults delete` の上限。根拠: 静かな機械で1秒未満・負荷の下の simctl は十数秒かかった回がある
    /// (`BridgeClient` の terminate の上限と同じ桁)。尽きたらそのドメインは失敗として呼び手が言う
    public static let deleteTimeoutSeconds: Double = 30

    public enum Listing: Equatable {
        /// ディスクにある設定のドメイン(`Library/Preferences/<ドメイン>` と `ByHost/<ドメイン>`。拡張子なし)
        case domains([String])
        /// 消させない(理由)。呼び手が断る(clearAppData は投げる・AppleSimulatorWipe は problems に残す)
        case refused(String)
    }

    /// **空にする前に**呼ぶ。置き場が無ければ空。置き場か plist が symlink・置き場が読めないなら `.refused`
    /// (symlink の先の設定を消させない。黙って外すと、そのドメインのキャッシュが残ったまま「消えた」と言う)
    public static func domainPaths(container: String) -> Listing {
        let preferences = container + "/Library/Preferences"
        var paths: [String] = []
        for dir in [preferences, preferences + "/ByHost"] {
            var isDirectory: ObjCBool = false
            let exists = FileManager.default.fileExists(atPath: dir, isDirectory: &isDirectory)
            if !exists && !SimulatorPreferencesPath.isSymlink(dir) { continue }
            guard SimulatorPreferencesPath.preferencesDirectoryIsInside(dir, container: container) else {
                return .refused("\(relative(dir, container)) is a symbolic link out of the container")
            }
            guard isDirectory.boolValue, let names = try? FileManager.default.contentsOfDirectory(atPath: dir) else {
                return .refused("\(relative(dir, container)) is not a readable directory")
            }
            for name in names where name.lowercased().hasSuffix(".plist") {
                let domain = dir + "/" + String(name.dropLast(".plist".count))
                guard SimulatorPreferencesPath.isDomain(domain, inContainer: container) else {
                    return .refused("\(relative(dir + "/" + name, container)) is a symbolic link or not a preferences domain")
                }
                paths.append(domain)
            }
        }
        return .domains(paths.sorted())
    }

    private static func relative(_ path: String, _ container: String) -> String {
        path.hasPrefix(container + "/") ? String(path.dropFirst(container.count + 1)) : path
    }

    /// 各ドメインを cfprefsd に消させる(ファイルとキャッシュの両方)。戻り値 = 失敗したドメイン(パス・理由)。
    /// 0 以外で終わっても、plist に値が無ければ失敗にしない(空の dict・0 バイト・読めない形は cfprefsd が not found と答える =
    /// cfprefsd も読み込めていない = 消すべき値が無い。判定はファイルの中身で行い、文言を読まない)
    public static func flush(udid: String, domainPaths: [String]) -> [(path: String, detail: String)] {
        domainPaths.compactMap { path in
            let result: Shell.Result
            do {
                result = try Shell.run(["xcrun", "simctl", "spawn", udid, "defaults", "delete", path], timeout: deleteTimeoutSeconds)
            } catch ShellError.timedOut {
                return (path, "simctl spawn defaults delete did not finish within \(Int(deleteTimeoutSeconds))s")
            } catch {
                return (path, "could not run simctl spawn defaults delete: \(error.localizedDescription)")
            }
            if result.status == 0 || !hasValues(plist: path + ".plist") { return nil }
            return (path, "exit \(result.status): \(result.tail)")
        }
    }

    /// plist が値を1つ以上持つ dict か(cfprefsd が読み込める形で中身がある)
    static func hasValues(plist: String) -> Bool {
        guard let data = FileManager.default.contents(atPath: plist), !data.isEmpty,
              let object = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else { return false }
        return !object.isEmpty
    }
}
