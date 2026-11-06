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

    /// iOS も同じ(入力欄は staticText で来ない。Round32IOSAndArgumentTests が両方向を固定)
    func testIOSStaticTextTypeIsRefusedToo() {
        let e = el("staticText")
        XCTAssertNotNil(executor(isAndroid: false).nonTextInputPreflightRefusal(e, in: [e], action: "type"))
    }
}
