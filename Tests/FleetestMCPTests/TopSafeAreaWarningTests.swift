// 画面上端の安全領域の帯(OI-1)の MCP 側の文言。判定は TopSafeAreaAdvisoryTests。

import XCTest
import FTCore
@testable import fleetest_mcp

final class TopSafeAreaWarningTests: XCTestCase {

    private let screen = FTRect(x: 0, y: 0, width: 402, height: 874)

    private func inBand() -> ElementInfo {
        ElementInfo(ref: 1, type: "link", identifier: nil, label: "Back", value: nil, placeholder: nil,
                    enabled: true, frame: FTRect(x: 16, y: -2, width: 85, height: 18), depth: 2)
    }

    func testPreTapWarningsNamesTheBandWhenMeasured() {
        let text = RefGuard.preTapWarnings(inBand(), keyboardOcclusion: .none, suppressKeyboardWarning: false, overlayWindows: .none,
                                           safeAreaTop: .measured(62), screen: screen)
        XCTAssertTrue(text.contains("safe-area band"), text)
        XCTAssertTrue(text.hasPrefix(" (warning:"), text)
    }

    /// 無効な要素が帯の中にあっても、より具体的な「無効」が先に出る(帯は最後)
    func testDisabledIsSaidBeforeTheBand() {
        var el = inBand()
        el = ElementInfo(ref: el.ref, type: el.type, identifier: nil, label: "Back", value: nil, placeholder: nil,
                         enabled: false, frame: el.frame, depth: 2)
        let text = RefGuard.preTapWarnings(el, keyboardOcclusion: .none, suppressKeyboardWarning: false, overlayWindows: .none,
                                           safeAreaTop: .measured(62), screen: screen)
        let disabled = text.range(of: "disabled")
        let band = text.range(of: "safe-area band")
        XCTAssertNotNil(disabled, text)
        XCTAssertNotNil(band, text)
        XCTAssertLessThan(disabled!.lowerBound, band!.lowerBound, text)
    }

    func testPreTapWarningsSaysNothingWhenUnknown() {
        let text = RefGuard.preTapWarnings(inBand(), keyboardOcclusion: .none, suppressKeyboardWarning: false, overlayWindows: .none,
                                           safeAreaTop: .unknown, screen: screen)
        XCTAssertFalse(text.contains("safe-area band"), text)
    }

}
