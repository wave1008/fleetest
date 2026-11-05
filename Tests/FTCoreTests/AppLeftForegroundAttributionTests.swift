// inapp-boost モードでアプリが前面を離れた後のステップ(17周目の探索):
// ①背面で iOS に一時停止された in-app ブリッジの無応答を「ブリッジ不達」と言わず、アプリが背面にあると言う(iultra F1・im4 F1)
// ②appSwitcher() の後、スイッチャーが前面の間はアプリを読む・触るステップを撃たずに断る(ilocal F1)

import XCTest
@testable import FTCore

/// in-app ブリッジの役。読みも操作も「届かない」で投げる(一時停止されたアプリの中のブリッジ)か、成功する
private final class SuspendableInAppDriver: AppDriver {
    var suspended = false
    /// true = プロセスが居ない(報告より先に落ちた形)。InAppDriver は生きていると確かめられないので appFate を付けない
    var crashed = false
    private(set) var taps = 0
    private func unreachable() -> DriverError {
        .bridgeUnreachable(context: DriverErrorContext(bridge: .iosInApp, physicalDevice: false,
                                                       appFate: crashed ? nil : .aliveButNotAnswering), detail: "timed out")
    }
    func status() async throws -> StatusResponse {
        StatusResponse(ready: true, device: "fake", osVersion: "-", sessionBundleID: nil)
    }
    func install(packagePath: String) async throws -> String? { nil }
    func uninstall(bundleID: String) async throws {}
    func launch(bundleID: String) async throws {}
    func isAppForeground(bundleID: String) async throws -> Bool { true }
    func terminate() async throws {}
    func screenshot() async throws -> Data { Data() }
    func type(ref: Int?, text: String) async throws {}
    func tap(ref: Int) async throws { if suspended { throw unreachable() }; taps += 1 }
    func tap(x: Double, y: Double) async throws { if suspended { throw unreachable() }; taps += 1 }
    func press(ref: Int, duration: Double) async throws {}
    func swipe(_ direction: FTSwipeDirection) async throws {}
    func drag(fromX: Double, fromY: Double, toX: Double, toY: Double,
              pressSeconds: Double, durationSeconds: Double) async throws {}
    func snapshot() async throws -> SnapshotResponse {
        if suspended { throw unreachable() }
        return SnapshotResponse(
            sessionBundleID: "com.example.app", screen: FTRect(x: 0, y: 0, width: 400, height: 800),
            elements: [ElementInfo(ref: 1, type: "button", identifier: "btn", label: "Go", value: nil, placeholder: nil,
                                   enabled: true, frame: FTRect(x: 16, y: 40, width: 100, height: 56), depth: 0)],
            truncatedCount: 0)
    }
}

/// XCUITest ブリッジの役。前面のアプリと SpringBoard の覆いを答える
private final class ForegroundAnsweringDriver: AppDriver {
    var appInFront: Bool?
    var front: String?
    var covering: Probe<SystemUICoveringResponse> = .notAnswerable
    func status() async throws -> StatusResponse {
        StatusResponse(ready: true, device: "fake", osVersion: "-", sessionBundleID: nil)
    }
    func install(packagePath: String) async throws -> String? { nil }
    func uninstall(bundleID: String) async throws {}
    func launch(bundleID: String) async throws {}
    func isAppForeground(bundleID: String) async throws -> Bool {
        guard let appInFront else { throw DriverError.badResponse(status: 500, body: "no answer") }
        return appInFront
    }
    func foregroundAppID() async -> Probe<String> { front.map { .value($0) } ?? .notAnswerable }
    func systemUICovering() async -> Probe<SystemUICoveringResponse> { covering }
    func terminate() async throws {}
    func screenshot() async throws -> Data { Data() }
    func type(ref: Int?, text: String) async throws {}
    func tap(ref: Int) async throws {}
    func tap(x: Double, y: Double) async throws {}
    func press(ref: Int, duration: Double) async throws {}
    func swipe(_ direction: FTSwipeDirection) async throws {}
    func drag(fromX: Double, fromY: Double, toX: Double, toY: Double,
              pressSeconds: Double, durationSeconds: Double) async throws {}
    func snapshot() async throws -> SnapshotResponse {
        SnapshotResponse(sessionBundleID: "com.apple.springboard", screen: FTRect(x: 0, y: 0, width: 400, height: 800),
                         elements: [], truncatedCount: 0)
    }
}

