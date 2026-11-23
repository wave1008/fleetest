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

/// 容器(高さ 400)の中の id 付きの行を、払うたびに `travelPerSwipe` だけ動かす。`targetAfter` 本目の後に対象の行が出る
private final class FixedTravelListDriver: AppDriver {
    private(set) var swipeCount = 0
    private let travelPerSwipe: Double
    private let targetAfter: Int

    init(travelPerSwipe: Double, targetAfter: Int) {
        self.travelPerSwipe = travelPerSwipe
        self.targetAfter = targetAfter
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
    }
    func snapshot() async throws -> SnapshotResponse {
        let offset = Double(swipeCount) * travelPerSwipe
        var elements = [ElementInfo(ref: 1, type: "scrollView", identifier: "list", label: nil, value: nil,
                                    placeholder: nil, enabled: true,
                                    frame: FTRect(x: 0, y: 200, width: 402, height: 400), depth: 1, scrollable: true)]
        // 行の高さ 50・容器の中に見えている行だけを出す(中身が動いた量を共通の id から測れる)
        for row in 0..<200 {
            let y = 200 + Double(row) * 50 - offset
            guard y >= 200, y + 50 <= 600 else { continue }
            elements.append(ElementInfo(ref: 10 + row, type: "cell", identifier: "row_\(row)", label: "行\(row)", value: nil,
                                        placeholder: nil, enabled: true,
                                        frame: FTRect(x: 0, y: y, width: 402, height: 50), depth: 2))
        }
        if swipeCount >= targetAfter {
            elements.append(ElementInfo(ref: 999, type: "button", identifier: "btn_target", label: "対象", value: nil,
                                        placeholder: nil, enabled: true,
                                        frame: FTRect(x: 0, y: 400, width: 402, height: 50), depth: 2))
        }
        return SnapshotResponse(sessionBundleID: nil, screen: FTRect(x: 0, y: 0, width: 402, height: 874),
                                elements: elements, truncatedCount: 0)
    }
}

/// 容器の半分しか動かない払い(in-app の払い = 慣性なし)は半分の1本と数える
final class ScrollSearchShortSwipeBudgetTests: XCTestCase {

    private func search(travelPerSwipe: Double, targetAfter: Int, maxSwipes: Int) async throws -> (Bool, Int) {
        let driver = FixedTravelListDriver(travelPerSwipe: travelPerSwipe, targetAfter: targetAfter)
        var step = FlowStep(action: "scrollTo", locator: FlowLocator(id: "btn_target"), direction: "up", maxSwipes: maxSwipes)
        // 容器を名指す(評価で赤になった形と同じ = 移動量を容器の長さで割る)
        step.scrollFrame = FlowLocator(id: "list")
        step.timeout = 1
        var phase = StepExecutor.PhaseAccumulator()
        let executor = StepExecutor(driver: driver, isAndroid: false, tunables: RunTunables())
        let result = try await executor.runScrollSearch(step: step, recoverOnMiss: false, phase: &phase)
        return (result.found, driver.swipeCount)
    }

    /// 1本で容器の半分(200 of 400)動く払いなら、maxSwipes: 4 でも 8 本目の後の対象に届く
    func testHalfContainerSwipesCountAsHalf() async throws {
        let (found, swipes) = try await search(travelPerSwipe: 200, targetAfter: 7, maxSwipes: 4)
        XCTAssertTrue(found, "容器の半分しか動かない払いを1本と数えた(swipes=\(swipes))")
    }

    /// 容器ぶん動く払いは1本と数える(従来どおり): maxSwipes: 4 では 7 本目の後の対象に届かない
    func testFullContainerSwipesStillCountAsOne() async throws {
        let (found, swipes) = try await search(travelPerSwipe: 400, targetAfter: 7, maxSwipes: 4)
        XCTAssertFalse(found)
        XCTAssertLessThanOrEqual(swipes, 4)
    }

    /// 少ししか動かない払いでも、払いの数は maxSwipes ÷ 探索の刻みの比(0.5)= 2 倍を超えない
    func testTinyTravelIsBoundedByTheStroke() async throws {
        let (found, swipes) = try await search(travelPerSwipe: 50, targetAfter: 100, maxSwipes: 4)
        XCTAssertFalse(found)
        XCTAssertLessThanOrEqual(swipes, 8)
        XCTAssertGreaterThan(swipes, 4)
    }

    func testWeightRule() {
        XCTAssertEqual(ScrollSearchBudget.weight(travelRatio: nil, strokeRatio: 0.5), 1)
        XCTAssertEqual(ScrollSearchBudget.weight(travelRatio: 1.4, strokeRatio: 0.5), 1)
        XCTAssertEqual(ScrollSearchBudget.weight(travelRatio: 0.5, strokeRatio: 0.5), 0.5)
        XCTAssertEqual(ScrollSearchBudget.weight(travelRatio: 0.1, strokeRatio: 0.5), 0.5)
        var credit = 0.0
        XCTAssertEqual(ScrollSearchBudget.attemptAfterMovedSwipe(attempt: 3, weight: 0.5, credit: &credit), 3)
        XCTAssertEqual(ScrollSearchBudget.attemptAfterMovedSwipe(attempt: 3, weight: 0.5, credit: &credit), 2)
        XCTAssertEqual(credit, 0, accuracy: 1e-9)
    }
}
