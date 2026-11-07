// ft_tap の ref 経路: 見えている部分を押した応答の並び(OI-163 ⑲)・キーボードが閉じるだけになりうる形の注記。

import XCTest
import FTCore
@testable import fleetest_mcp

final class TapRefKeyboardAndVisiblePartNoteTests: XCTestCase {

    /// 見えている部分の注記が、中心についての警告より前に来る
    func testVisiblePartNoteComesBeforeCentreWarnings() {
        let warning = " (warning: [3] may have hit #btn_bottom_b)"
        let lead = MCPServer.tapRefLead(ref: 3, targetNote: warning, visiblePoint: (10, 20), bandTouched: false, visibleBandNote: "")
        let note = lead.range(of: "Warnings below about the frame's centre")
        let hit = lead.range(of: "may have hit")
        XCTAssertNotNil(note, lead)
        XCTAssertNotNil(hit, lead)
        XCTAssertTrue(note!.lowerBound < hit!.lowerBound, lead)
        XCTAssertEqual(MCPServer.tapRefLead(ref: 3, targetNote: warning, visiblePoint: nil, bandTouched: false, visibleBandNote: ""),
                       "tap [3] done." + warning, "見えている部分を撃っていなければ従来のまま")
    }

    private func tree() -> (SnapshotResponse, ElementInfo, ElementInfo) {
        var list = ElementInfo(ref: 1, type: "scrollView", identifier: "list", label: "list", value: nil, placeholder: nil,
                               enabled: true, frame: FTRect(x: 0, y: 0, width: 400, height: 500), depth: 0)
        list.scrollable = true
        let row = ElementInfo(ref: 2, type: "button", identifier: "row", label: "row", value: nil, placeholder: nil,
                              enabled: true, frame: FTRect(x: 10, y: 100, width: 380, height: 40), depth: 1)
        var s = SnapshotResponse(sessionBundleID: nil, screen: FTRect(x: 0, y: 0, width: 400, height: 800),
                                 elements: [list, row], truncatedCount: 0)
        s.keyboardFrame = FTRect(x: 0, y: 560, width: 400, height: 240)
        return (s, list, row)
    }

    func testKeyboardMayOnlyDismissNote() {
        let (s, _, row) = tree()
        let note = MCPServer.keyboardMayOnlyDismissNote(ref: 2, element: row, in: s, framework: .reactNative)
        XCTAssertTrue(note.contains("may only dismiss the keyboard"), note)
        XCTAssertEqual(MCPServer.keyboardMayOnlyDismissNote(ref: 2, element: row, in: s, framework: .flutter), "")
        XCTAssertEqual(MCPServer.keyboardMayOnlyDismissNote(ref: 2, element: row, in: s, framework: nil), "")
        var hidden = s
        hidden.keyboardFrame = nil
        XCTAssertEqual(MCPServer.keyboardMayOnlyDismissNote(ref: 2, element: row, in: hidden, framework: .reactNative), "")
    }

    /// ft_tap が注記を応答へ載せている(配線の走査)
    func testFtTapWiresTheNote() throws {
        let path = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Sources/fleetest-mcp/MCPServer+ScreenTools.swift").path
        let source = try String(contentsOfFile: path, encoding: .utf8)
        XCTAssertTrue(source.contains("target.note + keyboardNote"))
        XCTAssertTrue(source.contains("Self.keyboardMayOnlyDismissNote(ref: ref"))
    }
}
