// アプリのコンテナを空にする前に、cfprefsd が抱えた設定(NSUserDefaults)をファイルごと消させる口(clearAppData・AppleSimulatorWipe)。
// **cfprefsd を起こし直さない**(`launchctl kickstart -k system/com.apple.cfprefsd.xpc.daemon`)—— 起こし直すと SpringBoard の
// 外観の部品(UserInterfaceStyleArbiter)が以後の外観の変更を受け取れなくなり、setAppearance がアプリへ届かない
// (外観が届かない件 = docs/verification/resolved.md。起こし直しの直後に3/3で無反応・しない対照は反応したまま)。
// 代わりにドメインをパスで名指しして `defaults delete` させると、cfprefsd のキャッシュも落ちる(消して起動した起動回数が 1 に戻る = 3/3。
// ファイルを消すだけなら 2→3・3→4 と戻ってくる)。ByHost の plist もパスで消せる(実測)。
// **順序は「アプリを止めた後・容器を空にする前」**: 空にした後ではドメインが無く `defaults delete` は 1(not found)で終わり、
// 成否を終了コードで言えない(0 以外は plist に値が無ければ成功とみなす = `flush`)。アプリ自身は止めてあるので書き戻さない。
// アプリ自身のドメインはファイルが無くても消させる(cfprefsd がまだ書いていない値をキャッシュにだけ持っている場合)。
// **group の容器はこの前提が成り立たない**(同じ group のウィジェット・拡張が動いていれば書き戻しうる)

import FTCore
import Foundation

public enum SimulatorPreferencesFlush {
    /// 秒。1回の `simctl spawn … defaults delete` の上限。根拠: 静かな機械で1秒未満・負荷の下の simctl は十数秒かかった回がある
    /// (`BridgeClient` の terminate の上限と同じ桁)。尽きたらそのドメインは失敗として呼び手が言う
    public static let deleteTimeoutSeconds: Double = 30

    /// 消させてよいドメインと、断った項目。**危ない項目だけを外し、ほかの安全なドメインは消させる**(全部を断って容器を空にすると、
    /// 安全なドメインのキャッシュが残ったまま次回は plist が無く名指せない = 黙った緑になる)
    public struct Listing: Equatable {
        /// ディスクにある設定のドメインと `always`(`Library/Preferences/<ドメイン>` と `ByHost/<ドメイン>`。拡張子なし)
        public var domains: [String]
        /// 断った項目(理由)。置き場そのものが外を指す・読めないときは domains が空でここに1つ
        public var refusals: [String]
    }

    /// **空にする前に**呼ぶ。`always` = ファイルが無くても含めるドメイン(アプリ自身)。置き場が外を指す(symlink)・読めないなら
    /// そこは何も消させない。symlink の plist はそれだけ外して断った項目に残す(symlink の先の設定を消させない)。
    /// ドメインの名前として通らない名前(制御文字等)の plist は飛ばす(空にする段がファイルを消す)
    public static func domainPaths(container: String, always: [String]) -> Listing {
        let preferences = container + "/Library/Preferences"
        var paths: [String] = []
        var refusals: [String] = []
        for dir in [preferences, preferences + "/ByHost"] {
            var isDirectory: ObjCBool = false
            let exists = FileManager.default.fileExists(atPath: dir, isDirectory: &isDirectory)
            if !exists && !SimulatorPreferencesPath.isSymlink(dir) { continue }
            // `Library/Preferences` そのものが危ないなら何も消させない。ByHost だけが危ないなら ByHost だけを外す
            let isByHost = dir != preferences
            guard SimulatorPreferencesPath.preferencesDirectoryIsInside(dir, container: container) else {
                refusals.append("\(relative(dir, container)) is a symbolic link out of the container")
                if isByHost { continue }
                return Listing(domains: [], refusals: refusals)
            }
            guard isDirectory.boolValue, let names = try? FileManager.default.contentsOfDirectory(atPath: dir) else {
                refusals.append("\(relative(dir, container)) is not a readable directory")
                if isByHost { continue }
                return Listing(domains: [], refusals: refusals)
            }
            // 拡張子は区別して照合する(`defaults delete` と `hasValues` は小文字の `.plist` を見る。`Foo.PLIST` を拾うと黙って通る)
            for name in names where name.hasSuffix(".plist") {
                let domain = dir + "/" + String(name.dropLast(".plist".count))
                if SimulatorPreferencesPath.isSymlink(domain) || SimulatorPreferencesPath.isSymlink(domain + ".plist") {
                    refusals.append("\(relative(dir + "/" + name, container)) is a symbolic link")
                } else if SimulatorPreferencesPath.isDomain(domain, inContainer: container) {
                    paths.append(domain)
                }
            }
        }
        for name in always where SimulatorPreferencesPath.isDomainName(name) {
            let domain = preferences + "/" + name
            if !paths.contains(domain), SimulatorPreferencesPath.isDomain(domain, inContainer: container) { paths.append(domain) }
        }
        return Listing(domains: paths.sorted(), refusals: refusals)
    }

