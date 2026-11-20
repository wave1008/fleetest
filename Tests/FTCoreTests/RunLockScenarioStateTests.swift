import XCTest
@testable import FTCore

/// シナリオのプロセスの側(キーの検査・規則②③・待ちと時間切れ・run メモの規則・受け渡しの行・走査)
final class RunLockScenarioStateTests: XCTestCase {
    private var servers: [RunLockServer] = []

    override func tearDown() {
        servers.forEach { $0.stop() }
        servers = []
        DeadlineExclusion.observer = nil
        super.tearDown()
    }

    private final class NullMemo: RunLockMemoBackend, @unchecked Sendable {
        func snapshot() -> [String: [String]] { [:] }
        func apply(_ op: RunMemoOp) {}
    }

    private func makeServer() throws -> RunLockServer {
        let server = try RunLockServer(memoFor: { _ in NullMemo() }, log: { _ in })
        servers.append(server)
        return server
    }

    private func state(_ access: RunLockAccess, cap: Int = 30) -> RunLockScenarioState {
        let state = RunLockScenarioState()
        state.access = access
        state.waitCapSeconds = cap
        state.scenarioID = "T.s"
        state.machine = "m"
        state.device = "d"
        return state
    }

    private func entry(_ result: Result<RunLockScenarioState.Entry, RunLockError>,
                       file: StaticString = #filePath, line: UInt = #line) throws -> RunLockScenarioState.Entry {
        switch result {
        case .success(let entry): return entry
        case .failure(let error):
            XCTFail("expected a lock but got: \(error.message)", file: file, line: line)
            throw error
        }
    }

    private func failure(_ result: Result<RunLockScenarioState.Entry, RunLockError>) -> String {
        if case .failure(let error) = result { return error.message }
        return ""
    }

    // MARK: キー

    func testKeysAreSortedByUTF8BytesAndDeduplicatedByBytes() throws {
        XCTAssertEqual(try RunLockKeys.normalize(["b", "a", "b"]).get(), ["a", "b"])
        // 合成済みの é(C3 A9)と分解形の e + U+0301(65 CC 81)は Swift の String では等しいが、バイト列では別のキーで、分解形が先
        let precomposed = "\u{E9}", decomposed = "e\u{301}"
        XCTAssertEqual(precomposed, decomposed)
        XCTAssertEqual(try RunLockKeys.normalize([precomposed, decomposed]).get().map { Array($0.utf8) },
                       [Array(decomposed.utf8), Array(precomposed.utf8)])
    }

    func testInvalidKeysAreRefused() {
        func message(_ keys: [String]) -> String {
            if case .failure(let error) = RunLockKeys.normalize(keys) { return error.message }
            return ""
        }
        XCTAssertTrue(message([]).contains("at least one"))
        XCTAssertTrue(message(["ok", "  "]).contains("blank"))
        XCTAssertTrue(message([""]).contains("blank"))
        XCTAssertTrue(message(["a\nb"]).contains("control characters"))
        XCTAssertTrue(message(["a\u{7F}"]).contains("control characters"), "DEL も制御文字")
    }

    /// キーの長さと個数に上限を置かない(DR-210)。上限を戻すと落ちる
    func testLongKeysAndManyKeysAreAccepted() throws {
        let long = String(repeating: "あ", count: 1_000)   // 3,000 バイト
        XCTAssertEqual(try RunLockKeys.normalize([long]).get(), [long])
        let many = (0..<100).map { String(format: "k%03d", $0) }
        XCTAssertEqual(try RunLockKeys.normalize(many.reversed()).get(), many)
    }

    // MARK: 入れ子の全面禁止(競合が無くても・どのアクセスでもエラー)

    func testNestedLockWithADifferentKeyIsAnErrorEvenWithoutContention() throws {
        let state = state(.immediate)
        let outer = try entry(state.enter(keys: ["a"], waitSeconds: nil))
        let message = failure(state.enter(keys: ["b"], waitSeconds: nil))
        XCTAssertTrue(message.contains("cannot be called inside another withRunLock"), message)
        XCTAssertTrue(message.contains("\"a\"") && message.contains("one call"), message)
        state.leave(outer)
        XCTAssertFalse(state.isHolding)
        _ = try entry(state.enter(keys: ["b"], waitSeconds: nil))  // 抜けた後は取れる
    }

