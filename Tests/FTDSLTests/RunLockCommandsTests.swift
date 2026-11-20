import XCTest
@testable import FTDSL
import FTCore

/// `withExclusiveLock` / `withSharedLock`(RR-8.5)の DSL 側: ステップの記録・失敗の後は本体を実行しない・ロックの中の run メモ
final class RunLockCommandsTests: XCTestCase {
    private final class Sink: @unchecked Sendable {
        private let lock = NSLock()
        private var items: [ScenarioEvent] = []
        /// 親が stdout のイベントを適用する側の代わり(遅れて適用する再現に使う)
        var onEvent: (@Sendable (ScenarioEvent) -> Void)?
        func add(_ event: ScenarioEvent) { lock.lock(); items.append(event); lock.unlock(); onEvent?(event) }
        var events: [ScenarioEvent] { lock.lock(); defer { lock.unlock() }; return items }
    }

    private final class NullDriver: AppDriver {
        func status() async throws -> StatusResponse {
            StatusResponse(ready: true, device: "stub", osVersion: "-", sessionBundleID: nil)
        }
        func install(packagePath: String) async throws -> String? { nil }
        func uninstall(bundleID: String) async throws {}
        func isAppForeground(bundleID: String) async throws -> Bool { false }
        func launch(bundleID: String) async throws {}
        func snapshot() async throws -> SnapshotResponse {
            SnapshotResponse(sessionBundleID: nil, screen: FTRect(x: 0, y: 0, width: 400, height: 800),
                             elements: [], truncatedCount: 0)
        }
        func tap(ref: Int) async throws {}
        func tap(x: Double, y: Double) async throws {}
        func type(ref: Int?, text: String) async throws {}
        func swipe(_ direction: FTSwipeDirection) async throws {}
        func press(ref: Int, duration: Double) async throws {}
        func screenshot() async throws -> Data { Data() }
        func terminate() async throws {}
    }

    private var servers: [RunLockServer] = []

    override func tearDown() {
        FTRuntime.tearDown()
        servers.forEach { $0.stop() }
        servers = []
        super.tearDown()
    }

    private func makeCore(sink: Sink, access: RunLockAccess, cap: Int = 20) -> FTDriveCore {
        let core = FTDriveCore(driver: NullDriver(), platform: "ios", app: "com.example.app",
                               scenarioID: "T.S0010", scenarioTitle: "t",
                               delegate: nil, healingEnabled: false, tunables: RunTunables(), dryRun: true,
                               fingerprintCacheURL: URL(fileURLWithPath: NSTemporaryDirectory())
                                   .appendingPathComponent("ft-lock-test.json"),
                               emit: { sink.add($0) })
        core.runLocks.access = access
        core.runLocks.waitCapSeconds = cap
        core.runLocks.scenarioID = "T.S0010"
        core.runLocks.machine = "m"
        core.runLocks.device = "d"
        core.runLocks.ownerToken = "tok"
        FTRuntime.bootstrap(core: core, dslThread: Thread.current)
        return core
    }

    private func steps(_ core: FTDriveCore) -> [DSLStepRecord] { core.finalRecord.scenes.flatMap(\.steps) }

    private func failedReason(_ core: FTDriveCore) -> String? {
        for step in steps(core) { if case .failed(let reason) = step.status { return reason } }
        return nil
    }

    private func startServer(_ store: RunMemoStore = RunMemoStore(),
                             applied: RunLockAppliedOps = RunLockAppliedOps()) throws -> RunLockServer {
        let server = try RunLockServer(memoFor: { _ in store }, applied: applied, waitCapSeconds: { 5 }, log: { _ in })
        servers.append(server)
        return server
    }

    func testBodyRunsAndTheStepNamesTheSortedKeys() {
        let core = makeCore(sink: Sink(), access: .immediate)
        var ran = false
        withExclusiveLock("b", "a") { ran = true }
        XCTAssertTrue(ran)
        XCTAssertEqual(steps(core).first?.description, "withExclusiveLock \"a\", \"b\"")
        XCTAssertNil(failedReason(core))
    }

    func testInvalidKeysFailTheStepAndSkipTheBody() {
        let core = makeCore(sink: Sink(), access: .immediate)
        var ran = false
        withExclusiveLock("a\nb") { ran = true }
        XCTAssertFalse(ran)
        XCTAssertTrue(failedReason(core)?.contains("control characters") == true)
        XCTAssertTrue(core.scenarioAborted)
    }

