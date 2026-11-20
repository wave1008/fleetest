import XCTest
@testable import FTCore

/// ロックのサーバーとクライアントを実際の unix ソケットで通す(RR-8.5)。持ち主のプロセスの終わりの待ちは偽に差し替える
final class RunLockServerTests: XCTestCase {
    private final class FakeMemo: RunLockMemoBackend, @unchecked Sendable {
        private let lock = NSLock()
        private var values: [String: [String]] = [:]
        private(set) var ops: [RunMemoOp] = []
        func snapshot() -> [String: [String]] { lock.withLock { values } }
        func apply(_ op: RunMemoOp) {
            lock.withLock {
                ops.append(op)
                switch op {
                case .write(let key, let value): values[key, default: []].append(value)
                case .clear: values.removeAll()
                }
            }
        }
    }

    private final class Lines: @unchecked Sendable {
        private let lock = NSLock()
        private var items: [String] = []
        func add(_ line: String) { lock.withLock { items.append(line) } }
        var all: [String] { lock.withLock { items } }
    }

    /// 持ち主の終わりの待ちの偽。呼ばれた pid と、終わりを知らせる口を控える
    private final class ExitWaiters: @unchecked Sendable {
        private let lock = NSLock()
        private var pids: [pid_t] = []
        private var exits: [@Sendable () -> Void] = []
        let fireAtOnce: Bool
        /// 非 nil なら、待てなくなった(kqueue の失敗の代わり)として `onError` をこの理由で呼ぶ
        let failWith: String?
        init(fireAtOnce: Bool = false, failWith: String? = nil) {
            self.fireAtOnce = fireAtOnce
            self.failWith = failWith
        }
        var waiter: RunLockServer.PidExitWaiter {
            { pid, _, onExit, onError in
                self.lock.withLock {
                    self.pids.append(pid)
                    if !self.fireAtOnce, self.failWith == nil { self.exits.append(onExit) }
                }
                if let failWith = self.failWith { onError(failWith); return }
                if self.fireAtOnce { onExit() }
            }
        }
        var requestedPids: [pid_t] { lock.withLock { pids } }
        func fireAll() {
            let current = lock.withLock { () -> [@Sendable () -> Void] in
                defer { exits.removeAll() }
                return exits
            }
            for exit in current { exit() }
        }
    }

    private var servers: [RunLockServer] = []

    override func tearDown() {
        servers.forEach { $0.stop() }
        servers = []
        super.tearDown()
    }

    private func makeServer(memo: RunLockMemoBackend = FakeMemo(), waiters: ExitWaiters = ExitWaiters(),
                            lines: Lines = Lines(), interval: Duration = .seconds(3600),
                            applied: RunLockAppliedOps = RunLockAppliedOps(), capSeconds: Int = 5,
                            peerPid: @escaping RunLockServer.PeerPidReader = RunLockServer.peerPid,
                            maxReply: Int = RunLockLimits.maxLineBytes,
                            log: (@Sendable (String) -> Void)? = nil) throws -> RunLockServer {
        let server = try RunLockServer(memoFor: { _ in memo }, applied: applied, waitCapSeconds: { capSeconds },
                                       log: log ?? { lines.add($0) }, reportInterval: interval,
                                       pidExitWaiter: waiters.waiter, peerPidReader: peerPid, maxReplyBytes: maxReply)
        servers.append(server)
        return server
    }

    private func connect(_ server: RunLockServer, _ name: String) throws -> RunLockClient {
        try RunLockClient.connect(path: server.socketPath, scenario: name, machine: "m", device: "d-\(name)")
    }

    private func take(_ client: RunLockClient, _ keys: [String],
                      timeout: Duration = .seconds(5)) throws -> (id: Int, outcome: RunLockClient.Outcome) {
        let id = try client.request(keys: keys).get()
        return (id, client.wait(id: id, timeout: timeout))
    }

    // MARK: プロトコル

