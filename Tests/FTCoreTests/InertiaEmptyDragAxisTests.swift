// 前のステップの swipe が残した慣性を吸う空打ちは、その swipe の軸と直交する向きへ抜く
// (横に送った一覧の末尾のカードを押す前の空打ちが横へ払うと、一覧が1枚戻って対象が窓の外へ出た。
// E2EY-CMP の iOS: scrollToRightEdge の直後の tap)

import XCTest
@testable import FTCore

private final class RecordingDragDriver: AppDriver {
    private(set) var drags: [(fromX: Double, fromY: Double, toX: Double, toY: Double)] = []
    private(set) var tappedRefs: [Int] = []

    func status() async throws -> StatusResponse {
        StatusResponse(ready: true, device: "fake", osVersion: "-", sessionBundleID: nil)
    }
    func install(packagePath: String) async throws -> String? { nil }
    func uninstall(bundleID: String) async throws {}
    func launch(bundleID: String) async throws {}
    func isAppForeground(bundleID: String) async throws -> Bool { true }
    func terminate() async throws {}
    func screenshot() async throws -> Data { Data() }
    func type(ref: Int?, text: String) async throws {}
    func tap(ref: Int) async throws { tappedRefs.append(ref) }
    func tap(x: Double, y: Double) async throws {}
    func press(ref: Int, duration: Double) async throws {}
    func swipe(_ direction: FTSwipeDirection) async throws {}
    func swipe(_ direction: FTSwipeDirection, intent: FTSwipeIntent, path: FTSwipePath?) async throws {}
    func drag(fromX: Double, fromY: Double, toX: Double, toY: Double,
              pressSeconds: Double, durationSeconds: Double) async throws {
        drags.append((fromX, fromY, toX, toY))
    }
    func snapshot() async throws -> SnapshotResponse {
        SnapshotResponse(
            sessionBundleID: nil, screen: FTRect(x: 0, y: 0, width: 402, height: 874),
            elements: [
                ElementInfo(ref: 1, type: "other", identifier: "shelf", label: nil, value: nil, placeholder: nil,
                            enabled: true, frame: FTRect(x: 0, y: 300, width: 402, height: 160), depth: 1),
                ElementInfo(ref: 2, type: "clickable", identifier: "card_a", label: "A", value: nil, placeholder: nil,
                            enabled: true, frame: FTRect(x: 20, y: 310, width: 100, height: 140), depth: 2),
                ElementInfo(ref: 3, type: "clickable", identifier: "card_b", label: "B", value: nil, placeholder: nil,
                            enabled: true, frame: FTRect(x: 150, y: 310, width: 100, height: 140), depth: 2),
            ],
            truncatedCount: 0)
    }
}

final class InertiaEmptyDragAxisTests: XCTestCase {

    private func emptyDrag(afterSwiping direction: String) async -> (fromX: Double, fromY: Double, toX: Double, toY: Double)? {
        let driver = RecordingDragDriver()
        let executor = StepExecutor(driver: driver, releasesScrollTouch: true, isAndroid: false, tunables: RunTunables(),
                                    uiFramework: .compose)
        _ = await executor.execute(FlowStep(action: "swipe", direction: direction))
        _ = await executor.execute(FlowStep(action: "tap", locator: FlowLocator(id: "card_a")))
        return driver.drags.first
    }

    func testEmptyDragAfterAHorizontalSwipeLeavesVertically() async throws {
        let first = await emptyDrag(afterSwiping: "left")
        let drag = try XCTUnwrap(first, "空打ちが撃たれていない")
        XCTAssertEqual(drag.toX, drag.fromX, "横の送りの直後の空打ちが横へ払った(一覧が戻る)")
        XCTAssertNotEqual(drag.toY, drag.fromY)
    }

    /// 対照: 縦の送りの後は従来どおり横へ抜ける
    func testEmptyDragAfterAVerticalSwipeStillLeavesSideways() async throws {
        let first = await emptyDrag(afterSwiping: "up")
        let drag = try XCTUnwrap(first, "空打ちが撃たれていない")
        XCTAssertEqual(drag.toY, drag.fromY)
        XCTAssertNotEqual(drag.toX, drag.fromX)
    }
}