final class AppLeftForegroundAttributionTests: XCTestCase {
    private func make() -> (StepExecutor, SuspendableInAppDriver, ForegroundAnsweringDriver) {
        let inApp = SuspendableInAppDriver()
        let xcuitest = ForegroundAnsweringDriver()
        let executor = StepExecutor(driver: inApp, fallbackDriver: xcuitest, isAndroid: false, tunables: RunTunables())
        executor.noteAppLaunched(bundleID: "com.example.app")
        return (executor, inApp, xcuitest)
    }

    // MARK: - ① 背面で一時停止された in-app ブリッジ

    /// home の後(launchedBundleID は消える)でも、XCUITest が前面に無いと答えたら背面と言い、ブリッジ不達にしない
    func testUnreachableInAppBridgeOfABackgroundedAppIsAttributedToTheBackground() async {
        let (executor, inApp, xcuitest) = make()
        executor.launchedBundleID = nil
        inApp.suspended = true
        xcuitest.appInFront = false
        xcuitest.front = "com.apple.mobilesafari"
        let outcome = await executor.execute(FlowStep(action: "tap", locator: FlowLocator(id: "btn"), timeout: 1))
        guard case .failed(let message) = outcome.status else { return XCTFail("\(outcome.status)") }
        XCTAssertEqual(outcome.failureKind, .appInBackground)
        XCTAssertTrue(message.contains("is in the background, so iOS suspended it"), message)
        XCTAssertFalse(message.contains("bridge up"), message)
    }

    /// 前面にいるのに答えない(本当に固まった in-app ブリッジ)はブリッジ不達のまま
    func testUnreachableInAppBridgeOfAForegroundAppStaysDriverUnreachable() async {
        let (executor, inApp, xcuitest) = make()
        inApp.suspended = true
        xcuitest.appInFront = true
        let outcome = await executor.execute(FlowStep(action: "tap", locator: FlowLocator(id: "btn"), timeout: 1))
        XCTAssertEqual(outcome.failureKind, .driverUnreachable)
    }

    /// プロセスが生きていると確かめられていない(落ちた・実機)なら、前面に無くても背面とは言わない
    func testAppNotKnownToBeAliveIsNotCalledBackgrounded() async {
        let (executor, inApp, xcuitest) = make()
        inApp.suspended = true
        inApp.crashed = true
        xcuitest.appInFront = false
        let outcome = await executor.execute(FlowStep(action: "tap", locator: FlowLocator(id: "btn"), timeout: 1))
        XCTAssertEqual(outcome.failureKind, .driverUnreachable)
    }

    /// 同じシナリオにブリッジ不達があれば、run はそちら(生存プローブ・振り直し)を優先する
    func testDriverUnreachableOutranksBackground() {
        XCTAssertEqual(ScenarioRunner.outcome(passed: false, frozen: false, environmentFault: false,
                                              driverUnreachable: true, notApplicable: false, appInBackground: true),
                       .driverUnreachable)
    }

    /// XCUITest が答えない(照会の失敗)ときは推測しない = ブリッジ不達のまま
    func testNoForegroundAnswerKeepsDriverUnreachable() async {
        let (executor, inApp, xcuitest) = make()
        inApp.suspended = true
        xcuitest.appInFront = nil
        let outcome = await executor.execute(FlowStep(action: "tap", locator: FlowLocator(id: "btn"), timeout: 1))
        XCTAssertEqual(outcome.failureKind, .driverUnreachable)
    }

    /// run は背面の失敗を振り直さず、赤のまま残す(ブリッジ不達として再キューしない)
    func testRunKeepsTheBackgroundFailureRed() {
        let outcome = ScenarioRunner.outcome(passed: false, frozen: false, environmentFault: false,
                                             driverUnreachable: false, notApplicable: false, appInBackground: true)
        XCTAssertEqual(outcome, .appInBackground)
        XCTAssertFalse(ScenarioRunner.requeuesWithoutRetiring(outcome: outcome))
        XCTAssertEqual(StepFailureKind.appInBackground.rawValue, "app-in-background")
    }

    // MARK: - ② アプリスイッチャー