    func testMessagesRoundTripThroughOneLineOfJSON() throws {
        let messages: [RunLockMessage] = [
            .hello(scenario: "S.a", machine: "m", device: "ios:1", token: "t"), .queued(id: 3),
            .acquire(id: 3, keys: ["a", "é"]), .cancel(id: 3), .release(id: 3), .memoRead(id: 6, outsideOps: 2),
            .memoWrite(id: 4, op: .write(key: "k", value: "line1\nline2"), outsideOps: 1), .memoWrite(id: 5, op: .clear, outsideOps: 0),
            .granted(id: 3), .failed(id: 3, reason: "r"), .memo(values: ["k": ["1", "2"]]), .committed(id: 4, seq: 9), .committed(id: 5, seq: nil),
        ]
        for message in messages {
            let line = message.encodedLine()
            XCTAssertEqual(line.filter { $0 == 0x0A }.count, 1, "改行を含む値でも1行")
            XCTAssertEqual(RunLockMessage.decode(line: line.dropLast()), message)
        }
        XCTAssertNil(RunLockMessage.decode(line: Data("{broken".utf8)))
    }

    // MARK: 競合・順序

    func testSecondExclusiveWaitsUntilTheFirstReleases() throws {
        let server = try makeServer()
        let a = try connect(server, "A")
        let b = try connect(server, "B")
        let first = try take(a, ["k"])
        XCTAssertEqual(first.outcome, .granted)
        let second = try b.request(keys: ["k"]).get()
        XCTAssertEqual(b.wait(id: second, timeout: .milliseconds(200)), .timedOut)
        a.release(id: first.id)
        XCTAssertEqual(b.wait(id: second, timeout: .seconds(5)), .granted)
    }

    // MARK: 持ち主の接続が閉じたとき

    func testHolderClosingReleasesOnlyAfterItsProcessHasExited() throws {
        let waiters = ExitWaiters()
        let server = try makeServer(waiters: waiters)
        var holder: RunLockClient? = try connect(server, "A")
        let waiting = try connect(server, "B")
        XCTAssertEqual(try take(try XCTUnwrap(holder), ["k"]).outcome, .granted)
        let id = try waiting.request(keys: ["k"]).get()
        holder = nil  // 外すを送らずに接続が閉じる
        let deadline = Date().addingTimeInterval(5)
        while waiters.requestedPids.isEmpty, Date() < deadline { usleep(10_000) }
        XCTAssertEqual(waiters.requestedPids, [getpid()], "接続の最初に控えた相手の pid の終わりを待つ")
        XCTAssertEqual(waiting.wait(id: id, timeout: .milliseconds(300)), .timedOut, "相手のプロセスが終わるまで渡さない")
        waiters.fireAll()
        XCTAssertEqual(waiting.wait(id: id, timeout: .seconds(5)), .granted)
    }

    func testHolderClosingWithAnAlreadyGoneProcessReleasesAtOnce() throws {
        let server = try makeServer(waiters: ExitWaiters(fireAtOnce: true))
        var holder: RunLockClient? = try connect(server, "A")
        let waiting = try connect(server, "B")
        XCTAssertEqual(try take(try XCTUnwrap(holder), ["k"]).outcome, .granted)
        let id = try waiting.request(keys: ["k"]).get()
        holder = nil
        XCTAssertEqual(waiting.wait(id: id, timeout: .seconds(5)), .granted)
    }

    func testAWaitingConnectionClosingJustDropsItsRequest() throws {
        let waiters = ExitWaiters()
        let server = try makeServer(waiters: waiters)
        let holder = try connect(server, "A")
        var gone: RunLockClient? = try connect(server, "B")
        let third = try connect(server, "C")
        let held = try take(holder, ["k"])
        _ = try XCTUnwrap(gone).request(keys: ["k"]).get()
        let queued = try third.request(keys: ["k"]).get()
        gone = nil
        usleep(200_000)
        XCTAssertTrue(waiters.requestedPids.isEmpty, "待っていただけの接続は終わりを待たない")
        holder.release(id: held.id)
        XCTAssertEqual(third.wait(id: queued, timeout: .seconds(5)), .granted)
    }

    // MARK: 取り消し・中断

    func testCancelledWaiterIsNeverGrantedAndTheNextOneIs() throws {
        let server = try makeServer()
        let a = try connect(server, "A"), b = try connect(server, "B"), c = try connect(server, "C")
        let held = try take(a, ["k"])
        let cancelled = try b.request(keys: ["k"]).get()
        let next = try c.request(keys: ["k"]).get()
        b.cancel(id: cancelled)
        a.release(id: held.id)
        XCTAssertEqual(c.wait(id: next, timeout: .seconds(5)), .granted)
    }

