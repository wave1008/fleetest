// RN の反転チャットの木(SnapshotDedupe.wrapperScrollMerge で内側の scroll が畳まれた形)で、一覧の下に固定された入力欄を
// 「容器の外へ押し出された行(ghost)」と読まないことを固定する。読むと tap / type が救済のスワイプ2本・6〜7 秒・
// 「飲まれたかも」の警告を払う(E2EY-RN の `type '#field_chat'`)。実測の木は iPhone 17 Pro の XCUITest。

import XCTest
@testable import FTCore

final class ContainerGeometryFixedBarTests: XCTestCase {
    private let screen = FTRect(x: 0, y: 0, width: 402, height: 874)

    private func element(_ ref: Int, _ type: String, id: String?, depth: Int,
                         x: Double, y: Double, w: Double, h: Double, scrollable: Bool? = nil) -> ElementInfo {
        ElementInfo(ref: ref, type: type, identifier: id, label: nil, value: nil, placeholder: nil, enabled: true,
                    frame: FTRect(x: x, y: y, width: w, height: h), depth: depth, scrollable: scrollable)
    }

    /// 反転チャット: ラッパー(d15・畳んだ後に scrollable)の中身の行は d20、入力欄は d16(畳まれた内側の scroll と同じ深さ)
    private func chatTree() -> [ElementInfo] {
        var tree = [
            element(1, "button", id: "btn_incoming", depth: 15, x: 8, y: 181, w: 386, h: 44),
            element(2, "scrollView", id: "list_chat", depth: 15, x: 0, y: 233, w: 402, h: 581, scrollable: true),
        ]
        for index in 0..<10 {
            tree.append(element(10 + index, "button", id: "msg_\(index)", depth: 20,
                                x: 8, y: 233 + Double(index) * 58, w: 386, h: 56))
        }
        tree.append(element(30, "textField", id: "field_chat", depth: 16, x: 8, y: 822, w: 316, h: 43))
        tree.append(element(31, "button", id: "btn_send", depth: 15, x: 333, y: 822, w: 60, h: 44))
        return tree
    }

    func testAFixedInputBarBelowTheListIsNotAGhostOfTheList() throws {
        let tree = chatTree()
        let field = try XCTUnwrap(tree.first { $0.identifier == "field_chat" })
        XCTAssertFalse(ContainerGeometry.isOutsideContainer(field, in: tree, screen: screen),
                       "一覧の外に固定された入力欄を、一覧から押し出された行と読んでいる")
        XCTAssertNil(ContainerGeometry.clippingContainer(of: field, in: tree),
                     "入力欄に一覧の枠を容器として当てている")
    }

    /// 対照: 一覧の行が容器の外へ押し出された形(同じ深さの兄弟が容器の中に居る)は従来どおり ghost
    func testARowPushedOutOfTheListIsStillAGhost() throws {
        var tree = [element(1, "scrollView", id: "list", depth: 15, x: 0, y: 233, w: 402, h: 581, scrollable: true)]
        for index in 0..<6 {
            tree.append(element(10 + index, "button", id: "row_\(index)", depth: 16,
                                x: 8, y: 233 + Double(index) * 58, w: 386, h: 56))
        }
        tree.append(element(20, "button", id: "row_pushed", depth: 16, x: 8, y: 900, w: 386, h: 56))
        let pushed = try XCTUnwrap(tree.first { $0.identifier == "row_pushed" })
        XCTAssertTrue(ContainerGeometry.isOutsideContainer(pushed, in: tree, screen: screen),
                      "容器の外へ押し出された行が ghost と読まれなくなった")
    }

    /// 対照: 容器の縁をまたぐ最後の1行(兄弟が居なくても枠が交わる)は従来どおり容器の中身
    func testALoneElementCrossingTheScrollerEdgeStillBelongsToIt() throws {
        let tree = [
            element(1, "scrollView", id: "list", depth: 15, x: 0, y: 0, w: 402, h: 800, scrollable: true),
            element(2, "staticText", id: "txt_offscreen", depth: 16, x: 16, y: 776, w: 200, h: 20),
        ]
        let lone = tree[1]
        XCTAssertEqual(ContainerGeometry.clippingContainer(of: lone, in: tree)?.height, 800)
    }
}
