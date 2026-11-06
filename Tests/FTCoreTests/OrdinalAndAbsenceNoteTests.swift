import Foundation
import XCTest
@testable import FTCore

/// OI-168 ③(スコープの無い序数は iOS のモードで別の要素を指しうる)と OI-182 ①(Android の否定が別のアプリの木を読んだ)の注記
final class OrdinalAndAbsenceNoteTests: XCTestCase {

    func testUnscopedOrdinalIsTheOnlyOrdinalFormFlagged() {
        XCTAssertTrue(FTSelector.parse(".button[5]").primary.hasUnscopedOrdinal)
        XCTAssertFalse(FTSelector.parse("#list >> .button[5]").primary.hasUnscopedOrdinal, "容器の中で数える序数を数えた")
        XCTAssertFalse(FTSelector.parse("#btn_ok").primary.hasUnscopedOrdinal)
        XCTAssertFalse(FTSelector.parse(".button").primary.hasUnscopedOrdinal)
    }

    func testIOSStepWithUnscopedOrdinalCarriesTheNoteAndAndroidDoesNot() async {
        let step = FlowStep(action: "tap", locator: FTSelector.parse(".button[2]").primary, timeout: 0.1)
        let ios = await StepExecutor(driver: TwoButtonsDriver(), isAndroid: false, tunables: RunTunables()).execute(step)
        XCTAssertTrue(StepExecutor.isSuccess(ios.status), "\(ios.status)")
        XCTAssertTrue(ios.notes.contains(.ordinalWithoutScope), "\(ios.notes)")
        XCTAssertTrue(ios.driverFallback?.contains("without a container scope") == true, "文言がステップの説明に出ない: \(ios.driverFallback ?? "nil")")
        let android = await StepExecutor(driver: TwoButtonsDriver(), isAndroid: true, tunables: RunTunables()).execute(step)
        XCTAssertFalse(android.notes.contains(.ordinalWithoutScope), "Android は木が1つなので言わない")
        let scoped = FlowStep(action: "tap", locator: FTSelector.parse("#row >> .button[1]").primary, timeout: 0.1)
        let iosScoped = await StepExecutor(driver: TwoButtonsDriver(), isAndroid: false, tunables: RunTunables()).execute(scoped)
        XCTAssertFalse(iosScoped.notes.contains(.ordinalWithoutScope), "\(iosScoped.notes)")
    }

    func testAbsenceNoteOnlyForAndroidAbsenceChecksOnAnotherAppsTree() {
        let notExists = FlowStep(assert: "notExists", locator: FlowLocator(id: "x"))
        let exists = FlowStep(assert: "exists", locator: FlowLocator(id: "x"))
        let app = "com.example.app", other = "com.android.settings"
        XCTAssertTrue(StepExecutor.absenceReadAnotherApp(isAndroid: true, step: notExists, owner: other, appUnderTest: app))
        XCTAssertFalse(StepExecutor.absenceReadAnotherApp(isAndroid: true, step: notExists, owner: app, appUnderTest: app))
        XCTAssertFalse(StepExecutor.absenceReadAnotherApp(isAndroid: false, step: notExists, owner: other, appUnderTest: app))
        XCTAssertFalse(StepExecutor.absenceReadAnotherApp(isAndroid: true, step: exists, owner: other, appUnderTest: app), "肯定の検証")
        XCTAssertFalse(StepExecutor.absenceReadAnotherApp(isAndroid: true, step: notExists, owner: nil, appUnderTest: app), "持ち主が読めない")
        XCTAssertFalse(StepExecutor.absenceReadAnotherApp(isAndroid: true, step: notExists, owner: other, appUnderTest: nil))
        var countZero = FlowStep(assert: "count", locator: FlowLocator(id: "x"))
        countZero.expectedCount = 0
        XCTAssertTrue(StepExecutor.absenceReadAnotherApp(isAndroid: true, step: countZero, owner: other, appUnderTest: app))
    }

    func testAndroidNotExistOnAnotherAppsTreePassesWithTheNote() async {
        let executor = StepExecutor(driver: TwoButtonsDriver(owner: "com.android.settings"), isAndroid: true, tunables: RunTunables())
        executor.appUnderTestBundleID = "com.example.app"
        let outcome = await executor.execute(FlowStep(assert: "notExists", locator: FlowLocator(id: "missing"), timeout: 0.1))
        XCTAssertTrue(StepExecutor.isSuccess(outcome.status), "合否は変えない: \(outcome.status)")
        XCTAssertTrue(outcome.notes.contains(.absenceCheckedOnAnotherApp), "\(outcome.notes)")
        XCTAssertTrue(outcome.driverFallback?.contains("not the app under test") == true, "文言がステップの説明に出ない: \(outcome.driverFallback ?? "nil")")
    }
}

private final class TwoButtonsDriver: AppDriver {
    let owner: String?
    init(owner: String? = nil) { self.owner = owner }
    func snapshot() async throws -> SnapshotResponse {
        func button(_ ref: Int, _ y: Double) -> ElementInfo {
            ElementInfo(ref: ref, type: "button", identifier: "b\(ref)", label: "B\(ref)", value: nil, placeholder: nil, enabled: true,
                        frame: FTRect(x: 10, y: y, width: 100, height: 40), depth: 1)
        }
        let row = ElementInfo(ref: 3, type: "other", identifier: "row", label: nil, value: nil, placeholder: nil, enabled: true,
                              frame: FTRect(x: 0, y: 0, width: 400, height: 200), depth: 0)
        return SnapshotResponse(sessionBundleID: owner, screen: FTRect(x: 0, y: 0, width: 400, height: 800),
                                elements: [row, button(1, 50), button(2, 120)], truncatedCount: 0)
    }
    func status() async throws -> StatusResponse { StatusResponse(ready: true, device: "fake", osVersion: "-", sessionBundleID: owner) }
    func install(packagePath: String) async throws -> String? { nil }
    func uninstall(bundleID: String) async throws {}
    func launch(bundleID: String) async throws {}
    func isAppForeground(bundleID: String) async throws -> Bool { true }
    func tap(ref: Int) async throws {}
    func tap(x: Double, y: Double) async throws {}
    func type(ref: Int?, text: String) async throws {}
    func press(ref: Int, duration: Double) async throws {}
    func swipe(_ direction: FTSwipeDirection) async throws {}
    func screenshot() async throws -> Data { Data() }
    func terminate() async throws {}
}
