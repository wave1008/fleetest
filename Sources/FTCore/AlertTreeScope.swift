// アラートが前面にある間の木の範囲。**MCP(snapshotBody)と DSL(失敗レポートの要素一覧)が共有する**(ユーザー決定:
// アラートの間の背面の木は押せない要素の一覧で、読み手はそこから次の手や原因を探してしまう)。
// システムアラート(SpringBoard)は木に載らないので呼び手が照会で知り、木を丸ごと伏せる。
// アプリ内のアラート(木の中の alert)はここで見つけ、その部分木だけを残す。

import Foundation

public enum AlertTreeScope {

    /// アプリの木の中の alert。いちばん手前 = 木の順で最後の1つ。**画面に描かれているものだけ**(枠が0・画面の外の
    /// alert は閉じた後の残りかもしれない。それで木を伏せると、読み手には押しても何も起きないアラートだけの画面が見え続ける)
    public static func frontInAppAlert(in snapshot: SnapshotResponse) -> ElementInfo? {
        front(of: ["alert"], in: snapshot)
    }

    /// 手前の alert と手前のアクションシート(`sheet` = UIAlertController の actionSheet)を**別々に**(在るものだけ)。
    /// **`/hittable` が中のボタンを引き当てない面の判定だけに使う**(カレンダーの削除確認シートで押せば届くのに引き当てられなかった)。
    /// 型ごとに取る = 両方が描かれているとき、木の順で後ろの片方だけを見ると、もう片方のボタンが除外から外れる。
    /// 閉じた後の古い面が新しい画面の裏に残っている形は見分けられない(塗り順が木に無い)。木を伏せる・ボタンを並べる側は alert のまま
    public static func frontInAppAlertAndActionSheet(in snapshot: SnapshotResponse) -> [ElementInfo] {
        [front(of: ["alert"], in: snapshot), front(of: ["sheet"], in: snapshot)].compactMap { $0 }
    }

    private static func front(of types: Set<String>, in snapshot: SnapshotResponse) -> ElementInfo? {
        snapshot.elements.last {
            types.contains(ElementInfo.normalizedType($0.type)) && $0.frame.width > 0 && $0.frame.height > 0
                && ScrollGeometry.intersection($0.frame, snapshot.screen) != nil
        }
    }

    /// アラートとその子孫だけの木(ref・枠はそのまま = 一覧の ref でそのまま押せる)
    public static func alertOnly(_ alert: ElementInfo, in snapshot: SnapshotResponse) -> SnapshotResponse {
        var only = snapshot
        only.elements = [alert] + subtree(of: alert, in: snapshot)
        return only
    }

    /// アラートの子孫のうち同じ窓の行。**オーバーレイの窓の行は深さでは見分けられず部分木に並ぶ**(`inOverlayWindow` の違いで外す)
    private static func subtree(of alert: ElementInfo, in snapshot: SnapshotResponse) -> [ElementInfo] {
        LocatorResolver.descendants(of: alert, in: snapshot.elements)
            .filter { ($0.inOverlayWindow == true) == (alert.inOverlayWindow == true) }
    }

    /// アラートの中の押せる要素のラベル(注記に並べる)。**アラートの枠に収まるものだけ** —— 入力欄つきの
    /// アラートではキーボード(予測変換の候補)が部分木に入り、ボタンとして並んでしまう
    public static func buttonLabels(of alert: ElementInfo, in snapshot: SnapshotResponse) -> [String] {
        buttonElements(of: alert, in: snapshot).compactMap { $0.label.map(SnapshotRenderer.displayText) }
    }

    /// `buttonLabels` と同じ集合の要素(ref つきで案内するため。ラベルとの対応が崩れないよう定義を1つにする)
    public static func buttonElements(of alert: ElementInfo, in snapshot: SnapshotResponse) -> [ElementInfo] {
        subtree(of: alert, in: snapshot)
            .filter { BridgeSnapshotThinning.operableTypes.contains($0.type) }
            .filter { TapTargetGeometry.contains(alert.frame, $0.frame) }
            .filter { $0.label.map(SnapshotRenderer.displayText).map { !$0.isEmpty } ?? false }
    }
}
