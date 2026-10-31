// 注入起動の ready 待ちが尽きた失敗は driver-unreachable(振り直し対象)、それ以外の起動失敗は名乗らない。

import XCTest
import FTCore
@testable import FTBridgeClient

final class InAppLauncherFailureKindTests: XCTestCase {
    func testOnlyNotReadyIsDriverUnreachable() {
        XCTAssertEqual(StepExecutor.failureKind(thrown: InAppLauncherError.notReady("connection refused")),
                       .driverUnreachable)
        for error in [InAppLauncherError.dylibMissing("x"), .repoRootInvalid("x"), .buildFailed("x"),
                      .bootFailed("x"), .launchFailed("x")] {
            XCTAssertNil(StepExecutor.failureKind(thrown: error), "\(error)")
        }
    }
}
