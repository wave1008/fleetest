// ref なしの type / clear が載せる `focusTapWhenImeHidden`(Android のブリッジが「IME が出ていなければ焦点の欄を押す」のを
// 撃つかの判断材料)の固定。Flutter だけ true・Flutter でないと分かっていれば false・不明と ref ありは欄ごと省く。

import XCTest
@testable import FTBridgeClient
import FTCore

final class FocusTapWhenImeHiddenWireTests: FTBridgeClientSourceScanCase {

    private func json(_ stub: RecordingStubServer, _ path: String) throws -> [String: Any] {
        let body = try XCTUnwrap(stub.body(for: path), "\(path) を受けていない: \(stub.paths)")
        return try XCTUnwrap(JSONSerialization.jsonObject(with: Data(body.utf8)) as? [String: Any])
    }

    private func run(framework: AppUIFramework?, ref: Int?) async throws -> (type: [String: Any], clear: [String: Any]) {
        let stub = try RecordingStubServer()
        defer { stub.stop() }
        let client = BridgeClient(port: stub.port, timeoutSeconds: 5, token: "")
        client.setAppUIFramework(framework)
        try await client.type(ref: ref, text: "x")
        try await client.clearInput(ref: ref)
        return (try json(stub, "POST /type"), try json(stub, "POST /clear"))
    }

    func testFlutterWithoutRefSendsTrue() async throws {
        let sent = try await run(framework: .flutter, ref: nil)
        XCTAssertEqual(sent.type["focusTapWhenImeHidden"] as? Bool, true)
        XCTAssertEqual(sent.clear["focusTapWhenImeHidden"] as? Bool, true)
    }

    func testNonFlutterWithoutRefSendsFalse() async throws {
        for framework in [AppUIFramework.androidView, .compose, .reactNative] {
            let sent = try await run(framework: framework, ref: nil)
            XCTAssertEqual(sent.type["focusTapWhenImeHidden"] as? Bool, false, "\(framework)")
            XCTAssertEqual(sent.clear["focusTapWhenImeHidden"] as? Bool, false, "\(framework)")
        }
    }

    func testUnknownFrameworkOmitsTheKey() async throws {
        let sent = try await run(framework: nil, ref: nil)
        XCTAssertNil(sent.type["focusTapWhenImeHidden"])
        XCTAssertNil(sent.clear["focusTapWhenImeHidden"])
    }

    func testRefRequestsNeverCarryTheKey() async throws {
        let sent = try await run(framework: .androidView, ref: 1)
        XCTAssertNil(sent.type["focusTapWhenImeHidden"])
        XCTAssertNil(sent.clear["focusTapWhenImeHidden"])
    }

    /// 配線の固定: DSL(ScenarioRunnerMain)・MCP(resolveExecutorHints と ft_type / ft_clear_input)・AndroidDriver が渡している
    func testHostsPassTheFrameworkToTheAndroidBridge() throws {
        let runner = try Self.readSource("Sources/FTScenarioRunner/ScenarioRunnerMain.swift")
        XCTAssertTrue(runner.contains("androidDriver.appUIFramework = uiFrameworkHint"), "DSL の配線が無い")
        let bridge = try Self.readSource("Sources/FTAndroid/AndroidBridge.swift")
        XCTAssertGreaterThanOrEqual(bridge.components(separatedBy: "setAppUIFramework(appUIFramework)").count - 1, 2,
                                    "withBridge が (再接続後も含め) ブリッジへ渡していない")
        let snapshot = try Self.readSource("Sources/fleetest-mcp/MCPServer+Snapshot.swift")
        let screen = try Self.readSource("Sources/fleetest-mcp/MCPServer+ScreenTools.swift")
        XCTAssertTrue(snapshot.contains("wireAndroidUIFramework("), "MCP の ft_batch 経路の配線が無い")
        XCTAssertGreaterThanOrEqual(screen.components(separatedBy: "wireAndroidUIFramework(").count - 1, 1)
    }
}
