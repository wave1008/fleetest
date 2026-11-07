import XCTest
@testable import FTCore

/// Android の staticText(押せない・入力欄でない)への type は、押す前に断る。押せる要素("clickable" = OTP の箱)は断らない
final class AndroidStaticTextTypePreflightTests: XCTestCase {
    private func executor(isAndroid: Bool) -> StepExecutor {
        StepExecutor(driver: FakeAppDriver(name: "primary", log: CallLog(), snapshotElements: [[]]),
                     isAndroid: isAndroid, tunables: RunTunables())
    }

    private func el(_ type: String) -> ElementInfo {
        ElementInfo(ref: 1, type: type, identifier: "x", label: nil, value: nil, placeholder: nil, enabled: true,
                    frame: FTRect(x: 0, y: 0, width: 10, height: 10), depth: 0)
    }

    func testAndroidStaticTextTypeIsRefusedBeforeTapping() {
        let e = el("staticText")
        let r = executor(isAndroid: true).nonTextInputPreflightRefusal(e, in: [e], action: "type")
        XCTAssertTrue(r?.contains("staticText, not a text field — refusing before anything is typed") == true, r ?? "nil")
    }

    func testAndroidClickableTypeIsNotRefused() {
        let e = el("clickable")
        XCTAssertNil(executor(isAndroid: true).nonTextInputPreflightRefusal(e, in: [e], action: "type"))
    }

    func testAndroidTextFieldTypeIsNotRefused() {
        let e = el("textField")
        XCTAssertNil(executor(isAndroid: true).nonTextInputPreflightRefusal(e, in: [e], action: "type"))
    }

    /// iOS は断らない(RN の iOS の木では押せる OTP の箱も staticText で来る = 33周目 im4 F1)
    func testIOSStaticTextTypeIsNotRefusedHere() {
        let e = el("staticText")
        XCTAssertNil(executor(isAndroid: false).nonTextInputPreflightRefusal(e, in: [e], action: "type"))
    }

    /// **中心を入力欄がちょうど1つ含む staticText は断らない**(View・RN の OTP の箱は隠れた欄 #field_otp の枠の中 = 押せば欄に焦点が移る。
    /// 34周目 alocal F2)。欄が2つ含めば断る(どれに移るか言えない)・中心が外れていれば断る
    func testAndroidStaticTextInsideAnInputFieldIsNotRefused() {
        let box = ElementInfo(ref: 2, type: "staticText", identifier: "otp_box_3", label: nil, value: nil, placeholder: nil, enabled: true,
                              frame: FTRect(x: 451, y: 567, width: 179, height: 156), depth: 2)
        let field = ElementInfo(ref: 1, type: "textField", identifier: "field_otp", label: nil, value: nil, placeholder: nil, enabled: true,
                                frame: FTRect(x: 48, y: 567, width: 1184, height: 156), depth: 1)
        let ex = executor(isAndroid: true)
        XCTAssertNil(ex.nonTextInputPreflightRefusal(box, in: [field, box], action: "type"))
        var second = field; second.ref = 3
        XCTAssertNotNil(ex.nonTextInputPreflightRefusal(box, in: [field, second, box], action: "type"), "欄が2つでも断らなかった")
        var away = field; away.frame = FTRect(x: 48, y: 900, width: 1184, height: 156)
        XCTAssertNotNil(ex.nonTextInputPreflightRefusal(box, in: [away, box], action: "type"), "中心が欄の外でも断らなかった")
    }
}
