// 31周目: 「このシナリオが止めた」の印の寿命(アプリを起こしうる操作だけが消す)・iOS 実機(照会なし)の back / tapAppIcon の門・
// removeApp の後の案内(installApp)・止めたコマンドの取り違え。偽ドライバで production の DSL の経路を通す。

import XCTest
import FTCore
import FTTestSupport
@testable import FTDSL

final class StoppedAppMarkDSLTests: XCTestCase {

    private final class FakeDriver: AppDriver, @unchecked Sendable {
        // テストのスレッドと DSL の FTSync の間で順に触るだけ(同時には触らない)
        var elements: [ElementInfo] = [ElementInfo(ref: 1, type: "button", identifier: "a", label: nil, value: nil,
                                                   placeholder: nil, enabled: true,
                                                   frame: FTRect(x: 10, y: 10, width: 100, height: 40), depth: 0)]
        private(set) var launched: [String] = []
        private(set) var backCount = 0
        private(set) var tappedRefs: [Int] = []
        func status() async throws -> StatusResponse {
            StatusResponse(ready: true, device: "stub", osVersion: "-", sessionBundleID: nil)
        }
        func install(packagePath: String) async throws -> String? { nil }
        func uninstall(bundleID: String) async throws {}
        func isAppForeground(bundleID: String) async throws -> Bool { true }
        func launch(bundleID: String) async throws { launched.append(bundleID) }
        func openURL(_ url: String, bundleID: String?) async throws {}
        func snapshot() async throws -> SnapshotResponse {
            SnapshotResponse(sessionBundleID: "com.example.app", screen: FTRect(x: 0, y: 0, width: 400, height: 800),
                             elements: elements, truncatedCount: 0)
        }
        func tap(ref: Int) async throws { tappedRefs.append(ref) }
        func tap(x: Double, y: Double) async throws {}
        func press(ref: Int, duration: Double) async throws {}
        func type(ref: Int?, text: String) async throws {}
        func swipe(_ direction: FTSwipeDirection) async throws {}
        func screenshot() async throws -> Data { Data([0x01]) }
        func terminate() async throws {}
        func back() async throws { backCount += 1 }
    }

    private static let bundle = "com.example.app"
    private static let iconName = "Example"

    private func androidCore(_ driver: FakeDriver, events: LockedValue<[ScenarioEvent]>) -> FTDriveCore {
        let core = FTDriveCore(driver: driver, platform: "android", app: Self.bundle,
                               scenarioID: "T.S0010", scenarioTitle: "t",
                               delegate: nil, healingEnabled: false, tunables: RunTunables(),
                               fmTextVisibilityCheckEnabled: false, occlusionOCREnabled: false, dryRun: false,
                               fingerprintCacheURL: URL(fileURLWithPath: NSTemporaryDirectory())
                                   .appendingPathComponent("ft-stopped-mark-test.json"),
                               emit: { event in events.withLock { $0.append(event) } })
        core.appProcessEvidence = { _ in ["process not running"] }
        return core
    }

    /// inapp-boost モードの組み立て。alive == nil かつ probe == false なら照会そのものが無い(実機)
    private func iosCore(primary: FakeDriver, springBoard: FakeDriver, probe: (@Sendable (String) async -> Bool?)?,
                         events: LockedValue<[ScenarioEvent]>) -> FTDriveCore {
        let core = FTDriveCore(driver: primary, platform: "ios", app: Self.bundle,
                               scenarioID: "T.S0010", scenarioTitle: "t",
                               delegate: nil, healingEnabled: false, tunables: RunTunables(), dryRun: false,
                               fingerprintCacheURL: URL(fileURLWithPath: NSTemporaryDirectory())
                                   .appendingPathComponent("ft-stopped-mark-test.json"),
                               fallbackDriver: springBoard, primaryCaptureOmitsSystemUI: true,
                               typeDriver: FakeDriver(), emit: { event in events.withLock { $0.append(event) } })
        core.appDisplayName = Self.iconName
        core.appAliveProbe = probe
        return core
    }

    private func logs(_ events: LockedValue<[ScenarioEvent]>) -> [String] {
        events.withLock { $0.filter { $0.kind == "log" }.compactMap(\.message) }
    }

    private func failedDetails(_ events: LockedValue<[ScenarioEvent]>) -> [String] {
        events.withLock { $0.filter { $0.kind == "step" && $0.status == "failed" }.compactMap(\.detail) }
    }