    func testNestedLockWithTheSameKeyIsAnErrorAndKeepsTheOuterHolding() throws {
        let state = state(.immediate)
        let outer = try entry(state.enter(keys: ["k"], waitSeconds: nil))
        XCTAssertTrue(failure(state.enter(keys: ["k"], waitSeconds: nil)).contains("another withRunLock"))
        XCTAssertTrue(state.isHolding, "エラーでも外側の持ち分は残る")
        state.leave(outer)
        XCTAssertFalse(state.isHolding)
    }

    func testNestedLockIsAnErrorForPassThroughToo() throws {
        let state = state(.passThrough)
        let outer = try entry(state.enter(keys: ["b"], waitSeconds: nil))
        XCTAssertFalse(failure(state.enter(keys: ["a"], waitSeconds: nil)).isEmpty)
        XCTAssertFalse(failure(state.enter(keys: ["b"], waitSeconds: nil)).isEmpty)
        state.leave(outer)
    }

    func testNestedLockViaTheServerNeverAsksTheServerAndTheOuterRequestStaysUntilTheOuterBlockLeaves() throws {
        let server = try makeServer()
        let state = state(.socket(server.socketPath))
        let other = try RunLockClient.connect(path: server.socketPath, scenario: "O", machine: "m", device: "d")
        let outer = try entry(state.enter(keys: ["k"], waitSeconds: nil))
        XCTAssertFalse(failure(state.enter(keys: ["k"], waitSeconds: nil)).isEmpty)
        XCTAssertFalse(failure(state.enter(keys: ["j"], waitSeconds: nil)).isEmpty)
        let id = try other.request(keys: ["j"]).get()
        XCTAssertEqual(other.wait(id: id, timeout: .seconds(5)), .granted, "入れ子の失敗は別のキーを取らない")
        let waiting = try other.request(keys: ["k"]).get()
        XCTAssertEqual(other.wait(id: waiting, timeout: .milliseconds(200)), .timedOut, "外側が持っている")
        state.leave(outer)
        XCTAssertEqual(other.wait(id: waiting, timeout: .seconds(5)), .granted)
    }

    func testRefuseFailsWithTheReasonAndDoesNotWait() {
        let state = state(.refuse("because"))
        let message = failure(state.enter(keys: ["a"], waitSeconds: nil))
        XCTAssertTrue(message.contains("because"), message)
        XCTAssertFalse(state.isHolding)
    }

    func testInvalidWaitSecondsIsRefused() {
        for value in [0.0, -1.0, .nan, .infinity] {
            XCTAssertTrue(failure(state(.immediate).enter(keys: ["a"], waitSeconds: value))
                .contains("waitSeconds"))
        }
    }

    // MARK: サーバーとの待ち

    func testWaitTimesOutAfterWaitSecondsNamingTheKeyAndTheSecondsAndThenTheKeyIsFree() throws {
        let server = try makeServer()
        let holder = try RunLockClient.connect(path: server.socketPath, scenario: "H", machine: "m", device: "d")
        let heldID = try holder.request(keys: ["db"]).get()
        XCTAssertEqual(holder.wait(id: heldID, timeout: .seconds(5)), .granted)
        let waiter = state(.socket(server.socketPath), cap: 30)
        let started = Date()
        let message = failure(waiter.enter(keys: ["db"], waitSeconds: 0.3))
        XCTAssertGreaterThanOrEqual(Date().timeIntervalSince(started), 0.25)
        XCTAssertLessThan(Date().timeIntervalSince(started), 5)
        XCTAssertTrue(message.contains("\"db\"") && message.contains("timed out") && message.contains("0.3"), message)
        XCTAssertFalse(waiter.isHolding)
        // 時間切れで取り消した要求はもう渡されない: 持ち主が放した後に別の人がすぐ取れる
        holder.release(id: heldID)
        let third = state(.socket(server.socketPath))
        _ = try entry(third.enter(keys: ["db"], waitSeconds: 5))
    }

    func testWaitSecondsLongerThanTheAbsoluteCapDoesNotExtendTheCap() throws {
        let server = try makeServer()
        let holder = try RunLockClient.connect(path: server.socketPath, scenario: "H", machine: "m", device: "d")
        _ = try holder.request(keys: ["db"]).get()
        let waiter = state(.socket(server.socketPath), cap: 1)
        let started = Date()
        let message = failure(waiter.enter(keys: ["db"], waitSeconds: 600))
        XCTAssertLessThan(Date().timeIntervalSince(started), 5, "上限(1秒)で切れる")
        XCTAssertTrue(message.contains("limit 1s"), message)
    }

