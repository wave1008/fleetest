// OI-169 ⑧: /scrollAction の最小の容器が端でも、入れ子の内側に送れる容器が同じ列にあれば atEdge と言わない。
// ブリッジは Java でデバイス上にしか動かないので、選び方の形をソース走査で固定する。

import XCTest

final class ScrollActionNestedSenderScanTests: XCTestCase {

    private func source() throws -> String {
        var url = URL(fileURLWithPath: #filePath)
        for _ in 0..<3 { url.deleteLastPathComponent() }
        return try String(contentsOf: url.appendingPathComponent(
            "AndroidRunner/src/com/example/ftbridge/BridgeRouter.java"), encoding: .utf8)
    }

    private func handler(_ s: String) throws -> String {
        let start = try XCTUnwrap(s.range(of: "private BridgeHttpServer.Response handleScrollAction"))
        let end = try XCTUnwrap(s.range(of: "SCROLL_SETTLE_POLL_MS = ", range: start.upperBound..<s.endIndex))
        return String(s[start.lowerBound..<end.lowerBound])
    }

    /// 端の判定(atEdge)の前に、入れ子の送れる容器を探す
    func testNestedSenderIsTriedBeforeAtEdge() throws {
        let h = try handler(try source())
        let nested = try XCTUnwrap(h.range(of: "nestedSenderInColumn(target"))
        let edge = try XCTUnwrap(h.range(of: "o.put(\"atEdge\", true)"))
        XCTAssertLessThan(nested.lowerBound, edge.lowerBound)
    }

    /// 黙って違う容器を送らない: 応答に note を載せる
    func testRedirectCarriesNote() throws {
        let h = try handler(try source())
        XCTAssertTrue(h.contains("o.put(\"note\""))
    }

    /// 候補は軸の一致・送る向きの申告・点の交差軸の座標を通ることを全部要求する
    func testCandidateConditions() throws {
        let s = try source()
        let start = try XCTUnwrap(s.range(of: "private static AccessibilityNodeInfo nestedSenderInColumn"))
        let end = try XCTUnwrap(s.range(of: "private static AccessibilityNodeInfo enclosingScrollableWithAction",
                                         range: start.upperBound..<s.endIndex))
        let body = String(s[start.lowerBound..<end.lowerBound])
        XCTAssertTrue(body.contains("scrollAxis(child) == (vertical ? 1 : 2)"))
        XCTAssertTrue(body.contains("scrollActionFor(child, finger, vertical) != null"))
        XCTAssertTrue(body.contains("cross >= crossLo && cross < crossHi"))
    }
}
