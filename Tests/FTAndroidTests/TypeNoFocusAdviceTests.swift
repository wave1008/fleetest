// ref 無しの `type` が「入力フォーカスが無い」で落ちたときの案内(2026-08-21 の受け手報告)。
//
// ブリッジの文面は「tap the field by ref first」だが、**その tap が効かなかったからここに来る**
// ので、読み手は次に何をすべきか分からない。Android の入力欄は容器(TextInputLayout)と
// 中身(TextInputEditText)に分かれ、**id は容器側に付くことが多い** —— `#id` で tap すると
// 容器に解決し、入力フォーカスは中身へ移らない。案内はセレクタを取る `type` へ寄せる。

import XCTest
@testable import FTAndroid
import FTCore

final class TypeNoFocusAdviceTests: XCTestCase {

    private let noFocus = "no-input-focus: nothing has input focus (tap the field by ref first)"
    /// 書き換えた後に残る理由(注入器の「by ref」は MCP の言い方で DSL に ref は無いので落とす = 41周目 alocal F2)
    private let noFocusReason = "no-input-focus: nothing has input focus"

    func testAdvisesTheSelectorFormWhenNothingHasFocus() throws {
        let rewritten = AndroidDriver.typeNoFocusAdvice(
            after: .badResponse(status: 500, body: noFocus), hadRef: false)

        guard case .badResponse(let status, let body)? = rewritten else {
            return XCTFail("書き換えていない: \(String(describing: rewritten))")
        }
        XCTAssertEqual(status, 500, "status はホストの分岐契約なので変えない")
        XCTAssertTrue(body.contains(noFocusReason), "元の理由も残すこと: \(body)")
        XCTAssertTrue(body.contains("type(<selector>"), "次の一手が書かれていない: \(body)")
        XCTAssertTrue(body.contains("TextInputEditText"), "容器と中身の話が要る: \(body)")
        XCTAssertFalse(body.contains("by ref"), "DSL に ref は無い: \(body)")
        // 何も叩いていない画面でも来る(41周目 amax F1)ので、叩いた前提で言い切らない
        XCTAssertTrue(body.contains("either no field was tapped"), body)
        XCTAssertFalse(body.contains("nothing was tapped into focus"), body)
    }

    /// キーボードが出ているなら欄が木から押し出されている話であって、容器(TextInputLayout)の話ではない
    func testKeyboardShownBlamesTheKeyboardNotTheContainer() throws {
        guard case .badResponse(_, let body)? = AndroidDriver.typeNoFocusAdvice(
            after: .badResponse(status: 500, body: noFocus), hadRef: false, keyboardShown: true) else {
            return XCTFail("書き換えていない")
        }
        XCTAssertTrue(body.contains(noFocusReason), body)
        XCTAssertTrue(body.contains("soft keyboard is showing"), body)
        XCTAssertTrue(body.contains("hideKeyboard"), body)
        XCTAssertFalse(body.contains("TextInputEditText"), body)
        // 閉じてからセレクタ無しで打ち直す対処は言わない(View の形では焦点が戻らず効かない = Pixel 3a の実測)
        XCTAssertFalse(body.contains("type again"), body)
        XCTAssertTrue(body.contains("then type by selector"), body)
    }

    /// 最後の tap の後に type が通っていれば、容器の話ではなく「焦点を持っていた欄が木から消えた」話をする
    /// (Flutter で焦点の欄を一覧の外へ送った後の ref 無し type)
    func testTypedFieldLeavingTheTreeIsNotBlamedOnAContainer() throws {
        guard case .badResponse(_, let body)? = AndroidDriver.typeNoFocusAdvice(
            after: .badResponse(status: 500, body: noFocus), hadRef: false, fieldTypedSinceLastTap: true) else {
            return XCTFail("書き換えていない")
        }
        XCTAssertTrue(body.contains(noFocusReason), body)
        XCTAssertTrue(body.contains("left the accessibility tree"), body)
        XCTAssertTrue(body.contains("type(<selector>"), body)
        XCTAssertFalse(body.contains("TextInputEditText"), body)
        XCTAssertFalse(body.contains("nothing was tapped into focus"), body)
    }

    /// 覆い・別アプリが前面なら、キーボードより前面の話が先
    func testFrontAdviceWinsOverTheKeyboardAdvice() throws {
        guard case .badResponse(_, let body)? = AndroidDriver.typeNoFocusAdvice(
            after: .badResponse(status: 500, body: noFocus), hadRef: false,
            front: "com.android.systemui", lastTreePackage: "com.app", keyboardShown: true) else {
            return XCTFail("書き換えていない")
        }
        XCTAssertTrue(body.contains("notification shade"), body)
        XCTAssertFalse(body.contains("soft keyboard is showing"), body)
    }

    /// **ref 付きで落ちたら別の話**(掴んだ要素へ撃って失敗している)ので触らない
    func testLeavesRefTypeFailuresAlone() {
        XCTAssertNil(AndroidDriver.typeNoFocusAdvice(
            after: .badResponse(status: 500, body: noFocus), hadRef: true))
    }

