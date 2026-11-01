// 全部が収まる一覧を払ったときの端のバウンス(払いの直後の1枚だけ枠がずれて戻る)を「動いた」と読まないことを固定する。
// 読み違えると maxSwipes まで回った末に「まだ動いていた」と失敗し、動いたことを根拠に逆走査(ゆっくりしたドラッグ最大 8 本)まで撃つ。

import XCTest
@testable import FTCore

/// 払いのたびに、直後の1回目の読みだけ行が `bounce` pt ずれて返り、その後は元の位置で静止する偽ドライバ。
/// `scrolls == true` のときは払うたびに本当に 40pt ずつ動く(バウンスでない普通のスクロールの対照)
private final class BouncingListDriver: AppDriver {
    private let screen = FTRect(x: 0, y: 0, width: 400, height: 800)
    private let bounce: Double
    private let scrolls: Bool
    private(set) var swipes = 0
    private(set) var drags = 0
    private var readsSinceSwipe = 1
    private var scrolled: Double = 0

    init(bounce: Double = 8, scrolls: Bool = false) { self.bounce = bounce; self.scrolls = scrolls }

    func status() async throws -> StatusResponse {
        StatusResponse(ready: true, device: "fake", osVersion: "-", sessionBundleID: nil)
    }
    func install(packagePath: String) async throws -> String? { nil }
    func uninstall(bundleID: String) async throws {}
    func launch(bundleID: String) async throws {}
    func isAppForeground(bundleID: String) async throws -> Bool { true }
    func foregroundAppID() async throws -> String? { nil }
    func terminate() async throws {}
    func screenshot() async throws -> Data { Data() }
    func type(ref: Int?, text: String) async throws {}
    func tap(ref: Int) async throws {}
    func tap(x: Double, y: Double) async throws {}
    func press(ref: Int, duration: Double) async throws {}
    func swipe(_ direction: FTSwipeDirection) async throws {
        swipes += 1
        readsSinceSwipe = 0
        if scrolls { scrolled += 40 }
    }
    func drag(fromX: Double, fromY: Double, toX: Double, toY: Double,
              pressSeconds: Double, durationSeconds: Double) async throws { drags += 1 }

    func snapshot() async throws -> SnapshotResponse {
        defer { readsSinceSwipe += 1 }
        let offset = (readsSinceSwipe == 0 && !scrolls ? bounce : 0) - scrolled
        let rows = (0..<3).map { index in
            ElementInfo(ref: 2 + index, type: "button", identifier: "row_0\(index)", label: nil, value: nil,
                        placeholder: nil, enabled: true,
                        frame: FTRect(x: 16, y: 40 + Double(index) * 80 + offset, width: 368, height: 56), depth: 1)
        }
        let list = ElementInfo(ref: 1, type: "scrollView", identifier: "list", label: nil, value: nil,
                               placeholder: nil, enabled: true,
                               frame: FTRect(x: 0, y: 0, width: 400, height: 800), depth: 0, scrollable: true)
        return SnapshotResponse(sessionBundleID: nil, screen: screen, elements: [list] + rows, truncatedCount: 0)
    }
}

final class ScrollSearchBounceTests: XCTestCase {
    private func element(_ id: String, y: Double, label: String? = nil) -> ElementInfo {
        ElementInfo(ref: 1, type: "button", identifier: id, label: label, value: nil, placeholder: nil,
                    enabled: true, frame: FTRect(x: 16, y: y, width: 368, height: 56), depth: 1)
    }

    func testSameElementsWithOnlyTheFramesMovedCountsAsPossibleBounce() {
        XCTAssertTrue(ScrollSearchBounce.sameElementsOnlyDisplaced(
            [element("a", y: 118), element("b", y: 174)], [element("a", y: 126), element("b", y: 182)]))
    }

    func testRowsEnteringOrLeavingIsARealScrollNotABounce() {
        XCTAssertFalse(ScrollSearchBounce.sameElementsOnlyDisplaced(
            [element("a", y: 118), element("b", y: 174)], [element("b", y: 118), element("c", y: 174)]))
        XCTAssertFalse(ScrollSearchBounce.sameElementsOnlyDisplaced(
            [element("a", y: 118)], [element("a", y: 100), element("b", y: 174)]))
    }

    func testAChangedLabelOrAnEmptyTreeIsNotABounce() {
        XCTAssertFalse(ScrollSearchBounce.sameElementsOnlyDisplaced(
            [element("a", y: 118, label: "1")], [element("a", y: 126, label: "2")]))
        XCTAssertFalse(ScrollSearchBounce.sameElementsOnlyDisplaced([], []))
        XCTAssertFalse(ScrollSearchBounce.sameElementsOnlyDisplaced([element("a", y: 118)], [element("a", y: 118)]))
    }

    /// 動かせない一覧の払いは、直後の1枚がずれていても「動かなかった」で端と確定する。
    /// 動いたと読むと逆走査のドラッグまで撃つ(この数が 0 でなくなる)
    func testABounceOnAListThatCannotMoveIsNotReadAsMovement() async throws {
        let driver = BouncingListDriver()
        let executor = StepExecutor(driver: driver, isAndroid: false, tunables: RunTunables())
        let step = FlowStep(action: "scrollTo", locator: FlowLocator(id: "row_nothing"), direction: "up", maxSwipes: 6)
        var phase = StepExecutor.PhaseAccumulator()

        let result = try await executor.runScrollSearch(step: step, phase: &phase)

        XCTAssertFalse(result.found)
        XCTAssertFalse(result.contentEverMoved, "バウンスの途中の1枚を「動いた」と読んでいる")
        XCTAssertTrue(result.stoppedUnmoving, "端と確定せず上限まで回っている")
        XCTAssertFalse(result.exhaustedWhileMoving)
        XCTAssertEqual(driver.drags, 0, "動いていない探索で逆走査のドラッグを撃った")
        XCTAssertLessThan(driver.swipes, 6, "上限まで払い続けている")
    }

    /// 対照: 本当に毎回動く一覧(顔ぶれは同じで枠が毎回ずれる)は、整定後もずれたままなので「動いた」と読む
    func testARealMovementWithTheSameRowsIsStillReadAsMovement() async throws {
        let driver = BouncingListDriver(scrolls: true)
        let executor = StepExecutor(driver: driver, isAndroid: false, tunables: RunTunables())
        let step = FlowStep(action: "scrollTo", locator: FlowLocator(id: "row_nothing"), direction: "up", maxSwipes: 2)
        var phase = StepExecutor.PhaseAccumulator()

        let result = try await executor.runScrollSearch(step: step, phase: &phase)

        // 弾切れの結果は contentEverMoved を持たない。動いたと読んだ印は「まだ動いていた」と逆走査
        XCTAssertTrue(result.exhaustedWhileMoving, "本物の移動を動かなかったと読んでいる")
        XCTAssertTrue(result.reverseSweepRan)
    }
}
