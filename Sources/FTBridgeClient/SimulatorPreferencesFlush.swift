// アプリのコンテナを空にする前に、cfprefsd が抱えた設定(NSUserDefaults)をファイルごと消させる口(clearAppData・AppleSimulatorWipe)。
// **cfprefsd を起こし直さない**(`launchctl kickstart -k system/com.apple.cfprefsd.xpc.daemon`)—— 起こし直すと SpringBoard の
// 外観の部品(UserInterfaceStyleArbiter)が以後の外観の変更を受け取れなくなり、setAppearance がアプリへ届かない
// (外観が届かない件 = docs/verification/resolved.md。起こし直しの直後に3/3で無反応・しない対照は反応したまま)。
// 代わりにドメインをパスで名指しして `defaults delete` させると、cfprefsd のキャッシュも落ちる(消して起動した起動回数が 1 に戻る = 3/3。
// ファイルを消すだけなら 2→3・3→4 と戻ってくる)。
// **順序は「アプリを止めた後・容器を空にする前」**: 空にした後ではドメインが無く `defaults delete` は 1(not found)で終わり、
// 成否を終了コードで言えない。止めた後なので書き戻す相手は居ない(初回起動で作ったドメインも、止めた直後には plist がある = 実測)

import FTCore
import Foundation

public enum SimulatorPreferencesFlush {
    /// 秒。1回の `simctl spawn … defaults delete` の上限。根拠: 静かな機械で1秒未満・負荷の下の simctl は十数秒かかった回がある
    /// (`BridgeClient` の terminate の上限と同じ桁)。尽きたらそのドメインは失敗として呼び手が言う
    public static let deleteTimeoutSeconds: Double = 30

    /// コンテナの `Library/Preferences/<ドメイン>`(拡張子なし)の一覧 = ディスクにある設定のドメイン。**空にする前に**呼ぶ。
    /// nil = 設定の置き場が容器の外を指している(`Library` か `Library/Preferences` が symlink)= 呼び手が断る。
    /// symlink の plist は外す(空にする段がリンクだけを消す)
    public static func domainPaths(container: String) -> [String]? {
        let dir = container + "/Library/Preferences"
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: dir) else {
            // 置き場が無い = ドメインも無い。在るのに読めない(リンク先が消えた等)も、下の判定で外の扱いになる
            return FileManager.default.fileExists(atPath: dir) ? nil : []
        }
        let paths = names.filter { $0.hasSuffix(".plist") }.map { dir + "/" + String($0.dropLast(".plist".count)) }
        guard SimulatorPreferencesPath.isDomain(dir + "/probe", inContainer: container) else { return nil }
        return paths.filter { SimulatorPreferencesPath.isDomain($0, inContainer: container) }.sorted()
    }

    /// 各ドメインを cfprefsd に消させる(ファイルとキャッシュの両方)。戻り値 = 失敗したドメイン(パス・理由)。
    /// 0 以外で終わっても、plist にキーが1つも無ければ失敗にしない(空の dict・0 バイトは cfprefsd が not found と答える =
    /// 消すべき値が無い。判定はファイルの中身で行い、文言を読まない)
    public static func flush(udid: String, domainPaths: [String]) -> [(path: String, detail: String)] {
        domainPaths.compactMap { path in
            guard let result = try? Shell.run(["xcrun", "simctl", "spawn", udid, "defaults", "delete", path],
                                              timeout: deleteTimeoutSeconds) else {
                return (path, "could not run simctl spawn defaults delete")
            }
            if result.status == 0 || !hasKeys(plist: path + ".plist") { return nil }
            return (path, "exit \(result.status): \(result.tail)")
        }
    }

    /// plist にキーが1つ以上あるか。読めない形は「ある」(消せたと言わない側)
    static func hasKeys(plist: String) -> Bool {
        guard let data = FileManager.default.contents(atPath: plist) else { return false }
        if data.isEmpty { return false }
        guard let object = try? PropertyListSerialization.propertyList(from: data, format: nil) else { return true }
        return !((object as? [String: Any])?.isEmpty ?? false)
    }
}
