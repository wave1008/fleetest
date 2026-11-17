import XCTest
@testable import FTCore

/// キーボードの縁に接した・裏へ押し込まれたタブバーの当たり判定の余白を、背景タップの点に選ばない
final class KeyboardDismissEdgeSlopTests: XCTestCase {

    private func el(_ ref: Int, _ type: String, _ id: String?, _ frame: FTRect, depth: Int) -> ElementInfo {
        ElementInfo(ref: ref, type: type, identifier: id, label: nil, value: nil, placeholder: nil, enabled: true,
                    frame: frame, depth: depth, focused: nil)
    }

    private let screen = FTRect(x: 0, y: 0, width: 402, height: 874)
    private let keyboard = FTRect(x: 0, y: 546, width: 402, height: 328)

    /// E2E-iOS の実測の形: タブがキーボード上端(546)より下(548)に押し込まれている
    private var tree: [ElementInfo] {
        [el(1, "other", nil, screen, depth: 0),
         el(2, "staticText", nil, FTRect(x: 56, y: 126, width: 95, height: 22), depth: 1),
         el(3, "tabBar", nil, FTRect(x: 0, y: 548, width: 402, height: 62), depth: 1),
         el(4, "tab", "tab_home", FTRect(x: 0, y: 548, width: 134, height: 62), depth: 2)]
    }

    func testNoCandidateWithinTheHitSlopOfATabTuckedBehindTheKeyboard() {
        let found = KeyboardDismissPoint.candidates(elements: tree, screen: screen, keyboard: keyboard, overlays: [])
        XCTAssertFalse(found.isEmpty)
        for choice in found {
            XCTAssertLessThan(choice.y, 548 - KeyboardDismissPoint.edgeHitSlop, "タブの当たり判定の余白(\(choice.x), \(choice.y))")
        }
    }

    /// E2E-CMP の小さい画面: タブの下端とキーボードの間の 8pt の隙間(木に載らない)は叩かず、その上の空きへ進む
    func testSkipsTheGapBetweenTheTabBarAndTheKeyboard() {
        let kb = FTRect(x: 0, y: 399, width: 375, height: 400)
        let scr = FTRect(x: 0, y: 0, width: 375, height: 800)
        let elements = [el(1, "other", nil, scr, depth: 0),
                        el(2, "tab", "tab_home", FTRect(x: 0, y: 343, width: 125, height: 48), depth: 1),
                        el(3, "tab", "tab_controls", FTRect(x: 125, y: 343, width: 125, height: 56), depth: 1)]
        let found = KeyboardDismissPoint.candidates(elements: elements, screen: scr, keyboard: kb, overlays: [])
        XCTAssertFalse(found.isEmpty)
        for choice in found {
            XCTAssertFalse(choice.y > 343 - KeyboardDismissPoint.edgeHitSlop && choice.x <= 250 + KeyboardDismissPoint.edgeHitSlop,
                           "タブの余白に候補(\(choice.x), \(choice.y))")
        }
    }

    /// 既定値はリテラルで固定する(実測: キーボード裏のタブは 11pt 上で反応・23pt 上で反応しない = その間)
    func testEdgeHitSlopIsPinned() {
        XCTAssertEqual(KeyboardDismissPoint.edgeHitSlop, 16)
    }

    /// 縁から離れた欄の余白までは除かない(詰まった画面で空きを失わない)
    func testControlsAwayFromTheKeyboardEdgeKeepOnlyTheirFrames() {
        let field = el(2, "textField", "f", FTRect(x: 16, y: 100, width: 370, height: 40), depth: 1)
        XCTAssertFalse(KeyboardDismissPoint.isNearKeyboardEdgeControl(x: 200, y: 145, elements: [field], keyboardTop: 546,
                                                                       keyboardRefs: [], slop: KeyboardDismissPoint.edgeHitSlop))
    }

    /// キーボードまで届く縦長のテキストビューの脇の狭い余白(その画面で唯一の空き)は、縁の帯より上なら候補に残る
    /// (部品の周り全体を除くと候補が空になり、DSL の hideKeyboard が Enter = 改行へ落ちる)
    func testNarrowMarginsBesideATallTextViewStayCandidatesAboveTheEdgeBand() {
        let compose = [el(1, "other", nil, screen, depth: 0),
                       el(2, "textView", "body", FTRect(x: 10, y: 60, width: 382, height: 486), depth: 1),
                       // 端の列を外した空きが他に無い形にする(端の列は戻るジェスチャの帯なので、空きがあればそちらを先に試す)
                       el(3, "button", "top_bar", FTRect(x: 0, y: 0, width: 402, height: 60), depth: 1)]
        let found = KeyboardDismissPoint.candidates(elements: compose, screen: screen, keyboard: keyboard, overlays: [])
        XCTAssertFalse(found.isEmpty, "脇の余白が1つも候補に残らない")
        // 候補は入れ物ごとに1点 = テキストビューより上(画面の最上部)の点でも空ではなくなるので、脇(テキストビューの縦の範囲)にあることを見る
        XCTAssertTrue(found.contains { $0.y > 60 }, "テキストビューの脇の余白が候補に残っていない: \(found)")
        for choice in found {
            XCTAssertTrue(choice.x < 10 || choice.x > 392, "テキストビューの上を選んだ: (\(choice.x), \(choice.y))")
            XCTAssertLessThan(choice.y, keyboard.y - KeyboardDismissPoint.edgeHitSlop, "縁の帯の中を選んだ")
        }
    }