    func testCancelOfAMultiKeyWaitReleasesTheKeysAlreadyGranted() throws {
        let server = try makeServer()
        let a = try connect(server, "A"), b = try connect(server, "B"), c = try connect(server, "C")
        _ = try take(a, ["b"])
        let multi = try b.request(keys: ["a", "b"]).get()
        XCTAssertEqual(b.wait(id: multi, timeout: .milliseconds(150)), .timedOut)
        b.cancel(id: multi)
        XCTAssertEqual(try take(c, ["a"]).outcome, .granted, "取っていた a が放されている")
    }

    func testInterruptFailsWaitersAndNewRequests() throws {
        let server = try makeServer()
        let a = try connect(server, "A"), b = try connect(server, "B")
        let held = try take(a, ["k"])
        let waiting = try b.request(keys: ["k"]).get()
        server.interrupt()
        XCTAssertEqual(b.wait(id: waiting, timeout: .seconds(5)), .failed(RunLockTable.interruptedReason))
        XCTAssertEqual(try take(b, ["other"]).outcome, .failed(RunLockTable.interruptedReason))
        a.release(id: held.id)
    }

    func testInvalidKeysAreRefusedByTheServerToo() throws {
        let server = try makeServer()
        let a = try connect(server, "A")
        guard case .failed = try take(a, [" "]).outcome else { return XCTFail("blank key must fail") }
    }

    // MARK: run メモ

    func testMemoWriteIsCommittedBeforeTheReplyAndReadSeesIt() throws {
        let memo = FakeMemo()
        let server = try makeServer(memo: memo)
        let a = try connect(server, "A")
        XCTAssertNil(a.memoWrite(.write(key: "n", value: "1"), outsideOps: 0))
        XCTAssertEqual(memo.ops, [.write(key: "n", value: "1")], "確定(返事)より前にバックエンドへ入っている")
        XCTAssertEqual(try a.memoRead(outsideOps: 0).get(), ["n": ["1"]])
        XCTAssertNil(a.memoWrite(.clear, outsideOps: 0))
        XCTAssertEqual(try a.memoRead(outsideOps: 0).get(), [:])
    }

    func testTheSessionRunMemoStoreIsTheBackendSoLaterScenariosSeeTheWriteAtOnce() throws {
        let store = RunMemoStore()
        let server = try makeServer(memo: store)
        let a = try connect(server, "A")
        XCTAssertNil(a.memoWrite(.write(key: "n", value: "7"), outsideOps: 0))
        XCTAssertEqual(store.snapshot(), ["n": ["7"]])
    }

    func testMemoWriteWhoseConnectionBreaksAfterSendingIsNotRetriedAndSaysItMayHaveBeenWritten() throws {
        // 1行読んだら黙って閉じる偽のサーバー
        let path = (NSTemporaryDirectory() as NSString).appendingPathComponent("ftlock-fake-\(UUID().uuidString.prefix(6)).sock")
        let listener = try UnixSocket.listen(path: path)
        defer { close(listener); unlink(path) }
        let received = LockedValue<[RunLockMessage]>([])
        let done = DispatchSemaphore(value: 0)
        Thread {
            let conn = accept(listener, nil, nil)
            let channel = RunLockLineChannel(descriptor: conn)
            while case .line(let data) = channel.readLine(timeoutMs: 2000) {
                if let message = RunLockMessage.decode(line: data) {
                    received.withLock { $0.append(message) }
                    if case .memoWrite = message { break }
                }
            }
            close(conn)
            done.signal()
        }.start()
        let client = try RunLockClient.connect(path: path, scenario: "S", machine: "m", device: "d")
        let failure = try XCTUnwrap(client.memoWrite(.write(key: "k", value: "v"), outsideOps: 0))
        XCTAssertTrue(failure.message.contains("may or may not have been written"), failure.message)
        done.wait()
        XCTAssertEqual(received.value.filter { if case .memoWrite = $0 { return true } else { return false } }.count, 1,
                       "撃ち直さない")
        XCTAssertTrue(client.isBroken)
        guard case .failure = client.request(keys: ["a"]) else { return XCTFail("再接続しない") }
        XCTAssertNotNil(client.memoWrite(.clear, outsideOps: 0))
    }

