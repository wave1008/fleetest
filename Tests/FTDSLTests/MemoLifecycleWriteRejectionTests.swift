import XCTest
@testable import FTDSL
import FTCore

/// DR-208: test 範囲のメモ(writeMemo 等)はテスト関数の外で読み書きとも失敗・run メモの書き込み(DR-207 を引き継ぐ)は setUpDevice / tearDownDevice / afterAll で失敗
final class MemoLifecycleWriteRejectionTests: XCTestCase {

    private final class Sink: @unchecked Sendable {
        private let lock = NSLock()
        private var items: [ScenarioEvent] = []
        func add(_ event: ScenarioEvent) { lock.lock(); items.append(event); lock.unlock() }
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

    private func makeCore(sink: Sink) -> FTDriveCore {
        let core = FTDriveCore(driver: NullDriver(), platform: "ios", app: "com.example.app",
                    scenarioID: "T.S0010", scenarioTitle: "t",
                    delegate: nil, healingEnabled: false, tunables: RunTunables(), dryRun: true,
                    fingerprintCacheURL: URL(fileURLWithPath: NSTemporaryDirectory())
                        .appendingPathComponent("ft-memo-reject-test.json"),
                    emit: { sink.add($0) })
        core.runSetUpDevice = true
        return core
    }

    func testRunMemoRejectionReasonOnlyForTheThreeSections() {
        XCTAssertNotNil(FTDriveCore.runMemoWriteRejection(command: "writeRunMemo", section: "setUpDevice"))
        XCTAssertNotNil(FTDriveCore.runMemoWriteRejection(command: "writeRunMemo", section: "tearDownDevice"))
        XCTAssertNotNil(FTDriveCore.runMemoWriteRejection(command: "writeRunMemo", section: "afterAll"))
        for allowed: String? in [nil, "beforeAll", "beforeEach", "afterEach", "action", "expectation"] {
            XCTAssertNil(FTDriveCore.runMemoWriteRejection(command: "writeRunMemo", section: allowed), "\(allowed ?? "nil")")
        }
    }

    func testTestMemoRejectionForTheFourSectionsOutsideATest() {
        for outside in ["beforeAll", "setUpDevice", "tearDownDevice", "afterAll"] {
            XCTAssertNotNil(FTDriveCore.testMemoRejection(command: "readMemo", section: outside), outside)
        }
        for inside: String? in [nil, "beforeEach", "afterEach", "action", "expectation"] {
            XCTAssertNil(FTDriveCore.testMemoRejection(command: "readMemo", section: inside), "\(inside ?? "nil")")
        }
    }

    func testReasonsNameTheAlternativeAndWhy() {
        let setUp = FTDriveCore.runMemoWriteRejection(command: "clearRunMemo", section: "setUpDevice") ?? ""
        XCTAssertTrue(setUp.contains("clearRunMemo") && setUp.contains("overwritten") && setUp.contains("beforeAll()"), setUp)
        let after = FTDriveCore.runMemoWriteRejection(command: "writeRunMemo", section: "afterAll") ?? ""
        XCTAssertTrue(after.contains("the tests have already finished") && after.contains("beforeRun()"), after)
        let test = FTDriveCore.testMemoRejection(command: "writeMemo", section: "beforeAll") ?? ""
        XCTAssertTrue(test.contains("writeMemo") && test.contains("writeRunMemo / readRunMemo"), test)
    }

    private func failedSteps(_ core: FTDriveCore) -> [String] {
        core.finalRecord.scenes.flatMap(\.steps).filter {
            if case .failed = $0.status { return true } else { return false }
        }.map(\.description)
    }

    /// 新しい core(中断フラグも空)で body を1回走らせ、失敗したステップ数と親へ出た run メモのイベント数を返す
    private func runFresh(_ body: () -> Void) -> (failed: Int, runMemoEvents: Int) {
        let sink = Sink()
        let core = makeCore(sink: sink)
        FTRuntime.bootstrap(core: core, dslThread: Thread.current)
        defer { FTRuntime.tearDown() }
        body()
        return (failedSteps(core).count,
                sink.events.filter { $0.kind == "runMemoWrite" || $0.kind == "runMemoClear" }.count)
    }

    func testEveryRunMemoWriteEntranceFailsInsideSetUpDeviceAndAfterAll() {
        let entrances: [() -> Void] = [
            { writeRunMemo("k", "v") }, { "text".runMemoTextAs("s") }, { clearRunMemo() },
        ]
        for entrance in entrances {
            for lifecycle in [ftRunSetUpDevice, ftRunAfterAll, ftRunTearDownDevice] {
                let result = runFresh { lifecycle(entrance) }
                XCTAssertEqual(result.failed, 1)
                XCTAssertEqual(result.runMemoEvents, 0)
            }
        }
    }

    func testReadRunMemoIsAllowedInSetUpDevice() {
        let sink = Sink()
        let core = makeCore(sink: sink)
        core.runMemo = ["k": ["v"]]
        FTRuntime.bootstrap(core: core, dslThread: Thread.current)
        defer { FTRuntime.tearDown() }
        var read = ""
        ftRunSetUpDevice { read = readRunMemo("k") }
        XCTAssertEqual(read, "v")
        XCTAssertTrue(failedSteps(core).isEmpty)
    }

    func testRunMemoWriteInAfterAllFailsButBeforeEachWrites() {
        let sink = Sink()
        let core = makeCore(sink: sink)
        FTRuntime.bootstrap(core: core, dslThread: Thread.current)
        defer { FTRuntime.tearDown() }
        ftRunBeforeEach { writeRunMemo("k", "v") }
        XCTAssertEqual(core.runMemo["k"], ["v"])
        XCTAssertTrue(failedSteps(core).isEmpty)
        ftRunAfterAll { writeRunMemo("k2", "v2") }
        XCTAssertNil(core.runMemo["k2"])
        XCTAssertEqual(failedSteps(core).count, 1)
    }

    func testTestMemoReadAndWriteFailOutsideATest() {
        let entrances: [() -> Void] = [
            { writeMemo("a", "1") }, { _ = readMemo("a") }, { "t".memoTextAs("b") }, { clearMemo() },
        ]
        for entrance in entrances {
            for lifecycle in [ftRunBeforeAll, ftRunSetUpDevice, ftRunAfterAll, ftRunTearDownDevice] {
                XCTAssertEqual(runFresh { lifecycle(entrance) }.failed, 1)
            }
        }
    }

    func testTestMemoWorksInBeforeEachBodyAndAfterEach() {
        let sink = Sink()
        let core = makeCore(sink: sink)
        FTRuntime.bootstrap(core: core, dslThread: Thread.current)
        defer { FTRuntime.tearDown() }
        ftRunBeforeEach { writeMemo("k", "v") }
        XCTAssertEqual(readMemo("k"), "v")
        ftRunAfterEach { XCTAssertEqual(readMemo("k"), "v") }
        XCTAssertTrue(failedSteps(core).isEmpty)
    }
}
