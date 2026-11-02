// ref なしの type / clear / IME Enter の宛先 `focusedEditable`。Android 13 の Compose では
// findFocus(FOCUS_INPUT) が返すノードの isFocused が、焦点を移した後も true のまま古い(Pixel 4a の logcat で実測:
// 取り直すと false で、別の欄が true)。取り直さずに採ると前の欄へ入って「入った」と言う。
// ソース走査でこの退行を止める。

import XCTest

final class InputInjectorFocusedEditableTests: XCTestCase {

    private func source() throws -> String {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // FTAndroidTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // リポジトリルート
        return try String(contentsOf: root.appendingPathComponent(
            "AndroidRunner/src/com/example/ftbridge/InputInjector.java"), encoding: .utf8)
    }

    func testFindFocusResultIsRefreshedBeforeItIsTrusted() throws {
        let text = try source()
        guard let start = text.range(of: "private static AccessibilityNodeInfo focusedEditable("),
              let end = text[start.upperBound...].range(of: "\n    /**") else {
            return XCTFail("focusedEditable が見つからない(改名したら走査も直す)")
        }
        let body = text[start.upperBound..<end.lowerBound]
        XCTAssertTrue(body.contains("focus.refresh() && focus.isFocused()"),
                      "findFocus の欄は取り直して今も焦点が立っているときだけ採ること")
    }

    func testTreeWalkRefreshesEditablesBeforeReadingFocus() throws {
        let text = try source()
        XCTAssertTrue(text.contains("node.isEditable() && node.refresh() && node.isFocused()"),
                      "木から焦点の欄を探すときも、editable は取り直してから isFocused を読むこと")
    }
}