    // MARK: queued・外の書き込みの待ち・pid 不明・lock の外・停止

    func testCanonicallyEquivalentKeysAreIndependentAtTheServerToo() throws {
        let server = try makeServer()
        let a = try connect(server, "A"), b = try connect(server, "B")
        XCTAssertEqual(try take(a, ["\u{E9}"]).outcome, .granted)
        XCTAssertEqual(try take(b, ["e\u{301}"], timeout: .seconds(2)).outcome, .granted, "別のバイト列のキーは待たない")
    }

    func testQueuedIsRepliedOnlyWhenTheRequestCannotBeGrantedAtOnce() throws {
        let server = try makeServer()
        let a = try connect(server, "A"), b = try connect(server, "B")
        let freeQueued = LockedValue(0)
        let first = try a.request(keys: ["k"]).get()
        XCTAssertEqual(a.wait(id: first, timeout: .seconds(5), onQueued: { freeQueued.withLock { $0 += 1 } }), .granted)
        XCTAssertEqual(freeQueued.value, 0, "すぐ渡せるときは queued を返さない")
        let blockedQueued = LockedValue(0)
        let second = try b.request(keys: ["k"]).get()
        XCTAssertEqual(b.wait(id: second, timeout: .milliseconds(200), onQueued: { blockedQueued.withLock { $0 += 1 } }), .timedOut)
        XCTAssertEqual(blockedQueued.value, 1, "待ちに入ったとき1回だけ")
        a.release(id: first)
        XCTAssertEqual(b.wait(id: second, timeout: .seconds(5)), .granted)
    }

    func testMemoAccessWaitsForTheCarriedNumberOfOutsideOpsToBeApplied() throws {
        let applied = RunLockAppliedOps()
        let memo = FakeMemo()
        let server = try makeServer(memo: memo, applied: applied)
        let client = try RunLockClient.connect(path: server.socketPath, scenario: "S", machine: "m", device: "d", token: "tok")
        let result = LockedValue<Result<[String: [String]], RunLockError>?>(nil)
        let done = DispatchSemaphore(value: 0)
        Thread { result.value = client.memoRead(outsideOps: 2); done.signal() }.start()
        XCTAssertEqual(done.wait(timeout: .now() + .milliseconds(300)), .timedOut, "適用された数が足りない間は答えない")
        memo.apply(.write(key: "a", value: "1"))
        applied.note(token: "other")  // 別の起動の数では進まない
        applied.note(token: "tok")
        XCTAssertEqual(done.wait(timeout: .now() + .milliseconds(300)), .timedOut)
        applied.note(token: "tok")
        XCTAssertEqual(done.wait(timeout: .now() + 5), .success)
        XCTAssertEqual(try result.value?.get(), ["a": ["1"]])
    }

    func testMemoWriteWaitsTooAndFailsAtTheCapWithAReason() throws {
        let memo = FakeMemo()
        let server = try makeServer(memo: memo, capSeconds: 1)
        let client = try RunLockClient.connect(path: server.socketPath, scenario: "S", machine: "m", device: "d", token: "tok")
        let started = Date()
        let failure = try XCTUnwrap(client.memoWrite(.write(key: "k", value: "v"), outsideOps: 3))
        XCTAssertGreaterThanOrEqual(Date().timeIntervalSince(started), 0.9)
        XCTAssertTrue(failure.message.contains("outside the lock"), failure.message)
        XCTAssertEqual(memo.ops, [], "待ちが尽きたら書かない")
        XCTAssertFalse(client.isBroken, "理由つきの失敗の返事であって、接続は壊れない")
    }

    func testOversizeMemoReadReplyIsAFailedReplyNotADroppedConnection() throws {
        let memo = FakeMemo()
        memo.apply(.write(key: "k", value: String(repeating: "x", count: 2000)))
        let server = try makeServer(memo: memo, maxReply: 500)
        let client = try connect(server, "A")
        guard case .failure(let error) = client.memoRead(outsideOps: 0) else { return XCTFail("must fail") }
        XCTAssertTrue(error.message.contains("too large"), error.message)
        XCTAssertFalse(client.isBroken)
        XCTAssertEqual(try take(client, ["k"]).outcome, .granted, "接続は使い続けられる")
    }