    func testNestedOrderViolationFailsWithoutContentionAndSkipsTheInnerBody() {
        let core = makeCore(sink: Sink(), access: .immediate)
        var inner = false
        var afterInner = false
        withExclusiveLock("b") {
            withExclusiveLock("a") { inner = true }
            afterInner = true  // 失敗の印が立った後の生の Swift は走り続ける(DSL のコマンドだけが飛ばされる)
        }
        XCTAssertFalse(inner)
        XCTAssertTrue(afterInner)
        XCTAssertTrue(failedReason(core)?.contains("one call") == true)
    }

    func testUpgradeFails() {
        let core = makeCore(sink: Sink(), access: .immediate)
        withSharedLock("k") { withExclusiveLock("k") { XCTFail("must not run") } }
        XCTAssertTrue(failedReason(core)?.contains("upgraded") == true)
    }

    func testAnAbortedScenarioSkipsTheBodyWithoutTakingTheLock() {
        let core = makeCore(sink: Sink(), access: .immediate)
        core.handleFailure(stepDescription: "x", reason: "boom")
        var ran = false
        withExclusiveLock("a") { ran = true }
        XCTAssertFalse(ran)
        XCTAssertFalse(core.runLocks.isHolding)
        if case .skipped = steps(core).last?.status {} else { XCTFail("skipped step expected") }
    }

    func testRefuseFailsAndSkipsTheBody() {
        let core = makeCore(sink: Sink(), access: .refuse("--fleet runs do not share locks across machines"))
        var ran = false
        withExclusiveLock("a") { ran = true }
        XCTAssertFalse(ran)
        XCTAssertTrue(failedReason(core)?.contains("--fleet runs do not share locks") == true)
    }

    func testPassThroughRunsTheBodyAndStillReportsViolations() {
        let core = makeCore(sink: Sink(), access: .passThrough)
        var ran = false
        withSharedLock("a") { ran = true }
        XCTAssertTrue(ran)
        XCTAssertNil(failedReason(core))
        withExclusiveLock("z") { withExclusiveLock("y") {} }
        XCTAssertNotNil(failedReason(core))
    }

    func testWriteRunMemoInsideOnlySharedLockFailsForEveryWritingCommand() {
        for command in ["writeRunMemo", "clearRunMemo", "runMemoTextAs"] {
            let core = makeCore(sink: Sink(), access: .immediate)
            withSharedLock("k") {
                switch command {
                case "writeRunMemo": writeRunMemo("n", "1")
                case "clearRunMemo": clearRunMemo()
                default: _ = "text".runMemoTextAs("n")
                }
            }
            XCTAssertTrue(failedReason(core)?.contains("needs an exclusive lock") == true, command)
            XCTAssertEqual(core.runMemo, [:], command)
            FTRuntime.tearDown()
        }
    }

    func testWriteRunMemoInsideExclusiveLockGoesThroughTheServerNotTheStdoutEvent() throws {
        let store = RunMemoStore()
        let server = try startServer(store)
        let sink = Sink()
        let core = makeCore(sink: sink, access: .socket(server.socketPath))
        withExclusiveLock("counter") {
            writeRunMemo("n", "1")
            XCTAssertEqual(store.snapshot(), ["n": ["1"]], "確定の返事の前にサーバー側へ入っている")
            XCTAssertEqual(readRunMemo("n"), "1")
            _ = "two".runMemoTextAs("n")
            clearRunMemo()
            writeRunMemo("m", "x")
        }
        XCTAssertNil(failedReason(core))
        XCTAssertEqual(store.snapshot(), ["m": ["x"]])
        XCTAssertEqual(core.runMemo, ["m": ["x"]], "手元の写しも更新され、ロックを出た後も見える")
        XCTAssertFalse(sink.events.contains { $0.kind == "runMemoWrite" || $0.kind == "runMemoClear" },
                       "ロックの中の書き込みを stdout の通り道へ重ねて出さない")
    }

    func testReadRunMemoInsideALockSeesTheLatestValueWrittenByAnotherScenario() throws {
        let store = RunMemoStore()
        let server = try startServer(store)
        let core = makeCore(sink: Sink(), access: .socket(server.socketPath))
        XCTAssertEqual(core.runMemo["n"], nil)
        store.write(key: "n", value: "from-other")  // 別のシナリオがロックの中で書いた
        var seen = ""
        withSharedLock("k") { seen = readRunMemo("n") }
        XCTAssertEqual(seen, "from-other")
        XCTAssertEqual(readRunMemo("n"), "from-other", "ロックを出た後もその写しを見続ける")
    }

    func testWriteOutsideLocksStillUsesTheEventPath() throws {
        let server = try startServer()
        let sink = Sink()
        _ = makeCore(sink: sink, access: .socket(server.socketPath))
        writeRunMemo("n", "1")
        XCTAssertTrue(sink.events.contains { $0.kind == "runMemoWrite" })
    }

