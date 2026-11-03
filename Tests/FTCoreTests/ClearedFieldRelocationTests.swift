// replace の消去の後の引き直しは DSL と MCP で同じ判定(ClearedFieldRelocation.relocate)。同じ画面で片方だけ引けると、
// MCP で通った手順が DSL(ft_batch・シナリオ)では「消した・打っていない」で落ちる

import XCTest
@testable import FTCore

final class ClearedFieldRelocationTests: XCTestCase {
    private func field(_ ref: Int, y: Double, placeholder: String?) -> ElementInfo {
        ElementInfo(ref: ref, type: "textField", identifier: nil, label: nil, value: nil, placeholder: placeholder,
                    enabled: true, frame: FTRect(x: 20, y: y, width: 300, height: 40), depth: 3)
    }

    /// id の無いアラートの欄がキーボードで持ち上がった: DSL の経路も placeholder で引き直す
    func testTheDSLPathFindsAMovedFieldWithoutIdByPlaceholder() {
        let before = field(3, y: 400, placeholder: "入力")
        let snapshot = SnapshotResponse(sessionBundleID: "a", screen: FTRect(x: 0, y: 0, width: 402, height: 874),
                                        elements: [field(11, y: 250, placeholder: "入力"), field(12, y: 600, placeholder: "別")],
                                        truncatedCount: 0)
        var step = FlowStep(action: "type")
        var locator = FlowLocator()
        locator.placeholder = "存在しない"
        step.locator = locator
        XCTAssertEqual(StepExecutor.relocateAfterClear(before, step: step, in: snapshot)?.ref, 11)
        XCTAssertEqual(ClearedFieldRelocation.relocate(before, in: snapshot.elements)?.ref, 11)
    }

    /// 推測の段(④ placeholder)は、横の位置・幅が違う欄を同じ欄とは読まない。焦点のある同じ型の欄では引かない(縦に並んだフォームは
    /// 列がそろうので区別にならず、焦点が次の欄へ移った画面で別の欄に打つ。OI-77)
    func testGuessingStepsOnlyAcceptAMoveAlongTheKeyboardsAxis() {
        let before = field(3, y: 400, placeholder: "入力")
        var sideways = field(11, y: 250, placeholder: "入力")
        sideways.frame = FTRect(x: 40, y: 250, width: 300, height: 40)
        XCTAssertNil(ClearedFieldRelocation.relocate(before, in: [sideways]), "横にずれた同じ placeholder の欄")
        var focusedElsewhere = field(12, y: 250, placeholder: nil)
        focusedElsewhere.frame = FTRect(x: 20, y: 250, width: 200, height: 40)
        focusedElsewhere.focused = true
        XCTAssertNil(ClearedFieldRelocation.relocate(before, in: [focusedElsewhere]), "幅の違う焦点の欄")
        var focusedAbove = field(13, y: 250, placeholder: nil)
        focusedAbove.focused = true
        XCTAssertNil(ClearedFieldRelocation.relocate(before, in: [focusedAbove]), "焦点のある同じ列の欄でも引かない")
    }
}
