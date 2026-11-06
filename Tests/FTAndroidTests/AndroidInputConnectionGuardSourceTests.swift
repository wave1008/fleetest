// OI-163 ⑬⑭: 入力接続を見る2つの直し(InputInjector)の形をソース走査で固定する(ブリッジはデバイスでしか動かない)。
// ⑬ 接続が閉じた欄への pressEnter を撃たずに no-input-focus で断る / ⑭ 押せるだけの要素への type を焦点の接続へ回す。

import XCTest

final class AndroidInputConnectionGuardSourceTests: XCTestCase {

    private func read(_ relative: String) throws -> String {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent(relative)
        return try String(contentsOf: url, encoding: .utf8)
    }

    private func body(of marker: String, in source: String, length: Int = 2500) throws -> String {
        // 見つからないのは走査が外れた = 退行かもしれない。飛ばさずに落とす
        guard let r = source.range(of: marker) else { XCTFail("\(marker) が見つからない"); return "" }
        return String(source[r.upperBound...].prefix(length))
    }

    func testPressImeEnterRefusesWhenInputConnectionIsClosed() throws {
        let enter = try body(of: "static void pressImeEnter(UiAutomation ua) {", in: try read("AndroidRunner/src/com/example/ftbridge/InputInjector.java"))
        guard let guardAt = enter.range(of: "Boolean.FALSE.equals(servedInputConnection(ua))"),
              let fireAt = enter.range(of: "performAction(AccessibilityNodeInfo.AccessibilityAction.ACTION_IME_ENTER") else {
            return XCTFail("接続の確認か ACTION_IME_ENTER の発火が見つからない")
        }
        XCTAssertLessThan(guardAt.lowerBound, fireAt.lowerBound, "接続の確認は発火の前")
        let refusal = String(enter[guardAt.upperBound...].prefix(300))
        XCTAssertTrue(refusal.contains("409") && refusal.contains("\"no-input-focus: "),
                      "断りは 409 + no-input-focus 接頭辞(ホストが keyevent へ落とさない目印)")
    }

    func testServedInputConnectionReadsDumpsysAndTreatsUnreadableAsUnknown() throws {
        let source = try read("AndroidRunner/src/com/example/ftbridge/InputInjector.java")
        XCTAssertTrue(source.contains("\"mServedInputConnection=\""))
        let read = try body(of: "static Boolean servedInputConnection(UiAutomation ua) {", in: source, length: 1400)
        XCTAssertTrue(read.contains("!value.equals(\"null\")"), "null と明示されたときだけ FALSE")
        XCTAssertTrue(read.contains("return null;"), "読めないときは null(断らない)")
    }

    func testTypeWithRefFallsBackToFocusedConnectionAfterFocusGrace() throws {
        let source = try read("AndroidRunner/src/com/example/ftbridge/InputInjector.java")
        let typeAt = try body(of: "static String setTextAppendingAt(", in: source, length: 9000)
        guard let fb = typeAt.range(of: "SystemClock.uptimeMillis() >= focusGraceUntil\n                        && hasNodeWithId(root, shortId)") else {
            return XCTFail("焦点の猶予を待ってから回す条件が見つからない(前の欄へ打つ事故の砦)")
        }
        let tail = String(typeAt[fb.lowerBound...].prefix(700))
        XCTAssertTrue(tail.contains("focusMovedSincePress(focusedEditable(root), focusBeforePress)"))
        XCTAssertTrue(tail.contains("Boolean.TRUE.equals(servedInputConnection(ua))"))
        XCTAssertTrue(tail.contains("setTextAppending(ua, text);") && tail.contains("return FOCUSED_CONNECTION_NOTE;"))
    }

    func testRouterCarriesTheFallbackNoteInOKResponse() throws {
        let router = try body(of: "private BridgeHttpServer.Response handleType(", in: try read("AndroidRunner/src/com/example/ftbridge/BridgeRouter.java"), length: 2000)
        XCTAssertTrue(router.contains("String note = InputInjector.setTextAppendingAt("))
        XCTAssertTrue(router.contains("\\\"note\\\":"), "OKResponse.note に載せる(ホストは lastActionNote で拾う)")
    }

    /// ブリッジの注記(OKResponse.note)は BridgeClient.lastActionNote に入るが、Android の読み手は AndroidDriver.lastActionNote を読む。
    /// type が拾って渡し、読んだら消える(後の別の操作に古い注記を付けない)
    func testAndroidDriverCarriesTheTypeNoteOnceToTheReader() throws {
        let src = try read("Sources/FTAndroid/AndroidDriver.swift")
        XCTAssertEqual(src.components(separatedBy: "return $0.lastActionNote").count - 1, 2,
                       "type の2経路(末尾の改行の有無)の両方で注記を拾っていない")
        let getter = try body(of: "public var lastActionNote: String? {", in: src, length: 120)
        XCTAssertTrue(getter.contains("defer { pendingTypeNote = nil }"), "読んだ後に消していない")
    }
}
