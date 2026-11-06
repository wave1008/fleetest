import XCTest
@testable import FTDSL
import FTCore
import FTTestSupport

/// `terminateApp()` で止めた対象アプリの扱い(OI-183・OI-169)。iOS の inapp-boost モードでは、アイコンや XCUITest の activate から
/// 起きたアプリに in-app ブリッジが載らない。back() は止めた後に生死を聞いて断り、tapAppIcon() は押さずに注入付きで起動する。
/// 失敗の時点にアプリが居なかった事実(processGone)は、このシナリオが起こしてその後止めていないときだけ記録してよい
final class StoppedAppRelaunchTests: XCTestCase {

    private final class FakeDriver: AppDriver, @unchecked Sendable {
        // テストのスレッドと DSL の FTSync の間で順に触るだけ(同時には触らない)
        var elements: [ElementInfo] = []
        var foreground = true
        private(set) var launched: [String] = []
        private(set) var backCount = 0
        private(set) var tappedRefs: [Int] = []

        func status() async throws -> StatusResponse {
            StatusResponse(ready: true, device: "stub", osVersion: "-", sessionBundleID: nil)
        }
        func install(packagePath: String) async throws -> String? { nil }
        func uninstall(bundleID: String) async throws {}
        func isAppForeground(bundleID: String) async throws -> Bool { foreground }
        func launch(bundleID: String) async throws { launched.append(bundleID) }
        func openURL(_ url: String, bundleID: String?) async throws {}
        func snapshot() async throws -> SnapshotResponse {
            SnapshotResponse(sessionBundleID: nil, screen: FTRect(x: 0, y: 0, width: 400, height: 800),
                             elements: elements, truncatedCount: 0)
        }
        func tap(ref: Int) async throws { tappedRefs.append(ref) }
        func tap(x: Double, y: Double) async throws {}
        func press(x: Double, y: Double, duration: Double) async throws {}
        func press(ref: Int, duration: Double) async throws {}
        func type(ref: Int?, text: String) async throws {}
        func pressEnter() async throws {}
        func swipe(_ direction: FTSwipeDirection) async throws {}
        func screenshot() async throws -> Data { Data([0x01]) }
        func terminate() async throws {}
        func home() async throws {}
        func back() async throws { backCount += 1 }
    }

    private static let bundle = "com.example.app"
    private static let iconName = "Example"

    private final class ProbeLog: @unchecked Sendable {
        private let lock = NSLock()
        private var _calls = 0
        var calls: Int { lock.withLock { _calls } }
        func hit() { lock.withLock { _calls += 1 } }
    }

    /// inapp-boost モードの組み立て(主 = in-app、typeDriver = XCUITest のセッション、fallback = SpringBoard)
    private func makeCore(primary: FakeDriver, xcui: FakeDriver, springBoard: FakeDriver,
                          alive: Bool?, probe: ProbeLog) -> FTDriveCore {
        let core = FTDriveCore(driver: primary, platform: "ios", app: Self.bundle,
                               scenarioID: "T.S0010", scenarioTitle: "t",
                               delegate: nil, healingEnabled: false, tunables: RunTunables(), dryRun: false,
                               fingerprintCacheURL: URL(fileURLWithPath: NSTemporaryDirectory())
                                   .appendingPathComponent("ft-stopped-app-test.json"),
                               fallbackDriver: springBoard, primaryCaptureOmitsSystemUI: true,
                               typeDriver: xcui, emit: { _ in })
        core.appDisplayName = Self.iconName
        core.appAliveProbe = { _ in probe.hit(); return alive }
        return core
    }

    private func homeScreen() -> [ElementInfo] {
        [ElementInfo(ref: 7, type: "icon", identifier: nil, label: Self.iconName, value: nil, placeholder: nil,
                     enabled: true, frame: FTRect(x: 100, y: 100, width: 60, height: 60), depth: 0)]
    }

