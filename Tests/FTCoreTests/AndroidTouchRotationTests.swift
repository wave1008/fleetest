// Emulator の gRPC タッチは自然な向きの座標で受ける。表示の座標からの変換(AndroidTouchRotation)の実測値を固定する
// (OI-75。実測 2026-11-02: Pixel 9 emulator 1080x2424 で、回転 1・2・3 とも逆変換した点が表示の狙った行に当たった)。

import XCTest
@testable import FTCore

final class AndroidTouchRotationTests: XCTestCase {
    private let natural = AndroidTouchRotation.Size(width: 1080, height: 2424)

    func testRotation0IsIdentity() {
        let p = AndroidTouchRotation.nativePoint(x: 540, y: 1000, rotation: 0, natural: natural)
        XCTAssertEqual(p?.x, 540)
        XCTAssertEqual(p?.y, 1000)
    }

    /// 回転 1: 表示 (900,520) に当てるには自然座標 (559,900) を撃つ(実測は (560,900) で当たった = 画素の添字との差の1)
    func testRotation1() {
        let p = AndroidTouchRotation.nativePoint(x: 900, y: 520, rotation: 1, natural: natural)
        XCTAssertEqual(p?.x, 559)
        XCTAssertEqual(p?.y, 900)
    }

    func testRotation2() {
        let p = AndroidTouchRotation.nativePoint(x: 540, y: 1000, rotation: 2, natural: natural)
        XCTAssertEqual(p?.x, 539)
        XCTAssertEqual(p?.y, 1423)
    }

    func testRotation3() {
        let p = AndroidTouchRotation.nativePoint(x: 1500, y: 520, rotation: 3, natural: natural)
        XCTAssertEqual(p?.x, 520)
        XCTAssertEqual(p?.y, 923)
    }

    func testOutOfRangeRotationIsNil() {
        XCTAssertNil(AndroidTouchRotation.nativePoint(x: 1, y: 1, rotation: 4, natural: natural))
        XCTAssertNil(AndroidTouchRotation.nativePoint(x: 1, y: 1, rotation: -1, natural: natural))
    }

    /// 表示の四隅が自然座標の範囲に収まる(負・はみ出しにならない)
    func testCornersStayInsideTheNaturalPanel() {
        for rotation in 0...3 {
            let landscape = rotation % 2 == 1
            let w: Int32 = landscape ? 2424 : 1080
            let h: Int32 = landscape ? 1080 : 2424
            for (x, y) in [(Int32(0), Int32(0)), (w - 1, 0), (0, h - 1), (w - 1, h - 1)] {
                let p = AndroidTouchRotation.nativePoint(x: x, y: y, rotation: rotation, natural: natural)!
                XCTAssertTrue((0..<1080).contains(p.x) && (0..<2424).contains(p.y),
                              "rotation \(rotation) (\(x),\(y)) -> \(p)")
            }
        }
    }

    func testParseReadsNaturalSize() {
        let dump = """
          Display: mDisplayId=0 (organized)
            init=1080x2424 420dpi cur=2424x1080 app=2424x1080
            mRotation=1 mDeferredRotationPauseCount=0
        """
        let state = AndroidDisplayRotation.parse(dump)
        XCTAssertEqual(state.rotation, 1)
        XCTAssertEqual(state.naturalSize, natural)
    }

    /// AndroidDriver の gRPC 経路(drag / long-press)が必ず回転を通す
    func testDriverRoutesGrpcThroughNativeTouchPoint() throws {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/FTAndroid/AndroidDriver.swift")
        let text = try String(contentsOf: url, encoding: .utf8)
        XCTAssertTrue(text.contains("EmulatorControl.drag(serial: serial, fromX: from.x"))
        XCTAssertTrue(text.contains("EmulatorControl.longPress(serial: serial, x: native.x"))
        XCTAssertFalse(text.contains("fromX: fromXi, fromY: fromYi,\n                                 toX: toXi"))
    }
}
