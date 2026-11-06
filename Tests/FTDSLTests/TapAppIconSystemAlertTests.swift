// tapAppIcon: SpringBoard の前面にシステムアラートがあり木にアイコンが1つも載らないとき、
// 「アイコンが見つからない」と払い続けずにアラートを名指して失敗する。判定は SystemUIGate.frontAlertPhrase
// (MCP の systemAlertNote と共有)。

import XCTest
@testable import FTDSL
@testable import FTCore

final class TapAppIconSystemAlertTests: XCTestCase {

    private final class Sink: @unchecked Sendable {
        private let lock = NSLock()
        private var items: [ScenarioEvent] = []
        func add(_ event: ScenarioEvent) { lock.lock(); items.append(event); lock.unlock() }
        var steps: [ScenarioEvent] { lock.lock(); defer { lock.unlock() }; return items.filter { $0.kind == "step" } }
    }

    /// 木にはアラートの中の要素しか無い(アイコンは無い)。swipe / drag の回数でページ送りを数える
    private final class AlertedHomeDriver: AppDriver {
        private let flicks = LockedValue(0)
        var flickCount: Int { flicks.value }
        func status() async throws -> StatusResponse {
            StatusResponse(ready: true, device: "stub", osVersion: "-", sessionBundleID: nil)
        }
        func install(packagePath: String) async throws -> String? { nil }
        func uninstall(bundleID: String) async throws {}
        func isAppForeground(bundleID: String) async throws -> Bool { false }
        func launch(bundleID: String) async throws {}
        func home() async throws {}
        func snapshot() async throws -> SnapshotResponse {
            SnapshotResponse(
                sessionBundleID: "com.apple.springboard", screen: FTRect(x: 0, y: 0, width: 402, height: 874),
                elements: [ElementInfo(ref: 1, type: "alert", identifier: "kTCCServicePhotos-staged-alert", label: nil,
                                       value: nil, placeholder: nil, enabled: true,
                                       frame: FTRect(x: 41, y: 158, width: 320, height: 584), depth: 1)],
                truncatedCount: 0)
        }
        func systemAlert() async -> Probe<SystemAlertProbeResponse> {
            .value(SystemAlertProbeResponse(present: true, title: "Allow Photos", buttons: ["Do not allow", "Allow"]))
        }
        func tap(ref: Int) async throws {}
        func tap(x: Double, y: Double) async throws {}
        func type(ref: Int?, text: String) async throws {}
        func swipe(_ direction: FTSwipeDirection) async throws { flicks.withLock { $0 += 1 } }
        func drag(fromX: Double, fromY: Double, toX: Double, toY: Double,
                  pressSeconds: Double, durationSeconds: Double) async throws { flicks.withLock { $0 += 1 } }
        func press(ref: Int, duration: Double) async throws {}
        func screenshot() async throws -> Data { Data() }
        func terminate() async throws {}
    }

    func testNamesTheAlertInsteadOfSayingTheIconIsMissing() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ft-tapicon-alert-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let sink = Sink()
        let driver = AlertedHomeDriver()
        let core = FTDriveCore(driver: driver, platform: "ios", app: "com.example.app",
                               scenarioID: "T.S0010", scenarioTitle: "t",
                               delegate: nil, healingEnabled: false,
                               tunables: RunTunables(screenWaitTimeout: 0.3),
                               visionClassifierProjectRoot: dir, dryRun: false,
                               fingerprintCacheURL: dir.appendingPathComponent("fp.json"),
                               emit: { [sink] in sink.add($0) })
        core.appDisplayName = "FT E2E"
        FTRuntime.bootstrap(core: core, dslThread: Thread.current)
        defer { FTRuntime.tearDown() }
        scenario { scene(1, "s") { action { tapAppIcon() } } }
        XCTAssertFalse(core.finalRecord.passed)
        let detail = sink.steps.first { $0.status == "failed" }?.detail ?? ""
        XCTAssertTrue(detail.contains("a system alert (\"Allow Photos\""), detail)
        XCTAssertTrue(detail.contains("Close the alert first"), detail)
        XCTAssertEqual(driver.flickCount, 0, "アラートが前面にあるのにページ送りを払った")
    }

    func testPhraseIsNilWithoutAnAlert() {
        XCTAssertNil(SystemUIGate.frontAlertPhrase(nil))
        XCTAssertNil(SystemUIGate.frontAlertPhrase(SystemAlertProbeResponse(present: false)))
        XCTAssertEqual(SystemUIGate.frontAlertPhrase(SystemAlertProbeResponse(present: true)), "a system alert")
    }
}
