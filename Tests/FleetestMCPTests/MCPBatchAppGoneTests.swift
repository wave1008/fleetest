// ft_batch: 途中の手の後にアプリのプロセスが消えたと確定したときだけ、続く手を撃たない。
// 前面の変化・判定不能(nil)では止めない。プロセスを聞くのは前面が対象アプリでない手の後だけ(1回約 0.95 秒)。

import XCTest
import FTBridgeClient
import FTCore
@testable import fleetest_mcp

final class MCPBatchAppGoneTests: XCTestCase {

    private func make(running: Bool?, front: String = "com.apple.springboard",
                      probes: LockedValue<Int> = LockedValue(0)) -> (MCPServer, FakeDriver) {
        let fake = FakeDriver()
        fake.foregroundBundleID = front
        let wrapped = SessionRecoveryDriver(base: fake, appIsRunning: { _ in
            probes.withLock { $0 += 1 }
            return running
        })
        let server = MCPServer(write: { _ in }, makeDriver: { _ in wrapped }, recordSnapshot: { _, _, _ in })
        server.settleWaitSeconds = 0
        server.launchedBundleIDs[MCPServer.sessionKey([:])] = "com.example.app"
        return (server, fake)
    }

    private func run(_ server: MCPServer, _ steps: String) async -> String {
        do {
            return try await server.call(tool: "ft_batch", args: ["steps": steps])
                .compactMap { $0["text"] as? String }.joined(separator: "\n")
        } catch {
            return error.localizedDescription
        }
    }

    func testStopsWhenTheProcessIsGone() async {
        let (server, fake) = make(running: false)
        let text = await run(server, "tap '#login_btn'; tap '#login_btn'; tap '#login_btn'")
        XCTAssertTrue(text.contains("Stopped after step 1 of 3"), text)
        XCTAssertTrue(text.contains("the remaining 2 step(s) were NOT sent"), text)
        XCTAssertEqual(fake.calls.filter { $0.hasPrefix("tap") }.count, 1, "\(fake.calls)")
    }

    func testRunningProcessContinues() async {
        let (server, fake) = make(running: true)
        let text = await run(server, "tap '#login_btn'; tap '#login_btn'")
        XCTAssertFalse(text.contains("NOT sent"), text)
        XCTAssertEqual(fake.calls.filter { $0.hasPrefix("tap") }.count, 2, "\(fake.calls)")
    }

    func testUnknownProcessStateContinues() async {
        let (server, fake) = make(running: nil)
        let text = await run(server, "tap '#login_btn'; tap '#login_btn'")
        XCTAssertFalse(text.contains("NOT sent"), text)
        XCTAssertEqual(fake.calls.filter { $0.hasPrefix("tap") }.count, 2, "\(fake.calls)")
    }

    func testProcessIsNotAskedWhileTheAppIsInFront() async {
        let probes = LockedValue(0)
        let (server, fake) = make(running: false, front: "com.example.app", probes: probes)
        let text = await run(server, "tap '#login_btn'; tap '#login_btn'; tap '#login_btn'")
        XCTAssertFalse(text.contains("NOT sent"), text)
        XCTAssertEqual(fake.calls.filter { $0.hasPrefix("tap") }.count, 3, "\(fake.calls)")
        XCTAssertEqual(probes.withLock { $0 }, 0, "前面が対象アプリなら遅い問い合わせを撃たない")
    }
}
