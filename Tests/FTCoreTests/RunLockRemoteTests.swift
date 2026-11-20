import XCTest
@testable import FTCore

/// run 全体のロック(RR-8.5)の 2b step 1: 持ち主不明(表)・待ち受けごとの出どころ・シナリオの終わりの知らせ・ssh の終わりの確かめ直し
final class RunLockRemoteTests: XCTestCase {
    private func owner(_ connection: Int, _ id: Int = 1) -> RunLockTable.Owner {
        RunLockTable.Owner(connection: connection, requestID: id)
    }

    // MARK: 表: 持ち主不明

    func testUnknownExclusiveOwnerFailsEveryWaiterAndEveryNewRequestAtOnce() {
        var table = RunLockTable()
        _ = table.acquire(connection: 1, requestID: 1, keys: ["k"], mode: .exclusive)
        _ = table.acquire(connection: 2, requestID: 1, keys: ["k"], mode: .shared)
        _ = table.acquire(connection: 3, requestID: 1, keys: ["k"], mode: .exclusive)
        let effects = table.markUnknown(connection: 1, scope: "S1", machine: "M1")
        XCTAssertEqual(Set(effects.failures.map(\.owner)), [owner(2), owner(3)], "待っていた共有も排他も失敗")
        XCTAssertTrue(effects.failures.allSatisfy { $0.reason.contains("machine M1 lost its connection") }, "\(effects.failures)")
        XCTAssertTrue(table.isGranted(owner(1)), "持ち主不明の持ち分は残る(向こうが走っているかもしれない)")
        for mode in [RunLockTable.Mode.shared, .exclusive] {
            let late = table.acquire(connection: 4, requestID: mode == .shared ? 1 : 2, keys: ["k"], mode: mode)
            XCTAssertEqual(late.failures.count, 1, "新しい要求(\(mode))もすぐ失敗")
            XCTAssertEqual(late.grants, [])
        }
        XCTAssertEqual(table.unknownKeyCount(scope: "S1"), 1)
    }

    func testUnknownSharedOwnerStillGrantsSharedAndFailsExclusiveAtOnce() {
        var table = RunLockTable()
        _ = table.acquire(connection: 1, requestID: 1, keys: ["k"], mode: .shared)
        _ = table.acquire(connection: 2, requestID: 1, keys: ["k"], mode: .exclusive)  // 共有を持つ人が居るので待つ
        let effects = table.markUnknown(connection: 1, scope: "S1", machine: "M1")
        XCTAssertEqual(effects.failures.map(\.owner), [owner(2)], "待っていた排他は失敗")
        XCTAssertEqual(table.acquire(connection: 3, requestID: 1, keys: ["k"], mode: .shared).grants, [owner(3)], "共有は渡す")
        XCTAssertEqual(table.acquire(connection: 4, requestID: 1, keys: ["k"], mode: .exclusive).failures.map(\.owner), [owner(4)],
                       "新しい排他はすぐ失敗")
    }

    func testAnUnknownExclusiveOwnerAlsoFailsAWaitingSharedRequest() {
        var table = RunLockTable()
        _ = table.acquire(connection: 1, requestID: 1, keys: ["k"], mode: .exclusive)
        _ = table.acquire(connection: 2, requestID: 1, keys: ["k"], mode: .shared)
        // 排他の持ち主が不明になると共有の待ちも失敗する(排他の不明は全部断る)
        XCTAssertEqual(table.markUnknown(connection: 1, scope: "S1", machine: "M1").failures.map(\.owner), [owner(2)])
    }

    func testAMultiKeyRequestThatHitsAnUnknownKeyFailsAndReleasesTheKeysItAlreadyHad() {
        var table = RunLockTable()
        _ = table.acquire(connection: 1, requestID: 1, keys: ["b"], mode: .exclusive)
        _ = table.acquire(connection: 2, requestID: 1, keys: ["a", "b"], mode: .exclusive)  // a を取って b を待つ
        XCTAssertEqual(table.holders(of: "a"), [owner(2)])
        let effects = table.markUnknown(connection: 1, scope: "S1", machine: "M1")
        XCTAssertEqual(effects.failures.map(\.owner), [owner(2)])
        XCTAssertEqual(table.holders(of: "a"), [], "取っていた a は放す")
    }

