import XCTest
@testable import FTCore

/// ロック(RR-8.5)の配線。起動の形ごとの受け渡しの値・サンドボックスへの名指し・run の入口の設定・中断・`--fleet` の印
final class RunLockWiringTests: XCTestCase {
    private static var repoRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    }

    private func source(_ path: String) throws -> String {
        try String(contentsOf: Self.repoRoot.appendingPathComponent(path), encoding: .utf8)
    }

    private func access(_ session: RunDeviceSession) async throws -> RunLockAccess {
        guard case .launch(let handoff) = await session.handoff(className: "C", classHasBeforeAll: false) else {
            throw XCTSkip("not launched")
        }
        return handoff.lockAccess
    }

    func testSessionsGiveTheAccessOfTheirKind() async throws {
        // 既定は「呼んだら失敗」(設定を忘れた経路・MCP の個別の呼び出しがその場で渡されて黙って競合しない)
        let unconfiguredDefault = try await access(RunDeviceSession())
        XCTAssertEqual(unconfiguredDefault, .refuse(RunLockHost.notConfiguredRefusal))
        // run の入口が設定する前は「呼んだら失敗」(設定を忘れた経路が黙って割れない)
        let book = RunDeviceSessionBook()
        let unconfigured = try await access(book.session(for: "lane"))
        XCTAssertEqual(unconfigured, .refuse(RunLockHost.notConfiguredRefusal))
        // 設定した run: ソースが使っていればソケット・使っていなければ検出しなかったと断る
        book.shared.locks.configure(usesLocks: true, waitCapSeconds: 99, linkedToParent: false) { _ in }
        let configured = try await access(book.session(for: "lane"))
        guard case .socket = configured else { return XCTFail("socket expected, got \(configured)") }
        XCTAssertEqual(book.session(for: "lane").tearDownHandoff().lockWaitCapSeconds, 99)
        book.shared.locks.stop()
    }

    func testHostOverridesTheAccessForDryRunAndDebugBeforeTheSocketReachesTheSandbox() throws {
        let host = try source("Sources/FTCore/ScenarioHost.swift")
        let dry = try XCTUnwrap(host.range(of: "if dryRun {\n            handoff.lockAccess = .passThrough"))
        XCTAssertTrue(host[dry.upperBound...].prefix(120).contains("else if debug != nil"), "debug は dry-run でない run だけ")
        XCTAssertTrue(host.contains("handoff.lockAccess = .immediate"))
        // 上書きの後で、その値(socket)を枠へ名指しする。逆順だと dry-run の子にソケットが開く
        let override = host.distance(from: host.startIndex, to: dry.lowerBound)
        let sandbox = try XCTUnwrap(host.range(of: "lockSocket: { if case .socket(let path) = handoff.lockAccess"))
        XCTAssertLessThan(override, host.distance(from: host.startIndex, to: sandbox.lowerBound))
    }

    func testAppliedOutsideOpsAreCountedPerTokenAfterTheStoreWrite() async throws {
        let session = RunDeviceSession()
        var write = ScenarioEvent(kind: "runMemoWrite")
        write.memoKey = "k"
        write.memoValue = "v"
        XCTAssertTrue(session.apply(write, className: "C", lockOwnerToken: "tok"))
        XCTAssertTrue(session.apply(ScenarioEvent(kind: "runMemoClear"), className: "C", lockOwnerToken: "tok"))
        XCTAssertTrue(session.shared.locks.appliedOps.wait(token: "tok", atLeast: 2, timeout: .zero))
        XCTAssertFalse(session.shared.locks.appliedOps.wait(token: "tok", atLeast: 3, timeout: .zero))
        XCTAssertFalse(session.shared.locks.appliedOps.wait(token: "other", atLeast: 1, timeout: .zero))
        let host = try source("Sources/FTCore/ScenarioHost.swift")
        XCTAssertTrue(host.contains("lockOwnerToken: handoff.lockOwnerToken) { continue }"))
        XCTAssertTrue(host.contains("deviceSession.shared.locks.unregister(token: handoff.lockOwnerToken)"))
    }

    func testRunsStopTheLockHostAtTheirEndAndMCPSharesOneHost() throws {
        XCTAssertTrue(try source("Sources/FTCore/RunOrchestrator.swift").contains("defer { deviceSessions.shared.locks.stop() }"))
        XCTAssertTrue(try source("Sources/fleetest/ApiRunCommand.swift").contains("defer { deviceSessions.shared.locks.stop() }"))
        XCTAssertTrue(try source("Sources/fleetest/Fleetest.swift").contains("defer { sharedSession.locks.stop() }"))
        let mcp = try source("Sources/fleetest-mcp/MCPServer+ScenarioTools.swift")
        XCTAssertTrue(mcp.contains("RunSharedSession(lockHost: .mcpShared(project: project.name))"))
        XCTAssertTrue(mcp.contains("RunLockHost.mcpShared(project: project.name).configure("))
    }

    func testTheSocketIsNamedToTheSandboxAfterTheHelperSockets() throws {
        let entry = try source("Sources/FTCore/ScenarioHost+Sandbox.swift")
        XCTAssertTrue(entry.contains("if let lockSocket { scope.helperSockets.append(lockSocket) }"))
        let host = try source("Sources/FTCore/ScenarioHost.swift")
        XCTAssertTrue(host.contains("lockSocket: { if case .socket(let path) = handoff.lockAccess"),
                      "run の子の起動が handoff の socket を入口へ渡している")
    }

    func testRunEntrancesConfigureTheLocksAndTheOrchestratorForwardsInterrupts() throws {
        let orchestrator = try source("Sources/FTCore/RunOrchestrator.swift")
        XCTAssertTrue(orchestrator.contains("deviceSessions.shared.locks.configure(project: project, scenarioTimeouts: items.map(\\.info.scenarioTimeout)"))
        XCTAssertTrue(orchestrator.contains("settingsTimeout: settings.scenarioTimeout)"))
        let interrupt = try XCTUnwrap(orchestrator.range(of: "public func requestInterrupt() {"))
        XCTAssertTrue(orchestrator[interrupt.upperBound...].prefix(300).contains("deviceSessions.shared.locks.interrupt()"))
        let api = try source("Sources/fleetest/ApiRunCommand.swift")
        XCTAssertTrue(api.contains("deviceSessions.shared.locks.configure(project: project, scenarioTimeouts: selected.map(\\.scenarioTimeout)"))
        let run = try source("Sources/fleetest/Fleetest.swift")
        XCTAssertTrue(run.contains("sharedSession.locks.configure(project: project"))
    }

    func testFleetEntriesAreMarkedAndTheMarkIsRelayedToRemoteRuns() throws {
        XCTAssertTrue(try source("Sources/fleetest/FleetRunner.swift").contains("if fleetEntry { args.append(\"--fleet-entry\") }"))
        XCTAssertTrue(try source("Sources/fleetest/RunCommonOptions.swift").contains("customLong(\"fleet-entry\")"))
        let remote = try source("Sources/FTRemote/RemoteDispatch.swift")
        XCTAssertEqual(remote.components(separatedBy: "if fleetEntry { args.append(\"--fleet-entry\") }").count - 1, 2,
                       "run と api run の両方の中継")
        for file in ["Sources/fleetest/ApiRunCommand.swift", "Sources/fleetest/Fleetest.swift"] {
            let text = try source(file)
            XCTAssertTrue(text.contains("if common.fleetEntry { RunLockHost.markFleetEntry() }"), file)
            XCTAssertTrue(text.contains("fleetEntry: common.fleetEntry"), file)
        }
    }

    /// 親が子を**見届けた後**にだけ知らせる。早く知らせると、まだ走っているシナリオの持ち分を外す(誤った緑)
    func testScenarioHostReportsTheScenarioEndOnlyAfterTheChildProcessWasReaped() throws {
        let host = try source("Sources/FTCore/ScenarioHost.swift")
        let launch = try XCTUnwrap(host.range(of: "let processExited = ProcessExitWait.prepare(process)"))
        let wait = try XCTUnwrap(host.range(of: "for await _ in processExited {}", range: launch.upperBound..<host.endIndex))
        let ended = try XCTUnwrap(host.range(of: "deviceSession.shared.locks.noteScenarioEnded(token: handoff.lockOwnerToken)"))
        let unregister = try XCTUnwrap(host.range(of: "deviceSession.shared.locks.unregister(token: handoff.lockOwnerToken)"))
        XCTAssertLessThan(wait.upperBound, ended.lowerBound, "子の終了を待った後(`processExited` の待ちの後)に知らせる")
        // 登録を外すのは関数の終わり(defer)= 知らせた後
        XCTAssertLessThan(unregister.lowerBound, wait.lowerBound)
        XCTAssertTrue(host[host.index(unregister.lowerBound, offsetBy: -200)..<unregister.lowerBound].contains("defer {"))
        XCTAssertEqual(host.components(separatedBy: "noteScenarioEnded(").count - 1, 1, "知らせる場所は1つだけ")
        // 起動より前(= 待ちの前に抜ける経路)に知らせる呼び出しを置かない・defer の中(早い return でも待たずに走る)に置かない
        let beforeWait = host[launch.upperBound..<wait.lowerBound]
        XCTAssertFalse(beforeWait.contains("noteScenarioEnded("))
        let deferStart = try XCTUnwrap(host.range(of: "defer {", range: launch.upperBound..<wait.lowerBound))
        XCTAssertFalse(host[deferStart.upperBound..<wait.lowerBound].prefix(400).contains("noteScenarioEnded("))
    }

    func testHookChildrenGetTheirLocksAtOnce() throws {
        XCTAssertTrue(try source("Sources/FTCore/RunHookHost.swift").contains("lockAccess: .immediate"))
    }

    func testLinkedChildrenRefuse() {
        let host = RunLockHost(mode: .ownServer)
        host.configure(usesLocks: true, waitCapSeconds: 1, linkedToParent: true) { _ in }
        XCTAssertEqual(host.access(), .refuse(RunLockHost.linkedChildRefusal))
    }
}