    func testUnknownPeerPidKeepsTheLocksHeldAndLogsInsteadOfReleasing() throws {
        let waiters = ExitWaiters()
        let lines = Lines()
        let server = try makeServer(waiters: waiters, lines: lines, peerPid: { _ in 0 })
        var holder: RunLockClient? = try connect(server, "Holder.scn")
        let waiting = try connect(server, "B")
        XCTAssertEqual(try take(try XCTUnwrap(holder), ["k"]).outcome, .granted)
        let id = try waiting.request(keys: ["k"]).get()
        holder = nil
        let deadline = Date().addingTimeInterval(5)
        while !lines.all.contains(where: { $0.contains("could not be identified") }), Date() < deadline { usleep(20_000) }
        XCTAssertTrue(lines.all.contains { $0.contains("Holder.scn") && $0.contains("stay held") }, "\(lines.all)")
        XCTAssertEqual(waiting.wait(id: id, timeout: .milliseconds(400)), .timedOut, "外さない(二重に持たない)")
        XCTAssertTrue(waiters.requestedPids.isEmpty)
    }

    private final class ServerBox: @unchecked Sendable { var server: RunLockServer? }

    func testLogIsCalledOutsideTheServerLock() throws {
        let box = ServerBox()
        let reentered = LockedValue(false)
        let server = try makeServer(log: { _ in
            _ = box.server?.isStopped  // サーバーの lock を取る呼び出し。lock の内側で log を呼ぶと詰まる
            reentered.value = true
        })
        box.server = server
        let a = try connect(server, "A"), b = try connect(server, "B")
        _ = try take(a, ["k"])
        let id = try b.request(keys: ["k"]).get()
        _ = b.wait(id: id, timeout: .milliseconds(100))
        b.cancel(id: id)  // 取り消しの行(持ち主の名指し)が log を呼ぶ
        let deadline = Date().addingTimeInterval(5)
        while !reentered.value, Date() < deadline { usleep(20_000) }
        XCTAssertTrue(reentered.value, "log が呼ばれて戻った(詰まっていない)")
        XCTAssertEqual(try take(try connect(server, "C"), ["other"]).outcome, .granted, "サーバーはまだ答える")
    }

    func testStopCalledFromAConnectionThreadDoesNotWaitForItself() throws {
        let box = ServerBox()
        let stopped = DispatchSemaphore(value: 0)
        let server = try makeServer(log: { line in
            if line.contains("gave up") {
                box.server?.stop()  // 読むスレッドの上から(最後の参照が外れる経路の代わり)
                stopped.signal()
            }
        })
        box.server = server
        let a = try connect(server, "A"), b = try connect(server, "B")
        _ = try take(a, ["k"])
        let id = try b.request(keys: ["k"]).get()
        _ = b.wait(id: id, timeout: .milliseconds(100))
        b.cancel(id: id)
        XCTAssertEqual(stopped.wait(timeout: .now() + 5), .success, "自分を待って詰まらない")
        server.stop()  // 外からの stop は残りを待って返る
        XCTAssertFalse(FileManager.default.fileExists(atPath: server.socketPath))
    }

    func testTheSocketFilesAreRemovedByTheExitCleanupToo() throws {
        let server = try makeServer()
        XCTAssertTrue(FileManager.default.fileExists(atPath: server.socketPath))
        RunLockServer.removeAllSocketFiles()  // `atexit` が呼ぶ関数
        XCTAssertFalse(FileManager.default.fileExists(atPath: server.socketPath))
    }

    func testClientSocketIsCloseOnExecAndAHelloCarriesTheToken() throws {
        let server = try makeServer()
        let client = try connect(server, "A")
        XCTAssertNotEqual(fcntl(client.descriptorForTesting, F_GETFD) & FD_CLOEXEC, 0)
    }

    func testListenBacklogIsLargerThanTheDefaultOf16() {
        XCTAssertEqual(RunLockServer.listenBacklog, 128)
    }

