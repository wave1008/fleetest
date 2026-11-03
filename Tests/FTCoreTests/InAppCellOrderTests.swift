// iOS の in-app の木は UITableView / UICollectionView のセルを画面上の位置の順に並べる(規則は `BridgeAPI.cellDisplayOrder`)。
// in-app の dylib は swift test でリンクされないので、配線はソースを走査して守る。

import CoreGraphics
import XCTest
@testable import FTCore

final class InAppCellOrderTests: XCTestCase {
    private func row(_ y: CGFloat) -> CGRect { CGRect(x: 16, y: y, width: 370, height: 56) }

    /// 再利用で subviews の順が崩れたセルを上から並べる(実測: 先頭が一覧の見える範囲の外の row_08)
    func testCellsAreOrderedTopToBottom() {
        let order = BridgeAPI.cellDisplayOrder(screenFrames: [row(662), row(270), row(326)], isCell: [true, true, true])
        XCTAssertEqual(order, [1, 2, 0])
    }

    /// セル以外(見出し・スクロールの指示)の位置は変えない
    func testNonCellSlotsStayInPlace() {
        let header = CGRect(x: 0, y: 200, width: 402, height: 30)
        let order = BridgeAPI.cellDisplayOrder(screenFrames: [row(662), header, row(270)], isCell: [true, false, true])
        XCTAssertEqual(order, [2, 1, 0])
    }

    /// 重なるセル(重ねたカード = zIndex の順)は並べ替えない(木の順は手前・奥の判定の代用)
    func testOverlappingCellsAreLeftAlone() {
        let cards = [CGRect(x: 20, y: 300, width: 300, height: 200), CGRect(x: 40, y: 250, width: 300, height: 200)]
        XCTAssertNil(BridgeAPI.cellDisplayOrder(screenFrames: cards, isCell: [true, true]))
        XCTAssertNil(BridgeAPI.cellDisplayOrder(screenFrames: [row(300)], isCell: [true]), "セルが1つなら何もしない")
        XCTAssertNil(BridgeAPI.cellDisplayOrder(screenFrames: [row(300), row(356)], isCell: [false, true]))
    }

    /// 並べる位置は画面上の位置(反転した一覧ではセルの枠と逆になる。呼び手は画面座標を渡す)
    func testInAppPassesScreenFramesAndUsesTheSharedRule() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let source = try String(contentsOf: root.appendingPathComponent("InAppBridge/Sources/InAppSnapshot.swift"),
                                encoding: .utf8)
        XCTAssertTrue(source.contains("if let view = node as? UIView { return cellsInDisplayOrder(view) }"))
        XCTAssertTrue(source.contains("screenFrames: subviews.map { $0.convert($0.bounds, to: nil) }"))
        XCTAssertTrue(source.contains("BridgeAPI.cellDisplayOrder("))
        XCTAssertTrue(source.contains("!$0.isHidden && $0.alpha >= 0.01"), "隠れた再利用待ちのセルはセルに数えない")
    }

    func testOverlapToleranceIsPinned() {
        XCTAssertEqual(BridgeAPI.cellOverlapTolerance, 0.5)
        let touching = [CGRect(x: 0, y: 0, width: 400, height: 56.3), CGRect(x: 0, y: 56, width: 400, height: 56)]
        XCTAssertEqual(BridgeAPI.cellDisplayOrder(screenFrames: touching.reversed(), isCell: [true, true]), [1, 0],
                       "端の 1 物理画素の共有は重なりに数えない")
    }
}
