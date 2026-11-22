import XCTest
@testable import FTCore

/// ロックの待ちの時間(RR-8.5 2b step 2): 待ちの和集合・中継役の期限の延長・結果 JSON の `lockWaitMs`・所要の見積りからの除外
final class RunLockWaitTimeTests: XCTestCase {
    // MARK: 和集合

    func testOverlappingWaitsCountOnceAndGapsAreNotCounted() {
        var union = RunLockWaitUnion()
        union.begin(nowMs: 100)   // A が待ち始める
        union.begin(nowMs: 150)   // B が重なって待ち始める
        union.end(nowMs: 300)     // A が終わる(B はまだ待っている)
        XCTAssertEqual(union.totalMs(nowMs: 300), 200, "重なっている間は1つぶん(100〜300)")
        union.end(nowMs: 400)     // B も終わる
        XCTAssertEqual(union.totalMs(nowMs: 400), 300, "100〜400 の壁時計(足し算なら 200 + 250 = 450 になる)")
        XCTAssertEqual(union.totalMs(nowMs: 1_000), 300, "誰も待っていない間は増えない")
        union.begin(nowMs: 1_000)
        XCTAssertEqual(union.totalMs(nowMs: 1_050), 350, "進行中の待ちは今までの分を含む")
    }

    func testEndWithoutBeginIsIgnored() {
        var union = RunLockWaitUnion()
        union.end(nowMs: 10)
        XCTAssertEqual(union.totalMs(nowMs: 50), 0)
        union.begin(nowMs: 60)
        union.end(nowMs: 70)
        union.end(nowMs: 80)
        XCTAssertEqual(union.totalMs(nowMs: 100), 10)
    }

    // MARK: 延長の判断

    func testExtensionIsTheDifferenceSinceTheLastCheckCappedAtTheTotalBound() {
        XCTAssertEqual(RemoteTimeoutExtension.additionalMs(waitedMs: 5_000, extendedMs: 0, capMs: 100_000), 5_000)
        XCTAssertEqual(RemoteTimeoutExtension.additionalMs(waitedMs: 8_000, extendedMs: 5_000, capMs: 100_000), 3_000, "前回までの分を引く")
        XCTAssertEqual(RemoteTimeoutExtension.additionalMs(waitedMs: 8_000, extendedMs: 8_000, capMs: 100_000), 0)
        XCTAssertEqual(RemoteTimeoutExtension.additionalMs(waitedMs: 900_000, extendedMs: 90_000, capMs: 100_000), 10_000, "合計は上限まで")
        XCTAssertEqual(RemoteTimeoutExtension.additionalMs(waitedMs: 900_000, extendedMs: 100_000, capMs: 100_000), 0, "上限に達したら延ばさない")
        XCTAssertEqual(RemoteTimeoutExtension.additionalMs(waitedMs: -5, extendedMs: 0, capMs: 100), 0)
        XCTAssertEqual(RemoteTimeoutExtension.additionalMs(waitedMs: 50, extendedMs: 0, capMs: -1), 0)
    }

    // MARK: 結果 JSON

    private func record(durationMs: Int, lockWaitMs: Int?, scenario: String = "A.S1", host: String = "h") -> ScenarioRunRecord {
        ScenarioRunRecord(scenarioID: scenario, platform: "ios", host: host, passed: true, startedAt: "2026-11-21T00:00:00Z",
                          durationMs: durationMs, steps: StepCountsRecord(), lockWaitMs: lockWaitMs)
    }

    /// 欄が無いこと自体が意味を持つ省略可の欄(DR-75): 古い記録・ロックを使わなかった記録は欄が無く、これまでどおり読めて見積りも変わらない
    func testRecordWithoutLockWaitMsDecodesAndEstimatesAsBefore() throws {
        let json = """
        {"schemaVersion":1,"runID":"r","scenarioID":"Foo.a","platform":"ios","host":"m",
         "passed":true,"startedAt":"2026-01-01T00:00:00Z","durationMs":7000,"scenes":[],
         "steps":{"total":1,"passed":1,"failed":0,"skipped":0,"healed":0,"passedViaFallback":0}}
        """
        let old = try JSONDecoder().decode(ScenarioRunRecord.self, from: Data(json.utf8))
        XCTAssertNil(old.lockWaitMs)
        XCTAssertEqual(old.estimateDurationMs, 7_000, "欄が無ければ引かない(従来と同じ)")
        XCTAssertEqual(LPTScheduler.durations(from: [old]).first?.medianMs, 7_000)
        // 書くのは 0 より大きいときだけ
        let waited = record(durationMs: 5_000, lockWaitMs: 1_234)
        XCTAssertEqual(try JSONDecoder().decode(ScenarioRunRecord.self, from: JSONEncoder().encode(waited)).lockWaitMs, 1_234)
        let none = try JSONSerialization.jsonObject(with: JSONEncoder().encode(record(durationMs: 1, lockWaitMs: nil))) as? [String: Any]
        XCTAssertNil(none?["lockWaitMs"], "待っていなければ欄ごと省く")
    }

