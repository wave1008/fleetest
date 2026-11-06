// 探索の始点の木が起こしたアプリでなく別のアプリのものなら、1本も払わずに断る(背面のまま撃つと最初の送りがシェードを開いた)。
// 同じアプリなら従来どおり払う。起こしていない(nil)なら意図した別の面なので止めない

import XCTest
@testable import FTCore

private final class ConstantOwnerDriver: AppDriver, @unchecked Sendable {
    let owner: String
    private(set) var swipes = 0
    init(owner: String) { self.owner = owner }
    func snapshot() async throws -> SnapshotResponse {
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

final class ScrollRefusesOnOtherAppStartTests: XCTestCase {
    private func run(owner: String, launched: String?) async -> (StepOutcome, ConstantOwnerDriver) {
        let driver = ConstantOwnerDriver(owner: owner)
        let executor = StepExecutor(driver: driver, isAndroid: true, tunables: RunTunables())
        executor.launchedBundleID = launched
        let outcome = await executor.execute(FlowStep(action: "scrollTo", locator: FlowLocator(id: "row_nope"), direction: "up", maxSwipes: 4))
        return (outcome, driver)
    }

    func testOtherOwnerAtStartSendsNothingAndSaysSo() async {
        let (outcome, driver) = await run(owner: "com.google.android.apps.nexuslauncher", launched: "com.app")
        XCTAssertEqual(driver.swipes, 0, "別の持ち主の画面へ送りを撃った")
        guard case .failed(let message) = outcome.status else { return XCTFail("\(outcome.status)") }
        XCTAssertTrue(message.contains("com.google.android.apps.nexuslauncher"), message)
        XCTAssertTrue(message.contains("no scroll was sent"), message)
        XCTAssertTrue(message.contains("launch"), message)
    }

    func testSameOwnerStillSwipes() async {
        let (_, driver) = await run(owner: "com.app", launched: "com.app")
        XCTAssertGreaterThan(driver.swipes, 0, "同じアプリなのに払わなかった")
    }

    func testNotLaunchedIsNotRefused() async {
        let (_, driver) = await run(owner: "com.android.settings", launched: nil)
        XCTAssertGreaterThan(driver.swipes, 0, "起こしていない探索を止めた")
    }

    func testRefusalSentenceIsShared() {
        let m = StepExecutor.startedOnOtherAppRefusal(("com.x", "com.app"))
        XCTAssertTrue(m.contains("com.x") && m.contains("com.app") && m.contains("no scroll was sent"), m)
    }
}
