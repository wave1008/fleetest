// 行が読みの逆順(preorder で y 降順)の容器では、申告だけで「払わずに端」と確定しない(60周目 amax F2: RN の反転チャットで
// scrollToTop が1本も払わずに ✅。申告が上下鏡映)。観測した木: list_chat (0,693 1280x1983) の子が msg_59(y=2502)→ msg_58(y=2322)…

import XCTest
@testable import FTCore

final class DeclaredEdgeReversedRowsTests: XCTestCase {
    private func el(_ ref: Int, depth: Int, _ y: Double, id: String? = nil, actions: [String]? = nil) -> ElementInfo {
        ElementInfo(ref: ref, type: actions != nil ? "scrollView" : "button", identifier: id, label: nil, value: nil,
                    placeholder: nil, enabled: true,
                    frame: actions != nil ? FTRect(x: 0, y: 693, width: 1280, height: 1983)
                                          : FTRect(x: 24, y: y, width: 1232, height: 168),
                    depth: depth, scrollable: actions != nil ? true : nil, scrollActions: actions)
    }

    /// 申告は「下へだけ送れる」(= 上端) で、行の並びだけを変える
    private func tree(descending: Bool) -> SnapshotResponse {
        var elements = [el(1, depth: 1, 0, id: "list_chat", actions: ["down"])]
        let ys = (0..<5).map { 702 + Double($0) * 180 }
        for (i, y) in (descending ? Array(ys.reversed()) : ys).enumerated() {
            elements.append(el(10 + i * 2, depth: 2, y, id: "msg_\(i)"))
            // 行の中の文字(一段深い)は行の並びに数えない
            elements.append(el(11 + i * 2, depth: 3, y + 10))
        }
        return SnapshotResponse(sessionBundleID: "app", screen: FTRect(x: 0, y: 0, width: 1280, height: 2856),
                                elements: elements, truncatedCount: 0)
    }

    private let step = FlowStep(action: "scrollToTop")

    func testReversedRowsDoNotTrustTheDeclaration() {
        XCTAssertFalse(StepExecutor.declaredAtEdge(step: step, in: tree(descending: true), finger: .down),
                       "行が逆順の容器の申告だけで上端と確定した(RN の反転一覧は申告が鏡映)")
    }

    func testAscendingRowsStillUseTheDeclaration() {
        XCTAssertTrue(StepExecutor.declaredAtEdge(step: step, in: tree(descending: false), finger: .down),
                      "通常の並びの容器まで近道を止めた(引っ張って更新の一覧で確かめの1本が更新に化ける)")
    }
}
