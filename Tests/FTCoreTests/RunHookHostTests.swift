import XCTest
@testable import FTCore

/// RR-8.4・DR-209: 発行元から起こす beforeRun() / afterRun() の子の引数・イベントの畳み込み・一覧の段の数の検査
final class RunHookHostTests: XCTestCase {

    private static var repoRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    }

    private func source(_ path: String) throws -> String {
        try String(contentsOf: Self.repoRoot.appendingPathComponent(path), encoding: .utf8)
    }

    private func event(_ kind: String, _ configure: (inout ScenarioEvent) -> Void = { _ in }) -> ScenarioEvent {
        var event = ScenarioEvent(kind: kind)
        configure(&event)
        return event
    }

    // MARK: 一覧の段の数

    func testSingleAcceptsZeroAndOneAndRejectsMore() throws {
        XCTAssertNil(try RunHookCount.single([]))
        XCTAssertEqual(try RunHookCount.single(["Hooks"]), "Hooks")
        XCTAssertThrowsError(try RunHookCount.single(["B", "A"])) { error in
            guard case ScenarioHostError.multipleRunHooks(let names) = error else { return XCTFail("\(error)") }
            XCTAssertEqual(names, ["B", "A"])
            let text = error.localizedDescription
            XCTAssertTrue(text.contains("more than one @RunHooks class") && text.contains("A, B"), text)
        }
    }

    // MARK: 子の引数

    func testArgumentsSelectThePhaseAndNeverCarryADeviceConnection() {
        for phase in [RunHookPhase.before, .after] {
            let args = ScenarioHost.runHookArguments(
                className: "Hooks", phase: phase, reportDir: "/r", projectRoot: "/p", tunables: "{}",
                config: LocalConfig())
            XCTAssertEqual(Array(args.prefix(4)), ["run", "--scenario", "Hooks", "--run-hook"])
            XCTAssertEqual(args[4], phase.rawValue)
            XCTAssertTrue(args.contains("--device-session-stdin"))
            XCTAssertTrue(args.contains("--json"))
            for forbidden in ["--port", "--serial", "--udid", "--xcui-port", "--mode", "--app", "--after-all-only",
                              "--device-teardown-only", "--dry-run", "--debug"] {
                XCTAssertFalse(args.contains(forbidden), forbidden)
            }
        }
    }

    func testHookNameMatchesTheDSLMethod() {
        XCTAssertEqual(RunHookPhase.before.hookName, "beforeRun")
        XCTAssertEqual(RunHookPhase.after.hookName, "afterRun")
        XCTAssertEqual(RunHookPhase(rawValue: "before"), .before)
        XCTAssertNil(RunHookPhase(rawValue: "beforeRun"))
    }

    // MARK: イベントの畳み込み

    func testRunMemoOpsAreCollectedInOrderAndNotLogged() {
        var fold = RunHookEventFold()
        let lines = [
            fold.consume(event("runMemoWrite") { $0.memoKey = "a"; $0.memoValue = "1" }),
            fold.consume(event("runMemoClear")),
            fold.consume(event("runMemoWrite") { $0.memoKey = "a"; $0.memoValue = "2" }),
            fold.consume(event("idleAllowance")),
        ]
        XCTAssertTrue(lines.allSatisfy(\.isEmpty))
        XCTAssertEqual(fold.ops, [.write(key: "a", value: "1"), .clear, .write(key: "a", value: "2")])
    }

    func testStepsAndLogsAreForwardedToTheLog() {
        var fold = RunHookEventFold()
        XCTAssertEqual(fold.consume(event("log") { $0.message = "hello" }), ["hello"])
        XCTAssertFalse(fold.consume(event("step") { $0.index = 1; $0.status = "passed"; $0.description = "wait 1s" }).isEmpty)
    }

    func testFirstFailedStepBecomesTheFailureReason() {
        var fold = RunHookEventFold()
        _ = fold.consume(event("step") { $0.status = "failed"; $0.description = "beforeRun() step"; $0.detail = "boom" })
        _ = fold.consume(event("step") { $0.status = "failed"; $0.description = "second"; $0.detail = "later" })
        _ = fold.consume(event("scenarioFinished") { $0.passed = false; $0.reportPath = "/r/x.md" })
        let outcome = fold.outcome(exitStatus: 1, timedOutAfter: nil, phase: .before, stderrTail: "ignored")
        XCTAssertFalse(outcome.passed)
        XCTAssertEqual(outcome.failureReason, "beforeRun() step: boom")
        XCTAssertEqual(outcome.reportPath, "/r/x.md")
    }

    /// アサーションの detail は説明を含む(「<説明> did not hold」)。重ねると同じ文が2回並ぶ(デバイス実行の陽性対照で観測)
    func testAFailureDetailThatRepeatsTheDescriptionIsNotDoubled() {
        var fold = RunHookEventFold()
        _ = fold.consume(event("step") {
            $0.status = "failed"; $0.description = "thisIs \"yes\" == \"no\""; $0.detail = "thisIs \"yes\" == \"no\" did not hold"
        })
        let outcome = fold.outcome(exitStatus: 1, timedOutAfter: nil, phase: .before, stderrTail: nil)
        XCTAssertEqual(outcome.failureReason, "thisIs \"yes\" == \"no\" did not hold")
    }

    func testPassedFinishedEventWinsOverExitStatusAndKeepsOps() {
        var fold = RunHookEventFold()
        _ = fold.consume(event("runMemoWrite") { $0.memoKey = "k"; $0.memoValue = "v" })
        _ = fold.consume(event("scenarioFinished") { $0.passed = true })
        let outcome = fold.outcome(exitStatus: 0, timedOutAfter: nil, phase: .after, stderrTail: nil)
        XCTAssertTrue(outcome.passed)
        XCTAssertNil(outcome.failureReason)
        XCTAssertEqual(outcome.runMemoOps, [.write(key: "k", value: "v")])
    }

    func testWithoutAFinishedEventTheExitStatusDecidesAndStderrExplains() {
        let fold = RunHookEventFold()
        XCTAssertTrue(fold.outcome(exitStatus: 0, timedOutAfter: nil, phase: .before, stderrTail: nil).passed)
        let crashed = fold.outcome(exitStatus: 64, timedOutAfter: nil, phase: .after, stderrTail: "--run-hook: no @RunHooks class named X")
        XCTAssertFalse(crashed.passed)
        XCTAssertEqual(crashed.failureReason, "--run-hook: no @RunHooks class named X")
        let silent = fold.outcome(exitStatus: 9, timedOutAfter: nil, phase: .after, stderrTail: nil)
        XCTAssertEqual(silent.failureReason, "afterRun() exited with status 9")
    }

    /// afterRun() だけ / beforeRun() だけのクラス(DR-209 で正当)。宣言の無い段の子は「宣言なし」を知らせて成功で返り、
    /// 親はそれを失敗にせず・「走った」とも言わない(失敗にすると run のシナリオが1本も流れない)
    func testAnUndeclaredPhasePassesAndIsMarkedNotDeclared() {
        var fold = RunHookEventFold()
        XCTAssertTrue(fold.consume(event(RunHookOutcome.notDeclaredEventKind)).isEmpty)
        let outcome = fold.outcome(exitStatus: 0, timedOutAfter: nil, phase: .before, stderrTail: nil)
        XCTAssertTrue(outcome.passed)
        XCTAssertFalse(outcome.declared)
        var declared = RunHookEventFold()
        _ = declared.consume(event("scenarioFinished") { $0.passed = true })
        XCTAssertTrue(declared.outcome(exitStatus: 0, timedOutAfter: nil, phase: .before, stderrTail: nil).declared)
    }

    /// 子の側: 宣言の無い段は断らずに知らせて戻る(exit 64 で断ると親が beforeRun の失敗として run を止める)
    func testRunnerAnswersAnUndeclaredPhaseWithoutFailing() throws {
        let hook = try source("Sources/FTScenarioRunner/RunHookRun.swift")
        XCTAssertTrue(hook.contains("ScenarioEvent(kind: RunHookOutcome.notDeclaredEventKind)"))
        XCTAssertFalse(hook.contains("declares no"), "宣言の無い段を失敗にしている")
    }

    func testTimeoutBeatsAFinishedEventAndKeepsTheOpsThatArrived() {
        var fold = RunHookEventFold()
        _ = fold.consume(event("runMemoWrite") { $0.memoKey = "k"; $0.memoValue = "v" })
        _ = fold.consume(event("scenarioFinished") { $0.passed = true })
        let outcome = fold.outcome(exitStatus: 15, timedOutAfter: 30, phase: .before, stderrTail: nil)
        XCTAssertFalse(outcome.passed)
        XCTAssertEqual(outcome.failureReason, "beforeRun() exceeded 30s (scenarioTimeout) and was killed")
        XCTAssertEqual(outcome.runMemoOps, [.write(key: "k", value: "v")])
    }

    // MARK: 配線(ソース走査)

    /// 発行元から起こす関数はサンドボックスの入口を通り、デバイスの口を開けず、接続情報を渡さない(RR-8.4 絞った規則)
    func testHostLaunchGoesThroughTheSandboxEntryWithoutADeviceOrGateway() throws {
        let host = try source("Sources/FTCore/RunHookHost.swift")
        XCTAssertEqual(host.components(separatedBy: "try sandboxedLaunch(").count - 1, 1)
        XCTAssertTrue(host.contains("connection: nil, drivesDevice: false"))
        XCTAssertTrue(host.contains("process.environment = launch.childEnvironment("))
        XCTAssertTrue(host.contains("process.environment = childEnvironment()"))
        XCTAssertTrue(host.contains("registerChildProcess?(process)"))
        XCTAssertFalse(host.contains("SandboxGateway") || host.contains("services"),
                       "beforeRun / afterRun には compose のテスト用サーバーへの通り道を渡さない")
        XCTAssertFalse(host.contains("\"--port\"") || host.contains("\"--serial\""))
    }

    /// 子の側: `--run-hook` の口があり、ドライバは NullDriver 固定・2つ以上の @RunHooks は断る
    func testRunnerHasTheRunHookEntryWithoutADriver() throws {
        let main = try source("Sources/FTScenarioRunner/ScenarioRunnerMain.swift")
        XCTAssertTrue(main.contains(#"@Option(name: .customLong("run-hook"),"#))
        XCTAssertTrue(main.contains("try await runRunHook(runHook, deviceSession: deviceSession, tunables: runTunables)"))
        let hook = try source("Sources/FTScenarioRunner/RunHookRun.swift")
        // 呼ばれたら「<フック>() cannot use the device」で失敗する(入口の断りを通らない経路の砦。素の NullDriver は dry-run の文言)
        XCTAssertTrue(hook.contains(#"driver: NullDriver(unavailableMessage: "\(hookName)() cannot use the device")"#))
        XCTAssertTrue(hook.contains("RunHookCount.multipleMessage("))
        XCTAssertFalse(hook.contains("LastResultsStore"), "フックはシナリオではない = --failed の記録に載せない")
        let list = main
        XCTAssertTrue(list.contains("runHooks: ScenarioDiscovery.allRunHooks().map("), "一覧に @RunHooks を載せていない")
    }
}
