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

    /// 最初の1回だけ profile を渡し、以後は宛先を省いた呼び出し(記憶した port / serial が足される = 直接の鍵)でも
    /// 同じプロファイルの設定を使う。鍵は `sessionKey` と同じ作り方で引く(作り方がずれると黙って既定値に戻る)
    func testCallsThatOmitTheTargetAfterAProfileCallKeepItsSettings() {
        let server = MCPServer()
        var tunables = RunTunables()
        tunables.defaultTimeout = 3
        server.rememberProfileExecution(ProfileExecutionDefaults(ScenarioExecutionSettings(containerInference: false,
                                                                                            tunables: tunables)),
                                        profileKey: MCPServer.sessionKey(profileArgs), iosPort: 8131, androidSerial: "emulator-5556")
        // foldInRememberedDevice が足す形(iOS は port と platform・Android は serial と platform)
        let iosFolded: [String: Any] = ["platform": "ios", "port": 8131]
        let androidFolded: [String: Any] = ["platform": "android", "serial": "emulator-5556"]
        for folded in [iosFolded, androidFolded] {
            XCTAssertEqual(server.executionDefaults(folded).tunables.defaultTimeout, 3, "\(folded)")
            XCTAssertFalse(server.containerInferenceEnabled(folded), "\(folded)")
        }
        XCTAssertEqual(server.executionDefaults(["platform": "ios", "port": 8123]).tunables.defaultTimeout,
                       RunTunables().defaultTimeout, "別の機は既定のまま")
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
                               "\(file.lastPathComponent): executor に既定の RunTunables() を渡している。profile の設定が ft_batch に効かず run と食い違う —— executionDefaults(args).tunables を渡す(.claude/rules/executor.md)")
            }
            for site in source.components(separatedBy: "StepExecutor(driver:").dropFirst() {
                executorSites += 1
                let call = site.prefix(600)  // 引数(数行)が収まる長さ
                XCTAssertTrue(call.contains("tunables: executionDefaults(args).tunables"),
                              "\(file.lastPathComponent): StepExecutor の生成が tunables: executionDefaults(args).tunables を渡していない(セッションの profile 設定を通す。.claude/rules/executor.md): \(call.prefix(120))")
                XCTAssertTrue(call.contains("containerInference: executionDefaults(args).containerInference"),
                              "\(file.lastPathComponent): StepExecutor の生成が containerInference: executionDefaults(args).containerInference を渡していない(.claude/rules/executor.md): \(call.prefix(120))")
            }
        }
        XCTAssertGreaterThanOrEqual(executorSites, 6, "StepExecutor(driver: の生成箇所を6件未満しか見つけられない。走査が空振りしている(書式変更か移動)。走査の対象を直す")
        let driverSource = try String(contentsOf: dir.appendingPathComponent("MCPServer+Driver.swift"), encoding: .utf8)
        XCTAssertTrue(driverSource.contains("rememberProfileExecution(ProfileExecutionDefaults(ScenarioExecutionSettings(resolvedProfile)), profileKey: key,"),
                      "MCPServer+Driver.swift の profile のドライバ生成が rememberProfileExecution で設定を覚えていない。覚えないと executionDefaults(args) が既定値に落ちる(.claude/rules/executor.md)")
        // 機の入れ替わりで捨てる(forgetDeviceState)より後に覚える
        let forget = try XCTUnwrap(driverSource.range(of: "forgetDeviceState(key)\n                    pendingWarnings[key, default: []].append("))
        let remember = try XCTUnwrap(driverSource.range(of: "rememberProfileExecution(ProfileExecutionDefaults("))
        XCTAssertLessThan(forget.lowerBound, remember.lowerBound, "rememberProfileExecution が forgetDeviceState(key) より前にある。機の入れ替わりの後始末が覚えた設定を消すので、覚えるのは後始末の後に置く")
    }
}
