// 39周目 iultra F2・amax F1: 手前のダイアログが裏を木から隠した画面の notExist は緑のまま(決定)、注記で事実を言う。
// Android は WebView 向けの tree-underreported と「id の綴りを確かめよ」が出ていた

import Foundation
import XCTest
@testable import FTCore

final class AbsenceBehindModalNoteTests: XCTestCase {
    private func notExist(scope: ModalScopeCover?, isAndroid: Bool = false, windows: [String]? = nil) async -> StepOutcome {
        let executor = StepExecutor(driver: ModalTreeDriver(scope: scope), isAndroid: isAndroid, tunables: RunTunables())
        if let windows { executor.foregroundWindowLines = { _ in windows } }
        return await executor.execute(FlowStep(assert: "notExists", locator: FlowLocator(id: "row_behind"), timeout: 0))
    }

    func testIOSModalScopeIsNotedAndThePassStays() async {
        let outcome = await notExist(scope: ModalScopeCover(droppedCount: 2, frames: []))
        guard case .passed = outcome.status else { return XCTFail("合否を変えた: \(outcome.status)") }
        XCTAssertTrue(outcome.notes.contains(.absenceBehindModal), "\(outcome.notes)")
        XCTAssertFalse(outcome.notes.contains(.treeUnderreported))
    }

    func testAndroidOwnDialogWindowIsNoted() async {
        let outcome = await notExist(scope: nil, isAndroid: true,
                                     windows: ["com.example.app/Dialog " + StepExecutor.ownDialogWindowMarker])
        guard case .passed = outcome.status else { return XCTFail("\(outcome.status)") }
        XCTAssertTrue(outcome.notes.contains(.absenceBehindModal), "\(outcome.notes)")
    }

    func testNoNoteWithoutADeclaredDialog() async {
        let ios = await notExist(scope: nil)
        XCTAssertFalse(ios.notes.contains(.absenceBehindModal))
        let android = await notExist(scope: nil, isAndroid: true, windows: [])
        XCTAssertFalse(android.notes.contains(.absenceBehindModal))
    }
}

private final class ModalTreeDriver: AppDriver {
    let scope: ModalScopeCover?
    init(scope: ModalScopeCover?) { self.scope = scope }
    func snapshot() async throws -> SnapshotResponse {
        let button = ElementInfo(ref: 1, type: "button", identifier: "btn_ok", label: "OK", value: nil, placeholder: nil,
                                 enabled: true, frame: FTRect(x: 100, y: 400, width: 200, height: 50), depth: 1)
        return SnapshotResponse(sessionBundleID: "com.example.app", screen: FTRect(x: 0, y: 0, width: 402, height: 874),
                                elements: [button], truncatedCount: 0, modalScope: scope)
    }
    func status() async throws -> StatusResponse { StatusResponse(ready: true, device: "fake", osVersion: "-", sessionBundleID: nil) }
    func install(packagePath: String) async throws -> String? { nil }
    func uninstall(bundleID: String) async throws {}
    func launch(bundleID: String) async throws {}
    func isAppForeground(bundleID: String) async throws -> Bool { true }
    func tap(ref: Int) async throws {}
    func tap(x: Double, y: Double) async throws {}
    func type(ref: Int?, text: String) async throws {}
    func press(ref: Int, duration: Double) async throws {}
    func swipe(_ direction: FTSwipeDirection) async throws {}
    func screenshot() async throws -> Data { Data() }
    func terminate() async throws {}
}