    func testReleaseUnknownFreesTheKeysAndMarksThemForEveryLaterGrant() {
        var table = RunLockTable()
        _ = table.acquire(connection: 1, requestID: 1, keys: ["k"], mode: .exclusive)
        _ = table.markUnknown(connection: 1, scope: "S1", machine: "M1")
        // 別の機械の不明は外さない
        XCTAssertEqual(table.releaseUnknown(scope: "S2").keys, 0)
        XCTAssertTrue(table.isGranted(owner(1)))
        let released = table.releaseUnknown(scope: "S1")
        XCTAssertEqual(released.keys, 1)
        XCTAssertEqual(table.unknownKeyCount(scope: "S1"), 0)
        let next = table.acquire(connection: 2, requestID: 1, keys: ["k"], mode: .exclusive)
        XCTAssertEqual(next.grants, [owner(2)])
        XCTAssertEqual(next.lossMarked[owner(2)], ["k"], "外した後の次の取得は印つき")
        _ = table.release(connection: 2, requestID: 1)
        XCTAssertEqual(table.acquire(connection: 3, requestID: 1, keys: ["k"], mode: .shared).lossMarked[owner(3)], ["k"],
                       "印はその後の取得にも付く(run の終わりまで)")
        XCTAssertNil(table.acquire(connection: 4, requestID: 1, keys: ["other"], mode: .exclusive).lossMarked[owner(4)], "他のキーには付かない")
    }

    func testReleaseUnknownGrantsTheRequestsThatWereWaitingForTheSharedKey() {
        var table = RunLockTable()
        _ = table.acquire(connection: 1, requestID: 1, keys: ["k"], mode: .shared)
        _ = table.markUnknown(connection: 1, scope: "S1", machine: "M1")
        XCTAssertEqual(table.acquire(connection: 2, requestID: 1, keys: ["k"], mode: .shared).grants, [owner(2)])
        _ = table.release(connection: 2, requestID: 1)
        _ = table.releaseUnknown(scope: "S1")
        XCTAssertEqual(table.holders(of: "k"), [])
    }

    func testReleaseAllMarksOnlyWhatWasHeldAndDropsWaiters() {
        var table = RunLockTable()
        _ = table.acquire(connection: 1, requestID: 1, keys: ["held"], mode: .exclusive)
        _ = table.acquire(connection: 9, requestID: 1, keys: ["busy"], mode: .exclusive)
        _ = table.acquire(connection: 1, requestID: 2, keys: ["busy"], mode: .exclusive)  // 待ち
        _ = table.releaseAll(connection: 1)
        XCTAssertEqual(table.holders(of: "held"), [])
        XCTAssertEqual(table.queue(of: "busy"), [], "待ちは消える")
        XCTAssertEqual(table.acquire(connection: 2, requestID: 1, keys: ["held"], mode: .exclusive).lossMarked[owner(2)], ["held"])
        _ = table.release(connection: 9, requestID: 1)
        XCTAssertNil(table.acquire(connection: 3, requestID: 1, keys: ["busy"], mode: .exclusive).lossMarked[owner(3)],
                     "待っていただけのキーには印を付けない")
    }

    func testAConnectionThatClosesAfterBeingMarkedUnknownIsNotReportedHeldAgain() {
        var table = RunLockTable()
        _ = table.acquire(connection: 1, requestID: 1, keys: ["k"], mode: .exclusive)
        _ = table.markUnknown(connection: 1, scope: "S1", machine: "M1")
        XCTAssertEqual(table.connectionClosed(1).held, [], "不明にした持ち分を pid 待ちへ回さない")
    }

    // MARK: サーバー

    private final class Lines: @unchecked Sendable {
        private let lock = NSLock()
        private var items: [String] = []
        func add(_ line: String) { lock.withLock { items.append(line) } }
        var all: [String] { lock.withLock { items } }
    }

    private final class NullMemo: RunLockMemoBackend, @unchecked Sendable {
        func snapshot() -> [String: [String]] { [:] }
        func apply(_ op: RunMemoOp) {}
    }

    private final class PidWaiters: @unchecked Sendable {
        private let lock = NSLock()
        private var pids: [pid_t] = []
        var requested: [pid_t] { lock.withLock { pids } }
        var waiter: RunLockServer.PidExitWaiter {
            { pid, _, _, _ in self.lock.withLock { self.pids.append(pid) } }
        }
    }

