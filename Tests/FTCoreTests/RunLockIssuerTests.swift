import XCTest
@testable import FTCore

/// 発行元のロックのサーバー(RR-8.5 第2a段の step 2): backend = run メモの正本(hub)・プロセスをまたぐ「ロックの外の操作」の順序
final class RunLockIssuerTests: XCTestCase {
    private var servers: [RunLockServer] = []

    override func tearDown() {
        servers.forEach { $0.stop() }
        servers = []
        super.tearDown()
    }

    private final class Sent: @unchecked Sendable {
        private let lock = NSLock()
        private var items: [(RunMemoHub.Child, [String])] = []
        func add(_ child: RunMemoHub.Child, _ lines: [String]) { lock.withLock { items.append((child, lines)) } }
        var all: [(RunMemoHub.Child, [String])] { lock.withLock { items } }
    }

    private func memoLines(src: String, lid: Int, op: RunMemoOp) -> [String] {
        let pieces = RunMemoWire.pieces(for: op)
        return pieces.enumerated().map {
            WorkQueueProtocol.encode(WorkQueueProtocol.MemoPiece(src: src, lid: lid, seq: nil, i: $0.offset, n: pieces.count, d: $0.element))
        }
    }

    // MARK: hub の backend

    func testAWriteThroughTheServerIsCommittedInTheHubAndBroadcastToJoinedChildren() throws {
        let sent = Sent()
        let hub = RunMemoHub(mode: .startOnHello, send: { child, lines in sent.add(child, lines) })
        let a = RunMemoHub.Child(target: "", entry: 0), b = RunMemoHub.Child(target: "", entry: 1)
        hub.receive(line: WorkQueueProtocol.encode(WorkQueueProtocol.MemoHello(src: "aaaa0000")), from: a)
        hub.receive(line: WorkQueueProtocol.encode(WorkQueueProtocol.MemoHello(src: "bbbb0000")), from: b)
        let before = sent.all.count
        let backend = RunMemoHubLockBackend(hub: hub)
        let server = try RunLockServer(memoFor: { _ in backend }, log: { _ in })
        servers.append(server)
        let client = try RunLockClient.connect(path: server.socketPath, scenario: "S", machine: "m", device: "d", token: "t")
        XCTAssertNil(client.memoWrite(.write(key: "n", value: "1"), outsideOps: 0))
        XCTAssertEqual(hub.finalValues(), ["n": ["1"]], "確定の返事の前に正本へ入っている")
        let broadcast = sent.all.dropFirst(before)
        XCTAssertEqual(Set(broadcast.map { $0.0 }), [a, b], "起動を知らせた全部の子へ配る")
        for (_, lines) in broadcast {
            let piece = try XCTUnwrap(WorkQueueProtocol.decodeMemoPiece(try XCTUnwrap(lines.first)))
            XCTAssertEqual(piece.seq, 1, "hub の通し番号を振る")
        }
        XCTAssertNil(client.memoWrite(.write(key: "n", value: "2"), outsideOps: 0))
        XCTAssertEqual(try client.memoRead(outsideOps: 0).get(), ["n": ["1", "2"]])
    }

    func testAReadThroughTheServerSeesWritesThatChildrenPublishedToTheHub() throws {
        let hub = RunMemoHub(mode: .startOnHello, send: { _, _ in })
        let child = RunMemoHub.Child(target: "", entry: 0)
        hub.receive(line: WorkQueueProtocol.encode(WorkQueueProtocol.MemoHello(src: "aaaa0000")), from: child)
        for line in memoLines(src: "aaaa0000", lid: 1, op: .write(key: "k", value: "from-child")) { hub.receive(line: line, from: child) }
        let server = try RunLockServer(memoFor: { _ in RunMemoHubLockBackend(hub: hub) }, log: { _ in })
        servers.append(server)
        let client = try RunLockClient.connect(path: server.socketPath, scenario: "S", machine: "m", device: "d", token: "t")
        XCTAssertEqual(try client.memoRead(outsideOps: 0).get(), ["k": ["from-child"]])
    }

