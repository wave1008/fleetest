// 操作可能な帯(タブ列・上下のバー)に中心を覆われた対象の「覆われていない見えている部分」の判定(OI-157)。
// 指で触る操作(tap・長押し・doubleTap・holdStart・ドラッグの始点)の DSL 全経路が共有する。
// MCP の ft_tap(ref)は今は警告して中心を撃つ(`occlusionAdvisory` の overlayCovering)ので、この判定を呼ぶ変更は別途。
extension TapTargetGeometry {
    public enum CoveredTouch {
        /// 見えている部分(対象の枠から覆いの枠を引いた残りのうち、床以上で最大のもの)。この中心を押す
        case visiblePart(FTRect, over: ElementInfo)
        /// 残りが床に届かない。`visible` = 残りの最も厚い部分の短辺・`floor` = 換算後の床(木の単位)。撃たない
        case tooThin(visible: Double, floor: Double, over: ElementInfo)
    }

    /// 対象の中心を `overlayCoveringForUncover` が名指す覆いが覆っているときの判断(覆っていなければ nil)。
    /// 残りは上・下・左・右の4片のうち、画面と容器(あれば)で切った後に幅・高さとも床以上のもの。
    /// 床は `minimumVisibleTapExtent` × scale(新しい定数は置かない)。scale・inferring に既定値を置かない = 渡し忘れをコンパイルで止める
    public static func coveredTouch(for element: ElementInfo, in elements: [ElementInfo], screen: FTRect,
                                    inferring: Bool, scale: Double) -> CoveredTouch? {
        guard let over = overlayCoveringForUncover(element, in: elements, screen: screen) else { return nil }
        let floor = minimumVisibleTapExtent * scale
        var area = ScrollGeometry.intersection(element.frame, screen)
        if let a = area, let container = ContainerGeometry.clippingContainer(of: element, in: elements, inferring: inferring) {
            area = ScrollGeometry.intersection(a, container)
        }
        guard let t = area else { return .tooThin(visible: 0, floor: floor, over: over) }
        let o = ScrollGeometry.intersection(t, over.frame)
            ?? FTRect(x: t.x, y: t.y, width: 0, height: 0)
        let tr = t.x + t.width, tb = t.y + t.height
        let or = o.x + o.width, ob = o.y + o.height
        let pieces = [
            FTRect(x: t.x, y: t.y, width: t.width, height: o.y - t.y),
            FTRect(x: t.x, y: ob, width: t.width, height: tb - ob),
            FTRect(x: t.x, y: o.y, width: o.x - t.x, height: o.height),
            FTRect(x: or, y: o.y, width: tr - or, height: o.height),
        ].filter { $0.width > 0 && $0.height > 0 }
        let best = pieces.map { (rect: $0, thickness: min($0.width, $0.height)) }
        if let pick = best.filter({ $0.thickness >= floor })
            .max(by: { $0.rect.width * $0.rect.height < $1.rect.width * $1.rect.height }) {
            return .visiblePart(pick.rect, over: over)
        }
        return .tooThin(visible: best.map(\.thickness).max() ?? 0, floor: floor, over: over)
    }
}
