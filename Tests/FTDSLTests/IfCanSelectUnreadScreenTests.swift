// 画面を読めなかった(クラッシュ・接続断・固まり)ときの `ifCanSelect` / `repeatWhileCanSelect`。
// 読めなかったことを「無い」と言って不成立で緑へ抜けない: 失敗として記録し、失敗の素性は DriverError の型から採る。
// 一過性の失敗(途中で1回だけ読めない)は、後の読みが成功すれば不成立の根拠に影響しない。

import XCTest
@testable import FTDSL
import FTCore

final class IfCanSelectUnreadScreenTests: XCTestCase {

    /// `failuresBeforeReads` 回の snapshot が接続拒否で失敗し、以後は `elements` を返す(負数 = 永久に失敗)
    private final class FlakyDriver: AppDriver, @unchecked Sendable {
        var failuresLeft: Int
        let elements: [ElementInfo]
        init(failures: Int, elements: [ElementInfo] = []) {
            self.failuresLeft = failures
            self.elements = elements
        }
        func status() async throws -> StatusResponse {
            StatusResponse(ready: true, device: "-", osVersion: "-", sessionBundleID: nil)
        }
        func install(packagePath: String) async throws -> String? { nil }
        func uninstall(bundleID: String) async throws {}
        func launch(bundleID: String) async throws {}
        func isAppForeground(bundleID: String) async throws -> Bool { false }
        func foregroundAppID() async throws -> String? { nil }
        func snapshot() async throws -> SnapshotResponse {
            if failuresLeft != 0 {
                if failuresLeft > 0 { failuresLeft -= 1 }
                throw DriverError.bridgeConnectionRefused(
                    context: DriverErrorContext(bridge: .iosInApp, physicalDevice: false), detail: "refused")
            }
            return SnapshotResponse(sessionBundleID: nil,
                                    screen: FTRect(x: 0, y: 0, width: 400, height: 800),
                                    elements: elements, truncatedCount: 0)
        }
        func tap(ref: Int) async throws {}
        func tap(x: Double, y: Double) async throws {}
        func type(ref: Int?, text: String) async throws {}
        func swipe(_ direction: FTSwipeDirection) async throws {}
        func press(ref: Int, duration: Double) async throws {}
        func screenshot() async throws -> Data { Data() }
        func terminate() async throws {}
    }

    private func makeCore(_ driver: AppDriver, emit: @escaping (ScenarioEvent) -> Void) -> FTDriveCore {
        FTDriveCore(driver: driver, platform: "ios", app: "com.example.app",
                    scenarioID: "T.S0010", scenarioTitle: "t",
                    delegate: nil, healingEnabled: false, tunables: RunTunables(), dryRun: false,
                    fingerprintCacheURL: URL(fileURLWithPath: NSTemporaryDirectory())
                        .appendingPathComponent("ft-ifcanselect-unread-test.json"),
                    fallbackDriver: nil,
                    emit: emit)
    }

    private func run(_ driver: AppDriver, _ body: @escaping () -> Void) -> [ScenarioEvent] {
        var steps: [ScenarioEvent] = []
        FTRuntime.bootstrap(core: makeCore(driver) { if $0.kind == "step" { steps.append($0) } },
                            dslThread: Thread.current)
        defer { FTRuntime.tearDown() }
        scenario { scene(1, "s") { action { body() } } }
        return steps
    }

    func testIfCanSelectFailsWhenTheScreenCannotBeRead() {
        var ran = false
        let steps = run(FlakyDriver(failures: -1)) { ifCanSelect("#email", waitSeconds: 0) { ran = true } }
        XCTAssertFalse(ran)
        guard let step = steps.first(where: { ($0.description ?? "").hasPrefix("ifCanSelect") }) else {
            return XCTFail("no ifCanSelect step: \(steps.map { $0.description ?? "" })")
        }
        XCTAssertEqual(step.status, "failed", "読めなかった条件は不成立(skipped)で緑へ抜けない")
        XCTAssertEqual(step.failureKind, StepFailureKind.driverUnreachable.rawValue)
    }

    func testIfCanSelectStillNotMetWhenTheScreenWasReadAndTheTargetIsAbsent() {
        let steps = run(FlakyDriver(failures: 0)) { ifCanSelect("#email", waitSeconds: 0) {} }
        let step = steps.first { ($0.description ?? "").hasPrefix("ifCanSelect") }
        XCTAssertEqual(step?.status, "skipped", "読めたうえで無いなら従来どおり不成立")
    }

    func testTransientReadFailureThenSuccessIsNotAFailure() {
        var ran = false
        let target = ElementInfo(ref: 1, type: "button", identifier: "email", label: "Email", value: nil,
                                 placeholder: nil, enabled: true,
                                 frame: FTRect(x: 0, y: 0, width: 10, height: 10), depth: 0)
        let steps = run(FlakyDriver(failures: 1, elements: [target])) {
            ifCanSelect("#email", waitSeconds: 2) { ran = true }
        }
        XCTAssertTrue(ran)
        XCTAssertTrue(steps.contains { ($0.description ?? "").hasPrefix("ifCanSelect") && $0.status == "passed" })
    }

    func testRepeatWhileCanSelectFailsWhenTheScreenCannotBeRead() {
        let steps = run(FlakyDriver(failures: -1)) {
            repeatWhileCanSelect("#more", waitSeconds: 0) {}
        }
        let step = steps.first { ($0.description ?? "").hasPrefix("repeatWhileCanSelect") }
        XCTAssertEqual(step?.status, "failed")
    }

    // MARK: - terminateApp の直後(シナリオが止めたアプリは「読めない」でなく「無い」)

    func testIfCanSelectAfterTerminateAppIsNotMetNotFailed() {
        var ran = false
        let steps = run(FlakyDriver(failures: -1)) {
            terminateApp()
            ifCanSelect("#email", waitSeconds: 0) { ran = true }
        }
        XCTAssertFalse(ran)
        let step = steps.first { ($0.description ?? "").hasPrefix("ifCanSelect") }
        XCTAssertEqual(step?.status, "skipped", "止めたアプリの読み失敗は不成立(失敗でも crashed でもない)")
        XCTAssertTrue(step?.description?.contains("stopped by terminateApp") == true, step?.description ?? "")
    }

    func testRepeatWhileCanSelectAfterTerminateAppRunsZeroTimes() {
        let steps = run(FlakyDriver(failures: -1)) {
            terminateApp()
            repeatWhileCanSelect("#more", waitSeconds: 0) {}
        }
        let step = steps.first { ($0.description ?? "").hasPrefix("repeatWhileCanSelect") }
        XCTAssertEqual(step?.status, "passed")
        XCTAssertTrue(step?.description?.contains("0 time(s)") == true, step?.description ?? "")
    }

    func testAnOperationAfterTerminateAppEndsTheStoppedState() {
        // 失敗でない別の操作(アプリを起こしうる)が入ったら、以後の読み失敗は従来どおり失敗
        let steps = run(FlakyDriver(failures: -1)) {
            terminateApp()
            launchApp()
            ifCanSelect("#email", waitSeconds: 0) {}
        }
        let step = steps.first { ($0.description ?? "").hasPrefix("ifCanSelect") }
        XCTAssertNotEqual(step?.status, "skipped")
    }
}