    private var servers: [RunLockServer] = []

    override func tearDown() {
        servers.forEach { $0.stop() }
        servers = []
        super.tearDown()
    }

    private func makeServer(waiters: PidWaiters = PidWaiters(), lines: Lines = Lines(), cap: Int = 5) throws -> RunLockServer {
        let server = try RunLockServer(memoFor: { _ in NullMemo() }, waitCapSeconds: { cap }, log: { lines.add($0) },
                                       pidExitWaiter: waiters.waiter)
        servers.append(server)
        return server
    }

    private func connect(_ path: String, _ name: String, token: String = "", claiming machine: String = "m") throws -> RunLockClient {
        try RunLockClient.connect(path: path, scenario: name, machine: machine, device: "d", token: token)
    }

    private func take(_ client: RunLockClient, _ key: String, _ mode: RunLockTable.Mode = .exclusive,
                      timeout: Duration = .seconds(5)) throws -> (id: Int, outcome: RunLockClient.Outcome) {
        let id = try client.request(keys: [key], mode: mode).get()
        return (id, client.wait(id: id, timeout: timeout))
    }

    func testEachDispatchHasItsOwnListenerWithAShortUniquePathAndClosingItKeepsTheServerUp() throws {
        let server = try makeServer()
        let first = try server.openRemoteListener(machine: "M1")
        let second = try server.openRemoteListener(machine: "M1")  // 同じ機械の別のディスパッチ
        let paths = [server.socketPath, first, second]
        XCTAssertEqual(Set(paths).count, 3, "同じ機械でもディスパッチごとに別の待ち受け")
        for path in paths {
            XCTAssertLessThan(path.utf8.count, 104)
            XCTAssertTrue(FileManager.default.fileExists(atPath: path))
        }
        server.closeRemoteListener(path: first)
        XCTAssertFalse(FileManager.default.fileExists(atPath: first))
        XCTAssertTrue(FileManager.default.fileExists(atPath: second), "他の待ち受けは残る")
        XCTAssertThrowsError(try connect(first, "late"), "閉じた待ち受けへはつなげない")
        server.stop()
        for path in paths { XCTAssertFalse(FileManager.default.fileExists(atPath: path), "全部の待ち受けのファイルを消す") }
    }

    func testARemoteListenerCloseGoesToUnknownOwnerWhileALocalCloseWaitsForThePid() throws {
        let waiters = PidWaiters()
        let lines = Lines()
        let server = try makeServer(waiters: waiters, lines: lines)
        let remotePath = try server.openRemoteListener(machine: "M1")
        // リモートの待ち受けで受けた接続は、**自分を local と名乗っても**リモートの出どころ
        var remoteHolder: RunLockClient? = try connect(remotePath, "Remote.scn", claiming: "local")
        XCTAssertEqual(try take(try XCTUnwrap(remoteHolder), "k").outcome, .granted)
        let waiter = try connect(server.socketPath, "Waiter.scn")
        let id = try waiter.request(keys: ["k"], mode: .exclusive).get()
        remoteHolder = nil
        XCTAssertEqual(waiter.wait(id: id, timeout: .seconds(5)),
                       .failed(RunLockTable.unknownOwnerReason(key: "k", machine: "M1")), "待っていた要求がすぐ失敗")
        XCTAssertTrue(waiters.requested.isEmpty, "リモートの出どころは pid の終わりを待たない")
        XCTAssertTrue(lines.all.contains { $0.contains("Remote.scn") && $0.contains("unknown-owner") && $0.contains("M1") }, "\(lines.all)")
        // 手元の待ち受けの接続は pid の終わりを待つ(既存の規則)
        var localHolder: RunLockClient? = try connect(server.socketPath, "Local.scn")
        XCTAssertEqual(try take(try XCTUnwrap(localHolder), "other").outcome, .granted)
        localHolder = nil
        let deadline = Date().addingTimeInterval(5)
        while waiters.requested.isEmpty, Date() < deadline { usleep(10_000) }
        XCTAssertEqual(waiters.requested, [getpid()])
    }