    /// フォーカス以外の失敗には足さない(全部のエラーに同じ助言を付けない)
    func testLeavesOtherFailuresAlone() {
        XCTAssertNil(AndroidDriver.typeNoFocusAdvice(
            after: .badResponse(status: 500, body: "set-text rejected"), hadRef: false))
        XCTAssertNil(AndroidDriver.typeNoFocusAdvice(
            after: .bridgeUnreachable(
                context: DriverErrorContext(bridge: .android, physicalDevice: false), detail: "x"),
            hadRef: false))
    }
}

/// 前面が覆い(systemui)・別のアプリのときは、欄の話ではなく前面の話をする
final class TypeNoFocusFrontAdviceTests: XCTestCase {
    private let noFocus = "no-input-focus: nothing has input focus (tap the field by ref first)"
    /// 書き換えた後に残る理由(注入器の「by ref」は MCP の言い方で DSL に ref は無いので落とす = 41周目 alocal F2)
    private let noFocusReason = "no-input-focus: nothing has input focus"

    private func body(front: String?, last: String?) -> String? {
        guard case .badResponse(_, let b)? = AndroidDriver.typeNoFocusAdvice(
            after: .badResponse(status: 500, body: noFocus), hadRef: false, front: front, lastTreePackage: last)
        else { return nil }
        return b
    }

    func testSystemUIInFrontIsNamedNotTheField() throws {
        let b = try XCTUnwrap(body(front: "com.android.systemui", last: "com.app"))
        XCTAssertTrue(b.contains("notification shade"), b)
        XCTAssertFalse(b.contains("TextInputEditText"), b)
    }

    func testAnotherAppInFrontSaysTheAppWentAway() throws {
        let b = try XCTUnwrap(body(front: "com.other", last: "com.app"))
        XCTAssertTrue(b.contains("com.other is in front, not com.app"), b)
        XCTAssertFalse(b.contains("TextInputEditText"), b)
    }

    func testSameAppInFrontKeepsTheContainerAdvice() throws {
        let b = try XCTUnwrap(body(front: "com.app", last: "com.app"))
        XCTAssertTrue(b.contains("TextInputEditText"), b)
    }
}

/// 焦点なしの文が名指す「直近の木のアプリ」は木の前面が先(端末ごとの控えのファイルから戻った別のプロセスの帳簿を先にすると、
/// このプロセスの木が e2e.android なのに e2ey.flutter を「落ちたか離れた」と言った = Pixel 3a・MCP)。launch 系は木の控えを消す
final class NoFocusLastTreeOrderTests: XCTestCase {
    func testTheLastTreeWinsOverTheRestoredLedger() throws {
        let path = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Sources/FTAndroid/AndroidDriver.swift")
        let src = try String(contentsOf: path, encoding: .utf8)
        XCTAssertFalse(src.contains("currentPackage ?? lastTreeForegroundPackage"), "帳簿を木より先に使っている")
        XCTAssertEqual(src.components(separatedBy: "lastTreeForegroundPackage ?? currentPackage").count - 1, 2,
                       "焦点なしの文の名指し(noFocusTreePackage)と WebView の端送り")
        XCTAssertTrue(src.contains("private var noFocusTreePackage: String? { departedTreePackage ?? lastTreeForegroundPackage ?? currentPackage }"))
        XCTAssertEqual(src.components(separatedBy: "lastTreePackage: noFocusTreePackage").count
                       + src.components(separatedBy: "let lastTree = noFocusTreePackage").count - 2, 2, "type・clearInput")
        XCTAssertEqual(src.components(separatedBy: "lastTreeForegroundPackage = nil").count - 1, 3,
                       "launch・activate・openURL が木の控えを消す")
    }
}

/// back() / home() で離れた先(ランチャー)の木を読んだ後も、焦点なしの文は前面の食い違いを言う
final class TreeForegroundDepartureTests: XCTestCase {
    func testLeavingKeepsTheDepartedAppAndReturnClearsIt() {
        var s = AndroidDriver.treeForegroundUpdate(previous: nil, departed: nil, new: "com.app")
        XCTAssertNil(s.departed)
        s = AndroidDriver.treeForegroundUpdate(previous: s.last, departed: s.departed, new: "com.launcher")
        XCTAssertEqual(s.last, "com.launcher")
        XCTAssertEqual(s.departed, "com.app")
        s = AndroidDriver.treeForegroundUpdate(previous: s.last, departed: s.departed, new: "com.launcher")
        XCTAssertEqual(s.departed, "com.app", "離れた先を続けて読んでも残る")
        s = AndroidDriver.treeForegroundUpdate(previous: s.last, departed: s.departed, new: "com.app")
        XCTAssertNil(s.departed)
    }

    func testLauncherInFrontIsNamedAgainstTheDepartedApp() throws {
        guard case .badResponse(_, let b)? = AndroidDriver.typeNoFocusAdvice(
            after: .badResponse(status: 500, body: "no-input-focus: nothing has input focus"), hadRef: false,
            front: "com.launcher", lastTreePackage: "com.app", fieldTypedSinceLastTap: true) else { return XCTFail() }
        XCTAssertTrue(b.contains("com.launcher is in front, not com.app"), b)
        XCTAssertFalse(b.contains("scroll"), b)
    }
}
