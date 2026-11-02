// Android でアプリが落ちた後、同じ id を持つ別アプリが前面でも、ft_batch / ft_scroll_to は撃たずに断る
// (判定は FTCore の AppProcessGone を StepExecutor が共有。プロセスが居る・判定できないときは通す)。
// F3: 前面を離れて終わったバッチは、画面の変化を見ていない触る手を名指す。

import XCTest
import FTCore
@testable import fleetest_mcp

final class MCPAndroidAppGoneGuardTests: XCTestCase {

    private func make(running: Bool?) -> (MCPServer, FakeDriver) {
        let fake = FakeDriver()
        fake.answers = .android
        // 木の持ち主は別アプリ(同じ id #login_btn を持つ)
        fake.snapshotResponse = SnapshotResponse(
            sessionBundleID: "com.example.other",
            screen: FTRect(x: 0, y: 0, width: 390, height: 844),
            elements: fake.snapshotResponse.elements, truncatedCount: 0)
        let server = MCPServer(write: { _ in }, makeDriver: { _ in fake }, recordSnapshot: { _, _, _ in })
        server.settleWaitSeconds = 0
        let key = MCPServer.sessionKey([:])
        server.bridges[key] = "android"
        server.launchedBundleIDs[key] = "com.example.app"
        server.androidPackageRunning = { _, _ in running }
        return (server, fake)
    }

    private func run(_ server: MCPServer, tool: String = "ft_batch", _ args: [String: Any]) async -> String {
        do {
            return try await server.call(tool: tool, args: args)
                .compactMap { $0["text"] as? String }.joined(separator: "\n")
        } catch {
            return error.localizedDescription
        }
    }

    func testBatchStopsBeforeFiringAtAnotherAppWhenTheProcessIsGone() async {
        let (server, fake) = make(running: false)
        let text = await run(server, ["steps": "tap '#login_btn'; tap '#login_btn'"])
        XCTAssertTrue(text.contains("is not running"), text)
        XCTAssertTrue(text.contains("nothing was sent"), text)
        XCTAssertTrue(text.contains("Stopped at step 1"), text)
        XCTAssertFalse(fake.calls.contains { $0.hasPrefix("tap") }, "\(fake.calls)")
    }

    func testBatchTypeWithSelectorIsRefusedToo() async {
        let (server, fake) = make(running: false)
        _ = await run(server, ["steps": "type '#login_btn' 'YY'"])
        XCTAssertFalse(fake.calls.contains { $0.hasPrefix("type") }, "\(fake.calls)")
    }

    /// 陰性対照: プロセスが居る(別アプリへ移っただけ)・判定できない
    func testBatchStillRunsWhenTheProcessIsRunningOrUnknown() async {
        for running in [Optional(true), nil] {
            let (server, fake) = make(running: running)
            _ = await run(server, ["steps": "tap '#login_btn'"])
            XCTAssertTrue(fake.calls.contains { $0.hasPrefix("tap") }, "\(String(describing: running)): \(fake.calls)")
        }
    }

    func testScrollToDoesNotSweepAnotherAppWhenTheProcessIsGone() async {
        let (server, fake) = make(running: false)
        let text = await run(server, tool: "ft_scroll_to", ["selector": "#missing"])
        XCTAssertTrue(text.contains("is not running"), text)
        XCTAssertFalse(fake.calls.contains { $0.hasPrefix("swipe") }, "\(fake.calls)")
    }

    // MARK: - F3

    func testVerdictNamesTouchStepsWhoseEffectWasNotObservedWhenTheAppLeftTheFront() {
        let text = MCPServer.batchVerdict(stepCount: 5, suspects: [], appLeftFront: true, unobservedTouches: [3, 4])
        XCTAssertTrue(text.contains("Touch step(s) 3, 4"), text)
        XCTAssertFalse(MCPServer.batchVerdict(stepCount: 5, suspects: [], appLeftFront: true, unobservedTouches: [])
            .contains("Touch step"))
        let unreadable = MCPServer.unreadableAfterBatchMessage(
            stepLines: ["x"], stepCount: 5, error: MCPError("422"), unobservedTouches: [5])
        XCTAssertTrue(unreadable.contains("Touch step(s) 5"), unreadable)
    }
}
