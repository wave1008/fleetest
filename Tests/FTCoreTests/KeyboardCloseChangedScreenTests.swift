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

    /// OS の入力補助バー(型 toolbar・識別子 Toolbar)は、予測変換の帯を挟んでキー面から浮いていても数えない。
    /// 実測(iOS Simulator の Safari・Web の入力欄): キー面の上端 583・バー (0,480 402x48)。数えていた間は、閉じた後に対象を撃たず赤になった。
    /// 識別子の違う浮いたバー(アプリの物)は従来どおり数える
    func testOSAccessoryBarFloatingAboveTheKeyboardIsNotCounted() {
        let keyboard = FTRect(x: 0, y: 583, width: 402, height: 233)
        let bar = ElementInfo(ref: 2, type: "toolbar", identifier: "Toolbar", label: "ツールバー", value: nil, placeholder: nil,
                              enabled: true, frame: FTRect(x: 0, y: 480, width: 402, height: 48), depth: 1)
        let previous = ElementInfo(ref: 3, type: "button", identifier: nil, label: "前へ", value: nil, placeholder: nil,
                                   enabled: true, frame: FTRect(x: 21, y: 485, width: 40, height: 38), depth: 2)
        let done = ElementInfo(ref: 4, type: "button", identifier: nil, label: "完了", value: nil, placeholder: nil,
                               enabled: true, frame: FTRect(x: 341, y: 485, width: 40, height: 38), depth: 2)
        let before = snap([el("TabBarItemTitle", y: 300), bar, previous, done])
        let after = snap([el("TabBarItemTitle", y: 300)])
        XCTAssertTrue(StepExecutor.elementsGoneAfterKeyboardClose(keyboard: keyboard, before: before, after: after).isEmpty)
        var appBar = bar
        appBar.identifier = "chat_composer"
        XCTAssertFalse(StepExecutor.elementsGoneAfterKeyboardClose(keyboard: keyboard, before: snap([appBar, previous, done]),
                                                                   after: snap([])).isEmpty)
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
                                                                   gone: ["#field_prompt", "#btn_save"], touchedScreen: true)
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
        XCTAssertTrue(body.contains("if !isAndroid, let keyboardRect {"), "iOS の閉じた後の確かめが外れた(閉じ方に関わらず見る)")
        let resolve = try XCTUnwrap(body.range(of: "LocatorResolver.resolve(step: step, in: after)"))
        XCTAssertLessThan(changed.lowerBound, resolve.lowerBound)
    }

    /// 画面を叩かずに閉じた(resign)回は「That tap」と言わない
    func testClauseDoesNotCallAResignATap() {
        let clause = StepExecutor.keyboardCloseChangedScreenClause(note: "closed the keyboard by resigning the focused React Native text input",
                                                                   gone: ["#overlay"], touchedScreen: false)
        XCTAssertFalse(clause.contains("That tap"), clause)
        XCTAssertTrue(clause.contains("Closing the keyboard was not side-effect free: #overlay disappeared"), clause)
    }

    /// 焦点の欄の枠の内側の飾り(RN paper の下線)は消えても数えない。欄そのものが消えたら数える
    func testDecorationsInsideTheFocusedFieldAreNotCounted() {
        let field = ElementInfo(ref: 8, type: "textField", identifier: "field_prompt", label: nil, value: nil, placeholder: nil,
                                enabled: true, frame: FTRect(x: 50, y: 392, width: 302, height: 56), depth: 2, focused: true)
        let underline = ElementInfo(ref: 9, type: "other", identifier: "text-input-underline", label: nil, value: nil, placeholder: nil,
                                    enabled: true, frame: FTRect(x: 50, y: 446.5, width: 302, height: 2), depth: 3)
        var unfocused = field
        unfocused.focused = false
        XCTAssertTrue(StepExecutor.elementsGoneAfterKeyboardClose(keyboard: keyboard, before: snap([field, underline]),
                                                                  after: snap([unfocused])).isEmpty)
        XCTAssertEqual(StepExecutor.elementsGoneAfterKeyboardClose(keyboard: keyboard, before: snap([field, underline]), after: snap([])),
                       ["#field_prompt"])
        // 欄の枠の内側でもラベルを持つ要素(大きな焦点の欄の中に描かれたダイアログの見出し等)は数える
        let titled = ElementInfo(ref: 10, type: "other", identifier: nil, label: "確認", value: nil, placeholder: nil,
                                 enabled: true, frame: FTRect(x: 60, y: 400, width: 100, height: 20), depth: 3)
        XCTAssertEqual(StepExecutor.elementsGoneAfterKeyboardClose(keyboard: keyboard, before: snap([field, underline, titled]),
                                                                   after: snap([unfocused])), ["other 確認"])
        // 除くのは飾りの要素そのもの: 同じ署名の別の要素(欄の外の無名の覆い)が消えたら数える
        let anonymousInside = ElementInfo(ref: 11, type: "other", identifier: nil, label: nil, value: nil, placeholder: nil,
                                          enabled: true, frame: FTRect(x: 60, y: 440, width: 10, height: 4), depth: 3)
        let anonymousOutside = ElementInfo(ref: 12, type: "other", identifier: nil, label: nil, value: nil, placeholder: nil,
                                           enabled: true, frame: FTRect(x: 0, y: 100, width: 402, height: 200), depth: 1)
        XCTAssertEqual(StepExecutor.elementsGoneAfterKeyboardClose(keyboard: keyboard,
                                                                   before: snap([field, anonymousInside, anonymousOutside]),
                                                                   after: snap([unfocused])), ["other "])
    }

    /// 閉じ方の申告: 画面を叩いた閉じ方だけ touchedScreen = true(文言の「That tap」はこれで決める)
    func testOnlyTapClosesClaimToHaveTouchedTheScreen() throws {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Sources/FTCore/StepExecutor+DirectActions.swift")
        let src = try String(contentsOf: url, encoding: .utf8)
        func closes(in function: String) throws -> [String] {
            let entry = try XCTUnwrap(src.range(of: "func \(function)("))
            // 次の宣言(修飾子・属性つきの func も含む)で切る
            let rest = String(src[entry.upperBound...])
            let end = rest.range(of: #"\n    [^\n/]*\bfunc "#, options: .regularExpression)?.lowerBound
                ?? rest.endIndex
            let body = String(rest[..<end])
            return body.components(separatedBy: "touchedScreen: ").dropFirst().map { String($0.prefix(5)) }
        }
        XCTAssertEqual(try closes(in: "closeReactNativeKeyboardByResign"), ["false"])
        XCTAssertEqual(try closes(in: "closeKeyboardWithoutSideEffects"), ["false"], "Android の戻るキー")
        XCTAssertEqual(try closes(in: "closeKeyboardByTappingOutside"), ["true)", "true)"])
    }

    /// hideKeyboard の成功時の注記(消えた要素の件数)も同じ判定を通す(自前で数えると入力補助のバー・欄の飾りまで「消えた」と言う)
    func testHideKeyboardSuccessNoteSharesTheGoneJudgment() throws {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Sources/FTCore/StepExecutor+DirectActions.swift")
        let src = try String(contentsOf: url, encoding: .utf8)
        let body = try XCTUnwrap(src.components(separatedBy: "func closeKeyboardByTappingOutside(").dropFirst().first?
            .components(separatedBy: "\n    func ").first)
        XCTAssertTrue(body.contains("Self.allElementsGoneAfterKeyboardClose(keyboard: keyboard, before: before, after: after)"))
        XCTAssertFalse(body.contains("contentAbove(keyboard, in: before).subtracting"), "消えた要素を自前で数えている")
    }
}
