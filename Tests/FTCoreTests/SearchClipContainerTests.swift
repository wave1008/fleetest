// 探索の見切れの枠(`StepExecutor.searchClipContainer`): 容器推定が scroll を申告していない・対象と重ならない祖先を選び、
// 対象の中心が scroll を申告した別の容器の中にあるときだけ、申告した容器を使う

import XCTest
@testable import FTCore

final class SearchClipContainerTests: XCTestCase {
    private func el(_ ref: Int, _ type: String, id: String?, _ r: FTRect, depth: Int, scrollable: Bool? = nil) -> ElementInfo {
        ElementInfo(ref: ref, type: type, identifier: id, label: nil, value: nil, placeholder: nil, enabled: true,
                    frame: r, depth: depth, scrollable: scrollable)
    }

    /// RN の隠れるバーの画面: FAB が上のバーの子に並ぶ(バーの枠と重ならない)。中心は申告した一覧の中
    func testFloatingButtonUsesTheDeclaredListInsteadOfTheBar() {
        let list = el(1, "other", id: nil, FTRect(x: 0, y: 168, width: 402, height: 706), depth: 1, scrollable: true)
        let row1 = el(2, "button", id: "row_h_01", FTRect(x: 8, y: 180, width: 386, height: 48), depth: 2)
        let row2 = el(3, "button", id: "row_h_02", FTRect(x: 8, y: 232, width: 386, height: 48), depth: 2)
        let bar = el(4, "other", id: "bar_top_hiding", FTRect(x: 0, y: 168, width: 402, height: 56), depth: 1)
        let title = el(5, "staticText", id: "txt_inbox", FTRect(x: 12, y: 185, width: 84, height: 21), depth: 2)
        let action = el(6, "button", id: "btn_top_action", FTRect(x: 301, y: 174, width: 88, height: 44), depth: 2)
        let fab = el(7, "button", id: "fab_hiding", FTRect(x: 330, y: 746, width: 56, height: 56), depth: 2)
        let elements = [list, row1, row2, bar, title, action, fab]
        let inferred = ContainerGeometry.clippingContainer(of: fab, in: elements, inferring: true)
        XCTAssertEqual(inferred, bar.frame, "前提: 容器推定はバーを選ぶ")
        XCTAssertEqual(StepExecutor.searchClipContainer(of: fab, in: elements, inferring: true), list.frame)
    }

    /// in-app の CMP の容器の外の行: 推定した容器が scroll を申告している = 従来どおり(本物の見切れ)
    func testDeclaredInferredContainerIsKept() {
        let list = el(1, "other", id: nil, FTRect(x: 0, y: 192, width: 402, height: 648), depth: 1, scrollable: true)
        let row1 = el(2, "button", id: "row_h_12", FTRect(x: 0, y: 0, width: 402, height: 56), depth: 2)
        let row2 = el(3, "button", id: "row_h_13", FTRect(x: 0, y: 55, width: 402, height: 55), depth: 2)
        let row3 = el(4, "button", id: "row_h_14", FTRect(x: 0, y: 200, width: 402, height: 56), depth: 2)
        let elements = [list, row1, row2, row3]
        XCTAssertEqual(StepExecutor.searchClipContainer(of: row1, in: elements, inferring: true),
                       ContainerGeometry.clippingContainer(of: row1, in: elements, inferring: true))
    }

    /// 申告した容器が木に無い(xcuitest の CMP)= 従来どおり
    func testWithoutAnyDeclaredContainerTheInferenceIsKept() {
        let list = el(1, "other", id: nil, FTRect(x: 0, y: 192, width: 402, height: 648), depth: 1)
        let row1 = el(2, "button", id: "row_h_12", FTRect(x: 0, y: 0, width: 402, height: 56), depth: 2)
        let row2 = el(3, "button", id: "row_h_13", FTRect(x: 0, y: 200, width: 402, height: 55), depth: 2)
        let row3 = el(4, "button", id: "row_h_14", FTRect(x: 0, y: 260, width: 402, height: 56), depth: 2)
        let elements = [list, row1, row2, row3]
        XCTAssertEqual(StepExecutor.searchClipContainer(of: row1, in: elements, inferring: true),
                       ContainerGeometry.clippingContainer(of: row1, in: elements, inferring: true))
    }
}
