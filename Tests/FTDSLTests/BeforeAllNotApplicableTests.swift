import XCTest
@testable import FTDSL
import FTCore

/// DR-214 の範囲: `beforeAll()` の中の対象外の宣言(fold を折りたためない台で撃った等)は失敗にする。beforeAll は run に1回・
/// 撃ち直さないので、対象外にすると最初のシナリオだけが別の台へ回され、残りは「beforeAll failed」で割れる。
/// setUpDevice の中では今までどおり対象外(その台の同じクラスを対象外にする)
final class BeforeAllNotApplicableTests: XCTestCase {

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

    private func withCore(_ body: (FTDriveCore, Sink) -> Void) {
        let sink = Sink()
        let core = FTDriveCore(driver: NullDriver(), platform: "ios", app: "com.example.app",
                               scenarioID: "T.S0010", scenarioTitle: "t",
                               delegate: nil, healingEnabled: false, tunables: RunTunables(), dryRun: true,
                               fingerprintCacheURL: URL(fileURLWithPath: NSTemporaryDirectory())
                                   .appendingPathComponent("ft-beforeall-na-test.json"),
                               emit: { sink.add($0) })
        core.runBeforeAll = true
        core.runSetUpDevice = true
        FTRuntime.bootstrap(core: core, dslThread: Thread.current)
        defer { FTRuntime.tearDown() }
        body(core, sink)
    }

    private func declare(_ core: FTDriveCore) {
        core.skipScenarioNotApplicable(description: "unfold", command: "unfold",
                                       reason: "this device cannot fold", file: #file, line: #line)
    }

    private func statuses(_ core: FTDriveCore) -> [StepResult.Status] {
        core.finalRecord.scenes.flatMap(\.steps).map(\.status)
    }

    func testNotApplicableInsideBeforeAllIsAFailureThatNamesSetUpDevice() {
        withCore { core, sink in
            ftRunBeforeAll { declare(core) }
            XCTAssertNil(core.notApplicableReason, "beforeAll の中で対象外の理由が立った")
            XCTAssertTrue(core.scenarioAborted)
            guard case .failed(let message)? = statuses(core).first else {
                return XCTFail("失敗として記録されていない: \(statuses(core))")
            }
            XCTAssertTrue(message.hasPrefix("this device cannot fold — beforeAll() runs once per run"), message)
            XCTAssertTrue(message.contains("in setUpDevice() instead"), message)
            XCTAssertEqual(sink.events.filter { $0.kind == "beforeAll" }.compactMap(\.status), ["began", "failed"])
        }
    }

    func testNotApplicableInsideSetUpDeviceStaysNotApplicable() {
        withCore { core, sink in
            ftRunSetUpDevice { declare(core) }
            XCTAssertEqual(core.notApplicableReason, "this device cannot fold")
            guard case .skipped? = statuses(core).first else { return XCTFail("対象外になっていない: \(statuses(core))") }
            XCTAssertEqual(sink.events.filter { $0.kind == "deviceSetUp" }.compactMap(\.status), ["began", "notApplicable"])
        }
    }
}