    func testControlMessagesFromARemoteListenerAreIgnored() throws {
        let server = try makeServer()
        let remotePath = try server.openRemoteListener(machine: "M1")
        let holder = try connect(remotePath, "Remote.scn")
        XCTAssertEqual(try take(holder, "k").outcome, .granted)
        // リモートの接続が `sshEnded` / `remoteRunEnded` を名乗っても読まない(中継役は手元のプロセス)
        let liar = try connect(remotePath, "Liar")
        XCTAssertTrue(liar.sendNote(.sshEnded(listener: remotePath)))
        let waiter = try connect(server.socketPath, "Waiter.scn")
        let id = try waiter.request(keys: ["k"], mode: .exclusive).get()
        XCTAssertEqual(waiter.wait(id: id, timeout: .milliseconds(500)), .timedOut, "持ち主は不明にされず、待つだけ")
        // 持ち主不明にしてから(リモートの持ち主が外さずに閉じる)、リモートの接続が `remoteRunEnded` を名乗っても外さない
        // (`remoteRunEnded` は不明のキーしか外さない = 不明のキーが無い状態では読み捨てても受け付けても見分けられない)
        var unknownHolder: RunLockClient? = try connect(remotePath, "Remote2.scn")
        XCTAssertEqual(try take(try XCTUnwrap(unknownHolder), "u").outcome, .granted)
        unknownHolder = nil
        let probe = try connect(server.socketPath, "Probe.scn")
        let firstProbe = try probe.request(keys: ["u"], mode: .exclusive).get()
        XCTAssertEqual(probe.wait(id: firstProbe, timeout: .seconds(5)),
                       .failed(RunLockTable.unknownOwnerReason(key: "u", machine: "M1")), "外さずに閉じたリモートの持ち主は不明")
        XCTAssertTrue(liar.sendNote(.remoteRunEnded(listener: remotePath)))
        usleep(200_000)
        let secondProbe = try probe.request(keys: ["u"], mode: .exclusive).get()
        XCTAssertEqual(probe.wait(id: secondProbe, timeout: .seconds(5)),
                       .failed(RunLockTable.unknownOwnerReason(key: "u", machine: "M1")), "リモートからの remoteRunEnded で外していない")
    }

    /// `scenarioEnded` が先に着いても、持ち分を外すのは**その接続が閉じたとき**(それまでの `release` を処理してから)
    func testScenarioEndedFirstReleasesOnlyWhenTheConnectionClosesAndMarksWhatWasStillHeld() throws {
        let server = try makeServer()
        let remotePath = try server.openRemoteListener(machine: "M1")
        var holder: RunLockClient? = try connect(remotePath, "Remote.scn", token: "T1")
        XCTAssertEqual(try take(try XCTUnwrap(holder), "k").outcome, .granted)
        let waiter = try connect(server.socketPath, "Waiter.scn", token: "T2")
        let id = try waiter.request(keys: ["k"], mode: .exclusive).get()
        server.scenarioEnded(token: "T1")  // 親が見届けた(接続はまだ開いている)
        XCTAssertEqual(waiter.wait(id: id, timeout: .milliseconds(300)), .timedOut, "接続が閉じるまで外さない")
        holder = nil  // 放さずに閉じた
        XCTAssertEqual(waiter.wait(id: id, timeout: .seconds(5)), .granted, "見届け済みの印の接続が閉じたら外す(持ち主不明にしない)")
        XCTAssertEqual(waiter.takeLostKeys(), ["k"], "閉じたとき持っていた分は印つき")
    }

    func testAReleaseThatIsProcessedAfterScenarioEndedDoesNotGetMarked() throws {
        let server = try makeServer()
        let remotePath = try server.openRemoteListener(machine: "M1")
        var holder: RunLockClient? = try connect(remotePath, "Remote.scn", token: "T1")
        let taken = try take(try XCTUnwrap(holder), "k")
        XCTAssertEqual(taken.outcome, .granted)
        server.scenarioEnded(token: "T1")  // 別の接続・別のスレッドの知らせが `release` より先に処理された順
        try XCTUnwrap(holder).release(id: taken.id)
        holder = nil
        let next = try connect(server.socketPath, "Next.scn", token: "T2")
        XCTAssertEqual(try take(next, "k").outcome, .granted)
        XCTAssertEqual(next.takeLostKeys(), [], "正常に放したキーに「前の持ち主が接続を失った」注記を付けない")
    }