    func testStepsAreRefusedWhileTheAppSwitcherIsInFront() async {
        let (executor, inApp, xcuitest) = make()
        executor.noteAppSwitcher(opened: true)
        xcuitest.covering = .value(SystemUICoveringResponse(covering: true, marker: "SBSwitcherWindow:Main"))
        let tap = await executor.execute(FlowStep(action: "tap", locator: FlowLocator(id: "btn"), timeout: 1))
        guard case .failed(let message) = tap.status else { return XCTFail("スイッチャーの間に撃った: \(tap.status)") }
        XCTAssertTrue(message.contains("the app switcher is in front"), message)
        XCTAssertEqual(tap.failureKind, .systemUICovered)
        XCTAssertEqual(inApp.taps, 0)
        let read = await executor.execute(FlowStep(assert: "exists", locator: FlowLocator(id: "btn"), timeout: 1))
        guard case .failed = read.status else { return XCTFail("スイッチャーの間に読んで緑: \(read.status)") }
    }

    /// スイッチャーが閉じたと答えたら印を落とし、以後は照会しない
    func testStepsRunOnceTheSwitcherIsGone() async {
        let (executor, inApp, xcuitest) = make()
        executor.noteAppSwitcher(opened: true)
        xcuitest.covering = .value(SystemUICoveringResponse(covering: false, marker: nil))
        let tap = await executor.execute(FlowStep(action: "tap", locator: FlowLocator(id: "btn"), timeout: 1))
        XCTAssertTrue(StepExecutor.isSuccess(tap.status), "\(tap.status)")
        XCTAssertEqual(inApp.taps, 1)
        xcuitest.covering = .value(SystemUICoveringResponse(covering: true, marker: "SBSwitcherWindow:Main"))
        let again = await executor.execute(FlowStep(action: "tap", locator: FlowLocator(id: "btn"), timeout: 1))
        XCTAssertTrue(StepExecutor.isSuccess(again.status), "閉じた後も照会している: \(again.status)")
    }

    /// appSwitcher() を撃っていなければ照会もしない(通知センター等の覆いはこの門の対象外)
    func testNoRefusalWithoutAppSwitcher() async {
        let (executor, inApp, xcuitest) = make()
        xcuitest.covering = .value(SystemUICoveringResponse(covering: true, marker: "SBSwitcherWindow:Main"))
        let tap = await executor.execute(FlowStep(action: "tap", locator: FlowLocator(id: "btn"), timeout: 1))
        XCTAssertTrue(StepExecutor.isSuccess(tap.status), "\(tap.status)")
        XCTAssertEqual(inApp.taps, 1)
    }
}

/// ③ 前面を離れたかもしれない後(home 等)だけ、撃つ前に XCUITest へ前面かを聞き、前面に無ければ待たずに断る
final class BackgroundedAppPreFireTests: XCTestCase {
    private final class CountingForeground: AppDriver {
        var appInFront: Bool? = false
        private(set) var asks = 0
        func status() async throws -> StatusResponse {
            StatusResponse(ready: true, device: "fake", osVersion: "-", sessionBundleID: nil)
        }
        func install(packagePath: String) async throws -> String? { nil }
        func uninstall(bundleID: String) async throws {}
        func launch(bundleID: String) async throws {}
        func isAppForeground(bundleID: String) async throws -> Bool {
            asks += 1
            guard let appInFront else { throw DriverError.badResponse(status: 500, body: "no answer") }
            return appInFront
        }
        func foregroundAppID() async -> Probe<String> { .value("com.apple.springboard") }
        func terminate() async throws {}
        func screenshot() async throws -> Data { Data() }
        func type(ref: Int?, text: String) async throws {}
        func tap(ref: Int) async throws {}
        func tap(x: Double, y: Double) async throws {}
        func press(ref: Int, duration: Double) async throws {}
        func swipe(_ direction: FTSwipeDirection) async throws {}
        func drag(fromX: Double, fromY: Double, toX: Double, toY: Double,
                  pressSeconds: Double, durationSeconds: Double) async throws {}
        func snapshot() async throws -> SnapshotResponse {
            SnapshotResponse(sessionBundleID: nil, screen: FTRect(x: 0, y: 0, width: 400, height: 800),
                             elements: [], truncatedCount: 0)
        }
    }

