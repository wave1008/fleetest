import XCTest
@testable import FTCore

final class KeyboardShownStateTests: XCTestCase {
    private func snap(shown: Bool?, frame: FTRect? = nil) -> SnapshotResponse {
        SnapshotResponse(sessionBundleID: nil, screen: FTRect(x: 0, y: 0, width: 400, height: 800),
                         elements: [], truncatedCount: 0, keyboardShown: shown, keyboardFrame: frame)
    }

    /// XCUITest ランナーはキーボードの無い木で false を返す。nil(不明)と区別できること
    func testExplicitFalseWithoutFrameIsKnownHidden() {
        XCTAssertEqual(KeyboardWait.shownState(snap(shown: false)), false)
        XCTAssertNil(KeyboardWait.shownState(snap(shown: nil)))
    }

    func testOffscreenFrameWinsOverShownTrue() {
        XCTAssertEqual(KeyboardWait.shownState(snap(shown: true, frame: FTRect(x: 0, y: 900, width: 400, height: 300))), false)
    }

    /// Runner が keyboardShown を nil に戻すと keyboardIsNotShown が全画面で赤になる
    func testRunnerReportsFalseNotNilWhenKeyboardAbsent() throws {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Runner/FleetestRunnerUITests/BridgeRouter.swift")
        let src = try String(contentsOf: url, encoding: .utf8)
        XCTAssertTrue(src.contains("keyboardShown: cap.keyboardFrame != nil,"))
        XCTAssertFalse(src.contains("keyboardFrame != nil ? true : nil"))
    }
}
