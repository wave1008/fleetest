// `ScenarioHost.run` の idle 打ち切り: 無出力が 2 × commandTimeout(+ 開いている除外窓)を超えたら子を止めて
// timedOut の赤にする。出力を続ける子は全体の長さに関わらず止めない。scenarioTimeout の行には打ち切り時点の無出力の長さが付く。
// 偽ランナーの置き方は ScenarioHostDeadlineExclusionTests と同じ(FT_PACKAGE_ROOT)。

import XCTest
@testable import FTCore

private let testFMSettings = FMSettingsRecord(
    heal: false, fmTextVisibilityCheck: false, screenLooksLike: true, ocrTextVisibilityCheck: true)

final class ScenarioHostIdleWatchTests: XCTestCase {

    private var savedPackageRoot: String?
    private var root: URL!

    override func setUpWithError() throws {
        savedPackageRoot = ProcessInfo.processInfo.environment["FT_PACKAGE_ROOT"]
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ft-idle-watch-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try "// swift-tools-version: 6.0".write(
            to: root.appendingPathComponent("Package.swift"), atomically: true, encoding: .utf8)
    }

    override func tearDownWithError() throws {
        if let savedPackageRoot { setenv("FT_PACKAGE_ROOT", savedPackageRoot, 1) } else { unsetenv("FT_PACKAGE_ROOT") }
        try? FileManager.default.removeItem(at: root)
    }

    private final class EventSink: @unchecked Sendable {
        private let lock = NSLock()
        private var _events: [(at: ContinuousClock.Instant, event: ScenarioEvent)] = []
        func append(_ event: ScenarioEvent) { lock.lock(); _events.append((ContinuousClock.now, event)); lock.unlock() }
        var events: [ScenarioEvent] { lock.lock(); defer { lock.unlock() }; return _events.map(\.event) }
        var timed: [(at: ContinuousClock.Instant, event: ScenarioEvent)] { lock.lock(); defer { lock.unlock() }; return _events }
    }

    /// 経過の内訳(開始からの秒)。時間の表明が落ちたとき、どの区間で延びたかを文言から読めるようにする
    private static func timeline(start: ContinuousClock.Instant, sink: EventSink,
                                 marks: [(String, ContinuousClock.Instant)]) -> String {
        func offset(_ t: ContinuousClock.Instant) -> String { String(format: "%.2fs", DurationConversion.seconds(t - start)) }
        let events = sink.timed.map { "\(offset($0.at)) \($0.event.kind): \(($0.event.message ?? "").prefix(80))" }
        return (events + marks.map { "\(offset($0.1)) \($0.0)" }).joined(separator: " | ")
    }

