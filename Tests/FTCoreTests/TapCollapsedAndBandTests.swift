// 潰れた枠・キーボードの上へ上がったバー・見出しの下の薄い行

import XCTest
@testable import FTCore

final class TapCollapsedAndBandTests: XCTestCase {
    private func e(_ ref: Int, _ type: String, _ id: String?, _ f: FTRect) -> ElementInfo {
        ElementInfo(ref: ref, type: type, identifier: id, label: id, value: nil, placeholder: nil, enabled: true,
                    frame: f, depth: 2)
    }

    func testCollapsedFrameIsAThinBandOnly() {
        XCTAssertTrue(TapTargetGeometry.isCollapsedFrame(e(1, "button", nil, FTRect(x: 199, y: 410, width: 175, height: 2))))
        XCTAssertFalse(TapTargetGeometry.isCollapsedFrame(e(1, "button", nil, FTRect(x: 199, y: 433, width: 175, height: 48))))
        XCTAssertFalse(TapTargetGeometry.isCollapsedFrame(e(1, "button", nil, FTRect(x: 0, y: 0, width: 8, height: 8))))
    }

    func testBarRaisedAboveKeyboardCoversTheButton() {
        let screen = FTRect(x: 0, y: 0, width: 360, height: 760)
        let keyboard = FTRect(x: 0, y: 500, width: 360, height: 260)
        let button = e(1, "button", "btn_clear", FTRect(x: 20, y: 440, width: 150, height: 60))
        let bar = e(2, "button", "tab_controls", FTRect(x: 0, y: 440, width: 360, height: 60))
        XCTAssertEqual(TapTargetGeometry.coveredByBarRaisedAboveKeyboard(
            button, in: [button, bar], screen: screen, keyboard: keyboard)?.identifier, "tab_controls")
        XCTAssertNil(TapTargetGeometry.coveredByBarRaisedAboveKeyboard(
            button, in: [button, bar], screen: screen, keyboard: nil))
        let farBar = e(2, "button", "tab_controls", FTRect(x: 0, y: 380, width: 360, height: 100))
        XCTAssertNil(TapTargetGeometry.coveredByBarRaisedAboveKeyboard(
            button, in: [button, farBar], screen: screen, keyboard: keyboard), "キーボードに接していない覆いはモーダル等")
    }

    /// 貼り付く見出しの文字(180..200)の下に 7pt だけ残った行(170..177)は、文字と縦に重ならなくても帯(170..210)に覆われている
    func testThinRowInsideTheInferredBandIsCovered() throws {
        let container = FTRect(x: 0, y: 170, width: 402, height: 704)
        let scroll = ElementInfo(ref: 1, type: "scrollView", identifier: nil, label: nil, value: nil, placeholder: nil,
                                 enabled: true, frame: container, depth: 1, scrollable: true)
        let row = e(2, "button", "row_s_D2", FTRect(x: 0, y: 170, width: 402, height: 7))
        let header = e(3, "staticText", "hdr_D", FTRect(x: 16, y: 180, width: 85, height: 20))
        let band = try XCTUnwrap(TapTargetGeometry.pinnedBandCovering(row, in: [scroll, row, header], container: container))
        XCTAssertEqual(band.identifier, "hdr_D")
    }
}
