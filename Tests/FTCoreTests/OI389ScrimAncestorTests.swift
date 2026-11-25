// 塗り順の z が本物の木で、z が対象より大きい(= 手前に描かれる)候補を祖先と数えない。
// 木は RN の Android のボトムシート(幕 depth 11 z=23 が背面 depth 15〜16 z=15〜22 の前に木の順で並ぶ)を、必要な要素だけ抜いて固定した形。

import XCTest
@testable import FTCore

final class OI389ScrimAncestorTests: XCTestCase {
    private let screen = FTRect(x: 0, y: 0, width: 1280, height: 2856)

    private func node(_ ref: Int, _ depth: Int, _ z: Int, _ type: String, _ id: String?, _ label: String?,
                      _ x: Double, _ y: Double, _ w: Double, _ h: Double, scrollable: Bool? = nil) -> ElementInfo {
        ElementInfo(ref: ref, type: type, identifier: id, label: label, value: nil, placeholder: nil,
                    enabled: true, frame: FTRect(x: x, y: y, width: w, height: h), depth: depth,
                    scrollable: scrollable, z: z, renderer: "view")
    }

    private var tree: [ElementInfo] {
        [node(1, 11, 23, "button", nil, "Bottom sheet backdrop", 0, 0, 1280, 2856),
         node(2, 14, 28, "scrollView", "list_sheet", nil, 0, 1214, 1280, 1642, scrollable: true),
         node(4, 17, 32, "button", "btn_sheet_opt_1", "選択肢 1", 0, 1284, 1280, 132),
         node(28, 15, 20, "button", nil, "前に戻る", 0, 156, 168, 168),
         node(30, 15, 15, "button", "btn_open_sheet", "シートを開く", 48, 372, 1184, 132),
         node(32, 15, 17, "staticText", "txt_sheet_result", "sheet=none", 48, 528, 1184, 57)]
    }

    private var target: ElementInfo { tree[4] }

    func testWithoutPaintOrderTheScrimIsStillCountedAsAncestor() {
        XCTAssertTrue(TapTargetGeometry.ancestors(of: target, in: tree).contains { $0.ref == 1 })
        XCTAssertNil(OcclusionGeometry.occluder(of: target, in: tree, screen: screen))
    }

    func testWithRealPaintOrderTheScrimDrawnAboveIsNotAnAncestor() {
        XCTAssertFalse(TapTargetGeometry.ancestors(of: target, in: tree, paintOrderIsReal: true).contains { $0.ref == 1 })
        XCTAssertFalse(TapTargetGeometry.lineage(of: target, in: tree, paintOrderIsReal: true).contains(1))
        XCTAssertEqual(OcclusionGeometry.occluder(of: target, in: tree, screen: screen, paintOrderIsReal: true)?.ref, 1)
    }

    func testRealParentChildAreKeptWhenParentIsDrawnBelow() {
        let row = tree[2]
        let refs = TapTargetGeometry.ancestors(of: row, in: tree, paintOrderIsReal: true).map(\.ref)
        XCTAssertEqual(refs, [2, 1])
    }

    func testAdvisoryNamesTheScrimOnRNAndroid() {
        let text = TapTargetGeometry.occlusionAdvisory(for: target, in: tree, screen: screen,
                                                       isAndroid: true, framework: .reactNative)
        XCTAssertNotNil(text)
        XCTAssertTrue(text?.contains("Bottom sheet backdrop") == true, text ?? "")
    }

    func testAdvisoryDoesNotChangeWhenPaintOrderIsNotReal() {
        // 自前描画(Compose)の Android は塗り順を信じない = 従来どおり祖先として除外され、覆いは出ない
        let text = TapTargetGeometry.occlusionAdvisory(for: target, in: tree, screen: screen,
                                                       isAndroid: true, framework: .compose)
        XCTAssertNil(text)
    }
}
