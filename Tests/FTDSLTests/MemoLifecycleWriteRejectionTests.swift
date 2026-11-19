import XCTest
@testable import FTDSL
import FTCore

/// DR-207: setUpDevice / tearDownDevice / afterAll でのメモの書き込み(writeMemo・memoTextAs・clearMemo)は失敗にする
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

    func testRejectionReasonOnlyForTheThreeSections() {
        XCTAssertNotNil(FTDriveCore.memoWriteRejection(command: "writeMemo", section: "setUpDevice"))
        XCTAssertNotNil(FTDriveCore.memoWriteRejection(command: "writeMemo", section: "tearDownDevice"))
        XCTAssertNotNil(FTDriveCore.memoWriteRejection(command: "writeMemo", section: "afterAll"))
        for allowed: String? in [nil, "beforeAll", "beforeEach", "afterEach", "action", "expectation"] {
            XCTAssertNil(FTDriveCore.memoWriteRejection(command: "writeMemo", section: allowed), "\(allowed ?? "nil")")
        }
    }

    func testReasonNamesTheAlternativeAndWhy() {
        let setUp = FTDriveCore.memoWriteRejection(command: "clearMemo", section: "setUpDevice") ?? ""
        XCTAssertTrue(setUp.contains("clearMemo") && setUp.contains("overwritten") && setUp.contains("beforeAll()"), setUp)
        let after = FTDriveCore.memoWriteRejection(command: "writeMemo", section: "afterAll") ?? ""
        XCTAssertTrue(after.contains("nothing reads") && after.contains("beforeAll()"), after)
    }

    private func failedSteps(_ core: FTDriveCore) -> [String] {
        core.finalRecord.scenes.flatMap(\.steps).filter {
            if case .failed = $0.status { return true } else { return false }
        }.map(\.description)
    }

    func testAllFourEntrancesFailInsideSetUpDevice() {
        let sink = Sink()
        let core = makeCore(sink: sink)
        FTRuntime.bootstrap(core: core, dslThread: Thread.current)
        defer { FTRuntime.tearDown() }
        ftRunSetUpDevice {
            writeMemo("k", "v")
            "text".memoTextAs("s")
            clearMemo()
        }
        XCTAssertTrue(failedSteps(core).contains { $0.hasPrefix("writeMemo") })
        XCTAssertEqual(sink.events.filter { $0.kind == "memoWrite" }.count, 0)
        XCTAssertEqual(sink.events.filter { $0.kind == "memoClear" }.count, 0)
        XCTAssertNil(core.deviceMemo["k"])
    }

    func testWriteInAfterAllFailsButBeforeEachWrites() {
        let sink = Sink()
        let core = makeCore(sink: sink)
        FTRuntime.bootstrap(core: core, dslThread: Thread.current)
        defer { FTRuntime.tearDown() }
        ftRunBeforeEach { writeMemo("k", "v") }
        XCTAssertEqual(core.deviceMemo["k"], ["v"])
        XCTAssertTrue(failedSteps(core).isEmpty)
        ftRunAfterAll { writeMemo("k2", "v2") }
        XCTAssertNil(core.deviceMemo["k2"])
        XCTAssertEqual(failedSteps(core).count, 1)
    }
}
