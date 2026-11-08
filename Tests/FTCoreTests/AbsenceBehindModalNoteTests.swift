// 39周目 iultra F2・amax F1: 手前のダイアログが裏を木から隠した画面の notExist は緑のまま(決定)、注記で事実を言う。
// Android は WebView 向けの tree-underreported と「id の綴りを確かめよ」が出ていた

import Foundation
import XCTest
@testable import FTCore

final class AbsenceBehindModalNoteTests: XCTestCase {
    private func notExist(scope: ModalScopeCover?, frontWindow: FrontWindowCover? = nil, isAndroid: Bool = false,
                          windows: [String]? = nil) async -> StepOutcome {
        let executor = StepExecutor(driver: ModalTreeDriver(scope: scope, frontWindow: frontWindow), isAndroid: isAndroid,
                                    tunables: RunTunables())
        if let windows { executor.foregroundWindowLines = { _ in windows } }
        return await executor.execute(FlowStep(assert: "notExists", locator: FlowLocator(id: "row_behind"), timeout: 0))
    }

    func testIOSModalScopeIsNotedAndThePassStays() async {
        let outcome = await notExist(scope: ModalScopeCover(droppedCount: 2, frames: []))
        guard case .passed = outcome.status else { return XCTFail("合否を変えた: \(outcome.status)") }
        XCTAssertTrue(outcome.notes.contains(.absenceBehindModal), "\(outcome.notes)")
        XCTAssertFalse(outcome.notes.contains(.treeUnderreported))
        // コードだけでなく文言もステップの説明に出す(レポート・コンソールが読むのは説明。40周目 iultra F1)
        XCTAssertTrue(outcome.driverFallback?.contains("in front of the screen keeps what is behind it out of the tree") == true,
                      "文言がステップの説明に出ない: \(outcome.driverFallback ?? "nil")")
    }

    /// 手前の別の UIWindow(キーウィンドウでない全面モーダル)が裏を木から外した申告でも付ける(40周目 im4 F2)
    func testIOSFrontWindowCoverIsNoted() async {
        let outcome = await notExist(scope: nil, frontWindow: FrontWindowCover(droppedCount: 15, frames: [FTRect(x: 0, y: 0, width: 402, height: 874)]))
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
    let frontWindow: FrontWindowCover?
    init(scope: ModalScopeCover?, frontWindow: FrontWindowCover?) { self.scope = scope; self.frontWindow = frontWindow }
    func snapshot() async throws -> SnapshotResponse {
        let button = ElementInfo(ref: 1, type: "button", identifier: "btn_ok", label: "OK", value: nil, placeholder: nil,
                                 enabled: true, frame: FTRect(x: 100, y: 400, width: 200, height: 50), depth: 1)
        return SnapshotResponse(sessionBundleID: "com.example.app", screen: FTRect(x: 0, y: 0, width: 402, height: 874),
                                elements: [button], truncatedCount: 0, coveredByFrontWindow: frontWindow, modalScope: scope)
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
