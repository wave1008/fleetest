// 渡したセレクタがその要素だけを選ぶなら、応答の `(selector: …)` はそれを返す(OI-268⑩: `通知:rightSwitch` を渡したのに、
// 状態を映す文字 `notify=off` を錨にした別の相対形を返し、押した後の画面ではもう当たらなかった)

import XCTest
import FTCore
@testable import fleetest_mcp

final class PassedSelectorEchoTests: XCTestCase {

    private func server(_ elements: [ElementInfo]) -> MCPServer {
        let driver = FakeDriver()
        driver.snapshotResponse = SnapshotResponse(sessionBundleID: "com.example",
                                                   screen: FTRect(x: 0, y: 0, width: 400, height: 800),
                                                   elements: elements, truncatedCount: 0)
        return MCPServer(write: { _ in }, makeDriver: { _ in driver }, recordSnapshot: { _, _, _ in })
    }

    private let screen = [
        PassedSelectorEchoTests.make(1, "staticText", "通知", 16, 100, 100, 40),
        PassedSelectorEchoTests.make(2, "switch", nil, 300, 100, 60, 40),
        PassedSelectorEchoTests.make(3, "staticText", "notify=off", 16, 145, 380, 40),
        PassedSelectorEchoTests.make(4, "switch", nil, 300, 220, 60, 40),
    ]

    private static func make(_ ref: Int, _ type: String, _ label: String?, _ x: Double, _ y: Double, _ w: Double, _ h: Double) -> ElementInfo {
        ElementInfo(ref: ref, type: type, identifier: nil, label: label, value: nil, placeholder: nil, enabled: true,
                    frame: FTRect(x: x, y: y, width: w, height: h), depth: 1)
    }

    func testTapEchoesThePassedSelectorWhenItPicksOnlyThatElement() async throws {
        let server = server(screen)
        _ = try await server.call(tool: "ft_snapshot", args: [:])
        let content = try await server.call(tool: "ft_tap", args: ["selector": "通知:rightSwitch"])
        let text = content.compactMap { $0["text"] as? String }.joined(separator: "\n")
        XCTAssertTrue(text.contains("(selector: 通知:rightSwitch)"), text)
    }

    /// 渡したセレクタが他の要素も選ぶなら、従来どおりツールが一意な形を勧める
    func testAmbiguousPassedSelectorFallsBackToTheGradedOne() async throws {
        let server = server(screen)
        _ = try await server.call(tool: "ft_snapshot", args: [:])
        let content = try await server.call(tool: "ft_tap", args: ["selector": ".switch"])
        let text = content.compactMap { $0["text"] as? String }.joined(separator: "\n")
        XCTAssertFalse(text.contains("(selector: .switch)"), text)
    }
}