    func testTheBuilderFoldsTheChildsLockWaitFromScenarioFinishedAndLeavesItAbsentWhenNoneWasReported() {
        func build(_ wait: Int?) -> ScenarioRunRecord {
            var builder = ScenarioRecordBuilder(scenarioID: "A.S1", variant: nil, platform: "ios", title: nil, worker: nil, mode: nil)
            var finished = ScenarioEvent(kind: "scenarioFinished")
            finished.passed = true
            finished.lockWaitMs = wait
            builder.consume(finished)
            return builder.build(passed: true, timedOut: false, startedAt: Date(), durationMs: 10_000, packageRoot: nil)
        }
        XCTAssertEqual(build(4_321).lockWaitMs, 4_321)
        XCTAssertNil(build(nil).lockWaitMs, "ロックを使わなかった・待たなかったシナリオは欄ごと無い")
    }

    func testEstimateDurationSubtractsTheLockWaitAndNeverDropsToZero() {
        XCTAssertEqual(record(durationMs: 10_000, lockWaitMs: 4_000).estimateDurationMs, 6_000)
        XCTAssertEqual(record(durationMs: 3_000, lockWaitMs: 5_000).estimateDurationMs, 1, "待ちが所要を超えても 0 にしない")
        XCTAssertEqual(record(durationMs: 3_000, lockWaitMs: 0).estimateDurationMs, 3_000)
    }

    // MARK: LPT・動的な割り振り・フリート分割の見積り

    func testEveryEstimateUsesTheDurationWithoutTheLockWait() {
        let records = [
            record(durationMs: 10_000, lockWaitMs: 7_000, scenario: "A.S1"),
            record(durationMs: 10_000, lockWaitMs: 7_000, scenario: "A.S1"),
            record(durationMs: 10_000, lockWaitMs: 7_000, scenario: "A.S1"),
        ]
        let durations = LPTScheduler.durations(from: records)
        XCTAssertEqual(durations.first?.medianMs, 3_000, "LPT の並べ替え・動的な割り振り・残り時間の見積りが読む中央値からロックの待ちを引く")
        XCTAssertEqual(LPTScheduler.machineDurations(from: records).first?.medianMs, 3_000, "フリート分割の見積りも同じ")
        // 待ちが大きいシナリオが「長いシナリオ」として先頭に来ない
        let waitHeavy = record(durationMs: 100_000, lockWaitMs: 99_000, scenario: "A.Wait")
        let plain = record(durationMs: 20_000, lockWaitMs: 0, scenario: "A.Plain")
        let ordered = LPTScheduler.durations(from: [waitHeavy, plain]).sorted { $0.medianMs > $1.medianMs }.map(\.scenarioID)
        XCTAssertEqual(ordered, ["A.Plain", "A.Wait"])
    }

    // MARK: シナリオ側の合計

    func testOnlyQueuedWaitsAreCountedInTheScenariosTotal() throws {
        final class Null: RunLockMemoBackend, @unchecked Sendable {
            func snapshot() -> [String: [String]] { [:] }
            func apply(_ op: RunMemoOp) {}
        }
        let server = try RunLockServer(memoFor: { _ in Null() }, log: { _ in })
        defer { server.stop() }
        let holder = try RunLockClient.connect(path: server.socketPath, scenario: "H", machine: "m", device: "d")
        let state = RunLockScenarioState()
        state.access = .socket(server.socketPath)
        state.waitCapSeconds = 30
        guard case .success(let free) = state.enter(keys: ["free"], waitSeconds: nil) else { return XCTFail("free") }
        state.leave(free)
        XCTAssertEqual(state.totalWaitedMs, 0, "すぐ渡された呼び出しは 0")
        let heldID = try holder.request(keys: ["busy"]).get()
        XCTAssertEqual(holder.wait(id: heldID, timeout: .seconds(5)), .granted)
        Thread { usleep(300_000); holder.release(id: heldID) }.start()
        guard case .success(let waited) = state.enter(keys: ["busy"], waitSeconds: nil) else { return XCTFail("busy") }
        state.leave(waited)
        XCTAssertGreaterThanOrEqual(state.totalWaitedMs, 250)
        XCTAssertLessThan(state.totalWaitedMs, 5_000)
    }

