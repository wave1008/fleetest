// Android の座標ピンチの既定半径は、指の最大間隔が最小スケール距離(27 mm)を超えるように広げる
// (Pixel 3a で既定 238 px = 間隔 428 px が 468 px を下回り、一切ズームしなかった)。
// 判定は純関数 `MCPServer.pinchRadiusHonouringMinimumSpan` に置く(AndroidDriver は FakeDriver から模せない)

import XCTest
import FTCore
@testable import fleetest_mcp

final class MCPPinchMinimumSpanTests: XCTestCase {
    /// 468 px(440 dpi)の最小距離に対し、既定 238 px は 325 px(= 468 × 1.25 / 1.8 の切り上げ)へ
    func testDefaultRadiusIsWidenedToExceedTheMinimumSpan() {
        let widened = MCPServer.pinchRadiusHonouringMinimumSpan(defaultRadius: 238, minimumSpan: 468)
        XCTAssertEqual(widened, 325)
        // ブリッジの最大間隔(短辺 × 0.9)が最小距離を 25% 超える
        XCTAssertGreaterThanOrEqual(widened * 2 * 0.9, 468 * 1.25)
    }

    /// 既定が既に足りていれば触らない・最小距離が読めなければ既定のまま
    func testLargeDefaultAndUnknownSpanAreLeftAlone() {
        XCTAssertEqual(MCPServer.pinchRadiusHonouringMinimumSpan(defaultRadius: 400, minimumSpan: 468), 400)
        XCTAssertEqual(MCPServer.pinchRadiusHonouringMinimumSpan(defaultRadius: 238, minimumSpan: nil), 238)
        XCTAssertEqual(MCPServer.pinchRadiusHonouringMinimumSpan(defaultRadius: 238, minimumSpan: 0), 238)
    }

    /// 配線: 明示の radius には触らず、Android だけが広げる(ソース走査)
    func testOnlyAndroidWidensAndExplicitRadiusWins() throws {
        let code = try MCPServerSourceText.combined()
        XCTAssertTrue(code.contains("if pinchRadius == nil, let android = pinchDriver as? AndroidDriver,"),
                      "Android 限定・明示 radius 優先の条件が消えている")
        XCTAssertTrue(code.contains("let minimumSpan = android.minimumScalingSpanPx()"), "最小距離を端末から採っていない")
    }

    /// 注記は実際の指の間隔(短辺 × 0.9)で言う: 560px の枠 = 504px は最小 446px を超えるので「届かない」と言わない(横向きの実測)。
    /// 本当に届かない枠(400px = 360px)だけが警告する
    func testSpanNoteComparesTheRealFingerSpan() {
        let reached = MCPServer.androidPinchSpanNote(area: FTRect(x: 0, y: 0, width: 560, height: 560), widened: 325, minimumSpan: 446)
        XCTAssertFalse(reached?.contains("span only") ?? false, "504px の間隔は 446px を超えている: \(reached ?? "nil")")
        XCTAssertNil(MCPServer.androidPinchSpanNote(area: FTRect(x: 0, y: 0, width: 560, height: 560), widened: 400, minimumSpan: 446))
        let short = MCPServer.androidPinchSpanNote(area: FTRect(x: 0, y: 0, width: 400, height: 400), widened: 325, minimumSpan: 446)
        XCTAssertTrue(short?.contains("span only 360 px") ?? false, short ?? "nil")
        let widenedNote = MCPServer.androidPinchSpanNote(area: FTRect(x: 0, y: 0, width: 700, height: 700), widened: 325, minimumSpan: 446)
        XCTAssertTrue(widenedNote?.contains("radius widened to 325 px") ?? false)
    }
}
