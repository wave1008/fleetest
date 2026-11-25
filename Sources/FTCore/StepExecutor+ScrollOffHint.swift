import Foundation

// 見つからない操作の失敗文に足す「送れば出るかも」の案内(`scrollOffHint`)と、その前提の判定
extension StepExecutor {
    /// **中身が容器に収まっている一覧には案内しない**: 送っても新しい物は出ない(メモの空のフォルダで従っても直らない案内だった)。
    /// 送れる中身があるかは、容器の枠をはみ出す要素が木に居るか(隠れるバーの画面の一覧は上下の行が容器の縁を越える・
    /// 収まったホームの一覧は越えない)。端の行がちょうど縁で揃って次の行が木に無い形は見逃す(案内が出ないだけ)
    static func scrollOffHint(_ step: FlowStep, in snapshot: SnapshotResponse) -> String {
        guard step.direction == nil else { return "" }
        return verticalScrollOffHint(step, in: snapshot) + horizontalShelfHint(step, in: snapshot)
    }

    private static func verticalScrollOffHint(_ step: FlowStep, in snapshot: SnapshotResponse) -> String {
        guard let container = TapTargetGeometry.primaryScrollContainer(in: snapshot.elements, screen: snapshot.screen),
              Self.contentOverflows(container, in: snapshot.elements) else { return "" }
        let why = ". If it is off the screen or was hidden by scrolling (for example a bar that hides while the list scrolls),"
        if coveredTouchAcceptsScroll(step.action) {
            return why + " add scroll: to this step (for example scroll: .down, or .up if it is above) so the list is scrolled until it appears"
        }
        guard let action = step.action, interactsByTouch(action) else { return "" }
        return why + " scroll the list before this step (scrollUp() or scrollDown()) until it appears — this command has no scroll: argument"
    }

    /// 中身が左右の縁をまたぐ横の容器(縦の一覧の中の横の棚)があるときの案内。**対象がどの棚にあるかは言わない**
    /// (木に対象が無いので材料が無い)。候補を挙げて横へ送る形を示すだけ。判定は変えない
    private static func horizontalShelfHint(_ step: FlowStep, in snapshot: SnapshotResponse) -> String {
        guard coveredTouchAcceptsScroll(step.action) || (step.action.map(interactsByTouch) ?? false) else { return "" }
        let shelves = Self.horizontalOverflowingShelves(in: snapshot)
        guard !shelves.isEmpty else { return "" }
        let named = shelves.prefix(horizontalShelfHintLimit).map { ScenarioCodeGen.literal($0) }.joined(separator: ", ")
        return ". It may also be in a shelf that scrolls sideways (its content runs past the left or right edge: \(named)) —"
            + " wrap the step in withScrollRight(scrollFrame: <that shelf>) { } (or withScrollLeft) to search it sideways"
    }

    /// 案内に挙げる棚の上限(画面に横の棚が並ぶ画面でも文が長くならない件数。尽きたら先頭から挙げる)
    static let horizontalShelfHintLimit = 3

    /// 書けるセレクタを持つ横の scrollable 容器のうち、子孫が左右どちらかの縁を 1 単位越えてまたぐもの(セレクタの文字列)。
    /// 向きは `directionMatchedScrollFrameCandidate` と同じ順(申告した軸 → 子の並び → 縦横比)
    static func horizontalOverflowingShelves(in snapshot: SnapshotResponse) -> [String] {
        var seen = Set<String>()
        return ScrollFrameCandidates.candidates(in: snapshot).compactMap { candidate in
            guard let selector = candidate.selector,
                  let container = snapshot.elements.first(where: { $0.ref == candidate.ref }) else { return nil }
            let actions = container.scrollActions
            let horizontal: Bool
            if ScrollActionsAxis.declares(actions, vertical: false) { horizontal = true }
            else if ScrollActionsAxis.declaresOnlyOtherAxis(actions, vertical: false) { horizontal = false }
            else if let flow = ContainerGeometry.childrenFlow(of: container, in: snapshot.elements) { horizontal = flow == .alongX }
            else { horizontal = container.frame.width > container.frame.height }
            guard horizontal, container.frame.width > 0 else { return nil }
            let left = container.frame.x, right = container.frame.x + container.frame.width
            let crosses = LocatorResolver.descendants(of: container, in: snapshot.elements).contains { e in
                guard e.frame.width > 0, e.frame.height > 0 else { return false }
                let eLeft = e.frame.x, eRight = e.frame.x + e.frame.width
                return (eLeft < left - 1 && eRight > left + 1) || (eLeft < right - 1 && eRight > right + 1)
            }
            return crosses && seen.insert(selector).inserted ? selector : nil
        }
    }

    /// 容器(`container`)の上下どちらかの縁を 1pt 越えてまたぐ要素があるか(縦の一覧の送れる中身の印。容器の外に並ぶ見出しのバー等は
    /// またがないので数えない)。**縁までで切られた行も印**: Android は容器の外へはみ出す行の frame を可視の範囲へ切って返すので
    /// またぐ要素が木に出ない(実測 E2EX-Flutter Android: 容器 324..2856 の最後の行が 2844..2856 の高さ 12・他の行は 168)。
    /// 縁に接し、同じ幅の兄弟の高さの中央値の半分に満たない行を、切られた行とみなす(収まった一覧の端の行は全高なので当たらない)
    static func contentOverflows(_ container: ElementInfo, in elements: [ElementInfo]) -> Bool {
        let top = container.frame.y, bottom = container.frame.y + container.frame.height
        let overlapping = elements.filter { e in
            e.ref != container.ref && e.frame.width > 0 && e.frame.height > 0
                && e.frame.x < container.frame.x + container.frame.width && e.frame.x + e.frame.width > container.frame.x
        }
        if overlapping.contains(where: { e in
            let eTop = e.frame.y, eBottom = e.frame.y + e.frame.height
            return (eTop < top - 1 && eBottom > top + 1) || (eTop < bottom - 1 && eBottom > bottom + 1)
        }) { return true }
        return overlapping.contains { e in
            let eTop = e.frame.y, eBottom = e.frame.y + e.frame.height
            guard abs(eBottom - bottom) <= 1 || abs(eTop - top) <= 1,
                  eTop >= top - 1, eBottom <= bottom + 1 else { return false }
            let siblings = overlapping.filter { $0.ref != e.ref && abs($0.frame.width - e.frame.width) <= 1 && $0.frame.y >= top - 1
                && $0.frame.y + $0.frame.height <= bottom + 1 }.map { $0.frame.height }.sorted()
            guard siblings.count >= 2 else { return false }
            return e.frame.height < siblings[siblings.count / 2] * 0.5
        }
    }
}