    func testTheWaitOpensAndClosesTheDeadlineExclusionWindowWithTheAbsoluteCap() throws {
        let server = try makeServer()
        let holder = try RunLockClient.connect(path: server.socketPath, scenario: "H", machine: "m", device: "d")
        let heldID = try holder.request(keys: ["db"]).get()
        _ = holder.wait(id: heldID, timeout: .seconds(5))
        let changes = LockedValue<[DeadlineExclusion.Change]>([])
        DeadlineExclusion.observer = { change in changes.withLock { $0.append(change) } }
        let waiter = state(.socket(server.socketPath), cap: 7)
        _ = waiter.enter(keys: ["db"], waitSeconds: 0.2)
        let seen = changes.value
        XCTAssertEqual(seen.count, 2)
        guard case .began(let capMs)? = seen.first else { return XCTFail("began first: \(seen)") }
        XCTAssertEqual(capMs, 7000, "窓の上限は waitSeconds ではなく絶対の上限")
        guard case .ended? = seen.last else { return XCTFail("ended last: \(seen)") }
    }

    func testAnImmediateGrantDoesNotOpenTheExclusionWindow() throws {
        let server = try makeServer()
        let changes = LockedValue<[DeadlineExclusion.Change]>([])
        DeadlineExclusion.observer = { change in changes.withLock { $0.append(change) } }
        let state = state(.socket(server.socketPath))
        let held = try entry(state.enter(keys: ["free"], waitSeconds: nil))
        XCTAssertTrue(changes.value.isEmpty)
        XCTAssertLessThan(held.waited, 1)
        state.leave(held)
    }

    func testUnreachableServerFailsAtOnceAndEveryLaterCallFailsWithoutReconnecting() throws {
        let path = (NSTemporaryDirectory() as NSString).appendingPathComponent("ftlock-none-\(UUID().uuidString.prefix(6)).sock")
        let state = state(.socket(path))
        let started = Date()
        XCTAssertTrue(failure(state.enter(keys: ["a"], waitSeconds: nil)).contains("cannot reach"))
        XCTAssertTrue(failure(state.enter(keys: ["b"], waitSeconds: nil)).contains("cannot reach"))
        XCTAssertLessThan(Date().timeIntervalSince(started), 2, "待たずに失敗する")
    }

    /// つなぐと ECONNREFUSED になる(ファイルはあるが待ち受けが無い)パス
    private func refusingSocketPath() throws -> String {
        let path = (NSTemporaryDirectory() as NSString).appendingPathComponent("ftlock-refuse-\(UUID().uuidString.prefix(6)).sock")
        let listener = try UnixSocket.listen(path: path)
        close(listener)
        return path
    }

    func testTransientConnectRefusalIsRetriedWithinTheCapAndThenFails() throws {
        let path = try refusingSocketPath()
        defer { unlink(path) }
        let changes = LockedValue<[DeadlineExclusion.Change]>([])
        DeadlineExclusion.observer = { change in changes.withLock { $0.append(change) } }
        let state = state(.socket(path), cap: 1)
        let started = Date()
        XCTAssertTrue(failure(state.enter(keys: ["a"], waitSeconds: nil)).contains("cannot reach"))
        XCTAssertGreaterThanOrEqual(Date().timeIntervalSince(started), 0.9, "上限(1秒)まで再試行する")
        XCTAssertLessThan(Date().timeIntervalSince(started), 5)
        XCTAssertEqual(changes.value.count, 2, "再試行の間は待ちの窓を開く")
    }

