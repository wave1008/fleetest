// DSL の swipePointToPoint が画面外の座標を断る。画面端ちょうどは壊さない(閉区間)。

import XCTest
@testable import FTCore

final class SwipePointToPointOffscreenTests: XCTestCase {
    private let screen = FTRect(x: 0, y: 0, width: 402, height: 874)

    func testEdgeExactPointsAreInside() {
        XCTAssertFalse(TapTargetGeometry.isDragPointOffScreen(x: 402, y: 874, screen: screen))
        XCTAssertFalse(TapTargetGeometry.isDragPointOffScreen(x: 0, y: 0, screen: screen))
    }

    func testPointsPastTheEdgeAreOutside() {
        XCTAssertTrue(TapTargetGeometry.isDragPointOffScreen(x: 402.5, y: 100, screen: screen))
        XCTAssertTrue(TapTargetGeometry.isDragPointOffScreen(x: 100, y: 875, screen: screen))
        XCTAssertTrue(TapTargetGeometry.isDragPointOffScreen(x: -1, y: 100, screen: screen))
        XCTAssertTrue(TapTargetGeometry.isDragPointOffScreen(x: .nan, y: 100, screen: screen))
    }

    /// 画面を読んでいない段は、読まずに言える負の座標・非有限だけ断り、正の座標は通す(木の読みを足さない)
    func testWithoutAScreenOnlyNegativeAndNonFiniteAreRefused() {
        XCTAssertTrue(TapTargetGeometry.isDragPointOffScreen(x: 100, y: -5, screen: nil))
        XCTAssertFalse(TapTargetGeometry.isDragPointOffScreen(x: 9999, y: 9999, screen: nil))
        XCTAssertFalse(TapTargetGeometry.isDragPointOffScreen(x: 100, y: 100, screen: FTRect(x: 0, y: 0, width: 0, height: 0)))
    }

    func testRefusalNamesTheOffendingPoint() throws {
        let start = try XCTUnwrap(StepExecutor.offscreenDragPointRefusal(x: -10, y: 5, toX: 10, toY: 10, screen: nil))
        XCTAssertTrue(start.contains("start point"), start)
        let end = try XCTUnwrap(StepExecutor.offscreenDragPointRefusal(x: 10, y: 5, toX: 10, toY: 900, screen: screen))
        XCTAssertTrue(end.contains("end point"), end)
        XCTAssertNil(StepExecutor.offscreenDragPointRefusal(x: 200, y: 874, toX: 200, toY: 0, screen: screen))
    }

    func testStepRefusesWithoutFiring() async {
        let log = CallLog()
        let driver = FakeAppDriver(name: "primary", log: log, snapshotElements: [[]])
        let executor = StepExecutor(driver: driver, isAndroid: false, tunables: RunTunables())
        var step = FlowStep(action: "swipePointToPoint")
        step.x = 100; step.y = -20; step.toX = 100; step.toY = 300
        let outcome = await executor.execute(step)
        guard case .failed(let message) = outcome.status else { return XCTFail("\(outcome.status)") }
        XCTAssertTrue(message.contains("outside the screen"), message)
        XCTAssertFalse(log.entries.contains { $0.contains("drag") }, "\(log.entries)")
    }
}
