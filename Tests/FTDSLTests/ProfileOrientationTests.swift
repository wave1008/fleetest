// 実行プロファイルの `orientation`: launchApp / restartApp のたびに直後に rotateTo する(起動し直すと向きが残らない経路がある)。
// 指定なし(nil)は向きに触らない。

import XCTest
@testable import FTDSL
import FTCore

final class ProfileOrientationTests: XCTestCase {

    private final class RotatingDriver: AppDriver, @unchecked Sendable {
        var rotations: [FTOrientation] = []
        var launches = 0
        func status() async throws -> StatusResponse {
            StatusResponse(ready: true, device: "stub", osVersion: "-", sessionBundleID: nil)
        }
        func install(packagePath: String) async throws -> String? { nil }
        func uninstall(bundleID: String) async throws {}
        func isAppForeground(bundleID: String) async throws -> Bool { false }
        func launch(bundleID: String) async throws { launches += 1 }
        func snapshot() async throws -> SnapshotResponse {
            SnapshotResponse(sessionBundleID: nil, screen: FTRect(x: 0, y: 0, width: 400, height: 800),
                             elements: [], truncatedCount: 0)
        }
        func tap(ref: Int) async throws {}
        func tap(x: Double, y: Double) async throws {}
        func type(ref: Int?, text: String) async throws {}
        func swipe(_ direction: FTSwipeDirection) async throws {}
        func press(ref: Int, duration: Double) async throws {}
        func screenshot() async throws -> Data { Data() }
        func terminate() async throws {}
        func rotate(to orientation: FTOrientation) async throws -> FTOrientation {
            rotations.append(orientation)
            return orientation
        }
    }

    private let driver = RotatingDriver()

    private func makeCore(orientation: FTOrientation?) -> FTDriveCore {
        FTDriveCore(driver: driver, platform: "android", app: "com.example.app",
                    scenarioID: "T.S0010", scenarioTitle: "t",
                    delegate: nil, healingEnabled: false, tunables: RunTunables(),
                    profileOrientation: orientation,
                    fingerprintCacheURL: URL(fileURLWithPath: NSTemporaryDirectory())
                        .appendingPathComponent("ft-orientation-test.json"),
                    emit: { _ in })
    }

    private func descriptions(_ core: FTDriveCore) -> [String] {
        core.finalRecord.scenes.flatMap(\.steps).map(\.description)
    }

    func testRotatesRightAfterEveryLaunch() {
        let core = makeCore(orientation: .landscape)
        FTRuntime.bootstrap(core: core, dslThread: Thread.current)
        defer { FTRuntime.tearDown() }
        launchApp()
        launchApp()
        restartApp()
        XCTAssertEqual(driver.rotations, [.landscape, .landscape, .landscape])
        XCTAssertEqual(driver.launches, 3)
        XCTAssertEqual(Array(descriptions(core).prefix(4)),
                       ["launch com.example.app", "rotateTo landscape",
                        "launch com.example.app", "rotateTo landscape"])
    }

    func testRestartAppAlsoRotates() {
        let core = makeCore(orientation: .portrait)
        FTRuntime.bootstrap(core: core, dslThread: Thread.current)
        defer { FTRuntime.tearDown() }
        restartApp()
        XCTAssertEqual(driver.rotations, [.portrait])
    }

    func testNoOrientationLeavesTheDeviceAlone() {
        let core = makeCore(orientation: nil)
        FTRuntime.bootstrap(core: core, dslThread: Thread.current)
        defer { FTRuntime.tearDown() }
        launchApp()
        restartApp()
        XCTAssertTrue(driver.rotations.isEmpty)
    }
}
