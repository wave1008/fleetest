// Android の座標ドラッグはブリッジの /gesture(1本指)で撃つ(DR-186)。経路の組み立て(純粋)を固定する
import XCTest
import FTCore
@testable import FTAndroid

final class AndroidDragGestureRequestTests: XCTestCase {
    /// 普通の払い(E2EX-Android の行を払って消す払い = 0.3 秒・550px): 始点 t=0 → 終点 t=総時間 の2点だけ(最初の区間を速めない)
    func testOrdinarySwipeIsTwoPointsOverTheDuration() {
        let r = AndroidDriver.dragGestureRequest(fromX: 915, fromY: 966, toX: 365, toY: 966, durationMs: 300, densityPxPerDp: 3)
        XCTAssertEqual(r.fingers.count, 1)
        XCTAssertEqual(r.fingers[0].points, [GesturePoint(x: 915, y: 966, t: 0), GesturePoint(x: 365, y: 966, t: 0.3)])
        XCTAssertEqual(r.totalSeconds, 0.3, accuracy: 1e-9)
    }

    /// 短くて遅いドラッグ: slop を越えるのが長押しのしきい値に近いので、最初の区間を速める点が入る(OI-168 ⑥ と同じ計画)
    func testShortSlowDragGetsTheLeadInPoint() {
        let r = AndroidDriver.dragGestureRequest(fromX: 500, fromY: 1000, toX: 500, toY: 900, durationMs: 1000, densityPxPerDp: 3)
        let points = r.fingers[0].points
        XCTAssertEqual(points.count, 3, "\(points)")
        XCTAssertEqual(points[1].t, 0.15, accuracy: 1e-9)      // leadInMs = 150
        XCTAssertEqual(points[1].y, 1000 - 36, accuracy: 1e-9)   // slop 8dp × 3 × 1.5 = 36px
        XCTAssertEqual(points[2], GesturePoint(x: 500, y: 900, t: 1))
    }
}