    /// 1行読んで `.acquire` のたびに `reply` を返す偽のサーバー(本物の接続の順序では起こしにくい行き違いの再現用)
    private func fakeServer(path: String, script: @escaping @Sendable (RunLockMessage, Int32) -> Bool) throws -> (Int32, Thread) {
        let listener = try UnixSocket.listen(path: path)
        let thread = Thread {
            let conn = accept(listener, nil, nil)
            let channel = RunLockLineChannel(descriptor: conn)
            while case .line(let data) = channel.readLine(timeoutMs: 3000) {
                guard let message = RunLockMessage.decode(line: data) else { break }
                if !script(message, conn) { break }
            }
            close(conn)
        }
        thread.start()
        return (listener, thread)
    }

    func testAGrantThatArrivesAfterTheClientCancelledIsReleasedAtOnce() throws {
        let path = (NSTemporaryDirectory() as NSString).appendingPathComponent("ftlock-fake-\(UUID().uuidString.prefix(6)).sock")
        let received = LockedValue<[RunLockMessage]>([])
        let (listener, _) = try fakeServer(path: path) { message, conn in
            received.withLock { $0.append(message) }
            switch message {
            case .cancel(let id):  // 取り消しが届いた後に、すれ違いの渡しを送る
                _ = RunLockLineChannel.writeAll(conn, RunLockMessage.granted(id: id).encodedLine())
            case .memoRead(let id, _):
                _ = RunLockLineChannel.writeAll(conn, RunLockMessage.memo(values: [:]).encodedLine())
                _ = id
            case .release: return false
            default: break
            }
            return true
        }
        defer { close(listener); unlink(path) }
        let client = try RunLockClient.connect(path: path, scenario: "S", machine: "m", device: "d")
        let id = try client.request(keys: ["a"]).get()
        XCTAssertEqual(client.wait(id: id, timeout: .milliseconds(100)), .timedOut)
        client.cancel(id: id)
        _ = client.memoRead(outsideOps: 0)  // 届いた渡しをここで読む
        let deadline = Date().addingTimeInterval(5)
        while !received.value.contains(.release(id: id)), Date() < deadline { usleep(20_000) }
        XCTAssertTrue(received.value.contains(.release(id: id)), "取り消し済みの要求の渡しは外す")
    }

    // MARK: 適用待ちの停止・中断・窓、kqueue の失敗、書き込みが詰まった接続

    func testStopWhileAMemoWaitIsPendingReturnsPromptlyAndTheClientGetsAReason() throws {
        let server = try makeServer(capSeconds: 60)
        let client = try RunLockClient.connect(path: server.socketPath, scenario: "S", machine: "m", device: "d", token: "tok")
        let result = LockedValue<Result<[String: [String]], RunLockError>?>(nil)
        let done = DispatchSemaphore(value: 0)
        let pendingSeen = LockedValue(false)
        Thread {
            result.value = client.memoRead(outsideOps: 3, cap: .seconds(60), onPending: { pendingSeen.value = true })
            done.signal()
        }.start()
        let deadline = Date().addingTimeInterval(5)
        while !pendingSeen.value, Date() < deadline { usleep(10_000) }
        XCTAssertTrue(pendingSeen.value, "サーバーが適用待ちに入ったと知らせる")
        let started = Date()
        let stopped = DispatchSemaphore(value: 0)
        Thread { server.stop(); stopped.signal() }.start()
        XCTAssertEqual(stopped.wait(timeout: .now() + 5), .success, "stop が適用待ちの上限(60秒)まで待たない")
        XCTAssertLessThan(Date().timeIntervalSince(started), 5)
        XCTAssertEqual(done.wait(timeout: .now() + 5), .success)
        guard case .failure? = result.value else { return XCTFail("must fail") }
    }

    func testInterruptFailsAPendingMemoWaitWithTheInterruptedReason() throws {
        let server = try makeServer(capSeconds: 60)
        let client = try RunLockClient.connect(path: server.socketPath, scenario: "S", machine: "m", device: "d", token: "tok")
        let failure = LockedValue<RunLockError?>(nil)
        let done = DispatchSemaphore(value: 0)
        let pendingSeen = LockedValue(false)
        Thread {
            failure.value = client.memoWrite(.write(key: "k", value: "v"), outsideOps: 2, cap: .seconds(60), onPending: { pendingSeen.value = true })
            done.signal()
        }.start()
        let deadline = Date().addingTimeInterval(5)
        while !pendingSeen.value, Date() < deadline { usleep(10_000) }
        server.interrupt()
        XCTAssertEqual(done.wait(timeout: .now() + 5), .success)
        XCTAssertTrue(failure.value?.message.contains(RunLockTable.interruptedReason) == true, "\(String(describing: failure.value))")
        XCTAssertTrue(failure.value?.message.contains("2 run memo write(s)") == true)
    }

