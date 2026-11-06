import Foundation
import XCTest
@testable import FTCore

/// 32周目: 止めた後の「無い」の注記の帰属(amax F2・alocal F2)・送りの門(amax F3)・pressEnter の対処(amax 回し直し)・
/// 手前のダイアログの名指し(amax F1)。偽ドライバで production の経路(`execute`)を通す
final class Round32AndroidStopAndSendTests: XCTestCase {
    private let app = "com.example.app"
    private let launcher = "com.google.android.apps.nexuslauncher"

    private func executor(stopped: Bool = true, command: String? = "terminateApp", running: Bool? = false,
                          driver: StopTestDriver = StopTestDriver()) -> StepExecutor {
        let executor = StepExecutor(driver: driver, isAndroid: true, tunables: RunTunables())
        executor.appUnderTestBundleID = app
        executor.appUnderTestStopped = stopped
        executor.appUnderTestStoppedCommand = stopped ? command : nil
        executor.appProcessRunning = { _ in running }
        return executor
    }

    // MARK: 注記の帰属

    func testAbsenceAfterStopStaysGreenAndNamesTheOwnerNotAScenarioLaunch() async {
        let outcome = await executor().execute(FlowStep(assert: "notExists", locator: FlowLocator(id: "missing"), timeout: 0.1))
        XCTAssertTrue(StepExecutor.isSuccess(outcome.status), "合否は変えない(OI-182): \(outcome.status)")
        XCTAssertTrue(outcome.notes.contains(.absenceCheckedOnAnotherApp), "\(outcome.notes)")
        let text = outcome.driverFallback ?? ""
        XCTAssertTrue(text.contains("was stopped by this scenario (terminateApp())"), text)
        XCTAssertTrue(text.contains(launcher), "持ち主を言う: \(text)")
        XCTAssertFalse(text.contains("launched by the scenario"), "シナリオが起こしたとは言わない: \(text)")
        XCTAssertTrue(text.contains("Launch it first (launchApp())"), text)
    }

    func testRemoveAppAdvisesInstallAndNotStoppedKeepsTheOriginalText() async {
        let removed = await executor(command: "removeApp").execute(
            FlowStep(assert: "notExists", locator: FlowLocator(id: "missing"), timeout: 0.1))
        XCTAssertTrue((removed.driverFallback ?? "").contains("installApp()"), removed.driverFallback ?? "nil")
        // 止めていない(別アプリを起こして居る)なら従来の文
        let other = executor(stopped: false, running: true)
        let outcome = await other.execute(FlowStep(assert: "notExists", locator: FlowLocator(id: "missing"), timeout: 0.1))
        XCTAssertTrue(outcome.notes.contains(.absenceCheckedOnAnotherApp), "\(outcome.notes)")
        XCTAssertTrue((outcome.driverFallback ?? "").contains("not the app under test"), outcome.driverFallback ?? "nil")
    }

    // MARK: 送りの門

    func testScrollSendsAreRefusedWhileStoppedWithoutSwiping() async {
        for step in [FlowStep(action: "scroll", direction: "down"),
                     FlowStep(action: "scrollToEdge", direction: "down", maxSwipes: 3)] {
            let driver = StopTestDriver()
            let outcome = await executor(driver: driver).execute(step)
            XCTAssertEqual(outcome.failureKind, .appStoppedBySession, "\(step.action ?? ""): \(outcome.status)")
            XCTAssertEqual(driver.swipes, 0, "断る前に撃った")
            guard case .failed(let message) = outcome.status else { return XCTFail("\(outcome.status)") }
            XCTAssertTrue(message.contains("sent nothing"), message)
            XCTAssertTrue(message.contains("launchApp()"), message)
        }
    }

    func testScrollToIsRefusedOnlyWhenTheTargetIsNotOnScreen() async {
        let absent = await executor().execute(FlowStep(action: "scrollTo", locator: FlowLocator(id: "nav_pin"), direction: "down", timeout: 0.1))
        XCTAssertEqual(absent.failureKind, .appStoppedBySession, "\(absent.status)")
        let present = await executor().execute(FlowStep(action: "scrollTo", locator: FlowLocator(label: "Chrome"), direction: "down", timeout: 0.1))
        XCTAssertNotEqual(present.failureKind, .appStoppedBySession, "画面にある対象まで断った: \(present.status)")
    }

    func testScrollSendIsNotRefusedWhenRunningNotStoppedOrIOS() async {
        let scroll = FlowStep(action: "scroll", direction: "down")
        let running = await executor(running: true).execute(scroll)
        XCTAssertNotEqual(running.failureKind, .appStoppedBySession, "プロセスが居るのに断った")
        let unknown = await executor(running: nil).execute(scroll)
        XCTAssertNotEqual(unknown.failureKind, .appStoppedBySession, "生死が分からないのに断った")
        let notStopped = await executor(stopped: false).execute(scroll)
        XCTAssertNotEqual(notStopped.failureKind, .appStoppedBySession, "起動の手の後に断った")
        let ios = StepExecutor(driver: StopTestDriver(), isAndroid: false, tunables: RunTunables())
        ios.appUnderTestBundleID = app
        ios.appUnderTestStopped = true
        ios.appProcessRunning = { _ in false }
        let iosOutcome = await ios.execute(scroll)
        XCTAssertNotEqual(iosOutcome.failureKind, .appStoppedBySession, "iOS は別の門")
    }

