// 動かなかった払いは払いの回数(maxSwipes)に数えない
// (E2EY の A3 読み込みの状態: 読み込み中の骨組みの間は一覧が動かず、その間の払いで予算を使い、読み込み後の4ページを送り切れなかった)

import XCTest
@testable import FTCore

/// `loadSeconds` 秒の間は骨組み(払っても動かない)。読み込み後は払うたびに一覧が動き、`retryAfterPostLoadSwipes` 本目の後に「再試行」が出る
private final class SkeletonThenListDriver: AppDriver {
    private(set) var swipeCount = 0
    private var postLoadSwipes = 0
    private let loadSeconds: TimeInterval
    private let retryAfterPostLoadSwipes: Int
    private var firstSnapshotAt: Date?

    init(loadSeconds: TimeInterval, retryAfterPostLoadSwipes: Int) {
        self.loadSeconds = loadSeconds
        self.retryAfterPostLoadSwipes = retryAfterPostLoadSwipes
    }

    private func loaded() -> Bool {
        if firstSnapshotAt == nil { firstSnapshotAt = Date() }
        return Date().timeIntervalSince(firstSnapshotAt!) >= loadSeconds
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
    func swipe(_ direction: FTSwipeDirection) async throws { try await swipe(direction, intent: .search, path: nil) }
    func swipe(_ direction: FTSwipeDirection, intent: FTSwipeIntent, path: FTSwipePath?) async throws {
        swipeCount += 1
        if loaded() { postLoadSwipes += 1 }
    }
    func snapshot() async throws -> SnapshotResponse {
        var elements: [ElementInfo] = []
        if loaded() {
            let y = 600 - Double(postLoadSwipes) * 40
            elements.append(ElementInfo(ref: 1, type: "clickable", identifier: "row", label: "行", value: nil,
                                        placeholder: nil, enabled: true,
                                        frame: FTRect(x: 16, y: y, width: 370, height: 56), depth: 1))
            if postLoadSwipes >= retryAfterPostLoadSwipes {
                elements.append(ElementInfo(ref: 2, type: "button", identifier: "btn_retry", label: "再試行", value: nil,
                                            placeholder: nil, enabled: true,
                                            frame: FTRect(x: 16, y: 700, width: 370, height: 56), depth: 1))
            }
        } else {
            elements.append(ElementInfo(ref: 1, type: "clickable", identifier: "skeleton", label: "骨組み", value: nil,
                                        placeholder: nil, enabled: false,
                                        frame: FTRect(x: 16, y: 600, width: 370, height: 56), depth: 1))
        }
        return SnapshotResponse(sessionBundleID: nil, screen: FTRect(x: 0, y: 0, width: 402, height: 874),
                                elements: elements, truncatedCount: 0)
    }
}

final class ScrollSearchUnmovedSwipeBudgetTests: XCTestCase {

    /// 骨組みの間の動かない払い(2本)で maxSwipes: 6 を使い切らない: 読み込み後に5本払って届く
    func testSwipesThatMovedNothingDoNotSpendTheBudget() async throws {
        let driver = SkeletonThenListDriver(loadSeconds: 1.2, retryAfterPostLoadSwipes: 5)
        var step = FlowStep(action: "scrollTo", locator: FlowLocator(id: "btn_retry"), direction: "up", maxSwipes: 6)
        step.timeout = 10
        var phase = StepExecutor.PhaseAccumulator()
        let result = try await StepExecutor(driver: driver, isAndroid: false, tunables: RunTunables())
            .runScrollSearch(step: step, phase: &phase)
        XCTAssertTrue(result.found, "動かなかった払いが回数を使った(swipes=\(driver.swipeCount))")
    }

    func testBudgetRule() {
        XCTAssertEqual(ScrollSearchBudget.attemptAfterSending(attempt: 3, previousSwipeMoved: true), 3)
        XCTAssertEqual(ScrollSearchBudget.attemptAfterSending(attempt: 3, previousSwipeMoved: false), 2)
    }
}
