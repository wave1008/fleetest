import Foundation
import XCTest
@testable import FTCore

/// Android で欄の中心が木に出ない別ウィンドウ(候補のポップアップ)の下なら、type / clearInput は撃たずに断る
/// (43周目 alocal F2・F3: CMP の候補「Japan」を焦点のタップが選び、上の欄が書き換わって ✅)
final class OverlayWindowFieldRefusalTests: XCTestCase {
    private func run(_ step: FlowStep, overlay: [FTRect]?) async -> (StepOutcome, PopupDriver) {
        let driver = PopupDriver(overlay: overlay)
        let executor = StepExecutor(driver: driver, isAndroid: true, tunables: RunTunables())
        return (await executor.execute(step), driver)
    }

    private let popup = FTRect(x: 48, y: 1152, width: 1184, height: 432)

    func testTypeIntoAFieldUnderAPopupWindowIsRefused() async {
        let (outcome, driver) = await run(FlowStep(action: "type", locator: FlowLocator(id: "field_number"), text: "42", timeout: 0.1),
                                          overlay: [popup])
        guard case .failed(let message) = outcome.status else { return XCTFail("覆いの下へ打った: \(outcome.status)") }
        XCTAssertTrue(message.contains("overlay window"), message)
        XCTAssertEqual(driver.touches, 0, "断ったのに撃った")
    }

    func testClearAFieldUnderAPopupWindowIsRefused() async {
        let (outcome, driver) = await run(FlowStep(action: "clearInput", locator: FlowLocator(id: "field_number"), timeout: 0.1),
                                          overlay: [popup])
        guard case .failed(let message) = outcome.status else { return XCTFail("覆いの下を消した: \(outcome.status)") }
        XCTAssertTrue(message.contains("overlay window"), message)
        XCTAssertEqual(driver.touches, 0, "断ったのに撃った")
    }

    /// 陽性対照: 覆いが無ければ打つ
    func testTypeWithoutAnOverlayGoesOn() async {
        let (outcome, driver) = await run(FlowStep(action: "type", locator: FlowLocator(id: "field_number"), text: "42", timeout: 0.1),
                                          overlay: nil)
        if case .failed(let message) = outcome.status { XCTAssertFalse(message.contains("overlay window"), message) }
        XCTAssertGreaterThan(driver.touches, 0, "覆いが無いのに撃たなかった")
    }
}

private final class PopupDriver: AppDriver {
    let overlay: [FTRect]?
    var touches = 0
    private var value = ""
    init(overlay: [FTRect]?) { self.overlay = overlay }
    var supportsCacheBypass: Bool { true }
    func snapshot(bypassingCache: Bool) async throws -> SnapshotResponse { try await snapshot() }
    func snapshot() async throws -> SnapshotResponse {
        let field = ElementInfo(ref: 1, type: "textField", identifier: "field_number", label: nil, value: value, placeholder: nil,
                                enabled: true, frame: FTRect(x: 48, y: 1164, width: 1184, height: 192), depth: 1)
        return SnapshotResponse(sessionBundleID: "com.example.app", screen: FTRect(x: 0, y: 0, width: 1280, height: 2856),
                                elements: [field], truncatedCount: 0, overlayWindowFrames: overlay)
    }
    func status() async throws -> StatusResponse { StatusResponse(ready: true, device: "fake", osVersion: "-", sessionBundleID: nil) }
    func install(packagePath: String) async throws -> String? { nil }
    func uninstall(bundleID: String) async throws {}
    func launch(bundleID: String) async throws {}
    func isAppForeground(bundleID: String) async throws -> Bool { true }
    func tap(ref: Int) async throws { touches += 1 }
    func tap(x: Double, y: Double) async throws { touches += 1 }
    func type(ref: Int?, text: String) async throws { touches += 1; value += text }
    func clearInput(ref: Int?) async throws { touches += 1; value = "" }
    func press(ref: Int, duration: Double) async throws {}
    func swipe(_ direction: FTSwipeDirection) async throws {}
    func screenshot() async throws -> Data { Data() }
    func terminate() async throws {}
}
