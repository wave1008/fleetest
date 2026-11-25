// 測る口: エミュレータの gRPC のドラッグで、送りが予定から大きくずれた回だけ1行言う(判定には使わない)

import XCTest
@testable import FTAndroid

final class EmulatorDragTimingNoteTests: XCTestCase {

    /// 普段の幅(所要 1.50〜1.70 倍・間隔 最大 200ms の実測)では何も言わない
    func testOnScheduleSaysNothing() {
        XCTAssertNil(EmulatorControl.dragTimingNote(durationMs: 600, elapsedMs: 690, maxGapMs: 40))
        XCTAssertNil(EmulatorControl.dragTimingNote(durationMs: 3000, elapsedMs: 5100, maxGapMs: 200))
    }

    func testLateOrGappedDragsAreNamed() {
        XCTAssertEqual(EmulatorControl.dragTimingNote(durationMs: 3000, elapsedMs: 6100, maxGapMs: 40),
                       "emulator drag took 6100ms for a planned 3000ms (largest gap between touches 40ms)")
        XCTAssertNotNil(EmulatorControl.dragTimingNote(durationMs: 600, elapsedMs: 650, maxGapMs: 260))
        // 短いドラッグは 2 倍より +500ms のほうが大きい
        XCTAssertNil(EmulatorControl.dragTimingNote(durationMs: 100, elapsedMs: 590, maxGapMs: 20))
    }
}