    // MARK: プロセスをまたぐ「ロックの外の操作」の順序

    /// 子(発行元の hub とつながったプロセス)の側の部品一式。`delayMs` = 子 → hub の行の遅れ・`lose` = 行を失う
    private final class ChildSide: @unchecked Sendable {
        let hub: RunMemoHub
        let store: RunMemoStore
        let session: RunDeviceSession
        let link: RunMemoLink
        init(hub: RunMemoHub, delayMs: UInt32, lose: Bool) {
            self.hub = hub
            let child = RunMemoHub.Child(target: "", entry: 0)
            let box = LinkBox()
            let link = RunMemoLink(send: { text in
                guard !lose else { return }
                DispatchQueue.global().async {
                    usleep(delayMs * 1000)
                    for line in text.split(separator: "\n") { hub.receive(line: String(line), from: child) }
                }
            })
            self.link = link
            box.link = link
            store = RunMemoStore(link: link)
            session = RunDeviceSession(shared: RunSharedSession(runMemo: store))
        }
        final class LinkBox: @unchecked Sendable { var link: RunMemoLink? }
    }

    private func setUp(delayMs: UInt32, lose: Bool = false, capSeconds: Int = 5)
        throws -> (child: ChildSide, hub: RunMemoHub, client: RunLockClient) {
        // hub → 子の行は子の link へ戻す(stdin の代わり)。子ができてから繋ぐために箱を使う
        let childBox = LockedValue<ChildSide?>(nil)
        let hub = RunMemoHub(mode: .startOnHello, send: { _, lines in
            for line in lines { childBox.value?.link.receive(line: line) }
        })
        let child = ChildSide(hub: hub, delayMs: delayMs, lose: lose)
        childBox.value = child
        child.link.hello()
        let issuerApplied = RunLockAppliedOps()
        let server = try RunLockServer(memoFor: { _ in RunMemoHubLockBackend(hub: hub) }, applied: issuerApplied,
                                       waitCapSeconds: { capSeconds }, log: { _ in })
        servers.append(server)
        // 子の host: 発行元のサーバーへつなぐ形(`--lock-socket` を受けた親とつながった子)
        child.session.shared.locks.configure(usesLocks: true, waitCapSeconds: capSeconds, linkedToParent: true,
                                      issuerSocket: server.socketPath) { _ in }
        guard case .socket(let path) = child.session.shared.locks.access() else { throw XCTSkip("socket access expected") }
        XCTAssertEqual(path, server.socketPath, "子は発行元のソケットを使う(自前のサーバーを起こさない)")
        let client = try RunLockClient.connect(path: path, scenario: "S", machine: "m", device: "d", token: "tok")
        return (child, hub, client)
    }

    private func writeEvent(_ key: String, _ value: String) -> ScenarioEvent {
        var event = ScenarioEvent(kind: "runMemoWrite")
        event.memoKey = key
        event.memoValue = value
        return event
    }

    func testTheIssuerWaitsUntilTheHubHasTheChildsOutsideWriteBeforeAnsweringARead() throws {
        let (child, hub, client) = try setUp(delayMs: 400)
        // シナリオのロックの外の書き込み → 子の ScenarioHost が適用(子のストアへ入り、発行元へは遅れて届く)
        XCTAssertTrue(child.session.apply(writeEvent("token", "abc"), className: "C", lockOwnerToken: "tok"))
        XCTAssertEqual(hub.finalValues(), [:], "発行元にはまだ届いていない")
        let started = Date()
        let values = try client.memoRead(outsideOps: 1).get()
        XCTAssertEqual(values, ["token": ["abc"]], "発行元の正本に入るまで読みを待つ")
        XCTAssertGreaterThanOrEqual(Date().timeIntervalSince(started), 0.3)
    }

