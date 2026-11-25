// 中心が上端の安全領域の帯の中でも、枠の一部が帯の下に見えていれば撃つ点を帯の外へ寄せる(下端の帯と同じ扱い)。

import XCTest
@testable import FTCore

final class OI388TopBandTapPointTests: XCTestCase {
    private let screen = FTRect(x: 0, y: 0, width: 1280, height: 2856)

    func testFrameStraddlingTheBandIsMovedToItsVisiblePart() {
        // 帯 156px・枠 y=90..200(中心 145 は帯の中)→ 見えている部分 156..200 の中心
        let y = TapTargetGeometry.topBandTapY(for: FTRect(x: 1000, y: 90, width: 200, height: 110),
                                              safeAreaTop: .measured(156), screen: screen)
        XCTAssertEqual(y!, (156 + 200) / 2, accuracy: 0.001)
    }

    func testCentreOutsideTheBandIsNotMoved() {
        XCTAssertNil(TapTargetGeometry.topBandTapY(for: FTRect(x: 0, y: 150, width: 200, height: 100),
                                                   safeAreaTop: .measured(156), screen: screen))
    }

    func testFrameEntirelyInsideTheBandIsNotMoved() {
        XCTAssertNil(TapTargetGeometry.topBandTapY(for: FTRect(x: 0, y: 20, width: 200, height: 100),
                                                   safeAreaTop: .measured(156), screen: screen))
    }

    func testUnknownOrZeroBandIsNotMoved() {
        let f = FTRect(x: 0, y: 90, width: 200, height: 110)
        XCTAssertNil(TapTargetGeometry.topBandTapY(for: f, safeAreaTop: .unknown, screen: screen))
        XCTAssertNil(TapTargetGeometry.topBandTapY(for: f, safeAreaTop: .measured(0), screen: screen))
    }

    func testMovedPointIsOutsideTheBandAndInsideTheFrame() {
        // 中心 y=20 は帯(0..62)の中、見えている部分は 62..80 → 71
        let y = TapTargetGeometry.topBandTapY(for: FTRect(x: 0, y: -40, width: 200, height: 120),
                                              safeAreaTop: .measured(62), screen: FTRect(x: 0, y: 0, width: 402, height: 874))
        XCTAssertEqual(y!, 71, accuracy: 0.001)
    }

    func testSliverBelowTheBandIsNotMoved() {
        // 見えている部分が 1pt(62..63)なら寄せない
        XCTAssertNil(TapTargetGeometry.topBandTapY(for: FTRect(x: 0, y: -40, width: 200, height: 103),
                                                   safeAreaTop: .measured(62), screen: FTRect(x: 0, y: 0, width: 402, height: 874)))
    }
}
