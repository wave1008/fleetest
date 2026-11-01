// CLI / ライブ操作 / MCP が共有する座標の判定と、CLI の ref の古さの判定

import XCTest
@testable import FTCore

final class CoordinateGuardsTests: XCTestCase {
    private func element(_ ref: Int, _ type: String, _ id: String?) -> ElementInfo {
        ElementInfo(ref: ref, type: type, identifier: id, label: nil, value: nil, placeholder: nil,
                    enabled: true, frame: FTRect(x: 0, y: 0, width: 10, height: 10), depth: 1)
    }

    func testKeyboardFrameContainingPoint() {
        var snapshot = SnapshotResponse(sessionBundleID: nil, screen: FTRect(x: 0, y: 0, width: 400, height: 800),
                                        elements: [], truncatedCount: 0)
        XCTAssertNil(CoordinateGuards.keyboardFrame(containing: 100, 600, in: snapshot))
        XCTAssertNil(CoordinateGuards.keyboardFrame(containing: 100, 600, in: nil))
        snapshot.keyboardFrame = FTRect(x: 0, y: 500, width: 400, height: 300)
        XCTAssertNotNil(CoordinateGuards.keyboardFrame(containing: 100, 600, in: snapshot))
        XCTAssertNil(CoordinateGuards.keyboardFrame(containing: 100, 400, in: snapshot))
    }

    func testDragDoesNotMove() {
        XCTAssertTrue(CoordinateGuards.dragDoesNotMove(fromX: 1, fromY: 2, toX: 1, toY: 2))
        XCTAssertFalse(CoordinateGuards.dragDoesNotMove(fromX: 1, fromY: 2, toX: 1, toY: 3))
        XCTAssertFalse(CoordinateGuards.dragDoesNotMove(fromX: 1, fromY: 2, toX: 2, toY: 2))
    }

    /// 控えと今の木で ref の指す先が別の物なら断る材料を返す。控えが無い・同じ物なら nil
    func testStaleDetail() {
        let memo = RefTableMemo.table(of: [element(14, "button", "btn_input_submit")])
        XCTAssertNotNil(RefTableMemo.staleDetail(ref: 14, remembered: memo, now: element(14, "button", "nav_scroll")))
        XCTAssertNotNil(RefTableMemo.staleDetail(ref: 14, remembered: memo, now: element(14, "textField", nil)))
        XCTAssertNil(RefTableMemo.staleDetail(ref: 14, remembered: memo, now: element(14, "button", "btn_input_submit")))
        XCTAssertNil(RefTableMemo.staleDetail(ref: 14, remembered: nil, now: element(14, "button", "nav_scroll")))
        XCTAssertNil(RefTableMemo.staleDetail(ref: 15, remembered: memo, now: element(15, "button", "nav_scroll")))
    }
}