    // MARK: 1. 印の寿命

    /// Android の back / swipe(アプリを起こさない)を挟んでも印は残り、続く赤は「止めた」と言って「クラッシュしたかも」と言わない
    func testNonWakingStepsKeepTheStoppedMark() {
        let events = LockedValue<[ScenarioEvent]>([])
        let core = androidCore(FakeDriver(), events: events)
        FTRuntime.bootstrap(core: core, dslThread: Thread.current)
        defer { FTRuntime.tearDown() }

        launchApp()
        terminateApp()
        back()
        swipe(.up)
        XCTAssertTrue(core.appStoppedByScenario)
        XCTAssertEqual(core.appStoppedCommand, "terminateApp")
        exist("#gone", waitSeconds: 0)

        let lines = logs(events)
        XCTAssertTrue(lines.contains { $0.contains("this scenario stopped it with terminateApp()") }, "\(lines)")
        XCTAssertFalse(lines.contains { $0.contains("may have crashed") }, "\(lines)")
    }

    /// 反対の向き: アプリを起こしうる操作(tap・openURL・launchApp)は印を消し、続く赤は従来どおり死の証拠を言う
    func testWakingStepsClearTheStoppedMark() {
        for wake in [{ tap("#a") }, { openURL("myapp://x") }, { launchApp() }] as [() -> Void] {
            let events = LockedValue<[ScenarioEvent]>([])
            let core = androidCore(FakeDriver(), events: events)
            FTRuntime.bootstrap(core: core, dslThread: Thread.current)
            defer { FTRuntime.tearDown() }

            launchApp()
            terminateApp()
            XCTAssertTrue(core.appStoppedByScenario)
            wake()
            XCTAssertFalse(core.appStoppedByScenario)
        }
    }

    // MARK: 2. iOS 実機(照会なし)





    // MARK: 4. removeApp の後の案内

    func testBackAfterRemoveAppPointsAtInstallAppNotLaunchApp() {
        let (primary, springBoard) = (FakeDriver(), FakeDriver())
        let events = LockedValue<[ScenarioEvent]>([])
        let core = iosCore(primary: primary, springBoard: springBoard, probe: nil, events: events)
        FTRuntime.bootstrap(core: core, dslThread: Thread.current)
        defer { FTRuntime.tearDown() }

        launchApp()
        removeApp()
        back()

        let details = failedDetails(events)
        XCTAssertTrue(details.contains { $0.contains("installApp()") && !$0.contains("Launch it first") }, "\(details)")
    }

    func testAndroidRefusalAfterRemoveAppPointsAtInstallApp() {
        let events = LockedValue<[ScenarioEvent]>([])
        let core = androidCore(FakeDriver(), events: events)
        core.appProcessRunning = { _ in false }
        FTRuntime.bootstrap(core: core, dslThread: Thread.current)
        defer { FTRuntime.tearDown() }

        launchApp()
        removeApp()
        tap("#missing", waitSeconds: 0)

        let details = failedDetails(events)
        XCTAssertTrue(details.contains { $0.contains("installApp()") }, "\(details)")
    }

    func testAndroidRefusalAfterTerminateAppStillSaysLaunchApp() {
        let events = LockedValue<[ScenarioEvent]>([])
        let core = androidCore(FakeDriver(), events: events)
        core.appProcessRunning = { _ in false }
        FTRuntime.bootstrap(core: core, dslThread: Thread.current)
        defer { FTRuntime.tearDown() }

        launchApp()
        terminateApp()
        tap("#missing", waitSeconds: 0)

        let details = failedDetails(events)
        XCTAssertTrue(details.contains { $0.contains("Launch it first (launchApp())") }, "\(details)")
    }

    // MARK: 5. 止めたコマンドの取り違え

    /// ドライバ層の「自分で止めた」の文は、止めたコマンドを名指さない(clearAppData でも terminateApp と言っていた)
    func testStoppedBySessionFateMessageNamesNoCommand() {
        let context = DriverErrorContext(bridge: .iosInApp, physicalDevice: false, appFate: .stoppedBySession)
        let text = DriverErrorMessage.unreachable(context: context, detail: "")
        XCTAssertTrue(text.contains("this session stopped it"), text)
        XCTAssertFalse(text.contains("terminateApp"), text)
    }
}
