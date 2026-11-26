// 覆いの相手を名指してよいか(DR-230)。名指す文言を出す出口(注記・失敗の文言・失敗後の案内・見本保存の断り・残像の警告)だけが
// 呼ぶ。判定(幾何・疑い・FM へ回す門)と撃ち方には使わない。

import Foundation

public enum OccluderNaming {
    /// 名指してよいか。偽は Android で、アプリが `.flutter` と分かっていて、かつ `inOverlayWindow` が同じ組だけ。
    /// - Android の Flutter は z が木の順で塗り順ではない(DR-230)ので、同じウィンドウの中の「手前」は根拠にならない。
    /// - `.compose` は「Compose を含む」の意味で View/XML のアプリも入るので含めない。
    /// - 別ウィンドウの組はウィンドウの順位が z に入る = 本物の塗り順なので名指す(`inOverlayWindow` は true のときだけ届く欄)。
    /// - 両方にブリッジの申告(renderer)があれば申告で決める(アプリの答えへ落とさない): 偽は両方 `virtual` で `renderHost` が
    ///   同じ(同じ仮想の土台の中どうし)ときだけ。`renderHost` が片方でも欠ければ申告の無い組として下のアプリの枝へ。
    public static func mayName(occluder: ElementInfo, target: ElementInfo,
                               isAndroid: Bool, framework: AppUIFramework?) -> Bool {
        if isAndroid, let o = occluder.renderer, let t = target.renderer {
            if o == "virtual", t == "virtual", let oh = occluder.renderHost, let th = target.renderHost {
                return oh != th
            }
            if !(o == "virtual" && t == "virtual") { return true }
        }
        return !(isAndroid && framework == .flutter
          && ((occluder.inOverlayWindow == true) == (target.inOverlayWindow == true)))
    }
}

/// 出口へ渡す「名指し」の材料(OS とアプリの答え・アプリの VM サービスの塗り順)。**既定値を置かない** —— 呼び忘れをコンパイルで止める。
public struct OccluderNamingContext: Equatable, Sendable {
    public let isAndroid: Bool
    public let framework: AppUIFramework?
    /// `OccluderNaming.mayName` が偽の組だけに効く塗り順(DR-235)。nil = 取っていない・取れなかった(DR-230 のまま)
    public let paintRanks: PaintRankAnswer?
    /// 常に名指す。`advisoryKind` を撃ち方(`overlayCoveringForUncover` 等)に使う呼び手と、名指しを抑える理由が無い呼び手用
    public static let alwaysName = OccluderNamingContext(isAndroid: false, framework: nil, paintRanks: nil)

    public init(isAndroid: Bool, framework: AppUIFramework?, paintRanks: PaintRankAnswer?) {
        self.isAndroid = isAndroid
        self.framework = framework
        self.paintRanks = paintRanks
    }

    /// OS だけ差し替えた文脈(アプリの答えと塗り順は保つ)
    public func withOS(isAndroid: Bool) -> OccluderNamingContext {
        OccluderNamingContext(isAndroid: isAndroid, framework: framework, paintRanks: paintRanks)
    }

    /// 今の規則(`OccluderNaming.mayName`)が偽の組は、塗り順が「覆いが手前」と答えたときだけ名指す
    public func mayName(_ occluder: ElementInfo, _ target: ElementInfo) -> Bool {
        if OccluderNaming.mayName(occluder: occluder, target: target, isAndroid: isAndroid, framework: framework) { return true }
        return paintRanks?.inFront(occluder, of: target) == true
    }

    /// 今の規則では名指せない組で、塗り順が「覆いは対象より奥」と答えた = 覆いの疑い自体が当たらない(注意も出さない。範囲を狭める向き)
    public func answeredBehind(_ occluder: ElementInfo, _ target: ElementInfo) -> Bool {
        guard !OccluderNaming.mayName(occluder: occluder, target: target, isAndroid: isAndroid, framework: framework) else { return false }
        return paintRanks?.inFront(occluder, of: target) == false
    }

    /// 今の規則では名指せない組で、名指しを塗り順で決めた(手前でも奥でも)
    public func decidedByPaintRanks(_ occluder: ElementInfo, _ target: ElementInfo) -> Bool {
        guard !OccluderNaming.mayName(occluder: occluder, target: target, isAndroid: isAndroid, framework: framework) else { return false }
        return paintRanks?.inFront(occluder, of: target) != nil
    }
}

public enum DescriptionHoldsDrawnText {
    /// 描いた文字を説明(contentDescription)に入れる作りか。nil = 分からない。
    /// 申告(renderer)が `view` / `compose` なら false(描いた文字は説明に入れない)。`web` / `virtual` / 無しはアプリの答え。
    public static func answer(element: ElementInfo, framework: AppUIFramework?) -> Bool? {
        if element.renderer == "view" || element.renderer == "compose" { return false }
        guard let framework else { return nil }
        return framework == .flutter
    }
}

/// ブリッジの申告(`ElementInfo.renderer`)を読む側の述語。
public enum ElementRenderer {
    /// 木のどれかが Compose の要素か(申告があるときだけ true。申告が無ければ false = 分からない)
    public static func containsCompose(_ elements: [ElementInfo]) -> Bool {
        elements.contains { $0.renderer == "compose" }
    }
}