    func testPendingIsNotSentWhenTheOutsideOpsAreAlreadyApplied() throws {
        let applied = RunLockAppliedOps()
        applied.note(token: "tok")
        let server = try makeServer(applied: applied)
        let client = try RunLockClient.connect(path: server.socketPath, scenario: "S", machine: "m", device: "d", token: "tok")
        let pending = LockedValue(0)
        _ = client.memoRead(outsideOps: 1, onPending: { pending.withLock { $0 += 1 } })
        XCTAssertEqual(pending.value, 0)
    }

    func testAFailingExitWaiterKeepsTheLocksHeldAndLogsInsteadOfReleasing() throws {
        let waiters = ExitWaiters(failWith: "kqueue() failed: injected")
        let lines = Lines()
        let server = try makeServer(waiters: waiters, lines: lines)
        var holder: RunLockClient? = try connect(server, "Holder.scn")
        let waiting = try connect(server, "B")
        XCTAssertEqual(try take(try XCTUnwrap(holder), ["k"]).outcome, .granted)
        let id = try waiting.request(keys: ["k"]).get()
        holder = nil
        let deadline = Date().addingTimeInterval(5)
        while !lines.all.contains(where: { $0.contains("cannot wait for the process") }), Date() < deadline { usleep(20_000) }
        XCTAssertTrue(lines.all.contains { $0.contains("Holder.scn") && $0.contains("injected") && $0.contains("stay held") }, "\(lines.all)")
        XCTAssertEqual(waiting.wait(id: id, timeout: .milliseconds(400)), .timedOut, "外さない(二重に持たない)")
    }

    func testAKeventErrorWhileWaitingIsReportedAsAnErrorNotAsAnExit() {
        let exited = LockedValue(false)
        let errors = LockedValue<[String]>([])
        // 不正な fd の kevent は即座に失敗する(待っている最中の kevent の失敗の代わり)
        RunLockServer.exitWaitLoop(queue: -1, cancelled: { false }, onExit: { exited.value = true },
                                   onError: { reason in errors.withLock { $0.append(reason) } })
        XCTAssertFalse(exited.value, "kevent の失敗を終了と読まない")
        XCTAssertEqual(errors.value.count, 1)
        XCTAssertTrue(errors.value.first?.contains("kevent failed while waiting") == true)
    }

    func testTheWaitLoopStopsWithoutCallingBackWhenCancelled() {
        let called = LockedValue(false)
        RunLockServer.exitWaitLoop(queue: -1, cancelled: { true }, onExit: { called.value = true }, onError: { _ in called.value = true })
        XCTAssertFalse(called.value)
    }

    func testStopDoesNotBlockBehindAPeerThatDoesNotReadAHugeReply() throws {
        let memo = FakeMemo()
        memo.apply(.write(key: "k", value: String(repeating: "x", count: 8_000_000)))
        let server = try makeServer(memo: memo)
        // 読まない相手: hello と memoRead を送って、返事を読まない
        let fd = try UnixSocket.connect(path: server.socketPath)
        defer { close(fd) }
        XCTAssertTrue(RunLockLineChannel.writeAll(fd, RunLockMessage.hello(scenario: "S", machine: "m", device: "d", token: "t").encodedLine()))
        XCTAssertTrue(RunLockLineChannel.writeAll(fd, RunLockMessage.memoRead(id: 1, outsideOps: 0).encodedLine()))
        usleep(500_000)  // サーバーの書き込みが詰まるのを待つ(返事は約 8 MB でソケットの緩衝を超える)
        let stopped = DispatchSemaphore(value: 0)
        Thread { server.stop(); stopped.signal() }.start()
        XCTAssertEqual(stopped.wait(timeout: .now() + 5), .success, "書き込みで詰まった接続があっても stop が返る")
    }

    // MARK: 停止・ファイル

