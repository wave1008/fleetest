// OI-163 ⑭ の回し先を「押した前後で焦点の持ち主が変わったとき」に限る形をソース走査で固定する(ブリッジはデバイスでしか動かない)。
// 押す前から焦点のあった欄のままなら、押した要素は入力欄でない(静的テキスト)= その欄へ打たず失敗させる。

import XCTest

final class AndroidTypeFocusOwnerChangeSourceTests: XCTestCase {

    private func read(_ relative: String) throws -> String {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent(relative)
        return try String(contentsOf: url, encoding: .utf8)
    }

    func testRouterCapturesFocusBeforeThePressAndPassesIt() throws {
        let router = try read("AndroidRunner/src/com/example/ftbridge/BridgeRouter.java")
        guard let h = router.range(of: "private BridgeHttpServer.Response handleType(") else { return XCTFail("handleType が見つからない") }
        let body = String(router[h.upperBound...].prefix(2000))
        guard let capture = body.range(of: "InputInjector.focusedEditableNow(ua())"),
              let press = body.range(of: "tapUnlessAlreadyFocused(center") else {
            return XCTFail("押す前の焦点の控えか押す行が見つからない")
        }
        XCTAssertLessThan(capture.lowerBound, press.lowerBound, "控えは押す前")
        XCTAssertTrue(body.contains("TEXT_INPUT_CONFIRM_BUDGET_MS, focusBeforePress)"), "控えを setTextAppendingAt へ渡す")
    }

    func testFallbackRequiresTheFocusOwnerToDifferFromBeforeThePress() throws {
        let source = try read("AndroidRunner/src/com/example/ftbridge/InputInjector.java")
        guard let r = source.range(of: "static String setTextAppendingAt(") else { return XCTFail("見つからない") }
        let typeAt = String(source[r.upperBound...].prefix(9000))
        XCTAssertTrue(typeAt.contains("focusMovedSincePress(focusedEditable(root), focusBeforePress)"))
        guard let d = source.range(of: "private static boolean focusMovedSincePress(") else { return XCTFail("判定が見つからない") }
        let fn = String(source[d.upperBound...].prefix(300))
        XCTAssertTrue(fn.contains("now != null && (before == null || !now.equals(before))"),
                      "前が無い・別の欄へ移った、だけ回す。同じ欄なら回さない")
    }
}
