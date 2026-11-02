// 枠なしの払いが「nothing moved at all」で終わる経路で、木に唯一の scrollable があればその中で1回払い直す。
// ブリッジ既定の払い(path == nil)は一覧に当たらず、容器の中の座標つきの払いだけが動く画面を模す。

import XCTest
@testable import FTCore

private final class LowListDriver: AppDriver {
    let containers: [FTRect]
    private(set) var defaultSwipes = 0
    private(set) var pathSwipes = 0
    private var offset = 0.0
    init(containers: [FTRect]) { self.containers = containers }

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
    func swipe(_ direction: FTSwipeDirection) async throws { defaultSwipes += 1 }
    func swipe(_ direction: FTSwipeDirection, intent: FTSwipeIntent, path: FTSwipePath?) async throws {
        guard let path else { defaultSwipes += 1; return }
        pathSwipes += 1
        if containers.contains(where: { $0.x <= path.fromX && path.fromX <= $0.x + $0.width
            && $0.y <= path.fromY && path.fromY <= $0.y + $0.height }), pathSwipes <= 2 {
            offset += 60
        }
    }
    func snapshot() async throws -> SnapshotResponse {
        var elements = containers.enumerated().map { index, frame in
            ElementInfo(ref: 10 + index, type: "other", identifier: "list\(index)", label: nil, value: nil,
                        placeholder: nil, enabled: true, frame: frame, depth: 1,
                        scrollable: true, scrollActions: ["up", "down"])
        }
        elements.append(ElementInfo(ref: 1, type: "clickable", identifier: "anchor", label: "行", value: nil,
                                    placeholder: nil, enabled: true,
                                    frame: FTRect(x: 20, y: 800 - offset, width: 300, height: 56), depth: 2))
        return SnapshotResponse(sessionBundleID: nil, screen: FTRect(x: 0, y: 0, width: 2400, height: 1080),
                                elements: elements, truncatedCount: 0)
    }
}

final class ScrollSearchContainerRedirectTests: XCTestCase {
    private let low = FTRect(x: 0, y: 680, width: 2400, height: 400)
    private func step() -> FlowStep {
        FlowStep(action: "scrollTo", locator: FlowLocator(id: "missing"), direction: "up", maxSwipes: 8)
    }

    func testUniqueContainerHelper() async throws {
        let one = try await LowListDriver(containers: [low]).snapshot()
        XCTAssertNotNil(ContainerGeometry.uniqueScrollContainer(in: one, vertical: true))
        let two = try await LowListDriver(containers: [low, FTRect(x: 0, y: 0, width: 2400, height: 300)]).snapshot()
        XCTAssertNil(ContainerGeometry.uniqueScrollContainer(in: two, vertical: true))
    }

    func testRedirectsIntoTheOnlyContainerAndKeepsSearching() async throws {
        let driver = LowListDriver(containers: [low])
        let result = await StepExecutor(driver: driver, isAndroid: true, tunables: RunTunables()).execute(step())
        XCTAssertGreaterThan(driver.pathSwipes, 0, "容器の中で払い直していない")
        XCTAssertTrue(result.notes.contains(.scrollRedirectedToContainer), "\(result.notes)")
        guard case .failed(let reason) = result.status else { return XCTFail("\(result.status)") }
        XCTAssertFalse(reason.contains("nothing moved at all"), reason)
        XCTAssertTrue(reason.contains("reached its end"), reason)
    }

    func testDoesNotRedirectWhenSeveralContainers() async throws {
        let driver = LowListDriver(containers: [low, FTRect(x: 0, y: 0, width: 2400, height: 300)])
        let result = await StepExecutor(driver: driver, isAndroid: true, tunables: RunTunables()).execute(step())
        XCTAssertEqual(driver.pathSwipes, 0)
        XCTAssertFalse(result.notes.contains(.scrollRedirectedToContainer))
        guard case .failed(let reason) = result.status else { return XCTFail("\(result.status)") }
        XCTAssertTrue(reason.contains("nothing moved at all"), reason)
    }
}