    func testALocalConnectionOfAnEndedScenarioIsReleasedAtOnceWithoutWaitingForThePid() throws {
        let waiters = PidWaiters()
        let server = try makeServer(waiters: waiters)
        var holder: RunLockClient? = try connect(server.socketPath, "Local.scn", token: "T1")
        XCTAssertEqual(try take(try XCTUnwrap(holder), "k").outcome, .granted)
        server.scenarioEnded(token: "T1")
        holder = nil
        let next = try connect(server.socketPath, "Next.scn", token: "T2")
        XCTAssertEqual(try take(next, "k", timeout: .seconds(5)).outcome, .granted)
        XCTAssertTrue(waiters.requested.isEmpty, "親が見届けた後は pid の終わりを待たない")
    }

    func testScenarioEndedAfterTheRemoteCloseReleasesTheUnknownOwnerAndMarks() throws {
        let server = try makeServer()
        let remotePath = try server.openRemoteListener(machine: "M1")
        var holder: RunLockClient? = try connect(remotePath, "Remote.scn", token: "T1")
        XCTAssertEqual(try take(try XCTUnwrap(holder), "k").outcome, .granted)
        holder = nil
        let local = try connect(server.socketPath, "Local.scn", token: "T3")
        guard case .failed = try take(local, "k").outcome else { return XCTFail("不明の間は失敗") }
        XCTAssertEqual(server.closedHolderCountForTesting, 1)
        server.scenarioEnded(token: "T1")
        XCTAssertEqual(try take(local, "k").outcome, .granted)
        XCTAssertEqual(local.takeLostKeys(), ["k"])
        XCTAssertEqual(server.closedHolderCountForTesting, 0, "外したら掃除する")
    }

    func testTwoDispatchesToTheSameMachineKeepTheirUnknownKeysApart() throws {
        let server = try makeServer()
        let first = try server.openRemoteListener(machine: "M1")
        let second = try server.openRemoteListener(machine: "M1")
        var holderA: RunLockClient? = try connect(first, "A.scn", token: "A")
        XCTAssertEqual(try take(try XCTUnwrap(holderA), "a").outcome, .granted)
        let control = try RunLockControl.connect(path: server.socketPath)
        XCTAssertEqual(try XCTUnwrap(control.sshEnded(listener: first)).count, 1, "最初のディスパッチの ssh が切れて不明のまま残る")
        holderA = nil
        // 後のディスパッチ(同じ機械)の run が終わったと確かめても、最初のディスパッチの不明は外れない
        var holderB: RunLockClient? = try connect(second, "B.scn", token: "B")
        XCTAssertEqual(try take(try XCTUnwrap(holderB), "b").outcome, .granted)
        holderB = nil
        XCTAssertEqual(try XCTUnwrap(control.sshEnded(listener: second)).count, 1)
        XCTAssertTrue(control.remoteRunEnded(listener: second))
        XCTAssertEqual(try XCTUnwrap(control.sshEnded(listener: first)).count, 1, "最初のディスパッチの不明は残る")
        XCTAssertEqual(try XCTUnwrap(control.sshEnded(listener: second)).count, 0)
        let local = try connect(server.socketPath, "Local.scn")
        guard case .failed = try take(local, "a").outcome else { return XCTFail("a は不明のまま") }
        XCTAssertEqual(try take(local, "b").outcome, .granted, "b は外れた")
        XCTAssertTrue(control.remoteRunEnded(listener: first))
        XCTAssertEqual(try take(local, "a").outcome, .granted)
    }

    /// 発行元のサーバーは run の間ずっと居るので、終わったシナリオの適用数を持ち続けない
    func testTheServerForgetsAScenariosAppliedCountWhenItsEndIsReported() throws {
        let applied = RunLockAppliedOps()
        let server = try RunLockServer(memoFor: { _ in NullMemo() }, applied: applied, log: { _ in })
        servers.append(server)
        let forwarder = try connect(try server.openRemoteListener(machine: "M1"), "forwarder")
        XCTAssertTrue(forwarder.sendOutsideApplied(token: "T1"))
        let deadline = Date().addingTimeInterval(5)
        while applied.count(token: "T1") == 0, Date() < deadline { usleep(10_000) }
        XCTAssertEqual(applied.count(token: "T1"), 1)
        XCTAssertTrue(forwarder.sendNote(.scenarioEnded(token: "T1")))
        while applied.count(token: "T1") != 0, Date() < deadline { usleep(10_000) }
        XCTAssertEqual(applied.count(token: "T1"), 0, "見届けたら数を捨てる")
    }