    /// 結んだが待ち受けていないソケット(つなぐと ECONNREFUSED)。後から同じ fd で `listen` すれば、ファイルを消して結び直す隙間
    /// (その間につなぐと ENOENT = 再試行しない失敗)を作らずに「サーバーが立った」を再現できる
    private func boundButNotListening() throws -> (path: String, descriptor: Int32) {
        let path = (NSTemporaryDirectory() as NSString).appendingPathComponent("ftlock-late-\(UUID().uuidString.prefix(6)).sock")
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &address.sun_path) { buffer in
            for (index, byte) in Array(path.utf8).enumerated() { buffer[index] = byte }
        }
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard descriptor >= 0, bound == 0 else { throw POSIXError(.EIO) }
        return (path, descriptor)
    }

    func testConnectSucceedsWhenTheServerComesUpDuringTheRetry() throws {
        let (path, listener) = try boundButNotListening()
        defer { unlink(path) }
        Thread {
            usleep(300_000)
            guard Darwin.listen(listener, 16) == 0 else { return }
            let conn = accept(listener, nil, nil)
            let channel = RunLockLineChannel(descriptor: conn)
            while case .line(let data) = channel.readLine(timeoutMs: 3000) {
                if case .acquire(let id, _)? = RunLockMessage.decode(line: data) {
                    _ = RunLockLineChannel.writeAll(conn, RunLockMessage.granted(id: id).encodedLine())
                }
            }
            close(conn)
            close(listener)
        }.start()
        let state = state(.socket(path), cap: 10)
        let held = try entry(state.enter(keys: ["a"], waitSeconds: nil))
        state.leave(held)
    }

    func testMissingServerFileStillFailsAtOnceWithoutRetrying() {
        let state = state(.socket("/tmp/ftlock-missing-\(UUID().uuidString.prefix(6)).sock"), cap: 30)
        let started = Date()
        XCTAssertTrue(failure(state.enter(keys: ["a"], waitSeconds: nil)).contains("cannot reach"))
        // 見分けるのは「即座」と「上限(30秒)まで再試行」。境目は上限の半分(全体のテストの並列の負荷で、即座の失敗でも 2 秒を超えた)
        XCTAssertLessThan(Date().timeIntervalSince(started), 15)
    }

    func testBrokenConnectionMakesEveryLaterLockCallFail() throws {
        let server = try makeServer()
        let state = state(.socket(server.socketPath))
        let held = try entry(state.enter(keys: ["a"], waitSeconds: nil))
        server.stop()
        let message = failure(state.enter(keys: ["z"], waitSeconds: 1))
        XCTAssertFalse(message.isEmpty)
        XCTAssertFalse(failure(state.enter(keys: ["y"], waitSeconds: 1)).isEmpty)
        state.leave(held)
    }

    func testMultiKeyEnterWithAHeldSecondKeyTimesOutAndReleasesTheFirst() throws {
        let server = try makeServer()
        let holder = try RunLockClient.connect(path: server.socketPath, scenario: "H", machine: "m", device: "d")
        let heldID = try holder.request(keys: ["b"]).get()
        _ = holder.wait(id: heldID, timeout: .seconds(5))
        let waiter = state(.socket(server.socketPath))
        XCTAssertFalse(failure(waiter.enter(keys: ["b", "a"], waitSeconds: 0.2)).isEmpty)
        let third = state(.socket(server.socketPath))
        _ = try entry(third.enter(keys: ["a"], waitSeconds: 2))
    }

    // MARK: run メモ

    func testRunMemoWritesAreAcceptedInsideTheLock() throws {
        let state = state(.immediate)
        let op = RunMemoOp.write(key: "k", value: "v")
        XCTAssertNil(state.memoWriteRejection(command: "writeRunMemo", op: op), "ロックの外は今のまま")
        let held = try entry(state.enter(keys: ["a"], waitSeconds: nil))
        for command in ["writeRunMemo", "clearRunMemo", "runMemoTextAs"] {
            XCTAssertNil(state.memoWriteRejection(command: command, op: command == "clearRunMemo" ? .clear : op), command)
        }
        state.leave(held)
    }

    func testOversizeRunMemoWriteIsRefusedEvenOnASingleMachineConfiguration() throws {
        let state = state(.immediate)
        let exclusive = try entry(state.enter(keys: ["a"], waitSeconds: nil))
        let huge = String(repeating: "x", count: RunMemoWire.maxPieces * RunMemoWire.pieceCharacters)
        XCTAssertTrue(state.memoWriteRejection(command: "writeRunMemo", op: .write(key: "k", value: huge))?
            .contains("too large") == true)
        state.leave(exclusive)
    }

    func testServerMemoIsUsedOnlyWhileHoldingALockOverAConnection() throws {
        let server = try makeServer()
        let state = state(.socket(server.socketPath))
        XCTAssertFalse(state.usesServerMemo)
        let held = try entry(state.enter(keys: ["a"], waitSeconds: nil))
        XCTAssertTrue(state.usesServerMemo)
        state.leave(held)
        XCTAssertFalse(state.usesServerMemo)
        // その場で渡す / 取らずに通すは接続を持たない = ロックの中でも手元の通り道
        let immediate = self.state(.immediate)
        let h2 = try entry(immediate.enter(keys: ["a"], waitSeconds: nil))
        XCTAssertFalse(immediate.usesServerMemo)
        immediate.leave(h2)
    }

    func testPendingReplyOpensTheDeadlineExclusionWindowWithTheAbsoluteCapDuringTheMemoWait() throws {
        let applied = RunLockAppliedOps()
        let server = try RunLockServer(memoFor: { _ in NullMemo() }, applied: applied, waitCapSeconds: { 30 }, log: { _ in })
        servers.append(server)
        let state = state(.socket(server.socketPath), cap: 7)
        state.ownerToken = "tok"
        let held = try entry(state.enter(keys: ["a"], waitSeconds: nil))
        state.noteOutsideMemoOp()  // ロックの外の操作が1件(親がまだ適用していない)
        let changes = LockedValue<[DeadlineExclusion.Change]>([])
        DeadlineExclusion.observer = { change in changes.withLock { $0.append(change) } }
        let done = DispatchSemaphore(value: 0)
        let result = LockedValue<Result<[String: [String]], RunLockError>?>(nil)
        Thread { result.value = state.serverMemoRead(); done.signal() }.start()
        let deadline = Date().addingTimeInterval(5)
        while changes.value.isEmpty, Date() < deadline { usleep(10_000) }
        guard case .began(let capMs)? = changes.value.first else { return XCTFail("window must open: \(changes.value)") }
        XCTAssertEqual(capMs, 7000, "窓の上限は絶対上限")
        XCTAssertEqual(done.wait(timeout: .now() + .milliseconds(200)), .timedOut, "適用が届くまで読みは待つ")
        applied.note(token: "tok")
        XCTAssertEqual(done.wait(timeout: .now() + 5), .success)
        XCTAssertEqual(changes.value.count, 2, "終わったら窓を閉じる")
        XCTAssertNotNil(try? result.value?.get())
        state.leave(held)
    }

    func testNoWindowOpensWhenTheOutsideOpsAreAlreadyApplied() throws {
        let applied = RunLockAppliedOps()
        let server = try RunLockServer(memoFor: { _ in NullMemo() }, applied: applied, waitCapSeconds: { 30 }, log: { _ in })
        servers.append(server)
        let state = state(.socket(server.socketPath))
        state.ownerToken = "tok"
        let held = try entry(state.enter(keys: ["a"], waitSeconds: nil))
        let changes = LockedValue<[DeadlineExclusion.Change]>([])
        DeadlineExclusion.observer = { change in changes.withLock { $0.append(change) } }
        XCTAssertNotNil(try? state.serverMemoRead().get())
        XCTAssertTrue(changes.value.isEmpty)
        state.leave(held)
    }

    // MARK: 受け渡しの行

    func testHandoffRoundTripsEveryAccessKindAndRequiresTheFields() throws {
        for access in [RunLockAccess.socket("/tmp/x.sock"), .immediate, .passThrough, .refuse("why \"quoted\"")] {
            let original = DeviceSessionHandoff(runMemo: [:], runSetUpDevice: true, runBeforeAll: false,
                                                lockAccess: access, lockWaitCapSeconds: 123, lockOwnerToken: "tok")
            XCTAssertEqual(DeviceSessionHandoff.decode(line: original.encodedLine()), original)
        }
        // 必須の欄(DR-5): 欄の無い古い形は読めない
        XCTAssertNil(DeviceSessionHandoff.decode(
            line: #"{"cmd":"deviceSession","runMemo":{},"runSetUpDevice":false,"runBeforeAll":false}"#))
        XCTAssertNil(DeviceSessionHandoff.decode(
            line: #"{"cmd":"deviceSession","runMemo":{},"runSetUpDevice":false,"runBeforeAll":false,"lockAccess":{"immediate":{}}}"#))
    }

    // MARK: 走査・上限・ホスト

    func testSourceScanFindsCallsOutsideCommentsAndStringsOnly() {
        XCTAssertTrue(RunLockUsage.sourceUsesLocks("withRunLock(\"a\") { }"))
        XCTAssertTrue(RunLockUsage.sourceUsesLocks("  withRunLock(\"a\") { }"))
        XCTAssertTrue(RunLockUsage.sourceUsesLocks("FTDSL.withRunLock(\"a\") { }"))
        XCTAssertFalse(RunLockUsage.sourceUsesLocks("// withRunLock(\"a\") { }"))
        XCTAssertFalse(RunLockUsage.sourceUsesLocks("/* withRunLock */"))
        XCTAssertFalse(RunLockUsage.sourceUsesLocks("let s = \"withRunLock\""))
        XCTAssertFalse(RunLockUsage.sourceUsesLocks("func mywithRunLockHelper() {}"))
        XCTAssertFalse(RunLockUsage.sourceUsesLocks("withRunLockX()"))
    }

    func testProjectScanSkipsTheDisabledFolder() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("lockscan-\(UUID().uuidString)")
        let project = TestProject(name: "P", rootURL: root)
        try FileManager.default.createDirectory(at: project.disabledDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try "withRunLock(\"a\") {}".write(to: project.disabledDir.appendingPathComponent("Old.swift"),
                                                 atomically: true, encoding: .utf8)
        XCTAssertFalse(RunLockUsage.projectUsesLocks(project))
        try "withRunLock(\"a\") {}".write(to: project.scenariosDir.appendingPathComponent("New.swift"),
                                               atomically: true, encoding: .utf8)
        XCTAssertTrue(RunLockUsage.projectUsesLocks(project))
    }

    func testWaitCapIsTheLongestEffectiveScenarioTimeoutIncludingTestOverrides() {
        XCTAssertEqual(RunLockUsage.waitCapSeconds(scenarioTimeouts: [nil, nil], settingsTimeout: 300), 300)
        XCTAssertEqual(RunLockUsage.waitCapSeconds(scenarioTimeouts: [nil, 1200, 60], settingsTimeout: 300), 1200,
                       "@Test(scenarioTimeout:) が長ければそれ")
        XCTAssertEqual(RunLockUsage.waitCapSeconds(scenarioTimeouts: [60], settingsTimeout: 300), 60,
                       "シナリオ側が短いときも実効の値(最長はその中の最大)")
        XCTAssertEqual(RunLockUsage.waitCapSeconds(scenarioTimeouts: [], settingsTimeout: nil), ScenarioHost.defaultScenarioTimeout)
    }

    func testOverlapLineCountsOtherRunsOfTheSameProjectOnly() {
        func record(pid: Int32, project: String) -> RunProgressRecord { RunProgressRecord(
            pid: pid, runID: nil, runGroup: nil, issuer: nil, project: project, profile: nil, startedAt: "2026-11-20T00:00:00Z",
            total: 1, done: 0, failed: 0, actions: 0, requeued: 0, laneDropouts: 0, etaSeconds: nil, lanes: [],
            phase: "running", supply: [], videoClips: nil, owner: nil, jobID: nil) }
        XCTAssertNil(RunLockUsage.overlapLine(project: "P", ownPid: 1, records: [record(pid: 1, project: "P"), record(pid: 2, project: "Q")]))
        let line = RunLockUsage.overlapLine(project: "P", ownPid: 1, records: [record(pid: 1, project: "P"), record(pid: 2, project: "P")])
        XCTAssertTrue(line?.contains("pid 2") == true)
    }

    func testEachOwnerTokenIsRoutedToItsOwnRunMemoAndUnregisterRefusesIt() throws {
        let host = RunLockHost(mode: .ownServer)
        let storeA = RunMemoStore(), storeB = RunMemoStore()
        host.register(token: "A", memo: storeA)
        host.register(token: "B", memo: storeB)
        guard case .socket(let path) = host.access() else { return XCTFail("socket expected") }
        defer { host.stop() }
        let clientA = try RunLockClient.connect(path: path, scenario: "S", machine: "m", device: "d", token: "A")
        let clientB = try RunLockClient.connect(path: path, scenario: "S", machine: "m", device: "d", token: "B")
        XCTAssertNil(clientA.memoWrite(.write(key: "k", value: "a"), outsideOps: 0))
        XCTAssertNil(clientB.memoWrite(.write(key: "k", value: "b"), outsideOps: 0))
        XCTAssertEqual(storeA.snapshot(), ["k": ["a"]])
        XCTAssertEqual(storeB.snapshot(), ["k": ["b"]])
        host.unregister(token: "A")
        XCTAssertNotNil(clientA.memoWrite(.write(key: "k", value: "again"), outsideOps: 0))
        XCTAssertEqual(storeA.snapshot(), ["k": ["a"]])
    }

    func testMergedConfigurationKeepsUsesAndTheLargerCap() {
        let host = RunLockHost(mode: .ownServer)
        host.configure(usesLocks: true, waitCapSeconds: 100, linkedToParent: false, merge: true) { _ in }
        host.configure(usesLocks: false, waitCapSeconds: 50, linkedToParent: false, merge: true) { _ in }
        XCTAssertEqual(host.currentWaitCapSeconds, 100)
        guard case .socket = host.access() else { return XCTFail("使う呼び出しが先にあったので止めない") }
        host.stop()
    }

    func testHostAccessFollowsTheConfigurationAndStopRemovesTheSocket() throws {
        let host = RunLockHost(mode: .refuse(RunLockHost.notConfiguredRefusal))
        XCTAssertEqual(host.access(), .refuse(RunLockHost.notConfiguredRefusal))
        let warnings = LockedValue<[String]>([])
        host.configure(usesLocks: false, waitCapSeconds: 42, linkedToParent: false) { _ in }
        XCTAssertEqual(host.access(), .refuse(RunLockHost.notDetectedRefusal))
        host.configure(usesLocks: true, waitCapSeconds: 42, linkedToParent: true) { _ in }
        XCTAssertEqual(host.access(), .refuse(RunLockHost.linkedChildRefusal), "親とつながった子は使っていても断る")
        host.configure(usesLocks: true, waitCapSeconds: 42, linkedToParent: false,
                       overlapWarning: { "overlap!" }) { line in warnings.withLock { $0.append(line) } }
        XCTAssertEqual(host.currentWaitCapSeconds, 42)
        guard case .socket(let path) = host.access() else { return XCTFail("socket expected") }
        XCTAssertTrue(FileManager.default.fileExists(atPath: path))
        _ = host.access()
        XCTAssertEqual(warnings.value.filter { $0 == "overlap!" }.count, 1, "重なりの警告はサーバーを起こした時に1回だけ")
        host.stop()
        XCTAssertFalse(FileManager.default.fileExists(atPath: path))
    }

    /// --fleet で断るときの文言は、直し方(1つの実行プロファイルでマシンをまたぐ)を言う
    func testFleetRefusalNamesTheFix() {
        XCTAssertTrue(RunLockHost.fleetEntryRefusal.contains("name the machines on the devices of one run profile"),
                      RunLockHost.fleetEntryRefusal)
    }

    /// 見つからなかったときの文言は、探した場所と直し方を言う(別のパッケージにだけ書いた利用者がたどり着けるように)
    func testNotDetectedRefusalNamesWhereItLookedAndTheFix() {
        let message = RunLockHost.notDetectedRefusal
        XCTAssertTrue(message.contains("scenarios/"), message)
        XCTAssertTrue(message.contains("another target or package"), message)
        XCTAssertTrue(message.contains("write at least one withRunLock call in a scenario file"), message)
    }

    func testHostInterruptBeforeAndAfterStartFailsNewRequests() throws {
        let host = RunLockHost(mode: .ownServer)
        host.interrupt()
        guard case .socket(let path) = host.access() else { return XCTFail("socket expected") }
        let client = try RunLockClient.connect(path: path, scenario: "S", machine: "m", device: "d")
        let id = try client.request(keys: ["a"]).get()
        XCTAssertEqual(client.wait(id: id, timeout: .seconds(5)), .failed(RunLockTable.interruptedReason))
        host.stop()
    }

    func testDroppingTheHostRemovesTheSocketFile() throws {
        var host: RunLockHost? = RunLockHost(mode: .ownServer)
        guard case .socket(let path)? = host?.access() else { return XCTFail("socket expected") }
        host = nil
        XCTAssertFalse(FileManager.default.fileExists(atPath: path))
    }
}

extension RunLockScenarioState.Entry {
    /// テスト用: サーバーへ頼んだ要求の番号(頼んでいなければ nil)
    var requestIDForTesting: Int? { requestID }
}
