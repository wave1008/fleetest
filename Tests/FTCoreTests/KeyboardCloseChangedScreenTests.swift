import XCTest
@testable import FTCore

/// 閉じる tap の後にキーボードの上の要素が消えたら、`resolveAfterClosingKeyboard` は対象を撃たずに断る
/// (入力つきダイアログの裏のボタンを指した tap が、閉じる tap でダイアログを閉じて裏のボタンを押した = 11/17 imax F5)
final class KeyboardCloseChangedScreenTests: XCTestCase {
    private let screen = FTRect(x: 0, y: 0, width: 402, height: 874)
    private let keyboard = FTRect(x: 0, y: 560, width: 402, height: 314)

    private func el(_ id: String, y: Double) -> ElementInfo {
        ElementInfo(ref: 1, type: "button", identifier: id, label: nil, value: nil, placeholder: nil, enabled: true,
                    frame: FTRect(x: 20, y: y, width: 100, height: 40), depth: 2)
    }

    private func snap(_ elements: [ElementInfo]) -> SnapshotResponse {
        SnapshotResponse(sessionBundleID: "com.example.app", screen: screen, elements: elements, truncatedCount: 0)
    }

    func testElementsAboveTheKeyboardThatVanishedAreNamed() {
        let before = snap([el("field_prompt", y: 300), el("btn_save", y: 400)])
        let after = snap([el("btn_fullscreen", y: 200)])
        XCTAssertEqual(StepExecutor.elementsGoneAfterKeyboardClose(keyboard: keyboard, before: before, after: after),
                       ["#btn_save", "#field_prompt"])
    }

    func testNothingGoneWhenOnlyMovedOrAdded() {
        let before = snap([el("field_prompt", y: 300)])
        let after = snap([el("field_prompt", y: 500), el("btn_new", y: 100)])
        XCTAssertTrue(StepExecutor.elementsGoneAfterKeyboardClose(keyboard: keyboard, before: before, after: after).isEmpty)
    }

    func testElementsBelowTheKeyboardTopAreIgnored() {
        let before = snap([el("under_keyboard", y: 600)])
        let after = snap([])
        XCTAssertTrue(StepExecutor.elementsGoneAfterKeyboardClose(keyboard: keyboard, before: before, after: after).isEmpty)
    }

    /// キーボードの上端に接した入力補助のバー(と中のボタン)はキーボードと一緒に消えるのが正当 = 数えない
    func testAccessoryBarAttachedToTheKeyboardIsNotCounted() {
        let bar = ElementInfo(ref: 2, type: "toolbar", identifier: "kb_toolbar", label: nil, value: nil, placeholder: nil,
                              enabled: true, frame: FTRect(x: 0, y: 516, width: 402, height: 44), depth: 1)
        let done = ElementInfo(ref: 3, type: "button", identifier: nil, label: "完了", value: nil, placeholder: nil,
                               enabled: true, frame: FTRect(x: 330, y: 522, width: 60, height: 32), depth: 2)
        let before = snap([el("field_prompt", y: 300), bar, done])
        let after = snap([el("field_prompt", y: 300)])
        XCTAssertTrue(StepExecutor.elementsGoneAfterKeyboardClose(keyboard: keyboard, before: before, after: after).isEmpty)
        // 接していない(間が空いた)バーは数える
        let floating = ElementInfo(ref: 4, type: "other", identifier: "dialog", label: nil, value: nil, placeholder: nil,
                                   enabled: true, frame: FTRect(x: 0, y: 400, width: 402, height: 100), depth: 1)
        XCTAssertEqual(StepExecutor.elementsGoneAfterKeyboardClose(keyboard: keyboard, before: snap([floating]), after: snap([])),
                       ["#dialog"])
    }

    /// キーボードを避けて上端まで縮んだ全幅の容器は帯ではない = 中の消えた要素を数える(帯として除くと検出が効かない)
    func testShrunkContainerEndingAtTheKeyboardIsNotABand() {
        let container = ElementInfo(ref: 5, type: "scrollView", identifier: "content", label: nil, value: nil, placeholder: nil,
                                    enabled: true, frame: FTRect(x: 0, y: 100, width: 402, height: 460), depth: 1)
        let before = snap([container, el("btn_save", y: 400)])
        let after = snap([ElementInfo(ref: 5, type: "scrollView", identifier: "content", label: nil, value: nil, placeholder: nil,
                                      enabled: true, frame: FTRect(x: 0, y: 100, width: 402, height: 774), depth: 1)])
        XCTAssertEqual(StepExecutor.elementsGoneAfterKeyboardClose(keyboard: keyboard, before: before, after: after),
                       ["#btn_save"])
    }

    /// キーボードの上に載ったボトムシート(焦点の欄を含む・低い)も帯ではない = 閉じる tap で閉じたら中身を数える
    func testSheetRestingOnTheKeyboardWithTheFocusedFieldIsNotABand() {
        let sheet = ElementInfo(ref: 6, type: "other", identifier: "sheet", label: nil, value: nil, placeholder: nil,
                                enabled: true, frame: FTRect(x: 0, y: 340, width: 402, height: 220), depth: 1)
        let field = ElementInfo(ref: 7, type: "textField", identifier: "sheet_field", label: nil, value: nil, placeholder: nil,
                                enabled: true, frame: FTRect(x: 20, y: 380, width: 360, height: 44), depth: 2, focused: true)
        let gone = StepExecutor.elementsGoneAfterKeyboardClose(keyboard: keyboard, before: snap([sheet, field]), after: snap([]))
        XCTAssertEqual(gone, ["#sheet", "#sheet_field"])
    }

    func testClauseStatesTheFactsAndThatTheTargetWasNotTouched() {
        let clause = StepExecutor.keyboardCloseChangedScreenClause(note: "closed the keyboard by tapping (25, 529) above the keyboard",
                                                                   gone: ["#field_prompt", "#btn_save"])
        XCTAssertTrue(clause.contains("#field_prompt, #btn_save disappeared"), clause)
        XCTAssertTrue(clause.contains("the target was not touched"), clause)
    }

    /// 呼び手の配線: 消えた要素があれば引き当てより先に `closedChangedScreen` を返す
    func testResolveReturnsChangedScreenBeforeResolvingTheTarget() throws {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Sources/FTCore/StepExecutor+TypeClear.swift")
        let src = try String(contentsOf: url, encoding: .utf8)
        let entry = try XCTUnwrap(src.range(of: "func resolveAfterClosingKeyboard("))
        let body = String(src[entry.upperBound...].prefix(3500))
        // 条件ごと固定する(`if false && …` のように条件を殺す変異を、文字列の順だけでは見逃した)
        let changed = try XCTUnwrap(body.range(of: "if !gone.isEmpty { return .closedChangedScreen("),
                                    "消えた要素があれば撃たずに返す条件が見当たらない")
        XCTAssertTrue(body.contains("if !isAndroid, let keyboardRect {"), "iOS の閉じるタップの後の確かめが外れた")
        let resolve = try XCTUnwrap(body.range(of: "LocatorResolver.resolve(step: step, in: after)"))
        XCTAssertLessThan(changed.lowerBound, resolve.lowerBound)
    }
}
