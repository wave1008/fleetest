// OI-177 ③ / OI-186 ③: openURL の同意の確かめの後の張り戻しの失敗が注記として結果に載ること、
// Android で back() がアプリを抜けた後の失敗の ⚠️ が直前の back() を名指すこと。

import XCTest
import FTCore
@testable import FTDSL

final class BackAndOpenURLNoteTests: XCTestCase {

    private final class ScriptedDriver: AppDriver, @unchecked Sendable {
        var noteAfterOpenURL: String?
        var ownerAfterBack: String?
        private var backed = false
        private(set) var lastActionNote: String?
        func status() async throws -> StatusResponse {
            StatusResponse(ready: true, device: "stub", osVersion: "-", sessionBundleID: nil)
        }
        func install(packagePath: String) async throws -> String? { nil }
        func uninstall(bundleID: String) async throws {}
        func isAppForeground(bundleID: String) async throws -> Bool { true }
        func launch(bundleID: String) async throws {}
        func snapshot() async throws -> SnapshotResponse {
            SnapshotResponse(sessionBundleID: backed ? ownerAfterBack : "com.example.app",
                             screen: FTRect(x: 0, y: 0, width: 400, height: 800),
                             elements: [ElementInfo(ref: 1, type: "button", identifier: backed ? "b" : "a", label: nil,
                                                    value: nil, placeholder: nil, enabled: true,
                                                    frame: FTRect(x: 10, y: 10, width: 100, height: 40), depth: 0)],
                             truncatedCount: 0)
        }
        func back() async throws { backed = true }
        func openURL(_ url: String, bundleID: String?) async throws { lastActionNote = noteAfterOpenURL }
        func tap(ref: Int) async throws {}
        func tap(x: Double, y: Double) async throws {}
        func type(ref: Int?, text: String) async throws {}
        func swipe(_ direction: FTSwipeDirection) async throws {}
        func press(ref: Int, duration: Double) async throws {}
        func screenshot() async throws -> Data { Data() }
        func terminate() async throws {}
    }

    private func run(platform: String, driver: ScriptedDriver, overlays: [String] = [],
                     _ body: () -> Void) -> [ScenarioEvent] {
        var events: [ScenarioEvent] = []
        let core = FTDriveCore(driver: driver, platform: platform, app: "com.example.app",
                               scenarioID: "T.S0010", scenarioTitle: "t",
                               delegate: nil, healingEnabled: false, tunables: RunTunables(),
                               fmTextVisibilityCheckEnabled: false, occlusionOCREnabled: false, dryRun: false,
                               fingerprintCacheURL: URL(fileURLWithPath: NSTemporaryDirectory())
                                   .appendingPathComponent("ft-back-openurl-note-test.json"),
                               emit: { events.append($0) })
        core.foregroundOverlays = { _ in overlays }
        FTRuntime.bootstrap(core: core, dslThread: Thread.current)
        defer { FTRuntime.tearDown() }
        body()
        return events
    }

    func testOpenURLCarriesTheSessionNotRestoredNote() {
        let driver = ScriptedDriver()
        driver.noteAfterOpenURL = StepNote.openURLSessionNotRestoredPrefix + "com.example.app after checking (x)"
        let events = run(platform: "ios", driver: driver) { openURL("myapp://x") }
        let step = events.first { $0.kind == "step" }
        XCTAssertEqual(step?.notes, [StepNote.openURLSessionNotRestored.rawValue])
    }

    /// 確かめが走らなかった回(注記が別の操作のもの・無い)には立てない
    func testOpenURLDoesNotCarryUnrelatedNotes() {
        let driver = ScriptedDriver()
        driver.noteAfterOpenURL = "fell back to XCUITest"
        let events = run(platform: "ios", driver: driver) { openURL("myapp://x") }
        XCTAssertNil(events.first { $0.kind == "step" }?.notes)
    }

    func testFailureAfterBackThatLeftTheAppNamesTheBack() {
        let driver = ScriptedDriver()
        driver.ownerAfterBack = "com.android.launcher"
        let events = run(platform: "android", driver: driver, overlays: ["com.android.launcher"]) {
            back()
            exist("#gone", waitSeconds: 0)
        }
        let logs = events.filter { $0.kind == "log" }.compactMap(\.message)
        XCTAssertTrue(logs.contains { $0.contains("Another window is in front") && $0.contains("the preceding back() left the app") },
                      "\(logs)")
    }

    /// back() と失敗の間に別のステップが挟まれば名指さない
    func testNotNamedWhenAnotherStepCameBetween() {
        let driver = ScriptedDriver()
        driver.ownerAfterBack = "com.android.launcher"
        let events = run(platform: "android", driver: driver, overlays: ["com.android.launcher"]) {
            back()
            tap("#b")
            exist("#gone", waitSeconds: 0)
        }
        let logs = events.filter { $0.kind == "log" }.compactMap(\.message)
        XCTAssertTrue(logs.contains { $0.contains("Another window is in front") }, "\(logs)")
        XCTAssertFalse(logs.contains { $0.contains("the preceding back() left the app") }, "\(logs)")
    }
}
