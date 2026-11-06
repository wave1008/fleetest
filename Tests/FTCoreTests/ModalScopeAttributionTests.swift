// OI-180 ②: in-app が「accessibilityViewIsModal の外を木から外した」と申告した木では、対象が無い理由をキーボードに帰属せず、
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

    func testFailureMessageUsesModalHintAndDropsKeyboardClause() throws {
        let src = try source("Sources/FTCore/StepExecutor+Actions.swift")
        XCTAssertTrue(src.contains("let leftHint = await leftForegroundHint() ?? Self.modalScopeHint(hintSnapshot)"))
        XCTAssertTrue(src.contains("keyboardClause = Self.hasModalScope(snapshot) ? \"\" : Self.keyboardResizedHint(snapshot)"))
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
