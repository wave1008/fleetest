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
    /// またがないので数えない)
    static func contentOverflows(_ container: ElementInfo, in elements: [ElementInfo]) -> Bool {
        let top = container.frame.y, bottom = container.frame.y + container.frame.height
        return elements.contains { e in
            guard e.ref != container.ref, e.frame.width > 0, e.frame.height > 0,
                  e.frame.x < container.frame.x + container.frame.width, e.frame.x + e.frame.width > container.frame.x else { return false }
            let eTop = e.frame.y, eBottom = e.frame.y + e.frame.height
            return (eTop < top - 1 && eBottom > top + 1) || (eTop < bottom - 1 && eBottom > bottom + 1)
        }
    }
}
