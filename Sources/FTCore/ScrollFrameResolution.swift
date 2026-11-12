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
}