    private final class InApp: AppDriver {
        private(set) var reads = 0
        func status() async throws -> StatusResponse {
            StatusResponse(ready: true, device: "fake", osVersion: "-", sessionBundleID: nil)
        }
        func install(packagePath: String) async throws -> String? { nil }
        func uninstall(bundleID: String) async throws {}
        func launch(bundleID: String) async throws {}
        func isAppForeground(bundleID: String) async throws -> Bool { true }
        func terminate() async throws {}
        func screenshot() async throws -> Data { Data() }
        func type(ref: Int?, text: String) async throws {}
        func tap(ref: Int) async throws {}
        func tap(x: Double, y: Double) async throws {}
        func press(ref: Int, duration: Double) async throws {}
        func swipe(_ direction: FTSwipeDirection) async throws {}
        func drag(fromX: Double, fromY: Double, toX: Double, toY: Double,
                  pressSeconds: Double, durationSeconds: Double) async throws {}
        func snapshot() async throws -> SnapshotResponse {
            reads += 1
            return SnapshotResponse(
                sessionBundleID: "com.example.app", screen: FTRect(x: 0, y: 0, width: 400, height: 800),
                elements: [ElementInfo(ref: 1, type: "button", identifier: "btn", label: "Go", value: nil, placeholder: nil,
                                       enabled: true, frame: FTRect(x: 16, y: 40, width: 100, height: 56), depth: 0)],
                truncatedCount: 0)
        }
    }

    private func make() -> (StepExecutor, InApp, CountingForeground) {
        let inApp = InApp()
        let xcuitest = CountingForeground()
        let executor = StepExecutor(driver: inApp, fallbackDriver: xcuitest, isAndroid: false, tunables: RunTunables())
        executor.noteAppLaunched(bundleID: "com.example.app")
        return (executor, inApp, xcuitest)
    }

    func testRefusesBeforeReadingWhenTheAppLeft() async {
        let (executor, inApp, _) = make()
        executor.noteAppMayHaveLeft(true)
        let outcome = await executor.execute(FlowStep(action: "tap", locator: FlowLocator(id: "btn"), timeout: 1))
        guard case .failed(let message) = outcome.status else { return XCTFail("\(outcome.status)") }
        XCTAssertEqual(outcome.failureKind, .appInBackground)
        XCTAssertTrue(message.contains("not in the foreground, so this step did not read or touch it"), message)
        XCTAssertEqual(inApp.reads, 0, "断る前に in-app を読んだ")
    }

    /// 前面と答えたら印を落とし、以後は聞かない
    func testStopsAskingOnceTheAppIsBack() async {
        let (executor, _, xcuitest) = make()
        executor.noteAppMayHaveLeft(true)
        xcuitest.appInFront = true
        _ = await executor.execute(FlowStep(action: "tap", locator: FlowLocator(id: "btn"), timeout: 1))
        _ = await executor.execute(FlowStep(action: "tap", locator: FlowLocator(id: "btn"), timeout: 1))
        XCTAssertEqual(xcuitest.asks, 1)
    }

    /// 照会が失敗したら断らず、以後は聞かない(固まったランナーで毎ステップ待ちを払わない)
    func testAFailedProbeIsAskedOnlyOnce() async {
        let (executor, _, xcuitest) = make()
        executor.noteAppMayHaveLeft(true)
        xcuitest.appInFront = nil
        let first = await executor.execute(FlowStep(action: "tap", locator: FlowLocator(id: "btn"), timeout: 1))
        _ = await executor.execute(FlowStep(action: "tap", locator: FlowLocator(id: "btn"), timeout: 1))
        XCTAssertTrue(StepExecutor.isSuccess(first.status), "\(first.status)")
        XCTAssertEqual(xcuitest.asks, 1)
    }

    /// 離れた印が無ければ聞かない(通常のステップに照会を足さない)
    func testDoesNotAskWithoutTheMark() async {
        let (executor, _, xcuitest) = make()
        let outcome = await executor.execute(FlowStep(action: "tap", locator: FlowLocator(id: "btn"), timeout: 1))
        XCTAssertTrue(StepExecutor.isSuccess(outcome.status), "\(outcome.status)")
        XCTAssertEqual(xcuitest.asks, 0)
    }
}
