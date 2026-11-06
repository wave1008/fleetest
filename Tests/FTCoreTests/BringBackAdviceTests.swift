import Foundation
import XCTest
@testable import FTCore

final class BringBackAdviceTests: XCTestCase {
    func testFoldedDeviceIsNotAdvisedTapAppIcon() {
        let advice = StepExecutor.bringBackAdvice(fold: .state(.folded))
        XCTAssertTrue(advice.hasPrefix("launchApp()"), advice)
        XCTAssertTrue(advice.contains("folded"), advice)
    }

    func testOtherObservationsKeepTheUsualAdvice() {
        for fold: FoldObservation? in [nil, .notFoldable, .state(.unfolded), .unknown("x")] {
            XCTAssertEqual(StepExecutor.bringBackAdvice(fold: fold), "tapAppIcon() or launchApp()")
        }
    }

    /// **iOS は注入した開閉の読み(devicectl)を使う**。iOS のドライバはどの包みも開閉を読めず nil を返すので、ドライバに聞くだけの版は
    /// 単体テストが緑のまま Duo では一度も効かなかった(畳んだ Duo の断りが tapAppIcon() を勧め続けた)
    func testInjectedFoldObserverWinsOverTheDriver() async {
        let executor = StepExecutor(driver: FoldBlindDriver(), isAndroid: false, tunables: RunTunables())
        let before = await executor.bringBackAdvice()
        XCTAssertEqual(before, "tapAppIcon() or launchApp()")
        executor.foldObserver = { FoldObservation.state(.folded) }
        let advice = await executor.bringBackAdvice()
        XCTAssertTrue(advice.hasPrefix("launchApp()"), advice)
    }
}

/// 開閉を読めないドライバ(iOS の包みと同じ = `foldObservation` は既定の nil)
private final class FoldBlindDriver: AppDriver {
    func snapshot() async throws -> SnapshotResponse {
        SnapshotResponse(sessionBundleID: nil, screen: FTRect(x: 0, y: 0, width: 100, height: 100), elements: [], truncatedCount: 0)
    }
    func status() async throws -> StatusResponse { StatusResponse(ready: true, device: "fake", osVersion: "-", sessionBundleID: nil) }
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
