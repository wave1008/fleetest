// 探索 20261107a: ①止める3コマンドを同じ印で扱う(clearAppData / removeApp の後の失敗に「クラッシュしたかも」を並べない)
// ②撃つ前から対象アプリが前面に居なかった Android の back() に back-left-app を付けない
// ③前面を離れた後の exist の「見つからない」が前面に無い事実を言う ④secure 入力のキーボードが失敗時の絵に写らない事実

import XCTest
import FTCore
@testable import FTDSL

final class StopAttributionAndFailureFactsTests: XCTestCase {

    private static let app = "com.example.app"

    private final class ScriptedDriver: AppDriver, @unchecked Sendable {
        var ownerBeforeBack: String? = StopAttributionAndFailureFactsTests.app
        var ownerAfterBack: String? = "com.android.launcher"
        var foreground = true
        var keyboardShown: Bool?
        var focusedType: String?
        private var backed = false
        func status() async throws -> StatusResponse {
            StatusResponse(ready: true, device: "stub", osVersion: "-", sessionBundleID: nil)
        }
        func install(packagePath: String) async throws -> String? { nil }
        func uninstall(bundleID: String) async throws {}
        func clearAppData(bundleID: String) async throws {}
        func isAppForeground(bundleID: String) async throws -> Bool { foreground }
        func launch(bundleID: String) async throws {}
        func snapshot() async throws -> SnapshotResponse {
            SnapshotResponse(sessionBundleID: backed ? ownerAfterBack : ownerBeforeBack,
                             screen: FTRect(x: 0, y: 0, width: 400, height: 800),
                             elements: [ElementInfo(ref: 1, type: focusedType ?? "button", identifier: backed ? "b" : "a", label: nil,
                                                    value: nil, placeholder: nil, enabled: true,
                                                    frame: FTRect(x: 10, y: 10, width: 100, height: 40), depth: 0,
                                                    focused: focusedType == nil ? nil : true)],
                             truncatedCount: 0, keyboardShown: keyboardShown)
        }
        func back() async throws { backed = true }
        func home() async throws {}
        func openURL(_ url: String, bundleID: String?) async throws {}
        func tap(ref: Int) async throws {}
        func tap(x: Double, y: Double) async throws {}
        func type(ref: Int?, text: String) async throws {}
        func swipe(_ direction: FTSwipeDirection) async throws {}
        func press(ref: Int, duration: Double) async throws {}
        func screenshot() async throws -> Data { Data([0x01]) }
        func terminate() async throws {}
    }

    private func run(platform: String = "android", driver: ScriptedDriver, evidence: [String] = [],
                     _ body: () -> Void) -> [ScenarioEvent] {
        var events: [ScenarioEvent] = []
        let core = FTDriveCore(driver: driver, platform: platform, app: Self.app,
                               scenarioID: "T.S0010", scenarioTitle: "t",
                               delegate: nil, healingEnabled: false, tunables: RunTunables(),
                               fmTextVisibilityCheckEnabled: false, occlusionOCREnabled: false, dryRun: false,
                               fingerprintCacheURL: URL(fileURLWithPath: NSTemporaryDirectory())
                                   .appendingPathComponent("ft-stop-attribution-test.json"),
                               emit: { events.append($0) })
        core.appProcessEvidence = { _ in evidence }
        FTRuntime.bootstrap(core: core, dslThread: Thread.current)
        defer { FTRuntime.tearDown() }
        body()
        return events
    }

    private func logs(_ events: [ScenarioEvent]) -> [String] { events.filter { $0.kind == "log" }.compactMap(\.message) }
    private func backNotes(_ events: [ScenarioEvent]) -> [String]? {
        events.first { $0.kind == "step" && ($0.description ?? "").hasPrefix("back") }?.notes
    }

    // MARK: ① 止める3コマンドは同じ印

    func testAllThreeStoppingCommandsSayTheScenarioStoppedItAndRecordNoCrashSuspicion() {
        let stoppers: [(String, () -> Void)] = [
            ("terminateApp", { terminateApp() }), ("clearAppData", { clearAppData() }), ("removeApp", { removeApp() }),
        ]
        for (name, stop) in stoppers {
            let events = run(driver: ScriptedDriver(), evidence: ["process not running"]) {
                launchApp(); stop(); exist("#gone", waitSeconds: 0)
            }
            let lines = logs(events)
            XCTAssertTrue(lines.contains { $0.contains("this scenario stopped it with \(name)()") }, "\(name): \(lines)")
            XCTAssertFalse(lines.contains { $0.contains("may have crashed") }, "\(name): \(lines)")
        }
    }

    /// 陽性対照: 止めていない失敗ではクラッシュの容疑を従来どおり記録する
    func testWithoutStoppingTheCrashSuspicionIsStillRecorded() {
        let events = run(driver: ScriptedDriver(), evidence: ["process not running"]) {
            launchApp(); exist("#gone", waitSeconds: 0)
        }
        XCTAssertTrue(logs(events).contains { $0.contains("may have crashed") })
    }

