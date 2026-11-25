import FTCore
import XCTest
@testable import FTBridgeClient

/// UDID 照合はポート専用の xctestrun 名まで見る・isAlive は HTTP で答えた失敗(401 等)を「居ない」と畳まない
final class BridgeLauncherOI380Tests: XCTestCase {
    private let udid = "B422AB58-6C79-45BC-92F0-BEF88061C8E1"

    func testRunnerMatchRequiresPortSpecificXctestrunName() {
        let command = "/x/xcodebuild test-without-building -xctestrun /r/.fleetest/DerivedData/Build/Products/FleetestRunner-8125.xctestrun"
            + " -destination platform=iOS Simulator,id=\(udid)"
        XCTAssertTrue(BridgeLauncher.isRunner(command: command, port: 8125, targeting: udid))
        // 別ポートのランナー(pid ファイルの pid が再利用された場合を含む)は UDID が一致しても数えない
        XCTAssertFalse(BridgeLauncher.isRunner(command: command, port: 8126, targeting: udid))
        // UDID の部分一致だけで拾っていた無関係なプロセス
        XCTAssertFalse(BridgeLauncher.isRunner(command: "tail -f /tmp/\(udid).log", port: 8125, targeting: udid))
        XCTAssertFalse(BridgeLauncher.isRunner(command: command, port: 8125, targeting: "OTHER-UDID"))
    }

    func testParsePidCommandLinesKeepsSpacesInCommand() {
        let out = "  101 /Users/me/Mobile Documents/x/xcodebuild -xctestrun /a b/FleetestRunner-8125.xctestrun\n"
            + "42 /bin/sh -c x\n\nbroken line\n"
        let parsed = BridgeLauncher.parsePidCommandLines(out)
        XCTAssertEqual(parsed[101], "/Users/me/Mobile Documents/x/xcodebuild -xctestrun /a b/FleetestRunner-8125.xctestrun")
        XCTAssertEqual(parsed[42], "/bin/sh -c x")
        XCTAssertEqual(parsed.count, 2)
    }

    func testAnsweredOverHTTPClassification() {
        let context = DriverErrorContext(bridge: .iosXCUITest, physicalDevice: true)
        XCTAssertTrue(BridgeDiscovery.answeredOverHTTP(error: DriverError.badResponse(status: 401, body: "token")))
        XCTAssertFalse(BridgeDiscovery.answeredOverHTTP(error: DriverError.bridgeUnreachable(context: context, detail: "")))
        XCTAssertFalse(BridgeDiscovery.answeredOverHTTP(error: DriverError.bridgeConnectionRefused(context: context, detail: "")))
    }
}
