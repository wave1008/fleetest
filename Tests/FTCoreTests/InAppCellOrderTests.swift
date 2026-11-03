// iOS の in-app の木は UITableView / UICollectionView のセルを画面上の位置の順に並べる(規則は `BridgeAPI.cellDisplayOrder`)。
// in-app の dylib は swift test でリンクされないので、配線はソースを走査して守る。

import CoreGraphics
import XCTest
@testable import FTCore

final class InAppCellOrderTests: XCTestCase {
    private func row(_ y: CGFloat) -> CGRect { CGRect(x: 16, y: y, width: 370, height: 56) }
    private let list = CGRect(x: 0, y: 0, width: 402, height: 874)

    /// 一覧の見える範囲の外に回ったセル(見える範囲の上の行)は、見えているセルの後ろへ(.clickable が最上段の上の行を撃った)
    func testCellsOutsideTheVisibleListGoLast() {
        let visible = CGRect(x: 0, y: 270, width: 402, height: 400)
        let order = BridgeAPI.cellDisplayOrder(screenFrames: [row(326), row(214), row(270)], isCell: [true, true, true],
                                               listVisible: visible)
        XCTAssertEqual(order, [2, 0, 1], "214 の行は見える範囲(270〜)の外 = 最後")
    }

    /// 再利用で subviews の順が崩れたセルを上から並べる(実測: 先頭が一覧の見える範囲の外の row_08)
    func testCellsAreOrderedTopToBottom() {
        let order = BridgeAPI.cellDisplayOrder(screenFrames: [row(662), row(270), row(326)], isCell: [true, true, true], listVisible: list)
        XCTAssertEqual(order, [1, 2, 0])
    }

    /// セル以外(見出し・スクロールの指示)の位置は変えない
    func testNonCellSlotsStayInPlace() {
        let header = CGRect(x: 0, y: 200, width: 402, height: 30)
        let order = BridgeAPI.cellDisplayOrder(screenFrames: [row(662), header, row(270)], isCell: [true, false, true], listVisible: list)
        XCTAssertEqual(order, [2, 1, 0])
    }

    /// 重なるセル(重ねたカード = zIndex の順)は並べ替えない(木の順は手前・奥の判定の代用)
    func testOverlappingCellsAreLeftAlone() {
        let cards = [CGRect(x: 20, y: 300, width: 300, height: 200), CGRect(x: 40, y: 250, width: 300, height: 200)]
        XCTAssertNil(BridgeAPI.cellDisplayOrder(screenFrames: cards, isCell: [true, true], listVisible: list))
        XCTAssertNil(BridgeAPI.cellDisplayOrder(screenFrames: [row(300)], isCell: [true], listVisible: list), "セルが1つなら何もしない")
        XCTAssertNil(BridgeAPI.cellDisplayOrder(screenFrames: [row(300), row(356)], isCell: [false, true], listVisible: list))
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
        XCTAssertTrue(source.contains("listVisible: view.convert(view.bounds.inset(by: (view as? UIScrollView)?.adjustedContentInset ?? .zero), to: nil)"),
                      "一覧の見える範囲 = 内側の余白(見出し・バーの下)を除いた範囲を渡す")
    }

    func testOverlapToleranceIsPinned() {
        XCTAssertEqual(BridgeAPI.cellOverlapTolerance, 0.5)
        let touching = [CGRect(x: 0, y: 0, width: 400, height: 56.3), CGRect(x: 0, y: 56, width: 400, height: 56)]
        XCTAssertEqual(BridgeAPI.cellDisplayOrder(screenFrames: touching.reversed(), isCell: [true, true], listVisible: list), [1, 0],
                       "端の 1 物理画素の共有は重なりに数えない")
    }

    /// type の replace の消去は、容器を送る・キーボードの向こうへ届かせる段の後(消去の焦点のタップがキーの上で断られて赤になった)
    func testTypeReplaceClearsAfterReachingPastTheKeyboard() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let source = try String(contentsOf: root.appendingPathComponent("Sources/FTCore/StepExecutor+Actions.swift"), encoding: .utf8)
        let typeCase = try XCTUnwrap(source.range(of: "        case \"type\":"))
        let reach = try XCTUnwrap(source.range(of: "element, in: snapshot, step: step, action: \"type\", allowsVisiblePart: false,",
                                               range: typeCase.upperBound..<source.endIndex))
        let clear = try XCTUnwrap(source.range(of: "switch try await performClearInput(element: element, step: step,",
                                               range: typeCase.upperBound..<source.endIndex))
        XCTAssertLessThan(reach.lowerBound, clear.lowerBound)
    }
}
