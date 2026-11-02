// 動いた後に端へ着いた探索は、利用者が書いた waitSeconds: の間は端と確定しない
// (末尾で遅れて出る要素を待つ。E2EY の A3 読み込みの状態: 末尾まで送ると「読み込み中」1 秒の後に「再試行」が出る)

import XCTest
@testable import FTCore

/// 2 本目の送りまでは一覧が動き、以後は端で凍る。`appearsAfterSwipes` 本目以降の送りで末尾に「再試行」が出る
private final class LateFooterDriver: AppDriver {
    private(set) var swipeCount = 0
    private let appearsAfterSwipes: Int

    init(appearsAfterSwipes: Int) { self.appearsAfterSwipes = appearsAfterSwipes }

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
    func tap(ref: Int) async throws {}
    func tap(x: Double, y: Double) async throws {}
    func press(ref: Int, duration: Double) async throws {}
    func swipe(_ direction: FTSwipeDirection) async throws { swipeCount += 1 }
    func swipe(_ direction: FTSwipeDirection, intent: FTSwipeIntent, path: FTSwipePath?) async throws { swipeCount += 1 }
    func snapshot() async throws -> SnapshotResponse {
        let y = 600 - Double(min(swipeCount, 2)) * 40
        var elements = [ElementInfo(ref: 1, type: "clickable", identifier: "anchor", label: "行", value: nil,
                                    placeholder: nil, enabled: true,
                                    frame: FTRect(x: 16, y: y, width: 370, height: 56), depth: 1)]
        if swipeCount >= appearsAfterSwipes {
            elements.append(ElementInfo(ref: 2, type: "button", identifier: "btn_retry", label: "再試行", value: nil,
                                        placeholder: nil, enabled: true,
                                        frame: FTRect(x: 16, y: 700, width: 370, height: 56), depth: 1))
        }
        return SnapshotResponse(sessionBundleID: nil, screen: FTRect(x: 0, y: 0, width: 402, height: 874),
                                elements: elements, truncatedCount: 0)
    }
}

final class ScrollSearchEndWaitTests: XCTestCase {

    private func step(waitSeconds: Double?) -> FlowStep {
        var step = FlowStep(action: "scrollTo", locator: FlowLocator(id: "btn_retry"), direction: "up", maxSwipes: 12)
        step.timeout = waitSeconds
        return step
    }

    /// 端に着いた後に出る要素は、waitSeconds: の間なら見つかる
    func testLateElementAtTheEndIsFoundWithinTheWrittenBudget() async throws {
        let driver = LateFooterDriver(appearsAfterSwipes: 8)
        var phase = StepExecutor.PhaseAccumulator()
        let result = try await StepExecutor(driver: driver, isAndroid: false, tunables: RunTunables())
            .runScrollSearch(step: step(waitSeconds: 10), phase: &phase)
        XCTAssertTrue(result.found, "端で待たずに打ち切った(swipes=\(driver.swipeCount))")
    }

    /// 対照: waitSeconds: を書かなければ従来どおり端で打ち切る
    func testWithoutAWrittenBudgetTheEndIsClaimedAtOnce() async throws {
        let driver = LateFooterDriver(appearsAfterSwipes: 8)
        var phase = StepExecutor.PhaseAccumulator()
        let result = try await StepExecutor(driver: driver, isAndroid: false, tunables: RunTunables())
            .runScrollSearch(step: step(waitSeconds: nil), phase: &phase)
        XCTAssertFalse(result.found)
        XCTAssertTrue(result.stoppedUnmoving)
    }
}
