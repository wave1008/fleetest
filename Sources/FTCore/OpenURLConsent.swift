// OpenURLConsent.swift
// openURL(ディープリンク配送)直後に OS が出す初回確認アラートから、確定ボタンの ref を選ぶ
// **純粋ロジックだけ**をここに置く(デバイス呼び出しは BridgeClient.acknowledgeOpenURLConsent が担う)。
//
// 実測(iOS 27 シミュレータ、SpringBoard の確認アラート):
//   [1] alert "“FT E2E RN”で開きますか?"
//   [2]   scrollView scroll
//   [3]     staticText "“FT E2E RN”で開きますか?"
//   [4]   scrollView scroll
//   [5]     button "キャンセル"
//   [6]     button "開く"
// ラベルは端末ロケールで変わるため、ラベル文字列("開きますか?"/"開く")では同定しない。
// 唯一の同定条件はアラートの label に**対象アプリの表示名**が含まれることと、
// ボタンがちょうど2つであること。

import Foundation

public enum OpenURLConsent {
    /// **このアプリの同意のアラート(「“<表示名>”で開きますか?」)が出うる URL か**。出るのは開いた先がこのアプリ = 自分のスキームの
    /// URL だけ(表題は開く先の表示名)。別のアプリ向け(https・`App-prefs:`・他のアプリのスキーム)では探しても当たらず、
    /// 出現待ちと SpringBoard からの張り戻し(開いた先が前面なので 500 まで約 5 秒)を毎回の初回で払っていた(最初の
    /// 別アプリ向けの openURL が 11.7〜15.1 秒)。スキームが分からない(nil)ときは true = 従来どおり試す
    public static func mayAppear(url: String, ownSchemes: Set<String>?) -> Bool {
        guard let scheme = URL(string: url)?.scheme?.lowercased() else { return false }
        guard let ownSchemes else { return true }
        return ownSchemes.contains(scheme)
    }

    /// 条件を満たす確認アラートが見つかったときだけ、確定ボタンの ref を返す。
    /// 満たさなければ nil(**何も押さない** —— 誤爆より取りこぼしを選ぶ)。
    ///
    /// 条件:
    ///   1. `type == "alert"` の要素があること
    ///   2. その `label` が `appDisplayName` を**引用符で囲んだ形**(`“名前”`)で含むこと。
    ///      **素の部分一致にしない** —— 表示名は互いの部分文字列になり得る
    ///      (`FT E2E` ⊂ `FT E2E RN`)。同じスキームを複数アプリが登録している端末では、
    ///      素の contains だと**別アプリの確認を了承してしまう**(E2E で実際に踏んだ)
    ///   3. そのアラートの子孫(`depth` がアラートより深い、次のアラート同格要素までの範囲)に
    ///      `type == "button"` がちょうど2つあること
    ///
    /// 確定ボタンは**ツリー順で最後**のもの(= 実測で右側=確定側。上の実測木の [6] 「開く」)。
    /// キャンセル/確定の2択アラートは XCUITest 側が左→右の出現順でツリーに載せるため、
    /// 先頭が取消・末尾が確定になる(実測で確認済み。type だけでは取消/確定を区別できない)。
    public static func confirmButtonRef(in snapshot: SnapshotResponse, appDisplayName: String) -> Int? {
        guard !appDisplayName.isEmpty else { return nil }
        let elements = snapshot.elements
        for (index, element) in elements.enumerated() {
            // 実測のラベルは `“FT E2E RN”で開きますか?`(表示名は約物の引用符で囲まれる)。
            // 直線引用符の端末も想定して両形を許す
            guard element.type == "alert", let label = element.label,
                  label.contains("“\(appDisplayName)”") || label.contains("\"\(appDisplayName)\"")
            else { continue }
            var buttons: [ElementInfo] = []
            for candidate in elements[(index + 1)...] {
                guard candidate.depth > element.depth else { break }
                if candidate.type == "button" { buttons.append(candidate) }
            }
            guard buttons.count == 2, let confirm = buttons.last else { continue }
            return confirm.ref
        }
        return nil
    }
}
