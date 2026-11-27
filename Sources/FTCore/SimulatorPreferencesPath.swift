// 「このパスは、その容器の設定の置き場(`<容器>/Library/Preferences`)の中の1つのドメインか」の判定の1箇所。
// 呼び手は2つ: シナリオの子の仲介(`SimctlPolicy` の `simctl spawn … defaults delete`)と、消させるドメインを集める側
// (FTBridgeClient の `SimulatorPreferencesFlush.domainPaths`)。**symlink を辿った実体で見る** —— 子は容器の中に書けるので、
// `Library` や `Library/Preferences`・plist を symlink にすると、cfprefsd(ホストの利用者で動く)にホストの設定を消させられる

import Foundation

public enum SimulatorPreferencesPath {
    /// ドメインの名前 = 1つの名前(`/`・制御文字・`.`・`..` を含まない)。アプリや SDK は空白や記号の入った名前でも書く
    public static func isDomainName(_ name: String) -> Bool {
        !name.isEmpty && name != "." && name != ".."
            && !name.unicodeScalars.contains { $0 == "/" || $0.value < 0x20 || $0.value == 0x7f }
    }

    /// `path` = `<container>/Library/Preferences/<ドメイン>` で、`Library` と `Library/Preferences` が実体のまま容器の中にあり、
    /// `<ドメイン>.plist` が symlink でないか
    public static func isDomain(_ path: String, inContainer container: String) -> Bool {
        let preferences = container + "/Library/Preferences"
        let name = (path as NSString).lastPathComponent
        guard isDomainName(name), (path as NSString).deletingLastPathComponent == preferences else { return false }
        guard ScenarioSandbox.canonicalPath(preferences) == ScenarioSandbox.canonicalPath(container) + "/Library/Preferences" else {
            return false
        }
        let plist = path + ".plist"
        if let type = try? FileManager.default.attributesOfItem(atPath: plist)[.type] as? FileAttributeType, type == .typeSymbolicLink {
            return false
        }
        return true
    }
}