    func testAnInsideWriteIsOrderedAfterTheOutsideClearAcrossProcesses() throws {
        let (child, hub, client) = try setUp(delayMs: 300)
        XCTAssertTrue(child.session.apply(ScenarioEvent(kind: "runMemoClear"), className: "C", lockOwnerToken: "tok"))
        XCTAssertNil(client.memoWrite(.write(key: "n", value: "1"), outsideOps: 1))
        Thread.sleep(forTimeInterval: 0.6)
        XCTAssertEqual(hub.finalValues(), ["n": ["1"]], "外の clear が先に確定してから中の書き込みが入る")
    }

    func testALostLineMakesTheReadFailAtTheCapWithAReasonInsteadOfHanging() throws {
        let (child, _, client) = try setUp(delayMs: 0, lose: true, capSeconds: 1)
        XCTAssertTrue(child.session.apply(writeEvent("token", "abc"), className: "C", lockOwnerToken: "tok"))
        let started = Date()
        guard case .failure(let error) = client.memoRead(outsideOps: 1) else { return XCTFail("must fail") }
        XCTAssertGreaterThanOrEqual(Date().timeIntervalSince(started), 0.9)
        XCTAssertLessThan(Date().timeIntervalSince(started), 5)
        XCTAssertTrue(error.message.contains("outside the lock"), error.message)
    }

    func testAnOutsideWriteIsNotCountedAsAppliedBeforeTheHubConfirmsIt() throws {
        // 発行元とつながったストア: 確定の戻りが無い間は数えない・戻ったら数える(自前のサーバーの host で直接観測する)
        let sent = LockedValue<[String]>([])
        let link = RunMemoLink(send: { text in sent.withLock { $0.append(text) } })
        let store = RunMemoStore(link: link)
        let session = RunDeviceSession(shared: RunSharedSession(runMemo: store))
        XCTAssertTrue(session.apply(writeEvent("k", "v"), className: "C", lockOwnerToken: "tok"))
        XCTAssertFalse(session.shared.locks.appliedOps.count(token: "tok") >= 1, "発行元に確定するまで数えない")
        // 発行元が確定して配り返した行(自分の印・書き込み番号 1)
        let published = try XCTUnwrap(sent.value.first)
        let piece = try XCTUnwrap(WorkQueueProtocol.decodeMemoPiece(try XCTUnwrap(published.split(separator: "\n").first.map(String.init))))
        for line in memoLines(src: link.source, lid: piece.lid, op: .write(key: "k", value: "v")) {
            let raw = try XCTUnwrap(WorkQueueProtocol.decodeMemoPiece(line))
            link.receive(line: WorkQueueProtocol.encode(
                WorkQueueProtocol.MemoPiece(src: raw.src, lid: raw.lid, seq: 1, i: raw.i, n: raw.n, d: raw.d)))
        }
        XCTAssertTrue(session.shared.locks.appliedOps.count(token: "tok") >= 1)
    }

    func testWithoutALinkTheWriteCountsAsAppliedAtOnce() {
        let session = RunDeviceSession(shared: RunSharedSession(runMemo: RunMemoStore()))
        XCTAssertTrue(session.apply(writeEvent("k", "v"), className: "C", lockOwnerToken: "tok"))
        XCTAssertTrue(session.shared.locks.appliedOps.count(token: "tok") >= 1)
    }

    func testLinkedChildWithoutAnIssuerSocketRefusesWithAReasonThatNamesTheCauses() {
        let host = RunLockHost(mode: .ownServer)
        host.configure(usesLocks: true, waitCapSeconds: 1, linkedToParent: true, issuerSocket: nil) { _ in }
        XCTAssertEqual(host.access(), .refuse(RunLockHost.linkedChildRefusal))
        XCTAssertTrue(RunLockHost.linkedChildRefusal.contains("did not hand over a run lock socket"))
        host.configure(usesLocks: true, waitCapSeconds: 1, linkedToParent: true, issuerSocket: "/tmp/x.sock") { _ in }
        XCTAssertEqual(host.access(), .socket("/tmp/x.sock"), "--lock-socket を受けた子はそのソケットを使う")
    }

