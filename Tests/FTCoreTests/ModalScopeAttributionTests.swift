// in-app が「accessibilityViewIsModal の外を木から外した」と申告した木では、対象が無い理由をキーボードに帰属せず、
// キーボードを閉じる tap も撃たない。

import XCTest
@testable import FTCore

final class ModalScopeAttributionTests: XCTestCase {
    private func source(_ path: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
        return try String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)
    }

    private func snapshot(scope: ModalScopeCover?, keyboard: Bool = true) -> SnapshotResponse {
        SnapshotResponse(sessionBundleID: "app", screen: FTRect(x: 0, y: 0, width: 402, height: 874),
                         elements: [], truncatedCount: 0, keyboardShown: keyboard,
                         keyboardFrame: keyboard ? FTRect(x: 0, y: 600, width: 402, height: 274) : nil, modalScope: scope)
    }

    func testHintNamesTheModalAndDoesNotSuggestWaitingOrKeyboard() throws {
        let hint = try XCTUnwrap(StepExecutor.modalScopeHint(snapshot(scope: ModalScopeCover(
            droppedCount: 3, frames: [FTRect(x: 20, y: 300, width: 362, height: 200)]))))
        XCTAssertTrue(hint.contains("(20,300 362x200)"))
        XCTAssertTrue(hint.contains("3 element group(s)"))
        XCTAssertTrue(hint.contains("close the modal"))
        XCTAssertTrue(hint.contains("waiting will not bring"))
        XCTAssertFalse(hint.lowercased().contains("hidekeyboard"))
    }

    func testNoHintWithoutTheReport() {
        XCTAssertNil(StepExecutor.modalScopeHint(snapshot(scope: nil)))
        XCTAssertNil(StepExecutor.modalScopeHint(snapshot(scope: ModalScopeCover(droppedCount: 0, frames: []))))
        XCTAssertFalse(StepExecutor.hasModalScope(snapshot(scope: nil)))
        XCTAssertTrue(StepExecutor.hasModalScope(snapshot(scope: ModalScopeCover(droppedCount: 1, frames: []))))
    }

    func testWireShapeRoundTrips() throws {
        let scope = ModalScopeCover(droppedCount: 2, frames: [FTRect(x: 0, y: 100, width: 402, height: 300)])
        let data = try JSONEncoder().encode(snapshot(scope: scope))
        XCTAssertEqual(try JSONDecoder().decode(SnapshotResponse.self, from: data).modalScope, scope)
    }

    /// 閉じる tap の入口はモーダルの申告で断る(キーボードが出ていても撃たない)
    func testKeyboardCloseEntryIsSkippedWhenModalIsReported() throws {
        let src = try source("Sources/FTCore/StepExecutor+TypeClear.swift")
        let entry = try XCTUnwrap(src.range(of: "func resolveAfterClosingKeyboard("))
        let head = String(src[entry.upperBound...].prefix(900))
        let modal = try XCTUnwrap(head.range(of: "guard !Self.hasModalScope(snapshot),"))
        let kb = try XCTUnwrap(head.range(of: "PreFireGuard.keyboardSensitiveActions.contains(action)"))
        XCTAssertLessThan(modal.lowerBound, kb.lowerBound)
    }

    func testFailureMessageDropsKeyboardClauseUnderModal() throws {
        let src = try source("Sources/FTCore/StepExecutor+Actions.swift")
        XCTAssertTrue(src.contains("keyboardClause = Self.hasModalScope(snapshot) ? \"\" : Self.keyboardResizedHint(snapshot)"))
    }

    /// モーダルの中に送れる一覧があれば、tap の「解決できない」はモーダルを名指したうえで送りの案内も言う
    /// (対象はモーダルの裏でなく中の送りの先にありうる。待ちの案内は言わない。56周目 iultra F1 = E2EX-iOS のボトムシート)
    func testTapMissUnderModalKeepsScrollAdviceWhenAListIsInTheModal() async {
        let list = ElementInfo(ref: 1, type: "collectionView", identifier: "list_sheet", label: nil, value: nil, placeholder: nil,
                               enabled: true, frame: FTRect(x: 0, y: 300, width: 402, height: 574), depth: 3, scrollable: true)
        let row = ElementInfo(ref: 2, type: "staticText", identifier: "row_sheet_00", label: "シート行 00", value: nil,
                              placeholder: nil, enabled: true, frame: FTRect(x: 0, y: 300, width: 402, height: 44), depth: 4)
        let modal = ModalScopeCover(droppedCount: 1, frames: [FTRect(x: 0, y: 0, width: 402, height: 874)])
        // 実物のシートの一覧は下端の行が容器の縁をまたぐ(送れる中身がある)
        let lastRow = ElementInfo(ref: 3, type: "staticText", identifier: "row_sheet_12", label: "シート行 12", value: nil,
                                  placeholder: nil, enabled: true, frame: FTRect(x: 0, y: 850, width: 402, height: 44), depth: 4)
        let withList = await tapMissReason(elements: [list, row, lastRow], modal: modal)
        XCTAssertTrue(withList.contains("close the modal"), withList)
        XCTAssertTrue(withList.contains("add scroll:"), withList)
        XCTAssertFalse(withList.contains("add waitSeconds"), withList)
        // 一覧が無ければ従来どおりモーダルの案内だけ
        let withoutList = await tapMissReason(elements: [row], modal: modal)
        XCTAssertTrue(withoutList.contains("close the modal"), withoutList)
        XCTAssertFalse(withoutList.contains("add scroll:"), withoutList)
    }

    /// モーダルの中でも、スコープの容器に中身が無いことは言う(閉じろ・送れに従っても直らない)。
    /// 57周目 im4・imax・alocal: シートの中で葉の見出しを容器にした tap が「モーダルを閉じろ」だけを言った
    func testTapMissUnderModalStillSaysTheScopeContainerHasNothingUnderIt() async {
        let title = ElementInfo(ref: 1, type: "staticText", identifier: "txt_sheet_title", label: "シート", value: nil,
                                placeholder: nil, enabled: true, frame: FTRect(x: 0, y: 300, width: 200, height: 20), depth: 3,
                                keptDepth: 1)
        let option = ElementInfo(ref: 2, type: "button", identifier: "btn_sheet_opt_2", label: "選択肢 2", value: nil,
                                 placeholder: nil, enabled: true, frame: FTRect(x: 0, y: 340, width: 402, height: 44), depth: 4,
                                 keptDepth: 1)
        let modal = ModalScopeCover(droppedCount: 1, frames: [FTRect(x: 0, y: 0, width: 402, height: 874)])
        var locator = FlowLocator(id: "btn_sheet_opt_2")
        locator.scope = [FlowLocator(id: "txt_sheet_title")]
        let reason = await tapMissReason(elements: [title, option], modal: modal, locator: locator)
        XCTAssertTrue(reason.contains("the scope's container #txt_sheet_title"), reason)
        XCTAssertTrue(reason.contains("has nothing under it"), reason)
        XCTAssertFalse(reason.contains("close the modal"), reason)
        XCTAssertFalse(reason.contains("add scroll:"), reason)
        // 検証(exist)も同じ順で理由を1つだけ言う
        let assertion = await tapMissReason(elements: [title, option], modal: modal, locator: locator, assert: "exists")
        XCTAssertTrue(assertion.contains("element not found"), assertion)
        XCTAssertTrue(assertion.contains("has nothing under it"), assertion)
        XCTAssertFalse(assertion.contains("close the modal"), assertion)
        // 容器に中身があれば、検証でも従来どおりモーダルの案内
        let ordinary = await tapMissReason(elements: [title, option], modal: modal, assert: "exists")
        XCTAssertTrue(ordinary.contains("close the modal"), ordinary)
    }

    private func tapMissReason(elements: [ElementInfo], modal: ModalScopeCover,
                               locator: FlowLocator = FlowLocator(id: "row_sheet_28"), assert: String? = nil) async -> String {
        let driver = ModalDriver(snapshot: SnapshotResponse(
            sessionBundleID: "app", screen: FTRect(x: 0, y: 0, width: 402, height: 874), elements: elements,
            truncatedCount: 0, modalScope: modal))
        let outcome = await StepExecutor(driver: driver, isAndroid: false, tunables: RunTunables())
            .execute(assert.map { FlowStep(assert: $0, locator: locator, timeout: 0.2) }
                     ?? FlowStep(action: "tap", locator: locator, timeout: 0.2))
        if case .failed(let text) = outcome.status { return text }
        XCTFail("failed を期待: \(outcome.status)")
        return ""
    }

    private final class ModalDriver: AppDriver {
        let fixed: SnapshotResponse
        init(snapshot: SnapshotResponse) { fixed = snapshot }
        func status() async throws -> StatusResponse {
            StatusResponse(ready: true, device: "fake", osVersion: "-", sessionBundleID: nil)
        }
        func install(packagePath: String) async throws -> String? { nil }
        func uninstall(bundleID: String) async throws {}
        func isAppForeground(bundleID: String) async throws -> Bool { true }
        func launch(bundleID: String) async throws {}
        func snapshot() async throws -> SnapshotResponse { fixed }
        func tap(ref: Int) async throws {}
        func tap(x: Double, y: Double) async throws {}
        func type(ref: Int?, text: String) async throws {}
        func swipe(_ direction: FTSwipeDirection) async throws {}
        func press(ref: Int, duration: Double) async throws {}
        func screenshot() async throws -> Data { Data() }
        func terminate() async throws {}
    }

    func testInAppReportsTheDroppedSiblingsAndBridgeVersionIsBumped() throws {
        let snap = try source("InAppBridge/Sources/InAppSnapshot.swift")
        XCTAssertTrue(snap.contains("tally.recordModal(dropped: dropped"))
        XCTAssertTrue(snap.contains("modalScope: tally.modalResult"))
        let bridge = try source("InAppBridge/Sources/InAppBridge.swift")
        XCTAssertTrue(bridge.contains("modalScope: base.modalScope"))
        XCTAssertGreaterThanOrEqual(BridgeAPI.bridgeProtocolVersion, 278)
    }
}
