// `run --run-hook before|after`(RR-8.4・DR-209)。@RunHooks のクラスの beforeRun() / afterRun() を1回だけ実行する専用の子。
// ドライバを持たない(デバイスのコマンドは FTDSL が「cannot use the device」で断る)・--port / --serial は渡されない。
// run メモの写しは `--device-session-stdin` の1行目で受け、書き込みは通常のシナリオと同じ runMemoWrite / runMemoClear で出す。
// 結果の記録はクラスの `<Class>.beforeRun` / `<Class>.afterRun`(シナリオではない = `--failed` の記録には載せない)

import ArgumentParser
import Foundation
import FTCore
import FTDSL

extension RunScenario {
    func runRunHook(_ rawPhase: String, deviceSession: DeviceSessionHandoff?, tunables runTunables: RunTunables) async throws {
        guard let phase = RunHookPhase(rawValue: rawPhase) else {
            throw ValidationError("--run-hook must be 'before' or 'after' (got '\(rawPhase)')")
        }
        let all = ScenarioDiscovery.allRunHooks()
        if all.count > 1 {
            ConsoleOut.err(RunHookCount.multipleMessage(classNames: all.map(\.className)))
            throw ExitCode(64)
        }
        guard let found = all.first(where: { $0.className == scenario }) else {
            ConsoleOut.err("--run-hook: no @RunHooks class named \(scenario)")
            throw ExitCode(64)
        }
        let hookName = phase == .before ? "beforeRun" : "afterRun"
        guard let body = phase == .before ? found.beforeRun : found.afterRun else {
            ConsoleOut.err("--run-hook \(rawPhase): \(found.className) declares no \(hookName)()")
            throw ExitCode(64)
        }
        let scenarioID = "\(found.className).\(hookName)"

        let emit: (ScenarioEvent) -> Void = json
            ? { ConsoleOut.out($0.encodedLine()) }
            : { event in
                for line in ScenarioLogFormatter.lines(for: event) { ConsoleOut.out(line) }
            }
        var started = ScenarioEvent(kind: "scenarioStarted")
        started.scenario = scenarioID
        started.title = hookName
        emit(started)

        let core = FTDriveCore(driver: NullDriver(unavailableMessage: "\(hookName)() cannot use the device"), platform: platform, app: app ?? "",
                               scenarioID: scenarioID, scenarioTitle: hookName,
                               delegate: nil, healingEnabled: false,
                               tunables: runTunables,
                               fmTextVisibilityCheckEnabled: false, screenLooksLikeEnabled: false,
                               containerInference: false, occlusionOCREnabled: false,
                               visionClassifierProjectRoot: projectDir.map { URL(fileURLWithPath: $0) },
                               preferCheckStateClassifier: false, findImagePrewarm: false,
                               emit: emit)
        core.runMemo = deviceSession?.runMemo ?? [:]
        core.redactAccountValues = redactAccountValues
        core.directoryForLog = TestLogPaths.logDirectory(
            reportDir: URL(fileURLWithPath: reportDir).standardizedFileURL,
            runStartedAt: runStartedAt.flatMap { TestLogSessionLabel.day(ofLabel: $0) != nil ? $0 : nil }
                ?? TestLogSessionLabel.label(Date()),
            className: found.className)
        core.directoryForTemp = TestLogPaths.temporaryDirectory(base: TemporaryDirectory.url, scenarioID: scenarioID)
        defer { if let temp = core.directoryForTemp { try? FileManager.default.removeItem(at: temp) } }

        // フックは専用スレッドで同期実行する(シナリオ本体と同じ。協調スレッドプールを塞がない)
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let thread = Thread {
                body()
                continuation.resume()
            }
            thread.name = "fleetest-dsl"
            thread.stackSize = 4 << 20
            FTRuntime.bootstrap(core: core, dslThread: thread)
            thread.start()
        }
        FTRuntime.tearDown()

        let record = core.finalRecord
        let passed = record.passed && !core.stoppedByUser
        let reportURL = try? ScenarioReportWriter.write(
            record: record, to: URL(fileURLWithPath: reportDir), notices: [], notApplicableReason: nil)
        var finished = ScenarioEvent(kind: "scenarioFinished")
        finished.scenario = scenarioID
        finished.passed = passed
        finished.reportPath = reportURL?.path
        emit(finished)
        if !passed { throw ExitCode(1) }
    }
}
