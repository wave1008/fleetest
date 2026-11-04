// Flutter の secure 欄(FlutterSecureTextInputView)は UITextField のサブクラスで delegate が nil。
// pressEnter が UITextField 分岐を先に通ると何も発火しないまま成功を返す(キーボードが閉じない ✅)。
// in-app の dylib は swift test でリンクされないので、判定の順序をソースを走査して守る。

import XCTest

final class InAppPressEnterFlutterOrderTests: XCTestCase {

    func testFlutterTextInputIsDecidedBeforeTheUITextFieldBranch() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let src = try String(contentsOf: root.appendingPathComponent("InAppBridge/Sources/InAppInput.m"),
                             encoding: .utf8)
        guard let start = src.range(of: "BOOL FTPressEnterOnComposeFirstResponder(void) {") else {
            return XCTFail("FTPressEnterOnComposeFirstResponder が見つかりません")
        }
        let body = src[start.upperBound...]
        let flutter = body.range(of: "if (ftIsFlutterTextInput(v))")
        let uiKit = body.range(of: "if ([v isKindOfClass:[UITextField class]])")
        XCTAssertNotNil(flutter)
        XCTAssertNotNil(uiKit)
        if let flutter, let uiKit {
            XCTAssertLessThan(flutter.lowerBound, uiKit.lowerBound,
                              "Flutter の判定が UITextField 分岐より後ろ(secure 欄の Enter が不発のまま成功になる)")
        }
    }
}
