// in-app の木: 祖先の view が隠れた・透明なら、`accessibilityElements` が直接返した要素でも木に載せない(`BridgeAPI.hiddenByAncestor`)
import XCTest
@testable import FTCore

final class BridgeHiddenByAncestorTests: XCTestCase {

    /// 遷移の途中の前の画面のバーボタン: 祖先の1つが alpha 0(リマインダーで測った形)
    func testTransparentAncestorHidesTheElement() {
        XCTAssertTrue(BridgeAPI.hiddenByAncestor(ancestors: [(false, 1), (false, 0), (false, 1)]))
    }

    func testHiddenAncestorHidesTheElement() {
        XCTAssertTrue(BridgeAPI.hiddenByAncestor(ancestors: [(false, 1), (true, 1)]))
    }

    /// 新しい画面のボタン: 祖先が全部見えている。半透明(0.01 以上)も描かれるので外さない
    func testVisibleAndTranslucentAncestorsKeepTheElement() {
        XCTAssertFalse(BridgeAPI.hiddenByAncestor(ancestors: [(false, 1), (false, 0.5), (false, 0.02)]))
        XCTAssertFalse(BridgeAPI.hiddenByAncestor(ancestors: []))
    }
}
