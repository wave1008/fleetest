import Foundation
import XCTest
@testable import FTCore

/// Android で、このシナリオが止めたままのアプリの要素を探さずに断る(OI-181 ④: terminateApp() の後の tap(scroll:) がランチャーを 17 秒送った)
final class StoppedAppRefusalTests: XCTestCase {
    private func executor(isAndroid: Bool = true, running: Bool? = false) -> StepExecutor {
        let executor = StepExecutor(driver: LauncherDriver(), isAndroid: isAndroid, tunables: RunTunables())
        executor.appUnderTestBundleID = "com.example.app"
        executor.appUnderTestStopped = true
        executor.appProcessRunning = { _ in running }
        return executor
    }

    func testAppElementIsRefusedWithoutSearching() async {
        let outcome = await executor().execute(FlowStep(action: "tap", locator: FlowLocator(id: "nav_lifecycle"), timeout: 0.1))
        XCTAssertEqual(outcome.failureKind, .appStoppedBySession, "\(outcome.status)")
        guard case .failed(let message) = outcome.status else { return XCTFail("\(outcome.status)") }
        XCTAssertTrue(message.contains("launchApp()"), message)
    }

    func testWhatIsOnScreenIsStillTapped() async {
        let outcome = await executor().execute(FlowStep(action: "tap", locator: FlowLocator(label: "Chrome"), timeout: 0.1))
        XCTAssertTrue(StepExecutor.isSuccess(outcome.status), "ランチャーのアイコンを押すのは人にもできる: \(outcome.status)")
    }

    func testNotRefusedWhenRunningNegativeOrIOSOrNotStopped() async {
        let tap = FlowStep(action: "tap", locator: FlowLocator(id: "nav_lifecycle"), timeout: 0.1)
        let running = await executor(running: true).execute(tap)
        XCTAssertNotEqual(running.failureKind, .appStoppedBySession, "プロセスが居るのに断った")
        let unknown = await executor(running: nil).execute(tap)
        XCTAssertNotEqual(unknown.failureKind, .appStoppedBySession, "生死を答えられないのに断った")
        let negative = await executor().execute(FlowStep(assert: "notExists", locator: FlowLocator(id: "nav_lifecycle"), timeout: 0.1))
        XCTAssertTrue(StepExecutor.isSuccess(negative.status), "否定の検証を断った: \(negative.status)")
        let ios = await executor(isAndroid: false).execute(tap)
        XCTAssertNotEqual(ios.failureKind, .appStoppedBySession, "iOS は別の門")
        let notStopped = executor()
        notStopped.appUnderTestStopped = false
        let launched = await notStopped.execute(tap)
        XCTAssertNotEqual(launched.failureKind, .appStoppedBySession, "起動の手の後に断った")
    }
}

/// ランチャーの木(対象アプリの要素は無い)
private final class LauncherDriver: AppDriver {
    func snapshot() async throws -> SnapshotResponse {
        let icon = ElementInfo(ref: 1, type: "button", identifier: nil, label: "Chrome", value: nil, placeholder: nil, enabled: true,
                               frame: FTRect(x: 10, y: 100, width: 80, height: 80), depth: 0)
        return SnapshotResponse(sessionBundleID: "com.google.android.apps.nexuslauncher",
                                screen: FTRect(x: 0, y: 0, width: 400, height: 800), elements: [icon], truncatedCount: 0)
    }
    func status() async throws -> StatusResponse { StatusResponse(ready: true, device: "fake", osVersion: "-", sessionBundleID: nil) }
    func install(packagePath: String) async throws -> String? { nil }
    func uninstall(bundleID: String) async throws {}
    func launch(bundleID: String) async throws {}
    func isAppForeground(bundleID: String) async throws -> Bool { false }
    func tap(ref: Int) async throws {}
    func tap(x: Double, y: Double) async throws {}
    func type(ref: Int?, text: String) async throws {}
    func press(ref: Int, duration: Double) async throws {}
    func swipe(_ direction: FTSwipeDirection) async throws {}
    func screenshot() async throws -> Data { Data() }
    func terminate() async throws {}
}