    // MARK: サーバー: 和集合を数えて制御用の接続で答える

    private final class Null: RunLockMemoBackend, @unchecked Sendable {
        func snapshot() -> [String: [String]] { [:] }
        func apply(_ op: RunMemoOp) {}
    }

    /// 重なった2つの待ちは1つぶん(合計なら約 1500ms・和集合なら約 800ms)。余裕を大きく取る
    func testTheServerCountsOverlappingWaitsOnceNotAsASum() throws {
        let server = try RunLockServer(memoFor: { _ in Null() }, log: { _ in })
        defer { server.stop() }
        let first = try server.openRemoteListener(machine: "M1")
        let second = try server.openRemoteListener(machine: "M1")
        let local = try RunLockClient.connect(path: server.socketPath, scenario: "L", machine: "m", device: "d")
        for key in ["k1", "k2"] {
            let id = try local.request(keys: [key]).get()
            XCTAssertEqual(local.wait(id: id, timeout: .seconds(5)), .granted)
        }
        let control = try RunLockControl.connect(path: server.socketPath)
        XCTAssertEqual(control.waitedMs(listener: first), 0)
        let a = try RunLockClient.connect(path: first, scenario: "A", machine: "m", device: "d")
        let b = try RunLockClient.connect(path: first, scenario: "B", machine: "m", device: "d")
        _ = try a.request(keys: ["k1"]).get()
        usleep(100_000)
        _ = try b.request(keys: ["k2"]).get()
        usleep(700_000)
        let waited = try XCTUnwrap(control.waitedMs(listener: first))
        XCTAssertGreaterThanOrEqual(waited, 700)
        XCTAssertLessThan(waited, 1_100, "合計(約 1500ms)ではなく和集合(約 800ms)")
        XCTAssertEqual(control.waitedMs(listener: second), 0, "別のディスパッチの待ちは数えない")
    }

    /// 待ちが終わったら(渡し・取り消し・接続の終わり)累計は増えない
    private func assertTotalStopsGrowing(ending: (inout RunLockClient?, Int, RunLockClient) throws -> Void,
                                         file: StaticString = #filePath, line: UInt = #line) throws {
        let server = try RunLockServer(memoFor: { _ in Null() }, log: { _ in })
        defer { server.stop() }
        let listener = try server.openRemoteListener(machine: "M1")
        let holder = try RunLockClient.connect(path: server.socketPath, scenario: "H", machine: "m", device: "d")
        let heldID = try holder.request(keys: ["k"]).get()
        XCTAssertEqual(holder.wait(id: heldID, timeout: .seconds(5)), .granted)
        let control = try RunLockControl.connect(path: server.socketPath)
        var waiter: RunLockClient? = try RunLockClient.connect(path: listener, scenario: "W", machine: "m", device: "d")
        let id = try XCTUnwrap(waiter).request(keys: ["k"]).get()
        usleep(300_000)
        let during = try XCTUnwrap(control.waitedMs(listener: listener))
        usleep(300_000)
        XCTAssertGreaterThan(try XCTUnwrap(control.waitedMs(listener: listener)), during, "待っている間は増える", file: file, line: line)
        try ending(&waiter, id, holder)
        usleep(200_000)
        let after = try XCTUnwrap(control.waitedMs(listener: listener))
        usleep(500_000)
        XCTAssertEqual(try XCTUnwrap(control.waitedMs(listener: listener)), after, accuracy: 30, "終わった後は増えない", file: file, line: line)
        XCTAssertGreaterThanOrEqual(after, 550, file: file, line: line)
        _ = holder
    }

    func testTheTotalStopsGrowingAfterTheGrant() throws {
        try assertTotalStopsGrowing { _, _, holder in
            // 持ち主が放す = 待っていた要求に渡る
            holder.release(id: 1)
        }
    }