    func testIssuerStartsOnlyWhenTheSourceUsesLocks() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("lockissuer-\(UUID().uuidString)")
        let project = TestProject(name: "P", rootURL: root)
        try FileManager.default.createDirectory(at: project.scenariosDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let hub = RunMemoHub(mode: .startOnHello, send: { _, _ in })
        XCTAssertNil(RunLockIssuer.startIfUsed(project: project, waitCapSeconds: 5, hub: hub, log: { _ in }))
        try "withExclusiveLock(\"a\") {}".write(to: project.scenariosDir.appendingPathComponent("S.swift"), atomically: true, encoding: .utf8)
        let issuer = try XCTUnwrap(RunLockIssuer.startIfUsed(project: project, waitCapSeconds: 5, hub: hub, log: { _ in }))
        XCTAssertTrue(FileManager.default.fileExists(atPath: issuer.socketPath))
        issuer.stop()
        XCTAssertFalse(FileManager.default.fileExists(atPath: issuer.socketPath))
    }

    func testMCPHostsAreSeparatePerProject() {
        let one = RunLockHost.mcpShared(project: "P1-test"), two = RunLockHost.mcpShared(project: "P2-test")
        XCTAssertFalse(one === two, "別のプロジェクトのキーが同じ表に載らない")
        XCTAssertTrue(one === RunLockHost.mcpShared(project: "P1-test"))
    }

    /// 大きすぎて発行元へ上げない外の書き込みは、確定が来ないので書いた時点で適用済みと数える(1台の run と結果が割れない)
    func testAnOversizeOutsideWriteThatStaysLocalIsCountedAsAppliedAtOnce() throws {
        let warned = LockedValue<[String]>([])
        let link = RunMemoLink(send: { _ in XCTFail("大きすぎる書き込みは上げない") }, warn: { line in warned.withLock { $0.append(line) } })
        let session = RunDeviceSession(shared: RunSharedSession(runMemo: RunMemoStore(link: link)))
        var event = ScenarioEvent(kind: "runMemoWrite")
        event.memoKey = "big"
        event.memoValue = String(repeating: "x", count: RunMemoWire.maxPieces * RunMemoWire.pieceCharacters)
        XCTAssertTrue(session.apply(event, className: "C", lockOwnerToken: "tok"))
        XCTAssertEqual(warned.value.count, 1)
        XCTAssertTrue(session.shared.locks.appliedOps.count(token: "tok") >= 1)
    }

    /// 同じプロセスのストアを複数のセッションが使っても、確定の観測を奪い合わない
    func testTwoSessionsOnTheSameLinkedStoreEachObserveTheirOwnConfirmations() throws {
        let sent = LockedValue<[String]>([])
        let link = RunMemoLink(send: { text in sent.withLock { $0.append(text) } })
        let store = RunMemoStore(link: link)
        let one = RunDeviceSession(shared: RunSharedSession(runMemo: store))
        let two = RunDeviceSession(shared: RunSharedSession(runMemo: store))
        XCTAssertTrue(one.apply(writeEvent("a", "1"), className: "C", lockOwnerToken: "one"))
        XCTAssertTrue(two.apply(writeEvent("b", "2"), className: "C", lockOwnerToken: "two"))
        func confirm(_ text: String, seq: Int, value: RunMemoOp) throws {
            let first = try XCTUnwrap(text.split(separator: "\n").first.map(String.init))
            let piece = try XCTUnwrap(WorkQueueProtocol.decodeMemoPiece(first))
            for line in memoLines(src: link.source, lid: piece.lid, op: value) {
                let raw = try XCTUnwrap(WorkQueueProtocol.decodeMemoPiece(line))
                link.receive(line: WorkQueueProtocol.encode(WorkQueueProtocol.MemoPiece(src: raw.src, lid: raw.lid, seq: seq, i: raw.i, n: raw.n, d: raw.d)))
            }
        }
        try confirm(sent.value[1], seq: 1, value: .write(key: "b", value: "2"))
        XCTAssertTrue(two.shared.locks.appliedOps.count(token: "two") >= 1)
        XCTAssertFalse(one.shared.locks.appliedOps.count(token: "one") >= 1, "他のセッションの確定で数えない")
        try confirm(sent.value[0], seq: 2, value: .write(key: "a", value: "1"))
        XCTAssertTrue(one.shared.locks.appliedOps.count(token: "one") >= 1)
    }

