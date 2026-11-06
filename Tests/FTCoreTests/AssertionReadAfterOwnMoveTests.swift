// 画面を動かす操作(tap 等)の直後のアサーションは、最初の1読みでキャッシュを迂回する(OI-161 ⑥:
// Android の素取得は tap の直後に前の値を返しうる)。操作の無い最初のアサーション・2本目以降のアサーションは素取得のまま
// (毎回払わない)。迂回した読みはキャッシュを更新しないので、次のロケータ操作の解決の1枚も迂回に残す。

import XCTest
@testable import FTCore

final class AssertionReadAfterOwnMoveTests: XCTestCase {

    private final class RecordingDriver: AppDriver {
        private(set) var reads: [Bool] = []
        var supportsCacheBypass: Bool { true }
        func status() async throws -> StatusResponse {
            StatusResponse(ready: true, device: "fake", osVersion: "-", sessionBundleID: nil)
        }
        func install(packagePath: String) async throws -> String? { nil }
        func uninstall(bundleID: String) async throws {}
        func isAppForeground(bundleID: String) async throws -> Bool { true }
        func launch(bundleID: String) async throws {}
        func snapshot() async throws -> SnapshotResponse { try await snapshot(bypassingCache: false) }
        func snapshot(bypassingCache: Bool) async throws -> SnapshotResponse {
            reads.append(bypassingCache)
            return SnapshotResponse(
                sessionBundleID: nil, screen: FTRect(x: 0, y: 0, width: 400, height: 800),
                elements: [ElementInfo(ref: 1, type: "button", identifier: "sw", label: "sw", value: nil,
                                       placeholder: nil, enabled: true,
                                       frame: FTRect(x: 0, y: 0, width: 100, height: 40), depth: 0)],
                truncatedCount: 0)
        }
        func tap(ref: Int) async throws {}
        func tap(x: Double, y: Double) async throws {}
        func type(ref: Int?, text: String) async throws {}
        func swipe(_ direction: FTSwipeDirection) async throws {}
        func press(ref: Int, duration: Double) async throws {}
        func screenshot() async throws -> Data { Data() }
        func terminate() async throws {}
    }

    private func exists() -> FlowStep { FlowStep(assert: "exists", locator: FlowLocator(id: "sw"), timeout: 2) }

    func testFirstAssertionReadAfterATapBypassesTheCache() async {
        let driver = RecordingDriver()
        let executor = StepExecutor(driver: driver, isAndroid: true, tunables: RunTunables(), uiFramework: .androidView)
        _ = await executor.execute(FlowStep(action: "tap", locator: FlowLocator(id: "sw")))
        let before = driver.reads.count
        _ = await executor.execute(exists())
        XCTAssertEqual(driver.reads[before], true, "tap の直後のアサーションの最初の読みが素取得だった: \(driver.reads)")
        XCTAssertTrue(executor.nextResolveBypassesCache, "迂回した読みの後、次の解決の迂回が消えた(MN-38)")
    }

    func testOnlyTheFirstAssertionAfterTheTapBypasses() async {
        let driver = RecordingDriver()
        let executor = StepExecutor(driver: driver, isAndroid: true, tunables: RunTunables(), uiFramework: .androidView)
        _ = await executor.execute(FlowStep(action: "tap", locator: FlowLocator(id: "sw")))
        _ = await executor.execute(exists())
        let before = driver.reads.count
        _ = await executor.execute(exists())
        XCTAssertEqual(driver.reads[before], false, "2本目のアサーションまで毎回迂回している: \(driver.reads)")
    }

    func testAssertionWithoutAPrecedingMoveReadsPlain() async {
        let driver = RecordingDriver()
        let executor = StepExecutor(driver: driver, isAndroid: true, tunables: RunTunables(), uiFramework: .androidView)
        _ = await executor.execute(exists())
        XCTAssertEqual(driver.reads.first, false, "\(driver.reads)")
    }
}
