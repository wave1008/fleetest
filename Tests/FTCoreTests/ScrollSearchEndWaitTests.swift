// 動いた後に端へ着いた探索は、利用者が書いた waitSeconds: の間は端と確定しない
// (末尾で遅れて出る要素を待つ。E2EY の A3 読み込みの状態: 末尾まで送ると「読み込み中」1 秒の後に「再試行」が出る)

import XCTest
@testable import FTCore

/// 2 本目の送りまでは一覧が動き、以後は端で凍る。`appearsAfterSwipes` 本目以降の送りで末尾に「再試行」が出る
private final class LateFooterDriver: AppDriver {
    private(set) var swipeCount = 0
    private let appearsAfterSwipes: Int
    /// 非 nil なら送りの本数でなく、端(2 本目の送り)に着いてからの経過時間で出る(アプリの時計。読みとは無関係)
    private let appearsAfterSeconds: TimeInterval?
    private var endReachedAt: Date?

    init(appearsAfterSwipes: Int, appearsAfterSeconds: TimeInterval? = nil) {
        self.appearsAfterSwipes = appearsAfterSwipes
        self.appearsAfterSeconds = appearsAfterSeconds
    }

    private func footerShown() -> Bool {
        if let appearsAfterSeconds {
            guard swipeCount >= 2 else { return false }
            if endReachedAt == nil { endReachedAt = Date() }
            return Date().timeIntervalSince(endReachedAt!) >= appearsAfterSeconds
        }
        return swipeCount >= appearsAfterSwipes
    }

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
        if footerShown() {
            elements.append(ElementInfo(ref: 2, type: "button", identifier: "btn_retry", label: "再試行", value: nil,
                                        placeholder: nil, enabled: true,
                                        frame: FTRect(x: 16, y: 700, width: 370, height: 56), depth: 1))
        }
        return SnapshotResponse(sessionBundleID: nil, screen: FTRect(x: 0, y: 0, width: 402, height: 874),
                                elements: elements, truncatedCount: 0)
    }
}

final class ScrollSearchEndWaitTests: XCTestCase {

    private func step(waitSeconds: Double?, maxSwipes: Int = 12) -> FlowStep {
        var step = FlowStep(action: "scrollTo", locator: FlowLocator(id: "btn_retry"), direction: "up", maxSwipes: maxSwipes)
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

    /// 端で待つ間の周回は払いの回数(maxSwipes)を使わない: 端に着いて 3 秒後に出る要素を、maxSwipes: 6 でも waitSeconds: 8 の間は待って見つける
    /// (待つ周回が1本ずつ回数を食うと、0.5 秒間隔の待ちは 6 本で尽きて赤になる)
    func testWaitingAtTheEndDoesNotSpendTheSwipeBudget() async throws {
        let driver = LateFooterDriver(appearsAfterSwipes: .max, appearsAfterSeconds: 3)
        var phase = StepExecutor.PhaseAccumulator()
        let result = try await StepExecutor(driver: driver, isAndroid: false, tunables: RunTunables())
            .runScrollSearch(step: step(waitSeconds: 8, maxSwipes: 6), phase: &phase)
        XCTAssertTrue(result.found, "待つ間に払いの回数を使い切った(swipes=\(driver.swipeCount))")
    }

    /// 端でさらに払うと続きが読み込まれる一覧(引っ張りで読む形): 待つ間も払うので、8 本目の払いで出る要素を maxSwipes: 6 でも見つける
    func testWaitingAtTheEndStillPullsForMoreWithoutSpendingTheBudget() async throws {
        let driver = LateFooterDriver(appearsAfterSwipes: 8)
        var phase = StepExecutor.PhaseAccumulator()
        let result = try await StepExecutor(driver: driver, isAndroid: false, tunables: RunTunables())
            .runScrollSearch(step: step(waitSeconds: 10, maxSwipes: 6), phase: &phase)
        XCTAssertTrue(result.found, "端で払わなかったか、回数を使い切った(swipes=\(driver.swipeCount))")
    }
}
