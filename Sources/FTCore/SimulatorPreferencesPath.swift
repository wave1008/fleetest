// 「このパスは、その容器の設定の置き場(`<容器>/Library/Preferences` と その `ByHost`)の中の1つのドメインか」の判定の1箇所。
// 呼び手は2つ: シナリオの子の仲介(`SimctlPolicy` の `simctl spawn … defaults delete`)と、消させるドメインを集める側
// (FTBridgeClient の `SimulatorPreferencesFlush.domainPaths`)。**symlink を辿った実体で見る** —— `Library` や `Library/Preferences`・
// plist が symlink だと、cfprefsd(ホストの利用者で動く)が先のホストの設定に作用する(子の枠は容器の中に symlink を作らせない =
// `ScenarioSandbox.profile`。これはその二重の守り)

import Foundation

public enum SimulatorPreferencesPath {
    /// ドメインの名前 = 1つの名前(`/`・制御文字・`.`・`..` を含まない)。アプリや SDK は空白や記号の入った名前でも書く
    public static func isDomainName(_ name: String) -> Bool {
        !name.isEmpty && name != "." && name != ".."
            && !name.unicodeScalars.contains { $0 == "/" || $0.value < 0x20 || $0.value == 0x7f }
    }

    /// 絶対パスで、`.`・`..`・空の要素(`//`)を含まないか。**判定は実体で見るが、撃つのは渡された文字列のまま** —— 正規化は `..` を
    /// 文字の上で畳んでから実体を見るので、symlink と `..` を組み合わせると判定と実際の行き先が食い違う(仲介をすり抜けてホストの設定に届く)
    public static func hasOnlyPlainComponents(_ path: String) -> Bool {
        guard path.hasPrefix("/") else { return false }
        return !path.dropFirst().split(separator: "/", omittingEmptySubsequences: false).contains { $0.isEmpty || $0 == "." || $0 == ".." }
    }

    /// 設定の置き場(`Library/Preferences` と `Library/Preferences/ByHost`)が実体のまま容器の中にあるか
    public static func preferencesDirectoryIsInside(_ directory: String, container: String) -> Bool {
        guard hasOnlyPlainComponents(directory), hasOnlyPlainComponents(container) else { return false }
        let real = ScenarioSandbox.canonicalPath(container)
        let expected = [real + "/Library/Preferences", real + "/Library/Preferences/ByHost"]
        guard [container + "/Library/Preferences", container + "/Library/Preferences/ByHost"].contains(directory) else { return false }
        return expected.contains(ScenarioSandbox.canonicalPath(directory))
    }

    /// `path` = `<container>/Library/Preferences[/ByHost]/<ドメイン>` で、置き場が実体のまま容器の中にあり、
    /// `<ドメイン>` も `<ドメイン>.plist` も symlink でないか。**両方を見る** —— `defaults delete` は拡張子を省いても付けても
    /// 同じファイルを指すので、`x.plist` を渡されたら `x.plist` そのもの(symlink でありうる)に作用する
    public static func isDomain(_ path: String, inContainer container: String) -> Bool {
        let name = (path as NSString).lastPathComponent
        guard isDomainName(name),
              preferencesDirectoryIsInside((path as NSString).deletingLastPathComponent, container: container) else { return false }
        return !isSymlink(path) && !isSymlink(path + ".plist")
    }

    /// `attributesOfItem` は最後の symlink を辿らない
    public static func isSymlink(_ path: String) -> Bool {
        (try? FileManager.default.attributesOfItem(atPath: path)[.type] as? FileAttributeType) == .typeSymbolicLink
    }
}
