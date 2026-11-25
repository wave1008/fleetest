// OI-398 の測る口: Android ブリッジの払いの注入の記録(`InputInjector.SwipeTrace`)。Java はデバイス上でしか動かないので
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

    /// 要約を添えるのは拒否(500)だけ。503(注入の口が死んでいる)の文言は変えない
    func testSummaryIsAttachedOnlyToTheRefusal() throws {
        let source = try injector
        XCTAssertTrue(source.contains("if (ex.status == 500) {"))
        XCTAssertTrue(source.contains("throw new BridgeRouter.BridgeException(500, ex.getMessage() + \" (\" + trace.summary() + \")\", ex.reason);"))
    }
}
