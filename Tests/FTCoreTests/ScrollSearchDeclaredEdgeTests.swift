// 探索(scrollTo / select の scroll:)の払いの前に、容器が「その向きへは動けない」と申告していれば払わずに端と確定する
// (OI-163 ⑩: 上端の PullToRefresh の一覧への scroll: .up が更新を走らせた)。判定は scrollToEdge と共有
// (StepExecutor.declaredAtEdge)。申告の無い木(iOS)は従来どおり払って確かめる。

import XCTest
@testable import FTCore

private final class DeclaredEdgeDriver: AppDriver {
    private let scrollActions: [String]?
    private(set) var swipes = 0
    init(scrollActions: [String]?) { self.scrollActions = scrollActions }

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
    func swipe(_ direction: FTSwipeDirection) async throws { swipes += 1 }
    func swipe(_ direction: FTSwipeDirection, intent: FTSwipeIntent, path: FTSwipePath?) async throws { swipes += 1 }
    func snapshot() async throws -> SnapshotResponse {
        SnapshotResponse(sessionBundleID: nil, screen: FTRect(x: 0, y: 0, width: 1280, height: 2800),
                         elements: [
                            ElementInfo(ref: 3, type: "other", identifier: "list", label: nil, value: nil,
                                        placeholder: nil, enabled: true,
                                        frame: FTRect(x: 0, y: 516, width: 1280, height: 2268), depth: 1,
                                        scrollable: true, scrollActions: scrollActions),
                            ElementInfo(ref: 4, type: "clickable", identifier: "row_1", label: "行", value: nil,
                                        placeholder: nil, enabled: true,
                                        frame: FTRect(x: 20, y: 600, width: 300, height: 56), depth: 2)],
                         truncatedCount: 0)
    }
}

final class ScrollSearchDeclaredEdgeTests: XCTestCase {
    private func step() -> FlowStep {
        FlowStep(action: "scrollTo", locator: FlowLocator(id: "missing"), direction: "down", maxSwipes: 8)
    }

    func testSearchSendsNoSwipeWhenContainerDeclaresNoMoveInThatDirection() async throws {
        let driver = DeclaredEdgeDriver(scrollActions: ["forward", "down"])
        let result = await StepExecutor(driver: driver, isAndroid: true, tunables: RunTunables()).execute(step())
        XCTAssertEqual(driver.swipes, 0, "上端と申告された容器へ探索の払いを送った(更新が走る)")
        guard case .failed = result.status else { return XCTFail("\(result.status)") }
    }

    func testSearchStillSwipesWhenContainerCanMoveThatWay() async throws {
        let driver = DeclaredEdgeDriver(scrollActions: ["backward", "forward", "up", "down"])
        _ = await StepExecutor(driver: driver, isAndroid: true, tunables: RunTunables()).execute(step())
        XCTAssertGreaterThan(driver.swipes, 0)
    }

    func testSearchStillSwipesWhenNothingIsDeclared() async throws {
        let driver = DeclaredEdgeDriver(scrollActions: nil)
        _ = await StepExecutor(driver: driver, isAndroid: false, tunables: RunTunables()).execute(step())
        XCTAssertGreaterThan(driver.swipes, 0, "未申告(iOS)の探索まで払わなくなった")
    }

    func testDeclaredAtEdgeHelperIsPureFunctionOfTheTree() async throws {
        let atTop = try await DeclaredEdgeDriver(scrollActions: ["forward", "down"]).snapshot()
        XCTAssertTrue(StepExecutor.declaredAtEdge(step: step(), in: atTop, finger: .down))
        XCTAssertFalse(StepExecutor.declaredAtEdge(step: step(), in: atTop, finger: .up))
    }
}
