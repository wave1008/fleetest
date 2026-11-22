// 子の確かめ(`FTDriveCore.awaitDisplayReachedApp`)の振る舞い。ドライバの申告を差し替えて、届かない・遅れて届く・答えない形を通す。

import XCTest
@testable import FTDSL
import FTCore

final class DisplayAppCheckDSLTests: XCTestCase {

    private final class ReportingDriver: AppDriver {
        let reports: @Sendable (Int) -> InAppDisplayReport?
        private let asked = LockedValue(0)
        init(_ reports: @escaping @Sendable (Int) -> InAppDisplayReport?) { self.reports = reports }
        var askCount: Int { asked.value }
        func inAppDisplayReport() async -> InAppDisplayReport? {
            let n = asked.withLock { $0 += 1; return $0 }
            return reports(n)
        }
        func status() async throws -> StatusResponse {
            StatusResponse(ready: true, device: "stub", osVersion: "-", sessionBundleID: nil)
        }
        func install(packagePath: String) async throws -> String? { nil }
        func uninstall(bundleID: String) async throws {}
        func isAppForeground(bundleID: String) async throws -> Bool { false }
        func launch(bundleID: String) async throws {}
        func clearAppData(bundleID: String) async throws {}
        func snapshot() async throws -> SnapshotResponse {
            SnapshotResponse(sessionBundleID: nil, screen: FTRect(x: 0, y: 0, width: 400, height: 800),
                             elements: [], truncatedCount: 0)
        }
        func tap(ref: Int) async throws {}
        func tap(x: Double, y: Double) async throws {}
        func type(ref: Int?, text: String) async throws {}
        func clearInput(ref: Int?) async throws {}
        func swipe(_ direction: FTSwipeDirection) async throws {}
        func press(ref: Int, duration: Double) async throws {}
        func screenshot() async throws -> Data { Data() }
        func terminate() async throws {}
    }

    private func core(_ driver: AppDriver, expected: DisplayAppExpectation?) -> FTDriveCore {
        FTDriveCore(driver: driver, platform: "ios", app: "com.example.app", scenarioID: "T.S0010", scenarioTitle: "t",
                    delegate: nil, healingEnabled: false, tunables: RunTunables(), displayExpected: expected, dryRun: false,
                    fingerprintCacheURL: URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("ft-display-app-check.json"),
                    emit: { _ in })
    }

    private let light = InAppDisplayReport(screenAppearance: "light", contentSizeCategory: "UICTContentSizeCategoryL")
    private let dark = InAppDisplayReport(screenAppearance: "dark", contentSizeCategory: "UICTContentSizeCategoryL")

    func testStuckAppFailsWithDisplayNotAppliedAfterTheLimit() async throws {
        let driver = ReportingDriver { [light] _ in light }
        let core = core(driver, expected: DisplayAppExpectation(appearance: .dark, textSize: .default))
        do {
            try await core.awaitDisplayReachedApp(limitSeconds: 0.6)
            XCTFail("dark was expected but the app reports light")
        } catch let error as DriverError {
            guard case .displayNotApplied(let detail) = error else { return XCTFail("\(error)") }
            XCTAssertTrue(detail.contains("expected dark, the app reports light"), detail)
            XCTAssertTrue(detail.contains("SpringBoard"), detail)
            XCTAssertEqual(StepExecutor.failureKind(thrown: error), .displayNotApplied)
        }
        XCTAssertGreaterThan(driver.askCount, 1, "尽きるまで読み直す")
    }

    func testReportThatCatchesUpInTimePasses() async throws {
        let driver = ReportingDriver { [light, dark] n in n < 3 ? light : dark }
        try await core(driver, expected: DisplayAppExpectation(appearance: .dark, textSize: nil))
            .awaitDisplayReachedApp(limitSeconds: 2)
        XCTAssertEqual(driver.askCount, 3)
    }

    func testNothingToJudgeDoesNothing() async throws {
        let silent = ReportingDriver { _ in nil }
        try await core(silent, expected: DisplayAppExpectation(appearance: .dark, textSize: nil))
            .awaitDisplayReachedApp(limitSeconds: 0.3)
        XCTAssertEqual(silent.askCount, 1, "答えが無ければ読み直さずに通る")
        let withoutExpectation = ReportingDriver { [light] _ in light }
        try await core(withoutExpectation, expected: nil).awaitDisplayReachedApp(limitSeconds: 0.3)
        XCTAssertEqual(withoutExpectation.askCount, 0, "期待が無ければ聞かない")
        let emptyReport = ReportingDriver { _ in InAppDisplayReport(screenAppearance: nil, contentSizeCategory: nil) }
        try await core(emptyReport, expected: DisplayAppExpectation(appearance: .dark, textSize: nil))
            .awaitDisplayReachedApp(limitSeconds: 0.3)
    }

    func testSettingUpdatesTheExpectation() async throws {
        let driver = ReportingDriver { [light] _ in light }
        let core = core(driver, expected: DisplayAppExpectation(appearance: .light, textSize: nil))
        try await core.awaitDisplayReachedApp(limitSeconds: 0.3)
        core.updateDisplayExpectation(appearance: .dark)
        do {
            try await core.awaitDisplayReachedApp(limitSeconds: 0.3)
            XCTFail("the expectation moved to dark")
        } catch let error as DriverError {
            guard case .displayNotApplied = error else { return XCTFail("\(error)") }
        }
    }
}