    // MARK: ② back の前から対象アプリが前面に居なかった

    func testBackFromTheLauncherDoesNotSayItLeftTheApp() {
        let driver = ScriptedDriver()
        driver.ownerBeforeBack = "com.android.launcher"
        driver.ownerAfterBack = "com.android.launcher"
        let events = run(driver: driver) { launchApp(); home(); back() }
        XCTAssertNil(backNotes(events), "\(String(describing: backNotes(events)))")
    }

    /// 陽性対照: アプリの上から撃った back がランチャーへ抜けたら従来どおり言う
    func testBackFromTheAppThatLeavesItStillSaysSo() {
        let events = run(driver: ScriptedDriver()) { launchApp(); back() }
        XCTAssertEqual(backNotes(events), [StepNote.backLeftApp.rawValue])
    }

    func testStartedOutsideTheAppJudgement() {
        let expected = [Self.app]
        XCTAssertTrue(BackEffect.startedOutsideTheApp(beforeOwner: "com.android.launcher", expected: expected))
        XCTAssertFalse(BackEffect.startedOutsideTheApp(beforeOwner: Self.app, expected: expected))
        XCTAssertFalse(BackEffect.startedOutsideTheApp(beforeOwner: nil, expected: expected), "読めなければ黙る")
        XCTAssertFalse(BackEffect.startedOutsideTheApp(beforeOwner: "", expected: expected))
        for dialog in ForegroundState.systemDialogPackages {
            XCTAssertFalse(BackEffect.startedOutsideTheApp(beforeOwner: dialog, expected: expected), dialog)
        }
    }

    // MARK: ③ 前面を離れた後の exist

    func testExistAfterHomeNamesThatTheAppIsNotInTheForeground() {
        let driver = ScriptedDriver()
        let events = run(driver: driver) {
            launchApp()
            driver.foreground = false
            home()
            exist("#gone", waitSeconds: 0)
        }
        let detail = events.first { $0.kind == "step" && $0.status == "failed" }?.detail ?? ""
        XCTAssertTrue(detail.contains("element not found"), detail)
        XCTAssertTrue(detail.contains("not in the foreground") && detail.contains("launchApp()"), detail)
    }

    /// 前面と答えたら従来の文のまま(推測で足さない)
    func testExistAfterHomeStaysSilentWhenTheAppIsInTheForeground() {
        let driver = ScriptedDriver()
        let events = run(driver: driver) { launchApp(); home(); exist("#gone", waitSeconds: 0) }
        let detail = events.first { $0.kind == "step" && $0.status == "failed" }?.detail ?? ""
        XCTAssertTrue(detail.contains("element not found"), detail)
        XCTAssertFalse(detail.contains("not in the foreground"), detail)
    }

    /// 前面を離れた印が無ければ聞かない・言わない
    func testExistWithoutLeavingDoesNotMentionTheForeground() {
        let driver = ScriptedDriver()
        driver.foreground = false
        let events = run(driver: driver) { launchApp(); exist("#gone", waitSeconds: 0) }
        let detail = events.first { $0.kind == "step" && $0.status == "failed" }?.detail ?? ""
        XCTAssertFalse(detail.contains("not in the foreground"), detail)
    }

    // MARK: ④ secure 入力のキーボードは失敗時の絵に写らない

    func testFailureWithSecureFocusAndKeyboardSaysTheScreenshotOmitsIt() {
        let driver = ScriptedDriver()
        driver.keyboardShown = true
        driver.focusedType = "secureTextField"
        let events = run(platform: "ios", driver: driver) { exist("#gone", waitSeconds: 0) }
        XCTAssertTrue(logs(events).contains { $0.contains(StepNote.screenshotOmitsSecureKeyboard.text) }, "\(logs(events))")
    }

    func testFailureWithOrdinaryFocusOrNoKeyboardStaysSilent() {
        for (shown, type) in [(true, "textField"), (false, "secureTextField"), (nil, "secureTextField"), (true, nil)] as [(Bool?, String?)] {
            let driver = ScriptedDriver()
            driver.keyboardShown = shown
            driver.focusedType = type
            let events = run(platform: "ios", driver: driver) { exist("#gone", waitSeconds: 0) }
            XCTAssertFalse(logs(events).contains { $0.contains(StepNote.screenshotOmitsSecureKeyboard.text) },
                           "shown=\(String(describing: shown)) type=\(String(describing: type))")
        }
    }

    func testSecureKeyboardNoteCodeIsPersisted() {
        XCTAssertEqual(StepNote.screenshotOmitsSecureKeyboard.rawValue, "screenshot-omits-secure-keyboard")
    }
}
