// 要素 0 個の木を「無い」の根拠にしないこと(起動直後の空の木で notExist が緑になった)。
// 両方向: 空の木では通さない / 待って要素が現れた木・空でない木では従来どおり通る・赤になる。

import XCTest
@testable import FTCore

private final class FramesDriver: AppDriver {
    let frames: [[ElementInfo]]
    private(set) var snapshotCount = 0
    init(frames: [[ElementInfo]]) { self.frames = frames }

    func status() async throws -> StatusResponse {
        StatusResponse(ready: true, device: "fake", osVersion: "-", sessionBundleID: nil)
    }
    func install(packagePath: String) async throws -> String? { nil }
    func uninstall(bundleID: String) async throws {}
    func launch(bundleID: String) async throws {}
    func isAppForeground(bundleID: String) async throws -> Bool { true }
    func snapshot() async throws -> SnapshotResponse {
        snapshotCount += 1
        return SnapshotResponse(sessionBundleID: nil, screen: FTRect(x: 0, y: 0, width: 400, height: 800),
                                elements: frames[min(snapshotCount - 1, frames.count - 1)], truncatedCount: 0)
    }
    func tap(ref: Int) async throws {}
    func tap(x: Double, y: Double) async throws {}
    func type(ref: Int?, text: String) async throws {}
    func press(ref: Int, duration: Double) async throws {}
    func swipe(_ direction: FTSwipeDirection) async throws {}
    func screenshot() async throws -> Data { Data() }
    func terminate() async throws {}
}

final class EmptyTreeAbsenceTests: XCTestCase {
    private func node(_ ref: Int, id: String) -> ElementInfo {
        ElementInfo(ref: ref, type: "button", identifier: id, label: id, value: nil, placeholder: nil, enabled: true,
                    frame: FTRect(x: 0, y: Double(ref) * 20, width: 100, height: 18), depth: 1)
    }

    private func isPassed(_ status: StepResult.Status) -> Bool {
        if case .passed = status { return true }
        if case .passedViaFallback = status { return true }
        return false
    }

    private func reason(_ status: StepResult.Status) -> String? {
        if case .failed(let r) = status { return r }
        return nil
    }

    private func notExist(timeout: Double) -> FlowStep {
        FlowStep(assert: "notExists", locator: FlowLocator(id: "txt_home_marker"), timeout: timeout, occlusionGuard: false)
    }

    func testPureJudgmentIsEmptyTreeOnly() {
        let screen = FTRect(x: 0, y: 0, width: 400, height: 800)
        XCTAssertTrue(StepExecutor.treeIsEmptyForAbsence(
            SnapshotResponse(sessionBundleID: nil, screen: screen, elements: [], truncatedCount: 0)))
        XCTAssertFalse(StepExecutor.treeIsEmptyForAbsence(
            SnapshotResponse(sessionBundleID: nil, screen: screen, elements: [node(1, id: "a")], truncatedCount: 0)))
    }

    func testNotExistDoesNotPassOnAnAlwaysEmptyTree() async {
        let driver = FramesDriver(frames: [[]])
        let outcome = await StepExecutor(driver: driver, isAndroid: false, tunables: RunTunables())
            .execute(notExist(timeout: 0))
        XCTAssertFalse(isPassed(outcome.status), "空の木で不在を通した(誤った成功): \(outcome.status)")
        XCTAssertTrue(reason(outcome.status)?.contains("0 elements") == true, "\(outcome.status)")
    }

    func testNotExistRereadsAnEmptyTreeUntilItHasContent() async {
        let driver = FramesDriver(frames: [[], [], [node(1, id: "other")]])
        let outcome = await StepExecutor(driver: driver, isAndroid: false, tunables: RunTunables())
            .execute(notExist(timeout: 5))
        XCTAssertTrue(isPassed(outcome.status), "\(outcome.status)")
        XCTAssertGreaterThanOrEqual(driver.snapshotCount, 3)
    }

    func testNotExistStillFailsWhenTheMarkerAppearsAfterAnEmptyRead() async {
        let driver = FramesDriver(frames: [[], [node(1, id: "txt_home_marker")]])
        let outcome = await StepExecutor(driver: driver, isAndroid: false, tunables: RunTunables())
            .execute(notExist(timeout: 0.5))
        XCTAssertNotNil(reason(outcome.status), "\(outcome.status)")
        XCTAssertFalse(reason(outcome.status)?.contains("0 elements") == true, "\(outcome.status)")
    }

    func testNotExistPassesOnANonEmptyTreeWithoutTheElement() async {
        let driver = FramesDriver(frames: [[node(1, id: "other")]])
        let outcome = await StepExecutor(driver: driver, isAndroid: false, tunables: RunTunables())
            .execute(notExist(timeout: 0))
        XCTAssertTrue(isPassed(outcome.status), "\(outcome.status)")
    }

    func testCountZeroDoesNotPassOnAnAlwaysEmptyTree() async {
        let step = FlowStep(assert: "count", locator: FlowLocator(type: "button"), timeout: 0, expectedCount: 0)
        let outcome = await StepExecutor(driver: FramesDriver(frames: [[]]), isAndroid: false, tunables: RunTunables())
            .execute(step)
        XCTAssertFalse(isPassed(outcome.status), "空の木で 0 件を通した(誤った成功): \(outcome.status)")
        XCTAssertTrue(reason(outcome.status)?.contains("0 elements") == true, "\(outcome.status)")
    }

    func testCountZeroPassesOnANonEmptyTreeWithNoMatch() async {
        let step = FlowStep(assert: "count", locator: FlowLocator(type: "row"), timeout: 0, expectedCount: 0)
        let outcome = await StepExecutor(driver: FramesDriver(frames: [[node(1, id: "a")]]), isAndroid: false,
                                         tunables: RunTunables()).execute(step)
        XCTAssertTrue(isPassed(outcome.status), "\(outcome.status)")
    }
}
