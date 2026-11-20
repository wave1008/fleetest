import XCTest
@testable import FTDSL
import FTCore

/// RR-8.4: beforeRun() / afterRun() はデバイスを操作するコマンドを断る(使えるのは run メモ・httpRequest・wait 等)
final class RunHookDeviceRefusalTests: XCTestCase {

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
        FTDriveCore(driver: NullDriver(), platform: "ios", app: "com.example.app",
                    scenarioID: "H.beforeRun", scenarioTitle: "beforeRun",
                    delegate: nil, healingEnabled: false, tunables: RunTunables(), dryRun: true,
                    fingerprintCacheURL: URL(fileURLWithPath: NSTemporaryDirectory())
                        .appendingPathComponent("ft-run-hook-refusal-test.json"),
                    emit: { sink.add($0) })
    }

    private func failures(_ core: FTDriveCore) -> [String] {
        core.finalRecord.scenes.flatMap(\.steps).compactMap {
            if case .failed(let reason) = $0.status { return reason } else { return nil }
        }
    }

    func testRefusalReasonNamesThePhaseAndTheCommand() {
        XCTAssertEqual(FTDriveCore.runHookDeviceRefusal(command: "tap", description: "tap \"#a\"", section: "beforeRun"),
                       "beforeRun() cannot use the device (tap)")
        XCTAssertEqual(FTDriveCore.runHookDeviceRefusal(command: "launchApp", description: "launch", section: "afterRun"),
                       "afterRun() cannot use the device (launchApp)")
        // command を持たない呼び出しは説明の先頭語で名指しする
        XCTAssertEqual(FTDriveCore.runHookDeviceRefusal(command: nil, description: "swipe up", section: "beforeRun"),
                       "beforeRun() cannot use the device (swipe)")
    }

    func testRefusalDoesNotApplyOutsideTheHooksOrToWait() {
        for section: String? in [nil, "beforeAll", "beforeEach", "afterEach", "action", "expectation", "afterAll"] {
            XCTAssertNil(FTDriveCore.runHookDeviceRefusal(command: "tap", description: "tap", section: section),
                         "\(section ?? "nil")")
        }
        XCTAssertNil(FTDriveCore.runHookDeviceRefusal(command: "wait", description: "wait 1s", section: "beforeRun"))
    }

    func testDeviceCommandsFailInsideBothHooksAndNameTheCommand() {
        let entrances: [(String, () -> Void)] = [
            ("tap", { tap("#a") }), ("launchApp", { launchApp() }), ("home", { home() }),
            // perform / performCustom を通らない入口(独自にステップを記録する)
            ("screenshot", { screenshot() }),
        ]
        for (name, entrance) in entrances {
            for (hook, phase) in [(ftRunBeforeRun, "beforeRun"), (ftRunAfterRun, "afterRun")] {
                let sink = Sink()
                let core = makeCore(sink: sink)
                FTRuntime.bootstrap(core: core, dslThread: Thread.current)
                defer { FTRuntime.tearDown() }
                hook(entrance)
                XCTAssertEqual(failures(core), ["\(phase)() cannot use the device (\(name))"], "\(phase) \(name)")
            }
        }
    }

    func testRunMemoWaitAndHTTPAreAllowedInBeforeRun() {
        let sink = Sink()
        let core = makeCore(sink: sink)
        core.runMemo = ["k": ["v"]]
        FTRuntime.bootstrap(core: core, dslThread: Thread.current)
        defer { FTRuntime.tearDown() }
        var read = ""
        ftRunBeforeRun {
            read = readRunMemo("k")
            writeRunMemo("k2", "v2")
            FTDSL.wait(0.01)
            httpRequest("http://127.0.0.1:1/")
        }
        XCTAssertEqual(read, "v")
        XCTAssertEqual(core.runMemo["k2"], ["v2"])
        XCTAssertTrue(failures(core).isEmpty, "\(failures(core))")
        XCTAssertEqual(sink.events.filter { $0.kind == "runMemoWrite" }.count, 1)
    }

    func testRunMemoWriteIsRefusedInAfterRunButReadIsAllowed() {
        let sink = Sink()
        let core = makeCore(sink: sink)
        core.runMemo = ["k": ["v"]]
        FTRuntime.bootstrap(core: core, dslThread: Thread.current)
        defer { FTRuntime.tearDown() }
        var read = ""
        ftRunAfterRun {
            read = readRunMemo("k")
            writeRunMemo("k2", "v2")
        }
        XCTAssertEqual(read, "v")
        XCTAssertNil(core.runMemo["k2"])
        XCTAssertEqual(failures(core).count, 1)
        XCTAssertTrue(sink.events.filter { $0.kind == "runMemoWrite" }.isEmpty)
    }

    func testTestMemoIsRefusedInBothHooks() {
        for hook in [ftRunBeforeRun, ftRunAfterRun] {
            let sink = Sink()
            let core = makeCore(sink: sink)
            FTRuntime.bootstrap(core: core, dslThread: Thread.current)
            defer { FTRuntime.tearDown() }
            hook { writeMemo("a", "1") }
            XCTAssertEqual(failures(core).count, 1)
        }
    }

    func testDeviceCommandInsideAHookIsStillRunnableInATestBody() {
        let sink = Sink()
        let core = makeCore(sink: sink)
        FTRuntime.bootstrap(core: core, dslThread: Thread.current)
        defer { FTRuntime.tearDown() }
        tap("#a")
        XCTAssertTrue(failures(core).isEmpty)
    }
}
