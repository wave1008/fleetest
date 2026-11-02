// 焦点を持つ欄への ft_type / ft_clear_input は、ドライバがタップせずに打つ。タップが前提の守りは全部この免除で揃える:
//  F2 キーボードで細い帯に潰れた欄の断り(`keyboardCoverRefusal`)
//  F7 キーボードの下の欄への「タップがキーボードに当たる」警告(`RefGuard.preTapWarnings`)
// 免除の判定は `MCPServer.typesWithoutTouching` の1箇所。ft_tap など叩く操作は従来どおり断る・警告する。
// F5 縁またぎの警告は操作名で言い、ref を引く全経路(`refGestureGuard` を含む)が `straddleWarning` を通る。

import XCTest
import FTCore
@testable import fleetest_mcp

final class FocusedFieldTouchlessGuardsTests: XCTestCase {

    private let screen = FTRect(x: 0, y: 0, width: 2800, height: 1280)
    private let keyboardFrame = FTRect(x: 156, y: 497, width: 2700, height: 783)

    /// 横向きで細い帯(2604x4)に潰れた、焦点のある欄
    private func collapsedField(focused: Bool) -> ElementInfo {
        var field = ElementInfo(ref: 218, type: "textField", identifier: "field_multiline", label: nil, value: nil,
                                placeholder: nil, enabled: true, frame: FTRect(x: 204, y: 372, width: 2604, height: 4),
                                depth: 1)
        field.focused = focused
        return field
    }

    private func snapshot(_ field: ElementInfo) -> SnapshotResponse {
        SnapshotResponse(sessionBundleID: "com.example.app", screen: screen, elements: [field], truncatedCount: 0,
                         keyboardFrame: keyboardFrame)
    }

    private func occlusion(_ tree: SnapshotResponse) -> KeyboardOcclusion {
        KeyboardOcclusion.resolve(reported: tree.keyboardFrame, in: tree.elements, screen: tree.screen)
    }

    private func coverRefusal(tool: String, focused: Bool) async -> String? {
        let field = collapsedField(focused: focused)
        let tree = snapshot(field)
        return await MCPServer.$currentTool.withValue(tool) {
            MCPServer.keyboardCoverRefusal(field, in: tree, keyboardOcclusion: occlusion(tree), label: "[218]")
        }
    }

    // MARK: - F2

    func testCollapsedFocusedFieldIsNotRefusedForTypeAndClearInput() async {
        let field = collapsedField(focused: true)
        XCTAssertEqual(PreFireGuard.keyboardCover(of: field, in: snapshot(field), keyboard: occlusion(snapshot(field))) != nil, true,
                       "前提: 潰れた帯としてキーボードの被覆に数えられる")
        for tool in ["ft_type", "ft_clear_input"] {
            let message = await coverRefusal(tool: tool, focused: true)
            XCTAssertNil(message, "\(tool) が焦点の欄を断った")
        }
    }

    /// 陰性対照: 焦点の無い欄・叩く操作は従来どおり断る
    func testCollapsedFieldWithoutFocusOrTouchingToolsIsStillRefused() async {
        let unfocused = await coverRefusal(tool: "ft_type", focused: false)
        XCTAssertNotNil(unfocused)
        XCTAssertTrue(unfocused?.contains("collapsed to a thin band") == true, unfocused ?? "")
        let tap = await coverRefusal(tool: "ft_tap", focused: true)
        XCTAssertNotNil(tap)
        let longPress = await coverRefusal(tool: "ft_long_press", focused: true)
        XCTAssertNotNil(longPress)
    }

    // MARK: - F7

    private func warnings(tool: String, suppress: Bool) async -> String {
        // キーボードの下(中心が申告されたキー面に入る)にある欄
        var field = ElementInfo(ref: 3083, type: "textField", identifier: "field_chat", label: nil, value: nil,
                                placeholder: nil, enabled: true, frame: FTRect(x: 24, y: 552, width: 2555, height: 168),
                                depth: 1)
        field.focused = true
        let tree = snapshot(field)
        let occ = occlusion(tree)
        let suppressed = await MCPServer.$currentTool.withValue(tool) {
            MCPServer.typesWithoutTouching(field, in: tree.elements)
        }
        XCTAssertEqual(suppressed, suppress, "\(tool)")
        return RefGuard.preTapWarnings(field, keyboardOcclusion: occ, suppressKeyboardWarning: suppressed,
                                       overlayWindows: .none, safeAreaTop: .unknown, screen: screen)
    }

    func testNoTapWillLandOnTheKeyboardWarningWhenTypingIntoTheFocusedField() async {
        for tool in ["ft_type", "ft_clear_input"] {
            let text = await warnings(tool: tool, suppress: true)
            XCTAssertFalse(text.contains("keyboard"), "\(tool): \(text)")
        }
    }

    /// 陰性対照: 叩く操作には従来どおり警告する(警告そのものが消えていない)
    func testTheWarningStaysForTouchingTools() async {
        let text = await warnings(tool: "ft_tap", suppress: false)
        XCTAssertTrue(text.contains("keyboard"), text)
    }

    // MARK: - F5

    private let container = ElementInfo(ref: 1, type: "scrollView", identifier: "list", label: nil, value: nil,
                                        placeholder: nil, enabled: true, frame: FTRect(x: 0, y: 100, width: 402, height: 600),
                                        depth: 0, scrollable: true)

    private func straddling() -> [ElementInfo] {
        let row = ElementInfo(ref: 2, type: "button", identifier: "nav_lifecycle", label: "ライフサイクル", value: nil,
                              placeholder: nil, enabled: true, frame: FTRect(x: 16, y: 680, width: 370, height: 62),
                              depth: 1)
        return [container, row]
    }

    func testStraddleWarningNamesTheOperation() throws {
        let tree = straddling()
        let row = try XCTUnwrap(tree.last)
        for operation in ["tap", "long press", "double tap", "drag"] {
            let text = MCPServer.straddleWarning(row, in: tree, operation: operation)
            XCTAssertTrue(text.contains("the \(operation) may land on a neighbouring row"), "\(operation): \(text)")
        }
        let inside = ElementInfo(ref: 3, type: "button", identifier: "ok", label: nil, value: nil, placeholder: nil,
                                 enabled: true, frame: FTRect(x: 16, y: 300, width: 370, height: 62), depth: 1)
        XCTAssertEqual(MCPServer.straddleWarning(inside, in: [container, inside], operation: "tap"), "", "完全に容器の中は言わない")
    }

    /// ref を引く経路の配線: verifiedRef(ft_tap / ft_long_press / ft_type ...)も refGestureGuard(ft_double_tap / ft_drag / ft_pinch)も共有の口を通る
    func testBothRefPathsGoThroughTheSharedStraddleWarning() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        for file in ["MCPServer+Snapshot.swift", "MCPServer+GesturesTools.swift"] {
            let text = try String(contentsOf: root.appendingPathComponent("Sources/fleetest-mcp/\(file)"), encoding: .utf8)
            XCTAssertTrue(text.contains("Self.straddleWarning("), "\(file) が縁またぎの警告を通っていない")
        }
    }
}
