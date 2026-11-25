// 測る口: Android ブリッジの払いの注入の記録(`InputInjector.SwipeTrace`)。Java はデバイス上でしか動かないので
// ソース走査で、端末ログへ書く閾値と、拒否(500)の失敗文に添える要約の形を固定する(読み手 = 台帳と人)。

import XCTest

final class SwipeInjectionTraceSourceTests: XCTestCase {

    private var injector: String {
        get throws {
            let root = URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            return try String(contentsOf: root.appendingPathComponent("AndroidRunner/src/com/example/ftbridge/InputInjector.java"),
                              encoding: .utf8)
        }
    }

    func testLogThresholdIsPinned() throws {
        XCTAssertTrue(try injector.contains("private static final long SWIPE_GAP_LOG_THRESHOLD_MS = 100;"))
    }

    func testSummaryFormatIsPinned() throws {
        let source = try injector
        for fragment in ["\"swipe injection trace: events=\"", "\", down-to-first-move planned=\"", "\"ms actual=\"",
                         "\", max lateness=\"", "\"ms, refused=\""] {
            XCTAssertTrue(source.contains(fragment), "要約の形が変わった: \(fragment)")
        }
    }

    /// ドラッグ(`/gesture`)の本体の注入も記録を通す。tapAppIcon のドロワーを開く払いはこちらの経路で、ここが素の inject だと
    /// 拒否の失敗文に要約が付かなかった(Pixel 3a の tapAppIcon)。後始末(finally で指を離す)は記録しない
    func testGestureBodyInjectionsAreTraced() throws {
        let source = try injector
        guard let start = source.range(of: "static void gesture(UiAutomation ua, double[][][] fingers) {"),
              let finally = source.range(of: "} finally {", range: start.upperBound..<source.endIndex) else {
            return XCTFail("gesture の本体が見つからない — テストを見直すこと")
        }
        let body = String(source[start.upperBound..<finally.lowerBound])
        XCTAssertFalse(body.contains("inject(ua, pointerEvent("), "gesture の本体に記録を通らない注入がある")
        XCTAssertEqual(body.components(separatedBy: "injectTraced(ua, pointerEvent(").count - 1, 5)
    }

    /// 要約を添えるのは拒否(500)だけ。503(注入の口が死んでいる)の文言は変えない
    func testSummaryIsAttachedOnlyToTheRefusal() throws {
        let source = try injector
        XCTAssertTrue(source.contains("if (ex.status == 500) {"))
        XCTAssertTrue(source.contains("throw new BridgeRouter.BridgeException(500, ex.getMessage() + \" (\" + trace.summary() + \")\", ex.reason);"))
    }
}
