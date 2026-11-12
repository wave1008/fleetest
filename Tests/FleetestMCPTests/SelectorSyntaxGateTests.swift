// MCP は DSL と違い、セレクタ構文の誤りを実行前に検査していなかった —— `ft_scroll_to` に
// `selector: "#"` (id が空)を渡すと、DSL の FTSelector.preflightError が実行前に落とす形を
// MCP は素通しし、見つからないまま探索を最後まで振り切っていた(実測46秒。負荷テストで観測)。
// `MCPServer.parseSelectorArgument(_:argument:)` を通すことで、DSL と同じ
// `FTSelector.validationError` の判定をデバイスに触る前に効かせる。

import XCTest
@testable import fleetest_mcp

final class SelectorSyntaxGateTests: XCTestCase {

    private var driver: FakeDriver!
    private var server: MCPServer!

    override func setUp() {
        super.setUp()
        driver = FakeDriver()
        let fake = driver!
        server = MCPServer(write: { _ in }, makeDriver: { _ in fake }, recordSnapshot: { _, _, _ in })
    }

    func testScrollToRejectsEmptyIdSelectorBeforeSearching() async {
        do {
            _ = try await server.call(tool: "ft_scroll_to", args: ["selector": "#"])
            XCTFail("selector \"#\" が通った")
        } catch {
            let message = error.localizedDescription
            XCTAssertTrue(message.contains("needs an id after it"), message)
            XCTAssertTrue(message.hasPrefix("selector:"), message)
        }
    }

    func testScrollToSwipeFrameRejectsEmptyIdSelectorBeforeSearching() async {
        do {
            _ = try await server.call(tool: "ft_scroll_to",
                                      args: ["selector": "#login_btn", "scrollFrame": "#"])
            XCTFail("scrollFrame \"#\" が通った")
        } catch {
            let message = error.localizedDescription
            XCTAssertTrue(message.contains("needs an id after it"), message)
            XCTAssertTrue(message.hasPrefix("scrollFrame:"), message)
        }
    }

    func testSnapshotWaitForRejectsEmptyIdSelectorBeforePolling() async {
        do {
            _ = try await server.call(tool: "ft_snapshot", args: ["waitFor": "#"])
            XCTFail("waitFor \"#\" が通った")
        } catch {
            let message = error.localizedDescription
            XCTAssertTrue(message.contains("needs an id after it"), message)
            XCTAssertTrue(message.hasPrefix("waitFor:"), message)
        }
    }

    /// 文字の途中の `*` は文字どおりなので、待っても当たらない。操作を撃つ前に断る(実測: 計測3周で毎回 10 秒待って外れた)
    func testInnerStarWaitForIsRefusedBeforeTheTap() async {
        do {
            _ = try await server.call(tool: "ft_tap", args: ["x": 10, "y": 10, "snapshotAfter": true, "waitFor": "19:* – *"])
            XCTFail("文字の途中に * のある waitFor が通った")
        } catch {
            let message = error.localizedDescription
            XCTAssertTrue(message.contains("was refused before anything was sent"), message)
        }
        XCTAssertFalse(driver.calls.contains { $0.hasPrefix("tap") }, "断ったのにタップを撃った: \(driver.calls)")
        XCTAssertNil(MCPServer.innerWildcardWaitForRefusal("*19:0*"))
        XCTAssertNil(MCPServer.innerWildcardWaitForRefusal("=a*b"), "文字どおりと明示した書き方は断らない")
    }

    func testBatchScrollToRejectsEmptyIdSelectorBeforeAnyStepRuns() async {
        do {
            _ = try await server.call(tool: "ft_batch", args: ["steps": "scrollTo '#'"])
            XCTFail("ft_batch の scrollTo '#' が通った")
        } catch {
            let message = error.localizedDescription
            XCTAssertTrue(message.contains("needs an id after it"), message)
        }
    }

    func testBatchSwipeElementToElementRejectsEmptyIdToSelector() async {
        do {
            _ = try await server.call(
                tool: "ft_batch",
                args: ["steps": "swipeElementToElement '#ok' '#'"])
            XCTFail("ft_batch の to '#' が通った")
        } catch {
            let message = error.localizedDescription
            XCTAssertTrue(message.contains("needs an id after it"), message)
        }
    }
}
