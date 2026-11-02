// ft_tap(ref): 容器の縁で半分切れた行(frame の中心が容器の外)は、スクロールせず見えている部分の点を撃つ。
// 判定は DSL と共有の `TapTargetGeometry.visibleTapRect`。見えている部分が無ければ従来どおり ref で撃つ。

import XCTest
import FTCore
@testable import fleetest_mcp

final class MCPTapVisiblePartTests: XCTestCase {

    private func element(_ ref: Int, id: String, frame: FTRect, type: String = "clickable", depth: Int = 2) -> ElementInfo {
        ElementInfo(ref: ref, type: type, identifier: id, label: id, value: nil, placeholder: nil,
                    enabled: true, frame: frame, depth: depth)
    }

    /// 容器 y=100..500。同じ深さの行を中に1つ添える(容器の推測が兄弟2つ以上を要求する)
    private func make(rowY: Double) -> (MCPServer, FakeDriver) {
        let fake = FakeDriver()
        fake.foregroundBundleID = "com.example.app"
        fake.snapshotResponse.elements = [
            element(1, id: "list", frame: FTRect(x: 0, y: 100, width: 300, height: 400), type: "scrollable", depth: 1),
            element(2, id: "row_inside", frame: FTRect(x: 0, y: 110, width: 300, height: 100)),
            element(3, id: "row_cut", frame: FTRect(x: 0, y: rowY, width: 300, height: 100)),
        ]
        let server = MCPServer(write: { _ in }, makeDriver: { _ in fake }, recordSnapshot: { _, _, _ in })
        server.settleWaitSeconds = 0
        return (server, fake)
    }

    private func tap(_ server: MCPServer, ref: Int) async throws -> String {
        _ = try await server.call(tool: "ft_snapshot", args: [:])
        return try await server.call(tool: "ft_tap", args: ["ref": ref])
            .compactMap { $0["text"] as? String }.joined(separator: "\n")
    }

    func testHalfCutRowIsTappedAtTheVisiblePart() async throws {
        // 行 y=460..560、容器の下端 500 → 見えているのは 460..500(40pt)・frame の中心 510 は容器の外
        let (server, fake) = make(rowY: 460)
        let text = try await tap(server, ref: 3)
        XCTAssertTrue(fake.calls.contains { $0.hasPrefix("tap(x:150.0,y:480.0)") }, "\(fake.calls)")
        XCTAssertFalse(fake.calls.contains { $0.hasPrefix("tap(ref:") }, "\(fake.calls)")
        XCTAssertTrue(text.contains("the visible part was tapped at (150, 480)"), text)
        XCTAssertFalse(fake.calls.contains { $0.contains("swipe") || $0.contains("drag") }, "スクロールしない: \(fake.calls)")
    }

    func testRowWithCentreInsideIsTappedByRef() async throws {
        // 行 y=420..520 → 中心 470 は容器の中
        let (server, fake) = make(rowY: 420)
        let text = try await tap(server, ref: 3)
        XCTAssertTrue(fake.calls.contains { $0.hasPrefix("tap(ref:") }, "\(fake.calls)")
        XCTAssertFalse(text.contains("visible part was tapped"), text)
    }

    func testNoVisiblePartKeepsTheRefTap() async throws {
        // 行 y=495..595 → 見えているのは 5pt(床未満)= 従来どおり ref
        let (server, fake) = make(rowY: 495)
        let text = try await tap(server, ref: 3)
        XCTAssertFalse(text.contains("visible part was tapped"), text)
        XCTAssertFalse(fake.calls.contains { $0.hasPrefix("tap(x:") }, "\(fake.calls)")
    }
}
