// 端と申告した外側の容器の内側に、同じ列でその向きへ送れる一覧があれば端と言わない(OI-169 ⑧: 横向きで
// バーが戻った後、指の点を含む外側の ScrollView は [forward] だけだが、内側の一覧は backward を持つ)。

import XCTest
@testable import FTCore

final class DeclaredEdgeNestedListTests: XCTestCase {
    private func el(_ ref: Int, _ type: String, depth: Int, _ x: Double, _ y: Double, _ w: Double, _ h: Double,
                    id: String? = nil, actions: [String]? = nil) -> ElementInfo {
        ElementInfo(ref: ref, type: type, identifier: id, label: nil, value: nil, placeholder: nil, enabled: true,
                    frame: FTRect(x: x, y: y, width: w, height: h), depth: depth,
                    scrollable: actions != nil ? true : nil, scrollActions: actions)
    }

    /// 観測した形: 外側 ScrollView (0,0 2856x1280) [forward]・内側 list_hiding (156,654 2700x554) [backward,forward]・行が縦に積む
    private func tree(innerActions: [String]?) -> SnapshotResponse {
        var elements = [el(1, "scrollView", depth: 1, 0, 0, 2856, 1280, actions: ["forward"]),
                        el(2, "other", depth: 2, 156, 486, 2700, 168, id: "bar_top_hiding"),
                        el(3, "recyclerView", depth: 2, 156, 654, 2700, 554, id: "list_hiding", actions: innerActions)]
        for i in 0..<4 {
            elements.append(el(10 + i, "clickable", depth: 3, 156, 654 + Double(i) * 140, 2700, 140, id: "row_h_0\(i + 2)"))
        }
        // 一覧の上に浮かぶ FAB(一覧の兄弟・枠は一覧の中)。枠の中の全要素で並びを見ると列が揃わず軸が決まらなかった
        elements.append(el(30, "button", depth: 2, 2640, 824, 168, 168, id: "fab_hiding"))
        return SnapshotResponse(sessionBundleID: "app", screen: FTRect(x: 0, y: 0, width: 2856, height: 1280),
                                elements: elements, truncatedCount: 0)
    }

    private let step = FlowStep(action: "scrollToTop")

    func testNestedListThatCanMoveUpMeansNotAtEdge() {
        XCTAssertFalse(StepExecutor.declaredAtEdge(step: step, in: tree(innerActions: ["backward", "forward"]), finger: .down),
                       "内側の一覧がまだ上へ送れるのに、外側の申告だけで上端と確定した")
    }

    func testWithoutAMovableNestedListTheOuterDeclarationStillDecides() {
        XCTAssertTrue(StepExecutor.declaredAtEdge(step: step, in: tree(innerActions: ["forward"]), finger: .down))
        XCTAssertTrue(StepExecutor.declaredAtEdge(step: step, in: tree(innerActions: nil), finger: .down),
                      "申告の無い内側を「送れる」の根拠にした")
    }
}
