// OI-129: `scroll-leftover`(TapTargetGeometry.outsideDeclaredScroller)の誤検知2形と、守る真陽性。
// ①間引きで繋がっただけの中間ノードが要素と交わらない鎖(Emulator の生の木)
// ②画面から横にずれた旧画面の容器の後ろに新画面の要素が並ぶ遷移中の木(iOS Simulator)

import XCTest
@testable import FTCore

final class ScrollLeftoverFalsePositiveTests: XCTestCase {

    private func el(_ ref: Int, _ type: String, _ depth: Int, _ x: Double, _ y: Double,
                    _ w: Double, _ h: Double, id: String? = nil, scrollable: Bool? = nil) -> ElementInfo {
        ElementInfo(ref: ref, type: type, identifier: id, label: nil, value: nil,
                    placeholder: nil, enabled: true, frame: FTRect(x: x, y: y, width: w, height: h),
                    depth: depth, scrollable: scrollable)
    }

    /// E2EX ホーム(Emulator・横向き 2856x1280)の生の preorder: 題名 d11 が容器 d9 の最後の子 nav_links d10 の直後に出る
    func testTitleAfterLastChildWithDisjointIntermediateIsNotLeftover() {
        let screen = FTRect(x: 0, y: 0, width: 2856, height: 1280)
        var tree = [el(0, "other", 9, 156, 348, 2700, 860, scrollable: true)]
        for i in 0..<5 {
            tree.append(el(1 + 2 * i, "clickable", 10, 156, 348 + Double(i) * 168, 2700, 160, id: "nav_\(i)"))
            tree.append(el(2 + 2 * i, "staticText", 11, 204, 380 + Double(i) * 168, 400, 60))
        }
        tree.append(el(11, "clickable", 10, 156, 1188, 2700, 92, id: "nav_links"))
        let title = el(12, "staticText", 11, 204, 204, 366, 96, id: "txt_screen_title")
        tree.append(title)
        XCTAssertNil(TapTargetGeometry.outsideDeclaredScroller(title, in: tree, screen: screen),
                     "間引かれた親の代わりに交わらない nav_links を祖先と読んだ")
    }

    /// 真陽性: 親(セル)ごと容器の上へ押し出された行。中間の祖先は要素と交わる
    func testRowPushedOutWithItsCellStaysLeftover() {
        let screen = FTRect(x: 0, y: 0, width: 400, height: 800)
        let tree = [el(0, "scrollView", 9, 0, 100, 400, 600, scrollable: true),
                    el(1, "other", 10, 0, 100, 400, 100),
                    el(2, "staticText", 11, 10, 110, 100, 20),
                    el(3, "staticText", 11, 10, 140, 100, 20),
                    el(4, "other", 10, 0, -200, 400, 120),
                    el(5, "staticText", 11, 10, -190, 100, 20)]
        XCTAssertNotNil(TapTargetGeometry.outsideDeclaredScroller(tree[5], in: tree, screen: screen),
                        "親ごと容器の外へ出た行の印が消えた")
    }

    /// 真陽性: 容器の直接の子が容器の上へ出た行(中間ノード無し)
    func testDirectChildRowAboveScrollerStaysLeftover() {
        let screen = FTRect(x: 0, y: 0, width: 400, height: 800)
        let tree = [el(0, "scrollView", 9, 0, 100, 400, 600, scrollable: true),
                    el(1, "staticText", 10, 0, 100, 400, 50), el(2, "staticText", 10, 0, 150, 400, 50),
                    el(3, "staticText", 10, 0, -150, 400, 100)]
        XCTAssertNotNil(TapTargetGeometry.outsideDeclaredScroller(tree[3], in: tree, screen: screen))
    }

    /// 遷移中の木: 旧画面の容器が x=-121 にずれ、新画面の FAB(d14)がその子に復元される
    func testElementBehindHorizontallyDisplacedScrollerIsNotLeftover() {
        let screen = FTRect(x: 0, y: 0, width: 402, height: 874)
        func tree(scrollerX: Double) -> [ElementInfo] {
            [el(0, "collectionView", 13, scrollerX, 0, 300, 874, scrollable: true),
             el(1, "cell", 14, scrollerX, 100, 300, 50), el(2, "cell", 14, scrollerX, 150, 300, 50),
             el(3, "button", 14, 330, 716, 56, 56, id: "fab_hiding")]
        }
        let moved = tree(scrollerX: -121)
        XCTAssertNil(TapTargetGeometry.outsideDeclaredScroller(moved[3], in: moved, screen: screen),
                     "ずれた旧画面の容器を新画面の要素の容器と読んだ")
        let settled = tree(scrollerX: 0)
        XCTAssertNotNil(TapTargetGeometry.outsideDeclaredScroller(settled[3], in: settled, screen: screen),
                        "画面内の容器の外の要素の印が消えた(対照)")
    }
}
