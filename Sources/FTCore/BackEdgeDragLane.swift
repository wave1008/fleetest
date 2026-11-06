// back() の左端エッジスワイプの高さを決める。interactive pop が成立しない画面では同じタッチが道筋の下の要素へ渡り、
// 高さの真ん中に固定していた頃は SwiftUI の画面で道筋が横切るボタン(送信・モーダルを出すボタン)が押されて ✅ だった
// (26周目 iultra F1/F2: 6/6・back を wait に替えた対照は 0/6。始点 x=1 はボタンの外 = 押下になる仕組みは材料不足)。
// 道筋(x: fromX〜toX)が押せる要素の枠を横切らない高さを、真ん中から外へ順に探す。空きが無ければ真ん中のまま(従来どおり)

import Foundation

public enum BackEdgeDragLane {
    /// 試す高さ(画面の高さに対する比)。interactive pop は高さに依らず成立するので、真ん中から外へ 5% ずつ。
    /// 上下 25% は外す(ナビゲーションバー・タブバー・ホームインジケータの帯 = 別の身振りに取られる)
    static let fractions: [Double] = [0.5, 0.45, 0.55, 0.4, 0.6, 0.35, 0.65, 0.3, 0.7, 0.25, 0.75]
    /// 指の当たりの余白(pt)。枠の上下にこれだけ離れていない高さは「横切る」とみなす
    static let fingerSlop: Double = 8

    public static func y(elements: [ElementInfo], screen: FTRect, fromX: Double, toX: Double) -> Double {
        let operable = elements.filter { KeyboardDismissPoint.unsafeTypes.contains($0.type) }
        for fraction in fractions {
            let y = screen.y + screen.height * fraction
            let crosses = operable.contains { element in
                let f = element.frame
                guard f.width > 0, f.height > 0 else { return false }
                let vertical = y >= f.y - fingerSlop && y <= f.y + f.height + fingerSlop
                let horizontal = f.x < toX && f.x + f.width > fromX
                return vertical && horizontal
            }
            if !crosses { return y }
        }
        return screen.y + screen.height * 0.5
    }
}