    /// キーボードの子孫でない押せる部品は、型が key でも余白を持つ(型ではなく木の位置で除く)
    func testKeyTypedControlOutsideTheKeyboardKeepsItsSlop() {
        let accessory = el(2, "key", "accessory_done", FTRect(x: 0, y: 548, width: 402, height: 40), depth: 1)
        XCTAssertTrue(KeyboardDismissPoint.isNearKeyboardEdgeControl(x: 200, y: 540, elements: [accessory],
                                                                     keyboardTop: 546, keyboardRefs: [], slop: KeyboardDismissPoint.edgeHitSlop))
    }

    /// キーボードの子孫(予測変換バーのボタン)の余白はキーボードの上の帯を潰さない(アプリの裏のタブだけが余白を持つ)
    func testPredictiveBarButtonsInsideTheKeyboardDoNotBlockTheBandAboveIt() {
        let elements = [el(1, "other", nil, screen, depth: 0),
                        el(2, "keyboard", nil, keyboard, depth: 1),
                        el(3, "button", "prediction", FTRect(x: 0, y: 546, width: 402, height: 44), depth: 2),
                        el(4, "key", "q", FTRect(x: 0, y: 600, width: 40, height: 44), depth: 2)]
        let found = KeyboardDismissPoint.candidates(elements: elements, screen: screen, keyboard: keyboard, overlays: [])
        XCTAssertTrue(found.contains { $0.y > 546 - KeyboardDismissPoint.edgeHitSlop }, "\(found.map(\.y))")
    }

    func testControlHitSlopIsPinned() {
        XCTAssertEqual(KeyboardDismissPoint.controlHitSlop, 16)
    }

    /// 実測の画面(iPad 横向き 1180x820・E2E-iOS の WebView): 戻るボタンの枠の外 1pt (73,78) を選んで戻るを押した。
    /// 余白の外に空きがあれば、戻るボタンの余白の中は選ばない
    func testBackButtonHitSlopIsAvoidedOnTheMeasuredScreen() throws {
        let wide = FTRect(x: 0, y: 0, width: 1180, height: 820)
        let kb = FTRect(x: 0, y: 398, width: 1180, height: 422)
        let back = el(2, "button", "btn_back", FTRect(x: 16, y: 48, width: 56, height: 62), depth: 1)
        let title = el(3, "staticText", "txt_screen_title", FTRect(x: 80, y: 68, width: 73, height: 20), depth: 1)
        let webView = el(4, "webView", "wv_container", FTRect(x: 0, y: 126, width: 1180, height: 210), depth: 1)
        let tabs = el(5, "button", "tab_home", FTRect(x: 0, y: 336, width: 1180, height: 62), depth: 1)
        let found = KeyboardDismissPoint.candidates(elements: [back, title, webView, tabs], screen: wide, keyboard: kb, overlays: [])
        let first = try XCTUnwrap(found.first)
        let slop = KeyboardDismissPoint.inflated(back.frame, by: KeyboardDismissPoint.controlSlop(screen: wide))
        XCTAssertFalse(first.x >= slop.x && first.x <= slop.x + slop.width && first.y >= slop.y && first.y <= slop.y + slop.height,
                       "戻るボタンの余白の中を選んだ: (\(first.x), \(first.y))")
    }

    /// 余白の中にしか空きが無い画面: 余白の外の候補は空(呼び手が先に Done を探す)、余白を除かない候補は残る(Done も無ければこちら)
    func testFallsBackIntoTheSlopWhenNoOtherSpotIsFree() {
        // 全幅の押せない入れ物の上に、上下左右 8pt だけ空けて並んだ行(SwiftUI の Form の行が button で出る形)
        var elements = [el(1, "other", nil, screen, depth: 0)]
        var y = 8.0
        var ref = 10
        while y < keyboard.y - 40 {
            elements.append(el(ref, "button", "row\(ref)", FTRect(x: 8, y: y, width: screen.width - 16, height: 40), depth: 1))
            y += 48
            ref += 1
        }
        XCTAssertTrue(KeyboardDismissPoint.candidates(elements: elements, screen: screen, keyboard: keyboard, overlays: []).isEmpty)
        XCTAssertFalse(KeyboardDismissPoint.candidatesIgnoringControlSlop(elements: elements, screen: screen, keyboard: keyboard,
                                                                          overlays: []).isEmpty, "余白の中の空きまで捨てた")
    }

