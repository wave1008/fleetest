// iOS の in-app が塗り順 z を送る規則の純粋な部分(`BridgeAPI.paintSiblingOrder` / `allOrNothingPaintOrder`)。
// 走査そのもの(InAppSnapshot.paintOrderTable)は UIKit 依存で dylib 側にある。
import XCTest
@testable import FTCore

final class InAppPaintOrderTests: XCTestCase {

    func testEqualZPositionsKeepSubviewOrder() {
        XCTAssertEqual(BridgeAPI.paintSiblingOrder(zPositions: [0, 0, 0, 0]), [0, 1, 2, 3])
    }

    func testHigherZPositionIsDrawnLater() {
        XCTAssertEqual(BridgeAPI.paintSiblingOrder(zPositions: [5, 0, 0]), [1, 2, 0])
    }

    func testNegativeZPositionComesFirst() {
        XCTAssertEqual(BridgeAPI.paintSiblingOrder(zPositions: [0, -1, 0, -1]), [1, 3, 0, 2])
    }

    func testEmptyAndSingle() {
        XCTAssertEqual(BridgeAPI.paintSiblingOrder(zPositions: []), [])
        XCTAssertEqual(BridgeAPI.paintSiblingOrder(zPositions: [3]), [0])
    }

    func testAllViewsKeepsNumbers() {
        XCTAssertEqual(BridgeAPI.allOrNothingPaintOrder([4, 1, 9]), [4, 1, 9])
    }

    func testOneNonViewClearsEveryElement() {
        XCTAssertEqual(BridgeAPI.allOrNothingPaintOrder([4, nil, 9]), [nil, nil, nil])
    }

    func testElementMissingFromTableClearsEveryElement() {
        XCTAssertEqual(BridgeAPI.allOrNothingPaintOrder([nil]), [nil])
    }

    func testEmptyTree() {
        XCTAssertEqual(BridgeAPI.allOrNothingPaintOrder([]), [])
    }

    /// RN の Text の文字の断片(UIView でない)は、要素でもある段落のビューの番号を継ぐ
    func testFragmentInheritsItsElementContainer() {
        XCTAssertEqual(BridgeAPI.paintNumber(own: nil, isView: false, container: 7, containerIsElement: true), 7)
    }

    /// 容器が要素でない(SwiftUI のホストのビュー等)なら番号を決めない = 全か無かで木全体が nil
    func testNodeUnderANonElementContainerHasNoNumber() {
        XCTAssertNil(BridgeAPI.paintNumber(own: nil, isView: false, container: 7, containerIsElement: false))
        XCTAssertNil(BridgeAPI.paintNumber(own: nil, isView: false, container: nil, containerIsElement: false))
    }

    func testViewUsesItsOwnNumber() {
        XCTAssertEqual(BridgeAPI.paintNumber(own: 3, isView: true, container: 7, containerIsElement: true), 3)
        XCTAssertNil(BridgeAPI.paintNumber(own: nil, isView: true, container: 7, containerIsElement: true))
    }

    /// 塗り順を送るのは要素がそれぞれ UIView を持つ構成だけ(全数を等号で固定 = 語彙を足したら見直す)
    func testPaintOrderFrameworksArePinned() {
        XCTAssertEqual(Set(AppUIFramework.allCases.filter(\.viewHierarchyIsPaintOrder)), [.uikit, .reactNative])
    }
}
