// 画面上端の安全領域の帯(OI-1)の MCP 側の文言と DSL 共有(RefFireCheck)の経路。判定は TopSafeAreaAdvisoryTests。

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
        let text = RefGuard.preTapWarnings(inBand(), keyboardOcclusion: .none, overlayWindows: .none,
                                           safeAreaTop: .measured(62), screen: screen)
        XCTAssertTrue(text.contains("safe-area band"), text)
        XCTAssertTrue(text.hasPrefix(" (warning:"), text)
    }

    func testPreTapWarningsSaysNothingWhenUnknown() {
        let text = RefGuard.preTapWarnings(inBand(), keyboardOcclusion: .none, overlayWindows: .none,
                                           safeAreaTop: .unknown, screen: screen)
        XCTAssertFalse(text.contains("safe-area band"), text)
    }

    /// DSL・CLI 共有の入口(RefFireCheck)も同じ事実を助言として運ぶ。断りにはしない(警告のみ)
    func testRefFireCheckCarriesTheBandAsAdvisoryNotRefusal() {
        let snapshot = SnapshotResponse(sessionBundleID: nil, screen: screen, elements: [inBand()],
                                        truncatedCount: 0, safeAreaTop: .measured(62))
        let result = RefFireCheck.evaluate(inBand(), in: snapshot, isAndroid: false)
        XCTAssertNil(result.refusal)
        XCTAssertTrue(result.advisory?.contains("safe-area band") == true, result.advisory ?? "nil")
    }
}
