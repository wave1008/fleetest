// keptDepth(ブリッジが木に出した入れ物の数)で容器の部分木に居ない要素を、送り残し(ghost)と読まない。
// 実測(SUT Store の Android・商品詳細。2026-11-18 の `fleetest snapshot --json`): スクロール容器 d10/k0 の後に、
// 本文の最後の行 d11/k1、上部バーのボタン d12/k0、固定フッタの数量ボタン d12/k0 と「カートに追加」d11/k0 が並ぶ。
// depth の復元ではどれも容器の子に見え、容器の外 = ghost と読まれて毎回救済のドラッグが本文を送っていた

import XCTest
@testable import FTCore

final class KeptDepthGhostTests: XCTestCase {

    private func el(_ ref: Int, _ type: String, _ depth: Int, _ kept: Int?, _ x: Double, _ y: Double,
                    _ w: Double, _ h: Double, id: String? = nil, scrollable: Bool? = nil) -> ElementInfo {
        ElementInfo(ref: ref, type: type, identifier: id, label: nil, value: nil, placeholder: nil, enabled: true,
                    frame: FTRect(x: x, y: y, width: w, height: h), depth: depth, scrollable: scrollable, keptDepth: kept)
    }

    private let screen = FTRect(x: 0, y: 0, width: 1280, height: 2856)

    private func detail(kept: Bool) -> [ElementInfo] {
        func k(_ v: Int) -> Int? { kept ? v : nil }
        return [
            el(1, "scrollView", 10, k(0), 0, 504, 1280, 2040, scrollable: true),
            el(4, "staticText", 11, k(1), 48, 1862, 294, 61),
            el(15, "staticText", 11, k(1), 48, 2419, 1184, 121),
            el(20, "clickable", 12, k(0), 1124, 336, 144, 144, id: "btn_open_cart"),
            el(22, "clickable", 12, k(0), 30, 2592, 144, 144, id: "btn_qty_decrement"),
            el(25, "clickable", 12, k(0), 222, 2592, 144, 144, id: "btn_qty_increment"),
            el(27, "button", 11, k(0), 396, 2592, 836, 144, id: "btn_add_to_cart"),
        ]
    }

    func testFixedBarsOutsideTheKeptSubtreeAreNotGhosts() {
        let tree = detail(kept: true)
        for ref in [20, 27] {
            let element = tree.first { $0.ref == ref }!
            XCTAssertFalse(ContainerGeometry.isOutsideContainer(element, in: tree, screen: screen), "ref \(ref)")
            XCTAssertNil(TapTargetGeometry.outsideDeclaredScroller(element, in: tree, screen: screen), "ref \(ref)")
        }
    }

    /// 前提の確認: keptDepth の無い木(XCUITest・固定コーパス)は従来の depth の判定のまま = この形では ghost と読む
    func testWithoutKeptDepthTheOldJudgementStands() {
        let tree = detail(kept: false)
        XCTAssertTrue(ContainerGeometry.isOutsideContainer(tree[6], in: tree, screen: screen))
    }

    /// 容器の部分木に居る行(keptDepth が容器より深い)が外へ押し出されたら従来どおり ghost
    func testRowInsideTheKeptSubtreeIsStillAGhost() {
        var tree = detail(kept: true)
        tree.insert(el(16, "staticText", 11, 1, 48, 2600, 1184, 121, id: "row_pushed_out"), at: 3)
        XCTAssertTrue(ContainerGeometry.isOutsideContainer(tree[3], in: tree, screen: screen))
    }
}
