// ScrollFrameResolution.swift
// scrollFrame のロケータを今の木で引く唯一の入口(DSL の探索・scroll 系・MCP の救済が共有する)

import Foundation

public enum ScrollFrameResolution {

    /// scrollFrame の容器。基本は `LocatorResolver.match`(先頭の一致)と同じ。
    /// **例外は1つ**: 添字・相対の無い指定が複数に当たり、先頭が scrollable を申告せず、子孫にも枠の内側にも
    /// scrollable が無い(= 払っても何も動かない)のに、ほかの一致が scrollable を申告しているときは、その先頭を採る。
    /// 実測(Apple マップの経路一覧): `#RoutePlanningOverviewViewController` が pageIndicator(先頭)と scrollView に当たり、
    /// 先頭を払って何も動かなかった。**「重なる scrollable」で除外しない** —— 先頭を包む外側の領域(同じ画面の
    /// `#IOSRoutePlanningOverview`)に当たって変わらなかった(実測)。コーパスで変わる画面は0件。
    /// **scrollable が1つも無い画面では変えない**(申告できないブリッジでは全部 nil で、先頭が動かないとは言えない)。
    /// 先頭も scrollable の重複(Apple マップの `#MUScrollableStackView` ×2)は区別する材料が無いので先頭のまま
    public static func resolve(_ locator: FlowLocator, in snapshot: SnapshotResponse) -> ElementInfo? {
        guard let first = LocatorResolver.match(locator, in: snapshot) else { return nil }
        guard locator.index == nil, locator.relative?.isEmpty ?? true,
              snapshot.elements.contains(where: { $0.scrollable == true }),
              first.scrollable != true,
              !LocatorResolver.descendants(of: first, in: snapshot.elements).contains(where: { $0.scrollable == true }),
              !snapshot.elements.contains(where: {
                  $0.ref != first.ref && $0.scrollable == true && first.frame.contains($0.frame)
              }),
              let scrollable = (LocatorResolver.candidates(locator, elements: snapshot.elements) ?? [])
                  .first(where: { $0.scrollable == true })
        else { return first }
        return scrollable
    }

    /// 先頭を飛ばして採ったときの言い方(DSL の注記と MCP のヒントが共有する)。position は候補列の 0 始まり・文言は DSL の `[n]` と同じ 1 始まり
    public static func skippedFirstPhrase(_ position: Int) -> String {
        "match [\(position + 1)] (the first that scrolls — the first match does not scroll)"
    }

    /// scrollFrame に渡された要素が**自身はスクロールを申告せず**、申告した容器の中の行のとき、払う場所にすべき容器。
    /// 行は中身と一緒に動くので、行の枠で払うと回を重ねるごとに細く・画面の外へずれ「何も動かなかった」へ落ちる。
    /// 木で最も近い祖先を優先し(枠が行を収めるときだけ)、無ければ行を収める最小の申告容器。
    /// **要素が scrollable・申告した容器が収めない・子孫に scrollable がある(`resolve` の領分)ときは nil = 従来どおり**
    /// (Android の申告の無い一覧を変えない)。DSL の探索と MCP の ref 解決が共有する。
    /// **容器が払う向き(`vertical`)に行より長いときだけ**切り替える: 申告の無い横の列(CMP iOS のタブ列 `#stab_row`)は縦の一覧の
    /// 中にあり、縦の一覧へ切り替えると横に払えなかった(回帰で実測)。行の向きの長さは容器と同じなので外れる
    /// **要素の中身が枠の外へ続く(行が縁を跨ぐ・はみ出す)なら切り替えない** —— それは行ではなく申告の無い一覧(XCUITest の木の
    /// CMP の `#list_rows` / `#list_chat` は scrollable を申告せず、行が枠の外へはみ出す)。切り替えると画面全体の容器を払い「何も動かなかった」で赤になった(回帰で実測)。
    /// **容器は払う向きへ動くと言えるものだけ**: 向きの申告が払う軸と違う側だけなら外し、横は申告か子の横の並びがあるときだけ(DR-190 と同じ。
    /// 画面全体の縦の容器へ横のページャ `#pager_main` を切り替え、横に払えなかった)
    public static func enclosingScrollable(of element: ElementInfo, in elements: [ElementInfo], vertical: Bool) -> ElementInfo? {
        guard element.scrollable != true,
              !LocatorResolver.descendants(of: element, in: elements).contains(where: { $0.scrollable == true }),
              !ViewportCount.contentContinuesPastEdge(of: element, in: elements) else { return nil }
        func holds(_ c: ElementInfo) -> Bool {
            guard c.ref != element.ref, c.scrollable == true, c.frame.width > 0, c.frame.height > 0,
                  c.frame.contains(element.frame),
                  vertical ? c.frame.height > element.frame.height + 1 : c.frame.width > element.frame.width + 1,
                  !ScrollActionsAxis.declaresOnlyOtherAxis(c.scrollActions, vertical: vertical) else { return false }
            if !vertical, !ScrollActionsAxis.declares(c.scrollActions, vertical: false),
               ContainerGeometry.childrenFlow(of: c, in: elements) != .alongX { return false }
            return true
        }
        if let index = elements.firstIndex(where: { $0.ref == element.ref }),
           let ancestor = ContainerGeometry.nearestScrollableAncestor(of: element, at: index, in: elements),
           holds(ancestor) { return ancestor }
        return elements.filter(holds).min { $0.frame.width * $0.frame.height < $1.frame.width * $1.frame.height }
    }

    /// 注記の見分けの鍵(`StepExecutor.scrollFrameSwitchNote` が読む)
    static let enclosingScrollableMarker = "is a row inside a scroll container"

    /// `enclosingScrollable` へ切り替えたときの注記(DSL と MCP が共有)
    public static func enclosingScrollableNote(frame: String, container: ElementInfo) -> String {
        "scrollFrame \(frame) " + enclosingScrollableMarker + ", which moves with the content — searched inside the container"
            + " [\(container.ref)] instead"
    }
}