    func testBackAfterTerminateIsRefusedWhileTheAppIsGone() {
        let (primary, xcui, springBoard, probe) = (FakeDriver(), FakeDriver(), FakeDriver(), ProbeLog())
        let core = makeCore(primary: primary, xcui: xcui, springBoard: springBoard, alive: false, probe: probe)
        FTRuntime.bootstrap(core: core, dslThread: Thread.current)
        defer { FTRuntime.tearDown() }

        scenario { scene(1, "s") { action { launchApp(); terminateApp(); back() } } }

        XCTAssertEqual(xcui.backCount + primary.backCount, 0, "動いていない対象アプリへ back を撃つと、アプリをブリッジ無しで起こす")
        XCTAssertEqual(probe.calls, 1)
    }

    func testBackAfterTerminateFiresWhenTheAppRunsAgain() {
        let (primary, xcui, springBoard, probe) = (FakeDriver(), FakeDriver(), FakeDriver(), ProbeLog())
        let core = makeCore(primary: primary, xcui: xcui, springBoard: springBoard, alive: true, probe: probe)
        FTRuntime.bootstrap(core: core, dslThread: Thread.current)
        defer { FTRuntime.tearDown() }

        scenario { scene(1, "s") { action { launchApp(); terminateApp(); back() } } }

        XCTAssertEqual(xcui.backCount + primary.backCount, 1)
    }

    /// 止めていないシナリオの back は生死を聞かない(simctl の照会を back のたびに払わない)
    func testBackWithoutStoppingDoesNotProbe() {
        let (primary, xcui, springBoard, probe) = (FakeDriver(), FakeDriver(), FakeDriver(), ProbeLog())
        let core = makeCore(primary: primary, xcui: xcui, springBoard: springBoard, alive: false, probe: probe)
        FTRuntime.bootstrap(core: core, dslThread: Thread.current)
        defer { FTRuntime.tearDown() }

        scenario { scene(1, "s") { action { launchApp(); back() } } }

        XCTAssertEqual(probe.calls, 0)
        XCTAssertEqual(xcui.backCount + primary.backCount, 1)
    }

    func testTapAppIconLaunchesWithTheBridgeInsteadOfTappingWhenTheAppIsGone() {
        let (primary, xcui, springBoard, probe) = (FakeDriver(), FakeDriver(), FakeDriver(), ProbeLog())
        springBoard.elements = homeScreen()
        let core = makeCore(primary: primary, xcui: xcui, springBoard: springBoard, alive: false, probe: probe)
        FTRuntime.bootstrap(core: core, dslThread: Thread.current)
        defer { FTRuntime.tearDown() }

        scenario { scene(1, "s") { action { launchApp(); terminateApp(); tapAppIcon() } } }

        XCTAssertEqual(primary.launched, [Self.bundle, Self.bundle], "2回目の起動は注入付き(主ドライバ)")
        XCTAssertEqual(springBoard.tappedRefs, [], "アイコンから起きたアプリには in-app ブリッジが載らない")
        XCTAssertEqual(core.appUnderTestLife, .launched)
    }

    func testTapAppIconTapsTheIconWhenTheAppIsAlive() {
        let (primary, xcui, springBoard, probe) = (FakeDriver(), FakeDriver(), FakeDriver(), ProbeLog())
        springBoard.elements = homeScreen()
        let core = makeCore(primary: primary, xcui: xcui, springBoard: springBoard, alive: true, probe: probe)
        FTRuntime.bootstrap(core: core, dslThread: Thread.current)
        defer { FTRuntime.tearDown() }

        scenario { scene(1, "s") { action { launchApp(); home(); tapAppIcon() } } }

        XCTAssertEqual(primary.launched, [Self.bundle])
        XCTAssertEqual(springBoard.tappedRefs, [7])
    }