    func testConnectionCloseDecidesTheOwnerInOneAtomicStep() throws {
        let source = try String(contentsOf: URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Sources/FTCore/RunLockServer.swift"), encoding: .utf8)
        let start = try XCTUnwrap(source.range(of: "private func connectionDidClose(_ conn: Conn) {"))
        let end = try XCTUnwrap(source.range(of: "let releaseHeld", range: start.upperBound..<source.endIndex))
        let body = source[start.upperBound..<end.lowerBound]
        XCTAssertEqual(body.components(separatedBy: "perform {").count - 1, 1,
                       "表から外す・印を残す・持ち主不明にするを別々の `perform` に分けない(間に入った scenarioEnded / sshEnded が失われる)")
        XCTAssertTrue(body.contains("state.table.connectionClosed(conn.id)") && body.contains("markUnknown(") && body.contains("closedHolders[conn.id]"))
    }

    func testScenarioEndedAlsoReleasesAnUnknownOwnerAndDropsTheTokensWaiters() throws {
        let server = try makeServer()
        let remotePath = try server.openRemoteListener(machine: "M1")
        var holder: RunLockClient? = try connect(remotePath, "Remote.scn", token: "T1")
        XCTAssertEqual(try take(try XCTUnwrap(holder), "k").outcome, .granted)
        let other = try connect(remotePath, "Other.scn", token: "T1")  // 同じ印の2つ目の接続: 待っている
        let blocked = try take(other, "j").id
        _ = blocked
        holder = nil
        usleep(300_000)  // 不明になるのを待つ
        let local = try connect(server.socketPath, "Local.scn", token: "T3")
        guard case .failed = try take(local, "k").outcome else { return XCTFail("不明の間は失敗") }
        server.scenarioEnded(token: "T1")
        XCTAssertEqual(try take(local, "k").outcome, .granted, "見届けたら不明が消える")
        XCTAssertEqual(local.takeLostKeys(), ["k"])
    }

    func testSshEndedMarksTheMachinesRemainingHoldersUnknownAndRemoteRunEndedReleasesThem() throws {
        let lines = Lines()
        let server = try makeServer(lines: lines)
        let remotePath = try server.openRemoteListener(machine: "M1")
        let holder = try connect(remotePath, "Remote.scn", token: "T1")
        XCTAssertEqual(try take(holder, "k").outcome, .granted)
        let waiter = try connect(server.socketPath, "Waiter.scn")
        let id = try waiter.request(keys: ["k"], mode: .exclusive).get()
        XCTAssertEqual(waiter.wait(id: id, timeout: .milliseconds(200)), .timedOut)
        // 中継役(手元のプロセス): ssh が終わった
        let control = try RunLockControl.connect(path: server.socketPath)
        let otherListener = try server.openRemoteListener(machine: "M2")
        let first = try XCTUnwrap(control.sshEnded(listener: remotePath))
        XCTAssertEqual(first.count, 1)
        XCTAssertEqual(first.capSeconds, 5, "上限(中継役が確かめ直しの上限を決める材料)")
        XCTAssertEqual(waiter.wait(id: id, timeout: .seconds(5)), .failed(RunLockTable.unknownOwnerReason(key: "k", machine: "M1")))
        XCTAssertEqual(try XCTUnwrap(control.sshEnded(listener: otherListener)).count, 0, "別のディスパッチの不明は無い")
        // 向こうの run の終わりを確かめた
        XCTAssertTrue(control.remoteRunEnded(listener: remotePath))
        XCTAssertEqual(try XCTUnwrap(control.sshEnded(listener: remotePath)).count, 0)
        let next = try connect(server.socketPath, "Next.scn")
        XCTAssertEqual(try take(next, "k").outcome, .granted)
        XCTAssertEqual(next.takeLostKeys(), ["k"])
        XCTAssertTrue(lines.all.contains { $0.contains("the remote run has ended") }, "\(lines.all)")
    }

    func testTheControlConnectionSeesTheIssuerClosingIt() throws {
        let server = try makeServer()
        let control = try RunLockControl.connect(path: server.socketPath)
        XCTAssertFalse(control.issuerClosed())
        server.stop()
        let deadline = Date().addingTimeInterval(5)
        while !control.issuerClosed(), Date() < deadline { usleep(10_000) }
        XCTAssertTrue(control.issuerClosed())
    }

    // MARK: 確かめ直し

    private final class FakeControl: RunLockRelayControl, @unchecked Sendable {
        var counts: [Int]
        var capSeconds: Int
        var othersActive = true
        var onSshEnded: () -> Void = {}
        var closed: Bool
        private(set) var sshEndedCalls = 0
        private(set) var remoteEndedCalls = 0
        init(counts: [Int], capSeconds: Int = 10, closed: Bool = false) {
            self.counts = counts
            self.capSeconds = capSeconds
            self.closed = closed
        }
        func sshEnded(listener: String) -> (count: Int, capSeconds: Int, othersActive: Bool)? {
            sshEndedCalls += 1
            onSshEnded()
            let value = counts.isEmpty ? 0 : counts.removeFirst()
            return (value, capSeconds, othersActive)
        }
        func remoteRunEnded(listener: String) -> Bool { remoteEndedCalls += 1; return true }
        func waitedMs(listener: String) -> Int? { nil }
        func issuerClosed() -> Bool { closed }
    }

    func testRecheckDoesNothingAndNeverAsksSshWhenThereAreNoUnknownKeys() {
        let control = FakeControl(counts: [0])
        var checks = 0
        XCTAssertEqual(RunLockRecheck.run(listener: "L1", control: control, runEnded: { checks += 1; return true }, sleep: { _ in }),
                       .noUnknownKeys)
        XCTAssertEqual(checks, 0, "不明のキーが無ければ向こうの run を確かめに行かない(run の終わりを遅らせない)")
        XCTAssertEqual(control.remoteEndedCalls, 0)
    }

    func testRecheckPollsUntilTheRemoteRunEndedThenReportsOnce() {
        let control = FakeControl(counts: [2, 2, 2])
        var results = [false, false, true]
        var sleeps = 0
        let outcome = RunLockRecheck.run(listener: "L1", control: control, runEnded: { results.removeFirst() }, sleep: { _ in sleeps += 1 })
        XCTAssertEqual(outcome, .released)
        XCTAssertEqual(control.remoteEndedCalls, 1)
        XCTAssertEqual(sleeps, 2, "終わるまで間をおいて確かめ直す")
    }

    func testRecheckStopsWhenTheIssuerClosesTheConnection() {
        let control = FakeControl(counts: [3], closed: true)
        var checks = 0
        XCTAssertEqual(RunLockRecheck.run(listener: "L1", control: control, runEnded: { checks += 1; return false }, sleep: { _ in }),
                       .issuerClosed)
        XCTAssertEqual(checks, 0)
        XCTAssertEqual(control.remoteEndedCalls, 0)
    }

    func testRecheckGivesUpAtTheCapPlusGraceAndStopsWhenTheUnknownKeysDisappear() {
        // 上限 + 猶予が既に過ぎている値(-猶予)なら、1回目の判定で諦める
        let expired = FakeControl(counts: [1], capSeconds: -RunLockRecheck.teardownGraceSeconds)
        XCTAssertEqual(RunLockRecheck.run(listener: "L1", control: expired, runEnded: { false }, sleep: { _ in }), .gaveUp)
        // シナリオの終わりの報告で不明が消えたら止める
        let drained = FakeControl(counts: [1, 0])
        XCTAssertEqual(RunLockRecheck.run(listener: "L1", control: drained, runEnded: { false }, sleep: { _ in }), .noUnknownKeys)
    }

    func testRecheckStopsAtOnceOnInterruptBeforeAndBetweenChecks() {
        let control = FakeControl(counts: [3])
        var checks = 0
        XCTAssertEqual(RunLockRecheck.run(listener: "L1", control: control, runEnded: { checks += 1; return false },
                                          interrupted: { true }, sleep: { _ in }), .interrupted)
        XCTAssertEqual(checks, 0, "中断の後は確かめ直さない")
        // 眠っている間に中断された
        let again = FakeControl(counts: [3, 3, 3])
        var interrupted = false
        var sleeps = 0
        XCTAssertEqual(RunLockRecheck.run(listener: "L1", control: again, runEnded: { false }, interrupted: { interrupted },
                                          sleep: { _ in sleeps += 1; interrupted = true }), .interrupted)
        XCTAssertEqual(sleeps, 1)
        XCTAssertEqual(again.remoteEndedCalls, 0)
    }

    /// 発行元にほかの動いている仕事が無いなら確かめ直さない(誰も不明のキーを待てない。発行元の終わりを遅らせない)。不明のキーは外さない
    func testRecheckStopsWhenTheIssuerHasNoOtherActivityAndNeverReleases() {
        let control = FakeControl(counts: [2, 2])
        control.othersActive = false
        var checks = 0
        XCTAssertEqual(RunLockRecheck.run(listener: "L1", control: control, runEnded: { checks += 1; return true }, sleep: { _ in }),
                       .noOneElse)
        XCTAssertEqual(checks, 0, "向こうの run を確かめに行かない")
        XCTAssertEqual(control.remoteEndedCalls, 0, "確かめていないので不明のキーは外さない(安全側)")
        // 途中でほかの仕事が尽きた
        let later = FakeControl(counts: [2, 2, 2])
        var calls = 0
        later.onSshEnded = { calls += 1; if calls >= 2 { later.othersActive = false } }
        XCTAssertEqual(RunLockRecheck.run(listener: "L1", control: later, runEnded: { false }, sleep: { _ in }), .noOneElse)
        XCTAssertEqual(later.remoteEndedCalls, 0)
        // ほかの仕事があれば、これまでどおり確かめ直して外す
        let busy = FakeControl(counts: [2, 2])
        XCTAssertEqual(RunLockRecheck.run(listener: "L1", control: busy, runEnded: { true }, sleep: { _ in }), .released)
    }

    func testTheServerReportsOthersActiveFromRunningChildrenMinusLingeringOnesAndTheMoreWorkProbe() throws {
        let server = try makeServer()
        let first = try server.openRemoteListener(machine: "M1")
        let second = try server.openRemoteListener(machine: "M2")
        let control = try RunLockControl.connect(path: server.socketPath)
        server.childLaunched()  // 中継役 1(first)
        server.childLaunched()  // 中継役 2(second)
        // first の ssh が終わった: 走っている 2 のうち first 自身は確かめ直しの段 → second が残っている
        XCTAssertEqual(try XCTUnwrap(control.sshEnded(listener: first)).othersActive, true)
        // second も終わった: 残りは確かめ直しの段の 2 つだけ
        XCTAssertEqual(try XCTUnwrap(control.sshEnded(listener: second)).othersActive, false)
        XCTAssertEqual(try XCTUnwrap(control.sshEnded(listener: first)).othersActive, false)
        // まだ起こしていない仕事が残るなら true
        let more = LockedValue(true)
        server.setMoreWorkProbe { more.value }
        XCTAssertEqual(try XCTUnwrap(control.sshEnded(listener: first)).othersActive, true)
        more.value = false
        XCTAssertEqual(try XCTUnwrap(control.sshEnded(listener: first)).othersActive, false)
        // 子が終わって待ち受けを閉じたら確かめ直しの段から外れる(別の子が残っていれば true)
        server.closeRemoteListener(path: second)
        server.childExited()
        server.childLaunched()  // 新しい子
        XCTAssertEqual(try XCTUnwrap(control.sshEnded(listener: first)).othersActive, true)
    }

    func testRecheckReportsUnreachableWhenTheServerDoesNotAnswer() {
        struct Dead: RunLockRelayControl {
            func sshEnded(listener: String) -> (count: Int, capSeconds: Int, othersActive: Bool)? { nil }
            func remoteRunEnded(listener: String) -> Bool { false }
            func waitedMs(listener: String) -> Int? { nil }
            func issuerClosed() -> Bool { false }
        }
        XCTAssertEqual(RunLockRecheck.run(listener: "L1", control: Dead(), runEnded: { true }, sleep: { _ in }), .unreachable)
    }
}