    /// 発行元へ送れない間は控えて再送する(つなぐのが一時的に失敗しても適用の知らせを落とさない)
    func testTheNotifierKeepsRetryingUntilTheIssuerSocketComesUp() throws {
        let path = (NSTemporaryDirectory() as NSString).appendingPathComponent("ftlock-late-\(UUID().uuidString.prefix(6)).sock")
        let received = LockedValue<[String]>([])
        let host = RunLockHost(mode: .ownServer)
        host.configure(usesLocks: true, waitCapSeconds: 10, linkedToParent: true, issuerSocket: path) { _ in }
        host.noteOutsideApplied(token: "tok")  // まだ待ち受けが無い: 控える
        Thread {
            usleep(400_000)
            guard let listener = try? UnixSocket.listen(path: path) else { return }
            let conn = accept(listener, nil, nil)
            let channel = RunLockLineChannel(descriptor: conn)
            while case .line(let data) = channel.readLine(timeoutMs: 3000) {
                if case .outsideApplied(let token)? = RunLockMessage.decode(line: data) { received.withLock { $0.append(token) } }
            }
            close(conn)
            close(listener)
        }.start()
        let deadline = Date().addingTimeInterval(8)
        while received.value.isEmpty, Date() < deadline { usleep(20_000) }
        XCTAssertEqual(received.value, ["tok"])
        unlink(path)
    }

    func testTheNotifierGivesUpAtTheCapWithOneLogLineWhenTheIssuerNeverComesUp() throws {
        let path = (NSTemporaryDirectory() as NSString).appendingPathComponent("ftlock-never-\(UUID().uuidString.prefix(6)).sock")
        let lines = LockedValue<[String]>([])
        let host = RunLockHost(mode: .ownServer)
        host.configure(usesLocks: true, waitCapSeconds: 1, linkedToParent: true, issuerSocket: path) { line in lines.withLock { $0.append(line) } }
        host.noteOutsideApplied(token: "tok")
        let deadline = Date().addingTimeInterval(8)
        while lines.value.isEmpty, Date() < deadline { usleep(50_000) }
        XCTAssertEqual(lines.value.count, 1)
        XCTAssertTrue(lines.value.first?.contains("gave up") == true, "\(lines.value)")
    }

