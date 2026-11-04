// 自分の動き(寄せ・空打ち・覆いを外す送り・キーボードを閉じる・整定の読み直し)の後に、**撃つと決めた要素**を新しい木で引き直す。
// セレクタで引き直すと、序数(`.clickable[1]`)・ワイルドカード(`項目 *`)・型だけのセレクタは「今の木の先頭」を返すので、
// 動いた一覧では別の行になる(E2EX-iOS の無限スクロール: 寄せで上の行が入り、`.clickable[1]` が 19 のセル → 18 のセルに替わって
// 18 を押して ok。OI-167 ①)。ステップが撃つ相手は最初に引いた時点で決まっていて、ツール自身の動きで替えない。
//
// 呼び手は「既に撃つと決めた要素を持っている」経路だけ(まだ見つけていない対象を探す経路 = キーボードを閉じてから探し直す・
// 逆走査は従来どおりセレクタで引く)。

import Foundation

public enum SameTargetResolution {

    /// `original`(`originalElements` の中の要素)と同じ要素を `fresh` から引く。
    /// - 同じ要素の鍵(`key`)が無い(識別できる物が何も無い)ときは従来どおりセレクタで引く
    /// - セレクタの答えが同じ鍵ならそれ(usedFallback も含めて従来と同じ)
    /// - 違えば、同じ鍵の要素を新しい木から引く(複数なら元の中心に最も近いもの)
    /// - 同じ鍵の要素が新しい木に無ければ nil = 呼び手は撃たない(セレクタの答えは別の要素 = 撃つと別の物を押す)
    public static func resolve(step: FlowStep, original: ElementInfo, originalElements: [ElementInfo],
                               in fresh: SnapshotResponse, strictForAssert: Bool = false) -> (ElementInfo, FlowLocator?)? {
        let plain = LocatorResolver.resolve(step: step, in: fresh, strictForAssert: strictForAssert)
        guard let wanted = key(of: original, in: originalElements) else { return plain }
        if let plain, key(of: plain.0, in: fresh.elements) == wanted { return plain }
        let same = fresh.elements.filter { key(of: $0, in: fresh.elements) == wanted }
        guard let nearest = same.min(by: { distance($0, original) < distance($1, original) }) else { return nil }
        return (nearest, plain?.1)
    }

    /// 同じ要素の鍵。identifier → 型 + ラベル → (どちらも無い行のセル)型 + 最初の識別できる子孫の鍵。
    /// ref は木ごとに振り直され、枠は動くので使わない。何も無ければ nil
    static func key(of element: ElementInfo, in elements: [ElementInfo]) -> String? {
        if let own = ownKey(element) { return own }
        guard let inner = LocatorResolver.descendants(of: element, in: elements).lazy.compactMap(ownKey).first else { return nil }
        return "d|\(element.type)|\(inner)"
    }

    private static func ownKey(_ element: ElementInfo) -> String? {
        if let id = element.identifier, !id.isEmpty { return "id|\(id)" }
        if let label = element.label, !label.isEmpty { return "tl|\(element.type)|\(label)" }
        return nil
    }

    private static func distance(_ a: ElementInfo, _ b: ElementInfo) -> Double {
        hypot(a.frame.centerX - b.frame.centerX, a.frame.centerY - b.frame.centerY)
    }
}
