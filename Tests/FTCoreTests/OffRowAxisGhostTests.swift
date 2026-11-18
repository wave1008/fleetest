// 横一列の申告容器から縦にだけ外れた要素を ghost(送り残し)と読まない。
// Compose の Android の検索結果: 容器として木に出ないグリッドのカードが、直前に並ぶカテゴリチップの行
// (scrollView (0,372 1280x168))の子に復元され、DSL の tap が「容器の外」と読んで救済のドラッグを撃ち、
// 始点・終点が「ファッション」チップの中に乗って絞り込みを変えた。MCP の outsideDeclaredScroller は既に除いていた

import XCTest
@testable import FTCore

final class OffRowAxisGhostTests: XCTestCase {

    private func el(_ ref: Int, _ type: String, _ depth: Int, _ x: Double, _ y: Double,
                    _ w: Double, _ h: Double, id: String? = nil, scrollable: Bool? = nil) -> ElementInfo {
        ElementInfo(ref: ref, type: type, identifier: id, label: nil, value: nil, placeholder: nil, enabled: true,
                    frame: FTRect(x: x, y: y, width: w, height: h), depth: depth, scrollable: scrollable)
    }

    private let screen = FTRect(x: 0, y: 0, width: 1280, height: 2856)

    /// 観測した枠の形(深さは trace の容器 = チップの行から逆算した、カードがチップの行の子に見える形)
    private var searchResults: [ElementInfo] {
        [
            el(1, "other", 1, 0, 156, 1280, 2388, id: "screen_search"),
            el(2, "scrollView", 2, 0, 372, 1280, 168, scrollable: true),
            el(3, "button", 3, 48, 384, 390, 144, id: "chip_category_electronics"),
            el(4, "button", 3, 450, 384, 348, 144, id: "chip_category_fashion"),
            el(5, "button", 3, 810, 384, 431, 144, id: "chip_category_home"),
            el(6, "button", 3, 1253, 384, 27, 144, id: "chip_category_beauty"),
            el(7, "button", 3, 48, 588, 580, 840, id: "product_card_electronics_1"),
        ]
    }

    func testCardBelowAHorizontalChipRowIsNotAGhost() {
        let tree = searchResults
        XCTAssertEqual(ContainerGeometry.clippingContainer(of: tree[6], in: tree),
                       FTRect(x: 0, y: 372, width: 1280, height: 168), "前提: 容器はチップの行に復元される")
        XCTAssertFalse(ContainerGeometry.isOutsideContainer(tree[6], in: tree, screen: screen))
        XCTAssertNil(TapTargetGeometry.outsideDeclaredScroller(tree[6], in: tree, screen: screen),
                     "MCP 側と同じ答え")
    }

    /// 横一列の容器から左右へ外れた送り残しは従来どおり ghost
    func testItemPushedSidewaysOutOfAHorizontalRowIsStillAGhost() {
        var tree = searchResults
        tree[6] = el(7, "button", 3, 1300, 384, 390, 144, id: "chip_category_sports")
        XCTAssertTrue(ContainerGeometry.isOutsideContainer(tree[6], in: tree, screen: FTRect(x: 0, y: 0, width: 2000, height: 2856)))
    }

    /// 縦の一覧から縦に外れた行は従来どおり ghost(行が横一列でないので除外は効かない)
    func testRowPushedOutOfAVerticalListIsStillAGhost() {
        let tree = [
            el(1, "other", 1, 0, 0, 1080, 2400, id: "screen"),
            el(2, "scrollView", 2, 0, 300, 1080, 1200, scrollable: true),
            el(3, "button", 3, 0, 300, 1080, 200, id: "row_1"),
            el(4, "button", 3, 0, 500, 1080, 200, id: "row_2"),
            el(5, "button", 3, 0, 700, 1080, 200, id: "row_3"),
            el(6, "button", 3, 0, 60, 1080, 200, id: "row_0"),
        ]
        XCTAssertTrue(ContainerGeometry.isOutsideContainer(tree[5], in: tree, screen: FTRect(x: 0, y: 0, width: 1080, height: 2400)))
    }
}
