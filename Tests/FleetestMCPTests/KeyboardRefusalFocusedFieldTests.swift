// キーボードの下の欄の門(`MCPServer.keyboardRefusal`): 焦点を持つ欄への ft_type / ft_clear_input は断らない(mxa F10)。
// ドライバは焦点の欄を叩かずに打つ・消す。ft_tap など叩く操作は従来どおり断る。

import XCTest
import FTCore
@testable import fleetest_mcp

final class KeyboardRefusalFocusedFieldTests: XCTestCase {

    private func underKeyboard(focused: Bool) -> (ElementInfo, KeyboardOcclusion) {
        var field = ElementInfo(ref: 1, type: "textView", identifier: "field_multiline", label: nil, value: nil,
                                placeholder: nil, enabled: true, frame: FTRect(x: 16, y: 494, width: 370, height: 88),
                                depth: 1)
        field.focused = focused
        let occlusion = KeyboardOcclusion.resolve(reported: FTRect(x: 0, y: 538, width: 402, height: 336),
                                                  in: [field], screen: FTRect(x: 0, y: 0, width: 402, height: 874))
        return (field, occlusion)
    }

    private func refusal(tool: String, focused: Bool) async -> String? {
        let (field, occlusion) = underKeyboard(focused: focused)
        return await MCPServer.$currentTool.withValue(tool) {
            MCPServer.keyboardRefusal(field, keyboardOcclusion: occlusion, tree: [field], isAndroid: false)
        }
    }

    func testFocusedFieldIsNotRefusedForTypeAndClearInput() async {
        let (field, occlusion) = underKeyboard(focused: true)
        XCTAssertNotNil(occlusion.advisory(for: field), "前提: 中心がキーボードの下")
        for tool in ["ft_type", "ft_clear_input"] {
            let message = await refusal(tool: tool, focused: true)
            XCTAssertNil(message, "\(tool) が焦点の欄を断った")
        }
    }

    func testUnfocusedFieldAndTapAreStillRefused() async {
        let unfocusedClear = await refusal(tool: "ft_clear_input", focused: false)
        XCTAssertNotNil(unfocusedClear)
        let focusedTap = await refusal(tool: "ft_tap", focused: true)
        XCTAssertNotNil(focusedTap)
    }

    /// Flutter の横向きでは focused が欄の内側のノードに立ち、ref の指す要素には付かない。内側/同じ枠の焦点のある要素があれば断らない
    func testFocusOnAnInnerNodeOfTheTargetCountsAsFocused() async {
        let (field, occlusion) = underKeyboard(focused: false)
        var inner = ElementInfo(ref: 2, type: "textField", identifier: nil, label: nil, value: nil, placeholder: nil,
                                enabled: true, frame: FTRect(x: 20, y: 500, width: 360, height: 70), depth: 2)
        inner.focused = true
        let message = await MCPServer.$currentTool.withValue("ft_type") {
            MCPServer.keyboardRefusal(field, keyboardOcclusion: occlusion, tree: [field, inner], isAndroid: true)
        }
        XCTAssertNil(message)
        var elsewhere = inner
        elsewhere.frame = FTRect(x: 20, y: 100, width: 360, height: 40)
        let refused = await MCPServer.$currentTool.withValue("ft_type") {
            MCPServer.keyboardRefusal(field, keyboardOcclusion: occlusion, tree: [field, elsewhere], isAndroid: true)
        }
        XCTAssertNotNil(refused)
        XCTAssertFalse(refused?.contains("XCUITest") ?? true, "Android の断りに XCUITest の説明を出さない")
    }
}