    func testScrollAfterHomeIsRefusedAsLeftTheApp() async {
        let driver = StopTestDriver(front: launcher)
        let executor = StepExecutor(driver: driver, fallbackDriver: nil, isAndroid: true, tunables: RunTunables())
        executor.appUnderTestBundleID = app
        executor.noteAppLaunched(bundleID: app)
        executor.noteAppMayHaveLeft(true)
        for step in [FlowStep(action: "scroll", direction: "down", timeout: 0.1),
                     FlowStep(action: "scrollToEdge", direction: "down", timeout: 0.1, maxSwipes: 3)] {
            let outcome = await executor.execute(step)
            XCTAssertEqual(outcome.failureKind, .appInBackground, "\(step.action ?? ""): \(outcome.status)")
        }
        XCTAssertEqual(driver.swipes, 0, "断る前に撃った")
        // 前面が対象アプリなら撃つ
        let front = StopTestDriver(front: app)
        let ok = StepExecutor(driver: front, fallbackDriver: nil, isAndroid: true, tunables: RunTunables())
        ok.appUnderTestBundleID = app
        ok.noteAppLaunched(bundleID: app)
        ok.noteAppMayHaveLeft(true)
        let outcome = await ok.execute(FlowStep(action: "scroll", direction: "down", timeout: 0.1))
        XCTAssertNotEqual(outcome.failureKind, .appInBackground, "\(outcome.status)")
    }

    // MARK: pressEnter

    func testPressEnterAdviceAfterStopDoesNotSayTapTheField() {
        let stopped = StepExecutor.pressEnterRefusalAdvice(isAndroid: true, stopped: true, stoppedCommand: "removeApp")
        XCTAssertTrue(stopped.contains("removeApp()") && stopped.contains("installApp()"), stopped)
        XCTAssertFalse(stopped.contains("tap the field"), stopped)
        let terminated = StepExecutor.pressEnterRefusalAdvice(isAndroid: true, stopped: true, stoppedCommand: "terminateApp")
        XCTAssertTrue(terminated.contains("launchApp()"), terminated)
        XCTAssertTrue(StepExecutor.pressEnterRefusalAdvice(isAndroid: true, stopped: false, stoppedCommand: nil)
            .contains("tap the field before pressing Enter again"))
        XCTAssertEqual(StepExecutor.pressEnterRefusalAdvice(isAndroid: false, stopped: false, stoppedCommand: nil), "")
    }

    func testPressEnterThroughTheExecutorUsesTheStoppedAdvice() async {
        let driver = StopTestDriver()
        driver.pressEnterError = DriverError.badResponse(status: 409, body: "no focused field")
        let outcome = await executor(command: "removeApp", driver: driver).execute(FlowStep(action: "pressEnter"))
        guard case .failed(let message) = outcome.status else { return XCTFail("\(outcome.status)") }
        XCTAssertFalse(message.contains("tap the field"), message)
        XCTAssertTrue(message.contains("installApp()"), message)
    }

    // MARK: 手前のダイアログ

    func testOwnDialogHintNamesTheDialogAndNotWaiting() {
        let lines = ["\(app)/\(app).MainActivity \(StepExecutor.ownDialogWindowMarker)", "NotificationShade"]
        let hint = StepExecutor.ownDialogHint(windows: lines) ?? ""
        XCTAssertTrue(hint.contains("MainActivity"), hint)
        XCTAssertTrue(hint.contains("close the dialog"), hint)
        XCTAssertFalse(hint.contains("add waitSeconds"), hint)
        XCTAssertNil(StepExecutor.ownDialogHint(windows: ["NotificationShade"]), "ダイアログでない窓は名指さない")
        XCTAssertNil(StepExecutor.ownDialogHint(windows: []))
    }

    func testUnresolvedTapWithOwnDialogDoesNotAdviseWaitSeconds() async {
        let withDialog = executor(stopped: false, running: true)
        withDialog.foregroundWindowLines = { _ in ["\("com.example.app")/x.MainActivity \(StepExecutor.ownDialogWindowMarker)"] }
        let outcome = await withDialog.execute(FlowStep(action: "tap", locator: FlowLocator(id: "btn_open_panel")))
        guard case .failed(let message) = outcome.status else { return XCTFail("\(outcome.status)") }
        XCTAssertTrue(message.contains("own dialog window"), message)
        XCTAssertFalse(message.contains("add waitSeconds"), message)
        let plain = executor(stopped: false, running: true)
        let usual = await plain.execute(FlowStep(action: "tap", locator: FlowLocator(id: "btn_open_panel")))
        guard case .failed(let usualMessage) = usual.status else { return XCTFail("\(usual.status)") }
        XCTAssertTrue(usualMessage.contains("add waitSeconds"), "ダイアログが無ければ従来の文: \(usualMessage)")
    }
}

/// ランチャーの木(対象アプリの要素は無い)。`front` は前面の答え(nil = 答えない)
final class StopTestDriver: AppDriver {
    let front: String?
    private(set) var swipes = 0
    var pressEnterError: Error?
    init(front: String? = nil) { self.front = front }
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
    func isAppForeground(bundleID: String) async throws -> Bool { bundleID == front }
    func tap(ref: Int) async throws {}
    func tap(x: Double, y: Double) async throws {}
    func type(ref: Int?, text: String) async throws {}
    func press(ref: Int, duration: Double) async throws {}
    func swipe(_ direction: FTSwipeDirection) async throws { swipes += 1 }
    func pressEnter() async throws { if let pressEnterError { throw pressEnterError } }
    func screenshot() async throws -> Data { Data() }
    func terminate() async throws {}
}
