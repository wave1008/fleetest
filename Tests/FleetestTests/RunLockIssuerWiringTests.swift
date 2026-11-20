// マシンをまたぐ run の発行元のロックのサーバー(RR-8.5 第2a段 step 2)の配線。
// 破ると: 発行元がサーバーを起こさず子が「呼んだら失敗」のまま / リモートの子へソケットのパスを渡して存在しないパスへつなぎに行く /
// 発行元が終わってもソケットのファイルが残る / 中断で待っている要求が失敗にならない。

import XCTest
import FTCore
import FTRemote
@testable import fleetest

final class RunLockIssuerWiringTests: XCTestCase {
    private func source(_ path: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return try String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)
    }

    func testLocalChildrenGetTheLocalSocketAndRemoteChildrenTheMachineSocketAndTheControlSocket() {
        func run(host: String, lock: String?, control: String?) -> [String] {
            DeviceMachineRunner.childArgs(
                project: "E2E", host: host, profile: "p", deviceNames: ["d"], deviceMachine: host,
                scenarios: ["A.S0010"], folders: [], noLPT: false, lptHistoryRuns: nil, performanceMode: false,
                forceLock: false, remoteDir: nil, remoteTimeout: nil, quiet: true, junitPath: nil,
                runMemoLink: true, lockSocket: lock, lockControlSocket: control)
        }
        let local = run(host: DeviceMachineGrouping.localDisplayName, lock: "/tmp/ftlock-local.sock", control: nil)
        XCTAssertEqual(local.firstIndex(of: "--lock-socket").map { local[$0 + 1] }, "/tmp/ftlock-local.sock")
        XCTAssertFalse(local.contains("--lock-control-socket"), "手元の子は直接つなぐので制御用は要らない")
        let remote = run(host: "M1Ultra", lock: "/tmp/ftlock-m1.sock", control: "/tmp/ftlock-local.sock")
        XCTAssertEqual(remote.firstIndex(of: "--lock-socket").map { remote[$0 + 1] }, "/tmp/ftlock-m1.sock",
                       "リモートの子(中継役)には**その機械の待ち受け**を渡す")
        XCTAssertEqual(remote.firstIndex(of: "--lock-control-socket").map { remote[$0 + 1] }, "/tmp/ftlock-local.sock")
        XCTAssertFalse(run(host: "M1Ultra", lock: nil, control: nil).contains("--lock-socket"), "待ち受けが無ければ渡さない")
        XCTAssertFalse(run(host: "M1Ultra", lock: "/tmp/x.sock", control: nil).contains("--lock-socket"),
                       "制御用が無いリモートの子へは片方だけ渡さない")
    }

    func testApiFanoutPassesTheSocketsTheSameWay() {
        func args(machine: String?, lock: String?, control: String?) -> [String] {
            ApiRunMachineFanout.buildArgs(
                project: "E2E", profileName: "p",
                group: DeviceMachineRunner.Group(machine: machine, deviceNames: ["d"], platforms: ["android"]),
                scenarioIDs: ["A.S0010"],
                options: ApiRunMachineFanout.Options(
                    defaultTimeout: nil, scenarioTimeout: nil, noLPT: false, lptHistoryRuns: nil,
                    performanceMode: false, remoteDir: nil, remoteTimeout: nil, waitLock: nil),
                runGroup: "g", runMemoLink: true, lockSocket: lock, lockControlSocket: control)
        }
        XCTAssertTrue(args(machine: nil, lock: "/tmp/a.sock", control: nil).contains("--lock-socket"))
        let remote = args(machine: "M1Ultra", lock: "/tmp/m.sock", control: "/tmp/a.sock")
        XCTAssertEqual(remote.firstIndex(of: "--lock-socket").map { remote[$0 + 1] }, "/tmp/m.sock")
        XCTAssertTrue(remote.contains("--lock-control-socket"))
        XCTAssertFalse(args(machine: "M1Ultra", lock: nil, control: nil).contains("--lock-socket"))
    }

    func testEachRemoteChildLaunchOpensItsOwnListenerAndClosingItLeavesTheOthers() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("lockchild-\(UUID().uuidString)")
        let project = TestProject(name: "P", rootURL: root)
        try FileManager.default.createDirectory(at: project.scenariosDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try "withExclusiveLock(\"a\") {}".write(to: project.scenariosDir.appendingPathComponent("S.swift"), atomically: true, encoding: .utf8)
        let hub = RunMemoHub(mode: .startOnHello, send: { _, _ in })
        let issuer = try XCTUnwrap(RunLockIssuer.startIfUsed(project: project, waitCapSeconds: 5, hub: hub, log: { _ in }))
        defer { issuer.stop() }
        let local = try XCTUnwrap(issuer.openChildSockets(machineLabel: DeviceMachineGrouping.localDisplayName))
        XCTAssertEqual(local.lockSocket, issuer.socketPath)
        XCTAssertNil(local.control)
        // 同じ機械へ続けて起こす別のディスパッチ(MultiTarget の別の対象)は別の待ち受け
        let first = try XCTUnwrap(issuer.openChildSockets(machineLabel: "M1Ultra"))
        let second = try XCTUnwrap(issuer.openChildSockets(machineLabel: "M1Ultra"))
        XCTAssertNotEqual(first.lockSocket, second.lockSocket, "ディスパッチごとに別の待ち受け(出どころ・持ち主不明の範囲を分ける)")
        XCTAssertNotEqual(first.lockSocket, issuer.socketPath, "リモートは手元の待ち受けと別(出どころの区別)")
        XCTAssertEqual(first.control, issuer.socketPath)
        issuer.closeChildSockets(first)
        XCTAssertFalse(FileManager.default.fileExists(atPath: first.lockSocket))
        XCTAssertTrue(FileManager.default.fileExists(atPath: second.lockSocket))
        issuer.closeChildSockets(local)
        XCTAssertTrue(FileManager.default.fileExists(atPath: issuer.socketPath), "手元の待ち受けは閉じない")
    }

    func testTheRelayForwardsOnlyWhenBothSocketsAreGivenAndNeverRequiresTheForwardToSucceed() {
        XCTAssertNil(RemoteLockLink.make(machineSocket: nil, controlSocket: "/tmp/c.sock"))
        XCTAssertNil(RemoteLockLink.make(machineSocket: "/tmp/m.sock", controlSocket: nil))
        XCTAssertNil(RemoteLockLink.make(machineSocket: "/tmp/a:b.sock", controlSocket: "/tmp/c.sock"), "`-R` の書式は ':' で分かれる")
        let link = RemoteLockLink.make(machineSocket: "/tmp/m.sock", controlSocket: "/tmp/c.sock", remotePath: "/tmp/ftlock-abcd1234.sock")
        XCTAssertEqual(link?.sshArgs, ["-o", "ExitOnForwardFailure=no", "-R", "/tmp/ftlock-abcd1234.sock:/tmp/m.sock"])
        XCTAssertFalse((link?.sshArgs ?? []).joined(separator: " ").contains("ExitOnForwardFailure=yes"), "転送の失敗で run を落とさない(利用者の ssh_config の yes に負けないよう no を明示)")
        XCTAssertFalse((link?.sshArgs ?? []).contains("StreamLocalBindUnlink=yes"), "クライアント側の指定は -R に効かない(向こうの sshd の設定)")
        for _ in 0..<20 {
            let path = RemoteLockLink.randomRemotePath()
            XCTAssertFalse(path.contains(":"))
            XCTAssertTrue(path.hasPrefix("/tmp/ftlock-") && path.hasSuffix(".sock"))
            XCTAssertLessThan(path.utf8.count, 104)
        }
        XCTAssertNotEqual(RemoteLockLink.randomRemotePath(), RemoteLockLink.randomRemotePath(), "ディスパッチごとに一意")
    }

    func testTheRemoteRunReceivesTheForwardedPathAsLockSocketOnlyWhenForwarded() {
        let with = RemoteRunArgs.build(
            project: "E2E", profile: "p", scenarios: [], folders: [], noLPT: false, lptHistoryRuns: nil,
            performanceMode: false, runMemoLink: true, lockSocket: "/tmp/ftlock-abcd1234.sock",
            remoteJUnitPath: nil, reportDir: nil)
        XCTAssertEqual(with.firstIndex(of: "--lock-socket").map { with[$0 + 1] }, "/tmp/ftlock-abcd1234.sock")
        let without = RemoteRunArgs.build(
            project: "E2E", profile: "p", scenarios: [], folders: [], noLPT: false, lptHistoryRuns: nil,
            performanceMode: false, runMemoLink: true, remoteJUnitPath: nil, reportDir: nil)
        XCTAssertFalse(without.contains("--lock-socket"))
        let api = RemoteRunArgs.buildApi(
            project: "E2E", profile: "p", scenarios: [], noLPT: false, lptHistoryRuns: nil, performanceMode: false,
            defaultTimeout: nil, scenarioTimeout: nil, runMemoLink: true, lockSocket: "/tmp/ftlock-abcd1234.sock", reportDir: nil)
        XCTAssertTrue(api.contains("--lock-socket"))
    }

    func testBothRelayPathsBuildTheForwardAndRecheckRightAfterSshEndsBeforeTheRunEndWaitAndStopOnInterrupt() throws {
        let relay = try source("Sources/fleetest/RemoteRunDispatcher.swift")
        XCTAssertEqual(relay.components(separatedBy: "RemoteLockLink.make(machineSocket: lockSocket, controlSocket: lockControlSocket)").count - 1, 2,
                       "dispatch と dispatchApi の両方")
        XCTAssertEqual(relay.components(separatedBy: "lockSocket: lockLink?.remotePath").count - 1, 2)
        XCTAssertTrue(relay.contains("sshRunBase + (lockLink?.sshArgs ?? [])"))
        XCTAssertTrue(relay.contains("rm -f \\(RemoteShell.quote(link.remotePath))"), "向こうのソケットのファイルを best effort で消す")
        // 順序: 各経路で、ssh の終わり(通常の戻りと打ち切りの throw の両方)の直後に確かめ直し、その後に run の終わりの待ち(`awaitRemoteRunEnd`)・回収
        for entry in ["let exitCode: Int32\n        do {", ] {
            var from = relay.startIndex
            var paths = 0
            while let start = relay.range(of: entry, range: from..<relay.endIndex) {
                paths += 1
                let tail = relay[start.upperBound...]
                let normal = try XCTUnwrap(tail.range(of: "finishLockLink(lockLink, reportDir: remoteReportDir, exitCode: exitCode, interruptFlag: interruptFlag)"))
                let thrown = try XCTUnwrap(tail.range(of: "finishLockLink(lockLink, reportDir: remoteReportDir, exitCode: nil, interruptFlag: interruptFlag)"))
                let waitRange = try XCTUnwrap(tail.range(of: "awaitRemoteRunEnd("))
                XCTAssertLessThan(normal.lowerBound, waitRange.lowerBound, "通常の終わりの確かめ直しは run の終わりの待ちより前")
                XCTAssertLessThan(thrown.lowerBound, waitRange.lowerBound, "打ち切りの確かめ直しも run の終わりの待ちより前")
                from = start.upperBound
            }
            XCTAssertEqual(paths, 2, "dispatch と dispatchApi の両方")
        }
        // 中断を渡して確かめ直しを止める・細かく眠って中断に気付く
        XCTAssertTrue(relay.contains("interrupted: { interruptFlag.interrupted }"))
        XCTAssertTrue(relay.contains("while remaining > 0, !interruptFlag.interrupted"))
        for file in ["Sources/fleetest/Fleetest.swift", "Sources/fleetest/ApiRunCommand.swift"] {
            XCTAssertTrue(try source(file).contains("lockSocket: common.lockSocket, lockControlSocket: common.lockControlSocket"), file)
        }
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
            XCTAssertTrue(text.contains("lockSocket: lockSockets?.lockSocket, lockControlSocket: lockSockets?.control"), "\(name): 子へソケットを渡していない")
            XCTAssertTrue(text.contains("openChildSockets(machineLabel: group.machineLabel)"), "\(name): ディスパッチごとの待ち受けを開いていない")
            XCTAssertTrue(text.contains("closeChildSockets(lockSockets)"), "\(name): 子が終わった後に待ち受けを閉じていない")
        }
        XCTAssertTrue(device.contains("defer { lockIssuer?.stop() }") && api.contains("defer { lockIssuer?.stop() }"))
        XCTAssertTrue(multi.contains("defer { lockIssuersByProject.values.forEach { $0.stop() } }"))
        // 複数対象はプロジェクトごとに1つ(同じプロジェクトの対象は同じ hub・同じサーバー)
        XCTAssertTrue(multi.contains("lockIssuersByProject[unit.project.name]"))
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

    // MARK: 中継役の期限の延長(ロックの待ち)

    private final class WaitedControl: RunLockRelayControl, @unchecked Sendable {
        var waited: [Int?]
        private(set) var asked = 0
        init(_ waited: [Int?]) { self.waited = waited }
        func sshEnded(listener: String) -> (count: Int, capSeconds: Int)? { nil }
        func remoteRunEnded(listener: String) -> Bool { false }
        func waitedMs(listener: String) -> Int? { asked += 1; return waited.isEmpty ? nil : waited.removeFirst() }
        func issuerClosed() -> Bool { false }
    }

    func testTheExtenderExtendsByTheDifferenceSinceTheLastCheckAndNeverBeyondTheCap() {
        let control = WaitedControl([4_000, 9_000, 9_000, 500_000])
        let extender = RemoteLockWaitExtender(listener: "L", capMs: 20_000, connect: { control })
        XCTAssertEqual(extender.additionalMs(), 4_000)
        XCTAssertEqual(extender.additionalMs(), 5_000, "前回との差")
        XCTAssertEqual(extender.additionalMs(), 0, "増えていなければ延ばさない")
        XCTAssertEqual(extender.additionalMs(), 11_000, "合計は元の期限(上限)まで: 20_000 - 9_000")
    }

    func testTheExtenderNeverExtendsWithoutAConnectionAndStaysGone() {
        var connects = 0
        let none = RemoteLockWaitExtender(listener: "L", capMs: 20_000, connect: { connects += 1; return nil })
        XCTAssertEqual(none.additionalMs(), 0)
        XCTAssertEqual(none.additionalMs(), 0)
        XCTAssertEqual(connects, 1, "つなげなかったら以後つなぎ直さない")
        // 途中で接続が切れた(答えが nil)
        let control = WaitedControl([3_000, nil, 9_000])
        let dropped = RemoteLockWaitExtender(listener: "L", capMs: 20_000, connect: { control })
        XCTAssertEqual(dropped.additionalMs(), 3_000)
        XCTAssertEqual(dropped.additionalMs(), 0)
        XCTAssertEqual(dropped.additionalMs(), 0, "切れた後は延ばさない")
        XCTAssertEqual(control.asked, 2)
    }

    /// 偽の世界: 時計はこの値だけ進む・`waitExit` は期限まで時計を進めて「まだ終わっていない」を返す(上限回数を超えたら終わった扱いで暴走を止める)
    private final class FakeWorld {
        var nowNs: UInt64 = 1_000_000_000_000
        var waitCalls = 0
        var logs: [String] = []
        func now() -> DispatchTime { DispatchTime(uptimeNanoseconds: nowNs) }
        func waitExit(_ deadline: DispatchTime) -> DispatchTimeoutResult {
            waitCalls += 1
            if waitCalls > 10_000 { return .success }
            nowNs = max(nowNs, deadline.uptimeNanoseconds)
            return .timedOut
        }
    }

    func testNothingWaitedMeansTheDeadlineFiresOnce() {
        let world = FakeWorld()
        var queries = 0
        let result = RemoteDeadlineWait.run(
            initialDeadline: world.now() + .seconds(60), waitExit: world.waitExit, capMs: 60_000,
            extension: { queries += 1; return 0 }, now: world.now, log: { world.logs.append($0) })
        XCTAssertTrue(result.timedOut)
        XCTAssertEqual(world.waitCalls, 1, "延ばす材料が無ければ1回で打ち切る(`guard extra > 0` を外すと無限に続く)")
        XCTAssertEqual(queries, 1)
        XCTAssertEqual(result.extendedMs, 0)
        XCTAssertTrue(world.logs.isEmpty)
        // 延長の仕組みを持たない(単発の `run --runner`)も同じ
        let plain = FakeWorld()
        XCTAssertTrue(RemoteDeadlineWait.run(initialDeadline: plain.now() + .seconds(60), waitExit: plain.waitExit,
                                             capMs: 60_000, extension: nil, now: plain.now, log: { _ in }).timedOut)
        XCTAssertEqual(plain.waitCalls, 1)
    }

    /// 待ちが続く間でも、問い合わせは最小の長さ(5秒)ごとにしか起きず、ログは最初と最後だけ。上限に達したら打ち切る
    func testQueriesAreBoundedWhileWaitingContinuesAndTheLogIsOnlyFirstAndSummary() {
        let world = FakeWorld()
        let start = world.nowNs
        let capMs = 600_000  // 延長の合計の上限(10分)
        let extender = RemoteLockWaitExtender(listener: "L", capMs: capMs, connect: {
            // サーバーの累計 = 開始からの経過(ずっと待ちが続いている)
            final class Growing: RunLockRelayControl {
                let world: FakeWorld, start: UInt64
                init(_ w: FakeWorld, _ s: UInt64) { world = w; start = s }
                func sshEnded(listener: String) -> (count: Int, capSeconds: Int)? { nil }
                func remoteRunEnded(listener: String) -> Bool { false }
                func waitedMs(listener: String) -> Int? { Int((world.nowNs - start) / 1_000_000) }
                func issuerClosed() -> Bool { false }
            }
            return Growing(world, start)
        })
        let result = RemoteDeadlineWait.run(
            initialDeadline: world.now() + .seconds(30), waitExit: world.waitExit, capMs: capMs,
            extension: { extender.additionalMs() }, now: world.now, log: { world.logs.append($0) })
        XCTAssertTrue(result.timedOut, "上限まで延ばしても終わらなければ打ち切る")
        // 問い合わせの数 ≤ 延長の合計の上限 / 最小の長さ + 余裕(数ミリ秒ごとの空回りなら数万回になる)
        XCTAssertLessThan(world.waitCalls, capMs / (RemoteDeadlineWait.minimumStepSeconds * 1000) + 5, "\(world.waitCalls)")
        XCTAssertEqual(world.logs.count, 2, "最初の延長と最後の要約だけ: \(world.logs)")
        XCTAssertTrue(world.logs.last?.contains("extended by") == true)
        // 新しい期限は max(いまの期限, いま) から数える: 時計は期限へ進んでいるので、延長のたびに少なくとも最小の長さ進む
        XCTAssertGreaterThanOrEqual(result.extendedMs, capMs, "上限の分は使い切る")
    }

    /// 待ちが細く続く(累計が経過時間の 2% ずつしか増えない)run でも、延長の合計は上限まで・問い合わせは上限 / 最小の長さ 回以内
    func testASlowlyGrowingWaitCannotExtendBeyondTheCapOrQueryMoreThanCapOverMinimumStep() {
        final class Slow: RunLockRelayControl {
            let world: FakeWorld, start: UInt64
            init(_ w: FakeWorld, _ s: UInt64) { world = w; start = s }
            func sshEnded(listener: String) -> (count: Int, capSeconds: Int)? { nil }
            func remoteRunEnded(listener: String) -> Bool { false }
            func waitedMs(listener: String) -> Int? { Int((world.nowNs - start) / 1_000_000 / 50) }
            func issuerClosed() -> Bool { false }
        }
        let world = FakeWorld()
        let capMs = 100_000
        let control = Slow(world, world.nowNs)
        let extender = RemoteLockWaitExtender(listener: "L", capMs: capMs, connect: { control })
        let result = RemoteDeadlineWait.run(
            initialDeadline: world.now() + .seconds(30), waitExit: world.waitExit, capMs: capMs,
            extension: { extender.additionalMs() }, now: world.now, log: { world.logs.append($0) })
        XCTAssertTrue(result.timedOut)
        XCTAssertLessThanOrEqual(result.extendedMs, capMs, "延長の合計は上限まで(最小の長さによる超過で上限を超えない)")
        XCTAssertLessThanOrEqual(world.waitCalls, capMs / (RemoteDeadlineWait.minimumStepSeconds * 1000) + 2, "\(world.waitCalls)")
        XCTAssertEqual(world.logs.count, 2)
    }

    func testTheDeadlineWaitIsWiredThroughTheSharedHelperAndTheTimeoutMessageNamesTheExtension() throws {
        let relay = try source("Sources/fleetest/RemoteRunDispatcher.swift")
        XCTAssertTrue(relay.contains("RemoteDeadlineWait.run("))
        XCTAssertTrue(relay.contains("extension: lockWaitExtender.map"))
        XCTAssertTrue(relay.contains("RemoteLockWaitExtender(listener: link.machineSocket, capMs: total * 1000"),
                      "延長の合計の上限は元の期限(dispatch と dispatchApi が共有する runRemoteAndRelay)")
        XCTAssertEqual(relay.components(separatedBy: "lockWaitExtender: extender").count - 1, 1)
        XCTAssertTrue(relay.contains("deadlineResult.extendedMs"), "打ち切りの文言に延長した合計を含める")
    }
}
