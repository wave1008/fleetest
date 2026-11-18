// Simulator でランナーを起動できなかった理由を xcodebuild のログから拾う。行は M1Max の iPhone 17e の実ログ
// (`bridge-8130.prev.log`。SpringBoard が落ちて "Host is down")から写した

import XCTest
@testable import FTBridgeClient

final class SimulatorLaunchFailureReasonTests: XCTestCase {

    private let log = """
    2026-11-18 05:02:20.638 xcodebuild[49128:5409244]  iOSSimulator: 7C566FA1: Failed to launch app with identifier: com.example.ftrunner.uitests.xctrunner and options: {
    } (error = Error Domain=NSPOSIXErrorDomain Code=64 "Host is down" UserInfo={BSErrorCodeDescription=host down})
    2026-11-18 05:02:20.641 xcodebuild[49128:5409033] [MT] IDELaunchReport: 9b09:9b09:Launching FleetestRunnerUITests Finished with error: Simulator device failed to launch com.example.ftrunner.uitests.xctrunner.
    Domain: NSPOSIXErrorDomain
    Code: 64
    Failure Reason: The system shell probably crashed.

    ** TEST EXECUTE FAILED **
    """

    func testNamesTheLaunchFailureAndItsReason() {
        XCTAssertEqual(BridgeLauncher.simulatorLaunchFailureReason(inLog: log),
                       "Simulator device failed to launch com.example.ftrunner.uitests.xctrunner. (The system shell probably crashed.)")
    }

    func testNothingToSayWithoutThoseLines() {
        XCTAssertNil(BridgeLauncher.simulatorLaunchFailureReason(inLog: "** TEST EXECUTE FAILED **\n"))
    }
}