    func testStopAnswersNothingMoreAndRemovesTheSocketFile() throws {
        let server = try makeServer()
        let path = server.socketPath
        let attributes = try FileManager.default.attributesOfItem(atPath: path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        XCTAssertLessThan(path.utf8.count, 104)
        let a = try connect(server, "A")
        let held = try take(a, ["k"])
        let b = try connect(server, "B")
        let waiting = try b.request(keys: ["k"]).get()
        server.stop()
        XCTAssertFalse(FileManager.default.fileExists(atPath: path))
        guard case .failed = b.wait(id: waiting, timeout: .seconds(5)) else { return XCTFail("EOF で失敗") }
        a.release(id: held.id)
        XCTAssertThrowsError(try RunLockClient.connect(path: path, scenario: "x", machine: "m", device: "d"))
    }

    // MARK: 待ちの報告

    func testWaitersAreReportedWithKeyAndHolderNames() throws {
        let lines = Lines()
        let server = try makeServer(lines: lines, interval: .milliseconds(50))
        let a = try connect(server, "Holder.scn"), b = try connect(server, "Waiter.scn")
        _ = try take(a, ["db"])
        _ = try b.request(keys: ["db"]).get()
        let deadline = Date().addingTimeInterval(5)
        while !lines.all.contains(where: { $0.contains("Waiter.scn") && $0.contains("\"db\"") && $0.contains("Holder.scn") }),
              Date() < deadline { usleep(20_000) }
        let line = try XCTUnwrap(lines.all.first { $0.contains("Waiter.scn") && $0.contains("has waited") })
        XCTAssertTrue(line.contains("[m / d-Holder.scn]"), line)
    }

    func testCancelOfATimedOutRequestNamesTheHolder() throws {
        let lines = Lines()
        let server = try makeServer(lines: lines)
        let a = try connect(server, "Holder.scn"), b = try connect(server, "Waiter.scn")
        _ = try take(a, ["db"])
        let id = try b.request(keys: ["db"]).get()
        XCTAssertEqual(b.wait(id: id, timeout: .milliseconds(100)), .timedOut)
        b.cancel(id: id)
        let deadline = Date().addingTimeInterval(5)
        while !lines.all.contains(where: { $0.contains("gave up") }), Date() < deadline { usleep(20_000) }
        let line = try XCTUnwrap(lines.all.first { $0.contains("gave up") })
        XCTAssertTrue(line.contains("Waiter.scn") && line.contains("Holder.scn") && line.contains("\"db\""), line)
    }

    func testPeerPidIsTheConnectingProcess() throws {
        let server = try makeServer()
        let pair = UnsafeMutablePointer<Int32>.allocate(capacity: 2)
        defer { pair.deallocate() }
        XCTAssertEqual(socketpair(AF_UNIX, SOCK_STREAM, 0, pair), 0)
        defer { close(pair[0]); close(pair[1]) }
        XCTAssertEqual(RunLockServer.peerPid(pair[0]), getpid())
        _ = server
    }

    func testKqueueWaiterFiresForAnAlreadyExitedProcessAndForAChildThatExitsLater() throws {
        // 既に終わっているプロセス
        let gone = Process()
        gone.executableURL = URL(fileURLWithPath: "/usr/bin/true")
        try gone.run()
        gone.waitUntilExit()
        let fired = DispatchSemaphore(value: 0)
        RunLockServer.kqueueExitWaiter(gone.processIdentifier, { false }, { fired.signal() }, { _ in XCTFail("no error expected") })
        XCTAssertEqual(fired.wait(timeout: .now() + 5), .success)
        // 後で終わるプロセス
        let sleeper = Process()
        sleeper.executableURL = URL(fileURLWithPath: "/bin/sleep")
        sleeper.arguments = ["0.5"]
        try sleeper.run()
        let later = DispatchSemaphore(value: 0)
        RunLockServer.kqueueExitWaiter(sleeper.processIdentifier, { false }, { later.signal() }, { _ in XCTFail("no error expected") })
        XCTAssertEqual(later.wait(timeout: .now() + .milliseconds(100)), .timedOut, "生きている間は呼ばない")
        sleeper.waitUntilExit()
        XCTAssertEqual(later.wait(timeout: .now() + 5), .success)
    }
}
