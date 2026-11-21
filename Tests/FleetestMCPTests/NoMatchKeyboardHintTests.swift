import XCTest
import FTCore
@testable import fleetest_mcp

/// 一致なしの断りの「木に無い理由の候補」。iOS でもキーボードが出ていれば閉じる手を先に言う
/// (Compose Multiplatform の iOS は窓をキーボードの上へ詰め、下の要素が木から消える)
final class NoMatchKeyboardHintTests: XCTestCase {
    private func snapshot(keyboard: FTRect?) -> SnapshotResponse {
        SnapshotResponse(sessionBundleID: "com.ftester.e2e",
                         screen: FTRect(x: 0, y: 0, width: 375, height: 667),
                         elements: [], truncatedCount: 0, keyboardFrame: keyboard)
    }

    func testIOSWithKeyboardUpSaysCloseIt() {
        let hint = MCPServer.hiddenOrOffscreenHint(in: snapshot(keyboard: FTRect(x: 0, y: 399, width: 375, height: 268)),
                                                   isAndroid: false)
        XCTAssertTrue(hint.contains("ft_hide_keyboard"), hint)
        XCTAssertFalse(hint.contains("ft_scroll_to"), hint)
    }

    func testIOSWithoutKeyboardSaysScroll() {
        let hint = MCPServer.hiddenOrOffscreenHint(in: snapshot(keyboard: nil), isAndroid: false)
        XCTAssertTrue(hint.contains("ft_scroll_to"), hint)
    }

    /// 隠れたキーボードは画面の外の矩形で来る(`KeyboardWait.isShown` が出ていないと読む)
    func testIOSWithOffscreenKeyboardFrameSaysScroll() {
        let hint = MCPServer.hiddenOrOffscreenHint(in: snapshot(keyboard: FTRect(x: 0, y: 667, width: 375, height: 268)),
                                                   isAndroid: false)
        XCTAssertTrue(hint.contains("ft_scroll_to"), hint)
    }
}
