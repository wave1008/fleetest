//: 中心がキーボードの下でも上端が見えている要素は、見えている部分を撃つ(判定は KeyboardOcclusion.visibleAboveKeyboard)

import XCTest
@testable import FTCore

final class KeyboardVisiblePartTests: XCTestCase {
    private func button(y: Double, h: Double) -> ElementInfo {
        ElementInfo(ref: 2, type: "button", identifier: "btn_discard", label: nil, value: nil,
                    placeholder: nil, enabled: true,
                    frame: FTRect(x: 100, y: y, width: 200, height: h), depth: 2)
    }
    private let keyboard = FTRect(x: 0, y: 200, width: 400, height: 150)

    func testReturnsTheBandAboveTheKeyboardTop() {
        let el = button(y: 186, h: 48)   // 上端 14pt がキーボードの上
        let occlusion = KeyboardOcclusion.resolve(reported: keyboard, in: [el], screen: nil)
        XCTAssertNotNil(occlusion.advisory(for: el), "中心 210 はキーボードの下")
        let band = occlusion.visibleAboveKeyboard(el)
        XCTAssertEqual(band?.y, 186)
        XCTAssertEqual(band?.height ?? 0, 14, accuracy: 0.01)
        XCTAssertLessThan(band!.centerY, 200)
    }

    func testNilWhenTheVisibleBandIsBelowTheFloor() {
        let el = button(y: 196, h: 48)   // 4pt しか見えない(床 8)
        let occlusion = KeyboardOcclusion.resolve(reported: keyboard, in: [el], screen: nil)
        XCTAssertNil(occlusion.visibleAboveKeyboard(el))
    }

    func testNilWhenTheElementStartsBelowTheKeyboardTop() {
        let el = button(y: 220, h: 48)
        let occlusion = KeyboardOcclusion.resolve(reported: keyboard, in: [el], screen: nil)
        XCTAssertNil(occlusion.visibleAboveKeyboard(el))
    }
}
