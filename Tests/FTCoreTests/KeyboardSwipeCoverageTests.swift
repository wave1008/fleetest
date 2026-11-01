import XCTest
@testable import FTCore

/// 座標なしの swipe の「キーボードが画面の大半を覆う」判定は `KeyboardSwipeCoverage` の1箇所(MCP と DSL が共有)
final class KeyboardSwipeCoverageTests: XCTestCase {
    private func snap(screen: FTRect, keyboard: FTRect) -> SnapshotResponse {
        SnapshotResponse(sessionBundleID: nil, screen: screen, elements: [], truncatedCount: 0,
                         keyboardShown: true, keyboardFrame: keyboard)
    }

    func testFullScreenImeCoversButBottomKeyboardDoesNot() {
        let full = snap(screen: FTRect(x: 0, y: 0, width: 2400, height: 1080),
                        keyboard: FTRect(x: 142, y: 137, width: 2282, height: 943))
        XCTAssertNotNil(KeyboardSwipeCoverage.coveringFrame(full))
        let low = snap(screen: FTRect(x: 0, y: 0, width: 402, height: 874),
                       keyboard: FTRect(x: 0, y: 600, width: 402, height: 274))
        XCTAssertNil(KeyboardSwipeCoverage.coveringFrame(low))
    }

    /// DSL の swipe が共有の判定を通って注記を積む(経路の表: MCP = keyboardSwipeAreaNote / DSL = executeDirectSwipe)
    func testDirectSwipeAddsTheSharedNote() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let text = try String(contentsOf: root.appendingPathComponent("Sources/FTCore/StepExecutor+DirectActions.swift"),
                              encoding: .utf8)
        XCTAssertTrue(text.contains("KeyboardSwipeCoverage.coveringFrame(snapshot)"))
        XCTAssertTrue(text.contains("notes.append(KeyboardSwipeCoverage.note(keyboard))"))
    }
}
