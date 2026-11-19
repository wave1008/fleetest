import Foundation

// 見つからない操作の失敗文に足す「送れば出るかも」の案内(`scrollOffHint`)と、その前提の判定
extension StepExecutor {
    /// **中身が容器に収まっている一覧には案内しない**: 送っても新しい物は出ない(メモの空のフォルダで従っても直らない案内だった)。
    /// 送れる中身があるかは、容器の枠をはみ出す要素が木に居るか(隠れるバーの画面の一覧は上下の行が容器の縁を越える・
    /// 収まったホームの一覧は越えない)。端の行がちょうど縁で揃って次の行が木に無い形は見逃す(案内が出ないだけ)
    static func scrollOffHint(_ step: FlowStep, in snapshot: SnapshotResponse) -> String {
        guard step.direction == nil,
              let container = TapTargetGeometry.primaryScrollContainer(in: snapshot.elements, screen: snapshot.screen),
              Self.contentOverflows(container, in: snapshot.elements) else { return "" }
        let why = ". If it is off the screen or was hidden by scrolling (for example a bar that hides while the list scrolls),"
        if coveredTouchAcceptsScroll(step.action) {
            return why + " add scroll: to this step (for example scroll: .down, or .up if it is above) so the list is scrolled until it appears"
        }
        guard let action = step.action, interactsByTouch(action) else { return "" }
        return why + " scroll the list before this step (scrollUp() or scrollDown()) until it appears — this command has no scroll: argument"
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
