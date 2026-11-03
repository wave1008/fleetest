// iOS の in-app の木は UITableView / UICollectionView のセルを表示の位置の順に並べる(XCUITest・Android の木と同じ並び)。
// 再利用されたセルの subviews の順のままだと、`[n]` を書かないセレクタが一覧の見える範囲の外の行を掴んだ。
// in-app の dylib は swift test でリンクされないので、配線はソースを走査して守る。

import XCTest

final class InAppCellOrderTests: XCTestCase {
    func testSubviewChildrenGoThroughTheCellOrdering() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let source = try String(contentsOf: root.appendingPathComponent("InAppBridge/Sources/InAppSnapshot.swift"),
                                encoding: .utf8)
        XCTAssertTrue(source.contains("if let view = node as? UIView { return cellsInDisplayOrder(view) }"),
                      "subviews を辿る子はセルを表示の順に並べてから返す")
        XCTAssertFalse(source.contains("if let view = node as? UIView { return view.subviews }"))
        // セル以外の位置は変えない(手前・奥の判定の代用 = PaintOrder を崩さない)
        XCTAssertTrue(source.contains("for (slot, cell) in zip(slots, ordered) { out[slot] = cell }"))
    }
}