    func testTimeoutFailsTheStepWithKeyAndSecondsAndSkipsTheBodyThenReleasesNothing() throws {
        let server = try startServer()
        let holder = try RunLockClient.connect(path: server.socketPath, scenario: "H", machine: "m", device: "d")
        let id = try holder.request(keys: ["db"], mode: .exclusive).get()
        XCTAssertEqual(holder.wait(id: id, timeout: .seconds(5)), .granted)
        let core = makeCore(sink: Sink(), access: .socket(server.socketPath))
        var ran = false
        withExclusiveLock("db", waitSeconds: 0.3) { ran = true }
        XCTAssertFalse(ran)
        let reason = failedReason(core) ?? ""
        XCTAssertTrue(reason.contains("\"db\"") && reason.contains("timed out"), reason)
    }

    func testTheLockIsReleasedWhenTheBlockExitsEvenIfTheBodyAborted() throws {
        let server = try startServer()
        let core = makeCore(sink: Sink(), access: .socket(server.socketPath))
        withSharedLock("k") { writeRunMemo("n", "1") }  // 失敗(共有だけでは書けない)
        XCTAssertTrue(core.scenarioAborted)
        XCTAssertFalse(core.runLocks.isHolding)
        let other = try RunLockClient.connect(path: server.socketPath, scenario: "O", machine: "m", device: "d")
        let id = try other.request(keys: ["k"], mode: .exclusive).get()
        XCTAssertEqual(other.wait(id: id, timeout: .seconds(5)), .granted, "ブロックを抜けた時点で外れている")
    }

    func testWaitedSecondsAppearInTheStepDescription() throws {
        let server = try startServer()
        let holder = try RunLockClient.connect(path: server.socketPath, scenario: "H", machine: "m", device: "d")
        let id = try holder.request(keys: ["db"], mode: .exclusive).get()
        _ = holder.wait(id: id, timeout: .seconds(5))
        let core = makeCore(sink: Sink(), access: .socket(server.socketPath))
        Thread { usleep(300_000); holder.release(id: id) }.start()
        withExclusiveLock("db") {}
        let description = steps(core).first?.description ?? ""
        XCTAssertTrue(description.contains("(waited "), description)
    }

    /// 親が stdout のイベントを少し遅れて適用する(実際の経路と同じ非同期)。適用したら数える
    private func delayedHost(_ sink: Sink, store: RunMemoStore, applied: RunLockAppliedOps, delayMs: UInt32 = 400) {
        sink.onEvent = { event in
            guard event.kind == "runMemoWrite" || event.kind == "runMemoClear" else { return }
            Thread {
                usleep(delayMs * 1000)
                if event.kind == "runMemoWrite", let key = event.memoKey, let value = event.memoValue {
                    store.write(key: key, value: value)
                } else {
                    store.clear()
                }
                applied.note(token: "tok")
            }.start()
        }
    }

    func testOwnWriteOutsideTheLockIsNotLostWhenTheNextLockReadReplacesTheLocalCopy() throws {
        let store = RunMemoStore()
        let applied = RunLockAppliedOps()
        let server = try startServer(store, applied: applied)
        let sink = Sink()
        delayedHost(sink, store: store, applied: applied)
        let core = makeCore(sink: sink, access: .socket(server.socketPath))
        writeRunMemo("token", "abc")  // ロックの外(イベントは遅れて親に適用される)
        var inside = ""
        withExclusiveLock("c") { inside = readRunMemo("token") }
        XCTAssertEqual(inside, "abc", "外の書き込みが適用されるまで読みを待つ")
        XCTAssertEqual(readRunMemo("token"), "abc", "ロックを出た後も消えない")
        XCTAssertNil(failedReason(core))
    }

    func testOutsideClearArrivingLateDoesNotWipeALaterInsideWrite() throws {
        let store = RunMemoStore()
        let applied = RunLockAppliedOps()
        let server = try startServer(store, applied: applied)
        let sink = Sink()
        delayedHost(sink, store: store, applied: applied)
        let core = makeCore(sink: sink, access: .socket(server.socketPath))
        clearRunMemo()  // ロックの外(適用は遅れる)
        withExclusiveLock("c") { writeRunMemo("n", "1") }
        Thread.sleep(forTimeInterval: 0.8)  // 遅れて届く分が全部届く時間
        XCTAssertEqual(store.snapshot(), ["n": ["1"]], "外の clear が先に適用されてから中の書き込みが入る")
        XCTAssertNil(failedReason(core))
    }
}
