// `StepExecutor.visibleDragArea`: slowDrag に渡す枠は、容器のうち画面に出ていてキーボードに覆われていない部分。
// 容器を `ScrollGeometry.viewport` に直に渡すと、容器の下のキーボードで枠が広がり・中心より上のキーボードで切られなかった

import XCTest
@testable import FTCore

final class VisibleDragAreaTests: XCTestCase {
    private let screen = FTRect(x: 0, y: 0, width: 402, height: 874)

    private func snapshot(keyboard: FTRect?) -> SnapshotResponse {
        var s = SnapshotResponse(sessionBundleID: nil, screen: screen, elements: [], truncatedCount: 0)
        s.keyboardFrame = keyboard
        return s
    }

    func testKeyboardOverTheContainerIsCutOff() {
        let area = StepExecutor.visibleDragArea(FTRect(x: 0, y: 100, width: 402, height: 600),
                                                in: snapshot(keyboard: FTRect(x: 0, y: 500, width: 402, height: 374)))
        XCTAssertEqual(area, FTRect(x: 0, y: 100, width: 402, height: 400))
    }

    /// 画面の外(下)に申告された隠れたキーボードは捨てる = 容器の画面に出ている部分のまま
    func testHiddenKeyboardBelowTheScreenIsIgnored() {
        let area = StepExecutor.visibleDragArea(FTRect(x: 0, y: 100, width: 402, height: 600),
                                                in: snapshot(keyboard: FTRect(x: 0, y: 918, width: 402, height: 300)))
        XCTAssertEqual(area, FTRect(x: 0, y: 100, width: 402, height: 600))
    }

    /// 容器が画面からはみ出す分は切る
    func testPartOutsideTheScreenIsCutOff() {
        let area = StepExecutor.visibleDragArea(FTRect(x: 0, y: 500, width: 402, height: 900), in: snapshot(keyboard: nil))
        XCTAssertEqual(area, FTRect(x: 0, y: 500, width: 402, height: 374))
    }

    /// 画面と交わらない容器では撃たない
    func testContainerOffTheScreenGivesNothing() {
        XCTAssertNil(StepExecutor.visibleDragArea(FTRect(x: 0, y: 1000, width: 402, height: 300), in: snapshot(keyboard: nil)))
    }
}