    /// processGone を記録してよいのは「このシナリオが対象アプリを起こし、その後止めていない」ときだけ。
    /// 止めた後にアプリを起こさないステップ(home 等)が通っても、止めた印は残る(起こしうる操作だけが解く)
    func testProcessGoneMayBeRecordedOnlyWhileTheLaunchedAppWasNotStopped() {
        func flagAtFailure(_ body: @escaping () -> Void) -> Bool? {
            let (primary, xcui, springBoard, probe) = (FakeDriver(), FakeDriver(), FakeDriver(), ProbeLog())
            let core = makeCore(primary: primary, xcui: xcui, springBoard: springBoard, alive: true, probe: probe)
            let seen = LockedValue<Bool?>(nil)
            core.appProcessEvidence = { flag in seen.withLock { $0 = flag }; return [] }
            FTRuntime.bootstrap(core: core, dslThread: Thread.current)
            defer { FTRuntime.tearDown() }
            scenario { scene(1, "s") { action { body(); exist("#missing", waitSeconds: 0) } } }
            return seen.withLock { $0 }
        }
        XCTAssertEqual(flagAtFailure { launchApp() }, true)
        // home() はアプリを起こさないので「止めた」の印が残る = 証拠を読みに行かない(居ないのは当然)
        XCTAssertNil(flagAtFailure { launchApp(); terminateApp(); home() })
        XCTAssertEqual(flagAtFailure { launchApp("com.apple.Preferences") }, false, "対象アプリを起こしていない")
    }
    /// 実機(生死の照会が無い)でも、止めたまま起こしうる操作が無ければ back は撃たない(31周目 phys F1)
    func testBackAfterTerminateIsRefusedWhenTheAppCannotBeProbed() {
        let (primary, xcui, springBoard, probe) = (FakeDriver(), FakeDriver(), FakeDriver(), ProbeLog())
        let core = makeCore(primary: primary, xcui: xcui, springBoard: springBoard, alive: false, probe: probe)
        core.appAliveProbe = nil
        FTRuntime.bootstrap(core: core, dslThread: Thread.current)
        defer { FTRuntime.tearDown() }

        scenario { scene(1, "s") { action { launchApp(); terminateApp(); back() } } }

        XCTAssertEqual(xcui.backCount + primary.backCount, 0, "照会の無い実機で止めたアプリへ back を撃った")
    }

    /// 照会が無くても、止めた後に起こしうる操作(launchApp)を撃っていれば back は撃つ
    func testBackAfterRelaunchFiresWhenTheAppCannotBeProbed() {
        let (primary, xcui, springBoard, probe) = (FakeDriver(), FakeDriver(), FakeDriver(), ProbeLog())
        let core = makeCore(primary: primary, xcui: xcui, springBoard: springBoard, alive: false, probe: probe)
        core.appAliveProbe = nil
        FTRuntime.bootstrap(core: core, dslThread: Thread.current)
        defer { FTRuntime.tearDown() }

        scenario { scene(1, "s") { action { launchApp(); terminateApp(); launchApp(); back() } } }

        XCTAssertEqual(xcui.backCount + primary.backCount, 1)
    }

    /// 実機(照会なし)で止めたままの tapAppIcon は、アイコンを押さず注入付きで起動する(31周目 phys F2)
    func testTapAppIconLaunchesWithTheBridgeWhenStoppedAndTheAppCannotBeProbed() {
        let (primary, xcui, springBoard, probe) = (FakeDriver(), FakeDriver(), FakeDriver(), ProbeLog())
        springBoard.elements = homeScreen()
        let core = makeCore(primary: primary, xcui: xcui, springBoard: springBoard, alive: false, probe: probe)
        core.appAliveProbe = nil
        FTRuntime.bootstrap(core: core, dslThread: Thread.current)
        defer { FTRuntime.tearDown() }

        scenario { scene(1, "s") { action { launchApp(); terminateApp(); tapAppIcon() } } }

        XCTAssertEqual(primary.launched, [Self.bundle, Self.bundle])
        XCTAssertEqual(springBoard.tappedRefs, [])
    }

    /// 止めていなければ、照会が無くてもアイコンを押す
    func testTapAppIconTapsWhenNotStoppedAndTheAppCannotBeProbed() {
        let (primary, xcui, springBoard, probe) = (FakeDriver(), FakeDriver(), FakeDriver(), ProbeLog())
        springBoard.elements = homeScreen()
        let core = makeCore(primary: primary, xcui: xcui, springBoard: springBoard, alive: true, probe: probe)
        core.appAliveProbe = nil
        FTRuntime.bootstrap(core: core, dslThread: Thread.current)
        defer { FTRuntime.tearDown() }

        scenario { scene(1, "s") { action { launchApp(); home(); tapAppIcon() } } }

        XCTAssertEqual(springBoard.tappedRefs, [7])
    }
}