    func testTheTotalStopsGrowingAfterTheCancel() throws {
        try assertTotalStopsGrowing { waiter, id, _ in waiter?.cancel(id: id) }
    }

    func testTheTotalStopsGrowingAfterTheWaitersConnectionCloses() throws {
        try assertTotalStopsGrowing { waiter, _, _ in waiter = nil }  // 参照を落として接続を閉じる
    }

    /// リモートの待ち受けの接続からの `waitedQuery` は読まず、返事も送らない(中継役は手元のプロセス)
    func testWaitedQueryFromARemoteListenerGetsNoReply() throws {
        let server = try RunLockServer(memoFor: { _ in Null() }, log: { _ in })
        defer { server.stop() }
        let remote = try server.openRemoteListener(machine: "M1")
        let fd = try UnixSocket.connect(path: remote)
        defer { close(fd) }
        XCTAssertTrue(RunLockLineChannel.writeAll(fd, RunLockMessage.hello(scenario: "Liar", machine: "m", device: "d", token: "").encodedLine()))
        XCTAssertTrue(RunLockLineChannel.writeAll(fd, RunLockMessage.waitedQuery(listener: remote).encodedLine()))
        let channel = RunLockLineChannel(descriptor: fd)
        var sawWaited = false
        let deadline = Date().addingTimeInterval(0.6)
        while Date() < deadline {
            if case .line(let data) = channel.readLine(timeoutMs: 100), case .waited? = RunLockMessage.decode(line: data) { sawWaited = true }
        }
        XCTAssertFalse(sawWaited, "リモートの出どころには waited を返さない")
        // 手元の待ち受けなら返る(上の無返事が「応答しない」ではなく出どころの判定であること)
        let local = try UnixSocket.connect(path: server.socketPath)
        defer { close(local) }
        XCTAssertTrue(RunLockLineChannel.writeAll(local, RunLockMessage.waitedQuery(listener: remote).encodedLine()))
        guard case .line(let data) = RunLockLineChannel(descriptor: local).readLine(timeoutMs: 3_000),
              case .waited? = RunLockMessage.decode(line: data) else { return XCTFail("手元の待ち受けには返す") }
    }

    /// 重複した要求(同じ接続・同じ番号)で待ちを二重に数えない・閉じた待ち受けの累計は待ちが尽きたら捨てる
    func testDuplicateRequestDoesNotLeaveTheScopeWaitingAndAClosedListenersTotalIsDropped() throws {
        let server = try RunLockServer(memoFor: { _ in Null() }, log: { _ in })
        defer { server.stop() }
        let listener = try server.openRemoteListener(machine: "M1")
        let holder = try RunLockClient.connect(path: server.socketPath, scenario: "H", machine: "m", device: "d")
        let heldID = try holder.request(keys: ["k"]).get()
        XCTAssertEqual(holder.wait(id: heldID, timeout: .seconds(5)), .granted)
        let fd = try UnixSocket.connect(path: listener)
        XCTAssertTrue(RunLockLineChannel.writeAll(fd, RunLockMessage.hello(scenario: "W", machine: "m", device: "d", token: "").encodedLine()))
        // 同じ番号の要求を2回送る(2回目は重複で断られる)
        for _ in 0..<2 {
            XCTAssertTrue(RunLockLineChannel.writeAll(fd, RunLockMessage.acquire(id: 1, keys: ["k"]).encodedLine()))
        }
        usleep(300_000)
        let control = try RunLockControl.connect(path: server.socketPath)
        let first = try XCTUnwrap(control.waitedMs(listener: listener))
        usleep(400_000)
        XCTAssertEqual(try XCTUnwrap(control.waitedMs(listener: listener)), first, accuracy: 30,
                       "重複で断られた要求が、その範囲を「待っている」まま残さない(増え続けない)")
        close(fd)
        usleep(300_000)
        let after = try XCTUnwrap(control.waitedMs(listener: listener))
        usleep(300_000)
        XCTAssertEqual(try XCTUnwrap(control.waitedMs(listener: listener)), after, accuracy: 30)
        server.closeRemoteListener(path: listener)
        XCTAssertEqual(try XCTUnwrap(control.waitedMs(listener: listener)), 0, "閉じて待ちが尽きた範囲の累計は捨てる")
    }
}
