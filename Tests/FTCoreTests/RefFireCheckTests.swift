// CLI の --ref が撃つ前に通す判定(RefFireCheck)の挙動

import XCTest
@testable import FTCore

final class RefFireCheckTests: XCTestCase {
    private let screen = FTRect(x: 0, y: 0, width: 402, height: 874)
    private let keyboard = FTRect(x: 0, y: 573, width: 402, height: 301)

    private func element(_ ref: Int, _ id: String, _ f: FTRect, focused: Bool? = nil) -> ElementInfo {
        var e = ElementInfo(ref: ref, type: "button", identifier: id, label: id, value: nil, placeholder: nil,
                            enabled: true, frame: f, depth: 2)
        e.focused = focused
        return e
    }

    private func tree(_ elements: [ElementInfo], keyboardShown: Bool) -> SnapshotResponse {
        var s = SnapshotResponse(sessionBundleID: nil, screen: screen, elements: elements, truncatedCount: 0)
        if keyboardShown { s.keyboardFrame = keyboard }
        return s
    }

    /// キーボードの下の対象は断る(撃つとキーを押して焦点の欄へ文字が入る)。キーボードが無ければ通す
    func testUnderTheKeyboardIsRefused() {
        let tab = element(1, "tab_controls", FTRect(x: 20, y: 570, width: 80, height: 44))
        let shown = RefFireCheck.evaluate(tab, in: tree([tab], keyboardShown: true), isAndroid: false)
        guard case .underKeyboard? = shown.refusal else { return XCTFail("キーボードの下を断っていない") }
        XCTAssertNil(RefFireCheck.evaluate(tab, in: tree([tab], keyboardShown: false), isAndroid: false).refusal)
    }

    /// type の対象が既に焦点を持つなら断らない(ドライバはタップせずに打つ)
    func testFocusedFieldIsAllowedOnlyWhenAsked() {
        let field = element(1, "field", FTRect(x: 20, y: 570, width: 300, height: 44), focused: true)
        let snapshot = tree([field], keyboardShown: true)
        XCTAssertNotNil(RefFireCheck.evaluate(field, in: snapshot, isAndroid: false).refusal)
        XCTAssertNil(RefFireCheck.evaluate(field, in: snapshot, isAndroid: false, allowFocused: true).refusal)
    }

    /// 画面の外の対象は撃つが事実を返す(常に nil を返す実装・常に返す実装のどちらも落ちる)
    func testOffscreenIsAnAdvisoryNotARefusal() {
        let above = element(1, "slot", FTRect(x: 20, y: -60, width: 100, height: 40))
        let result = RefFireCheck.evaluate(above, in: tree([above], keyboardShown: false), isAndroid: false)
        XCTAssertNil(result.refusal)
        XCTAssertNotNil(result.advisory)
        let visible = element(2, "ok", FTRect(x: 20, y: 200, width: 100, height: 40))
        let quiet = RefFireCheck.evaluate(visible, in: tree([visible], keyboardShown: false), isAndroid: false)
        XCTAssertNil(quiet.refusal)
        XCTAssertNil(quiet.advisory)
    }
}
