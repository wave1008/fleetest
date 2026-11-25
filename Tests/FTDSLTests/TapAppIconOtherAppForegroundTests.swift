// 対象アプリ以外の tapAppIcon(Android)は、固定 1.5 秒の待ちで緑にせず、前面がランチャーから離れたかを照会で確かめる。

import XCTest
@testable import FTDSL
@testable import FTCore

final class TapAppIconOtherAppForegroundTests: XCTestCase {

    private final class Sink: @unchecked Sendable {
        private let lock = NSLock()
        private var items: [ScenarioEvent] = []
        func add(_ event: ScenarioEvent) { lock.lock(); items.append(event); lock.unlock() }
        var steps: [ScenarioEvent] { lock.lock(); defer { lock.unlock() }; return items.filter { $0.kind == "step" } }
    }

    /// 前面は launcherStays なら常にランチャー、でなければ撃った後に別のパッケージへ移る
    private final class LauncherDriver: AppDriver {
        let launcherStays: Bool
        private let tapped = LockedValue(false)
        init(launcherStays: Bool) { self.launcherStays = launcherStays }
        func status() async throws -> StatusResponse {
            StatusResponse(ready: true, device: "stub", osVersion: "-", sessionBundleID: nil)
        }
        func install(packagePath: String) async throws -> String? { nil }
        func uninstall(bundleID: String) async throws {}
        func isAppForeground(bundleID: String) async throws -> Bool { false }
        func foregroundAppID() async -> Probe<String> {
            .value(tapped.value && !launcherStays ? "org.mozilla.firefox" : "com.google.android.apps.nexuslauncher")
        }
        func launch(bundleID: String) async throws {}
        func home() async throws {}
        func snapshot() async throws -> SnapshotResponse {
            SnapshotResponse(
                sessionBundleID: nil, screen: FTRect(x: 0, y: 0, width: 400, height: 800),
                elements: [ElementInfo(ref: 7, type: "button", identifier: nil, label: "Firefox", value: nil,
                                       placeholder: nil, enabled: true,
                                       frame: FTRect(x: 100, y: 200, width: 50, height: 40), depth: 1)],
                truncatedCount: 0)
        }
        func tap(ref: Int) async throws { tapped.withLock { $0 = true } }
        func tap(x: Double, y: Double) async throws {}
        func type(ref: Int?, text: String) async throws {}
        func swipe(_ direction: FTSwipeDirection) async throws {}
        func press(ref: Int, duration: Double) async throws {}
        func screenshot() async throws -> Data { Data() }
        func terminate() async throws {}
    }

    private let sink = Sink()
    private var dir: URL!

    override func setUpWithError() throws {
        dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ft-oi391-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }
    override func tearDown() { try? FileManager.default.removeItem(at: dir) }

    private func run(_ driver: LauncherDriver) -> FTDriveCore {
        let core = FTDriveCore(driver: driver, platform: "android", app: "com.example.app",
                               scenarioID: "T.S0010", scenarioTitle: "t",
                               delegate: nil, healingEnabled: false,
                               tunables: RunTunables(screenWaitTimeout: 0.3),
                               visionClassifierProjectRoot: dir, dryRun: false,
                               fingerprintCacheURL: dir.appendingPathComponent("fp.json"),
                               emit: { [sink] in sink.add($0) })
        core.appDisplayName = "FT E2E"
        FTRuntime.bootstrap(core: core, dslThread: Thread.current)
        defer { FTRuntime.tearDown() }
        scenario { scene(1, "s") { action { tapAppIcon("Firefox") } } }
        return core
    }

    func testFailsWhenTheLauncherStaysInFront() {
        let core = run(LauncherDriver(launcherStays: true))
        XCTAssertFalse(core.finalRecord.passed)
        let detail = sink.steps.first { $0.status == "failed" }?.detail ?? ""
        XCTAssertTrue(detail.contains("stayed in the foreground"), detail)
    }

    func testPassesWhenAnotherAppComesToFront() {
        let core = run(LauncherDriver(launcherStays: false))
        XCTAssertTrue(core.finalRecord.passed)
    }
}
