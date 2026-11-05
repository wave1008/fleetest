// 探索の途中でアプリが落ちたら、そこで止めてアプリの消失として返す(0回目だけの確かめでは、落ちた後もランチャーの上で払い続けた)。
// 生きていれば(持ち主が一時的に替わっただけ)続ける

import XCTest
@testable import FTCore

private final class OwnerChangesAfterSwipeDriver: AppDriver, @unchecked Sendable {
    private(set) var swipes = 0
    func snapshot() async throws -> SnapshotResponse {
        let owner = swipes == 0 ? "com.app" : "com.google.android.apps.nexuslauncher"
        let list = ElementInfo(ref: 1, type: "other", identifier: "list", label: nil, value: nil, placeholder: nil, enabled: true,
                               frame: FTRect(x: 0, y: 200, width: 400, height: 600), depth: 1, scrollable: true)
        let row = ElementInfo(ref: 2, type: "staticText", identifier: "row_\(swipes)", label: "行 \(swipes)", value: nil, placeholder: nil,
                              enabled: true, frame: FTRect(x: 0, y: 300, width: 400, height: 60), depth: 2)
        return SnapshotResponse(sessionBundleID: owner, screen: FTRect(x: 0, y: 0, width: 400, height: 900),
                                elements: [list, row], truncatedCount: 0)
    }
    func snapshot(bypassingCache: Bool) async throws -> SnapshotResponse { try await snapshot() }
    func swipe(_ direction: FTSwipeDirection) async throws { swipes += 1 }
    func swipe(_ direction: FTSwipeDirection, intent: FTSwipeIntent, path: FTSwipePath?) async throws { swipes += 1 }
    func status() async throws -> StatusResponse { StatusResponse(ready: true, device: "fake", osVersion: "-", sessionBundleID: nil) }
    func install(packagePath: String) async throws -> String? { nil }
    func uninstall(bundleID: String) async throws {}
    func launch(bundleID: String) async throws {}
    func isAppForeground(bundleID: String) async throws -> Bool { true }
    func tap(ref: Int) async throws {}
    func tap(x: Double, y: Double) async throws {}
    func type(ref: Int?, text: String) async throws {}
    func press(ref: Int, duration: Double) async throws {}
    func screenshot() async throws -> Data { Data() }
    func terminate() async throws {}
}

final class ScrollSearchAppGoneMidwayTests: XCTestCase {
    private func run(processRunning: Bool) async -> (StepOutcome, OwnerChangesAfterSwipeDriver) {
        let driver = OwnerChangesAfterSwipeDriver()
        let executor = StepExecutor(driver: driver, isAndroid: true, tunables: RunTunables())
        executor.launchedBundleID = "com.app"
        executor.appProcessRunning = { _ in processRunning }
        let outcome = await executor.execute(FlowStep(action: "tap", locator: FlowLocator(id: "row_nope"), direction: "up", maxSwipes: 6))
        return (outcome, driver)
    }

    func testStopsWhenTheAppDiedDuringTheSearch() async {
        let (outcome, driver) = await run(processRunning: false)
        guard case .failed(let message) = outcome.status else { return XCTFail("\(outcome.status)") }
        XCTAssertTrue(message.contains("is not running"), message)
        XCTAssertTrue(message.contains("the search stopped after 1 swipe(s)"), message)
        XCTAssertFalse(message.contains("nothing was sent"), message)
        XCTAssertEqual(driver.swipes, 1, "落ちた後も払い続けた")
    }

    func testKeepsSearchingWhileTheAppIsAlive() async {
        let (_, driver) = await run(processRunning: true)
        XCTAssertGreaterThan(driver.swipes, 1, "生きているのに止めた")
    }

    /// notExist(scroll:) は、探索が落ちたアプリで止まったら、その場で止まった事実を言って失敗する
    func testNotExistDoesNotPassWhenTheAppDied() async {
        let driver = OwnerChangesAfterSwipeDriver()
        let executor = StepExecutor(driver: driver, isAndroid: true, tunables: RunTunables())
        executor.launchedBundleID = "com.app"
        executor.appProcessRunning = { _ in false }
        let outcome = await executor.execute({ var step = FlowStep(assert: "notExists", locator: FlowLocator(id: "row_nope"), timeout: 0, occlusionGuard: false)
            step.direction = "up"; step.maxSwipes = 6; return step }())
        guard case .failed(let message) = outcome.status else { return XCTFail("落ちたアプリで無いと言った: \(outcome.status)") }
        // 後段の砦(通った検証を別アプリの木なら落とす)だけだと、探索が止まった事実を言わない
        XCTAssertTrue(message.contains("the search stopped after 1 swipe(s)"), message)
        XCTAssertNil(outcome.failureKind)
    }
}