    func testReapedScenarioIsReportedToTheOwnServerAndToTheIssuerOverTheSocket() throws {
        // 自前のサーバー: 見届けたら持ち分を外す
        let host = RunLockHost(mode: .ownServer)
        guard case .socket(let path) = host.access() else { return XCTFail("socket expected") }
        defer { host.stop() }
        var holder: RunLockClient? = try RunLockClient.connect(path: path, scenario: "H", machine: "m", device: "d", token: "T")
        let id = try XCTUnwrap(holder).request(keys: ["k"]).get()
        XCTAssertEqual(try XCTUnwrap(holder).wait(id: id, timeout: .seconds(5)), .granted)
        let waiter = try RunLockClient.connect(path: path, scenario: "W", machine: "m", device: "d", token: "W")
        let waiting = try waiter.request(keys: ["k"]).get()
        XCTAssertEqual(waiter.wait(id: waiting, timeout: .milliseconds(200)), .timedOut)
        host.noteScenarioEnded(token: "T")
        holder = nil  // 接続が閉じたとき(見届け済みの印)に持ち分を外す
        XCTAssertEqual(waiter.wait(id: waiting, timeout: .seconds(5)), .granted)

        // 発行元へつなぐ子: ソケットで知らせる
        let fakePath = (NSTemporaryDirectory() as NSString).appendingPathComponent("ftlock-end-\(UUID().uuidString.prefix(6)).sock")
        let received = LockedValue<[RunLockMessage]>([])
        let listener = try UnixSocket.listen(path: fakePath)
        defer { close(listener); unlink(fakePath) }
        Thread {
            let conn = accept(listener, nil, nil)
            let channel = RunLockLineChannel(descriptor: conn)
            while case .line(let data) = channel.readLine(timeoutMs: 3000) {
                if let message = RunLockMessage.decode(line: data) { received.withLock { $0.append(message) } }
            }
            close(conn)
        }.start()
        let child = RunLockHost(mode: .ownServer)
        child.configure(usesLocks: true, waitCapSeconds: 10, linkedToParent: true, issuerSocket: fakePath) { _ in }
        child.noteScenarioEnded(token: "T9")
        let deadline = Date().addingTimeInterval(5)
        while !received.value.contains(.scenarioEnded(token: "T9")), Date() < deadline { usleep(20_000) }
        XCTAssertTrue(received.value.contains(.scenarioEnded(token: "T9")))
    }

    /// ロックの中の書き込みは、書いたマシンの次のシナリオの写しに、発行元の配りの戻りを待たずに入る(1台の run と同じ見え方)。
    /// 後から戻る同じ通し番号の配りは重複として無視される
    func testAnInsideLockWriteIsVisibleToTheNextScenarioBeforeTheBroadcastComesBackAndIsNotDuplicatedAfter() throws {
        let link = RunMemoLink(send: { _ in })
        let store = RunMemoStore(link: link)
        let session = RunDeviceSession(shared: RunSharedSession(runMemo: store))
        var event = ScenarioEvent(kind: "runMemoCommitted")
        event.memoSeq = 5
        event.memoKey = "count"
        event.memoValue = "1"
        XCTAssertTrue(session.apply(event, className: "C", lockOwnerToken: "tok"))
        XCTAssertEqual(session.shared.runMemoSnapshot(), ["count": ["1"]], "配りの戻りの前に、次のシナリオへ渡す写しに入っている")
        // 発行元の配り(同じ通し番号・src は run-hook)が後から届く
        for line in memoLines(src: "run-hook", lid: 1, op: .write(key: "count", value: "1")) {
            let raw = try XCTUnwrap(WorkQueueProtocol.decodeMemoPiece(line))
            link.receive(line: WorkQueueProtocol.encode(WorkQueueProtocol.MemoPiece(src: raw.src, lid: raw.lid, seq: 5, i: raw.i, n: raw.n, d: raw.d)))
        }
        XCTAssertEqual(session.shared.runMemoSnapshot(), ["count": ["1"]], "同じ通し番号の配りは重複として足さない")
        // clear も同じ
        var clear = ScenarioEvent(kind: "runMemoCommitted")
        clear.memoSeq = 6
        XCTAssertTrue(session.apply(clear, className: "C", lockOwnerToken: "tok"))
        XCTAssertEqual(session.shared.runMemoSnapshot(), [:])
        XCTAssertFalse(session.shared.locks.appliedOps.count(token: "tok") >= 1, "ロックの外の書き込みの数には数えない")
    }

    func testTheHubBackendReturnsTheSequenceNumberItAssigned() {
        let hub = RunMemoHub(mode: .startOnHello, send: { _, _ in })
        let backend = RunMemoHubLockBackend(hub: hub)
        XCTAssertEqual(backend.applyCommitted(.write(key: "a", value: "1")), 1)
        XCTAssertEqual(backend.applyCommitted(.write(key: "a", value: "2")), 2)
        XCTAssertNil(RunMemoStore().applyCommitted(.write(key: "a", value: "1")), "正本が無い構成は通し番号が無い")
    }
}