    /// 呼び手の順: 余白の外の空き → OS の入力補助バーの Done → 余白の中の空き(Done を飛ばして戻るボタンの隣を叩かない)
    func testCallerTriesDoneBeforeSpotsInsideTheSlop() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let src = try String(contentsOf: root.appendingPathComponent("Sources/FTCore/StepExecutor+DirectActions.swift"), encoding: .utf8)
        let body = try XCTUnwrap(src.components(separatedBy: "func closeKeyboardByTappingOutside(").dropFirst().first)
        let outside = try XCTUnwrap(body.range(of: "KeyboardDismissPoint.candidates("))
        let done = try XCTUnwrap(body.range(of: "KeyboardAccessoryDone.target("))
        let inside = try XCTUnwrap(body.range(of: "KeyboardDismissPoint.candidatesIgnoringControlSlop("))
        XCTAssertLessThan(outside.lowerBound, done.lowerBound)
        XCTAssertLessThan(done.lowerBound, inside.lowerBound)
    }

    /// キーボードの子孫・無効な部品・大きさ0の枠は余白を持たない
    func testSlopRectsSkipKeyboardDisabledAndEmptyControls() {
        var disabled = el(3, "button", "send", FTRect(x: 300, y: 400, width: 60, height: 40), depth: 1)
        disabled.enabled = false
        let elements = [el(1, "keyboard", nil, keyboard, depth: 0),
                        el(2, "button", "prediction", FTRect(x: 0, y: 546, width: 402, height: 44), depth: 1),
                        el(4, "other", nil, screen, depth: 0),
                        disabled,
                        el(5, "button", "zero", FTRect(x: 0, y: 0, width: 0, height: 0), depth: 1),
                        el(6, "button", "back", FTRect(x: 16, y: 48, width: 56, height: 62), depth: 1)]
        XCTAssertEqual(KeyboardDismissPoint.controlSlopRects(elements, screen: screen).map(\.x), [0])
    }

    /// 既定値はリテラルで固定する(iPad の実測: 押し上がったタブは 25pt 上(Pro)・24pt 上(Air)で反応・28pt 上(Pro)・26pt 上(Air)で反応しない)
    func testLargeScreenSlopIsPinned() {
        XCTAssertEqual(KeyboardDismissPoint.largeScreenHitSlop, 28)
        XCTAssertEqual(KeyboardDismissPoint.largeScreenMinSide, 744)
    }

    /// iPad の大きさだけ大きい余白を使う。iPhone・閉じた/開いた iPhone Duo は 16pt のまま(測っていない文脈へ流用しない)
    func testOnlyIPadSizedScreensUseTheLargerSlop() {
        for (w, h) in [(834.0, 1210.0), (1210, 834), (820, 1180), (744, 1133)] {
            XCTAssertEqual(KeyboardDismissPoint.controlSlop(screen: FTRect(x: 0, y: 0, width: w, height: h)), 28, "\(w)x\(h)")
            XCTAssertEqual(KeyboardDismissPoint.edgeSlop(screen: FTRect(x: 0, y: 0, width: w, height: h)), 28, "\(w)x\(h)")
        }
        for (w, h) in [(402.0, 874.0), (874, 402), (466, 678), (951, 669)] {
            XCTAssertEqual(KeyboardDismissPoint.controlSlop(screen: FTRect(x: 0, y: 0, width: w, height: h)), 16, "\(w)x\(h)")
            XCTAssertEqual(KeyboardDismissPoint.edgeSlop(screen: FTRect(x: 0, y: 0, width: w, height: h)), 16, "\(w)x\(h)")
        }
    }

    /// 実測の画面(iPad Pro 11 縦向き 834x1210・E2E-iOS のテキスト入力): キーボードで押し上がったタブ #tab_home (0,808 278x62) の
    /// 25pt 上 (52, 783) を選んでタブを押し、ホームへ遷移した。iPad の余白(28pt)の中は選ばない
    func testIPadTabPushedUpByTheKeyboardKeepsItsLargerSlop() throws {
        let pad = FTRect(x: 0, y: 0, width: 834, height: 1210)
        let kb = FTRect(x: 0, y: 870, width: 834, height: 340)
        let tab = el(5, "tab", "tab_home", FTRect(x: 0, y: 808, width: 278, height: 62), depth: 2)
        let elements = [el(1, "other", nil, pad, depth: 0),
                        el(2, "button", "btn_back", FTRect(x: 16, y: 48, width: 56, height: 62), depth: 1),
                        el(3, "textField", "field_single", FTRect(x: 16, y: 140, width: 802, height: 40), depth: 1),
                        el(4, "tabBar", nil, FTRect(x: 0, y: 808, width: 834, height: 62), depth: 1),
                        tab,
                        el(6, "tab", "tab_controls", FTRect(x: 278, y: 808, width: 278, height: 62), depth: 2),
                        el(7, "tab", "tab_settings", FTRect(x: 556, y: 808, width: 278, height: 62), depth: 2)]
        let found = KeyboardDismissPoint.candidates(elements: elements, screen: pad, keyboard: kb, overlays: [])
        let first = try XCTUnwrap(found.first)
        // 期待値は実測の事実(タブの上端から 25pt 上で反応した)で書く。定数から計算すると定数を戻す変異と一緒に動く
        XCTAssertLessThan(first.y, 808 - 25, "タブが反応した距離の中を選んだ: (\(first.x), \(first.y))")
    }
}
