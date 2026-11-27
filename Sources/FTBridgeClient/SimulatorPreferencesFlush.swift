// アプリのコンテナを空にする前に、cfprefsd が抱えた設定(NSUserDefaults)をファイルごと消させる口(clearAppData・AppleSimulatorWipe)。
// **cfprefsd を起こし直さない**(`launchctl kickstart -k system/com.apple.cfprefsd.xpc.daemon`)—— 起こし直すと SpringBoard の
// 外観の部品(UserInterfaceStyleArbiter)が以後の外観の変更を受け取れなくなり、setAppearance がアプリへ届かない(外観が届かない件 = docs/verification/resolved.md。
// 起こし直しの直後に3/3で無反応・しない対照は反応したまま)。代わりにドメインをパスで名指しして `defaults delete` させると、
// cfprefsd のキャッシュも落ちる(消して起動した起動回数が 1 に戻る = 3/3。ファイルを消すだけなら 2→3・3→4 と戻ってくる)。
// **順序は「アプリを止めた後・容器を空にする前」**: 空にした後ではドメインが無く `defaults delete` は 1(not found)で終わり、
// 成否を終了コードで言えない。止めた後なので書き戻す相手は居ない(ディスクに無くキャッシュにだけある値は、止めた時点で書かれている前提)

import FTCore
import Foundation

public enum SimulatorPreferencesFlush {
    /// コンテナの `Library/Preferences/<ドメイン>`(拡張子なし)の一覧 = ディスクにある設定のドメイン。**空にする前に**呼ぶ
    public static func domainPaths(container: String) -> [String] {
        let dir = container + "/Library/Preferences"
        return ((try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? [])
            .filter { $0.hasSuffix(".plist") }
            .map { dir + "/" + String($0.dropLast(".plist".count)) }
            .sorted()
    }

    /// 各ドメインを cfprefsd に消させる(ファイルとキャッシュの両方)。戻り値 = 失敗したドメイン(パス・理由)。
    /// ドメインが在る間に撃つので、0 以外は失敗
    public static func flush(udid: String, domainPaths: [String]) -> [(path: String, detail: String)] {
        domainPaths.compactMap { path in
            guard let result = try? Shell.run(["xcrun", "simctl", "spawn", udid, "defaults", "delete", path]) else {
                return (path, "could not run simctl spawn defaults delete")
            }
            return result.status == 0 ? nil : (path, "exit \(result.status): \(result.tail)")
        }
    }
}
