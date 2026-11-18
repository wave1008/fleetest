// ft_scroll_to が返した木の id も dry-run の台帳へ落ちる(書いていなかったのは ft_scroll_to だけで、そこで初めて見えた
// `#id` に dry-run が「綴り誤りかも」と警告し、エージェントが警告を無視することを覚えた)

import XCTest
@testable import FTCore
@testable import fleetest_mcp

final class ScrollToRecordsSelectorsTests: XCTestCase {

    func testScrollToRecordsTheReturnedTree() async throws {
        let driver = FakeDriver()
        driver.hitTestAnswer = .hittable(true)
        let recorded = LockedValue<[(ids: [String], platform: String)]>([])
        let server = MCPServer(write: { _ in }, makeDriver: { _ in driver }, recordSnapshot: { snapshot, platform, _ in
            recorded.withLock { $0.append((snapshot.elements.compactMap(\.identifier), platform)) }
        })
        _ = try await server.call(tool: "ft_scroll_to", args: ["selector": "#login_btn"])
        let got = recorded.withLock { $0 }
        XCTAssertEqual(got.count, 1, "ft_scroll_to の木が台帳へ落ちていない")
        XCTAssertTrue(got.first?.ids.contains("login_btn") ?? false, "\(got)")
        XCTAssertEqual(got.first?.platform, "ios")
    }
}
