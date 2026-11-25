import XCTest

/// スクリプトの枠の配線をソース走査で固定する。枠が外れてもスクリプトは走るので、デバイス実行では緑のまま通る
/// (壁が消えたことに誰も気づかない)。
final class RunHookRunnerSandboxWiringTests: XCTestCase {
    private static let repoRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

    private func source(_ path: String) throws -> String {
        try String(contentsOf: Self.repoRoot.appendingPathComponent(path), encoding: .utf8)
    }

    /// setup / teardown / 孤児の teardown の3経路が `runScript` を通り、そこだけが `ScriptSandbox.launch` を呼ぶ
    func testEveryScriptGoesThroughTheSandboxEntry() throws {
        let runner = try source("Sources/fleetest/RunHookRunner.swift")
        XCTAssertEqual(runner.components(separatedBy: "try runScript(").count - 1, 2,
                       "runScript の呼び出しが run(hook:) と reapOrphans の2箇所でない。スクリプトを起こす経路は runScript(= 枠の入口)を通し、直に Process を起こさない")
        XCTAssertEqual(runner.components(separatedBy: "ScriptSandbox.launch(").count - 1, 1,
                       "ScriptSandbox.launch の呼び出しが runScript の1箇所でない。"+"スクリプトの枠(ScriptSandbox)の配線が外れている(executor.md のスクリプトの項)。"+"起こす経路は runScript だけにする")
        // 包むかどうかはマシン側の設定だけで決まる
        XCTAssertTrue(runner.contains("try ScenarioSandbox.plan(settings: try ScenarioSandbox.machineSettings())"),
                      "包むかどうかはマシン側の設定(ScenarioSandbox.machineSettings)だけで決める。プロジェクトや環境変数から決めない")
        // 親の環境を丸ごと継がせない(基本の鍵 → 秘密 → 契約 → 制御変数の順)
        XCTAssertTrue(runner.contains("ScriptSandbox.baseEnvironment(ProcessInfo.processInfo.environment)"),
                      "環境は ScriptSandbox.baseEnvironment で絞った基本の鍵から作る(親の環境を丸ごと継がせない)")
        XCTAssertFalse(runner.contains("var env = ProcessInfo.processInfo.environment"),
                       "親の環境を丸ごと継いでいる。ScriptSandbox.baseEnvironment から作る")
        XCTAssertFalse(runner.contains("process.environment = env\n"), "親の環境を継いだ変数を渡している")
        XCTAssertTrue(runner.contains("process.environment = environment\n"),
                      "process.environment には絞った environment を渡す(親の環境を継いだ変数を渡さない)")
        // 終了は終了通知で待ち、EOF は猶予つきで回収し、残った子孫を掃除する
        XCTAssertTrue(runner.contains("while waitExit(.now() + 0.2) == .timedOut"),
                      "終了は終了通知で待つ(pipe の EOF や生死の polling に戻さない。process-lifecycle.md)")
        XCTAssertTrue(runner.contains("readDone.wait(timeout: .now() + Shell.outputDrainGraceSeconds)"),
                      "出力の EOF は Shell.outputDrainGraceSeconds の猶予つきで回収する(孫が pipe を握ると無限に待つ)")
        XCTAssertTrue(runner.contains("sweepProcessGroup(pid, what:"),
                      "終了後に sweepProcessGroup で残った子孫を掃除する")
        // 中断の中継(SIGINT / SIGTERM をスクリプトへ)
        XCTAssertTrue(runner.contains("interrupt?.registerChildProcess(process)"),
                      "中断の中継(InterruptRelay)へスクリプトの子を登録する。子プロセスを起こす経路の規律(CLAUDE.md)")
        // 一時領域(gateway のソケットの置き場)は run の後に消し、死んだ run のものは回収が掃く
        XCTAssertTrue(runner.contains("defer { try? FileManager.default.removeItem(atPath: temp) }"),
                      "gateway のソケットの置き場(temp)は run の後に必ず消す")
        XCTAssertTrue(runner.contains("for stale in ScriptSandbox.staleTemporaryDirectories()"),
                      "死んだ run の一時領域を ScriptSandbox.staleTemporaryDirectories で回収する")
    }

    /// run の2経路がサービスと中断を渡し、`hooks reap` はスクリプトの孤児をサービスの孤児より先に片付ける
    func testBothRunPathsPassTheServicesSessionAndTheReapOrderIsScriptsFirst() throws {
        // 2経路とも `prepareEnvironment` の1箇所を通る(RunPreparationOrderParityTests)
        let supply = try source("Sources/fleetest/ProfileRunner+Supply.swift")
        XCTAssertTrue(supply.contains("services: servicesSession, interrupt: interruptState"),
                      "run の経路がスクリプトへ services のセッションと中断を渡していない。prepareEnvironment の1箇所で RunHookRunner へ渡す")
        let hooks = try source("Sources/fleetest/HooksCommand.swift")
        let scripts = try XCTUnwrap(hooks.range(of: "RunHookRunner.reapOrphans("))
        let services = try XCTUnwrap(hooks.range(of: "ServicesReaper.reap("))
        XCTAssertLessThan(scripts.lowerBound, services.lowerBound,
                        "hooks reap はスクリプトの孤児(RunHookRunner.reapOrphans)をサービスの孤児(ServicesReaper.reap)より先に片付ける。順序を戻す")
    }

    /// 秘密は compose.yaml が参照している名前だけ・制御変数は秘密で上書きされない(merge の順序)
    func testSecretsAreMergedBeforeTheContractAndControlVariables() throws {
        let runner = try source("Sources/fleetest/RunHookRunner.swift")
        let secrets = try XCTUnwrap(runner.range(of: "environment.merge(inputs.secrets) { $1 }"))
        let contract = try XCTUnwrap(runner.range(of: "environment.merge(contract) { $1 }"))
        let gateway = try XCTUnwrap(runner.range(of: "environment[ServiceGatewayWire.environmentKey] = server.socketPath"))
        let tmpdir = try XCTUnwrap(runner.range(of: "environment[\"TMPDIR\"] = temp"))
        XCTAssertLessThan(secrets.lowerBound, contract.lowerBound,
                        "秘密(inputs.secrets)の merge が契約の変数より後ろにある。順序は 秘密 → 契約 → 制御変数(秘密が契約を上書きしない)")
        XCTAssertLessThan(contract.lowerBound, gateway.lowerBound,
                        "gateway の制御変数が契約の merge より前にある。制御変数は契約・秘密で上書きされない順に置く")
        XCTAssertLessThan(contract.lowerBound, tmpdir.lowerBound,
                        "TMPDIR の制御変数が契約の merge より前にある。制御変数は契約・秘密で上書きされない順に置く")
        let session = try source("Sources/fleetest/ServicesSession.swift")
        XCTAssertTrue(session.contains("usedSecretNames.compactMap { name in dictionaries.secrets[name]"),
                      "スクリプトへ渡す秘密が compose.yaml の参照名(usedSecretNames)だけに絞られていない")
    }
}
