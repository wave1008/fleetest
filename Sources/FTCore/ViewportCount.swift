// countIs の件数が画面の大きさ・向きで変わる形の判定(DR-204)。**判定は変えず注記だけ**(幾何からの疑いであって、
// 数えた物が全部画面に収まる正当な数え方もある)。MCP の ft_batch と DSL が StepExecutor を通して共有する

public enum ViewportCount {

    /// 一致した要素のどれかが、中身が枠の外へ続いているスクロール容器の中にあるか。
    /// 「続いている」= 容器の中の要素(容器より小さい)のどれかが、容器の縁を跨ぐか外にはみ出している(次の行が半分見えている等)。
    /// このとき見えている件数は画面の高さ・向きで変わる(横向きの実機で作った countIs が縦の Emulator で 3 になった = シナリオ作成の評価)
    public static func dependsOnViewport(matches: [ElementInfo], in elements: [ElementInfo]) -> Bool {
        let scrollers = elements.filter { $0.scrollable == true && $0.frame.width > 0 && $0.frame.height > 0 }
        guard !matches.isEmpty, !scrollers.isEmpty else { return false }
        for match in matches {
            let centre = FTRect(x: match.frame.centerX, y: match.frame.centerY, width: 0, height: 0)
            guard let container = scrollers
                .filter({ $0.ref != match.ref && $0.frame.contains(centre) })
                .min(by: { $0.frame.width * $0.frame.height < $1.frame.width * $1.frame.height }) else { continue }
            // Android の木は切れた行を見えている部分だけの枠で申告する(縁を跨がない)ので、幾何だけでは続きが見えない。
            // 容器自身の申告(いま動かせる向き。空 = 動けない・nil = 申告なし = iOS)が空でなければ中身は枠の外へ続いている
            if let actions = container.scrollActions, !actions.isEmpty { return true }
            if contentContinuesPastEdge(of: container, in: elements) { return true }
        }
        return false
    }

    /// 容器より小さい要素のうち、容器と重なりつつ縁を跨ぐ・はみ出す物があるか(縦は上下・横は左右)
    static func contentContinuesPastEdge(of container: ElementInfo, in elements: [ElementInfo]) -> Bool {
        let c = container.frame
        let slack = 1.0
        return elements.contains { e in
            guard e.ref != container.ref, e.frame.width > 0, e.frame.height > 0 else { return false }
            let f = e.frame
            // 容器を覆う祖先・兄弟(容器以上の大きさ)は中身ではない
            guard f.width * f.height < c.width * c.height else { return false }
            let overlapsX = f.x < c.x + c.width && f.x + f.width > c.x
            let overlapsY = f.y < c.y + c.height && f.y + f.height > c.y
            guard overlapsX, overlapsY else { return false }
            let insideX = f.x >= c.x - slack && f.x + f.width <= c.x + c.width + slack
            let insideY = f.y >= c.y - slack && f.y + f.height <= c.y + c.height + slack
            // 縦に跨ぐ(左右は容器の中)か、横に跨ぐ(上下は容器の中)
            return (insideX && !insideY && f.height < c.height) || (insideY && !insideX && f.width < c.width)
        }
    }
}
