// CLI / ライブ操作 / MCP が共有する座標の判定

import XCTest
@testable import FTCore

final class CoordinateGuardsTests: XCTestCase {
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
}
