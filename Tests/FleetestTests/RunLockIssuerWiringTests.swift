// マシンをまたぐ run の発行元のロックのサーバー(RR-8.5 第2a段 step 2)の配線。
// 破ると: 発行元がサーバーを起こさず子が「呼んだら失敗」のまま / リモートの子へソケットのパスを渡して存在しないパスへつなぎに行く /
// 発行元が終わってもソケットのファイルが残る / 中断で待っている要求が失敗にならない。

import XCTest
import FTCore
@testable import fleetest

final class RunLockIssuerWiringTests: XCTestCase {
    private func source(_ path: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return try String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)
    }

    func testLockSocketIsPassedToLocalChildrenOnly() {
        func run(host: String) -> [String] {
            DeviceMachineRunner.childArgs(
                project: "E2E", host: host, profile: "p", deviceNames: ["d"], deviceMachine: host,
                scenarios: ["A.S0010"], folders: [], noLPT: false, lptHistoryRuns: nil, performanceMode: false,
                forceLock: false, remoteDir: nil, remoteTimeout: nil, quiet: true, junitPath: nil,
                runMemoLink: true, lockSocket: "/tmp/ftlock-x.sock")
        }
        let local = run(host: DeviceMachineGrouping.localDisplayName)
        let index = local.firstIndex(of: "--lock-socket")
        XCTAssertNotNil(index)
        XCTAssertEqual(index.map { local[$0 + 1] }, "/tmp/ftlock-x.sock")
        XCTAssertFalse(run(host: "M1Ultra").contains("--lock-socket"), "ssh 越しのリモートの子へは渡さない")
        // マシン別サブ実行は1つの run の子 = `--fleet` のエントリではない(付けると子がロックを断る。デバイスの陽性対照で踏んだ)
        for host in [DeviceMachineGrouping.localDisplayName, "M1Ultra"] {
            XCTAssertFalse(run(host: host).contains("--fleet-entry"), "host=\(host)")
        }
        XCTAssertTrue(FleetRunner.buildArgs(
            project: "E2E", host: "local", profile: "p", fleetEntry: true, scenarios: [], folders: [],
            noLPT: false, lptHistoryRuns: nil, performanceMode: false, forceLock: false, remoteDir: nil,
            remoteTimeout: nil, quiet: true, junitPath: nil).contains("--fleet-entry"))
    }

    func testApiFanoutPassesLockSocketToLocalChildrenOnly() {
        func args(machine: String?) -> [String] {
            ApiRunMachineFanout.buildArgs(
                project: "E2E", profileName: "p",
                group: DeviceMachineRunner.Group(machine: machine, deviceNames: ["d"], platforms: ["android"]),
                scenarioIDs: ["A.S0010"],
                options: ApiRunMachineFanout.Options(
                    defaultTimeout: nil, scenarioTimeout: nil, noLPT: false, lptHistoryRuns: nil,
                    performanceMode: false, remoteDir: nil, remoteTimeout: nil, waitLock: nil),
                runGroup: "g", runMemoLink: true, lockSocket: "/tmp/ftlock-x.sock")
        }
        XCTAssertTrue(args(machine: nil).contains("--lock-socket"))
        XCTAssertFalse(args(machine: "M1Ultra").contains("--lock-socket"))
    }

    func testLockSocketIsNeverRelayedToRemoteRuns() throws {
        XCTAssertFalse(try source("Sources/FTRemote/RemoteDispatch.swift").contains("lock-socket"))
        XCTAssertFalse(try source("Sources/fleetest/RemoteRunDispatcher.swift").contains("lockSocket"))
    }

    func testBothRunEntriesMarkTheIssuerSocketAfterTheStdinClaim() throws {
        for file in ["Sources/fleetest/Fleetest.swift", "Sources/fleetest/ApiRunCommand.swift"] {
            let text = try source(file)
            XCTAssertTrue(text.contains("if let path = common.lockSocket { RunLockHost.markIssuerSocket(path) }"), file)
        }
    }

    /// 発行元の3経路: サーバーを起こして(ソースがロックを使うときだけ)・子が終わるまで持って止め・中断を伝え・ローカルの子へだけパスを渡す
    func testEveryIssuerStartsStopsAndInterruptsTheServerAndPassesTheSocketToLocalChildren() throws {
        let device = try source("Sources/fleetest/DeviceMachineRunner.swift")
        let api = try source("Sources/fleetest/ApiRunMachineFanout.swift")
        let multi = try source("Sources/fleetest/MultiTargetRunner.swift")
        for (name, text) in [("DeviceMachineRunner", device), ("ApiRunMachineFanout", api), ("MultiTargetRunner", multi)] {
            XCTAssertTrue(text.contains("RunLockIssuerSetup.start("), "\(name): サーバーを起こしていない")
            XCTAssertTrue(text.contains("InterruptRelay.observing(catchUp: true) { issuer.interrupt() }"), "\(name): 中断を伝えていない")
            XCTAssertTrue(text.contains("lockSocket: lockIssuer"), "\(name): 子へソケットを渡していない")
        }
        XCTAssertTrue(device.contains("defer { lockIssuer?.stop() }") && api.contains("defer { lockIssuer?.stop() }"))
        XCTAssertTrue(multi.contains("defer { lockIssuersByProject.values.forEach { $0.stop() } }"))
        // 複数対象はプロジェクトごとに1つ(同じプロジェクトの対象は同じ hub・同じサーバー)
        XCTAssertTrue(multi.contains("lockIssuersByProject[unit.project.name]?.socketPath"))
        XCTAssertTrue(multi.contains("for unit in units where lockIssuers[unit.project.name] == nil"))
        // 待ちの上限は配るシナリオの @Test の値を含めて求める
        XCTAssertTrue(device.contains("listedScenarioTimeouts.value = selected.map(\\.scenarioTimeout)"))
        XCTAssertTrue(api.contains("listedScenarioTimeouts.value = selected.map(\\.scenarioTimeout)"))
        XCTAssertTrue(multi.contains("scenarioTimeouts: sameProject.flatMap { $0.infos.map(\\.scenarioTimeout) }"))
    }

    func testWaitCapUsesTheLongestEffectiveTimeoutIncludingTestOverridesAndTheExplicitFlag() {
        let project = TestProject(name: "NoSuchProject", rootURL: URL(fileURLWithPath: "/nonexistent-\(UUID().uuidString)"))
        XCTAssertEqual(RunLockIssuerSetup.waitCapSeconds(
            project: project, profiles: ["p"], setOverrides: [:], explicitScenarioTimeout: 300, scenarioTimeouts: [nil, 1200, 60]), 1200)
        XCTAssertEqual(RunLockIssuerSetup.waitCapSeconds(
            project: project, profiles: ["p"], setOverrides: [:], explicitScenarioTimeout: 300, scenarioTimeouts: [nil]), 300)
        XCTAssertEqual(RunLockIssuerSetup.waitCapSeconds(
            project: project, profiles: ["p"], setOverrides: [:], scenarioTimeouts: []), ScenarioHost.defaultScenarioTimeout,
                       "プロファイルを読めなければ既定")
    }
}