    private static func relative(_ path: String, _ container: String) -> String {
        path.hasPrefix(container + "/") ? String(path.dropFirst(container.count + 1)) : path
    }

    public struct Outcome {
        /// 消させられなかったドメイン(パス・理由)
        public var failures: [(path: String, detail: String)] = []
        /// 時間切れで止めた(呼び手は以後の容器も撃たない = 詰まった Simulator で容器の数 × 上限だけ止まらない)
        public var timedOut = false
    }

    /// 各ドメインを cfprefsd に消させる(ファイルとキャッシュの両方)。
    /// 0 以外で終わっても、plist に値が無ければ失敗にしない(空の dict・0 バイト・読めない形は cfprefsd が not found と答える =
    /// cfprefsd も読み込めていない = 消すべき値が無い。判定はファイルの中身で行い、文言を読まない)。
    /// **時間切れが1回出たら残りは撃たない**(外 = `ShellError.timedOut`・サンドボックスの中 = 仲介の 127。外の 127 はシェルの
    /// 「見つからない」なので止めない)。残りも消させられなかった扱い
    /// - insideSandbox: シナリオの子の中か(127 を仲介の時間切れと読むか)。run: simctl を撃つ口(テストの差し替え口)
    public static func flush(udid: String, domainPaths: [String],
                             insideSandbox: Bool = ProcessInfo.processInfo.environment[SandboxGateway.environmentKey] != nil,
                             run: ([String], Double) throws -> Shell.Result = { try Shell.run($0, timeout: $1) }) -> Outcome {
        var outcome = Outcome()
        for (index, path) in domainPaths.enumerated() {
            let result: Shell.Result
            do {
                result = try run(["xcrun", "simctl", "spawn", udid, "defaults", "delete", path], deleteTimeoutSeconds)
            } catch ShellError.timedOut {
                outcome.failures.append((path, "simctl spawn defaults delete did not finish within \(Int(deleteTimeoutSeconds))s"))
                outcome.failures += domainPaths.dropFirst(index + 1).map { ($0, "not attempted after an earlier timeout") }
                outcome.timedOut = true
                return outcome
            } catch {
                outcome.failures.append((path, "could not run simctl spawn defaults delete: \(error.localizedDescription)"))
                continue
            }
            if insideSandbox, result.status == SandboxBroker.didNotCompleteStatus {
                outcome.failures.append((path, "the sandbox broker did not complete it (exit \(result.status)): \(result.tail)"))
                outcome.failures += domainPaths.dropFirst(index + 1).map { ($0, "not attempted after an earlier timeout") }
                outcome.timedOut = true
                return outcome
            }
            if let detail = failureDetail(status: result.status, tail: result.tail, plist: path + ".plist") {
                outcome.failures.append((path, detail))
            }
        }
        return outcome
    }

    /// 1回の `defaults delete` の結果の判定(nil = 消せた / 消すべき値が無かった)。126 / 127 は値の有無で流さない
    /// (サンドボックスの中では仲介の拒否と時間切れ、外ではシェルの「実行できない / 見つからない」= どちらも撃てていない)
    static func failureDetail(status: Int32, tail: String, plist: String) -> String? {
        if status == SandboxGateway.refusedStatus || status == SandboxBroker.didNotCompleteStatus {
            return "exit \(status) (refused or not completed by the sandbox broker, or not executable): \(tail)"
        }
        if status == 0 || !hasValues(plist: plist) { return nil }
        return "exit \(status): \(tail)"
    }

    /// plist が値を1つ以上持つ dict か(cfprefsd が読み込める形で中身がある)
    static func hasValues(plist: String) -> Bool {
        guard let data = FileManager.default.contents(atPath: plist), !data.isEmpty,
              let object = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else { return false }
        return !object.isEmpty
    }
}
