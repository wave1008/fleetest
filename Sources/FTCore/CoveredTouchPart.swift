// 操作可能な帯(タブ列・上下のバー)に中心を覆われた対象の「覆われていない見えている部分」の判定。
// 指で触る操作(tap・長押し・doubleTap・holdStart・ドラッグの始点)の DSL 全経路が共有する。
// MCP の ref 経路(ft_tap・ft_long_press・ft_double_tap・ft_drag の fromRef = `MCPServer.coveredRefTouch`)も同じ判定を呼ぶ(文言だけ呼び手ごと)。
// ft_batch の行は StepExecutor を通るので DSL と同じ。ライブ操作は座標だけで ref を撃たない。
extension TapTargetGeometry {
    public enum CoveredTouch {
        /// 見えている部分(対象の枠から覆いの枠を引いた残りのうち、床以上で最大のもの)。この中心を押す
        case visiblePart(FTRect, over: ElementInfo)
        /// 残りが床に届かない。`visible` = 残りの最も厚い部分の短辺・`floor` = 換算後の床(木の単位)。撃たない
        case tooThin(visible: Double, floor: Double, over: ElementInfo)
    }

    /// 対象の中心を `overlayCoveringForUncover` が名指す覆いが覆っているときの判断(覆っていなければ nil)。
    /// 残りは対象の枠を画面と容器(あれば)で切り、手前の押せる覆いを全部引いた片のうち、幅・高さとも床以上で最大のもの。
    /// 床は `minimumVisibleTapExtent` × scale(新しい定数は置かない)。scale・inferring に既定値を置かない = 渡し忘れをコンパイルで止める
    /// `zIsPaintOrder`: 木の z が本物の塗り順か(iOS の in-app = UIKit・RN のときだけ送る = true。Android は z を必ず送るが、
    /// Flutter・Compose のように1枚の描画面で描くアプリでは木の順と同じで塗り順ではない = false)。既定値を置かない
    public static func coveredTouch(for element: ElementInfo, in elements: [ElementInfo], screen: FTRect,
                                    inferring: Bool, scale: Double, zIsPaintOrder: Bool) -> CoveredTouch? {
        guard let over = overlayCoveringForUncover(element, in: elements, screen: screen) else { return nil }
        // 次の3形は nil = 呼び手の従来の扱い(警告して中心を撃つ)。断ると押せる対象を押さなくなる(回帰で実際に赤):
        // ⓪覆い(中心の最前面)が押せる型でない: 防ぐ害は「別の押せる部品(タブ)に当たる」こと。背景・装飾・行の文字なら中心を
        //   撃っても別の部品は押さず、塗り順の推測違い(見出しの容器が中の文字を覆うと読む)で断ると誤った赤になる。
        //   **最前面を押せる祖先へ持ち上げない**: 祖先は preorder+depth の復元で、行の中の文字が行(cell)へ上がって浮いたボタンを
        //   断る・対象を包む祖先が対象を丸ごと引く・平たい木で無関係のボタンを祖先と読む(タブの中の文字が最前面の形は従来の扱い)
        guard BridgeSnapshotThinning.operableTypes.contains(over.type) else { return nil }
        let targetLineage = TapTargetGeometry.lineage(of: element, in: elements)
        // ①対象が押せる型でなく、覆いが入力欄: 手前の入力欄こそが受け手(OTP の箱の上に重ねた透明な入力欄)。型だけで外すと、
        //   クリックを付けた Android の TextView の行(木では staticText)を外して下のバーのボタンを押した
        if !BridgeSnapshotThinning.operableTypes.contains(element.type),
           SnapshotRenderer.textInputTypes.contains(over.type) { return nil }
        // ②覆いが、対象の祖先でないスクロール容器の中身: 塗り順は木の順の推測でしかなく、一覧の上に浮いたボタン(FAB・
        //   「一番下へ」)を行が覆っていると読み違える(Flutter の Android は描画順を申告しない = z が木の順)。
        //   **z が本物の塗り順で両方にあればこの例外を使わない**(RN の iOS の in-app: 半分のシートのキューの行が裏の本文の行を
        //   覆うのに中心を撃ち、キューの行を押して ok だった)。Android の z は本物とは限らない(Flutter の FAB を行が覆うと読んで断った)
        let targetAncestors = Set(ancestors(of: element, in: elements).map(\.ref))
        if !(zIsPaintOrder && over.z != nil && element.z != nil),
           ancestors(of: over, in: elements).contains(where: { $0.scrollable == true && !targetAncestors.contains($0.ref) }) {
            return nil
        }
        let floor = minimumVisibleTapExtent * scale
        var area = ScrollGeometry.intersection(element.frame, screen)
        if let a = area, let container = ContainerGeometry.clippingContainer(of: element, in: elements, inferring: inferring) {
            area = ScrollGeometry.intersection(a, container)
        }
        guard let t = area else { return .tooThin(visible: 0, floor: floor, over: over) }
        // 中心を覆う1つだけでなく、手前に描かれて対象に掛かる要素を全部引く。1つだけ引くと、残りの片が隣のタブの下に
        // 落ちて隣のタブを押した(実測・Flutter の横向き: 欄の左の片が #tab_home の下 = ホームへ遷移)。
        // 対象を丸ごと包む相手はラッパーなので引かない(引くと何でも「薄い」になる)。スクロール容器・容器の外の残像も覆わない。
        // 引くのは押せる型だけ(⓪と同じ理由 = 押せない覆いの上を押しても別の部品には当たらない)
        let covers = [over] + elements.filter { other in
            other.ref != over.ref && other.ref != element.ref && !targetLineage.contains(other.ref)
                && BridgeSnapshotThinning.operableTypes.contains(other.type)
                && other.scrollable != true
                && PaintOrder.drawnAbove(other, element)
                && !TapTargetGeometry.contains(other.frame, element.frame)
                && ScrollGeometry.intersection(other.frame, t) != nil
                && !ContainerGeometry.isOutsideContainer(other, in: elements, screen: screen)
        }
        var pieces = [t]
        for cover in covers {
            pieces = pieces.flatMap { subtract(cover.frame, from: $0) }
        }
        let best = pieces.map { (rect: $0, thickness: min($0.width, $0.height)) }
        if let pick = best.filter({ $0.thickness >= floor })
            .max(by: { $0.rect.width * $0.rect.height < $1.rect.width * $1.rect.height }) {
            return .visiblePart(pick.rect, over: over)
        }
        return .tooThin(visible: best.map(\.thickness).max() ?? 0, floor: floor, over: over)
    }

    /// `rect` から `hole` を引いた残り(上・下・左・右の最大4片。重ならなければ `rect` そのもの)
    static func subtract(_ hole: FTRect, from rect: FTRect) -> [FTRect] {
        guard let o = ScrollGeometry.intersection(rect, hole), o.width > 0, o.height > 0 else { return [rect] }
        let rr = rect.x + rect.width, rb = rect.y + rect.height
        let or = o.x + o.width, ob = o.y + o.height
        return [
            FTRect(x: rect.x, y: rect.y, width: rect.width, height: o.y - rect.y),
            FTRect(x: rect.x, y: ob, width: rect.width, height: rb - ob),
            FTRect(x: rect.x, y: o.y, width: o.x - rect.x, height: o.height),
            FTRect(x: or, y: o.y, width: rr - or, height: o.height),
        ].filter { $0.width > 0 && $0.height > 0 }
    }
}
