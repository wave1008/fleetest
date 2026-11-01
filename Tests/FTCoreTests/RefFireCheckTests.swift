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
        var field = element(1, "field", FTRect(x: 20, y: 570, width: 300, height: 44), focused: true)
        field.type = "textField"
        let snapshot = tree([field], keyboardShown: true)
        XCTAssertNotNil(RefFireCheck.evaluate(field, in: snapshot, isAndroid: false).refusal)
        XCTAssertNil(RefFireCheck.evaluate(field, in: snapshot, isAndroid: false, typing: true).refusal)
    }

    /// 焦点を持つ欄への type は、せり上がったバー(inputView)に覆われていても断らない(触らずに打つ)。ref の tap は断る
    func testFocusedFieldIsNotRefusedByTheKeyboardCover() {
        var field = element(1, "field", FTRect(x: 78, y: 600, width: 300, height: 48), focused: true)
        field.type = "textField"
        let bar = element(2, "inputView", FTRect(x: 0, y: 573, width: 402, height: 301))
        let snapshot = tree([field, bar], keyboardShown: true)
        XCTAssertNotNil(RefFireCheck.evaluate(field, in: snapshot, isAndroid: false).refusal)
        XCTAssertNil(RefFireCheck.evaluate(field, in: snapshot, isAndroid: false, typing: true).refusal)
    }

    /// type の対象がボタンなら撃たずに断る(押してしまう)。入力欄・自前描画の clickable は断らない。typing でなければ断らない
    func testTypingIntoAButtonIsRefused() {
        let button = element(1, "btn_input_submit", FTRect(x: 20, y: 200, width: 100, height: 40))
        let snapshot = tree([button], keyboardShown: false)
        guard case .notATextField? = RefFireCheck.evaluate(button, in: snapshot, isAndroid: false, typing: true).refusal
        else { return XCTFail("ボタンへの type を断っていない") }
        XCTAssertNil(RefFireCheck.evaluate(button, in: snapshot, isAndroid: false).refusal)
        var field = element(2, "field", FTRect(x: 20, y: 300, width: 100, height: 40))
        field.type = "textField"
        XCTAssertNil(RefFireCheck.evaluate(field, in: tree([field], keyboardShown: false), isAndroid: false, typing: true).refusal)
        var custom = element(3, "custom", FTRect(x: 20, y: 400, width: 100, height: 40))
        custom.type = "clickable"
        XCTAssertNil(RefFireCheck.evaluate(custom, in: tree([custom], keyboardShown: false), isAndroid: false, typing: true).refusal)
    }

    /// 中心が画面の下端ちょうど(丸め許容の内側)の対象は、座標なら断られる点なので助言を出す。内側は出さない
    func testCentreOnTheScreenEdgeIsAnAdvisory() {
        let edge = element(1, "row_12", FTRect(x: 16, y: 846, width: 370, height: 56))
        XCTAssertNotNil(RefFireCheck.evaluate(edge, in: tree([edge], keyboardShown: false), isAndroid: false).advisory)
        let inside = element(2, "row_11", FTRect(x: 16, y: 790, width: 370, height: 56))
        XCTAssertNil(RefFireCheck.evaluate(inside, in: tree([inside], keyboardShown: false), isAndroid: false).advisory)
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
