// profile 経由で作った MCP のセッションは、そのプロファイルの実行時設定(`defaultTimeout` 等の RunTunables・容器推定)で
// executor を組む(DSL と同じ写像 = `ScenarioExecutionSettings(resolved)`)。既定値で組むと、ft_batch で通った手順が
// run では待ち・容器推定が変わって赤になる(逆も)

import XCTest
@testable import fleetest_mcp
import FTCore

final class MCPProfileExecutionDefaultsTests: XCTestCase {
    private let profileArgs: [String: Any] = ["profile": "ios-run", "project": "Demo"]

    func testSessionMadeFromAProfileUsesItsSettings() {
        let server = MCPServer()
        var tunables = RunTunables()
        tunables.defaultTimeout = 3
        server.profileExecutions[MCPServer.sessionKey(profileArgs)] = ProfileExecutionDefaults(
            ScenarioExecutionSettings(containerInference: false, tunables: tunables))

        XCTAssertEqual(server.executionDefaults(profileArgs).tunables.defaultTimeout, 3)
        XCTAssertFalse(server.executionDefaults(profileArgs).containerInference)
        XCTAssertFalse(server.containerInferenceEnabled(profileArgs))
    }

    /// profile を使っていないセッション(udid / serial の直指定)は既定のまま
    func testSessionWithoutAProfileUsesTheDefaults() {
        let server = MCPServer()
        let direct: [String: Any] = ["platform": "ios", "port": 8123]
        XCTAssertEqual(server.executionDefaults(direct).tunables.defaultTimeout, RunTunables().defaultTimeout)
        XCTAssertTrue(server.executionDefaults(direct).containerInference)
    }

    /// MCP の executor は全部セッションの設定を通す(既定値の `RunTunables()` を直に渡さない)。profile のドライバを作る所で
    /// 設定を覚える。どちらも既定値で書けてしまう(コンパイルは止めない)ので走査で固定する
    func testEveryMCPExecutorReadsTheSessionSettings() throws {
        let dir = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Sources/fleetest-mcp")
        let files = try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "swift" }
        var executorSites = 0
        for file in files {
            let source = try String(contentsOf: file, encoding: .utf8)
            if file.lastPathComponent != "DeviceSession.swift" {
                XCTAssertFalse(source.contains("RunTunables()"),
                               "\(file.lastPathComponent): executor に既定の RunTunables() を渡している(executionDefaults(args) を通す)")
            }
            for site in source.components(separatedBy: "StepExecutor(driver:").dropFirst() {
                executorSites += 1
                let call = site.prefix(600)  // 引数(数行)が収まる長さ
                XCTAssertTrue(call.contains("tunables: executionDefaults(args).tunables"), "\(file.lastPathComponent): \(call.prefix(120))")
                XCTAssertTrue(call.contains("containerInference: executionDefaults(args).containerInference"),
                              "\(file.lastPathComponent): \(call.prefix(120))")
            }
        }
        XCTAssertGreaterThanOrEqual(executorSites, 6)
        let driverSource = try String(contentsOf: dir.appendingPathComponent("MCPServer+Driver.swift"), encoding: .utf8)
        XCTAssertTrue(driverSource.contains("profileExecutions[key] = ProfileExecutionDefaults(ScenarioExecutionSettings(resolvedProfile))"))
    }
}
