// 塗り順 `z` の無い木(iOS の SwiftUI・CMP・Flutter)で「別の層に覆われているかもしれない」対象を拾う粗い門。
// 呼び手(DSL の `coveredTouchPlan`・MCP の ref 経路)は、この門が要素を返したときだけ XCUITest の `isHittable` を聞き、
// false と答えたときだけ撃たずに断る。文言は呼び手ごと(判定だけ共有)。
extension TapTargetGeometry {
    /// 対象の中心に重なる押せる要素のうち、**対象とは別のスクロール容器の中身**であるもの(複数なら木の順で最初)。無ければ nil。
    /// 粗い門であって断定ではない: 手前かどうかは木から決められない(`PaintOrder` の無い木)ので、断るかどうかは
    /// プラットフォームの答え(`isHittable`)で決める。**使うのは false だけ、true は使わない** —— false は半分のシートの裏の行・
    /// 隠れたバーのボタン・縮んだヘッダの裏の行で正しかったが、SwiftUI で送って戻した FAB で誤った(本物のタッチは届く)ので、
    /// in-app で聞けるときは `touchClearsCovers` で確かめる。true は誤ることがある
    /// (SwiftUI の半分のシートの裏の行は全部 true・CMP の縮んだヘッダでナビゲーションバーの裏のボタンが true)。
    /// 「別のスクロール容器」の条件を外すと実アプリの木で発火が約3倍になる(同じ一覧の中の行どうしの重なりまで拾う)ので必須。
    public static func otherLayerCoverSuspect(_ element: ElementInfo, in elements: [ElementInfo],
                                              screen: FTRect) -> ElementInfo? {
        otherLayerCoverCandidates(element, in: elements, screen: screen).first
    }

    /// `otherLayerCoverSuspect` の候補の全部(木の順)。`touchClearsCovers` で「どれにも届かない」を確かめるのに使う
    public static func otherLayerCoverCandidates(_ element: ElementInfo, in elements: [ElementInfo],
                                                 screen: FTRect) -> [ElementInfo] {
        guard elements.allSatisfy({ $0.z == nil }) else { return [] }
        let cx = element.frame.centerX
        let cy = element.frame.centerY
        guard isPointOnScreen(x: cx, y: cy, screen: screen) else { return [] }
        let lineage = lineage(of: element, in: elements)
        let targetScroller = innermostScrollableAncestor(of: element, in: elements)
        var found: [ElementInfo] = []
        for other in elements {
            guard other.ref != element.ref, !lineage.contains(other.ref),
                  BridgeSnapshotThinning.operableTypes.contains(other.type),
                  pointInside(cx, cy, other.frame),
                  !contains(other.frame, element.frame),
                  !contains(element.frame, other.frame),
                  !ContainerGeometry.isOutsideContainer(other, in: elements, screen: screen)
            else { continue }
            let otherScroller = innermostScrollableAncestor(of: other, in: elements)
            if otherScroller?.ref != targetScroller?.ref { found.append(other) }
        }
        return found
    }

    /// `isHittable` が false と答えた対象を、本物のタッチの当たり判定(in-app の `/touchlands`)で撃ってよいと言えるか。
    /// 言えるのは **全部の view を引けて、タッチが対象に届き、覆いの候補のどれにも届かない** ときだけ(nil・1つでも不明は false)。
    /// 自前描画(Flutter・CMP)は全要素が同じ view なので覆いにも「届く」= 常に false(断りのまま)。
    /// 実測: SwiftUI で送って戻した FAB の中心は対象だけに届き、隠れたバーの下の行は対象に届かない
    public static func touchClearsCovers(_ answer: TouchLandsResponse?, target: Int, covers: [Int]) -> Bool {
        guard let answer, answer.unresolved.isEmpty, !covers.isEmpty, answer.lands.contains(target) else { return false }
        return covers.allSatisfy { !answer.lands.contains($0) }
    }

    private static func innermostScrollableAncestor(of element: ElementInfo, in elements: [ElementInfo]) -> ElementInfo? {
        ancestors(of: element, in: elements).first { $0.scrollable == true }
    }

    private static func pointInside(_ x: Double, _ y: Double, _ frame: FTRect) -> Bool {
        x >= frame.x && x < frame.x + frame.width && y >= frame.y && y < frame.y + frame.height
    }
}
