import XCTest
@testable import FTBridgeClient

final class InAppLauncherNotInstalledTests: XCTestCase {
    func testNotInstalledIsNamed() {
        let e = InAppLauncher.launchFailure(tail: "t", verdict: .notInstalled)
        guard case .appNotInstalled = e else { return XCTFail("\(e)") }
        let text = e.errorDescription ?? ""
        XCTAssertTrue(text.contains("not installed"), text)
        XCTAssertTrue(text.contains("installApp()"), text)
        XCTAssertFalse(text.contains("verified during provisioning"), text)
    }

    func testInstalledOrUnknownKeepsOriginalText() {
        for verdict in [InstalledAppCheck.InstallVerdict.installed, .unknown("x")] {
            let e = InAppLauncher.launchFailure(tail: "t", verdict: verdict)
            guard case .launchFailed = e else { return XCTFail("\(e)") }
            XCTAssertTrue((e.errorDescription ?? "").contains("verified during provisioning"))
        }
    }
}
