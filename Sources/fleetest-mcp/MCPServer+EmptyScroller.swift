import FTCore
import Foundation

extension MCPServer {
    /// `looksUnchanged` では拾えない「まだ読み込み中」の形を1つだけ足す(監査)。
    /// 実測(Google マップ・経路検索): 出発地/目的地を確定した直後の snapshotAfter は
    /// `#expandingscrollview_container` が**子ゼロ**のまま返り、経路一覧は次の ft_snapshot で
    /// 初めて出た —— 木そのものは前の画面から大きく変わっているので、既存の settle-lite
    /// (操作前と見分けが付かないときだけ待つ)は構造上まったく発火しない。
    ///
    /// **誤発火を避けるための3条件**:
    /// - `scrollable` 申告がある容器だけ(true を見つけたときだけ使ってよい。ElementInfo の宣言参照)
    /// - **画面の3割以上の高さ**を占める容器だけ(小さな横カルーセルの空は正常なことがある)
    /// - 子が**1つも無い**(preorder で depth が大きい後続要素が0件)—— 1件でも入っていれば
    ///   「描画は始まっている」ので待たない
    ///
    /// 空のリストは正当にも存在する(検索結果0件)ので、**これを根拠に throw も再試行もしない** ——
    /// 呼び手が払うのは settle-lite と同じ1回きりの短い待ちだけ
    static func emptyLoadingScroller(in snapshot: SnapshotResponse) -> ElementInfo? {
        let screenHeight = snapshot.screen.height
        guard screenHeight > 0 else { return nil }
        let elements = snapshot.elements
        for (index, element) in elements.enumerated() {
            guard element.scrollable == true,
                  element.frame.height >= screenHeight * emptyScrollerScreenRatio else { continue }
            let hasChild = elements[(index + 1)...].prefix { $0.depth > element.depth }.isEmpty == false
            // Flutter は中身を容器の子でなく兄弟で返す = 枠の中に中心のある小さな要素があれば空と言わない(OI-282 ⑥)
            let box = element.frame
            let hasContentInside = elements.contains { other in
                other.ref != element.ref && other.frame.width * other.frame.height < box.width * box.height
                    && box.contains(FTRect(x: other.frame.centerX, y: other.frame.centerY, width: 0, height: 0))
            }
            if !hasChild, !hasContentInside { return element }
        }
        return nil
    }

    /// `emptyLoadingScroller` が見る容器の最小の高さ(画面比)。小さな帯(フィルタの横並び等)の
    /// 空は正常なので、**画面の主役になる大きさ**だけを読み込み中の候補にする
    static let emptyScrollerScreenRatio = 0.3
}