    private func runOnce(name: String, script: String, scenarioTimeout: Int) async throws
        -> (passed: Bool, record: ScenarioRunRecord?, logs: [String], timeline: String,
            returned: ContinuousClock.Instant, firstArrival: (String) -> ContinuousClock.Instant?) {
        let start = ContinuousClock.now
        let project = TestProject(name: name, rootURL: root.appendingPathComponent("TestProjects/\(name)"))
        let path = root.appendingPathComponent(".build/debug").appendingPathComponent(project.productName)
        try FileManager.default.createDirectory(
            at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "#!/bin/sh\n\(script)\n".write(to: path, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: path.path)
        setenv("FT_PACKAGE_ROOT", root.path, 1)

        let recorder = RunRecorder.begin(project: project, profile: nil, trigger: "test",
                                         captureHostMetrics: false)
        let sink = EventSink()
        var tunables = RunTunables()
        tunables.commandTimeout = 1  // idle budget = 2s(子の起動の揺れ = 負荷時の bash 起動より十分大きく取る)
        let passed = await ScenarioHost.run(
            project: project, scenarioID: "Login.S0010",
            connection: DriverConnection(platform: "ios"),
            deviceSession: RunDeviceSession(),
            classHasBeforeAll: false,
            scenarioTimeoutOverride: nil,
            settings: ScenarioExecutionSettings(fm: FMConfig(enabled: false), tunables: tunables,
                                                scenarioTimeout: scenarioTimeout),
            reportDir: root.appendingPathComponent("reports").path,
            recording: ScenarioRecording(recorder: recorder)) { sink.append($0) }
        let returned = ContinuousClock.now
        recorder.finish(total: 1, passed: passed ? 1 : 0, failed: passed ? 0 : 1,
                        performanceMode: false, fmSettings: testFMSettings, setOverrides: nil, servicesWarnings: [], responseMeasurement: nil)
        return (passed, RunResultsStore.records(runDir: recorder.runDir).first,
                sink.events.compactMap(\.message),
                Self.timeline(start: start, sink: sink, marks: [("ScenarioHost.run returned", returned),
                                                                ("recorder finished", ContinuousClock.now)]),
                returned, { message in sink.timed.first { $0.event.message == message }?.at })
    }

    func testSilentChildIsKilledWhenOutputStops() async throws {
        let result = try await runOnce(name: "IdleSilent", script: """
            echo '{"kind":"log","message":"hello"}'
            sleep 8
            echo '{"kind":"scenarioFinished","passed":true}'
            """, scenarioTimeout: 60)
        XCTAssertFalse(result.passed)
        XCTAssertEqual(result.record?.timedOut, true)
        let line = result.logs.first { $0.contains("was killed") }
        XCTAssertTrue(line?.hasPrefix("⏱ The scenario produced no output for ") == true, "\(result.logs)")
        XCTAssertTrue(line?.contains("(allowed 2.0s = 2 × commandTimeout + open waits 0.0s)") == true, "\(line ?? "")")
        // 予算 2 秒 + 猶予で止まる(8 秒の sleep を待ち切っていない)。**子の最初の出力から測る** —— 開始から測ると
        // RunRecorder.begin の ToolchainFingerprint(xcodebuild -version。負荷の下で十数秒)まで数えて誤った赤になる。
        // 6 秒 = 予算 2 + SIGTERM を無視されたときの猶予 Shell.killGraceSeconds 2 + 余裕 2(打ち切らなければ sleep の 8 秒)
        let hello = try XCTUnwrap(result.firstArrival("hello"), result.timeline)
        XCTAssertLessThan(result.returned - hello, .seconds(6), result.timeline)
    }

    /// 遅いだけで出力を続ける子は、予算(2 秒)より長く走っても止めない
    func testChattyChildRunningLongerThanTheBudgetIsNotKilled() async throws {
        let result = try await runOnce(name: "IdleChatty", script: """
            i=0
            while [ $i -lt 20 ]; do echo '{"kind":"log","message":"tick"}'; sleep 0.2; i=$((i+1)); done
            echo '{"kind":"scenarioFinished","passed":true}'
            """, scenarioTimeout: 60)
        XCTAssertTrue(result.passed, "\(result.logs)")
        XCTAssertNotEqual(result.record?.timedOut, true)
    }

    /// 除外窓(began の上限 4 秒)の間は無出力を予算 + 上限まで許す
    func testOpenExclusionWindowAllowsLongerSilence() async throws {
        let result = try await runOnce(name: "IdleExcluded", script: """
            echo '{"kind":"deadlineExclusion","status":"began","durationMs":4000}'
            sleep 4
            echo '{"kind":"deadlineExclusion","status":"ended","durationMs":4000}'
            echo '{"kind":"scenarioFinished","passed":true}'
            """, scenarioTimeout: 60)
        XCTAssertTrue(result.passed, "\(result.logs)")
        XCTAssertNotEqual(result.record?.timedOut, true)
    }

    /// 子が申告した待ち(idleAllowance の上限 4 秒)の間は無出力を予算 + 上限まで許す
    func testDeclaredWaitAllowsLongerSilence() async throws {
        let result = try await runOnce(name: "IdleDeclared", script: """
            echo '{"kind":"idleAllowance","status":"began","durationMs":4000}'
            sleep 4
            echo '{"kind":"idleAllowance","status":"ended"}'
            echo '{"kind":"scenarioFinished","passed":true}'
            """, scenarioTimeout: 60)
        XCTAssertTrue(result.passed, "\(result.logs)")
        XCTAssertNotEqual(result.record?.timedOut, true)
        XCTAssertFalse(result.logs.contains { $0.contains("idleAllowance") }, "the event must not reach emit")
    }

    func testTimeoutLineCarriesSilenceAtKill() async throws {
        let result = try await runOnce(name: "IdleKilled", script: """
            echo '{"kind":"log","message":"hello"}'
            sleep 5
            """, scenarioTimeout: 1)
        XCTAssertFalse(result.passed)
        XCTAssertEqual(result.record?.timedOut, true)
        let line = result.logs.first { $0.contains("was killed") }
        XCTAssertTrue(line?.hasPrefix("⏱ The scenario exceeded 1s (run profile scenarioTimeout) and was killed") == true,
                      "\(line ?? "")")
        XCTAssertTrue(line?.hasSuffix("s before)") == true, "\(line ?? "")")
    }

    func testUnreadPipeBytesAreSeen() throws {
        let pipe = Pipe()
        XCTAssertFalse(ScenarioHost.hasUnreadOutput(pipe.fileHandleForReading))
        pipe.fileHandleForWriting.write(Data("x\n".utf8))
        XCTAssertTrue(ScenarioHost.hasUnreadOutput(pipe.fileHandleForReading))
    }
}
