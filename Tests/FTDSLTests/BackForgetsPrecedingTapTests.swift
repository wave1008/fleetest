// 39周目 im4 F2: tap → back() → 検証の赤が「直前の tap は画面を変えなかった」と言った(直前の操作は back で、tap は画面を移していた)。
// back() で tap の前の画面へ戻ると木が tap の前と同じになるので、画面を移すコマンドの後は直前の tap の記録を捨てる

import XCTest
import FTCore
import FTTestSupport
@testable import FTDSL

final class BackForgetsPrecedingTapTests: XCTestCase {

    private final class FakeDriver: AppDriver, @unchecked Sendable {
        // テストのスレッドと DSL の FTSync の間で順に触るだけ(同時には触らない)
        let elements = [ElementInfo(ref: 1, type: "button", identifier: "nav_links", label: "リンク", value: nil,
                                    placeholder: nil, enabled: true,
                                    frame: FTRect(x: 10, y: 10, width: 100, height: 40), depth: 0)]
        func status() async throws -> StatusResponse {
            StatusResponse(ready: true, device: "stub", osVersion: "-", sessionBundleID: nil)
        }
        func install(packagePath: String) async throws -> String? { nil }
        func uninstall(bundleID: String) async throws {}
        func isAppForeground(bundleID: String) async throws -> Bool { true }
        func launch(bundleID: String) async throws {}
        func snapshot() async throws -> SnapshotResponse {
            SnapshotResponse(sessionBundleID: "com.example.app", screen: FTRect(x: 0, y: 0, width: 400, height: 800),
                             elements: elements, truncatedCount: 0)
        }
        func tap(ref: Int) async throws {}
        func tap(x: Double, y: Double) async throws {}
        func press(ref: Int, duration: Double) async throws {}
        func type(ref: Int?, text: String) async throws {}
        func swipe(_ direction: FTSwipeDirection) async throws {}
        func screenshot() async throws -> Data { Data([0x01]) }
        func terminate() async throws {}
        func back() async throws {}
    }

    private func failedDetail(withBack: Bool) -> String {
        let events = LockedValue<[ScenarioEvent]>([])
        let core = FTDriveCore(driver: FakeDriver(), platform: "android", app: "com.example.app",
                               scenarioID: "T.S0010", scenarioTitle: "t",
                               delegate: nil, healingEnabled: false, tunables: RunTunables(),
                               fmTextVisibilityCheckEnabled: false, occlusionOCREnabled: false, dryRun: false,
                               fingerprintCacheURL: URL(fileURLWithPath: NSTemporaryDirectory())
                                   .appendingPathComponent("ft-back-forgets-tap-test.json"),
                               emit: { event in events.withLock { $0.append(event) } })
        FTRuntime.bootstrap(core: core, dslThread: Thread.current)
        defer { FTRuntime.tearDown() }
        tap("#nav_links")
        if withBack { back() }
        select("#nav_links").textIs("リンクの先")
        return events.withLock { $0.filter { $0.kind == "step" && $0.status == "failed" }.compactMap(\.detail) }
            .joined(separator: "\n")
    }

    func testBackDropsThePrecedingTapFromTheFailure() {
        let control = failedDetail(withBack: false)
        XCTAssertTrue(control.contains("the preceding tap"), "対照(back なし)で注記が出ない = 検査が効いていない: \(control)")
        let afterBack = failedDetail(withBack: true)
        XCTAssertFalse(afterBack.isEmpty)
        XCTAssertFalse(afterBack.contains("the preceding tap"), "back の後に tap の話をした: \(afterBack)")
    }

    func testWaitKeepsThePrecedingTap() {
        XCTAssertTrue(FTDriveCore.screenMovingCommands.contains("back"))
        XCTAssertFalse(FTDriveCore.screenMovingCommands.contains("wait"), "tap → wait → 検証の証跡を消す")
    }
}
